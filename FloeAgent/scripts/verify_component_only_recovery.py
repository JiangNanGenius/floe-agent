#!/usr/bin/env python3
"""Reuse a tagged App only after a reviewed, test-only component correction.

This narrowly recognizes the build187 FIFO fixture correction. It cannot bless
product edits, a different assertion change, a failed SDK job, or skipped tests.
Original failures and the replacement qualification retain separate source IDs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

REPOSITORY = "JiangNanGenius/floe-agent"
APP_SOURCE = "d77aa11f7b4933b987faf5cf65ebc817d520e15e"
COMPONENT_SOURCE = "920132dcc88b448a5877fca3d61ea911afb69566"
TEST_PATH = "FloeAgent/Qualification/NativeNotes/Tests/NotesProgressiveCoverTests.swift"
ORIGINAL_TEST_HASH = "b38920a382cebb13fa2b6b6fe3a1e8dda6bfda03388a29d84c8ffaeab810065a"
REPAIRED_TEST_HASH = "5ae9deb7f7305d40a02577621b05ec3c25d2bc0b3ca46dcd4ea5f8ce98055e61"
FAILURE_ID = "NotesProgressiveCoverTests/testSummaryGateBoundsCopiesAndReleasesBeforeTheQuickLookWait()"
FAILURE_TEXT = ('XCTAssertEqual failed: ("2") is not equal to ("1") - only the Quick Look copy may exist: '
                'the summary copy is deleted before the wait')
SDK_JOBS = ("build-verify-release", "Qualify and build the accepted SDK in parallel")
SOURCE_COMPONENT = "Qualify the NativeNotes development component in parallel / development"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def job(jobs, name, conclusion):
    found = [j for j in jobs["jobs"] if j["name"] == name]
    require(len(found) == 1, f"missing/ambiguous job: {name}")
    value = found[0]
    require(value["status"] == "completed" and value["conclusion"] == conclusion,
            f"job did not finish as {conclusion}: {name}")
    return value["id"]


def check_run(run, sha, path, event, conclusion):
    require(re.fullmatch(r"[0-9a-f]{40}", sha), "invalid source SHA")
    require(run["head_repository"]["full_name"] == REPOSITORY, "foreign repository")
    require(run["head_sha"] == sha and run["path"] == path and run["event"] == event,
            "run source/workflow/event mismatch")
    require(run["status"] == "completed" and run["conclusion"] == conclusion,
            "run has not reached the required terminal result")


def check_summary(summary, original):
    require(summary["totalTestCount"] == 101, "component coverage count changed")
    require(summary["skippedTests"] == 0 and summary["expectedFailures"] == 0,
            "component has skipped/expected failures")
    require(not summary["runtimeWarnings"], "component runtime warnings")
    if original:
        require(summary["result"] == "Failed" and summary["passedTests"] == 100
                and summary["failedTests"] == 1, "original failure is not the reviewed single case")
        failures = summary["testFailures"]
        require(len(failures) == 1 and failures[0]["testIdentifierString"] == FAILURE_ID
                and failures[0]["failureText"] == FAILURE_TEXT, "unreviewed original failure")
    else:
        require(summary["result"] == "Passed" and summary["passedTests"] == 101
                and summary["failedTests"] == 0 and not summary["testFailures"],
                "replacement component did not fully pass")


def check_diff(paths, original_hash, repaired_hash):
    require(original_hash == ORIGINAL_TEST_HASH and repaired_hash == REPAIRED_TEST_HASH,
            "fixture differs from the reviewed correction")
    require(TEST_PATH in paths, "missing fixture correction")
    for path in paths:
        require(path == TEST_PATH or path.startswith("docs/")
                or path in {"README.md", "README.zh-CN.md", "FloeAgent/README.md"},
                f"build-affecting or unreviewed change: {path}")


def verify(source, component, source_jobs, component_jobs, summaries,
           tag, source_sha, component_sha, paths, original_hash, repaired_hash):
    require((tag, source_sha, component_sha) == ("v1.7.0-beta.44", APP_SOURCE, COMPONENT_SOURCE),
            "unreviewed release/component pair")
    check_run(source, source_sha, ".github/workflows/release-unsigned-ipa.yml", "push", "failure")
    require(source["head_branch"] == tag, "source run is not the immutable tag push")
    check_run(component, component_sha, ".github/workflows/notes-native-qualification.yml",
              "workflow_dispatch", "success")
    source_ids = [job(source_jobs, name, "success") for name in SDK_JOBS]
    original_component_id = job(source_jobs, SOURCE_COMPONENT, "failure")
    job(source_jobs, "Archive and upload the same commit to TestFlight", "skipped")
    replacement_id = job(component_jobs, "development", "success")
    job(component_jobs, "compatibility", "skipped")
    check_diff(paths, original_hash, repaired_hash)
    for family in ("iPad", "iPhone"):
        check_summary(summaries[f"original-{family}"], True)
        check_summary(summaries[f"replacement-{family}"], False)
    return {"qualificationMode": "all_gates_with_test_only_component_repair",
            "sourceRun": source["id"], "sourceCommit": source_sha, "sourceTag": tag,
            "sdkJobIDs": source_ids, "originalComponentJobID": original_component_id,
            "componentRun": component["id"], "componentSource": component_sha,
            "componentJobID": replacement_id, "originalFixtureSHA256": original_hash,
            "repairedFixtureSHA256": repaired_hash, "changedPaths": sorted(paths),
            "componentResults": "original100/101 per device; corrected101/101 per device",
            "policy": "Both original SDK jobs passed. Only the reviewed test fixture and documentation changed; App code/resources/settings/dependencies are identical. Original failure remains recorded. No qualification waiver or device rebuild."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--component-sha", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    def git(*parts):
        return subprocess.check_output(["git", "-C", str(args.repository), *parts])
    for sha in (args.source_sha, args.component_sha):
        require(re.fullmatch(r"[0-9a-f]{40}", sha), "invalid SHA")
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:[.-][A-Za-z0-9._-]+)?", args.tag), "invalid tag")
    require(git("rev-parse", f"refs/tags/{args.tag}^{{commit}}").decode().strip() == args.source_sha,
            "tag moved or does not match source")
    paths = git("diff", "--name-only", "-z", args.source_sha, args.component_sha).decode().strip("\0").split("\0")
    read = lambda name: json.loads((args.evidence / f"{name}.json").read_text())
    summaries = {f"{kind}-{family}": read(f"{kind}-{family}")
                 for kind in ("original", "replacement") for family in ("iPad", "iPhone")}
    report = verify(read("source-run"), read("component-run"), read("source-jobs"), read("component-jobs"),
                    summaries, args.tag, args.source_sha, args.component_sha, paths,
                    hashlib.sha256(git("show", f"{args.source_sha}:{TEST_PATH}")).hexdigest(),
                    hashlib.sha256(git("show", f"{args.component_sha}:{TEST_PATH}")).hexdigest())
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print("All recovery guards passed; device application remains from the original immutable tag.")


if __name__ == "__main__":
    main()
