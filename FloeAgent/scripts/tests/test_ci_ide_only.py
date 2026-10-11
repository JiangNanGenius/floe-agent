"""Pin the lean default and the manual rerun modes of the CI workflow.

Push/PR and a selector-free manual dispatch run only lean-checks: read-only
pin/asset/license/localization/native-runtime/diagnostic contracts and the
secret scan. The historical heavy matrix is the explicit manual `full` opt-in;
`build_test_only` and ide_only remain narrow reruns of the build-test lane.
ide_only must reuse the build-test job's dependency preparation, asset
verification and the real App build-for-testing, then run only the existing
dual-device WorkspaceIDEUITests legs with their strict verifier and artifact
retention: every skipped phase is gated on the explicit ide_only input, the
IDE phase still runs against a freshly built xctestrun (never a reused
simulator .app), failure detection (verifier, startup-only retry) is
preserved, and every ambiguous selector combination fails in the dedicated
validate-selectors job before any paid, write-capable or heavy lane starts.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

WORKFLOW = Path(__file__).resolve().parents[3] / '.github' / 'workflows' / 'ci.yml'
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from should_retry_test_bootstrap import should_retry


def job_block(source, job):
    """Return one job's YAML block, independent of job ordering."""
    start = source.index(f'\n  {job}:') + 1
    match = re.search(r'\n  [a-z0-9-]+:\n', source[start:])
    return source[start:] if match is None else source[start:start + match.start() + 1]


class CiIdeOnlyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = WORKFLOW.read_text()
        build_test = cls.source.split('\n  build-test:', 1)[1]
        cls.build_test = build_test.split('\n  appstore-sdk-compatibility:', 1)[0]
        cls.sdk_compat = cls.source.split('\n  appstore-sdk-compatibility:', 1)[1] \
            .split('\n  spm-linux-build:', 1)[0]
        cls.linux = cls.source.split('\n  spm-linux-build:', 1)[1]
        cls.validate = job_block(cls.source, 'validate-selectors')
        cls.lean = job_block(cls.source, 'lean-checks')
        cls.ide_step = cls.build_test.split(
            '- name: Verify IDE native saves and retain workbench screenshots', 1)[1] \
            .split('- name: Preserve simulator app', 1)[0]

    def test_successful_app_test_loop_reaches_strict_result_verifier(self):
        # Execute the real shell loop with a controlled test driver. A successful
        # test command must not exit the step before its xcresult is verified.
        phase = self.build_test.split('- name: Run Canvas, PiP, timeline and execution regressions', 1)[1].split('- name:', 1)[0]
        run = textwrap.dedent(phase.split('        run: |', 1)[1])
        run = run[run.index('attempt=1'):]
        with tempfile.TemporaryDirectory() as root:
            script = r'''
set -e -o pipefail
python3() {
  case "$1" in
    scripts/run_test_with_diagnostics.py) return "$FAKE_TEST_CODE" ;;
    scripts/verify_app_regression_xcresult.py) touch "$VERIFIER_MARKER"; return 7 ;;
    *) return 99 ;;
  esac
}
''' + run
            marker = Path(root) / 'verified'
            env = dict(os.environ, RUNNER_TEMP=root, VERIFIER_MARKER=str(marker), FAKE_TEST_CODE='0')
            result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True)
            self.assertTrue(marker.exists(), result.stderr)
            self.assertEqual(result.returncode, 7, 'Verifier failure must fail the step')
            marker.unlink()
            env['FAKE_TEST_CODE'] = '65'
            result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 65)
            self.assertFalse(marker.exists(), 'Failed test execution must not be reported as verified')

    def test_ide_only_input_is_explicit_and_defaults_off(self):
        lines = self.source.splitlines()
        start = lines.index('      ide_only:')
        block = '\n'.join(lines[start + 1:start + 4])
        self.assertIn('type: boolean', block)
        self.assertIn('default: false', block)
        self.assertIn('not release acceptance', block)
        # ide_only exists only as a workflow_dispatch input.
        dispatch = self.source.split('  workflow_dispatch:', 1)[1].split('\n  push:', 1)[0]
        self.assertIn('ide_only:', dispatch)

    def test_default_path_is_lean_and_full_is_the_explicit_manual_matrix(self):
        # Push/PR and a selector-free manual dispatch run only the read-only
        # lean lane. The historical heavy matrix is never a push/PR gate; it
        # is selected only by the explicit manual `full` input.
        full_input = self.source.split('      full:', 1)[1].split('      live_agent_demo:', 1)[0]
        self.assertIn('type: boolean', full_input)
        self.assertIn('default: false', full_input)
        self.assertIn('lean-checks:', self.source)
        # Every manual selector disables the lean default.
        lean_header = self.lean.split('run: |', 1)[0]
        for selector in ('full', 'live_agent_demo', 'local_inference', 'feedback_ui',
                         'publish_skill_hub', 'build_test_only', 'ide_only',
                         'palette_only', 'palette_unit_only'):
            self.assertIn(f'!inputs.{selector}', lean_header, selector)
        # The heavy lanes are dispatch-only and gated on their selector.
        build_header = self.build_test.split('steps:', 1)[0]
        self.assertIn("github.event_name == 'workflow_dispatch'", build_header)
        self.assertIn('inputs.full', build_header)
        for job in (self.sdk_compat, self.linux):
            header = job.split('steps:', 1)[0]
            self.assertIn("github.event_name == 'workflow_dispatch'", header)
            self.assertIn('inputs.full', header)
        # The narrow ide_only rerun still guards all skipped heavy phases.
        for guard in ('success() && !inputs.ide_only', 'always() && !inputs.ide_only'):
            self.assertIn(guard, self.build_test)

    def test_selector_conflicts_are_validated_before_any_lane(self):
        # One validation job runs before every other lane through `needs` and
        # delegates the truth table to the checked-in script; the detailed
        # conflict matrix is exercised in test_ci_scope.py.
        self.assertIn('validate-selectors:', self.source)
        self.assertIn('ci_scope.py --event workflow_dispatch', self.validate)
        for selector in ('full', 'live_agent_demo', 'local_inference', 'feedback_ui',
                         'publish_skill_hub', 'build_test_only', 'ide_only',
                         'palette_only', 'palette_unit_only'):
            self.assertIn(f'--set "{selector}=${{{{ inputs.{selector} }}}}"', self.validate)
        for job in ('live-agent-demo', 'local-inference', 'feedback-ui',
                    'publish-skill-hub', 'build-test',
                    'appstore-sdk-compatibility', 'spm-linux-build'):
            self.assertIn('needs: validate-selectors', job_block(self.source, job), job)
        # The old in-job guard is gone: validation is centralized in its own
        # job, so no lane can start from an ambiguous dispatch.
        self.assertNotIn('Reject ambiguous ide_only combinations', self.source)

    def test_special_modes_gate_on_the_validated_dispatch(self):
        # An ambiguous dispatch must surface only as the validation failure —
        # never as a paid demo, a signed skill-hub publish, or any other
        # business leg running concurrently.
        # The native CPython wheel job was sealed out with Build 215's
        # removal of bundled native runtimes, so no such leg exists anymore.
        for job, selector in (('live-agent-demo', 'live_agent_demo'),
                              ('local-inference', 'local_inference'),
                              ('feedback-ui', 'feedback_ui'),
                              ('publish-skill-hub', 'publish_skill_hub')):
            block = job_block(self.source, job)
            self.assertIn('needs: validate-selectors', block, job)
            self.assertIn(f'inputs.{selector}', block, job)
            # No single-purpose lane can start from a push/PR event.
            self.assertIn("github.event_name == 'workflow_dispatch'", block, job)
        # Build 215 sealed bundled native Python/Node runtimes out: the
        # native wheel job and its dispatch input must never return.
        self.assertNotIn('build-native-wheels', self.source)
        self.assertNotIn('native_wheels_package', self.source)

    def test_full_and_ide_only_have_their_own_concurrency_groups(self):
        group = self.source.split('group: floe-ci-', 1)[1].split('\n', 1)[0]
        self.assertIn("inputs.ide_only && '-ide' || ''", group)
        self.assertIn("inputs.full && '-full' || ''", group)
        self.assertIn("inputs.feedback_ui && '-ui' || ''", group)

    def test_unrelated_phases_are_guarded_and_core_prep_is_not(self):
        guarded = {
            '- name: Qualify environment, package, media and job modules': 'success() && !inputs.ide_only',
            '- name: Qualify durable Notes storage and editable archives': 'success() && !inputs.ide_only',
            '- name: Upload platform qualification evidence': 'always() && !inputs.ide_only',
            '- name: Run Canvas, PiP, timeline and execution regressions': 'success() && !inputs.ide_only',
            '- name: Verify Notes workspace import and retain full App screenshots': '!inputs.ide_only',
            '- name: SPM test (cross-platform targets)': 'success() && !inputs.ide_only',
        }
        for name, guard in guarded.items():
            step = self.build_test.split(name, 1)[1].split('- name:', 1)[0]
            self.assertIn(guard, step, name)
        # Dependency preparation and asset verification must never be
        # skippable: the IDE rerun still needs them.
        for core in ('Install pinned catalog verification dependency',
                     'Prepare the pinned Lua WASI fixture',
                     'Verify bundled assets and pinned tools',
                     'Resolve and pin-check dependencies',
                     'Fetch and verify bundled fonts',
                     'Build App regression host once'):
            step = self.build_test.split(f'- name: {core}', 1)[1].split('- name:', 1)[0]
            self.assertNotIn('if:', step, core)
        self.assertIn('scripts/pin_check.sh', self.build_test)
        self.assertIn('build-for-testing', self.build_test)

    def test_ide_phase_runs_in_every_build_test_mode_against_a_fresh_test_host(self):
        # The IDE phase itself is not ide_only-gated and still skips only on
        # a missing build host, never on test failures, so full,
        # build_test_only and ide_only all verify the same fresh host.
        self.assertNotIn('ide_only', self.ide_step.split('run: |', 1)[0])
        self.assertIn("steps.app_regression_build.outcome == 'success'",
                      self.ide_step.split('run: |', 1)[0])
        # Fresh xctestrun from this run's build-for-testing products; the
        # stale simulator .app artifact is never downloaded or substituted.
        self.assertIn("find FloeAgent-AppRegressionBuild/Build/Products -maxdepth 1 -name '*.xctestrun'",
                      self.ide_step)
        self.assertIn('-xctestrun "$xctestrun"', self.ide_step)
        self.assertNotIn('download-artifact', self.build_test)
        # The simulator .app is only ever uploaded as evidence, never
        # downloaded or substituted for the xctestrun host.
        self.assertNotIn('FloeAgent-Simulator.zip', self.ide_step)

    def test_ide_failure_detection_and_verifier_are_preserved(self):
        self.assertEqual(self.ide_step.count('test-without-building'), 1)
        self.assertIn('-only-testing:FloeAgentUITests/WorkspaceIDEUITests', self.ide_step)
        self.assertIn("for device in 'iPad mini (A17 Pro)' 'iPhone 17 Pro'", self.ide_step)
        self.assertIn('-retry-tests-on-failure -test-iterations 2', self.ide_step)
        # Only startup failures may be retried; an executed failure cannot
        # be retried into a pass.
        self.assertIn('scripts/should_retry_test_bootstrap.py', self.ide_step)
        self.assertIn('"$diag_dir/summary.json" "FloeAgent-IDE-$name-attempt-$leg_attempt.log"', self.ide_step)
        self.assertIn('scripts/verify_ide_ui_xcresult.py', self.ide_step)
        self.assertIn('--result-bundle "FloeAgent-IDE-$name.xcresult"', self.ide_step)
        self.assertIn('xcresulttool export attachments', self.ide_step)

    def test_ide_evidence_is_retained(self):
        upload = self.build_test.split('- name: Upload artifacts', 1)[1]
        for pattern in ('FloeAgent/FloeAgent-IDE-*.log',
                        'FloeAgent/FloeAgent-IDE-*.json',
                        'FloeAgent/FloeAgent-IDE-*.xcresult',
                        'FloeAgent/FloeAgent-IDE-Screenshots'):
            self.assertIn(pattern, upload)

    def test_bootstrap_retry_is_limited_to_failures_before_tests_start(self):
        crash = ('Early unexpected exit, operation never finished bootstrapping '
                 '(Underlying Error: The test runner crashed while preparing to run tests)')
        self.assertTrue(should_retry({'exitCode': 65, 'reason': 'exited', 'testsStarted': False}, crash))
        self.assertTrue(should_retry({'exitCode': 124, 'reason': 'stalled', 'testsStarted': False}, ''))
        self.assertFalse(should_retry({'exitCode': 65, 'reason': 'exited', 'testsStarted': True}, crash))
        self.assertFalse(should_retry({'exitCode': 65, 'reason': 'exited', 'testsStarted': False}, 'App test failed'))


if __name__ == '__main__':
    unittest.main()
