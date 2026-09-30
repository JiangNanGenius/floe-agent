#!/usr/bin/env python3
"""Tests for the native Office host rebuild/pin path.

The pin must describe the framework the sources actually build, and it must
fail closed whenever it cannot: an artifact from different sources, an
unqualified artifact, tampered resources, a traversal path, a lock that still
owes a rebuild, or a release-capability claim without device provenance. This
test pins that contract and proves the pin script refuses anything it cannot
verify.
"""

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "FloeAgent/scripts/pin_office_host_artifact.py"
LOCK = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/engine.lock.json"
HOST_SOURCES = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/FloeOfficeNative"


def digest(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class OfficeHostPinPath(unittest.TestCase):
    def run_script(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            capture_output=True, text=True, check=False, timeout=120,
        )

    def test_check_matches_the_pin_or_reports_the_rebuild_path(self) -> None:
        """The released pin either matches these sources or fails closed.

        While a host-source change is ahead of the pinned framework the check
        must exit 1 and name the rebuild workflow; the matched state is proven
        by `test_apply_records_a_verified_artifact_and_clears_the_marker`, which
        re-checks a refreshed pin.
        """
        completed = self.run_script("--check")
        self.assertIn(completed.returncode, (0, 1), completed.stdout + completed.stderr)
        if completed.returncode == 0:
            self.assertIn("matches the current host sources", completed.stdout)
        else:
            self.assertIn("SOURCE AHEAD OF ARTIFACT", completed.stdout)
            self.assertIn("office-native-host.yml", completed.stdout)
            self.assertIn("--artifact-zip", completed.stdout)
        # Capabilities that are not proven by a device artifact are always
        # reported, never silently assumed.
        self.assertIn("Office capability not proven for release", completed.stdout)

    def test_check_fails_closed_whenever_the_pin_cannot_be_trusted(self) -> None:
        """A lock that owes a rebuild, or whose source hash drifted, must fail.

        The released lock no longer carries pendingHostRebuild, so both
        mutations are exercised on a copy to keep the fail-closed contract
        covered.
        """
        with tempfile.TemporaryDirectory() as folder:
            lock = json.loads(LOCK.read_text())
            pin = lock["qualifiedHostArtifact"]
            with self.subTest("rebuild owed"):
                mutated = json.loads(json.dumps(lock))
                mutated["qualifiedHostArtifact"]["pendingHostRebuild"] = True
                path = Path(folder) / "pending.lock.json"
                path.write_text(json.dumps(mutated), encoding="utf-8")
                completed = self.run_script("--lock", str(path), "--check")
                self.assertEqual(completed.returncode, 1, completed.stdout)
                self.assertIn("SOURCE AHEAD OF ARTIFACT", completed.stdout)
                # The message must name the rebuild workflow and the pin command.
                self.assertIn("office-native-host.yml", completed.stdout)
                self.assertIn("--artifact-zip", completed.stdout)
            with self.subTest("source hash drifted"):
                mutated = json.loads(json.dumps(lock))
                mutated["qualifiedHostArtifact"]["hostSourceSHA256"]["FloeOfficeNative.mm"] = "0" * 64
                path = Path(folder) / "drifted.lock.json"
                path.write_text(json.dumps(mutated), encoding="utf-8")
                completed = self.run_script("--lock", str(path), "--check")
                self.assertEqual(completed.returncode, 1, completed.stdout)
                self.assertIn("FloeOfficeNative.mm", completed.stdout)

    def make_artifact(self, folder: Path, *, matching_sources: bool, qualified: bool = True,
                      tamper_resources: bool = False, omit_overlay_key: bool = False,
                      omit_scheme: bool = False, omit_forwarding: bool = False,
                      omit_kit: bool = False, kit_patch: str = None,
                      kit_commit: str = None, kit_files: dict = None,
                      lock_obj: dict = None) -> Path:
        root = folder / "OfficeNativeHost"
        framework = root / "FloeOfficeNative.framework"
        framework.mkdir(parents=True)
        (framework / "FloeOfficeNative").write_bytes(b"framework-binary")
        (framework / "Info.plist").write_text("<plist/>", encoding="utf-8")
        resources_root = root / "OfficeRuntimeResources"
        resources = resources_root / "share"
        resources.mkdir(parents=True)
        (resources / "fundamentalrc").write_text("rc", encoding="utf-8")

        lock = lock_obj if lock_obj is not None else json.loads(LOCK.read_text())
        pin = lock["qualifiedHostArtifact"]
        sources = {name: digest(HOST_SOURCES / name) for name in pin["hostSourceSHA256"]}
        if not matching_sources:
            sources["FloeOfficeNative.mm"] = "0" * 64
        manifest = {
            "sourceCommit": lock["commit"],
            "overlaySHA256": pin["overlaySHA256"],
            "hostSourceSHA256": sources,
            "hostCompilePassed": qualified,
            "hostLinkPassed": qualified,
            "swiftModuleImportPassed": qualified,
            # A compile/link qualification never proves the release
            # capabilities; all four stay false until verified device receipts
            # are recorded.
            "capabilityQualification": {
                "embeddedEditorPassed": False,
                "pptxVisibleRenderPassed": False,
                "deviceRoundtripPassed": False,
                "originalFileWritebackPassed": False,
            },
            "runID": "test-run",
            "workflowCommit": "test-commit",
            # The real manifest records resource hashes relative to the
            # resources root; the pin must compare in the same key space.
            "runtimeResourceSHA256": {
                str(path.relative_to(resources_root)): digest(path)
                for path in sorted(resources_root.rglob("*")) if path.is_file()
            },
        }
        scheme = lock.get("schemeTaskLifecycleOverlay")
        if scheme and not omit_scheme:
            manifest["schemeTaskLifecycle"] = {
                "patchSHA256": scheme["sha256"],
                "sourceCommit": lock["commit"],
                "files": {name: value["preparedSHA256"]
                          for name, value in scheme["files"].items()},
            }
        forwarding = lock.get("forwardingLifecycleOverlay")
        if forwarding and not omit_forwarding:
            manifest["forwardingLifecycle"] = {
                "patchSHA256": forwarding["sha256"], "sourceCommit": lock["commit"],
                "files": {name: value["preparedSHA256"]
                          for name, value in forwarding["files"].items()},
            }
        # The kit callback overlay is tracked in the production lock; a host
        # built from it must carry exact patch/commit/prepared-file provenance.
        kit = lock.get("kitCallbackLifecycleOverlay")
        if kit and not omit_kit:
            manifest["kitCallbackLifecycle"] = {
                "patchSHA256": kit_patch if kit_patch is not None else kit["sha256"],
                "sourceCommit": kit_commit if kit_commit is not None else lock["commit"],
                "files": (kit_files if kit_files is not None
                          else {name: value["preparedSHA256"]
                                for name, value in kit["files"].items()}),
            }
        # The overlay archive is reassembled for every host build; the manifest
        # carries the rebuilt values in the pin's key space.
        if pin.get("filterOverlay"):
            overlay = dict(pin["filterOverlay"])
            overlay["archiveSHA256"] = "b" * 64
            overlay["compilePassed"] = True
            overlay["archiveReplacementPassed"] = True
            if omit_overlay_key:
                overlay.pop("patchSHA256", None)
            manifest["filterOverlay"] = overlay
        if tamper_resources:
            (resources / "fundamentalrc").write_text("tampered", encoding="utf-8")
        (root / "native-host.json").write_text(json.dumps(manifest), encoding="utf-8")
        archive_path = folder / "OfficeNativeHost.zip"
        with zipfile.ZipFile(archive_path, "w") as archive:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(folder))
        return archive_path

    def test_apply_refuses_missing_forwarding_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            lock = folder / "lock.json"
            lock.write_bytes(LOCK.read_bytes())
            artifact = self.make_artifact(folder, matching_sources=True, omit_forwarding=True)
            completed = self.run_script("--lock", str(lock), "--artifact-zip", str(artifact), "--apply")
            self.assertEqual(completed.returncode, 1, completed.stdout)
            self.assertIn("forwarding lifecycle overlay provenance", completed.stderr)
            self.assertEqual(lock.read_bytes(), LOCK.read_bytes())

    def test_apply_refuses_missing_scheme_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            lock = folder / "lock.json"
            lock.write_bytes(LOCK.read_bytes())
            artifact = self.make_artifact(folder, matching_sources=True, omit_scheme=True)
            completed = self.run_script("--lock", str(lock), "--artifact-zip", str(artifact), "--apply")
            self.assertEqual(completed.returncode, 1, completed.stdout)
            self.assertIn("scheme lifecycle overlay provenance", completed.stderr)
            self.assertEqual(lock.read_bytes(), LOCK.read_bytes())

    def test_check_is_strictly_read_only(self) -> None:
        """--check never writes the lock, ahead or matched.

        A lock with an omitted kit claim is source ahead, even after the
        shipped pin is refreshed; after accepting a fully-proven artifact into a
        copy the same check must pass, and in both states the lock bytes are
        exactly preserved.
        """
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            ahead = folder / "ahead.lock.json"
            ahead_lock = json.loads(LOCK.read_text())
            ahead_lock['qualifiedHostArtifact'].pop('kitCallbackOverlaySHA256', None)
            ahead.write_text(json.dumps(ahead_lock), encoding='utf-8')
            ahead_bytes = ahead.read_bytes()
            completed = self.run_script("--lock", str(ahead), "--check")
            self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
            self.assertIn("SOURCE AHEAD OF ARTIFACT", completed.stdout)
            self.assertIn("kit callback lifecycle overlay", completed.stdout)
            self.assertEqual(ahead.read_bytes(), ahead_bytes)

            matched = folder / "matched.lock.json"
            matched.write_bytes(LOCK.read_bytes())
            artifact = self.make_artifact(folder, matching_sources=True)
            completed = self.run_script("--lock", str(matched), "--artifact-zip",
                                        str(artifact), "--apply")
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            applied_bytes = matched.read_bytes()
            completed = self.run_script("--lock", str(matched), "--check")
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertEqual(matched.read_bytes(), applied_bytes)

    def test_apply_refuses_missing_kit_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            lock = folder / "lock.json"
            lock.write_bytes(LOCK.read_bytes())
            artifact = self.make_artifact(folder, matching_sources=True, omit_kit=True)
            completed = self.run_script("--lock", str(lock), "--artifact-zip", str(artifact), "--apply")
            self.assertEqual(completed.returncode, 1, completed.stdout)
            self.assertIn("kit callback lifecycle overlay provenance", completed.stderr)
            # A rejected artifact never mutates the pin.
            self.assertEqual(lock.read_bytes(), LOCK.read_bytes())

    def test_apply_refuses_a_changed_kit_patch(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            lock = folder / "lock.json"
            lock.write_bytes(LOCK.read_bytes())
            artifact = self.make_artifact(folder, matching_sources=True, kit_patch="c" * 64)
            completed = self.run_script("--lock", str(lock), "--artifact-zip", str(artifact), "--apply")
            self.assertEqual(completed.returncode, 1, completed.stdout)
            self.assertIn("kit callback lifecycle overlay patch differs", completed.stderr)
            self.assertEqual(lock.read_bytes(), LOCK.read_bytes())

    def test_apply_refuses_kit_provenance_from_another_commit(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            lock = folder / "lock.json"
            lock.write_bytes(LOCK.read_bytes())
            artifact = self.make_artifact(folder, matching_sources=True,
                                          kit_commit="0" * 40)
            completed = self.run_script("--lock", str(lock), "--artifact-zip", str(artifact), "--apply")
            self.assertEqual(completed.returncode, 1, completed.stdout)
            self.assertIn("kit callback lifecycle overlay", completed.stderr)
            self.assertIn("different engine commit", completed.stderr)
            self.assertEqual(lock.read_bytes(), LOCK.read_bytes())

    def test_apply_refuses_changed_kit_prepared_files(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            lock = folder / "lock.json"
            lock.write_bytes(LOCK.read_bytes())
            tracked = json.loads(LOCK.read_text())["kitCallbackLifecycleOverlay"]["files"]
            changed = {name: ("1" * 64) for name in tracked}
            artifact = self.make_artifact(folder, matching_sources=True, kit_files=changed)
            completed = self.run_script("--lock", str(lock), "--artifact-zip", str(artifact), "--apply")
            self.assertEqual(completed.returncode, 1, completed.stdout)
            self.assertIn("kit callback lifecycle overlay prepared file hashes differ",
                          completed.stderr)
            self.assertEqual(lock.read_bytes(), LOCK.read_bytes())

    def test_check_rejects_a_kit_claim_without_a_tracked_overlay(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            legacy = json.loads(LOCK.read_text())
            legacy.pop("kitCallbackLifecycleOverlay", None)
            legacy["qualifiedHostArtifact"]["kitCallbackOverlaySHA256"] = "9" * 64
            path = Path(folder) / "dangling.lock.json"
            path.write_text(json.dumps(legacy), encoding="utf-8")
            completed = self.run_script("--lock", str(path), "--check")
            self.assertEqual(completed.returncode, 1, completed.stdout)
            self.assertIn("kit callback lifecycle overlay", completed.stdout)
            self.assertIn("claim without a tracked overlay", completed.stdout)

    def test_old_lock_without_a_kit_overlay_keeps_backward_compatibility(self) -> None:
        """Locks predating the kit overlay accept hosts without kit provenance.

        No tracked section and no pin claim means the host was built before the
        overlay existed; such a pin stays usable, --check passes and --apply
        neither requires nor records kitCallbackOverlaySHA256.
        """
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            legacy = json.loads(LOCK.read_text())
            legacy.pop("kitCallbackLifecycleOverlay", None)
            legacy["qualifiedHostArtifact"].pop("kitCallbackOverlaySHA256", None)
            lock = folder / "legacy.lock.json"
            lock.write_text(json.dumps(legacy), encoding="utf-8")
            completed = self.run_script("--lock", str(lock), "--check")
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            artifact = self.make_artifact(folder, matching_sources=True, omit_kit=True,
                                          lock_obj=legacy)
            completed = self.run_script("--lock", str(lock), "--artifact-zip",
                                        str(artifact), "--apply")
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            updated = json.loads(lock.read_text())["qualifiedHostArtifact"]
            self.assertNotIn("kitCallbackOverlaySHA256", updated)
            completed = self.run_script("--lock", str(lock), "--check")
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def test_apply_refuses_an_artifact_from_other_sources(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            artifact = self.make_artifact(Path(folder), matching_sources=False)
            completed = self.run_script("--artifact-zip", str(artifact), "--apply")
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn("different host sources", completed.stderr)

    def test_apply_refuses_an_artifact_whose_resources_do_not_match(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            artifact = self.make_artifact(Path(folder), matching_sources=True, tamper_resources=True)
            completed = self.run_script("--artifact-zip", str(artifact), "--apply")
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn("runtime resources do not match", completed.stderr)

    def test_apply_refuses_an_artifact_without_the_pinned_overlay_keys(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            artifact = self.make_artifact(Path(folder), matching_sources=True, omit_overlay_key=True)
            completed = self.run_script("--artifact-zip", str(artifact), "--apply")
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn("filter overlay omits patchSHA256", completed.stderr)

    def test_apply_refuses_capability_claims_without_device_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            folder_path = Path(folder)
            artifact = self.make_artifact(folder_path, matching_sources=True)
            with zipfile.ZipFile(artifact) as archive:
                names = [name for name in archive.namelist() if name.endswith("native-host.json")]
                manifest = json.loads(archive.read(names[0]))
            manifest["capabilityQualification"]["pptxVisibleRenderPassed"] = True
            with zipfile.ZipFile(artifact, "a") as archive:
                archive.writestr(names[0], json.dumps(manifest))
            completed = self.run_script("--artifact-zip", str(artifact), "--apply")
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn("pptxVisibleRenderEvidence", completed.stderr)

    def test_apply_refuses_an_artifact_without_the_capability_block(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            folder_path = Path(folder)
            artifact = self.make_artifact(folder_path, matching_sources=True)
            with zipfile.ZipFile(artifact) as archive:
                names = [name for name in archive.namelist() if name.endswith("native-host.json")]
                manifest = json.loads(archive.read(names[0]))
            del manifest["capabilityQualification"]
            with zipfile.ZipFile(artifact, "a") as archive:
                archive.writestr(names[0], json.dumps(manifest))
            completed = self.run_script("--artifact-zip", str(artifact), "--apply")
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn("capabilityQualification block", completed.stderr)

    def test_apply_refuses_an_unqualified_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            artifact = self.make_artifact(Path(folder), matching_sources=True, qualified=False)
            completed = self.run_script("--artifact-zip", str(artifact), "--apply")
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn("qualification flag", completed.stderr)

    def test_apply_records_a_verified_artifact_and_clears_the_marker(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            folder_path = Path(folder)
            artifact = self.make_artifact(folder_path, matching_sources=True)
            lock_copy = folder_path / "engine.lock.json"
            lock_copy.write_text(LOCK.read_text(), encoding="utf-8")
            completed = self.run_script("--lock", str(lock_copy), "--artifact-zip", str(artifact),
                                        "--artifact-id", "42", "--apply")
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            updated = json.loads(lock_copy.read_text())["qualifiedHostArtifact"]
            self.assertEqual(updated["archiveSHA256"], digest(artifact))
            # The pin records the artifact's capability state verbatim; a
            # compile/link artifact never promotes a release capability.
            self.assertEqual(
                updated["capabilityQualification"],
                {"embeddedEditorPassed": False, "pptxVisibleRenderPassed": False,
                 "deviceRoundtripPassed": False, "originalFileWritebackPassed": False},
            )
            self.assertEqual(updated["runID"], "test-run")
            self.assertEqual(updated["artifactID"], 42)
            # Counts describe what the pin actually verified in the artifact.
            self.assertEqual(updated["verifiedResourceFiles"], 1)
            self.assertEqual(updated["verifiedResourceDirectories"], 1)
            # The rebuilt overlay archive is recorded; stable qualification
            # fields keep their locked values.
            before = json.loads(LOCK.read_text())["qualifiedHostArtifact"]["filterOverlay"]
            self.assertEqual(updated["filterOverlay"]["archiveSHA256"], "b" * 64)
            self.assertEqual(updated["filterOverlay"]["patchSHA256"], before["patchSHA256"])
            self.assertEqual(updated["filterOverlay"]["sourceFiles"], before["sourceFiles"])
            # The verified kit callback overlay is recorded in the pin so
            # bootstrap_office_host.py can require hosts to carry its provenance.
            kit = json.loads(LOCK.read_text())["kitCallbackLifecycleOverlay"]["sha256"]
            self.assertEqual(updated["kitCallbackOverlaySHA256"], kit)
            self.assertNotIn("SOURCE AHEAD OF ARTIFACT", updated["note"])
            self.assertEqual(
                updated["hostSourceSHA256"],
                {name: digest(HOST_SOURCES / name) for name in updated["hostSourceSHA256"]},
            )
            # A re-check against the refreshed pin now passes.
            completed = self.run_script("--lock", str(lock_copy), "--check")
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def test_archive_paths_are_validated(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            folder_path = Path(folder)
            archive_path = folder_path / "evil.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("../escape/native-host.json", "{}")
            completed = self.run_script("--artifact-zip", str(archive_path), "--apply")
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("invalid artifact path", completed.stderr)


class OfficeHostRunIdentity(unittest.TestCase):
    """The manifest must name the CI run that produced the artifact.

    bootstrap_office_host.py re-downloads Vendor/Office/<runID>/OfficeNativeHost
    from the pin, so a manifest without run identity would leave the pin (and
    the App build) pointing at an older artifact.
    """

    def test_build_script_stamps_the_github_run(self) -> None:
        sys.path.insert(0, str(REPO_ROOT / "FloeAgent/scripts"))
        import build_office_native_host
        self.assertEqual(
            {"runID": "123456", "workflowCommit": "a" * 40},
            build_office_native_host.run_identity(
                {"GITHUB_RUN_ID": "123456", "GITHUB_SHA": "a" * 40}),
        )
        # A local qualification run keeps the manifest free of run identity.
        self.assertEqual({}, build_office_native_host.run_identity({}))


if __name__ == "__main__":
    unittest.main(verbosity=2)
