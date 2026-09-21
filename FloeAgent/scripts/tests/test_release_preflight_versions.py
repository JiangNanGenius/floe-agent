"""Exercise release preflight against committed, tagged project fixtures."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CATALOG_KEY = "notes.navigation.backToNotes"

class ReleaseVersionPreflightTests(unittest.TestCase):
    def run_preflight(self, transform=lambda text: text, catalog_transform=lambda text: text, missing_office_lock=False):
        with tempfile.TemporaryDirectory(prefix="floe-release-version-test-") as temp:
            root = Path(temp)
            app = root / "FloeAgent"
            for name in ("project.yml", "scripts/release_preflight.sh",
                         "scripts/validate_localization_catalog.py",
                         "scripts/audit_native_runtime_free.py",
                         "scripts/bootstrap_office_host.py",
                         "scripts/office_release_gates.py",
                         "FloeAgent.xcodeproj/project.pbxproj", "FloeScreenShare/Info.plist",
                         "FloeApp/Resources/Localizable.xcstrings"):
                target = app / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, target)
            # Copy the small pinned source inputs used by the real Office gate;
            # version fixtures must not weaken the release script itself.
            office = Path("ThirdParty/Collabora")
            lock = json.loads((ROOT / office / "engine.lock.json").read_text())
            files = [office / "engine.lock.json"]
            files += [office / "FloeOfficeNative" / name
                      for name in lock["qualifiedHostArtifact"]["hostSourceSHA256"]]
            if "filterOverlay" in lock["qualifiedHostArtifact"]:
                files.append(office / "filter-overlay.lock.json")
                filters = json.loads((ROOT / files[-1]).read_text())
                files.append(office / filters["patch"])
                files += [office / spec["patch"]
                          for spec in filters.get("headerDependencies", {}).values()]
            for name in files:
                target = app / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, target)
            # A host-source change legitimately leads the pinned framework until
            # cloud CI rebuilds and re-pins it. These version fixtures are about
            # release metadata, so record the copied sources in the staged pin
            # exactly as a re-pin would, leaving the real Office gate (overlay,
            # filter patch, artifact identity) in force.
            staged_lock = app / office / "engine.lock.json"
            staged = json.loads(staged_lock.read_text())
            for name in list(staged["qualifiedHostArtifact"]["hostSourceSHA256"]):
                staged["qualifiedHostArtifact"]["hostSourceSHA256"][name] = hashlib.sha256(
                    (app / office / "FloeOfficeNative" / name).read_bytes()).hexdigest()
            staged_lock.write_text(json.dumps(staged))
            if missing_office_lock:
                (app / office / "engine.lock.json").unlink()
            project = app / "FloeAgent.xcodeproj/project.pbxproj"
            project.write_text(transform(project.read_text()))
            catalog = app / "FloeApp/Resources/Localizable.xcstrings"
            catalog.write_text(catalog_transform(catalog.read_text()))
            env = dict(os.environ, GIT_AUTHOR_NAME="Floe Test", GIT_COMMITTER_NAME="Floe Test",
                       GIT_AUTHOR_EMAIL="test@example.invalid", GIT_COMMITTER_EMAIL="test@example.invalid")
            for args in (("init", "-q"), ("add", "."), ("commit", "-qm", "fixture"),
                         ("tag", "v1.7.0-beta.999")):
                subprocess.run(["git", *args], cwd=root, env=env, check=True, capture_output=True)
            return subprocess.run(["bash", str(app / "scripts/release_preflight.sh"),
                                   "v1.7.0-beta.999"], cwd=root, env=env,
                                  capture_output=True, text=True)

    def test_missing_office_lock_is_rejected(self):
        result = self.run_preflight(missing_office_lock=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("release preflight OK", result.stdout)

    def test_matching_generated_versions_pass(self):
        result = self.run_preflight()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("release preflight OK", result.stdout)
        # The real catalog must clear the pre-build localization gate.
        self.assertIn("localization catalog OK", result.stdout)

    def test_one_stale_extension_build_is_rejected(self):
        import re
        result = self.run_preflight(lambda text: re.sub(
            r"CURRENT_PROJECT_VERSION = [^;]+;", "CURRENT_PROJECT_VERSION = 1;", text, count=1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("generated Xcode project must match", result.stderr)

    def test_stale_marketing_version_is_rejected(self):
        import re
        result = self.run_preflight(lambda text: re.sub(
            r"MARKETING_VERSION = [^;]+;", "MARKETING_VERSION = 0.0.1;", text, count=1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("generated Xcode project must match", result.stderr)

    def test_missing_generated_metadata_is_rejected(self):
        result = self.run_preflight(lambda text: "// missing settings\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("generated Xcode project must match", result.stderr)

    def test_unnamespaced_catalog_key_is_rejected(self):
        result = self.run_preflight(catalog_transform=lambda text: text.replace(
            f'"{CATALOG_KEY}"', '"backToNotes"'))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("error: localization catalog incomplete", result.stderr)
        self.assertIn("non-namespaced key: 'backToNotes'", result.stderr)
        self.assertNotIn("release preflight OK", result.stdout)

    def test_catalog_missing_bilingual_value_is_rejected(self):
        def drop_chinese(text):
            catalog = json.loads(text)
            del catalog["strings"][CATALOG_KEY]["localizations"]["zh-Hans"]
            return json.dumps(catalog, ensure_ascii=False)

        result = self.run_preflight(catalog_transform=drop_chinese)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"{CATALOG_KEY}: missing zh-Hans", result.stderr)
        self.assertNotIn("release preflight OK", result.stdout)

    def test_catalog_empty_bilingual_value_is_rejected(self):
        def blank_english(text):
            catalog = json.loads(text)
            catalog["strings"][CATALOG_KEY]["localizations"]["en"]["stringUnit"]["value"] = "  "
            return json.dumps(catalog, ensure_ascii=False)

        result = self.run_preflight(catalog_transform=blank_english)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"{CATALOG_KEY}: en empty", result.stderr)
        self.assertNotIn("release preflight OK", result.stdout)

if __name__ == "__main__":
    unittest.main()
