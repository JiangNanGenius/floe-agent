"""Signed WASI catalog tests: temporary test keys only, no official secrets.

These tests exercise the fixed manifest, the pinned Lua artifact, artifact
immutability and the read-only ``--check`` path without invoking a Swift build
(the assembler is injected) and without touching the repository working tree.
"""
import base64
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import build
from build import (MANIFEST, catalog_payload, check, place_immutable,
                   artifact_bytes, build as build_catalog, sign_catalog,
                   verify_catalog, verify_committed)
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

REVISION = 'a' * 40
WASM_MAGIC = b'\0asm\x01\0\0\0'


def fake_module(payload=b'floe-lua'):
    return WASM_MAGIC + payload


def payload_for(artifacts, manifest):
    packages = []
    for entry in manifest:
        data = artifacts[entry['id']]
        packages.append({
            'id': entry['id'],
            'version': entry['version'],
            'command': entry['command'],
            'minimumAppVersion': entry['minimumAppVersion'],
            'sha256': hashlib.sha256(data).hexdigest(),
            'url': f"{build.URL_PREFIX}/{REVISION}/capability-hub/{entry['path']}",
        })
    return {'schemaVersion': 1, 'packages': packages}


def test_manifest(lua_bytes):
    return (
        {
            'id': 'floe/test-text',
            'command': 'floe-text',
            'version': '1.0.0',
            'minimumAppVersion': '1.6.7',
            'kind': 'assembled',
            'source': 'Sources/floe-text.wat',
            'path': 'packages/floe-text/1.0.0/floe-text.wasm',
        },
        {
            'id': 'floe/test-lua',
            'command': 'floe-lua',
            'version': '5.4.8',
            'minimumAppVersion': '1.7.0',
            'kind': 'committed',
            'path': 'packages/floe-lua/5.4.8/lua.wasm',
            'sha256': hashlib.sha256(lua_bytes).hexdigest(),
            'sizeBytes': len(lua_bytes),
        },
    )


class FixedManifestTests(unittest.TestCase):
    """The committed 5.4.8 artifact is what the signed catalog will pin."""

    def test_lua_entry_pins_the_committed_artifact(self):
        entry = next(e for e in MANIFEST if e['id'] == 'floe/lua')
        data = (build.ROOT / entry['path']).read_bytes()
        self.assertEqual(entry['sha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual(entry['sizeBytes'], len(data))
        self.assertEqual(entry['command'], 'floe-lua')
        self.assertEqual(entry['version'], '5.4.8')
        build.verify_committed(entry, data)

    def test_manifest_commands_satisfy_the_app_parser(self):
        import re
        for entry in MANIFEST:
            self.assertRegex(entry['command'], r'^floe-[a-z0-9][a-z0-9-]{0,63}$')
            self.assertRegex(entry['id'], r'^floe/[a-z0-9][a-z0-9-]{0,63}$')
            self.assertRegex(entry['version'], r'^[0-9]+[.][0-9]+[.][0-9]+$')


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.private = Ed25519PrivateKey.generate()
        self.public = self.private.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)

    def tearDown(self):
        self.temporary.cleanup()

    def test_sign_and_verify_round_trip_rejects_tampering(self):
        artifacts = {'floe/test-text': fake_module(b'text'), 'floe/test-lua': fake_module()}
        catalog = json.dumps(payload_for(artifacts, test_manifest(fake_module())),
                             sort_keys=True, separators=(',', ':')).encode()
        signature = sign_catalog(catalog, self.private)
        verify_catalog(catalog, signature, self.public)
        with self.assertRaises(Exception):
            verify_catalog(catalog + b' ', signature, self.public)

    def _committed_signed_repo(self):
        repo = self.root / 'checkout'
        (repo / 'packages/floe-text/1.0.0').mkdir(parents=True)
        (repo / 'packages/floe-lua/5.4.8').mkdir(parents=True)
        text, lua = fake_module(b'text'), fake_module()
        (repo / 'packages/floe-text/1.0.0/floe-text.wasm').write_bytes(text)
        (repo / 'packages/floe-lua/5.4.8/lua.wasm').write_bytes(lua)
        manifest = test_manifest(lua)
        payload = payload_for({'floe/test-text': text, 'floe/test-lua': lua}, manifest)
        catalog = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
        (repo / 'catalog.json').write_bytes(catalog)
        (repo / 'catalog.sig').write_text(sign_catalog(catalog, self.private) + '\n')
        key_file = self.root / 'public-key.json'
        key_file.write_text(json.dumps({'publicKey': base64.b64encode(self.public).decode()}))
        return repo, catalog, manifest, key_file

    @staticmethod
    def _tree(repo):
        return {str(path.relative_to(repo)): path.read_bytes() for path in repo.rglob('*') if path.is_file()}

    def test_check_is_read_only_and_rejects_digest_drift(self):
        repo, catalog, manifest, key_file = self._committed_signed_repo()
        before = self._tree(repo)
        with mock.patch.object(build, 'MANIFEST', manifest):
            check(base=repo, public_key_path=key_file)
            self.assertEqual(before, self._tree(repo))
            (repo / 'catalog.json').write_bytes(catalog.replace(b'floe/test-lua', b'floe/tampered'))
            with self.assertRaises(Exception):
                check(base=repo, public_key_path=key_file)

    def test_check_rejects_a_catalog_missing_a_manifest_package(self):
        repo, catalog, manifest, key_file = self._committed_signed_repo()
        payload = json.loads(catalog)
        payload['packages'] = [package for package in payload['packages'] if package['id'] != 'floe/test-lua']
        incomplete = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
        (repo / 'catalog.json').write_bytes(incomplete)
        (repo / 'catalog.sig').write_text(sign_catalog(incomplete, self.private) + '\n')
        with mock.patch.object(build, 'MANIFEST', manifest):
            with self.assertRaises(Exception):
                check(base=repo, public_key_path=key_file)


class ArtifactImmutabilityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_place_immutable_never_overwrites_released_bytes(self):
        target = self.root / 'packages/floe-text/1.0.0/floe-text.wasm'
        place_immutable(target, b'released', 'floe-text.wasm')
        place_immutable(target, b'released', 'floe-text.wasm')
        with self.assertRaises(RuntimeError):
            place_immutable(target, b'different', 'floe-text.wasm')

    def test_committed_artifact_must_match_pinned_digest(self):
        lua = fake_module()
        entry = next(e for e in test_manifest(lua) if e['kind'] == 'committed')
        verify_committed(entry, lua)
        with self.assertRaises(RuntimeError):
            verify_committed(entry, fake_module(b'other'))
        with self.assertRaises(RuntimeError):
            verify_committed(entry, b'not-wasm')
        with self.assertRaises(RuntimeError):
            verify_committed(dict(entry, sha256=None), lua)

    def test_assembled_output_cannot_replace_a_committed_artifact(self):
        repo = self.root / 'checkout'
        entry = test_manifest(fake_module())[0]
        released = fake_module(b'released')
        committed = repo / entry['path']
        committed.parent.mkdir(parents=True)
        committed.write_bytes(released)
        output = self.root / 'output'
        with mock.patch.object(build, 'ROOT', repo):
            with mock.patch.object(build, 'MANIFEST', test_manifest(fake_module())):
                with self.assertRaises(RuntimeError):
                    artifact_bytes(entry, output, assembler=lambda source, destination: destination.write_bytes(fake_module(b'changed')))


class CatalogBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.private = Ed25519PrivateKey.generate()
        self.public = self.private.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)

    def tearDown(self):
        self.temporary.cleanup()

    def _build(self, output, test_key, revision=REVISION):
        lua = fake_module()
        repo = self.root / 'checkout'
        (repo / 'packages/floe-lua/5.4.8').mkdir(parents=True, exist_ok=True)
        (repo / 'packages/floe-lua/5.4.8/lua.wasm').write_bytes(lua)
        manifest = test_manifest(lua)
        assembler = lambda source, destination: destination.write_bytes(fake_module(b'text'))
        with mock.patch.object(build, 'ROOT', repo), mock.patch.object(build, 'MANIFEST', manifest):
            return build_catalog(output, test_key=test_key, revision=revision, assembler=assembler)

    def test_test_key_build_writes_a_self_verifying_catalog(self):
        output = self.root / 'output'
        result = self._build(output, test_key=True)
        catalog = (output / 'catalog.json').read_bytes()
        self.assertEqual(catalog, result['catalog'])
        verify_catalog(catalog, (output / 'catalog.sig').read_text().strip(), result['publicKey'])
        packages = result['payload']['packages']
        self.assertEqual([package['command'] for package in packages], ['floe-text', 'floe-lua'])
        lua = next(package for package in packages if package['id'] == 'floe/test-lua')
        self.assertEqual(lua['sha256'], hashlib.sha256(fake_module()).hexdigest())
        self.assertIn(f'/{REVISION}/capability-hub/packages/floe-lua/5.4.8/lua.wasm', lua['url'])

    def test_official_build_requires_revision_and_key(self):
        output = self.root / 'official'
        with mock.patch.dict('os.environ', {'FLOE_CAPABILITY_REVISION': ''}, clear=False):
            with self.assertRaises(RuntimeError):
                self._build(output, test_key=False, revision=None)
        with mock.patch.dict('os.environ', {'FLOE_CAPABILITY_REVISION': REVISION,
                                            'FLOE_SKILL_HUB_SIGNING_KEY': ''}, clear=False):
            with self.assertRaises(RuntimeError):
                self._build(output, test_key=False)

    def test_official_build_rejects_a_foreign_signing_identity(self):
        output = self.root / 'foreign'
        key_file = self.root / 'public-key.json'
        key_file.write_text(json.dumps({'publicKey': base64.b64encode(self.public).decode()}))
        other = base64.b64encode(Ed25519PrivateKey.generate().private_bytes(
            serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
            serialization.NoEncryption())).decode()
        with mock.patch.dict('os.environ', {'FLOE_CAPABILITY_REVISION': REVISION,
                                            'FLOE_SKILL_HUB_SIGNING_KEY': other}, clear=False):
            with mock.patch.object(build, 'PUBLIC_KEY', key_file):
                with self.assertRaises(RuntimeError):
                    self._build(output, test_key=False)

    def test_official_build_rejects_mutable_revisions(self):
        output = self.root / 'mutable'
        for revision in ('main', '', 'b' * 39, 'z' * 40):
            with mock.patch.dict('os.environ', {'FLOE_CAPABILITY_REVISION': revision,
                                                'FLOE_SKILL_HUB_SIGNING_KEY': ''}, clear=False):
                with self.assertRaises(RuntimeError):
                    self._build(output, test_key=False, revision=None)
        # The temporary test-key path still allows a placeholder revision.
        result = self._build(output, test_key=True, revision='main')
        self.assertIn('/main/capability-hub/', result['payload']['packages'][0]['url'])


if __name__ == '__main__':
    unittest.main()
