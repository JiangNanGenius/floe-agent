#!/usr/bin/env python3
"""Wait for the selected CI simulator before handing launch to XCTest.

Does not launch the App, erase data, change tests, or retry a failed test.
The original boot output and a machine-readable result are retained even
when preparation fails. Only the caller-selected UUID can be booted.
"""
import argparse
import json
from pathlib import Path
import subprocess
import uuid


def prepare(identifier, output_dir, runner=subprocess.run):
    identifier = str(uuid.UUID(identifier)).upper()
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=False)
    result = {"simulatorID": identifier, "ready": False, "exitCode": None}
    with (output_dir / "boot.log").open("w") as log:
        try:
            completed = runner(["xcrun", "simctl", "bootstatus", identifier, "-b"],
                               stdout=log, stderr=subprocess.STDOUT, timeout=180,
                               check=False)
            result["exitCode"] = completed.returncode
            result["ready"] = completed.returncode == 0
        except subprocess.TimeoutExpired:
            result.update(exitCode=124, error="simulator boot exceeded 180 seconds")
        except OSError as error:
            result.update(exitCode=1, error=str(error))
    (output_dir / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator-id", required=True, type=lambda value: str(uuid.UUID(value)))
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    result = prepare(args.simulator_id, args.output_dir)
    print(json.dumps(result))
    return 0 if result["ready"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
