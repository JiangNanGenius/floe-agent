"""Selector truth table and lean default for the supplementary CI workflow.

Two layers are checked:

* the accepted selector semantics in ``scripts/ci_scope.py`` (one top-level
  mode per dispatch, palette modifiers require feedback_ui, push/PR never
  carries selectors, ``full`` expands to the historical three-job matrix,
  selector-free runs are lean);
* the real ``.github/workflows/ci.yml`` job conditions, evaluated against the
  full cross product of events and selector subsets with a small parser for
  the boolean subset of GitHub expressions the workflow uses.  A drifted job
  condition fails here instead of silently running or dropping a lane.

The lean job must stay read-only and portable: it may run only the selected
pin/asset/license/localization/native-runtime/diagnostic-contract checks and
the secret scan, never xcodebuild/swift/simctl/bootstrap/package resolution.
"""
from __future__ import annotations

import itertools
import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
WORKFLOW = ROOT.parent / ".github" / "workflows" / "ci.yml"
sys.path.insert(0, str(SCRIPTS))
import ci_scope  # noqa: E402


# --------------------------------------------------------------------------
# Approved truth table (the independent specification the workflow must meet)
# --------------------------------------------------------------------------

def expected_condition(job, event, combo):
    """What each ci.yml job condition must evaluate to for one combination."""
    modes = [mode for mode in ci_scope.MODES if mode in combo]
    modifiers = [name for name in ci_scope.MODIFIERS if name in combo]
    mode = modes[0] if modes else None
    if job == "validate-selectors":
        return event == "workflow_dispatch"
    if job == "lean-checks":
        return not modes and not modifiers
    if event != "workflow_dispatch":
        return False
    return {
        "live-agent-demo": mode == "live_agent_demo",
        "local-inference": mode == "local_inference",
        "feedback-ui": mode == "feedback_ui",
        "publish-skill-hub": mode == "publish_skill_hub",
        "build-test": mode in ("full", "build_test_only", "ide_only"),
        "appstore-sdk-compatibility": mode == "full",
        "spm-linux-build": mode == "full",
    }[job]


def expected_raw_condition(job, event, combo):
    """The lane's own condition, ignoring the validate-selectors needs gate."""
    if job == "validate-selectors":
        return event == "workflow_dispatch"
    if job == "lean-checks":
        return not combo
    if event != "workflow_dispatch":
        return False
    return {
        "live-agent-demo": "live_agent_demo" in combo,
        "local-inference": "local_inference" in combo,
        "feedback-ui": "feedback_ui" in combo,
        "publish-skill-hub": "publish_skill_hub" in combo,
        "build-test": bool({"full", "build_test_only", "ide_only"} & combo),
        "appstore-sdk-compatibility": "full" in combo,
        "spm-linux-build": "full" in combo,
    }[job]


def expected_valid(event, selectors):
    """The declared conflict rules, written directly from the contract."""
    modes = ci_scope.selected_modes(selectors)
    modifiers = ci_scope.selected_modifiers(selectors)
    if event != "workflow_dispatch" and (modes or modifiers):
        return False
    if len(modes) > 1:
        return False
    for modifier in modifiers:
        if ci_scope.MODIFIERS[modifier] not in modes:
            return False
    return True


def all_selector_subsets():
    for size in range(len(ci_scope.ALL_SELECTORS) + 1):
        for combo in itertools.combinations(ci_scope.ALL_SELECTORS, size):
            yield frozenset(combo)


# --------------------------------------------------------------------------
# Minimal GitHub expression evaluator for the job conditions in ci.yml
# --------------------------------------------------------------------------

class ConditionEvaluator:
    TOKEN = re.compile(r"\s*(==|!=|&&|\|\||[()!]|'[^']*'|[A-Za-z_][A-Za-z0-9_.]*)")

    def __init__(self, expression, *, event, true_inputs):
        text = expression.strip()
        if text.startswith("${{") and text.endswith("}}"):
            text = text[3:-2].strip()
        self.tokens = self._tokenize(text)
        self.position = 0
        self.event = event
        self.true_inputs = set(true_inputs)

    @classmethod
    def _tokenize(cls, text):
        tokens = []
        position = 0
        while position < len(text):
            match = cls.TOKEN.match(text, position)
            if not match:
                raise ValueError(f"unsupported condition text: {text[position:]!r}")
            tokens.append(match.group(1))
            position = match.end()
        return tokens

    def evaluate(self):
        value = self._parse_or()
        if self.position != len(self.tokens):
            raise ValueError(f"unconsumed condition tokens: {self.tokens[self.position:]}")
        return bool(value)

    def _peek(self):
        return self.tokens[self.position] if self.position < len(self.tokens) else None

    def _next(self):
        token = self._peek()
        if token is None:
            raise ValueError("unexpected end of condition")
        self.position += 1
        return token

    def _accept(self, token):
        if self._peek() == token:
            self.position += 1
            return True
        return False

    def _expect(self, token):
        actual = self._next()
        if actual != token:
            raise ValueError(f"expected {token!r}, got {actual!r}")
        return actual

    def _parse_or(self):
        value = self._parse_and()
        while self._accept("||"):
            value = self._parse_and() or value
        return value

    def _parse_and(self):
        value = self._parse_unary()
        while self._accept("&&"):
            value = self._parse_unary() and value
        return value

    def _parse_unary(self):
        if self._accept("!"):
            return not self._parse_unary()
        if self._accept("("):
            value = self._parse_or()
            self._expect(")")
            return value
        token = self._next()
        if token == "github.event_name":
            operator = self._next()
            if operator not in ("==", "!="):
                raise ValueError(f"unsupported event comparison {operator!r}")
            literal = self._next()
            if not (literal.startswith("'") and literal.endswith("'")):
                raise ValueError(f"event name must be single-quoted, got {literal!r}")
            matches = self.event == literal[1:-1]
            return matches if operator == "==" else not matches
        if token.startswith("inputs."):
            return token.split(".", 1)[1] in self.true_inputs
        raise ValueError(f"unsupported condition token {token!r}")


JOB_LINE = re.compile(r"^  ([a-z0-9-]+):\n", re.MULTILINE)
JOB_IF = re.compile(r"^    if: (.+)$", re.MULTILINE)


def job_blocks(source):
    matches = list(JOB_LINE.finditer(source))
    blocks = {}
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(source)
        blocks[match.group(1)] = source[match.start():end]
    return blocks


def strip_comments(text):
    """Drop comment lines so prose between jobs cannot trip token checks."""
    return "\n".join(line for line in text.splitlines()
                     if not line.lstrip().startswith("#"))


def dispatch_input_block(source, name):
    dispatch = source.split("  workflow_dispatch:", 1)[1].split("\n  push:", 1)[0]
    match = re.search(rf"(?ms)^      {re.escape(name)}:\n(.*?)(?=^      \S|\Z)", dispatch)
    return match.group(0) if match else None


def job_condition(block):
    match = JOB_IF.search(block)
    return match.group(1).strip() if match else None


# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------

class SelectorTruthTableTests(unittest.TestCase):
    def test_validation_matches_the_declared_conflict_rules(self):
        for event in ci_scope.EVENTS:
            for combo in all_selector_subsets():
                selectors = {name: True for name in combo}
                problems = ci_scope.validate(event, selectors)
                valid = expected_valid(event, selectors)
                self.assertEqual(not problems, valid,
                                 f"{event} {sorted(combo)} -> {problems}")
                if valid:
                    scope = ci_scope.scope(event, selectors)
                    expected_jobs = {job: expected_condition(job, event, selectors)
                                     for job in ci_scope.JOBS}
                    self.assertEqual(scope["jobs"], expected_jobs,
                                     f"{event} {sorted(combo)}")
                    self.assertEqual(scope["lean"], expected_jobs["lean-checks"])
                    self.assertEqual(scope["full"], "full" in combo)
                else:
                    with self.assertRaises(ValueError):
                        ci_scope.scope(event, selectors)

    def test_representative_selector_rows(self):
        # push/PR, manual default, manual full, every special mode and the
        # conflict rows that must be rejected before any heavy/paid/write work.
        rows = (
            ("push", frozenset(), True, frozenset({"lean-checks"})),
            ("pull_request", frozenset(), True, frozenset({"lean-checks"})),
            ("workflow_dispatch", frozenset(), True, frozenset({"lean-checks"})),
            ("workflow_dispatch", frozenset({"full"}), True,
             frozenset({"build-test", "appstore-sdk-compatibility", "spm-linux-build"})),
            ("workflow_dispatch", frozenset({"build_test_only"}), True,
             frozenset({"build-test"})),
            ("workflow_dispatch", frozenset({"ide_only"}), True, frozenset({"build-test"})),
            ("workflow_dispatch", frozenset({"live_agent_demo"}), True,
             frozenset({"live-agent-demo"})),
            ("workflow_dispatch", frozenset({"local_inference"}), True,
             frozenset({"local-inference"})),
            ("workflow_dispatch", frozenset({"feedback_ui"}), True,
             frozenset({"feedback-ui"})),
            ("workflow_dispatch", frozenset({"feedback_ui", "palette_only"}), True,
             frozenset({"feedback-ui"})),
            ("workflow_dispatch", frozenset({"feedback_ui", "palette_unit_only"}), True,
             frozenset({"feedback-ui"})),
            ("workflow_dispatch", frozenset({"publish_skill_hub"}), True,
             frozenset({"publish-skill-hub"})),
            ("workflow_dispatch", frozenset({"full", "ide_only"}), False, frozenset()),
            ("workflow_dispatch", frozenset({"full", "publish_skill_hub"}), False,
             frozenset()),
            ("workflow_dispatch", frozenset({"full", "build_test_only"}), False,
             frozenset()),
            ("workflow_dispatch", frozenset({"full", "live_agent_demo"}), False,
             frozenset()),
            ("workflow_dispatch", frozenset({"full", "feedback_ui"}), False, frozenset()),
            ("workflow_dispatch", frozenset({"feedback_ui", "local_inference"}), False,
             frozenset()),
            ("workflow_dispatch", frozenset({"live_agent_demo", "ide_only"}), False,
             frozenset()),
            ("workflow_dispatch", frozenset({"palette_only"}), False, frozenset()),
            ("workflow_dispatch", frozenset({"palette_unit_only"}), False, frozenset()),
            ("push", frozenset({"full"}), False, frozenset()),
        )
        for event, combo, valid, enabled in rows:
            selectors = {name: True for name in combo}
            with self.subTest(event=event, selectors=sorted(combo)):
                problems = ci_scope.validate(event, selectors)
                self.assertEqual(not problems, valid, problems)
                if not valid:
                    with self.assertRaises(ValueError):
                        ci_scope.scope(event, selectors)
                    continue
                scope = ci_scope.scope(event, selectors)
                self.assertEqual(set(scope["selectors"]), set(combo))
                actual = frozenset(job for job, on in scope["jobs"].items()
                                   if on and job != "validate-selectors")
                self.assertEqual(actual, enabled)
                self.assertEqual(scope["jobs"]["validate-selectors"],
                                 event == "workflow_dispatch")


class SelectorCliTests(unittest.TestCase):
    def run_cli(self, *arguments):
        return subprocess.run(
            [sys.executable, str(SCRIPTS / "ci_scope.py"), *arguments],
            capture_output=True, text=True)

    def selector_flags(self, true_names=()):
        flags = []
        for name in ci_scope.ALL_SELECTORS:
            flags += ["--set", f"{name}={'true' if name in true_names else 'false'}"]
        return flags

    def test_selector_free_dispatch_resolves_to_lean(self):
        result = self.run_cli("--event", "workflow_dispatch", *self.selector_flags())
        self.assertEqual(result.returncode, 0, result.stderr)
        scope = json.loads(result.stdout)
        self.assertTrue(scope["jobs"]["lean-checks"])
        self.assertFalse(scope["jobs"]["build-test"])

    def test_full_dispatch_enables_the_three_job_matrix(self):
        result = self.run_cli("--event", "workflow_dispatch", *self.selector_flags({"full"}))
        self.assertEqual(result.returncode, 0, result.stderr)
        scope = json.loads(result.stdout)
        for job in ci_scope.FULL_MATRIX:
            self.assertTrue(scope["jobs"][job], job)
        self.assertFalse(scope["jobs"]["lean-checks"])

    def test_conflicting_selectors_fail_with_a_named_message(self):
        result = self.run_cli(
            "--event", "workflow_dispatch",
            *self.selector_flags({"full", "ide_only"}))
        self.assertEqual(result.returncode, 1)
        self.assertIn("conflicting selectors", result.stderr)
        self.assertIn("full", result.stderr)
        self.assertIn("ide_only", result.stderr)

    def test_palette_modifier_requires_feedback_ui(self):
        result = self.run_cli(
            "--event", "workflow_dispatch", *self.selector_flags({"palette_only"}))
        self.assertEqual(result.returncode, 1)
        self.assertIn("palette_only requires feedback_ui", result.stderr)

    def test_unknown_selector_is_rejected(self):
        result = self.run_cli("--event", "workflow_dispatch", "--set", "native_wheels=true")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown selector", result.stderr)


class WorkflowSelectorWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = WORKFLOW.read_text()
        cls.blocks = job_blocks(cls.source)
        for job in ci_scope.JOBS:
            assert job in cls.blocks, job

    def evaluate(self, condition, event, combo):
        return ConditionEvaluator(condition, event=event, true_inputs=combo).evaluate()

    def test_job_conditions_match_the_truth_table_for_every_combination(self):
        for event in ci_scope.EVENTS:
            for combo in all_selector_subsets():
                selectors = {name: True for name in combo}
                valid = expected_valid(event, selectors)
                for job in ci_scope.JOBS:
                    condition = job_condition(self.blocks[job])
                    self.assertIsNotNone(condition, f"{job} has no job-level if")
                    raw = self.evaluate(condition, event, combo)
                    self.assertEqual(
                        raw, expected_raw_condition(job, event, combo),
                        f"{job} {event} {sorted(combo)}: {condition}")
                    # Every manual lane carries `needs: validate-selectors`, so
                    # a rejected combination can never start it even when the
                    # lane's own condition is true (for example full+ide_only).
                    gated = job in ("validate-selectors", "lean-checks") or valid
                    effective = raw and gated
                    # A rejected combination starts no lane at all; only the
                    # validator itself runs (and fails).
                    expected = (expected_condition(job, event, combo)
                                if valid or job == "validate-selectors" else False)
                    self.assertEqual(
                        effective, expected,
                        f"{job} {event} {sorted(combo)}: {condition}")

    def test_every_manual_lane_waits_for_the_validator(self):
        # A failed validate-selectors job must skip every lane that is not
        # read-only, including the paid demo and the write-capable publish job.
        for job in ("live-agent-demo", "local-inference", "feedback-ui",
                    "publish-skill-hub", "build-test",
                    "appstore-sdk-compatibility", "spm-linux-build"):
            self.assertIn("needs: validate-selectors", self.blocks[job], job)

    def test_validator_receives_every_declared_selector(self):
        validator = strip_comments(self.blocks["validate-selectors"])
        self.assertIn("ci_scope.py --event workflow_dispatch", validator)
        for name in ci_scope.ALL_SELECTORS:
            self.assertIn(f'--set "{name}=${{{{ inputs.{name} }}}}"', validator)
        self.assertIn("runs-on: ubuntu-latest", validator)
        self.assertIn("actions/checkout@v5", validator)
        # Pure stdlib validation before any build/bootstrap/resolve step.
        for token in ("xcodebuild", "swift", "simctl", "bootstrap", "xcodegen"):
            self.assertNotIn(token, validator, token)

    def test_manual_full_is_an_explicit_opt_in_input(self):
        block = dispatch_input_block(self.source, "full")
        self.assertIsNotNone(block)
        self.assertIn("type: boolean", block)
        self.assertIn("default: false", block)
        self.assertIn("xplicit", block)  # description documents the opt-in
        # No job condition may enable a heavy lane from a push/PR event.
        for job in ci_scope.HEAVY_JOBS:
            condition = job_condition(self.blocks[job])
            self.assertFalse(self.evaluate(condition, "push", frozenset()), job)
            self.assertFalse(self.evaluate(condition, "pull_request", frozenset()), job)

    def test_only_manual_full_expands_to_the_historical_matrix(self):
        for event, combo, expected in (
            ("workflow_dispatch", frozenset({"full"}),
             {"build-test", "appstore-sdk-compatibility", "spm-linux-build"}),
            ("workflow_dispatch", frozenset({"build_test_only"}), {"build-test"}),
            ("workflow_dispatch", frozenset({"ide_only"}), {"build-test"}),
            ("workflow_dispatch", frozenset(), set()),
        ):
            actual = {job for job in ci_scope.HEAVY_JOBS
                      if self.evaluate(job_condition(self.blocks[job]), event, combo)}
            self.assertEqual(actual, expected, (event, sorted(combo)))


class LeanChecksJobTests(unittest.TestCase):
    REQUIRED = (
        "scripts/check_engineering_viewer_assets.py",
        "scripts/pin_check.sh",
        "scripts/validate_localization_catalog.py",
        "scripts/audit_native_runtime_free.py --project",
        "scripts/license_inventory.sh --check",
        "scripts/secret_scan.sh",
        "test_run_test_with_diagnostics.py",
        "test_select_test_simulator.py",
        "test_app_regression_xcresult.py",
        "test_deadline_suite_coverage.py",
        "test_notes_ui_startup_retry.py",
        "test_release_preflight_versions.py",
        "test_ci_scope.py",
        "test_ci_ide_only.py",
    )
    FORBIDDEN = (
        "xcodebuild", "xcrun", "simctl", "swift build", "swift test",
        "swift package", "xcodegen", "brew ", "gen_project", "fetch_fonts",
        "bootstrap_native", "downloadComponent", "codesign",
        "resolve_xcode_dependencies", "MetalToolchain", "actions/cache",
    )

    @classmethod
    def setUpClass(cls):
        cls.blocks = job_blocks(WORKFLOW.read_text())
        cls.lean = strip_comments(cls.blocks["lean-checks"])

    def test_lean_job_runs_the_selected_read_only_checks(self):
        for command in self.REQUIRED:
            self.assertIn(command, self.lean, command)

    def test_lean_job_has_no_build_resolve_simulator_or_bootstrap_work(self):
        for token in self.FORBIDDEN:
            self.assertNotIn(token, self.lean, token)

    def test_lean_job_is_portable_and_uncached(self):
        self.assertIn("runs-on: ubuntu-latest", self.lean)
        self.assertIn("actions/setup-python@v5", self.lean)
        self.assertIn("fetch-depth: 0", self.lean)
        # The pinned gitleaks binary is checksum-verified, not brew-installed.
        self.assertIn("sha256sum -c -", self.lean)
        self.assertIn("8.30.1", self.lean)


if __name__ == "__main__":
    unittest.main()
