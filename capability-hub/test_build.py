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
import stage_artifact
from build import (MANIFEST, CANDIDATES, catalog_payload, check, place_immutable,
                   artifact_bytes, build as build_catalog, entry_limits, sign_catalog,
                   status as catalog_status, validate_candidates, verify_catalog,
                   verify_committed)
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


def candidate_fixture():
    """A synthetic compilepending candidate for the still-supported mechanism."""
    return {
        'id': 'floe/next',
        'command': 'floe-next',
        'version': '1.0.0',
        'minimumAppVersion': '1.7.0',
        'status': 'compilepending',
        'artifactPath': 'packages/floe-next/1.0.0/next.wasm',
        'limits': {
            'moduleMaxBytes': 32 * 1024 * 1024,
            'memoryMaxBytes': 256 * 1024 * 1024,
            'defaultTimeoutSeconds': 120,
        },
        'source': {
            'kind': 'wasi-source-build',
            'url': 'https://example.invalid/next.tar.gz',
            'sha256': 'a' * 64,
            'license': 'MIT',
            'provenance': 'FloeAgent/ThirdParty/Next/runtime.lock.json',
        },
        'artifactGates': ['qualification run passes before promotion'],
    }


class CandidateLanguageTests(unittest.TestCase):
    """Candidates are visible, pinned, and never signed until promoted."""

    def test_candidates_are_compilepending_and_disjoint_from_released(self):
        for candidate in validate_candidates(candidates=(candidate_fixture(),)):
            self.assertEqual(candidate['status'], 'compilepending')
            self.assertRegex(candidate['command'], r'^floe-[a-z0-9][a-z0-9-]{0,63}$')
            self.assertRegex(candidate['id'], r'^floe/[a-z0-9][a-z0-9-]{0,63}$')
            self.assertRegex(candidate['version'], r'^[0-9]+[.][0-9]+[.][0-9]+$')
            self.assertTrue(candidate['artifactGates'])
            limits = entry_limits(candidate)
            self.assertIsNotNone(limits)
            self.assertLessEqual(limits['moduleMaxBytes'], build.LIMIT_RANGES['moduleMaxBytes'][1])
            self.assertRegex(candidate['artifactPath'], r'^packages/[a-z0-9-]+/[0-9.]+/[a-z0-9-]+[.]wasm$')

    def test_promoted_interpreters_pin_real_source_and_artifact_digests(self):
        """Ruby and PHP are released: their promoted entries must pin the real
        upstream source and the exact staged module bytes."""
        by_id = {entry['id']: entry for entry in MANIFEST}
        ruby = by_id['floe/ruby']
        self.assertEqual(ruby['kind'], 'committed')
        self.assertEqual(ruby['path'], 'packages/floe-ruby/3.4.1/ruby.wasm')
        self.assertEqual(ruby['sha256'],
                         '348305ee0b4e4cdb84ec169223e33721899548577a42a421725b71e481afff11')
        self.assertEqual(ruby['sizeBytes'], 34719962)
        staged_ruby = build.ROOT / ruby['path']
        self.assertTrue(staged_ruby.exists())
        self.assertEqual(hashlib.sha256(staged_ruby.read_bytes()).hexdigest(), ruby['sha256'])
        php = by_id['floe/php']
        self.assertEqual(php['kind'], 'committed')
        self.assertEqual(php['path'], 'packages/floe-php/8.2.33/php.wasm')
        self.assertEqual(php['sha256'],
                         'c76afbdaa0d9e20779211c85eaf5cbd408eed4a71700908203a52fa860dcc73f')
        self.assertEqual(php['sizeBytes'], 4077894)
        staged_php = build.ROOT / php['path']
        self.assertTrue(staged_php.exists())
        self.assertEqual(hashlib.sha256(staged_php.read_bytes()).hexdigest(), php['sha256'])
        # Released entries do not carry the candidate source metadata; the
        # pinned upstream chain stays in the ThirdParty lock files.
        php_lock = json.loads((build.ROOT.parent /
                               'FloeAgent/ThirdParty/PHPWASI/runtime.lock.json').read_text())
        self.assertEqual(php_lock['version'], php['version'])
        self.assertEqual(php_lock['source']['sha256'],
                         '9a525d4db1237ede408e454b46f5a93b9e45d83d71753592e3f921903d917e07')
        self.assertIn(php_lock['version'], php_lock['source']['url'])
        self.assertEqual(php_lock['wasiSdk']['sha256'],
                         '7030139d495a19fbeccb9449150c2b1531e15d8fb74419872a719a7580aad0f9')
        ruby_lock = json.loads((build.ROOT.parent /
                                'FloeAgent/ThirdParty/RubyWASI/runtime.lock.json').read_text())
        self.assertEqual(ruby_lock['version'], ruby['version'])
        self.assertIn('ruby-3.4-wasm32-unknown-wasip1-full', ruby_lock['asset']['url'])
        self.assertEqual(ruby_lock['asset']['memberSha256'], ruby['sha256'])
        self.assertEqual(ruby_lock['asset']['memberSizeBytes'], ruby['sizeBytes'])

    def test_ready_status_is_rejected_for_a_candidate(self):
        broken = (dict(candidate_fixture(), status='ready'),)
        with self.assertRaises(RuntimeError):
            validate_candidates(candidates=broken)

    def test_candidate_colliding_with_a_released_package_is_rejected(self):
        broken = (dict(candidate_fixture(), id='floe/lua'),)
        with self.assertRaises(RuntimeError):
            validate_candidates(candidates=broken)

    def test_candidate_requires_explicit_reviewed_limits(self):
        broken = (dict(candidate_fixture(), limits={}),)
        with self.assertRaises(RuntimeError):
            validate_candidates(candidates=broken)
        broken = (dict(candidate_fixture(), limits={'moduleMaxBytes': 2 * 1024 * 1024 * 1024}),)
        with self.assertRaises(RuntimeError):
            validate_candidates(candidates=broken)

    def test_status_reports_ready_and_pending_without_writing(self):
        rows = catalog_status(base=build.ROOT)
        ready = [row for row in rows if row[0] == 'ready']
        self.assertEqual({row[1] for row in ready}, {entry['id'] for entry in MANIFEST})
        pending = [row for row in rows if row[0] == 'compilepending']
        self.assertEqual({row[1] for row in pending}, {candidate['id'] for candidate in CANDIDATES})

    def test_committed_signed_catalog_matches_the_released_manifest(self):
        """The committed catalog must match MANIFEST and never carry a candidate.

        A reviewed promotion leaves the committed catalog stale until
        capability-hub.yml signs again; that transitional state is the only
        accepted exception, and the signing job's build.py --check is the gate.
        """
        try:
            payload = check()
        except RuntimeError as error:
            self.assertIn('missing manifest packages', str(error))
            return
        signed_ids = {package['id'] for package in payload['packages']}
        for candidate in CANDIDATES:
            self.assertNotIn(candidate['id'], signed_ids)
        self.assertEqual(signed_ids, {entry['id'] for entry in MANIFEST})

    def test_catalog_payload_carries_declared_limits_only(self):
        artifacts = {entry['id']: fake_module(entry['id'].encode()) for entry in MANIFEST}
        payload = catalog_payload(artifacts, REVISION)
        for package in payload['packages']:
            entry = next(item for item in MANIFEST if item['id'] == package['id'])
            limits = entry_limits(entry) or {}
            self.assertEqual(package.get('moduleMaxBytes'), limits.get('moduleMaxBytes'))
            self.assertEqual(package.get('defaultTimeoutSeconds'), limits.get('defaultTimeoutSeconds'))


class StageArtifactTests(unittest.TestCase):
    """Staging records immutable bytes; promotion and signing stay separate."""

    CANDIDATE = {
        'id': 'floe/testlang',
        'command': 'floe-testlang',
        'version': '1.0.0',
        'minimumAppVersion': '1.7.1',
        'status': 'compilepending',
        'artifactPath': 'packages/floe-testlang/1.0.0/testlang.wasm',
        'limits': {'moduleMaxBytes': 4 * 1024 * 1024, 'memoryMaxBytes': 64 * 1024 * 1024,
                   'defaultTimeoutSeconds': 60},
        'source': {
            'kind': 'upstream-release',
            'url': 'https://example.invalid/testlang.tar.gz',
            'sha256': 'f' * 64,
            'memberSha256': hashlib.sha256(fake_module(b'testlang')).hexdigest(),
            'license': 'MIT',
            'provenance': 'FloeAgent/ThirdParty/TestLang/runtime.lock.json',
        },
        'artifactGates': ['test gate'],
    }

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.artifact = self.root / 'testlang.wasm'

    def tearDown(self):
        self.temporary.cleanup()

    def _stage(self, candidate=None, artifact=None):
        candidate = candidate or self.CANDIDATE
        artifact = artifact or self.artifact
        with mock.patch.object(build, 'CANDIDATES', (candidate,)):
            return stage_artifact.stage(candidate['id'], artifact, base=self.root)

    def test_stage_writes_immutable_artifact_and_record_only(self):
        self.artifact.write_bytes(fake_module(b'testlang'))
        record = self._stage()
        staged = self.root / self.CANDIDATE['artifactPath']
        self.assertEqual(staged.read_bytes(), fake_module(b'testlang'))
        self.assertEqual(record['artifactSha256'], hashlib.sha256(fake_module(b'testlang')).hexdigest())
        self.assertEqual(record['status'], 'compilepending')
        self.assertFalse((self.root / 'catalog.json').exists())
        self.assertFalse((self.root / 'catalog.sig').exists())
        record_path = self.root / 'candidates/floe-testlang.json'
        self.assertTrue(record_path.exists())
        self.assertEqual(json.loads(record_path.read_text())['id'], 'floe/testlang')

    def test_stage_refuses_different_bytes_at_the_same_path(self):
        self.artifact.write_bytes(fake_module(b'testlang'))
        self._stage()
        self.artifact.write_bytes(fake_module(b'other'))
        with self.assertRaises(RuntimeError):
            self._stage()

    def test_stage_refuses_a_wrong_member_digest_or_non_wasm_bytes(self):
        self.artifact.write_bytes(fake_module(b'other'))
        with self.assertRaises(RuntimeError):
            self._stage()
        self.artifact.write_bytes(b'not-wasm')
        with self.assertRaises(RuntimeError):
            self._stage()

    def test_stage_refuses_a_payload_over_the_declared_limit(self):
        oversize = dict(self.CANDIDATE, limits={'moduleMaxBytes': 1024 * 1024, 'memoryMaxBytes': 64 * 1024 * 1024,
                                                'defaultTimeoutSeconds': 60})
        self.artifact.write_bytes(WASM_MAGIC + b'x' * (2 * 1024 * 1024))
        with mock.patch.object(build, 'CANDIDATES', (oversize,)):
            with self.assertRaises(RuntimeError):
                stage_artifact.stage('floe/testlang', self.artifact, base=self.root)

    def test_stage_accepts_a_sapi_variant_filename(self):
        self.artifact.write_bytes(fake_module(b'testlang'))
        variant = self.root / 'testlang-cgi.wasm'
        variant.write_bytes(fake_module(b'testlang'))
        with mock.patch.object(build, 'CANDIDATES', (self.CANDIDATE,)):
            record = stage_artifact.stage('floe/testlang', variant, base=self.root)
        self.assertEqual(record['artifactPath'], 'packages/floe-testlang/1.0.0/testlang-cgi.wasm')
        self.assertTrue((self.root / record['artifactPath']).exists())

    def test_stage_rejects_a_filename_outside_the_command(self):
        self.artifact.write_bytes(fake_module(b'testlang'))
        wrong = self.root / 'other.wasm'
        wrong.write_bytes(fake_module(b'testlang'))
        with mock.patch.object(build, 'CANDIDATES', (self.CANDIDATE,)):
            with self.assertRaises(RuntimeError):
                stage_artifact.stage('floe/testlang', wrong, base=self.root)

    def test_stage_records_evidence_digests(self):
        self.artifact.write_bytes(fake_module(b'testlang'))
        evidence = self.root / 'evidence'
        evidence.mkdir()
        (evidence / 'build.log').write_text('ok\n')
        with mock.patch.object(build, 'CANDIDATES', (self.CANDIDATE,)):
            record = stage_artifact.stage('floe/testlang', self.artifact, evidence=evidence, base=self.root)
        self.assertEqual(record['evidence'],
                         {'build.log': hashlib.sha256(b'ok\n').hexdigest()})


if __name__ == '__main__':
    unittest.main()
