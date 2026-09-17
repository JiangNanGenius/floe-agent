"""Targeted tests for the Lua WASI qualification fixture preparation.

Covers verification (digest/size/WASM magic), stale-cache protection, the
no-network repository-artifact preference and hard failures for missing or
corrupt committed artifacts.  There is deliberately no download fallback:
the fixture under test must be the exact bytes tracked in this repository.
All temporary artifacts live under this task's private directory; the
repository working tree is never modified.
"""
import contextlib
import hashlib
import importlib.util
import io
import shutil
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURE_ROOT = REPO_ROOT / 'Local' / 'Private' / 'build178-feedback' / 'lua-ci-fixture'

spec = importlib.util.spec_from_file_location(
    'prepare_lua_qualification',
    Path(__file__).resolve().parents[1] / 'prepare_lua_qualification.py')
prepare_lua = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare_lua)

REAL_ARTIFACT = REPO_ROOT / 'capability-hub' / 'packages' / 'floe-lua' / '5.4.8' / 'lua.wasm'
REAL_SHA256 = '81ad32f4eca06d232598ad7bf6f4f92bab4864a5b5d0f4da036e159b2efdf049'
REAL_SIZE = 671143


class PrepareFixtureTests(unittest.TestCase):
    def setUp(self):
        FIXTURE_ROOT.mkdir(parents=True, exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix='case-', dir=FIXTURE_ROOT))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.cache = self.tmp / 'cache'

    def wasm(self, payload=b'floe-test-lua'):
        data = prepare_lua.WASM_MAGIC + payload
        return data, hashlib.sha256(data).hexdigest(), len(data)

    # --- verification -----------------------------------------------------

    def test_verification_accepts_the_pinned_repository_artifact(self):
        data = REAL_ARTIFACT.read_bytes()
        self.assertEqual(prepare_lua.verify_wasm(data, REAL_SHA256, REAL_SIZE), data)
        self.assertTrue(data.startswith(prepare_lua.WASM_MAGIC))
        self.assertEqual(len(data), REAL_SIZE)

    def test_verification_rejects_tampered_bytes(self):
        data, sha256, size = self.wasm()
        tampered = data[:-1] + bytes([data[-1] ^ 0xFF])
        with self.assertRaisesRegex(RuntimeError, 'SHA-256 mismatch'):
            prepare_lua.verify_wasm(tampered, sha256, size)

    def test_verification_rejects_size_mismatch(self):
        data, sha256, _ = self.wasm()
        with self.assertRaisesRegex(RuntimeError, 'size mismatch'):
            prepare_lua.verify_wasm(data, sha256, len(data) + 1)

    def test_verification_rejects_non_wasm_magic(self):
        data = b'{"not":"a wasm module"}'
        sha256 = hashlib.sha256(data).hexdigest()
        with self.assertRaisesRegex(RuntimeError, 'not a WASM module'):
            prepare_lua.verify_wasm(data, sha256, len(data))

    # --- cache preference ---------------------------------------------------

    def test_verified_cache_hits_without_touching_the_artifact(self):
        data, sha256, size = self.wasm()
        self.cache.mkdir(parents=True)
        (self.cache / 'lua.wasm').write_bytes(data)
        path, source = prepare_lua.prepare(sha256, size, self.cache,
                                           repo_artifact=self.tmp / 'absent.wasm')
        self.assertEqual((path, source), (self.cache / 'lua.wasm', 'cache'))

    def test_stale_cache_is_replaced_from_repository_artifact(self):
        data, sha256, size = self.wasm()
        self.cache.mkdir(parents=True)
        stale = self.cache / 'lua.wasm'
        stale.write_bytes(b'outdated cached bytes')
        artifact = self.tmp / 'repo-lua.wasm'
        artifact.write_bytes(data)
        path, source = prepare_lua.prepare(sha256, size, self.cache,
                                           repo_artifact=artifact)
        self.assertEqual(source, 'repository')
        self.assertEqual(path.read_bytes(), data)
        self.assertEqual(prepare_lua.read_verified(path, sha256, size), data)
        self.assertEqual(list(self.cache.iterdir()), [stale])

    # --- repository artifact is the only source -----------------------------

    def test_missing_repository_artifact_is_a_hard_error(self):
        data, sha256, size = self.wasm()
        with self.assertRaisesRegex(RuntimeError, 'is missing'):
            prepare_lua.prepare(sha256, size, self.cache,
                                repo_artifact=self.tmp / 'absent.wasm')
        self.assertFalse((self.cache / 'lua.wasm').exists())

    def test_corrupt_repository_artifact_is_an_integrity_error(self):
        data, sha256, size = self.wasm()
        artifact = self.tmp / 'repo-lua.wasm'
        artifact.write_bytes(b'corrupt committed bytes')
        with self.assertRaisesRegex(RuntimeError, 'refusing to replace committed bytes'):
            prepare_lua.prepare(sha256, size, self.cache, repo_artifact=artifact)
        self.assertFalse((self.cache / 'lua.wasm').exists())

    def test_failed_prepare_leaves_any_existing_cache_file_intact(self):
        data, sha256, size = self.wasm()
        self.cache.mkdir(parents=True)
        stale = self.cache / 'lua.wasm'
        stale.write_bytes(b'old but recoverable')
        with self.assertRaisesRegex(RuntimeError, 'is missing'):
            prepare_lua.prepare(sha256, size, self.cache,
                                repo_artifact=self.tmp / 'absent.wasm')
        self.assertEqual(stale.read_bytes(), b'old but recoverable')
        self.assertEqual(list(self.cache.iterdir()), [stale])


@unittest.skipUnless(REAL_ARTIFACT.is_file(), 'repository-tracked lua.wasm is required')
class SignedCatalogIntegrationTests(unittest.TestCase):
    """Authenticate the real signed catalog against the tracked artifact."""

    def setUp(self):
        FIXTURE_ROOT.mkdir(parents=True, exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix='integration-', dir=FIXTURE_ROOT))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.tool = prepare_lua.load_capability_tool()

    def test_signed_catalog_pins_the_tracked_artifact(self):
        url, sha256, size = prepare_lua.pinned_lua_entry(self.tool)
        self.assertTrue(url.startswith('https://'))
        self.assertEqual(sha256, REAL_SHA256)
        self.assertEqual(size, REAL_SIZE)
        self.assertEqual(prepare_lua.repo_artifact_path(self.tool), REAL_ARTIFACT)

    def test_main_prepares_from_repository_artifact_without_network(self):
        self.assertEqual(hashlib.sha256(REAL_ARTIFACT.read_bytes()).hexdigest(), REAL_SHA256)
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            rc = prepare_lua.main(['--cache-dir', str(self.tmp / 'cache')])
        self.assertEqual(rc, 0)
        prepared = Path(stdout.getvalue().strip())
        self.assertTrue(prepared.is_file())
        self.assertEqual(prepared.read_bytes(), REAL_ARTIFACT.read_bytes())
        self.assertIn('repository', stderr.getvalue())
        # A second run must be a pure cache hit.
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            prepare_lua.main(['--cache-dir', str(self.tmp / 'cache')])
        self.assertIn('cache', stderr.getvalue())


if __name__ == '__main__':
    unittest.main()
