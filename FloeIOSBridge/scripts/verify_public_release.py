#!/usr/bin/env python3
"""Read-only verification of a Floe iOS Bridge public asset set.

This helper never calls ``gh``, never creates tags/releases, never uploads and
never touches a workflow.  It binds a canonical unsigned IPA and its
``.sha256`` sidecar to:

* the immutable public tag ``floe-ios-bridge-v<version>`` and its commit;
* the exact tracked Bridge source tree at that commit;
* every role/version/topology/linkage boundary in ``verify_bridge --mode
  release``; and, when supplied, a captured GitHub ``releases/latest`` JSON so
  the Bridge release can be proven not to have moved the repository's latest
  pointer (``make_latest=false``).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import package_bridge  # noqa: E402
import verify_bridge  # noqa: E402

TAG_PREFIX = "floe-ios-bridge-v"
MACOS_TAG_PREFIX = "floe-bridge-v"
SEMVER_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def canonical_ipa_name(version: str) -> str:
    return f"{package_bridge.CANONICAL_PREFIX}-{version}-unsigned.ipa"


def check(name: str, ok: bool, detail: str) -> dict:
    return {"name": name, "ok": bool(ok), "detail": detail}


def check_sidecar(ipa: Path, sidecar: Path | None = None) -> list[dict]:
    checks: list[dict] = []
    ipa = Path(ipa)
    sidecar = Path(sidecar) if sidecar else Path(str(ipa) + ".sha256")
    checks.append(check("sidecar-present", sidecar.is_file(), str(sidecar)))
    if not sidecar.is_file():
        return checks
    try:
        fields = sidecar.read_text(encoding="utf-8").split()
    except OSError as error:
        checks.append(check("sidecar-readable", False, str(error)))
        return checks
    checks.append(check("sidecar-two-fields", len(fields) == 2, json.dumps(fields)))
    if len(fields) != 2:
        return checks
    digest, filename = fields
    checks.append(check("sidecar-hash-format", bool(SHA256_RE.fullmatch(digest)), digest))
    checks.append(check("sidecar-filename-matches", filename == ipa.name, filename))
    try:
        actual = package_bridge.sha256(ipa)
    except OSError as error:
        checks.append(check("artifact-readable", False, str(error)))
        return checks
    checks.append(check("sidecar-hash-matches", digest == actual, f"{digest} != {actual}"))
    return checks


def check_tag(
    repo_root: Path,
    tag: str,
    source_ref: str,
    version: str,
    allow_missing: bool = False,
) -> list[dict]:
    checks: list[dict] = []
    expected = TAG_PREFIX + version
    checks.append(check("tag-name-canonical", tag == expected, f"{tag!r} expected {expected!r}"))
    checks.append(check("tag-not-macos-bridge", not tag.startswith(MACOS_TAG_PREFIX), tag))
    try:
        source_commit = verify_bridge.resolve_ref(Path(repo_root), source_ref)
    except verify_bridge.IdentityError as error:
        checks.append(check("source-ref-resolves", False, str(error)))
        return checks
    checks.append(check("source-ref-resolves", True, source_commit))
    result = subprocess.run(
        ["git", "-C", str(repo_root), "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}"],
        text=True, capture_output=True,
    )
    if result.returncode != 0:
        checks.append(check(
            "tag-exists",
            allow_missing,
            "tag does not exist yet" if allow_missing else "tag does not exist",
        ))
        return checks
    tag_object = result.stdout.strip()
    checks.append(check("tag-exists", True, tag_object))
    kind = subprocess.run(
        ["git", "-C", str(repo_root), "cat-file", "-t", tag_object],
        text=True, capture_output=True,
    )
    kind_value = kind.stdout.strip() if kind.returncode == 0 else ""
    checks.append(check("tag-object-kind", kind_value in {"commit", "tag"}, kind_value))
    peeled = subprocess.run(
        ["git", "-C", str(repo_root), "rev-list", "-n", "1", tag_object],
        text=True, capture_output=True,
    )
    tag_commit = peeled.stdout.strip() if peeled.returncode == 0 else ""
    checks.append(check("tag-commit-resolves", bool(re.fullmatch(r"[0-9a-f]{40}", tag_commit)), tag_commit))
    checks.append(check(
        "tag-commit-equals-source-ref",
        tag_commit == source_commit,
        f"{tag_commit} != {source_commit}",
    ))
    return checks


def check_latest(
    latest_json: Path | None,
    bridge_tag: str,
    expect_latest_tag: str | None,
    strict: bool,
) -> list[dict]:
    checks: list[dict] = []
    if latest_json is None:
        checks.append(check(
            "latest-pointer-captured",
            not strict,
            "no --latest-json supplied; latest pointer unchecked" if not strict else "required in strict mode",
        ))
        return checks
    try:
        payload = json.loads(Path(latest_json).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        checks.append(check("latest-json-readable", False, str(error)))
        return checks
    latest_tag = payload.get("tag_name") or payload.get("tagName")
    checks.append(check("latest-json-has-tag", isinstance(latest_tag, str) and bool(latest_tag), str(latest_tag)))
    if not isinstance(latest_tag, str):
        return checks
    checks.append(check(
        "latest-not-bridge-tag",
        latest_tag != bridge_tag,
        f"latest={latest_tag} bridge={bridge_tag}",
    ))
    if expect_latest_tag is not None:
        checks.append(check(
            "latest-pointer-unchanged",
            latest_tag == expect_latest_tag,
            f"{latest_tag!r} expected {expect_latest_tag!r}",
        ))
    else:
        checks.append(check(
            "latest-pointer-unchanged",
            not strict,
            f"latest tag is {latest_tag!r}; no expected tag supplied"
            if not strict else "strict publication requires --expect-latest-tag",
        ))
    return checks


def check_public_summary(
    summary_path: Path,
    identity: verify_bridge.BuildIdentity,
    provenance: dict,
    ipa: Path,
) -> list[dict]:
    checks: list[dict] = []
    try:
        summary = json.loads(Path(summary_path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return [check("public-summary-readable", False, str(error))]
    checks.append(check("public-summary-readable", True, str(summary_path)))
    checks.append(check(
        "public-summary-schema",
        summary.get("schema") == package_bridge.PUBLIC_SCHEMA,
        str(summary.get("schema")),
    ))
    checks.append(check(
        "public-summary-mode",
        summary.get("mode") == verify_bridge.RELEASE,
        str(summary.get("mode")),
    ))
    checks.append(check(
        "public-summary-version",
        summary.get("marketingVersion") == identity.marketing_version
        and summary.get("buildNumber") == identity.build_number,
        json.dumps({
            "marketingVersion": summary.get("marketingVersion"),
            "buildNumber": summary.get("buildNumber"),
        }),
    ))
    checks.append(check(
        "public-summary-canonical-bundle-ids",
        summary.get("bundleIdentifier") == verify_bridge.HOST_ID
        and summary.get("applicationExtensionBundleIdentifier") == verify_bridge.TUNNEL_ID
        and summary.get("coreBundleIdentifier") == verify_bridge.CORE_ID,
        json.dumps({
            "host": summary.get("bundleIdentifier"),
            "tunnel": summary.get("applicationExtensionBundleIdentifier"),
            "core": summary.get("coreBundleIdentifier"),
        }),
    ))
    artifact = summary.get("artifact") if isinstance(summary.get("artifact"), dict) else {}
    checks.append(check(
        "public-summary-artifact-filename",
        artifact.get("filename") == ipa.name,
        str(artifact.get("filename")),
    ))
    try:
        actual_sha = package_bridge.sha256(ipa)
    except OSError as error:
        checks.append(check("public-summary-artifact-readable", False, str(error)))
        actual_sha = ""
    checks.append(check(
        "public-summary-artifact-sha256",
        artifact.get("sha256") == actual_sha,
        str(artifact.get("sha256")),
    ))
    checks.append(check(
        "public-summary-artifact-bytes",
        artifact.get("bytes") == ipa.stat().st_size,
        f"{artifact.get('bytes')} != {ipa.stat().st_size}",
    ))
    checks.append(check(
        "public-summary-source-ref",
        summary.get("sourceRef") == provenance.get("sourceRef"),
        f"{summary.get('sourceRef')} != {provenance.get('sourceRef')}",
    ))
    checks.append(check(
        "public-summary-source-tree-sha256",
        summary.get("sourceTreeSHA256") == provenance.get("sourceTreeSHA256"),
        f"{summary.get('sourceTreeSHA256')} != {provenance.get('sourceTreeSHA256')}",
    ))
    checks.append(check(
        "public-summary-source-file-count",
        summary.get("sourceFileCount") == provenance.get("sourceFileCount"),
        f"{summary.get('sourceFileCount')} != {provenance.get('sourceFileCount')}",
    ))
    topology = summary.get("topology") if isinstance(summary.get("topology"), dict) else {}
    checks.append(check(
        "public-summary-topology",
        topology.get("topLevelApps") == 1
        and topology.get("appExtensions") == 1
        and topology.get("xctests") == 1
        and topology.get("nestedApps") == 0,
        json.dumps(topology, sort_keys=True),
    ))
    verification = summary.get("verification") if isinstance(summary.get("verification"), dict) else {}
    checks.append(check(
        "public-summary-verification-clean",
        verification.get("failed") == 0
        and verification.get("unsigned") is True
        and verification.get("noDDI") is True
        and verification.get("hostNoXCTest") is True
        and verification.get("arm64IPhoneOS") is True,
        json.dumps(verification, sort_keys=True),
    ))
    unsafe = package_bridge.public_summary_failures(summary)
    checks.append(check("public-summary-safe", not unsafe, json.dumps(unsafe[:20])))
    return checks


def run_artifact_verifier(
    ipa: Path,
    version: str,
    build: str,
    source_ref: str,
    project: Path,
    repo_root: Path,
    expected_commit: str,
) -> tuple[list[dict], dict]:
    command = [
        sys.executable, "-B", str(Path(__file__).resolve().parent / "verify_bridge.py"),
        "--ipa", str(ipa),
        "--mode", verify_bridge.RELEASE,
        "--project", str(project),
        "--repo-root", str(repo_root),
        "--source-ref", source_ref,
        "--expected-version", version,
        "--expected-build", build,
        "--json",
    ]
    result = subprocess.run(command, text=True, capture_output=True)
    checks = [check("artifact-verifier-exit", result.returncode == 0, str(result.returncode))]
    payload = {}
    try:
        payload = json.loads(result.stdout)
    except ValueError:
        checks.append(check("artifact-verifier-json", False, result.stdout[-500:]))
        return checks, payload
    checks.append(check("artifact-verifier-json", True, "parsed"))
    ipa_result = payload.get("ipa", {})
    checks.append(check("artifact-topology-and-roles", bool(ipa_result.get("ok")), json.dumps(ipa_result.get("failures", []))))
    checks.append(check("artifact-mode-release", payload.get("mode") == verify_bridge.RELEASE, str(payload.get("mode"))))
    checks.append(check(
        "artifact-source-ref-bound",
        payload.get("sourceRef") == expected_commit,
        f"{payload.get('sourceRef')} != {expected_commit}",
    ))
    return checks, payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa", required=True)
    parser.add_argument("--sha256")
    parser.add_argument("--public-summary")
    parser.add_argument("--version")
    parser.add_argument("--build")
    parser.add_argument("--source-ref", required=True)
    parser.add_argument("--tag")
    parser.add_argument("--repo-root")
    parser.add_argument("--project", default=str(Path(__file__).resolve().parent.parent / "project.yml"))
    parser.add_argument("--latest-json")
    parser.add_argument("--expect-latest-tag")
    parser.add_argument("--allow-missing-tag", action="store_true")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    ipa = Path(args.ipa).resolve()
    project = Path(args.project).resolve()
    repo_root = Path(args.repo_root).resolve() if args.repo_root else project.parent.parent
    checks: list[dict] = []

    checks.append(check("ipa-present", ipa.is_file(), str(ipa)))
    if not ipa.is_file():
        return _finish(checks, args.json, {})

    version = args.version
    if version is None:
        match = re.fullmatch(
            re.escape(package_bridge.CANONICAL_PREFIX) + r"-(.+)-unsigned\.ipa",
            ipa.name,
        )
        if not match:
            checks.append(check("ipa-canonical-filename", False, ipa.name))
            return _finish(checks, args.json, {})
        version = match.group(1)
    checks.append(check("ipa-canonical-filename", ipa.name == canonical_ipa_name(version), ipa.name))
    checks.append(check("version-semver", bool(SEMVER_RE.fullmatch(version)), version))

    summary_payload = {}
    if args.public_summary:
        try:
            summary_payload = json.loads(Path(args.public_summary).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            summary_payload = {}
    build = args.build or summary_payload.get("buildNumber")
    if not build:
        checks.append(check("build-number-supplied", False, "provide --build or a public summary"))
        return _finish(checks, args.json, {})

    try:
        identity, commit = verify_bridge.load_identity_for_source(
            project, repo_root, args.source_ref
        )
        identity = verify_bridge.apply_identity_overrides(identity, version, build)
        identity = verify_bridge.validate_identity(identity, verify_bridge.RELEASE)
    except verify_bridge.IdentityError as error:
        checks.append(check("trusted-identity", False, str(error)))
        return _finish(checks, args.json, {})
    checks.append(check("trusted-identity", True, json.dumps(identity.as_json(), sort_keys=True)))
    checks.append(check(
        "source-ref-is-full-commit",
        bool(re.fullmatch(r"[0-9a-f]{40}", commit or "")),
        str(commit),
    ))

    checks.extend(check_sidecar(ipa, Path(args.sha256) if args.sha256 else None))
    tag = args.tag or TAG_PREFIX + version
    checks.extend(check_tag(repo_root, tag, args.source_ref, version, args.allow_missing_tag))
    checks.extend(check_latest(
        Path(args.latest_json) if args.latest_json else None,
        tag,
        args.expect_latest_tag,
        args.strict,
    ))

    try:
        provenance = package_bridge.compute_provenance(
            repo_root, project.parent, verify_bridge.RELEASE, args.source_ref
        )
    except (ValueError, RuntimeError, verify_bridge.IdentityError) as error:
        checks.append(check("source-provenance", False, str(error)))
        return _finish(checks, args.json, {})
    checks.append(check("source-provenance", provenance["ok"],
                        json.dumps(provenance["strictDeviations"])))
    checks.append(check("source-file-count", provenance["sourceFileCount"] > 0,
                        str(provenance["sourceFileCount"])))

    if args.public_summary:
        checks.extend(check_public_summary(Path(args.public_summary), identity, provenance, ipa))
    else:
        checks.append(check(
            "public-summary-present",
            not args.strict,
            "no --public-summary supplied" if not args.strict else "required in strict mode",
        ))

    artifact_checks, artifact_payload = run_artifact_verifier(
        ipa, version, build, args.source_ref, project, repo_root, commit
    )
    checks.extend(artifact_checks)

    report = {
        "ok": all(item["ok"] for item in checks),
        "version": version,
        "buildNumber": build,
        "sourceRef": commit,
        "sourceTreeSHA256": provenance.get("sourceTreeSHA256"),
        "sourceFileCount": provenance.get("sourceFileCount"),
        "tag": tag,
        "latestPointer": "checked" if args.latest_json else "unchecked",
        "checks": checks,
        "artifactVerification": artifact_payload,
    }
    return _finish(checks, args.json, report)


def _finish(checks: list[dict], as_json: bool, report: dict) -> int:
    ok = all(item["ok"] for item in checks)
    if as_json:
        payload = dict(report) if report else {}
        payload["ok"] = ok
        payload["checks"] = checks
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"public release verification ok={ok}")
        for item in checks:
            print(f"  {'OK' if item['ok'] else 'FAIL'}  {item['name']}: {item['detail']}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
