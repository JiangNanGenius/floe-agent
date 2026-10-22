"""Focused packaging/privacy tests; synthetic bytes are not native qualification."""
import copy
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import sys
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import office_component_public_metadata as public

COMMIT = '1' * 40


class PublicMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=os.environ.get('FLOE_OFFICE_PUBLIC_METADATA_TEST_ROOT'))
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.input = self.root / 'private.zip'
        self.output = self.root / 'public.zip'
        self.receipt = self.root / 'public-receipt.json'
        self.binary = (struct.pack('<IiiIIIII', 0xFEEDFACF, 0x0100000C, 0, 6, 1, 24, 0, 0)
                       + struct.pack('<6I', 0x32, 24, 2, 0x1A0000, 0x1B0000, 0))
        self.manifest = {
            'sourceCommit': '2' * 40, 'sdk': 'iphoneos', 'arch': 'arm64',
            'nativeCompilePassed': True, 'nativeLinkPassed': True,
            'capabilityQualification': {'embeddedEditorPassed': False, 'pptxVisibleRenderPassed': False,
                'deviceRoundtripPassed': False, 'originalFileWritebackPassed': False},
            'hostSourceSHA256': {'FloeOfficeNative.mm': '3' * 64},
            'platformOriginalArchives': {'sdk': 'iphoneos', 'archives': {'libvcllo.a': '4' * 64}},
            'embeddedLifecycleMember': {'memberSources': {'fontcache.o': {'sourceFile': 'engine/vcl/source/font/fontcache.cxx'}},
                'objectABIByMember': {'fontcache.o': {'arch': 'arm64', 'platform': 'IOS'}},
                'linkOwnership': {'linkMapSHA256': '5' * 64}},
            'engineRepair': {'sourceFile': 'engine/vcl/source/gdi/virdev.cxx', 'patchSHA256': '6' * 64},
            'browserResources': {'bundleSHA256': '7' * 64},
            'executableSHA256': hashlib.sha256(self.binary).hexdigest(),
            'runtimeResourceSHA256': {'bundle.js': '8' * 64}, 'runtimeResourceDirectories': [],
            'command': ['/Applications/Xcode.app/xcodebuild', 'OBJROOT=/Users/example/private/build'],
            'engineRepairReceiptPath': '/Volumes/example/Local/Private/repair.json',
            'platformLoadCommands': '/Users/example/build/FloeOfficeNative:\nLoad command 1\n platform IOS\n sdk 27.0\n',
            'dynamicLibraries': '/Volumes/example/FloeOfficeNative:\n\t/usr/lib/libc++.1.dylib (compatibility version 1.0.0)\n\t/System/Library/Frameworks/UIKit.framework/UIKit (compatibility version 1.0.0)\n',
            'filterOverlay': {'sourceFiles': {'engine/sc/source/filter/excel.cxx': '9' * 64},
                'patchSHA256': 'a' * 64, 'objectSHA256': 'b' * 64, 'archiveSHA256': 'c' * 64,
                'selectedArchiveSHA256': 'd' * 64, 'compilePassed': True, 'archiveReplacementPassed': True,
                'compileCommand': ['clang', '/Users/example/private.cxx'],
                'compileCommands': {'foo.o': ['clang', '/Volumes/example/private.cxx']},
                'archive': '/Users/example/lib.a', 'selectedArchive': '/Volumes/example/lib.a',
                'serializationDelta': {'command': ['clang', '/private/tmp/example.cxx'],
                    'compilePassed': True, 'objectSHA256': 'e' * 64}},
        }

    def write_archive(self, *, extra=None, manifest_bytes=None, binary=None):
        parts = {
            public.MANIFEST: manifest_bytes or json.dumps(self.manifest).encode(),
            public.BINARY: self.binary if binary is None else binary,
            'OfficeNativeHost/FloeOfficeNative.framework/Info.plist': b'public-header-fixture',
            'OfficeNativeHost/OfficeRuntimeResources/bundle.js': b'/* unchanged runtime bytes */',
        }
        if extra:
            parts.update(extra)
        with zipfile.ZipFile(self.input, 'w') as archive:
            for name, data in parts.items():
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                archive.writestr(info, data)

    def run_helper(self):
        return public.derive_public_zip(self.input, self.output, self.receipt, packaging_source_commit=COMMIT)

    def assert_refused_without_output(self):
        with self.assertRaises((ValueError, OSError, KeyError, zipfile.BadZipFile)):
            self.run_helper()
        self.assertFalse(self.output.exists())
        self.assertFalse(self.receipt.exists())
        self.assertFalse(any(p.name.startswith('.office-') for p in self.root.iterdir()))

    def test_only_diagnostic_metadata_changes_and_every_payload_byte_survives(self):
        self.write_archive()
        original_hash = public.sha(self.input)
        result = self.run_helper()
        self.assertEqual(public.sha(self.input), original_hash)
        with zipfile.ZipFile(self.input) as before, zipfile.ZipFile(self.output) as after:
            self.assertEqual(set(before.namelist()), set(after.namelist()))
            for name in before.namelist():
                if name != public.MANIFEST:
                    self.assertEqual(before.read(name), after.read(name))
            normalized = json.loads(after.read(public.MANIFEST))
            for key in ('sourceCommit', 'sdk', 'arch', 'capabilityQualification', 'hostSourceSHA256',
                        'platformOriginalArchives', 'embeddedLifecycleMember', 'engineRepair',
                        'browserResources', 'executableSHA256', 'runtimeResourceSHA256', 'runtimeResourceDirectories'):
                self.assertEqual(normalized[key], self.manifest[key])
            self.assertEqual(normalized['platformLoadCommands'].splitlines()[1:], self.manifest['platformLoadCommands'].splitlines()[1:])
            self.assertEqual(normalized['dynamicLibraries'].splitlines()[1:], self.manifest['dynamicLibraries'].splitlines()[1:])
            self.assertNotIn('command', normalized)
            self.assertEqual(normalized['filterOverlay']['serializationDelta'], {'compilePassed': True, 'objectSHA256': 'e' * 64})
        recorded = json.loads(self.receipt.read_text())
        self.assertEqual(result, recorded)
        self.assertEqual(result['originalArchiveSHA256'], original_hash)
        self.assertEqual(result['publicArchiveSHA256'], public.sha(self.output))
        self.assertEqual(result['packagingSource']['callerSuppliedCommit'], COMMIT)
        public.assert_public_metadata(result)
        self.assertEqual({x['field'] for x in result['changedFields']},
            {'.'.join(x) for x in public.REMOVED_FIELDS} | set(public.HEADER_FIELDS))

    def test_unknown_metadata_paths_are_rejected_in_values_keys_and_encoded_forms(self):
        for value in ['/Users/example/secret', '/opt/private-build', 'Local/Private/input.json',
                      'file:///Volumes/example/input', '%2FUsers%2Fexample%2Fsecret', 'C:\\Users\\example\\secret',
                      '//server/private-build', '\\opt\\private-build']:
            with self.subTest(value=value):
                changed = copy.deepcopy(self.manifest); changed['futureDiagnostics'] = {'newField': value}
                with self.assertRaisesRegex(ValueError, 'unrecognized local/private path'):
                    public.normalize_manifest(changed)
        changed = copy.deepcopy(self.manifest); changed['futureDiagnostics'] = {'/Users/example/key': 'value'}
        with self.assertRaisesRegex(ValueError, 'unsafe key'):
            public.normalize_manifest(changed)
        changed = copy.deepcopy(self.manifest); changed['publicReference'] = 'https://example.com/public'
        normalized, _ = public.normalize_manifest(changed)
        self.assertEqual(normalized['publicReference'], changed['publicReference'])

    def test_unknown_path_failure_leaves_original_and_no_partial_outputs(self):
        self.manifest['futureDiagnostics'] = ['/Users/example/unknown']
        self.write_archive(); before = public.sha(self.input)
        self.assert_refused_without_output()
        self.assertEqual(public.sha(self.input), before)

    def test_private_path_in_abi_body_is_rejected_instead_of_scrubbed(self):
        for key in public.HEADER_FIELDS:
            changed = copy.deepcopy(self.manifest); changed[key] += ' private /Users/example/secret\n'
            with self.assertRaises(ValueError):
                public.normalize_manifest(changed)

    def test_refuses_existing_output_or_receipt_without_overwriting(self):
        self.write_archive()
        for destination in (self.output, self.receipt):
            destination.write_bytes(b'owned-by-another-task')
            with self.assertRaisesRegex(ValueError, 'refusing overwrite'):
                self.run_helper()
            self.assertEqual(destination.read_bytes(), b'owned-by-another-task')
            destination.unlink()

    def test_zip_boundary_rejects_traversal_symlink_and_duplicate_manifest(self):
        self.write_archive(extra={'OfficeNativeHost/../../escape.txt': b'no'})
        self.assert_refused_without_output()
        self.write_archive()
        with zipfile.ZipFile(self.input, 'a') as archive:
            info = zipfile.ZipInfo('OfficeNativeHost/OfficeRuntimeResources/alias')
            info.create_system = 3; info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, '/Users/example/secret')
        self.assert_refused_without_output()
        self.write_archive()
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(self.input, 'a') as archive:
                archive.writestr(public.MANIFEST, json.dumps(self.manifest))
        self.assert_refused_without_output()

    def test_duplicate_json_keys_wrong_abi_and_unexpected_files_are_refused(self):
        self.write_archive(manifest_bytes=b'{"sdk":"iphoneos","sdk":"iphoneos","arch":"arm64"}')
        self.assert_refused_without_output()
        wrong_abi = self.binary[:40] + struct.pack('<I', 7) + self.binary[44:]
        self.write_archive(binary=wrong_abi)
        self.assert_refused_without_output()
        self.write_archive(extra={'OfficeNativeHost/private-notes.txt': b'no'})
        self.assert_refused_without_output()
        self.write_archive(extra={'OfficeNativeHost/FloeOfficeNative.framework/private.dSYM/Info.plist': b'no'})
        self.assert_refused_without_output()

    def test_atomic_receipt_collision_rolls_back_only_our_output(self):
        self.write_archive()
        real_link = os.link
        def race(source, destination, **kwargs):
            if Path(destination) == self.receipt:
                self.receipt.write_bytes(b'another-task')
                raise FileExistsError('race')
            return real_link(source, destination, **kwargs)
        with mock.patch.object(public.os, 'link', side_effect=race):
            with self.assertRaises(FileExistsError):
                self.run_helper()
        self.assertFalse(self.output.exists())
        self.assertEqual(self.receipt.read_bytes(), b'another-task')


if __name__ == '__main__':
    unittest.main()
