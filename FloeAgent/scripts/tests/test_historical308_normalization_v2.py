"""Bounded V2 contracts; native calls here are scripted, full308 is separate."""
import importlib.util
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zipfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('normalization', HERE.parent / 'historical308_normalization_v2.py')
normalization = importlib.util.module_from_spec(spec); spec.loader.exec_module(normalization)


def binary(*, signed=False, vmsize=0x4000, fat=False):
    size = 640 + (32 if signed else 0)
    data = bytearray(size)
    struct.pack_into('<IiiIIIII', data, 0, 0xFEEDFACF, 0x100000c, 0, 2, 3 if signed else 2,
                     160 if signed else 144, 0, 0)
    struct.pack_into('<II16sQQQQiiII', data, 32, 0x19, 72, b'__TEXT', 0x100000000, 512, 0, 512, 5, 5, 0, 0)
    struct.pack_into('<II16sQQQQiiII', data, 104, 0x19, 72, b'__LINKEDIT', 0x100000200,
                     vmsize, 512, size - 512, 1, 1, 0, 0)
    data[256:272] = b'non-signatureXYZ'
    data[512:528] = b'linkedit-content'
    if signed:
        struct.pack_into('<IIII', data, 176, 0x1d, 16, 640, 32)
        data[640:] = b'S' * 32
    if fat:
        prefix = bytearray(4096)
        struct.pack_into('>IIiiIII', prefix, 0, 0xcafebabe, 1, 0x100000c, 0, 4096, size, 12)
        return bytes(prefix + data)
    return bytes(data)


def metadata(value=b'fixture-value'):
    name = b'com.floe.fixture\0'
    start, entry = 84, 120
    data_start = (entry + 11 + len(name) + 3) & ~3
    total = data_start + len(value)
    data = bytearray(total)
    struct.pack_into('>II16sH', data, 0, 0x51607, 0x20000, b'Mac OS X        ', 2)
    struct.pack_into('>III', data, 26, 9, 50, total - 50)
    struct.pack_into('>III', data, 38, 2, total, 0)
    struct.pack_into('>8I2H', data, start, 0x41545452, 0, total, data_start, len(value), 0, 0, 0, 0, 1)
    struct.pack_into('>IIHB', data, entry, data_start, len(value), 0, len(name))
    data[entry + 11:entry + 11 + len(name)] = name
    data[data_start:] = value
    return bytes(data)


class Historical308NormalizationV2Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_complete_roundtrip_proof_covers_thin_and_fat_without_masking_effective_metadata(self):
        for fat in (False, True):
            for signed in (False, True):
                with self.subTest(fat=fat, signed=signed):
                    before = binary(signed=signed, vmsize=0x8000 if signed else 0x2000, fat=fat)
                    after = binary(vmsize=0x4000, fat=fat)
                    proof = normalization.prove_roundtrip(before, after)
                    self.assertTrue(proof['nonSignatureDataUnchanged'])
                    self.assertTrue(proof['finalUnsigned'])
                    self.assertEqual(proof['inputSHA256'], normalization.sha(before))
                    self.assertEqual(proof['outputSHA256'], normalization.sha(after))
                    self.assertTrue(any(r['field'] == '__LINKEDIT.vmsize' for r in proof['changedRanges']))
                    self.assertGreater(sum(s['bytes'] for s in proof['nonSignatureSpans']), 500)

    def test_code_non_signature_header_or_unexplained_tail_changes_are_rejected(self):
        before = binary(signed=True, vmsize=0x8000)
        for offset in (256, 512, 60):
            with self.subTest(offset=offset):
                changed = bytearray(binary()); changed[offset] ^= 1
                with self.assertRaises(normalization.NormalizationError):
                    normalization.prove_roundtrip(before, bytes(changed))
        with self.assertRaises(normalization.NormalizationError):
            normalization.prove_roundtrip(binary(), binary() + b'unknown bytes')
        bad = bytearray(before); bad[639] = 1
        with self.assertRaises(normalization.NormalizationError):
            normalization.prove_roundtrip(bytes(bad), binary()[:-1])

    def test_native_command_contract_is_fixed_adhoc_verified_removed_and_fail_closed(self):
        app = self.root / 'Floe Agent.app'; app.mkdir()
        executable = app / 'binary'; executable.write_bytes(binary(vmsize=0x2000)); executable.chmod(0o755)
        calls = []
        def native(argv, **kwargs):
            calls.append(argv)
            if '--force' in argv:
                executable.write_bytes(binary(signed=True))
            elif '--remove-signature' in argv:
                executable.write_bytes(binary())
            return subprocess.CompletedProcess(argv, 0, '', '')
        result = normalization.normalize_machos(app, invoke=native, require_unsigned=True)
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[0][:-1], ['/usr/bin/codesign', '--force', '--sign', '-', '--identifier',
                                       normalization.IDENTIFIER, '--timestamp=none'])
        self.assertIn('--verify', calls[1]); self.assertIn('--remove-signature', calls[2])
        self.assertTrue(result['files'][0]['nonSignatureDataUnchanged'])
        executable.write_bytes(binary(signed=True))
        with self.assertRaises(normalization.NormalizationError):
            normalization.normalize_machos(app, invoke=native, require_unsigned=True)
        executable.write_bytes(binary())
        refused = []
        def deny(argv, **kwargs):
            refused.append(argv); return subprocess.CompletedProcess(argv, 1, '', 'official tool rejected')
        with self.assertRaises(normalization.NormalizationError):
            normalization.normalize_machos(app, invoke=deny)
        self.assertEqual(len(refused), 1)

    def test_valid_appledouble_and_extended_attributes_are_structurally_bound(self):
        data = metadata()
        parsed = normalization.appledouble(data)
        self.assertEqual(parsed['sha256'], normalization.sha(data))
        self.assertEqual(len(parsed['attributes']), 1)
        self.assertNotIn('fixture-value', str(parsed))
        changes = [(0, b'FAKE'), (26, struct.pack('>I', 99)), (30, struct.pack('>I', 0xffffffff)),
                   (38, struct.pack('>I', 9)), (116, struct.pack('>HH', 0, 257)),
                   (120, struct.pack('>I', 0xffffffff))]
        for offset, value in changes:
            with self.subTest(offset=offset):
                bad = bytearray(data); bad[offset:offset + len(value)] = value
                with self.assertRaises(normalization.NormalizationError): normalization.appledouble(bytes(bad))

    def paired(self, *, source_bytes=None, transport_bytes=None, source_member=True, transport_member=True,
               target=True, name='._Fixture'):
        source_bytes = metadata() if source_bytes is None else source_bytes
        transport_bytes = source_bytes if transport_bytes is None else transport_bytes
        prefix = 'Payload/Floe Agent.app/'
        relative = 'Frameworks/Fixture.framework/' + name
        original, transport = self.root / 'signed.ipa', self.root / 'transport.zip'
        for path, signed in ((original, True), (transport, False)):
            with zipfile.ZipFile(path, 'w') as archive:
                if target: archive.writestr(prefix + 'Frameworks/Fixture.framework/Fixture', b'original target')
                if signed and source_member: archive.writestr('__MACOSX/' + prefix + relative, source_bytes)
                if not signed and transport_member: archive.writestr(prefix + relative, transport_bytes)
        signed_app, transport_app = self.root / 'signed/Floe Agent.app', self.root / 'transport/Floe Agent.app'
        for app in (signed_app, transport_app): app.mkdir(parents=True, exist_ok=True)
        local = transport_app / relative; local.parent.mkdir(parents=True, exist_ok=True)
        if transport_member: local.write_bytes(transport_bytes)
        return original, transport, signed_app, transport_app, relative

    def test_only_full_equal_valid_same_path_pairs_move_to_separate_metadata_evidence(self):
        original, transport, signed_app, transport_app, relative = self.paired()
        result = normalization.paired_metadata(original, transport, signed_app, transport_app, self.root / 'mapped')
        self.assertEqual(result['summary']['mappings'], 1)
        self.assertEqual((self.root / 'mapped' / relative).read_bytes(), metadata())
        self.assertFalse((transport_app / relative).exists())
        self.assertEqual(result['entries'][0]['targetPath'], 'Frameworks/Fixture.framework/Fixture')

    def test_unknown_missing_conflicting_invalid_or_orphan_metadata_never_moves(self):
        for index, change in enumerate(({'source_member': False}, {'transport_member': False},
                {'transport_bytes': metadata(b'different')}, {'source_bytes': b'not AppleDouble'},
                {'target': False}, {'name': '._Unknown'})):
            with self.subTest(change=change):
                case = self.root / str(index); case.mkdir()
                original_root = self.root; self.root = case
                try:
                    original, transport, signed_app, transport_app, relative = self.paired(**change)
                    with self.assertRaises(normalization.NormalizationError):
                        normalization.paired_metadata(original, transport, signed_app, transport_app, case / 'mapped')
                    self.assertFalse((case / 'mapped').exists())
                    if change.get('transport_member', True): self.assertTrue((transport_app / relative).exists())
                finally:
                    self.root = original_root


if __name__ == '__main__':
    unittest.main()
