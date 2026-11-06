#!/usr/bin/env python3
"""Compile only this package for an iOS target. Never boots or modifies devices."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--cache-root", required=True, type=Path)
parser.add_argument("--evidence-root", required=True, type=Path)
parser.add_argument("--developer-dir", default="/Applications/Xcode-27.1.app/Contents/Developer")
parser.add_argument("--platform", choices=["iphoneos", "iphonesimulator"], default="iphoneos")
parser.add_argument("--jobs", type=int, default=6)
args = parser.parse_args()
if not args.cache_root.is_absolute() or not args.evidence_root.is_absolute() or args.jobs < 1:
    parser.error("Explicit absolute cache/evidence paths and positive jobs are required.")
package = Path(__file__).resolve().parents[1]
cache = args.cache_root / args.platform
evidence = args.evidence_root
evidence.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env["DEVELOPER_DIR"] = args.developer_dir
sdk = subprocess.check_output(["xcrun", "--sdk", args.platform, "--show-sdk-path"], env=env, text=True).strip()
triple = "arm64-apple-ios26.0" + ("-simulator" if args.platform == "iphonesimulator" else "")
command = [
    "swift", "build", "--build-system", "native", "--package-path", str(package),
    "--scratch-path", str(cache), "--sdk", sdk, "--triple", triple,
    "--target", "FloeInteractiveContentWebKit", "--jobs", str(args.jobs)
]
files = sorted(p for p in (package / "Sources").rglob("*") if p.is_file())
manifest = {str(p.relative_to(package)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
record = {"command": command, "developer_dir": args.developer_dir, "sdk": sdk, "triple": triple,
          "source_sha256": manifest, "result": "running", "simulator_booted": False}
record_path = evidence / (args.platform + "-compile.json")
record_path.write_text(json.dumps(record, indent=2) + "\n")
print(shlex.join(command), flush=True)
log = evidence / (args.platform + "-compile.log")
with log.open("w") as output:
    result = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT)
record["exit_code"] = result.returncode
record["result"] = "passed" if result.returncode == 0 else "failed"
if result.returncode == 0:
    objects = sorted(p for p in cache.rglob("*.o") if
                     "FloeInteractiveContentCore.build" in str(p) or "FloeInteractiveContentWebKit.build" in str(p))
    record["objects"] = [{"path": str(p), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in objects]
    inspections = []
    for p in objects:
        inspected = subprocess.run(["xcrun", "vtool", "-show-build", str(p)], env=env, capture_output=True, text=True)
        inspections.append({"object": str(p), "exit_code": inspected.returncode, "output": inspected.stdout})
    record["platform_inspection"] = inspections
    if not objects or any(item["exit_code"] != 0 or "minos 26.0" not in item["output"] for item in inspections):
        record["result"] = "inspection_failed"
        result.returncode = 1
record_path.write_text(json.dumps(record, indent=2) + "\n")
print(json.dumps({"result": record["result"], "record": str(record_path), "log": str(log)}), flush=True)
if result.returncode:
    print(log.read_text()[-16000:], file=sys.stderr)
sys.exit(result.returncode)
