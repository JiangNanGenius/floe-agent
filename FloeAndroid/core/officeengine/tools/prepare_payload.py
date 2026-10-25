#!/usr/bin/env python3
"""Stage or verify the pinned Office producer payload from the signed publisher APK.

This is repository build tooling for the Floe Office engine module. It does
not install an app, grant a permission, publish a dependency, rebuild the
engine, or prove rendering. It only:

  * (staging) verifies the byte-exact signed publisher APK and streams the
    manifest-listed assets/native libraries into a new, task-owned output
    directory with per-file SHA-256 verification and an atomic rename, and
  * (--check) read-only verifies an existing staging tree against the public
    canonical producer-manifest.json.

The manifest co-located with this script (../producer-manifest.json) is the
single source of truth for artifact identity (APK SHA-256, pinned signer
certificate SHA-256, producer revision) and for the exact per-file byte
lengths and SHA-256 values of every staged member. Module pin authority
lives in ../payload-pins.json (Main-owned); this tool never rewrites pins.

Usage:
  python3 prepare_payload.py --apk /path/to/pinned.apk --output /new/owned/dir
  python3 prepare_payload.py --check /path/to/existing/staging

Standard library only. Python 3.9+. apksigner (Android SDK build-tools) is
required for staging; discovery order: --apksigner, $ANDROID_SDK_ROOT,
$ANDROID_HOME, repository toolchain, then PATH. See README.md for the full
fresh-source recipe.

Exit codes: 0 success, 2 verification/usage failure (fail closed).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path, PurePosixPath

HERE = Path(__file__).resolve().parent
DEFAULT_MANIFEST = HERE.parent / "producer-manifest.json"

# Bounded staging budget: the pinned cohort is ~305 MB / 5291 files, so these
# bounds only catch accidents or substitutions, never legitimate input.
MAX_FILE_BYTES = 256 * 1024 * 1024
MAX_TOTAL_BYTES = 1024 * 1024 * 1024
MAX_MEMBERS = 65536

# apksigner has shipped two human-readable formats:
#   older: "V3.0 Signer: certificate SHA-256 digest: <hex>"
#   newer: "Signer #1 certificate SHA-256 digest: <hex>"
APKSIGNER_CERT_RE = re.compile(
    r"^\s*(?:Signer #\d+|V\d+(?:\.\d+)* Signer):?\s+certificate SHA-256 digest:\s*([0-9a-f]{64})\s*$",
    re.I | re.M,
)


class Failure(Exception):
    """Verification/usage failure: fail closed with exit code 2."""


def sha256_stream(stream) -> str:
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(1 << 20), b""):
        digest.update(block)
    return digest.hexdigest()


def sha256_file(path: Path) -> str:
    with path.open("rb") as handle:
        return sha256_stream(handle)


def safe_member(name: str) -> PurePosixPath:
    """Return a canonical relative archive path or raise."""
    candidate = PurePosixPath(name)
    if (
        not name
        or name.startswith("/")
        or "\\" in name
        or "\x00" in name
        or ".." in candidate.parts
        or "." in candidate.parts
        or str(candidate) != name
    ):
        raise Failure(f"unsafe/non-canonical archive member: {name!r}")
    return candidate


def load_manifest(path: Path) -> dict:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise Failure(f"cannot read manifest {path}: {exc}")
    manifest = json.loads(raw)
    for key in ("source", "artifact", "selectedFiles", "selectedBytes",
                "nativeLibraries", "files"):
        if key not in manifest:
            raise Failure(f"manifest {path} lacks required key {key!r}")
    files = manifest["files"]
    if not isinstance(files, dict) or not files:
        raise Failure("manifest 'files' must be a non-empty object")
    for rel, entry in files.items():
        safe_member(rel)
        if set(entry.keys()) != {"bytes", "sha256"}:
            raise Failure(f"manifest entry {rel!r} must have exactly bytes+sha256")
        if not isinstance(entry["bytes"], int) or entry["bytes"] < 0:
            raise Failure(f"manifest entry {rel!r} has invalid bytes")
        if not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
            raise Failure(f"manifest entry {rel!r} has invalid sha256")
    total = sum(entry["bytes"] for entry in files.values())
    if len(files) > MAX_MEMBERS or total > MAX_TOTAL_BYTES:
        raise Failure("manifest cohort exceeds bounded staging budget")
    if total != manifest["selectedBytes"] or len(files) != manifest["selectedFiles"]:
        raise Failure("manifest counts disagree with per-file records")
    return manifest


def find_apksigner(explicit: str | None) -> Path:
    if explicit:
        path = Path(explicit)
        if path.is_file():
            return path
        raise Failure(f"--apksigner not found: {explicit}")
    candidates = []
    for env_key in ("ANDROID_SDK_ROOT", "ANDROID_HOME"):
        value = os.environ.get(env_key)
        if value:
            candidates.extend(Path(value).glob("build-tools/*/apksigner"))
    for parent in [HERE, *HERE.parents]:
        toolchain = parent / "Local" / "Private" / "android-toolchains" / "android-sdk"
        if toolchain.is_dir():
            candidates.extend(toolchain.glob("build-tools/*/apksigner"))
            break
    which = shutil.which("apksigner")
    if which:
        candidates.append(Path(which))
    usable = [c for c in candidates
              if c.is_file() and os.access(c, os.X_OK)]
    if not usable:
        raise Failure(
            "apksigner not found; pass --apksigner or set ANDROID_SDK_ROOT "
            "(Android SDK build-tools 37+ required)"
        )
    # Prefer the newest build-tools (e.g. 37 over 36) when several exist.
    return sorted(usable, key=lambda c: str(c))[-1]
    raise Failure(
        "apksigner not found; pass --apksigner or set ANDROID_SDK_ROOT "
        "(Android SDK build-tools 37+ required)"
    )


def java_env(explicit: str | None) -> dict:
    env = dict(os.environ)
    if explicit:
        env["JAVA_HOME"] = explicit
        return env
    if env.get("JAVA_HOME"):
        return env
    for parent in [HERE, *HERE.parents]:
        jdk = parent / "Local" / "Private" / "android-toolchains" / "jdk"
        if jdk.is_dir():
            homes = sorted(jdk.glob("jdk-*/Contents/Home")) + sorted(jdk.glob("jdk-*"))
            if homes:
                env["JAVA_HOME"] = str(homes[0])
                return env
    return env


def verify_apk_signature(apk: Path, apksigner: Path, java_home: str | None,
                         pinned_signer: str) -> dict:
    env = java_env(java_home)
    command = [str(apksigner), "verify", "--verbose", "--print-certs", str(apk)]
    try:
        result = subprocess.run(command, env=env, capture_output=True, text=True)
    except OSError as exc:
        raise Failure(f"cannot execute apksigner: {exc}")
    certificates = {value.lower() for value in APKSIGNER_CERT_RE.findall(result.stdout)}
    if (
        result.returncode != 0
        or not certificates
        or certificates != {pinned_signer.lower()}
        or "Number of signers: 1" not in result.stdout
    ):
        detail = (result.stdout + result.stderr).strip()[-400:] or "no output"
        raise Failure(f"APK signature/pinned signer verification failed: {detail}")
    return {"apksigner": str(apksigner), "signerCertSha256": pinned_signer}


def validate_archive(zip_path: Path, manifest: dict) -> dict:
    """Open the APK and validate every member against the manifest cohort."""
    try:
        archive = zipfile.ZipFile(zip_path)
    except (OSError, zipfile.BadZipFile) as exc:
        raise Failure(f"cannot open APK {zip_path}: {exc}")
    with archive:
        infos = archive.infolist()
        seen: set[str] = set()
        staged = []
        for info in infos:
            name = info.filename
            if name in seen:
                raise Failure(f"duplicate archive member: {name!r}")
            seen.add(name)
            if info.is_dir():
                continue
            safe_member(name)
            unix_mode = (info.external_attr >> 16) & 0o170000
            if unix_mode == 0o120000 or info.flag_bits & 1:
                raise Failure(f"symlink/encrypted archive member: {name!r}")
            if name in manifest["files"]:
                if info.file_size < 0 or info.file_size > MAX_FILE_BYTES:
                    raise Failure(f"member exceeds bounded staging budget: {name!r}")
                staged.append(info)
        wanted = set(manifest["files"])
        selected = {info.filename for info in staged}
        missing = wanted - selected
        if missing:
            sample = sorted(missing)[:3]
            raise Failure(f"APK is missing {len(missing)} manifest-listed members, e.g. {sample}")
        total = sum(info.file_size for info in staged)
        if total > MAX_TOTAL_BYTES:
            raise Failure("selected cohort exceeds bounded staging budget")
        # Stream-hash every selected member against the manifest record so a
        # substituted APK fails before anything reaches the output directory.
        for info in staged:
            entry = manifest["files"][info.filename]
            if info.file_size != entry["bytes"]:
                raise Failure(f"archive member size drift: {info.filename!r}")
            with archive.open(info, "r") as stream:
                actual = sha256_stream(stream)
            if actual != entry["sha256"]:
                raise Failure(f"archive member SHA-256 mismatch: {info.filename!r}")
        # Producer provenance tie: the embedded build id must match the pinned
        # mobile revision (buildid = first 10 hex of the revision, per the
        # producer's own createRCfiles mechanism).
        revision = manifest["source"]["revision"]
        try:
            versionrc = archive.read("assets/program/versionrc").decode("utf-8")
        except (KeyError, UnicodeDecodeError):
            raise Failure("APK lacks assets/program/versionrc; not the pinned artifact")
        if "buildid=" + revision[:10] not in versionrc:
            raise Failure("embedded build id does not match the pinned producer revision")
        return {"selectedFiles": len(staged), "selectedBytes": total}


def stage(zip_path: Path, output: Path, manifest: dict, apksigner: Path,
          java_home: str | None) -> dict:
    artifact = manifest["artifact"]
    actual_apk_sha = sha256_file(zip_path)
    if actual_apk_sha != artifact["sha256"]:
        raise Failure(
            f"APK SHA-256 {actual_apk_sha} != pinned {artifact['sha256']}"
        )
    signature = verify_apk_signature(zip_path, apksigner, java_home,
                                     artifact["signerSha256"])
    cohort = validate_archive(zip_path, manifest)

    output = output.expanduser().resolve()
    if output.exists():
        raise Failure(f"output directory already exists (refusing to overwrite): {output}")
    if not output.parent.is_dir():
        raise Failure(f"output parent directory does not exist: {output.parent}")
    partial = output.with_name(output.name + ".partial")
    if partial.exists():
        shutil.rmtree(partial)
    partial.mkdir(mode=0o700)
    written = 0
    try:
        with zipfile.ZipFile(zip_path) as archive:
            for rel, entry in manifest["files"].items():
                target = partial / str(safe_member(rel))
                target.parent.mkdir(parents=True, exist_ok=True)
                source = archive.open(archive.getinfo(rel), "r")
                digest = hashlib.sha256()
                with source, target.open("xb") as stream:
                    for block in iter(lambda: source.read(1 << 20), b""):
                        digest.update(block)
                        stream.write(block)
                if digest.hexdigest() != entry["sha256"] or target.stat().st_size != entry["bytes"]:
                    raise Failure(f"staged file verification failed: {rel!r}")
                written += 1
        if written != len(manifest["files"]):
            raise Failure(f"staged {written} files != manifest {len(manifest['files'])}")
        os.rename(partial, output)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    return {
        "mode": "stage",
        "apk": str(zip_path),
        "apkSha256": actual_apk_sha,
        "output": str(output),
        "stagedFiles": written,
        "stagedBytes": manifest["selectedBytes"],
        "signature": signature,
        "manifestSha256": manifest.get("_manifestSha256"),
    }


def check(tree: Path, manifest: dict) -> dict:
    tree = tree.expanduser().resolve()
    if not tree.is_dir():
        raise Failure(f"staging directory not found: {tree}")
    wanted = manifest["files"]
    missing: list[str] = []
    corrupt: list[str] = []
    symlinked: list[str] = []
    extras: list[str] = []
    checked = 0
    for root, dirs, files in os.walk(tree):
        for name in files:
            path = Path(root) / name
            rel = path.relative_to(tree).as_posix()
            if rel not in wanted:
                extras.append(rel)
                continue
            if path.is_symlink():
                symlinked.append(rel)
                continue
            entry = wanted[rel]
            size = path.stat().st_size
            if size != entry["bytes"]:
                corrupt.append(f"{rel} (size {size} != {entry['bytes']})")
                continue
            if sha256_file(path) != entry["sha256"]:
                corrupt.append(f"{rel} (sha256)")
                continue
            checked += 1
    for rel in wanted:
        if not (tree / rel).is_file():
            missing.append(rel)
    for directory in [tree, *[Path(root) / d for root, dirs, _ in os.walk(tree) for d in dirs]]:
        if directory.is_symlink():
            symlinked.append(str(directory.relative_to(tree)) + "/")
    report = {
        "mode": "check",
        "tree": str(tree),
        "manifestSha256": manifest.get("_manifestSha256"),
        "expectedFiles": len(wanted),
        "verifiedFiles": checked,
        "missingCount": len(missing),
        "corruptCount": len(corrupt),
        "symlinkCount": len(symlinked),
        "extraCount": len(extras),
        "missingSample": sorted(missing)[:5],
        "corruptSample": sorted(corrupt)[:5],
        "symlinkSample": sorted(symlinked)[:5],
        "extraSample": sorted(extras)[:5],
        "ok": not (missing or corrupt or symlinked),
    }
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST,
                        help="producer manifest (default: ../producer-manifest.json)")
    parser.add_argument("--apk", type=Path, help="byte-exact signed publisher APK")
    parser.add_argument("--output", type=Path, help="new owned staging directory")
    parser.add_argument("--check", type=Path, metavar="TREE",
                        help="read-only verify an existing staging tree")
    parser.add_argument("--apksigner", help="path to apksigner (build-tools 37+)")
    parser.add_argument("--java-home", help="JAVA_HOME for apksigner")
    args = parser.parse_args(argv)

    try:
        manifest_path = args.manifest.resolve()
        if manifest_path.stat().st_size > 4 * 1024 * 1024:
            raise Failure("producer manifest exceeds 4 MiB")
        pin_path = DEFAULT_MANIFEST.parent / "payload-pins.json"
        pins = json.loads(pin_path.read_text(encoding="utf-8"))
        expected = pins["payload"]["manifestSha256"]
        actual = sha256_file(manifest_path)
        if actual != expected:
            raise Failure("producer manifest does not match the source-controlled module pin")
        manifest = load_manifest(manifest_path)
        manifest["_manifestSha256"] = actual
        if args.check is not None:
            report = check(args.check, manifest)
        else:
            if args.apk is None or args.output is None:
                raise Failure("staging requires --apk and --output (or use --check)")
            apksigner = find_apksigner(args.apksigner)
            report = stage(args.apk, args.output, manifest, apksigner, args.java_home)
    except (Failure, OSError, ValueError, KeyError, TypeError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, indent=2))
        return 2

    report.pop("_manifestSha256", None)
    print(json.dumps(report, indent=2))
    return 0 if report.get("ok", True) else 2


if __name__ == "__main__":
    sys.exit(main())
