#!/usr/bin/env python3
"""Focused contract tests for the Office browser resource producer.

These tests validate the producer contracts without running any real
TypeScript, bundler or engine build: frontend lock validation, patch/source
identity, staging guards, the control-rebuild scope, make overrides, patch
marker semantics, the git-apply command contract and the receipt verification
roundtrip (including that verification performs no writes). The actual rebuild
is executed by the producer itself with its own evidence logs.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))

import build_office_browser_resources as producer  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[3]
LOCK_PATH = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/browser.patch.lock.json"
PATCH_PATH = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/patches/ios-batched-touch-start.patch"

REAL_ENTRY = {
    "patch": "patches/ios-batched-touch-start.patch",
    "patchSHA256": "df47d2dad175bb180fd2b736c7707ee424f6f59c93065ce6827a4292647c5a28",
    "sourceRepository": "https://github.com/CollaboraOnline/online.mirror.git",
    "sourceCommit": "27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc",
    "sourceFile": "browser/src/canvas/CanvasSectionContainer.ts",
    "originalSourceSHA256": "16389cdebe77ddc98e4eddfcdeee6ca0a4432f35dbfd342c17c2d12be2349135",
    "patchedSourceSHA256": "9c930d4145196acffb6920bfc1573fdd39534dd86a3771bc2a0981d23ca71ec5",
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def _lock_with(mutate=None):
    lock = {
        "formatVersion": 1,
        "engine": {"repository": "https://github.com/CollaboraOnline/online.mirror.git",
                   "commit": REAL_ENTRY["sourceCommit"]},
        "browserSourcePatches": [dict(REAL_ENTRY)],
    }
    if mutate:
        mutate(lock)
    return lock


class LockValidationTests(unittest.TestCase):
    def test_real_repo_lock_and_patch_validate(self):
        lock = json.loads(LOCK_PATH.read_text())
        repository, commit, entries = producer.validate_browser_lock(lock, LOCK_PATH.parent)
        self.assertEqual(commit, REAL_ENTRY["sourceCommit"])
        self.assertEqual(len(entries), 1)
        entry = entries[0]
        self.assertEqual(entry["patchSHA256"], REAL_ENTRY["patchSHA256"])
        self.assertEqual(entry["originalSourceSHA256"], REAL_ENTRY["originalSourceSHA256"])
        self.assertEqual(entry["patchedSourceSHA256"], REAL_ENTRY["patchedSourceSHA256"])
        self.assertEqual(sha(PATCH_PATH.read_bytes()), REAL_ENTRY["patchSHA256"])
        self.assertEqual(repository, lock["engine"]["repository"])

    def _validate_in_tmp(self, lock, tmp):
        patches = Path(tmp) / "patches"
        patches.mkdir(parents=True, exist_ok=True)
        (patches / "ios-batched-touch-start.patch").write_bytes(PATCH_PATH.read_bytes())
        return producer.validate_browser_lock(lock, Path(tmp))

    def test_rejects_bad_shape(self):
        mutations = [
            ("formatVersion", lambda l: l.update(formatVersion=2)),
            ("no engine", lambda l: l.pop("engine")),
            ("bad commit", lambda l: l["engine"].update(commit="zzzz")),
            ("empty patches", lambda l: l.update(browserSourcePatches=[])),
            ("missing field", lambda l: l["browserSourcePatches"][0].pop("patchSHA256")),
            ("digest not lowercase hex", lambda l: l["browserSourcePatches"][0].update(
                patchSHA256=REAL_ENTRY["patchSHA256"].upper())),
            ("commit mismatch", lambda l: l["browserSourcePatches"][0].update(
                sourceCommit="0" * 40)),
            ("same original and patched", lambda l: l["browserSourcePatches"][0].update(
                patchedSourceSHA256=REAL_ENTRY["originalSourceSHA256"])),
            ("escaping source file", lambda l: l["browserSourcePatches"][0].update(
                sourceFile="../../etc/passwd")),
            ("escaping patch path", lambda l: l["browserSourcePatches"][0].update(
                patch="../outside.patch")),
            ("duplicate target files", lambda l: l["browserSourcePatches"].append(dict(REAL_ENTRY))),
        ]
        for label, mutate in mutations:
            with self.subTest(label):
                with tempfile.TemporaryDirectory() as tmp:
                    with self.assertRaises(producer.ProducerError):
                        self._validate_in_tmp(_lock_with(mutate), tmp)

    def test_rejects_tampered_patch_digest(self):
        with tempfile.TemporaryDirectory() as tmp:
            lock = _lock_with(lambda l: l["browserSourcePatches"][0].update(
                patchSHA256=sha(b"not the patch")))
            with self.assertRaisesRegex(producer.ProducerError, "digest mismatch"):
                self._validate_in_tmp(lock, tmp)


class OverrideAndScopeTests(unittest.TestCase):
    def test_make_overrides_are_explicit_absolute_replacements(self):
        overrides = producer.make_overrides(
            "/stage/source", "/stage/source/browser",
            "/opt/homebrew/bin/node", "/opt/homebrew/bin/npm", "27b21dc1a9")
        joined = "\n".join(overrides)
        for token in ("NODE=/opt/homebrew/bin/node", "NPM=/opt/homebrew/bin/npm",
                      "abs_top_srcdir=/stage/source",
                      "abs_top_builddir=/stage/source",
                      "abs_builddir=/stage/source/browser",
                      "abs_srcdir=/stage/source/browser",
                      "COOL_VERSION=27b21dc1a9"):
            self.assertIn(token, joined)
        self.assertNotIn("runner", joined)

    def test_control_cleanup_scope_is_the_bundle_js_chain(self):
        self.assertEqual(
            list(producer.CONTROL_CLEAN_STAMPS),
            ["eslint.done", "prettier.done", "tsc-emit.done", "tsc-strict.done",
             "tscompile.done"])
        for rel in ("dist/src", "dist/bundle.js", "release/cool-src.js", "release/bundle.js"):
            self.assertIn(rel, producer.CONTROL_CLEAN_PATHS)
        # Unrelated original dist content must not be inside the control scope.
        self.assertNotIn("dist/bundle.css", producer.CONTROL_CLEAN_PATHS)
        self.assertNotIn("dist/admin-bundle.js", producer.CONTROL_CLEAN_PATHS)

    def test_configure_bookkeeping_targets_are_consume_only(self):
        args = producer.assume_old_args()
        targets = [args[i + 1] for i, v in enumerate(args) if v == "-o"]
        self.assertEqual(sorted(targets), sorted(producer.ASSUME_OLD_TARGETS))
        for target in ("Makefile", "npm-shrinkwrap.json"):
            self.assertIn(target, targets)
        # no real bundle-chain output may ever be marked consume-only
        for banned in ("bundle.js", "cool-src.js", "dist", "tscompile.done"):
            self.assertTrue(all(banned not in t for t in targets))

    def test_npm_state_env_routes_to_owned_stage_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            stage = Path(tmp) / "stage"
            base = {"npm_config_cache": "/Users/x/.npm/_cacache",
                    "npm_config_globalconfig": "/usr/local/etc/npmrc",
                    "HOME": str(tmp)}
            env = producer.npm_state_env(stage, base_env=base)
            self.assertEqual(env["npm_config_cache"], str(stage / "npm-cache"))
            self.assertEqual(env["npm_config_logs_dir"], str(stage / "npm-logs"))
            self.assertTrue((stage / "npm-cache").is_dir())
            self.assertTrue((stage / "npm-logs").is_dir())
            # everything else (registry/auth/user settings) passes through untouched
            self.assertEqual(env["npm_config_globalconfig"], "/usr/local/etc/npmrc")
            self.assertEqual(env["HOME"], str(tmp))
            self.assertNotIn("npm_config_userconfig", base)

    def test_plan_control_cleanup_only_lists_existing(self):
        with tempfile.TemporaryDirectory() as tmp:
            browser = Path(tmp)
            (browser / "tscompile.done").write_text("")
            (browser / "dist").mkdir()
            (browser / "dist/bundle.js").write_text("x")
            planned = producer.plan_control_cleanup(browser)
            self.assertEqual(sorted(planned), sorted(["tscompile.done", "dist/bundle.js"]))


class MarkerTests(unittest.TestCase):
    def test_marker_report(self):
        original = "a(); this.clearMousePositions(); b();"
        patched = ("if (this.positionOnMouseDown===null||this.touchEventInProgress){"
                   "this.clearMousePositions(); this.clearMousePositions();"
                   " this.convertPositionToCanvasLocale(e);"
                   "this.findSectionContainingPoint(this.positionOnMouseDown);}")
        report_original = producer.marker_report(original)
        report_patched = producer.marker_report(patched)
        self.assertFalse(report_original["patchMarkerPresent"])
        self.assertTrue(report_patched["patchMarkerPresent"])
        self.assertGreater(
            report_patched["tokenCounts"]["this.clearMousePositions()"],
            report_original["tokenCounts"]["this.clearMousePositions()"])


def _original_and_patched_from_patch(patch_text):
    """Reconstruct (original, patched) texts satisfying every hunk header.

    Each hunk is placed at its declared original start by padding gaps with
    filler lines; gap-padding is valid because git only validates the context
    lines at the hunk positions. Returns (None, None) when hunks overlap and
    no faithful single-file reconstruction exists.
    """
    lines = patch_text.splitlines()
    hunks = []
    index = 0
    while index < len(lines):
        if lines[index].startswith("@@"):
            old = lines[index].split()[1]
            start = int(old.lstrip("-").split(",")[0])
            body = []
            index += 1
            while index < len(lines) and not lines[index].startswith("@@"):
                body.append(lines[index])
                index += 1
            hunks.append((start, body))
        else:
            index += 1
    if not hunks:
        return None, None
    original_lines = []
    patched_lines = []
    cursor = 1
    for start, body in hunks:
        orig = []
        patched = []
        for line in body:
            if line.startswith("\\"):
                continue
            if line.startswith(" "):
                orig.append(line[1:])
                patched.append(line[1:])
            elif line.startswith("-"):
                orig.append(line[1:])
            elif line.startswith("+"):
                patched.append(line[1:])
        if start < cursor:
            return None, None
        gap = start - cursor
        original_lines.extend("filler" for _ in range(gap))
        patched_lines.extend("filler" for _ in range(gap))
        original_lines.extend(orig)
        patched_lines.extend(patched)
        cursor = start + len(orig)
    return ("\n".join(original_lines) + "\n", "\n".join(patched_lines) + "\n")


    def test_marker_report_survives_esbuild_line_wraps(self):
        # esbuild --line-limit wraps identifiers after a dot with a newline;
        # counting must see the flattened token.
        wrapped = ("x(); if (this.positionOnMouseDown===null||this.touchEventInProgress)"
                   "{var a=this.\nfindSectionContainingPoint(this.positionOnMouseDown);}"
                   "this.\nclearMousePositions();")
        report = producer.marker_report(wrapped)
        self.assertTrue(report["patchMarkerPresent"])
        self.assertEqual(report["tokenCounts"]["this.findSectionContainingPoint(this.positionOnMouseDown)"], 1)
        self.assertEqual(report["tokenCounts"]["this.clearMousePositions()"], 1)


class GitApplyContractTests(unittest.TestCase):
    """The producer's apply command contract (cwd, -p1, contained path)."""

    def test_apply_contract_with_reconstructed_file(self):
        original, expected = _original_and_patched_from_patch(PATCH_PATH.read_text())
        if original is None:
            self.skipTest("hunk geometry not gap-reconstructible")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "browser/src/canvas/CanvasSectionContainer.ts"
            target.parent.mkdir(parents=True)
            target.write_text(original)
            check = subprocess.run(
                ["git", "apply", "--check", "-p1", str(PATCH_PATH)],
                cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            self.assertEqual(check.returncode, 0, check.stdout)
            apply = subprocess.run(
                ["git", "apply", "-p1", str(PATCH_PATH)],
                cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            self.assertEqual(apply.returncode, 0, apply.stdout)
            self.assertEqual(target.read_text(), expected)
            # An already-applied tree must fail a fresh --check: no silent double apply.
            again = subprocess.run(
                ["git", "apply", "--check", "-p1", str(PATCH_PATH)],
                cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            self.assertNotEqual(again.returncode, 0)


def _producer_args(tmp, stage):
    return producer.build_arg_parser().parse_args([
        "--restored-source", str(Path(tmp) / "restored"),
        "--stage-root", str(stage),
        "--output-dir", str(Path(tmp) / "out"),
        "--evidence-dir", str(Path(tmp) / "evidence"),
        "--build-lock-runner", "none",
    ])


class StagingGuardTests(unittest.TestCase):
    def test_refuses_nonempty_stage(self):
        with tempfile.TemporaryDirectory() as tmp:
            stage = Path(tmp) / "stage"
            (stage / "something").mkdir(parents=True)
            instance = producer.Producer(_producer_args(tmp, stage))
            with self.assertRaisesRegex(producer.ProducerError, "not empty"):
                instance.stage()

    def test_absent_or_empty_stage_passes_the_guard(self):
        # With a missing restored source the guard itself must pass and the
        # copy is what fails afterwards.
        for make_dir in (False, True):
            with tempfile.TemporaryDirectory() as tmp:
                stage = Path(tmp) / "stage"
                if make_dir:
                    stage.mkdir()
                instance = producer.Producer(_producer_args(tmp, stage))
                with self.assertRaises(producer.ProducerError):
                    instance.stage()
                self.assertTrue((stage / "source").exists())


class ReceiptVerifyTests(unittest.TestCase):
    """Self-consistent synthetic worlds verify; any tamper is detected."""

    def _build_world(self, tmp):
        tmp = Path(tmp)
        stage = tmp / "stage"
        browser = stage / "source/browser"
        ts = browser / producer.BROWSER_TS_REL
        ts.parent.mkdir(parents=True)
        ts.write_text("synthetic patched TS bytes")
        (browser / "dist/src/canvas").mkdir(parents=True)
        bundle_content = (
            "prefix " + producer.PATCH_MARKER +
            " this.clearMousePositions() this.findSectionContainingPoint("
            "this.positionOnMouseDown) this.convertPositionToCanvasLocale(")
        (browser / "dist/bundle.js").write_text(bundle_content)
        (browser / "dist/src/canvas/CanvasSectionContainer.js").write_text("module")
        (browser / "dist/extra.css").write_text("css")
        (browser / "npm-shrinkwrap.json").write_text('{"lockfileVersion":3}')
        (browser / "package-lock.json").write_text('{"lockfileVersion":3}')
        (browser / "node_shrinkpack").mkdir()
        (browser / "node_shrinkpack/pkg-1.0.tgz").write_bytes(b"tar")
        (browser / "release").mkdir()
        (browser / "release/cool-src.js").write_text("cool")
        (browser / "release/bundle.js").write_text("inter")
        out_dir = stage / "output"
        out_dir.mkdir(parents=True)
        (out_dir / "bundle.js").write_text(bundle_content)

        # Live synthetic lock that agrees with the receipt world.
        lock_dir = tmp / "collabora"
        patches = lock_dir / "patches"
        patches.mkdir(parents=True)
        patch = patches / "ios-batched-touch-start.patch"
        patch.write_text("synthetic patch bytes")
        lock = {
            "formatVersion": 1,
            "engine": {"repository": "https://example.invalid/online.mirror.git",
                       "commit": "a" * 40},
            "browserSourcePatches": [{
                "patch": "patches/ios-batched-touch-start.patch",
                "patchSHA256": sha(patch.read_bytes()),
                "sourceRepository": "https://example.invalid/online.mirror.git",
                "sourceCommit": "a" * 40,
                "sourceFile": str(producer.LOCKED_SOURCEFILE_REL),
                "originalSourceSHA256": sha(b"original"),
                "patchedSourceSHA256": sha(ts.read_bytes()),
            }],
        }
        lock_file = lock_dir / "browser.patch.lock.json"
        lock_file.write_text(json.dumps(lock))

        bundle_sha = sha((browser / "dist/bundle.js").read_bytes())
        original_sha = producer.DEFAULT_EXPECTED_ORIGINAL_BUNDLE_SHA256
        shr, cnt = producer.shrinkpack_manifest_digest(browser / "node_shrinkpack")
        rows = producer.dist_manifest(browser / "dist")
        receipt = {
            "formatVersion": producer.RECEIPT_FORMAT_VERSION,
            "kind": producer.RECEIPT_KIND,
            "inputs": {"stageRoot": str(stage), "restoredOriginalBundleSHA256": original_sha},
            "frontendIdentity": {
                "browserPatchLock": str(lock_file),
                "browserPatchLockSHA256": sha(lock_file.read_bytes()),
                "engineRepository": "https://example.invalid/online.mirror.git",
                "engineCommit": "a" * 40,
                "coolVersionOverride": "aaaaaaaaaa",
                "patches": [{
                    "sourceFile": str(producer.LOCKED_SOURCEFILE_REL),
                    "patchPath": str(patch),
                    "patchSHA256": sha(patch.read_bytes()),
                    "originalSourceSHA256": sha(b"original"),
                    "patchedSourceSHA256": sha(ts.read_bytes()),
                    "stagedPatchedSHA256": sha(ts.read_bytes()),
                }],
            },
            "dependencyInstall": {
                "npmShrinkwrapSHA256": sha((browser / "npm-shrinkwrap.json").read_bytes()),
                "packageLockSHA256": sha((browser / "package-lock.json").read_bytes()),
                "nodeShrinkpackManifestSHA256": shr,
            },
            "controlBuild": {"byteIdenticalToRestoredOriginal": True,
                             "rebuiltBundleSHA256": original_sha},
            "patchedBuild": {
                "distBundleSHA256": bundle_sha,
                "moduleSHA256": sha((browser / producer.MODULE_JS_REL).read_bytes()),
                "intermediates": {
                    "release/cool-src.js": sha((browser / "release/cool-src.js").read_bytes()),
                    "release/bundle.js": sha((browser / "release/bundle.js").read_bytes()),
                },
            },
            "output": {"bundle": str(out_dir / "bundle.js"), "bundleSHA256": bundle_sha},
            "distTree": {"patchedTreeSHA256": producer.tree_digest(rows),
                         "patchedFiles": len(rows)},
            "browserResources": {
                "engineCommit": "a" * 40,
                "browserPatchLockSHA256": sha(lock_file.read_bytes()),
                "patchSHA256": sha(patch.read_bytes()),
                "sourceFile": str(producer.LOCKED_SOURCEFILE_REL),
                "originalSourceSHA256": sha(b"original"),
                "patchedSourceSHA256": sha(ts.read_bytes()),
                "originalBundleSHA256": original_sha,
                "bundleSHA256": bundle_sha,
                "sizeBytes": (out_dir / "bundle.js").stat().st_size,
                "patchedDistTreeSHA256": producer.tree_digest(rows),
                "dependencyLockSHA256": sha((browser / "npm-shrinkwrap.json").read_bytes()),
                "toolchain": {"typescript": "5.0.0"},
            },
        }
        receipt_path = tmp / "receipt.json"
        receipt_path.write_text(json.dumps(receipt))
        return receipt_path, browser, receipt, lock_file

    def test_self_consistent_world_verifies(self):
        with tempfile.TemporaryDirectory() as tmp:
            receipt_path, _, _, lock_file = self._build_world(tmp)
            self.assertEqual(producer.verify_receipt(receipt_path, lock_path=lock_file), [])

    def test_verify_performs_no_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            receipt_path, browser, _, lock_file = self._build_world(tmp)
            snapshot = {}
            for root, dirs, files in os.walk(tmp):
                for name in files:
                    path = Path(root) / name
                    stat = path.stat()
                    snapshot[str(path)] = (stat.st_mtime_ns, stat.st_size)
            dir_count = sum(len(files) for _, _, files in os.walk(tmp))
            self.assertEqual(producer.verify_receipt(receipt_path, lock_path=lock_file), [])
            after = {}
            for root, dirs, files in os.walk(tmp):
                for name in files:
                    path = Path(root) / name
                    stat = path.stat()
                    after[str(path)] = (stat.st_mtime_ns, stat.st_size)
            self.assertEqual(snapshot, after)
            self.assertEqual(sum(len(files) for _, _, files in os.walk(tmp)), dir_count)

    def test_detects_bundle_tampering(self):
        with tempfile.TemporaryDirectory() as tmp:
            receipt_path, browser, _, lock_file = self._build_world(tmp)
            (browser / "dist/bundle.js").write_text("tampered")
            failures = producer.verify_receipt(receipt_path, lock_path=lock_file)
            self.assertTrue(any("staged patched bundle" in f for f in failures))
            self.assertTrue(any("marker" in f for f in failures))
            self.assertTrue(any("dist tree" in f.lower() for f in failures))

    def test_detects_live_lock_tampering(self):
        with tempfile.TemporaryDirectory() as tmp:
            receipt_path, browser, _, lock_file = self._build_world(tmp)
            lock = json.loads(lock_file.read_text())
            entry = lock["browserSourcePatches"][0]
            entry["patchedSourceSHA256"] = sha(b"rogue patched source")
            lock_file.write_text(json.dumps(lock))
            failures = producer.verify_receipt(receipt_path, lock_path=lock_file)
            self.assertTrue(any("browserPatchLockSHA256" in f for f in failures))
            self.assertTrue(any("patchedSourceSHA256 differs from the live lock" in f
                                for f in failures))

    def test_detects_receipt_output_internal_inconsistency(self):
        with tempfile.TemporaryDirectory() as tmp:
            receipt_path, _, receipt, lock_file = self._build_world(tmp)
            receipt["output"]["bundleSHA256"] = sha(b"different")
            Path(receipt_path).write_text(json.dumps(receipt))
            failures = producer.verify_receipt(receipt_path, lock_path=lock_file)
            self.assertTrue(any("output.bundleSHA256 != patchedBuild.distBundleSHA256" in f
                                for f in failures))

    def test_detects_baseline_or_control_fraud(self):
        with tempfile.TemporaryDirectory() as tmp:
            receipt_path, _, receipt, lock_file = self._build_world(tmp)
            receipt["inputs"]["restoredOriginalBundleSHA256"] = sha(b"not the baseline")
            Path(receipt_path).write_text(json.dumps(receipt))
            failures = producer.verify_receipt(receipt_path, lock_path=lock_file)
            self.assertTrue(any("baseline" in f for f in failures))
        with tempfile.TemporaryDirectory() as tmp:
            receipt_path, _, receipt, lock_file = self._build_world(tmp)
            receipt["controlBuild"]["byteIdenticalToRestoredOriginal"] = False
            Path(receipt_path).write_text(json.dumps(receipt))
            failures = producer.verify_receipt(receipt_path, lock_path=lock_file)
            self.assertTrue(any("control build was not byte-identical" in f for f in failures))

    def test_detects_path_leak_in_browser_resources_block(self):
        with tempfile.TemporaryDirectory() as tmp:
            receipt_path, _, receipt, lock_file = self._build_world(tmp)
            receipt["browserResources"]["bundleSHA256"] = "/abs/path/bundle.js"
            Path(receipt_path).write_text(json.dumps(receipt))
            failures = producer.verify_receipt(receipt_path, lock_path=lock_file)
            self.assertTrue(any("inconsistent" in f for f in failures))
            self.assertTrue(any("path-free" in f for f in failures))

    def test_rejects_foreign_receipt(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "receipt.json"
            path.write_text(json.dumps({"kind": "other", "formatVersion": 1}))
            with self.assertRaises(producer.ProducerError):
                producer.verify_receipt(path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
