"""Protect shared test hosts and the two-SDK join before distribution."""
from pathlib import Path
import unittest

WORKFLOW = Path(__file__).resolve().parents[3] / '.github/workflows/release-unsigned-ipa.yml'

class SharedReleaseHostTests(unittest.TestCase):
    def jobs(self):
        source = WORKFLOW.read_text()
        sdk27 = source.split('\n  build-verify-release:', 1)[1].split('\n  accepted-sdk-build:', 1)[0]
        stable = source.split('\n  accepted-sdk-build:', 1)[1].split('\n  testflight:', 1)[0]
        upload = source.split('\n  testflight:', 1)[1].split('\n  publish-release:', 1)[0]
        return source, sdk27, stable, upload

    def test_both_sdks_build_once_and_execute_their_own_tests(self):
        source, sdk27, stable, upload = self.jobs()
        for job, derived in ((sdk27, 'FloeAppRegressionDerivedData'), (stable, 'FloeStableDeviceDerivedData')):
            self.assertEqual(job.count('CODE_SIGNING_ALLOWED=NO build-for-testing'), 1)
            self.assertIn('ENABLE_TESTABILITY=YES', job)
            self.assertIn("-configuration Debug -destination 'generic/platform=iOS Simulator'", job)
            self.assertIn('-configuration Release', job)
            self.assertIn(f'$RUNNER_TEMP/{derived}/Build/Products', job)
            self.assertIn('-xctestrun "$xctestrun"', job)
            self.assertIn('verify_app_regression_xcresult.py', job)
            self.assertIn('verify_notes_ui_xcresult.py', job)
            self.assertIn("for device in 'iPad mini (A17 Pro)' 'iPhone 17 Pro'", job)
            self.assertGreaterEqual(job.count('test-without-building'), 2)
            self.assertNotIn('            test\n', job)
        self.assertNotIn('FloeSimulatorDerivedData', source)
        self.assertIn('Build unsigned device application', sdk27)
        self.assertIn('Rebuild the exact tag with the accepted App Store SDK', stable)
        self.assertNotIn('build-for-testing', upload)
        self.assertNotIn('            build\n', upload)

    def test_sdk_jobs_share_frozen_source_and_upload_waits_for_both(self):
        source, sdk27, stable, upload = self.jobs()
        for job in [sdk27, stable]:
            self.assertIn('needs: prepare-release', job)
            self.assertIn('ref: ${{ needs.prepare-release.outputs.source_sha }}', job)
            self.assertNotIn('secrets.APPLE_CERTIFICATE', job)
            self.assertNotIn('secrets.APP_STORE_CONNECT', job)
        self.assertIn('needs: [build-verify-release, accepted-sdk-build]', upload)
        self.assertIn('needs.accepted-sdk-build.outputs.input_sha256', upload)
        self.assertIn('shasum -a 256 -c -', upload)
        self.assertIn('SOURCE-SHA.txt', upload)
        self.assertLess(upload.index('Verify and restore the exact qualified'), upload.index('Install App Store Connect API key'))
        self.assertLess(stable.index('verify_notes_ui_xcresult.py'), stable.index('Stage the qualified accepted-SDK application'))
        self.assertIn('needs.accepted-sdk-build.outputs.passed', upload)
        self.assertNotIn('steps.stable_app_regression.outputs.', upload)

if __name__ == '__main__': unittest.main()
