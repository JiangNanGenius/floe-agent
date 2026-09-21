#!/usr/bin/env python3
"""Tests for the native Office host rebuild/pin path.

The host sources in this revision lead the pinned framework artifact, so the
app build must fail closed until CI rebuilds and re-qualifies it. This test
pins that contract and proves the pin script refuses anything it cannot verify.
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

    def test_check_reports_the_current_source_ahead_of_artifact_state(self) -> None:
        completed = self.run_script("--check")
        self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
        self.assertIn("SOURCE AHEAD OF ARTIFACT", completed.stdout)
        # The message must name the rebuild workflow and the pin command.
        self.assertIn("office-native-host.yml", completed.stdout)
        self.assertIn("--artifact-zip", completed.stdout)

    def make_artifact(self, folder: Path, *, matching_sources: bool, qualified: bool = True) -> Path:
        root = folder / "OfficeNativeHost"
        framework = root / "FloeOfficeNative.framework"
        framework.mkdir(parents=True)
        (framework / "FloeOfficeNative").write_bytes(b"framework-binary")
        (framework / "Info.plist").write_text("<plist/>", encoding="utf-8")
        resources = root / "OfficeRuntimeResources" / "share"
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
        }
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
            completed = self.run_script("--lock", str(lock_copy), "--artifact-zip", str(artifact), "--apply")
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            updated = json.loads(lock_copy.read_text())["qualifiedHostArtifact"]
            self.assertEqual(updated["archiveSHA256"], digest(artifact))
            self.assertEqual(updated["runID"], "test-run")
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
