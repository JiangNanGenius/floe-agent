"""Independent functional/security tests for the applied direct-artifact verifier.

Unlike the earlier static suite, this file exercises the exact script that now
lives at ``FloeAgent/scripts/verify_direct_unsigned_artifact.py`` (no private
copy), including the recovery-ordering additions:

* the retained unsigned package stays verifiable when the private symbols
  artifact is missing, while ``--require-symbols-artifact`` refuses to let a
  rebuild-free retry distribute a build whose dSYM was never captured;
* accepted TestFlight evidence may come from the producing run or from the
  caller run of a rebuild-free retry, but two accepted uploads are rejected;
* the provenance record must carry the truthful pre-signing symbol state;
* zip extraction rejects traversal, absolute paths, backslashes, AppleDouble
  entries and symlinks.

No network, Xcode, SwiftPM or App build is required: every artifact is a small
synthetic zip.
"""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import plistlib
from pathlib import Path
import tempfile
import unittest
import zipfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SCRIPT = REPO / 'FloeAgent' / 'scripts' / 'verify_direct_unsigned_artifact.py'
spec = importlib.util.spec_from_file_location('direct_artifact_review', SCRIPT)
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)

REPOSITORY = 'JiangNanGenius/floe-agent'
SOURCE = 'a' * 40
TAG = 'v1.7.0-beta.49'
VERSION = '1.7.0'
BUILD = '192'
TOOLCHAIN = 'Xcode 26.6 (17F113)'
IPA_NAME = f'Floe-Agent-{VERSION}-build{BUILD}-unsigned.ipa'
ARTIFACT = f'expedited-unsigned-ipa-{VERSION}-build{BUILD}'
EVIDENCE = f'testflight-{VERSION}-build{BUILD}'
SYMBOLS = f'release-symbols-{VERSION}-build{BUILD}'


def make_ipa(*, bundle='org.floeagent.ios', version=VERSION, build=BUILD,
             signed=False) -> bytes:
    buffer = io.BytesIO()
    plist = plistlib.dumps({'CFBundleIdentifier': bundle,
                            'CFBundleShortVersionString': version,
                            'CFBundleVersion': build,
                            'CFBundleExecutable': 'Floe Agent',
                            'MinimumOSVersion': '26.0'},
                           fmt=plistlib.FMT_BINARY)
    with zipfile.ZipFile(buffer, 'w') as bundle_zip:
        bundle_zip.writestr('Payload/Floe Agent.app/Info.plist', plist)
        bundle_zip.writestr('Payload/Floe Agent.app/Floe Agent', b'binary')
        if signed:
            bundle_zip.writestr('Payload/Floe Agent.app/embedded.mobileprovision', b'profile')
    return buffer.getvalue()


def make_provenance(**overrides) -> bytes:
    record = {
        'schemaVersion': 1,
        'route': 'direct-testflight',
        'tag': TAG,
        'version': VERSION,
        'build': BUILD,
        'sourceCommit': SOURCE,
        'bundleIdentifier': 'org.floeagent.ios',
        'assetName': IPA_NAME,
        'artifactName': ARTIFACT,
        'symbolsArtifact': SYMBOLS,
        'symbolsState': v.SYMBOLS_STATE_REQUIRED,
        'toolchain': TOOLCHAIN,
        'appUUID': '00000000-0000-0000-0000-000000000000',
        'runId': 500,
        'runAttempt': 1,
        'workflow': 'release-unsigned-ipa.yml',
        'simulatorQualification': 'skipped_by_user_request',
        'deviceAcceptance': 'pending_user',
        'signedPayloadPublished': False,
        'signedIpaPublished': False,
    }
    record.update(overrides)
    return (json.dumps(record, indent=2) + '\n').encode()


def make_summary(**overrides) -> bytes:
    fields = {
        'tag': TAG,
        'version': VERSION,
        'build': BUILD,
        'bundle': 'org.floeagent.ios',
        'source': SOURCE,
        'asset': IPA_NAME,
        'artifact': ARTIFACT,
        'symbols_artifact': SYMBOLS,
        'symbols_state': v.SYMBOLS_STATE_REQUIRED,
        'app_uuid': '00000000-0000-0000-0000-000000000000',
        'toolchain': TOOLCHAIN,
        'policy': 'user_requested_direct_TestFlight',
        'simulator_tests': 'skipped_by_user_request',
        'device_acceptance': 'pending_user',
        'signed_ipas_published': 'false',
    }
    fields.update(overrides)
    return ''.join(f'{key}={value}\n' for key, value in fields.items()).encode()


def default_run(**overrides) -> dict:
    run = {'id': 500, 'status': 'completed', 'head_sha': SOURCE,
           'head_repository': {'full_name': REPOSITORY},
           'path': '.github/workflows/release-unsigned-ipa.yml',
           'event': 'workflow_dispatch', 'run_attempt': 1,
           'html_url': f'https://github.com/{REPOSITORY}/actions/runs/500'}
    run.update(overrides)
    return run


def artifact_entry(name: str, digest_char: str, *, expired=False, artifact_id=77) -> dict:
    return {'id': artifact_id, 'name': name, 'expired': expired,
            'digest': 'sha256:' + digest_char * 64, 'size_in_bytes': 10}


class Fixture:
    """One synthetic retained artifact plus its run and artifacts JSON."""

    def __init__(self, *, ipa=None, summary=None, provenance=None, sidecar=None,
                 artifact_name=ARTIFACT, artifacts=None, run=None, digest=None,
                 zip_extra=None, extra_evidence=None, include_symbols=True,
                 include_evidence=True):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.ipa_bytes = make_ipa() if ipa is None else ipa
        self.summary = make_summary() if summary is None else summary
        self.provenance = make_provenance() if provenance is None else provenance
        self.sidecar = sidecar
        self.artifact_name = artifact_name
        self.artifacts_override = artifacts
        self.run = default_run() if run is None else run
        self.digest_override = digest
        self.zip_extra = zip_extra or {}
        self.extra_evidence = extra_evidence
        self.include_symbols = include_symbols
        self.include_evidence = include_evidence

    def write(self) -> dict:
        artifact_dir = self.root / 'artifact'
        artifact_dir.mkdir(parents=True, exist_ok=True)
        (artifact_dir / IPA_NAME).write_bytes(self.ipa_bytes)
        sidecar = self.sidecar
        if sidecar is None:
            sidecar = f'{hashlib.sha256(self.ipa_bytes).hexdigest()}  {IPA_NAME}\n'
        (artifact_dir / (IPA_NAME + '.sha256')).write_text(sidecar)
        (artifact_dir / 'TEST-SUMMARY.txt').write_bytes(self.summary)
        (artifact_dir / 'DIRECT-PROVENANCE.json').write_bytes(self.provenance)
        (artifact_dir / 'bundle-normalization.json').write_text('{}\n')
        for name, payload in self.zip_extra.items():
            (artifact_dir / name).parent.mkdir(parents=True, exist_ok=True)
            (artifact_dir / name).write_bytes(payload)
        archive = self.root / 'artifact.zip'
        with zipfile.ZipFile(archive, 'w') as bundle:
            for path in sorted(artifact_dir.rglob('*')):
                if path.is_file():
                    bundle.write(path, path.relative_to(artifact_dir).as_posix())
        digest = self.digest_override or (
            'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest())
        artifacts = self.artifacts_override
        if callable(artifacts):
            artifacts = artifacts(digest, archive.stat().st_size, self.artifact_name)
        if artifacts is None:
            artifacts = [{'id': 77, 'name': self.artifact_name, 'expired': False,
                          'digest': digest, 'size_in_bytes': archive.stat().st_size}]
            if self.include_symbols:
                artifacts.append(artifact_entry(SYMBOLS, 'c', artifact_id=99))
            if self.include_evidence:
                artifacts.append(artifact_entry(EVIDENCE, 'b', artifact_id=88))
        (self.root / 'artifacts.json').write_text(json.dumps({'artifacts': artifacts}))
        (self.root / 'run.json').write_text(json.dumps(self.run))
        extra_path = None
        if self.extra_evidence is not None:
            extra_path = self.root / 'extra-artifacts.json'
            extra_path.write_text(json.dumps({'artifacts': self.extra_evidence}))
        return {'run': self.root / 'run.json', 'artifacts': self.root / 'artifacts.json',
                'zip': archive, 'extract': self.root / 'extract', 'extra': extra_path}

    def verify(self, **overrides):
        paths = self.write()
        kwargs = dict(run=v.load_json(paths['run']), artifacts=v.load_json(paths['artifacts']),
                      repository=REPOSITORY, artifact_name=ARTIFACT, tag=TAG,
                      source_sha=SOURCE, version=VERSION, build=BUILD, toolchain=TOOLCHAIN,
                      artifact_zip=paths['zip'], extract_dir=paths['extract'])
        if 'evidence_artifacts' not in overrides and paths['extra'] is not None:
            kwargs['evidence_artifacts'] = [v.load_json(paths['extra'])]
        kwargs.update(overrides)
        return v.verify(**kwargs)


class RetainedArtifactReviewTests(unittest.TestCase):
    def fixture(self, **kwargs) -> Fixture:
        fixture = Fixture(**kwargs)
        self.addCleanup(fixture._tmp.cleanup)
        return fixture

    def assert_rejected(self, fixture: Fixture, **overrides):
        with self.assertRaises(v.VerificationError) as caught:
            fixture.verify(**overrides)
        self.assertTrue(str(caught.exception))

    # -- recovery ordering: package survives a symbol failure ------------------

    def test_unsigned_package_verifies_when_symbols_were_never_captured(self):
        fixture = self.fixture(include_symbols=False)
        report = fixture.verify()
        self.assertFalse(report['symbolsArtifactPresent'])
        self.assertIsNone(report['symbolsArtifactId'])
        self.assertEqual(report['symbolsState'], v.SYMBOLS_STATE_REQUIRED)
        self.assertTrue(report['testflightAccepted'])

    def test_rebuild_free_retry_refuses_a_missing_symbols_artifact(self):
        fixture = self.fixture(include_symbols=False)
        with self.assertRaises(v.VerificationError) as caught:
            fixture.verify(require_symbols_artifact=True)
        message = str(caught.exception)
        self.assertIn('no live private symbols artifact', message)
        self.assertIn('retained unsigned IPA is preserved', message)

    def test_symbols_artifact_presence_and_digest_are_reported(self):
        report = self.fixture().verify(require_symbols_artifact=True)
        self.assertTrue(report['symbolsArtifactPresent'])
        self.assertEqual(report['symbolsArtifactId'], 99)
        self.assertEqual(report['symbolsArtifactDigest'], 'sha256:' + 'c' * 64)

    def test_expired_symbols_artifact_does_not_satisfy_the_gate(self):
        fixture = self.fixture(artifacts=lambda digest, size, name: [
            {'id': 77, 'name': name, 'expired': False, 'digest': digest,
             'size_in_bytes': size},
            artifact_entry(SYMBOLS, 'c', expired=True, artifact_id=99),
            artifact_entry(EVIDENCE, 'b', artifact_id=88),
        ])
        report = fixture.verify()
        self.assertFalse(report['symbolsArtifactPresent'])
        self.assert_rejected(fixture, require_symbols_artifact=True)

    # -- TestFlight evidence union and duplicate rejection ---------------------

    def test_accepted_evidence_can_come_from_the_caller_run(self):
        fixture = self.fixture(include_evidence=False,
                               extra_evidence=[artifact_entry(EVIDENCE, 'b', artifact_id=88)])
        report = fixture.verify(expect_testflight_accepted=True)
        self.assertTrue(report['testflightAccepted'])
        self.assertEqual(report['testflightEvidenceSource'], 'caller_run')

    def test_duplicate_accepted_uploads_across_runs_are_rejected(self):
        fixture = self.fixture(
            include_evidence=True,
            extra_evidence=[artifact_entry(EVIDENCE, 'b', artifact_id=89)])
        with self.assertRaises(v.VerificationError) as caught:
            fixture.verify(expect_testflight_accepted=True)
        message = str(caught.exception)
        self.assertIn('Duplicate accepted TestFlight evidence', message)
        self.assertIn('accepted twice', message)

    def test_producer_evidence_is_used_when_no_caller_evidence_exists(self):
        fixture = self.fixture(
            include_evidence=True,
            extra_evidence=[artifact_entry('direct-reuse-x', 'd', artifact_id=90)])
        report = fixture.verify(expect_testflight_accepted=True)
        self.assertEqual(report['testflightEvidenceSource'], 'artifact_run')

    def test_missing_evidence_is_still_reported_and_required_fails_closed(self):
        fixture = self.fixture(include_evidence=False)
        report = fixture.verify()
        self.assertFalse(report['testflightAccepted'])
        self.assertIsNone(report['testflightEvidenceArtifact'])
        self.assertIsNone(report['testflightEvidenceSource'])
        self.assert_rejected(fixture, expect_testflight_accepted=True)

    # -- truthful provenance / identity / security -----------------------------

    def test_record_symbols_state_must_not_pretend_capture(self):
        self.assert_rejected(self.fixture(
            provenance=make_provenance(symbolsState='captured')))
        self.assert_rejected(self.fixture(
            provenance=make_provenance(symbolsState=None)))

    def test_run_must_bind_source_workflow_and_event(self):
        for overrides in ({'head_sha': 'b' * 40},
                          {'path': '.github/workflows/other.yml'},
                          {'event': 'push'},
                          {'head_repository': {'full_name': 'someone/else'}},
                          {'status': 'in_progress'}):
            with self.subTest(overrides=overrides):
                self.assert_rejected(self.fixture(run=default_run(**overrides)))

    def test_downloaded_zip_must_match_the_github_digest(self):
        self.assert_rejected(self.fixture(digest='sha256:' + 'd' * 64))

    def test_ipa_identity_and_signing_material_are_enforced(self):
        for kwargs in ({'bundle': 'com.example.other'}, {'version': '1.6.9'},
                       {'build': '190'}, {'signed': True}):
            with self.subTest(kwargs=kwargs):
                self.assert_rejected(self.fixture(ipa=make_ipa(**kwargs)))

    def test_sidecar_and_summary_must_bind_the_same_source(self):
        self.assert_rejected(self.fixture(sidecar='f' * 64 + '  ' + IPA_NAME + '\n'))
        self.assert_rejected(self.fixture(sidecar='f' * 64 + '  other.ipa\n'))
        self.assert_rejected(self.fixture(summary=make_summary(source='e' * 40)))
        self.assert_rejected(self.fixture(summary=make_summary(asset='Floe-Agent-x-unsigned.ipa')))
        self.assert_rejected(self.fixture(summary=make_summary(signed_ipas_published='true')))
        self.assert_rejected(self.fixture(provenance=make_provenance(runId=501)))
        self.assert_rejected(self.fixture(provenance=make_provenance(tag='v1.7.0-beta.48')))
        self.assert_rejected(self.fixture(provenance=make_provenance(signedIpaPublished=True)))
        self.assert_rejected(self.fixture(provenance=make_provenance(toolchain='Xcode 27.0')))
        self.assert_rejected(self.fixture(provenance=make_provenance(symbolsArtifact='')))

    def test_artifact_selection_requires_one_live_named_digest_artifact(self):
        self.assert_rejected(self.fixture(artifact_name='expedited-unsigned-ipa-x'))
        self.assert_rejected(self.fixture(artifacts=[
            {'id': 77, 'name': ARTIFACT, 'expired': True,
             'digest': 'sha256:' + 'c' * 64, 'size_in_bytes': 10}]))
        self.assert_rejected(self.fixture(artifacts=[
            {'id': 77, 'name': ARTIFACT, 'expired': False,
             'digest': None, 'size_in_bytes': 10}]))

    def test_zip_hazards_are_rejected(self):
        cases = {
            'traversal': '../escape.txt',
            'absolute': '/etc/passwd',
            'backslash': 'a\\b.txt',
            'appledouble': '__MACOSX/junk',
        }
        for label, member in cases.items():
            with self.subTest(case=label):
                with tempfile.TemporaryDirectory() as folder:
                    archive = Path(folder) / f'{label}.zip'
                    with zipfile.ZipFile(archive, 'w') as bundle:
                        bundle.writestr(member, b'nope')
                    with self.assertRaises(v.VerificationError):
                        v.safe_extract_zip(archive, Path(folder) / 'out')
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / 'symlink.zip'
            with zipfile.ZipFile(archive, 'w') as bundle:
                info = zipfile.ZipInfo('symlink')
                info.external_attr = (0o120777 << 16)
                bundle.writestr(info, b'/etc/passwd')
            with self.assertRaises(v.VerificationError):
                v.safe_extract_zip(archive, Path(folder) / 'out2')

    # -- CLI -------------------------------------------------------------------

    def cli_args(self, fixture: Fixture, report: Path, *extra):
        paths = fixture.write()
        args = ['--run', str(paths['run']), '--artifacts', str(paths['artifacts']),
                '--repository', REPOSITORY, '--artifact-name', ARTIFACT,
                '--tag', TAG, '--source-sha', SOURCE, '--version', VERSION,
                '--build', BUILD, '--toolchain', TOOLCHAIN,
                '--artifact-zip', str(paths['zip']),
                '--extract-dir', str(paths['extract']),
                '--report', str(report)]
        if paths['extra'] is not None:
            args += ['--evidence-artifacts', str(paths['extra'])]
        return args + list(extra)

    def test_cli_matches_the_fresh_lean_publish_invocation(self):
        # Mirrors lean-publish on the first run: the producing run is still
        # running, symbols and accepted TestFlight evidence are in that run.
        fixture = self.fixture(run=default_run(status='in_progress'))
        report = fixture.root / 'report.json'
        self.assertEqual(v.main(self.cli_args(
            fixture, report, '--allow-running', '--expect-testflight-accepted',
            '--require-symbols-artifact')), 0)
        written = json.loads(report.read_text())
        self.assertEqual(written['testflightEvidenceSource'], 'artifact_run')
        self.assertTrue(written['symbolsArtifactPresent'])
        self.assertEqual(written['runId'], 500)

    def test_cli_new_gates_and_fail_closed_reporting(self):
        fixture = self.fixture(include_symbols=False)
        report = fixture.root / 'report.json'
        self.assertEqual(v.main(self.cli_args(fixture, report, '--require-symbols-artifact')), 1)
        self.assertFalse(report.exists())

        fixture = self.fixture(
            include_evidence=False,
            extra_evidence=[artifact_entry(EVIDENCE, 'b', artifact_id=88)])
        report = fixture.root / 'report.json'
        self.assertEqual(v.main(self.cli_args(
            fixture, report, '--expect-testflight-accepted',
            '--require-symbols-artifact')), 0)
        written = json.loads(report.read_text())
        self.assertEqual(written['testflightEvidenceSource'], 'caller_run')
        self.assertTrue(written['symbolsArtifactPresent'])


if __name__ == '__main__':
    unittest.main()
