#!/usr/bin/env python3
import json
import plistlib
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import zipfile
import office_component_recovery as component_recovery
from bootstrap_office_host import (digest, install, relative, checked_lock, fetch_pinned_archive,
                                   verify_installed, write_project_inputs, write_project_configuration)
from embed_office_host import embed
from verify_office_app_embedding import verify_payload

EXECUTABLE_UUID = '11111111-2222-3333-4444-555555555555'


def macho_bytes(uuid_text=EXECUTABLE_UUID):
    compact = bytes.fromhex(uuid_text.replace('-', ''))
    header = struct.pack('<IIIIIIII', 0xfeedfacf, 0x0100000c, 0, 6, 1, 24, 0, 0)
    command = struct.pack('<II', 0x1b, 24) + compact
    return header + command


def release_runner_from(directory, *, fail=False):
    def run(argv, check=True, timeout=None):
        if fail:
            raise subprocess.CalledProcessError(1, argv)
        pattern = argv[argv.index('--pattern') + 1]
        output = Path(argv[argv.index('--output') + 1])
        source = Path(directory) / pattern
        if not source.is_file():
            raise subprocess.CalledProcessError(1, argv)
        shutil.copyfile(source, output)
    return run


class OfficeHostBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.host = self.root / 'OfficeNativeHost'
        native = self.root / 'FloeOfficeNative'
        native.mkdir()
        for name in ['FloeOfficeNative.h', 'FloeOfficeNative.mm', 'FloeOfficeAttachment.cpp', 'FloeOfficeAttachment.hxx']:
            (native / name).write_text('source-' + name)
        files = {'FloeOfficeNative.framework/FloeOfficeNative': macho_bytes(),
                 'FloeOfficeNative.framework/Headers/FloeOfficeNative.h': 'public header',
                 'FloeOfficeNative.framework/Modules/module.modulemap': 'module fixture',
                 'FloeOfficeNative.framework/Info.plist': 'plist fixture',
                 'OfficeRuntimeResources/cool.html': 'editor fixture'}
        for name, data in files.items():
            path = self.host / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(data, bytes):
                path.write_bytes(data)
            else:
                path.write_text(data)
        (self.host / 'OfficeRuntimeResources/config').mkdir()
        sources = {path.name: digest(path) for path in native.iterdir()}
        report = {'sourceCommit': 'pinned-source', 'overlaySHA256': 'pinned-overlay',
            'hostSourceSHA256': sources, 'hostCompilePassed': True, 'hostLinkPassed': True,
            'swiftModuleImportPassed': True,
            'runtimeResourceSHA256': {'cool.html': digest(self.host / 'OfficeRuntimeResources/cool.html')},
            'runtimeResourceDirectories': ['config']}
        (self.host / 'native-host.json').write_text(json.dumps(report))
        framework = self.host / 'FloeOfficeNative.framework'
        self.pin = {'runID': '123', 'artifactName': 'fixture', 'overlaySHA256': 'pinned-overlay',
            'hostSourceSHA256': sources, 'executableSHA256': digest(framework / 'FloeOfficeNative'),
            'manifestSHA256': digest(self.host / 'native-host.json'),
            'frameworkAuxiliarySHA256': {str(path.relative_to(framework)): digest(path)
                for path in framework.rglob('*') if path.is_file() and path.name != 'FloeOfficeNative'}}
        self.archive = self.root / 'host.zip'
        with zipfile.ZipFile(self.archive, 'w') as archive:
            for path in self.host.rglob('*'):
                archive.write(path, str(path.relative_to(self.root)))
        self.pin['archiveSHA256'] = digest(self.archive)
        self.lock = self.root / 'engine.lock.json'
        self.lock.write_text(json.dumps({'commit': 'pinned-source', 'embeddingOverlay': {'sha256': 'pinned-overlay'},
                                        'qualifiedHostArtifact': self.pin}))
        self.destination = self.root / 'installed/OfficeNativeHost'

    def install(self):
        return install(self.archive, self.destination, self.lock)

    def make_component_release(self):
        release = self.root / 'release'
        release.mkdir()
        shutil.copyfile(self.archive, release / component_recovery.HOST_ASSET)
        lock, pin = checked_lock(self.lock)
        manifest = json.loads((self.host / 'native-host.json').read_text())
        hashes = {'manifestSHA256': pin['manifestSHA256'],
                  'executableSHA256': pin['executableSHA256']}
        dsym = self.root / 'Symbols' / component_recovery.SYMBOLS_ROOT
        dwarf = dsym / 'Contents/Resources/DWARF/FloeOfficeNative'
        dwarf.parent.mkdir(parents=True)
        dwarf.write_bytes(macho_bytes())
        # The dSYM is a separate PRIVATE artifact; it is never written into
        # the public release directory downloaded by bootstrap.
        private = self.root / 'private-symbols'
        private.mkdir()
        symbols_archive = component_recovery.write_deterministic_zip(
            dsym, private / component_recovery.SYMBOLS_ASSET,
            component_recovery.SYMBOLS_ROOT)
        licenses = self.root / 'licenses' / component_recovery.LICENSES_ROOT
        licenses.mkdir(parents=True)
        for name in ('LICENSE', 'COPYING.MPL', 'NOTICE'):
            (licenses / name).write_text('license ' + name)
        component_recovery.write_deterministic_zip(
            licenses, release / component_recovery.LICENSES_ASSET,
            component_recovery.LICENSES_ROOT)
        symbols = component_recovery.inspect_symbol_archive(symbols_archive)
        licenses_block = component_recovery.inspect_license_archive(
            release / component_recovery.LICENSES_ASSET)
        descriptor = component_recovery.build_descriptor(
            lock, manifest, hashes, release / component_recovery.HOST_ASSET,
            claims=component_recovery.required_claims(lock, pin),
            transport=component_recovery.expected_transport(pin),
            symbols=symbols, symbols_archive=symbols_archive,
            licenses=licenses_block)
        (release / component_recovery.DESCRIPTOR_ASSET).write_text(
            json.dumps(descriptor, indent=2, sort_keys=True) + '\n')
        (release / component_recovery.HOST_SIDECAR).write_text(
            f"{descriptor['archive']['sha256']}  {component_recovery.HOST_ASSET}\n")
        self.release = release
        self.private_symbols = symbols_archive
        return release

    def expired_actions(self, argv, check=True, timeout=None):
        raise subprocess.CalledProcessError(1, argv)

    def test_expired_actions_artifact_recovers_the_exact_component_release(self):
        release = self.make_component_release()
        lock, pin = checked_lock(self.lock)
        staging = self.root / 'staging'
        staging.mkdir()
        archive, transport = fetch_pinned_archive(
            lock, pin, staging, actions_runner=self.expired_actions,
            release_runner=release_runner_from(release), attempts=1, sleep=lambda _: None)
        self.assertEqual(transport['kind'], 'component-release')
        self.assertEqual(digest(archive), pin['archiveSHA256'])
        self.assertFalse(transport['symbolsVerified'])
        self.assertEqual(transport['symbolsVisibility'], 'private')
        self.assertNotIn(component_recovery.SYMBOLS_ASSET,
                         {path.name for path in release.iterdir()})
        result = install(archive, self.destination, self.lock,
                         expected_executable_uuid=transport['executableUUID'])
        self.assertEqual(result['runID'], '123')
        self.assertEqual((self.destination / 'OfficeRuntimeResources/cool.html').read_text(),
                         'editor fixture')

    def test_release_only_never_calls_the_actions_artifact(self):
        release = self.make_component_release()
        lock, pin = checked_lock(self.lock)
        calls = []

        def actions(argv, check=True, timeout=None):
            calls.append(argv)
            raise subprocess.CalledProcessError(1, argv)

        staging = self.root / 'staging'
        staging.mkdir()
        archive, transport = fetch_pinned_archive(
            lock, pin, staging, actions_runner=actions,
            release_runner=release_runner_from(release), release_only=True,
            attempts=1, sleep=lambda _: None)
        self.assertEqual(calls, [])
        self.assertEqual(digest(archive), pin['archiveSHA256'])
        self.assertEqual(transport['kind'], 'component-release')

    def test_unavailable_network_reports_both_transports_and_installs_nothing(self):
        lock, pin = checked_lock(self.lock)
        staging = self.root / 'staging'
        staging.mkdir()
        with self.assertRaisesRegex(ValueError, 'both transports'):
            fetch_pinned_archive(
                lock, pin, staging, actions_runner=self.expired_actions,
                release_runner=release_runner_from(self.root / 'missing', fail=True),
                attempts=1, sleep=lambda _: None)
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(staging.iterdir()), [])

    def test_wrong_component_bytes_do_not_create_a_destination(self):
        release = self.make_component_release()
        (release / component_recovery.HOST_ASSET).write_bytes(b'corrupt archive')
        lock, pin = checked_lock(self.lock)
        staging = self.root / 'staging'
        staging.mkdir()
        with self.assertRaisesRegex(ValueError, 'component release'):
            fetch_pinned_archive(
                lock, pin, staging, release_only=True,
                release_runner=release_runner_from(release), attempts=1,
                sleep=lambda _: None)
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(staging.iterdir()), [])

    def test_mismatched_symbol_uuid_is_rejected_before_commit(self):
        with self.assertRaisesRegex(ValueError, 'UUID differs'):
            install(self.archive, self.destination, self.lock,
                    expected_executable_uuid='00000000-0000-0000-0000-000000000000')
        self.assertFalse(self.destination.exists())

    def test_cancelled_install_never_commits_or_leaves_staging(self):
        checks = []

        def cancel():
            checks.append(True)
            if len(checks) == 3:
                raise component_recovery.RecoveryCancelled('cancelled by test')

        with self.assertRaises(component_recovery.RecoveryCancelled):
            install(self.archive, self.destination, self.lock, cancel_check=cancel)
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.destination.parent.glob('.office-host-*')), [])

    def test_existing_destination_is_not_replaced_by_a_failed_component(self):
        self.install()
        release = self.make_component_release()
        (release / component_recovery.HOST_ASSET).write_bytes(b'corrupt archive')
        lock, pin = checked_lock(self.lock)
        staging = self.root / 'staging'
        staging.mkdir()
        with self.assertRaises(ValueError):
            fetch_pinned_archive(lock, pin, staging, release_only=True,
                                 release_runner=release_runner_from(release),
                                 attempts=1, sleep=lambda _: None)
        self.assertEqual(self.install()['verifiedFiles'], 6)
        self.assertEqual((self.destination / 'OfficeRuntimeResources/cool.html').read_text(),
                         'editor fixture')

    def test_installs_once_and_preserves_required_empty_directories(self):
        first = self.install()
        self.assertTrue((self.destination / 'OfficeRuntimeResources/config').is_dir())
        self.assertEqual(first['verifiedFiles'], 6)
        self.assertEqual(self.install(), first)
        self.assertEqual(digest(self.archive), self.pin['archiveSHA256'])

    def test_changed_filter_patch_requires_a_rebuilt_host(self):
        patch = self.root / 'filter.patch'
        patch.write_text('qualified filter source')
        filters = {'commit': 'pinned-source', 'patch': 'filter.patch',
                   'patchSHA256': digest(patch), 'files': {'source.cpp': {'patchedSHA256': 'known'}}}
        (self.root / 'filter-overlay.lock.json').write_text(json.dumps(filters))
        value = json.loads(self.lock.read_text())
        value['qualifiedHostArtifact']['filterOverlay'] = {
            'patchSHA256': filters['patchSHA256'], 'sourceFiles': filters['files']}
        self.lock.write_text(json.dumps(value))
        checked_lock(self.lock)
        patch.write_text('uncompiled replacement')
        with self.assertRaisesRegex(ValueError, 'engine filter patch'):
            checked_lock(self.lock)

    def test_host_without_filter_build_evidence_cannot_claim_filter_pin(self):
        lock, pin = checked_lock(self.lock)
        pin['filterOverlay'] = {'patchSHA256': 'expected'}
        with self.assertRaisesRegex(ValueError, 'filter qualification'):
            verify_installed(self.host, lock, pin)

    def forwarding_fixture(self, claim='forwarded-overlay'):
        value = json.loads(self.lock.read_text())
        value['forwardingLifecycleOverlay'] = {
            'sha256': 'forwarded-overlay',
            'files': {'ios/Mobile/DocumentViewController.mm': {'preparedSHA256': 'prepared-forwarded'}}}
        value['qualifiedHostArtifact']['forwardingOverlaySHA256'] = claim
        self.lock.write_text(json.dumps(value))
        return value

    def test_forwarding_claim_must_match_the_lock(self):
        self.forwarding_fixture(claim='stale-claim')
        with self.assertRaisesRegex(ValueError, 'forwarding overlay claim'):
            checked_lock(self.lock)

    def test_forwarding_claim_requires_a_lock_section(self):
        value = json.loads(self.lock.read_text())
        value['qualifiedHostArtifact']['forwardingOverlaySHA256'] = 'forwarded-overlay'
        self.lock.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, 'forwarding overlay claim'):
            checked_lock(self.lock)

    def test_forwarding_claim_requires_manifest_provenance(self):
        self.forwarding_fixture()
        lock, pin = checked_lock(self.lock)
        with self.assertRaisesRegex(ValueError, 'forwarding overlay provenance'):
            verify_installed(self.host, lock, pin)

    def test_forwarding_claim_accepts_matching_provenance(self):
        self.forwarding_fixture()
        report_path = self.host / 'native-host.json'
        report = json.loads(report_path.read_text())
        report['forwardingLifecycle'] = {
            'patchSHA256': 'forwarded-overlay', 'sourceCommit': 'pinned-source',
            'files': {'ios/Mobile/DocumentViewController.mm': 'prepared-forwarded'}}
        report_path.write_text(json.dumps(report))
        self.pin['manifestSHA256'] = digest(report_path)
        value = json.loads(self.lock.read_text())
        value['qualifiedHostArtifact']['manifestSHA256'] = self.pin['manifestSHA256']
        self.lock.write_text(json.dumps(value))
        lock, pin = checked_lock(self.lock)
        verify_installed(self.host, lock, pin)


    def test_header_dependency_changes_require_rebuilt_host(self):
        patch = self.root / 'filter.patch'
        patch.write_text('filter')
        header_patch = self.root / 'headers.patch'
        header_patch.write_text('upstream patch')
        spec = {'patch': header_patch.name, 'patchSHA256': digest(header_patch), 'sha256': 'archive'}
        filters = {'commit': 'pinned-source', 'patch': patch.name,
                   'patchSHA256': digest(patch), 'files': {}, 'headerDependencies': {'mdds': spec}}
        (self.root / 'filter-overlay.lock.json').write_text(json.dumps(filters))
        value = json.loads(self.lock.read_text())
        selected = {'patchSHA256': digest(patch), 'sourceFiles': {}}
        value['qualifiedHostArtifact']['filterOverlay'] = selected
        self.lock.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, 'engine filter patch'):
            checked_lock(self.lock)
        selected['headerDependencies'] = filters['headerDependencies']
        self.lock.write_text(json.dumps(value))
        checked_lock(self.lock)
        header_patch.write_text('uncompiled change')
        with self.assertRaisesRegex(ValueError, 'header dependency patch'):
            checked_lock(self.lock)

    def test_additional_filter_archive_must_be_present_and_bound_to_selection(self):
        patch = self.root / 'filter.patch'
        patch.write_text('two archives')
        filters = {'commit': 'pinned-source', 'patch': 'filter.patch',
                   'patchSHA256': digest(patch), 'files': {}, 'additionalArchives': {
                       'libooxlo.a': {'originalArchiveSHA256': 'original', 'members': {'shape.o': 'shape.cpp'}}}}
        (self.root / 'filter-overlay.lock.json').write_text(json.dumps(filters))
        value = json.loads(self.lock.read_text())
        selected = {'patchSHA256': filters['patchSHA256'], 'sourceFiles': {}}
        value['qualifiedHostArtifact']['filterOverlay'] = selected
        self.lock.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, 'missing qualified additional'):
            checked_lock(self.lock)
        selected.update(additionalArchives={'libooxlo.a': {'originalArchiveSHA256': 'original',
            'archiveSHA256': 'new', 'objectSHA256ByMember': {'shape.o': 'object'}}},
            selectedArchiveSHA256ByName={'libscfiltlo.a': 'calc', 'libooxlo.a': 'new'})
        self.lock.write_text(json.dumps(value))
        checked_lock(self.lock)
        selected['selectedArchiveSHA256ByName']['libooxlo.a'] = 'stale'
        self.lock.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, 'differs from its lock'):
            checked_lock(self.lock)

    def test_xcode_input_list_remains_bounded_after_full_payload_verification(self):
        self.install()
        output = self.root / 'inputs.xcfilelist'
        write_project_inputs(self.destination, output, self.root, self.lock)
        lines = set(output.read_text().splitlines())
        self.assertEqual(lines, {'$(SRCROOT)/installed/OfficeNativeHost'})
        (self.destination / 'OfficeRuntimeResources/cool.html').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            write_project_inputs(self.destination, output, self.root, self.lock)

    def test_changed_binary_is_rejected_without_overwriting_it(self):
        self.install()
        binary = self.destination / 'FloeOfficeNative.framework/FloeOfficeNative'
        binary.write_text('edited locally')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            self.install()
        self.assertEqual(binary.read_text(), 'edited locally')

    def test_configuration_tracks_the_verified_host_after_an_artifact_upgrade(self):
        self.install()
        output = self.root / 'native-host.xcconfig'
        write_project_configuration(self.destination, output, self.root, self.lock)
        self.assertIn('$(PROJECT_DIR)/installed/OfficeNativeHost', output.read_text())
        newer = self.root / 'next-run/OfficeNativeHost'
        install(self.archive, newer, self.lock)
        write_project_configuration(newer, output, self.root, self.lock)
        self.assertIn('$(PROJECT_DIR)/next-run/OfficeNativeHost', output.read_text())
        self.assertNotIn('/installed/', output.read_text())
        (newer / 'FloeOfficeNative.framework/FloeOfficeNative').write_text('unqualified')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            write_project_configuration(newer, output, self.root, self.lock)

    def test_changed_manifest_cannot_redefine_trusted_resource_hashes(self):
        self.install()
        manifest = self.destination / 'native-host.json'
        value = json.loads(manifest.read_text())
        value['runtimeResourceSHA256'] = {}
        manifest.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, 'manifest differs'):
            self.install()

    def test_missing_empty_directory_and_extra_file_each_fail_inventory(self):
        self.install()
        directory = self.destination / 'OfficeRuntimeResources/config'
        directory.rmdir()
        with self.assertRaisesRegex(ValueError, 'inventory changed'):
            self.install()
        directory.mkdir()
        (self.destination / 'extra').write_text('unknown')
        with self.assertRaisesRegex(ValueError, 'inventory changed'):
            self.install()

    def test_source_change_requires_a_new_binary_before_installation(self):
        for name in self.pin['hostSourceSHA256']:
            with self.subTest(source=name):
                source = self.root / 'FloeOfficeNative' / name
                original = source.read_bytes()
                source.write_text('new implementation')
                with self.assertRaisesRegex(ValueError, 'must be rebuilt'):
                    self.install()
                self.assertFalse(self.destination.exists())
                source.write_bytes(original)

    def test_archive_mismatch_is_rejected_before_destination_is_created(self):
        self.archive.write_bytes(b'changed archive')
        with self.assertRaisesRegex(ValueError, 'archive checksum mismatch'):
            self.install()
        self.assertFalse(self.destination.parent.exists())

    def test_alias_cannot_replace_a_verified_resource(self):
        self.install()
        resource = self.destination / 'OfficeRuntimeResources/cool.html'
        resource.unlink()
        resource.symlink_to(self.host / 'OfficeRuntimeResources/cool.html')
        with self.assertRaisesRegex(ValueError, 'unexpected alias'):
            self.install()

    def test_noncanonical_and_parent_paths_are_rejected(self):
        for name in ['../escape', '/absolute', 'a/../b', 'a//b', './file', 'a\\b']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                relative(name)

    def make_app(self, identifier='org.floeagent.ios'):
        app = self.root / 'Floe Agent.app'
        app.mkdir()
        (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))
        (app / 'unrelated-resource.txt').write_text('keep')
        return app

    def test_embeds_only_verified_resources_into_main_bundle_and_preserves_unrelated_files(self):
        self.install()
        app = self.make_app()
        result = embed(self.destination, app, self.lock)
        self.assertTrue(result['embeddedFramework'])
        self.assertFalse(result['signedFramework'])
        self.assertEqual((app / 'cool.html').read_text(), 'editor fixture')
        self.assertTrue((app / 'config').is_dir())
        self.assertTrue((app / 'Frameworks/FloeOfficeNative.framework/FloeOfficeNative').is_file())
        self.assertEqual((app / 'unrelated-resource.txt').read_text(), 'keep')
        self.assertTrue(verify_payload(self.destination, app, self.lock)['unsignedPayloadVerified'])
        (app / 'config/obsolete').write_text('old build data')
        embed(self.destination, app, self.lock)
        self.assertFalse((app / 'config/obsolete').exists())
        (app / 'cool.html').write_text('damaged packaged editor')
        with self.assertRaisesRegex(ValueError, 'payload differs'):
            verify_payload(self.destination, app, self.lock)

    def test_invalid_source_does_not_change_an_existing_app(self):
        self.install()
        app = self.make_app()
        (app / 'cool.html').write_text('existing app data')
        (self.destination / 'OfficeRuntimeResources/cool.html').write_text('wrong source')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            embed(self.destination, app, self.lock)
        self.assertEqual((app / 'cool.html').read_text(), 'existing app data')

    def test_unrelated_app_and_aliased_output_are_not_overwritten(self):
        self.install()
        app = self.make_app('org.example.other')
        with self.assertRaisesRegex(ValueError, 'destination is not Floe'):
            embed(self.destination, app, self.lock)
        (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.floeagent.ios'}))
        outside = self.root / 'outside'
        outside.mkdir()
        (app / 'Frameworks').symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'unexpected alias'):
            embed(self.destination, app, self.lock)
        self.assertEqual(list(outside.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
