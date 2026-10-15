#!/usr/bin/env python3
"""python-venv-seed-verify.py — verify a Floe Python venv seed and its manifest.

Checks (the reproducible-hash gate for the image recipe):
  1. the manifest exists, parses and has schema floe-python-venv-seed/v1;
  2. the seed path is absolute and NOT under /floe (a seed there would be
     shadowed by the per-environment writable layer);
  3. `materialize_target` is the per-environment venv path
     (/floe/env/python/venv), i.e. seed and live venv are separate;
  4. every file/symlink recorded in the manifest exists under the rootfs with
     the recorded content hash (or link target), and no other file appears
     under the seed (extra files fail: the manifest is the exact inventory);
  5. pyvenv.cfg's `version`/`include-system-site-packages` match the manifest;
  6. optional `--run`: executes <root>/<seed>/bin/python3 (the caller must be
     able to run it — a riscv64 rootfs needs qemu-user / the guest itself)
     and requires the same version string and a working `import pip`.

Usage:
  python-venv-seed-verify.py --root <rootfs-dir> [--manifest PATH] [--run]
Exit: 0 = all checks pass; 1 = verification failure; 2 = usage/IO error.
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys


def fail(problems, message):
    problems.append(message)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(root, manifest_path, run, timeout):
    problems = []
    if not os.path.isfile(manifest_path):
        return ["manifest not found: %s" % manifest_path], {}
    try:
        with open(manifest_path, encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        return ["manifest unreadable: %s" % error], {}

    if manifest.get("schema") != "floe-python-venv-seed/v1":
        fail(problems, "unexpected schema: %r" % manifest.get("schema"))
    seed_path = manifest.get("seed_path", "")
    if not seed_path.startswith("/"):
        fail(problems, "seed_path is not absolute: %r" % seed_path)
    if seed_path == "/floe" or seed_path.startswith("/floe/"):
        fail(problems, "seed_path is under the per-environment layer: %s" % seed_path)
    if manifest.get("materialize_target") != "/floe/env/python/venv":
        fail(problems, "materialize_target must be /floe/env/python/venv (got %r)"
             % manifest.get("materialize_target"))

    seed_dir = os.path.join(root, seed_path.lstrip("/"))
    if not os.path.isdir(seed_dir):
        fail(problems, "seed directory missing: %s" % seed_dir)
        return problems, manifest

    files = manifest.get("files") or {}
    if not files:
        fail(problems, "manifest records no files")
    for rel, record in sorted(files.items()):
        full = os.path.join(seed_dir, rel)
        if "link" in record:
            if not os.path.islink(full):
                fail(problems, "%s: expected symlink" % rel)
            elif os.readlink(full) != record["link"]:
                fail(problems, "%s: symlink target %r != %r"
                     % (rel, os.readlink(full), record["link"]))
            continue
        if not os.path.isfile(full):
            fail(problems, "%s: missing" % rel)
            continue
        digest = sha256_file(full)
        if digest != record.get("sha256"):
            fail(problems, "%s: sha256 %s != manifest %s" % (rel, digest, record.get("sha256")))
        size = os.path.getsize(full)
        if size != record.get("bytes"):
            fail(problems, "%s: size %d != manifest %d" % (rel, size, record.get("bytes")))

    # exact inventory: nothing under the seed may be absent from the manifest
    seen = set()
    for base, _dirs, names in os.walk(seed_dir):
        for name in names:
            seen.add(os.path.relpath(os.path.join(base, name), seed_dir))
    extra = sorted(seen - set(files))
    if extra:
        fail(problems, "files not in the manifest: %s" % ", ".join(extra[:8]))

    pyvenv = os.path.join(seed_dir, "pyvenv.cfg")
    if os.path.isfile(pyvenv):
        values = {}
        with open(pyvenv, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if "=" in line:
                    key, value = line.split("=", 1)
                    values[key.strip()] = value.strip()
        recorded = manifest.get("python") or {}
        if recorded.get("version") and values.get("version") != recorded["version"]:
            fail(problems, "pyvenv.cfg version %r != manifest %r"
                 % (values.get("version"), recorded.get("version")))
        if recorded.get("include_system_site_packages") and values.get("include-system-site-packages") != "true":
            fail(problems, "pyvenv.cfg include-system-site-packages is not true")
    else:
        fail(problems, "pyvenv.cfg missing")

    result = {"manifest": manifest_path, "seed_path": seed_path,
              "file_count": len(files), "ran": False}
    if run:
        python = os.path.join(seed_dir, "bin", "python3")
        if not os.access(python, os.X_OK):
            fail(problems, "seed python is not executable: %s" % python)
        else:
            try:
                version = subprocess.run([python, "-c", "import sys; print(sys.version.split()[0])"],
                                         capture_output=True, text=True, timeout=timeout, check=True)
                expected = (manifest.get("python") or {}).get("version", "")
                if expected and version.stdout.strip() != expected:
                    fail(problems, "seed python reports %r != manifest %r" % (version.stdout.strip(), expected))
                subprocess.run([python, "-c", "import pip"], capture_output=True, text=True,
                               timeout=timeout, check=True)
                result["ran"] = True
            except (OSError, subprocess.SubprocessError) as error:
                fail(problems, "cannot run the seed interpreter: %s" % error)
    return problems, result


def main(argv=None):
    parser = argparse.ArgumentParser(description="verify a Floe Python venv seed")
    parser.add_argument("--root", default="/", help="rootfs directory (default /)")
    parser.add_argument("--manifest", default=None,
                        help="manifest path (default <root>/usr/lib/floe/python/venv-seed.manifest.json)")
    parser.add_argument("--run", action="store_true",
                        help="also execute the seed interpreter (same arch as the host)")
    parser.add_argument("--timeout", type=float, default=60.0)
    args = parser.parse_args(argv)

    manifest = args.manifest or os.path.join(
        args.root, "usr/lib/floe/python/venv-seed.manifest.json")
    problems, result = verify(args.root, manifest, args.run, args.timeout)
    for problem in problems:
        print("SEED VERIFY FAILED: %s" % problem)
    if problems:
        return 1
    print("seed verify ok: %s files=%d ran=%s"
          % (result["seed_path"], result["file_count"], result["ran"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
