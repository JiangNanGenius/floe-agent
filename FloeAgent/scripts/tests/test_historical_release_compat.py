"""Hermetic contracts, using the real producer scripts and extracted workflow steps.

Tiny synthetic device IPAs/gh metadata are fixtures, never historical delivery
proof. No workflow dispatch, network write, App build or real asset is needed.
"""
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

import yaml

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
REPO = HERE.parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


feed = load('historical_feed', SCRIPTS / 'generate_feather_source.py')
fixture = load('historical_publication_fixture', HERE / 'test_verify_github_release_publication.py')
pointer = load('historical_pointer', SCRIPTS / 'snapshot_github_latest.py')
release_workflow = yaml.safe_load((REPO / '.github/workflows/release-unsigned-ipa.yml').read_text())
feather_workflow = yaml.safe_load((REPO / '.github/workflows/publish-feather-source.yml').read_text())


def step(workflow, job, name):
    return next(item for item in workflow['jobs'][job]['steps'] if item.get('name') == name)


def python_body(run, delimiter='PY'):
    lines = run.splitlines()
    start = next(i for i, line in enumerate(lines) if line.rstrip().endswith("<<'" + delimiter + "'"))
    end = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == delimiter)
    return '\n'.join(lines[start + 1:end]) + '\n'


def latest_snapshot():
    name = 'Floe-Agent-1.8.5-build325-unsigned.ipa'
    assets = []
    for i, asset_name in enumerate((name, name + '.sha256'), 51):
        assets.append({'name': asset_name, 'id': i, 'state': 'uploaded', 'size': 200 + i,
                       'digest': 'sha256:' + str(i % 10) * 64,
                       'browser_download_url': f'https://github.com/JiangNanGenius/floe-agent/releases/download/v1.8.5/{asset_name}'})
    return {'schemaVersion': 1,
            'release': {'id': 325, 'tag_name': 'v1.8.5', 'draft': False, 'prerelease': False,
                        'published_at': '2026-11-08T00:00:00Z', 'assets': assets},
            'tagRef': {'ref': 'refs/tags/v1.8.5', 'object': {'type': 'commit', 'sha': 'c' * 40}},
            'tagObject': {}}


class HistoricalReleaseCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def make_feed(self, build, previous=None, **kwargs):
        version = '1.8.5' if build == 325 else f'1.7.{build - 241}'
        ipa = self.root / f'Floe-Agent-{version}-build{build}-unsigned.ipa'
        with zipfile.ZipFile(ipa, 'w') as archive:
            archive.writestr('Payload/Floe Agent.app/Info.plist', plistlib.dumps({
                'CFBundleIdentifier': 'org.floeagent.ios', 'CFBundleShortVersionString': version,
                'CFBundleVersion': str(build), 'MinimumOSVersion': '26.0'}))
        return feed.generate(ipa, 'v' + version, 'a' * 40, '2026-11-08T00:00:00Z',
                             previous=previous, **kwargs)

    def test_historical_merge_preserves_325_and_all_primary_history_and_legacy_fields(self):
        previous = None
        for build in range(300, 326):
            previous = self.make_feed(build, previous)
        original_head = copy.deepcopy(previous['apps'][0]['versions'][0])
        merged = self.make_feed(275, previous, historical=True, preserve_latest_tag='v1.8.5')
        app = merged['apps'][0]
        self.assertEqual(len(app['versions']), 27)  # no ten-entry truncation
        self.assertEqual([int(x['buildVersion']) for x in app['versions']], list(range(325, 299, -1)) + [275])
        self.assertEqual(app['versions'][0], original_head)
        for app_key, key in (('version', 'version'), ('versionDate', 'date'), ('size', 'size'), ('downloadURL', 'downloadURL')):
            self.assertEqual(app[app_key], original_head[key])
        self.assertEqual(merged, self.make_feed(275, merged, historical=True, preserve_latest_tag='v1.8.5'))

    def test_rollback_wrong_preserved_head_and_conflicting_builds_remain_rejected(self):
        previous = self.make_feed(325)
        with self.assertRaises(ValueError):
            self.make_feed(275, previous)
        for preserved in ('', 'v1.8.4'):
            with self.subTest(preserved=preserved), self.assertRaises(ValueError):
                self.make_feed(275, previous, historical=True, preserve_latest_tag=preserved)
        merged = self.make_feed(275, previous, historical=True, preserve_latest_tag='v1.8.5')
        merged['apps'][0]['versions'][-1]['sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            self.make_feed(275, merged, historical=True, preserve_latest_tag='v1.8.5')

    def run_feed_readback(self, live, published, generated):
        checker = python_body(step(feather_workflow, 'publish-source', 'Read back the live feed and the bound release asset')['run'])
        paths = []
        for name, payload in (('live', live), ('published', published), ('generated', generated)):
            path = self.root / (name + '.json'); path.write_text(json.dumps(payload)); paths.append(str(path))
        return subprocess.run([sys.executable, '-c', checker, *paths, 'v1.7.34', 'a' * 40],
                              capture_output=True, text=True)

    def test_actual_feed_readback_finds_a_non_head_target_and_rejects_loss_or_corruption(self):
        generated = self.make_feed(275, self.make_feed(325), historical=True, preserve_latest_tag='v1.8.5')
        target = generated['apps'][0]['versions'][-1]
        asset = {'name': target['downloadURL'].rsplit('/', 1)[-1], 'browser_download_url': target['downloadURL'],
                 'state': 'uploaded', 'size': target['size'], 'digest': 'sha256:' + target['sha256']}
        published = {'tag_name': 'v1.7.34', 'draft': False, 'published_at': target['date'], 'assets': [asset]}
        result = self.run_feed_readback(generated, published, generated)
        self.assertEqual(result.returncode, 0, result.stderr)
        for mutation in ('missing target', 'legacy changed', 'head changed', 'source changed', 'foreign asset'):
            with self.subTest(mutation=mutation):
                live, release = copy.deepcopy(generated), copy.deepcopy(published)
                if mutation == 'missing target': live['apps'][0]['versions'].pop()
                elif mutation == 'legacy changed': live['apps'][0]['downloadURL'] = target['downloadURL']
                elif mutation == 'head changed': live['apps'][0]['versions'].reverse()
                elif mutation == 'source changed': live['apps'][0]['versions'][-1]['sourceCommit'] = 'f' * 40
                else: release['assets'][0]['browser_download_url'] = 'https://example.invalid/' + asset['name']
                self.assertNotEqual(self.run_feed_readback(live, release, generated).returncode, 0)

    def historical_publication(self, value=None, *, before=None, after=None, staged=True):
        value = value or fixture.Fixture()
        self.addCleanup(value.close)
        before = before or latest_snapshot(); after = after or copy.deepcopy(before)
        extra = ['--preserve-latest-before-json', str(value.write('before.json', before)),
                 '--preserve-latest-after-json', str(value.write('after.json', after)),
                 '--expect-ipa-sha256', value.ipa_digest]
        args = value.args(release=fixture.release_json(fixture.valid_assets(value.ipa_bytes)),
                          latest=after['release'], staged=staged, extra=extra)
        return fixture.run(args)

    def test_strict_historical_readback_binds_full_device_bytes_and_unchanged_latest_source(self):
        code, output, error = self.historical_publication()
        self.assertEqual(code, 0, error)
        result = json.loads(output)
        self.assertTrue(result['installableDelivery'])
        self.assertEqual(result['sourceCommit'], fixture.SOURCE)
        self.assertEqual(result['latest']['tag'], 'v1.8.5')
        self.assertEqual(result['latest']['sourceCommit'], 'c' * 40)
        self.assertEqual(result['latest']['mode'], 'preserved')
        self.assertEqual(result['staged']['deviceBinary']['platform'], 'IOS')

    def test_latest_replacement_tag_mutation_asset_change_or_missing_device_bytes_fail_closed(self):
        for mutation in ('release', 'source', 'asset', 'draft', 'prerelease'):
            with self.subTest(mutation=mutation):
                before = latest_snapshot(); after = copy.deepcopy(before)
                if mutation == 'release': after['release']['id'] += 1
                elif mutation == 'source': after['tagRef']['object']['sha'] = 'd' * 40
                elif mutation == 'asset': after['release']['assets'][0]['digest'] = 'sha256:' + 'd' * 64
                else: after['release'][mutation] = True
                self.assertNotEqual(self.historical_publication(before=before, after=after)[0], 0)
        self.assertNotEqual(self.historical_publication(staged=False)[0], 0)
        simulator = fixture.Fixture(ipa_bytes=fixture.make_ipa(executable=fixture.macho(platform=7)))
        self.assertNotEqual(self.historical_publication(simulator)[0], 0)

    def test_latest_snapshot_uses_only_read_apis_and_the_explicit_tag(self):
        expected = latest_snapshot(); calls = []
        responses = {'repos/JiangNanGenius/floe-agent/releases/latest': expected['release'],
                     'repos/JiangNanGenius/floe-agent/git/ref/tags/v1.8.5': expected['tagRef']}
        def api(path): calls.append(path); return responses[path]
        self.assertEqual(pointer.capture('JiangNanGenius/floe-agent', 'v1.8.5', api), expected)
        self.assertEqual(calls, list(responses))
        with self.assertRaises(ValueError):
            pointer.capture('JiangNanGenius/floe-agent', 'v1.8.4', api)
        annotated = copy.deepcopy(expected)
        annotated['tagRef']['object'] = {'type': 'tag', 'sha': 'f' * 40}
        annotated['tagObject'] = {'tag': 'v1.8.5', 'sha': 'f' * 40,
                                  'object': {'type': 'commit', 'sha': 'c' * 40}}
        responses['repos/JiangNanGenius/floe-agent/git/ref/tags/v1.8.5'] = annotated['tagRef']
        responses['repos/JiangNanGenius/floe-agent/git/tags/' + 'f' * 40] = annotated['tagObject']
        self.assertEqual(pointer.capture('JiangNanGenius/floe-agent', 'v1.8.5', api), annotated)
        annotated['tagObject']['tag'] = 'v1.8.4'
        with self.assertRaises(ValueError):
            pointer.capture('JiangNanGenius/floe-agent', 'v1.8.5', api)

    def test_actual_route_guard_rejects_signing_rebuild_prerelease_and_recovery_combinations(self):
        run = step(release_workflow, 'published-readback-route-gate', 'Confirm a normal release request')['run']
        script = python_body(run, 'PYINPUT')
        valid = {'historical_release': True, 'preserve_latest_tag': 'v1.8.5', 'tag': 'v1.7.34',
                 'publish': True, 'local_artifact_sha256': 'a' * 64, 'transport_tag': 'private-fixture'}
        def execute(inputs):
            return subprocess.run([sys.executable, '-c', script], capture_output=True, text=True,
                                  env=dict(os.environ, REQUEST_INPUTS=json.dumps(inputs)))
        self.assertEqual(execute(valid).returncode, 0)
        self.assertEqual(execute({}).returncode, 0)
        for field in ('github_prerelease', 'direct_testflight', 'lean_release', 'published_readback_only',
                      'recover_developer_build191', 'recover_build_156', 'build191_ui_waiver',
                      'reuse_accepted_run', 'component_recovery_run', 'reuse_direct_run'):
            with self.subTest(field=field):
                self.assertNotEqual(execute(dict(valid, **{field: True})).returncode, 0)
        self.assertNotEqual(execute(dict(valid, preserve_latest_tag='v1.7.34')).returncode, 0)
        self.assertNotEqual(execute({'preserve_latest_tag': 'v1.8.5'}).returncode, 0)

    def test_actual_publisher_flags_and_awaited_feed_keep_source_attestation_checks(self):
        job = release_workflow['jobs']['local-publish']
        run = step(release_workflow, 'local-publish', 'Publish the normal stable release without clobbering')['run']
        begin = run.index('if [[ "$RELEASE_PRERELEASE" == true ]]')
        end = run.index('\nfi', begin) + len('\nfi')
        shell = run[begin:end] + '\nprintf "%s\\n" "${RELEASE_MODE_ARGS[@]}"\n'
        for historical, prerelease, expected in ((False, False, ['--latest=true']),
                                                (True, False, ['--latest=false']),
                                                (False, True, ['--prerelease', '--latest=false'])):
            result = subprocess.run(['/bin/bash', '-c', 'set -euo pipefail\n' + shell],
                                    capture_output=True, text=True,
                                    env=dict(os.environ, RELEASE_PRERELEASE=str(prerelease).lower(),
                                             HISTORICAL_RELEASE=str(historical).lower()))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), expected)
        preflight = step(release_workflow, 'local-publish', 'Require the local tag and release copy before any publication')['run']
        self.assertIn('"$GITHUB_SHA" != "$TAG_COMMIT"', preflight)
        self.assertIn('"$GITHUB_REF" != "refs/tags/$RELEASE_TAG"', preflight)
        verify = step(release_workflow, 'local-publish', 'Verify the attestation exactly as Feather will')['run']
        self.assertIn('--source-digest "$SOURCE_SHA"', verify)
        self.assertIn('--signer-workflow "$GITHUB_REPOSITORY/.github/workflows/release-unsigned-ipa.yml"', verify)
        downstream = release_workflow['jobs']['feather-local-release']
        self.assertEqual(downstream['needs'], ['local-publish'])
        self.assertEqual(downstream['uses'], './.github/workflows/publish-feather-source.yml')
        self.assertEqual(downstream['with']['historical_release'], '${{ inputs.historical_release }}')


if __name__ == '__main__':
    unittest.main()
