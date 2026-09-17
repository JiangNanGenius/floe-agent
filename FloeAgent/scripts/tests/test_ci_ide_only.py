"""Pin the manual ide_only rerun mode of the CI workflow.

ide_only must reuse the build-test job's dependency preparation, asset
verification and the real App build-for-testing, then run only the existing
dual-device WorkspaceIDEUITests legs with their strict verifier and artifact
retention. The default push/PR/manual gates must stay exactly as strong as
before: every skipped phase is gated on the explicit ide_only input, the IDE
phase still runs against a freshly built xctestrun (never a reused simulator
.app), failure detection (verifier, stall-only retry) is preserved, and an
ambiguous input combination fails fast instead of being silently ignored.
"""
from pathlib import Path
import unittest

WORKFLOW = Path(__file__).resolve().parents[3] / '.github' / 'workflows' / 'ci.yml'


class CiIdeOnlyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = WORKFLOW.read_text()
        build_test = cls.source.split('\n  build-test:', 1)[1]
        cls.build_test = build_test.split('\n  appstore-sdk-compatibility:', 1)[0]
        cls.sdk_compat = cls.source.split('\n  appstore-sdk-compatibility:', 1)[1] \
            .split('\n  spm-linux-build:', 1)[0]
        cls.linux = cls.source.split('\n  spm-linux-build:', 1)[1]
        cls.ide_step = cls.build_test.split(
            '- name: Verify IDE native saves and retain workbench screenshots', 1)[1] \
            .split('- name: Preserve simulator app', 1)[0]

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

    def test_default_gates_still_run_everything(self):
        # Empty inputs (push/PR) make every new guard pass, so the full
        # matrix is unchanged for the default path.
        for guard in ('success() && !inputs.ide_only', 'always() && !inputs.ide_only'):
            self.assertIn(guard, self.build_test)
        for job in (self.sdk_compat, self.linux):
            self.assertIn('&& !inputs.build_test_only && !inputs.ide_only }}', job)
        # The build-test job still runs for the default combination and is
        # only additionally admitted when ide_only is set, so an ambiguous
        # combination reaches the validation step instead of being dropped.
        self.assertIn("(!inputs.live_agent_demo && !inputs.local_inference", self.build_test)
        self.assertIn('|| inputs.ide_only }}', self.build_test)

    def test_ambiguous_combinations_fail_fast_before_checkout(self):
        validate = self.build_test.split('- name: Reject ambiguous ide_only combinations', 1)[1] \
            .split('- uses: actions/checkout@v5', 1)[0]
        for other in ('live_agent_demo', 'local_inference', 'feedback_ui',
                      'publish_skill_hub', 'native_wheels_package', 'build_test_only'):
            self.assertIn(other, validate)
        self.assertIn('exit 1', validate)
        # Runs before checkout, outside the job-level FloeAgent working
        # directory, which does not exist yet at that point.
        self.assertIn('working-directory: .', validate)
        self.assertLess(self.build_test.index('Reject ambiguous ide_only combinations'),
                        self.build_test.index('uses: actions/checkout@v5'))

    def test_no_other_single_purpose_job_starts_under_ide_only(self):
        # An ambiguous dispatch must surface only as the build-test
        # validation failure — never as a paid demo, a signed skill-hub
        # publish, or any other business leg running concurrently.
        preamble = self.source.split('\n  build-test:', 1)[0]
        lines = preamble.splitlines()
        for job in ('live-agent-demo:', 'local-inference:', 'feedback-ui:',
                    'build-native-wheels:', 'publish-skill-hub:'):
            start = lines.index(f'  {job}')
            body = '\n'.join(lines[start:start + 8])
            self.assertIn('!inputs.ide_only', body, job)

    def test_ide_only_has_its_own_concurrency_group(self):
        group = self.source.split('group: floe-ci-', 1)[1].split('\n', 1)[0]
        self.assertIn("inputs.ide_only && '-ide' || ''", group)
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
                     'Verify persistent Node host and pinned tools',
                     'Resolve and pin-check dependencies',
                     'Fetch and verify bundled fonts',
                     'Build App regression host once'):
            step = self.build_test.split(f'- name: {core}', 1)[1].split('- name:', 1)[0]
            self.assertNotIn('if:', step, core)
        self.assertIn('scripts/pin_check.sh', self.build_test)
        self.assertIn('build-for-testing', self.build_test)

    def test_ide_phase_runs_in_both_modes_against_a_fresh_test_host(self):
        # The IDE phase itself is not ide_only-gated and still skips only on
        # a missing build host, never on test failures.
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
        # The only permitted retry is a stall before any test started; an
        # executed failure can never be retried into a pass.
        self.assertIn('reason")=="stalled" and not s.get("testsStarted")', self.ide_step)
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


if __name__ == '__main__':
    unittest.main()
