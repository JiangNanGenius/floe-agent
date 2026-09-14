"""Protect the shared test-host optimization without skipping qualification."""
from pathlib import Path
import unittest

WORKFLOW = Path(__file__).resolve().parents[3] / '.github/workflows/release-unsigned-ipa.yml'

class SharedReleaseHostTests(unittest.TestCase):
    def test_both_sdks_build_once_and_execute_their_own_tests(self):
        source = WORKFLOW.read_text()
        sdk27, stable = source.split('\n  testflight:', 1)
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
        # A testable simulator host never substitutes for the shipping device build.
        self.assertIn('Build unsigned device application', sdk27)
        self.assertIn('Rebuild the exact tag with the accepted App Store SDK', stable)
        self.assertLess(stable.index('verify_notes_ui_xcresult.py'), stable.index('Sign, verify, package, and upload to TestFlight'))

if __name__ == '__main__': unittest.main()
