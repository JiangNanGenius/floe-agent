"""Safety contract for the manually selected, encrypted device-build lane."""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CALLER = ROOT / '.github/workflows/ci.yml'
BUILD = ROOT / '.github/workflows/cloud-device-build-only.yml'


def step_blocks(text: str):
    return re.split(r'(?m)^      - name: ', text)[1:]


class CloudDeviceWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.caller = CALLER.read_text()
        cls.build = BUILD.read_text()
        cls.steps = step_blocks(cls.build)

    def test_only_reusable_and_caller_is_explicit_and_gated(self):
        self.assertIn('  workflow_call:', self.build)
        self.assertNotIn('  workflow_dispatch:', self.build)
        header = self.caller.split('  cloud-device:', 1)[1].split('\n  live-agent-demo:', 1)[0]
        self.assertIn('needs: validate-selectors', header)
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.cloud_device_only", header)
        self.assertIn('uses: ./.github/workflows/cloud-device-build-only.yml', header)
        for key in ('source_sha', 'recipient_certificate_base64', 'recipient_sha256'):
            self.assertIn(key + ': ${{ inputs.cloud_', header)
        self.assertIn("test \"$SOURCE_SHA\" = \"$GITHUB_SHA\"", self.build)
        self.assertIn('git tag --points-at "$SOURCE_SHA"', self.build)
        self.assertIn('[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]', self.build)

    def test_precheckout_validation_runs_in_existing_runner_directory(self):
        precheckout = self.build.split('- name: Validate the immutable source and public recipient', 1)[1].split(
            '- name: Check out the exact source and tags', 1)[0]
        self.assertIn('working-directory: ${{ runner.temp }}', precheckout)
        self.assertNotIn('working-directory: FloeAgent', precheckout)

    def test_failure_diagnostics_work_when_checkout_fails(self):
        diagnostics = next(s for s in self.steps if s.startswith('Encrypt failure diagnostics\n'))
        self.assertIn('working-directory: ${{ runner.temp }}', diagnostics)
        self.assertIn("failure() && steps.recipient.outputs.validated == 'true'", diagnostics)

    def test_font_receipt_records_observed_inputs_and_limitations(self):
        for item in ('sourceManifestSHA256', 'stagedFilesSHA256', 'shippedFilesSHA256',
                     'no source-bound expected hashes', 'outputSurfaceLimitation',
                     'Actions/setup logs and dependency caches'):
            self.assertIn(item, self.build)
        self.assertIn('-p test_cloud_device_workflow.py', self.caller)

    def test_only_encrypted_device_and_failure_artifacts_leave_runner(self):
        uploads = [s for s in self.steps if 'actions/upload-artifact@' in s]
        self.assertEqual(len(uploads), 2)
        for block in uploads:
            self.assertIn('.cms', block)
            self.assertNotIn('.zip', block)
            self.assertNotIn('.log', block)
            self.assertNotIn('FloeCloudDevice/manifest.json', block)
            self.assertIn('if-no-files-found: error', block)
        self.assertEqual(self.build.count('openssl cms -encrypt -binary -aes256 -outform DER'), 2)
        self.assertIn('openssl cms -cmsout -inform DER', self.build)
        self.assertNotIn('| tee ', self.build)
        self.assertIn("failure() && steps.recipient.outputs.validated == 'true'", self.build)
        self.assertIn("failure() && steps.encrypted-diagnostics.outcome == 'success'", self.build)
        self.assertIn('canonical != der', self.build)
        self.assertIn('hashlib.sha256(der).hexdigest() != value', self.build)

    def test_no_signing_or_publication_and_required_symbols_are_checked(self):
        for forbidden in ('altool', 'upload-app', 'codesign ', 'gh release', 'git push', 'secrets: inherit'):
            self.assertNotIn(forbidden, self.build)
        for required in ('CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO',
                         "'Xcode 27.2'", "'Build version 27B52'", 'iphoneos27.2',
                         'required - available.keys()', 'actual != expected',
                         'shippedBinariesWithoutAvailableSymbols'):
            self.assertIn(required, self.build)
        self.assertRegex(self.build, r'permissions:\s*\n\s+contents: read\s*\n\s+actions: read')


if __name__ == '__main__':
    unittest.main()
