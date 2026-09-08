#!/usr/bin/env python3
import copy
from pathlib import Path
import unittest
from build_office_native_host import EXCLUDED_SOURCES, framework_project


class NativeHostProjectTests(unittest.TestCase):
    def project(self):
        objects = {
            'target': {'isa': 'PBXNativeTarget', 'name': 'Mobile', 'productReference': 'product',
                'buildPhases': ['sources', 'resources'], 'buildConfigurationList': 'configs'},
            'product': {'isa': 'PBXFileReference', 'explicitFileType': 'wrapper.application'},
            'configs': {'buildConfigurations': ['release']},
            'release': {'buildSettings': {'HEADER_SEARCH_PATHS': ['qualified/engine'],
                'OTHER_LDFLAGS': ['-filelist', 'complete.list'],
                'INFOPLIST_FILE': 'Mobile/Info.plist', 'CODE_SIGN_ENTITLEMENTS': 'upstream.entitlements'}},
            'sources': {'isa': 'PBXSourcesBuildPhase', 'files': []},
            'resources': {'isa': 'PBXResourcesBuildPhase', 'files': []}}
        for name in sorted(EXCLUDED_SOURCES | {'CODocument.mm', 'DocumentViewController.mm', 'Kit.cpp'}):
            objects[name] = {'isa': 'PBXFileReference', 'path': name}
            objects['build-' + name] = {'isa': 'PBXBuildFile', 'fileRef': name}
            objects['sources']['files'].append('build-' + name)
        for name in ['rc', 'program', 'share', 'cool.html', 'bundle.js', 'Assets.xcassets', 'Settings.bundle', 'Templates']:
            objects[name] = {'isa': 'PBXFileReference', 'path': name}
            objects['resource-' + name] = {'fileRef': name}
            objects['resources']['files'].append('resource-' + name)
        return {'objects': objects}

    def test_replaces_application_lifetime_but_retains_real_editor_and_engine(self):
        original = self.project()
        unchanged = copy.deepcopy(original)
        prepared = framework_project(original, Path('/owned host'))['objects']
        files = [prepared[prepared[key]['fileRef']]['path'] for key in prepared['sources']['files']]
        self.assertEqual(set(files), {'CODocument.mm', 'DocumentViewController.mm', 'Kit.cpp', '/owned host/FloeOfficeNative.mm'})
        self.assertEqual(original, unchanged)
        self.assertEqual(prepared['target']['productType'], 'com.apple.product-type.framework')

    def test_keeps_runtime_resources_and_complete_link_inputs_without_app_identity(self):
        prepared = framework_project(self.project(), Path('/host'))['objects']
        self.assertEqual(prepared['resources']['files'], ['resource-' + name for name in ['rc', 'program', 'share', 'cool.html', 'bundle.js']])
        settings = prepared['release']['buildSettings']
        self.assertEqual(settings['OTHER_LDFLAGS'], ['-filelist', 'complete.list'])
        self.assertEqual(settings['HEADER_SEARCH_PATHS'], ['qualified/engine'])
        self.assertNotIn('CODE_SIGN_ENTITLEMENTS', settings)
        self.assertEqual(settings['MACH_O_TYPE'], 'mh_dylib')

    def test_changed_upstream_application_boundary_fails_closed(self):
        project = self.project()
        project['objects']['sources']['files'].remove('build-main.m')
        with self.assertRaisesRegex(ValueError, 'boundaries changed'):
            framework_project(project, Path('/host'))


if __name__ == '__main__':
    unittest.main()
