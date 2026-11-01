#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Focused offline tests for channel-exact native packaging in check-apk.py.

Synthetic in-memory facts only: no APK is built, signed, installed or read, and
no SDK tool is invoked. The tests pin the Full/Play distinction:

* Full requires extractNativeLibs=true, accepts deflated ZIP entries and still
  rejects an unaligned stored entry, a non-16 KiB ELF load segment, or a
  missing extracted starter;
* Play requires extractNativeLibs=false and every native entry stored and
  16 KiB zip-aligned; true is rejected rather than treated as an alternative.

Run directly::

    PYTHONDONTWRITEBYTECODE=1 python3 \
        FloeAndroid/scripts/tests/test_check_apk_packaging.py -v
"""

import importlib.util
import sys
import unittest
from pathlib import Path

CHECKER = Path(__file__).resolve().parents[1] / "check-apk.py"


def _load_checker():
    spec = importlib.util.spec_from_file_location(
        "floe_check_apk_under_test", CHECKER
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load check-apk.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


checker = _load_checker()


def native(name, stored=False, zip_aligned=False, elfs=(checker.PAGE_16K,)):
    return {
        "name": "lib/arm64-v8a/" + name,
        "entry": name,
        "stored": stored,
        "zipAligned": zip_aligned,
        "elfMachine": checker.ELF_EM_AARCH64,
        "loadSegmentAlignments": list(elfs),
    }


def baseline_full():
    return [
        native("libFloeAndroidCore.so"),
        native("libfloe_jni.so"),
        native("libfloe_starter.so"),
    ]


def baseline_play():
    return [
        native("libFloeAndroidCore.so", stored=True, zip_aligned=True),
        native("libfloe_jni.so", stored=True, zip_aligned=True),
    ]


class NativePackagingPolicyTests(unittest.TestCase):
    def run_checks(self, variant, libraries, extracted):
        checks = checker.native_packaging_checks(variant, libraries, extracted)
        return checks, {check["id"]: check for check in checks}

    def assert_failed(self, by_id, identifier):
        self.assertIn(identifier, by_id)
        self.assertFalse(by_id[identifier]["ok"], by_id[identifier])

    def test_full_requires_extraction_and_accepts_deflated_entries(self):
        checks, by_id = self.run_checks("full", baseline_full(), "true")
        self.assertTrue(all(check["ok"] for check in checks), checks)
        self.assertIn("full.native.extractNativeLibsTrue", by_id)
        self.assertTrue(by_id["full.native.zip16k"]["ok"])

    def test_full_rejects_extract_native_libs_false(self):
        _, by_id = self.run_checks("full", baseline_full(), "false")
        self.assert_failed(by_id, "full.native.extractNativeLibsTrue")

    def test_full_absent_extract_native_libs_is_rejected(self):
        _, by_id = self.run_checks("full", baseline_full(), None)
        self.assert_failed(by_id, "full.native.extractNativeLibsTrue")

    def test_full_still_rejects_unaligned_stored_entry(self):
        libraries = baseline_full()
        libraries[0]["stored"] = True
        libraries[0]["zipAligned"] = False
        _, by_id = self.run_checks("full", libraries, "true")
        self.assert_failed(by_id, "full.native.zip16k")

    def test_full_still_rejects_non_16k_elf(self):
        libraries = baseline_full()
        libraries[0]["loadSegmentAlignments"] = [4096]
        _, by_id = self.run_checks("full", libraries, "true")
        self.assert_failed(by_id, "full.native.elf16k")

    def test_full_requires_the_extracted_starter(self):
        libraries = [item for item in baseline_full()
                     if item["entry"] != "libfloe_starter.so"]
        _, by_id = self.run_checks("full", libraries, "true")
        self.assert_failed(by_id, "full.native.extractedStarter")

    def test_play_requires_mapped_stored_entries(self):
        checks, by_id = self.run_checks("play", baseline_play(), "false")
        self.assertTrue(all(check["ok"] for check in checks), checks)
        self.assertIn("play.native.extractNativeLibsFalse", by_id)
        self.assertTrue(by_id["play.native.zip16k"]["ok"])

    def test_play_rejects_extraction_true(self):
        _, by_id = self.run_checks("play", baseline_play(), "true")
        self.assert_failed(by_id, "play.native.extractNativeLibsFalse")

    def test_play_rejects_deflated_entry(self):
        libraries = baseline_play()
        libraries[0]["stored"] = False
        libraries[0]["zipAligned"] = False
        _, by_id = self.run_checks("play", libraries, "false")
        self.assert_failed(by_id, "play.native.zip16k")

    def test_play_absent_extract_native_libs_is_rejected(self):
        _, by_id = self.run_checks("play", baseline_play(), None)
        self.assert_failed(by_id, "play.native.extractNativeLibsFalse")

    def test_elf_16k_is_required_for_play_too(self):
        libraries = baseline_play()
        libraries[0]["loadSegmentAlignments"] = [4096]
        _, by_id = self.run_checks("play", libraries, "false")
        self.assert_failed(by_id, "play.native.elf16k")


if __name__ == "__main__":
    unittest.main(verbosity=2)
