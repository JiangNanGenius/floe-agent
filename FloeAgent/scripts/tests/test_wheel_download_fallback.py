"""Exercise transfer fallback and the real checksum/atomic-cache boundary."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


class WheelDownloadFallbackTests(unittest.TestCase):
    def exercise(self, *, corrupt=False, url='https://github.com/example/wheels/releases/download/v1/package.whl'):
        script = Path(__file__).parents[1] / 'install_python_binary_packages.sh'
        function = re.search(r'^download_wheel\(\) \{.*?^\}', script.read_text(), re.M | re.S).group()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            tools = root / 'bin'; tools.mkdir()
            cache = root / 'cache'; cache.mkdir()
            (tools / 'curl').write_text('#!/bin/bash\nexit 56\n')
            (tools / 'gh').write_text('''#!/bin/bash
printf invoked > "$FLOE_TEST_GH_CALLED"
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then shift; printf '%s' "$FLOE_TEST_PAYLOAD" > "$1"; exit 0; fi
  shift
done
exit 2
''')
            for file in tools.iterdir(): file.chmod(0o755)
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                       FLOE_TEST_URL=url, FLOE_TEST_PAYLOAD='corrupt' if corrupt else 'pinned-wheel',
                       FLOE_TEST_GH_CALLED=str(root / 'called'), FLOE_TEST_CACHE=str(cache))
            digest = hashlib.sha256(b'pinned-wheel').hexdigest()
            command = 'set -euo pipefail\ncache_root="$FLOE_TEST_CACHE"\nwheel_url() { printf "%s" "$FLOE_TEST_URL"; }\n' + function + '\ndownload_wheel package 1 iphoneos ' + digest
            result = subprocess.run(['bash', '-c', command], env=env, capture_output=True, text=True)
            output = cache / 'package-1-iphoneos.whl'
            return result.returncode, output.read_bytes() if output.exists() else None, (root / 'called').exists(), list(cache.glob('*.partial.*'))

    def test_api_fallback_commits_only_verified_bytes(self):
        status, payload, called, partials = self.exercise()
        self.assertEqual(status, 0)
        self.assertEqual(payload, b'pinned-wheel')
        self.assertTrue(called)
        self.assertFalse(partials)

    def test_corrupt_api_payload_never_enters_cache(self):
        status, payload, called, partials = self.exercise(corrupt=True)
        self.assertNotEqual(status, 0)
        self.assertIsNone(payload)
        self.assertTrue(called)
        self.assertFalse(partials)

    def test_non_github_source_does_not_use_authenticated_api(self):
        status, payload, called, partials = self.exercise(url='https://example.org/package.whl')
        self.assertNotEqual(status, 0)
        self.assertIsNone(payload)
        self.assertFalse(called)
        self.assertFalse(partials)
