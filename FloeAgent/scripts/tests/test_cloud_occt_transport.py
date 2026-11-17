"""Focused synthetic checks for locked OCCT evidence; no network or builds."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('occt_transport', ROOT / '.github/scripts/occt_transport.py')
occt = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(occt)


class QualifiedOCCTEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'cad'
        self.root.mkdir()
        self.evidence = self.root.parent / 'evidence.json'
        artifacts = []
        for index, name in enumerate(sorted(occt.EXPECTED_SLICES)):
            data = f'archive-{index}'.encode()
            digest = hashlib.sha256(data).hexdigest()
            path = occt.PREFIX + name
            artifacts.append({'installPath': path, 'derivation': {'receiptPath': path + '.derivation.json',
                              'expectedResult': {'size': len(data), 'sha256': digest}}})
            dest = self.root / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            receipt = {'archive': {'size': len(data), 'sha256': digest},
                       'toolchain': {'xcodeVersion': '27.1', 'xcodeBuild': '27A9275', 'sdkVersion': '27.1'}}
            Path(str(dest) + '.derivation.json').write_text(json.dumps(receipt))
        (self.root / 'DEPENDENCIES.json').write_text(json.dumps({'artifacts': artifacts}))

    def test_capture_then_verify_detects_library_tampering(self):
        occt.capture(self.root, self.evidence)
        occt.verify(self.root, self.evidence)
        path = self.root / occt.PREFIX / sorted(occt.EXPECTED_SLICES)[0]
        path.write_bytes(b'altered')
        with self.assertRaises(ValueError):
            occt.verify(self.root, self.evidence)

    def test_unqualified_toolchain_is_rejected(self):
        path = self.root / occt.PREFIX / (sorted(occt.EXPECTED_SLICES)[0] + '.derivation.json')
        data = json.loads(path.read_text()); data['toolchain']['xcodeVersion'] = '27.2'
        path.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            occt.capture(self.root, self.evidence)
        self.assertFalse(self.evidence.exists())

    def test_changed_receipt_rejected_after_capture(self):
        occt.capture(self.root, self.evidence)
        path = self.root / occt.PREFIX / (sorted(occt.EXPECTED_SLICES)[0] + '.derivation.json')
        data = json.loads(path.read_text()); data['extra'] = 'changed'
        path.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            occt.verify(self.root, self.evidence)

    def test_missing_slice_or_existing_evidence_fails(self):
        path = self.root / occt.PREFIX / sorted(occt.EXPECTED_SLICES)[0]
        path.unlink()
        with self.assertRaises(ValueError):
            occt.capture(self.root, self.evidence)
        self.assertFalse(self.evidence.exists())


if __name__ == '__main__':
    unittest.main()
