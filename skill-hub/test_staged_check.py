"""End-to-end CLI tests for the staged-source vs released-feed gates.

The fixture is a disposable mini repository with its own synthetic Ed25519 key;
the real skill-hub tree is never modified and no repository secret is read.
These tests exercise the actual `build.py` CLI and on-disk contract instead of
re-implementing the verification logic.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from build import IDS, KEY_ID
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))


def guide_sources(identifier, version, body="Fixture body.\n"):
    name = f"{identifier} fixture"
    description = f"{name} description"
    skill_md = f"---\nname: {identifier}\ndisplay_name: {name}\ndescription: {description}\n---\n\n{body}"
    manifest = dict(schemaVersion=1, id=identifier, version=version, capabilities=[], tools=[],
                    platforms=["ios"], scriptRuntime="none", pythonPackages=[])
    release = dict(name=name, description=description, minimumAppVersion="1.4.98",
                   releaseNotes={"zh-Hans": "本地夹具更新。", "en": "Fixture update."})
    return skill_md, manifest, release


class StagedCheckCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._temp = tempfile.TemporaryDirectory(prefix="floe-skill-hub-staged-")
        cls.repo = Path(cls._temp.name)
        cls.build_script = cls.repo / "skill-hub/build.py"
        cls.build_script.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(Path(__file__).resolve().parent / "build.py", cls.build_script)
        for identifier in IDS:
            folder = cls.repo / "skill-hub/sources" / identifier
            skill_md, manifest, release = guide_sources(identifier, "1.0.0")
            write(folder / "SKILL.md", skill_md)
            write(folder / "floe.json", canonical_json(manifest))
            write(folder / "release.json", canonical_json(release))
        models = [
            # A staged model with asset metadata must stay pending and unusable.
            dict(id="floe/fixture-pending", skillID="floe-video", capability="video.interpolate",
                 license="MIT", status="pending-assets",
                 files=[dict(url="https://example.invalid/weights.bin", sha256="a" * 64, sizeBytes=1024)]),
            dict(id="floe/fixture-license", skillID="floe-video", capability="video.restore",
                 license="check", status="license-check", files=[]),
            dict(id="floe/fixture-excluded", skillID="floe-video", capability="video.inpaint",
                 license="CC-BY-NC-4.0", status="excluded", notes="Out of scope", files=[]),
        ]
        write(cls.repo / "skill-hub/models.json", canonical_json({"models": models}))
        cls.key = Ed25519PrivateKey.generate()
        raw_public = cls.key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        write(cls.repo / "skill-hub/public-key.json",
              canonical_json({"keyID": KEY_ID, "publicKey": base64.b64encode(raw_public).decode()}))
        result = cls.run_cli(env=cls.signing_env())
        if result.returncode != 0:
            raise AssertionError(f"fixture build failed: {result.stderr}")

    @classmethod
    def tearDownClass(cls):
        cls._temp.cleanup()

    @classmethod
    def signing_env(cls):
        raw = cls.key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                    serialization.NoEncryption())
        return {"FLOE_SKILL_HUB_SIGNING_KEY": base64.b64encode(raw).decode()}

    @classmethod
    def run_cli(cls, *args, env=None):
        """Runs the real CLI with every FLOE_* variable removed (no real key)."""
        environment = {key: value for key, value in os.environ.items() if not key.startswith("FLOE_")}
        if env:
            environment.update(env)
        return subprocess.run([sys.executable, str(cls.build_script), *args],
                              cwd=cls.repo, env=environment, capture_output=True, text=True)

    def mutate(self, relative, transform):
        path = self.repo / relative
        original = path.read_bytes()
        self.addCleanup(path.write_bytes, original)
        path.write_bytes(transform(original))

    def mutate_json(self, relative, transform):
        def apply(data):
            value = json.loads(data)
            transform(value)
            return canonical_json(value)
        self.mutate(relative, apply)

    def resign_catalog(self, transform):
        """Mutates the released catalog and re-signs it with the fixture key."""
        catalog = json.loads((self.repo / "skill-hub/catalog.json").read_bytes())
        transform(catalog)
        payload = canonical_json(catalog)
        self.mutate("skill-hub/catalog.json", lambda _: payload)
        signature = {"keyID": KEY_ID, "signature": base64.b64encode(self.key.sign(payload)).decode()}
        self.mutate("skill-hub/catalog.sig", lambda _: canonical_json(signature))

    def stage_office_source(self, version="2.0.0", body="Newer staged body.\n"):
        """Stages a source change and regenerates only the app-bundled seed.

        A real staged tree keeps the released catalog/signature and only moves
        the source plus the generated Swift seed, so the fixture follows that
        operator flow instead of running a signed build.
        """
        skill_md, manifest, _ = guide_sources("floe-office", version, body)
        self.mutate("skill-hub/sources/floe-office/SKILL.md", lambda _: skill_md.encode("utf-8"))
        self.mutate("skill-hub/sources/floe-office/floe.json", lambda _: canonical_json(manifest))
        import importlib.util
        spec = importlib.util.spec_from_file_location("fixture_build", self.build_script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        outputs, _, _, _, _ = module.candidate_outputs()
        for name in ("OfficialBundledSkills.generated.swift", "OfficialSkillHubKeys.generated.swift"):
            path = module.SWIFT / name
            original = path.read_bytes()
            self.addCleanup(path.write_bytes, original)
            path.write_bytes(outputs[path])

    def snapshot(self):
        entries = {}
        for path in sorted(self.repo.rglob("*")):
            relative = path.relative_to(self.repo).as_posix()
            if path.is_dir():
                entries[relative + "/"] = "dir"
            else:
                entries[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
        return entries

    def output(self, result):
        return result.stdout + result.stderr

    def test_published_baseline_passes_both_gates(self):
        staged = self.run_cli("--check-staged")
        self.assertEqual(staged.returncode, 0, staged.stderr)
        self.assertIn(f"Released feed verified: {len(IDS)} guides, 3 models, keyID {KEY_ID}", staged.stdout)
        self.assertIn("Staged sources match the released versions", staged.stdout)
        self.assertIn("0 ready models of 3", staged.stdout)
        strict = self.run_cli("--check")
        self.assertEqual(strict.returncode, 0, strict.stderr)
        self.assertIn("Verified official packages, signatures and generated app definitions", strict.stdout)

    def test_newer_unpublished_source_passes_only_the_staged_gate(self):
        self.stage_office_source()
        staged = self.run_cli("--check-staged")
        self.assertEqual(staged.returncode, 0, staged.stderr)
        self.assertIn("Unpublished staged sources (validated but not in the released catalog): floe-office 2.0.0 (released 1.0.0)", staged.stdout)
        self.assertNotIn("Staged sources match the released versions", staged.stdout)
        before = self.snapshot()
        strict = self.run_cli("--check")
        self.assertNotEqual(strict.returncode, 0)
        self.assertNotIn("Verified official packages", strict.stdout)
        self.assertEqual(before, self.snapshot(), "strict --check must not write unexpected outputs")

    def test_same_version_mutated_source_is_rejected(self):
        self.mutate("skill-hub/sources/floe-office/SKILL.md",
                    lambda data: data + b"Mutated body without a version bump.\n")
        staged = self.run_cli("--check-staged")
        self.assertNotEqual(staged.returncode, 0)
        self.assertIn("immutable version changed", self.output(staged))

    def test_same_version_metadata_change_is_rejected(self):
        self.mutate_json("skill-hub/sources/floe-office/release.json",
                         lambda release: release.update(releaseNotes={"zh-Hans": "改动的说明。", "en": "Changed notes."}))
        staged = self.run_cli("--check-staged")
        self.assertNotEqual(staged.returncode, 0)
        self.assertIn("changed without a version bump", self.output(staged))

    def test_source_downgrade_is_rejected(self):
        self.stage_office_source(version="0.9.0", body="Older staged body.\n")
        staged = self.run_cli("--check-staged")
        self.assertNotEqual(staged.returncode, 0)
        self.assertIn("older than released", self.output(staged))

    def test_tampered_released_catalog_bytes_are_rejected(self):
        self.mutate("skill-hub/catalog.json", lambda data: data.replace(b"floe-pdf", b"floe-pdF", 1))
        staged = self.run_cli("--check-staged")
        self.assertNotEqual(staged.returncode, 0)
        self.assertIn("released catalog signature verification failed", self.output(staged))

    def test_tampered_released_signature_is_rejected(self):
        forged = {"keyID": KEY_ID, "signature": base64.b64encode(b"forged").decode()}
        self.mutate("skill-hub/catalog.sig", lambda _: canonical_json(forged))
        staged = self.run_cli("--check-staged")
        self.assertNotEqual(staged.returncode, 0)
        self.assertIn("released catalog signature verification failed", self.output(staged))

    def test_unknown_signing_key_id_is_rejected(self):
        forged = {"keyID": "official-2026-10", "signature": base64.b64encode(b"forged").decode()}
        self.mutate("skill-hub/catalog.sig", lambda _: canonical_json(forged))
        staged = self.run_cli("--check-staged")
        self.assertNotEqual(staged.returncode, 0)
        self.assertIn("unknown signing key", self.output(staged))

    def test_tampered_trust_root_is_rejected(self):
        self.mutate_json("skill-hub/public-key.json",
                         lambda record: record.update(publicKey=base64.b64encode(b"1" * 32).decode()))
        staged = self.run_cli("--check-staged")
        self.assertNotEqual(staged.returncode, 0)
        self.assertIn("released catalog signature verification failed", self.output(staged))

    def test_tampered_released_archive_is_rejected(self):
        self.mutate("skill-hub/packages/floe-office/1.0.0/floe-office.zip",
                    lambda data: data[:-8] + b"00000000")
        staged = self.run_cli("--check-staged")
        self.assertNotEqual(staged.returncode, 0)
        self.assertIn("released package sha256 mismatch", self.output(staged))

    def test_resigned_catalog_with_broken_entry_hash_is_rejected(self):
        self.resign_catalog(lambda catalog: catalog["packages"][0].update(sha256="0" * 64))
        staged = self.run_cli("--check-staged")
        self.assertNotEqual(staged.returncode, 0)
        self.assertIn("released package sha256 mismatch", self.output(staged))

    def test_resigned_catalog_with_rewritten_version_is_rejected(self):
        self.resign_catalog(lambda catalog: catalog["packages"][0].update(version="9.9.9"))
        staged = self.run_cli("--check-staged")
        self.assertNotEqual(staged.returncode, 0)
        self.assertIn("invalid released package path", self.output(staged))

    def test_stale_generated_app_seed_is_rejected(self):
        self.mutate("FloeAgent/Sources/FloeSkills/OfficialBundledSkills.generated.swift",
                    lambda data: data + b"\n// stale\n")
        staged = self.run_cli("--check-staged")
        self.assertNotEqual(staged.returncode, 0)
        self.assertIn("generated artifact stale", self.output(staged))

    def test_pending_model_cannot_promote_without_assets(self):
        def promote(models):
            pending = next(model for model in models["models"] if model["id"] == "floe/fixture-pending")
            pending["status"] = "ready"
            pending["files"] = []
        self.mutate_json("skill-hub/models.json", promote)
        staged = self.run_cli("--check-staged")
        self.assertNotEqual(staged.returncode, 0)
        self.assertIn("ready models need files", self.output(staged))

    def test_rejected_license_model_cannot_be_ready(self):
        def promote(models):
            pending = next(model for model in models["models"] if model["id"] == "floe/fixture-pending")
            pending.update(status="ready", license="GPL")
        self.mutate_json("skill-hub/models.json", promote)
        staged = self.run_cli("--check-staged")
        self.assertNotEqual(staged.returncode, 0)
        self.assertIn("rejected license", self.output(staged))

    def test_check_modes_are_read_only(self):
        before = self.snapshot()
        staged = self.run_cli("--check-staged")
        self.assertEqual(staged.returncode, 0, staged.stderr)
        strict = self.run_cli("--check")
        self.assertEqual(strict.returncode, 0, strict.stderr)
        self.assertEqual(before, self.snapshot())

    def test_conflicting_check_modes_are_rejected(self):
        result = self.run_cli("--check", "--check-staged")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("separate gates", self.output(result))


if __name__ == "__main__":
    unittest.main()
