import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import qualify_office_mobile as producer
import office_compiled_lifecycle as lifecycle


class OriginalArchiveProofTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.lock = {'commit': 'a' * 40}
        self.contract = {'archive': 'source/engine/instdir/program/libvcllo.a',
                         'additionalArchives': {name: {'archive': 'source/engine/instdir/program/' + name}
                                                for name in ['libsallo.a', 'libsfxlo.a']}}
        self.files = []
        for name in ['libscfiltlo.a', 'libooxlo.a', 'libsdlo.a', 'libvcllo.a', 'libsallo.a', 'libsfxlo.a']:
            relative = 'source/engine/instdir/program/' + name
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(('original-' + name).encode())
            self.files.append({'path': relative, 'size': path.stat().st_size,
                               'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
        self.manifest = self.root / 'bundle-manifest.json'
        self.write_manifest()

    def tearDown(self):
        self.temporary.cleanup()

    def write_manifest(self):
        self.manifest.write_text(json.dumps({'sourceCommit': self.lock['commit'], 'files': self.files}))

    def measure(self, sdk='iphonesimulator'):
        with patch.object(lifecycle, 'contract', return_value=self.contract):
            return producer.platform_original_archives(self.root, self.lock, sdk)

    def test_dynamic_archive_inventory_includes_new_sfx_and_existing_originals(self):
        result = self.measure()
        self.assertEqual(result['sdk'], 'iphonesimulator')
        self.assertEqual(result['archives'], {Path(item['path']).name: item['sha256'] for item in self.files})
        self.assertEqual(self.measure('iphoneos')['sdk'], 'iphoneos')

    def test_new_contract_archive_missing_rejected(self):
        (self.root / self.contract['additionalArchives']['libsfxlo.a']['archive']).unlink()
        with self.assertRaisesRegex(ValueError, 'missing or aliased'):
            self.measure()

    def test_new_archive_missing_from_original_manifest_rejected(self):
        self.files = self.files[:-1]
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, 'differs from cold manifest'):
            self.measure()

    def test_actual_archive_drift_rejected_without_rewriting_manifest(self):
        original = self.manifest.read_bytes()
        (self.root / self.contract['additionalArchives']['libsfxlo.a']['archive']).write_bytes(b'different')
        with self.assertRaisesRegex(ValueError, 'differs from cold manifest'):
            self.measure()
        self.assertEqual(self.manifest.read_bytes(), original)

    def test_unknown_sdk_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Unsupported original archive SDK'):
            self.measure('macosx')

    def test_wrong_original_manifest_commit_rejected(self):
        self.manifest.write_text(json.dumps({'sourceCommit': 'b' * 40, 'files': self.files}))
        with self.assertRaisesRegex(ValueError, 'different engine commit'):
            self.measure()


if __name__ == '__main__':
    unittest.main()
