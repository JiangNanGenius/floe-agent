import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock

SCRIPTS = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location('feather_provenance', SCRIPTS / 'verify_feather_provenance.py')
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


class FeatherProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.ipa = Path(self.temp.name) / 'Floe-Agent-1.7.0-build191-unsigned.ipa'
        self.ipa.write_bytes(b'fixture IPA bytes')
        self.path = self.ipa.parent / 'BUILD191-RECOVERY-PROVENANCE.json'
        self.tag = 'v1.7.0-beta.48'
        self.source = '715cbc42e9402cf5ca691291fed5c201e61cf222'
        self.policy = dict(sourceCommit=self.source, sourceRun=35337960392,
                           sourceArtifactID=10544612762, sourceArtifactDigest='d' * 64,
                           deviceArchiveSHA256='e' * 64, packagingController='a' * 40,
                           packagingRun=123, signerWorkflow='.github/workflows/developer-ipa-from-recovery.yml')
        self.record = dict(self.policy, schemaVersion=1, sourceTag=self.tag,
                           appRebuilt=False, unsigned=True, ipaName=self.ipa.name,
                           ipaBytes=self.ipa.stat().st_size, ipaSHA256=v.digest_file(self.ipa))
        self.save()

    def save(self):
        self.path.write_text(json.dumps(self.record))

    def verify(self, invoke=None):
        return v.verify(self.ipa, self.tag, self.source, {self.tag: self.policy},
                        self.path, invoke=invoke or Mock())

    def test_legacy_verifies_original_source_and_workflow(self):
        invoke = Mock()
        report = v.verify(self.ipa, self.tag, self.source, {}, invoke=invoke)
        self.assertEqual(report['mode'], 'original-source')
        self.assertIn(self.source, invoke.call_args.args[0])
        self.assertIn(v.REPOSITORY + '/.github/workflows/release-unsigned-ipa.yml', invoke.call_args.args[0])

    def test_recovery_requires_two_attestations_and_keeps_source_distinct(self):
        invoke = Mock(); report = self.verify(invoke)
        self.assertEqual(invoke.call_count, 2)
        self.assertEqual(report['sourceCommit'], self.source)
        self.assertEqual(report['packagingController'], 'a' * 40)
        self.assertEqual({call.args[0][3] for call in invoke.call_args_list}, {str(self.ipa), str(self.path)})
        for call in invoke.call_args_list:
            self.assertIn('a' * 40, call.args[0]); self.assertTrue(call.kwargs['check'])

    def test_failed_attestation_does_not_fall_back(self):
        for outcomes in ([subprocess.CalledProcessError(1, 'gh')], [None, subprocess.CalledProcessError(1, 'gh')]):
            invoke = Mock(side_effect=outcomes)
            with self.assertRaises(subprocess.CalledProcessError): self.verify(invoke)
            self.assertEqual(invoke.call_count, len(outcomes))

    def test_unsigned_source_controller_run_and_artifact_bindings(self):
        original = self.record.copy()
        for key in ('sourceCommit', 'sourceTag', 'sourceRun', 'sourceArtifactID', 'sourceArtifactDigest',
                    'deviceArchiveSHA256', 'packagingController', 'packagingRun', 'ipaName', 'ipaSHA256', 'ipaBytes'):
            with self.subTest(key=key):
                self.record = dict(original, **{key: 'tampered'})
                self.save()
                with self.assertRaises(ValueError): self.verify()
        for key, value in [('appRebuilt', True), ('unsigned', False), ('schemaVersion', 2)]:
            self.record = dict(original, **{key: value}); self.save()
            with self.assertRaises(ValueError): self.verify()

    def test_missing_or_untrusted_recovery_record_rejected(self):
        with self.assertRaises(ValueError):
            v.verify(self.ipa, self.tag, self.source, {self.tag: self.policy}, invoke=Mock())
        with self.assertRaises(ValueError):
            v.verify(self.ipa, self.tag, self.source, {}, self.path, invoke=Mock())

    def test_modified_ipa_and_foreign_signer_rejected(self):
        self.ipa.write_bytes(b'other payload')
        with self.assertRaises(ValueError): self.verify()
        self.policy['signerWorkflow'] = '.github/workflows/other.yml'
        with self.assertRaises(ValueError): self.verify()

    def test_release_recovery_cannot_start_normal_build_or_upload(self):
        spec = importlib.util.spec_from_file_location('gate_helpers', SCRIPTS / 'tests/test_release_notes_component_gate.py')
        helpers = importlib.util.module_from_spec(spec); spec.loader.exec_module(helpers)
        root = SCRIPTS.parents[1]
        source = (root / '.github/workflows/release-unsigned-ipa.yml').read_text()
        for job in ('direct-testflight', 'expedited-testflight', 'recover-testflight',
                    'component-recovery', 'prepare-release', 'build-verify-release', 'notes-component'):
            condition = helpers.job_scalar(helpers.job_block(source, job), 'if')
            self.assertTrue(condition.startswith('${{ !inputs.recover_developer_build191 && '), job)
        package = (root / '.github/workflows/developer-ipa-from-recovery.yml').read_text()
        self.assertNotIn('altool', package)
        self.assertNotIn('CODE_SIGNING_ALLOWED', package)
        self.assertNotIn('secrets.', package)
        self.assertIn('scripts/package_unsigned_ipa.sh', package)
        self.assertIn('BUILD191-RECOVERY-PROVENANCE.json', package)


if __name__ == '__main__':
    unittest.main()
