#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Focused tests for the ZIP-aware FloePatch v1 producer.

Run:
    python3 scripts/update/test_produce_update_delta_zip.py
"""
import importlib.util
import os
import struct
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "produce-update-delta.py")
spec = importlib.util.spec_from_file_location("produce_update_delta_v2", SCRIPT)
producer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(producer)


def make_zip(path, entries):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as archive:
        for name, data in entries:
            archive.writestr(name, data)


def make_zip_mixed(path, entries):
    with zipfile.ZipFile(path, "w") as archive:
        for name, data, method in entries:
            info = zipfile.ZipInfo(name)
            info.compress_type = method
            archive.writestr(info, data)


class ZipProducerV2Test(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="floe-delta-test-")
        self.base = os.path.join(self.tmp.name, "base.apk")
        self.target = os.path.join(self.tmp.name, "target.apk")
        self.patch = os.path.join(self.tmp.name, "patch.delta")
        self.out = os.path.join(self.tmp.name, "out.apk")
        self.shared = bytes((i * 37 + 11) % 251 for i in range(120_000))
        self.shared2 = b"floe-common-entry-" + bytes((i * 13) % 256 for i in range(70_000))
        make_zip(self.base, [
            ("assets/shared.bin", self.shared),
            ("assets/second.bin", self.shared2),
            ("classes.dex", b"base-dex-" + bytes((i * 5) % 256 for i in range(20_000))),
        ])
        # Different local-header lengths shift every later payload byte by a
        # phase that is not a multiple of the old 512-byte stride.
        make_zip(self.target, [
            ("assets/shared.bin", b"prefix-17-bytes!!" + self.shared[500:-300]),
            ("assets/second.bin", self.shared2),
            ("classes.dex", b"target-dex-" + bytes((i * 7) % 256 for i in range(30_000))),
        ])

    def tearDown(self):
        self.tmp.cleanup()

    def produce(self, base=None, target=None, patch=None):
        base = base or self.base
        target = target or self.target
        patch = patch or self.patch
        info = producer.write_patch(
            producer.build_zip_ops(base, target), patch,
            producer.sha256_file(base), producer.file_size(base),
            producer.sha256_file(target), producer.file_size(target),
        )
        proof = producer.apply_patch(
            patch, base, self.out,
            expected_target_sha=producer.sha256_file(target),
            expected_target_size=producer.file_size(target),
            expected_base_sha=producer.sha256_file(base),
            expected_base_size=producer.file_size(base),
        )
        return info, proof

    def test_phase_shifted_zip_roundtrip_and_copy(self):
        info, proof = self.produce()
        self.assertEqual(proof["targetSizeBytes"], os.path.getsize(self.target))
        with open(self.out, "rb") as handle, open(self.target, "rb") as target:
            self.assertEqual(handle.read(), target.read())
        self.assertGreater(info["ops"]["copyBytes"], 100_000)
        self.assertLess(info["patchSizeBytes"], os.path.getsize(self.target))
        self.assertEqual(info["matcher"]["name"], "zip-anchor-crc32")
        # v1 header must carry the exact keys the Android consumer reads.
        with open(self.patch, "rb") as patch:
            self.assertEqual(patch.read(len(producer.MAGIC)), producer.MAGIC)
            length = struct.unpack("<I", patch.read(4))[0]
            raw = producer.json.loads(patch.read(length))
        self.assertEqual(raw["format"], "floepatch")
        self.assertEqual(raw["formatVersion"], 1)
        for key in ("copies", "copyBytes", "inserts", "insertBytes"):
            self.assertIn(key, raw["ops"])

    def test_deflated_identical_entry_is_copied_whole(self):
        payload = bytes((i * 19 + 7) % 256 for i in range(90_000))
        make_zip_mixed(self.base, [
            ("assets/shared.bin", self.shared, zipfile.ZIP_STORED),
            ("assets/deflated.bin", payload, zipfile.ZIP_DEFLATED),
            ("classes.dex", b"base" + self.shared2, zipfile.ZIP_STORED),
        ])
        make_zip_mixed(self.target, [
            ("assets/shared.bin", b"shifted-prefix" + self.shared[100:], zipfile.ZIP_STORED),
            ("assets/deflated.bin", payload, zipfile.ZIP_DEFLATED),
            ("classes.dex", b"target" + self.shared2, zipfile.ZIP_STORED),
        ])
        info, _ = self.produce()
        self.assertGreaterEqual(info["matcherStats"]["identicalEntries"], 1)
        self.assertGreater(info["ops"]["copyBytes"], 80_000)

    def test_recompressed_entry_is_inserted_not_falsely_copied(self):
        payload = bytes((i * 23 + 3) % 256 for i in range(120_000))
        make_zip_mixed(self.base, [
            ("assets/recompressed.bin", payload, zipfile.ZIP_STORED),
            ("classes.dex", self.shared, zipfile.ZIP_STORED),
        ])
        make_zip_mixed(self.target, [
            ("assets/recompressed.bin", payload, zipfile.ZIP_DEFLATED),
            ("classes.dex", self.shared, zipfile.ZIP_STORED),
        ])
        info, _ = self.produce()
        # The deflated target bytes cannot come from the stored base bytes;
        # they must be literal INSERT data.  The unchanged classes.dex copies.
        self.assertGreater(info["matcherStats"]["identicalBytes"], 100_000)

    def test_patch_is_deterministic(self):
        first, _ = self.produce()
        second, _ = self.produce(patch=os.path.join(self.tmp.name, "patch2.delta"))
        self.assertEqual(first["patchSha256"], second["patchSha256"])
        self.assertEqual(first["patchSizeBytes"], second["patchSizeBytes"])

    def test_negative_cases_are_rejected(self):
        self.produce()
        with open(self.patch, "rb") as handle:
            original = handle.read()
        bad = os.path.join(self.tmp.name, "bad.delta")

        with open(bad, "wb") as handle:
            handle.write(original[:-32])
        with self.assertRaises(producer.ProducerError):
            producer.apply_patch(bad, self.base, self.out,
                                 producer.sha256_file(self.target), os.path.getsize(self.target),
                                 producer.sha256_file(self.base), os.path.getsize(self.base))

        with open(bad, "wb") as handle:
            handle.write(b"NOTFLOE\n" + original[len(producer.MAGIC):])
        with self.assertRaises(producer.ProducerError):
            producer.apply_patch(bad, self.base, self.out,
                                 producer.sha256_file(self.target), os.path.getsize(self.target),
                                 producer.sha256_file(self.base), os.path.getsize(self.base))

        with self.assertRaises(producer.ProducerError):
            producer.apply_patch(self.patch, self.base, self.out,
                                 "0" * 64, os.path.getsize(self.target),
                                 producer.sha256_file(self.base), os.path.getsize(self.base))


if __name__ == "__main__":
    unittest.main()
