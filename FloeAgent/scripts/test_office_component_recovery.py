#!/usr/bin/env python3
"""Contract tests for durable Office component recovery (no build, no network).

The public component release carries only the exact host archive, its
checksum, source-bound descriptor and Office licensing.  The matching dSYM is
private: tests prove the public allowlist rejects symbol/signing payloads, the
descriptor retains the actual private digest/UUID binding, and metadata alone
can never be presented as verified signing evidence.  Publication read-back
uses the canonical GitHub REST JSON schema.

Fixtures are tiny synthetic hosts.  Network calls are replaced only at the
``gh release download`` command boundary; helper runners copy local fixtures.
"""
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))

import office_component_recovery as recovery  # noqa: E402
import pin_office_host_artifact as pin_tool  # noqa: E402

EXECUTABLE_UUID = '11111111-2222-3333-4444-555555555555'
WRONG_UUID = '99999999-8888-7777-6666-555555555555'
ENGINE_COMMIT = 'b' * 40
PRODUCER_COMMIT = 'd' * 40
OVERLAY = 'c' * 64


def macho_bytes(uuid_text=EXECUTABLE_UUID):
    compact = bytes.fromhex(uuid_text.replace('-', ''))
    header = struct.pack('<IIIIIIII', 0xfeedfacf, 0x0100000c, 0, 6, 1, 24, 0, 0)
    return header + struct.pack('<II', 0x1b, 24) + compact


def fat_macho_bytes(uuid_text=EXECUTABLE_UUID):
    thin = macho_bytes(uuid_text)
    header = (struct.pack('>II', 0xcafebabe, 1) +
              struct.pack('>IIIII', 0x0100000c, 0, 4096, len(thin), 0))
    return header + b'\0' * (4096 - len(header)) + thin


def release_runner_from(directory):
    def run(argv, check=True, timeout=None):
        pattern = argv[argv.index('--pattern') + 1]
        output = Path(argv[argv.index('--output') + 1])
        source = Path(directory) / pattern
        if not source.is_file():
            raise subprocess.CalledProcessError(1, argv)
        shutil.copyfile(source, output)
    return run


class ComponentFixture:
    """A self-consistent host, pin, lock, public release and private dSYM."""

    def __init__(self, root):
        self.root = Path(root)
        self.host = self.root / 'OfficeNativeHost'
        executable = self.host / 'FloeOfficeNative.framework/FloeOfficeNative'
        executable.parent.mkdir(parents=True)
        for relative in ('Headers/FloeOfficeNative.h', 'Modules/module.modulemap', 'Info.plist'):
            path = executable.parent / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('framework ' + relative)
        executable.write_bytes(macho_bytes())
        resources = self.host / 'OfficeRuntimeResources'
        resources.mkdir(parents=True)
        (resources / 'cool.html').write_text('editor fixture')
        (resources / 'config').mkdir()
        # The producer verifies the artifact against the real tracked host
        # sources, so the fixture must use those exact hashes.
        sources = pin_tool.source_hashes()
        self.sources = sources
        manifest = {
            'sourceCommit': ENGINE_COMMIT,
            'overlaySHA256': OVERLAY,
            'sdk': 'iphoneos',
            'arch': 'arm64',
            'hostCompilePassed': True,
            'hostLinkPassed': True,
            'swiftModuleImportPassed': True,
            'hostSourceSHA256': sources,
            'runtimeResourceSHA256': {'cool.html': recovery.digest(resources / 'cool.html')},
            'runtimeResourceDirectories': ['config'],
            'capabilityQualification': {
                'embeddedEditorPassed': False,
                'pptxVisibleRenderPassed': False,
                'deviceRoundtripPassed': False,
                'originalFileWritebackPassed': False,
            },
        }
        (self.host / 'native-host.json').write_text(json.dumps(manifest))
        self.manifest = manifest
        self.archive = self.root / recovery.HOST_ASSET
        with zipfile.ZipFile(self.archive, 'w') as archive:
            for path in sorted(self.host.rglob('*')):
                archive.write(path, str(path.relative_to(self.root)))
        self.pin = {
            'runID': '123',
            'workflowCommit': PRODUCER_COMMIT,
            'artifactName': 'office-native-host-unsigned',
            'artifactID': 77,
            'archiveSHA256': recovery.digest(self.archive),
            'manifestSHA256': recovery.digest(self.host / 'native-host.json'),
            'executableSHA256': recovery.digest(
                self.host / 'FloeOfficeNative.framework/FloeOfficeNative'),
            'frameworkAuxiliarySHA256': {
                str(path.relative_to(self.host / 'FloeOfficeNative.framework')):
                    recovery.digest(path)
                for path in sorted((self.host / 'FloeOfficeNative.framework').rglob('*'))
                if path.is_file() and path.name != 'FloeOfficeNative'
            },
            'hostSourceSHA256': sources,
            'overlaySHA256': OVERLAY,
        }
        self.pin['localStorageArtifact'] = {
            'kind': 'office-local-host-artifact-storage',
            'runID': '123',
            'workflowCommit': PRODUCER_COMMIT,
            'artifactName': 'office-native-host-unsigned',
            'artifactID': 77,
            'archiveSHA256': self.pin['archiveSHA256'],
            'nativeProducer': 'local-device-host-build',
        }
        self.lock = self.root / 'engine.lock.json'
        self.lock.write_text(json.dumps({
            'commit': ENGINE_COMMIT,
            'embeddingOverlay': {'sha256': OVERLAY},
            'qualifiedHostArtifact': self.pin,
        }, indent=2))
        self.symbols_source = self.root / 'Symbols' / recovery.SYMBOLS_ROOT
        dwarf = self.symbols_source / 'Contents/Resources/DWARF/FloeOfficeNative'
        dwarf.parent.mkdir(parents=True)
        dwarf.write_bytes(macho_bytes())
        self.licenses_source = self.root / 'licenses' / recovery.LICENSES_ROOT
        self.licenses_source.mkdir(parents=True)
        for name in ('LICENSE', 'COPYING.MPL', 'NOTICE', 'THIRDPARTYLICENSES'):
            (self.licenses_source / name).write_text('license ' + name)
        # The public release has no dSYM.  The private output does.
        self.release = self.root / 'release'
        self.release.mkdir()
        self.private = self.root / 'private'
        self.private.mkdir()
        shutil.copyfile(self.archive, self.release / recovery.HOST_ASSET)
        self.private_symbols = recovery.write_deterministic_zip(
            self.symbols_source, self.private / recovery.SYMBOLS_ASSET,
            recovery.SYMBOLS_ROOT)
        recovery.write_deterministic_zip(
            self.licenses_source, self.release / recovery.LICENSES_ASSET,
            recovery.LICENSES_ROOT)
        self.symbols = recovery.inspect_symbol_archive(self.private_symbols)
        self.licenses = recovery.inspect_license_archive(
            self.release / recovery.LICENSES_ASSET)
        self.write_descriptor()

    def hashes(self):
        return {'manifestSHA256': self.pin['manifestSHA256'],
                'executableSHA256': self.pin['executableSHA256']}

    def write_descriptor(self, descriptor=None):
        lock = json.loads(self.lock.read_text())
        descriptor = descriptor or recovery.build_descriptor(
            lock, self.manifest, self.hashes(), self.release / recovery.HOST_ASSET,
            claims=recovery.required_claims(lock, self.pin),
            transport=recovery.expected_transport(self.pin),
            symbols=self.symbols, symbols_archive=self.private_symbols,
            licenses=self.licenses)
        (self.release / recovery.DESCRIPTOR_ASSET).write_text(
            json.dumps(descriptor, indent=2, sort_keys=True) + '\n')
        (self.release / recovery.HOST_SIDECAR).write_text(
            f"{descriptor['archive']['sha256']}  {recovery.HOST_ASSET}\n")
        return descriptor

    def publication_payloads(self):
        descriptor = json.loads(
            (self.release / recovery.DESCRIPTOR_ASSET).read_text())
        assets = []
        for name in recovery.PUBLIC_ASSETS:
            local = self.release / name
            assets.append({
                'name': name,
                'size': local.stat().st_size,
                'digest': 'sha256:' + recovery.digest(local),
                'state': 'uploaded',
            })
        release = {
            'id': 9001,
            'tag_name': descriptor['tag'],
            'draft': False,
            'prerelease': False,
            'published_at': '2026-10-21T12:00:00Z',
            'html_url': f"https://github.com/{recovery.DEFAULT_REPOSITORY}/releases/tag/{descriptor['tag']}",
            'assets': assets,
        }
        tag_ref = {
            'ref': f"refs/tags/{descriptor['tag']}",
            'object': {'type': 'commit', 'sha': PRODUCER_COMMIT},
        }
        latest = {'tag_name': 'v1.7.43'}
        feed = {'apps': [{'versions': [{'buildVersion': '284',
                                       'downloadURL': 'https://github.com/'
                                                      f'{recovery.DEFAULT_REPOSITORY}/releases/download/'
                                                      'v1.7.43/Floe-Agent-1.7.43-build284-unsigned.ipa'}]}]}
        return descriptor, release, tag_ref, latest, feed


class OfficeComponentRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fixture = ComponentFixture(self.root)
        self.lock = json.loads(self.fixture.lock.read_text())
        self.pin = self.lock['qualifiedHostArtifact']

    def test_existing_pin_without_component_block_derives_the_durable_tag(self):
        contract = recovery.expected_contract(self.lock, self.pin)
        self.assertEqual(contract['tag'], recovery.component_tag(self.pin['archiveSHA256']))
        self.assertEqual(contract['repository'], recovery.DEFAULT_REPOSITORY)
        summary = recovery.verify_component_directory(
            self.fixture.release, self.lock, self.pin)
        self.assertEqual(summary['archiveSHA256'], self.pin['archiveSHA256'])
        self.assertEqual(summary['executableUUID'], EXECUTABLE_UUID)
        self.assertFalse(summary['symbolsVerified'])
        self.assertEqual(summary['symbolsVisibility'], 'private')
        self.assertEqual(summary['publicAssets'], sorted(recovery.PUBLIC_ASSETS))
        qualified = recovery.verify_component_directory(
            self.fixture.release, self.lock, self.pin,
            private_symbols=self.fixture.private_symbols)
        self.assertTrue(qualified['symbolsVerified'])

    def test_tag_requires_the_pinned_archive_hash(self):
        self.assertEqual(recovery.component_tag(self.pin['archiveSHA256']),
                         recovery.TAG_PREFIX + self.pin['archiveSHA256'])
        for value in ('', 'a' * 63, 'g' * 64, None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                recovery.component_tag(value)

    def test_wrong_source_commit_or_manifest_hash_is_rejected(self):
        descriptor = json.loads(
            (self.fixture.release / recovery.DESCRIPTOR_ASSET).read_text())
        descriptor['sourceCommit'] = 'e' * 40
        self.fixture.write_descriptor(descriptor)
        with self.assertRaisesRegex(ValueError, 'source commit'):
            recovery.verify_component_directory(
                self.fixture.release, self.lock, self.pin)
        descriptor = json.loads(
            (self.fixture.release / recovery.DESCRIPTOR_ASSET).read_text())
        descriptor['manifest']['sha256'] = 'e' * 64
        self.fixture.write_descriptor(descriptor)
        with self.assertRaisesRegex(ValueError, 'manifest hash'):
            recovery.verify_component_directory(
                self.fixture.release, self.lock, self.pin)

    def test_wrong_claim_or_transport_identity_is_rejected(self):
        descriptor = json.loads(
            (self.fixture.release / recovery.DESCRIPTOR_ASSET).read_text())
        descriptor['claims']['overlaySHA256'] = 'e' * 64
        self.fixture.write_descriptor(descriptor)
        with self.assertRaisesRegex(ValueError, 'source claims'):
            recovery.verify_component_directory(
                self.fixture.release, self.lock, self.pin)
        descriptor = json.loads(
            (self.fixture.release / recovery.DESCRIPTOR_ASSET).read_text())
        descriptor['claims'] = recovery.required_claims(self.lock, self.pin)
        descriptor['transport']['runID'] = '999'
        self.fixture.write_descriptor(descriptor)
        with self.assertRaisesRegex(ValueError, 'transport identity'):
            recovery.verify_component_directory(
                self.fixture.release, self.lock, self.pin)

    def test_symbol_uuid_must_match_the_host_executable(self):
        descriptor = json.loads(
            (self.fixture.release / recovery.DESCRIPTOR_ASSET).read_text())
        descriptor['symbols']['executableUUID'] = WRONG_UUID
        self.fixture.write_descriptor(descriptor)
        with self.assertRaisesRegex(ValueError, 'UUID differs|dSYM binding'):
            recovery.verify_component_directory(
                self.fixture.release, self.lock, self.pin)

    def test_public_release_set_never_accepts_a_symbols_or_signing_asset(self):
        self.assertNotIn(recovery.SYMBOLS_ASSET, recovery.PUBLIC_ASSET_SET)
        shutil.copyfile(self.fixture.private_symbols,
                        self.fixture.release / recovery.SYMBOLS_ASSET)
        with self.assertRaisesRegex(ValueError, 'asset set|private symbol'):
            recovery.verify_component_directory(
                self.fixture.release, self.lock, self.pin)
        (self.fixture.release / recovery.SYMBOLS_ASSET).unlink()
        for name in ('FloeOfficeNative.framework.dSYM.zip', 'symbols.zip',
                     'App.dSYM/Contents/Resources/DWARF/App',
                     'embedded.mobileprovision', 'signing.p12',
                     'unsigned.ipa', 'build.xcarchive', 'Flutter.bcsymbolmap',
                     'App.app/_CodeSignature/CodeResources', 'App.provisionprofile'):
            with self.subTest(name=name):
                self.assertTrue(recovery.private_material_failures(
                    [name], 'the public component release'))
        self.assertFalse(recovery.private_material_failures(
            ['OfficeRuntimeResources/images/lc_symbolshapes.moon.svg'],
            'the public component release'))

    def test_nested_private_payload_in_a_public_archive_is_rejected(self):
        nested = self.root / 'nested.zip'
        with zipfile.ZipFile(nested, 'w') as archive:
            archive.writestr('OfficeNativeHost/OfficeRuntimeResources/cool.html', b'ok')
            archive.writestr('OfficeNativeHost/FloeOfficeNative.framework.dSYM/'
                             'Contents/Resources/DWARF/FloeOfficeNative', b'dwarf')
        with self.assertRaisesRegex(ValueError, 'private symbol'):
            recovery.inspect_public_archive(nested, 'the component host archive')
        signing = self.root / 'signing.zip'
        with zipfile.ZipFile(signing, 'w') as archive:
            archive.writestr('OfficeEngine/LICENSE', b'ok')
            archive.writestr('OfficeEngine/embedded.mobileprovision', b'profile')
        with self.assertRaisesRegex(ValueError, 'private symbol'):
            recovery.inspect_public_archive(signing, 'the component licensing archive')

    def test_actual_private_symbols_are_required_for_qualification(self):
        with self.assertRaisesRegex(ValueError, 'actual qualified private dSYM'):
            recovery.verify_self_contained(
                self.fixture.release, lock=self.lock, pin=self.pin)
        wrong = self.root / 'wrong-private.zip'
        wrong_dir = self.root / 'wrong-symbols/FloeOfficeNative.framework.dSYM'
        dwarf = wrong_dir / 'Contents/Resources/DWARF/FloeOfficeNative'
        dwarf.parent.mkdir(parents=True)
        dwarf.write_bytes(macho_bytes(WRONG_UUID))
        recovery.write_deterministic_zip(wrong_dir, wrong, recovery.SYMBOLS_ROOT)
        with self.assertRaisesRegex(ValueError, 'size differs|digest differs'):
            recovery.verify_self_contained(
                self.fixture.release, private_symbols=wrong,
                lock=self.lock, pin=self.pin)
        summary = recovery.verify_self_contained(
            self.fixture.release, private_symbols=self.fixture.private_symbols,
            lock=self.lock, pin=self.pin)
        self.assertTrue(summary['symbolsVerified'])
        self.assertEqual(summary['executableUUID'], EXECUTABLE_UUID)

    def test_private_symbols_must_match_digest_size_and_uuid(self):
        descriptor = json.loads(
            (self.fixture.release / recovery.DESCRIPTOR_ASSET).read_text())
        wrong = self.root / 'private-wrong-bytes.zip'
        wrong.write_bytes(b'not the recorded archive')
        with self.assertRaisesRegex(ValueError, 'size differs|digest differs'):
            recovery.verify_private_symbols(wrong, descriptor)
        missing = self.root / 'missing-symbols.zip'
        with self.assertRaisesRegex(ValueError, 'actual qualified private dSYM'):
            recovery.verify_private_symbols(missing, descriptor)
        descriptor['symbols']['visibility'] = 'public'
        with self.assertRaisesRegex(ValueError, 'not marked private'):
            recovery.verify_private_symbols(self.fixture.private_symbols, descriptor)

    def test_license_archive_requires_the_office_license_set(self):
        missing = self.root / 'missing-licenses/OfficeEngine'
        missing.mkdir(parents=True)
        (missing / 'LICENSE').write_text('only one')
        archive = self.root / 'missing-licenses.zip'
        recovery.write_deterministic_zip(missing, archive, recovery.LICENSES_ROOT)
        with self.assertRaisesRegex(ValueError, 'omits'):
            recovery.inspect_license_archive(archive)

    def test_archive_or_sidecar_mismatch_is_rejected(self):
        (self.fixture.release / recovery.HOST_ASSET).write_bytes(b'other bytes')
        with self.assertRaisesRegex(ValueError, 'archive (size|checksum)'):
            recovery.verify_component_directory(
                self.fixture.release, self.lock, self.pin)
        shutil.copyfile(self.fixture.archive,
                        self.fixture.release / recovery.HOST_ASSET)
        (self.fixture.release / recovery.HOST_SIDECAR).write_text(
            f"{'e' * 64}  {recovery.HOST_ASSET}\n")
        with self.assertRaisesRegex(ValueError, 'sidecar'):
            recovery.verify_component_directory(
                self.fixture.release, self.lock, self.pin)

    def test_extra_or_aliased_release_file_is_rejected(self):
        extra = self.fixture.release / 'unexpected.bin'
        extra.write_text('extra')
        with self.assertRaisesRegex(ValueError, 'asset set'):
            recovery.verify_component_directory(
                self.fixture.release, self.lock, self.pin)
        extra.unlink()
        os.symlink(self.fixture.archive, self.fixture.release / 'alias')
        with self.assertRaisesRegex(ValueError, 'alias'):
            recovery.verify_component_directory(
                self.fixture.release, self.lock, self.pin)

    def test_pin_component_release_hashes_are_enforced(self):
        self.pin['componentRelease'] = {
            'schema': recovery.SCHEMA,
            'repository': recovery.DEFAULT_REPOSITORY,
            'tag': recovery.component_tag(self.pin['archiveSHA256']),
            'archiveSHA256': self.pin['archiveSHA256'],
            'descriptorSHA256': 'e' * 64,
            'symbolsSHA256': self.fixture.symbols['sha256'],
        }
        self.fixture.lock.write_text(json.dumps(self.lock))
        with self.assertRaisesRegex(ValueError, 'descriptor hash'):
            recovery.verify_component_directory(
                self.fixture.release, json.loads(self.fixture.lock.read_text()),
                json.loads(self.fixture.lock.read_text())['qualifiedHostArtifact'])
        self.pin['componentRelease']['descriptorSHA256'] = recovery.digest(
            self.fixture.release / recovery.DESCRIPTOR_ASSET)
        self.fixture.lock.write_text(json.dumps(self.lock))
        recovery.verify_component_directory(
            self.fixture.release, json.loads(self.fixture.lock.read_text()),
            json.loads(self.fixture.lock.read_text())['qualifiedHostArtifact'])

    def test_recover_into_stages_only_public_assets_and_cleans_partial_downloads(self):
        patterns = []

        def runner(argv, check=True, timeout=None):
            patterns.append(argv[argv.index('--pattern') + 1])
            return release_runner_from(self.fixture.release)(argv, check, timeout)

        staging = self.root / 'staging'
        archive, transport = recovery.recover_into(
            staging, self.lock, self.pin, runner=runner, attempts=1)
        self.assertEqual(recovery.digest(archive), self.pin['archiveSHA256'])
        self.assertEqual(transport['kind'], 'component-release')
        self.assertEqual(transport['executableUUID'], EXECUTABLE_UUID)
        self.assertFalse(transport['symbolsVerified'])
        self.assertEqual(transport['symbolsVisibility'], 'private')
        self.assertEqual(sorted(patterns),
                         sorted([recovery.DESCRIPTOR_ASSET, recovery.HOST_SIDECAR,
                                 recovery.HOST_ASSET, recovery.LICENSES_ASSET]))
        self.assertEqual(sorted(path.name for path in staging.iterdir()),
                         sorted([recovery.DESCRIPTOR_ASSET, recovery.HOST_ASSET,
                                 recovery.HOST_SIDECAR, recovery.LICENSES_ASSET]))
        failing = self.root / 'failing'
        with self.assertRaises(ValueError):
            recovery.recover_into(failing, self.lock, self.pin,
                                  runner=lambda argv, check=True, timeout=None:
                                  (_ for _ in ()).throw(
                                      subprocess.CalledProcessError(1, argv)),
                                  attempts=1)
        self.assertEqual(list(failing.iterdir()), [])

    def test_recovery_cancellation_removes_partial_downloads(self):
        staging = self.root / 'cancelled'
        calls = []

        def cancel():
            calls.append(True)
            if len(calls) == 2:
                raise recovery.RecoveryCancelled('cancelled by test')

        with self.assertRaises(recovery.RecoveryCancelled):
            recovery.recover_into(
                staging, self.lock, self.pin,
                runner=release_runner_from(self.fixture.release),
                cancel_check=cancel, attempts=1)
        self.assertEqual(list(staging.iterdir()), [])

    def test_wrong_release_bytes_never_verify(self):
        (self.fixture.release / recovery.HOST_ASSET).write_bytes(b'wrong bytes')
        staging = self.root / 'staging'
        with self.assertRaises(ValueError):
            recovery.recover_into(
                staging, self.lock, self.pin,
                runner=release_runner_from(self.fixture.release), attempts=1)
        self.assertEqual(list(staging.iterdir()), [])

    def test_publication_readback_uses_canonical_api_schema(self):
        descriptor, release, tag_ref, latest, feed = self.fixture.publication_payloads()
        summary = recovery.verify_publication(
            release, tag_ref, None, latest, expected_tag=descriptor['tag'],
            expected_source_commit=PRODUCER_COMMIT,
            release_dir=self.fixture.release, lock_path=self.fixture.lock,
            feed=feed, private_symbols=self.fixture.private_symbols)
        self.assertEqual(summary['tag'], descriptor['tag'])
        self.assertEqual(summary['tagStyle'], 'lightweight')
        self.assertEqual(summary['producerSourceCommit'], PRODUCER_COMMIT)
        self.assertEqual(summary['engineSourceCommit'], ENGINE_COMMIT)
        self.assertFalse(summary['feedEntry'])
        self.assertTrue(summary['symbolsVerified'])
        self.assertEqual([asset['name'] for asset in summary['assets']],
                         list(recovery.PUBLIC_ASSETS))

        annotated = {
            'ref': f"refs/tags/{descriptor['tag']}",
            'object': {'type': 'tag', 'sha': 'a' * 40},
        }
        tag_object = {'sha': 'a' * 40, 'tag': descriptor['tag'],
                      'object': {'type': 'commit', 'sha': PRODUCER_COMMIT}}
        recovery.verify_publication(
            release, annotated, tag_object, latest, expected_tag=descriptor['tag'],
            expected_source_commit=PRODUCER_COMMIT,
            release_dir=self.fixture.release, lock_path=self.fixture.lock,
            feed=feed, private_symbols=self.fixture.private_symbols)
        broken_object = dict(tag_object, tag='v9.9.9')
        with self.assertRaisesRegex(ValueError, 'different tag'):
            recovery.verify_publication(
                release, annotated, broken_object, latest, expected_tag=descriptor['tag'],
                expected_source_commit=PRODUCER_COMMIT,
                release_dir=self.fixture.release, lock_path=self.fixture.lock,
                feed=feed, private_symbols=self.fixture.private_symbols)

    def test_publication_rejects_draft_wrong_source_and_partial_assets(self):
        descriptor, release, tag_ref, latest, feed = self.fixture.publication_payloads()
        for field, value in (('draft', True), ('prerelease', True),
                             ('published_at', None)):
            broken = json.loads(json.dumps(release))
            broken[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                recovery.verify_publication(
                    broken, tag_ref, None, latest, expected_tag=descriptor['tag'],
                    expected_source_commit=PRODUCER_COMMIT,
                    release_dir=self.fixture.release, lock_path=self.fixture.lock,
                    feed=feed, private_symbols=self.fixture.private_symbols)
        wrong_ref = {'ref': f"refs/tags/{descriptor['tag']}",
                     'object': {'type': 'commit', 'sha': 'e' * 40}}
        with self.assertRaisesRegex(ValueError, 'actual producer source'):
            recovery.verify_publication(
                release, wrong_ref, None, latest, expected_tag=descriptor['tag'],
                expected_source_commit=PRODUCER_COMMIT,
                release_dir=self.fixture.release, lock_path=self.fixture.lock,
                feed=feed, private_symbols=self.fixture.private_symbols)
        extra = json.loads(json.dumps(release))
        extra['assets'].append({'name': recovery.SYMBOLS_ASSET, 'size': 10,
                                'digest': 'sha256:' + 'e' * 64, 'state': 'uploaded'})
        with self.assertRaisesRegex(ValueError, 'private symbol'):
            recovery.verify_publication(
                extra, tag_ref, None, latest, expected_tag=descriptor['tag'],
                expected_source_commit=PRODUCER_COMMIT,
                release_dir=self.fixture.release, lock_path=self.fixture.lock,
                feed=feed, private_symbols=self.fixture.private_symbols)
        missing = json.loads(json.dumps(release))
        missing['assets'] = [asset for asset in missing['assets']
                             if asset['name'] != recovery.LICENSES_ASSET]
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            recovery.verify_publication(
                missing, tag_ref, None, latest, expected_tag=descriptor['tag'],
                expected_source_commit=PRODUCER_COMMIT,
                release_dir=self.fixture.release, lock_path=self.fixture.lock,
                feed=feed, private_symbols=self.fixture.private_symbols)

    def test_publication_compares_remote_digest_and_size(self):
        descriptor, release, tag_ref, latest, feed = self.fixture.publication_payloads()
        for field, value in (('size', 1), ('digest', 'sha256:' + 'e' * 64)):
            broken = json.loads(json.dumps(release))
            broken['assets'][0][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(
                    ValueError, 'size differs|digest differs'):
                recovery.verify_publication(
                    broken, tag_ref, None, latest, expected_tag=descriptor['tag'],
                    expected_source_commit=PRODUCER_COMMIT,
                    release_dir=self.fixture.release, lock_path=self.fixture.lock,
                    feed=feed, private_symbols=self.fixture.private_symbols)

    def test_component_never_takes_latest_or_the_app_feed(self):
        descriptor, release, tag_ref, latest, feed = self.fixture.publication_payloads()
        with self.assertRaisesRegex(ValueError, 'latest pointer'):
            recovery.verify_publication(
                release, tag_ref, None, {'tag_name': descriptor['tag']},
                expected_tag=descriptor['tag'], expected_source_commit=PRODUCER_COMMIT,
                release_dir=self.fixture.release, lock_path=self.fixture.lock,
                feed=feed, private_symbols=self.fixture.private_symbols)
        with self.assertRaisesRegex(ValueError, 'latest pointer'):
            recovery.verify_publication(
                release, tag_ref, None, {'tag_name': recovery.TAG_PREFIX + '9' * 64},
                expected_tag=descriptor['tag'], expected_source_commit=PRODUCER_COMMIT,
                release_dir=self.fixture.release, lock_path=self.fixture.lock,
                feed=feed, private_symbols=self.fixture.private_symbols)
        poisonous = json.loads(json.dumps(feed))
        poisonous['apps'][0]['versions'][0]['downloadURL'] = (
            f"https://github.com/{recovery.DEFAULT_REPOSITORY}/releases/download/"
            f"{descriptor['tag']}/OfficeNativeHost.zip")
        with self.assertRaisesRegex(ValueError, 'Feather feed'):
            recovery.verify_publication(
                release, tag_ref, None, latest, expected_tag=descriptor['tag'],
                expected_source_commit=PRODUCER_COMMIT,
                release_dir=self.fixture.release, lock_path=self.fixture.lock,
                feed=poisonous, private_symbols=self.fixture.private_symbols)
        with self.assertRaisesRegex(ValueError, 'feed read-back is required'):
            recovery.verify_publication(
                release, tag_ref, None, latest, expected_tag=descriptor['tag'],
                expected_source_commit=PRODUCER_COMMIT,
                release_dir=self.fixture.release, lock_path=self.fixture.lock,
                feed=None, private_symbols=self.fixture.private_symbols)

    def test_self_contained_verification_rejects_a_foreign_executable(self):
        summary = recovery.verify_self_contained(
            self.fixture.release, private_symbols=self.fixture.private_symbols,
            lock=self.lock, pin=self.pin)
        self.assertEqual(summary['executableUUID'], EXECUTABLE_UUID)
        executable = self.fixture.host / 'FloeOfficeNative.framework/FloeOfficeNative'
        executable.write_bytes(macho_bytes(WRONG_UUID))
        with zipfile.ZipFile(self.fixture.release / recovery.HOST_ASSET, 'w') as archive:
            for path in sorted(self.fixture.host.rglob('*')):
                archive.write(path, str(path.relative_to(self.fixture.root)))
        descriptor = json.loads(
            (self.fixture.release / recovery.DESCRIPTOR_ASSET).read_text())
        descriptor['archive']['sha256'] = recovery.digest(
            self.fixture.release / recovery.HOST_ASSET)
        descriptor['archive']['bytes'] = (
            self.fixture.release / recovery.HOST_ASSET).stat().st_size
        descriptor['tag'] = recovery.component_tag(descriptor['archive']['sha256'])
        descriptor['manifest']['executableSHA256'] = recovery.digest(executable)
        self.fixture.write_descriptor(descriptor)
        # This is a structural descriptor/UUID check against the rebuilt
        # archive; the pin still names the old archive, so do not bind it here.
        with self.assertRaisesRegex(ValueError, 'UUID differs'):
            recovery.verify_self_contained(
                self.fixture.release, private_symbols=self.fixture.private_symbols)

    def test_macho_uuid_parser_handles_fat_and_rejects_truncated_input(self):
        self.assertEqual(recovery.macho_uuid_bytes(macho_bytes()), EXECUTABLE_UUID)
        fat = fat_macho_bytes()
        self.assertEqual(recovery.macho_uuid_bytes(fat + b'\0' * 4096), EXECUTABLE_UUID)
        for payload in (b'', b'\xcf\xfa\xed\xfe', macho_bytes()[:40]):
            with self.subTest(size=len(payload)), self.assertRaises(ValueError):
                recovery.macho_uuid_bytes(payload)

    def test_deterministic_asset_packaging_is_reproducible(self):
        first = self.root / 'first.zip'
        second = self.root / 'second.zip'
        recovery.write_deterministic_zip(
            self.fixture.licenses_source, first, recovery.LICENSES_ROOT)
        recovery.write_deterministic_zip(
            self.fixture.licenses_source, second, recovery.LICENSES_ROOT)
        self.assertEqual(recovery.digest(first), recovery.digest(second))
        with zipfile.ZipFile(first) as archive:
            self.assertEqual(archive.namelist(), sorted(archive.namelist()))

    def test_producer_keeps_symbols_private_and_metadata_binds_actual_archive(self):
        output = self.root / 'component'
        private = self.root / 'component-private'
        result = pin_tool.component_release_metadata(
            self.fixture.lock, self.fixture.archive, output,
            self.fixture.symbols_source, self.fixture.licenses_source, private,
            recovery.DEFAULT_REPOSITORY, 'office-native-host-unsigned')
        self.assertEqual(result, 0)
        self.assertEqual(sorted(path.name for path in output.iterdir()),
                         sorted([recovery.DESCRIPTOR_ASSET, recovery.HOST_SIDECAR,
                                 recovery.LICENSES_ASSET, 'OFFICE_COMPONENT_RELEASE.md',
                                 'pin-block.json']))
        self.assertNotIn(recovery.SYMBOLS_ASSET,
                         {path.name for path in output.iterdir()})
        private_assets = {path.name for path in private.iterdir()}
        self.assertEqual(private_assets,
                         {recovery.SYMBOLS_ASSET, recovery.PRIVATE_SYMBOLS_METADATA})
        symbols_path = private / recovery.SYMBOLS_ASSET
        descriptor = json.loads((output / recovery.DESCRIPTOR_ASSET).read_text())
        self.assertEqual(descriptor['symbols']['sha256'], recovery.digest(symbols_path))
        self.assertEqual(descriptor['symbols']['visibility'], 'private')
        self.assertEqual(descriptor['symbols']['executableUUID'], EXECUTABLE_UUID)
        self.assertEqual(descriptor['tag'],
                         recovery.component_tag(self.fixture.pin['archiveSHA256']))
        # Assemble the public publication set exactly as the workflow does.
        published = self.root / 'published'
        published.mkdir()
        shutil.copyfile(self.fixture.archive, published / recovery.HOST_ASSET)
        for name in (recovery.DESCRIPTOR_ASSET, recovery.HOST_SIDECAR,
                     recovery.LICENSES_ASSET):
            shutil.copyfile(output / name, published / name)
        pin = json.loads(self.fixture.lock.read_text())['qualifiedHostArtifact']
        pin.update(descriptor['claims'])
        pin['componentRelease'] = {
            'schema': recovery.SCHEMA,
            'repository': recovery.DEFAULT_REPOSITORY,
            'tag': descriptor['tag'],
            'archiveSHA256': descriptor['archive']['sha256'],
            'descriptorSHA256': recovery.digest(output / recovery.DESCRIPTOR_ASSET),
            'symbolsSHA256': descriptor['symbols']['sha256'],
        }
        lock = json.loads(self.fixture.lock.read_text())
        lock['qualifiedHostArtifact'] = pin
        summary = recovery.verify_self_contained(
            published, private_symbols=symbols_path, lock=lock, pin=pin)
        self.assertTrue(summary['symbolsVerified'])
        self.assertEqual(summary['publicAssets'], sorted(recovery.PUBLIC_ASSETS))

    def test_private_symbols_output_must_be_outside_the_public_directory(self):
        with self.assertRaisesRegex(ValueError, 'separate directory'):
            pin_tool.component_release_metadata(
                self.fixture.lock, self.fixture.archive,
                self.root / 'public-component', self.fixture.symbols_source,
                self.fixture.licenses_source,
                self.root / 'public-component/private',
                recovery.DEFAULT_REPOSITORY, 'office-native-host-unsigned')


if __name__ == '__main__':
    unittest.main()
