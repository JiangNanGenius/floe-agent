#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Host-only regression tests for the FloePatch v1 producer.

Run:
    /Library/Developer/CommandLineTools/usr/bin/python3 \
        FloeAndroid/scripts/update/test_produce_update_delta.py

These tests exercise the byte format and the reference applier only; they do
not touch an APK, a device, Gradle or the network.
"""

import importlib.util
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "produce-update-delta.py")
spec = importlib.util.spec_from_file_location("produce_update_delta", SCRIPT)
producer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(producer)


class FloePatchV1Test(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory(prefix="floe-delta-test-")
        self.base = os.path.join(self.dir.name, "base.bin")
        self.target = os.path.join(self.dir.name, "target.bin")
        self.patch = os.path.join(self.dir.name, "patch.bin")
        self.output = os.path.join(self.dir.name, "out.bin")
        self.base_bytes = bytes((i * 31) % 251 for i in range(48_000))
        self.target_bytes = (
            self.base_bytes[:9_000]
            + bytes((i * 7 + 3) % 251 for i in range(5_000))
            + self.base_bytes[14_000:40_000]
            + bytes((i * 13 + 5) % 251 for i in range(4_000))
        )
        with open(self.base, "wb") as handle:
            handle.write(self.base_bytes)
        with open(self.target, "wb") as handle:
            handle.write(self.target_bytes)

    def tearDown(self):
        self.dir.cleanup()

    def produce(self, base=None, target=None, out=None, window=512, stride=128):
        base = base or self.base
        target = target or self.target
        out = out or self.patch
        ops = producer.build_ops(base, target, window, stride, 4)
        return producer.write_patch(
            ops, out,
            producer.sha256_file(base), producer.file_size(base),
            producer.sha256_file(target), producer.file_size(target),
        )

    def test_round_trip_reconstructs_exact_target(self):
        info = self.produce()
        self.assertEqual(info["ops"]["copyBytes"] + info["ops"]["insertBytes"], len(self.target_bytes))
        proof = producer.apply_patch(
            self.patch, self.base, self.output,
            expected_target_sha=producer.sha256_file(self.target),
            expected_target_size=len(self.target_bytes),
            expected_base_sha=producer.sha256_file(self.base),
            expected_base_size=len(self.base_bytes),
        )
        self.assertEqual(proof["targetSizeBytes"], len(self.target_bytes))
        with open(self.output, "rb") as handle:
            self.assertEqual(handle.read(), self.target_bytes)

    def test_patch_is_deterministic(self):
        first = self.produce()
        second = self.produce(out=os.path.join(self.dir.name, "patch2.bin"))
        self.assertEqual(first["patchSha256"], second["patchSha256"])
        self.assertEqual(first["patchSizeBytes"], second["patchSizeBytes"])

    def test_wrong_base_is_rejected(self):
        self.produce()
        with self.assertRaises(producer.ProducerError):
            producer.apply_patch(
                self.patch, self.base, self.output,
                expected_target_sha=producer.sha256_file(self.target),
                expected_target_size=len(self.target_bytes),
                expected_base_sha="0" * 64,
                expected_base_size=len(self.base_bytes),
            )

    def test_truncated_patch_is_rejected(self):
        self.produce()
        with open(self.patch, "rb") as handle:
            data = handle.read()
        with open(self.patch, "wb") as handle:
            handle.write(data[:-32])
        with self.assertRaises(producer.ProducerError):
            producer.apply_patch(
                self.patch, self.base, self.output,
                expected_target_sha=producer.sha256_file(self.target),
                expected_target_size=len(self.target_bytes),
                expected_base_sha=producer.sha256_file(self.base),
                expected_base_size=len(self.base_bytes),
            )

    def test_corrupt_target_hash_is_rejected(self):
        self.produce()
        with self.assertRaises(producer.ProducerError):
            producer.apply_patch(
                self.patch, self.base, self.output,
                expected_target_sha="f" * 64,
                expected_target_size=len(self.target_bytes),
                expected_base_sha=producer.sha256_file(self.base),
                expected_base_size=len(self.base_bytes),
            )

    def test_identical_inputs_produce_an_all_copy_patch(self):
        info = self.produce(target=self.base, out=os.path.join(self.dir.name, "same.bin"))
        self.assertEqual(info["ops"]["insertBytes"], 0)
        self.assertLess(info["patchSizeBytes"], 4096)

    def test_patch_asset_name_is_safe(self):
        self.assertEqual(
            "Floe-Android-0.1.0-alpha.17-from-0.1.0-alpha.16.delta",
            producer.patch_asset_name("0.1.0-alpha.17", "0.1.0-alpha.16"),
        )
        self.assertEqual(
            "Floe-Android-0.1.0-alpha.17_.._x-from-0.1.0-alpha.16.delta",
            producer.patch_asset_name("0.1.0-alpha.17/../x", "0.1.0-alpha.16"),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
