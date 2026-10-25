"""Real signed-channel roundtrips with a disposable synthetic trust root."""
import base64
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

import build
import build_android as android


class AndroidChannelTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="floe-android-channel-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "skill-hub"
        self.root.mkdir()
        shutil.copytree(android.ROOT / "sources", self.root / "sources")
        (self.root / "android").mkdir()
        shutil.copy2(android.ROOT / "android/guides.json", self.root / "android/guides.json")
        self.key = Ed25519PrivateKey.generate()
        public = self.key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        (self.root / "public-key.json").write_bytes(build.encoded(dict(
            keyID=build.KEY_ID, publicKey=base64.b64encode(public).decode())))
        raw_key = self.key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                         serialization.NoEncryption())
        contexts = ExitStack()
        self.addCleanup(contexts.close)
        contexts.enter_context(patch.object(android, "ROOT", self.root))
        contexts.enter_context(patch.object(build, "ROOT", self.root))
        contexts.enter_context(patch.dict(os.environ, {"FLOE_SKILL_HUB_SIGNING_KEY": base64.b64encode(raw_key).decode()}))
        # A released iOS channel is unrelated input, never an Android output.
        (self.root / "catalog.json").write_bytes(b"iOS immutable sentinel\n")
        (self.root / "catalog.sig").write_bytes(b"iOS signature sentinel\n")

    def snapshot(self):
        return {p.relative_to(self.root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in self.root.rglob("*") if p.is_file()}

    def test_staged_check_is_read_only_and_does_not_claim_publication(self):
        before = self.snapshot()
        android.run(staged=True)
        self.assertEqual(before, self.snapshot())
        self.assertIsNone(android.verify_released())
        with self.assertRaises(ValueError):
            android.run(check=True)

    def test_signed_channel_roundtrip_and_ios_bytes_untouched(self):
        before = self.snapshot()
        android.run()
        android.run(check=True)
        published = android.verify_released()
        self.assertEqual(set(published), set(build.IDS))
        for identifier, entry in published.items():
            files = build.unpack((self.root.parent / entry["path"]).read_bytes())
            manifest = json.loads(files["floe.json"])
            self.assertEqual(manifest["platforms"], ["android", "linux"])
            self.assertNotIn("ios", manifest["platforms"])
            self.assertFalse(entry["executionVerified"])
            self.assertEqual(files["SKILL.md"], (self.root / "sources" / identifier / "SKILL.md").read_bytes())
        for name in ("catalog.json", "catalog.sig"):
            self.assertEqual(before[name], self.snapshot()[name])
        after = self.snapshot()
        android.run(staged=True)
        android.run(check=True)
        self.assertEqual(after, self.snapshot())

    def test_tampered_archive_rejected(self):
        android.run()
        entry = android.verify_released()["floe-pdf"]
        archive = self.root.parent / entry["path"]
        archive.write_bytes(archive.read_bytes() + b"tampered")
        with self.assertRaises(ValueError):
            android.verify_released()

    def test_same_version_content_or_metadata_change_rejected(self):
        android.run()
        source = self.root / "sources/floe-pdf/SKILL.md"
        original = source.read_bytes()
        source.write_bytes(original + b"\nChanged Android content\n")
        with self.assertRaises(ValueError):
            android.run(staged=True)
        source.write_bytes(original)
        policy = self.root / "android/guides.json"
        record = json.loads(policy.read_bytes())
        record["minimumAppVersion"] = "0.2.0"
        policy.write_bytes(build.encoded(record))
        with self.assertRaises(ValueError):
            android.run(staged=True)

    def test_scripts_and_symlinks_are_not_inferred_compatible(self):
        source = self.root / "sources/floe-pdf"
        scripts = source / "scripts"
        scripts.mkdir()
        (scripts / "audit.py").write_text("print('unqualified')\n")
        with self.assertRaises(ValueError):
            android.candidates()
        shutil.rmtree(scripts)
        (source / "link.md").symlink_to(source / "SKILL.md")
        with self.assertRaises(ValueError):
            android.candidates()

    def test_even_valid_signature_cannot_cross_channel_paths(self):
        android.run()
        path = self.root / "android/catalog.json"
        record = json.loads(path.read_bytes())
        record["packages"][0]["path"] = "skill-hub/packages/floe-pdf/1.3.1/floe-pdf.zip"
        raw = build.encoded(record)
        path.write_bytes(raw)
        (self.root / "android/catalog.sig").write_bytes(build.encoded(dict(
            keyID=build.KEY_ID, signature=base64.b64encode(self.key.sign(raw)).decode())))
        with self.assertRaises(ValueError):
            android.verify_released()


if __name__ == "__main__":
    unittest.main()
