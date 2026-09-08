#!/usr/bin/env python3
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from qualify_office_mobile import qualification_project, qualify, shadow_sources
from package_office_engine import digest


class MobileQualificationTests(unittest.TestCase):
    def test_new_patch_subtree_never_writes_through_to_verified_source(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original = root / 'source/wsd/COOLWSD.cpp'
            original.parent.mkdir(parents=True)
            original.write_text('original server')
            (root / 'source/ios').mkdir()
            (root / 'source/engine').mkdir()
            prepared = root / 'prepared/native/wsd/COOLWSD.cpp'
            prepared.parent.mkdir(parents=True)
            prepared.write_text('prepared server')
            shadow = root / 'shadow'
            shadow_sources(root, shadow, {'files': {'wsd/COOLWSD.cpp': digest(prepared)}})
            self.assertEqual(original.read_text(), 'original server')
            self.assertEqual((shadow / 'wsd/COOLWSD.cpp').read_text(), 'prepared server')
            self.assertFalse((shadow / 'wsd').is_symlink())
            self.assertTrue((shadow / 'engine').is_symlink())

    def test_patch_below_directory_alias_is_rejected_without_changing_target(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original = root / 'source/engine/actual/file.cpp'
            original.parent.mkdir(parents=True)
            original.write_text('original')
            (root / 'source/ios').mkdir()
            (root / 'source/ios/alias').symlink_to('../engine/actual')
            prepared = root / 'prepared/native/ios/alias/file.cpp'
            prepared.parent.mkdir(parents=True)
            prepared.write_text('prepared')
            with self.assertRaisesRegex(ValueError, 'parent is a source alias'):
                shadow_sources(root, root / 'shadow', {'files': {'ios/alias/file.cpp': digest(prepared)}})
            self.assertEqual(original.read_text(), 'original')

    def setUp(self):
        self.project = {"objects": {
            "mobile": {"isa": "PBXNativeTarget", "name": "Mobile", "dependencies": ["extension"],
                       "buildPhases": ["sources", "resources", "release", "embed"]},
            "sources": {"isa": "PBXSourcesBuildPhase", "files": ["controller", "save"]},
            "resources": {"isa": "PBXResourcesBuildPhase", "files": ["browser", "data"]},
            "browser": {"fileRef": "html"}, "html": {"path": "../../../browser/dist/cool.html"},
            "data": {"fileRef": "fixture"}, "fixture": {"path": "../test/data"},
            "release": {"isa": "PBXShellScriptBuildPhase"},
            "embed": {"isa": "PBXCopyFilesBuildPhase"},
            "config": {"isa": "XCBuildConfiguration", "buildSettings": {
                "OTHER_LDFLAGS": ["-filelist", "/old/input.list", "-lPocoNet"]}}}}

    def prepare(self):
        return qualification_project(self.project, Path('/relocated bundle/input.list'), '26.0', ['GameController'])

    def test_sources_and_editor_resources_are_retained_without_mutating_original(self):
        original = copy.deepcopy(self.project)
        prepared = self.prepare()['objects']
        self.assertEqual(prepared['sources']['files'], ['controller', 'save'])
        self.assertEqual(prepared['resources']['files'], ['browser'])
        self.assertEqual(self.project, original)

    def test_qualification_does_not_run_release_script_or_embed_upstream_extension(self):
        target = self.prepare()['objects']['mobile']
        self.assertEqual(target['buildPhases'], ['sources', 'resources'])
        self.assertEqual(target['dependencies'], [])

    def test_complete_relocated_list_and_public_keyboard_framework_are_linked(self):
        settings = self.prepare()['objects']['config']['buildSettings']
        self.assertEqual(settings['OTHER_LDFLAGS'], [
            '-filelist', '/relocated bundle/input.list', '-lPocoNet', '-framework', 'GameController'])
        self.assertEqual(settings['IPHONEOS_DEPLOYMENT_TARGET'], '26.0')
        self.assertEqual(settings['CODE_SIGNING_ALLOWED'], 'NO')

    def test_changed_upstream_target_or_linker_shape_fails_explicitly(self):
        self.project['objects']['config']['buildSettings']['OTHER_LDFLAGS'] = '-filelist x'
        with self.assertRaisesRegex(ValueError, 'linker settings changed'):
            self.prepare()
        self.project['objects']['mobile']['name'] = 'DifferentApp'
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            self.prepare()

    def test_input_verification_failure_preserves_a_failed_receipt(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with patch('qualify_office_mobile.prepare', side_effect=ValueError('changed input')):
                with self.assertRaisesRegex(ValueError, 'changed input'):
                    qualify(root / 'bundle', root / 'output', build=False)
            report = json.loads((root / 'output/qualification.json').read_text())
            self.assertEqual(report['stage'], 'input-verification-failed')
            self.assertFalse(report['nativeCompilePassed'])
            self.assertFalse(report['embeddedEditorPassed'])


if __name__ == '__main__':
    unittest.main()
