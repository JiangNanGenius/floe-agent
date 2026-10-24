#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Focused regressions for G04 vendored-input binding in native-manifest.py.

Boundary under test: the packaging provenance collectors must bind the
reviewed shared/Vendor tree (Swift sources, C sources, headers, include
parts (.inc), hand-written assembly (.S/.s) and module.modulemap files) into
the existing schemaVersion 1 sharedSources/cInputs/sourceLinks maps and into
inputDigest — while keeping every previous guarantee:

* the shared/Sources scan, its required-anchor checks and the security
  corpus byte-equality gate are unchanged;
* a minimal fixture without any Vendor directory still generates (pre-G04
  compatibility);
* broken/unreadable symlinks and links resolving outside the repository
  fail closed;
* --check stays read-only and never rewrites the recorded manifest.

Stdlib only, tiny synthetic bytes in temporary directories. No build, Gradle,
network, Git or repository writes; nothing here touches the canonical shared
tree. Run directly (bytecode caching off, scratch under the default tmpdir)::

    PYTHONDONTWRITEBYTECODE=1 python3 \
        FloeAndroid/scripts/tests/test_native_manifest_vendor_inputs.py -v
"""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "native-manifest.py"


def _load_tool():
    spec = importlib.util.spec_from_file_location(
        "floe_native_manifest_under_test", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load native-manifest.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


tool = _load_tool()

VENDOR = "FloeAndroid/shared/Vendor"

# Relevant vendored inputs: (repo-relative path, text content, bucket).
VENDOR_SWIFT = (
    "%s/Git/swiftgitx/Sources/SwiftGitX/Repository.swift" % VENDOR,
    "%s/Network/SMBClient-0.2.1/Sources/SMBClient/Client.swift" % VENDOR,
    "%s/Archive/SWCompression-4.9.1/Sources/SwiftFoundation/BitByteData.swift"
    % VENDOR,
)
VENDOR_C = (
    "%s/Archive/libarchive-3.8.9/libarchive/archive_read.c" % VENDOR,
    "%s/Archive/libarchive-3.8.9/libarchive/archive.h" % VENDOR,
    "%s/Archive/libarchive-3.8.9/libarchive/module.modulemap" % VENDOR,
    "%s/Archive/xz-5.8.1/src/liblzma/check/crc64_x86.S" % VENDOR,
    "%s/Git/floe-shim/include/floe_android_mbedtls_config.inc" % VENDOR,
    "%s/Git/mbedtls/include/mbedtls/platform_time.h" % VENDOR,
)

# Non-source bytes that must NOT be bound by the type filter.
VENDOR_DECOYS = (
    "%s/Archive/bzip2-1.0.8/LICENSE" % VENDOR,
    "%s/Git/libgit2/deps/pcre/config.h.in" % VENDOR,
    "%s/Archive/xz-5.8.1/src/liblzma/liblzma_linux.map" % VENDOR,
    "%s/Git/README.md" % VENDOR,
    "%s/Git/libgit2/CMakeLists.txt" % VENDOR,
)

REVISION = "ab" * 20  # 40 hex chars


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _write(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, str):
        data = data.encode("utf-8")
    path.write_bytes(data)


class Fixture:
    """Synthetic minimal canonical repository + packaged library output.

    Mirrors every REQUIRED_INPUTS/BUILD_INPUTS/RESOLVED_INPUTS/SECURITY_CORPUS
    anchor so generation runs to completion, plus an optional Vendor tree.
    The jniLibs directory lives beside (not inside) the repo, exactly like a
    build output directory, so manifest writes land only in the scratch base.
    """

    def __init__(self, with_vendor: bool = True, with_extra_sources: bool = False):
        self.base = Path(tempfile.mkdtemp(prefix="floe-nm-vendor-")).resolve()
        self.root = self.base / "repo"
        self.jni_libs = self.base / "jniLibs" / "arm64-v8a"
        self.manifest_path = self.base / "jniLibs" / "native-manifest.json"

        repo = self.root / "FloeAndroid"
        _write(repo / "shared/Package.swift",
               "// swift-tools-version:6.0\nlet targets: [String] = []\n")
        _write(repo / "shared/Package.resolved", json.dumps({
            "pins": [{"identity": "swift-crypto",
                      "location": "https://example.invalid/swift-crypto.git",
                      "state": {"version": "3.9.0", "revision": REVISION}}]}))
        _write(repo / "shared/Sources/GRDBSQLite/sqlite3.c", "/* amalgamation */\n")
        _write(repo / "shared/Sources/GRDBSQLite/sqlite3.h", "/* header */\n")
        _write(repo / "shared/Sources/GRDBSQLite/shim.h", "/* shim */\n")
        _write(repo / "shared/Sources/GRDBSQLite/module.modulemap",
               "module GRDBSQLite { header \"sqlite3.h\" }\n")
        _write(repo / "shared/Sources/CZLib/module.modulemap",
               "module CZLib { header \"shim.h\" }\n")
        _write(repo / "shared/Sources/FloeCore/Core.swift",
               "public func floeCore() {}\n")
        corpus = b'[{"pattern": "catastrophic"}]\n'
        _write(repo / "shared/Sources/FloeSecurity/Resources/"
               "catastrophic-patterns.json", corpus)
        _write(repo / "core/swiftbridge/src/main/assets/security/"
               "catastrophic-patterns.json", corpus)
        _write(repo / "core/swiftbridge/build.gradle.kts", "// gradle\n")
        _write(repo / "core/linuxauthoritybridge/build.gradle.kts", "// gradle\n")
        _write(repo / "core/swiftbridge/gradle.lockfile",
               "# workspace lock\nandroidx.test=1.0.0.0@1.0.0@fake@fake\n")
        _write(repo / "core/swiftbridge/src/main/cpp/CMakeLists.txt",
               "add_library(floe_jni SHARED floe_jni.cpp)\n")
        _write(repo / "core/swiftbridge/src/main/cpp/floe_jni.cpp",
               "// JNI onLoad\n")
        _write(repo / "core/linuxauthoritybridge/src/main/cpp/CMakeLists.txt",
               "add_library(floe_authority SHARED)\n")
        _write(repo / "scripts/build-swift.sh", "#!/bin/sh\n")
        _write(repo / "scripts/env.sh", "#!/bin/sh\n")
        _write(repo / "scripts/configure-swift-sdk.py", "# sdk\n")
        _write(repo / "toolchains.lock.json",
               json.dumps({"swift": {"version": "6.2-fake"},
                           "ndk": {"version": "30.1-fake"}}))
        _write(self.jni_libs / "libFloeAndroidCore.so", b"\x7fELF fake library")

        if with_extra_sources:
            # Regression for the pre-G04 suffix gap: include parts and
            # assembly under shared/Sources must also be bound now.
            _write(repo / "shared/Sources/FloeCore/kernels.S", "/* asm */\n")
            _write(repo / "shared/Sources/GRDBSQLite/sqlite3_stubs.inc",
                   "/* include part */\n")

        if with_vendor:
            for rel in VENDOR_SWIFT:
                _write(self.root / rel, "// vendored swift\n")
            for rel in VENDOR_C:
                _write(self.root / rel, "/* vendored c/native */\n")
            for rel in VENDOR_DECOYS:
                _write(self.root / rel, "not a compile input\n")
            # Vendored overlay-style link: recorded with its target bytes,
            # exactly like the iOS overlay links under shared/Sources.
            self.vendored_link = self.root / (
                "%s/Network/SMBClient-0.2.1/Sources/SMBClient/"
                "AndroidOverlay.swift" % VENDOR)
            self.vendored_link_target = (
                "FloeAndroid/shared/Sources/FloeCore/Core.swift")
            self.vendored_link.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(str(self.root / self.vendored_link_target),
                       str(self.vendored_link))

    # -- CLI helpers -------------------------------------------------------
    def generate(self):
        return self.run([str(self.jni_libs), "--root", str(self.root)])

    def check(self):
        return self.run([str(self.jni_libs), "--root", str(self.root),
                         "--check"])

    def run(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = tool.main(argv)
        return rc, out.getvalue(), err.getvalue()

    def tamper(self, rel_or_path, text):
        path = (Path(rel_or_path) if isinstance(rel_or_path, Path)
                else self.root / rel_or_path)
        path.write_bytes(text.encode("utf-8"))

    def remove(self, rel_or_path):
        path = (Path(rel_or_path) if isinstance(rel_or_path, Path)
                else self.root / rel_or_path)
        path.unlink()

    def manifest(self):
        return json.loads(self.manifest_path.read_text(encoding="utf-8"))

    def manifest_bytes(self):
        return self.manifest_path.read_bytes()

    def cleanup(self):
        shutil.rmtree(self.base, ignore_errors=True)


class VendorProvenanceGeneration(unittest.TestCase):
    """Collectors bind Vendor into the existing maps and the digest."""

    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.cleanup)

    def test_generation_binds_vendored_swift_c_and_links(self):
        rc, out, err = self.fixture.generate()
        self.assertEqual(rc, 0, msg="stdout=%s stderr=%s" % (out, err))
        manifest = self.fixture.manifest()
        for rel in VENDOR_SWIFT:
            self.assertIn(rel, manifest["sharedSources"],
                          "vendored Swift not recorded")
            self.assertEqual(manifest["sharedSources"][rel],
                             _sha(b"// vendored swift\n"))
        for rel in VENDOR_C:
            self.assertIn(rel, manifest["cInputs"],
                          "vendored C/header/modulemap/.S/.inc not recorded")
            self.assertEqual(manifest["cInputs"][rel],
                             _sha(b"/* vendored c/native */\n"))
        link = "%s/Network/SMBClient-0.2.1/Sources/SMBClient/" \
               "AndroidOverlay.swift" % VENDOR
        self.assertIn(link, manifest["sourceLinks"])
        self.assertEqual(manifest["sourceLinks"][link],
                         self.fixture.vendored_link_target)
        self.assertEqual(manifest["sharedSources"][link],
                         manifest["sharedSources"][
                             self.fixture.vendored_link_target],
                         "link entry and target bytes must match")

    def test_non_source_vendored_files_are_not_bound(self):
        rc, out, err = self.fixture.generate()
        self.assertEqual(rc, 0, msg="stdout=%s stderr=%s" % (out, err))
        manifest = self.fixture.manifest()
        recorded = set(manifest["sharedSources"]) | set(manifest["cInputs"]) \
            | set(manifest["nativeInputs"]) | set(manifest["resources"])
        for decoy in VENDOR_DECOYS:
            self.assertNotIn(decoy, recorded,
                             "non-source vendored file leaked into provenance")

    def test_input_digest_covers_the_vendored_entries(self):
        rc, out, err = self.fixture.generate()
        self.assertEqual(rc, 0, msg="stdout=%s stderr=%s" % (out, err))
        manifest = self.fixture.manifest()
        recomputed = tool.input_digest(
            manifest["sharedSources"], manifest["nativeInputs"],
            manifest["sourceLinks"], manifest["resources"],
            manifest["cInputs"], manifest["resolvedInputs"],
            manifest["resolvedPins"])
        self.assertEqual(recomputed, manifest["inputDigest"])
        # Drop every Vendor path and the digest must move: the recorded
        # digest demonstrably includes them.
        stripped_sources = {k: v for k, v in manifest["sharedSources"].items()
                            if not k.startswith(VENDOR)}
        stripped_c = {k: v for k, v in manifest["cInputs"].items()
                      if not k.startswith(VENDOR)}
        stripped_links = {k: v for k, v in manifest["sourceLinks"].items()
                          if not k.startswith(VENDOR)}
        moved = tool.input_digest(
            stripped_sources, manifest["nativeInputs"], stripped_links,
            manifest["resources"], stripped_c,
            manifest["resolvedInputs"], manifest["resolvedPins"])
        self.assertNotEqual(moved, manifest["inputDigest"],
                            "inputDigest ignores vendored entries")

    def test_clean_tree_check_passes(self):
        rc, out, err = self.fixture.generate()
        self.assertEqual(rc, 0, msg="stdout=%s stderr=%s" % (out, err))
        rc, out, err = self.fixture.check()
        self.assertEqual(rc, 0, msg="stdout=%s stderr=%s" % (out, err))
        self.assertIn("native-manifest: OK", out)


class VendorTamperDetection(unittest.TestCase):
    """Mutation or deletion of a vendored input must differ from recorded
    provenance, and --check must report it without rewriting anything."""

    def _tamper_and_check(self, path_or_rel):
        fixture = Fixture()
        self.addCleanup(fixture.cleanup)
        rc, out, err = fixture.generate()
        self.assertEqual(rc, 0, msg="stdout=%s stderr=%s" % (out, err))
        before = fixture.manifest_bytes()
        fixture.tamper(path_or_rel, "TAMPERED BY AN UNAPPROVED EDIT\n")
        rc, out, err = fixture.check()
        self.assertEqual(rc, 1, "tampered vendored input must fail --check")
        self.assertIn("drift detected", out)
        self.assertEqual(fixture.manifest_bytes(), before,
                         "--check rewrote the recorded manifest")
        return fixture, out

    def test_vendored_swift_tamper_is_detected(self):
        for rel in VENDOR_SWIFT:
            with self.subTest(path=rel):
                _, out = self._tamper_and_check(rel)
                self.assertIn("DRIFT sharedSources.%s:" % rel, out)

    def test_vendored_c_header_modulemap_assembly_inc_tamper_is_detected(self):
        for rel in VENDOR_C:
            with self.subTest(path=rel):
                _, out = self._tamper_and_check(rel)
                self.assertIn("DRIFT cInputs.%s:" % rel, out)

    def test_vendored_link_target_tamper_is_detected_through_the_link(self):
        fixture = Fixture()
        self.addCleanup(fixture.cleanup)
        rc, out, err = fixture.generate()
        self.assertEqual(rc, 0, msg="stdout=%s stderr=%s" % (out, err))
        before = fixture.manifest_bytes()
        fixture.tamper(fixture.vendored_link_target,
                       "public func floeCore() { /* hijacked */ }\n")
        rc, out, err = fixture.check()
        self.assertEqual(rc, 1)
        self.assertIn("DRIFT sharedSources.%s:" % fixture.vendored_link_target,
                      out)
        link = "%s/Network/SMBClient-0.2.1/Sources/SMBClient/" \
               "AndroidOverlay.swift" % VENDOR
        self.assertIn("DRIFT sharedSources.%s:" % link, out,
                      "vendored link bytes must be bound via the target")
        self.assertIn("DRIFT inputDigest:", out)
        self.assertEqual(fixture.manifest_bytes(), before,
                         "--check rewrote the recorded manifest")

    def test_vendored_deletion_is_detected(self):
        for rel in (VENDOR_C[0], VENDOR_SWIFT[0]):
            with self.subTest(path=rel):
                fixture = Fixture()
                self.addCleanup(fixture.cleanup)
                rc, out, err = fixture.generate()
                self.assertEqual(rc, 0, msg="stdout=%s stderr=%s" % (out, err))
                before = fixture.manifest_bytes()
                fixture.remove(rel)
                rc, out, err = fixture.check()
                self.assertEqual(rc, 1, "deleted vendored input must fail")
                bucket = "cInputs" if rel in VENDOR_C else "sharedSources"
                self.assertIn("%s.%s: recorded but not computed"
                              % (bucket, rel), out)
                self.assertIn("DRIFT inputDigest:", out)
                self.assertEqual(fixture.manifest_bytes(), before,
                                 "--check rewrote the recorded manifest")

    def test_generated_manifest_survives_unrelated_vendored_addition(self):
        # A new NON-source vendored file (license text) must not change the
        # recorded digest semantics of the existing inputs; a new SOURCE file
        # must move the computed set. Both directions are checked against the
        # same recorded manifest via --check (still read-only).
        fixture = Fixture()
        self.addCleanup(fixture.cleanup)
        rc, out, err = fixture.generate()
        self.assertEqual(rc, 0, msg="stdout=%s stderr=%s" % (out, err))
        before = fixture.manifest_bytes()
        fixture.tamper("%s/Git/README.md" % VENDOR, "doc drift only\n")
        rc, out, err = fixture.check()
        self.assertEqual(rc, 0, "non-source vendor doc change is not a "
                                "provenance input: %s" % out)
        _write(fixture.root / ("%s/Git/libgit2/src/util/floe_new.c" % VENDOR),
               "// new source\n")
        rc, out, err = fixture.check()
        self.assertEqual(rc, 1, "a new vendored source must differ from "
                                "recorded provenance")
        self.assertIn("computed but not recorded", out)
        self.assertEqual(fixture.manifest_bytes(), before,
                         "--check rewrote the recorded manifest")


class VendorFailClosedGuards(unittest.TestCase):
    """Unreadable/broken links and out-of-repository sources are refused;
    minimal pre-G04 fixtures without a Vendor directory still work."""

    def test_broken_vendored_symlink_fails_closed(self):
        fixture = Fixture()
        self.addCleanup(fixture.cleanup)
        link = fixture.root / ("%s/Git/mbedtls/library/broken.h" % VENDOR)
        link.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(str(link.parent / "does-not-exist.h"), str(link))
        rc, out, err = fixture.generate()
        self.assertEqual(rc, 1, "broken vendored symlink must fail")
        self.assertIn("broken symlink", err)
        self.assertFalse(fixture.manifest_path.exists(),
                         "failed generation must not write a manifest")

    def test_out_of_repository_vendored_symlink_is_refused(self):
        fixture = Fixture()
        self.addCleanup(fixture.cleanup)
        outside = fixture.base / "outside-repo-header.h"
        _write(outside, "/* smuggled */\n")
        link = fixture.root / ("%s/Git/floe-shim/include/leaked.h" % VENDOR)
        link.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(str(outside), str(link))
        rc, out, err = fixture.generate()
        self.assertEqual(rc, 1, "out-of-repo link must be refused")
        self.assertIn("outside the repository", err)
        self.assertFalse(fixture.manifest_path.exists())

    def test_out_of_repository_vendored_swift_symlink_is_refused(self):
        fixture = Fixture()
        self.addCleanup(fixture.cleanup)
        outside = fixture.base / "Outside.swift"
        _write(outside, "public func smuggled() {}\n")
        link = fixture.root / ("%s/Archive/swOutside.swift" % VENDOR)
        link.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(str(outside), str(link))
        rc, out, err = fixture.generate()
        self.assertEqual(rc, 1)
        self.assertIn("outside the repository", err)
        self.assertFalse(fixture.manifest_path.exists())

    def test_minimal_fixture_without_vendor_still_generates(self):
        fixture = Fixture(with_vendor=False)
        self.addCleanup(fixture.cleanup)
        rc, out, err = fixture.generate()
        self.assertEqual(rc, 0, msg="stdout=%s stderr=%s" % (out, err))
        manifest = fixture.manifest()
        self.assertTrue(out.startswith("Native manifest:"))
        for bucket in ("sharedSources", "cInputs", "sourceLinks"):
            self.assertFalse(any(p.startswith(VENDOR)
                                 for p in manifest[bucket]),
                             "%s gained phantom vendor entries" % bucket)
        rc, out, err = fixture.check()
        self.assertEqual(rc, 0, msg="stdout=%s stderr=%s" % (out, err))

    def test_sources_include_and_assembly_suffixes_are_now_bound(self):
        fixture = Fixture(with_extra_sources=True)
        self.addCleanup(fixture.cleanup)
        rc, out, err = fixture.generate()
        self.assertEqual(rc, 0, msg="stdout=%s stderr=%s" % (out, err))
        manifest = fixture.manifest()
        for rel in ("FloeAndroid/shared/Sources/FloeCore/kernels.S",
                    "FloeAndroid/shared/Sources/GRDBSQLite/sqlite3_stubs.inc"):
            self.assertIn(rel, manifest["cInputs"],
                          "Sources-side .S/.inc input silently omitted")
        rc, out, err = fixture.check()
        self.assertEqual(rc, 0, msg="stdout=%s stderr=%s" % (out, err))
        before = fixture.manifest_bytes()
        fixture.tamper("FloeAndroid/shared/Sources/FloeCore/kernels.S",
                       "/* tampered asm */\n")
        rc, out, err = fixture.check()
        self.assertEqual(rc, 1)
        self.assertIn("DRIFT cInputs.FloeAndroid/shared/Sources/"
                      "FloeCore/kernels.S:", out)
        self.assertEqual(fixture.manifest_bytes(), before,
                         "--check rewrote the recorded manifest")


class CliContract(unittest.TestCase):
    """The real CLI keeps its exit-code and read-only contract (subprocess)."""

    def test_cli_check_reports_vendor_tamper_and_writes_nothing(self):
        fixture = Fixture()
        self.addCleanup(fixture.cleanup)
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        base = subprocess.run(
            [sys.executable, str(SCRIPT), str(fixture.jni_libs),
             "--root", str(fixture.root)],
            capture_output=True, text=True, env=env)
        self.assertEqual(base.returncode, 0, msg=base.stderr)
        before = fixture.manifest_bytes()
        fixture.tamper(VENDOR_C[0], "TAMPERED\n")
        check = subprocess.run(
            [sys.executable, str(SCRIPT), str(fixture.jni_libs),
             "--root", str(fixture.root), "--check"],
            capture_output=True, text=True, env=env)
        self.assertEqual(check.returncode, 1, msg=check.stdout)
        self.assertIn("DRIFT cInputs.%s:" % VENDOR_C[0], check.stdout)
        self.assertEqual(fixture.manifest_bytes(), before,
                         "--check rewrote the recorded manifest via CLI")
        stray = [p for p in fixture.base.rglob("native-manifest.json")
                 if p != fixture.manifest_path]
        self.assertEqual(stray, [], "--check wrote an extra manifest")


if __name__ == "__main__":
    unittest.main(verbosity=2)
