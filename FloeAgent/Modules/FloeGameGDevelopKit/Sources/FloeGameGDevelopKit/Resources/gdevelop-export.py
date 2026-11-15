#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Export a standard GDevelop project with the official SDK.

This is a checked build recipe, not a general-purpose interpreter or App tool.
It never edits the source tree: a private staging copy is exported, the
official GDevelop CLI writes its normal `build/` folder, and the verified
bytes are published to a new output directory. The script re-verifies the
pinned SDK archive/receipt and writes a deterministic manifest.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

PLATFORMS = {
    "macOSUniversal": {
        "executable": "GDevelop 5.app/Contents/MacOS/GDevelop 5",
        "runtime_index": "GDevelop 5.app/Contents/Resources/GDJS/Runtime/index.html",
    },
    "linuxX86_64": {
        "executable": "gdevelop",
        "runtime_index": "resources/GDJS/Runtime/index.html",
    },
}


def fail(message):
    print("error: " + message, file=sys.stderr)
    raise SystemExit(1)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_digest(files):
    payload = "\n".join(
        f"{item['path']}:{item['sha256']}:{item['bytes']}:false" for item in files
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as stream:
            return json.load(stream)
    except Exception as error:
        fail(f"cannot read {path}: {error}")


def write_json_atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
    with open(temporary, "w", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def verify_receipt(receipt_path, platform, expected_version, expected_sha):
    receipt = read_json(receipt_path)
    spec = PLATFORMS[platform]
    expected = {
        "version": expected_version,
        "platform": platform,
        "assetSHA256": expected_sha,
        "assetVerified": True,
        "executableRelativePath": spec["executable"],
        "runtimeIndexRelativePath": spec["runtime_index"],
    }
    for key, value in expected.items():
        if receipt.get(key) != value:
            fail(f"sdk-receipt.json mismatch for {key}")
    return receipt


def extract_and_receipt(sdk_zip, sdk_root, platform, version, expected_sha):
    if sdk_zip is None:
        fail("--sdk-zip is required when no verified sdk-receipt.json exists")
    if not sdk_zip.is_file():
        fail(f"SDK zip is missing: {sdk_zip}")
    actual = sha256_file(sdk_zip)
    if actual != expected_sha:
        fail(f"SDK zip SHA256 mismatch: {actual}")
    if sdk_root.exists() and any(sdk_root.iterdir()):
        fail(f"SDK root is not empty: {sdk_root}")
    sdk_root.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["unzip", "-q", str(sdk_zip), "-d", str(sdk_root)],
        capture_output=True, text=True, timeout=600,
    )
    if result.returncode != 0:
        fail("official SDK unzip failed: " + (result.stderr or result.stdout))
    spec = PLATFORMS[platform]
    executable = sdk_root / spec["executable"]
    runtime_index = sdk_root / spec["runtime_index"]
    if not executable.is_file() or not runtime_index.is_file():
        fail("official SDK layout is incomplete")
    receipt = {
        "version": version,
        "platform": platform,
        "assetName": sdk_zip.name,
        "assetSHA256": expected_sha,
        "assetVerified": True,
        "executableRelativePath": spec["executable"],
        "runtimeIndexRelativePath": spec["runtime_index"],
        "runtimeIndexSHA256": sha256_file(runtime_index),
    }
    write_json_atomic(sdk_root / "sdk-receipt.json", receipt)
    return receipt


def ensure_sdk(args):
    sdk_root = Path(args.sdk_root).resolve()
    sdk_zip = Path(args.sdk_zip).resolve() if args.sdk_zip else None
    receipt_path = sdk_root / "sdk-receipt.json"
    if receipt_path.is_file():
        receipt = verify_receipt(receipt_path, args.platform, args.sdk_version, args.sdk_sha256)
    else:
        receipt = extract_and_receipt(
            sdk_zip, sdk_root, args.platform, args.sdk_version, args.sdk_sha256
        )
    executable = sdk_root / receipt["executableRelativePath"]
    runtime_index = sdk_root / receipt["runtimeIndexRelativePath"]
    if not executable.is_file() or not runtime_index.is_file():
        fail("official SDK executable/runtime is missing")
    if sha256_file(runtime_index) != receipt["runtimeIndexSHA256"]:
        fail("official SDK runtime index SHA256 mismatch")
    return receipt


def copy_source(source, destination):
    ignored = {"build", ".git", ".swiftpm", "DerivedData"}

    def ignore(directory, names):
        return [name for name in names if name in ignored]

    shutil.copytree(source, destination, symlinks=False, ignore=ignore)


def normalize_data_js(build):
    """Clear the editor's random staging path from the exported data.

    Official `EXPORT_HTML5_EXTERNAL` writes the temporary compilation
    directory into `properties.latestCompilationDirectory`. It is metadata,
    not game logic, but it makes otherwise identical exports differ and leaks
    a local path. Normalize only that JSON string; all other official bytes
    stay untouched.
    """
    path = build / "data.js"
    text = path.read_text(encoding="utf-8")
    pattern = r'("latestCompilationDirectory"\s*:\s*)"(?:\\.|[^"\\])*"'
    replaced, count = re.subn(pattern, r'\1""', text, count=1)
    if count != 1:
        fail("data.js has no latestCompilationDirectory field to normalize")
    path.write_text(replaced, encoding="utf-8")


def verify_build(build):
    required = ["index.html", "data.js", "gd.js", "LICENSE.GDevelop.txt"]
    for name in required:
        if not (build / name).is_file() or (build / name).stat().st_size == 0:
            fail(f"official export is missing {name}")
    if not any(path.name.startswith("code") and path.suffix == ".js" for path in build.iterdir()):
        fail("official export is missing compiled code*.js")
    if not any(path.name == "pixi.js" for path in build.rglob("pixi.js")):
        fail("official export is missing the GDJS pixi runtime")


def manifest_files(root):
    files = []
    total = 0
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            fail(f"symlink in export: {path}")
        if not path.is_file():
            continue
        size = path.stat().st_size
        if size > 64 * 1024 * 1024:
            fail(f"export file too large: {path}")
        total += size
        if total > 512 * 1024 * 1024:
            fail("export total size limit exceeded")
        files.append({
            "path": path.relative_to(root).as_posix(),
            "sha256": sha256_file(path),
            "bytes": size,
        })
    return files, total


def run_export(args):
    if not args.project or Path(args.project).is_absolute():
        fail("--project must be a relative path")
    project_rel = Path(args.project)
    if any(part == ".." for part in project_rel.parts) or project_rel.suffix.lower() != ".json":
        fail("--project is not a safe project JSON path")
    source = Path(args.source).resolve()
    workspace = Path(args.workspace).resolve()
    output = Path(args.output).resolve()
    if not source.is_dir():
        fail(f"source directory is missing: {source}")
    if output == workspace or workspace not in output.parents:
        fail("--output must be inside --workspace")
    if output.exists():
        fail(f"output already exists: {output}")
    if output == source or source in output.parents or output in source.parents:
        fail("source and output must not overlap")
    workspace.mkdir(parents=True, exist_ok=True)
    project_source = source / project_rel
    if not project_source.is_file():
        fail(f"project file is missing: {project_source}")
    source_project_sha = sha256_file(project_source)

    receipt = ensure_sdk(args)
    stage = workspace / (".gdevelop-export-" + uuid.uuid4().hex)
    stage.mkdir(parents=True)
    publish_tmp = output.parent / (".gdevelop-publish-" + uuid.uuid4().hex)
    log_path = workspace / "gdevelop-export.log"
    try:
        copy_source(source, stage / "source")
        project_copy = stage / "source" / project_rel
        build = project_copy.parent / "build"
        if build.exists():
            shutil.rmtree(build)
        executable = Path(args.sdk_root).resolve() / receipt["executableRelativePath"]
        command = [str(executable), "--no-sandbox", "--disable-update-check",
                   "--run-command", "EXPORT_HTML5_EXTERNAL", str(project_copy)]
        if args.platform == "linuxX86_64":
            if not shutil.which("xvfb-run"):
                fail("xvfb-run is required for the official GDevelop CLI on headless Linux")
            command = ["xvfb-run", "-a", "--server-args=-screen 0 1280x800x24", *command]
        result = subprocess.run(command, capture_output=True, text=True, timeout=600,
                                cwd=str(stage / "source"))
        with open(log_path, "w", encoding="utf-8") as stream:
            stream.write("command: " + " ".join(command) + "\n")
            stream.write("exit: " + str(result.returncode) + "\n")
            stream.write(result.stdout or "")
            stream.write(result.stderr or "")
        if result.returncode != 0:
            fail(f"official GDevelop export failed; see {log_path}")
        verify_build(build)
        normalize_data_js(build)
        stage_text = str(stage)
        for output_file in build.rglob("*"):
            if output_file.is_file() and stage_text.encode() in output_file.read_bytes():
                fail(f"staging path leaked into export: {output_file}")
        verify_build(build)

        inputs_source = project_copy.parent / args.inputs
        inputs = None
        if inputs_source.is_file():
            inputs = {
                "path": args.inputs,
                "sha256": sha256_file(inputs_source),
                "value": read_json(inputs_source),
            }
            shutil.copy2(inputs_source, build / args.inputs)

        # Retain dependency notices in every Floe-produced Web export. Do not
        # replace the original GDevelop notice or change runtime source bytes.
        notices = Path(__file__).with_name("gdevelop-third-party-notices.txt")
        if not notices.is_file():
            fail("reviewed runtime dependency notices are missing")
        license_folder = build / "licenses"
        license_folder.mkdir(exist_ok=True)
        shutil.copy2(notices, license_folder / "GDevelop-runtime-third-party.txt")

        files, total = manifest_files(build)
        digest = canonical_digest(files)
        publish_tmp.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(build, publish_tmp)
        os.replace(publish_tmp, output)
        if sha256_file(project_source) != source_project_sha:
            fail("source project changed during export")
        manifest = {
            "schemaVersion": 1,
            "engine": "gdevelop",
            "sdk": {
                "version": receipt["version"],
                "platform": receipt["platform"],
                "assetName": receipt["assetName"],
                "assetSHA256": receipt["assetSHA256"],
                "sourceTag": args.source_tag,
                "sourceCommit": args.source_commit,
                "license": "MIT",
            },
            "source": {
                "projectPath": project_rel.as_posix(),
                "projectSHA256": source_project_sha,
            },
            "inputs": inputs,
            "output": {
                "entry": "index.html",
                "directory": str(output),
                "files": files,
                "totalBytes": total,
                "digest": digest,
            },
            "command": "official GDevelop CLI --run-command EXPORT_HTML5_EXTERNAL",
            "normalization": {"latestCompilationDirectory": "cleared"},
            "recipeSHA256": sha256_file(Path(__file__).resolve()),
            "log": str(log_path),
        }
        manifest_path = workspace / "gdevelop-export-manifest.json"
        write_json_atomic(manifest_path, manifest)
        print(json.dumps(manifest, indent=2, sort_keys=True))
    finally:
        shutil.rmtree(stage, ignore_errors=True)
        shutil.rmtree(publish_tmp, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk-root", required=True)
    parser.add_argument("--sdk-zip")
    parser.add_argument("--sdk-version", required=True)
    parser.add_argument("--sdk-sha256", required=True)
    parser.add_argument("--source-tag", default="v5.6.287")
    parser.add_argument("--source-commit", default="cfaccd2c20bba2b43fea529523042249c90b9a41")
    parser.add_argument("--platform", choices=sorted(PLATFORMS), required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--inputs", default="floe-inputs.json")
    args = parser.parse_args()
    run_export(args)


if __name__ == "__main__":
    main()
