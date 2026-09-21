#!/usr/bin/env python3
"""Tests for the native Office host rebuild/pin path.

The pin must describe the framework the sources actually build, and it must
fail closed whenever it cannot: an artifact from different sources, an
unqualified artifact, tampered resources, a traversal path, or a lock that
still owes a rebuild. This test pins that contract and proves the pin script
refuses anything it cannot verify.
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

    def test_check_passes_against_the_rebuilt_pinned_artifact(self) -> None:
        completed = self.run_script("--check")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("matches the current host sources", completed.stdout)

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
                      tamper_resources: bool = False, omit_overlay_key: bool = False) -> Path:
        root = folder / "OfficeNativeHost"
        framework = root / "FloeOfficeNative.framework"
        framework.mkdir(parents=True)
        (framework / "FloeOfficeNative").write_bytes(b"framework-binary")
        (framework / "Info.plist").write_text("<plist/>", encoding="utf-8")
        resources_root = root / "OfficeRuntimeResources"
        resources = resources_root / "share"
        resources.mkdir(parents=True)
        (resources / "fundamentalrc").write_text("rc", encoding="utf-8")

        lock = json.loads(LOCK.read_text())
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
            "runID": "test-run",
            "workflowCommit": "test-commit",
            # The real manifest records resource hashes relative to the
            # resources root; the pin must compare in the same key space.
            "runtimeResourceSHA256": {
                str(path.relative_to(resources_root)): digest(path)
                for path in sorted(resources_root.rglob("*")) if path.is_file()
            },
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
