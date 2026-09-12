#!/usr/bin/env python3
"""Run release tests with retained output and bounded stall diagnostics."""
import argparse
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def sample_children(parent, destination):
    if sys.platform != "darwin":
        return
    try:
        rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,comm="], text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return
    processes = [line.strip().split(None, 2) for line in rows.splitlines()]
    owned = {parent}
    while True:
        found = {int(row[0]) for row in processes if len(row) == 3 and int(row[1]) in owned}
        if found <= owned:
            break
        owned |= found
    sampled = 0
    for row in processes:
        if len(row) != 3 or int(row[0]) not in owned:
            continue
        if "swiftpm-testing" not in row[2] and "PackageTests" not in row[2]:
            continue
        if sampled == 4:
            break
        sampled += 1
        try:
            subprocess.run(
                ["sample", row[0], "3", "-file", str(destination / f"sample-{row[0]}.txt")],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10,
            )
        except (OSError, subprocess.TimeoutExpired):
            pass  # A test may exit while the process list is being sampled.


def stop_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    # The driver can exit before a blocked test child; clean up that same group.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=900)
    parser.add_argument("--stall-timeout", type=float, default=180)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or any(not math.isfinite(v) or v <= 0 for v in [args.timeout, args.stall_timeout]):
        parser.error("a command and positive finite time limits are required")
    args.output_dir.mkdir(parents=True, exist_ok=False)
    path = args.output_dir / "tests.log"
    start = last_output = time.monotonic()
    seen_tests = execution_ready = sampled = False
    previous = b""
    reason = "exited"
    with path.open("wb") as log, path.open("rb") as reader:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while True:
                data = reader.read()
                if data:
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                    seen_tests |= b"Test run started" in previous + data
                    execution_ready |= seen_tests or b"Build complete!" in previous + data
                    previous = data[-128:]
                    last_output = time.monotonic()
                if process.poll() is not None:
                    # Read any final bytes produced between the first read and exit.
                    sys.stdout.buffer.write(reader.read())
                    sys.stdout.buffer.flush()
                    break
                now = time.monotonic()
                if execution_ready and not sampled and now - last_output >= args.stall_timeout / 2:
                    print("\nTest output stalled; capturing owned test processes.", flush=True)
                    sample_children(process.pid, args.output_dir)
                    sampled = True
                if now - start >= args.timeout or (execution_ready and now - last_output >= args.stall_timeout):
                    reason = "timeout" if now - start >= args.timeout else "stalled"
                    stop_group(process)
                    sys.stdout.buffer.write(reader.read())
                    break
                time.sleep(0.25)
        finally:
            if process.poll() is None:
                stop_group(process)
    code = 124 if reason != "exited" else process.returncode
    code = 128 - code if code < 0 else code
    summary = {"exitCode": code, "reason": reason, "elapsedSeconds": round(time.monotonic() - start, 3), "testsStarted": seen_tests}
    (args.output_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary), flush=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
