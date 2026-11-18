#!/usr/bin/env python3
"""Offline metadata and synthetic input checks; this is not OTA qualification."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
MAC = ROOT / 'FloeMac'
BASELINE = '2c2208f9d9cb9324f7acbdf85f8d71165e539224'
REVISION = 'ab7d71291238df6e0492143b120c9b696a35f603'


def project(name):
    path = MAC / name / 'project.pbxproj'
    data = subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(path)])
    return json.loads(data)['objects']


def host(objects):
    return next(v for v in objects.values() if v.get('isa') == 'PBXNativeTarget' and v.get('name') == 'FloeMacHost')


def configurations(objects, target):
    refs = objects[target['buildConfigurationList']]['buildConfigurations']
    return {objects[i]['name']: objects[i]['buildSettings'] for i in refs}


class OTACandidateMetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ota = project('FloeMacOTA.xcodeproj')
        cls.m00 = project('FloeMac.xcodeproj')
        cls.ota_host = host(cls.ota)
        cls.phase = next(cls.ota[i] for i in cls.ota_host['buildPhases']
                         if cls.ota[i].get('name') == 'Validate explicit OTA candidate inputs')

    def test_inherited_identity_and_feed_match_frozen_published_source(self):
        source = subprocess.check_output(['git', 'show', f'{BASELINE}:FloeMacBridge/Info.plist'], cwd=ROOT)
        legacy = plistlib.loads(source)
        candidate = plistlib.loads((MAC / 'Resources/FloeMacHost-OTA-Info.plist').read_bytes())
        self.assertEqual(legacy['CFBundleIdentifier'], 'org.floeagent.macbridge')
        self.assertEqual((legacy['CFBundleShortVersionString'], legacy['CFBundleVersion']), ('1.1.6', '9'))
        for key in ('SUFeedURL', 'SUPublicEDKey', 'CFBundleURLTypes'):
            self.assertEqual(candidate[key], legacy[key], key)
        self.assertEqual(candidate['CFBundleIdentifier'], '$(PRODUCT_BUNDLE_IDENTIFIER)')
        self.assertEqual(candidate['CFBundleShortVersionString'], '$(FLOE_OTA_VERSION)')
        self.assertEqual(candidate['CFBundleVersion'], '$(FLOE_OTA_BUILD)')
        for key in ('SUEnableAutomaticChecks', 'SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates'):
            self.assertIs(candidate[key], False)
        self.assertIs(candidate['SUVerifyUpdateBeforeExtraction'], True)

    def test_generated_settings_and_m00_are_separate(self):
        ota_settings = configurations(self.ota, self.ota_host)
        m00_settings = configurations(self.m00, host(self.m00))
        for configuration in ('Debug', 'Release'):
            ota = ota_settings[configuration]
            expected = {
                'PRODUCT_BUNDLE_IDENTIFIER': 'org.floeagent.macbridge',
                'INFOPLIST_FILE': 'Resources/FloeMacHost-OTA-Info.plist',
                'MARKETING_VERSION': '$(FLOE_OTA_VERSION)',
                'CURRENT_PROJECT_VERSION': '$(FLOE_OTA_BUILD)',
                'DEVELOPMENT_TEAM': '$(FLOE_OTA_TEAM)',
                'CODE_SIGN_IDENTITY': '$(FLOE_OTA_IDENTITY)',
                'CODE_SIGNING_ALLOWED': 'YES', 'CODE_SIGNING_REQUIRED': 'YES',
                'ENABLE_HARDENED_RUNTIME': 'YES',
            }
            for key, value in expected.items():
                self.assertEqual(ota[key], value, (configuration, key))
            self.assertEqual(m00_settings[configuration]['PRODUCT_BUNDLE_IDENTIFIER'], 'org.floeagent.mac')
            self.assertNotEqual(m00_settings[configuration].get('INFOPLIST_FILE'), expected['INFOPLIST_FILE'])
        names = {p.name for p in (MAC / 'FloeMacOTA.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme')}
        self.assertEqual(names, {
            'FloeMacOTACandidate.xcscheme',
            'FloeMacOTABridgeService.xcscheme',
            'FloeMacOTAAgentUI.xcscheme',
        })
        script = (MAC / 'scripts/build_m00.sh').read_text()
        self.assertNotIn('FloeMacOTA', script)
        self.assertNotIn('project-ota.yml', script)

    def test_sparkle_is_pinned_and_uses_automatic_framework_embedding(self):
        refs = [v for v in self.ota.values() if v.get('isa') == 'XCRemoteSwiftPackageReference'
                and v.get('repositoryURL') == 'https://github.com/sparkle-project/Sparkle']
        self.assertEqual(len(refs), 1)
        self.assertEqual(refs[0]['requirement'], {'kind': 'revision', 'revision': REVISION})
        products = [i for i in self.ota_host.get('packageProductDependencies', [])
                    if self.ota[i].get('productName') == 'Sparkle']
        self.assertEqual(len(products), 1)
        embed = [self.ota[i] for i in self.ota_host['buildPhases']
                 if self.ota[i].get('isa') == 'PBXCopyFilesBuildPhase']
        entries = [self.ota[i] for phase in embed for i in phase.get('files', [])
                   if self.ota[i].get('productRef') == products[0]]
        self.assertEqual(entries, [])
        m00_host = host(self.m00)
        self.assertFalse(any(self.m00[i].get('productName') == 'Sparkle'
                             for i in m00_host.get('packageProductDependencies', [])))

    def test_generated_validation_script_rejects_missing_or_invalid_inputs(self):
        identity = 'Developer ID Application: Synthetic Fixture (QYL72C43K6)'
        fixture = {'PATH': '/usr/bin:/bin', 'FLOE_OTA_VERSION': '1.1.7', 'FLOE_OTA_BUILD': '10',
                   'FLOE_OTA_TEAM': 'QYL72C43K6', 'DEVELOPMENT_TEAM': 'QYL72C43K6',
                   'FLOE_OTA_IDENTITY': identity, 'CODE_SIGN_IDENTITY': identity,
                   'CODE_SIGNING_ALLOWED': 'YES', 'CODE_SIGNING_REQUIRED': 'YES',
                   'ENABLE_HARDENED_RUNTIME': 'YES'}
        def run(env):
            return subprocess.run(['/bin/sh', '-c', self.phase['shellScript']], env=env,
                                  capture_output=True, text=True)
        self.assertNotEqual(run({'PATH': '/usr/bin:/bin'}).returncode, 0)
        success = run(fixture)
        self.assertEqual(success.returncode, 0, success.stderr)
        for changes in ({'FLOE_OTA_VERSION': '1.1.6'}, {'FLOE_OTA_VERSION': 'bogus'},
                        {'FLOE_OTA_BUILD': '9'}, {'FLOE_OTA_BUILD': ''},
                        {'FLOE_OTA_TEAM': 'WRONG'}, {'DEVELOPMENT_TEAM': 'WRONG'},
                        {'FLOE_OTA_IDENTITY': '-'}, {'CODE_SIGN_IDENTITY': '-'},
                        {'CODE_SIGNING_ALLOWED': 'NO'}, {'CODE_SIGNING_REQUIRED': 'NO'},
                        {'ENABLE_HARDENED_RUNTIME': 'NO'}):
            with self.subTest(changes=changes):
                result = run({**fixture, **changes})
                self.assertNotEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
