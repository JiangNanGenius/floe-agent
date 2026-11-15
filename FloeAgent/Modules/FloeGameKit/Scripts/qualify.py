#!/usr/bin/env python3
"""Qualify this independent component with explicit resources, caches and evidence.

Runs host tests (including a real AppKit/WebKit game), CLI fixtures and iOS object
compilation. Does not boot a Simulator, build the App, sign or distribute anything.
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("cache-root", "evidence-root", "resources"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--developer-dir", default="/Applications/Xcode.app/Contents/Developer")
    args = parser.parse_args()
    if not all(p.is_absolute() for p in (args.cache_root, args.evidence_root, args.resources)):
        parser.error("Use explicit absolute paths")
    if args.evidence_root.exists():
        parser.error("Use a fresh evidence directory; prior evidence is preserved")
    package = Path(__file__).resolve().parents[1]
    args.evidence_root.mkdir(parents=True)
    env = dict(os.environ, DEVELOPER_DIR=args.developer_dir)
    sources = sorted(p for p in package.rglob("*") if p.is_file() and p.suffix in (".swift", ".py"))
    source_hashes = {str(p.relative_to(package)): digest(p) for p in sources}
    record = {"version": 1, "qualifiedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "sourceSHA256": source_hashes, "commands": [], "result": "running", "simulatorBooted": False}
    record_file = args.evidence_root / "qualification.json"

    def save():
        record_file.write_text(json.dumps(record, indent=2) + "\n")

    def run(name, command, timeout=240):
        print("Running " + name, flush=True)
        start = time.monotonic()
        log = args.evidence_root / (name + ".log")
        with log.open("w") as output:
            result = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
        record["commands"].append({"name": name, "command": command, "exitCode": result.returncode,
            "elapsedSeconds": round(time.monotonic() - start, 3), "log": log.name})
        save()
        if result.returncode:
            print(log.read_text()[-18000:], flush=True)
            raise RuntimeError(name + " failed")
        return log.read_text()

    try:
        run("resource-check", ["python3", str(package / "Scripts/prepare_phaser.py"), "--output", str(args.resources), "--check"])
        mac_sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip()
        common = ["--build-system", "native", "--package-path", str(package), "--scratch-path", str(args.cache_root / "macos"), "--sdk", mac_sdk]
        binary_root = Path(subprocess.check_output(["xcrun", "swift", "build", *common, "--show-bin-path"], env=env, text=True).strip().splitlines()[-1])
        env.update(FLOE_GAME_TEST_RESOURCES=str(args.resources), FLOE_GAME_TEST_EVIDENCE=str(args.evidence_root / "runtime"),
                   FLOE_GAME_QUALIFICATION_BINARY=str(binary_root / "floe-game-runtime-qualification"))
        tests = run("tests", ["xcrun", "swift", "test", *common, "--jobs", "6"])
        summary = re.search(r"Test run with (\d+) tests in 0 suites passed", tests)
        xctest = re.findall(r"Executed (\d+) tests, with 0 failures", tests)
        assert summary and xctest
        functions = int(summary.group(1))
        parameters = [int(n) for n in re.findall(r"with (\d+) test cases passed", tests)]
        record["testFunctions"] = functions + int(xctest[-1])
        record["testCases"] = functions - len(parameters) + sum(parameters) + int(xctest[-1])
        runtime = json.loads((args.evidence_root / "runtime/runtime-result.json").read_text())
        assert runtime["result"] == "passed" and runtime["nativeHost"] is True
        record["runtime"] = runtime
        demo = run("metadata-demo", [str(binary_root / "floe-game-preflight"), "--demo"])
        samples = json.loads(demo); assert len(samples) == 11 and all(not s["engineExecuted"] for s in samples)
        record["metadataSamples"] = len(samples)
        ios_sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], env=env, text=True).strip()
        run("ios-objects", ["xcrun", "swift", "build", "--build-system", "native", "--package-path", str(package),
            "--scratch-path", str(args.cache_root / "ios-simulator"), "--sdk", ios_sdk,
            "--triple", "arm64-apple-ios26.0-simulator", "--target", "FloeGameWebKit", "--jobs", "6"])
        objects = sorted(p for p in (args.cache_root / "ios-simulator").rglob("*.o")
                         if p.parent.name in ("FloeGameCore.build", "FloeGameWebKit.build"))
        assert len(objects) >= 13
        retained = args.evidence_root / "compiled"; retained.mkdir()
        record["iosObjects"] = []
        for obj in objects:
            inspection = subprocess.check_output(["xcrun", "vtool", "-show-build", str(obj)], env=env, text=True)
            assert "IOSSIMULATOR" in inspection and "minos 26.0" in inspection
            shutil.copy2(obj, retained / obj.name)
            record["iosObjects"].append({"name": obj.name, "sha256": digest(obj), "platform": inspection})
        for name in ("floe-game-preflight", "floe-game-runtime-qualification"):
            shutil.copy2(binary_root / name, retained / name)
        assert source_hashes == {str(p.relative_to(package)): digest(p) for p in sources}, "Source changed during qualification"
        record["result"] = "passed"
        save()
        print(json.dumps({"result": "passed", "functions": record["testFunctions"], "cases": record["testCases"],
            "iosObjects": len(objects), "evidence": str(args.evidence_root)}), flush=True)
    except Exception as error:
        record["result"] = "failed"; record["error"] = str(error); save()
        raise


if __name__ == "__main__":
    main()
