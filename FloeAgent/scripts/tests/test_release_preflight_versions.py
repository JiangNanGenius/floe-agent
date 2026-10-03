"""Exercise release preflight against committed, tagged project fixtures."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CATALOG_KEY = "notes.navigation.backToNotes"

def version_and_build(project_yml):
    """Read the fixture's own MARKETING_VERSION/CURRENT_PROJECT_VERSION."""
    version = re.search(r'^\s*MARKETING_VERSION:\s*"?([^"\s]+)', project_yml, re.MULTILINE).group(1)
    build = re.search(r'^\s*CURRENT_PROJECT_VERSION:\s*"?([^"\s]+)', project_yml, re.MULTILINE).group(1)
    return version, build

def write_release_copy(docs, project_yml, notes_transform=None, whatsnew=None,
                       whatsnew_raw=None, remove_notes=False, remove_whatsnew=False):
    """Stage synthetic bilingual release copy for the fixture's version/build.

    The fixtures must not depend on the repository's current build documents:
    a version bump may land before its notes, and this test file also runs in
    ordinary CI. Synthetic documents keep the gate mechanics under test while
    the real tagged release is still enforced by the real preflight.
    """
    version, build = version_and_build(project_yml)
    series = '.'.join(version.split('.')[:2])
    (docs / 'releases' / 'notes').mkdir(parents=True, exist_ok=True)
    (docs / 'releases' / 'testflight').mkdir(parents=True, exist_ok=True)
    notes_name = f'RELEASE_NOTES_{version}_BUILD_{build}.md'
    notes = (f'# Floe Agent {version} (build {build})\n\n'
             '## 简体中文\n\n内测说明。\n\n## English\n\nInternal beta notes.\n')
    if notes_transform:
        notes = notes_transform(notes)
    if not remove_notes:
        (docs / 'releases' / 'notes' / notes_name).write_text(notes, encoding='utf-8')
    whatsnew_name = f'TESTFLIGHT_{series}_WHATS_NEW_BUILD_{build}.json'
    if not remove_whatsnew:
        if whatsnew_raw is not None:
            (docs / 'releases' / 'testflight' / whatsnew_name).write_text(whatsnew_raw, encoding='utf-8')
        else:
            payload = whatsnew or {'en-US': 'Internal beta fixture notes.', 'zh-Hans': '内测夹具说明。'}
            (docs / 'releases' / 'testflight' / whatsnew_name).write_text(json.dumps(payload, ensure_ascii=False), encoding='utf-8')
    return notes_name, whatsnew_name

class ReleaseVersionPreflightTests(unittest.TestCase):
    def run_preflight(self, transform=lambda text: text, catalog_transform=lambda text: text,
                      missing_office_lock=False, notes_transform=None, whatsnew=None,
                      whatsnew_raw=None, remove_notes=False, remove_whatsnew=False):
        with tempfile.TemporaryDirectory(prefix="floe-release-version-test-") as temp:
            root = Path(temp)
            app = root / "FloeAgent"
            # Every script release_preflight.sh executes, directly or through
            # imports: pin_office_host_artifact imports office_engine_repair,
            # which imports sim_paths (office_real_simulator) and
            # verify_office_engine/package_office_engine. A missing dependency
            # must fail this fixture loudly, never silently skip the gate.
            for name in ("project.yml", "scripts/release_preflight.sh",
                         "scripts/validate_localization_catalog.py",
                         "scripts/audit_native_runtime_free.py",
                         "scripts/bootstrap_office_host.py",
                         "scripts/office_release_gates.py",
                         "scripts/pin_office_host_artifact.py",
                         "scripts/office_engine_repair.py",
                         "scripts/verify_office_engine.py",
                         "scripts/package_office_engine.py",
                         "scripts/office_real_simulator/sim_paths.py",
                         "FloeAgent.xcodeproj/project.pbxproj", "FloeScreenShare/Info.plist",
                         "FloeApp/Resources/Localizable.xcstrings"):
                target = app / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, target)
            # Copy the small pinned source inputs used by the real Office gate;
            # version fixtures must not weaken the release script itself. The
            # engine patch lock stays beside the engine lock so
            # pin_office_host_artifact.py --check verifies the engineRepair
            # claim against its tracked contract, exactly as a release does.
            office = Path("ThirdParty/Collabora")
            lock = json.loads((ROOT / office / "engine.lock.json").read_text())
            files = [office / "engine.lock.json", office / "engine.patch.lock.json"]
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
            fixture_project = (app / "project.yml").read_text()
            # The fixture tag must follow the fixture's own project.yml version.
            # A frozen literal goes stale on every version bump and stops the
            # negative cases before the assertion they intend to exercise.
            fixture_version, _ = version_and_build(fixture_project)
            fixture_tag = f"v{fixture_version}-beta.999"
            write_release_copy(root / "docs", fixture_project,
                               notes_transform=notes_transform, whatsnew=whatsnew,
                               whatsnew_raw=whatsnew_raw, remove_notes=remove_notes,
                               remove_whatsnew=remove_whatsnew)
            env = dict(os.environ, GIT_AUTHOR_NAME="Floe Test", GIT_COMMITTER_NAME="Floe Test",
                       GIT_AUTHOR_EMAIL="test@example.invalid", GIT_COMMITTER_EMAIL="test@example.invalid")
            for args in (("init", "-q"), ("add", "."), ("commit", "-qm", "fixture"),
                         ("tag", fixture_tag)):
                subprocess.run(["git", *args], cwd=root, env=env, check=True, capture_output=True)
            return subprocess.run(["bash", str(app / "scripts/release_preflight.sh"),
                                   fixture_tag], cwd=root, env=env,
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
        self.assertIn("Release-copy preflight OK", result.stdout)

    def test_h3_bilingual_headings_are_accepted(self):
        # The publish step accepts h2 (Build 177) and h3 (later) headings.
        result = self.run_preflight(notes_transform=lambda text: text.replace("## ", "### "))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Release-copy preflight OK", result.stdout)

    def test_missing_release_notes_file_is_rejected(self):
        result = self.run_preflight(remove_notes=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release-copy preflight failed", result.stderr)
        self.assertIn("RELEASE_NOTES_", result.stderr)
        self.assertIn("unreadable", result.stderr)
        self.assertNotIn("release preflight OK", result.stdout)

    def test_release_notes_missing_chinese_heading_is_rejected(self):
        result = self.run_preflight(
            notes_transform=lambda text: text.replace("## 简体中文", "## 中文"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing '## 简体中文' section heading", result.stderr)
        self.assertNotIn("release preflight OK", result.stdout)

    def test_release_notes_missing_english_heading_is_rejected(self):
        result = self.run_preflight(
            notes_transform=lambda text: text.replace("## English", "## Release notes"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing '## English' section heading", result.stderr)
        self.assertNotIn("release preflight OK", result.stdout)

    def test_missing_testflight_notes_file_is_rejected(self):
        result = self.run_preflight(remove_whatsnew=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TESTFLIGHT_", result.stderr)
        self.assertIn("unreadable", result.stderr)
        self.assertNotIn("release preflight OK", result.stdout)

    def test_invalid_testflight_notes_json_is_rejected(self):
        result = self.run_preflight(whatsnew_raw="{not json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid JSON", result.stderr)
        self.assertNotIn("release preflight OK", result.stdout)

    def test_missing_testflight_locale_is_rejected(self):
        result = self.run_preflight(whatsnew={"en-US": "Only English."})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing non-empty zh-Hans text", result.stderr)
        self.assertNotIn("release preflight OK", result.stdout)

    def test_empty_testflight_locale_is_rejected(self):
        result = self.run_preflight(whatsnew={"en-US": "   ", "zh-Hans": "内测说明。"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing non-empty en-US text", result.stderr)

    def test_extra_testflight_locale_is_rejected(self):
        result = self.run_preflight(
            whatsnew={"en-US": "ok", "zh-Hans": "好", "fr-FR": "non"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported locales ['fr-FR']", result.stderr)

    def test_overlong_testflight_text_is_rejected(self):
        result = self.run_preflight(
            whatsnew={"en-US": "x" * 4001, "zh-Hans": "内测说明。"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exceeds 4000 characters", result.stderr)

    def test_release_copy_gate_is_read_only_and_runs_before_the_build_ok_line(self):
        script = (ROOT / "scripts/release_preflight.sh").read_text()
        start = script.index("Release-copy gate")
        end = script.index("# App extensions must carry the same version/build")
        gate = script[start:end]
        self.assertIn("read_text", gate)
        self.assertNotIn("write_text", gate)
        self.assertNotIn("unlink", gate)
        self.assertNotIn("git add", gate)
        self.assertLess(start, script.index("release preflight OK"))

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
