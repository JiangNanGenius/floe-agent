#!/usr/bin/env python3
import json
import plistlib
from pathlib import Path
import tempfile
import unittest
import zipfile
from bootstrap_office_host import digest, install, relative, checked_lock, verify_installed, write_project_inputs, write_project_configuration
from embed_office_host import embed
from verify_office_app_embedding import verify_payload


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
        files = {'FloeOfficeNative.framework/FloeOfficeNative': 'native binary fixture',
                 'FloeOfficeNative.framework/Headers/FloeOfficeNative.h': 'public header',
                 'FloeOfficeNative.framework/Modules/module.modulemap': 'module fixture',
                 'FloeOfficeNative.framework/Info.plist': 'plist fixture',
                 'OfficeRuntimeResources/cool.html': 'editor fixture'}
        for name, data in files.items():
            path = self.host / name
            path.parent.mkdir(parents=True, exist_ok=True)
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
