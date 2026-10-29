"""Ordering, portability and publishing-policy checks for the lean release route.

Two kinds of checks live here:

* a real functional fixture for ``FloeAgent/scripts/release_preflight.sh`` that
  runs the script with a PATH that contains no ``plutil`` (the ubuntu lean-source
  environment) and proves both the pass and the empty-display-name failure;
* workflow assertions for the recovery ordering that main found broken: the
  unsigned IPA must be retained immediately after package validation, before
  dSYM capture, and publishing must stay unsigned-only, exact-SHA and
  idempotent;
* release-mode assertions for the lean route: the normal-release rule
  (2026-10-18) makes the stable latest release the default, an explicitly
  dispatched true keeps the prerelease/not-latest exception, an existing release
  is verified rather than silently converted, and every publish is followed by
  the shared installable-delivery readback gate.

The executable python gates embedded in the workflows are extracted and run
against synthetic asset folders, so the exclusions are exercised, not just
grepped.
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
WORKFLOWS = REPO / '.github' / 'workflows'
RELEASE_TEXT = (WORKFLOWS / 'release-unsigned-ipa.yml').read_text(encoding='utf-8')
DIRECT_TEXT = (WORKFLOWS / 'testflight-direct.yml').read_text(encoding='utf-8')
FEATHER_TEXT = (WORKFLOWS / 'publish-feather-source.yml').read_text(encoding='utf-8')
PREFLIGHT = (REPO / 'FloeAgent' / 'scripts' / 'release_preflight.sh')

RELEASE = yaml.safe_load(RELEASE_TEXT)
DIRECT = yaml.safe_load(DIRECT_TEXT)
FEATHER = yaml.safe_load(FEATHER_TEXT)


def job_block(source: str, job: str) -> str:
    marker = f'\n  {job}:'
    if marker not in source:
        raise AssertionError(f'job {job!r} is missing')
    tail = source.split(marker, 1)[1]
    match = re.search(r'\n  [a-z][a-z0-9-]*:', tail)
    return tail[:match.start()] if match else tail


def step_index(steps: list, name: str) -> int:
    names = [step.get('name') for step in steps]
    return names.index(name)


def extract_heredoc_python(step: dict) -> str:
    lines = step['run'].splitlines()
    start = next(index for index, line in enumerate(lines) if line.strip().endswith("<<'PY'"))
    end = next(index for index in range(start + 1, len(lines)) if lines[index].strip() == 'PY')
    return '\n'.join(lines[start + 1:end]) + '\n'


def extract_release_mode_block(run: str) -> str:
    """Return the shell lines that select the GitHub release mode flags."""
    lines = run.splitlines()
    start = next(index for index, line in enumerate(lines)
                 if line.strip() == 'RELEASE_MODE_ARGS=()')
    end = next(index for index in range(start + 1, len(lines))
               if lines[index].strip() == 'fi')
    return '\n'.join(lines[start:end + 1]) + '\n'


def dispatch_inputs(workflow: dict) -> dict:
    # PyYAML resolves the bare ``on`` key to True in YAML 1.1 mode.
    triggers = workflow.get('on', workflow.get(True))
    return triggers['workflow_dispatch']['inputs']


class PortablePreflightFixtureTests(unittest.TestCase):
    """Run the real preflight script without Apple's plutil on PATH."""

    def run_preflight(self, transform=lambda text: text, env_extra=None):
        root = Path(tempfile.mkdtemp(prefix='floe-preflight-review-'))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        app = root / 'FloeAgent'
        for name in ('project.yml', 'scripts/release_preflight.sh',
                     'scripts/validate_localization_catalog.py',
                     'scripts/verify_apple_upload_metadata.py',
                     'scripts/check_application_pins.py',
                     'scripts/resolved_pins.py',
                     'Package.resolved',
                     'FloeAgent.xcodeproj/project.pbxproj', 'FloeScreenShare/Info.plist',
                     'FloeApp/Entitlements/Floe.entitlements',
                     'FloeApp/Resources/Info.plist',
                     'FloeApp/Resources/InfoPlist.xcstrings',
                     'FloeApp/Resources/Localizable.xcstrings'):
            target = app / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / 'FloeAgent' / name, target)
        # This fixture isolates the portable plist/version checks. The real
        # native-runtime and Office pin gates have their own focused tests and
        # require a much larger source tree, so keep explicit passing stubs
        # rather than letting newly added preflight dependencies fail first.
        (app / 'scripts/audit_native_runtime_free.py').write_text(
            'print("native-runtime-free fixture passed")\n', encoding='utf-8')
        (app / 'scripts/pin_office_host_artifact.py').write_text(
            'print("Office pin fixture passed")\n', encoding='utf-8')
        (app / 'scripts/bootstrap_office_host.py').write_text(
            'LOCK = None\n'
            'def checked_lock(_):\n'
            '    return {}, {}\n', encoding='utf-8')
        # release_preflight.sh also reads the Office capability readout after
        # bootstrap; stub it with the same passing no-op shape so this fixture
        # keeps exercising the portable plist/version checks.
        (app / 'scripts/office_release_gates.py').write_text(
            'def capability_status(_pin):\n'
            '    return {"unproven": [], "failures": []}\n', encoding='utf-8')
        plist_path = app / 'FloeScreenShare/Info.plist'
        plist_path.write_text(transform(plist_path.read_text()))
        # Stage synthetic bilingual release copy for the copied project.yml's
        # version/build so the read-only release-copy gate passes in this
        # portable fixture; the real documents and the gate's failure cases are
        # exercised by test_release_preflight_versions.py.
        project_yml = (app / 'project.yml').read_text()
        version = re.search(r'^\s*MARKETING_VERSION:\s*"?([^"\s]+)', project_yml, re.MULTILINE).group(1)
        build = re.search(r'^\s*CURRENT_PROJECT_VERSION:\s*"?([^"\s]+)', project_yml, re.MULTILINE).group(1)
        series = '.'.join(version.split('.')[:2])
        fixture_tag = f'v{version}-beta.999'
        docs = root / 'docs' / 'releases'
        (docs / 'notes').mkdir(parents=True)
        (docs / 'testflight').mkdir(parents=True)
        (docs / 'notes' / f'RELEASE_NOTES_{version}_BUILD_{build}.md').write_text(
            f'# Floe Agent {version} (build {build})\n\n## 简体中文\n\n内测说明。\n\n'
            '## English\n\nInternal beta notes.\n', encoding='utf-8')
        (docs / 'testflight' / f'TESTFLIGHT_{series}_WHATS_NEW_BUILD_{build}.json').write_text(
            json.dumps({'en-US': 'Internal beta fixture notes.', 'zh-Hans': '内测夹具说明。'},
                       ensure_ascii=False), encoding='utf-8')
        # project.yml declares the first-party FloeMacBridge sibling at
        # ../FloeMacBridge; stage the same tracked, clean layout with the real
        # reviewed manifest (the pin policy pins its digest) so the application
        # pin gate exercises a faithful checkout.
        sibling = root / 'FloeMacBridge'
        sibling.mkdir()
        shutil.copy2(REPO / 'FloeMacBridge' / 'Package.swift',
                     sibling / 'Package.swift')
        git_env = dict(os.environ, GIT_AUTHOR_NAME='Floe Review', GIT_COMMITTER_NAME='Floe Review',
                       GIT_AUTHOR_EMAIL='review@example.invalid',
                       GIT_COMMITTER_EMAIL='review@example.invalid')
        for args in (('init', '-q'), ('add', '.'), ('commit', '-qm', 'fixture'),
                     ('tag', fixture_tag)):
            subprocess.run(['git', *args], cwd=root, env=git_env, check=True,
                           capture_output=True)
        # A shim PATH with git/python3/awk/dirname but deliberately no plutil.
        shim = root / 'shim-bin'
        shim.mkdir()
        for tool in ('git', 'python3', 'awk', 'dirname', 'bash', 'sh', 'uname'):
            found = shutil.which(tool)
            if found:
                (shim / tool).symlink_to(found)
        env = dict(git_env, PATH=str(shim), HOME=str(root))
        if env_extra:
            env.update(env_extra)
        probe = subprocess.run(['bash', '-c', 'command -v plutil || true'], env=env,
                               capture_output=True, text=True)
        self.assertEqual(probe.stdout.strip(), '',
                         'fixture PATH must not expose plutil')
        return subprocess.run(['bash', str(app / 'scripts/release_preflight.sh'),
                               fixture_tag], cwd=root, env=env,
                              capture_output=True, text=True)

    def test_script_does_not_depend_on_apples_plutil(self):
        script = PREFLIGHT.read_text(encoding='utf-8')
        code = '\n'.join(line for line in script.splitlines()
                         if not line.lstrip().startswith('#'))
        self.assertNotIn('plutil', code)
        self.assertIn('plistlib', script)

    def test_preflight_passes_without_plutil_and_reports_display_name(self):
        result = self.run_preflight()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('release preflight OK', result.stdout)
        self.assertIn('localization catalog OK', result.stdout)

    def test_missing_display_name_still_fails_without_plutil(self):
        def strip_display_name(text):
            plist = plistlib.loads(text.encode())
            del plist['CFBundleDisplayName']
            return plistlib.dumps(plist).decode()

        result = self.run_preflight(strip_display_name)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('non-empty CFBundleDisplayName', result.stderr)
        self.assertNotIn('release preflight OK', result.stdout)

    def test_empty_display_name_still_fails_without_plutil(self):
        def blank_display_name(text):
            plist = plistlib.loads(text.encode())
            plist['CFBundleDisplayName'] = '   '
            return plistlib.dumps(plist).decode()

        result = self.run_preflight(blank_display_name)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('non-empty CFBundleDisplayName', result.stderr)


class RecoveryOrderingTests(unittest.TestCase):
    """The unsigned IPA must be recoverable before dSYM capture and signing."""

    @classmethod
    def setUpClass(cls):
        cls.steps = DIRECT['jobs']['upload']['steps']
        cls.reuse = next(step for step in cls.steps
                         if step.get('name', '').startswith('Restore and verify'))

    def test_retained_artifact_precedes_symbols_and_signing(self):
        package = step_index(self.steps, 'Preserve the unsigned device package before signing')
        record = step_index(self.steps,
                            'Record the direct-release provenance inside the retained artifact')
        upload = step_index(self.steps, 'Retain the device artifact for recovery and Feather')
        symbols = step_index(self.steps, 'Retain source-bound private symbols before distribution')
        save = step_index(self.steps, 'Save private symbolication artifact')
        sign = step_index(self.steps, 'Sign, verify, package, and upload to TestFlight')
        evidence = step_index(self.steps, 'Upload TestFlight evidence')
        self.assertEqual(record, package + 1)
        self.assertEqual(upload, record + 1)
        self.assertLess(upload, symbols)
        self.assertLess(symbols, save)
        self.assertLess(save, sign)
        self.assertLess(sign, evidence)

    def test_record_decouples_app_uuid_from_symbol_capture(self):
        record = self.steps[
            step_index(self.steps,
                       'Record the direct-release provenance inside the retained artifact')]
        script = record['run']
        self.assertIn('dwarfdump --uuid', script)
        self.assertNotIn('steps.symbols.outputs', json.dumps(self.steps))
        self.assertNotIn("steps.symbols.outputs.app_uuid", script)
        self.assertEqual(record['env']['SYMBOLS_STATE'], 'capture_required_before_signing')
        self.assertIn("'symbolsState': os.environ['SYMBOLS_STATE']", script)

    def test_symbol_capture_is_a_required_check_after_the_recovery_upload(self):
        symbols = self.steps[
            step_index(self.steps, 'Retain source-bound private symbols before distribution')]
        self.assertEqual(symbols['if'], "inputs.reuse_artifact_run == ''")
        self.assertIn('test "$DSYM_UUID" = "$APP_UUID"', symbols['run'])
        self.assertIn('SYMBOLS-STATE.txt', symbols['run'])
        self.assertIn('state=captured', symbols['run'])
        save = self.steps[step_index(self.steps, 'Save private symbolication artifact')]
        self.assertEqual(save['with']['retention-days'], 90)

    def test_rebuild_free_retry_requires_the_private_symbols_artifact(self):
        script = self.reuse['run']
        self.assertIn('--require-symbols-artifact', script)
        self.assertIn('symbols_state=captured_in_producing_run_', script)
        self.assertIn('symbolsArtifactId', script)
        # Upload is only skipped when the producer already has accepted evidence.
        self.assertIn('upload_required=false', script)
        self.assertIn('upload_required=true', script)
        for step in self.steps:
            if step.get('name') in ('Sign, verify, package, and upload to TestFlight',
                                    'Upload TestFlight evidence',
                                    'Install App Store Connect API key'):
                self.assertEqual(
                    step['if'],
                    "inputs.reuse_artifact_run == '' || steps.reuse.outputs.upload_required == 'true'")

    def test_rebuild_free_retry_verification_passes_extraction_paths(self):
        # The verifier refuses a bare metadata-only call ("Provide either
        # --artifact-zip with --extract-dir or explicit extracted paths"), which
        # the frozen build 201 recovery hit after TestFlight had already accepted
        # the upload. Resolve the artifact id from GitHub's payload instead and
        # keep exactly one verifier invocation, the full zip verification.
        invocations = self.reuse['run'].split(
            'python3 scripts/verify_direct_unsigned_artifact.py')[1:]
        self.assertEqual(len(invocations), 1, invocations)
        self.assertIn('--artifact-zip "$RUNNER_TEMP/DirectReuseArtifact.zip"', invocations[0])
        self.assertIn('--extract-dir "$EXTRACT"', invocations[0])
        self.assertNotIn('metadata.json', self.reuse['run'])
        self.assertIn('ARTIFACT_ID="$(jq -r', self.reuse['run'])
        self.assertIn("select(.name == $n and (.expired | not))", self.reuse['run'])


class RebuildDiagnosticsControlFlowTests(unittest.TestCase):
    """A successful rebuild must reach payload packaging; a failed one must not.

    The build 202 diagnostics commit added the failure summary with an
    unconditional ``exit "$build_status"`` after the branch, so every
    successful rebuild exited before the STABLE_APP_PATH verification and the
    FloeSignedPayload preparation and no app was ever packaged. These checks
    pin the corrected control flow: the exit lives inside the failure branch,
    the packaging lines sit after the branch with no earlier exit, and the
    extracted failure branch is executed to prove both paths rather than
    merely grepping for them.
    """

    FAILURE_IF = 'if [[ "$build_status" -ne 0 ]]; then'
    REBUILD_STEP = 'Rebuild the exact tag with the accepted App Store SDK'

    @classmethod
    def setUpClass(cls):
        cls.steps = DIRECT['jobs']['upload']['steps']
        cls.rebuild = cls.steps[step_index(cls.steps, cls.REBUILD_STEP)]
        cls.script = cls.rebuild['run']

    @classmethod
    def failure_branch_lines(cls):
        lines = cls.script.splitlines()
        start = next(index for index, line in enumerate(lines)
                     if line.strip() == cls.FAILURE_IF)
        end = next(index for index in range(start + 1, len(lines))
                   if lines[index].strip() == 'fi')
        return lines, start, end

    def test_failure_branch_prints_diagnostics_and_exits_nonzero(self):
        lines, start, end = self.failure_branch_lines()
        body = '\n'.join(lines[start + 1:end])
        self.assertIn('::group::xcodebuild error/warning summary', body)
        self.assertIn('grep -E "error:|warning:" "$BUILD_LOG"', body)
        self.assertIn('::group::xcodebuild log tail', body)
        self.assertIn('tail -n 120 "$BUILD_LOG"', body)
        self.assertIn('exit "$build_status"', body)
        # Exactly one status exit exists in the whole step, and it is the
        # branch's own: a second top-level exit would repeat the build 202
        # early-exit bug that skipped packaging on success.
        self.assertEqual(self.script.count('exit "$build_status"'), 1)
        self.assertNotIn('exit "$build_status"', '\n'.join(lines[end:]))
        self.assertEqual(lines[end].strip(), 'fi')

    def test_packaging_lines_run_only_after_the_failure_branch(self):
        lines, start, end = self.failure_branch_lines()
        tail = '\n'.join(lines[end + 1:])
        for required in (
                'STABLE_APP_PATH="$(find "$RUNNER_TEMP/FloeStableDeviceDerivedData'
                '/Build/Products/Release-iphoneos"',
                'test -n "$STABLE_APP_PATH"',
                "test \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "
                "\"$STABLE_APP_PATH/Info.plist\")\" = org.floeagent.ios",
                'mkdir -p "$RUNNER_TEMP/FloeSignedPayload/Payload"',
                'ditto "$STABLE_APP_PATH" '
                '"$RUNNER_TEMP/FloeSignedPayload/Payload/$(basename "$STABLE_APP_PATH")"'):
            with self.subTest(required=required):
                self.assertIn(required, tail)
        # Nothing between the failure branch and packaging may terminate the
        # step, or success could again stop before FloeSignedPayload exists.
        self.assertNotIn('exit', tail)

    def run_failure_branch(self, build_status):
        lines, start, end = self.failure_branch_lines()
        with tempfile.TemporaryDirectory(prefix='floe-rebuild-flow-') as folder:
            root = Path(folder)
            log = root / 'rebuild-xcodebuild.log'
            log.write_text('note: harmless build noise\n'
                           'FloeApp/App.swift:12: warning: unused variable\n'
                           'FloeApp/App.swift:99: error: cannot find scope\n')
            harness = root / 'harness.sh'
            harness.write_text('\n'.join([
                'set -euo pipefail',
                f'BUILD_LOG={shlex.quote(str(log))}',
                f'build_status={int(build_status)}',
                *lines[start:end + 1],
                'echo reached-packaging',
                '',
            ]))
            return subprocess.run(['bash', str(harness)], capture_output=True,
                                  text=True)

    def test_success_reaches_packaging_without_diagnostics(self):
        result = self.run_failure_branch(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('reached-packaging', result.stdout)
        self.assertNotIn('xcodebuild error/warning summary', result.stdout)
        self.assertNotIn('xcodebuild log tail', result.stdout)

    def test_failure_prints_diagnostics_and_exits_before_packaging(self):
        result = self.run_failure_branch(65)
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertNotIn('reached-packaging', result.stdout)
        self.assertIn('xcodebuild error/warning summary', result.stdout)
        self.assertIn('cannot find scope', result.stdout)
        self.assertIn('xcodebuild log tail', result.stdout)

    def test_failure_diagnostics_upload_stays_failure_only(self):
        upload = self.steps[step_index(
            self.steps, 'Upload rebuild diagnostics on failure')]
        self.assertIn('always()', upload['if'])
        self.assertIn("inputs.reuse_artifact_run == ''", upload['if'])
        self.assertIn("steps.rebuild.outcome == 'failure'", upload['if'])
        self.assertIn('rebuild-xcodebuild.log', upload['with']['path'])
        self.assertIn('FloeRebuild.xcresult', upload['with']['path'])


class LeanPublishPolicyTests(unittest.TestCase):
    IPA = 'Floe-Agent-1.7.0-build192-unsigned.ipa'

    @classmethod
    def setUpClass(cls):
        cls.publish = job_block(RELEASE_TEXT, 'lean-publish')
        cls.steps = {step.get('name'): step for step in RELEASE['jobs']['lean-publish']['steps']}
        cls.publish_step = cls.steps['Publish the attested unsigned release without clobbering']

    def good_existing_assets(self):
        return [self.IPA, f'{self.IPA}.sha256', 'TEST-SUMMARY.txt', 'DIRECT-PROVENANCE.json']

    def run_existing_release_gate(self, names, *, is_prerelease, requested, is_draft=False):
        root = Path(tempfile.mkdtemp(prefix='floe-existing-release-'))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        script = root / 'existing_release_gate.py'
        script.write_text(extract_heredoc_python(self.publish_step))
        record = root / 'release.json'
        record.write_text(json.dumps({
            'assets': [{'name': name} for name in names],
            'isPrerelease': is_prerelease,
            'isDraft': is_draft,
        }))
        return subprocess.run(
            [sys.executable, str(script), str(record), self.IPA, requested,
             'v1.7.0-beta.999'],
            capture_output=True, text=True)

    def test_exact_sha_attestation_and_evidence_union(self):
        fetch = self.steps['Download, digest and verify the retained unsigned IPA']['run']
        self.assertIn('--expect-testflight-accepted', fetch)
        self.assertIn('--require-symbols-artifact', fetch)
        self.assertIn('--evidence-artifacts', fetch)
        self.assertIn('caller-artifacts.json', fetch)
        self.assertIn('--allow-running', fetch)
        self.assertIn('--source-digest "$SOURCE_SHA"', self.publish)
        self.assertIn(
            '--signer-workflow "$GITHUB_REPOSITORY/.github/workflows/release-unsigned-ipa.yml"',
            self.publish)
        self.assertIn('actions/attest-build-provenance@', self.publish)

    def test_retained_artifact_verification_always_passes_extraction_paths(self):
        # The verifier refuses a bare metadata-only call ("Provide either
        # --artifact-zip with --extract-dir or explicit extracted paths"), which
        # the first lean release hit after its TestFlight upload had already been
        # accepted. Resolve the artifact id from GitHub's payload instead and
        # keep exactly one verifier invocation, the full zip verification.
        fetch = self.steps['Download, digest and verify the retained unsigned IPA']['run']
        invocations = fetch.split(
            'python3 FloeAgent/scripts/verify_direct_unsigned_artifact.py')[1:]
        self.assertEqual(len(invocations), 1, invocations)
        self.assertIn('--artifact-zip "$ARTIFACTS/artifact.zip"', invocations[0])
        self.assertIn('--extract-dir "$ARTIFACTS/extracted"', invocations[0])
        self.assertNotIn('metadata.json', fetch)
        self.assertIn('ARTIFACT_ID="$(jq -r', fetch)
        self.assertIn("select(.name == $n and (.expired | not))", fetch)

    def test_publish_is_idempotent_and_never_clobbers(self):
        self.assertIn('gh release view "$RELEASE_TAG"', self.publish)
        self.assertIn('--json assets,isPrerelease,isDraft', self.publish)
        self.assertIn('gh release download "$RELEASE_TAG"', self.publish)
        self.assertIn('sha256sum "$PUBLISHED/$ASSET_NAME"', self.publish)
        self.assertNotRegex(self.publish, r'gh release (create|upload)[^\n]*--clobber')
        self.assertNotIn('gh release edit', self.publish)
        self.assertNotIn('gh release delete', self.publish)

    def test_release_mode_flags_for_both_dispatch_paths(self):
        block = extract_release_mode_block(self.publish_step['run'])
        for requested, flags in (('true', ['--prerelease', '--latest=false']),
                                 ('false', ['--latest=true'])):
            with self.subTest(github_prerelease=requested):
                result = subprocess.run(
                    ['bash', '-c', block + '\nprintf "%s\\n" "${RELEASE_MODE_ARGS[@]}"\n'],
                    env=dict(os.environ, RELEASE_PRERELEASE=requested),
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.split(), flags)

    def test_create_command_uses_the_selected_release_mode(self):
        run = self.publish_step['run']
        self.assertIn('--verify-tag "${RELEASE_MODE_ARGS[@]}"', run)
        # Neither mode may be hard-coded back into the create command, and the
        # created release is published directly (never left as a draft).
        self.assertNotIn('--verify-tag --prerelease', run)
        self.assertNotIn('--verify-tag --latest', run)
        self.assertNotIn('--draft', run)

    def test_existing_release_mode_is_verified_and_never_silently_changed(self):
        good = self.good_existing_assets()
        for is_prerelease, requested in ((True, 'false'), (False, 'true')):
            with self.subTest(isPrerelease=is_prerelease, requested=requested):
                mismatch = self.run_existing_release_gate(
                    good, is_prerelease=is_prerelease, requested=requested)
                self.assertNotEqual(mismatch.returncode, 0)
                self.assertIn('refusing to change an existing release', mismatch.stderr)
        draft = self.run_existing_release_gate(
            good, is_prerelease=False, is_draft=True, requested='false')
        self.assertNotEqual(draft.returncode, 0)

    def test_existing_release_asset_gate_rejects_signed_assets(self):
        good = self.good_existing_assets()
        for requested, is_prerelease in (('true', True), ('false', False)):
            with self.subTest(requested=requested):
                ok = self.run_existing_release_gate(
                    good, is_prerelease=is_prerelease, requested=requested)
                self.assertEqual(ok.returncode, 0, ok.stderr)
        for bad in ('FloeAgent.ipa', 'Floe-Agent-1.7.0-build192-signed.ipa',
                    'Floe.mobileprovision', 'distribution.p12'):
            with self.subTest(bad=bad):
                failed = self.run_existing_release_gate(
                    good + [bad], is_prerelease=True, requested='true')
                self.assertNotEqual(failed.returncode, 0, bad)

    def test_public_assets_are_unsigned_only(self):
        assemble = self.steps['Assemble only the public unsigned release assets']
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            assets = root / 'release-assets'
            assets.mkdir()
            ipa = f'Floe-Agent-1.7.0-build192-unsigned.ipa'
            (assets / ipa).write_bytes(b'ipa')
            (assets / f'{ipa}.sha256').write_text('00  ' + ipa + '\n')
            (assets / 'TEST-SUMMARY.txt').write_text('signed_ipas_published=false\n')
            (assets / 'DIRECT-PROVENANCE.json').write_text(json.dumps(
                {'signedPayloadPublished': False, 'signedIpaPublished': False}))
            script = root / 'gate.py'
            script.write_text(extract_heredoc_python(assemble))
            ok = subprocess.run([sys.executable, str(script)], cwd=root,
                                capture_output=True, text=True)
            self.assertEqual(ok.returncode, 0, ok.stderr)
            for pollution in ('FloeAgent.ipa', 'Floe-Agent-1.7.0-build192-signed.ipa',
                              'FloeAgent.mobileprovision', 'distribution.p12',
                              'Floe Agent.app.dSYM', 'FloeAgent.ipa.zip'):
                with self.subTest(pollution=pollution):
                    path = assets / pollution
                    path.write_bytes(b'secret')
                    failed = subprocess.run([sys.executable, str(script)], cwd=root,
                                            capture_output=True, text=True)
                    self.assertNotEqual(failed.returncode, 0, pollution)
                    path.unlink()

    def test_feather_gate_rejects_any_signed_ipa(self):
        step = next(step for step in FEATHER['jobs']['publish-source']['steps']
                    if step.get('name') == 'Require a public unsigned-only asset set')
        script_text = extract_heredoc_python(step)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            script = root / 'feather_gate.py'
            script.write_text(script_text)
            env = dict(os.environ, RUNNER_TEMP=str(root))

            def run(assets):
                (root / 'feather-assets.json').write_text(json.dumps({'assets': assets}))
                return subprocess.run([sys.executable, str(script)], env=env,
                                      capture_output=True, text=True,
                                      cwd=str(REPO))

            unsigned = [{'name': 'Floe-Agent-1.7.0-build192-unsigned.ipa'},
                        {'name': 'Floe-Agent-1.7.0-build192-unsigned.ipa.sha256'}]
            self.assertEqual(run(unsigned).returncode, 0)
            for pollution in ({'name': 'FloeAgent.ipa'},
                              {'name': 'Floe-Agent-1.7.0-build192-signed.ipa'},
                              {'name': 'Foo.mobileprovision'},
                              {'name': 'Foo.p12'}):
                with self.subTest(pollution=pollution):
                    self.assertNotEqual(run(unsigned + [pollution]).returncode, 0)
            # The xcresult zip assets of historical releases stay allowed.
            self.assertEqual(run(unsigned + [
                {'name': 'FloeAgent-AppRegressionTests.xcresult.zip'}]).returncode, 0)

    def test_lean_source_uses_githube_token_and_verifies_remote_ref(self):
        source = job_block(RELEASE_TEXT, 'lean-source')
        self.assertIn('contents: write', source)
        self.assertIn('git tag "$TAG" "$GITHUB_SHA"', source)
        self.assertIn('git push origin "refs/tags/$TAG"', source)
        self.assertNotIn('git push --force', source)
        self.assertNotIn('git push -f', source)
        self.assertNotIn('secrets.', source)
        self.assertIn('git fetch --no-tags --force origin "+refs/tags/$TAG:refs/tags/$TAG"', source)
        self.assertIn('test "$(git rev-parse "refs/tags/$TAG^{commit}")" = "$GITHUB_SHA"', source)

    def test_lean_build_reusable_call_permissions_allow_artifact_reads(self):
        build = job_block(RELEASE_TEXT, 'lean-build')
        self.assertIn('actions: read', build)
        self.assertIn('contents: read', build)
        self.assertIn('secrets: inherit', build)
        direct_permissions = DIRECT.get('permissions') or {}
        self.assertEqual(direct_permissions.get('contents'), 'read')
        self.assertEqual(direct_permissions.get('actions'), 'read')


class LeanReleaseModeInputTests(unittest.TestCase):
    """The dispatch input defaults to the normal stable latest release and is wired."""

    @classmethod
    def setUpClass(cls):
        cls.inputs = dispatch_inputs(RELEASE)
        cls.publish = next(
            step for step in RELEASE['jobs']['lean-publish']['steps']
            if step.get('name', '').startswith('Publish the attested unsigned'))

    def test_mode_input_defaults_to_the_normal_stable_latest_release(self):
        # 2026-10-18 normal-release rule: the default is the stable latest
        # release so AltStore/Feather resolve the newest installable build; the
        # historical prerelease mode remains an explicit opt-in exception.
        mode = self.inputs['github_prerelease']
        self.assertEqual(mode['type'], 'boolean')
        self.assertIs(mode['default'], False)
        self.assertFalse(mode['required'])
        description = mode['description'].lower()
        for token in ('prerelease', 'latest', 'lean'):
            self.assertIn(token, description)

    def test_lean_release_description_names_the_mode_input(self):
        description = self.inputs['lean_release']['description']
        self.assertIn('github_prerelease', description)
        self.assertNotIn('GitHub prerelease', description)

    def test_publish_step_reads_the_dispatch_input(self):
        job_env = RELEASE['jobs']['lean-publish']['env']
        self.assertEqual(job_env['RELEASE_PRERELEASE'], '${{ inputs.github_prerelease }}')
        self.assertIn('RELEASE_PRERELEASE', self.publish['run'])
        evidence = next(step for step in RELEASE['jobs']['lean-publish']['steps']
                        if step.get('name') == 'Record the lean delivery evidence')
        self.assertIn('github_release_prerelease=$RELEASE_PRERELEASE', evidence['run'])


class PublicationReadbackContractTests(unittest.TestCase):
    """Both cloud publish routes and the feed refresh verify the live result.

    2026-10-18 normal-release rule: every public App release must be a stable
    latest release carrying the verified unsigned IPA, and the AltStore/Feather
    feed must be read back against the published asset. These checks keep the
    fail-closed readback wired after publishing and before any downstream sync.
    """

    @classmethod
    def setUpClass(cls):
        cls.publish_job = RELEASE['jobs']['publish-release']
        cls.lean_job = RELEASE['jobs']['lean-publish']
        cls.feather_job = FEATHER['jobs']['publish-source']

    def step(self, job, name):
        return next(step for step in job['steps'] if step.get('name') == name)

    def test_legacy_source_guard_rejects_a_different_dispatch_commit(self):
        run = self.step(RELEASE['jobs']['prepare-release'],
                        'Freeze and validate the release source before parallel qualification')['run']
        guard = run.split('FloeAgent/scripts/release_preflight.sh', 1)[0]
        with tempfile.TemporaryDirectory(prefix='floe-release-source-') as folder:
            repo = Path(folder)
            env = dict(os.environ, GIT_AUTHOR_NAME='Floe Review',
                       GIT_COMMITTER_NAME='Floe Review',
                       GIT_AUTHOR_EMAIL='review@example.invalid',
                       GIT_COMMITTER_EMAIL='review@example.invalid')
            for args in (('init', '-q'), ('commit', '--allow-empty', '-qm', 'source'),
                         ('tag', 'v1.7.99')):
                subprocess.run(['git', *args], cwd=repo, env=env, check=True,
                               capture_output=True)
            commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo,
                                             text=True).strip()
            for source, succeeds in ((commit, True), ('0' * 40, False)):
                result = subprocess.run(['bash', '-c', guard], cwd=repo,
                                        env=dict(env, RELEASE_TAG='v1.7.99', GITHUB_SHA=source),
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)
                if not succeeds:
                    self.assertIn('--ref v1.7.99', result.stderr)

    def test_legacy_publish_reads_back_after_publishing_before_gitee(self):
        names = [step.get('name') for step in self.publish_job['steps']]
        readback = 'Read back the published release as an installable delivery'
        self.assertLess(names.index('Publish the transport-accepted paired release'),
                        names.index(readback))
        self.assertLess(names.index(readback),
                        names.index('Request Gitee synchronization for the published release'))
        run = self.step(self.publish_job, readback)['run']
        self.assertIn('FloeAgent/scripts/verify_github_release_publication.py', run)
        self.assertIn('gh api "repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG"', run)
        self.assertIn('gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$RELEASE_TAG"', run)
        self.assertIn('--expect-source-sha "$SOURCE_SHA"', run)
        self.assertIn('--staged-dir release-assets', run)
        self.assertIn('releases/latest', run)
        self.assertIn('*-beta.*', run)
        self.assertIn('set -euo pipefail', run)

    def test_legacy_publish_uses_the_normal_stable_mode_for_stable_tags(self):
        publish = self.step(self.publish_job, 'Publish the transport-accepted paired release')
        run = publish['run']
        self.assertIn('case "$RELEASE_TAG" in', run)
        self.assertIn('*-beta.*) RELEASE_MODE_ARGS=(--prerelease --latest=false)', run)
        self.assertIn('*) RELEASE_MODE_ARGS=(--latest=true)', run)
        self.assertIn('gh release edit "$RELEASE_TAG" --notes-file release-notes.md --draft=false',
                      run)
        self.assertIn('gh release create "$RELEASE_TAG" release-assets/*', run)
        self.assertIn('"${RELEASE_MODE_ARGS[@]}"', run)
        # The old hardcoded prerelease must not return to the App release path.
        self.assertNotIn('--draft=false --prerelease', run)
        self.assertNotIn('--verify-tag --prerelease', run)

    def test_lean_publish_reads_back_the_attested_release(self):
        names = [step.get('name') for step in self.lean_job['steps']]
        readback = 'Read back the published release as an installable delivery'
        self.assertLess(names.index('Publish the attested unsigned release without clobbering'),
                        names.index(readback))
        self.assertLess(names.index(readback),
                        names.index('Request Gitee synchronization for the published release'))
        run = self.step(self.lean_job, readback)['run']
        self.assertIn('verify_github_release_publication.py', run)
        self.assertIn('--expect-ipa-sha256 "${{ steps.fetch.outputs.ipa_sha256 }}"', run)
        self.assertIn('--staged-dir release-assets', run)
        self.assertIn('--expect-source-sha "$SOURCE_SHA"', run)
        self.assertIn('RELEASE_PRERELEASE', run)

    def test_readback_script_exists_and_compiles(self):
        script = REPO / 'FloeAgent' / 'scripts' / 'verify_github_release_publication.py'
        self.assertTrue(script.is_file())
        subprocess.run([sys.executable, '-m', 'py_compile', str(script)], check=True)

    def test_feather_feed_is_read_back_live_and_bound_to_the_asset(self):
        names = [step.get('name') for step in self.feather_job['steps']]
        readback = 'Read back the live feed and the bound release asset'
        self.assertLess(names.index('Publish the stable source URL'), names.index(readback))
        run = self.step(self.feather_job, readback)['run']
        self.assertIn('raw.githubusercontent.com/$GITHUB_REPOSITORY/main/feather.json', run)
        self.assertIn('releases/tags/$RELEASE_TAG', run)
        self.assertIn("asset.get('digest')", run)
        self.assertIn("asset.get('browser_download_url')", run)
        self.assertIn('"$RELEASE_TAG" "$(cat "$RUNNER_TEMP/feather-source-sha.txt")"', run)
        self.assertIn('buildVersion', run)
        # Retry until the live feed MATCHES the expected build, not merely until
        # any HTTP 200 arrives: bounded timeout + cache-busting + a matching
        # checker inside the loop, then a hard failure if it never converges.
        self.assertIn('--max-time 30', run)
        self.assertIn("Cache-Control: no-cache", run)
        self.assertIn('check_feed.py', run)
        self.assertIn('test "$matched" = true', run)
        self.assertLess(run.index('for attempt in $(seq 1 10)'),
                        run.index('python3 "$RUNNER_TEMP/check_feed.py"'))

    def test_reusable_workflows_are_only_called_from_job_level(self):
        # GitHub Actions only supports reusable workflows at jobs.<id>.uses;
        # a step-level .github/workflows reference is rejected at run creation.
        for workflow_name in ('release-unsigned-ipa.yml', 'publish-feather-source.yml'):
            workflow = yaml.safe_load((WORKFLOWS / workflow_name).read_text())
            for job_id, job in workflow['jobs'].items():
                for step in job.get('steps', []):
                    uses = step.get('uses', '')
                    self.assertFalse(uses.startswith('./.github/workflows/'),
                                     f'{workflow_name}:{job_id} has a step-level reusable workflow: {uses}')

    def test_all_normal_publish_routes_await_the_same_feather_workflow(self):
        expected = {
            'publish-release': ('feather-normal-release',
                                '${{ needs.publish-release.outputs.tag }}', self.publish_job),
            'lean-publish': ('feather-lean-release',
                             '${{ needs.lean-publish.outputs.tag }}', self.lean_job),
            'local-publish': ('feather-local-release',
                              '${{ needs.local-publish.outputs.tag }}',
                              RELEASE['jobs']['local-publish']),
        }
        for publisher, (feather_job_id, tag_expression, job) in expected.items():
            with self.subTest(job=publisher):
                self.assertEqual(job['outputs']['tag'],
                                 {'publish-release': '${{ needs.build-verify-release.outputs.tag }}',
                                  'lean-publish': '${{ needs.lean-source.outputs.tag }}',
                                  'local-publish': '${{ inputs.tag }}'}[publisher])
                feather_job = RELEASE['jobs'][feather_job_id]
                self.assertEqual(feather_job['uses'],
                                 './.github/workflows/publish-feather-source.yml')
                self.assertEqual(feather_job['needs'], [publisher])
                self.assertEqual(feather_job['if'], f"needs.{publisher}.result == 'success'")
                self.assertEqual(feather_job['with']['tag'], tag_expression)
                self.assertEqual(feather_job['permissions']['contents'], 'write')
                raw = job_block(RELEASE_TEXT, publisher)
                # No detached run-ID heuristic: the called workflow either
                # succeeds (and reads the live feed back) or the release fails.
                self.assertNotIn('gh run list', raw)
                self.assertNotIn('gh workflow run publish-feather-source.yml', raw)
        triggers = FEATHER.get('on', FEATHER.get(True))
        self.assertIn('workflow_call', triggers)
        call_input = triggers['workflow_call']['inputs']['tag']
        self.assertEqual(call_input['type'], 'string')
        self.assertTrue(call_input['required'])
        self.assertEqual(FEATHER['concurrency'],
                         {'group': 'floe-feather-source', 'cancel-in-progress': False})
        # publish-release previously granted only contents: write; the called
        # workflow needs the token scopes it declares.
        for scope in ('contents', 'actions', 'attestations'):
            self.assertIn(scope, self.publish_job['permissions'])

    def test_local_publish_requires_the_dispatch_ref_to_be_the_frozen_tag(self):
        job = RELEASE['jobs']['local-publish']
        names = [step.get('name') for step in job['steps']]
        preflight_name = 'Require the local tag and release copy before any publication'
        preflight = self.step(job, preflight_name)['run']
        self.assertLess(names.index(preflight_name),
                        names.index('Download the private draft transport and verify local provenance'))
        self.assertLess(names.index(preflight_name), names.index('Attest the exact unsigned IPA bytes'))
        self.assertIn('"$GITHUB_SHA" != "$TAG_COMMIT"', preflight)
        self.assertIn('"$GITHUB_REF" != "refs/tags/$RELEASE_TAG"', preflight)
        self.assertIn('--ref $RELEASE_TAG', preflight)
        self.assertIn('Refusing before transport download, attestation or publication', preflight)

    def test_local_publish_source_context_guard_runs_and_fails_closed(self):
        run = self.step(
            RELEASE['jobs']['local-publish'],
            'Require the local tag and release copy before any publication')['run']
        lines = run.splitlines()
        start = next(index for index, line in enumerate(lines)
                     if line.strip().startswith('TAG_COMMIT='))
        end = next(index for index in range(start, len(lines))
                   if lines[index].strip() == 'fi')
        guard = 'set -euo pipefail\n' + '\n'.join(lines[start:end + 1]) + '\n'
        with tempfile.TemporaryDirectory(prefix='floe-local-ref-guard-') as folder:
            repo = Path(folder)
            env = dict(os.environ, GIT_AUTHOR_NAME='Floe Review',
                       GIT_COMMITTER_NAME='Floe Review',
                       GIT_AUTHOR_EMAIL='review@example.invalid',
                       GIT_COMMITTER_EMAIL='review@example.invalid')
            for args in (('init', '-q'), ('commit', '--allow-empty', '-qm', 'frozen'),
                         ('tag', 'v1.7.35')):
                subprocess.run(['git', *args], cwd=repo, env=env, check=True,
                               capture_output=True)
            commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo,
                                             text=True).strip()
            script = repo / 'guard.sh'
            script.write_text(guard)

            def check(sha, ref):
                return subprocess.run(
                    ['bash', str(script)], cwd=repo,
                    env=dict(env, RELEASE_TAG='v1.7.35', GITHUB_SHA=sha, GITHUB_REF=ref),
                    capture_output=True, text=True)

            ok = check(commit, 'refs/tags/v1.7.35')
            self.assertEqual(ok.returncode, 0, ok.stderr)
            wrong_ref = check(commit, 'refs/heads/main')
            self.assertNotEqual(wrong_ref.returncode, 0)
            self.assertIn('--ref v1.7.35', wrong_ref.stderr)
            wrong_sha = check('0' * 40, 'refs/tags/v1.7.35')
            self.assertNotEqual(wrong_sha.returncode, 0)
            self.assertIn('attestation source digest', wrong_sha.stderr)

    def test_local_publish_requires_an_explicit_distinct_transport_tag(self):
        job = RELEASE['jobs']['local-publish']
        transport = self.step(
            job, 'Download the private draft transport and verify local provenance')['run']
        self.assertIn('TRANSPORT_TAG="$TRANSPORT_TAG_INPUT"', transport)
        self.assertIn('if [[ -z "$TRANSPORT_TAG" ]]', transport)
        self.assertIn('if [[ "$TRANSPORT_TAG" == "$RELEASE_TAG" ]]', transport)
        self.assertIn('must differ from the public release tag', transport)
        self.assertNotIn('${TRANSPORT_TAG_INPUT:-$RELEASE_TAG}', transport)

    def test_all_normal_routes_audit_the_ipa_before_attestation_or_publication(self):
        cases = {
            'publish-release': (
                'Download accepted-SDK focused-test evidence',
                'Publish the transport-accepted paired release', 'release-assets'),
            'lean-publish': (
                'Download, digest and verify the retained unsigned IPA',
                'Attest the unsigned IPA provenance',
                '$RUNNER_TEMP/DirectArtifact/extracted'),
        }
        audit = 'Audit the staged unsigned IPA and device binary before publishing'
        for job_id, (before, after, folder) in cases.items():
            with self.subTest(job=job_id):
                job = RELEASE['jobs'][job_id]
                names = [step.get('name') for step in job['steps']]
                self.assertLess(names.index(before), names.index(audit))
                self.assertLess(names.index(audit), names.index(after))
                script = self.step(job, audit)['run']
                self.assertIn('publication.audit_staged_ipa', script)
                self.assertIn(folder, script)
                self.assertNotIn('LC_BUILD_VERSION', script)
                self.assertNotIn('struct.unpack', script)

    def test_local_publish_audits_device_binary_before_attestation_and_publish(self):
        job = RELEASE['jobs']['local-publish']
        names = [step.get('name') for step in job['steps']]
        audit = 'Audit the staged unsigned IPA and device binary before attestation'
        self.assertLess(names.index('Package the unsigned IPA from the archived device build'),
                        names.index(audit))
        self.assertLess(names.index(audit), names.index('Attest the exact unsigned IPA bytes'))
        self.assertLess(names.index(audit),
                        names.index('Publish the normal stable release without clobbering'))
        script = self.step(job, audit)['run']
        # The pre-attestation gate calls the shared publication helper; it must
        # not grow a second Mach-O parser or a weaker inlined identity check.
        self.assertIn('publication.audit_staged_ipa', script)
        self.assertIn('verify_github_release_publication.py', script)
        self.assertIn("record['sourceCommit'] == os.environ['SOURCE_SHA']", script)
        self.assertNotIn('LC_BUILD_VERSION', script)
        self.assertNotIn('struct.unpack', script)

    def test_local_publish_public_asset_allowlist_and_minimal_provenance(self):
        job = RELEASE['jobs']['local-publish']
        package = self.step(job, 'Package the unsigned IPA from the archived device build')['run']
        self.assertIn('local-private-evidence', package)
        self.assertIn("assert names == {asset, asset + '.sha256', 'PROVENANCE.json'}", package)
        self.assertIn("'sourceCommit': source", package)
        self.assertIn("'ipaSHA256': digest", package)
        self.assertIn("'unsigned': True", package)
        self.assertIn("'appRebuilt': False", package)
        # The raw local provenance/normalization/pdfium reports must never be
        # copied into the public asset folder.
        self.assertNotIn('provenance.json" release-assets', package)
        self.assertNotIn('bundle-normalization.json" release-assets', package)
        self.assertNotIn('pdfium-linkage.json" release-assets', package)
        publish = self.step(job, 'Publish the normal stable release without clobbering')['run']
        self.assertIn('gh release create "$RELEASE_TAG" release-assets/*', publish)
        self.assertNotIn('symbols/', job_block(RELEASE_TEXT, 'local-publish'))
        retained = self.step(job, 'Retain private local packaging and readback evidence')
        self.assertIn('local-private-evidence/', retained['with']['path'])

    def feed_checker(self) -> str:
        return extract_heredoc_python(
            self.step(self.feather_job, 'Read back the live feed and the bound release asset'))

    def run_feed_check(self, *, live, published, generated, tag='v1.7.35',
                       source='a' * 40):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            paths = []
            for name, payload in (('live.json', live), ('published.json', published),
                                  ('generated.json', generated)):
                path = root / name
                path.write_text(json.dumps(payload))
                paths.append(str(path))
            checker = root / 'check_feed.py'
            checker.write_text(self.feed_checker())
            return subprocess.run([sys.executable, str(checker), *paths, tag, source],
                                  capture_output=True, text=True)

    def feed_fixture(self, *, tag='v1.7.35', version='1.7.35', build='276',
                     source='a' * 40):
        name = f'Floe-Agent-{version}-build{build}-unsigned.ipa'
        url = (f'https://github.com/JiangNanGenius/floe-agent/releases/download/'
               f'{tag}/{name}')
        entry = {'version': version, 'buildVersion': build, 'downloadURL': url,
                 'size': 1234, 'sha256': 'b' * 64, 'sourceCommit': source}
        live_app = {'bundleIdentifier': 'org.floeagent.ios', 'versions': [entry]}
        generated = {'apps': [{'bundleIdentifier': 'org.floeagent.ios',
                               'versions': [dict(entry)]}]}
        published = {'tag_name': tag, 'draft': False,
                     'published_at': '2026-10-18T00:00:00Z',
                     'assets': [{'name': name, 'browser_download_url': url,
                                 'state': 'uploaded', 'size': entry['size'],
                                 'digest': 'sha256:' + entry['sha256']}]}
        return dict(live={'apps': [live_app]}, published=published,
                    generated=generated, tag=tag, source=source,
                    entry=entry, name=name, url=url)

    def test_feed_readback_binds_the_exact_published_asset_url(self):
        fixture = self.feed_fixture()
        ok = self.run_feed_check(**{key: fixture[key]
                                    for key in ('live', 'published', 'generated', 'tag', 'source')})
        self.assertEqual(ok.returncode, 0, ok.stderr)
        # Same basename on a different host/path is not the published asset.
        fixture['published']['assets'][0]['browser_download_url'] = (
            'https://example.invalid/' + fixture['name'])
        mismatch = self.run_feed_check(**{key: fixture[key]
                                          for key in ('live', 'published', 'generated', 'tag', 'source')})
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn('browser_download_url', mismatch.stderr)

    def test_feed_readback_rejects_wrong_tag_version_or_source(self):
        fixture = self.feed_fixture()
        cases = {
            'wrong release tag': ('published', 'tag_name', 'v1.7.34'),
            'wrong feed version': ('generated', None, None),
            'wrong source commit': ('generated', None, None),
        }
        for label, (target, key, value) in cases.items():
            with self.subTest(label=label):
                payload = json.loads(json.dumps(fixture[target]))
                if label == 'wrong feed version':
                    payload['apps'][0]['versions'][0]['version'] = '1.7.34'
                elif label == 'wrong source commit':
                    payload['apps'][0]['versions'][0]['sourceCommit'] = 'c' * 40
                else:
                    payload[key] = value
                result = self.run_feed_check(live=fixture['live'], published=payload
                                             if target == 'published' else fixture['published'],
                                             generated=payload
                                             if target == 'generated' else fixture['generated'],
                                             tag=fixture['tag'], source=fixture['source'])
                self.assertNotEqual(result.returncode, 0, label)

    def run_feather_asset_gate(self, names):
        gate_step = self.step(self.feather_job, 'Require a public unsigned-only asset set')
        python = extract_heredoc_python(gate_step)
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, 'feather-assets.json').write_text(
                json.dumps({'assets': [{'name': name} for name in names]}))
            return subprocess.run([sys.executable, '-c', python],
                                  env=dict(os.environ, RUNNER_TEMP=tmp),
                                  capture_output=True, text=True)

    def test_feather_gate_requires_the_pair_for_the_intended_release(self):
        # A valid new stable release passes even though the historic 275
        # source-only release remains asset-less: the gate inspects only the
        # intended tag's assets. The same intended release missing its IPA fails.
        valid = self.run_feather_asset_gate([
            'Floe-Agent-1.7.34-build275-unsigned.ipa',
            'Floe-Agent-1.7.34-build275-unsigned.ipa.sha256'])
        self.assertEqual(valid.returncode, 0, valid.stderr)
        missing = self.run_feather_asset_gate(['PROVENANCE.json'])
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn('Expected one published unsigned IPA', missing.stderr)
        transport = self.run_feather_asset_gate(['local-device.zip.part00'])
        self.assertNotEqual(transport.returncode, 0)

    def test_local_first_publish_attests_then_publishes_and_reads_back(self):
        job = RELEASE['jobs']['local-publish']
        condition = job['if']
        for token in ("inputs.local_artifact_sha256 != ''", 'inputs.publish',
                      '!inputs.lean_release', '!inputs.direct_testflight'):
            self.assertIn(token, condition)
        names = [step.get('name') for step in job['steps']]
        order = ['Download the private draft transport and verify local provenance',
                 'Package the unsigned IPA from the archived device build',
                 'Attest the exact unsigned IPA bytes',
                 'Verify the attestation exactly as Feather will',
                 'Publish the normal stable release without clobbering',
                 'Read back the published release as an installable delivery',
                 'Request Gitee synchronization for the published release']
        self.assertEqual([name for name in names if name in order], order,
                         'the local-first route must attest, publish, read back, then sync')
        feather = RELEASE['jobs']['feather-local-release']
        self.assertEqual(feather['uses'], './.github/workflows/publish-feather-source.yml')
        self.assertEqual(feather['needs'], ['local-publish'])
        steps = {step.get('name'): step for step in job['steps']}
        transport = steps['Download the private draft transport and verify local provenance']['run']
        self.assertIn("grep -x true", transport)
        self.assertIn('EXPECTED_TRANSPORT_SHA256', transport)
        self.assertIn('local-device.zip.part??', transport)
        self.assertIn("provenance['source_sha'] == os.environ['SOURCE_SHA']", transport)
        self.assertIn('_CodeSignature', transport)
        attest = steps['Attest the exact unsigned IPA bytes']
        self.assertIn('attest-build-provenance@', attest['uses'])
        self.assertEqual(attest['with']['subject-path'], '${{ steps.package.outputs.ipa_path }}')
        verify = steps['Verify the attestation exactly as Feather will']['run']
        self.assertIn('--signer-workflow "$GITHUB_REPOSITORY/.github/workflows/release-unsigned-ipa.yml"',
                      verify)
        package = steps['Package the unsigned IPA from the archived device build']['run']
        self.assertIn('scripts/package_unsigned_ipa.sh', package)
        self.assertIn('ipa_sha256=', package)
        self.assertNotIn('symbols/', package)
        publish = steps['Publish the normal stable release without clobbering']['run']
        self.assertIn('RELEASE_MODE_ARGS=(--latest=true)', publish)
        self.assertIn('RELEASE_MODE_ARGS=(--prerelease --latest=false)', publish)
        self.assertIn('gh release create "$RELEASE_TAG"', publish)
        self.assertIn('gh release download "$$RELEASE_TAG"'.replace('$$', '$'), publish)
        self.assertNotIn('gh release upload', publish)
        readback = steps['Read back the published release as an installable delivery']['run']
        self.assertIn('verify_github_release_publication.py', readback)
        self.assertIn('--expect-ipa-sha256 "${{ steps.package.outputs.ipa_sha256 }}"', readback)
        self.assertIn('--latest-json "$READBACK/latest.json"', readback)
        raw = job_block(RELEASE_TEXT, 'local-publish')
        self.assertNotIn('secrets.', raw)
        self.assertNotIn('APP_STORE_CONNECT', raw)


if __name__ == '__main__':
    unittest.main()
