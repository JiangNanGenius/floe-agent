#!/usr/bin/env python3
"""Focused contract tests for verified browser resources in native components.

These tests never build TypeScript, Xcode, a Simulator or a device. They use
small faithful fixtures for the producer receipt format and the existing core
predicates, and prove the integration boundary:

* the producer receipt and live adjacent browser contract are both mandatory;
* staging materializes the owned shadow path without writing through aliases
  or mutating the verified base bundle;
* only the compact portable block enters a manifest/pin;
* a legacy pin without the block remains a checkable baseline while never
  claiming the frontend patch, and a new artifact cannot be pinned without it.
"""

import hashlib
import io
import json
import plistlib
import sys
import tempfile
import unittest
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = REPO_ROOT / "FloeAgent/scripts"
for path in (SCRIPTS, SCRIPTS / "office_floe_simulator"):
    sys.path.insert(0, str(path))

import bootstrap_office_host as bootstrap  # noqa: E402
import build_office_browser_resources as producer  # noqa: E402
import build_office_native_host as native_host  # noqa: E402
import build_simulator_framework as simulator  # noqa: E402
import office_browser_resources as browser  # noqa: E402
import pin_office_host_artifact as pinner  # noqa: E402

HOST_SOURCES = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/FloeOfficeNative"
TRACKED_BROWSER_LOCK = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/browser.patch.lock.json"
ENGINE_COMMIT = "a" * 40
EMBEDDING_SHA = "b" * 64
QUALIFICATION_FLAGS = ("hostCompilePassed", "hostLinkPassed", "swiftModuleImportPassed")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def sha_file(path):
    return sha(Path(path).read_bytes())


def clone(value):
    return json.loads(json.dumps(value))


class BrowserFixture:
    """A small but producer-shaped world: base tree, stage, receipt, contract."""

    def __init__(self, root):
        self.root = Path(root)
        self.base = self.root / "base/source"
        self.base_browser = self.base / "browser"
        self.base_bundle = self.base_browser / "dist/bundle.js"
        self.original_bundle = b"verified original bundle bytes"
        self.base_bundle.parent.mkdir(parents=True)
        self.base_bundle.write_bytes(self.original_bundle)
        (self.base_browser / "dist/bundle.css").write_bytes(b"original css")
        (self.base_browser / "unrelated.js").write_bytes(b"original sibling")

        self.shadow = self.root / "shadow/source"
        self.shadow.mkdir(parents=True)
        (self.shadow / "browser").symlink_to(self.base_browser.resolve())

        self.contract = self.root / "contract"
        self.contract.mkdir()
        self.patch = self.contract / "patches/fixture-browser.patch"
        self.patch.parent.mkdir(parents=True)
        self.patch.write_bytes(b"fixture browser patch bytes\n")
        self.original_ts = b"original fixture TypeScript\n"
        self.patched_ts = b"patched fixture TypeScript\n"
        self.browser_lock = self.write_browser_lock()

        self.engine_lock = self.contract / "engine.lock.json"
        self.engine_lock.write_text(json.dumps({
            "commit": ENGINE_COMMIT,
            "embeddingOverlay": {"sha256": EMBEDDING_SHA},
        }, indent=2) + "\n")

        self.stage = self.root / "stage"
        self.stage_browser = self.stage / "source/browser"
        ts = self.stage_browser / producer.BROWSER_TS_REL
        ts.parent.mkdir(parents=True)
        ts.write_bytes(self.patched_ts)
        module = self.stage_browser / "dist/src/canvas/CanvasSectionContainer.js"
        module.parent.mkdir(parents=True)
        module.write_bytes(b"transpiled module")
        self.patched_bundle = (
            "prefix " + producer.PATCH_MARKER
            + " this.clearMousePositions() this.clearMousePositions()"
            + " this.findSectionContainingPoint(this.positionOnMouseDown)"
            + " this.convertPositionToCanvasLocale("
        ).encode()
        (self.stage_browser / "dist/bundle.js").write_bytes(self.patched_bundle)
        (self.stage_browser / "dist/extra.css").write_bytes(b"staged css")
        (self.stage_browser / "npm-shrinkwrap.json").write_bytes(b"{}")
        (self.stage_browser / "package-lock.json").write_bytes(b"{}")
        (self.stage_browser / "node_shrinkpack").mkdir()
        (self.stage_browser / "node_shrinkpack/pkg-1.0.tgz").write_bytes(b"tar")
        (self.stage_browser / "release").mkdir()
        (self.stage_browser / "release/cool-src.js").write_bytes(b"cool")
        (self.stage_browser / "release/bundle.js").write_bytes(b"intermediate")
        self.output = self.stage / "output"
        self.output.mkdir()
        self.output_bundle = self.output / "bundle.js"
        self.output_bundle.write_bytes(self.patched_bundle)

        inventory = self.browser_lock["browserSourcePatches"][0]
        self.receipt = self.root / "receipt.json"
        self.receipt.write_text(json.dumps({
            "formatVersion": producer.RECEIPT_FORMAT_VERSION,
            "kind": producer.RECEIPT_KIND,
            "inputs": {
                "stageRoot": str(self.stage),
                "restoredSourceRoot": str(self.base),
                "restoredOriginalBundleSHA256": sha(self.original_bundle),
                "restoredOriginalTSSHA256": sha(self.original_ts),
            },
            "frontendIdentity": {
                "browserPatchLock": str(self.contract / browser.LOCK_NAME),
                "browserPatchLockSHA256": sha_file(self.contract / browser.LOCK_NAME),
                "engineRepository": self.browser_lock["engine"]["repository"],
                "engineCommit": ENGINE_COMMIT,
                "coolVersionOverride": ENGINE_COMMIT[:10],
                "patches": [{
                    "patch": inventory["patch"],
                    "patchPath": str(self.patch),
                    "patchSHA256": inventory["patchSHA256"],
                    "sourceFile": inventory["sourceFile"],
                    "originalSourceSHA256": inventory["originalSourceSHA256"],
                    "patchedSourceSHA256": inventory["patchedSourceSHA256"],
                    "stagedPatchedSHA256": sha(self.patched_ts),
                    "applied": True,
                }],
            },
            "dependencyInstall": {
                "npmShrinkwrapSHA256": sha_file(self.stage_browser / "npm-shrinkwrap.json"),
                "packageLockSHA256": sha_file(self.stage_browser / "package-lock.json"),
                "nodeShrinkpackManifestSHA256": producer.shrinkpack_manifest_digest(
                    self.stage_browser / "node_shrinkpack")[0],
            },
            "controlBuild": {
                "byteIdenticalToRestoredOriginal": True,
                "rebuiltBundleSHA256": sha(self.original_bundle),
            },
            "patchedBuild": {
                "distBundleSHA256": sha(self.patched_bundle),
                "moduleSHA256": sha_file(module),
                "intermediates": {
                    "release/cool-src.js": sha_file(self.stage_browser / "release/cool-src.js"),
                    "release/bundle.js": sha_file(self.stage_browser / "release/bundle.js"),
                },
            },
            "output": {
                "bundle": str(self.output_bundle),
                "bundleSHA256": sha(self.patched_bundle),
            },
            "distTree": {
                "patchedTreeSHA256": producer.tree_digest(
                    producer.dist_manifest(self.stage_browser / "dist")),
                "patchedFiles": len(producer.dist_manifest(self.stage_browser / "dist")),
            },
            "browserResources": {
                "engineCommit": ENGINE_COMMIT,
                "browserPatchLockSHA256": sha_file(self.contract / browser.LOCK_NAME),
                "patchSHA256": inventory["patchSHA256"],
                "sourceFile": inventory["sourceFile"],
                "originalSourceSHA256": inventory["originalSourceSHA256"],
                "patchedSourceSHA256": inventory["patchedSourceSHA256"],
                "originalBundleSHA256": sha(self.original_bundle),
                "bundleSHA256": sha(self.patched_bundle),
                "sizeBytes": len(self.patched_bundle),
                "patchedDistTreeSHA256": producer.tree_digest(
                    producer.dist_manifest(self.stage_browser / "dist")),
                "dependencyLockSHA256": sha_file(
                    self.stage_browser / "npm-shrinkwrap.json"),
                "toolchain": {},
            },
        }, indent=2) + "\n")

    def write_browser_lock(self, *, commit=ENGINE_COMMIT, patch_bytes=None,
                           patched_ts=None):
        patch_bytes = self.patch.read_bytes() if patch_bytes is None else patch_bytes
        patched_ts = self.patched_ts if patched_ts is None else patched_ts
        lock = {
            "formatVersion": 1,
            "kind": "fixture browser source patches",
            "engine": {
                "repository": "https://example.invalid/fixture-online.git",
                "commit": commit,
            },
            "browserSourcePatches": [{
                "patch": "patches/fixture-browser.patch",
                "patchSHA256": sha(patch_bytes),
                "sourceRepository": "https://example.invalid/fixture-online.git",
                "sourceCommit": commit,
                "sourceFile": "browser/src/canvas/CanvasSectionContainer.ts",
                "originalSourceSHA256": sha(self.original_ts),
                "patchedSourceSHA256": sha(patched_ts),
                "note": "fixture only",
            }],
        }
        (self.contract / browser.LOCK_NAME).write_text(json.dumps(lock, indent=2) + "\n")
        return lock

    def contract_value(self):
        return browser.live_contract(self.engine_lock, engine_commit=ENGINE_COMMIT)

    def validate(self, **overrides):
        values = {
            "lock_path": self.engine_lock,
            "base_bundle": self.base_bundle,
            "engine_commit": ENGINE_COMMIT,
            "expected_original_bundle_sha256": sha(self.original_bundle),
        }
        values.update(overrides)
        return browser.validate_receipt(self.receipt, **values)

    def block(self):
        return browser.compact_block(
            self.contract_value(), sha(self.original_bundle), sha(self.patched_bundle))

    def pin_block(self):
        """The portable block a manifest/pin records for the pinned original."""
        return browser.compact_block(
            self.contract_value(), browser.EXPECTED_ORIGINAL_BUNDLE_SHA256,
            sha(self.patched_bundle))


class ReceiptAndStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.fixture = BrowserFixture(self.temporary.name)

    def test_real_tracked_contract_is_bound_exactly(self):
        self.assertEqual(
            browser.EXPECTED_ORIGINAL_BUNDLE_SHA256,
            "6320b78ccd3b08e55d4d861f78e696b15d750aca871a1c4a6c8f2027a795f574")
        contract = browser.live_contract(
            REPO_ROOT / "FloeAgent/ThirdParty/Collabora/engine.lock.json",
            engine_commit="27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc")
        self.assertEqual(
            contract["lockSHA256"],
            "5e6b8222a581851dff57f44811b83bb89f50df8221acfc7daf705cfd84867b55")
        self.assertEqual(len(contract["patches"]), 3)
        by_patch = {patch["patch"]: patch for patch in contract["patches"]}
        patch = by_patch["patches/ios-batched-touch-start.patch"]
        self.assertEqual(
            patch["sourceFile"], "browser/src/canvas/CanvasSectionContainer.ts")
        self.assertEqual(
            patch["originalSourceSHA256"],
            "16389cdebe77ddc98e4eddfcdeee6ca0a4432f35dbfd342c17c2d12be2349135")
        self.assertEqual(
            patch["patchedSourceSHA256"],
            "9c930d4145196acffb6920bfc1573fdd39534dd86a3771bc2a0981d23ca71ec5")
        chained = by_patch["patches/ios-pinch-cancel-propagation.patch"]
        self.assertEqual(
            chained["originalSourceSHA256"],
            "9c930d4145196acffb6920bfc1573fdd39534dd86a3771bc2a0981d23ca71ec5")
        self.assertEqual(
            chained["sourceFile"],
            "browser/src/canvas/CanvasSectionContainer.ts")
        live = by_patch["patches/ios-live-pinch-zoom.patch"]
        self.assertEqual(
            live["sourceFile"], "browser/src/canvas/sections/ZoomControl.ts")
        self.assertEqual(
            live["patchSHA256"],
            "12a1152fa2455bb174462006ce8f097b2b874f397d3b1d2cabcfa9d198957b45")
        self.assertEqual(
            live["originalSourceSHA256"],
            "d4af808380c7610fdfb3e40749395833bb8d24bccd1f45eaffb8e66f9cb6e3fc")
        self.assertEqual(
            live["patchedSourceSHA256"],
            "b4afe9ee63720e445f6e6579def565c3808ff846d063287dbb66120f55d973d8")
        self.assertNotIn("lockPath", browser.compact_block(contract, "6" * 64, "7" * 64))

    def test_valid_receipt_and_owned_materialization(self):
        info = self.fixture.validate()
        self.assertEqual(info["bundleSHA256"], sha(self.fixture.patched_bundle))
        self.assertEqual(info["block"], self.fixture.block())
        staged = browser.stage_bundle(
            self.fixture.shadow, self.fixture.base, info)
        # The owned leaf carries the patched bytes, while the base tree and the
        # unpatched sibling aliases are untouched.
        self.assertFalse(staged.is_symlink())
        self.assertEqual(staged.read_bytes(), self.fixture.patched_bundle)
        self.assertFalse((self.fixture.shadow / "browser").is_symlink())
        self.assertFalse((self.fixture.shadow / "browser/dist").is_symlink())
        self.assertTrue(
            (self.fixture.shadow / "browser/dist/bundle.css").is_symlink())
        self.assertEqual(
            (self.fixture.shadow / "browser/dist/bundle.css").read_bytes(),
            b"original css")
        self.assertEqual(
            self.fixture.base_bundle.read_bytes(), self.fixture.original_bundle)
        self.assertEqual(
            (self.fixture.base_browser / "dist/bundle.css").read_bytes(),
            b"original css")

    def test_report_receives_only_the_compact_block(self):
        report = {}
        block = browser.apply_to_report(
            report,
            lock_path=self.fixture.engine_lock,
            receipt_path=self.fixture.receipt,
            shadow=self.fixture.shadow,
            base_source=self.fixture.base,
            build=True,
            engine_commit=ENGINE_COMMIT,
            expected_original_bundle_sha256=sha(self.fixture.original_bundle),
        )
        self.assertEqual(block, self.fixture.block())
        self.assertEqual(report, {"browserResources": block})
        text = json.dumps(report)
        self.assertNotIn(str(self.fixture.root), text)
        self.assertNotIn("receipt.json", text)
        self.assertNotIn("stageRoot", text)

    def test_missing_or_tampered_output_is_rejected(self):
        self.fixture.output_bundle.unlink()
        with self.assertRaises(browser.BrowserResourceError):
            self.fixture.validate()
        self.fixture.output_bundle.write_bytes(b"tampered after build")
        with self.assertRaises(browser.BrowserResourceError):
            self.fixture.validate()

    def test_wrong_base_or_live_identity_is_rejected(self):
        self.fixture.base_bundle.write_bytes(b"different base")
        with self.assertRaisesRegex(browser.BrowserResourceError, "original bundle"):
            self.fixture.validate()
        self.fixture.base_bundle.write_bytes(self.fixture.original_bundle)
        with self.assertRaisesRegex(browser.BrowserResourceError, "engine commit"):
            browser.live_contract(self.fixture.engine_lock,
                                  engine_commit="d" * 40)

        # A changed live lock (same patch, different identity bytes) cannot
        # satisfy the receipt's locked hash. The producer's own verification
        # is now live-contract-bound, so it rejects the mismatch before the
        # explicit helper comparison.
        alternate = self.fixture.root / "alternate"
        (alternate / "patches").mkdir(parents=True)
        changed = json.loads(
            (self.fixture.contract / browser.LOCK_NAME).read_text())
        changed["note"] = "changed live identity"
        (alternate / browser.LOCK_NAME).write_text(
            json.dumps(changed, indent=2) + "\n")
        (alternate / "patches/fixture-browser.patch").write_bytes(
            self.fixture.patch.read_bytes())
        alternate_lock = alternate / "engine.lock.json"
        alternate_lock.write_bytes(self.fixture.engine_lock.read_bytes())
        with self.assertRaisesRegex(browser.BrowserResourceError,
                                    "browserPatchLockSHA256"):
            self.fixture.validate(lock_path=alternate_lock)

        # The receipt's own recorded contract hash is also enforced.
        receipt = json.loads(self.fixture.receipt.read_text())
        receipt["frontendIdentity"]["browserPatchLockSHA256"] = "0" * 64
        self.fixture.receipt.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(browser.BrowserResourceError,
                                    "browserPatchLockSHA256"):
            self.fixture.validate()

        # A live lock that names different patched source bytes is rejected,
        # and a lock whose patch digest no longer matches the patch file is
        # rejected by the producer contract validator.
        self.fixture.write_browser_lock(patched_ts=b"different patched source")
        with self.assertRaises(browser.BrowserResourceError):
            self.fixture.validate()
        self.fixture.write_browser_lock(patch_bytes=b"different patch bytes")
        with self.assertRaises(browser.BrowserResourceError):
            self.fixture.validate()
        self.fixture.write_browser_lock()

    def test_private_path_block_is_rejected(self):
        contract = self.fixture.contract_value()
        block = self.fixture.pin_block()
        with_path = clone(block)
        with_path["receiptPath"] = "/private/tmp/pencil/receipt.json"
        self.assertTrue(browser.compact_block_failures(with_path, contract))
        absolute_patch = clone(block)
        absolute_patch["patches"][0]["sourceFile"] = "/private/tmp/source.ts"
        self.assertTrue(browser.compact_block_failures(absolute_patch, contract))
        self.assertEqual(browser.compact_block_failures(block, contract), [])

    def test_new_build_requires_receipt_but_custom_lock_stays_compatible(self):
        with self.assertRaisesRegex(browser.BrowserResourceError, "requires a verified"):
            browser.stage_for_build(
                lock_path=self.fixture.engine_lock,
                receipt_path=None,
                shadow=self.fixture.shadow,
                base_source=self.fixture.base,
                build=True,
                engine_commit=ENGINE_COMMIT,
            )
        # Prepare-only remains diagnostic; no resource is claimed.
        self.assertIsNone(browser.stage_for_build(
            lock_path=self.fixture.engine_lock,
            receipt_path=None,
            shadow=self.fixture.shadow,
            base_source=self.fixture.base,
            build=False,
            engine_commit=ENGINE_COMMIT,
        ))

        custom = self.fixture.root / "custom"
        custom.mkdir()
        custom_lock = custom / "engine.lock.json"
        custom_lock.write_bytes(self.fixture.engine_lock.read_bytes())
        self.assertIsNone(browser.stage_for_build(
            lock_path=custom_lock,
            receipt_path=None,
            shadow=self.fixture.shadow,
            base_source=self.fixture.base,
            build=True,
            engine_commit=ENGINE_COMMIT,
        ))
        with self.assertRaisesRegex(browser.BrowserResourceError, "no live browser"):
            browser.stage_for_build(
                lock_path=custom_lock,
                receipt_path=self.fixture.receipt,
                shadow=self.fixture.shadow,
                base_source=self.fixture.base,
                build=True,
                engine_commit=ENGINE_COMMIT,
            )


class NativeHostWiringTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.fixture = BrowserFixture(self.temporary.name)

    def fake_qualify(self, root, output, *, build, sdk, lock_path):
        output = Path(output)
        (output / "source/ios/Mobile.xcodeproj").mkdir(parents=True)
        (output / "source/ios/Mobile.xcodeproj/project.pbxproj").write_bytes(
            plistlib.dumps({}))
        (output / "source/ios/Mobile").mkdir()
        (output / "source/browser").symlink_to(
            (Path(root) / "source/browser").resolve())
        return {
            "command": ["xcodebuild", "-target", "Mobile",
                        "-resultBundlePath", "fixture.xcresult"],
            "sdk": sdk,
            "sourceCommit": ENGINE_COMMIT,
            "overlaySHA256": EMBEDDING_SHA,
            "nativeCompilePassed": False,
            "nativeLinkPassed": False,
            "swiftModuleImportPassed": False,
        }

    def run_prepare(self, *, lock_path=None, receipt=True, build=False):
        lock_path = Path(lock_path or self.fixture.engine_lock)
        output = self.fixture.root / ("out-" + lock_path.parent.name)
        with mock.patch.object(native_host, "qualify", side_effect=self.fake_qualify), \
             mock.patch.object(native_host, "framework_project",
                               return_value={"objects": {}}), \
             mock.patch.object(native_host, "select_lifecycle_archive",
                               return_value=None), \
             mock.patch.object(browser, "EXPECTED_ORIGINAL_BUNDLE_SHA256",
                               sha(self.fixture.original_bundle)):
            return native_host.build_host(
                self.fixture.root / "base", output, build=build,
                lock_path=lock_path,
                browser_resource_receipt=self.fixture.receipt if receipt else None,
                engine_source=None)

    def test_build_host_records_the_compact_block(self):
        report = self.run_prepare(build=False)
        self.assertEqual(report["browserResources"], self.fixture.block())
        self.assertEqual(report["stage"], "host-prepared")
        staged = self.fixture.root / "out-contract/source/browser/dist/bundle.js"
        self.assertFalse(staged.is_symlink())
        self.assertEqual(staged.read_bytes(), self.fixture.patched_bundle)
        self.assertEqual(
            self.fixture.base_bundle.read_bytes(), self.fixture.original_bundle)

    def test_new_component_build_without_receipt_fails_before_compile(self):
        with self.assertRaisesRegex(browser.BrowserResourceError,
                                    "requires a verified"):
            self.run_prepare(receipt=False, build=True)

    def test_custom_lock_without_contract_keeps_old_behavior(self):
        custom = self.fixture.root / "no-contract"
        custom.mkdir()
        (custom / "engine.lock.json").write_bytes(self.fixture.engine_lock.read_bytes())
        report = self.run_prepare(lock_path=custom / "engine.lock.json", receipt=False)
        self.assertNotIn("browserResources", report)
        self.assertEqual(
            self.fixture.base_bundle.read_bytes(), self.fixture.original_bundle)


def minimal_lock(with_block=None):
    pin = {
        "hostSourceSHA256": {
            name: sha_file(HOST_SOURCES / name)
            for name in ("FloeOfficeNative.h", "FloeOfficeNative.mm",
                         "FloeOfficeAttachment.cpp", "FloeOfficeAttachment.hxx")
        },
        "overlaySHA256": EMBEDDING_SHA,
    }
    if with_block is not None:
        pin["browserResources"] = with_block
    return {
        "commit": ENGINE_COMMIT,
        "embeddingOverlay": {"sha256": EMBEDDING_SHA},
        "qualifiedHostArtifact": pin,
    }


class PinIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.fixture = BrowserFixture(self.temporary.name)
        self.contract = self.fixture.contract_value()
        # Minimal custom contract keeps the native repair/lifecycle proof out
        # of this focused frontend test.
        self.lock_path = self.fixture.root / "pin/engine.lock.json"
        self.lock_path.parent.mkdir()
        (self.lock_path.parent / "browser.patch.lock.json").write_bytes(
            (self.fixture.contract / browser.LOCK_NAME).read_bytes())
        (self.lock_path.parent / "patches").mkdir()
        (self.lock_path.parent / "patches/fixture-browser.patch").write_bytes(
            self.fixture.patch.read_bytes())

    def write_lock(self, block=None):
        self.lock_path.write_text(json.dumps(minimal_lock(block), indent=2) + "\n")
        return self.lock_path

    def run_check(self):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = pinner.check(self.lock_path)
        return code, out.getvalue(), err.getvalue()

    def make_artifact(self, folder, *, block, bundle_bytes=None):
        folder = Path(folder) / ("artifact-" + str(len(list(Path(folder).glob("artifact-*")))))
        folder.mkdir(parents=True)
        root = folder / "OfficeNativeHost"
        framework = root / "FloeOfficeNative.framework"
        framework.mkdir(parents=True)
        (framework / "FloeOfficeNative").write_bytes(b"framework binary")
        resources = root / "OfficeRuntimeResources"
        resources.mkdir()
        bundle_bytes = self.fixture.patched_bundle if bundle_bytes is None else bundle_bytes
        (resources / "bundle.js").write_bytes(bundle_bytes)
        manifest = {
            "sourceCommit": ENGINE_COMMIT,
            "overlaySHA256": EMBEDDING_SHA,
            "hostSourceSHA256": minimal_lock()["qualifiedHostArtifact"]["hostSourceSHA256"],
            "hostCompilePassed": True,
            "hostLinkPassed": True,
            "swiftModuleImportPassed": True,
            "capabilityQualification": {
                "embeddedEditorPassed": False,
                "pptxVisibleRenderPassed": False,
                "deviceRoundtripPassed": False,
                "originalFileWritebackPassed": False,
            },
            "runID": "12345",
            "workflowCommit": "c" * 40,
            "runtimeResourceSHA256": {
                "bundle.js": sha(bundle_bytes),
            },
        }
        if block is not None:
            manifest["browserResources"] = block
            manifest["runtimeResourceSHA256"]["bundle.js"] = sha(bundle_bytes)
        (root / "native-host.json").write_text(json.dumps(manifest, indent=2) + "\n")
        archive_path = Path(folder) / "OfficeNativeHost.zip"
        with zipfile.ZipFile(archive_path, "w") as archive:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(folder))
        return archive_path

    def test_legacy_pin_stays_a_checkable_baseline(self):
        lock = self.write_lock(block=None)
        code, out, _ = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn("legacy baseline", out)
        self.assertNotIn("browserResources", json.loads(lock.read_text())["qualifiedHostArtifact"])

    def test_pin_claim_must_match_the_live_contract(self):
        wrong = clone(self.fixture.pin_block())
        wrong["browserPatchLockSHA256"] = "0" * 64
        self.write_lock(block=wrong)
        code, out, _ = self.run_check()
        self.assertEqual(code, 2, out)
        self.assertIn("REJECTED browser resources claim", out)

    def test_apply_requires_the_block_and_actual_bundle_digest(self):
        lock = self.write_lock(block=None)
        before = lock.read_bytes()
        artifact = self.make_artifact(self.fixture.root, block=None)
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = pinner.apply(lock, artifact, "fixture")
        self.assertEqual(code, 1, out.getvalue())
        self.assertIn("no verified browser resources", err.getvalue())
        self.assertEqual(lock.read_bytes(), before)

        wrong = clone(self.fixture.pin_block())
        wrong["bundleSHA256"] = "9" * 64
        artifact = self.make_artifact(self.fixture.root, block=wrong)
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = pinner.apply(lock, artifact, "fixture")
        self.assertEqual(code, 1, out.getvalue())
        self.assertIn("bundle digest differs", err.getvalue())
        self.assertEqual(lock.read_bytes(), before)

        artifact = self.make_artifact(self.fixture.root, block=self.fixture.pin_block())
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = pinner.apply(lock, artifact, "fixture")
        self.assertEqual(code, 0, out.getvalue() + err.getvalue())
        updated = json.loads(lock.read_text())["qualifiedHostArtifact"]
        self.assertEqual(updated["browserResources"], self.fixture.pin_block())
        self.assertFalse(updated["capabilityQualification"]["deviceRoundtripPassed"])
        code, out, _ = self.run_check()
        self.assertEqual(code, 0, out)

    def test_pin_claim_cannot_be_dropped_by_an_artifact(self):
        lock = self.write_lock(block=self.fixture.pin_block())
        before = lock.read_bytes()
        artifact = self.make_artifact(self.fixture.root, block=None)
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = pinner.apply(lock, artifact, "fixture")
        self.assertEqual(code, 1, out.getvalue())
        self.assertIn("pin claims browser resources", err.getvalue())
        self.assertEqual(lock.read_bytes(), before)

    def test_custom_contract_absence_keeps_apply_compatible(self):
        lock_dir = self.fixture.root / "custom-pin"
        lock_dir.mkdir()
        lock = lock_dir / "engine.lock.json"
        lock.write_text(json.dumps(minimal_lock(), indent=2) + "\n")
        artifact = self.make_artifact(self.fixture.root / "custom-artifact",
                                      block=None, bundle_bytes=b"original")
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(browser, "EXPECTED_ORIGINAL_BUNDLE_SHA256",
                               sha(b"original")):
            with redirect_stdout(out), redirect_stderr(err):
                code = pinner.apply(lock, artifact, "fixture")
        self.assertEqual(code, 0, out.getvalue() + err.getvalue())
        self.assertNotIn("browserResources",
                         json.loads(lock.read_text())["qualifiedHostArtifact"])


class BootstrapIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.fixture = BrowserFixture(self.temporary.name)
        self.lock_path = self.fixture.root / "boot/engine.lock.json"
        self.lock_path.parent.mkdir()
        (self.lock_path.parent / "browser.patch.lock.json").write_bytes(
            (self.fixture.contract / browser.LOCK_NAME).read_bytes())
        (self.lock_path.parent / "patches").mkdir()
        (self.lock_path.parent / "patches/fixture-browser.patch").write_bytes(
            self.fixture.patch.read_bytes())
        (self.lock_path.parent / "FloeOfficeNative").symlink_to(HOST_SOURCES)

    def write_lock(self, block=None):
        self.lock_path.write_text(json.dumps(minimal_lock(block), indent=2) + "\n")
        return json.loads(self.lock_path.read_text())

    def test_checked_lock_legacy_and_claimed(self):
        self.write_lock(block=None)
        _, pin = bootstrap.checked_lock(self.lock_path)
        self.assertNotIn("browserResources", pin)

        self.write_lock(block=self.fixture.pin_block())
        _, pin = bootstrap.checked_lock(self.lock_path)
        self.assertEqual(pin["browserResources"], self.fixture.pin_block())

        wrong = clone(self.fixture.pin_block())
        wrong["engineCommit"] = "d" * 40
        self.write_lock(block=wrong)
        with self.assertRaisesRegex(ValueError, "browser resources claim"):
            bootstrap.checked_lock(self.lock_path)

    def make_installed(self, block, bundle_bytes):
        folder = self.fixture.root / ("installed-" + str(len(list(self.fixture.root.glob("installed-*")))))
        folder.mkdir()
        manifest = {
            "sourceCommit": ENGINE_COMMIT,
            "overlaySHA256": EMBEDDING_SHA,
            "hostSourceSHA256": minimal_lock()["qualifiedHostArtifact"]["hostSourceSHA256"],
            "hostCompilePassed": True,
            "hostLinkPassed": True,
            "swiftModuleImportPassed": True,
            "runtimeResourceSHA256": {"bundle.js": sha(bundle_bytes)},
            "runtimeResourceDirectories": [],
        }
        if block is not None:
            manifest["browserResources"] = block
        (folder / "native-host.json").write_text(json.dumps(manifest, indent=2) + "\n")
        lock = minimal_lock(block)
        lock["qualifiedHostArtifact"].update({
            "manifestSHA256": sha_file(folder / "native-host.json"),
            "executableSHA256": "e" * 64,
            "frameworkAuxiliarySHA256": {},
        })
        return folder, lock, lock["qualifiedHostArtifact"]

    def test_inventory_requires_pinned_block_and_actual_runtime_digest(self):
        block = self.fixture.pin_block()
        folder, lock, pin = self.make_installed(block, self.fixture.patched_bundle)
        bootstrap.inventory(folder, lock, pin)

        folder, lock, pin = self.make_installed(None, self.fixture.patched_bundle)
        with self.assertRaisesRegex(ValueError, "non-baseline browser bundle"):
            bootstrap.inventory(folder, lock, pin)

        folder, lock, pin = self.make_installed(None, self.fixture.original_bundle)
        with mock.patch.object(browser, "EXPECTED_ORIGINAL_BUNDLE_SHA256",
                               sha(self.fixture.original_bundle)):
            bootstrap.inventory(folder, lock, pin)

        bad = clone(block)
        bad["bundleSHA256"] = "9" * 64
        folder, lock, pin = self.make_installed(bad, self.fixture.patched_bundle)
        with self.assertRaisesRegex(ValueError, "digest differs"):
            bootstrap.inventory(folder, lock, pin)


class SimulatorIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fixture = BrowserFixture(self.root)

    def test_nokit_lock_keeps_the_live_browser_contract(self):
        with tempfile.TemporaryDirectory() as workdir:
            lock_path, applied = simulator.variant_lock("nokit", workdir)
            self.assertFalse(applied)
            staged = Path(lock_path).parent / browser.LOCK_NAME
            self.assertTrue(staged.is_file())
            self.assertEqual(staged.read_bytes(), TRACKED_BROWSER_LOCK.read_bytes())

    def test_wrapper_forwards_the_receipt(self):
        output = self.root / "sim-output"
        receipt = self.fixture.receipt
        fake_zip = self.root / "fake.zip"
        fake_zip.write_bytes(b"zip")
        with mock.patch.object(simulator, "variant_lock",
                               return_value=(self.fixture.engine_lock, True)), \
             mock.patch.object(simulator, "sdk_identity", return_value={}), \
             mock.patch.object(simulator, "validate_build_inputs",
                               return_value=(None, None, {})), \
             mock.patch.object(simulator, "build_host", return_value={}) as build, \
             mock.patch.object(simulator, "package_host",
                               return_value=(self.root / "bundle",
                                             {"kind": "fixture"})), \
             mock.patch.object(simulator, "zip_bundle", return_value=fake_zip):
            simulator.build_framework(
                self.root / "restored", output, variant="kit", base_run_id="1",
                browser_resource_receipt=receipt)
        self.assertEqual(build.call_args.kwargs["browser_resource_receipt"], receipt)

    def test_package_host_carries_the_compact_block(self):
        output = self.root / "package"
        framework = output / "build/products/Release-iphonesimulator/FloeOfficeNative.framework"
        framework.mkdir(parents=True)
        (framework / "FloeOfficeNative").write_bytes(b"framework")
        resources = output / "build/OfficeRuntimeResources"
        resources.mkdir(parents=True)
        (resources / "bundle.js").write_bytes(self.fixture.patched_bundle)
        restored = self.root / "restored"
        restored.mkdir()
        (restored / "restore-report.json").write_text(json.dumps({
            "provenanceArtifactSHA256": "d" * 64,
            "sourceCommit": ENGINE_COMMIT,
        }) + "\n")
        report = {
            "sourceCommit": ENGINE_COMMIT,
            "sdk": "iphonesimulator",
            "swiftImportTarget": "arm64-apple-ios26.0-simulator",
            "overlaySHA256": EMBEDDING_SHA,
            "schemeTaskLifecycle": None,
            "forwardingLifecycle": None,
            "kitCallbackLifecycle": None,
            "embeddedLifecycle": None,
            "embeddedLifecycleMember": None,
            "filterOverlay": None,
            "hostSourceSHA256": minimal_lock()["qualifiedHostArtifact"]["hostSourceSHA256"],
            "executableSHA256": sha_file(framework / "FloeOfficeNative"),
            "platformLoadCommands": "",
            "swiftModuleImportPassed": True,
            "swiftProbeSHA256": "f" * 64,
            "nativeCompilePassed": True,
            "nativeLinkPassed": True,
            "runtimeResourceSHA256": {"bundle.js": sha(self.fixture.patched_bundle)},
            "runtimeResourceDirectories": [],
            "fontSubstitutionConfig": None,
            "languageResources": None,
            "buildInputs": {},
            "platformOriginalArchives": None,
            "browserResources": self.fixture.block(),
        }
        import office_engine_repair
        with mock.patch.object(office_engine_repair, "tracked_contract",
                               return_value=(None, None)):
            _, receipt = simulator.package_host(
                report, restored, output, variant="kit", kit_applied=True,
                base_run_id="1", identity={
                    "sdkVersion": "26.0", "sdkBuildVersion": "1", "xcodeVersion": "X"})
        self.assertEqual(receipt["browserResources"], self.fixture.block())


if __name__ == "__main__":
    unittest.main(verbosity=2)
