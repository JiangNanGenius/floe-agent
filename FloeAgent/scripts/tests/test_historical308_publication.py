import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

import yaml

SCRIPTS = Path(__file__).resolve().parents[1]
REPO = SCRIPTS.parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


v = load('publication308_contract', SCRIPTS / 'historical308_publication.py')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(data):
    return json.dumps(data, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


class Fixture:
    """Small synthetic device ZIP plus scripted GH crypto/API, never a real App claim."""
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(); self.root = Path(self.temporary.name)
        self.authority = self.root / 'authority'; self.authority.mkdir()
        policies = self.authority / 'release-policies'; policies.mkdir()
        self.ipa = self.root / v.b.IPA_NAME; self.binding = self.root / v.b.BINDING_NAME
        plist = plistlib.dumps({'CFBundleIdentifier': v.b.BUNDLE, 'CFBundleShortVersionString': v.b.VERSION,
            'CFBundleVersion': v.b.BUILD, 'CFBundleExecutable': 'Floe Agent', 'MinimumOSVersion': '26.0',
            'DTSDKName': 'iphoneos26.0', 'DTPlatformName': 'iphoneos'}, fmt=plistlib.FMT_BINARY)
        command = struct.pack('<IIIIII', 0x32, 24, 2, 0x001A0000, 0x001A0000, 0)
        executable = struct.pack('<IiiIIIII', 0xFEEDFACF, 0x0100000C, 0, 2, 1, len(command), 0, 0) + command
        self.members = [('Payload/', None, 0o755), ('Payload/Floe Agent.app/', None, 0o755),
            ('Payload/Floe Agent.app/Info.plist', plist, 0o644),
            ('Payload/Floe Agent.app/Floe Agent', executable, 0o755),
            ('Payload/Floe Agent.app/Assets.txt', b'exact resource', 0o640),
            ('Payload/Floe Agent.app/Empty/', None, 0o750)]
        self.write_ipa()
        # Independent explicit expected paths, contents, full permission modes,
        # root/empty directory and sort order. Never call the verifier to make
        # its own expected raw manifest.
        self.entries = [{'path': '.', 'kind': 'directory', 'mode': 0o755, 'executable': True},
            {'path': 'Assets.txt', 'kind': 'file', 'sha256': sha(b'exact resource'), 'bytes': 14, 'mode': 0o640, 'executable': False},
            {'path': 'Empty', 'kind': 'directory', 'mode': 0o750, 'executable': True},
            {'path': 'Floe Agent', 'kind': 'file', 'sha256': sha(executable), 'bytes': len(executable), 'mode': 0o755, 'executable': True},
            {'path': 'Info.plist', 'kind': 'file', 'sha256': sha(plist), 'bytes': len(plist), 'mode': 0o644, 'executable': False}]
        manifest = {'sha256': sha(canonical(self.entries)), 'files': 3,
                    'bytes': sum(x.get('bytes', 0) for x in self.entries)}
        self.policy = json.loads((SCRIPTS / 'release-policies' / v.POLICY_FILE).read_text())
        self.policy['expectedManifest'] = manifest
        self.proof = {'synthetic': 'private normalization proof fixture'}
        self.metadata_entries = [{'logicalPath': '._fixture', 'structure': {'bytes': 16}}]
        self.observed = {'signedIPA': {'sha256': '1' * 64, 'bytes': 100}, 'deviceManifest': manifest,
            'sourceRaw': {'sha256': '2' * 64, 'files': 4, 'bytes': 200},
            'transportRaw': {'sha256': '3' * 64, 'files': 4, 'bytes': 180},
            'metadata': {'sha256': sha(canonical(self.metadata_entries)), 'mappings': 1, 'bytes': 16},
            'normalizationProof': {'sha256': sha(canonical(self.proof)), 'files': 48}}
        reviewed = {'schemaVersion': 1, 'kind': 'floe.historical308.publication-review-v2',
            'reviewedMainSHA256': sha((SCRIPTS / 'historical308_source_binding.py').read_bytes()),
            'normalizerSHA256': sha((SCRIPTS / 'historical308_normalization_v2.py').read_bytes()),
            'review': self.observed, 'canonicalEntries': 5, 'protectedLatest': {'tag': 'v1.8.5', 'build': '325'}}
        policy_path, review_path = policies / v.POLICY_FILE, policies / v.REVIEW_FILE
        policy_path.write_bytes(json.dumps(self.policy, indent=2).encode() + b'\n')
        review_path.write_bytes(json.dumps(reviewed, indent=2).encode() + b'\n')
        self.activation = {'mode': v.MODE, 'sourceCommit': self.policy['app']['sourceCommit'],
            'packagingController': 'a' * 40, 'controllerRef': 'refs/tags/historical308-fixture-controller',
            'packagingRun': 901, 'packagingRunAttempt': 2, 'signerWorkflow': v.b.WORKFLOW,
            'unsignedArtifactID': 902, 'unsignedArtifactDigest': 'sha256:' + 'b' * 64,
            'unsignedArtifactSize': 123, 'policySHA256': sha(policy_path.read_bytes()), 'reviewSHA256': sha(review_path.read_bytes())}
        self.controller = {'commit': 'a' * 40, 'ref': self.activation['controllerRef'],
                           'runID': 901, 'runAttempt': 2, 'workflow': v.b.WORKFLOW}
        self.record = {'schemaVersion': 2, 'kind': 'floe.historical308.source-binding',
            'policySHA256': self.activation['policySHA256'], 'app': copy.deepcopy(self.policy['app']),
            'original': dict(self.policy['original'], signedIPA=self.observed['signedIPA']),
            'transport': {k: self.policy['transport'][k] for k in ('archiveSHA256', 'archiveBytes')},
            'deviceManifest': {'normalization': v.b.NORMALIZATION, 'canonical': manifest,
                'sourceRaw': self.observed['sourceRaw'], 'transportRaw': self.observed['transportRaw'],
                'metadata': self.observed['metadata'], 'normalizationProof': self.observed['normalizationProof']},
            'ipa': {'name': v.b.IPA_NAME, 'sha256': sha(self.ipa.read_bytes()), 'bytes': self.ipa.stat().st_size},
            'controller': self.controller, 'appRebuilt': False, 'unsigned': True}
        self.save_binding()
        self.archive = self.root / 'preparation.zip'
        proof_data = {'DEVICE-MANIFEST.json': self.entries, 'NORMALIZATION-PROOF.json': self.proof,
                      'APPLEDOUBLE-METADATA.json': {'summary': self.observed['metadata'], 'entries': self.metadata_entries}}
        with zipfile.ZipFile(self.archive, 'w') as output:
            for f in [self.ipa, self.ipa.with_suffix('.ipa.sha256'), self.binding]:
                output.write(f, 'subjects/' + f.name)
            for name, value in proof_data.items(): output.writestr('work/' + name, canonical(value) + b'\n')
        self.activation.update(unsignedArtifactDigest='sha256:' + sha(self.archive.read_bytes()),
                               unsignedArtifactSize=self.archive.stat().st_size)
        self.crypto_calls = []; self.api_calls = []
        self.responses = self.make_responses()

    def close(self): self.temporary.cleanup()

    def write_ipa(self):
        with zipfile.ZipFile(self.ipa, 'w') as output:
            for name, data, mode in self.members:
                item = zipfile.ZipInfo(name); item.create_system = 3
                item.external_attr = ((stat.S_IFDIR if data is None else stat.S_IFREG) | mode) << 16
                output.writestr(item, b'' if data is None else data)
        self.ipa.with_suffix('.ipa.sha256').write_text(sha(self.ipa.read_bytes()) + '  ' + self.ipa.name + '\n')

    def save_binding(self): self.binding.write_bytes(canonical(self.record) + b'\n')

    def make_responses(self):
        policy, control, activation = self.policy, self.controller, self.activation
        start, created, end = '2026-11-03T00:00:00Z', '2026-11-03T00:01:00Z', '2026-11-03T00:02:00Z'
        original = {'id': policy['original']['runID'], 'run_attempt': 1,
            'head_repository': {'full_name': v.b.REPOSITORY}, 'head_sha': policy['app']['sourceCommit'],
            'head_branch': v.b.TAG, 'path': v.b.SOURCE_WORKFLOW, 'event': 'workflow_dispatch',
            'status': 'completed', 'conclusion': 'success', 'run_started_at': start, 'updated_at': end}
        producing = dict(original, id=control['runID'], run_attempt=control['runAttempt'],
                         head_sha=control['commit'], head_branch=control['ref'][len('refs/tags/'):], path=v.b.WORKFLOW)
        return {'git/ref/tags/' + v.b.TAG: {'ref': 'refs/tags/' + v.b.TAG,
                    'object': {'type': 'tag', 'sha': policy['app']['tagObjectSHA']}},
            'git/tags/' + policy['app']['tagObjectSHA']: {'tag': v.b.TAG, 'sha': policy['app']['tagObjectSHA'],
                'object': {'type': 'commit', 'sha': policy['app']['sourceCommit']}},
            f"actions/runs/{policy['original']['runID']}/attempts/1": original,
            f"actions/artifacts/{policy['original']['artifactID']}": {'id': policy['original']['artifactID'],
                'name': 'testflight-1.7.67-build308', 'expired': False, 'digest': 'sha256:' + policy['original']['archiveSHA256'],
                'size_in_bytes': policy['original']['archiveBytes'], 'created_at': created,
                'workflow_run': {'id': original['id'], 'head_sha': original['head_sha']}},
            f"actions/runs/{policy['original']['runID']}/attempts/1/jobs?per_page=100": {'total_count': 1, 'jobs': [
                {'conclusion': 'success', 'steps': [{'name': 'Confirm Apple processing and existing internal Floe QA availability', 'conclusion': 'success'}]}]},
            f"releases/{policy['transport']['releaseID']}": {'id': policy['transport']['releaseID'], 'draft': True,
                'assets': [{'id': policy['transport']['assetID']}]},
            f"releases/assets/{policy['transport']['assetID']}": {'id': policy['transport']['assetID'],
                'name': 'local-device.zip', 'state': 'uploaded', 'size': policy['transport']['archiveBytes'],
                'digest': 'sha256:' + policy['transport']['archiveSHA256']},
            'git/ref/tags/' + control['ref'][len('refs/tags/'):]: {'ref': control['ref'], 'object': {'type': 'commit', 'sha': control['commit']}},
            'actions/runs/901/attempts/2': producing,
            'actions/artifacts/902': {'id': 902, 'expired': False, 'name': 'historical308-preparation-901-2',
                'digest': activation['unsignedArtifactDigest'], 'size_in_bytes': activation['unsignedArtifactSize'],
                'created_at': created, 'workflow_run': {'id': 901, 'head_sha': control['commit']}}}

    def invoke(self, command, **kwargs):
        self.crypto_calls.append(command)
        assert kwargs['check'] is True and kwargs['capture_output'] is True
        for flag, value in [('--source-ref', self.controller['ref']), ('--source-digest', self.controller['commit']),
                            ('--signer-digest', self.controller['commit']), ('--signer-workflow', v.b.REPOSITORY + '/' + v.b.WORKFLOW)]:
            assert command[command.index(flag) + 1] == value
        assert '--deny-self-hosted-runners' in command
        subject = Path(command[3])
        statement = {'predicateType': 'https://slsa.dev/provenance/v1',
            'subject': [{'name': subject.name, 'digest': {'sha256': sha(subject.read_bytes())}}],
            'predicate': {'runDetails': {'metadata': {'invocationId': 'https://github.com/' + v.b.REPOSITORY + '/actions/runs/901/attempts/2'},
                'builder': {'id': 'https://github.com/' + v.b.REPOSITORY + '/' + v.b.WORKFLOW + '@' + self.controller['ref']}}}}
        return SimpleNamespace(stdout=json.dumps([{'verificationResult': {'statement': statement}}]))

    def api(self, path):
        assert len(self.crypto_calls) == 2, 'source/run/artifact authority read before both cryptographic verifications'
        self.api_calls.append(path); return copy.deepcopy(self.responses[path])

    def verify(self, **kwargs):
        return v.verify(self.ipa, self.binding, self.activation, authority_root=self.authority,
                        api_get=self.api, invoke=self.invoke, **kwargs)


class Historical308PublicationTests(unittest.TestCase):
    def fixture(self):
        f = Fixture(); self.addCleanup(f.close); return f

    def test_fixed_macos26_pair_binds_exact_review_and_preserves_both_old_files(self):
        policies = SCRIPTS / 'release-policies'
        old_policy_path = policies / 'historical308-reviewed-v2.json'
        old_review_path = policies / 'historical308-publication-review-v2.json'
        self.assertEqual(sha(old_policy_path.read_bytes()),
            '4b2caa0caebc4ab9d1ce192ce2ec37160bed47b49a14cebee395608cc2b021d9')
        self.assertEqual(sha(old_review_path.read_bytes()),
            '2c58a38ac34b897a364b4057b879dc3e4803a2e23f7d90afe56fecaac24bbc57')
        self.assertEqual(v.POLICY_FILE, 'historical308-reviewed-macos26-v2.json')
        self.assertEqual(v.REVIEW_FILE, 'historical308-publication-review-macos26-v2.json')
        expected_manifest = {'bytes': 1440637339, 'files': 5248,
            'sha256': 'e66401fd093b3e3891a166f86bfe595b40e758362f6cfc66b00f47cc06cfeb6b'}
        expected_policy = json.loads(old_policy_path.read_text())
        expected_policy['expectedManifest'] = expected_manifest
        expected_review = json.loads(old_review_path.read_text())
        expected_review['reviewedMainSHA256'] = sha((SCRIPTS / 'historical308_source_binding.py').read_bytes())
        expected_review['review']['deviceManifest'] = expected_manifest
        expected_review['review']['normalizationProof'] = {'files': 48,
            'sha256': '06b53adbcd88bf8accae0a5e755ddb3ef75f3eeaa3ae6279522a243cf0cb3834'}
        # Synthetic activation checks data/code compatibility only: it is never
        # saved as production trust or passed off as a completed producer.
        f = self.fixture(); activation = dict(f.activation,
            policySHA256=sha((policies / v.POLICY_FILE).read_bytes()),
            reviewSHA256=sha((policies / v.REVIEW_FILE).read_bytes()))
        policy, review, controller = v.authority(activation, SCRIPTS)
        self.assertEqual(policy, expected_policy); self.assertEqual(review, expected_review)
        self.assertEqual(review['canonicalEntries'], 5537)
        self.assertEqual(review['protectedLatest'], {'tag': 'v1.8.5', 'build': '325'})
        self.assertNotEqual(controller['commit'], policy['app']['sourceCommit'])
        self.assertNotEqual(activation['unsignedArtifactDigest'], 'sha256:' + expected_manifest['sha256'])

    def test_fixed_pair_rejects_old_activation_hashes_and_mixed_review_even_with_refreshed_hash(self):
        policies = SCRIPTS / 'release-policies'
        old_review = json.loads((policies / 'historical308-publication-review-v2.json').read_text())
        for mutation in ('old policy hash', 'old review hash', 'old validator', 'old manifest', 'old normalizer'):
            f = self.fixture(); selected = f.authority / 'release-policies'
            policy_path, review_path = selected / v.POLICY_FILE, selected / v.REVIEW_FILE
            policy_bytes = (policies / v.POLICY_FILE).read_bytes()
            review = json.loads((policies / v.REVIEW_FILE).read_text())
            policy_path.write_bytes(policy_bytes)
            if mutation == 'old validator': review['reviewedMainSHA256'] = old_review['reviewedMainSHA256']
            elif mutation == 'old manifest': review['review']['deviceManifest'] = old_review['review']['deviceManifest']
            elif mutation == 'old normalizer': review['normalizerSHA256'] = '0' * 64
            review_path.write_bytes(canonical(review) + b'\n')
            activation = dict(f.activation, policySHA256=sha(policy_path.read_bytes()), reviewSHA256=sha(review_path.read_bytes()))
            if mutation == 'old policy hash':
                activation['policySHA256'] = sha((policies / 'historical308-reviewed-v2.json').read_bytes())
            elif mutation == 'old review hash':
                activation['reviewSHA256'] = sha((policies / 'historical308-publication-review-v2.json').read_bytes())
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                v.authority(activation, f.authority)
            self.assertEqual(f.crypto_calls, []); self.assertEqual(f.api_calls, [])

    def test_shared_reader_routes_only_explicit_new_mode_through_dual_crypto(self):
        f = self.fixture(); f.binding.write_text('{invalid JSON')
        activation = copy.deepcopy(f.activation)
        activation['policySHA256'] = sha((SCRIPTS / 'release-policies' / v.POLICY_FILE).read_bytes())
        activation['reviewSHA256'] = sha((SCRIPTS / 'release-policies' / v.REVIEW_FILE).read_bytes())
        shared = load('shared_feather_readback_red', SCRIPTS / 'verify_feather_provenance.py')
        with self.assertRaises(json.JSONDecodeError):
            shared.verify(f.ipa, v.b.TAG, activation['sourceCommit'], {v.b.TAG: activation},
                f.binding, invoke=f.invoke, api_get=f.api)
        self.assertEqual(len(f.crypto_calls), 2); self.assertEqual(f.api_calls, [])

    def test_full_small_device_payload_and_private_preparation_proofs_pass_the_real_reader(self):
        f = self.fixture(); staged = v.stage_prepared_archive(f.archive, f.root / 'prepared', f.activation)
        self.assertEqual(set(staged), {v.b.IPA_NAME, v.b.IPA_NAME + '.sha256', v.b.BINDING_NAME,
            'DEVICE-MANIFEST.json', 'APPLEDOUBLE-METADATA.json', 'NORMALIZATION-PROOF.json'})
        report = f.verify(prepared_directory=f.root / 'prepared')
        self.assertTrue(report['verified']); self.assertFalse(report['appRebuilt'])
        self.assertEqual(report['sourceCommit'], f.policy['app']['sourceCommit'])
        self.assertNotEqual(report['sourceCommit'], report['packagingController'])
        self.assertEqual((report['packagingRun'], report['packagingRunAttempt']), (901, 2))
        self.assertEqual(report['deviceManifest'], f.policy['expectedManifest'])
        self.assertEqual(report['canonicalEntries'], 5)

    def test_shared_feather_mode_uses_the_same_verifier_with_default_legacy_calls_preserved(self):
        f = self.fixture(); shared = load('shared_feather_308', SCRIPTS / 'verify_feather_provenance.py')
        report = shared.verify(f.ipa, v.b.TAG, f.policy['app']['sourceCommit'], {v.b.TAG: f.activation},
            f.binding, invoke=f.invoke, api_get=f.api, historical_authority_root=f.authority)
        self.assertEqual(report['mode'], v.MODE); self.assertTrue(report['verified'])

    def test_prepared_manifest_proof_and_metadata_entries_cannot_change_under_the_same_summary(self):
        for name in ['DEVICE-MANIFEST.json', 'NORMALIZATION-PROOF.json', 'APPLEDOUBLE-METADATA.json']:
            f = self.fixture(); paths = v.stage_prepared_archive(f.archive, f.root / 'prepared', f.activation)
            value = json.loads(paths[name].read_text())
            if name == 'DEVICE-MANIFEST.json': value[0]['mode'] ^= 1
            elif name == 'NORMALIZATION-PROOF.json': value['synthetic'] = 'tampered proof'
            else: value['entries'][0]['logicalPath'] = 'different metadata'
            paths[name].write_bytes(canonical(value) + b'\n')
            with self.subTest(name=name), self.assertRaises(ValueError): f.verify(prepared_directory=f.root / 'prepared')

    def test_duplicate_binding_keys_are_rejected_only_after_both_subjects_verify(self):
        f = self.fixture(); f.binding.write_text('{"schemaVersion":2,"schemaVersion":2}')
        with self.assertRaises(ValueError): f.verify()
        self.assertEqual(len(f.crypto_calls), 2); self.assertEqual(f.api_calls, [])

    def test_both_crypto_failures_precede_binding_json_or_live_authority_and_never_fall_back(self):
        for failure in [1, 2]:
            f = self.fixture(); f.binding.write_text('{invalid JSON')
            def invoke(command, **kwargs):
                if len(f.crypto_calls) + 1 == failure:
                    f.crypto_calls.append(command); raise subprocess.CalledProcessError(1, command)
                return f.invoke(command, **kwargs)
            with patch.object(v.b, 'read_json', wraps=v.b.read_json) as reads:
                with self.assertRaises(subprocess.CalledProcessError):
                    v.verify(f.ipa, f.binding, f.activation, authority_root=f.authority, invoke=invoke, api_get=f.api)
                self.assertFalse(any(Path(call.args[0]) == f.binding for call in reads.call_args_list))
            self.assertEqual(len(f.crypto_calls), failure); self.assertEqual(f.api_calls, [])

    def test_inactive_controller_wrong_source_ref_attempt_or_policy_is_rejected(self):
        for key, bad in [('packagingController', None), ('packagingController', 'a' * 39),
                         ('packagingController', '3368baaf8045023043bfb70d9062374c17a48a1d'),
                         ('controllerRef', 'refs/heads/main'), ('controllerRef', 'refs/tags/v1.7.67'),
                         ('packagingRun', True), ('packagingRunAttempt', 0), ('unsignedArtifactDigest', 'digest only'),
                         ('policySHA256', '0' * 64), ('reviewSHA256', '0' * 64), ('mode', 'implicit')]:
            f = self.fixture(); f.activation[key] = bad
            with self.subTest(key=key, bad=bad), self.assertRaises(ValueError): f.verify()
            self.assertEqual(f.crypto_calls, []); self.assertEqual(f.api_calls, [])

    def test_signed_binding_has_no_field_exemptions_or_numeric_type_coercions(self):
        for field in ['app', 'original', 'transport', 'deviceManifest', 'ipa', 'controller', 'schemaVersion', 'appRebuilt', 'extra']:
            f = self.fixture()
            if field == 'extra': f.record['publicationAuthorized'] = True
            elif field == 'schemaVersion': f.record[field] = 2.0
            elif field == 'appRebuilt': f.record[field] = 0
            else: f.record[field] = {'forged': True}
            f.save_binding()
            with self.subTest(field=field), self.assertRaises(ValueError): f.verify()
            self.assertEqual(len(f.crypto_calls), 2)

    def test_raw_resource_content_permission_and_empty_directory_tampering_cannot_be_repaired(self):
        for mutation in ['resource', 'mode', 'empty directory', 'simulator', 'signed']:
            f = self.fixture()
            if mutation == 'resource': f.members[4] = (f.members[4][0], b'changed resource', 0o640)
            elif mutation == 'mode': f.members[4] = (f.members[4][0], f.members[4][1], 0o644)
            elif mutation == 'empty directory': f.members.pop()
            elif mutation == 'signed': f.members.append(('Payload/Floe Agent.app/embedded.mobileprovision', b'profile', 0o644))
            else:
                name, data, mode = f.members[3]; replacement = bytearray(data)
                struct.pack_into('<I', replacement, 40, 7); f.members[3] = (name, bytes(replacement), mode)
            f.write_ipa(); f.record['ipa'].update(sha256=sha(f.ipa.read_bytes()), bytes=f.ipa.stat().st_size); f.save_binding()
            with self.subTest(mutation=mutation), patch.object(v.b, 'apple_normalize', side_effect=AssertionError('verification cannot normalize')):
                with self.assertRaises(ValueError): f.verify()

    def test_missing_expired_changed_original_or_producer_authority_fails_after_both_signatures(self):
        changes = [('actions/artifacts/902', 'expired', True), ('actions/artifacts/902', 'digest', 'sha256:' + '0' * 64),
            ('actions/artifacts/902', 'name', 'historical308-preparation-901-1'),
            ('actions/artifacts/902', 'created_at', '2026-11-02T00:00:00Z'),
            ('actions/runs/901/attempts/2', 'conclusion', None), ('actions/runs/901/attempts/2', 'head_sha', '0' * 40),
            ('actions/runs/901/attempts/2', 'path', '.github/workflows/release-unsigned-ipa.yml'),
            ('actions/artifacts/13251103493', 'expired', True),
            ('actions/runs/41677588064/attempts/1', 'conclusion', 'failure'),
            ('actions/runs/41677588064/attempts/1', 'head_sha', '0' * 40),
            ('releases/432964321', 'draft', False)]
        for path, key, value in changes:
            f = self.fixture(); f.responses[path][key] = value
            with self.subTest(path=path, key=key), self.assertRaises(ValueError): f.verify()
            self.assertEqual(len(f.crypto_calls), 2)

    def test_wrong_verified_controller_invocation_or_builder_is_refused_before_source_apis(self):
        for mutation in ['attempt', 'builder', 'subject digest']:
            f = self.fixture()
            def invoke(command, **kwargs):
                result = f.invoke(command, **kwargs); result_json = json.loads(result.stdout)
                statement = result_json[0]['verificationResult']['statement']
                if mutation == 'attempt': statement['predicate']['runDetails']['metadata']['invocationId'] += '1'
                elif mutation == 'builder': statement['predicate']['runDetails']['builder']['id'] = 'wrong workflow'
                else: statement['subject'][0]['digest']['sha256'] = '0' * 64
                return SimpleNamespace(stdout=json.dumps(result_json))
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                v.verify(f.ipa, f.binding, f.activation, authority_root=f.authority, invoke=invoke, api_get=f.api)
            self.assertEqual(f.api_calls, [])

    def test_preparation_archive_hash_traversal_and_ambiguous_files_are_refused(self):
        for mutation in ['digest', 'traversal', 'duplicate binding']:
            f = self.fixture()
            if mutation == 'digest': f.activation['unsignedArtifactDigest'] = 'sha256:' + '0' * 64
            else:
                with zipfile.ZipFile(f.archive, 'a') as archive:
                    archive.writestr('../outside' if mutation == 'traversal' else 'other/' + v.b.BINDING_NAME, b'bad')
                f.activation.update(unsignedArtifactDigest='sha256:' + sha(f.archive.read_bytes()), unsignedArtifactSize=f.archive.stat().st_size)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                v.stage_prepared_archive(f.archive, f.root / 'staged-bad', f.activation)
            self.assertFalse((f.root / 'outside').exists())

    def test_public_asset_retry_only_adds_missing_files_and_refuses_any_overwrite_or_extra(self):
        f = self.fixture(); names = [v.b.IPA_NAME, v.b.IPA_NAME + '.sha256', v.b.BINDING_NAME]
        release = {'id': 8, 'tag_name': v.b.TAG, 'draft': False, 'prerelease': False, 'published_at': '2026-11-08T00:00:00Z', 'assets': []}
        self.assertEqual(v.public_assets(release, f.root, complete=False), sorted(names))
        for index, name in enumerate(names):
            release['assets'].append({'id': index + 1, 'name': name, 'state': 'uploaded',
                'size': (f.root / name).stat().st_size, 'digest': 'sha256:' + sha((f.root / name).read_bytes()),
                'browser_download_url': f'https://github.com/{v.b.REPOSITORY}/releases/download/{v.b.TAG}/{name}'})
        self.assertEqual(v.public_assets(release, f.root, complete=True), [])
        for mutation in ['digest', 'foreign URL', 'extra raw transport', 'prerelease', 'draft', 'wrong tag']:
            altered = copy.deepcopy(release)
            if mutation == 'digest': altered['assets'][0]['digest'] = 'sha256:' + '0' * 64
            elif mutation == 'foreign URL': altered['assets'][0]['browser_download_url'] = 'https://example.invalid/'
            elif mutation == 'extra raw transport': altered['assets'].append({'name': 'local-device.zip'})
            elif mutation == 'wrong tag': altered['tag_name'] = 'v1.7.68'
            else: altered[mutation] = True
            with self.subTest(mutation=mutation), self.assertRaises(ValueError): v.public_assets(altered, f.root, complete=True)

    def test_historical_feather_pins_executed_code_and_keeps_main_as_data(self):
        workflow = yaml.safe_load((REPO / '.github/workflows/publish-feather-source.yml').read_text())
        steps = workflow['jobs']['publish-source']['steps']
        checkout = next((step for step in steps if step.get('with', {}).get('path') == 'historical-controller'), None)
        self.assertIsNotNone(checkout, 'Historical Feather must execute the frozen controller checkout')
        self.assertEqual(checkout['with']['ref'], '${{ github.sha }}')
        self.assertEqual(checkout['if'], 'inputs.historical_release == true')
        self.assertFalse(checkout['with']['persist-credentials'])
        selection = next(step['run'] for step in steps if step.get('name') == 'Select the verified code root')
        with tempfile.TemporaryDirectory(prefix='feather-code-root-') as temporary:
            root = Path(temporary); controller = root / 'historical-controller'; controller.mkdir()
            subprocess.run(['git', 'init', '--quiet', str(controller)], check=True)
            subprocess.run(['git', '-C', str(controller), '-c', 'user.name=fixture',
                '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '--allow-empty', '-m', 'fixture'], check=True)
            commit = subprocess.check_output(['git', '-C', str(controller), 'rev-parse', 'HEAD'], text=True).strip()
            for historical, expected in [('true', controller), ('false', root)]:
                output = root / ('environment-' + historical)
                environment = dict(os.environ, GITHUB_WORKSPACE=str(root), GITHUB_SHA=commit,
                    GITHUB_ENV=str(output), HISTORICAL_RELEASE=historical)
                subprocess.run(['bash', '-c', selection], env=environment, check=True, capture_output=True)
                self.assertEqual(output.read_text().strip(), 'FEATHER_CODE_ROOT=' + str(expected))
            environment.update(HISTORICAL_RELEASE='true', GITHUB_SHA='0' * 40)
            refused = subprocess.run(['bash', '-c', selection], env=environment, capture_output=True)
            self.assertNotEqual(refused.returncode, 0)
        scripts = '\n'.join(step.get('run', '') for step in steps)
        self.assertNotIn('python3 FloeAgent/scripts/', scripts)
        self.assertIn('"$FEATHER_CODE_ROOT/FloeAgent/scripts/verify_feather_provenance.py"', scripts)
        self.assertIn('--historical-authority-root "$GITHUB_WORKSPACE"', scripts)
        self.assertIn('trust=FloeAgent/scripts/feather_recovery_trust.json', scripts)

    def test_feather_cli_carries_separate_authority_root_without_changing_legacy_calls(self):
        shared = load('shared_feather_cli_authority', SCRIPTS / 'verify_feather_provenance.py')
        with tempfile.TemporaryDirectory(prefix='feather-cli-data-') as temporary:
            root = Path(temporary); trust = root / 'trust.json'; trust.write_text('{}')
            arguments = ['--ipa', str(root / 'fixture.ipa'), '--tag', 'v1.7.67',
                '--source-sha', 'a' * 40, '--trust', str(trust)]
            for flags, expected in [([], None), (['--historical-authority-root', str(root)], root)]:
                with patch.object(shared, 'verify', return_value={'verified': True}) as verify, patch('sys.stdout', io.StringIO()):
                    shared.main(arguments + flags)
                self.assertEqual(verify.call_args.kwargs['historical_authority_root'], expected)

    def test_controller_context_and_workflow_keep_two_explicit_runs_and_await_the_original_feather(self):
        f = self.fixture(); env = {'GITHUB_REPOSITORY': v.b.REPOSITORY, 'GITHUB_SHA': 'a' * 40,
            'GITHUB_REF': f.controller['ref'], 'GITHUB_WORKFLOW_REF': v.b.REPOSITORY + '/' + v.PUBLISH_WORKFLOW + '@' + f.controller['ref']}
        v.publisher_context(f.activation, f.authority, env)
        for key, bad in [('GITHUB_SHA', f.policy['app']['sourceCommit']), ('GITHUB_REF', 'refs/heads/main'),
                         ('GITHUB_WORKFLOW_REF', v.b.REPOSITORY + '/' + v.b.WORKFLOW + '@' + f.controller['ref'])]:
            with self.subTest(key=key), self.assertRaises(ValueError): v.publisher_context(f.activation, f.authority, dict(env, **{key: bad}))
        text = (REPO / '.github/workflows/publish-historical308.yml').read_text(); workflow = yaml.safe_load(text)
        jobs = workflow['jobs']; writer = jobs['feather']
        self.assertEqual(writer['uses'], './.github/workflows/publish-feather-source.yml')
        self.assertEqual(writer['needs'], ['verify-and-publish']); self.assertTrue(writer['with']['historical_release'])
        self.assertIn('success', writer['if']); self.assertNotIn('steps', writer)
        self.assertNotIn('gh workflow run', text); self.assertNotIn('--clobber', text)
        self.assertIn('--latest=false', text); self.assertNotIn('--latest=true', text)
        self.assertIn('verify_github_release_publication.py --mode app', text)
        self.assertIn('--preserve-latest-before-json', text); self.assertIn('--preserve-latest-after-json', text)
        self.assertNotIn('id-token', workflow['permissions']); self.assertNotIn('attest-build-provenance@', text)
        normal = (REPO / '.github/workflows/release-unsigned-ipa.yml').read_text()
        self.assertIn('"$GITHUB_SHA" != "$TAG_COMMIT"', normal)


if __name__ == '__main__':
    unittest.main()
