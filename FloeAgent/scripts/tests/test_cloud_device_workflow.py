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
        for key in ('source_sha', 'infra_sha', 'simulation_release_id', 'simulation_asset_id', 'simulation_sha256', 'recipient_certificate_base64', 'recipient_sha256'):
            self.assertIn(key + ': ${{ inputs.cloud_', header)
        self.assertIn('test "$INFRA_SHA" = "$GITHUB_SHA"', self.build)
        self.assertIn('test "$SOURCE_SHA" = fa252b61852dd37d489635c0dd83fe8c6b4b2d00', self.build)
        self.assertIn("refs/tags/v1.8.42^{commit}", self.build)
        self.assertIn("'infrastructureSHA': os.environ['INFRA_SHA']", self.build)
        self.assertIn('git tag --points-at "$SOURCE_SHA"', self.build)
        self.assertIn('[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]', self.build)

    def test_precheckout_validation_runs_in_existing_runner_directory(self):
        precheckout = self.build.split('- name: Validate the immutable source and public recipient', 1)[1].split(
            '- name: Check out the exact source and tags', 1)[0]
        self.assertIn('working-directory: ${{ runner.temp }}', precheckout)
        self.assertNotIn('working-directory: FloeAgent', precheckout)

    def test_native_input_download_has_step_scoped_token(self):
        native = next(s for s in self.steps if s.startswith('Prepare and verify native inputs\n'))
        self.assertIn('GH_TOKEN: ${{ github.token }}', native)
        self.assertIn('prime_shell_artifact_cache.py', native)
        job_header = self.build.split('    steps:', 1)[0]
        self.assertNotIn('GH_TOKEN:', job_header)

    def test_qualified_occt_is_derived_with_locked_toolchain_and_rechecked(self):
        derive = next(s for s in self.steps if s.startswith('Derive and qualify locked OCCT inputs with Xcode 27.1\n'))
        for required in ('/Applications/Xcode_27.1.app/Contents/Developer',
                         "'Xcode 27.1'", "'Build version 27A9275'", '--sdk iphoneos',
                         '--sdk iphonesimulator', 'DEVELOPER_DIR="$occt_developer"',
                         'bootstrap.py --release-check', 'occt_transport.py" capture'):
            self.assertIn(required, derive)
        for required in ('occt_transport.py" verify', "'occtInputs': occt_evidence",
                         '27.1-derived locked input', "'derivationSDK='",):
            if required == "'derivationSDK='":
                self.assertIn("derivationSDK='27.1'", self.build)
            else:
                self.assertIn(required, self.build)
        self.assertGreaterEqual(self.build.count('bootstrap.py --release-check'), 2)
        self.assertIn('-p test_cloud_occt_transport.py', self.caller)
        for forbidden in ('occt_release_id', 'occt_asset_id', 'occt_sha256', 'verified-occt-inputs.zip'):
            self.assertNotIn(forbidden, self.build)
            self.assertNotIn(forbidden, self.caller)
        cloud_header = self.caller.split('  cloud-device:', 1)[1].split('\n  live-agent-demo:', 1)[0]
        self.assertIn('contents: read', cloud_header)
        self.assertRegex(self.build, r'device:\s*\n(?:.*\n)*?    permissions:\s*\n\s+contents: read')

    def test_restricted_simulation_input_checked_before_and_after_build(self):
        step = next(s for s in self.steps if s.startswith('Retrieve and verify restricted SimulationKit inputs\n'))
        for required in ('.draft == true', 'verified-simulation-inputs.zip', 'SIMULATION_RELEASE_ID',
                         'SIMULATION_ASSET_ID', 'SIMULATION_SHA256', 'simulation_transport.py" install', 'simulation_transport.py" verify-release-target',
                         'verify_apple.py --check'):
            self.assertIn(required, step)
        self.assertIn('simulation_transport.py" verify', self.build)
        self.assertGreaterEqual(self.build.count('verify_apple.py --check'), 2)
        self.assertIn("'simulationInputs': simulation_evidence", self.build)
        self.assertIn('-p test_cloud_simulation_transport.py', self.caller)
        self.assertIn('one-time qualified build completed', self.build)

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
