#!/usr/bin/env python3
"""Validate the one-off, explicitly waived Build191 recovery (never general qualification)."""
import argparse
import json
from pathlib import Path

SOURCE = "715cbc42e9402cf5ca691291fed5c201e61cf222"
RUN = 35337960392
TAG = "v1.7.0-beta.48"
REPO = "JiangNanGenius/floe-agent"
ARTIFACTS = {
    "device": (10544612762, "accepted-sdk-device-recovery-1.7.0-build191", "d73db7af1378b9773c76ddf14c51c56a4a53b602e8c2f46fe0c5b261fe02d7ff"),
    "regression": (10545243814, "accepted-sdk-app-diagnostics-1.7.0-build191", "cfd9acfb6bc73ab74b6ef00e5f69be4d04b7c83f17b6344baa8a86aef0e69aef"),
}
FAILURES = {
    105577179456: {
        "Require Notes import on the iPhone simulator with the accepted SDK",
        "Require both accepted-SDK Notes device legs to pass",
    },
    105577179457: {
        "Require Notes import on the iPad simulator with the SDK 27",
        "Require Notes import on the iPhone simulator with the SDK 27",
        "Require both SDK 27 Notes device legs to pass",
    },
}
REQUIRED = {
    105577179456: {
        "Rebuild the exact tag with the accepted App Store SDK",
        "Preserve the completed device build before simulator qualification",
        "Retain the device build even if later qualification fails",
        "Build accepted-SDK simulator test hosts once",
        "Verify focused app regressions with the accepted App Store SDK",
        "Preserve accepted-SDK App regression diagnostics",
        "Require Notes import on the iPad simulator with the accepted SDK",
    },
    105577179457: {
        "Run Swift tests when exact-source CI cannot be reused",
        "Qualify environment, package, media and Node release modules",
        "Verify Canvas, PiP, and timeline app regression contracts",
    },
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(run, jobs_data, artifacts_data, acknowledged=False):
    require(acknowledged, "All three recorded UI failures require an explicit waiver")
    require((run["id"], run["head_sha"], run["head_branch"], run["run_attempt"]) ==
            (RUN, SOURCE, TAG, 1), "Wrong immutable source, tag, run or attempt")
    require(run["head_repository"]["full_name"] == REPO, "Foreign source repository")
    require(run["event"] == "push" and run["path"] == ".github/workflows/release-unsigned-ipa.yml",
            "Unexpected source workflow")
    require(run["status"] == "completed" and run["conclusion"] == "failure", "Unexpected run state")
    jobs = jobs_data["jobs"]
    require(jobs_data["total_count"] == len(jobs), "Incomplete jobs response")
    require({j["id"] for j in jobs if j["conclusion"] == "failure"} == set(FAILURES),
            "Unexpected failed jobs")
    require(all(j["status"] == "completed" and j["conclusion"] in {"success", "failure", "skipped"}
                for j in jobs), "Incomplete or cancelled jobs")
    for job_id, failures in FAILURES.items():
        matches = [j for j in jobs if j["id"] == job_id]
        require(len(matches) == 1, "Missing or duplicate SDK job")
        steps = matches[0]["steps"]
        require({s["name"] for s in steps if s["conclusion"] == "failure"} == failures,
                "Failure set differs from the reviewed UI waiver")
        require(all(s["conclusion"] in {"success", "failure", "skipped"} for s in steps),
                "Incomplete or cancelled step")
        require(REQUIRED[job_id] <= {s["name"] for s in steps if s["conclusion"] == "success"},
                "Missing mandatory build or regression success")
    for job_id in (105577087053, 105577180017):
        require(len([j for j in jobs if j["id"] == job_id and j["conclusion"] == "success"]) == 1,
                "Preparation or NativeNotes component did not pass")
    artifacts = artifacts_data["artifacts"]
    require(artifacts_data["total_count"] == len(artifacts), "Incomplete artifacts response")
    for artifact_id, name, digest in ARTIFACTS.values():
        matches = [a for a in artifacts if a["name"] == name]
        require(len(matches) == 1, "Missing or duplicate recovery artifact")
        artifact = matches[0]
        require(artifact["id"] == artifact_id and artifact["digest"] == "sha256:" + digest
                and not artifact["expired"], "Artifact identity or integrity mismatch")
        require(artifact["workflow_run"]["id"] == RUN and artifact["workflow_run"]["head_sha"] == SOURCE,
                "Artifact source mismatch")
    return {"sourceRun": RUN, "sourceCommit": SOURCE, "sourceTag": TAG,
            "policy": "explicit_user_waiver_of_three_recorded_UI_failures_internal_TestFlight_only",
            "fullQualificationPassed": False, "waivedFailedSteps": {str(k): sorted(v) for k, v in FAILURES.items()},
            "artifacts": ARTIFACTS}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--acknowledge-three-ui-failures", action="store_true")
    args = parser.parse_args()
    data = [json.loads((args.directory / (name + ".json")).read_text())
            for name in ("reuse-run", "reuse-jobs", "reuse-artifacts")]
    report = verify(*data, acknowledged=args.acknowledge_three_ui_failures)
    (args.directory / "REUSE-PROVENANCE.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
