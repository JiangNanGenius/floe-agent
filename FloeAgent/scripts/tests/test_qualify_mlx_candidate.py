"""Independent tests for the isolated MLX candidate diagnostic.

These tests drive the real ``qualify_mlx_candidate`` functions and CLI against
fixtures taken from the committed repository (``git show HEAD:...``). They never
resolve, build, download or touch the product ``Package.swift`` or any
``Package.resolved``; every write happens inside a temporary directory.
"""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT_DIR = Path(__file__).resolve().parents[1]
SCRIPT = SCRIPT_DIR / "qualify_mlx_candidate.py"
sys.path.insert(0, str(SCRIPT_DIR))

import qualify_mlx_candidate as qmc  # noqa: E402

PACKAGE_SWIFT = "FloeAgent/Package.swift"
LOCAL_INFERENCE_LOCK = "FloeAgent/Qualification/LocalInference/Package.resolved"


def git_show(path):
    return subprocess.check_output(
        ["git", "show", "HEAD:%s" % path], cwd=str(REPO_ROOT), text=True)


def current_package_swift():
    return git_show(PACKAGE_SWIFT)


def baseline_lock():
    return json.loads(git_show(LOCAL_INFERENCE_LOCK))


def candidate_lock():
    document = copy.deepcopy(baseline_lock())
    for identity, state in qmc.CANDIDATE_PINS.items():
        for pin in document["pins"]:
            if pin["identity"] == identity:
                pin["state"] = dict(state)
                break
        else:
            raise AssertionError("baseline lock missing %s" % identity)
    return document


def with_state(document, identity, state):
    changed = copy.deepcopy(document)
    for pin in changed["pins"]:
        if pin["identity"] == identity:
            pin["state"] = state
            return changed
    raise AssertionError("lock missing %s" % identity)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run_cli(*args):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        cwd=str(REPO_ROOT), text=True, capture_output=True)


class CandidatePatchTests(unittest.TestCase):
    def test_patch_is_exactly_two_declarations(self):
        original = current_package_swift()
        patched, changes = qmc.plan_candidate_patch(original)

        self.assertEqual(len(changes), 2)
        self.assertEqual({c["identity"] for c in changes}, set(qmc.TARGET_IDENTITIES))
        removed, added = qmc.line_changes(original, patched)
        self.assertEqual(len(removed), 2)
        self.assertEqual(len(added), 2)
        for identity, state in qmc.CANDIDATE_PINS.items():
            self.assertIn("%s: \"%s\"" % (next(iter(state)), state[next(iter(state))]), added)
        self.assertNotIn(qmc.CURRENT_PINS["mlx-swift-lm"]["revision"], patched)
        self.assertNotIn('exact: "0.31.4"', patched)

        # The original string is untouched, and the patched file presents the
        # candidate state to a read-only profile check.
        self.assertEqual(qmc.pin_state(qmc.find_target_declarations(original)["mlx-swift"][0]["block"]),
                         qmc.CURRENT_PINS["mlx-swift"])
        self.assertTrue(qmc.check_declarations("gpu-fix-candidate", patched)["ok"])

    def test_patch_rejects_mismatched_original(self):
        original = current_package_swift()
        corruptions = (
            ("mlx-swift-lm", qmc.CURRENT_PINS["mlx-swift-lm"]["revision"], "0" * 40),
            ("mlx-swift", '"0.31.4"', '"0.31.5"'),
        )
        for identity, old, new in corruptions:
            with self.subTest(identity=identity):
                corrupted = original.replace(old, new, 1)
                self.assertNotEqual(corrupted, original)
                with self.assertRaises(qmc.PatchError):
                    qmc.plan_candidate_patch(corrupted)

    def test_patch_rejects_missing_or_duplicate_declaration(self):
        original = current_package_swift()
        declarations = qmc.find_target_declarations(original)
        block = declarations["mlx-swift"][0]["block"]

        missing = original.replace(qmc.MLX_SWIFT_LM_URL, "https://example.org/not-mlx.git", 1)
        with self.assertRaises(qmc.PatchError):
            qmc.plan_candidate_patch(missing)

        duplicated = original + "\n" + block + "\n"
        with self.assertRaises(qmc.PatchError):
            qmc.plan_candidate_patch(duplicated)

    def test_patch_rejects_already_candidate(self):
        patched, _ = qmc.plan_candidate_patch(current_package_swift())
        with self.assertRaises(qmc.PatchError):
            qmc.plan_candidate_patch(patched)


class LockVerificationTests(unittest.TestCase):
    def test_candidate_profile_accepts_exact_target_revisions(self):
        report = qmc.verify_lock("gpu-fix-candidate", baseline_lock(), candidate_lock())
        self.assertTrue(report["ok"], report)
        self.assertEqual(report["drifted"], [])
        self.assertEqual(report["added"], [])
        self.assertEqual(report["removed"], [])
        self.assertEqual(report["targets"]["mlx-swift"]["revision"],
                         qmc.CANDIDATE_PINS["mlx-swift"]["revision"])
        self.assertEqual(report["targets"]["mlx-swift-lm"]["revision"],
                         qmc.CANDIDATE_PINS["mlx-swift-lm"]["revision"])

    def test_candidate_profile_rejects_wrong_target_revision(self):
        for identity in qmc.TARGET_IDENTITIES:
            with self.subTest(identity=identity):
                resolved = with_state(candidate_lock(), identity, {"revision": "f" * 40})
                report = qmc.verify_lock("gpu-fix-candidate", baseline_lock(), resolved)
                self.assertFalse(report["ok"], report)
                self.assertIn(identity, [d["identity"] for d in report["drifted"]])

    def test_candidate_profile_rejects_other_pin_drift(self):
        resolved = with_state(candidate_lock(), "swift-crypto", {"revision": "0" * 40})
        report = qmc.verify_lock("gpu-fix-candidate", baseline_lock(), resolved)
        self.assertFalse(report["ok"], report)
        self.assertIn("swift-crypto", [d["identity"] for d in report["drifted"]])

    def test_added_and_removed_pins_fail(self):
        added = candidate_lock()
        added["pins"].append({
            "identity": "candidate-extra",
            "kind": "remoteSourceControl",
            "location": "https://example.org/candidate-extra.git",
            "state": {"revision": "a" * 40},
        })
        report = qmc.verify_lock("gpu-fix-candidate", baseline_lock(), added)
        self.assertFalse(report["ok"], report)
        self.assertIn("candidate-extra", report["added"])

        removed = candidate_lock()
        removed["pins"] = [pin for pin in removed["pins"] if pin["identity"] != "swift-log"]
        report = qmc.verify_lock("gpu-fix-candidate", baseline_lock(), removed)
        self.assertFalse(report["ok"], report)
        self.assertIn("swift-log", report["removed"])

    def test_extra_state_on_target_fails(self):
        resolved = with_state(candidate_lock(), "mlx-swift",
                              {"revision": qmc.CANDIDATE_PINS["mlx-swift"]["revision"],
                               "version": "0.32.0"})
        report = qmc.verify_lock("gpu-fix-candidate", baseline_lock(), resolved)
        self.assertFalse(report["ok"], report)

    def test_current_profile_requires_identical_lock(self):
        report = qmc.verify_lock("current", baseline_lock(), baseline_lock())
        self.assertTrue(report["ok"], report)

        self.assertFalse(qmc.verify_lock("current", baseline_lock(), candidate_lock())["ok"])
        drifted = with_state(baseline_lock(), "swift-crypto", {"revision": "0" * 40})
        self.assertFalse(qmc.verify_lock("current", baseline_lock(), drifted)["ok"])

    def test_unknown_profile_and_missing_target_fail(self):
        with self.assertRaises(ValueError):
            qmc.verify_lock("unknown", baseline_lock(), baseline_lock())
        no_target = copy.deepcopy(baseline_lock())
        no_target["pins"] = [p for p in no_target["pins"] if p["identity"] != "mlx-swift"]
        with self.assertRaises(ValueError):
            qmc.verify_lock("gpu-fix-candidate", no_target, candidate_lock())


class CliTests(unittest.TestCase):
    def test_apply_failure_preserves_original_and_records_evidence(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            package = root / "Package.swift"
            corrupt = current_package_swift().replace(
                qmc.CURRENT_PINS["mlx-swift-lm"]["revision"], "0" * 40, 1)
            package.write_text(corrupt)
            before = sha256(package)

            result = run_cli(
                "apply-patch", "--package-swift", str(package),
                "--profile", "gpu-fix-candidate",
                "--diff", str(root / "candidate.diff"),
                "--manifest", str(root / "manifest.json"))

            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(sha256(package), before)
            self.assertFalse((root / "candidate.diff").exists())
            manifest = json.loads((root / "manifest.json").read_text())
            self.assertFalse(manifest["applied"])
            self.assertTrue(manifest["error"])

    def test_apply_rejects_current_profile_without_writing(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            package = root / "Package.swift"
            package.write_text(current_package_swift())
            before = sha256(package)

            result = run_cli(
                "apply-patch", "--package-swift", str(package),
                "--profile", "current",
                "--diff", str(root / "candidate.diff"),
                "--manifest", str(root / "manifest.json"))

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sha256(package), before)
            self.assertFalse((root / "candidate.diff").exists())

    def test_apply_success_is_scoped_and_never_touches_product(self):
        product = REPO_ROOT / PACKAGE_SWIFT
        product_before = sha256(product)
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            package = root / "Package.swift"
            package.write_text(current_package_swift())

            result = run_cli(
                "apply-patch", "--package-swift", str(package),
                "--profile", "gpu-fix-candidate",
                "--diff", str(root / "candidate.diff"),
                "--manifest", str(root / "manifest.json"))

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            patched = package.read_text()
            removed, added = qmc.line_changes(current_package_swift(), patched)
            self.assertEqual(len(removed), 2)
            self.assertEqual(len(added), 2)
            self.assertTrue(qmc.check_declarations("gpu-fix-candidate", patched)["ok"])
            diff = (root / "candidate.diff").read_text()
            self.assertIn("d5d8b290e601ac1bf11f24635f8f811a83b98bf8", diff)
            self.assertIn("ab924c82ead3b970caaa1c0ac11171de23f0305a", diff)
            manifest = json.loads((root / "manifest.json").read_text())
            self.assertTrue(manifest["applied"])
            self.assertEqual(manifest["changed_line_count"], 2)
        self.assertEqual(sha256(product), product_before)

    def test_verify_lock_check_is_read_only(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            baseline = root / "baseline.json"
            resolved = root / "resolved.json"
            baseline.write_text(json.dumps(baseline_lock()))
            resolved.write_text(json.dumps(baseline_lock()))
            before = {path.name: sha256(path) for path in root.iterdir()}

            result = run_cli(
                "verify-lock", "--check",
                "--profile", "current",
                "--baseline", str(baseline),
                "--resolved", str(resolved))

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertTrue(report["ok"], report)
            after = {path.name: sha256(path) for path in root.iterdir()}
            self.assertEqual(before, after)

    def test_verify_lock_check_rejects_drift_and_output_combination(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            baseline = root / "baseline.json"
            resolved = root / "resolved.json"
            baseline.write_text(json.dumps(baseline_lock()))
            resolved.write_text(json.dumps(with_state(
                baseline_lock(), "swift-crypto", {"revision": "0" * 40})))
            result = run_cli(
                "verify-lock", "--check",
                "--profile", "current",
                "--baseline", str(baseline),
                "--resolved", str(resolved))
            self.assertEqual(result.returncode, 1)
            self.assertFalse(json.loads(result.stdout)["ok"])

            combined = run_cli(
                "verify-lock", "--check",
                "--profile", "current",
                "--baseline", str(baseline),
                "--resolved", str(resolved),
                "--output", str(root / "evaluation.json"))
            self.assertNotEqual(combined.returncode, 0)
            self.assertFalse((root / "evaluation.json").exists())

    def test_check_is_read_only(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            package = root / "Package.swift"
            package.write_text(current_package_swift())
            before = sha256(package)

            result = run_cli("check", "--profile", "current", "--package-swift", str(package))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(json.loads(result.stdout)["ok"])
            self.assertEqual(sha256(package), before)

            candidate = run_cli("check", "--profile", "gpu-fix-candidate",
                                "--package-swift", str(package))
            self.assertEqual(candidate.returncode, 1)
            self.assertFalse(json.loads(candidate.stdout)["ok"])
            self.assertEqual(sha256(package), before)

    def test_check_accepts_patched_copy(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            package = root / "Package.swift"
            patched, _ = qmc.plan_candidate_patch(current_package_swift())
            package.write_text(patched)
            result = run_cli("check", "--profile", "gpu-fix-candidate",
                             "--package-swift", str(package))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(json.loads(result.stdout)["ok"])


class ApplicationPinTests(unittest.TestCase):
    def test_host_may_omit_exact_xcode_only_dependency(self):
        baseline = baseline_lock()
        resolved = candidate_lock()
        app = qmc.application_pins(git_show("FloeAgent/project.yml"))
        self.assertEqual({p["identity"] for p in app}, {"whisperkit"})
        resolved["pins"] = [p for p in resolved["pins"] if p["identity"] != "whisperkit"]
        self.assertFalse(qmc.verify_lock("gpu-fix-candidate", baseline, resolved)["ok"])
        result = qmc.verify_lock("gpu-fix-candidate", baseline, resolved, app)
        self.assertTrue(result["ok"])
        self.assertEqual(result["omitted_application_pins"], ["whisperkit"])
        resolved["pins"] = [p for p in resolved["pins"] if p["identity"] != "swift-crypto"]
        self.assertFalse(qmc.verify_lock("gpu-fix-candidate", baseline, resolved, app)["ok"])

    def test_application_pin_override_cannot_hide_drift(self):
        baseline = baseline_lock()
        app = qmc.application_pins(git_show("FloeAgent/project.yml"))
        app[0]["state"] = {"revision": "0" * 40}
        with self.assertRaises(ValueError):
            qmc.verify_lock("gpu-fix-candidate", baseline, candidate_lock(), app)


if __name__ == "__main__":
    unittest.main()
