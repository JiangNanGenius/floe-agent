"""Contracts for the published-release readback repair and its Bash 3 fix.

On 2026-10-19 the normal local publish run 39202881875 packaged, audited,
attested and published the canonical v1.7.39 (build 280) unsigned IPA, then
failed its post-publish readback on the macOS runner's Bash 3.2::

    line 21: MODE_ARGS[@]: unbound variable

Under ``set -u`` Bash treats an empty ``"${arr[@]}"`` expansion as unbound until
4.4. A stable dispatch fills LATEST_ARGS and leaves MODE_ARGS empty (a
prerelease or beta-pattern dispatch does the reverse), so every readback route
needed the ``+`` guard. The functional fixture below executes the real extracted
step text under the host Bash 3.2 with canned ``gh`` JSON, proves both variants
reach the verifier with the expected arguments and no empty argv entries, and
shows that the unguarded spelling still aborts on this shell.

The second half keeps ``repair-release-readback.yml`` a read-only recovery for
an already public stable App release: the exact three dispatch inputs, immutable
action pins, the existing strict verifier with the staged arm64/iphoneos audit
and remote digest binding, the original publisher attestation (never a new one),
no release/asset/tag writes, and one awaited job-level call to the existing
Feather workflow so delivery cannot complete without its live feed readback.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
WORKFLOWS = REPO / '.github' / 'workflows'
RELEASE_TEXT = (WORKFLOWS / 'release-unsigned-ipa.yml').read_text(encoding='utf-8')
REPAIR_TEXT = (WORKFLOWS / 'repair-release-readback.yml').read_text(encoding='utf-8')
FEATHER_TEXT = (WORKFLOWS / 'publish-feather-source.yml').read_text(encoding='utf-8')
RELEASE = yaml.safe_load(RELEASE_TEXT)
REPAIR = yaml.safe_load(REPAIR_TEXT)
FEATHER = yaml.safe_load(FEATHER_TEXT)
READBACK_STEP = 'Read back the published release as an installable delivery'
SOURCE_SHA = '0c9b0864d6e5bbae48f3f4917d5175fcd542b25c'
IPA_SHA256 = '461f2d59e42da38e5546e87e3393702ff8f285f5ef084906fe0ea64e0e14f48c'
BASH = '/bin/bash' if Path('/bin/bash').exists() else shutil.which('bash')


class BashOptionalArrayExpansionTests(unittest.TestCase):
    """Run each real readback step text under this host's Bash with a gh stub."""

    # job, tag, prerelease, required flags, forbidden flags, step passes an IPA digest
    CASES = (
        ('publish-release', 'v1.7.39', False, ('--latest-json',), (), False),
        ('publish-release', 'v1.7.39-beta.1', False,
         ('--allow-prerelease', '--prerelease-reason'), ('--latest-json',), False),
        ('lean-publish', 'v1.7.39', False,
         ('--latest-json',), ('--allow-prerelease',), True),
        ('lean-publish', 'v1.7.39', True,
         ('--allow-prerelease', '--prerelease-reason'), ('--latest-json',), True),
        ('local-publish', 'v1.7.39', False,
         ('--latest-json',), ('--allow-prerelease',), True),
        ('local-publish', 'v1.7.39', True,
         ('--allow-prerelease', '--prerelease-reason'), ('--latest-json',), True),
    )

    @classmethod
    def setUpClass(cls):
        cls.bash_version = tuple(int(part) for part in subprocess.check_output(
            [BASH, '-c', 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"'],
            text=True).split('.'))

    def readback_run(self, job: str) -> str:
        steps = RELEASE['jobs'][job]['steps']
        return next(step for step in steps if step.get('name') == READBACK_STEP)['run']

    def prepared_run(self, job: str) -> str:
        run = self.readback_run(job)
        # GitHub expressions cannot be executed by a shell; bind the two known
        # digest references to the fixture digest. Every step must be fully
        # substituted, so a future expression cannot silently weaken this test.
        run = run.replace('${{ steps.package.outputs.ipa_sha256 }}', IPA_SHA256)
        run = run.replace('${{ steps.fetch.outputs.ipa_sha256 }}', IPA_SHA256)
        self.assertNotIn('${{', run)
        return run

    def execute(self, run: str, *, tag: str, prerelease: bool):
        root = Path(tempfile.mkdtemp(prefix='floe-readback-bash3-'))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        fixtures = root / 'fixtures'
        fixtures.mkdir()
        (fixtures / 'release.json').write_text(json.dumps({
            'tag_name': tag, 'draft': False, 'prerelease': prerelease,
            'published_at': '2026-10-19T05:09:33Z'}))
        tag_object_sha = 'a' * 40
        (fixtures / 'tag-ref.json').write_text(json.dumps({
            'ref': f'refs/tags/{tag}',
            'object': {'type': 'tag', 'sha': tag_object_sha}}))
        (fixtures / 'tag-object.json').write_text(json.dumps({
            'sha': tag_object_sha, 'tag': tag,
            'object': {'type': 'commit', 'sha': SOURCE_SHA}}))
        (fixtures / 'latest.json').write_text(json.dumps({'tag_name': tag}))
        captured = root / 'captured-args.txt'
        shim = root / 'bin'
        shim.mkdir()
        for tool in ('mkdir', 'jq', 'cat'):
            found = shutil.which(tool)
            self.assertIsNotNone(found, f'{tool} is required for the readback fixture')
            (shim / tool).symlink_to(found)
        gh = shim / 'gh'
        gh.write_text(
            '#!/bin/bash\n'
            'set -euo pipefail\n'
            'case "$*" in\n'
            '  *"/releases/latest"*) cat "$FIXTURE_LATEST" ;;\n'
            '  *"/releases/tags/"*) cat "$FIXTURE_RELEASE" ;;\n'
            '  *"/git/ref/tags/"*) cat "$FIXTURE_TAG_REF" ;;\n'
            '  *"/git/tags/"*) cat "$FIXTURE_TAG_OBJECT" ;;\n'
            '  *) echo "unexpected gh invocation: $*" >&2; exit 9 ;;\n'
            'esac\n', encoding='utf-8')
        python = shim / 'python3'
        python.write_text(
            '#!/bin/bash\n'
            'set -euo pipefail\n'
            'printf \'%s\\n\' "$@" > "$CAPTURED_ARGS"\n', encoding='utf-8')
        for script in (gh, python):
            script.chmod(0o755)
        script_path = root / 'readback.sh'
        script_path.write_text(run, encoding='utf-8')
        env = {
            'PATH': str(shim),
            'HOME': str(root),
            'RELEASE_TAG': tag,
            'RELEASE_PRERELEASE': 'true' if prerelease else 'false',
            'GITHUB_REPOSITORY': 'JiangNanGenius/floe-agent',
            'RUNNER_TEMP': str(root / 'temp'),
            # The real jobs receive these from their release/prepare steps.
            'SOURCE_SHA': SOURCE_SHA,
            'VERSION': '1.7.39',
            'BUILD': '280',
            'CAPTURED_ARGS': str(captured),
            'FIXTURE_RELEASE': str(fixtures / 'release.json'),
            'FIXTURE_TAG_REF': str(fixtures / 'tag-ref.json'),
            'FIXTURE_TAG_OBJECT': str(fixtures / 'tag-object.json'),
            'FIXTURE_LATEST': str(fixtures / 'latest.json'),
        }
        result = subprocess.run([BASH, str(script_path)], env=env, cwd=str(root),
                                text=True, capture_output=True)
        args = captured.read_text().splitlines() if captured.exists() else []
        return result, args

    def test_readback_steps_survive_bash3_with_empty_optional_arrays(self):
        for job, tag, prerelease, required, forbidden, has_digest in self.CASES:
            with self.subTest(job=job, tag=tag, prerelease=prerelease):
                result, args = self.execute(
                    self.prepared_run(job), tag=tag, prerelease=prerelease)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('unbound variable', result.stderr)
                self.assertTrue(args, 'the verifier invocation was not reached')
                # The guard adds no argument at all for the empty array; a
                # quoted-empty fallback would inject one and change the CLI.
                self.assertNotIn('', args)
                for token in required:
                    self.assertIn(token, args)
                for token in forbidden:
                    self.assertNotIn(token, args)
                self.assertEqual(args[args.index('--mode') + 1], 'app')
                self.assertEqual(args[args.index('--staged-dir') + 1], 'release-assets')
                self.assertEqual(args[args.index('--expect-source-sha') + 1], SOURCE_SHA)
                if has_digest:
                    self.assertEqual(args[args.index('--expect-ipa-sha256') + 1], IPA_SHA256)
                if '--prerelease-reason' in args:
                    reason = args[args.index('--prerelease-reason') + 1]
                    self.assertTrue(reason.strip())

    def test_unguarded_expansion_still_aborts_on_bash3(self):
        if self.bash_version >= (4, 4):
            self.skipTest('Bash >= 4.4 accepts an empty array under set -u')
        for job, tag, prerelease, *_ in self.CASES:
            if prerelease or '*' in tag:
                continue  # only the stable branch leaves MODE_ARGS empty
            with self.subTest(job=job):
                run = self.prepared_run(job).replace(
                    '"${LATEST_ARGS[@]+"${LATEST_ARGS[@]}"}"',
                    '"${LATEST_ARGS[@]}"').replace(
                    '"${MODE_ARGS[@]+"${MODE_ARGS[@]}"}"',
                    '"${MODE_ARGS[@]}"')
                result, _ = self.execute(run, tag=tag, prerelease=prerelease)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('unbound variable', result.stderr)

    def test_all_three_readback_steps_use_the_guard(self):
        for job in ('publish-release', 'lean-publish', 'local-publish'):
            with self.subTest(job=job):
                run = self.readback_run(job)
                self.assertIn('"${LATEST_ARGS[@]+"${LATEST_ARGS[@]}"}"', run)
                self.assertIn('"${MODE_ARGS[@]+"${MODE_ARGS[@]}"}"', run)
                self.assertNotIn('"${LATEST_ARGS[@]}" "${MODE_ARGS[@]}"', run)

    def test_no_comment_interrupts_a_continued_command(self):
        # A comment line cannot sit between backslash-continued arguments: it
        # terminates the command (this exact regression appeared while writing
        # the guard). The functional fixture above would fail, and this cheap
        # structural check names the mistake directly.
        runs = {job: self.readback_run(job)
                for job in ('publish-release', 'lean-publish', 'local-publish')}
        for step in REPAIR['jobs']['verify-published-readback']['steps']:
            if 'run' in step:
                runs[f"repair:{step['name']}"] = step['run']
        for label, run in runs.items():
            lines = run.splitlines()
            for index, line in enumerate(lines[:-1]):
                if line.rstrip().endswith('\\') and lines[index + 1].strip().startswith('#'):
                    self.fail(f'{label}: comment interrupts a continued command '
                              f'after line {index + 1}: {line.strip()!r}')


class RepairWorkflowContractTests(unittest.TestCase):
    """The recovery is a read-only readback for an already public stable release."""

    @classmethod
    def setUpClass(cls):
        cls.triggers = REPAIR.get('on', REPAIR.get(True))
        cls.jobs = REPAIR['jobs']
        cls.readback = cls.jobs['verify-published-readback']
        cls.feather = cls.jobs['await-feather-publication']
        cls.readback_runs = [step.get('run', '') for step in cls.readback['steps']]
        cls.all_runs = [step.get('run', '')
                        for job in cls.jobs.values() for step in job.get('steps', [])]

    def test_dispatch_inputs_are_exactly_the_release_identity(self):
        self.assertEqual(list(self.triggers), ['workflow_dispatch'])
        inputs = self.triggers['workflow_dispatch']['inputs']
        self.assertEqual(set(inputs), {'tag', 'expected_source_sha', 'expected_ipa_sha256'})
        for name, spec in inputs.items():
            self.assertIs(spec.get('required'), True, name)
            self.assertEqual(spec.get('type'), 'string', name)

    def test_recovery_never_writes_release_assets_tags_or_attestations(self):
        self.assertEqual(REPAIR['permissions'], {'contents': 'read'})
        self.assertEqual(self.readback['permissions'],
                         {'contents': 'read', 'actions': 'read', 'attestations': 'read'})
        self.assertIn("github.repository == 'JiangNanGenius/floe-agent'",
                      self.readback['if'])
        forbidden = (
            r'gh release (create|edit|upload|delete)',
            r'gh api (--method|-X) (POST|PATCH|PUT|DELETE)',
            r'gh attestation (?!verify)',
            r'attest-build-provenance',
            r'gh workflow run',
            r'git push',
            r'git tag\b',
            r'xcodebuild',
            r'codesign',
            r'package_unsigned_ipa\.sh',
        )
        for pattern in forbidden:
            for run in self.all_runs:
                self.assertIsNone(re.search(pattern, run), f'{pattern} in {run[:120]!r}')
        self.assertNotIn('attestations: write', REPAIR_TEXT)
        self.assertNotIn('id-token: write', REPAIR_TEXT)
        self.assertNotIn('secrets', REPAIR_TEXT)

    def test_actions_are_immutably_pinned(self):
        uses = [job['uses'] for job in self.jobs.values() if 'uses' in job]
        uses += [step['uses'] for job in self.jobs.values()
                 for step in job.get('steps', []) if 'uses' in step]
        for value in uses:
            if value.startswith('./'):
                continue
            self.assertRegex(value, r'^[A-Za-z0-9_.\-/]+@[0-9a-f]{40}$')
        checkout = next(step for step in self.readback['steps']
                        if step.get('uses', '').startswith('actions/checkout@'))
        self.assertEqual(checkout['with']['ref'], '${{ inputs.tag }}')
        self.assertIs(checkout['with']['fetch-tags'], True)

    def test_tag_source_is_bound_before_any_github_read(self):
        runs = '\n'.join(self.readback_runs)
        self.assertIn('git rev-parse HEAD', runs)
        self.assertIn('refs/tags/$RELEASE_TAG^{commit}', runs)
        first_run_index = next(index for index, run in enumerate(self.readback_runs)
                               if 'git rev-parse HEAD' in run)
        api_index = next(index for index, run in enumerate(self.readback_runs)
                         if 'releases/tags/$RELEASE_TAG' in run)
        self.assertLess(first_run_index, api_index)

    def test_recovery_requires_the_annotated_tag_object(self):
        runs = '\n'.join(self.readback_runs)
        self.assertIn('test "$(git cat-file -t "refs/tags/$RELEASE_TAG")" = tag', runs)
        self.assertIn('test "$REF_TYPE" = tag', runs)
        # The lightweight fallback the normal route tolerates must not exist in
        # the recovery: an annotated tag is the promised immutable input.
        self.assertNotIn('jq -n --arg sha', runs)

    def test_provenance_binding_matches_the_local_publisher_contract(self):
        runs = '\n'.join(self.readback_runs)
        for line in ("'schemaVersion', 'tag', 'version', 'build', 'sourceCommit',",
                     "'bundleIdentifier', 'assetName', 'ipaSHA256', 'ipaBytes',",
                     "'unsigned', 'appRebuilt'"):
            self.assertIn(line, runs)
        self.assertIn("record['schemaVersion'] == 1", runs)
        self.assertIn("isinstance(record['ipaBytes'], int)", runs)
        self.assertIn("record['bundleIdentifier'] == 'org.floeagent.ios'", runs)
        producer = '\n'.join(step.get('run', '')
                             for step in RELEASE['jobs']['local-publish']['steps'])
        for field in ('schemaVersion', 'tag', 'version', 'build', 'sourceCommit',
                      'bundleIdentifier', 'assetName', 'ipaSHA256', 'ipaBytes',
                      'unsigned', 'appRebuilt'):
            self.assertIn(f"'{field}':", producer)

    def test_recovery_requires_an_already_public_stable_latest_release(self):
        runs = '\n'.join(self.readback_runs)
        self.assertIn('gh api "repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG"', runs)
        self.assertIn('gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$RELEASE_TAG"', runs)
        self.assertIn('releases/latest', runs)
        self.assertIn("release.get('draft') is False", runs)
        self.assertIn("release.get('prerelease') is False", runs)
        self.assertIn("latest.get('tag_name')", runs)
        self.assertIn('PROVENANCE.json', runs)
        self.assertIn("record['sourceCommit'] == source", runs)
        self.assertIn("record['ipaSHA256'] == digest", runs)
        self.assertIn('sha256sum -c -', runs)
        self.assertIn('$EXPECTED_IPA_SHA256', runs)

    def test_readback_runs_the_repo_strict_verifier_with_the_device_audit(self):
        runs = '\n'.join(self.readback_runs)
        self.assertIn('FloeAgent/scripts/verify_github_release_publication.py', runs)
        self.assertIn('--mode app', runs)
        self.assertIn('--latest-json "$READBACK/latest.json"', runs)
        self.assertIn('--expect-source-sha "$EXPECTED_SOURCE_SHA"', runs)
        self.assertIn('--expect-ipa-sha256 "$EXPECTED_IPA_SHA256"', runs)
        self.assertIn('--staged-dir "$RUNNER_TEMP/PublishedAssets"', runs)
        self.assertIn('--report "$READBACK/report.json"', runs)
        # A stable release only: the prerelease waiver must never be offered.
        self.assertNotIn('--allow-prerelease', runs)

    def test_original_publisher_attestation_is_verified_not_recreated(self):
        runs = '\n'.join(self.readback_runs)
        self.assertEqual(runs.count('gh attestation '), runs.count('gh attestation verify '))
        self.assertIn('gh attestation verify "$RUNNER_TEMP/PublishedAssets/$ASSET_NAME"', runs)
        self.assertIn('--repo "$GITHUB_REPOSITORY"', runs)
        self.assertIn('--source-digest "$EXPECTED_SOURCE_SHA"', runs)
        self.assertIn('--signer-workflow '
                      '"$GITHUB_REPOSITORY/.github/workflows/release-unsigned-ipa.yml"', runs)

    def test_readback_evidence_is_retained_on_success_and_failure(self):
        retention = next(step for step in self.readback['steps']
                         if step.get('name', '').startswith('Retain'))
        self.assertEqual(retention['if'], 'always()')
        self.assertTrue(retention['uses'].startswith('actions/upload-artifact@'))
        paths = retention['with']['path']
        for token in ('report.json', 'attestation-verify.txt',
                      'PUBLISHED-READBACK-EVIDENCE.txt', 'latest.json'):
            self.assertIn(token, paths)

    def test_feather_runs_as_awaited_same_run_job(self):
        self.assertEqual(self.feather['uses'],
                         './.github/workflows/publish-feather-source.yml')
        self.assertEqual(self.feather['needs'], ['verify-published-readback'])
        self.assertEqual(self.feather['if'],
                         "needs.verify-published-readback.result == 'success'")
        self.assertEqual(self.feather['with'], {'tag': '${{ inputs.tag }}'})
        self.assertEqual(self.feather['permissions'],
                         {'contents': 'write', 'actions': 'read', 'attestations': 'read'})
        self.assertEqual(FEATHER['permissions'],
                         {'contents': 'write', 'attestations': 'read', 'actions': 'read'})
        for job in self.jobs.values():
            for step in job.get('steps', []):
                self.assertNotIn('./.github/workflows/', step.get('uses', ''))

    def test_recovery_never_overlaps_the_normal_release_run(self):
        self.assertEqual(REPAIR['concurrency']['cancel-in-progress'], False)
        self.assertIn('${{ inputs.tag }}', REPAIR['concurrency']['group'])
        self.assertEqual(self.readback.get('timeout-minutes'), 30)


class ReleasePublishRouteIsUnchangedTests(unittest.TestCase):
    """The Bash fix must not alter what the normal routes publish or attest."""

    PUBLISH_STEPS = {
        'publish-release': 'Publish the transport-accepted paired release',
        'lean-publish': 'Publish the attested unsigned release without clobbering',
        'local-publish': 'Publish the normal stable release without clobbering',
    }

    def publish_run(self, job: str) -> str:
        steps = RELEASE['jobs'][job]['steps']
        return next(step for step in steps
                    if step.get('name') == self.PUBLISH_STEPS[job])['run']

    def test_publish_steps_keep_the_stable_latest_default_and_the_beta_exception(self):
        for job in self.PUBLISH_STEPS:
            with self.subTest(job=job):
                run = self.publish_run(job)
                self.assertIn('RELEASE_MODE_ARGS=(--latest=true)', run)
                self.assertIn('RELEASE_MODE_ARGS=(--prerelease --latest=false)', run)
                self.assertNotIn('--draft=false --prerelease', run)

    def test_attestation_is_still_created_only_from_the_publisher(self):
        local = RELEASE['jobs']['local-publish']
        attest = next(step for step in local['steps']
                      if step.get('name') == 'Attest the exact unsigned IPA bytes')
        self.assertIn('attest-build-provenance@', attest['uses'])
        self.assertEqual(local['permissions']['attestations'], 'write')
        self.assertEqual(local['permissions']['id-token'], 'write')


class PublicRepairRecordTests(unittest.TestCase):
    """The public record keeps the original failure and the open delivery state."""

    def test_repair_note_records_the_public_failure_truthfully(self):
        note = (REPO / 'docs' / 'releases' / 'repairs'
                / 'FLOE_RELEASE_280_READBACK_REPAIR_20261019.md')
        self.assertTrue(note.is_file())
        text = note.read_text(encoding='utf-8')
        for token in ('39202881875', 'v1.7.39', SOURCE_SHA, IPA_SHA256,
                      'MODE_ARGS[@]: unbound variable',
                      'Delivery is not yet complete.', 'local-publish'):
            self.assertIn(token, text)


if __name__ == '__main__':
    unittest.main()
