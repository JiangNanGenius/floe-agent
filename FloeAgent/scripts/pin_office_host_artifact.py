#!/usr/bin/env python3
"""Pin (or verify) a rebuilt Floe native Office host artifact.

`engine.lock.json` is the single source of truth for the native Office host:
the framework archive it may embed, the per-file source hashes it was built
from, and the qualification manifest hashes. When the host sources change, the
pin intentionally leads the artifact and the app build fails closed — the
release cannot proceed until CI rebuilds and re-qualifies the framework and
this script records the new artifact.

Usage:
  # Read-only: is the pinned artifact built from the current sources?
  python3 FloeAgent/scripts/pin_office_host_artifact.py --check

  # From a completed "Qualify Floe Native Office Host" CI run:
  #   gh run download <run-id> -n office-native-host-unsigned -D ./host
  python3 FloeAgent/scripts/pin_office_host_artifact.py \
      --artifact-zip ./host/OfficeNativeHost.zip [--artifact-id <id>] [--apply]

`--apply` refuses any artifact whose manifest was not built from the current
host sources, whose overlay differs, or whose compile/link/Swift-import
qualification did not pass. Without `--apply` the script only reports what
would change, so it is safe to run in review. `qualifiedHostArtifact` carries
`pendingHostRebuild: true` while the pinned framework predates the sources;
`--apply` clears it once the rebuilt artifact is recorded.
"""

import argparse
import hashlib
import json
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

from office_release_gates import (CAPABILITY_FLAGS, capability_status, false_capabilities,
                                  validate_capability_claims)

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "ThirdParty/Collabora/engine.lock.json"
HOST_SOURCES = ROOT / "ThirdParty/Collabora/FloeOfficeNative"
FRAMEWORK = "FloeOfficeNative.framework"
REBUILD_WORKFLOW = ".github/workflows/office-native-host.yml"
SOURCE_AHEAD_MARKER = "SOURCE AHEAD OF ARTIFACT"

QUALIFICATION_KEYS = ("hostCompilePassed", "hostLinkPassed", "swiftModuleImportPassed")


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1048576), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def relative(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    if (not name or path.is_absolute() or ".." in path.parts or "\\" in name
            or str(path) != name.rstrip("/")):
        raise ValueError(f"invalid artifact path: {name!r}")
    return path


def lock_pin(lock_path: Path) -> dict:
    return json.loads(Path(lock_path).read_text())["qualifiedHostArtifact"]


def source_hashes() -> dict:
    return {name: digest(HOST_SOURCES / name) for name in sorted(p.name for p in HOST_SOURCES.iterdir() if p.is_file())}


def check(lock_path: Path) -> int:
    pin = lock_pin(lock_path)
    expected = pin["hostSourceSHA256"]
    actual = {name: source_hashes().get(name) for name in expected}
    mismatched = sorted(name for name, value in actual.items() if value != expected[name])
    pending = pin.get("pendingHostRebuild") is True
    status = capability_status(pin)
    for flag in status["unproven"]:
        print(f"pin: Office capability not proven for release: {flag}")
    if status["failures"]:
        for failure in status["failures"]:
            print(f"pin: REJECTED capability claim — {failure}")
    if not mismatched and not pending:
        print("pin: the recorded artifact matches the current host sources")
        return 0 if not status["failures"] else 1
    detail = ", ".join(mismatched) if mismatched else "pendingHostRebuild is recorded"
    print(f"pin: SOURCE AHEAD OF ARTIFACT — the pinned framework predates the host sources ({detail})")
    print("     the app build fails closed until CI rebuilds and re-qualifies the host:")
    print(f"     workflow: {REBUILD_WORKFLOW} (workflow_dispatch)")
    print("     then: gh run download <run-id> -n office-native-host-unsigned -D ./host")
    print("     then: python3 FloeAgent/scripts/pin_office_host_artifact.py "
          "--artifact-zip ./host/OfficeNativeHost.zip --apply")
    return 1


def read_artifact(artifact_zip: Path, workspace: Path) -> tuple[dict, Path]:
    """Extract and validate one uploaded CI artifact.

    Returns the qualification manifest and the artifact root directory.
    """
    with zipfile.ZipFile(artifact_zip) as archive:
        names = archive.namelist()
        if not any(name.endswith("native-host.json") for name in names):
            raise ValueError("the artifact contains no native-host.json qualification manifest")
        for name in names:
            # Reject absolute paths, traversal and backslashes before writing
            # anything: an uploaded artifact must never escape the workspace.
            relative(name)
        archive.extractall(workspace)
    manifest_path = next(workspace.rglob("native-host.json"))
    manifest = json.loads(manifest_path.read_text())
    # The build script uploads <Root>/{FloeOfficeNative.framework,
    # OfficeRuntimeResources,native-host.json}; the manifest sits beside them.
    return manifest, manifest_path.parent


def artifact_hashes(root: Path) -> dict:
    """Hashes exactly what bootstrap_office_host.py inventories."""
    framework_root = root / FRAMEWORK
    executable = framework_root / "FloeOfficeNative"
    manifest = root / "native-host.json"
    if not executable.is_file():
        raise ValueError(f"the artifact has no {FRAMEWORK}/FloeOfficeNative executable")
    auxiliary = {}
    for path in sorted(framework_root.rglob("*")):
        if path.is_file() and path != executable:
            auxiliary[str(path.relative_to(framework_root))] = digest(path)
    # The build script records runtimeResourceSHA256 relative to the resources
    # root, so key the artifact's files the same way; otherwise the comparison
    # below could never match a real artifact.
    resources = {}
    resource_directories = 0
    resources_root = root / "OfficeRuntimeResources"
    if resources_root.is_dir():
        for path in sorted(resources_root.rglob("*")):
            if path.is_file():
                resources[str(path.relative_to(resources_root))] = digest(path)
            elif path.is_dir():
                resource_directories += 1
    return {
        "manifestSHA256": digest(manifest),
        "executableSHA256": digest(executable),
        "frameworkAuxiliarySHA256": auxiliary,
        "runtimeResourceSHA256": resources,
        "runtimeResourceDirectories": resource_directories,
    }


def apply(lock_path: Path, artifact_zip: Path, note: str, artifact_id: int = None) -> int:
    lock_path = Path(lock_path)
    lock = json.loads(lock_path.read_text())
    pin = lock["qualifiedHostArtifact"]
    sources = source_hashes()
    with tempfile.TemporaryDirectory() as folder:
        manifest, root = read_artifact(Path(artifact_zip), Path(folder))
        hashes = artifact_hashes(root)

    failures = []
    # Compare against this checkout, not the pin: the pin legitimately predates
    # a source change (that is why the rebuild is owed), while the artifact
    # being applied must have been built from exactly these sources.
    expected_sources = {name: sources.get(name) for name in pin["hostSourceSHA256"]}
    if manifest.get("hostSourceSHA256") != expected_sources:
        failures.append("the artifact was built from different host sources; rebuild it from this revision")
    if manifest.get("sourceCommit") != lock.get("commit"):
        failures.append("the artifact was built from a different engine commit")
    if manifest.get("overlaySHA256") != pin["overlaySHA256"]:
        failures.append("the embedding overlay differs from the locked one")
    for key in QUALIFICATION_KEYS:
        if manifest.get(key) is not True:
            failures.append(f"qualification flag {key} did not pass")
    # A compile/link manifest must never claim release capabilities it cannot
    # prove, and a true claim without device/render provenance is rejected.
    failures.extend(validate_capability_claims(manifest, label="artifact manifest"))
    manifest_claims = manifest.get("capabilityQualification")
    if not isinstance(manifest_claims, dict):
        failures.append("the artifact manifest carries no capabilityQualification block")
    else:
        for flag in CAPABILITY_FLAGS:
            if flag not in manifest_claims:
                failures.append(f"the artifact manifest omits capability {flag}")
            elif not isinstance(manifest_claims[flag], bool):
                failures.append(f"the artifact manifest capability {flag} is not a boolean")
    declared_resources = manifest.get("runtimeResourceSHA256", {})
    if declared_resources and declared_resources != hashes["runtimeResourceSHA256"]:
        failures.append("the artifact's runtime resources do not match its manifest")
    # The filter overlay archive is reassembled for every host build, so the
    # pin must record the rebuilt values in the same key space it already
    # tracks; bootstrap_office_host.py compares them key by key against the
    # manifest and would otherwise reject the pinned artifact.
    rebuilt_overlay = {}
    if pin.get("filterOverlay"):
        declared_overlay = manifest.get("filterOverlay")
        if not isinstance(declared_overlay, dict):
            failures.append("the artifact carries no filter overlay qualification to record")
        else:
            omitted = sorted(key for key in pin["filterOverlay"] if key not in declared_overlay)
            if omitted:
                failures.append("the artifact's filter overlay omits " + ", ".join(omitted))
            else:
                rebuilt_overlay = {key: declared_overlay[key] for key in pin["filterOverlay"]}
    if failures:
        print("pin: refusing to pin this artifact", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    updated = dict(pin)
    updated["archiveSHA256"] = digest(Path(artifact_zip))
    updated["manifestSHA256"] = hashes["manifestSHA256"]
    updated["executableSHA256"] = hashes["executableSHA256"]
    updated["frameworkAuxiliarySHA256"] = hashes["frameworkAuxiliarySHA256"]
    updated["verifiedResourceFiles"] = len(hashes["runtimeResourceSHA256"])
    updated["verifiedResourceDirectories"] = hashes["runtimeResourceDirectories"]
    updated["hostSourceSHA256"] = {name: sources[name] for name in pin["hostSourceSHA256"]}
    if rebuilt_overlay:
        updated["filterOverlay"] = rebuilt_overlay
    updated["runID"] = manifest.get("runID", pin.get("runID"))
    updated["workflowCommit"] = manifest.get("workflowCommit", pin.get("workflowCommit"))
    if artifact_id:
        updated["artifactID"] = artifact_id
    updated["note"] = note
    updated["capabilityQualification"] = manifest_claims
    updated.pop("pendingHostRebuild", None)
    lock["qualifiedHostArtifact"] = updated
    lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n")
    print("pin: recorded the rebuilt artifact")
    print(f"  archiveSHA256={updated['archiveSHA256']}")
    print(f"  runID={updated.get('runID')}")
    status = capability_status(updated)
    for flag in status["unproven"]:
        print(f"  release gate still unproven: {flag}")
    if not status["releaseReady"]:
        print("  this pin is framework evidence only; Office release capabilities are not proven")
    print("  next: re-run the App build so bootstrap_office_host.py verifies the new pin")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", default=str(LOCK))
    parser.add_argument("--artifact-zip")
    parser.add_argument("--artifact-id", type=int,
                        help="the uploaded artifact id (gh run view --json artifacts)")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--check", action="store_true", help="read-only pin check (default)")
    parser.add_argument(
        "--note",
        default=("Rebuilt and re-qualified from the source in this revision "
                 "(staged-font catalog fingerprint profile identity and Pencil-only annotation input gating). "
                 "Native host compile/link and Swift import passed. Engine source and filter patches unchanged. "
                 "This is framework evidence; App build, TestFlight and physical-device acceptance are separate."),
    )
    args = parser.parse_args()
    lock_path = Path(args.lock)
    try:
        if args.apply:
            if not args.artifact_zip:
                parser.error("--apply requires --artifact-zip")
            return apply(lock_path, Path(args.artifact_zip), args.note, args.artifact_id)
        return check(lock_path)
    except ValueError as failure:
        print(f"pin: {failure}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
