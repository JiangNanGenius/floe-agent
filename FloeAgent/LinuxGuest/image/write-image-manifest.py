#!/usr/bin/env python3
"""write-image-manifest.py — write or verify the guest image manifest that the
app's LinuxGuestImageStore expects.

The schema is the Codable shape of `LinuxGuestImage` in
FloeAgent/Sources/FloeExecution/Linux/LinuxGuestService.swift (branch
codex/feedback-integration):

    {
      "id": "...",
      "biosPath": "bbl64.bin",
      "kernelPath": "kernel-riscv64.bin",       (optional)
      "initrdPath": "...",                      (optional)
      "diskPath": "disk.img",                   (optional)
      "diskReadWrite": true,
      "cmdline": "console=hvc0 root=/dev/vda rw loglevel=4",
      "qualified": true,
      "qualificationEvidence": "...",
      "qualificationRun": "https://github.com/.../actions/runs/<id>",
      "artifacts": [
        {"role": "bios", "path": "bbl64.bin", "sha512": "<128 hex>", "bytes": 53786},
        {"role": "kernel", "path": "kernel-riscv64.bin", "sha512": "...", "bytes": 3946740},
        {"role": "disk", "path": "disk.img", "sha512": "...", "bytes": 3085959168}
      ],
      "provenance": {
        "sourceURL": "...", "buildConfigurationURL": "...",
        "license": "...", "distributionAllowed": false
      }
    }

`write` refuses to emit `qualified: true` without a qualification run id.
`verify` re-checks the same things LinuxGuestImageVerifier checks: the declared
roles have digests, every digest is 128 hex chars, every artifact exists as a
regular file inside the image directory with the recorded size and SHA-512.
Paths in the manifest are relative, which is the portable form the app's
importer keeps intact inside the image directory.

This script never "forces" qualified: the caller passes the flag that the
actual capability run produced.
"""
import argparse
import hashlib
import json
import os
import re
import sys

ROLES = ("bios", "kernel", "initrd", "disk")
HEX512 = re.compile(r"^[0-9a-f]{128}$")


def sha512_and_size(path):
    digest = hashlib.sha512()
    size = 0
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def relative_inside(image_dir, path):
    """Return `path` as a path relative to image_dir, rejecting escapes."""
    absolute = os.path.abspath(path)
    root = os.path.abspath(image_dir)
    if not absolute.startswith(root + os.sep):
        raise SystemExit("artifact %s is outside the image directory %s" % (path, image_dir))
    return os.path.relpath(absolute, root)


def build_manifest(args):
    image_dir = os.path.abspath(args.image_dir)
    artifacts = []
    declared = []

    def add(role, path):
        if not path:
            return
        if os.path.islink(path) or not os.path.isfile(path):
            raise SystemExit("%s is not a regular file: %s" % (role, path))
        rel = relative_inside(image_dir, path)
        digest, size = sha512_and_size(path)
        artifacts.append({"role": role, "path": rel, "sha512": digest, "bytes": size})
        declared.append(role)

    add("bios", args.bios)
    add("kernel", args.kernel)
    add("initrd", args.initrd)
    add("disk", args.disk)

    for role in ("bios",):
        if role not in declared:
            raise SystemExit("the manifest needs a %s artifact" % role)

    if args.qualified and not (args.qualification_run or "").strip():
        raise SystemExit("refusing to write qualified=true without a qualification run id")

    manifest = {
        "id": args.id,
        "biosPath": next(a["path"] for a in artifacts if a["role"] == "bios"),
        "diskReadWrite": not args.read_only_disk,
        "qualified": bool(args.qualified),
    }
    for role, key in (("kernel", "kernelPath"), ("initrd", "initrdPath"), ("disk", "diskPath")):
        for artifact in artifacts:
            if artifact["role"] == role:
                manifest[key] = artifact["path"]
    if args.cmdline:
        manifest["cmdline"] = args.cmdline
    if args.qualification_evidence:
        manifest["qualificationEvidence"] = args.qualification_evidence
    if args.qualification_run:
        manifest["qualificationRun"] = args.qualification_run
    manifest["artifacts"] = artifacts
    manifest["provenance"] = {
        "sourceURL": args.source_url or "",
        "buildConfigurationURL": args.build_configuration_url or "",
        "license": args.license or "",
        "distributionAllowed": bool(args.distribution_allowed),
    }
    return manifest


def verify_manifest(image_dir, manifest_path):
    image_dir = os.path.abspath(image_dir)
    with open(manifest_path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    problems = []

    def fail(message):
        problems.append(message)

    declared = [("bios", manifest.get("biosPath"))]
    for key, role in (("kernelPath", "kernel"), ("initrdPath", "initrd"), ("diskPath", "disk")):
        if manifest.get(key):
            declared.append((role, manifest[key]))
    artifacts = manifest.get("artifacts") or []
    by_role = {artifact.get("role"): artifact for artifact in artifacts}

    if not manifest.get("id"):
        fail("manifest has no id")
    if manifest.get("qualified"):
        if not (manifest.get("qualificationRun") or "").strip():
            fail("qualified=true without qualificationRun")
        if not artifacts:
            fail("qualified=true without artifact digests")
    for role, path in declared:
        artifact = by_role.get(role)
        if not artifact:
            fail("no digest for declared %s" % role)
            continue
        if artifact.get("path") != path:
            fail("%s digest path %r != manifest path %r" % (role, artifact.get("path"), path))
            continue
        digest = str(artifact.get("sha512", "")).strip().lower()
        if not HEX512.match(digest):
            fail("%s sha512 is not 128 hex chars" % role)
            continue
        if int(artifact.get("bytes", 0)) <= 0:
            fail("%s records no size" % role)
            continue
        target = path if os.path.isabs(path) else os.path.join(image_dir, path)
        if os.path.islink(target) or not os.path.isfile(target):
            fail("%s is missing or not a regular file: %s" % (role, target))
            continue
        actual_digest, actual_size = sha512_and_size(target)
        if actual_size != int(artifact["bytes"]):
            fail("%s size mismatch: on disk %d, manifest %d" % (role, actual_size, int(artifact["bytes"])))
        if actual_digest != digest:
            fail("%s SHA-512 mismatch" % role)

    if problems:
        for problem in problems:
            print("VERIFY FAIL: %s" % problem, file=sys.stderr)
        return 1
    print("VERIFY OK: %s" % manifest_path)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    write = sub.add_parser("write", help="write manifest.json from the image artifacts")
    write.add_argument("--image-dir", required=True)
    write.add_argument("--out", default=None, help="defaults to <image-dir>/manifest.json")
    write.add_argument("--id", required=True)
    write.add_argument("--bios", required=True)
    write.add_argument("--kernel", default=None)
    write.add_argument("--initrd", default=None)
    write.add_argument("--disk", default=None)
    write.add_argument("--cmdline", default=None)
    write.add_argument("--qualification-run", default=None)
    write.add_argument("--qualification-evidence", default=None)
    write.add_argument("--source-url", default=None)
    write.add_argument("--build-configuration-url", default=None)
    write.add_argument("--license", default=None)
    write.add_argument("--qualified", action="store_true", help="set only when the capability run really passed")
    write.add_argument("--distribution-allowed", action="store_true",
                       help="set only when corresponding source + license obligations are published")
    write.add_argument("--read-only-disk", action="store_true")

    verify = sub.add_parser("verify", help="re-check a manifest the way LinuxGuestImageVerifier does")
    verify.add_argument("--image-dir", required=True)
    verify.add_argument("--manifest", default=None, help="defaults to <image-dir>/manifest.json")

    args = parser.parse_args(argv)
    if args.command == "write":
        image_dir = os.path.abspath(args.image_dir)
        manifest = build_manifest(args)
        out = args.out or os.path.join(image_dir, "manifest.json")
        with open(out, "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, indent=2, sort_keys=False)
            handle.write("\n")
        print("wrote %s (qualified=%s, artifacts=%d)" % (out, manifest["qualified"], len(manifest["artifacts"])))
        return 0
    manifest_path = args.manifest or os.path.join(os.path.abspath(args.image_dir), "manifest.json")
    return verify_manifest(args.image_dir, manifest_path)


if __name__ == "__main__":
    sys.exit(main())
