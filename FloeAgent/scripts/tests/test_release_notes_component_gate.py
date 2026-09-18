"""Fixture checks for the parallel NativeNotes component release gate.

The normal qualified release used to run no component preflight, or had to run
the 60-minute NativeNotes qualification sequentially. The component workflow is
now reusable, and the normal release path calls it once with ``sdk:
development`` and the exact commit ``prepare-release`` froze, in parallel with
both SDK builds; the signed-upload job needs all three gates.

These tests pin the integration without dispatching any workflow:

* standalone dispatch/push selection is preserved, and a reusable call with
  ``sdk: development`` must never start the compatibility job. A called
  workflow inherits the caller's ``github`` context, so the old
  ``event_name != 'workflow_dispatch'`` shortcut made a call run both jobs;
  selection must read only the declared ``sdk`` input.
* ``workflow_call`` declares ``sdk`` as a string defaulting to ``both`` and an
  optional ``source_ref``; both checks resolve ``inputs.source_ref || github.ref``
  and the extracted real step shell rejects a mutable, malformed or mismatched
  pin.
* the release workflow wires ``sdk: development`` and
  ``needs.prepare-release.outputs.source_sha`` and makes ``testflight`` need all
  three gates, while the explicit direct/reuse/recovery flows stay untouched.

Everything is local: no network, no CI dispatch, no secret value and no App or
simulator build.
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[3]
NOTES_WORKFLOW = (
    REPO_ROOT / ".github" / "workflows" / "notes-native-qualification.yml")
RELEASE_WORKFLOW = (
    REPO_ROOT / ".github" / "workflows" / "release-unsigned-ipa.yml")
BASH = "/bin/bash" if Path("/bin/bash").exists() else "bash"
SHA_GUARD_STEP = "Require the checked-out commit to be the caller-frozen SHA"
LOWER_HEX_SHA = re.compile(r"^[0-9a-f]{40}$")
# The old event-based shortcut that also matched a workflow_call (whose
# inherited github.event_name is the caller's event, never 'workflow_call').
LEGACY_DISPATCH_SHORTCUTS = (
    "github.event_name != 'workflow_dispatch' || inputs.sdk == 'development'",
    "github.event_name != 'workflow_dispatch' || inputs.sdk == 'compatibility'",
)
SDK_GUARD = re.compile(
    r"\$\{\{\s*inputs\.sdk != '(?P<excluded>development|compatibility)'\s*\}\}")


def trigger_inputs(source, trigger):
    """Return the declared ``inputs`` mapping of one workflow trigger.

    The fixtures must also run on a clean CI runner, so this is a small
    indentation parser rather than a PyYAML dependency.
    """
    marker = "\n  {}:".format(trigger)
    if marker not in source:
        raise AssertionError("trigger {!r} is not declared".format(trigger))
    section = source.split(marker, 1)[1]
    next_trigger = re.search(r"\n  [a-z_]+:", section)
    if next_trigger:
        section = section[:next_trigger.start()]
    for boundary in ("\npermissions:", "\nconcurrency:", "\njobs:"):
        if boundary in section:
            section = section.split(boundary, 1)[0]
    if "inputs:" not in section:
        return {}
    entries = {}
    current = None
    for line in section.split("inputs:", 1)[1].splitlines():
        if re.fullmatch(r"      [a-z0-9_]+:", line):
            current = line.strip()[:-1]
            entries[current] = {}
            continue
        if current is None:
            continue
        stripped = line.strip()
        if stripped.startswith("- "):
            entries[current].setdefault("options", []).append(stripped[2:])
            continue
        field = re.fullmatch(r"([a-z]+): (.+)", stripped)
        if field:
            value = field.group(2)
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            entries[current][field.group(1)] = value
    return entries


def job_block(source, job):
    """Return the text of one two-space-indented job, failing loudly if absent."""
    marker = "\n  {}:".format(job)
    if marker not in source:
        raise AssertionError("job {!r} is not declared".format(job))
    tail = source.split(marker, 1)[1]
    next_job = re.search(r"\n  [a-z][a-z0-9-]*:", tail)
    return tail[:next_job.start()] if next_job else tail


def job_scalar(job_text, key):
    """Return one four-space-indented job scalar (``if``, ``uses``, ...)."""
    match = re.search(
        r"^    {}: (.+)$".format(re.escape(key)), job_text, re.MULTILINE)
    if match is None:
        raise AssertionError("no job-level {!r} in {!r}".format(key, job_text[:80]))
    return match.group(1).strip()


def needs_list(job_text):
    """Return a job's ``needs`` as an ordered list."""
    flow = re.search(r"^    needs: \[(.+)\]$", job_text, re.MULTILINE)
    if flow:
        return [item.strip() for item in flow.group(1).split(",")]
    single = re.search(r"^    needs: (\S+)$", job_text, re.MULTILINE)
    if single:
        return [single.group(1)]
    raise AssertionError("job has no needs list")


def permission_entries(job_text):
    """Return a job's four-space ``permissions`` block as ordered pairs."""
    match = re.search(r"^    permissions:\n", job_text, re.MULTILINE)
    if match is None:
        raise AssertionError("job has no permissions block")
    entries = []
    for line in job_text[match.end():].splitlines():
        if re.fullmatch(r"      [a-z-]+: \S+", line):
            key, _, value = line.strip().partition(": ")
            entries.append((key, value))
        else:
            break
    return entries


def step_run(job_text, step_name):
    """Extract one step's real ``run: |`` shell body (dedented).

    Indentation based, mirroring ``test_notes_native_device_legs.py``, so the
    fixtures execute the workflow's own shell rather than a paraphrase.
    """
    lines = job_text.splitlines()
    for index, line in enumerate(lines):
        if line.strip() != "- name: {}".format(step_name):
            continue
        indent = len(line) - len(line.lstrip(" "))
        cursor = index + 1
        while cursor < len(lines) and lines[cursor].strip() != "run: |":
            cursor += 1
        if cursor >= len(lines):
            raise AssertionError("no run block for step {!r}".format(step_name))
        body = []
        body_indent = None
        cursor += 1
        while cursor < len(lines):
            current = lines[cursor]
            if current.strip():
                current_indent = len(current) - len(current.lstrip(" "))
                if current_indent <= indent:
                    break
                if body_indent is None:
                    body_indent = current_indent
            body.append(current)
            cursor += 1
        if body_indent is None:
            raise AssertionError("empty run block for step {!r}".format(step_name))
        return "\n".join(
            current[body_indent:] if current.strip() else "" for current in body
        ) + "\n"
    raise AssertionError("step {!r} not found".format(step_name))


def sdk_selection(expression, sdk):
    """Evaluate the real Notes job guard for one effective ``sdk`` value.

    ``sdk=''`` models push and any payload without an ``inputs`` context.
    """
    match = SDK_GUARD.fullmatch(expression.strip())
    if match is None:
        raise AssertionError("unexpected Notes sdk guard {!r}".format(expression))
    return sdk != match.group("excluded")


def create_source_repo(root):
    """Create a tiny real repository and return its full lowercase HEAD SHA."""
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    (Path(root) / "tracked.txt").write_text("fixture\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(root), "add", "tracked.txt"], check=True)
    subprocess.run(
        ["git", "-C", str(root),
         "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com",
         "-c", "commit.gpgsign=false",
         "commit", "-q", "-m", "fixture"],
        check=True, capture_output=True, text=True)
    head = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True)
    return head.stdout.strip()


def run_source_guard(root, script, source_ref):
    """Execute one extracted guard shell with ``SOURCE_REF`` in the environment."""
    path = Path(root) / "source-guard.sh"
    path.write_text(script, encoding="utf-8")
    environment = dict(os.environ)
    environment["SOURCE_REF"] = source_ref
    return subprocess.run(
        [BASH, "--noprofile", "--norc", "-e", str(path)],
        cwd=str(root), env=environment, capture_output=True, text=True)


class ReusableTriggerContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.notes = NOTES_WORKFLOW.read_text(encoding="utf-8")

    def test_workflow_call_sdk_is_string_default_both(self):
        inputs = trigger_inputs(self.notes, "workflow_call")
        self.assertEqual(set(inputs), {"sdk", "source_ref"})
        self.assertEqual(inputs["sdk"].get("type"), "string")
        self.assertEqual(inputs["sdk"].get("default"), "both")
        self.assertNotEqual(inputs["sdk"].get("required"), "true")

    def test_workflow_call_source_ref_is_optional_string(self):
        source_ref = trigger_inputs(self.notes, "workflow_call")["source_ref"]
        self.assertEqual(source_ref.get("type"), "string")
        self.assertNotEqual(source_ref.get("required"), "true")
        self.assertNotIn("options", source_ref)
        self.assertNotIn("default", source_ref)

    def test_manual_dispatch_choice_is_preserved(self):
        dispatch = trigger_inputs(self.notes, "workflow_dispatch")
        self.assertEqual(set(dispatch), {"sdk"})
        self.assertEqual(dispatch["sdk"].get("type"), "choice")
        self.assertEqual(dispatch["sdk"].get("default"), "both")
        self.assertEqual(
            dispatch["sdk"].get("options"),
            ["both", "development", "compatibility"])

    def test_push_trigger_is_preserved(self):
        self.assertIn(
            "branches: ['codex/floe-1-7-integration-20260912']", self.notes)
        self.assertIn("FloeAgent/Qualification/NativeNotes/**", self.notes)

    def test_workflow_permissions_stay_minimal(self):
        self.assertIn("\npermissions:\n  contents: read\n", self.notes)


class JobSelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        notes = NOTES_WORKFLOW.read_text(encoding="utf-8")
        cls.notes = notes
        cls.development_guard = job_scalar(job_block(notes, "development"), "if")
        cls.compatibility_guard = job_scalar(job_block(notes, "compatibility"), "if")

    def selection(self, sdk):
        return (sdk_selection(self.development_guard, sdk),
                sdk_selection(self.compatibility_guard, sdk))

    def test_guards_never_read_the_caller_event_name(self):
        # A called workflow inherits the caller's github context, so
        # event_name cannot distinguish a workflow_call from a dispatch.
        self.assertNotIn("github.event_name", self.notes)
        for shortcut in LEGACY_DISPATCH_SHORTCUTS:
            self.assertNotIn(shortcut, self.notes)

    def test_selection_matrix_preserves_dispatch_push_and_fixes_calls(self):
        cases = (
            # (label, effective sdk, development runs, compatibility runs)
            ("push/no inputs context", "", True, True),
            ("dispatch both", "both", True, True),
            ("dispatch development", "development", True, False),
            ("dispatch compatibility", "compatibility", False, True),
            ("call development", "development", True, False),
            ("call compatibility", "compatibility", False, True),
            ("call both", "both", True, True),
            ("call default omitted (both)", "both", True, True),
        )
        for label, sdk, development, compatibility in cases:
            with self.subTest(label=label):
                self.assertEqual(
                    self.selection(sdk), (development, compatibility))

    def test_no_sdk_value_can_skip_every_leg(self):
        # A component gate must never report success by running nothing, so an
        # unsupported future value has to start at least one qualification job.
        for sdk in ("", "both", "development", "compatibility", "unsupported",
                    "Development"):
            with self.subTest(sdk=sdk):
                self.assertTrue(
                    any(self.selection(sdk)),
                    "sdk={!r} skipped every Notes leg".format(sdk))


class SourcePinTests(unittest.TestCase):
    JOBS = ("development", "compatibility")

    @classmethod
    def setUpClass(cls):
        notes = NOTES_WORKFLOW.read_text(encoding="utf-8")
        cls.blocks = {job: job_block(notes, job) for job in cls.JOBS}
        cls.guards = {
            job: step_run(cls.blocks[job], SHA_GUARD_STEP) for job in cls.JOBS}
        cls.notes = notes

    def test_both_jobs_checkout_the_caller_pin_or_github_ref(self):
        for job, block in self.blocks.items():
            with self.subTest(job=job):
                self.assertIn(
                    "ref: ${{ inputs.source_ref || github.ref }}", block)

    def test_both_jobs_verify_the_pin_before_qualification(self):
        for job, block in self.blocks.items():
            with self.subTest(job=job):
                self.assertIn(SHA_GUARD_STEP, block)
                self.assertIn("if: ${{ inputs.source_ref != '' }}", block)
                self.assertLess(
                    block.index(SHA_GUARD_STEP),
                    block.index("Select the {} Xcode toolchain".format(
                        "development" if job == "development" else "compatibility")))

    def test_artifact_names_are_bound_to_the_resolved_source(self):
        for job in self.JOBS:
            with self.subTest(job=job):
                self.assertIn(
                    "name: notes-native-{}-${{{{ inputs.source_ref || github.sha }}}}"
                    .format(job),
                    self.blocks[job])

    def test_real_guard_accepts_only_the_exact_frozen_sha(self):
        for job, script in self.guards.items():
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                sha = create_source_repo(root)
                self.assertTrue(LOWER_HEX_SHA.fullmatch(sha), sha)
                accepted = run_source_guard(root, script, sha)
                self.assertEqual(accepted.returncode, 0, accepted.stderr)
                self.assertIn("verified at checkout", accepted.stdout)

                mismatched = ("0" if sha[0] != "0" else "1") + sha[1:]
                self.assertNotEqual(mismatched, sha)
                mismatch = run_source_guard(root, script, mismatched)
                self.assertNotEqual(mismatch.returncode, 0)
                self.assertIn("does not match caller-frozen", mismatch.stderr)

                for label, invalid in (
                        ("branch", "refs/heads/main"),
                        ("tag", "v1.7.0"),
                        ("short", sha[:12]),
                        ("uppercase", sha.upper()),
                        ("non-hex", "g" * 40),
                        ("empty", "")):
                    with self.subTest(job=job, invalid=label):
                        rejected = run_source_guard(root, script, invalid)
                        self.assertNotEqual(rejected.returncode, 0)
                        self.assertIn("::error::", rejected.stderr)


class DiagnosticSeparationTests(unittest.TestCase):
    """The strict Quick Look class stays real, separate and honestly recorded.

    The component workflow excludes ``NotesOfficeThumbnailDiagnosticsTests``
    from the functional legs and runs it in an explicit diagnostic step with
    its own xcresult/log/original exit code. The step classifies through
    ``FloeAgent/scripts/verify_quicklook_diagnostics.py``, which reads the real
    xcresult summary/tests structures: only a complete 7/7 run with xcodebuild's
    test-failure exit 65 whose failures are all fixed-marker Quick Look
    content/timeout/icon assertions is non-gating; an empty selector, a
    partial/skipped run, a missing result bundle, a runner/host crash, a forged
    log, a timeout/kill exit or any other assertion failure fails the
    diagnostic step as a coverage gap. Functional failures still fail the job
    and no global ``continue-on-error`` softens any leg.
    """

    FUNCTIONAL_STEP = "Test iPad first, then iPhone"
    DIAGNOSTIC_STEP = "Run strict Quick Look diagnostics (diagnostic, non-gating)"
    STRICT_CLASS = "NotesOfficeThumbnailDiagnosticsTests"
    DIAGNOSTIC_CASES = 7

    @classmethod
    def setUpClass(cls):
        cls.notes = NOTES_WORKFLOW.read_text(encoding="utf-8")
        cls.jobs = {
            job: job_block(cls.notes, job)
            for job in ("development", "compatibility")}
        cls.functional = {
            job: step_run(block, cls.FUNCTIONAL_STEP)
            for job, block in cls.jobs.items()}
        cls.diagnostic = {
            job: step_run(block, cls.DIAGNOSTIC_STEP)
            for job, block in cls.jobs.items()}

    def test_functional_legs_exclude_the_strict_class_and_stay_gating(self):
        for job, script in self.functional.items():
            with self.subTest(job=job):
                self.assertIn(
                    "-skip-testing:NativeNotesTests/{}".format(self.STRICT_CLASS),
                    script)
                self.assertNotIn("-only-testing:", script)
                self.assertNotIn("test-without-building", script)
                self.assertIn("::error::", script)
                self.assertIn('exit "$first_failure"', script)

    def test_diagnostic_step_runs_only_the_strict_class_without_rebuilding(self):
        for job, script in self.diagnostic.items():
            with self.subTest(job=job):
                self.assertIn(
                    "-only-testing:NativeNotesTests/{}".format(self.STRICT_CLASS),
                    script)
                self.assertIn("CODE_SIGNING_ALLOWED=NO test-without-building", script)
                self.assertIn(
                    '-resultBundlePath "notes-diagnostic-$family.xcresult"', script)
                self.assertIn("notes-diagnostic-$family.log", script)
                self.assertIn("notes-diagnostic-$family.status", script)
                self.assertIn("diagnostic non-gating", script)
                self.assertIn("for family in iPad iPhone; do", script)
                self.assertIn(
                    '"$GITHUB_WORKSPACE/FloeAgent/scripts/verify_quicklook_diagnostics.py"',
                    script)

    def test_guard_classifies_from_real_xcresult_structures_not_log_text(self):
        for job, script in self.diagnostic.items():
            with self.subTest(job=job):
                # The independent stdlib helper receives the bundle, the
                # original exit code and the evidence outputs.
                self.assertIn(
                    '--result-bundle "notes-diagnostic-$family.xcresult"', script)
                self.assertIn('--original-exit "$result"', script)
                self.assertIn('--family "$family"', script)
                self.assertIn(
                    '--status-output "$evidence_dir/notes-diagnostic-$family.status"', script)
                self.assertIn(
                    '--failures-output "$evidence_dir/notes-diagnostic-$family.status.failures.txt"',
                    script)
                self.assertIn("NOT_EXECUTED", script)
                self.assertIn("ASSERTION_FAILURE", script)
                # No embedded log-text classifier may remain in the workflow.
                self.assertNotIn("Executed (\\d+) tests", script)
                self.assertNotIn("import pathlib, re, sys", script)
                # Coverage gaps fail this step; only a complete assertion
                # failure is a warning.
                self.assertIn('exit "$incomplete"', script)
                self.assertIn('::error::', script)
                self.assertIn('::warning::', script)

    def test_diagnostic_step_is_non_gating_and_never_hides_functional_failures(self):
        self.assertNotRegex(self.notes, r"(?m)^\s+continue-on-error\s*:")
        for job, block in self.jobs.items():
            with self.subTest(job=job):
                self.assertIn("if: always()", block)
                script = self.diagnostic[job]
                self.assertTrue(
                    script.rstrip().endswith('exit "$incomplete"'),
                    "the diagnostic step status must carry the coverage result")
        # Functional status is still carried by the functional step only.
        self.assertIn('exit "$first_failure"', self.functional["development"])
        self.assertIn('exit "$first_failure"', self.functional["compatibility"])

    def test_diagnostic_results_are_a_separate_artifact_set(self):
        self.assertEqual(
            self.notes.count("notes-diagnostic-$family.xcresult"), 4,
            "each job's xcodebuild and its classifier name the bundle")
        self.assertEqual(self.notes.count("notes-diagnostic-$family.log"), 4,
                         "each job tees the diagnostic log and passes it to the classifier")
        self.assertEqual(self.notes.count(
            '--status-output "$evidence_dir/notes-diagnostic-$family.status"'), 2)
        self.assertEqual(self.notes.count(
            '--failures-output "$evidence_dir/notes-diagnostic-$family.status.failures.txt"'), 2)
        # The existing functional artifact upload step is unchanged.
        self.assertEqual(self.notes.count("notes-*.xcresult"), 2)
        self.assertEqual(self.notes.count("notes-*.log"), 2)


class ReleaseComponentGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.release = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        cls.jobs = {
            name: job_block(cls.release, name)
            for name in ("direct-testflight", "expedited-testflight",
                         "recover-testflight", "prepare-release",
                         "notes-component", "build-verify-release",
                         "accepted-sdk-build", "testflight", "publish-release")
        }

    def test_component_job_calls_the_reusable_workflow_with_the_frozen_sha(self):
        component = self.jobs["notes-component"]
        self.assertEqual(
            job_scalar(component, "uses"),
            "./.github/workflows/notes-native-qualification.yml")
        self.assertIn("      sdk: development\n", component)
        self.assertIn(
            "      source_ref: ${{ needs.prepare-release.outputs.source_sha }}\n",
            component)
        self.assertNotIn("inputs.tag", component)
        self.assertNotIn("github.sha", component)
        self.assertNotIn("github.ref", component)

    def test_component_job_is_normal_path_only_with_minimal_permissions(self):
        component = self.jobs["notes-component"]
        self.assertEqual(needs_list(component), ["prepare-release"])
        self.assertEqual(
            job_scalar(component, "if"), job_scalar(
                self.jobs["build-verify-release"], "if"))
        for token in ("!inputs.direct_testflight",
                      "!inputs.recover_build_156",
                      "inputs.reuse_accepted_run == ''"):
            self.assertIn(token, job_scalar(component, "if"))
        permissions = permission_entries(component)
        self.assertEqual(permissions, [("contents", "read")])
        self.assertNotRegex(component, r"(?m)^\s+secrets:")
        self.assertNotIn("runs-on", component)
        self.assertNotIn("steps:", component)
        self.assertNotIn("always()", component)

    def test_three_gates_run_in_parallel_after_the_single_freeze(self):
        self.assertEqual(
            needs_list(self.jobs["notes-component"]), ["prepare-release"])
        self.assertEqual(
            needs_list(self.jobs["build-verify-release"]), ["prepare-release"])
        self.assertEqual(
            needs_list(self.jobs["accepted-sdk-build"]), ["prepare-release"])
        self.assertIn('source_sha: ${{ steps.release.outputs.source_sha }}',
                      self.jobs["prepare-release"])
        for name in ("build-verify-release", "accepted-sdk-build"):
            self.assertIn(
                "ref: ${{ needs.prepare-release.outputs.source_sha }}",
                self.jobs[name])

    def test_testflight_waits_for_all_three_gates_without_bypass(self):
        testflight = self.jobs["testflight"]
        self.assertEqual(
            needs_list(testflight),
            ["build-verify-release", "accepted-sdk-build", "notes-component"])
        self.assertNotRegex(testflight, r"(?m)^    if:")
        self.assertNotIn("always()", testflight)
        self.assertNotIn("continue-on-error", testflight)
        self.assertIn(
            "ref: ${{ needs.build-verify-release.outputs.source_sha }}",
            testflight)

    def test_publish_stays_behind_the_upload_gate(self):
        publish = self.jobs["publish-release"]
        self.assertEqual(needs_list(publish),
                         ["build-verify-release", "testflight"])
        self.assertIn("inputs.publish", job_scalar(publish, "if"))

    def test_direct_reuse_and_recovery_flows_are_unchanged(self):
        direct = self.jobs["direct-testflight"]
        self.assertEqual(job_scalar(direct, "uses"),
                         "./.github/workflows/testflight-direct.yml")
        self.assertEqual(
            job_scalar(direct, "if"),
            "github.event_name == 'workflow_dispatch' && inputs.direct_testflight "
            "&& inputs.reuse_accepted_run == ''")
        self.assertIn("      tag: ${{ inputs.tag }}\n", direct)

        expedited = self.jobs["expedited-testflight"]
        self.assertEqual(job_scalar(expedited, "uses"),
                         "./.github/workflows/testflight-from-artifact.yml")
        self.assertEqual(
            job_scalar(expedited, "if"),
            "github.event_name == 'workflow_dispatch' && "
            "inputs.reuse_accepted_run != ''")
        self.assertIn("      source_run: ${{ inputs.reuse_accepted_run }}\n",
                      expedited)
        self.assertIn("      tag: ${{ inputs.tag }}\n", expedited)

        recovery = self.jobs["recover-testflight"]
        self.assertEqual(job_scalar(recovery, "uses"),
                         "./.github/workflows/testflight-recovery.yml")
        self.assertEqual(
            job_scalar(recovery, "if"),
            "${{ github.event_name == 'workflow_dispatch' && "
            "inputs.recover_build_156 && inputs.tag == 'v1.7.0-beta.13' && "
            "!inputs.publish }}")

        # The new gate never widens those explicit flows.
        component = self.jobs["notes-component"]
        self.assertNotIn("direct-testflight", needs_list(component))
        self.assertNotIn("expedited-testflight", needs_list(component))
        self.assertNotIn("recover-testflight", needs_list(component))


if __name__ == "__main__":
    unittest.main()
