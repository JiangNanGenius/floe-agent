#!/usr/bin/env python3
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
from build_office_native_host import (EXCLUDED_SOURCES, SYSTEM_FRAMEWORKS, HOST_PUBLIC_HEADER,
                                      SWIFT_IMPORT_PROBE, framework_project,
                                      verify_swift_import_probe)
import build_office_native_host as build_host
import office_render_gate_swift
import office_render_readiness
from qualify_office_device_capabilities import qualify as device_qualify
from verify_pptx_deck_semantics import DEFAULT_DECK, digest
from office_release_gates import (CAPABILITY_FLAGS, capability_status, false_capabilities,
                                  host_source_matches_pin, validate_capability_claims)
from pin_office_host_artifact import LOCK, check as pin_check


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
        self.assertEqual(set(files), {'CODocument.mm', 'DocumentViewController.mm', 'Kit.cpp',
                                    '/owned host/FloeOfficeNative.mm', '/owned host/FloeOfficeAttachment.cpp'})
        self.assertEqual(original, unchanged)
        self.assertEqual(prepared['target']['productType'], 'com.apple.product-type.framework')

    def test_keeps_runtime_resources_and_complete_link_inputs_without_app_identity(self):
        prepared = framework_project(self.project(), Path('/host'))['objects']
        self.assertEqual(prepared['resources']['files'], ['resource-' + name for name in ['rc', 'program', 'share', 'cool.html', 'bundle.js']])
        settings = prepared['release']['buildSettings']
        self.assertEqual(settings['OTHER_LDFLAGS'], ['-filelist', 'complete.list']
            + [flag for name in SYSTEM_FRAMEWORKS for flag in ['-framework', name]])
        self.assertEqual(settings['HEADER_SEARCH_PATHS'], ['qualified/engine'])
        self.assertNotIn('CODE_SIGN_ENTITLEMENTS', settings)
        self.assertEqual(settings['MACH_O_TYPE'], 'mh_dylib')

    def test_changed_upstream_application_boundary_fails_closed(self):
        project = self.project()
        project['objects']['sources']['files'].remove('build-main.m')
        with self.assertRaisesRegex(ValueError, 'boundaries changed'):
            framework_project(project, Path('/host'))


class SwiftImportProbeContractTests(unittest.TestCase):
    """The generated ImportProbe must match how Swift imports the host header."""

    @staticmethod
    def _iphoneos_sdk():
        result = subprocess.run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'],
                                capture_output=True, text=True)
        path = result.stdout.strip()
        return path if result.returncode == 0 and path else None

    def test_header_and_probe_agree_on_render_diagnostics(self):
        # Static contract: the property the cloud run rejected is imported from
        # NSDictionary<NSString *, id> * into Swift as [String: Any]?. This pins
        # the expectation to the real public declaration even without an SDK.
        header = HOST_PUBLIC_HEADER.read_text()
        self.assertRegex(
            header,
            r'@property[^\n]*nullable\)\s*NSDictionary<NSString \*, id> \*renderDiagnostics;')
        probe = SWIFT_IMPORT_PROBE.read_text()
        self.assertIn('let _: [String: Any]? = editor.renderDiagnostics', probe)
        self.assertNotIn('let _: NSDictionary? = editor.renderDiagnostics', probe)

    def test_build_copies_the_verified_probe_verbatim(self):
        # build_host must generate ImportProbe.swift from the exact fixture this
        # contract checks, not a second, drifting copy.
        source = Path(__file__).resolve().parent / 'build_office_native_host.py'
        text = source.read_text()
        self.assertIn('shutil.copyfile(SWIFT_IMPORT_PROBE, probe)', text)
        self.assertEqual(SWIFT_IMPORT_PROBE.name, 'office_native_host_api.swift')

    def test_generated_probe_compiles_against_the_real_host_header(self):
        sdk = self._iphoneos_sdk()
        if not sdk:
            self.skipTest('iphoneos SDK unavailable; the cloud build runs this gate')
        receipt = verify_swift_import_probe(sdk=sdk)
        self.assertTrue(receipt['swiftImportProbeCompiled'])
        # A header-only type-check must never fabricate an engine/device result.
        self.assertFalse(receipt['engineVisibleRenderPassed'])
        self.assertFalse(receipt['deviceVisibleRenderPassed'])
        self.assertEqual(receipt['swiftProbeSHA256'],
                         hashlib.sha256(SWIFT_IMPORT_PROBE.read_bytes()).hexdigest())

    def test_old_nsdictionary_expectation_is_rejected(self):
        # The exact cloud regression: NSDictionary? against a property Swift
        # imports as [String: Any]? must fail the gate rather than be weakened.
        sdk = self._iphoneos_sdk()
        if not sdk:
            self.skipTest('iphoneos SDK unavailable; the cloud build runs this gate')
        buggy = SWIFT_IMPORT_PROBE.read_text().replace(
            'let _: [String: Any]? = editor.renderDiagnostics',
            'let _: NSDictionary? = editor.renderDiagnostics')
        self.assertIn('NSDictionary?', buggy)
        with tempfile.TemporaryDirectory() as folder:
            bad_probe = Path(folder) / 'office_native_host_api.swift'
            bad_probe.write_text(buggy)
            with mock.patch.object(build_host, 'SWIFT_IMPORT_PROBE', bad_probe):
                with self.assertRaisesRegex(AssertionError, r"\[String : Any\]\?.*NSDictionary\?|ImportProbe"):
                    verify_swift_import_probe(sdk=sdk)


class OfficeReleaseGateTests(unittest.TestCase):
    def evidenced(self):
        return {
            'capabilityQualification': {
                'embeddedEditorPassed': True,
                'pptxVisibleRenderPassed': True,
                'deviceRoundtripPassed': True,
                'originalFileWritebackPassed': True,
            },
            'embeddedEditorEvidence': {'runID': '1', 'appBuildVersion': '219', 'payloadVerified': True,
                                       'recordedAt': '2026-09-22T00:00:00Z'},
            'pptxVisibleRenderEvidence': {'runID': '2', 'deviceModel': 'iPad14,3', 'osVersion': '26.0',
                                          'documentType': 'presentation', 'readyTiles': 6,
                                          'canvasWidth': 1024, 'canvasHeight': 768, 'elapsedMs': 2400,
                                          'recordedAt': '2026-09-22T00:00:00Z'},
            'deviceRoundtripEvidence': {'runID': '2', 'deviceModel': 'iPad14,3', 'osVersion': '26.0',
                                        'documentTypes': ['docx', 'xlsx', 'pptx'],
                                        'recordedAt': '2026-09-22T00:00:00Z'},
            'originalFileWritebackEvidence': {'runID': '2', 'deviceModel': 'iPad14,3',
                                              'documentType': 'pptx',
                                              'savedSHA256': 'a' * 64, 'recordedAt': '2026-09-22T00:00:00Z'},
        }

    def test_compile_only_receipt_cannot_claim_release_capabilities(self):
        self.assertEqual(validate_capability_claims({'capabilityQualification': false_capabilities()}), [])
        status = capability_status({'capabilityQualification': false_capabilities()})
        self.assertFalse(status['releaseReady'])
        self.assertEqual(sorted(status['unproven']), sorted(CAPABILITY_FLAGS))

    def test_fully_evidenced_capabilities_pass_the_release_gate(self):
        status = capability_status(self.evidenced())
        self.assertEqual(status['failures'], [])
        self.assertTrue(status['releaseReady'])

    def test_true_claim_without_evidence_is_rejected(self):
        claims = self.evidenced()
        del claims['pptxVisibleRenderEvidence']
        failures = validate_capability_claims(claims)
        self.assertTrue(any('pptxVisibleRenderPassed is claimed without pptxVisibleRenderEvidence' in failure
                            for failure in failures))
        self.assertFalse(capability_status(claims)['releaseReady'])

    def test_placeholder_or_impossible_device_facts_are_rejected(self):
        for mutation in ({'readyTiles': 0}, {'canvasWidth': 0}, {'canvasHeight': -4},
                         {'documentType': 'text'}, {'readyTiles': 'many'}):
            claims = self.evidenced()
            claims['pptxVisibleRenderEvidence'].update(mutation)
            self.assertTrue(validate_capability_claims(claims), mutation)
        claims = self.evidenced()
        claims['originalFileWritebackEvidence']['savedSHA256'] = 'not-a-digest'
        self.assertTrue(validate_capability_claims(claims))

    def test_inferred_capabilities_are_never_assumed(self):
        # An absent block or absent flag is unproven, never passed; a rejected
        # true claim is not passed either.
        for claims in ({}, {'capabilityQualification': {'embeddedEditorPassed': True}},
                       {'capabilityQualification': None}):
            status = capability_status(claims)
            self.assertFalse(status['releaseReady'])
            self.assertNotIn('passed', status['capabilities'].values())
        self.assertEqual(len(capability_status({})['unproven']), len(CAPABILITY_FLAGS))

    def test_pin_check_reports_capabilities_read_only(self):
        lock = json.loads(Path(LOCK).read_text())
        pin = lock['qualifiedHostArtifact']
        self.assertFalse(host_source_matches_pin({}, hashlib.sha256))
        status = capability_status(pin)
        self.assertFalse(status['releaseReady'])
        self.assertEqual(capability_status({})['unproven'], status['unproven'])
        with tempfile.TemporaryDirectory() as folder:
            copy_path = Path(folder) / 'engine.lock.json'
            copy_path.write_text(json.dumps(lock))
            # Read-only: reports 0 (matches the pin) or 1 (source ahead);
            # either way the lock content is untouched.
            self.assertIn(pin_check(copy_path), (0, 1))
            self.assertEqual(copy_path.read_text(), json.dumps(lock))

    def test_shipped_render_probe_and_native_decision_qualify_visible_render(self):
        # Runs the actual probe script and the compiled native decision against
        # synthetic engine states: a decoded tile passes, page skeletons and a
        # blank canvas never do.
        receipt = office_render_readiness.check()
        self.assertTrue(receipt['nativeDecisionCompiled'])
        self.assertFalse(receipt['engineVisibleRenderPassed'])
        self.assertFalse(receipt['deviceVisibleRenderPassed'])
        self.assertEqual(len(receipt['checksPassed']), 8)

    def test_shipped_swift_visible_render_gate_compiles_and_holds(self):
        receipt = office_render_gate_swift.check()
        self.assertTrue(receipt['swiftGateCompiled'])
        self.assertFalse(receipt['deviceVisibleRenderPassed'])
        self.assertEqual(len(receipt['checksPassed']), 6)

    def synthetic_device_receipts(self, folder):
        folder = Path(folder)
        folder.mkdir(parents=True, exist_ok=True)
        deck_digest = digest(DEFAULT_DECK)
        events = [{'event': 'opened'}, {'event': 'visibleRender'}, {'event': 'saveRequested'},
                  {'event': 'saveCompleted', 'detail': 'success'}, {'event': 'editingClosed'},
                  {'event': 'reopenedReadonly'}]
        (folder / 'render-receipt.json').write_text(json.dumps({
            'docType': 'presentation', 'visibleRender': True, 'readyTiles': 5,
            'canvasWidth': 1024, 'canvasHeight': 768, 'slideCount': 3,
            'deckSHA256': deck_digest, 'elapsedMs': 2100, 'recordedAt': '2026-09-22T00:00:00Z'}))
        (folder / 'events.json').write_text(json.dumps({'events': events}))
        for extension in ('docx', 'xlsx', 'pptx'):
            (folder / f'roundtrip-{extension}.json').write_text(json.dumps({
                'documentType': extension, 'edited': True, 'savedWorkingCopy': True,
                'closed': True, 'reopened': True, 'savedSHA256': 'c' * 64, 'events': events}))
        writeback = folder / 'original-writeback.json'
        writeback.write_text(json.dumps({
            'originalFileWriteback': True, 'documentType': 'pptx', 'savedSHA256': 'd' * 64,
            'deckSHA256': deck_digest, 'recordedAt': '2026-09-22T00:00:00Z'}))
        embedded = folder / 'embedding.json'
        embedded.write_text(json.dumps({
            'unsignedPayloadVerified': True, 'appVersion': '1.7.0', 'appBuild': '219',
            'hostExecutableSHA256': 'e' * 64}))
        return folder, writeback, embedded

    def test_device_capabilities_need_a_complete_roundtrip_and_are_never_inferred(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder, writeback, embedded = self.synthetic_device_receipts(temporary)
            evidence, failures = device_qualify(folder, DEFAULT_DECK, 'iPad14,3', '26.0', '1234',
                                                writeback, embedded)
            self.assertEqual(failures, [])
            self.assertTrue(capability_status(evidence)['releaseReady'])
            # Removing any single receipt, or a single device fact, fails closed.
            (folder / 'roundtrip-pptx.json').unlink()
            _, failures = device_qualify(folder, DEFAULT_DECK, 'iPad14,3', '26.0', '1234',
                                         writeback, embedded)
            self.assertTrue(any('roundtrip-pptx.json' in failure for failure in failures))
            folder, writeback, embedded = self.synthetic_device_receipts(temporary + '/second')
            _, failures = device_qualify(folder, DEFAULT_DECK, None, '26.0', '1234', writeback, embedded)
            self.assertTrue(any('device model' in failure for failure in failures))
            folder, writeback, embedded = self.synthetic_device_receipts(temporary + '/third')
            receipt = json.loads((folder / 'render-receipt.json').read_text())
            receipt['readyTiles'] = 0
            (folder / 'render-receipt.json').write_text(json.dumps(receipt))
            _, failures = device_qualify(folder, DEFAULT_DECK, 'iPad14,3', '26.0', '1234',
                                         writeback, embedded)
            self.assertTrue(any('readyTiles' in failure for failure in failures))
            folder, writeback, embedded = self.synthetic_device_receipts(temporary + '/fourth')
            events = {'events': [{'event': 'opened'}, {'event': 'visibleRender'},
                                 {'event': 'unexpectedClose'}]}
            (folder / 'events.json').write_text(json.dumps(events))
            _, failures = device_qualify(folder, DEFAULT_DECK, 'iPad14,3', '26.0', '1234',
                                         writeback, embedded)
            self.assertTrue(any('unexpectedClose' in failure for failure in failures))


if __name__ == '__main__':
    unittest.main()
