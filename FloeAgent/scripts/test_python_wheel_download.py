#!/usr/bin/env python3
"""Exercise the production shell download function without network or builds."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class WheelDownloadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cache = self.root / 'cache'
        self.cache.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        curl = self.bin / 'curl'
        curl.write_text('''#!/bin/bash
while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then shift; target="$1"; fi
    shift
done
printf '%s' "${MOCK_BODY:-verified wheel}" > "$target"
exit "${MOCK_EXIT:-0}"
''')
        curl.chmod(0o755)
        source = (Path(__file__).parent / 'install_python_binary_packages.sh').read_text()
        function = source[source.index('download_wheel() {'):source.index('\nmake_framework() {')]
        self.script = self.root / 'test.sh'
        self.script.write_text('set -euo pipefail\ncache_root="$1"\n' + function +
            '\nresult="$(download_wheel numpy 2.5.2.post1 iphoneos "$2")"\nprintf "%s" "$result"\n')
        self.checksum = hashlib.sha256(b'verified wheel').hexdigest()

    def run_download(self, **values):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'], **values)
        return subprocess.run(['bash', str(self.script), str(self.cache), self.checksum],
            env=env, capture_output=True, text=True)

    def test_failed_transfer_does_not_become_a_cached_wheel(self):
        result = self.run_download(MOCK_EXIT='56', MOCK_BODY='partial')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('download failed', result.stderr)
        self.assertNotIn('SHA256 mismatch', result.stderr)
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_checksum_failure_does_not_poison_retry_cache(self):
        result = self.run_download(MOCK_BODY='wrong bytes')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SHA256 mismatch', result.stderr)
        self.assertEqual(list(self.cache.iterdir()), [])
        self.assertEqual(self.run_download().returncode, 0)

    def test_verified_cache_is_reused_without_another_transfer(self):
        result = self.run_download()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(result.stdout).read_bytes(), b'verified wheel')
        cached = self.run_download(MOCK_EXIT='56')
        self.assertEqual(cached.returncode, 0, cached.stderr)
        self.assertEqual(cached.stdout, result.stdout)


if __name__ == '__main__':
    unittest.main()
