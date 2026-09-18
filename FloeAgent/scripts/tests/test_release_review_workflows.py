"""Ordering, portability and publishing-policy checks for the lean release route.

Two kinds of checks live here:

* a real functional fixture for ``FloeAgent/scripts/release_preflight.sh`` that
  runs the script with a PATH that contains no ``plutil`` (the ubuntu lean-source
  environment) and proves both the pass and the empty-display-name failure;
* workflow assertions for the recovery ordering that main found broken: the
  unsigned IPA must be retained immediately after package validation, before
  dSYM capture, and publishing must stay unsigned-only, exact-SHA and
  idempotent.

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


class PortablePreflightFixtureTests(unittest.TestCase):
    """Run the real preflight script without Apple's plutil on PATH."""

    def run_preflight(self, transform=lambda text: text, env_extra=None):
        root = Path(tempfile.mkdtemp(prefix='floe-preflight-review-'))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        app = root / 'FloeAgent'
        for name in ('project.yml', 'scripts/release_preflight.sh',
                     'scripts/validate_localization_catalog.py',
                     'FloeAgent.xcodeproj/project.pbxproj', 'FloeScreenShare/Info.plist',
                     'FloeApp/Resources/Localizable.xcstrings'):
            target = app / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / 'FloeAgent' / name, target)
        plist_path = app / 'FloeScreenShare/Info.plist'
        plist_path.write_text(transform(plist_path.read_text()))
        git_env = dict(os.environ, GIT_AUTHOR_NAME='Floe Review', GIT_COMMITTER_NAME='Floe Review',
                       GIT_AUTHOR_EMAIL='review@example.invalid',
                       GIT_COMMITTER_EMAIL='review@example.invalid')
        for args in (('init', '-q'), ('add', '.'), ('commit', '-qm', 'fixture'),
                     ('tag', 'v1.7.0-beta.999')):
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
                               'v1.7.0-beta.999'], cwd=root, env=env,
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


class LeanPublishPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.publish = job_block(RELEASE_TEXT, 'lean-publish')
        cls.steps = {step.get('name'): step for step in RELEASE['jobs']['lean-publish']['steps']}

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

    def test_publish_is_idempotent_and_never_clobbers(self):
        self.assertIn('gh release view "$RELEASE_TAG"', self.publish)
        self.assertIn('--verify-tag --prerelease --latest=false', self.publish)
        self.assertIn('gh release download "$RELEASE_TAG"', self.publish)
        self.assertIn('sha256sum "$PUBLISHED/$ASSET_NAME"', self.publish)
        self.assertNotRegex(self.publish, r'gh release (create|upload)[^\n]*--clobber')
        self.assertNotIn('gh release edit', self.publish)
        self.assertNotIn('gh release delete', self.publish)

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

    def test_existing_release_asset_gate_rejects_signed_assets(self):
        step = self.steps['Publish the attested unsigned prerelease without clobbering']
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            script = root / 'existing_release_gate.py'
            script.write_text(extract_heredoc_python(step))
            ipa = 'Floe-Agent-1.7.0-build192-unsigned.ipa'
            assets = root / 'assets.txt'
            good = [ipa, f'{ipa}.sha256', 'TEST-SUMMARY.txt', 'DIRECT-PROVENANCE.json']
            assets.write_text('\n'.join(good) + '\n')
            ok = subprocess.run([sys.executable, str(script), str(assets), ipa],
                                capture_output=True, text=True)
            self.assertEqual(ok.returncode, 0, ok.stderr)
            for bad in ('FloeAgent.ipa', 'Floe-Agent-1.7.0-build192-signed.ipa',
                        'Floe.mobileprovision', 'distribution.p12'):
                with self.subTest(bad=bad):
                    assets.write_text('\n'.join(good + [bad]) + '\n')
                    failed = subprocess.run([sys.executable, str(script), str(assets), ipa],
                                            capture_output=True, text=True)
                    self.assertNotEqual(failed.returncode, 0, bad)

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


if __name__ == '__main__':
    unittest.main()
