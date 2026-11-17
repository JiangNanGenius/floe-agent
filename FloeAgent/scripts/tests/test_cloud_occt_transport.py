"""Focused, synthetic transport tests; no Apple or GitHub access."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('occt_transport', ROOT / '.github/scripts/occt_transport.py')
occt = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(occt)


class QualifiedOCCTTransportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.tmp = Path(self.temporary.name)
        self.root = self.tmp / 'cad'
        self.root.mkdir()
        self.members = {}
        artifacts = []
        for index, name in enumerate(sorted(occt.EXPECTED_SLICES)):
            data = f'archive-{index}'.encode()
            digest = hashlib.sha256(data).hexdigest()
            path = occt.PREFIX + name
            artifacts.append({'installPath': path, 'derivation': {'receiptPath': path + '.derivation.json',
                              'expectedResult': {'size': len(data), 'sha256': digest}}})
            self.members[name] = data
            self.members[name + '.derivation.json'] = json.dumps({'archive': {'size': len(data), 'sha256': digest},
                                                                 'toolchain': {'xcodeVersion': '27.1'}}).encode()
            (self.root / occt.PREFIX / Path(name).parent).mkdir(parents=True, exist_ok=True)
        (self.root / 'DEPENDENCIES.json').write_text(json.dumps({'artifacts': artifacts}))
        self.archive = self.tmp / 'input.zip'
        self.evidence = self.tmp / 'evidence.json'

    def make_zip(self, members):
        with zipfile.ZipFile(self.archive, 'w') as archive:
            for name, data in members:
                archive.writestr(name, data)
        return occt.sha(self.archive)

    def test_install_and_post_build_verification_detect_tampering(self):
        digest = self.make_zip(self.members.items())
        occt.install(self.root, self.archive, digest, self.evidence)
        occt.verify(self.root, self.evidence)
        path = self.root / occt.PREFIX / sorted(occt.EXPECTED_SLICES)[0]
        path.write_bytes(b'altered')
        with self.assertRaises(ValueError):
            occt.verify(self.root, self.evidence)

    def test_wrong_transport_digest_rejected(self):
        self.make_zip(self.members.items())
        with self.assertRaises(ValueError):
            occt.install(self.root, self.archive, '0' * 64, self.evidence)
        self.assertFalse(self.evidence.exists())

    def test_duplicate_extra_and_wrong_archive_bytes_rejected(self):
        rows = list(self.members.items())
        cases = (rows + [rows[0]], rows + [('../escape', b'x')],
                 [(name, b'x' if name in occt.EXPECTED_SLICES else data) for name, data in rows])
        for members in cases:
            with self.subTest(members=len(members)):
                digest = self.make_zip(members)
                with self.assertRaises(ValueError):
                    occt.install(self.root, self.archive, digest, self.evidence)
                self.assertFalse(self.evidence.exists())

    def test_changed_receipt_rejected_after_install(self):
        digest = self.make_zip(self.members.items())
        occt.install(self.root, self.archive, digest, self.evidence)
        name = sorted(occt.EXPECTED_SLICES)[0]
        path = self.root / occt.PREFIX / (name + '.derivation.json')
        data = json.loads(path.read_text()); data['toolchain']['xcodeVersion'] = '27.2'
        path.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            occt.verify(self.root, self.evidence)


if __name__ == '__main__':
    unittest.main()
