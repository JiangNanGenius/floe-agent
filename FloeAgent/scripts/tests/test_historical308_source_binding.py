"""Small synthetic contracts, not a real308/codesign/Actions acceptance claim.

Actual archive safety, manifest hashing and unsigned device audit run. Only
GitHub transport/signature responses and Apple's normalization are scripted;
the fixtures have no genuine signatures. Real308 byte projection is pending.
"""
import copy
import importlib.util
import contextlib
import io
import sys
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('binding', HERE.parent / 'historical308_source_binding.py')
binding = importlib.util.module_from_spec(spec); spec.loader.exec_module(binding)


def macho():
    command = struct.pack('<IIIIII', 0x32, 24, 2, 0x001A0000, 0x001B0000, 0)
    return struct.pack('<IiiIIIII', 0xFEEDFACF, 0x0100000C, 0, 2, 1, len(command), 0, 0) + command


class Historical308SourceBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = 'a' * 40
        self.controller = {'commit': 'c' * 40, 'ref': 'refs/tags/packaging/historical308-v1',
                           'runID': 81, 'runAttempt': 1, 'workflow': binding.WORKFLOW}
        self.policy = {'schemaVersion': 2, 'purpose': 'historical308-preparation-only-v2', 'normalization': binding.NORMALIZATION,
            'app': {'tag': binding.TAG, 'tagObjectSHA': 'b' * 40, 'sourceCommit': self.source,
                    'version': binding.VERSION, 'build': binding.BUILD, 'bundleIdentifier': binding.BUNDLE},
            'original': {'runID': 41, 'runAttempt': 1, 'artifactID': 51, 'archiveSHA256': '', 'archiveBytes': 0},
            'transport': {'archiveSHA256': '', 'archiveBytes': 0, 'releaseID': 61, 'assetID': 71},
            'expectedManifest': {'sha256': None, 'files': None, 'bytes': None}, 'packagerSHA256': 'd' * 64}
        self.source_archive = self.root / 'original.zip'
        self.transport = self.root / 'transport.zip'
        self.api_calls, self.signature_calls, self.normalize_calls = [], [], []
        self.verification_number = 0
        self.make_archives()
        # Review derives the complete fixture manifest, just as an offline
        # real-artifact review must before any reviewed policy is enabled.
        reviewed = binding.review_archives(self.policy, self.source_archive, self.transport,
                                          self.root / 'offline-review', self.normalize)
        self.policy['expectedManifest'] = reviewed['manifest']
        self.policy_file = self.root / 'reviewed-policy.json'; self.write_policy()
        self.controller_file = self.root / 'reviewed-controller.json'
        self.controller_file.write_bytes(binding.canonical(self.controller))
        output = self.root / 'subjects'; output.mkdir()
        self.ipa = output / binding.IPA_NAME
        with zipfile.ZipFile(self.ipa, 'w') as archive:
            for path in sorted(reviewed['app'].rglob('*')):
                if path.is_file(): archive.write(path, 'Payload/Floe Agent.app/' + path.relative_to(reviewed['app']).as_posix())
        self.ipa.with_suffix('.ipa.sha256').write_text(binding.digest(self.ipa) + '  ' + self.ipa.name + '\n')
        record = binding.binding_for(self.policy, binding.digest(self.policy_file), self.controller, reviewed, self.ipa)
        self.record = self.ipa.parent / binding.BINDING_NAME; self.record.write_bytes(binding.canonical(record))
        self.normalize_calls.clear()

    def write_policy(self):
        self.policy_file.write_bytes(binding.canonical(self.policy))

    def make_archives(self, resource=b'original resource', resource_mode=None):
        info = plistlib.dumps({'CFBundleIdentifier': binding.BUNDLE,
            'CFBundleShortVersionString': binding.VERSION, 'CFBundleVersion': binding.BUILD,
            'CFBundleExecutable': 'Floe Agent', 'DTSDKName': 'iphoneos27.1', 'DTPlatformName': 'iphoneos',
            'MinimumOSVersion': '26.0'})
        signed = self.root / 'FloeAgent.ipa'
        with zipfile.ZipFile(signed, 'w') as archive:
            for name, data in [('Info.plist', info), ('Floe Agent', macho()), ('Asset.txt', b'original resource'),
                               ('_CodeSignature/CodeResources', b'synthetic signature fixture')]:
                archive.writestr('Payload/Floe Agent.app/' + name, data)
        with zipfile.ZipFile(self.source_archive, 'w') as archive:
            archive.write(signed, 'FloeAgent.ipa')
            archive.writestr('TESTFLIGHT-SUMMARY.txt', 'tag=v1.7.67\nversion=1.7.67\nbuild=308\ncommit=' + self.source + '\napp_rebuilt=False\ntestflight_upload=accepted_by_transport\n')
        with zipfile.ZipFile(self.transport, 'w') as archive:
            for name, data in [('Info.plist', info), ('Floe Agent', macho()), ('Asset.txt', resource)]:
                member = 'Payload/Floe Agent.app/' + name
                if name == 'Asset.txt' and resource_mode is not None:
                    member = zipfile.ZipInfo(member); member.create_system = 3
                    member.external_attr = (0o100000 | resource_mode) << 16
                archive.writestr(member, data)
            archive.writestr('provenance.json', json.dumps({'source_sha': self.source, 'version': binding.VERSION, 'build': binding.BUILD}))
        for file, entry in [(self.source_archive, self.policy['original']), (self.transport, self.policy['transport'])]:
            entry['archiveSHA256'], entry['archiveBytes'] = binding.digest(file), file.stat().st_size

    def normalize(self, app, *, signed=False, require_unsigned=False):
        self.normalize_calls.append((signed, require_unsigned))
        signature = Path(app) / '_CodeSignature'
        if require_unsigned: self.assertFalse(signature.exists())
        removed = [p.relative_to(app).as_posix() for p in [signature, *signature.rglob('*')]] if signature.exists() else []
        if signature.exists(): shutil.rmtree(signature)
        binary = Path(app) / 'Floe Agent'
        return {'files': [{'path': 'Floe Agent', 'mode': binary.stat().st_mode & 0o7777,
                           'inputSHA256': binding.digest(binary), 'inputBytes': binary.stat().st_size,
                           'outputSHA256': binding.digest(binary), 'outputBytes': binary.stat().st_size,
                           'nonSignatureDataUnchanged': True, 'finalUnsigned': True, 'scriptedFixtureOnly': True}],
                'removedSigningEntries': sorted(removed), 'privateCommandLog': []}

    def api(self, path):
        self.assertGreaterEqual(len(self.signature_calls), 2)
        self.api_calls.append(path); original = self.policy['original']; transport = self.policy['transport']
        if path == 'git/ref/tags/' + binding.TAG:
            return {'ref': 'refs/tags/' + binding.TAG, 'object': {'type': 'tag', 'sha': 'b' * 40}}
        if path == 'git/tags/' + 'b' * 40:
            return {'sha': 'b' * 40, 'tag': binding.TAG, 'object': {'type': 'commit', 'sha': self.source}}
        if path == 'actions/runs/41/attempts/1':
            return {'id': 41, 'run_attempt': 1, 'head_repository': {'full_name': binding.REPOSITORY},
                    'head_sha': self.source, 'head_branch': binding.TAG, 'path': binding.SOURCE_WORKFLOW,
                    'event': 'workflow_dispatch', 'status': 'completed', 'conclusion': 'success',
                    'run_started_at': '2026-11-03T00:00:00Z', 'updated_at': '2026-11-03T00:10:00Z'}
        if path == 'actions/artifacts/51':
            return {'id': 51, 'name': 'testflight-1.7.67-build308', 'expired': False,
                    'digest': 'sha256:' + original['archiveSHA256'], 'size_in_bytes': original['archiveBytes'],
                    'workflow_run': {'id': 41, 'head_sha': self.source}, 'created_at': '2026-11-03T00:05:00Z'}
        if path == 'actions/runs/41/attempts/1/jobs?per_page=100':
            return {'total_count': 1, 'jobs': [{'conclusion': 'success', 'steps': [{'name': 'Confirm Apple processing and existing internal Floe QA availability', 'conclusion': 'success'}]}]}
        if path == 'releases/61': return {'id': 61, 'draft': True, 'assets': [{'id': 71}]}
        if path == 'releases/assets/71':
            return {'id': 71, 'name': 'local-device.zip', 'state': 'uploaded', 'size': transport['archiveBytes'], 'digest': 'sha256:' + transport['archiveSHA256']}
        if path == 'git/ref/tags/packaging/historical308-v1':
            return {'ref': self.controller['ref'], 'object': {'type': 'commit', 'sha': self.controller['commit']}}
        if path == 'actions/runs/81/attempts/1':
            return {'id': 81, 'run_attempt': 1, 'head_repository': {'full_name': binding.REPOSITORY},
                    'head_sha': self.controller['commit'], 'head_branch': 'packaging/historical308-v1',
                    'path': binding.WORKFLOW, 'event': 'workflow_dispatch', 'status': 'completed', 'conclusion': 'success'}
        raise AssertionError('Unexpected read API: ' + path)

    def signatures(self, command, **kwargs):
        self.signature_calls.append(command)
        path = Path(command[3]); controller = self.controller
        statement = {'predicateType': 'https://slsa.dev/provenance/v1',
            'subject': [{'name': path.name, 'digest': {'sha256': binding.digest(path)}}],
            'predicate': {'runDetails': {'builder': {'id': f"https://github.com/{binding.REPOSITORY}/{binding.WORKFLOW}@{controller['ref']}"},
                'metadata': {'invocationId': f"https://github.com/{binding.REPOSITORY}/actions/runs/81/attempts/1"}}}}
        return subprocess.CompletedProcess(command, 0, json.dumps([{'verificationResult': {'statement': statement}}]), '')

    def verify(self, **kwargs):
        self.verification_number += 1
        return binding.verify(self.policy_file, self.controller_file, self.ipa, self.record,
            self.source_archive, self.transport, self.root / ('verify-' + str(self.verification_number)),
            api_get=kwargs.get('api_get', self.api), invoke=kwargs.get('invoke', self.signatures), normalize=self.normalize)

    def test_complete_source_chain_and_manifest_pass_only_as_preparation_not_publication(self):
        result = self.verify()
        self.assertTrue(result['verified']); self.assertTrue(result['preparationOnly'])
        self.assertFalse(result['publicationAuthorized'])
        self.assertNotEqual(result['appSource'], result['packagingController']['commit'])
        self.assertEqual(result['deviceManifest']['files'], 3)
        self.assertEqual(len(self.signature_calls), 2)
        for command in self.signature_calls:
            for flag in ('--source-ref', '--source-digest', '--signer-digest', '--signer-workflow', '--deny-self-hosted-runners'):
                self.assertIn(flag, command)
        record = binding.read_json(self.record)
        self.assertNotIn('assetID', record['transport'])
        self.assertNotIn('releaseID', record['transport'])

    def test_signature_failure_precedes_binding_parse_and_all_source_api_trust(self):
        self.record.write_text('{not-json')
        def denied(command, **kwargs):
            if len(self.signature_calls) == 1: raise subprocess.CalledProcessError(1, command)
            return self.signatures(command, **kwargs)
        with self.assertRaises(subprocess.CalledProcessError): self.verify(invoke=denied)
        self.assertEqual(len(self.signature_calls), 1)
        self.assertEqual(self.api_calls, [])
        self.assertEqual(self.normalize_calls, [])

    def test_wrong_attestation_run_cannot_reach_binding_or_source_metadata(self):
        def wrong(command, **kwargs):
            result = self.signatures(command, **kwargs)
            result.stdout = result.stdout.replace('/runs/81/', '/runs/82/')
            return result
        with self.assertRaises(binding.BindingError) as error: self.verify(invoke=wrong)
        self.assertEqual(error.exception.code, 'attestationIdentity')
        self.assertEqual(self.api_calls, [])

    def test_expired_original_or_changed_source_controller_or_private_transport_is_rejected(self):
        for mutation in ('expired', 'source', 'controller', 'public transport', 'wrong artifact attempt'):
            with self.subTest(mutation=mutation):
                self.api_calls.clear()
                def changed(path):
                    value = copy.deepcopy(self.api(path))
                    if mutation == 'expired' and path == 'actions/artifacts/51': value['expired'] = True
                    elif mutation == 'source' and path == 'git/tags/' + 'b' * 40: value['object']['sha'] = 'f' * 40
                    elif mutation == 'controller' and path == 'actions/runs/81/attempts/1': value['head_sha'] = 'f' * 40
                    elif mutation == 'public transport' and path == 'releases/61': value['draft'] = False
                    elif mutation == 'wrong artifact attempt' and path == 'actions/artifacts/51': value['created_at'] = '2026-11-02T00:00:00Z'
                    return value
                with self.assertRaises((binding.BindingError, ValueError)): self.verify(api_get=changed)

    def test_matching_new_archive_hash_does_not_excuse_changed_device_resource(self):
        for mutation in ('resource', 'empty directory', 'permission'):
            with self.subTest(mutation=mutation):
                self.make_archives(resource=b'modified resource' if mutation == 'resource' else b'original resource',
                                   resource_mode=0o644 if mutation == 'permission' else None)
                if mutation == 'empty directory':
                    with zipfile.ZipFile(self.transport, 'a') as archive:
                        archive.writestr('Payload/Floe Agent.app/ExtraEmpty/', b'')
                    self.policy['transport']['archiveSHA256'] = binding.digest(self.transport)
                    self.policy['transport']['archiveBytes'] = self.transport.stat().st_size
                self.write_policy()
                # Both metadata digests truthfully match the changed archive;
                # the full manifest must still detect altered files/empty dirs.
                with self.assertRaises(binding.BindingError) as error: self.verify()
                self.assertEqual(error.exception.code, 'normalizationMismatch')

    def test_unknown_fractional_or_forged_binding_fields_cannot_replace_reconstructed_proof(self):
        original = self.record.read_bytes()
        for key, value in [('schemaVersion', 2.0), ('unsigned', 1), ('unknown', True)]:
            with self.subTest(key=key):
                record = json.loads(original); record[key] = value
                self.record.write_bytes(binding.canonical(record)); self.api_calls.clear()
                with self.assertRaises(binding.BindingError): self.verify()

    def test_unreviewed_manifest_and_malformed_policy_are_rejected(self):
        legacy = copy.deepcopy(self.policy); legacy['schemaVersion'] = 1
        legacy['purpose'] = 'historical308-preparation-only'; legacy.pop('normalization')
        with self.assertRaises(binding.BindingError): binding.validate_policy(legacy)
        invalid = copy.deepcopy(self.policy); invalid['expectedManifest']['sha256'] = None
        with self.assertRaises(binding.BindingError) as error: binding.validate_policy(invalid)
        self.assertEqual(error.exception.code, 'missingReviewedManifest')
        invalid = copy.deepcopy(self.policy); invalid['original']['artifactID'] = 51.0
        with self.assertRaises(binding.BindingError): binding.validate_policy(invalid)
        for text in ('{"schemaVersion":1,"schemaVersion":1}', '{"x":NaN}'):
            self.policy_file.write_text(text)
            with self.assertRaises(binding.BindingError): binding.read_json(self.policy_file)
        self.write_policy()
        real_ipa = self.ipa
        self.ipa = self.root / 'linked' / binding.IPA_NAME; self.ipa.parent.mkdir()
        self.ipa.symlink_to(real_ipa)
        with self.assertRaises(binding.BindingError): self.verify()
        self.assertEqual(self.signature_calls, [])

    def test_apple_auto_removed_signing_entries_are_frozen_before_tools_and_other_resources_still_reject(self):
        for deletes_resource in (False, True):
            with self.subTest(deletes_resource=deletes_resource):
                app = self.root / str(deletes_resource) / 'Floe Agent.app'; app.mkdir(parents=True)
                (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Floe Agent'}))
                binary = app / 'Floe Agent'; binary.write_bytes(macho())
                resource = app / 'Asset.txt'; resource.write_bytes(b'original resource')
                signature = app / '_CodeSignature'; signature.mkdir()
                (signature / 'CodeResources').write_bytes(b'original signing record')
                _, before = binding.file_manifest(app)
                def apple_operation(*args, **kwargs):
                    shutil.rmtree(signature)  # Actual Apple's early-removal behavior.
                    if deletes_resource: resource.unlink()
                    return {'files': [{'path': 'Floe Agent', 'mode': binary.stat().st_mode & 0o7777,
                               'inputSHA256': binding.digest(binary), 'inputBytes': binary.stat().st_size,
                               'outputSHA256': binding.digest(binary), 'outputBytes': binary.stat().st_size,
                               'nonSignatureDataUnchanged': True, 'finalUnsigned': True}], 'privateCommandLog': []}
                with mock.patch.object(binding.projection, 'normalize_machos', side_effect=apple_operation):
                    proof = binding.apple_normalize(app, signed=True)
                _, after = binding.file_manifest(app)
                self.assertEqual(proof['removedSigningEntries'], ['_CodeSignature', '_CodeSignature/CodeResources'])
                if deletes_resource:
                    with self.assertRaises(binding.BindingError): binding.resource_preservation(before, after, proof)
                else:
                    checked = binding.resource_preservation(before, after, proof)
                    self.assertEqual(checked['verifiedMachOFiles'], 1)

    def test_unsigned_ipa_cannot_be_repaired_by_projection_before_comparison(self):
        # This ZIP still passes the actual arm64/IOS/version IPA audit. Its raw
        # executable bytes differ; a "repair" callback must not make it valid.
        target = self.root / 'noncanonical' / binding.IPA_NAME; target.parent.mkdir()
        with zipfile.ZipFile(self.ipa) as original, zipfile.ZipFile(target, 'w') as output:
            for info in original.infolist():
                data = original.read(info)
                if info.filename.endswith('/Floe Agent'): data += b'noncanonical raw bytes'
                output.writestr(info, data)
        target.with_suffix('.ipa.sha256').write_text(binding.digest(target) + '  ' + target.name + '\n')
        app = self.root / 'offline-review/transport/Payload/Floe Agent.app'
        manifest, entries = binding.file_manifest(app)
        def repair(app, **kwargs):
            self.assertTrue(kwargs['require_unsigned'])
            (Path(app) / 'Floe Agent').write_bytes(macho())
        with self.assertRaises(binding.BindingError) as error:
            binding.verify_output(target, {'manifest': manifest, 'entries': entries}, self.root / 'output-repair-test', repair)
        self.assertEqual(error.exception.code, 'outputNotCanonical')

    def test_static_schema_and_preparation_route_keep_scoped_access_without_publication(self):
        schema = json.loads((HERE.parent / 'schemas/historical-source-binding-v2.schema.json').read_text())
        self.assertFalse(schema['additionalProperties'])
        self.assertEqual(set(schema['required']), set(binding.read_json(self.record)))
        try:
            import jsonschema
        except ImportError:
            jsonschema = None
        if jsonschema is not None: jsonschema.Draft202012Validator(schema).validate(binding.read_json(self.record))
        root = HERE.parents[2]
        text = (root / '.github/workflows/prepare-historical308.yml').read_text()
        global_permissions = text.split('\npermissions:\n', 1)[1].split('\nconcurrency:', 1)[0]
        self.assertIn('  contents: read\n', global_permissions)
        self.assertNotIn('contents: write', global_permissions)
        prepare_job = text.split('\n  prepare:\n', 1)[1].split('    env:\n', 1)[0]
        self.assertIn('    permissions:\n      contents: write\n      actions: read\n', prepare_job)
        self.assertEqual(text.count('contents: write'), 1)
        self.assertNotIn('gh release create', text); self.assertNotIn('publish-feather', text)
        self.assertNotIn('testflightUpload', text); self.assertNotIn('feather_recovery_trust', text)
        self.assertIn('historical308-reviewed-v2.json', text)
        reviewed_policy = HERE.parent / 'release-policies/historical308-reviewed-v2.json'
        self.assertEqual(binding.digest(reviewed_policy), '4b2caa0caebc4ab9d1ce192ce2ec37160bed47b49a14cebee395608cc2b021d9')
        policy = binding.read_json(reviewed_policy)
        binding.validate_policy(policy)
        self.assertEqual(policy['purpose'], 'historical308-preparation-only-v2')
        self.assertEqual(policy['app']['sourceCommit'], '3368baaf8045023043bfb70d9062374c17a48a1d')

    def test_prepare_manifest_mismatch_retains_complete_diagnostics_before_original_refusal(self):
        self.policy['expectedManifest']['sha256'] = '0' * 64
        self.write_policy()
        policy_before = self.policy_file.read_bytes()
        work, output = self.root / 'prepare-mismatch', self.root / 'no-subjects'
        real_review = binding.review_archives
        def review(*args):
            return real_review(*args, normalize=self.normalize)
        argv = ['historical308_source_binding.py', 'prepare', '--policy', str(self.policy_file),
                '--original-archive', str(self.source_archive), '--transport-archive', str(self.transport),
                '--work', str(work), '--output', str(output), '--packager', str(self.root / 'must-not-run.sh')]
        capture = io.StringIO()
        with mock.patch.object(sys, 'argv', argv), \
                mock.patch.object(binding, 'context_controller', return_value=self.controller), \
                mock.patch.object(binding, 'check_sources') as source_checks, \
                mock.patch.object(binding, 'review_archives', side_effect=review), \
                contextlib.redirect_stdout(capture):
            with self.assertRaises(binding.BindingError) as error:
                binding.main()
        self.assertEqual(error.exception.code, 'reviewedManifest')
        source_checks.assert_called_once()
        self.assertFalse(output.exists())
        self.assertEqual(self.policy_file.read_bytes(), policy_before)
        diagnostic = work / 'manifest-mismatch'
        summary = json.loads((diagnostic / 'DIAGNOSTICS.private.json').read_text())
        entries = json.loads((diagnostic / 'DEVICE-MANIFEST.private.json').read_text())
        proofs = json.loads((diagnostic / 'NORMALIZATION-PROOF.private.json').read_text())
        rows = json.loads((diagnostic / 'MACHO-OUTPUTS.private.json').read_text())
        self.assertEqual(summary['expectedManifest'], self.policy['expectedManifest'])
        self.assertNotEqual(summary['actualManifest'], summary['expectedManifest'])
        self.assertEqual(summary['entryCounts']['total'], len(entries))
        self.assertEqual(summary['machOFileCount'], 1)
        self.assertEqual(rows[0]['path'], 'Floe Agent')
        self.assertEqual(rows[0]['signed']['outputSHA256'], rows[0]['transport']['outputSHA256'])
        self.assertEqual(rows[0]['signed']['outputSHA256'], proofs['signed']['files'][0]['outputSHA256'])
        self.assertEqual(diagnostic.stat().st_mode & 0o777, 0o700)
        self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in diagnostic.iterdir()))
        self.assertIn('HISTORICAL308_MANIFEST_MISMATCH=', capture.getvalue())
        self.assertEqual(capture.getvalue().count('HISTORICAL308_MACHO_OUTPUT='), 1)

    def test_matching_review_creates_no_diagnostics_or_log(self):
        reviewed = binding.review_archives(self.policy, self.source_archive, self.transport,
                                          self.root / 'matching-review', self.normalize)
        work = self.root / 'no-diagnostics'
        capture = io.StringIO()
        with contextlib.redirect_stdout(capture):
            binding.report_manifest_mismatch(self.policy, reviewed, work)
        self.assertFalse(work.exists())
        self.assertEqual(capture.getvalue(), '')

    def test_diagnostic_destination_collision_cannot_overwrite_or_bypass_manifest_failure(self):
        self.policy['expectedManifest']['sha256'] = '0' * 64
        self.write_policy()
        work = self.root / 'verify-1'; work.mkdir()
        outside = self.root / 'outside'; outside.mkdir()
        sentinel = outside / 'keep'; sentinel.write_text('original')
        (work / 'manifest-mismatch').symlink_to(outside, target_is_directory=True)
        capture, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(capture), contextlib.redirect_stderr(errors):
            with self.assertRaises(binding.BindingError) as error:
                self.verify()
        self.assertEqual(error.exception.code, 'reviewedManifest')
        self.assertEqual(sentinel.read_text(), 'original')
        self.assertEqual([p.name for p in outside.iterdir()], ['keep'])
        self.assertIn('HISTORICAL308_MANIFEST_MISMATCH=', capture.getvalue())
        self.assertIn('HISTORICAL308_DIAGNOSTIC_ERROR=FileExistsError', errors.getvalue())

    def test_failure_artifact_route_is_private_bounded_and_does_not_change_subjects(self):
        text = (HERE.parents[2] / '.github/workflows/prepare-historical308.yml').read_text()
        failure = text.split('      - name: Retain private manifest mismatch diagnostics after preparation failure\n')[1].split('      - name: Genuinely attest')[0]
        self.assertIn("failure() && steps.prepare.outcome == 'failure'", failure)
        self.assertIn('historical308/work/manifest-mismatch/', failure)
        self.assertNotIn('subjects', failure)
        self.assertNotIn('gh release', failure)
        self.assertIn('actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02', failure)

    def test_plan_and_selective_extraction_skip_symbols_but_keep_the_complete_app(self):
        with zipfile.ZipFile(self.transport, 'a') as archive:
            archive.writestr('symbols/ignored.dSYM/Contents/Resources/DWARF/image', b'unneeded symbol bytes' * 1000)
        self.policy['transport']['archiveSHA256'] = binding.digest(self.transport)
        self.policy['transport']['archiveBytes'] = self.transport.stat().st_size
        plan = binding.plan_archives(self.policy, self.source_archive, self.transport, self.root / 'plan')
        self.assertFalse(plan['provenanceVerified']); self.assertFalse(plan['publicationAuthorized'])
        self.assertFalse(plan['archiveDigestsVerified'])
        self.assertEqual(plan['unsignedTransportApp']['skippedMembers'], 1)
        self.assertEqual(plan['unsignedTransportApp']['skippedBytes'], 21000)
        review = binding.review_archives(self.policy, self.source_archive, self.transport,
                                         self.root / 'app-only', self.normalize)
        self.assertEqual(review['manifest'], self.policy['expectedManifest'])
        self.assertFalse((self.root / 'app-only/transport/symbols').exists())
        self.assertEqual(len(review['entries']), 4)  # Includes the App root directory/mode.
        self.assertGreater(plan['reviewScratchUpperBoundBytes'], plan['signedApp']['selectedBytes'])


if __name__ == '__main__':
    unittest.main()
