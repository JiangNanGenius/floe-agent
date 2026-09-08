#!/usr/bin/env python3
import copy
from pathlib import Path
import unittest
from qualify_office_mobile import qualification_project


class MobileQualificationTests(unittest.TestCase):
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


if __name__ == '__main__':
    unittest.main()
