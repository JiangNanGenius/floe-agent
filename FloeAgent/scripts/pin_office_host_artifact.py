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
host sources, whose embedding or scheme/forwarding/kit-callback lifecycle
overlays differ or lack exact provenance (patch sha, engine commit, prepared
file hashes), or whose compile/link/Swift-import qualification did not pass.
Without `--apply` the script only reports what would change, so it is safe to
run in review. `qualifiedHostArtifact` carries `pendingHostRebuild: true`
while the pinned framework predates the sources; `--apply` clears it once the
rebuilt artifact is recorded and records each verified overlay claim,
including `kitCallbackOverlaySHA256`. Locks built before an overlay was
tracked (no tracked section and no claim) keep working for backward
compatibility.
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

# Lifecycle overlays recorded by a host build, in application order. Each entry
# maps the tracked engine-lock overlay section to the claim key the host pin
# carries (bootstrap_office_host.py enforces the claim against this lock) and
# to the exact-provenance block the artifact manifest carries (the patch that
# was applied, the engine commit it applied to, and the prepared file hashes
# the host actually compiled). A pin that claims an overlay must be backed by
# a manifest containing exactly this provenance; an absent claim keeps hosts
# built before the overlay was tracked usable (backward compatibility).
LIFECYCLE_OVERLAYS = (
    ("schemeTaskLifecycleOverlay", "schemeOverlaySHA256", "schemeTaskLifecycle",
     "scheme lifecycle overlay"),
    ("forwardingLifecycleOverlay", "forwardingOverlaySHA256", "forwardingLifecycle",
     "forwarding lifecycle overlay"),
    ("kitCallbackLifecycleOverlay", "kitCallbackOverlaySHA256", "kitCallbackLifecycle",
     "kit callback lifecycle overlay"),
)


def engine_repair_claim(lock_path: Path) -> dict:
    """The tracked engine repair contract for the device (IOS) platform.

    Absent (no tracked lock / no IOS section) means backward compatibility:
    artifacts built before the repair existed stay pin-able until the pin is
    replaced, mirroring the lifecycle overlay claim rules.
    """
    import office_engine_repair
    repair_lock, section = office_engine_repair.tracked_contract(
        lock_path=Path(lock_path).parent / "engine.patch.lock.json",
        platform="IOS")
    if section is None:
        return None
    lock = json.loads(Path(lock_path).read_text())
    # Bind the claim to THIS engine lock's commit as well: the repair is a
    # source patch on the pinned engine, so an engine bump must re-verify it.
    if repair_lock["engine"]["commit"] != lock["commit"]:
        raise ValueError("engine patch lock tracks a different engine commit")
    return office_engine_repair.expected_manifest_block(repair_lock, section)


def engine_repair_claim_failures(block, claim: dict, label: str) -> list:
    """Strict canonical comparison of one engineRepair claim block.

    The blockmust carry exactly the tracked identity fields: a missing field,
    a changed value or an unexpected extra field (for example an absolute
    receipt path) can never be accepted.
    """
    failures = []
    if not isinstance(block, dict):
        return [f"the {label} carries no engine repair provenance"]
    missing = sorted(key for key in claim if key not in block)
    extra = sorted(key for key in block if key not in claim)
    if missing:
        failures.append(f"the engine repair provenance omits {', '.join(missing)}")
    if extra:
        failures.append(f"the engine repair provenance carries unexpected fields: {', '.join(extra)}")
    for key, value in claim.items():
        if json.dumps(block.get(key), sort_keys=True) != json.dumps(value, sort_keys=True):
            failures.append(f"the engine repair {key} differs from the tracked contract")
    return failures


def engine_repair_provenance_failures(manifest: dict, claim: dict) -> list:
    return engine_repair_claim_failures(
        manifest.get("engineRepair"), claim, "artifact")


def lifecycle_provenance(overlay: dict, commit: str) -> dict:
    """The exact manifest block a host must carry for a tracked overlay."""
    return {
        "patchSHA256": overlay["sha256"],
        "sourceCommit": commit,
        "files": {name: spec["preparedSHA256"] for name, spec in overlay["files"].items()},
    }


def lifecycle_provenance_failures(manifest: dict, overlay: dict, commit: str,
                                  block: str, label: str) -> list:
    """Fail-closed comparison of one manifest lifecycle block.

    Reports a distinct reason for a missing block and for a changed patch,
    source commit or prepared-file hash set, so a host can never be pinned on
    an unstated or partial overlay claim.
    """
    provenance = manifest.get(block)
    if not isinstance(provenance, dict):
        return [f"the artifact carries no {label} provenance"]
    expected = lifecycle_provenance(overlay, commit)
    failures = []
    if provenance.get("patchSHA256") != expected["patchSHA256"]:
        failures.append(f"the {label} patch differs from the locked one")
    if provenance.get("sourceCommit") != expected["sourceCommit"]:
        failures.append(f"the {label} was applied to a different engine commit")
    if provenance.get("files") != expected["files"]:
        failures.append(f"the {label} prepared file hashes differ from the locked source")
    return failures


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
    lock_path = Path(lock_path)
    lock = json.loads(lock_path.read_text())
    pin = lock["qualifiedHostArtifact"]
    expected = pin["hostSourceSHA256"]
    actual = {name: source_hashes().get(name) for name in expected}
    mismatched = sorted(name for name, value in actual.items() if value != expected[name])
    # A tracked lifecycle overlay that the pin does not honestly claim (or
    # claims with a different patch) means the pinned framework predates those
    # sources: the check must report SOURCE AHEAD rather than match a host that
    # cannot contain the overlay. Old locks without a claim stay accepted while
    # no overlay section is tracked for them (backward compatibility).
    for section, claim_key, _, label in LIFECYCLE_OVERLAYS:
        overlay = lock.get(section)
        claim = pin.get(claim_key)
        if overlay is None:
            # A claim without a tracked overlay cannot be verified; an old lock
            # without either carries no claim and stays accepted.
            if claim is not None:
                mismatched.append(label + " claim without a tracked overlay")
            continue
        if claim != overlay["sha256"]:
            mismatched.append(label)
    pending = pin.get("pendingHostRebuild") is True
    # The tracked single-member engine repair (blank iOS slideshow fix) is
    # part of the host sources now: a pin that does not claim the exact
    # patch/object/archive identity names a pre-repair host, so the check
    # must report SOURCE AHEAD until CI rebuilds with the repaired engine.
    # A claim that is present but disagrees with the tracked contract (missing
    # field, wrong SHA/platform/member/lock or an unexpected extra field) is a
    # corrupt pin, not a rebuild request, and is rejected outright.
    repair_claim = engine_repair_claim(lock_path)
    rejected = []
    if repair_claim is not None:
        pin_block = pin.get("engineRepair")
        if pin_block is None:
            mismatched.append("engine repair (blank slideshow fix)")
        else:
            rejected = engine_repair_claim_failures(
                pin_block, repair_claim, "pin")
    if rejected:
        for failure in rejected:
            print(f"pin: REJECTED engine repair claim — {failure}")
        return 2
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
    # Every tracked lifecycle overlay must be present in the host with exact
    # provenance (patch sha, engine commit, prepared file hashes). The kit
    # callback overlay is covered here too: a host missing it, carrying a
    # changed patch or different prepared bytes can never be pinned. All
    # failures are collected before the lock is touched, so a rejected artifact
    # never mutates the pin.
    claimed_overlay_shas = {}
    for section, claim_key, block, label in LIFECYCLE_OVERLAYS:
        overlay = lock.get(section)
        if not overlay:
            continue
        failures.extend(lifecycle_provenance_failures(manifest, overlay, lock["commit"], block, label))
        claimed_overlay_shas[claim_key] = overlay["sha256"]
    # The engine single-member repair: the manifest must carry the exact
    # patch/object/archive identity the tracked contract expects.
    repair_claim = engine_repair_claim(lock_path)
    if repair_claim is not None:
        failures.extend(engine_repair_provenance_failures(manifest, repair_claim))
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
    # Record the exact overlay shas the accepted manifest proved, including the
    # kit callback overlay; bootstrap_office_host.py then requires hosts to
    # carry the same provenance.
    for claim_key, sha in claimed_overlay_shas.items():
        updated[claim_key] = sha
    if repair_claim is not None:
        # Store the canonical tracked identity, not the raw manifest block:
        # strict provenance above already rejected missing/changed/extra
        # fields, and the pin must stay byte-portable for bootstrap.
        updated["engineRepair"] = repair_claim
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
