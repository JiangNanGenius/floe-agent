#!/usr/bin/env python3
"""Production-preparation contract for the kit callback lifecycle overlay.

This is a Python test of the Office native host pipeline (not a Swift/Xcode
test; no Xcode target includes this directory). It proves that:

  * the tracked kitCallbackLifecycleOverlay patch and file hashes are exactly
    what prepare_office_native_sources.py applies and records;
  * a preparation receipt can only exist when the patch was actually applied,
    and an edited prepared tree fails closed;
  * the qualification shadow compiles the prepared (patched) kit sources;
  * a future host pin claiming kitCallbackOverlaySHA256 is rejected for a host
    manifest without matching kitCallbackLifecycle provenance, while the
    existing pin (no claim) stays usable until it is replaced;
  * the host build report records the applied patch hash and patched file
    hashes for that pin.

The real patch applied to the real pinned kit source is verified by
scripts/test_office_kit_lifecycle.py. Passing here is pipeline evidence, not an
engine build, cloud run or device result.

Run: python3 FloeAgent/Tests/FloeOfficeTests/test_office_kit_callback_overlay.py
"""
import difflib
import json
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = REPO_ROOT / "FloeAgent/scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from bootstrap_office_host import checked_lock, verify_installed  # noqa: E402
from build_office_native_host import EXCLUDED_SOURCES, build_host  # noqa: E402
from package_office_engine import digest  # noqa: E402
from prepare_office_native_sources import (DEFAULT_LOCK, expected_receipt,  # noqa: E402
                                           prepare, prepared_files)
from qualify_office_mobile import shadow_sources  # noqa: E402

KIT_FILES = {"kit/Kit.cpp": "// synthetic original kit/Kit.cpp\n",
             "kit/Kit.hpp": "// synthetic original kit/Kit.hpp\n"}
KIT_PATCHED_FILES = {"kit/Kit.cpp": "// synthetic patched kit/Kit.cpp\n",
                     "kit/Kit.hpp": "// synthetic patched kit/Kit.hpp\n"}


def unified_patch(name, original, patched):
    diff = difflib.unified_diff(original.splitlines(keepends=True),
                                patched.splitlines(keepends=True),
                                fromfile=f"a/{name}", tofile=f"b/{name}")
    return f"diff --git a/{name} b/{name}\n" + "".join(diff)


def write_synthetic_bundle(root, *, kit=True):
    """A minimal format-2 bundle plus a lock whose patches live beside it."""
    source = root / "source"
    source.mkdir(parents=True)
    (source / "ios").mkdir()
    (source / "ios/touch.txt").write_text("original touch\n")
    for name, text in KIT_FILES.items():
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    linker = source / "synthetic/engine.a"
    linker.parent.mkdir()
    linker.write_bytes(b"synthetic archive")
    entries = []
    for path in sorted(source.rglob("*")):
        if path.is_file():
            entries.append({"path": str(path.relative_to(root)), "size": path.stat().st_size,
                            "sha256": digest(path)})
    (root / "bundle-manifest.json").write_text(json.dumps({
        "formatVersion": 2, "sourceCommit": "synthetic-commit",
        "files": entries, "linkerInputs": ["source/synthetic/engine.a"],
        "linkerArchives": []}))

    lock_dir = root / "lock"
    (lock_dir / "patches").mkdir(parents=True)
    embedding_patch = lock_dir / "patches/embedding.patch"
    embedding_patch.write_text(unified_patch("ios/touch.txt", "original touch\n",
                                             "embedding touch\n"))
    lock = {
        "commit": "synthetic-commit",
        "embeddingOverlay": {
            "patch": "patches/embedding.patch",
            "sha256": digest(embedding_patch),
            "requiredFrameworks": [],
            "files": {"ios/touch.txt": {
                "originalSHA256": digest(source / "ios/touch.txt"),
                "preparedSHA256": digest_of_text("embedding touch\n")}}}}
    if kit:
        kit_patch = lock_dir / "patches/kit.patch"
        kit_patch.write_text("".join(
            unified_patch(name, KIT_FILES[name], KIT_PATCHED_FILES[name])
            for name in sorted(KIT_FILES)))
        lock["kitCallbackLifecycleOverlay"] = {
            "patch": "patches/kit.patch",
            "sha256": digest(kit_patch),
            "files": {name: {"originalSHA256": digest_of_text(KIT_FILES[name]),
                             "preparedSHA256": digest_of_text(KIT_PATCHED_FILES[name])}
                      for name in sorted(KIT_FILES)}}
    lock_path = lock_dir / "engine.lock.json"
    lock_path.write_text(json.dumps(lock))
    return lock_path


def digest_of_text(text):
    import hashlib
    return hashlib.sha256(text.encode()).hexdigest()


class KitOverlayLockTests(unittest.TestCase):
    def test_lock_records_the_patch_and_exact_file_hashes(self):
        lock = json.loads(DEFAULT_LOCK.read_text())
        section = lock["kitCallbackLifecycleOverlay"]
        self.assertEqual(digest(DEFAULT_LOCK.parent / section["patch"]), section["sha256"])
        self.assertEqual(set(section["files"]), {"kit/Kit.cpp", "kit/Kit.hpp"})
        for name, spec in section["files"].items():
            with self.subTest(file=name):
                self.assertRegex(spec["originalSHA256"], r"^[0-9a-f]{64}$")
                self.assertRegex(spec["preparedSHA256"], r"^[0-9a-f]{64}$")
                self.assertNotEqual(spec["originalSHA256"], spec["preparedSHA256"])
        for key in ("schemeTaskLifecycleOverlay", "forwardingLifecycleOverlay"):
            self.assertIn(key, lock)
        self.assertEqual(lock["commit"], "27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc")

    def test_existing_pin_has_no_kit_claim_and_stays_accepted(self):
        # The published host predates the overlay: it stays usable until it is
        # replaced, so bootstrap must not require the new claim.
        lock = json.loads(DEFAULT_LOCK.read_text())
        pin = lock["qualifiedHostArtifact"]
        self.assertIsNone(pin.get("kitCallbackOverlaySHA256"))
        self.assertIn("kitCallbackLifecycleOverlay", lock)


class KitOverlayPrepareTests(unittest.TestCase):
    def test_prepare_applies_kit_patch_and_records_its_hashes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            lock_path = write_synthetic_bundle(root)
            receipt = prepare(root, lock_path)
            section = json.loads(lock_path.read_text())["kitCallbackLifecycleOverlay"]
            self.assertEqual(receipt["kitCallbackLifecycle"]["patchSHA256"], section["sha256"])
            self.assertEqual(receipt["kitCallbackLifecycle"]["files"],
                             {name: spec["preparedSHA256"]
                              for name, spec in section["files"].items()})
            for name, text in KIT_PATCHED_FILES.items():
                self.assertEqual((root / "prepared/native" / name).read_text(), text)
            recorded = json.loads((root / "prepared/native/overlay.json").read_text())
            self.assertEqual(recorded, receipt)
            # The pristine inputs are untouched.
            for name, text in KIT_FILES.items():
                self.assertEqual((root / "source" / name).read_text(), text)

    def test_second_prepare_is_idempotent_and_edit_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            lock_path = write_synthetic_bundle(root)
            first = prepare(root, lock_path)
            self.assertEqual(prepare(root, lock_path), first)
            (root / "prepared/native/kit/Kit.cpp").write_text("edited after preparation")
            with self.assertRaisesRegex(ValueError, "Prepared native source was edited"):
                prepare(root, lock_path)

    def test_absent_section_keeps_the_previous_preparation_contract(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            lock_path = write_synthetic_bundle(root, kit=False)
            lock = json.loads(lock_path.read_text())
            receipt = prepare(root, lock_path)
            self.assertNotIn("kitCallbackLifecycle", receipt)
            self.assertEqual(receipt, expected_receipt(lock))
            self.assertFalse((root / "prepared/native/kit").exists())
            self.assertEqual(set(prepared_files(lock)), {"ios/touch.txt"})

    def test_qualification_shadow_compiles_the_prepared_kit_source(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "source/ios").mkdir(parents=True)
            (root / "source/kit").mkdir()
            (root / "source/kit/Kit.cpp").write_text(KIT_FILES["kit/Kit.cpp"])
            (root / "source/kit/Kit.hpp").write_text(KIT_FILES["kit/Kit.hpp"])
            prepared = root / "prepared/native/kit"
            prepared.mkdir(parents=True)
            for name, text in KIT_PATCHED_FILES.items():
                (prepared / Path(name).name).write_text(text)
            kit_overlay = {"files": {
                name: {"preparedSHA256": digest_of_text(text)}
                for name, text in KIT_PATCHED_FILES.items()}}
            shadow_sources(root, root / "shadow", {"files": {}}, [kit_overlay])
            for name, text in KIT_PATCHED_FILES.items():
                self.assertEqual((root / "shadow" / name).read_text(), text)
            for name, text in KIT_FILES.items():
                self.assertEqual((root / "source" / name).read_text(), text)
            # A drifted prepared tree can never reach the compiler shadow.
            (prepared / "Kit.cpp").write_text("tampered")
            with self.assertRaisesRegex(ValueError, "does not compile"):
                shadow_sources(root, root / "bad-shadow", {"files": {}}, [kit_overlay])


class KitOverlayBootstrapTests(unittest.TestCase):
    """A future pin claiming the overlay needs matching host provenance."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.host = self.root / "OfficeNativeHost"
        native = self.root / "FloeOfficeNative"
        native.mkdir()
        for name in ["FloeOfficeNative.h", "FloeOfficeNative.mm",
                     "FloeOfficeAttachment.cpp", "FloeOfficeAttachment.hxx"]:
            (native / name).write_text("source-" + name)
        files = {"FloeOfficeNative.framework/FloeOfficeNative": "native binary fixture",
                 "FloeOfficeNative.framework/Headers/FloeOfficeNative.h": "public header",
                 "FloeOfficeNative.framework/Modules/module.modulemap": "module fixture",
                 "FloeOfficeNative.framework/Info.plist": "plist fixture",
                 "OfficeRuntimeResources/cool.html": "editor fixture"}
        for name, data in files.items():
            path = self.host / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(data)
        (self.host / "OfficeRuntimeResources/config").mkdir()
        sources = {path.name: digest(path) for path in native.iterdir()}
        report = {"sourceCommit": "pinned-source", "overlaySHA256": "pinned-overlay",
                  "hostSourceSHA256": sources, "hostCompilePassed": True,
                  "hostLinkPassed": True, "swiftModuleImportPassed": True,
                  "runtimeResourceSHA256": {
                      "cool.html": digest(self.host / "OfficeRuntimeResources/cool.html")},
                  "runtimeResourceDirectories": ["config"]}
        (self.host / "native-host.json").write_text(json.dumps(report))
        framework = self.host / "FloeOfficeNative.framework"
        self.pin = {"runID": "123", "artifactName": "fixture",
                    "archiveSHA256": "fixture-archive",
                    "overlaySHA256": "pinned-overlay", "hostSourceSHA256": sources,
                    "executableSHA256": digest(framework / "FloeOfficeNative"),
                    "manifestSHA256": digest(self.host / "native-host.json"),
                    "frameworkAuxiliarySHA256": {
                        str(path.relative_to(framework)): digest(path)
                        for path in framework.rglob("*")
                        if path.is_file() and path.name != "FloeOfficeNative"}}
        self.lock = self.root / "engine.lock.json"

    def write_lock(self, *, kit=True, claim=None, manifest=None):
        lock = {"commit": "pinned-source", "embeddingOverlay": {"sha256": "pinned-overlay"},
                "qualifiedHostArtifact": dict(self.pin)}
        if kit:
            lock["kitCallbackLifecycleOverlay"] = {
                "sha256": "kit-overlay",
                "files": {"kit/Kit.cpp": {"preparedSHA256": "prepared-kit"}}}
        if claim is not None:
            lock["qualifiedHostArtifact"]["kitCallbackOverlaySHA256"] = claim
        if manifest is not None:
            lock["qualifiedHostArtifact"]["manifestSHA256"] = manifest
        self.lock.write_text(json.dumps(lock))
        return lock

    def test_claim_requires_a_matching_lock_section(self):
        self.write_lock(kit=False, claim="kit-overlay")
        with self.assertRaisesRegex(ValueError, "kit callback overlay claim"):
            checked_lock(self.lock)
        self.write_lock(claim="stale-claim")  # section sha256 is "kit-overlay"
        with self.assertRaisesRegex(ValueError, "kit callback overlay claim"):
            checked_lock(self.lock)

    def test_existing_host_without_a_claim_stays_accepted(self):
        self.write_lock(claim=None)
        lock, pin = checked_lock(self.lock)
        verify_installed(self.host, lock, pin)

    def test_claim_requires_manifest_provenance(self):
        self.write_lock(claim="kit-overlay")
        lock, pin = checked_lock(self.lock)
        with self.assertRaisesRegex(ValueError, "kit callback overlay provenance"):
            verify_installed(self.host, lock, pin)

    def test_claim_accepts_matching_provenance(self):
        report_path = self.host / "native-host.json"
        report = json.loads(report_path.read_text())
        report["kitCallbackLifecycle"] = {
            "patchSHA256": "kit-overlay", "sourceCommit": "pinned-source",
            "files": {"kit/Kit.cpp": "prepared-kit"}}
        report_path.write_text(json.dumps(report))
        self.write_lock(claim="kit-overlay", manifest=digest(report_path))
        lock, pin = checked_lock(self.lock)
        verify_installed(self.host, lock, pin)

    def test_stale_host_provenance_claim_is_rejected(self):
        report_path = self.host / "native-host.json"
        report = json.loads(report_path.read_text())
        report["kitCallbackLifecycle"] = {
            "patchSHA256": "kit-overlay", "sourceCommit": "pinned-source",
            "files": {"kit/Kit.cpp": "different"}}
        report_path.write_text(json.dumps(report))
        self.write_lock(claim="kit-overlay", manifest=digest(report_path))
        lock, pin = checked_lock(self.lock)
        with self.assertRaisesRegex(ValueError, "kit callback overlay provenance"):
            verify_installed(self.host, lock, pin)


class KitOverlayHostReportTests(unittest.TestCase):
    def minimal_project(self):
        objects = {
            "target": {"isa": "PBXNativeTarget", "name": "Mobile", "productReference": "product",
                       "buildPhases": ["sources", "resources"],
                       "buildConfigurationList": "configs"},
            "product": {"isa": "PBXFileReference", "explicitFileType": "wrapper.application"},
            "configs": {"buildConfigurations": ["release"]},
            "release": {"buildSettings": {"OTHER_LDFLAGS": ["-filelist", "complete.list"]}},
            "sources": {"isa": "PBXSourcesBuildPhase", "files": []},
            "resources": {"isa": "PBXResourcesBuildPhase", "files": []}}
        for name in sorted(EXCLUDED_SOURCES | {"CODocument.mm"}):
            objects[name] = {"isa": "PBXFileReference", "path": name}
            objects["build-" + name] = {"isa": "PBXBuildFile", "fileRef": name}
            objects["sources"]["files"].append("build-" + name)
        return {"objects": objects}

    def test_host_report_records_the_applied_kit_overlay_provenance(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "host"
            (output / "source/ios/Mobile").mkdir(parents=True)
            project_path = output / "source/ios/Mobile.xcodeproj/project.pbxproj"
            project_path.parent.mkdir(parents=True)
            project_path.write_bytes(plistlib.dumps(self.minimal_project()))
            base = {"command": ["xcodebuild", "-target", "Mobile",
                                "-resultBundlePath", "fixture.xcresult"]}
            with mock.patch("build_office_native_host.qualify", return_value=base):
                report = build_host(Path("/bundle"), output, build=False)
        lock = json.loads(DEFAULT_LOCK.read_text())
        section = lock["kitCallbackLifecycleOverlay"]
        self.assertEqual(report["kitCallbackLifecycle"], {
            "patchSHA256": section["sha256"],
            "sourceCommit": lock["commit"],
            "files": {name: spec["preparedSHA256"]
                      for name, spec in section["files"].items()}})
        # The old host pin is not silently relabeled: it has no claim, so
        # bootstrap keeps accepting the artifact built before this overlay.
        self.assertIsNone(lock["qualifiedHostArtifact"].get("kitCallbackOverlaySHA256"))


if __name__ == "__main__":
    unittest.main()
