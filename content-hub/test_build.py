"""Content-hub build checks. No network access and no repository writes:
temp roots are copies, fixture tests live in TemporaryDirectory."""
import base64
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build  # noqa: E402

EXPECTED_IDS = {
    "floe.prompts.core",
    "floe.help.quickstart",
    "floe.templates.report",
    "floe.providers.compatibility",
    "floe.models.catalog-metadata",
}


class ContentHubBuildTests(unittest.TestCase):
    def mirror_sources(self, temporary):
        root = Path(temporary) / "content-hub"
        shutil.copytree(build.ROOT / "sources", root / "sources")
        return root

    def make_fixture(self, temporary):
        fixture = Path(temporary) / "basic"
        build.make_fixture(fixture)
        return fixture

    def verify_fixture(self, fixture):
        build.check(fixture, fixture, "", fixture / "public-key.json")

    def test_committed_repo_artifacts_match_sources(self):
        entries, packages = build.plan(build.ROOT / "sources", build.PATH_PREFIX)
        self.assertEqual({entry["id"] for entry in entries}, EXPECTED_IDS)
        build.write_packages(build.ROOT, packages, check=True)
        payload = build.build_index(entries, build.ROOT, sign=False)
        self.assertEqual(payload, (build.ROOT / "index.json").read_bytes())
        for entry in entries:
            self.assertEqual(entry["path"], f"content-hub/packages/{entry['id']}/{entry['version']}/{entry['id']}.zip")
            self.assertFalse(entry["containsScripts"])
            self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(entry["contentDigest"], r"^[0-9a-f]{64}$")

    def test_deterministic_rebuild(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.mirror_sources(temporary)
            entries, packages = build.plan(root / "sources", build.PATH_PREFIX)
            build.write_packages(root, packages)
            first = build.build_index(entries, root, sign=False)
            (root / "index.json").write_bytes(first)
            time.sleep(1.1)
            entries_again, packages_again = build.plan(root / "sources", build.PATH_PREFIX)
            build.write_packages(root, packages_again)
            second = build.build_index(entries_again, root, sign=False)
            self.assertEqual(entries, entries_again)
            self.assertEqual(packages, packages_again)
            self.assertEqual(first, second)

    def test_fixture_roundtrip_signature_and_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.make_fixture(temporary)
            self.verify_fixture(fixture)
            record = json.loads((fixture / "public-key.json").read_bytes())
            self.assertEqual(record["keyID"], "fixture-local")
            self.assertEqual(len(base64.b64decode(record["publicKey"])), 32)
            private = fixture / "signing-key.b64"
            self.assertTrue(private.is_file())
            self.assertEqual(private.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(list((fixture / "packages").rglob("*.zip"))), 5)

    def test_tampered_package_byte_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.make_fixture(temporary)
            package = sorted((fixture / "packages").rglob("*.zip"))[0]
            data = bytearray(package.read_bytes())
            data[len(data) // 2] ^= 0x01
            package.write_bytes(bytes(data))
            with self.assertRaises(ValueError):
                self.verify_fixture(fixture)

    def test_tampered_release_note_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.make_fixture(temporary)
            index = json.loads((fixture / "index.json").read_bytes())
            index["entries"][0]["releaseNotes"]["en"] = "Tampered release note"
            (fixture / "index.json").write_bytes(build.encoded(index))
            with self.assertRaises(ValueError):
                self.verify_fixture(fixture)

    def test_content_digest_mismatch_detected(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.make_fixture(temporary)
            index = json.loads((fixture / "index.json").read_bytes())
            prompt_entry = next(
                item for item in index["entries"] if item["id"] == "floe.prompts.core"
            )
            package = fixture / prompt_entry["path"]
            files = build.unpack(package.read_bytes())
            content = json.loads(files["content.json"].decode("utf-8"))
            content["releaseNotes"]["en"] = "Rewritten payload"
            files["content.json"] = build.encoded(content)
            rewritten = build.package_zip(files)
            package.write_bytes(rewritten)
            entry = json.loads((fixture / "index.json").read_bytes())["entries"]
            entry = next(item for item in entry if item["id"] == "floe.prompts.core")
            entry["size"] = len(rewritten)
            entry["sha256"] = hashlib.sha256(rewritten).hexdigest()
            with self.assertRaises(ValueError):
                build.validate_entry(entry, "", fixture)

    def test_strict_versions_and_immutable_version_bytes(self):
        for value in ("1.0", "01.0.0", "v1.0.0", "1.0.0-beta", "1.0.0.0", "1.00.0", "", None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                build.validate_version(value)
        with tempfile.TemporaryDirectory() as temporary:
            root = self.mirror_sources(temporary)
            _, packages = build.plan(root / "sources", build.PATH_PREFIX)
            build.write_packages(root, packages)
            payload = root / "sources/help/floe.help.quickstart/index.md"
            payload.write_text(payload.read_text() + "\nchanged\n")
            _, changed = build.plan(root / "sources", build.PATH_PREFIX)
            with self.assertRaises(ValueError):
                build.write_packages(root, changed)

    def test_fixture_location_guard(self):
        with self.assertRaises(ValueError):
            build.ensure_fixture_location(build.REPO / "content-hub" / "tracked-fixture")

    def test_cli_fixture_and_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary) / "basic"
            created = subprocess.run(
                [sys.executable, str(build.ROOT / "build.py"), "--fixture", str(fixture)],
                capture_output=True, text=True)
            self.assertEqual(created.returncode, 0, created.stderr)
            private_bytes = (fixture / "signing-key.b64").read_bytes()
            self.assertNotIn(private_bytes.decode(), created.stdout)
            self.assertIn("publicKey=", created.stdout)
            verified = subprocess.run(
                [sys.executable, str(build.ROOT / "build.py"), "--check", "--fixture", str(fixture)],
                capture_output=True, text=True)
            self.assertEqual(verified.returncode, 0, verified.stderr)


if __name__ == "__main__":
    unittest.main()
