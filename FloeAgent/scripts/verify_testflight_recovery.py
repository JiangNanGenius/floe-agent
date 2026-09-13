#!/usr/bin/env python3
"""Require successful exact-source build/tests before a distribution-only retry."""
import argparse
import json
from pathlib import Path
import re


def verify(run, jobs, repository, source):
    if (run.get("head_sha") != source or run.get("head_repository", {}).get("full_name") != repository
            or run.get("path", "").split("@")[0] != ".github/workflows/release-unsigned-ipa.yml"
            or run.get("event") not in ("push", "workflow_dispatch")
            or run.get("conclusion") != "failure"):
        raise ValueError("Recovery run does not identify the trusted failed release of this exact source")
    first = [j for j in jobs["jobs"] if j["name"] == "build-verify-release"]
    second = [j for j in jobs["jobs"] if j["name"] == "Archive and upload the same commit to TestFlight"]
    if len(first) != 1 or len(second) != 1 or first[0]["conclusion"] != "success" or second[0]["conclusion"] != "failure":
        raise ValueError("Both qualification jobs must have the expected terminal results")
    steps = {s["name"]: s.get("conclusion") for s in second[0]["steps"]}
    for name in ("Require the App Store accepted Xcode toolchain", "Validate the exact verified application",
                 "Rebuild the exact tag with the accepted App Store SDK",
                 "Verify focused app regressions with the accepted App Store SDK"):
        if steps.get(name) != "success":
            raise ValueError(f"Required accepted-SDK qualification did not pass: {name}")
    if steps.get("Sign, verify, package, and upload to TestFlight") != "failure":
        raise ValueError("Do not retry a successful upload or an unrelated failure")
    return {"qualified_run": run["id"], "source": source, "sdk27_job": first[0]["id"],
            "accepted_sdk_job": second[0]["id"], "accepted_sdk": "Xcode 26.6 (17F113)",
            "qualification": "successful build and test steps reused; prior failure was distribution"}


def test_summary(log):
    matches = re.findall(r"canvas-pip-timeline-app-regression-summary total=(\d+) passed=(\d+) failed=(\d+) skipped=(\d+) expectedFailures=(\d+) result=(\w+)", log)
    if len(matches) != 1:
        raise ValueError("Expected exactly one actual App regression summary in the trusted job log")
    total, passed, failed, skipped, expected, result = matches[0]
    if int(total) < 135 or total != passed or (failed, skipped, expected, result) != ("0", "0", "0", "Passed"):
        raise ValueError("Accepted-SDK App regressions were incomplete or unsuccessful")
    return {"total": int(total), "passed": int(passed), "failed": 0, "skipped": 0, "result": result}


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--run", required=True)
    p.add_argument("--jobs", required=True)
    p.add_argument("--repository", required=True)
    p.add_argument("--source", required=True)
    p.add_argument("--report", required=True)
    args = p.parse_args()
    result = verify(json.loads(Path(args.run).read_text()), json.loads(Path(args.jobs).read_text()), args.repository, args.source)
    Path(args.report).write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
