"""Every excluded latency suite must have its own mandatory invocation."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]


class DeadlineSuiteCoverageTests(unittest.TestCase):
    def test_each_excluded_suite_is_run_once_with_retained_diagnostics(self):
        expected = {
            'FloeExecutionTests.JavaScriptEngineTests',
            'FloeExecutionTests.JavaScriptExecutionToolTests',
            'FloeExecutionTests.NetworkDiagnosticToolsTests',
        }
        for name in ('ci.yml', 'release-unsigned-ipa.yml'):
            with self.subTest(workflow=name):
                text = (ROOT / '.github/workflows' / name).read_text()
                block = text.split('SwiftTestDiagnostics/full', 1)[1].split('\n      - name:', 1)[0]
                skipped = re.findall(r"--skip '(FloeExecutionTests\.[^']+)'", block)
                selected = re.findall(r"--filter '(FloeExecutionTests\.[^']+)'", block)
                self.assertEqual(set(skipped), expected)
                self.assertEqual(set(selected), expected)
                self.assertEqual(len(skipped), len(expected))
                self.assertEqual(len(selected), len(expected))
                for line in block.splitlines():
                    if '--filter' in line:
                        self.assertIn('python3 scripts/run_test_with_diagnostics.py', line)
                        self.assertIn('--output-dir "$RUNNER_TEMP/SwiftTestDiagnostics/', line)
                        self.assertNotIn('||', line)
                self.assertNotIn('set +e', block)


if __name__ == '__main__':
    unittest.main()
