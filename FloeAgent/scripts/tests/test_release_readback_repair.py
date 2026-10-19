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

import hashlib
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

# Snapshot of the pre-fallback job definitions from 9918a7c9, excluding the
# selector and dependency list. The focused test below proves the fallback added
# only the route-gate dependency on legacy roots: every selector and every other
# job key and step is byte-identical.
LEGACY_JOB_BASELINE = {'developer-recovery': ("${{ inputs.local_artifact_sha256 == '' && github.event_name == "
                        "'workflow_dispatch' && inputs.recover_developer_build191 && inputs.tag == "
                        "'v1.7.0-beta.48' && inputs.publish && !inputs.direct_testflight && "
                        '!inputs.recover_build_156 && !inputs.build191_ui_waiver && '
                        "inputs.reuse_accepted_run == '' && inputs.component_recovery_run == '' }}",
                        None,
                        '7fd5f2d0149067564f3fb25444487739e7655d324f6978b98558b2f85172921d'),
 'direct-testflight': ("${{ inputs.local_artifact_sha256 == '' && "
                       '!inputs.recover_developer_build191 && !inputs.build191_ui_waiver && '
                       "github.event_name == 'workflow_dispatch' && inputs.direct_testflight && "
                       "inputs.reuse_accepted_run == '' && inputs.component_recovery_run == '' }}",
                       None,
                       '1ed438d01d534441cb09787f02aa8f40fa9b14266ffe233c4231d622434814b4'),
 'expedited-testflight': ("${{ inputs.local_artifact_sha256 == '' && "
                          '!inputs.recover_developer_build191 && github.event_name == '
                          "'workflow_dispatch' && inputs.reuse_accepted_run != '' && "
                          "inputs.component_recovery_run == '' && (!inputs.build191_ui_waiver || "
                          "(inputs.tag == 'v1.7.0-beta.48' && inputs.reuse_accepted_run == "
                          "'35337960392' && !inputs.publish && !inputs.direct_testflight)) }}",
                          None,
                          '05e7d162d89167ad73960af7e91ba506c0a86f74660d9a50bf6f29f02e3c5a73'),
 'recover-testflight': ("${{ inputs.local_artifact_sha256 == '' && "
                        '!inputs.recover_developer_build191 && !inputs.build191_ui_waiver && '
                        "github.event_name == 'workflow_dispatch' && inputs.recover_build_156 && "
                        "inputs.tag == 'v1.7.0-beta.13' && !inputs.publish && "
                        "inputs.component_recovery_run == '' }}",
                        None,
                        '300f57c5255c2873ee1ceea27c445b6a26be93a69082914d7f9434305bbeabd2'),
 'component-recovery': ("${{ inputs.local_artifact_sha256 == '' && "
                        '!inputs.recover_developer_build191 && !inputs.build191_ui_waiver && '
                        "github.event_name == 'workflow_dispatch' && inputs.component_recovery_run "
                        "!= '' }}",
                        None,
                        '6cacef668ceb7c74157a55911c4efff233328ff9a6ebacbd9fb92a5830e310d0'),
 'prepare-release': ("${{ inputs.local_artifact_sha256 == '' && !inputs.recover_developer_build191 "
                     '&& !inputs.build191_ui_waiver && !inputs.direct_testflight && '
                     "!inputs.recover_build_156 && inputs.reuse_accepted_run == '' && "
                     "inputs.component_recovery_run == '' && !inputs.lean_release && "
                     "inputs.reuse_direct_run == '' }}",
                     None,
                     'f4de4c9d349acb04e31009bb057ec41acb744e9ac21a175460c5e9e8f767f877'),
 'notes-component': ("${{ inputs.local_artifact_sha256 == '' && !inputs.recover_developer_build191 "
                     '&& !inputs.build191_ui_waiver && !inputs.direct_testflight && '
                     "!inputs.recover_build_156 && inputs.reuse_accepted_run == '' && "
                     "inputs.component_recovery_run == '' && !inputs.lean_release && "
                     "inputs.reuse_direct_run == '' }}",
                     'prepare-release',
                     'f6115eb8440b998c33db64c7c7a2d61547584f1902a560142ad0cd46a6da2f5f'),
 'build-verify-release': ("${{ inputs.local_artifact_sha256 == '' && "
                          '!inputs.recover_developer_build191 && !inputs.build191_ui_waiver && '
                          '!inputs.direct_testflight && !inputs.recover_build_156 && '
                          "inputs.reuse_accepted_run == '' && inputs.component_recovery_run == '' "
                          "&& !inputs.lean_release && inputs.reuse_direct_run == '' }}",
                          'prepare-release',
                          '94e57a774155ddc2f9a404d2866e467e959d3aa63b24e37d56339a942d7dac26'),
 'accepted-sdk-build': (None,
                        'prepare-release',
                        '84b01b49d45f220f0d21749e58847574e7fb30ee58ecb406ee39197c57c1f08e'),
 'testflight': (None,
                ['build-verify-release', 'accepted-sdk-build', 'notes-component'],
                '24d55c82ee53ab8775343f283da79cb42cb937098dd47397d3f2aa9027aa16ce'),
 'publish-release': ("(github.event_name == 'push' && "
                     "!contains(needs.build-verify-release.outputs.tag, '-beta.')) || "
                     'inputs.publish',
                     ['build-verify-release', 'testflight'],
                     '824587373763197c1bc6a21c6bb25a5d25b74d6d1bf3df2041238f08ae101e92'),
 'feather-normal-release': ("needs.publish-release.result == 'success'",
                            ['publish-release'],
                            'bf3cf41cbd49062ea9c457680a7a6dc46cacf8cb31307857b1344aed708e42cd'),
 'lean-request-check': ("${{ inputs.local_artifact_sha256 == '' && github.event_name == "
                        "'workflow_dispatch' && inputs.reuse_direct_run != '' && "
                        '!inputs.lean_release }}',
                        None,
                        '5405556c8d96fcad379fcaae0b8830f2458a7f8b74aaadf626346f18f7923c16'),
 'lean-source': ("${{ inputs.local_artifact_sha256 == '' && !inputs.recover_developer_build191 && "
                 '!inputs.build191_ui_waiver && !inputs.recover_build_156 && github.event_name == '
                 "'workflow_dispatch' && inputs.lean_release && inputs.reuse_accepted_run == '' && "
                 "inputs.component_recovery_run == '' }}",
                 None,
                 'fed3aeb7bc595149f3362671aa0f0fbfe5252eefb7f1a258a0f63d2a724fb8e4'),
 'lean-build': ("${{ inputs.local_artifact_sha256 == '' && !inputs.recover_developer_build191 && "
                '!inputs.build191_ui_waiver && !inputs.recover_build_156 && github.event_name == '
                "'workflow_dispatch' && inputs.lean_release && !inputs.direct_testflight && "
                "inputs.reuse_accepted_run == '' && inputs.component_recovery_run == '' }}",
                ['lean-source'],
                '913785b6a00039d68fd3455b4ae31ed48f494ebdfa4717fe2904654b605604c3'),
 'lean-publish': ("${{ inputs.local_artifact_sha256 == '' && !inputs.recover_developer_build191 && "
                  '!inputs.build191_ui_waiver && !inputs.recover_build_156 && github.event_name == '
                  "'workflow_dispatch' && inputs.lean_release && inputs.publish && "
                  "!inputs.direct_testflight && inputs.reuse_accepted_run == '' && "
                  "inputs.component_recovery_run == '' }}",
                  ['lean-source', 'lean-build'],
                  'dfd72a2e45d5c4414a041f46acb7d0eb2794c8235f330a80fe47eea02553e33b'),
 'feather-lean-release': ("needs.lean-publish.result == 'success'",
                          ['lean-publish'],
                          '68493eff65ce4aca9322cf2bd20fa4ad94833ca4e561987c6a73fefbe7e6cfb1'),
 'local-artifact-testflight': ("${{ github.event_name == 'workflow_dispatch' && "
                               "inputs.local_artifact_sha256 != '' && !inputs.publish && "
                               '!inputs.lean_release && !inputs.direct_testflight }}',
                               None,
                               '3b1d75bbf9ecb7dd6150880892f59b95a754472c7af11ebaf3b75afdceccf293'),
 'local-publish': ("${{ github.event_name == 'workflow_dispatch' && inputs.local_artifact_sha256 "
                   "!= '' && inputs.publish && !inputs.lean_release && !inputs.direct_testflight "
                   "&& inputs.reuse_accepted_run == '' && inputs.component_recovery_run == '' && "
                   '!inputs.recover_developer_build191 && !inputs.recover_build_156 && '
                   '!inputs.build191_ui_waiver }}',
                   None,
                   '191ac9a9872e6cb631992281bc67ebd4be64a5a92d8b0b74201cd06ffbaba990'),
 'feather-local-release': ("needs.local-publish.result == 'success'",
                           ['local-publish'],
                           '2cc3a0efbc34f16327218d60400f89a5815676ebf23b12305cf61cfcbf39980b')}

OLD_INPUT_ORDER = [
    'tag', 'local_artifact_sha256', 'transport_tag', 'direct_testflight',
    'lean_release', 'github_prerelease', 'reuse_direct_run',
    'reuse_accepted_run', 'recover_developer_build191', 'build191_ui_waiver',
    'component_recovery_run', 'recover_build_156', 'publish',
]
OLD_INPUTS_SHA256 = 'eb0d0605a315fd74db3708ac7a1f24d7c5443fd96e723ed7f83412872f0f7ee0'
RECOVERY_JOB = 'published-readback-recovery'
GATE_JOB = 'published-readback-route-gate'


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
                self.assertIn('python3 FloeAgent/scripts/verify_github_release_publication.py', run)
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
        self.assertIn('workflow_dispatch', self.triggers)
        inputs = self.triggers['workflow_dispatch']['inputs']
        self.assertEqual(set(inputs), {'tag', 'expected_source_sha', 'expected_ipa_sha256'})
        for name, spec in inputs.items():
            self.assertIs(spec.get('required'), True, name)
            self.assertEqual(spec.get('type'), 'string', name)

    def test_workflow_call_accepts_the_same_three_required_proofs(self):
        # The registered publisher calls this exact file at the same commit;
        # the reusable contract must carry the same identity proofs and no
        # additional input that could change what is verified or published.
        self.assertIn('workflow_call', self.triggers)
        dispatch = self.triggers['workflow_dispatch']['inputs']
        call = self.triggers['workflow_call']['inputs']
        self.assertEqual(set(call), {'tag', 'expected_source_sha', 'expected_ipa_sha256'})
        for name, spec in call.items():
            with self.subTest(input=name):
                self.assertIs(spec.get('required'), True, name)
                self.assertEqual(spec.get('type'), 'string', name)
                self.assertEqual(spec.get('required'), dispatch[name].get('required'))
                self.assertEqual(spec.get('type'), dispatch[name].get('type'))
                self.assertNotIn('default', spec, name)

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


class RegisteredEntryRecoveryRouteTests(unittest.TestCase):
    """The fallback runs through the registered publisher, not a new workflow."""

    GATED_ROOTS = {
        'developer-recovery', 'direct-testflight', 'expedited-testflight',
        'recover-testflight', 'component-recovery', 'prepare-release',
        'lean-request-check', 'lean-source', 'local-artifact-testflight',
        'local-publish',
    }

    @classmethod
    def setUpClass(cls):
        cls.triggers = RELEASE.get('on', RELEASE.get(True))
        cls.inputs = cls.triggers['workflow_dispatch']['inputs']
        cls.jobs = RELEASE['jobs']
        cls.recovery = cls.jobs[RECOVERY_JOB]
        cls.gate = cls.jobs[GATE_JOB]

    @staticmethod
    def digest(value) -> str:
        return hashlib.sha256(json.dumps(
            value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()

    @staticmethod
    def needs(job) -> list:
        needs = job.get('needs', [])
        return [needs] if isinstance(needs, str) else list(needs)

    def test_recovery_inputs_are_explicit_and_old_inputs_are_unchanged(self):
        self.assertEqual(set(self.triggers), {'workflow_dispatch'})
        self.assertEqual(list(self.inputs)[:len(OLD_INPUT_ORDER)], OLD_INPUT_ORDER)
        old = {name: self.inputs[name] for name in OLD_INPUT_ORDER}
        self.assertEqual(self.digest(old), OLD_INPUTS_SHA256)
        self.assertEqual(list(self.inputs)[len(OLD_INPUT_ORDER):],
                         ['published_readback_only', 'expected_source_sha',
                          'expected_ipa_sha256'])
        selector = self.inputs['published_readback_only']
        self.assertEqual(selector['required'], False)
        self.assertIs(selector['default'], False)
        self.assertEqual(selector['type'], 'boolean')
        for name in ('expected_source_sha', 'expected_ipa_sha256'):
            proof = self.inputs[name]
            self.assertEqual(proof['required'], False)
            self.assertEqual(proof['default'], '')
            self.assertEqual(proof['type'], 'string')
        self.assertEqual(RELEASE['permissions'], {'contents': 'read'})

    def test_legacy_selectors_and_all_other_keys_are_unchanged(self):
        self.assertEqual(set(self.jobs),
                         set(LEGACY_JOB_BASELINE) | {RECOVERY_JOB, GATE_JOB})
        for name, (old_if, old_needs, signature) in LEGACY_JOB_BASELINE.items():
            with self.subTest(job=name):
                job = self.jobs[name]
                payload = {key: value for key, value in job.items()
                           if key not in ('if', 'needs')}
                self.assertEqual(self.digest(payload), signature)
                self.assertEqual(job.get('if'), old_if)
                if name in self.GATED_ROOTS:
                    # The only legacy change is the explicit route dependency.
                    self.assertEqual(self.needs(job), [GATE_JOB])
                else:
                    expected = ([] if old_needs is None else
                                [old_needs] if isinstance(old_needs, str)
                                else old_needs)
                    self.assertEqual(self.needs(job), expected)
                # A status-function selector would escape a skipped need.
                for token in ('always()', 'failure()', 'cancelled()'):
                    self.assertNotIn(token, job.get('if') or '', name)

    def test_every_legacy_job_transitively_depends_on_the_route_gate(self):
        def reaches_gate(start: str) -> bool:
            pending, seen = [start], set()
            while pending:
                current = pending.pop()
                if current == GATE_JOB:
                    return True
                if current in seen:
                    continue
                seen.add(current)
                pending.extend(self.needs(self.jobs.get(current, {})))
            return False

        for name in LEGACY_JOB_BASELINE:
            with self.subTest(job=name):
                self.assertTrue(reaches_gate(name),
                                f'{name} does not depend on {GATE_JOB}')

    def test_route_gate_is_selected_only_by_the_recovery_flag(self):
        self.assertEqual(self.gate['if'], '${{ !inputs.published_readback_only }}')
        self.assertEqual(self.gate['runs-on'], 'ubuntu-latest')
        self.assertEqual(self.gate.get('timeout-minutes'), 2)
        self.assertNotIn('uses', self.gate)
        self.assertEqual(len(self.gate.get('steps', [])), 1)
        self.assertIn('legacy release routing is enabled',
                      self.gate['steps'][0]['run'])
        self.assertNotIn('uses', self.gate['steps'][0])
        # The gate is exactly !published_readback_only. Its default false keeps
        # the normal no-op gate selected; true skips it and the skip propagates
        # through every legacy dependency edge proven below.
        self.assertIs(self.inputs['published_readback_only']['default'], False)

    def test_only_the_registered_recovery_job_calls_the_module(self):
        callers = [name for name, job in self.jobs.items()
                   if job.get('uses') == './.github/workflows/repair-release-readback.yml']
        self.assertEqual(callers, [RECOVERY_JOB])
        for job in self.jobs.values():
            for step in job.get('steps', []):
                self.assertNotIn('./.github/workflows/repair-release-readback.yml',
                                 step.get('uses', ''))

    def test_recovery_job_calls_the_same_strict_module_at_the_same_commit(self):
        self.assertEqual(
            self.recovery['if'],
            "${{ github.event_name == 'workflow_dispatch' && inputs.published_readback_only }}")
        self.assertEqual(self.recovery['uses'],
                         './.github/workflows/repair-release-readback.yml')
        self.assertEqual(self.recovery['with'], {
            'tag': '${{ inputs.tag }}',
            'expected_source_sha': '${{ inputs.expected_source_sha }}',
            'expected_ipa_sha256': '${{ inputs.expected_ipa_sha256 }}',
        })
        self.assertNotIn('needs', self.recovery)
        self.assertNotIn('steps', self.recovery)
        self.assertNotIn('secrets', self.recovery)

    def test_recovery_job_grants_only_the_nested_feed_write_scope(self):
        self.assertEqual(self.recovery['permissions'], {
            'contents': 'write', 'actions': 'read', 'attestations': 'read'})
        self.assertNotIn('id-token', self.recovery['permissions'])
        self.assertNotEqual(self.recovery['permissions'].get('attestations'),
                            'write')
        rendered = json.dumps(self.recovery)
        self.assertNotIn('attest-build-provenance', rendered)
        self.assertNotIn('verify_github_release_publication.py', rendered)
        self.assertNotIn('generate_feather_source.py', rendered)
        self.assertNotIn('run', self.recovery)

    def test_called_jobs_stay_within_the_registered_route_permissions(self):
        caller = self.recovery['permissions']
        for job_name in ('verify-published-readback', 'await-feather-publication'):
            for scope, level in REPAIR['jobs'][job_name]['permissions'].items():
                with self.subTest(job=job_name, scope=scope):
                    self.assertIn(scope, caller)
                    if level == 'write':
                        self.assertEqual(caller[scope], 'write')
        self.assertEqual(REPAIR['permissions'], {'contents': 'read'})
        self.assertNotIn('attestations: write', REPAIR_TEXT)
        self.assertNotIn('id-token: write', REPAIR_TEXT)

    def test_recovery_proofs_and_dummy_values_do_not_reach_legacy_routes(self):
        forbidden = (
            'publish', 'local_artifact_sha256', 'transport_tag', 'lean_release',
            'direct_testflight', 'reuse_direct_run', 'reuse_accepted_run',
            'component_recovery_run', 'recover_developer_build191',
            'recover_build_156', 'build191_ui_waiver')
        for key in forbidden:
            self.assertNotIn(key, self.recovery['with'])
        for name, job in self.jobs.items():
            if name in (RECOVERY_JOB, GATE_JOB):
                continue
            rendered = json.dumps(job)
            # "expected_source_sha" is also an existing lean-build with: key
            # bound to lean-source.outputs.source_sha; only the new dispatch
            # input references would cross the routes.
            self.assertNotIn('inputs.expected_source_sha', rendered, name)
            self.assertNotIn('inputs.expected_ipa_sha256', rendered, name)

    def test_concurrency_serializes_recovery_with_the_normal_tag_run(self):
        self.assertEqual(RELEASE['concurrency'], {
            'group': 'floe-release-${{ github.ref }}',
            'cancel-in-progress': False})
        self.assertEqual(self.recovery['concurrency'], {
            'group': 'floe-release-refs/tags/${{ inputs.tag }}',
            'cancel-in-progress': False})
        tag = 'v1.7.39'
        self.assertEqual('floe-release-refs/tags/' + tag,
                         'floe-release-' + 'refs/tags/' + tag)
        self.assertNotEqual('floe-release-refs/tags/' + tag,
                            'floe-release-refs/heads/main')
        self.assertEqual(REPAIR['concurrency']['group'],
                         'floe-published-readback-${{ inputs.tag }}')
        self.assertEqual(FEATHER['concurrency']['group'], 'floe-feather-source')
        self.assertNotEqual('floe-release-refs/tags/' + tag,
                            REPAIR['concurrency']['group'].replace(
                                '${{ inputs.tag }}', tag))
        self.assertNotEqual('floe-release-refs/tags/' + tag,
                            FEATHER['concurrency']['group'])

    def test_default_false_keeps_the_original_selector_and_gate_result(self):
        # With the default false the gate runs and every original selector is
        # evaluated exactly as recorded in the baseline; nothing above changes
        # the selector text. The Bash 3 fixture also executes the unchanged
        # readback commands themselves.
        self.assertIs(self.inputs['published_readback_only']['default'], False)
        for name, (old_if, _, _) in LEGACY_JOB_BASELINE.items():
            self.assertEqual(self.jobs[name].get('if'), old_if, name)


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
                      'Delivery is not yet complete.', 'local-publish',
                      'published_readback_only', 'workflow_call', '404',
                      'registered-entry'):
            self.assertIn(token, text)


if __name__ == '__main__':
    unittest.main()
