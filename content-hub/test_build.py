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

# Packages referenced by the currently published, signed index.json.
EXPECTED_IDS = {
    "floe.prompts.core",
    "floe.help.quickstart",
    "floe.templates.report",
    "floe.providers.compatibility",
    "floe.models.catalog-metadata",
}

# Staged packages: sources and deterministic package bytes are committed, but
# the index is NOT regenerated here. The serialized release owner re-signs
# index.json/index.sig once; until then the existing published signature must
# stay byte-identical (never replace it with an unsigned index). When the
# staged package is signed, move its id into EXPECTED_IDS.
STAGED_IDS = {"floe.search.providers"}

SEARCH_CATALOG_ADAPTERS = {
    "bocha": "bochaWeb",
    "tencent-wsa": "tencentWSA",
    "volcengine": "volcengine",
    "brave": "brave",
    "tavily": "tavily",
    "exa": "exa",
    "google-programmable": "googleProgrammable",
    "searxng": "searxng",
    "custom-interface": "custom",
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
        self.assertEqual({entry["id"] for entry in entries}, EXPECTED_IDS | STAGED_IDS)
        # Every committed package byte, including the staged (unsigned) one,
        # must match its sources exactly.
        build.write_packages(build.ROOT, packages, check=True)
        signed_index = json.loads((build.ROOT / "index.json").read_bytes())
        published_ids = {entry["id"] for entry in signed_index["entries"]}
        # Both sides of the signing transaction are valid: the existing feed
        # stays signed before publication, and the publish workflow verifies
        # the newly signed candidate before its promotion to EXPECTED_IDS.
        # Never omit an established package or admit an unknown candidate.
        self.assertTrue(EXPECTED_IDS <= published_ids)
        self.assertTrue(published_ids <= EXPECTED_IDS | STAGED_IDS)
        published = [entry for entry in entries if entry["id"] in published_ids]
        payload = build.build_index(published, build.ROOT, sign=False)
        self.assertEqual(payload, (build.ROOT / "index.json").read_bytes())
        # The published signature still verifies against the pinned identity.
        build.check(build.ROOT, build.REPO, build.PATH_PREFIX, build.ROOT / "public-key.json")
        for entry in entries:
            self.assertEqual(entry["path"], f"content-hub/packages/{entry['id']}/{entry['version']}/{entry['id']}.zip")
            self.assertFalse(entry["containsScripts"])
            self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(entry["contentDigest"], r"^[0-9a-f]{64}$")

    def test_staged_search_catalog_package(self):
        source = build.ROOT / "sources/providers/floe.search.providers"
        envelope = json.loads((source / "content.json").read_bytes())
        self.assertEqual(envelope["id"], "floe.search.providers")
        self.assertEqual(envelope["kind"], "providers")
        self.assertEqual(envelope["version"], "1.0.0")
        # The catalog payload is only understood by app builds that ship the
        # searchable-catalog flow; 1.7.0 would silently block activation.
        self.assertEqual(envelope["minimumAppVersion"], "1.7.47")
        self.assertFalse(envelope["containsScripts"])
        self.assertTrue(envelope["releaseNotes"]["en"])
        self.assertTrue(envelope["releaseNotes"]["zh-Hans"])

        payload_path = source / "SearchProviderCatalog.json"
        payload = json.loads(payload_path.read_bytes())
        self.assertEqual(payload["schemaVersion"], 1)
        self.assertEqual(payload["id"], envelope["id"])
        self.assertEqual(payload["version"], envelope["version"])
        entries = payload["entries"]
        self.assertEqual(len(entries), len(SEARCH_CATALOG_ADAPTERS))
        self.assertEqual(
            {entry["presetID"]: entry["adapterKind"] for entry in entries},
            SEARCH_CATALOG_ADAPTERS,
        )
        for entry in entries:
            # Entries describe adapters and defaults only: no source switch,
            # no enablement and no secret may exist in catalog data.
            self.assertNotIn("enabled", entry)
            self.assertNotIn("apiKey", json.dumps(entry).lower().replace("apikey", ""))
            for field in ("name", "blurb"):
                localized = entry[field]
                self.assertTrue(localized["en"].strip())
                self.assertTrue(localized["zh-Hans"].strip())
            if entry.get("defaultEndpoint") is not None:
                self.assertTrue(entry["defaultEndpoint"].startswith("https://"))

        # The committed package zip contains the exact payload bytes.
        entries_plan, packages = build.plan(build.ROOT / "sources", build.PATH_PREFIX)
        staged = next(entry for entry in entries_plan if entry["id"] == "floe.search.providers")
        relative = staged["path"][len(build.PATH_PREFIX):]
        files = build.unpack(packages[relative])
        self.assertEqual(files["SearchProviderCatalog.json"], payload_path.read_bytes())
        self.assertEqual(files["content.json"], (source / "content.json").read_bytes())

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
            self.assertEqual(
            len(list((fixture / "packages").rglob("*.zip"))),
            len(EXPECTED_IDS | STAGED_IDS),
        )

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
