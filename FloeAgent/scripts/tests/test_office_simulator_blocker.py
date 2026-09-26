#!/usr/bin/env python3
"""Focused checks for the Office simulator-host blocker probe.

The probe proves a device-only `FloeOfficeNative.framework` cannot be linked
against the iOS Simulator SDK. These tests pin the parsing rules (the platform
field is the decisive fact, a legacy LC_VERSION_MIN_IPHONEOS is never read as a
simulator platform) without requiring the pinned artifact, and run the real
end-to-end probe when a framework path is supplied through the environment
(`FLOE_OFFICE_HOST_FRAMEWORK`), which is how the cloud workflow executes it
against the hash-verified pin.

The tests never claim an engine open, render or device result.
"""

import json
import os
from pathlib import Path
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import check_office_simulator_blocker as blocker  # noqa: E402


VTK_DEVICE = """\
FloeOfficeNative:
Load command 10
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform IOS
    minos 26.0
      sdk 27.0
   ntools 1
     tool LD
  version 27037.1
"""

VTK_SIMULATOR = """\
FloeOfficeNative:
Load command 10
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform IOSSIMULATOR
    minos 26.0
      sdk 27.0
"""

VTK_LEGACY = """\
FloeOfficeNative:
Load command 4
      cmd LC_VERSION_MIN_IPHONEOS
  cmdsize 16
  version 12.0
      sdk 14.5
"""


class BlockerParsingTests(unittest.TestCase):
    def test_device_platform_is_parsed_and_is_not_simulator(self):
        facts = blocker.parse_build_version(VTK_DEVICE)
        self.assertEqual(facts['platform'], 'IOS')
        self.assertNotEqual(facts['platform'], blocker.SIMULATOR_PLATFORM)
        self.assertEqual(facts['minimumOS'], '26.0')
        self.assertEqual(facts['sdk'], '27.0')

    def test_simulator_platform_is_detected(self):
        facts = blocker.parse_build_version(VTK_SIMULATOR)
        self.assertEqual(facts['platform'], 'IOSSIMULATOR')

    def test_legacy_min_version_is_not_read_as_a_simulator_slice(self):
        facts = blocker.parse_build_version(VTK_LEGACY)
        self.assertEqual(facts['platform'], 'LEGACY-IOS')
        self.assertNotEqual(facts['platform'], blocker.SIMULATOR_PLATFORM)

    def test_missing_build_version_reports_no_platform(self):
        self.assertEqual(blocker.parse_build_version('no mach-o here')['platform'], '')

    def test_architectures_parse_without_fabricating_a_slice(self):
        self.assertEqual(blocker.parse_architectures('arm64\n'), ['arm64'])
        self.assertEqual(blocker.parse_architectures('arm64 x86_64\n'), ['arm64', 'x86_64'])
        self.assertEqual(blocker.parse_architectures(''), [])

    def test_simulator_target_uses_the_minimum_os(self):
        self.assertEqual(blocker.simulator_target('arm64', '26.0'),
                         'arm64-apple-ios26.0-simulator')
        self.assertEqual(blocker.simulator_target('arm64', ''),
                         'arm64-apple-ios26.0-simulator')

    def test_missing_framework_fails_closed_without_a_claim(self):
        receipt = blocker.probe('/nonexistent/FloeOfficeNative.framework')
        self.assertFalse(receipt['frameworkBinaryExists'])
        self.assertFalse(receipt['simulatorHostBlockerProven'])
        self.assertFalse(receipt['realEngineInSimulator'])


class BlockerEndToEndTests(unittest.TestCase):
    """Run the real probe against a provided framework (cloud workflow)."""

    def test_real_framework_refuses_a_simulator_link(self):
        framework = os.environ.get('FLOE_OFFICE_HOST_FRAMEWORK')
        if not framework:
            self.skipTest('FLOE_OFFICE_HOST_FRAMEWORK is not set')
        expected = os.environ.get('FLOE_OFFICE_HOST_EXECUTABLE_SHA256') or None
        receipt = blocker.probe(framework, expected_executable_sha256=expected)
        self.assertFalse(receipt['platformIsSimulator'],
                         'a simulator-slice framework would invalidate the blocker record')
        self.assertTrue(receipt['simulatorLinkAttempted'])
        self.assertTrue(receipt['simulatorLinkRefused'],
                        f"unexpected simulator link result: {receipt.get('simulatorLinkDiagnostic')}")
        self.assertTrue(receipt['simulatorHostBlockerProven'])
        self.assertFalse(receipt['realEngineInSimulator'])
        if expected:
            self.assertTrue(receipt['matchesPinnedExecutable'])
        Path('/tmp/floe-office-simulator-blocker-receipt.json').write_text(
            json.dumps(receipt, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    unittest.main()
