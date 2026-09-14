"""Exercise release preflight against committed, tagged project fixtures."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

@unittest.skipUnless(sys.platform == "darwin", "release preflight requires Apple's plutil")
class ReleaseVersionPreflightTests(unittest.TestCase):
    def run_preflight(self, transform=lambda text: text):
        with tempfile.TemporaryDirectory(prefix="floe-release-version-test-") as temp:
            root = Path(temp)
            app = root / "FloeAgent"
            for name in ("project.yml", "scripts/release_preflight.sh",
                         "FloeAgent.xcodeproj/project.pbxproj", "FloeScreenShare/Info.plist"):
                target = app / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, target)
            project = app / "FloeAgent.xcodeproj/project.pbxproj"
            project.write_text(transform(project.read_text()))
            env = dict(os.environ, GIT_AUTHOR_NAME="Floe Test", GIT_COMMITTER_NAME="Floe Test",
                       GIT_AUTHOR_EMAIL="test@example.invalid", GIT_COMMITTER_EMAIL="test@example.invalid")
            for args in (("init", "-q"), ("add", "."), ("commit", "-qm", "fixture"),
                         ("tag", "v1.7.0-beta.999")):
                subprocess.run(["git", *args], cwd=root, env=env, check=True, capture_output=True)
            return subprocess.run(["bash", str(app / "scripts/release_preflight.sh"),
                                   "v1.7.0-beta.999"], cwd=root, env=env,
                                  capture_output=True, text=True)

    def test_matching_generated_versions_pass(self):
        result = self.run_preflight()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("release preflight OK", result.stdout)

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

if __name__ == "__main__":
    unittest.main()
