#!/usr/bin/env python3
"""Assemble the unsigned one-app BootstrapCanary IPA and evidence manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify_canary  # noqa: E402


BUNDLE_ID = "org.floeagent.iosbridge"
TEST_BUNDLE_NAME = "BootstrapCanaryUITests.xctest"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], cwd: Path | None = None) -> str:
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(command)}\n{result.stderr}")
    return result.stdout


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


def source_manifest(repo_root: Path, canary_root: Path, artifact_dir: Path) -> dict:
    files = []
    for path in sorted(canary_root.rglob("*")):
        if not path.is_file():
            continue
        if ".xcodeproj" in path.parts and path.name != "project.pbxproj" and "xcworkspace" not in path.name:
            continue
        if path.name == ".DS_Store" or path.suffix == ".pyc":
            continue
        files.append({
            "path": str(path.relative_to(repo_root)),
            "bytes": path.stat().st_size,
            "sha256": sha256(path),
        })

    git_head = run(["git", "-C", str(repo_root), "rev-parse", "HEAD"]).strip()
    git_status = run(
        ["git", "-C", str(repo_root), "status", "--short", "--", "FloeIOSBridge/Qualification/BootstrapCanary"]
    ).strip()

    xcode_version = ""
    if Path("/Applications/Xcode-27.1.app/Contents/Developer").is_dir():
        xcode_version = run([
            "/Applications/Xcode-27.1.app/Contents/Developer/usr/bin/xcodebuild",
            "-version",
        ]).strip()

    build_command = ""
    command_file = artifact_dir / "build-command.txt"
    if command_file.is_file():
        build_command = command_file.read_text().strip()

    return {
        "generatedAt": timestamp(),
        "gitHead": git_head,
        "gitStatusForCanary": git_status.splitlines() if git_status else [],
        "xcodeVersion": xcode_version,
        "bundleIdentifier": BUNDLE_ID,
        "sourceRoot": str(canary_root.relative_to(repo_root)),
        "buildCommand": build_command,
        "files": files,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--xctest", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--ipa-name", default="BootstrapCanary-unsigned.ipa")
    parser.add_argument("--dSYM-host")
    parser.add_argument("--dSYM-test")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    canary_root = Path(__file__).resolve().parent.parent
    build_app = Path(args.app).resolve()
    build_xctest = Path(args.xctest).resolve()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    artifact_app = output_dir / "BootstrapCanary.app"
    if artifact_app.exists():
        shutil.rmtree(artifact_app)
    shutil.copytree(build_app, artifact_app, symlinks=True)

    plugs = artifact_app / "PlugIns"
    plugs.mkdir(parents=True, exist_ok=True)
    destination_xctest = plugs / TEST_BUNDLE_NAME
    if destination_xctest.exists():
        shutil.rmtree(destination_xctest)
    shutil.copytree(build_xctest, destination_xctest, symlinks=True)

    host_plist = artifact_app / "Info.plist"
    test_plist = destination_xctest / "Info.plist"
    host_id = verify_canary.plist_raw(host_plist, "CFBundleIdentifier")
    test_id = verify_canary.plist_raw(test_plist, "CFBundleIdentifier")
    if host_id != BUNDLE_ID:
        raise RuntimeError(f"host bundle ID is {host_id!r}, expected {BUNDLE_ID!r}")
    if test_id != host_id:
        raise RuntimeError(f"test bundle ID {test_id!r} does not align with host {host_id!r}")

    app_result = verify_canary.check_app(artifact_app, require_unsigned=True)
    (output_dir / "verify-app.json").write_text(json.dumps(app_result, indent=2, sort_keys=True) + "\n")
    if not app_result["ok"]:
        for failure in app_result["failures"]:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1

    ipa_path = output_dir / args.ipa_name
    if ipa_path.exists():
        ipa_path.unlink()
    with tempfile.TemporaryDirectory(prefix="bootstrap-canary-package-") as temporary:
        payload = Path(temporary) / "Payload"
        payload.mkdir()
        shutil.copytree(artifact_app, payload / "BootstrapCanary.app", symlinks=True)
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(payload), str(ipa_path)])

    ipa_result = verify_canary.check_ipa(ipa_path, require_unsigned=True)
    (output_dir / "verify-ipa.json").write_text(json.dumps(ipa_result, indent=2, sort_keys=True) + "\n")
    if not ipa_result["ok"]:
        for failure in ipa_result["failures"]:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1

    if args.dSYM_host:
        source = Path(args.dSYM_host).resolve()
        if source.is_dir():
            target = output_dir / source.name
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(source, target, symlinks=True)
    if args.dSYM_test:
        source = Path(args.dSYM_test).resolve()
        if source.is_dir():
            target = output_dir / source.name
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(source, target, symlinks=True)

    host_binary = artifact_app / "BootstrapCanary"
    test_binary = destination_xctest / "BootstrapCanaryUITests"
    manifest = {
        "generatedAt": timestamp(),
        "artifact": {
            "ipa": str(ipa_path),
            "ipaBytes": ipa_path.stat().st_size,
            "ipaSHA256": sha256(ipa_path),
            "app": str(artifact_app),
            "appHostBinarySHA256": sha256(host_binary),
            "xctest": str(destination_xctest),
            "xctestBinarySHA256": sha256(test_binary),
            "signed": False,
            "bundleIdentifier": BUNDLE_ID,
        },
        "source": source_manifest(repo_root, canary_root, output_dir),
        "verification": {
            "appOK": app_result["ok"],
            "ipaOK": ipa_result["ok"],
            "hostLoads": app_result["hostLoads"],
            "hostRpaths": app_result.get("hostRpaths", []),
            "testLoads": app_result["testLoads"],
            "testRpaths": app_result["testRpaths"],
        },
    }
    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    (output_dir / "otool-host.txt").write_text("\n".join(app_result["hostLoads"]) + "\n")
    (output_dir / "otool-test.txt").write_text("\n".join(app_result["testLoads"]) + "\n")

    print(json.dumps({
        "ipa": str(ipa_path),
        "ipaSHA256": manifest["artifact"]["ipaSHA256"],
        "ipaBytes": manifest["artifact"]["ipaBytes"],
        "appOK": app_result["ok"],
        "ipaOK": ipa_result["ok"],
        "manifest": str(output_dir / "manifest.json"),
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
