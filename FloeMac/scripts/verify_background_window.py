#!/usr/bin/env python3
"""Verify the actual debug App's background computer-use tool on a disposable AppKit window."""
import argparse
import json
import os
import plistlib
import signal
import subprocess
import tempfile
import time
from pathlib import Path


def verify(app, report):
    source = Path(__file__).resolve().parents[1] / "Tests/BackgroundWindowFixture.swift"
    with tempfile.TemporaryDirectory(prefix="floe-background-window-", dir="/private/tmp") as directory:
        base = Path(directory)
        fixture = base / "Floe Background Fixture.app"
        contents = fixture / "Contents"
        binary = contents / "MacOS/Fixture"
        binary.parent.mkdir(parents=True)
        info = {"CFBundleIdentifier": "org.floeagent.qa.background-window", "CFBundleName": "Floe Background Fixture",
                "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL", "LSUIElement": True}
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(source), "-o", str(binary)], check=True)
        subprocess.run(["open", "-g", "-n", "-a", str(fixture), "--args", str(base)], check=True)
        state_file = base / "state.json"
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if state_file.exists() and json.loads(state_file.read_bytes())["window"] > 0:
                    break
                time.sleep(.1)
            state = json.loads(state_file.read_bytes())
            assert state["window"] > 0 and not state["becameFrontmost"], state
            smoke = base / "report.json"
            subprocess.run([str(app / "Contents/MacOS/Floe Agent"), "--unified-smoke-report", str(smoke),
                            "--background-window-fixture", str(state["pid"]), str(state["window"])], timeout=90, check=True)
            result = json.loads(smoke.read_bytes())
            state = json.loads(state_file.read_bytes())
            result["targetConfirmed"] = state["clicked"] == 1 and state["value"] == "Floe background edit"
            result["targetStayedInBackground"] = not state["becameFrontmost"]
            print(json.dumps(result))
            if report:
                report.write_text(json.dumps(result, indent=2) + "\n")
            for key in ["fieldVerified", "clickDelivered", "imageVerified", "foregroundPreserved", "targetConfirmed", "targetStayedInBackground"]:
                assert result.get(key) is True, key
        finally:
            # Stop only this launch, including when it failed before writing its state.
            active = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
            for row in active.splitlines():
                fields = row.strip().split(maxsplit=1)
                if len(fields) == 2 and fields[1] == f"{binary} {base}":
                    try:
                        os.kill(int(fields[0]), signal.SIGTERM)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    verify(args.app.resolve(), args.report)
