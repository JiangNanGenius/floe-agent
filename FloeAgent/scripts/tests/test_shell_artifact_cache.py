import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('shell_cache', Path(__file__).parents[1] / 'prime_shell_artifact_cache.py')
cache = importlib.util.module_from_spec(spec); spec.loader.exec_module(cache)
URL = 'https://github.com/example/engine/releases/download/v1/engine.xcframework.zip'


class ShellArtifactCacheTests(unittest.TestCase):
    def test_verified_archive_is_reused_without_downloading(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            expected = hashlib.sha256(b'archive').hexdigest()
            path = cache.prime(URL, expected, root, lambda p: p.write_bytes(b'archive'))
            self.assertEqual(path.name, 'https___github_com_example_engine_releases_download_v1_engine_xcframework_zip')
            cache.prime(URL, expected, root, lambda p: self.fail('verified cache should be reused'))

    def test_corruption_cannot_replace_existing_cache_or_leave_partial(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); target = root / cache.cache_key(URL); target.write_bytes(b'old')
            with self.assertRaises(ValueError):
                cache.prime(URL, hashlib.sha256(b'correct').hexdigest(), root, lambda p: p.write_bytes(b'corrupt'))
            self.assertEqual(target.read_bytes(), b'old')
            self.assertFalse(list(root.glob('.floe-artifact-*')))

    def test_foreign_hosts_and_filename_patterns_are_rejected(self):
        for url in ['http://github.com/example/engine/releases/download/v1/a.zip',
                    'https://github.com.example.org/example/engine/releases/download/v1/a.zip',
                    'https://github.com/example/engine/releases/download/v1/*.zip']:
            with self.assertRaises(ValueError): cache.github_asset(url)
