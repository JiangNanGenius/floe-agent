"""Content-hub build checks. No network access and no repository writes:
temp roots are copies, fixture tests live in TemporaryDirectory."""
import base64
import copy
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
    "floe.search.providers",
}

# Staged packages: sources and deterministic package bytes are committed, but
# the index is NOT regenerated here. The serialized release owner re-signs
# index.json/index.sig once; until then the existing published signature must
# stay byte-identical (never replace it with an unsigned index). When the
# staged package is signed, move its id into EXPECTED_IDS.
STAGED_IDS = set()

# Approved staged version bump for an already-published id:
# id -> (still-published version, reviewed candidate version). While the feed
# carries the published version, only the exact candidate source/archive is
# accepted; once the feed is promoted to the candidate, strict source/index
# equality applies again. A downgrade, an unapproved candidate, or a
# same-version rewrite is rejected.
STAGED_VERSIONS = {
    "floe.providers.compatibility": ("1.1.0", "1.1.2"),
    "floe.search.providers": ("1.0.0", "1.1.0"),
}

# The immutable provider archives that must survive this staging step
# byte-for-byte. The signed feed pins 1.1.0 through its Ed25519 signature;
# 1.0.0 predates that feed and is pinned here so a stray rebuild cannot
# silently rewrite either historical version.
IMMUTABLE_PROVIDER_PACKAGE_SHA256 = {
    "1.0.0": "e91cd711624abbd6cec518b0abe8abe2cad9198bc40e8ec8172fdb339aaffdc3",
    "1.1.0": "290e7962f9659eb8d22d08586176bb9559c4b98532a50a57abe72fe444a1f33d",
}

# The search catalog published in the signed feed stays 1.0.0; its archive is
# immutable while the 1.1.0 candidate is staged.
IMMUTABLE_SEARCH_PACKAGE_SHA256 = {
    "1.0.0": "5d85ea6f3804c6108a273f229c613e947307c0cef1b0de6aaf18f3af53a6543c",
}

# The pinned content-hub trust root. A local fixture key must never be passed
# off as the production signer.
PINNED_PUBLIC_KEY = {
    "keyID": "official-2026-09",
    "publicKey": "qOMhhkiyMpw1tWRgbuNH79PjlL6nynbFGqBxeNX2Hco=",
}

# Exact reviewed candidate package plan. The archive is built from the current
# sources by build.plan(); these constants ensure a future source drift cannot
# slip through without an explicit version/review update.
PROVIDER_CANDIDATE = {
    "version": "1.1.2",
    "minimumAppVersion": "1.7.64",
    "size": 161018,
    "sha256": "18918f534afa7fd9b378d7f18dce457f28935f8e7675ea004e2af2916b546ec9",
    "contentDigest": "72a182a32b61a4bdfa1ca66a2358e8b653afa031371ccd5a192d0ca2f8e60bc4",
}

# Exact reviewed search-catalog candidate. 1.1.0 adds the compiled DeepSeek
# adapter kind, so it must target App 1.7.65; 1.7.64 would fail closed and drop
# the new entry. The signed feed still serves 1.0.0 until the release owner
# signs and publishes this candidate.
SEARCH_CATALOG_CANDIDATE = {
    "version": "1.1.0",
    "minimumAppVersion": "1.7.65",
    "size": 8881,
    "sha256": "4cc46189a235f3e33408e8916edb98466822b6922d5ab82ca4d0e4f91aa9fab6",
    "contentDigest": "ca7ac3cc9e168df2674caa34d66edff9dae415f64387806f130bceba7d5f8b21",
}

SEARCH_CATALOG_ADAPTERS = {
    "bocha": "bochaWeb",
    "tencent-wsa": "tencentWSA",
    "volcengine": "volcengine",
    "deepseek": "deepseek",
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

    def mirror_published_repository(self, temporary):
        repository = Path(temporary) / "repository"
        root = repository / "content-hub"
        shutil.copytree(build.ROOT / "sources", root / "sources")
        shutil.copytree(build.ROOT / "packages", root / "packages")
        for name in ("index.json", "index.sig", "public-key.json"):
            shutil.copy2(build.ROOT / name, root / name)
        return repository, root

    def source_entries_and_published(self):
        entries, _ = build.plan(build.ROOT / "sources", build.PATH_PREFIX)
        published = json.loads((build.ROOT / "index.json").read_bytes())["entries"]
        return entries, published

    def test_committed_repo_artifacts_match_sources(self):
        self.assertEqual(
            json.loads((build.ROOT / "public-key.json").read_bytes()),
            PINNED_PUBLIC_KEY,
        )
        # The signed feed keeps its old entries and signature, while the
        # approved 1.1.2 candidate package must already carry exactly the
        # deterministic archive built from the current sources.
        state = build.check_staged(
            build.ROOT,
            build.REPO,
            build.PATH_PREFIX,
            build.ROOT / "public-key.json",
            required_ids=EXPECTED_IDS,
            staged_ids=STAGED_IDS,
            staged_versions=STAGED_VERSIONS,
        )
        entries = state["entries"]
        self.assertEqual({entry["id"] for entry in entries}, EXPECTED_IDS | STAGED_IDS)
        self.assertEqual(
            build.build_index(state["feed_entries"], build.ROOT, sign=False),
            (build.ROOT / "index.json").read_bytes(),
        )

        identifier = "floe.providers.compatibility"
        provider = next(entry for entry in entries if entry["id"] == identifier)
        for field, value in PROVIDER_CANDIDATE.items():
            self.assertEqual(provider[field], value)
        relative = provider["path"][len(build.PATH_PREFIX):]
        candidate_path = build.ROOT / relative
        self.assertEqual(candidate_path.read_bytes(), state["packages"][relative])
        self.assertEqual(hashlib.sha256(candidate_path.read_bytes()).hexdigest(), provider["sha256"])
        candidate_files = build.unpack(candidate_path.read_bytes())
        self.assertEqual(sorted(candidate_files), ["ProviderCatalog.json", "content.json"])
        source = build.ROOT / "sources/providers" / identifier
        self.assertEqual(candidate_files["ProviderCatalog.json"], (source / "ProviderCatalog.json").read_bytes())
        self.assertEqual(candidate_files["content.json"], (source / "content.json").read_bytes())

        # Before promotion the feed still points at the immutable 1.1.0
        # package; after promotion it must equal the candidate source entry.
        # Either way both historical provider archives remain intact.
        published_provider = next(
            entry for entry in state["index"]["entries"] if entry["id"] == identifier
        )
        self.assertIn(published_provider["version"], ("1.1.0", PROVIDER_CANDIDATE["version"]))
        if published_provider["version"] == "1.1.0":
            self.assertEqual(published_provider["sha256"], IMMUTABLE_PROVIDER_PACKAGE_SHA256["1.1.0"])
        else:
            self.assertEqual(published_provider, provider)
        for version, digest in IMMUTABLE_PROVIDER_PACKAGE_SHA256.items():
            path = build.ROOT / f"packages/{identifier}/{version}/{identifier}.zip"
            self.assertTrue(path.is_file())
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest)

        # The reviewed search-catalog candidate is staged with its exact
        # deterministic archive while the signed feed still serves 1.0.0.
        identifier = "floe.search.providers"
        search = next(entry for entry in entries if entry["id"] == identifier)
        for field, value in SEARCH_CATALOG_CANDIDATE.items():
            self.assertEqual(search[field], value)
        relative = search["path"][len(build.PATH_PREFIX):]
        candidate_path = build.ROOT / relative
        self.assertEqual(candidate_path.read_bytes(), state["packages"][relative])
        self.assertEqual(hashlib.sha256(candidate_path.read_bytes()).hexdigest(), search["sha256"])
        search_files = build.unpack(candidate_path.read_bytes())
        self.assertEqual(sorted(search_files), ["SearchProviderCatalog.json", "content.json"])
        search_source = build.ROOT / "sources/providers" / identifier
        self.assertEqual(
            search_files["SearchProviderCatalog.json"],
            (search_source / "SearchProviderCatalog.json").read_bytes(),
        )
        self.assertEqual(search_files["content.json"], (search_source / "content.json").read_bytes())

        published_search = next(
            entry for entry in state["index"]["entries"] if entry["id"] == identifier
        )
        self.assertEqual(published_search["version"], "1.0.0")
        self.assertEqual(
            published_search["sha256"],
            IMMUTABLE_SEARCH_PACKAGE_SHA256["1.0.0"],
        )
        published_search_path = build.ROOT / published_search["path"][len(build.PATH_PREFIX):]
        self.assertEqual(
            hashlib.sha256(published_search_path.read_bytes()).hexdigest(),
            IMMUTABLE_SEARCH_PACKAGE_SHA256["1.0.0"],
        )

        for entry in entries:
            self.assertEqual(entry["path"], f"content-hub/packages/{entry['id']}/{entry['version']}/{entry['id']}.zip")
            self.assertFalse(entry["containsScripts"])
            self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(entry["contentDigest"], r"^[0-9a-f]{64}$")

    def test_staged_validation_rejects_unapproved_version_bump(self):
        entries, _ = self.source_entries_and_published()
        published = copy.deepcopy(entries)
        provider = next(entry for entry in published if entry["id"] == "floe.providers.compatibility")
        provider["version"] = "1.1.1"
        provider["path"] = f"{build.PATH_PREFIX}packages/floe.providers.compatibility/1.1.1/floe.providers.compatibility.zip"
        with self.assertRaisesRegex(ValueError, "without an approved staged version bump"):
            build.validate_staged_sources(entries, published, EXPECTED_IDS, STAGED_IDS, {})

    def test_staged_validation_rejects_downgrade_or_unapproved_candidate(self):
        entries, published = self.source_entries_and_published()
        identifier = "floe.providers.compatibility"
        with self.assertRaisesRegex(ValueError, "must be newer"):
            build.validate_staged_sources(
                entries, published, EXPECTED_IDS, STAGED_IDS,
                {identifier: ("1.1.2", "1.1.1")},
            )
        with self.assertRaisesRegex(ValueError, "is not the approved staged candidate"):
            build.validate_staged_sources(
                entries, published, EXPECTED_IDS, STAGED_IDS,
                {identifier: ("1.1.0", "1.1.3")},
            )
        with self.assertRaisesRegex(ValueError, "must be newer"):
            build.validate_staged_sources(
                entries, published, EXPECTED_IDS, STAGED_IDS,
                {**STAGED_VERSIONS, "floe.search.providers": ("1.1.0", "1.0.0")},
            )
        with self.assertRaisesRegex(ValueError, "is not the approved staged candidate"):
            build.validate_staged_sources(
                entries, published, EXPECTED_IDS, STAGED_IDS,
                {**STAGED_VERSIONS, "floe.search.providers": ("1.0.0", "1.1.1")},
            )
        source_downgrade = copy.deepcopy(entries)
        source_provider = next(entry for entry in source_downgrade if entry["id"] == identifier)
        source_provider["version"] = "1.1.1"
        source_provider["path"] = source_provider["path"].replace("/1.1.2/", "/1.1.1/")
        with self.assertRaisesRegex(ValueError, "is not the approved staged candidate"):
            build.validate_staged_sources(source_downgrade, published, EXPECTED_IDS, STAGED_IDS, STAGED_VERSIONS)
        moved = copy.deepcopy(published)
        provider = next(entry for entry in moved if entry["id"] == identifier)
        provider["version"] = "1.1.1"
        provider["path"] = provider["path"].replace("/1.1.0/", "/1.1.1/")
        with self.assertRaisesRegex(ValueError, "neither the pinned published"):
            build.validate_staged_sources(
                entries, moved, EXPECTED_IDS, STAGED_IDS,
                {identifier: ("1.1.0", "1.1.2")},
            )

    def test_staged_validation_rejects_rewrites_and_requires_exact_promotion(self):
        entries, _ = self.source_entries_and_published()
        identifier = "floe.providers.compatibility"
        rewritten = copy.deepcopy(entries)
        prompt = next(entry for entry in rewritten if entry["id"] == "floe.prompts.core")
        prompt["releaseNotes"]["en"] = "Rewritten without a version bump"
        with self.assertRaisesRegex(ValueError, "without an approved staged version bump"):
            build.validate_staged_sources(entries, rewritten, EXPECTED_IDS, STAGED_IDS, STAGED_VERSIONS)

        promoted = copy.deepcopy(entries)
        provider = next(entry for entry in promoted if entry["id"] == identifier)
        provider["releaseNotes"]["en"] = "Promoted with rewritten metadata"
        with self.assertRaisesRegex(ValueError, "promoted 1.1.2 source differs"):
            build.validate_staged_sources(entries, promoted, EXPECTED_IDS, STAGED_IDS, STAGED_VERSIONS)

        source_provider = next(entry for entry in entries if entry["id"] == identifier)
        exact_promotion = copy.deepcopy(entries)
        feed = build.validate_staged_sources(entries, exact_promotion, EXPECTED_IDS, STAGED_IDS, STAGED_VERSIONS)
        self.assertEqual(next(entry for entry in feed if entry["id"] == identifier), source_provider)

    def test_staged_validation_rejects_unknown_or_deleted_ids(self):
        entries, published = self.source_entries_and_published()
        extra_source = list(entries) + [dict(entries[0], id="floe.unknown.package")]
        with self.assertRaisesRegex(ValueError, "source ids do not match"):
            build.validate_staged_sources(extra_source, published, EXPECTED_IDS, STAGED_IDS, STAGED_VERSIONS)
        missing = [entry for entry in published if entry["id"] != "floe.help.quickstart"]
        with self.assertRaisesRegex(ValueError, "missing required ids"):
            build.validate_staged_sources(entries, missing, EXPECTED_IDS, STAGED_IDS, STAGED_VERSIONS)
        extra_published = list(published) + [dict(published[0], id="floe.unknown.package")]
        with self.assertRaisesRegex(ValueError, "ids absent from sources"):
            build.validate_staged_sources(entries, extra_published, EXPECTED_IDS, STAGED_IDS, STAGED_VERSIONS)

    def test_candidate_package_must_exist_and_match_sources(self):
        identifier = "floe.providers.compatibility"
        with tempfile.TemporaryDirectory() as temporary:
            repository, root = self.mirror_published_repository(temporary)
            candidate = root / f"packages/{identifier}/1.1.2/{identifier}.zip"
            original = candidate.read_bytes()
            arguments = (root, repository, build.PATH_PREFIX, root / "public-key.json")
            keywords = dict(required_ids=EXPECTED_IDS, staged_ids=STAGED_IDS, staged_versions=STAGED_VERSIONS)
            candidate.write_bytes(original + b"tampered")
            with self.assertRaisesRegex(
                ValueError,
                r"package (?:stale or missing|missing at|size mismatch|sha256 mismatch|contentDigest mismatch)",
            ):
                build.check_staged(*arguments, **keywords)
            candidate.unlink()
            with self.assertRaisesRegex(
                ValueError,
                r"package (?:stale or missing|missing at|size mismatch|sha256 mismatch|contentDigest mismatch)",
            ):
                build.check_staged(*arguments, **keywords)
            candidate.write_bytes(original)
            build.check_staged(*arguments, **keywords)

    def test_signed_feed_and_immutable_package_tamper_fails(self):
        identifier = "floe.providers.compatibility"
        with tempfile.TemporaryDirectory() as temporary:
            repository, root = self.mirror_published_repository(temporary)
            index = json.loads((root / "index.json").read_bytes())
            published = next(entry for entry in index["entries"] if entry["id"] == identifier)
            old = root / published["path"][len(build.PATH_PREFIX):]
            data = bytearray(old.read_bytes())
            data[len(data) // 2] ^= 0x01
            old.write_bytes(bytes(data))
            with self.assertRaisesRegex(
                ValueError,
                r"package (?:size|sha256|contentDigest) mismatch",
            ):
                build.check(root, repository, build.PATH_PREFIX, root / "public-key.json")
        with tempfile.TemporaryDirectory() as temporary:
            repository, root = self.mirror_published_repository(temporary)
            index_path = root / "index.json"
            index = json.loads(index_path.read_bytes())
            index["entries"][0]["releaseNotes"]["en"] = "Tampered feed"
            index_path.write_bytes(build.encoded(index))
            with self.assertRaisesRegex(ValueError, "signature verification failed"):
                build.check(root, repository, build.PATH_PREFIX, root / "public-key.json")

    def test_staged_search_catalog_package(self):
        source = build.ROOT / "sources/providers/floe.search.providers"
        envelope = json.loads((source / "content.json").read_bytes())
        self.assertEqual(envelope["id"], "floe.search.providers")
        self.assertEqual(envelope["kind"], "providers")
        self.assertEqual(envelope["version"], SEARCH_CATALOG_CANDIDATE["version"])
        # 1.1.0 adds the DeepSeek adapter kind compiled in App 1.7.65; an
        # older 1.7.64 app would fail closed and drop the new entry.
        self.assertEqual(
            envelope["minimumAppVersion"], SEARCH_CATALOG_CANDIDATE["minimumAppVersion"]
        )
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
        deepseek = next(entry for entry in entries if entry["presetID"] == "deepseek")
        self.assertEqual(deepseek["adapterKind"], "deepseek")
        self.assertEqual(
            deepseek["defaultEndpoint"], "https://api.deepseek.com/v1/tools/search"
        )
        self.assertEqual(
            [field["key"] for field in deepseek["credentialFields"]], ["apiKey"]
        )
        self.assertEqual(
            [field["key"] for field in deepseek["optionFields"]], ["needContent"]
        )
        self.assertEqual(deepseek["optionFields"][0]["kind"], "bool")
        self.assertEqual(deepseek["optionFields"][0]["defaultValue"], "false")
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

        # The committed package zip contains the exact payload bytes and pins
        # the reviewed deterministic archive the release owner will sign.
        entries_plan, packages = build.plan(build.ROOT / "sources", build.PATH_PREFIX)
        staged = next(entry for entry in entries_plan if entry["id"] == "floe.search.providers")
        for field, value in SEARCH_CATALOG_CANDIDATE.items():
            self.assertEqual(staged[field], value)
        relative = staged["path"][len(build.PATH_PREFIX):]
        archive = packages[relative]
        self.assertEqual(len(archive), SEARCH_CATALOG_CANDIDATE["size"])
        self.assertEqual(
            hashlib.sha256(archive).hexdigest(), SEARCH_CATALOG_CANDIDATE["sha256"]
        )
        files = build.unpack(archive)
        self.assertEqual(files["SearchProviderCatalog.json"], payload_path.read_bytes())
        self.assertEqual(files["content.json"], (source / "content.json").read_bytes())
        self.assertEqual(build.canonical(files), SEARCH_CATALOG_CANDIDATE["contentDigest"])

        # The signed feed and its published 1.0.0 archive remain untouched.
        index = json.loads((build.ROOT / "index.json").read_bytes())
        published = next(
            entry for entry in index["entries"] if entry["id"] == "floe.search.providers"
        )
        self.assertEqual(published["version"], "1.0.0")
        self.assertEqual(published["minimumAppVersion"], "1.7.47")
        self.assertEqual(published["sha256"], IMMUTABLE_SEARCH_PACKAGE_SHA256["1.0.0"])

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
