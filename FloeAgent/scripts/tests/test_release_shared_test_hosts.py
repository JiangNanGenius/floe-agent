"""Protect shared test hosts, per-device Notes legs and the two-SDK join.

The standard release must not share one Notes budget between iPad and iPhone:
a single slow device used to time out the whole qualification. Each device now
runs in its own 25-minute step with bounded stall diagnostics and a single
pre-test retry, the other device still runs for evidence when one fails, and an
explicit gate fails the job unless both legs strictly passed so no unsigned IPA
or signed upload can come from a partial Notes run.

The retry decision comes only from ``scripts/notes_ui_startup_retry.py``, which
these tests execute for real: the leg shell has no inline fallback, so a missing
helper, a missing/unreadable attempt log, malformed evidence, executed-test
output or an App crash can never be retried into a pass.
"""
from pathlib import Path
import json
import subprocess
import tempfile
import textwrap
import unittest

WORKFLOW = Path(__file__).resolve().parents[3] / '.github/workflows/release-unsigned-ipa.yml'
HELPER = Path(__file__).resolve().parents[1] / 'notes_ui_startup_retry.py'

IPAD_STEP = "- name: Require Notes import on the iPad simulator with the"
IPHONE_STEP = "- name: Require Notes import on the iPhone simulator with the"
GATE_STEP = "- name: Require both"


def accepted_leg_run_block(name: str) -> str:
    """The real shell ``run`` body of one Notes leg (device behaviour is env)."""
    source = WORKFLOW.read_text(encoding="utf-8")
    block = source.split(name, 1)[1].split(GATE_STEP, 1)[0]
    return textwrap.dedent(block.split("run: |", 1)[1])


# Controlled xcrun/xcodebuild/python3 drivers so the real leg shell can be
# executed without a Mac, a simulator or a build. The retry classifier is
# executed for real from $NOTES_RETRY_HELPER (the leg runs in a temporary cwd,
# so the relative workflow path cannot resolve), the diagnostics driver copies
# the truthful per-call summary written by write_state, and each attempt log
# line comes from the same state files.
LEG_STUB = r'''
xcrun() {
  case " $* " in
    *" --show-sdk-version "*) echo "26.0"; return 0 ;;
    *" list devices "*) echo "{}"; return 0 ;;
    *" export attachments "*) return 0 ;;
    *) return 0 ;;
  esac
}
xcodebuild() { return 0; }
python3() {
  case "$1" in
    -c) command python3 "$@" ;;
    *select_test_simulator.py) echo "00000000-0000-0000-0000-000000000000"; return 0 ;;
    *notes_ui_startup_retry.py)
      shift
      command python3 "$NOTES_RETRY_HELPER" "$@" ;;
    *run_test_with_diagnostics.py)
      printf '%s\n' "$*" >> "$FAKE_STATE/run.calls"
      call=$(( $(cat "$FAKE_STATE/calls" 2>/dev/null || echo 0) + 1 ))
      echo "$call" > "$FAKE_STATE/calls"
      diag=""; bundle=""
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --output-dir) diag="$2"; shift 2 ;;
          -resultBundlePath) bundle="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      mkdir -p "$diag" "$bundle"
      code="$(sed -n "${call}p" "$FAKE_STATE/codes")"
      [ -n "$code" ] || code=0
      # Truthful summary.json exactly as run_test_with_diagnostics.py writes it.
      sed -n "${call}p" "$FAKE_STATE/summaries" > "$diag/summary.json"
      # The attempt log the classifier must judge; an empty entry produces an
      # empty log, i.e. the missing/unreadable evidence shape.
      log_line="$(sed -n "${call}p" "$FAKE_STATE/logs" 2>/dev/null || true)"
      if [ -n "$log_line" ]; then printf '%s\n' "$log_line"; fi
      return "$code" ;;
    *verify_notes_ui_xcresult.py) return 0 ;;
    *) return 99 ;;
  esac
}
'''

# Exact retained bootstrap-crash line from release run 35292395886 (job
# 105437894361, SDK 27 iPhone Notes leg), without the surrounding context.
BOOTSTRAP_LOG_LINE = (
    "\tFloeAgentUITests-Runner (5415) encountered an error (Early unexpected "
    "exit, operation never finished bootstrapping - no restart will be "
    "attempted. (Underlying Error: The test runner crashed while preparing to "
    "run tests: FloeAgentUITests-Runner at -[XCTWaiter(StallHandling) "
    "handleStalledWait:]))")
# Exact retained executed Office cover assertion line from the same run.
EXECUTED_FAILURE_LOG_LINE = (
    "/Users/runner/work/floe-agent/floe-agent/FloeAgent/Tests/FloeAgentUITests/"
    "NotesWorkspaceImportUITests.swift:264: error: -[FloeAgentUITests."
    "NotesWorkspaceImportUITests testNotesLibraryCardsShowRealContentCovers] : "
    "XCTAssertTrue failed - office cover source 'unsupported' is not a real "
    "content source [\"quickLook\"]")
# Modeled (not observed): the App under test crashed during launch.
APPLICATION_CRASH_LOG_LINE = (
    "FloeAgentUITests-Runner (5415) encountered an error (Failed to launch the "
    "test runner: The application 'Floe Agent' crashed during launch.)")
# A harmless nonempty attempt log for pre-test infrastructure shapes.
STALL_LOG_LINE = ("Command line invocation: xcodebuild -xctestrun host.xctestrun "
                  "test-without-building")
PASS_LOG_LINE = "Test Suite 'All tests' passed at 2026-09-18 01:48:12.968."


class SharedReleaseHostTests(unittest.TestCase):
    def jobs(self):
        source = WORKFLOW.read_text()
        sdk27 = source.split('\n  build-verify-release:', 1)[1].split('\n  accepted-sdk-build:', 1)[0]
        stable = source.split('\n  accepted-sdk-build:', 1)[1].split('\n  testflight:', 1)[0]
        upload = source.split('\n  testflight:', 1)[1].split('\n  publish-release:', 1)[0]
        return source, sdk27, stable, upload

    def test_both_sdks_build_once_and_execute_their_own_tests(self):
        source, sdk27, stable, upload = self.jobs()
        for job, derived in ((sdk27, 'FloeAppRegressionDerivedData'), (stable, 'FloeStableDeviceDerivedData')):
            self.assertEqual(job.count('CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing'), 1)
            self.assertIn('ENABLE_TESTABILITY=YES', job)
            self.assertIn("-configuration Debug -destination 'generic/platform=iOS Simulator'", job)
            self.assertIn('-configuration Release', job)
            self.assertIn(f'$RUNNER_TEMP/{derived}/Build/Products', job)
            self.assertIn('-xctestrun "$xctestrun"', job)
            self.assertIn('verify_app_regression_xcresult.py', job)
            self.assertIn('verify_notes_ui_xcresult.py', job)
            self.assertIn(IPAD_STEP, job)
            self.assertIn(IPHONE_STEP, job)
            self.assertGreaterEqual(job.count('test-without-building'), 2)
            self.assertNotIn('            test\n', job)
        self.assertNotIn('FloeSimulatorDerivedData', source)
        self.assertIn('Build unsigned device application', sdk27)
        self.assertIn('Rebuild the exact tag with the accepted App Store SDK', stable)
        self.assertNotIn('build-for-testing', upload)
        self.assertNotIn('            build\n', upload)

    def test_sdk_jobs_share_frozen_source_and_upload_waits_for_both(self):
        source, sdk27, stable, upload = self.jobs()
        for job in [sdk27, stable]:
            self.assertIn('needs: prepare-release', job)
            self.assertIn('ref: ${{ needs.prepare-release.outputs.source_sha }}', job)
            self.assertNotIn('secrets.APPLE_CERTIFICATE', job)
            self.assertNotIn('secrets.APP_STORE_CONNECT', job)
        self.assertIn('needs: [build-verify-release, accepted-sdk-build]', upload)
        self.assertIn('needs.accepted-sdk-build.outputs.input_sha256', upload)
        self.assertIn('shasum -a 256 -c -', upload)
        self.assertIn('SOURCE-SHA.txt', upload)
        self.assertLess(upload.index('Verify and restore the exact qualified'), upload.index('Install App Store Connect API key'))
        self.assertLess(stable.index('verify_notes_ui_xcresult.py'), stable.index('Stage the qualified accepted-SDK application'))
        self.assertIn('needs.accepted-sdk-build.outputs.passed', upload)
        self.assertNotIn('steps.stable_app_regression.outputs.', upload)

    def test_notes_legs_are_split_with_own_budget_diagnostics_and_retry(self):
        _, sdk27, stable, _ = self.jobs()
        for job in (sdk27, stable):
            # One 25-minute budget per device, never a shared 20-minute one.
            self.assertEqual(job.count('timeout-minutes: 25'), 2)
            self.assertEqual(job.count(IPAD_STEP), 1)
            self.assertEqual(job.count(IPHONE_STEP), 1)
            for token in ('--timeout 1320 --stall-timeout 210',
                          '--startup-stall-timeout 420',
                          'run_test_with_diagnostics.py',
                          '-only-testing:FloeAgentUITests/NotesWorkspaceImportUITests',
                          '-parallel-testing-enabled NO -test-timeouts-enabled YES',
                          'verify_notes_ui_xcresult.py',
                          '--simulator-without-office'):
                self.assertIn(token, job)
            self.assertNotIn("-retry-tests-on-failure", job)
            # Exactly one bounded retry, and the real classifier is the only
            # decision point: both evidence files are passed, there is no inline
            # JSON fallback that could override a rejection.
            self.assertEqual(job.count('python3 scripts/notes_ui_startup_retry.py'), 2)
            self.assertEqual(job.count('--summary "$diag_dir/summary.json"'), 2)
            self.assertEqual(
                job.count('--log "$qualification/$NOTES_NAME-attempt-$leg_attempt.log"'), 2)
            self.assertEqual(job.count('--attempt "$leg_attempt"'), 2)
            self.assertNotIn('s.get("reason")=="stalled"', job)
            self.assertNotIn('s.get("testsStarted")', job)
            self.assertEqual(job.count('leg_attempt=2'), 2)
            # The second device runs after the first fails, but never on cancel.
            self.assertIn("!cancelled() && steps.notes_ipad.outcome != 'skipped'", job)
            # Strict gate, not a continue-on-error bypass.
            self.assertNotIn('continue-on-error', job)
        self.assertNotIn('continue-on-error', WORKFLOW.read_text())

    def test_hosts_are_retained_before_tests_with_distinct_prefixes(self):
        _, sdk27, stable, _ = self.jobs()
        self.assertIn('sdk27-simulator-host-${{ needs.prepare-release.outputs.source_sha }}', sdk27)
        self.assertIn('accepted-sdk26-simulator-host-${{ needs.prepare-release.outputs.source_sha }}', stable)
        self.assertIn('Retain the complete SDK 27 simulator test host', sdk27)
        self.assertIn('Retain the compiled accepted-SDK simulator test host', stable)
        self.assertIn('Upload recoverable SDK 27 simulator test host', sdk27)
        self.assertIn('Upload recoverable accepted-SDK simulator host', stable)
        for job in (sdk27, stable):
            for token in ('Products.tar.gz.sha256', 'SOURCE-SHA.txt', 'SOURCE-RUN.txt',
                          'SOURCE-ATTEMPT.txt', 'TOOLCHAIN.txt', 'retention-days: 7'):
                self.assertIn(token, job)
        # Retention happens once the host is built and before the first UI leg.
        self.assertLess(sdk27.index('Retain the complete SDK 27'), sdk27.index(IPAD_STEP))
        self.assertLess(stable.index('Retain the compiled accepted-SDK'), stable.index(IPAD_STEP))

    def test_notes_gate_blocks_packaging_when_one_device_fails(self):
        _, sdk27, stable, _ = self.jobs()
        for job in (sdk27, stable):
            self.assertLess(job.index(IPAD_STEP), job.index(GATE_STEP))
            self.assertLess(job.index(IPHONE_STEP), job.index(GATE_STEP))
        # SDK 27 must not build the unsigned IPA on a partial Notes result.
        self.assertLess(sdk27.index(GATE_STEP), sdk27.index('Build unsigned device application'))
        # The accepted SDK must not normalize or stage a partial qualification.
        self.assertLess(stable.index(GATE_STEP), stable.index('Normalize reviewed App Store bundle defects'))
        self.assertLess(stable.index(GATE_STEP), stable.index('Stage the qualified accepted-SDK application'))

    def run_gate(self, job, ipad, iphone):
        tail = job.split(GATE_STEP, 1)[1].split('run: |', 1)[1]
        block = textwrap.dedent(tail.split('\n      - name:', 1)[0])
        return subprocess.run(
            ['bash', '-e', '-c', block],
            env={'IPAD_NOTES_OUTCOME': ipad, 'IPHONE_NOTES_OUTCOME': iphone,
                 'PATH': '/usr/bin:/bin'},
            capture_output=True, text=True)

    def test_real_gate_shell_rejects_ipad_fail_iphone_pass(self):
        _, sdk27, stable, _ = self.jobs()
        for job in (sdk27, stable):
            self.assertEqual(self.run_gate(job, 'success', 'success').returncode, 0)
            self.assertNotEqual(self.run_gate(job, 'failure', 'success').returncode, 0)
            self.assertNotEqual(self.run_gate(job, 'success', 'failure').returncode, 0)
            self.assertNotEqual(self.run_gate(job, 'skipped', 'success').returncode, 0)
            self.assertNotEqual(self.run_gate(job, 'success', 'skipped').returncode, 0)

    def run_leg(self, name, root, *, notes_name, helper=HELPER):
        """Execute the real leg shell with controlled drivers and real helper."""
        products = (Path(root) / 'FloeStableDeviceDerivedData' / 'Build' / 'Products')
        products.mkdir(parents=True, exist_ok=True)
        (products / 'FloeAgent.xctestrun').touch()
        env = dict(
            {'PATH': '/usr/bin:/bin'},
            RUNNER_TEMP=root,
            NOTES_DEVICE='iPad mini (A17 Pro)' if notes_name == 'ipad' else 'iPhone 17 Pro',
            NOTES_NAME=notes_name,
            NOTES_DERIVED='FloeStableDeviceDerivedData',
            NOTES_EVIDENCE='FloeStable-Notes',
            NOTES_RETRY_HELPER=str(helper),
            FAKE_STATE=str(Path(root) / 'state'),
        )
        return subprocess.run(
            ['bash', '-e', '-o', 'pipefail', '-c', LEG_STUB + accepted_leg_run_block(name)],
            cwd=root, env=env, capture_output=True, text=True)

    def write_state(self, root, codes, reasons, started, logs=None, summaries=None):
        state = Path(root) / 'state'
        state.mkdir(parents=True, exist_ok=True)
        (state / 'calls').unlink(missing_ok=True)
        (state / 'run.calls').unlink(missing_ok=True)
        (state / 'codes').write_text('\n'.join(codes) + '\n')
        (state / 'reasons').write_text('\n'.join(reasons) + '\n')
        (state / 'started').write_text('\n'.join(started) + '\n')
        if logs is None:
            logs = [STALL_LOG_LINE] * len(codes)
        (state / 'logs').write_text('\n'.join(logs) + '\n')
        if summaries is None:
            # Truthful summaries: the same exitCode the driver returns, plus
            # the reason/testsStarted the driver observed.
            summaries = ['{"reason":"%s","testsStarted":%s,"exitCode":%s}' % (r, s, c)
                         for r, s, c in zip(reasons, started, codes)]
        (state / 'summaries').write_text('\n'.join(summaries) + '\n')

    def test_strict_flow_runs_iphone_after_ipad_failure_and_still_gates(self):
        # A real executed iPad failure must (1) not stop the iPhone leg from
        # running for evidence and (2) still fail the strict gate, so the
        # signing/packaging path can never start.
        with tempfile.TemporaryDirectory() as root:
            self.write_state(root, ['65', '0'], ['exited', 'exited'], ['true', 'true'],
                             logs=[EXECUTED_FAILURE_LOG_LINE, PASS_LOG_LINE])
            ipad = self.run_leg(IPAD_STEP, root, notes_name='ipad')
            self.assertNotEqual(ipad.returncode, 0, ipad.stderr)
            iphone = self.run_leg(IPHONE_STEP, root, notes_name='iphone')
            self.assertEqual(iphone.returncode, 0, iphone.stderr)
            self.assertTrue(
                (Path(root) / 'FloeStable-Notes' / 'ipad-attempt-1.xcresult').is_dir())
            self.assertTrue(
                (Path(root) / 'FloeStable-Notes' / 'iphone-attempt-1.xcresult').is_dir())
            # The normal UI path never rebuilds the test host: it only runs the
            # already compiled xctestrun with test-without-building.
            calls = (Path(root) / 'state/run.calls').read_text()
            self.assertIn('test-without-building', calls)
            self.assertNotIn('build-for-testing', calls)
            _, _, stable, _ = self.jobs()
            self.assertNotEqual(self.run_gate(stable, 'failure', 'success').returncode, 0)

    def test_pre_test_stall_retries_once_in_a_fresh_directory(self):
        with tempfile.TemporaryDirectory() as root:
            self.write_state(root, ['124', '0'], ['stalled', 'exited'], ['false', 'true'],
                             logs=[STALL_LOG_LINE, PASS_LOG_LINE])
            result = self.run_leg(IPAD_STEP, root, notes_name='ipad')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((Path(root) / 'state/calls').read_text().strip(), '2')
            diag = Path(root) / 'FloeStable-NotesDiagnostics'
            self.assertTrue((diag / 'ipad-attempt-1').is_dir())
            self.assertTrue((diag / 'ipad-attempt-2').is_dir())
            # The truthful attempt-1 summary the classifier accepted.
            summary = json.loads((diag / 'ipad-attempt-1' / 'summary.json').read_text())
            self.assertEqual(summary,
                             {"reason": "stalled", "testsStarted": False, "exitCode": 124})

    def test_observed_bootstrap_crash_retries_once_and_can_pass(self):
        # The exact retained pre-test bootstrap crash (exit 65) is the second
        # retryable shape; attempt 2 then passes.
        with tempfile.TemporaryDirectory() as root:
            self.write_state(root, ['65', '0'], ['exited', 'exited'], ['false', 'true'],
                             logs=[BOOTSTRAP_LOG_LINE, PASS_LOG_LINE])
            result = self.run_leg(IPAD_STEP, root, notes_name='ipad')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((Path(root) / 'state/calls').read_text().strip(), '2')
            first_log = (Path(root) / 'FloeStable-Notes' / 'ipad-attempt-1.log').read_text()
            self.assertIn('handleStalledWait:', first_log)

    def test_bootstrap_crash_twice_is_bounded_to_two_attempts(self):
        with tempfile.TemporaryDirectory() as root:
            self.write_state(root, ['65', '65'], ['exited', 'exited'], ['false', 'false'],
                             logs=[BOOTSTRAP_LOG_LINE, BOOTSTRAP_LOG_LINE])
            result = self.run_leg(IPAD_STEP, root, notes_name='ipad')
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertEqual((Path(root) / 'state/calls').read_text().strip(), '2')

    def test_contradictory_log_never_retries_a_stalled_summary(self):
        # reason=stalled / testsStarted=false / exitCode=124 is exactly the
        # legacy bypass shape: the real classifier must still reject it when
        # the attempt log proves an executed failure, an executed run or an App
        # crash, and the shell must not retry.
        executed_only = ("Executed 5 tests, with 1 test skipped and 1 failure "
                         "(0 unexpected) in 650.517 (650.531) seconds")
        for label, log_line in (('xctassert', EXECUTED_FAILURE_LOG_LINE),
                                ('executed', executed_only),
                                ('app-crash', APPLICATION_CRASH_LOG_LINE)):
            with self.subTest(label), tempfile.TemporaryDirectory() as root:
                self.write_state(root, ['124'], ['stalled'], ['false'],
                                 logs=[log_line])
                result = self.run_leg(IPAD_STEP, root, notes_name='ipad')
                self.assertNotEqual(result.returncode, 0,
                                    result.stdout + result.stderr)
                self.assertEqual(
                    (Path(root) / 'state/calls').read_text().strip(), '1')

    def test_missing_classifier_helper_is_never_retried(self):
        # No inline fallback: if notes_ui_startup_retry.py cannot run, the
        # pre-test stall shape must fail closed, not retry.
        with tempfile.TemporaryDirectory() as root:
            self.write_state(root, ['124'], ['stalled'], ['false'],
                             logs=[STALL_LOG_LINE])
            result = self.run_leg(IPAD_STEP, root, notes_name='ipad',
                                  helper=Path(root) / 'absent-helper.py')
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('absent-helper.py', result.stderr)
            self.assertEqual((Path(root) / 'state/calls').read_text().strip(), '1')

    def test_missing_attempt_log_is_never_retried(self):
        # reason=stalled with no readable attempt log is not retryable.
        with tempfile.TemporaryDirectory() as root:
            self.write_state(root, ['124'], ['stalled'], ['false'], logs=[''])
            result = self.run_leg(IPAD_STEP, root, notes_name='ipad')
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((Path(root) / 'state/calls').read_text().strip(), '1')

    def test_malformed_summary_is_never_retried(self):
        # Exit status alone must not authorize a retry: the summary has to be
        # well formed evidence (here it lacks exitCode).
        with tempfile.TemporaryDirectory() as root:
            self.write_state(root, ['124'], ['stalled'], ['false'],
                             logs=[STALL_LOG_LINE],
                             summaries=['{"reason":"stalled","testsStarted":false}'])
            result = self.run_leg(IPAD_STEP, root, notes_name='ipad')
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((Path(root) / 'state/calls').read_text().strip(), '1')

    def test_real_executed_failure_is_never_retried(self):
        with tempfile.TemporaryDirectory() as root:
            self.write_state(root, ['65'], ['exited'], ['true'],
                             logs=[EXECUTED_FAILURE_LOG_LINE])
            result = self.run_leg(IPAD_STEP, root, notes_name='ipad')
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertEqual((Path(root) / 'state/calls').read_text().strip(), '1')


if __name__ == '__main__':
    unittest.main()
