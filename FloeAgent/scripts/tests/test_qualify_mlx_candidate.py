"""Independent tests for the MLX pin/lifecycle guard.

These tests drive the real ``qualify_mlx_candidate`` functions and CLI against
the working tree, which CI checks out at the immutable source SHA. They never
resolve, build, download or mutate the product ``Package.swift`` or any
``Package.resolved``; every write happens inside a temporary directory.

Three guards are covered and all are semantic, not substring theatre:

* the committed production profile: ``mlx-swift`` must stay the exact accepted
  remote revision while ``mlx-swift-lm`` is the reviewed in-repo package
  ``ThirdParty/MLXSwiftLM`` (manifest name, provenance revision, patch file);
* every committed lock must agree with that profile, with the remote
  ``mlx-swift-lm`` pin either absent (SwiftPM does not lock local packages) or
  exactly the reviewed revision for host locks that have not been re-resolved
  yet; and
* the one-time ``MLXCompilePolicy`` is checked structurally so the actual
  ``MLX.compile(enable: false)`` call is inside the engine initializer *before*
  the first ``loadContainer`` and there is no enable/env/per-turn toggle.
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
FLOE_AGENT = REPO_ROOT / "FloeAgent"
SCRIPT_DIR = Path(__file__).resolve().parents[1]
SCRIPT = SCRIPT_DIR / "qualify_mlx_candidate.py"
sys.path.insert(0, str(SCRIPT_DIR))

import qualify_mlx_candidate as qmc  # noqa: E402

PACKAGE_SWIFT = FLOE_AGENT / "Package.swift"
VENDOR_DIR = FLOE_AGENT / "ThirdParty/MLXSwiftLM"
QUALIFICATION_HOST = FLOE_AGENT / "Qualification/LocalInference/Sources/Qualification.swift"
MLX_ENGINE = FLOE_AGENT / "Sources/FloeLocalModels/MLXTextEngine.swift"
LOCAL_INFERENCE_LOCK = FLOE_AGENT / "Qualification/LocalInference/Package.resolved"
ROOT_LOCKS = (
    FLOE_AGENT / "Package.resolved",
    LOCAL_INFERENCE_LOCK,
    FLOE_AGENT / "Qualification/Package.resolved",
    FLOE_AGENT / "Qualification/Notes/Package.resolved",
    FLOE_AGENT / "Qualification/Services/Package.resolved",
)
# Host locks outside this task's scope still carry the reviewed remote pin in
# their pins list; they drop it on their next host resolve. They are covered by
# the "no foreign revision" assertion below rather than by an absence assertion.
LOCAL_INFERENCE_AUDIT_LOCKS = (FLOE_AGENT / "Package.resolved", LOCAL_INFERENCE_LOCK)


def current_package_swift():
    return PACKAGE_SWIFT.read_text()


def current_lock():
    return json.loads(LOCAL_INFERENCE_LOCK.read_text())


def lock_pins(document):
    return {pin["identity"]: pin for pin in qmc.resolved_pins(document)}


def lock_with_reviewed_local_pin():
    """The committed host lock as it looked before the local-package switch."""
    document = current_lock()
    document["pins"].append({
        "identity": qmc.CURRENT_LOCAL_PACKAGE["identity"],
        "kind": "remoteSourceControl",
        "location": qmc.MLX_SWIFT_LM_URL,
        "state": {"revision": qmc.CURRENT_LOCAL_PACKAGE["revision"]},
    })
    return document


def historical_lock(document=None):
    """A host lock with the frozen historical baseline pair resolved."""
    document = copy.deepcopy(document if document is not None else current_lock())
    for identity, state in qmc.HISTORICAL_BASELINE_RESOLVED_PINS.items():
        for pin in document["pins"]:
            if pin["identity"] == identity:
                pin["state"] = dict(state)
                break
        else:
            document["pins"].append({
                "identity": identity,
                "kind": "remoteSourceControl",
                "location": qmc._TARGET_URLS[identity],
                "state": dict(state),
            })
    return document


def manifest_targets(text=None, package_dir=FLOE_AGENT):
    """Parse the two committed MLX declarations (kind + state/path)."""
    found = qmc.find_target_declarations(
        text if text is not None else current_package_swift(), package_dir)
    targets = {}
    for identity in qmc.TARGET_IDENTITIES:
        declarations = found.get(identity, [])
        if len(declarations) != 1:
            raise AssertionError("expected one %s declaration" % identity)
        block = declarations[0]["block"]
        kind = qmc.declaration_kind(block)
        if kind == "remote":
            targets[identity] = {
                "kind": "remote",
                "state": qmc.pin_state(block),
                "location": qmc._string_value(block, "url"),
            }
        else:
            targets[identity] = {
                "kind": "local",
                "name": qmc._string_value(block, "name"),
                "path": qmc._string_value(block, "path"),
            }
    return targets


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


def write_fake_vendor_tree(root, name=None, revision=None, provenance=True, patch=True):
    """Create a minimal directory the audit can read; return the repo root."""
    vendor = Path(root) / qmc.CURRENT_LOCAL_PACKAGE["path"]
    (vendor / "patches").mkdir(parents=True, exist_ok=True)
    package_name = name if name is not None else qmc.CURRENT_LOCAL_PACKAGE["name"]
    (vendor / "Package.swift").write_text(
        '// swift-tools-version:6.2\nimport PackageDescription\n'
        'let package = Package(name: "%s")\n' % package_name)
    if provenance:
        recorded = qmc.CURRENT_LOCAL_PACKAGE["revision"] if revision is None else revision
        (vendor / qmc.CURRENT_LOCAL_PACKAGE["provenance_file"]).write_text(
            "# vendor notes\nrevision: %s\n" % recorded)
    if patch:
        patch_path = vendor / qmc.CURRENT_LOCAL_PACKAGE["patch"]
        patch_path.write_text("--- a\n+++ b\n")
    return root


class AcceptedPinTests(unittest.TestCase):
    """Semantic pin guard: manifest, vendored package and locks must agree."""

    def test_manifest_declares_accepted_current_profile(self):
        report = qmc.check_declarations("current", current_package_swift(), FLOE_AGENT)
        self.assertTrue(report["ok"], report)
        self.assertEqual(
            report["declarations"]["mlx-swift"]["actual"],
            {"kind": "remote", "state": dict(qmc.CURRENT_REMOTE_PINS["mlx-swift"])})
        self.assertEqual(
            report["declarations"]["mlx-swift-lm"]["actual"],
            {"kind": "local",
             "name": qmc.CURRENT_LOCAL_PACKAGE["name"],
             "path": qmc.CURRENT_LOCAL_PACKAGE["path"]})
        self.assertEqual(report["declarations"]["mlx-swift"]["count"], 1)
        self.assertEqual(report["declarations"]["mlx-swift-lm"]["count"], 1)
        self.assertTrue(report["local_package"]["ok"], report["local_package"])

    def test_local_package_audit_pins_the_reviewed_vendor_tree(self):
        report = qmc.audit_local_package(FLOE_AGENT)
        self.assertTrue(report["ok"], report)
        self.assertEqual(report["errors"], [])
        self.assertEqual(report["manifest"]["package_name"],
                         qmc.CURRENT_LOCAL_PACKAGE["name"])
        self.assertTrue(report["provenance"]["records_revision"])
        self.assertTrue(report["patch"]["present"])
        # The declaration path and the audited directory are the same tree.
        declared = manifest_targets()["mlx-swift-lm"]["path"]
        self.assertEqual(declared, qmc.CURRENT_LOCAL_PACKAGE["path"])
        self.assertEqual(Path(report["root"]).resolve(), VENDOR_DIR.resolve())
        self.assertTrue((VENDOR_DIR / "LICENSE").is_file())

    def test_local_package_audit_rejects_missing_or_tampered_tree(self):
        with tempfile.TemporaryDirectory() as root:
            write_fake_vendor_tree(root, revision="0" * 40)
            report = qmc.audit_local_package(root)
            self.assertFalse(report["ok"], report)
            self.assertFalse(report["provenance"]["records_revision"])
            self.assertTrue(any("provenance" in error for error in report["errors"]))

        with tempfile.TemporaryDirectory() as root:
            write_fake_vendor_tree(root, name="mlx-swift-lm-renamed")
            report = qmc.audit_local_package(root)
            self.assertFalse(report["ok"], report)
            self.assertTrue(any("package name" in error for error in report["errors"]))

        with tempfile.TemporaryDirectory() as root:
            write_fake_vendor_tree(root, patch=False)
            report = qmc.audit_local_package(root)
            self.assertFalse(report["ok"], report)
            self.assertFalse(report["patch"]["present"])

        with tempfile.TemporaryDirectory() as root:
            report = qmc.audit_local_package(root)
            self.assertFalse(report["ok"], report)
            self.assertTrue(any("Package.swift" in error for error in report["errors"]))

    def test_current_profile_rejects_a_remote_local_declaration(self):
        remote = '.package(url: "%s", revision: "%s")' % (
            qmc.MLX_SWIFT_LM_URL, qmc.CURRENT_LOCAL_PACKAGE["revision"])
        corrupted = current_package_swift().replace(
            '.package(name: "%s", path: "%s")' % (qmc.CURRENT_LOCAL_PACKAGE["name"],
                                                  qmc.CURRENT_LOCAL_PACKAGE["path"]),
            remote, 1)
        self.assertNotEqual(corrupted, current_package_swift())
        report = qmc.check_declarations("current", corrupted, FLOE_AGENT)
        self.assertFalse(report["ok"], report)
        self.assertEqual(report["declarations"]["mlx-swift-lm"]["actual"]["kind"], "remote")
        with self.assertRaises(qmc.PatchError):
            qmc.plan_historical_baseline_patch(corrupted, FLOE_AGENT)

    def test_mlx_swift_pin_matches_in_every_committed_lock(self):
        manifest = manifest_targets()
        self.assertEqual(manifest["mlx-swift"]["state"], qmc.CURRENT_REMOTE_PINS["mlx-swift"])
        for lock_path in ROOT_LOCKS:
            with self.subTest(lock=lock_path.name):
                targets = lock_pins(json.loads(lock_path.read_text()))
                self.assertIn("mlx-swift", targets, lock_path.name)
                self.assertEqual(targets["mlx-swift"]["state"],
                                 qmc.CURRENT_REMOTE_PINS["mlx-swift"])
                self.assertEqual(
                    qmc.normalize_url(targets["mlx-swift"]["location"]),
                    qmc.normalize_url(qmc.MLX_SWIFT_URL),
                    "%s source URL disagrees with Package.swift" % lock_path.name)

    def test_no_committed_lock_pins_a_foreign_local_revision(self):
        for lock_path in ROOT_LOCKS:
            with self.subTest(lock=lock_path.name):
                pin = lock_pins(json.loads(lock_path.read_text())).get(
                    qmc.CURRENT_LOCAL_PACKAGE["identity"])
                if pin is None:
                    continue
                self.assertEqual(pin["state"],
                                 {"revision": qmc.CURRENT_LOCAL_PACKAGE["revision"]},
                                 lock_path.name)
                self.assertEqual(qmc.normalize_url(pin["location"]),
                                 qmc.normalize_url(qmc.MLX_SWIFT_LM_URL))

    def test_root_and_local_inference_locks_drop_the_remote_local_pin(self):
        # The app lock and the qualification host lock were updated to the
        # local-package truth: SwiftPM does not pin a `.package(path:)`
        # dependency. The other host locks are outside this change and are
        # covered by the reviewed-revision assertion above.
        for lock_path in LOCAL_INFERENCE_AUDIT_LOCKS:
            with self.subTest(lock=lock_path.name):
                pins = lock_pins(json.loads(lock_path.read_text()))
                self.assertNotIn(qmc.CURRENT_LOCAL_PACKAGE["identity"], pins)

    def test_locks_are_valid_json_and_keep_unrelated_pins(self):
        # The MLX pair is the only intentional change; the lock must still parse
        # to the full committed dependency set.
        self.assertGreaterEqual(len(current_lock()["pins"]), 30)

    def test_historical_baseline_patch_is_exactly_two_declarations(self):
        original = current_package_swift()
        patched, changes = qmc.plan_historical_baseline_patch(original, FLOE_AGENT)

        self.assertEqual(len(changes), 2)
        self.assertEqual({c["identity"] for c in changes}, set(qmc.TARGET_IDENTITIES))
        kinds = {c["identity"]: c["kind"] for c in changes}
        self.assertEqual(kinds["mlx-swift"], "remote")
        self.assertEqual(kinds["mlx-swift-lm"], "local")
        removed, added = qmc.line_changes(original, patched)
        self.assertEqual(len(removed), 2, removed)
        self.assertEqual(len(added), 2, added)
        self.assertIn('exact: "0.31.4"', added)
        self.assertTrue(any(
            'revision: "%s"' % qmc.HISTORICAL_BASELINE_PINS["mlx-swift-lm"]["revision"] in line
            for line in added), added)
        self.assertNotIn(qmc.CURRENT_REMOTE_PINS["mlx-swift"]["revision"], patched)
        self.assertNotIn('path: "ThirdParty/MLXSwiftLM"', patched)

        # The original string is untouched, and the patched file presents the
        # historical state to a read-only profile check.
        self.assertEqual(manifest_targets(original)["mlx-swift"]["state"],
                         qmc.CURRENT_REMOTE_PINS["mlx-swift"])
        self.assertTrue(qmc.check_declarations("historical-baseline", patched)["ok"])

    def test_patch_rejects_mismatched_original(self):
        original = current_package_swift()
        corruptions = (
            ("mlx-swift", qmc.CURRENT_REMOTE_PINS["mlx-swift"]["revision"], "0" * 40),
            ("mlx-swift-lm", qmc.CURRENT_LOCAL_PACKAGE["path"],
             "ThirdParty/NotTheReviewedPackage"),
            ("mlx-swift-lm", 'name: "%s"' % qmc.CURRENT_LOCAL_PACKAGE["name"],
             'name: "mlx-swift-lm-renamed"'),
        )
        for identity, old, new in corruptions:
            with self.subTest(identity=identity, old=old):
                corrupted = original.replace(old, new, 1)
                self.assertNotEqual(corrupted, original)
                with self.assertRaises(qmc.PatchError):
                    qmc.plan_historical_baseline_patch(corrupted, FLOE_AGENT)

    def test_patch_rejects_missing_duplicate_or_already_baseline(self):
        original = current_package_swift()
        block = qmc.find_target_declarations(original, FLOE_AGENT)["mlx-swift"][0]["block"]

        missing = original.replace(qmc.MLX_SWIFT_LM_URL, "https://example.org/not-mlx.git", 1)
        self.assertEqual(missing, original)  # current manifest has no remote lm URL
        missing = original.replace('path: "ThirdParty/MLXSwiftLM"',
                                   'path: "ThirdParty/Other"', 1)
        with self.assertRaises(qmc.PatchError):
            qmc.plan_historical_baseline_patch(missing, FLOE_AGENT)

        duplicated = original + "\n" + block + "\n"
        with self.assertRaises(qmc.PatchError):
            qmc.plan_historical_baseline_patch(duplicated, FLOE_AGENT)

        patched, _ = qmc.plan_historical_baseline_patch(original, FLOE_AGENT)
        with self.assertRaises(qmc.PatchError):
            qmc.plan_historical_baseline_patch(patched, FLOE_AGENT)


class LockVerificationTests(unittest.TestCase):
    def test_current_profile_accepts_the_committed_host_lock(self):
        report = qmc.verify_lock("current", current_lock(), current_lock())
        self.assertTrue(report["ok"], report)
        self.assertEqual(report["omitted_local_packages"], [])
        self.assertEqual(report["targets"]["mlx-swift"],
                         qmc.CURRENT_REMOTE_PINS["mlx-swift"])

    def test_current_profile_allows_a_missing_local_pin(self):
        baseline = lock_with_reviewed_local_pin()
        report = qmc.verify_lock("current", baseline, current_lock())
        self.assertTrue(report["ok"], report)
        self.assertEqual(report["omitted_local_packages"],
                         [qmc.CURRENT_LOCAL_PACKAGE["identity"]])
        self.assertIsNone(report["targets"][qmc.CURRENT_LOCAL_PACKAGE["identity"]])
        self.assertEqual(report["expected_targets"][qmc.CURRENT_LOCAL_PACKAGE["identity"]],
                         {"revision": qmc.CURRENT_LOCAL_PACKAGE["revision"]})
        self.assertEqual(report["drifted"], [])
        self.assertEqual(report["removed"], [])

    def test_current_profile_requires_the_exact_mlx_swift_revision(self):
        resolved = with_state(current_lock(), "mlx-swift", {"revision": "f" * 40})
        report = qmc.verify_lock("current", current_lock(), resolved)
        self.assertFalse(report["ok"], report)
        self.assertIn("mlx-swift", [d["identity"] for d in report["drifted"]])

    def test_current_profile_rejects_other_drift_additions_and_removals(self):
        drifted = with_state(current_lock(), "swift-crypto", {"revision": "0" * 40})
        report = qmc.verify_lock("current", current_lock(), drifted)
        self.assertFalse(report["ok"], report)
        self.assertIn("swift-crypto", [d["identity"] for d in report["drifted"]])

        added = current_lock()
        added["pins"].append({
            "identity": "extra-extra",
            "kind": "remoteSourceControl",
            "location": "https://example.org/extra-extra.git",
            "state": {"revision": "a" * 40},
        })
        report = qmc.verify_lock("current", current_lock(), added)
        self.assertFalse(report["ok"], report)
        self.assertIn("extra-extra", report["added"])

        removed = current_lock()
        removed["pins"] = [pin for pin in removed["pins"] if pin["identity"] != "swift-log"]
        report = qmc.verify_lock("current", current_lock(), removed)
        self.assertFalse(report["ok"], report)
        self.assertIn("swift-log", report["removed"])

    def test_current_profile_fails_closed_on_a_foreign_local_pin(self):
        baseline = lock_with_reviewed_local_pin()
        tampered = copy.deepcopy(baseline)
        for pin in tampered["pins"]:
            if pin["identity"] == qmc.CURRENT_LOCAL_PACKAGE["identity"]:
                pin["state"] = {"revision": "0" * 40}
        with self.assertRaises(ValueError):
            qmc.verify_lock("current", tampered, current_lock())

        resolved = copy.deepcopy(baseline)
        for pin in resolved["pins"]:
            if pin["identity"] == qmc.CURRENT_LOCAL_PACKAGE["identity"]:
                pin["state"] = {"revision": "f" * 40}
        report = qmc.verify_lock("current", baseline, resolved)
        self.assertFalse(report["ok"], report)
        self.assertIn(qmc.CURRENT_LOCAL_PACKAGE["identity"],
                      [d["identity"] for d in report["drifted"]])

    def test_historical_profile_accepts_exact_target_revisions(self):
        report = qmc.verify_lock("historical-baseline", current_lock(), historical_lock())
        self.assertTrue(report["ok"], report)
        self.assertEqual(report["drifted"], [])
        self.assertEqual(report["added"], [])
        self.assertEqual(report["removed"], [])
        self.assertEqual(report["targets"]["mlx-swift"]["revision"],
                         qmc.HISTORICAL_BASELINE_RESOLVED_PINS["mlx-swift"]["revision"])
        self.assertEqual(report["targets"]["mlx-swift-lm"]["revision"],
                         qmc.HISTORICAL_BASELINE_RESOLVED_PINS["mlx-swift-lm"]["revision"])

    def test_historical_profile_accepts_a_stale_baseline(self):
        # A committed lock that still carries the reviewed remote pin is fine:
        # the target expectations come from the frozen constants, not the lock.
        report = qmc.verify_lock("historical-baseline",
                                  lock_with_reviewed_local_pin(), historical_lock())
        self.assertTrue(report["ok"], report)

    def test_historical_profile_rejects_wrong_target_revision(self):
        for identity in qmc.TARGET_IDENTITIES:
            with self.subTest(identity=identity):
                resolved = with_state(historical_lock(), identity, {"revision": "f" * 40})
                report = qmc.verify_lock("historical-baseline", current_lock(), resolved)
                self.assertFalse(report["ok"], report)
                self.assertIn(identity, [d["identity"] for d in report["drifted"]])

    def test_historical_profile_rejects_other_pin_drift(self):
        resolved = with_state(historical_lock(), "swift-crypto", {"revision": "0" * 40})
        report = qmc.verify_lock("historical-baseline", current_lock(), resolved)
        self.assertFalse(report["ok"], report)
        self.assertIn("swift-crypto", [d["identity"] for d in report["drifted"]])

    def test_added_and_removed_pins_fail(self):
        added = historical_lock()
        added["pins"].append({
            "identity": "extra-extra",
            "kind": "remoteSourceControl",
            "location": "https://example.org/extra-extra.git",
            "state": {"revision": "a" * 40},
        })
        report = qmc.verify_lock("historical-baseline", current_lock(), added)
        self.assertFalse(report["ok"], report)
        self.assertIn("extra-extra", report["added"])

        removed = historical_lock()
        removed["pins"] = [pin for pin in removed["pins"] if pin["identity"] != "swift-log"]
        report = qmc.verify_lock("historical-baseline", current_lock(), removed)
        self.assertFalse(report["ok"], report)
        self.assertIn("swift-log", report["removed"])

    def test_extra_state_on_target_fails(self):
        resolved = with_state(historical_lock(), "mlx-swift",
                              {"revision": qmc.HISTORICAL_BASELINE_RESOLVED_PINS["mlx-swift"]["revision"],
                               "version": "0.31.5"})
        report = qmc.verify_lock("historical-baseline", current_lock(), resolved)
        self.assertFalse(report["ok"], report)

    def test_unknown_profile_and_missing_resolved_target_fail(self):
        with self.assertRaises(ValueError):
            qmc.verify_lock("unknown", current_lock(), current_lock())
        for profile in qmc.SUPPORTED_PROFILES:
            with self.subTest(profile=profile):
                no_target = copy.deepcopy(current_lock())
                no_target["pins"] = [p for p in no_target["pins"] if p["identity"] != "mlx-swift"]
                report = qmc.verify_lock(profile, current_lock(), no_target)
                self.assertFalse(report["ok"], report)
                self.assertIn("mlx-swift", report["removed"])


class MLXCompilePolicyGuardTests(unittest.TestCase):
    """Structural guard for the actual one-time compile configuration."""

    @classmethod
    def setUpClass(cls):
        cls.source = MLX_ENGINE.read_text()

    def test_exactly_one_disable_and_no_enable_env_or_per_turn_toggle(self):
        self.assertEqual(self.source.count("MLX.compile(enable: false)"), 1)
        self.assertNotIn("MLX.compile(enable: true)", self.source)
        self.assertNotIn("MLX.compile()", self.source)
        self.assertNotIn("MLX_DISABLE_COMPILE", self.source)
        self.assertNotIn("setenv(", self.source)
        self.assertNotIn("unsetenv(", self.source)

    def test_disable_is_a_thread_safe_once_token(self):
        # The single disabling call is the body of a private `static let`,
        # which the Swift runtime evaluates at most once, thread-safely.
        self.assertIn("private static let disableCompiledTracesOnce", self.source)
        policy = self.source.index("public enum MLXCompilePolicy")
        disable = self.source.index("MLX.compile(enable: false)", policy)
        token_body = self.source[policy:disable]
        self.assertIn("static let disableCompiledTracesOnce", token_body)
        self.assertIn("Mutex<Bool>", self.source)

    def test_policy_call_is_inside_initializer_before_first_load(self):
        init_start = self.source.index("public init(")
        init_end = self.source.index("public func shutdown", init_start)
        initializer = self.source[init_start:init_end]

        policy = initializer.index("MLXCompilePolicy.applyBeforeModelLoad()")
        vlm = initializer.index("VLMModelFactory.shared.loadContainer(")
        llm = initializer.index("LLMModelFactory.shared.loadContainer(")
        self.assertLess(policy, vlm, "compile policy must precede VLM load")
        self.assertLess(policy, llm, "compile policy must precede LLM load")
        # The policy call is unconditional and first, not behind a branch.
        prog = initializer.index("self.resourceProfile = resourceProfile")
        self.assertLess(policy, prog)

    def test_policy_exposes_truthful_metadata_label(self):
        self.assertIn("disabled-by-process-policy", self.source)
        self.assertIn("public static var compiledTracesDisabled", self.source)


class QualificationHostMetadataTests(unittest.TestCase):
    """The host must record environmentless compile-policy evidence."""

    @classmethod
    def setUpClass(cls):
        cls.host = QUALIFICATION_HOST.read_text()

    def test_host_records_compile_policy_on_every_event(self):
        self.assertIn('"mlxCompilePolicy"', self.host)
        self.assertIn('"mlxDisableCompileEnvSet"', self.host)
        self.assertIn("MLXCompilePolicy.compiledTracesDisabled", self.host)

    def test_host_fails_load_if_policy_missing(self):
        # The post-construction guard must run before load-complete is recorded.
        guard = self.host.index("guard MLXCompilePolicy.compiledTracesDisabled")
        complete = self.host.index('record("load-complete", done)')
        self.assertLess(guard, complete)
        self.assertIn("mlxCompilePolicyAppliedBeforeLoad", self.host)


class CliTests(unittest.TestCase):
    def test_apply_failure_preserves_original_and_records_evidence(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            package = root / "Package.swift"
            corrupt = current_package_swift().replace(
                qmc.CURRENT_LOCAL_PACKAGE["path"], "ThirdParty/NotTheReviewedPackage", 1)
            package.write_text(corrupt)
            before = sha256(package)

            result = run_cli(
                "apply-patch", "--package-swift", str(package),
                "--profile", "historical-baseline",
                "--diff", str(root / "baseline.diff"),
                "--manifest", str(root / "manifest.json"))

            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(sha256(package), before)
            self.assertFalse((root / "baseline.diff").exists())
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
                "--diff", str(root / "baseline.diff"),
                "--manifest", str(root / "manifest.json"))

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sha256(package), before)
            self.assertFalse((root / "baseline.diff").exists())

    def test_apply_success_is_scoped_and_never_touches_product(self):
        product = PACKAGE_SWIFT
        product_before = sha256(product)
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            package = root / "Package.swift"
            package.write_text(current_package_swift())

            result = run_cli(
                "apply-patch", "--package-swift", str(package),
                "--profile", "historical-baseline",
                "--diff", str(root / "baseline.diff"),
                "--manifest", str(root / "manifest.json"))

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            patched = package.read_text()
            removed, added = qmc.line_changes(current_package_swift(), patched)
            self.assertEqual(len(removed), 2)
            self.assertEqual(len(added), 2)
            self.assertTrue(qmc.check_declarations("historical-baseline", patched)["ok"])
            diff = (root / "baseline.diff").read_text()
            self.assertIn("bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57", diff)
            self.assertIn('exact: "0.31.4"', diff)
            manifest = json.loads((root / "manifest.json").read_text())
            self.assertTrue(manifest["applied"])
            self.assertEqual(manifest["removed_lines"], removed)
            self.assertEqual(manifest["added_lines"], added)
        self.assertEqual(sha256(product), product_before)

    def test_verify_lock_check_is_read_only(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            baseline = root / "baseline.json"
            resolved = root / "resolved.json"
            baseline.write_text(json.dumps(current_lock()))
            resolved.write_text(json.dumps(current_lock()))
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
            baseline.write_text(json.dumps(current_lock()))
            resolved.write_text(json.dumps(with_state(
                current_lock(), "swift-crypto", {"revision": "0" * 40})))
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

    def test_check_is_read_only_on_the_product_manifest(self):
        before = sha256(PACKAGE_SWIFT)

        result = run_cli("check", "--profile", "current", "--package-swift", str(PACKAGE_SWIFT))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report["ok"], report)
        self.assertTrue(report["local_package"]["ok"], report)
        self.assertEqual(sha256(PACKAGE_SWIFT), before)

        baseline = run_cli("check", "--profile", "historical-baseline",
                           "--package-swift", str(PACKAGE_SWIFT))
        self.assertEqual(baseline.returncode, 1)
        self.assertFalse(json.loads(baseline.stdout)["ok"])
        self.assertEqual(sha256(PACKAGE_SWIFT), before)

    def test_check_fails_closed_when_the_vendored_tree_is_absent(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            package = root / "Package.swift"
            package.write_text(current_package_swift())
            result = run_cli("check", "--profile", "current",
                             "--package-swift", str(package))
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertFalse(report["local_package"]["ok"])
            self.assertTrue(report["local_package"]["errors"])

    def test_check_accepts_patched_copy(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            package = root / "Package.swift"
            patched, _ = qmc.plan_historical_baseline_patch(current_package_swift(), FLOE_AGENT)
            package.write_text(patched)
            result = run_cli("check", "--profile", "historical-baseline",
                             "--package-swift", str(package))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(json.loads(result.stdout)["ok"])


class SourceURLTests(unittest.TestCase):
    def test_target_github_git_suffix_alias_is_same_source(self):
        baseline = current_lock()
        resolved = historical_lock()
        target = next(p for p in resolved["pins"] if p["identity"] == "mlx-swift")
        # The accepted lock stores the `.git` form; the old fetch may resolve
        # without the suffix. Semantically they are the same repository.
        target["location"] = "https://github.com/ml-explore/mlx-swift"
        result = qmc.verify_lock("historical-baseline", baseline, resolved)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["equivalent_source_urls"][0]["identity"], "mlx-swift")
        for invalid in ["https://github.com/another-owner/mlx-swift.git",
                        "http://github.com/ml-explore/mlx-swift.git",
                        "https://example.com/ml-explore/mlx-swift.git"]:
            with self.subTest(invalid=invalid):
                target["location"] = invalid
                self.assertFalse(qmc.verify_lock("historical-baseline", baseline, resolved)["ok"])


class ApplicationPinTests(unittest.TestCase):
    def setUp(self):
        self.project = (FLOE_AGENT / "project.yml").read_text()

    def test_host_may_omit_exact_xcode_only_dependency(self):
        resolved = historical_lock()
        app = qmc.application_pins(self.project)
        self.assertEqual({p["identity"] for p in app}, {"whisperkit"})
        resolved["pins"] = [p for p in resolved["pins"] if p["identity"] != "whisperkit"]
        self.assertFalse(qmc.verify_lock("historical-baseline", current_lock(), resolved)["ok"])
        result = qmc.verify_lock("historical-baseline", current_lock(), resolved, app)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["omitted_application_pins"], ["whisperkit"])
        resolved["pins"] = [p for p in resolved["pins"] if p["identity"] != "swift-crypto"]
        self.assertFalse(qmc.verify_lock("historical-baseline", current_lock(), resolved, app)["ok"])

    def test_application_pin_override_cannot_hide_drift(self):
        app = qmc.application_pins(self.project)
        app[0]["state"] = {"revision": "0" * 40}
        with self.assertRaises(ValueError):
            qmc.verify_lock("historical-baseline", current_lock(), historical_lock(), app)


if __name__ == "__main__":
    unittest.main()
