#!/usr/bin/env python3
"""Optional integration check against a retained real Bridge artifact.

This is intentionally not part of the hermetic unittest discovery.  It reads a
retained IPA/app and dSYMs, verifies the real Mach-O/topology boundaries, then
proves that an explicit private re-sign bundle-ID rewrite is accepted by the
signed verifier.  It never signs, installs, boots a simulator or modifies the
retained evidence.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "scripts"))
sys.path.insert(0, str(HERE))
import prepare_signing  # noqa: E402
import verify_bridge  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa")
    parser.add_argument("--app")
    parser.add_argument("--project", required=True)
    parser.add_argument("--expected-version", default="0.1.0")
    parser.add_argument("--expected-build", default="13")
    parser.add_argument("--dsym", action="append", default=[])
    parser.add_argument("--scratch", required=True)
    args = parser.parse_args()
    if not args.ipa and not args.app:
        parser.error("provide --ipa and/or --app")

    project = Path(args.project).resolve()
    identity = verify_bridge.load_project_identity(project)
    identity = verify_bridge.apply_identity_overrides(
        identity, args.expected_version, args.expected_build
    )
    identity = verify_bridge.validate_identity(identity, verify_bridge.QUALIFICATION)
    probe = verify_bridge.SystemMachOProbe()
    report: dict = {"qualification": {}, "dsyms": {}, "customIds": {}, "releaseNegative": {}}

    scratch = Path(args.scratch).resolve()
    scratch.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="retained-integration-", dir=scratch))
    try:
        if args.ipa:
            result = verify_bridge.check_ipa(
                Path(args.ipa), require_unsigned=True, mode=verify_bridge.QUALIFICATION,
                identity=identity, probe=probe, source_root=project.parent,
                project_yml=project,
            )
            report["qualification"] = {
                "ok": result["ok"],
                "failures": result["failures"],
                "checks": len(result["checks"]),
                "bundleIds": result.get("bundleIds"),
            }
            if not result["ok"]:
                return _finish(report, 1)
            app_result = result["appResult"]
            app = Path(tempfile.mkdtemp(prefix="extracted-", dir=work)) / "BridgeHost.app"
            # Reuse the verifier extraction by extracting the IPA once more.
            import zipfile
            with zipfile.ZipFile(args.ipa) as archive:
                archive.extractall(app.parent)
            app = app.parent / "Payload" / "BridgeHost.app"
        else:
            app = Path(args.app).resolve()
            result = verify_bridge.check_app(
                app, require_unsigned=True, mode=verify_bridge.QUALIFICATION,
                identity=identity, probe=probe, source_root=project.parent,
                project_yml=project,
            )
            report["qualification"] = {
                "ok": result["ok"],
                "failures": result["failures"],
                "checks": len(result["checks"]),
                "bundleIds": result.get("bundleIds"),
            }
            if not result["ok"]:
                return _finish(report, 1)
            app_result = result

        if args.dsym:
            dsym_result = verify_bridge.check_dsyms(
                app_result, [Path(item) for item in args.dsym],
                mode=verify_bridge.QUALIFICATION, probe=probe,
            )
            report["dsyms"] = {
                "ok": dsym_result["ok"],
                "failures": dsym_result["failures"],
                "uuids": dsym_result["uuids"],
            }
            if not dsym_result["ok"]:
                return _finish(report, 1)

        custom_ids = verify_bridge.derive_bundle_ids("com.example.floe.bridge")
        mutable_app = work / "custom" / "BridgeHost.app"
        shutil.copytree(app, mutable_app, symlinks=True)
        prepare_signing.apply_bundle_ids(mutable_app, custom_ids)
        custom_result = verify_bridge.check_app(
            mutable_app, require_unsigned=False, mode=verify_bridge.QUALIFICATION,
            identity=identity, bundle_ids=custom_ids, probe=probe,
            source_root=project.parent, project_yml=project,
        )
        report["customIds"] = {
            "ok": custom_result["ok"],
            "failures": custom_result["failures"],
            "bundleIds": custom_result["bundleIds"],
            "metadataMode": custom_result.get("metadataMode"),
            "checks": len(custom_result["checks"]),
        }
        if not custom_result["ok"]:
            return _finish(report, 1)

        release_identity = verify_bridge.BuildIdentity(
            "1.0.0", "14", "integration-negative",
            {role: {"marketingVersion": "1.0.0", "buildNumber": "14"}
             for role in ("host", "appex", "core", "test")},
        )
        release_result = verify_bridge.check_app(
            app, require_unsigned=True, mode=verify_bridge.RELEASE,
            identity=release_identity, bundle_ids=verify_bridge.canonical_bundle_ids(),
            probe=probe, source_root=project.parent, project_yml=project,
        )
        report["releaseNegative"] = {
            "ok": not release_result["ok"],
            "failures": release_result["failures"],
        }
        if release_result["ok"]:
            return _finish(report, 1)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return _finish(report, 0)


def _finish(report: dict, code: int) -> int:
    print(json.dumps(report, indent=2, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
