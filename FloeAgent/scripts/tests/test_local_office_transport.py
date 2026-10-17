#!/usr/bin/env python3
"""Synthetic byte/contract fixtures only; not Office compile or render proof."""
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import validate_local_office_transport as transport
from office_release_gates import false_capabilities


class LocalOfficeTransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repo'
        self.base = self.repo / 'FloeAgent/ThirdParty/Collabora'
        self.base.mkdir(parents=True)
        self.host = self.root / 'OfficeNativeHost'
        self.framework = self.host / 'FloeOfficeNative.framework'
        self.framework.mkdir(parents=True)
        sources = self.base / 'FloeOfficeNative'
        sources.mkdir()
        for name in ('FloeOfficeNative.h', 'FloeOfficeNative.mm', 'FloeOfficeAttachment.cpp', 'FloeOfficeAttachment.hxx'):
            (sources / name).write_text('synthetic source ' + name)
        self.sources = {p.name: transport.pinning.digest(p) for p in sources.iterdir()}
        # Tiny structural Mach-O fixture: never executed or claimed as a real
        # compiled Office binary. Tests prove validator boundaries only.
        self.binary = struct.pack('<IiiIIIII', 0xFEEDFACF, 0x0100000C, 0, 6, 1, 24, 0, 0)
        self.binary += struct.pack('<IIIIII', 0x32, 24, 2, 0x1A0000, 0x1B0000, 0)
        (self.framework / 'FloeOfficeNative').write_bytes(self.binary)
        (self.framework / 'Headers').mkdir()
        (self.framework / 'Headers/FloeOfficeNative.h').write_bytes((sources / 'FloeOfficeNative.h').read_bytes())
        (self.framework / 'Modules').mkdir()
        (self.framework / 'Modules/module.modulemap').write_text('synthetic module map')
        (self.framework / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'FloeOfficeNative', 'CFBundlePackageType': 'FMWK',
            'CFBundleSupportedPlatforms': ['iPhoneOS']}))
        resources = self.host / 'OfficeRuntimeResources'
        (resources / 'config').mkdir(parents=True)
        (resources / 'cool.html').write_text('synthetic resource, not Office')
        # Reuse the real small repair CONTRACT parser/patch check; copy no
        # binaries/builds. Other locks/sources below are synthetic fixtures.
        actual_base = SCRIPTS.parent / 'ThirdParty/Collabora'
        repair = json.loads((actual_base / 'engine.patch.lock.json').read_text())
        (self.base / 'engine.patch.lock.json').write_text(json.dumps(repair))
        target = self.base / repair['repair']['patch']
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(actual_base / repair['repair']['patch'], target)
        self.commit = repair['engine']['commit']
        self.lock = {'commit': self.commit, 'qualifiedHostArtifact': {
            'hostSourceSHA256': self.sources, 'frameworkAuxiliarySHA256': {
                'Headers/FloeOfficeNative.h': 'unused-old-pin', 'Info.plist': 'unused-old-pin',
                'Modules/module.modulemap': 'unused-old-pin'}}, 'embeddingOverlay': self.overlay('embedding')}
        self.manifest = {'sdk': 'iphoneos', 'arch': 'arm64', 'sourceCommit': self.commit,
            'overlaySHA256': self.lock['embeddingOverlay']['sha256'], 'hostSourceSHA256': self.sources,
            'runtimeResourceSHA256': {'cool.html': transport.pinning.digest(resources / 'cool.html')},
            'runtimeResourceDirectories': ['config'], 'capabilityQualification': false_capabilities(),
            'executableSHA256': transport.pinning.digest(self.framework / 'FloeOfficeNative')}
        for flag in (*transport.pinning.QUALIFICATION_KEYS, 'nativeCompilePassed', 'nativeLinkPassed'):
            self.manifest[flag] = True
        for section, _, block in transport.LIFECYCLES:
            self.lock[section] = self.overlay(block)
            self.manifest[block] = transport.pinning.lifecycle_provenance(self.lock[section], self.commit)
        filters_patch = self.base / 'patches/filters.patch'
        filters_patch.write_text('synthetic filter patch')
        self.filters = {'commit': self.commit, 'patch': 'patches/filters.patch',
            'patchSHA256': transport.pinning.digest(filters_patch), 'originalArchiveSHA256': '6' * 64,
            'member': 'synthetic.o', 'members': {'synthetic.o': 'synthetic.cxx'}, 'files': {'synthetic.cxx': {
                'originalSHA256': '1' * 64, 'patchedSHA256': '2' * 64}}}
        (self.base / 'filter-overlay.lock.json').write_text(json.dumps(self.filters))
        self.manifest['filterOverlay'] = {'compilePassed': True, 'archiveReplacementPassed': True,
            'patchSHA256': self.filters['patchSHA256'], 'sourceFiles': self.filters['files'],
            'headerDependencies': {}, 'archiveSHA256': '3' * 64, 'objectSHA256': '4' * 64,
            'originalArchiveSHA256': '6' * 64, 'objectSHA256ByMember': {'synthetic.o': '4' * 64},
            'selectedArchiveSHA256': '5' * 64, 'selectedArchiveSHA256ByName': {'libscfiltlo.a': '5' * 64}}
        self.lock['qualifiedHostArtifact']['filterOverlay'] = {key: value for key, value in self.manifest['filterOverlay'].items()
            if key not in ('compilePassed', 'archiveReplacementPassed')}
        (self.base / 'engine.lock.json').write_text(json.dumps(self.lock))
        self.manifest['engineRepair'] = transport.pinning.engine_repair_claim(self.base / 'engine.lock.json')
        self.git('init', '-q')
        self.git('add', '.')
        self.git('-c', 'user.name=Transport fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'synthetic contracts')
        self.source = self.git('rev-parse', 'HEAD').strip()
        self.archive = self.root / 'OfficeNativeHost-local.zip'

    def git(self, *args):
        environment = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True, env=environment)

    def overlay(self, name):
        relative = 'patches/' + name + '.patch'
        target = self.base / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('synthetic ' + name)
        return {'patch': relative, 'sha256': transport.pinning.digest(target),
                'files': {'synthetic/' + name: {'preparedSHA256': '4' * 64}}}

    def pack(self, extras=()):
        (self.host / 'native-host.json').write_text(json.dumps(self.manifest))
        with zipfile.ZipFile(self.archive, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(self.host.rglob('*')):
                archive.write(path, str(path.relative_to(self.root)))
            for name, value in extras:
                archive.writestr(name, value)
        return transport.pinning.digest(self.archive)

    def validate(self, sha=None):
        return transport.validate_archive(self.archive, sha or transport.pinning.digest(self.archive), self.repo, self.source)

    def test_valid_local_fixture_preserves_bytes_and_false_capabilities(self):
        sha = self.pack()
        original = self.archive.read_bytes()
        report = self.validate(sha)
        self.assertEqual(report['archiveSHA256'], sha)
        self.assertEqual(self.archive.read_bytes(), original)
        self.assertEqual(report['capabilityQualification'], false_capabilities())
        self.assertFalse(report['nativeManifestModified'])

    def test_cli_copies_original_zip_with_separate_truthful_provenance(self):
        sha = self.pack()
        output = self.root / 'transport-output'
        environment = {key: value for key, value in os.environ.items()
                       if key not in ('GITHUB_ACTIONS', 'GITHUB_SHA', 'GITHUB_WORKFLOW_SHA', 'GH_TOKEN', 'GITHUB_TOKEN')}
        result = subprocess.run([sys.executable, '-B', str(SCRIPTS / 'validate_local_office_transport.py'),
            '--archive', str(self.archive), '--sha256', sha, '--source-commit', self.source,
            '--repo-root', str(self.repo), '--output-dir', str(output)],
            env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.archive.read_bytes(), (output / 'OfficeNativeHost.zip').read_bytes())
        report = json.loads((output / 'transport-provenance.json').read_text())
        self.assertFalse(report['nativeManifestModified'])
        self.assertFalse(report['permanentDistribution'])
        self.assertEqual(report['requestedRetentionDays'], 7)
        self.assertEqual(report['sourceCommit'], self.source)

    def test_invalid_or_duplicate_key_manifest_refused(self):
        for invalid in ('not-json', '{"sdk":"iphoneos","sdk":"iphonesimulator"}'):
            self.pack()
            with zipfile.ZipFile(self.archive) as archive:
                members = [(item, archive.read(item)) for item in archive.infolist()]
            with zipfile.ZipFile(self.archive, 'w') as archive:
                for item, data in members:
                    archive.writestr(item, invalid.encode() if item.filename == 'OfficeNativeHost/native-host.json' else data)
            with self.assertRaises(ValueError): self.validate()

    def test_hash_source_and_workflow_ref_mismatch(self):
        self.pack()
        with self.assertRaisesRegex(ValueError, 'Archive SHA256'):
            self.validate('0' * 64)
        with self.assertRaisesRegex(ValueError, 'source commit'):
            transport.checkout_identity(self.repo, '0' * 40)
        with self.assertRaisesRegex(ValueError, 'Workflow ref'):
            transport.checkout_identity(self.repo, self.source, '0' * 40)
        self.manifest['hostSourceSHA256'] = {'forged.h': '0' * 64}
        self.pack()
        with self.assertRaisesRegex(ValueError, 'Host source'):
            self.validate()

    def test_simulator_or_forged_actual_platform_refused(self):
        self.manifest['sdk'] = 'iphonesimulator'
        self.pack()
        with self.assertRaisesRegex(ValueError, 'iphoneos'):
            self.validate()
        self.manifest['sdk'] = 'iphoneos'
        binary = bytearray(self.binary)
        struct.pack_into('<I', binary, 40, 7)  # actual LC_BUILD_VERSION simulator
        (self.framework / 'FloeOfficeNative').write_bytes(binary)
        self.manifest['executableSHA256'] = hashlib.sha256(binary).hexdigest()
        self.pack()
        with self.assertRaisesRegex(ValueError, 'device build'):
            self.validate()

    def test_traversal_duplicate_member_and_symlink_refused(self):
        for extra in ('OfficeNativeHost/../escape', '/OfficeNativeHost/escape', 'OfficeNativeHost\\evil'):
            with self.subTest(extra=extra):
                self.pack([(extra, 'bad')])
                with self.assertRaises(ValueError): self.validate()
        self.pack([('OfficeNativeHost/native-host.json', '{}')])
        with self.assertRaisesRegex(ValueError, 'Duplicate ZIP'): self.validate()
        self.pack()
        link = zipfile.ZipInfo('OfficeNativeHost/link')
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(self.archive, 'a') as archive: archive.writestr(link, '/etc/passwd')
        with self.assertRaisesRegex(ValueError, 'link or special'): self.validate()

    def test_missing_forged_and_extra_lifecycle_evidence_refused(self):
        for _, _, block in transport.LIFECYCLES:
            original = copy.deepcopy(self.manifest[block])
            with self.subTest(block=block, kind='missing'):
                del self.manifest[block]
                self.pack()
                with self.assertRaisesRegex(ValueError, 'lifecycle'): self.validate()
            for field in ('patchSHA256', 'sourceCommit', 'files', 'extra'):
                with self.subTest(block=block, field=field):
                    self.manifest[block] = {**original, field: 'forged'}
                    self.pack()
                    with self.assertRaisesRegex(ValueError, 'lifecycle'): self.validate()
            self.manifest[block] = original

    def test_engine_repair_filter_and_compile_false_refused(self):
        original = self.manifest.pop('engineRepair')
        self.pack()
        with self.assertRaisesRegex(ValueError, 'engine repair'): self.validate()
        self.manifest['engineRepair'] = {**original, 'extra': 'forged'}
        self.pack()
        with self.assertRaisesRegex(ValueError, 'engine repair'): self.validate()
        self.manifest['engineRepair'] = original
        self.manifest['filterOverlay']['compilePassed'] = False
        self.pack()
        with self.assertRaisesRegex(ValueError, 'Filter overlay'): self.validate()
        self.manifest['filterOverlay']['compilePassed'] = True
        self.manifest['nativeLinkPassed'] = 1
        self.pack()
        with self.assertRaisesRegex(ValueError, 'did not actually pass'): self.validate()

    def test_missing_filter_archive_and_unproven_capability_refused(self):
        original = self.manifest['filterOverlay'].pop('objectSHA256')
        self.pack()
        with self.assertRaisesRegex(ValueError, 'Filter overlay omits'): self.validate()
        self.manifest['filterOverlay']['objectSHA256'] = original
        self.manifest['filterOverlay']['selectedArchiveSHA256ByName'] = {'libscfiltlo.a': 'invalid'}
        self.pack()
        with self.assertRaisesRegex(ValueError, 'selected archive'): self.validate()
        self.manifest['filterOverlay']['selectedArchiveSHA256ByName'] = {'libscfiltlo.a': '5' * 64}
        self.manifest['capabilityQualification']['deviceRoundtripPassed'] = True
        self.pack()
        with self.assertRaises(ValueError): self.validate()

    def test_unknown_executable_resources_and_bad_manifest_refused(self):
        self.pack([('OfficeNativeHost/FloeOfficeNative.framework/UnknownExecutable', 'bad')])
        with self.assertRaisesRegex(ValueError, 'Unknown/missing framework'): self.validate()
        self.pack([('OfficeNativeHost/OfficeRuntimeResources/unknown.txt', 'bad')])
        with self.assertRaisesRegex(ValueError, 'runtime resource'): self.validate()
        self.pack()
        self.manifest['runtimeResourceDirectories'] = ['config', '../escape']
        self.pack()
        with self.assertRaises(ValueError): self.validate()
        self.manifest['runtimeResourceDirectories'] = ['config']
        self.pack()
        with zipfile.ZipFile(self.archive, 'a') as archive:
            # Duplicate JSON fields cannot silently choose the final claim.
            archive.writestr('OfficeNativeHost/native-host.json', '{"sdk":"iphoneos","sdk":"iphonesimulator"}')
        with self.assertRaises(ValueError): self.validate()

    def test_zip_expansion_bound_and_bad_zip(self):
        self.pack()
        with patch.object(transport, 'MAX_EXPANDED_BYTES', 1):
            with self.assertRaisesRegex(ValueError, 'expansion limit'): self.validate()
        self.archive.write_bytes(b'not a zip')
        with self.assertRaises(zipfile.BadZipFile): self.validate()

    def test_private_draft_exact_asset_selection(self):
        digest = 'a' * 64
        release = {'id': 1, 'draft': True, 'published_at': None, 'tag_name': 'office-local-fixture',
                   'target_commitish': self.source, 'assets': [{'id': 2, 'name': transport.ARCHIVE_NAME,
                   'state': 'uploaded', 'size': 1024, 'digest': 'sha256:' + digest,
                   'url': 'https://api.github.com/repos/octo/fixture/releases/assets/2'}]}
        self.assertEqual(transport.select_draft_asset(release, 'office-local-fixture', self.source)['id'], 2)
        self.assertEqual(transport.select_draft_asset(
            release, 'office-local-fixture', self.source, digest, 'octo/fixture')['id'], 2)
        with self.assertRaisesRegex(ValueError, 'digest differs'):
            transport.select_draft_asset(release, 'office-local-fixture', self.source, 'b' * 64)
        wrong_origin = copy.deepcopy(release)
        wrong_origin['assets'][0]['url'] = 'https://evil.invalid/releases/assets/2'
        with self.assertRaisesRegex(ValueError, 'origin'):
            transport.select_draft_asset(wrong_origin, 'office-local-fixture', self.source, digest, 'octo/fixture')
        for changes in ({'draft': False}, {'published_at': 'today'}, {'target_commitish': 'main'},
                        {'assets': []}, {'assets': release['assets'] * 2}):
            with self.subTest(changes=changes):
                with self.assertRaises(ValueError): transport.select_draft_asset({**release, **changes}, 'office-local-fixture', self.source)

    def test_transport_resolves_the_numeric_draft_by_id_and_never_by_tag(self):
        sha = self.pack()
        binary = self.root / 'bin'
        binary.mkdir()
        shim = binary / 'gh'
        shim.write_text(
            '#!/usr/bin/env python3\n'
            'import json, os, sys\n'
            'endpoint = sys.argv[-1]\n'
            'with open(os.environ["GH_CALL_LOG"], "a") as log:\n'
            '    log.write(endpoint + "\\n")\n'
            'if "releases/tags/" in endpoint:\n'
            '    sys.exit("by-tag lookup must never be used for a draft")\n'
            'if "releases/assets/" in endpoint:\n'
            '    sys.stdout.buffer.write(open(os.environ["GH_FIXTURE_ZIP"], "rb").read())\n'
            '    sys.exit(0)\n'
            'release = json.load(open(os.environ["GH_FIXTURE_RELEASE"]))\n'
            'if endpoint.rsplit("/", 1)[-1] != str(release["id"]):\n'
            '    sys.exit("unknown release id")\n'
            'print(json.dumps(release))\n')
        shim.chmod(0o755)
        release_path = self.root / 'release.json'
        release_path.write_text(json.dumps({
            'id': 415971006, 'url': 'https://api.github.com/repos/octo/fixture/releases/415971006',
            'draft': True, 'published_at': None, 'tag_name': 'office-local-fixture',
            'target_commitish': self.source,
            'assets': [{'id': 651161706, 'name': transport.ARCHIVE_NAME, 'state': 'uploaded',
                        'size': self.archive.stat().st_size, 'digest': 'sha256:' + sha,
                        'url': 'https://api.github.com/repos/octo/fixture/releases/assets/651161706'}]}))
        log = self.root / 'gh-calls.log'
        environment = {key: value for key, value in os.environ.items()
                       if key not in ('GITHUB_ACTIONS', 'GITHUB_SHA', 'GITHUB_WORKFLOW_SHA')}
        environment.update(PATH=str(binary) + os.pathsep + environment.get('PATH', ''),
                           GITHUB_REPOSITORY='octo/fixture', GH_CALL_LOG=str(log),
                           GH_FIXTURE_ZIP=str(self.archive), GH_FIXTURE_RELEASE=str(release_path))
        output = self.root / 'transport-output'
        result = subprocess.run([sys.executable, '-B', str(SCRIPTS / 'validate_local_office_transport.py'),
            '--release-tag', 'office-local-fixture', '--release-id', '415971006',
            '--sha256', sha, '--source-commit', self.source,
            '--repo-root', str(self.repo), '--output-dir', str(output)],
            env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((output / 'OfficeNativeHost.zip').read_bytes(), self.archive.read_bytes())
        provenance = json.loads((output / 'transport-provenance.json').read_text())
        self.assertEqual(provenance['draftReleaseID'], 415971006)
        self.assertEqual(provenance['draftAssetID'], 651161706)
        self.assertEqual(provenance['draftTransportTag'], 'office-local-fixture')
        calls = log.read_text().splitlines()
        self.assertTrue(calls)
        self.assertFalse([call for call in calls if 'releases/tags/' in call])
        self.assertEqual(calls[0], 'repos/octo/fixture/releases/415971006')
        self.assertIn('repos/octo/fixture/releases/assets/651161706', calls)

    def test_transport_requires_the_numeric_release_id(self):
        sha = self.pack()
        environment = {key: value for key, value in os.environ.items()
                       if key not in ('GITHUB_ACTIONS', 'GITHUB_SHA', 'GITHUB_WORKFLOW_SHA')}
        environment['GITHUB_REPOSITORY'] = 'octo/fixture'
        result = subprocess.run([sys.executable, '-B', str(SCRIPTS / 'validate_local_office_transport.py'),
            '--release-tag', 'office-local-fixture', '--sha256', sha,
            '--source-commit', self.source, '--repo-root', str(self.repo),
            '--output-dir', str(self.root / 'no-release-id')],
            env=environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('numeric --release-id', result.stderr)


if __name__ == '__main__':
    unittest.main()
