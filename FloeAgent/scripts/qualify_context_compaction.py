#!/usr/bin/env python3
"""Focused qualification for Floe context compaction and tool-result retention.

This runner builds ONLY the FloeAgentRuntimeTests SwiftPM target and executes
the resulting test bundle with `xcrun xctest`. It never builds the App, boots a
Simulator, touches a device, calls a model provider or publishes anything.

The selected suites cover:
  * 64K and 128K runtime -> provider-request observations: complete settled
    tool results and whole JSON Schemas when the real window has room;
  * a 1 MiB captured result: byte-exact durable retention, UTF-8 boundary
    paging, stable ref, tail recovery after a real checkpoint/resume;
  * over-budget compaction through the real context engine: observed record,
    trusted system contract vs historical user transcript, current intent and
    pending tool-call/result pairing;
  * the trusted summary contract's language and instruction-separation guards.

Usage (from anywhere):
    python3 FloeAgent/scripts/qualify_context_compaction.py
    python3 FloeAgent/scripts/qualify_context_compaction.py --skip-build
    python3 FloeAgent/scripts/qualify_context_compaction.py --jobs 6

Exit status is 0 only when the bundle reports a passing run that contains
every expected acceptance scenario. The JSON receipt is written next to this
job's private evidence directory; no tracked file is modified.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
EXPECTED_TESTS = (
    "64K: complete settled tool result and whole schemas reach the request",
    "128K: complete settled tool result and whole schemas reach the request",
    "128K: 1 MiB result stays byte-exact and pages its tail after resume",
    "64K and 128K: real compaction retains intent, roles and pending pairing",
    "A clear continuation-language drift is rejected",
    "A record that copies the trusted instructions into Goal/Instructions is rejected",
)
CONTRACT_TESTS = (
    "Prompt targets the latest user language and forbids meta-instruction leakage",
    "A valid record in the transcript language is accepted",
    "Structural and exact-reference integrity still gate the record",
    "A matching Chinese continuation record is accepted",
)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def sha256_file(path: Path) -> str | None:
    try:
        import hashlib

        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return None


def git_value(root: Path, *args: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=root,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def toolchain_version(developer_dir: str) -> dict:
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = developer_dir
    payload: dict = {"developerDir": developer_dir}
    for key, command in (
        ("xcodebuild", ["xcodebuild", "-version"]),
        ("swift", ["swift", "--version"]),
    ):
        try:
            result = subprocess.run(
                command,
                cwd="/",
                env=env,
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
            payload[key] = {
                "exit": result.returncode,
                "output": (result.stdout or result.stderr).strip().splitlines()[:4],
            }
        except (OSError, subprocess.TimeoutExpired) as error:
            payload[key] = {"exit": None, "error": str(error)}
    return payload


def run(command: list[str], *, cwd: Path, env: dict, timeout: int, log_path: Path) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as log:
        log.write("$ " + " ".join(command) + "\n\n")
        log.flush()
        started = time.monotonic()
        process = subprocess.Popen(
            command,
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            log.write(line)
            log.flush()
        code = process.wait(timeout=timeout)
        log.write(f"\n[exit {code} after {time.monotonic() - started:.1f}s]\n")
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument(
        "--scratch",
        default=str(
            Path.home()
            / "Library/Caches/CodexBuild/Floe/ios-pencil-live-20261019/context-acceptance"
        ),
    )
    parser.add_argument("--jobs", type=int, default=6)
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument(
        "--receipt",
        default=None,
        help="Receipt path (default: this job's private qualification/latest.json)",
    )
    args = parser.parse_args()

    root = repo_root()
    package = root / "FloeAgent"
    scratch = Path(args.scratch).expanduser()
    evidence = (
        root
        / "Local/Private/cad106-native-closure-20261031/context-acceptance"
    )
    receipt_path = (
        Path(args.receipt).expanduser()
        if args.receipt
        else evidence / "qualification/latest.json"
    )
    logs = evidence / "evidence"
    date_stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    developer_dir = os.environ.get("DEVELOPER_DIR", DEFAULT_DEVELOPER_DIR)
    if not Path(developer_dir).is_dir():
        print(f"error: DEVELOPER_DIR does not exist: {developer_dir}", file=sys.stderr)
        return 2
    trace_dir = evidence / "traces" / date_stamp
    env = {
        "HOME": str(Path.home()),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "DEVELOPER_DIR": developer_dir,
        "LANG": "en_US.UTF-8",
        # The acceptance tests export only asserted counts/booleans (no
        # content or credentials) when this opt-in is present.
        "FLOE_CONTEXT_TRACE_DIR": str(trace_dir),
    }

    receipt: dict = {
        "job": "job-fbf2f0fcb9e041d5",
        "startedAt": date_stamp,
        "source": {
            "head": git_value(root, "rev-parse", "HEAD"),
            "branch": git_value(root, "rev-parse", "--abbrev-ref", "HEAD"),
            "dirtyPaths": [],
            "contextEngineBaseSHA256": sha256_file(
                package / "Sources/FloeAgentRuntime/ContextEngine.swift"
            ),
            "agentRuntimeSHA256": sha256_file(
                package / "Sources/FloeAgentRuntime/AgentRuntime.swift"
            ),
            "contextPolicySHA256": sha256_file(
                package / "Sources/FloeAgentRuntime/ContextManagementPolicy.swift"
            ),
            "acceptanceTestsSHA256": sha256_file(
                package / "Tests/FloeAgentRuntimeTests/ContextCompactionAcceptanceTests.swift"
            ),
            "contextEngineOverlay": {
                "path": "Local/Private/cad106-native-closure-20261031/context-acceptance/overlays/ContextEngine.swift.patch",
                "sha256": sha256_file(
                    evidence / "overlays/ContextEngine.swift.patch"
                ),
                "appliedToLiveFile": False,
                "note": "ContextEngine.swift is root-owned; the private overlay is integrated by the primary after review.",
            },
        },
        "toolchain": toolchain_version(developer_dir),
        "scratch": str(scratch),
        "commands": [],
        "tests": {},
        "outcome": "blocked",
    }
    status = git_value(root, "status", "--porcelain")
    if status:
        receipt["source"]["dirtyPaths"] = status.splitlines()

    if not args.skip_build:
        build_log = logs / f"qualify-build-{date_stamp}.log"
        command = [
            "swift",
            "build",
            "--package-path",
            str(package),
            "--scratch-path",
            str(scratch),
            "--target",
            "FloeAgentRuntimeTests",
            "--jobs",
            str(args.jobs),
            "--force-resolved-versions",
        ]
        print("[1/2] building FloeAgentRuntimeTests (own scratch, jobs=%d)" % args.jobs)
        build_started = time.monotonic()
        build_exit = run(
            command,
            cwd=root,
            env=env,
            timeout=args.timeout,
            log_path=build_log,
        )
        receipt["commands"].append(
            {
                "name": "swift build",
                "argv": command,
                "exit": build_exit,
                "seconds": round(time.monotonic() - build_started, 1),
                "log": str(build_log.relative_to(root)),
            }
        )
        if build_exit != 0:
            receipt["tests"] = {"buildExit": build_exit}
            receipt_path.parent.mkdir(parents=True, exist_ok=True)
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
            print(f"FAILED: build exit {build_exit}; receipt {receipt_path}", file=sys.stderr)
            return build_exit or 1
    else:
        print("[1/2] build skipped by request")

    bundles = sorted(scratch.glob("out/Products/Debug/FloeAgentRuntimeTests.xctest"))
    if not bundles:
        receipt["tests"] = {"error": "FloeAgentRuntimeTests.xctest not found in scratch"}
        receipt_path.parent.mkdir(parents=True, exist_ok=True)
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
        print("FAILED: test bundle not found; build first or set --scratch", file=sys.stderr)
        return 2
    bundle = bundles[0]

    test_log = logs / f"qualify-runtime-{date_stamp}.log"
    command = ["xcrun", "xctest", str(bundle)]
    print(f"[2/2] running {bundle.name}")
    test_started = time.monotonic()
    test_exit = run(
        command,
        cwd=root,
        env=env,
        timeout=args.timeout,
        log_path=test_log,
    )
    seconds = round(time.monotonic() - test_started, 1)
    text = test_log.read_text(encoding="utf-8", errors="replace")

    summary = None
    for match in re.finditer(
        r"Test run with (\d+) tests in (\d+) suites (passed|failed) after ([0-9.]+) seconds",
        text,
    ):
        summary = {
            "tests": int(match.group(1)),
            "suites": int(match.group(2)),
            "status": match.group(3),
            "seconds": float(match.group(4)),
        }
    failure_markers = [
        line
        for line in text.splitlines()
        if line.lstrip().startswith("\u2718") or line.lstrip().startswith("✘")
    ]
    missing = [name for name in EXPECTED_TESTS if name not in text]
    missing_contract = [name for name in CONTRACT_TESTS if name not in text]
    passed_scenarios = [
        name
        for name in EXPECTED_TESTS
        if re.search(
            r"(?m)^\u2714 Test \"" + re.escape(name) + r"\" passed",
            text,
        )
    ]
    passed_contract = [
        name
        for name in CONTRACT_TESTS
        if re.search(
            r"(?m)^\u2714 Test \"" + re.escape(name) + r"\" passed",
            text,
        )
    ]
    receipt["commands"].append(
        {
            "name": "xcrun xctest",
            "argv": command,
            "exit": test_exit,
            "seconds": seconds,
            "log": str(test_log.relative_to(root)),
        }
    )
    traces = sorted(path.name for path in trace_dir.glob("*.json")) if trace_dir.is_dir() else []
    receipt["tests"] = {
        "summary": summary,
        "traceDirectory": str(trace_dir.relative_to(root)),
        "traces": traces,
        "failureMarkers": len(failure_markers),
        "expectedScenarios": len(EXPECTED_TESTS),
        "expectedScenariosPassed": len(passed_scenarios),
        "missingScenarios": missing,
        "contractScenariosPassed": len(passed_contract),
        "missingContractScenarios": missing_contract,
        "bundle": str(bundle),
    }

    ok = (
        test_exit == 0
        and summary is not None
        and summary["status"] == "passed"
        and not failure_markers
        and not missing
        and not missing_contract
        and len(passed_scenarios) == len(EXPECTED_TESTS)
        and len(passed_contract) == len(CONTRACT_TESTS)
        and len(traces) >= 5
    )
    receipt["outcome"] = "passed" if ok else "failed"
    receipt["finishedAt"] = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")

    if not ok:
        print(
            "FAILED: see %s (missing scenarios: %s; failures: %d)"
            % (test_log, missing + missing_contract, len(failure_markers)),
            file=sys.stderr,
        )
        return test_exit or 1
    print(
        "PASSED: %d tests in %d suites; %d acceptance and %d contract scenarios; receipt %s"
        % (
            summary["tests"],
            summary["suites"],
            len(passed_scenarios),
            len(passed_contract),
            receipt_path,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
