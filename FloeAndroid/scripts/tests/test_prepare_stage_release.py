#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Focused offline tests for the Android stage-release asset preparation tool.

These tests use only stdlib, synthetic bytes and small read-only text fixtures
captured from existing component-qualification APKs. The positive preparation
path uses a fake inspector so it does not require a formally signed APK; that
is UNIT evidence only. The optional ``RealArtifact`` tests use the actual
installed ``aapt2``/``apksigner`` and existing qualification APKs only when the
FLOE_ANDROID_* environment variables are supplied, and they assert the
expected REJECTION of the current unsigned/debug artifacts.

No test creates a key, signs an APK, builds Gradle/Swift, calls a device, or
writes to the repository. The production CLI has no fake/skip-verification
switch.

Run directly::

    PYTHONDONTWRITEBYTECODE=1 python3 \
        FloeAndroid/scripts/tests/test_prepare_stage_release.py -v
"""

import argparse
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent / "fixtures"
SCRIPT = Path(__file__).resolve().parents[1] / "prepare-stage-release.py"


def _load_tool():
    spec = importlib.util.spec_from_file_location(
        "floe_prepare_stage_release_under_test", SCRIPT
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load stage-release tool")
    module = importlib.util.module_from_spec(spec)
    # Register before exec so dataclasses and typing work on Python 3.9.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


tool = _load_tool()

PACKAGE = "com.floe.agent.full"
VERSION = "0.1.0-g02"
TAG = "android/v" + VERSION
CERT = "ab" * 32
SOURCE_COMMIT = "a" * 40
DEBUG_CERT = "44c68beed4bf95da6d1653b2b1f724dd879d72b9b4ff7dd6fdcb7487120a3789"


def fixture(name):
    return (FIXTURES / name).read_text(encoding="utf-8")


def valid_zip_facts():
    return {
        "entryCount": 9,
        "uncompressedBytes": 4096,
        "abis": [tool.ANDROID_ABI],
        "nativeEntries": [
            "lib/arm64-v8a/libFloeAndroidCore.so",
            "lib/arm64-v8a/libfloe_jni.so",
        ],
        "dexEntries": ["classes.dex"],
        "licenseEntries": ["META-INF/androidx/example/LICENSE.txt"],
        "hasManifest": True,
        "problems": [],
    }


def valid_manifest_facts():
    return {
        "package": PACKAGE,
        "versionCode": 8,
        "versionName": VERSION,
        "minSdk": 28,
        "targetSdk": 37,
        "debuggable": False,
        "testOnly": False,
        "split": None,
        "extractNativeLibs": False,
        "hasInstrumentation": False,
        "applicationLabel": "@0x7f090004",
    }


def valid_badging_facts():
    return {
        "package": PACKAGE,
        "versionCode": "8",
        "versionName": VERSION,
        "abis": [tool.ANDROID_ABI],
    }


def valid_signing_facts():
    return {
        "verified": True,
        "schemes": {"v1": False, "v2": True, "v3": True, "v3.1": False},
        "modernScheme": True,
        "signerCount": 1,
        "certSha256": CERT,
        "dn": "CN=Formal Floe, O=Floe",
        "debugCertificate": False,
        "problems": [],
    }


def valid_dex_facts():
    return {
        "dexFiles": ["classes.dex"],
        "classCount": 100,
        "markers": {marker: True for marker in tool.FULL_ONLY_MARKERS},
        "fullOnlyClassCount": 4,
    }


def valid_native_facts():
    return {
        "abi": tool.ANDROID_ABI,
        "libraries": [
            {
                "name": "lib/arm64-v8a/libFloeAndroidCore.so",
                "bytes": 1234,
                "sha256": "11" * 32,
                "stored": True,
                "zipDataOffset": 16384,
                "zipAligned": True,
                "minLoadAlignment": 16384,
                "loadAlignments": [16384, 16384],
                "buildId": "22" * 20,
                "debugSectionBytes": 0,
                "debugSections": {},
                "needed": ["libc.so", "libm.so"],
                "exportCount": 10,
                "jniExportCount": 0,
                "sectionHeaders": True,
            },
            {
                "name": "lib/arm64-v8a/libfloe_jni.so",
                "bytes": 5678,
                "sha256": "33" * 32,
                "stored": True,
                "zipDataOffset": 32768,
                "zipAligned": True,
                "minLoadAlignment": 16384,
                "loadAlignments": [16384],
                "buildId": "44" * 20,
                "debugSectionBytes": 0,
                "debugSections": {},
                "needed": ["libc.so", "libFloeAndroidCore.so"],
                "exportCount": 7,
                "jniExportCount": 3,
                "sectionHeaders": True,
            },
        ],
        "problems": [],
        "debugSectionBytes": 0,
        "maxDebugSectionBytes": 0,
        "testOnlyLibraries": [],
        "stripped": True,
    }


def valid_facts():
    return {
        "zip": valid_zip_facts(),
        "manifest": valid_manifest_facts(),
        "badging": valid_badging_facts(),
        "signing": valid_signing_facts(),
        "dex": valid_dex_facts(),
        "native": valid_native_facts(),
        "toolVersions": {"aapt2": "fake-aapt2", "apksigner": "fake-apksigner"},
    }


class FakeInspector:
    """Test-only inspector; unreachable from the production CLI."""

    def __init__(self, facts=None, error=None):
        self.facts = copy.deepcopy(facts if facts is not None else valid_facts())
        self.error = error
        self.calls = []

    def inspect(self, apk):
        self.calls.append(Path(apk))
        if self.error is not None:
            raise self.error
        return copy.deepcopy(self.facts)


def policy_for(apk, expected_sha256, **overrides):
    values = {
        "apk": Path(apk),
        "expected_sha256": expected_sha256,
        "package": PACKAGE,
        "version_code": 8,
        "version_name": VERSION,
        "tag": TAG,
        "cert_sha256": CERT,
        "source_commit": SOURCE_COMMIT,
        "min_sdk": 28,
        "target_sdk": 37,
        "maturity": "prerelease",
        "source_repository": None,
        "previous_version_code": None,
        "previous_cert_sha256": None,
        "previous_package": None,
        "previous_release_tag": None,
        "stage_label": "G02",
        "native_manifest": None,
        "native_manifest_role": "canonical",
    }
    values.update(overrides)
    return tool.ReleasePolicy(**values)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


class BaseTempTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="floe-stage-release-test-")
        self.tmp = Path(self._tmp.name)
        self.apk_path = self.tmp / "app-full-release.apk"
        self.apk_bytes = b"SYNTHETIC-APK-BYTES-" + bytes(range(256)) * 64
        self.apk_path.write_bytes(self.apk_bytes)
        self.apk_sha = sha256_bytes(self.apk_bytes)
        self.output = self.tmp / "upload-assets"
        self.body = self.tmp / "release-body.md"

    def tearDown(self):
        self._tmp.cleanup()

    def policy(self, **overrides):
        expected = overrides.pop("expected_sha256", self.apk_sha)
        return policy_for(self.apk_path, expected, **overrides)

    def cli_namespace(self, **overrides):
        values = {
            "apk": str(self.apk_path),
            "apksigner": None,
            "aapt2": None,
            "expected_sha256": self.apk_sha,
            "package": PACKAGE,
            "version_code": 8,
            "version_name": VERSION,
            "tag": TAG,
            "cert_sha256": CERT,
            "source_commit": SOURCE_COMMIT,
            "source_repository": None,
            "min_sdk": 28,
            "target_sdk": 37,
            "maturity": "prerelease",
            "stage_label": "G02",
            "previous_version_code": None,
            "previous_cert_sha256": None,
            "previous_package": None,
            "previous_release_tag": None,
            "native_manifest": None,
            "native_manifest_role": "canonical",
            "output": str(self.output),
            "body_out": str(self.body),
        }
        values.update(overrides)
        return argparse.Namespace(**values)


class PolicyValidationTests(BaseTempTest):
    def assert_policy_error(self, code, **overrides):
        with self.assertRaises(tool.StageReleaseError) as caught:
            tool.policy_from_args(self.cli_namespace(**overrides))
        self.assertEqual(caught.exception.code, code, caught.exception.message)

    def test_valid_policy_binds_tag_version_and_artifact(self):
        policy = tool.policy_from_args(self.cli_namespace())
        self.assertEqual(policy.tag, TAG)
        self.assertEqual(policy.version_name, VERSION)
        self.assertEqual(policy.expected_sha256, self.apk_sha)
        self.assertEqual(policy.asset_filename(), "Floe-Android-0.1.0-g02-full-arm64-v8a.apk")

    def test_tag_must_be_android_prefixed(self):
        self.assert_policy_error("arg.tag", tag=VERSION)

    def test_version_name_must_match_tag(self):
        self.assert_policy_error(
            "arg.version-name-mismatch", version_name="0.1.0-g03"
        )

    def test_tag_rejects_path_traversal(self):
        self.assert_policy_error(
            "arg.tag", tag="android/v../evil", version_name="../evil"
        )

    def test_package_rejects_debug_suffix(self):
        self.assert_policy_error("arg.package", package="com.floe.agent.full.dev")

    def test_package_rejects_debug_named_suffix(self):
        self.assert_policy_error("arg.package", package="com.floe.agent.full.debug")

    def test_known_debug_certificate_is_rejected(self):
        self.assert_policy_error("arg.cert-debug", cert_sha256=DEBUG_CERT)

    def test_previous_requires_complete_trio(self):
        self.assert_policy_error(
            "arg.previous-incomplete", previous_version_code=7
        )

    def test_previous_version_code_must_increase(self):
        self.assert_policy_error(
            "arg.version-code-not-increasing",
            previous_version_code=8,
            previous_cert_sha256=CERT,
            previous_package=PACKAGE,
        )

    def test_previous_package_must_match(self):
        self.assert_policy_error(
            "arg.previous-package-mismatch",
            previous_version_code=7,
            previous_cert_sha256=CERT,
            previous_package="com.other.package",
        )

    def test_previous_certificate_must_match(self):
        self.assert_policy_error(
            "arg.previous-cert-mismatch",
            previous_version_code=7,
            previous_cert_sha256="cd" * 32,
            previous_package=PACKAGE,
        )

    def test_previous_ios_tag_is_rejected(self):
        self.assert_policy_error(
            "arg.tag",
            previous_version_code=7,
            previous_cert_sha256=CERT,
            previous_package=PACKAGE,
            previous_release_tag="v1.7.39",
        )

    def test_min_sdk_must_not_exceed_target(self):
        self.assert_policy_error("arg.sdk", min_sdk=37, target_sdk=28)

    def test_sha_must_be_hex(self):
        self.assert_policy_error("arg.sha256", expected_sha256="not-a-hash")

    def test_cli_rejects_skip_verification_switch(self):
        parser = tool.build_parser()
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                parser.parse_args(
                    [
                        "check",
                        "--apk",
                        str(self.apk_path),
                        "--expected-sha256",
                        self.apk_sha,
                        "--package",
                        PACKAGE,
                        "--version-code",
                        "8",
                        "--version-name",
                        VERSION,
                        "--tag",
                        TAG,
                        "--cert-sha256",
                        CERT,
                        "--source-commit",
                        SOURCE_COMMIT,
                        "--min-sdk",
                        "28",
                        "--target-sdk",
                        "37",
                        "--maturity",
                        "prerelease",
                        "--skip-verify",
                    ]
                )

    def test_cli_rejects_inspector_injection_switch(self):
        parser = tool.build_parser()
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                parser.parse_args(
                    [
                        "prepare",
                        "--apk",
                        str(self.apk_path),
                        "--expected-sha256",
                        self.apk_sha,
                        "--package",
                        PACKAGE,
                        "--version-code",
                        "8",
                        "--version-name",
                        VERSION,
                        "--tag",
                        TAG,
                        "--cert-sha256",
                        CERT,
                        "--source-commit",
                        SOURCE_COMMIT,
                        "--min-sdk",
                        "28",
                        "--target-sdk",
                        "37",
                        "--maturity",
                        "prerelease",
                        "--output",
                        str(self.output),
                        "--body-out",
                        str(self.body),
                        "--inspector",
                        "fake",
                    ]
                )


class ZipSafetyTests(BaseTempTest):
    def write_zip(self, entries, symlink=None, duplicate=None):
        path = self.tmp / "fixture.apk"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            with zipfile.ZipFile(str(path), "w", zipfile.ZIP_DEFLATED) as archive:
                for name, data in entries:
                    archive.writestr(name, data)
                if duplicate:
                    archive.writestr(duplicate, b"duplicate")
                if symlink:
                    info = zipfile.ZipInfo(symlink)
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(info, b"target")
        return path

    def base_entries(self):
        return [
            ("AndroidManifest.xml", b"manifest"),
            ("classes.dex", b"dex"),
            ("lib/arm64-v8a/libFloeAndroidCore.so", b"elf"),
        ]

    def test_valid_zip_shape(self):
        path = self.write_zip(self.base_entries())
        facts = tool.zip_structure_facts(path)
        self.assertEqual(facts["abis"], [tool.ANDROID_ABI])
        self.assertTrue(facts["hasManifest"])
        self.assertEqual(facts["dexEntries"], ["classes.dex"])
        self.assertEqual(facts["problems"], [])

    def test_traversal_entry_is_rejected(self):
        path = self.write_zip(self.base_entries() + [("../evil", b"x")])
        ids = {problem["id"] for problem in tool.zip_structure_facts(path)["problems"]}
        self.assertIn("zip.entry.traversal", ids)

    def test_absolute_entry_is_rejected(self):
        path = self.write_zip(self.base_entries() + [("/evil", b"x")])
        ids = {problem["id"] for problem in tool.zip_structure_facts(path)["problems"]}
        self.assertIn("zip.entry.absolute", ids)

    def test_backslash_entry_is_rejected(self):
        path = self.write_zip(self.base_entries() + [("lib\\evil.so", b"x")])
        ids = {problem["id"] for problem in tool.zip_structure_facts(path)["problems"]}
        self.assertIn("zip.entry.backslash", ids)

    def test_duplicate_entry_is_rejected(self):
        path = self.write_zip(self.base_entries(), duplicate="classes.dex")
        ids = {problem["id"] for problem in tool.zip_structure_facts(path)["problems"]}
        self.assertIn("zip.entry.duplicate", ids)

    def test_symlink_entry_is_rejected(self):
        path = self.write_zip(
            self.base_entries() + [("assets/link", b"x")], symlink="assets/link"
        )
        ids = {problem["id"] for problem in tool.zip_structure_facts(path)["problems"]}
        self.assertIn("zip.entry.symlink", ids)

    def test_aab_marker_is_rejected(self):
        path = self.write_zip(self.base_entries() + [("BundleConfig.pb", b"x")])
        ids = {problem["id"] for problem in tool.zip_structure_facts(path)["problems"]}
        self.assertIn("input.aab", ids)

    def test_nested_package_is_rejected(self):
        path = self.write_zip(self.base_entries() + [("payload.apk", b"x")])
        ids = {problem["id"] for problem in tool.zip_structure_facts(path)["problems"]}
        self.assertIn("zip.entry.nested-package", ids)

    def test_zip_data_offset_is_resolved(self):
        path = self.write_zip(self.base_entries())
        with zipfile.ZipFile(str(path), "r") as archive:
            info = archive.getinfo("lib/arm64-v8a/libFloeAndroidCore.so")
            offset = tool.zip_data_offset(archive, info)
        self.assertGreater(offset, 0)


class ManifestParserTests(unittest.TestCase):
    def test_debug_manifest_fixture(self):
        facts = tool.manifest_tree_facts(
            tool.parse_xmltree(fixture("aapt2_xmltree_full_debug.txt"))
        )
        self.assertEqual(facts["package"], "com.floe.agent.full.dev")
        self.assertEqual(facts["versionCode"], 1)
        self.assertEqual(facts["versionName"], "0.1.0-g01")
        self.assertEqual(facts["minSdk"], 28)
        self.assertEqual(facts["targetSdk"], 37)
        self.assertTrue(facts["debuggable"])
        self.assertFalse(facts["testOnly"])
        self.assertFalse(facts["hasInstrumentation"])
        self.assertIsNone(facts["split"])
        self.assertFalse(facts["extractNativeLibs"])

    def test_release_manifest_fixture(self):
        facts = tool.manifest_tree_facts(
            tool.parse_xmltree(fixture("aapt2_xmltree_full_release_unsigned.txt"))
        )
        self.assertEqual(facts["package"], PACKAGE)
        self.assertEqual(facts["versionCode"], 1)
        self.assertEqual(facts["versionName"], "0.1.0-g01")
        self.assertFalse(facts["debuggable"])
        self.assertFalse(facts["hasInstrumentation"])
        self.assertFalse(facts["extractNativeLibs"])

    def test_badging_fixture(self):
        facts = tool.parse_badging_output(
            fixture("aapt2_badging_full_release_unsigned.txt")
        )
        self.assertEqual(facts["package"], PACKAGE)
        self.assertEqual(facts["versionCode"], "1")
        self.assertEqual(facts["versionName"], "0.1.0-g01")
        self.assertEqual(facts["abis"], [tool.ANDROID_ABI])

    def test_badging_rejects_malformed_package_line(self):
        with self.assertRaises(tool.StageReleaseError):
            tool.parse_badging_output("not a badging line\n")


class SigningParserTests(unittest.TestCase):
    def test_unsigned_fixture_is_rejected(self):
        facts = tool.parse_apksigner_output(fixture("apksigner_unsigned.txt"))
        self.assertFalse(facts["verified"])
        ids = {problem["id"] for problem in facts["problems"]}
        self.assertIn("signing.not-verified", ids)

    def test_debug_fixture_detects_debug_certificate(self):
        facts = tool.parse_apksigner_output(fixture("apksigner_debug.txt"))
        self.assertFalse(facts["verified"])
        self.assertTrue(facts["modernScheme"])
        self.assertTrue(facts["debugCertificate"])
        self.assertEqual(facts["certSha256"], DEBUG_CERT)
        ids = {problem["id"] for problem in facts["problems"]}
        self.assertIn("signing.debug-certificate", ids)

    def formal_text(self, v1="false", v2="true", v3="true", signers=1, digests=None, dns=None):
        digests = digests or [CERT]
        dns = dns or ["CN=Formal Floe, O=Floe"]
        lines = [
            "Verifies",
            "Verified using v1 scheme (JAR signing): {}".format(v1),
            "Verified using v2 scheme (APK Signature Scheme v2): {}".format(v2),
            "Verified using v3 scheme (APK Signature Scheme v3): {}".format(v3),
            "Number of signers: {}".format(signers),
        ]
        for digest in digests:
            lines.append("V2 Signer: certificate SHA-256 digest: {}".format(digest))
        for dn in dns:
            lines.append("V2 Signer: certificate DN: {}".format(dn))
        return "\n".join(lines) + "\n"

    def test_formal_output_is_accepted(self):
        facts = tool.parse_apksigner_output(self.formal_text())
        self.assertTrue(facts["verified"])
        self.assertTrue(facts["modernScheme"])
        self.assertFalse(facts["debugCertificate"])
        self.assertEqual(facts["certSha256"], CERT)

    def test_v1_only_is_rejected(self):
        facts = tool.parse_apksigner_output(self.formal_text(v1="true", v2="false", v3="false"))
        self.assertFalse(facts["verified"])
        ids = {problem["id"] for problem in facts["problems"]}
        self.assertIn("signing.legacy-only", ids)

    def test_multiple_signers_are_rejected(self):
        facts = tool.parse_apksigner_output(
            self.formal_text(signers=2, digests=[CERT, "cd" * 32])
        )
        self.assertFalse(facts["verified"])
        ids = {problem["id"] for problem in facts["problems"]}
        self.assertIn("signing.multiple-signers", ids)
        self.assertIn("signing.certificate-count", ids)

    def test_missing_signer_count_is_rejected(self):
        text = self.formal_text().replace("Number of signers: 1\n", "")
        facts = tool.parse_apksigner_output(text)
        self.assertFalse(facts["verified"])
        ids = {problem["id"] for problem in facts["problems"]}
        self.assertIn("signing.signer-count", ids)


class EvaluationTests(BaseTempTest):
    def evaluate(self, facts=None, policy=None, apk_sha=None, apk_bytes=None):
        facts = facts if facts is not None else valid_facts()
        policy = policy or self.policy()
        return tool.evaluate(
            policy,
            facts,
            apk_sha if apk_sha is not None else self.apk_sha,
            apk_bytes if apk_bytes is not None else len(self.apk_bytes),
        )

    def assert_failure(self, report, identifier):
        self.assertFalse(report["ok"], report["failures"])
        ids = {failure["id"] for failure in report["failures"]}
        self.assertIn(identifier, ids, report["failures"])

    def test_valid_facts_pass(self):
        report = self.evaluate()
        self.assertTrue(report["ok"], report["failures"])
        self.assertEqual(report["apk"]["fileName"], "Floe-Android-0.1.0-g02-full-arm64-v8a.apk")
        self.assertFalse(report["publication"]["performed"])
        self.assertEqual(report["publication"]["latestFlag"], "--latest=false")
        self.assertEqual(report["license"]["project"], "MPL-2.0")
        self.assertEqual(
            report["license"]["packagedLicenseEntries"],
            ["META-INF/androidx/example/LICENSE.txt"],
        )
        self.assertFalse(report["license"]["completenessVerified"])

    def test_package_mismatch(self):
        facts = valid_facts()
        facts["manifest"]["package"] = "com.other.package"
        self.assert_failure(self.evaluate(facts), "manifest.package")

    def test_version_code_mismatch(self):
        facts = valid_facts()
        facts["manifest"]["versionCode"] = 7
        self.assert_failure(self.evaluate(facts), "manifest.version-code")

    def test_version_name_mismatch(self):
        facts = valid_facts()
        facts["manifest"]["versionName"] = "0.1.0-g03"
        self.assert_failure(self.evaluate(facts), "manifest.version-name")

    def test_min_sdk_mismatch(self):
        facts = valid_facts()
        facts["manifest"]["minSdk"] = 29
        self.assert_failure(self.evaluate(facts), "manifest.min-sdk")

    def test_target_sdk_mismatch(self):
        facts = valid_facts()
        facts["manifest"]["targetSdk"] = 36
        self.assert_failure(self.evaluate(facts), "manifest.target-sdk")

    def test_debuggable_manifest_is_rejected(self):
        facts = valid_facts()
        facts["manifest"]["debuggable"] = True
        self.assert_failure(self.evaluate(facts), "manifest.debuggable")

    def test_test_only_manifest_is_rejected(self):
        facts = valid_facts()
        facts["manifest"]["testOnly"] = True
        self.assert_failure(self.evaluate(facts), "manifest.test-only")

    def test_split_apk_is_rejected(self):
        facts = valid_facts()
        facts["manifest"]["split"] = "config.arm64_v8a"
        self.assert_failure(self.evaluate(facts), "manifest.split")

    def test_instrumentation_apk_is_rejected(self):
        facts = valid_facts()
        facts["manifest"]["hasInstrumentation"] = True
        self.assert_failure(self.evaluate(facts), "manifest.instrumentation")

    def test_extract_native_libs_true_is_rejected(self):
        facts = valid_facts()
        facts["manifest"]["extractNativeLibs"] = True
        self.assert_failure(self.evaluate(facts), "manifest.extract-native-libs")

    def test_zip_problem_is_propagated(self):
        facts = valid_facts()
        facts["zip"]["problems"].append(
            {"id": "zip.entry.traversal", "message": "bad entry"}
        )
        self.assert_failure(self.evaluate(facts), "zip.entry.traversal")

    def test_zip_abi_mismatch_is_rejected(self):
        facts = valid_facts()
        facts["zip"]["abis"] = ["arm64-v8a", "armeabi-v7a"]
        self.assert_failure(self.evaluate(facts), "zip.abi")

    def test_badging_abi_mismatch_is_rejected(self):
        facts = valid_facts()
        facts["badging"]["abis"] = ["armeabi-v7a"]
        self.assert_failure(self.evaluate(facts), "badging.abi")

    def test_certificate_mismatch_is_rejected(self):
        facts = valid_facts()
        facts["signing"]["certSha256"] = "cd" * 32
        self.assert_failure(self.evaluate(facts), "signing.cert-mismatch")

    def test_debug_signing_is_rejected_even_with_expected_digest(self):
        facts = valid_facts()
        facts["signing"]["debugCertificate"] = True
        facts["signing"]["certSha256"] = CERT
        facts["signing"]["problems"].append(
            {"id": "signing.debug-certificate", "message": "debug"}
        )
        self.assert_failure(self.evaluate(facts), "signing.debug-certificate")

    def test_unsigned_signing_is_rejected(self):
        facts = valid_facts()
        facts["signing"] = {
            "verified": False,
            "schemes": {},
            "modernScheme": False,
            "signerCount": None,
            "certSha256": None,
            "dn": None,
            "debugCertificate": False,
            "problems": [
                {"id": "signing.apksigner-failed", "message": "DOES NOT VERIFY"}
            ],
        }
        self.assert_failure(self.evaluate(facts), "signing.apksigner-failed")

    def test_channel_markers_are_required(self):
        facts = valid_facts()
        facts["dex"]["markers"][tool.FULL_ONLY_MARKERS[0]] = False
        self.assert_failure(self.evaluate(facts), "channel.full")

    def test_native_problem_is_propagated(self):
        facts = valid_facts()
        facts["native"]["problems"].append(
            {"id": "native.debug-sections", "message": "debug data"}
        )
        self.assert_failure(self.evaluate(facts), "native.debug-sections")

    def test_expected_hash_mismatch_is_rejected(self):
        self.assert_failure(
            self.evaluate(apk_sha="00" * 32), "provenance.hash"
        )

    def test_previous_upgrade_is_accepted_when_matching(self):
        policy = self.policy(
            previous_version_code=7,
            previous_cert_sha256=CERT,
            previous_package=PACKAGE,
            previous_release_tag="android/v0.1.0-g01",
        )
        report = self.evaluate(policy=policy)
        self.assertTrue(report["ok"], report["failures"])
        self.assertEqual(report["upgrade"]["identityContinuity"], "supplied-and-matching")
        self.assertTrue(report["upgrade"]["versionCodeIncremented"])

    def test_previous_signer_mismatch_is_rejected(self):
        policy = self.policy(
            previous_version_code=7,
            previous_cert_sha256="cd" * 32,
            previous_package=PACKAGE,
        )
        self.assert_failure(self.evaluate(policy=policy), "upgrade.certificate")

    def test_canonical_native_manifest_exact_is_reported(self):
        policy = self.policy(
            native_manifest={
                "inputDigest": "dd" * 32,
                "libraries": {
                    "libFloeAndroidCore.so": "11" * 32,
                    "libfloe_jni.so": "33" * 32,
                },
            }
        )
        report = self.evaluate(policy=policy)
        self.assertTrue(report["ok"], report["failures"])
        self.assertEqual(
            report["native"]["libraryBasis"], "canonical-exact", report["native"]
        )
        self.assertFalse(report["native"]["runtimeEquivalenceVerified"])

    def test_canonical_native_manifest_reports_derived_libraries(self):
        policy = self.policy(
            native_manifest={
                "inputDigest": "dd" * 32,
                "libraries": {
                    "libFloeAndroidCore.so": "99" * 32,
                    "libfloe_jni.so": "33" * 32,
                },
            }
        )
        report = self.evaluate(policy=policy)
        self.assertTrue(report["ok"], report["failures"])
        self.assertEqual(report["native"]["libraryBasis"], "derived-after-final-build")
        self.assertEqual(len(report["native"]["canonicalManifest"]["derived"]), 1)
        self.assertFalse(report["native"]["runtimeEquivalenceVerified"])

    def test_derived_native_manifest_requires_exact_hashes(self):
        policy = self.policy(
            native_manifest={
                "inputDigest": None,
                "libraries": {
                    "libFloeAndroidCore.so": "99" * 32,
                    "libfloe_jni.so": "33" * 32,
                },
            },
            native_manifest_role="derived",
        )
        report = self.evaluate(policy=policy)
        self.assert_failure(report, "native.manifest.derived-mismatch")

    def test_canonical_native_manifest_missing_library_is_rejected(self):
        policy = self.policy(
            native_manifest={
                "inputDigest": "dd" * 32,
                "libraries": {"libMissing.so": "11" * 32},
            }
        )
        self.assert_failure(
            self.evaluate(policy=policy), "native.manifest.missing"
        )


class PrepareTests(BaseTempTest):
    def prepare(self, policy=None, output=None, body=None, inspector=None):
        return tool.prepare_release(
            policy or self.policy(),
            Path(output or self.output),
            Path(body or self.body),
            inspector=inspector or FakeInspector(),
        )

    def test_successful_prepare_writes_exactly_two_assets(self):
        report = self.prepare()
        self.assertTrue(report["ok"], report["failures"])
        self.assertTrue(report["assetSetCommitted"])
        self.assertTrue(report["bodyWritten"])
        self.assertEqual(len(report["assets"]), 2)
        names = sorted(path.name for path in self.output.iterdir())
        self.assertEqual(names, ["Floe-Android-0.1.0-g02-full-arm64-v8a.apk", "SHA256SUMS"])
        for path in self.output.iterdir():
            self.assertTrue(path.is_file())
            self.assertFalse(path.is_symlink())
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)
        checksum = (self.output / "SHA256SUMS").read_text(encoding="ascii")
        self.assertEqual(
            checksum,
            "{}  Floe-Android-0.1.0-g02-full-arm64-v8a.apk\n".format(self.apk_sha),
        )
        self.assertTrue(
            tool.verify_checksum_text(
                checksum,
                "Floe-Android-0.1.0-g02-full-arm64-v8a.apk",
                self.apk_sha,
            )
        )
        self.assertEqual((self.output / "Floe-Android-0.1.0-g02-full-arm64-v8a.apk").read_bytes(), self.apk_bytes)
        self.assertEqual(sha256_bytes(self.apk_path.read_bytes()), self.apk_sha)

    def test_body_is_private_and_honest(self):
        report = self.prepare()
        self.assertTrue(report["ok"], report["failures"])
        body = self.body.read_text(encoding="utf-8")
        self.assertIn("# Floe for Android 0.1.0-g02", body)
        self.assertIn("manual APK installation only", body)
        self.assertIn("No Android update feed", body)
        self.assertIn(self.apk_sha, body)
        self.assertIn("SHA256SUMS", body)
        self.assertIn("Mozilla Public License 2.0", body)
        self.assertNotIn(str(self.tmp), body)
        # The tool must not claim feature/basic-usability acceptance in the body.
        self.assertNotIn("basic usability verified", body.lower())
        self.assertNotIn("G02 complete", body)

    def test_check_is_read_only(self):
        before = sorted(path.name for path in self.tmp.iterdir())
        report = tool.check_release(self.policy(), inspector=FakeInspector())
        self.assertTrue(report["ok"], report["failures"])
        after = sorted(path.name for path in self.tmp.iterdir())
        self.assertEqual(before, after)
        self.assertFalse(report["assetSetCommitted"])
        self.assertEqual(report["actions"], ["read", "hash", "verify"])

    def test_check_hash_mismatch_is_rejected(self):
        policy = self.policy(expected_sha256="00" * 32)
        report = tool.check_release(policy, inspector=FakeInspector())
        self.assertFalse(report["ok"])
        self.assertIn(
            "provenance.hash", {failure["id"] for failure in report["failures"]}
        )

    def test_nonempty_output_is_preserved(self):
        self.output.mkdir()
        sentinel = self.output / "existing.bin"
        sentinel.write_bytes(b"keep-me")
        report = self.prepare()
        self.assertFalse(report["ok"])
        self.assertIn(
            "output.nonempty", {failure["id"] for failure in report["failures"]}
        )
        self.assertEqual(sentinel.read_bytes(), b"keep-me")
        self.assertFalse(self.body.exists())

    def test_existing_empty_output_is_atomically_replaced(self):
        self.output.mkdir()
        report = self.prepare()
        self.assertTrue(report["ok"], report["failures"])
        self.assertEqual(len(list(self.output.iterdir())), 2)

    def test_output_symlink_is_rejected(self):
        real = self.tmp / "real-output"
        real.mkdir()
        link = self.tmp / "linked-output"
        link.symlink_to(real, target_is_directory=True)
        report = self.prepare(output=link)
        self.assertFalse(report["ok"])
        self.assertIn(
            "output.symlink", {failure["id"] for failure in report["failures"]}
        )
        self.assertEqual(list(real.iterdir()), [])

    def test_body_inside_output_is_rejected(self):
        report = self.prepare(body=self.output / "body.md")
        self.assertFalse(report["ok"])
        self.assertIn(
            "output.body", {failure["id"] for failure in report["failures"]}
        )
        self.assertFalse(self.output.exists())

    def test_existing_body_is_not_overwritten(self):
        self.body.write_text("existing body", encoding="utf-8")
        report = self.prepare()
        self.assertFalse(report["ok"])
        self.assertIn(
            "output.body", {failure["id"] for failure in report["failures"]}
        )
        self.assertEqual(self.body.read_text(encoding="utf-8"), "existing body")
        self.assertFalse(self.output.exists())

    def test_validation_failure_leaves_no_output_or_body(self):
        facts = valid_facts()
        facts["manifest"]["package"] = "com.other.package"
        report = self.prepare(inspector=FakeInspector(facts))
        self.assertFalse(report["ok"])
        self.assertFalse(report["assetSetCommitted"])
        self.assertFalse(report["bodyWritten"])
        self.assertFalse(self.output.exists())
        self.assertFalse(self.body.exists())
        self.assertEqual(list(self.tmp.glob(".prepare-stage-release-*")), [])

    def test_mid_copy_failure_leaves_no_partial_output(self):
        def failing_copy(source, destination, expected_sha256, **kwargs):
            Path(destination).write_bytes(b"partial")
            raise tool.StageReleaseError("copy.injected", "injected mid-copy failure")

        original = tool.copy_source_to_path
        try:
            tool.copy_source_to_path = failing_copy
            report = self.prepare()
        finally:
            tool.copy_source_to_path = original
        self.assertFalse(report["ok"])
        self.assertIn(
            "copy.injected", {failure["id"] for failure in report["failures"]}
        )
        self.assertFalse(self.output.exists())
        self.assertFalse(self.body.exists())
        self.assertEqual(list(self.tmp.glob(".prepare-stage-release-*")), [])

    def test_expected_hash_mismatch_leaves_no_output(self):
        report = self.prepare(policy=self.policy(expected_sha256="00" * 32))
        self.assertFalse(report["ok"])
        self.assertIn(
            "provenance.hash", {failure["id"] for failure in report["failures"]}
        )
        self.assertFalse(self.output.exists())
        self.assertFalse(self.body.exists())

    def test_replaced_source_is_detected(self):
        source = self.tmp / "source.apk"
        source.write_bytes(b"original-source" * 100)
        replacement = self.tmp / "replacement.apk"
        replacement.write_bytes(b"replacement-source" * 100)
        destination = self.tmp / "copy.apk"

        def replace_source(total):
            os.replace(str(replacement), str(source))

        with self.assertRaises(tool.StageReleaseError) as caught:
            tool.copy_source_to_path(
                source,
                destination,
                sha256_bytes(b"original-source" * 100),
                on_chunk=replace_source,
            )
        self.assertEqual(caught.exception.code, "source.changed")
        self.assertFalse(destination.exists())

    def test_two_runs_are_deterministic(self):
        output_a = self.tmp / "out-a"
        body_a = self.tmp / "body-a.md"
        output_b = self.tmp / "out-b"
        body_b = self.tmp / "body-b.md"
        report_a = self.prepare(output=output_a, body=body_a)
        report_b = self.prepare(output=output_b, body=body_b)
        self.assertTrue(report_a["ok"], report_a["failures"])
        self.assertTrue(report_b["ok"], report_b["failures"])
        for name in (
            "Floe-Android-0.1.0-g02-full-arm64-v8a.apk",
            "SHA256SUMS",
        ):
            self.assertEqual((output_a / name).read_bytes(), (output_b / name).read_bytes())
        self.assertEqual(body_a.read_bytes(), body_b.read_bytes())
        self.assertEqual(report_a["assets"], report_b["assets"])

    def test_prepare_requires_body_out(self):
        parser = tool.build_parser()
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                parser.parse_args(
                    [
                        "prepare",
                        "--apk",
                        str(self.apk_path),
                        "--expected-sha256",
                        self.apk_sha,
                        "--package",
                        PACKAGE,
                        "--version-code",
                        "8",
                        "--version-name",
                        VERSION,
                        "--tag",
                        TAG,
                        "--cert-sha256",
                        CERT,
                        "--source-commit",
                        SOURCE_COMMIT,
                        "--min-sdk",
                        "28",
                        "--target-sdk",
                        "37",
                        "--maturity",
                        "prerelease",
                        "--output",
                        str(self.output),
                    ]
                )


def _real_env():
    names = (
        "FLOE_ANDROID_UNSIGNED_RELEASE_APK",
        "FLOE_ANDROID_DEBUG_APK",
        "FLOE_ANDROID_AAPT2",
        "FLOE_ANDROID_APKSIGNER",
    )
    values = {name: os.environ.get(name) for name in names}
    return values if all(values.values()) else None


@unittest.skipUnless(_real_env(), "set FLOE_ANDROID_* real artifact/tool variables")
class RealArtifactIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        values = _real_env()
        cls.unsigned = Path(values["FLOE_ANDROID_UNSIGNED_RELEASE_APK"]).resolve()
        cls.debug = Path(values["FLOE_ANDROID_DEBUG_APK"]).resolve()
        cls.inspector = tool.ApkInspector(
            Path(values["FLOE_ANDROID_AAPT2"]).resolve(),
            Path(values["FLOE_ANDROID_APKSIGNER"]).resolve(),
        )
        cls.unsigned_sha = tool.stable_hash(cls.unsigned)["sha256"]
        cls.debug_sha = tool.stable_hash(cls.debug)["sha256"]

    def unsigned_policy(self):
        return policy_for(
            self.unsigned,
            self.unsigned_sha,
            package="com.floe.agent.full",
            version_code=1,
            version_name="0.1.0-g01",
            tag="android/v0.1.0-g01",
            cert_sha256=CERT,
        )

    def debug_policy(self):
        return policy_for(
            self.debug,
            self.debug_sha,
            package="com.floe.agent.full.dev",
            version_code=1,
            version_name="0.1.0-g01",
            tag="android/v0.1.0-g01",
            cert_sha256=DEBUG_CERT,
        )

    def test_unsigned_release_is_rejected_with_real_tools(self):
        report = tool.check_release(self.unsigned_policy(), inspector=self.inspector)
        self.assertFalse(report["ok"])
        ids = {failure["id"] for failure in report["failures"]}
        self.assertIn("signing.apksigner-failed", ids)
        self.assertIn("native.debug-sections", ids)
        self.assertIn("native.test-only", ids)
        self.assertEqual(report["apk"]["sha256"], self.unsigned_sha)
        self.assertFalse(report["signing"]["verified"])

    def test_debug_apk_is_rejected_with_real_tools(self):
        report = tool.check_release(self.debug_policy(), inspector=self.inspector)
        self.assertFalse(report["ok"])
        ids = {failure["id"] for failure in report["failures"]}
        self.assertIn("manifest.debuggable", ids)
        self.assertIn("signing.debug-certificate", ids)
        self.assertEqual(report["apk"]["sha256"], self.debug_sha)

    def test_real_dex_full_markers(self):
        facts = tool.dex_facts(self.unsigned)
        self.assertTrue(all(facts["markers"].values()))
        self.assertGreater(facts["classCount"], 1000)

    def test_real_native_inventory_matches_observation(self):
        facts = tool.native_facts(self.unsigned)
        self.assertEqual(len(facts["libraries"]), 31)
        self.assertEqual(
            set(facts["testOnlyLibraries"]),
            {
                "libXCTest.so",
                "libTesting.so",
                "lib_TestingInterop.so",
                "lib_Testing_Foundation.so",
            },
        )
        self.assertGreater(facts["debugSectionBytes"], 80 * 1024 * 1024)
        self.assertTrue(all(library["stored"] for library in facts["libraries"]))
        self.assertTrue(all(library["zipAligned"] for library in facts["libraries"]))
        alignment_problems = [
            problem
            for problem in facts["problems"]
            if problem["id"] in ("native.zip-alignment", "native.elf-alignment", "native.needed", "native.build-id")
        ]
        self.assertEqual(alignment_problems, [], alignment_problems)

    def test_real_elf_parser_on_packaged_library(self):
        with zipfile.ZipFile(str(self.unsigned), "r") as archive:
            data = archive.read("lib/arm64-v8a/libBlocksRuntime.so")
        facts = tool.elf_facts(data)
        self.assertEqual(facts["machine"], tool.ELF_EM_AARCH64)
        self.assertEqual(facts["minLoadAlignment"], 16384)
        self.assertTrue(facts["buildId"])
        self.assertEqual(facts["debugSectionBytes"], 76)


if __name__ == "__main__":
    unittest.main(verbosity=2)
