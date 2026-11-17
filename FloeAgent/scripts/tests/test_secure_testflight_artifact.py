import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import yaml

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / '.github/scripts/secure_testflight_artifact.py'
SPEC = importlib.util.spec_from_file_location('secure_testflight', SCRIPT)
secure = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(secure)


class SecureTestFlightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.key, cls.cert, cls.der = (cls.root / n for n in ('synthetic-key.pem', 'synthetic-cert.pem', 'synthetic-cert.der'))
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-days', '1',
                        '-subj', '/CN=offline-test', '-keyout', str(cls.key), '-out', str(cls.cert)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        subprocess.run(['openssl', 'x509', '-in', str(cls.cert), '-outform', 'DER', '-out', str(cls.der)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def environment(self, root):
        der = self.der.read_bytes()
        config = {'source_sha': secure.PRODUCT_SHA, 'infra_sha': 'b' * 40,
                  'recipient_sha256': hashlib.sha256(der).hexdigest(),
                  'recipient_certificate_base64': base64.b64encode(der).decode()}
        return {'SECURE_TESTFLIGHT': json.dumps(config), 'RUNNER_TEMP': str(root),
                'GITHUB_SHA': 'b' * 40, 'RELEASE_TAG': 'v1.8.42', 'SIGNING_JOB_STATUS': 'success',
                'ARTIFACT_SHA256': 'c' * 64, 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1',
                'APP_VERSION': '1.8.42', 'APP_BUILD': '363'}

    def invoke(self, command, env):
        real_run = secure.run
        def run(*args, **kwargs):
            if args == ('git', 'rev-parse', 'HEAD'):
                return (secure.PRODUCT_SHA + '\n').encode()
            return real_run(*args, **kwargs)
        with patch.dict(os.environ, env), patch.object(secure, 'run', side_effect=run), patch.object(secure.sys, 'argv', ['helper', command]):
            secure.main()

    def test_encrypt_and_decrypt_all_with_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = {'TestFlightExport/FloeAgent.ipa': b'signed IPA',
                     'TestFlightExport/UPLOAD-RECEIPT.txt': b'upload accepted',
                     'TestFlightExport/TESTFLIGHT-SUMMARY.txt': b'upload summary',
                     'TestFlightExport/bundle-normalization.json': b'{}',
                     'TestFlightExport/apns-signing-profile.json': b'{}',
                     'FloeSignedPayload/provenance.json': b'{}',
                     'FloeSignedPayload/symbols/app.dSYM/data': b'symbols',
                     'APPLE-INTERNAL.json': b'{}'}
            for name, value in files.items():
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(value)
            for missing in ('TestFlightExport/FloeAgent.ipa', 'TestFlightExport/UPLOAD-RECEIPT.txt',
                            'FloeSignedPayload/provenance.json'):
                file = root / missing
                file.write_bytes(b'')
                with self.subTest(empty=missing), self.assertRaises(ValueError):
                    self.invoke('encrypt-upload' if 'UPLOAD-RECEIPT' in missing else 'encrypt-early', self.environment(root))
                file.write_bytes(files[missing])
            apple = root / 'APPLE-INTERNAL.json'
            apple.write_bytes(b'')
            with self.assertRaises(ValueError):
                self.invoke('encrypt-apple', self.environment(root))
            apple.write_bytes(files['APPLE-INTERNAL.json'])
            link = root / 'FloeSignedPayload/symbols/latest'
            link.symlink_to('app.dSYM')
            files['FloeSignedPayload/symbols/latest'] = b'app.dSYM'
            (root / 'TestFlightExport/FloeAgent.ipa').chmod(0o640)
            self.invoke('encrypt-early', self.environment(root))
            self.invoke('encrypt-upload', self.environment(root))
            self.invoke('encrypt-apple', self.environment(root))
            for ciphertext in secure.CIPHERTEXTS:
                decrypted = root / 'decrypted.zip'
                subprocess.run(['openssl', 'cms', '-decrypt', '-binary', '-inform', 'DER',
                                '-in', str(root / ciphertext), '-recip', str(self.cert), '-inkey', str(self.key),
                                '-out', str(decrypted)], check=True)
                secure.verify_archive(decrypted)
                with zipfile.ZipFile(decrypted) as archive:
                    manifest = json.loads(archive.read('MANIFEST.json'))
                    self.assertEqual(manifest['product_sha'], secure.PRODUCT_SHA)
                    self.assertEqual(manifest['signing_infra_sha'], 'b' * 40)
                    self.assertEqual(manifest['transport_sha256'], 'c' * 64)
                    self.assertEqual((manifest['run_id'], manifest['run_attempt'], manifest['version'], manifest['build']), ('123', '1', '1.8.42', '363'))
                    self.assertEqual(manifest['archive_ciphertext'], ciphertext)
                    self.assertEqual(manifest['ciphertexts'], secure.CIPHERTEXTS)
                    for entry in manifest['files']:
                        contents = archive.read(entry['path'])
                        self.assertEqual(entry['sha256'], hashlib.sha256(contents).hexdigest())
                        self.assertEqual(entry['size'], len(contents))
                        self.assertEqual(contents, files[entry['path']])
                        original = root / entry['path']
                        self.assertEqual(entry['mode'], original.lstat().st_mode & 0o7777)
                        self.assertEqual((archive.getinfo(entry['path']).external_attr >> 16) & 0o7777, entry['mode'])
                        if entry['path'].endswith('/latest'):
                            self.assertEqual(entry['type'], 'symlink')
                decrypted.unlink()
            self.assertFalse(list(root.glob('*.cms.zip')))

    def test_reject_mismatched_binding_and_certificate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for key in ('source_sha', 'infra_sha', 'recipient_sha256'):
                env = self.environment(root)
                value = json.loads(env['SECURE_TESTFLIGHT'])
                value[key] = 'a' * len(value[key])
                env['SECURE_TESTFLIGHT'] = json.dumps(value)
                with self.subTest(key=key), self.assertRaises(ValueError):
                    self.invoke('validate', env)
            env = self.environment(root)
            env['GITHUB_RUN_ATTEMPT'] = '2'
            with self.assertRaisesRegex(ValueError, 'does not permit reruns'):
                self.invoke('validate', env)

    def test_archive_tampering_and_partial_write_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = root / 'payload'
            payload.write_bytes(b'original')
            payload.chmod(0o640)
            env = self.environment(root)
            value = json.loads(env['SECURE_TESTFLIGHT'])
            archive = root / 'original.zip'
            with patch.dict(os.environ, env):
                secure.write_archive(root, value, 'test.cms', ['payload'], archive)
            secure.verify_archive(archive)
            for field in ('content', 'mode'):
                changed = root / (field + '.zip')
                with zipfile.ZipFile(archive) as source, zipfile.ZipFile(changed, 'w') as target:
                    for info in source.infolist():
                        data = source.read(info.filename)
                        if info.filename == 'payload':
                            if field == 'content':
                                data = b'tampered'
                            else:
                                info.external_attr ^= 0o100 << 16
                        target.writestr(info, data)
                with self.subTest(field=field), self.assertRaises(ValueError):
                    secure.verify_archive(changed)
            with patch.dict(os.environ, env), patch.object(secure.zipfile.ZipFile, 'writestr', side_effect=OSError('injected disk error')):
                with self.assertRaises(OSError):
                    secure.seal(root, value, self.cert, 'partial.cms', [])
            self.assertFalse((root / 'partial.cms.zip').exists())
            self.assertFalse((root / 'partial.cms.partial').exists())

    def test_failure_evidence_is_marked_and_never_treated_as_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            env['SIGNING_JOB_STATUS'] = 'failure'
            self.invoke('encrypt-early', env)
            self.invoke('encrypt-upload', env)
            self.invoke('encrypt-apple', env)
            decrypted = root / 'decrypted.zip'
            subprocess.run(['openssl', 'cms', '-decrypt', '-binary', '-inform', 'DER', '-in',
                            str(root / secure.CIPHERTEXTS[1]), '-recip', str(self.cert), '-inkey', str(self.key),
                            '-out', str(decrypted)], check=True)
            with zipfile.ZipFile(decrypted) as archive:
                self.assertEqual(json.loads(archive.read('MANIFEST.json'))['signing_job_status'], 'failure')
            env['SIGNING_JOB_STATUS'] = 'success'
            with self.assertRaises(ValueError):
                self.invoke('encrypt-early', env)

    def test_workflow_fail_closed_and_legacy_defaults(self):
        caller = yaml.load((ROOT / '.github/workflows/release-unsigned-ipa.yml').read_text(), Loader=yaml.BaseLoader)
        workflow = yaml.load((ROOT / '.github/workflows/testflight-local-artifact.yml').read_text(), Loader=yaml.BaseLoader)
        inputs = caller['on']['workflow_dispatch']['inputs']
        self.assertLessEqual(len(inputs), 25)
        self.assertEqual(inputs['secure_testflight']['default'], '')
        self.assertEqual(caller['jobs']['local-artifact-testflight']['with']['secure_testflight'], '${{ inputs.secure_testflight }}')
        gate = caller['jobs']['published-readback-route-gate']['steps'][0]['run']
        gate_code = gate.split("python3 - <<'PYINPUT'\n", 1)[1].rsplit('\nPYINPUT', 1)[0]
        for override in ({'publish': True}, {'published_readback_only': True}, {'local_artifact_sha256': ''}):
            request = {'secure_testflight': '{}', 'local_artifact_sha256': 'abc'}
            request.update(override)
            result = subprocess.run(['python3', '-O', '-c', gate_code], env={**os.environ, 'REQUEST_INPUTS': json.dumps(request)},
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(result.returncode, 0, override)
        steps = workflow['jobs']['upload']['steps']
        recipient = next(i for i, step in enumerate(steps) if step.get('id') == 'secure_recipient')
        self.assertLess(recipient, next(i for i, step in enumerate(steps) if step['name'] == 'Validate package with Apple'))
        self.assertLess(recipient, next(i for i, step in enumerate(steps) if step['name'] == 'Upload validated package to TestFlight'))
        uploads = [s for s in steps if 'actions/upload-artifact@' in s.get('uses', '')]
        self.assertEqual(len(uploads), 6)
        plaintext = [s for s in uploads if s['name'] in ('Upload TestFlight evidence', 'Retain local provenance and symbols', 'Save Apple internal availability evidence')]
        self.assertEqual(len(plaintext), 3)
        for step in plaintext:
            self.assertIn("inputs.secure_testflight == ''", step['if'])
        early = next(s for s in uploads if s['name'] == 'Upload only encrypted TestFlight artifacts')
        self.assertIn("steps.encrypt_export.outcome == 'success'", early['if'])
        self.assertEqual(early['with']['if-no-files-found'], 'error')
        self.assertIn('FloeTestFlightExport.cms', early['with']['path'])
        self.assertIn('FloeTestFlightEvidence.cms', early['with']['path'])
        self.assertLess(steps.index(early), next(i for i, s in enumerate(steps) if s['name'] == 'Validate package with Apple'))
        self.assertLess(steps.index(early), next(i for i, s in enumerate(steps) if s['name'] == 'Upload validated package to TestFlight'))
        self.assertLess(steps.index(early), next(i for i, s in enumerate(steps) if s['name'] == 'Confirm Apple processing and existing internal Floe QA availability'))
        apple = next(s for s in uploads if s['name'] == 'Upload only encrypted Apple internal evidence')
        self.assertIn("steps.encrypt_apple.outcome == 'success'", apple['if'])
        self.assertIn('FloeTestFlightApple.cms', apple['with']['path'])
        receipt = next(s for s in uploads if s['name'] == 'Upload only encrypted TestFlight receipt')
        self.assertIn("steps.encrypt_upload.outcome == 'success'", receipt['if'])
        self.assertIn('FloeTestFlightUpload.cms', receipt['with']['path'])
        self.assertIn("steps.secure_recipient.outcome == 'success'", next(s for s in steps if s.get('id') == 'encrypt_export')['if'])


if __name__ == '__main__':
    unittest.main()
