"""Focused fail-closed tests for the external/public TestFlight helper.

These tests use an in-memory App Store Connect double and a real temporary git
repository for source-tag verification. They never touch the network and never
perform a real submission.
"""
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

import yaml

MODULE_PATH = Path(__file__).parents[1] / 'public_testflight.py'
spec = importlib.util.spec_from_file_location('public_testflight', MODULE_PATH)
pt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pt)

WORKFLOW = Path(__file__).parents[3] / '.github' / 'workflows' / 'public-testflight.yml'
REPO = Path(__file__).parents[3]

PROJECT_YML = (
    'name: FloeAgent\n'
    'settings:\n'
    '  base:\n'
    '    PRODUCT_BUNDLE_IDENTIFIER: org.floeagent.ios\n'
    '    MARKETING_VERSION: "1.7.0"\n'
    '    CURRENT_PROJECT_VERSION: "241"\n'
)

# Explicit final product-text fixture. It deliberately shares no wording with
# the repo draft files, so tests never submit (or validate) the current draft.
REVIEW_NOTES_TEXT = (
    'Floe Agent review guidance. The app is an iPad-first AI workspace with iPhone support.\n'
    'Cloud AI is optional and bring-your-own-key; the app ships no provider key and no credit.\n'
    'Notes, PDF annotation, documents and Canvas work without any AI service. On-device inference\n'
    "uses MLX local models that the user downloads from Settings; those downloads are Beta and\n"
    "optional. Apple's system model, when available, is a separate path.\n\n"
    'Suggested walkthrough: open Notes, import a sample document, annotate it, close and reopen;\n'
    'open a prepared Office file; create a canvas and verify it after relaunch.'
)


def make_source_repo(root):
    repo = Path(root) / 'repo'
    (repo / 'FloeAgent').mkdir(parents=True)
    (repo / 'FloeAgent' / 'project.yml').write_text(PROJECT_YML)
    env = dict(os.environ)
    env.update({
        'GIT_AUTHOR_NAME': 'test', 'GIT_AUTHOR_EMAIL': 'test@example.com',
        'GIT_COMMITTER_NAME': 'test', 'GIT_COMMITTER_EMAIL': 'test@example.com',
    })
    subprocess.run(['git', 'init', '-q'], cwd=repo, check=True, env=env)
    subprocess.run(['git', 'add', '.'], cwd=repo, check=True, env=env)
    subprocess.run(['git', 'commit', '-qm', 'base'], cwd=repo, check=True, env=env)
    subprocess.run(['git', 'tag', 'v1.7.0'], cwd=repo, check=True, env=env)
    sha = subprocess.check_output(['git', '-C', repo, 'rev-parse', 'HEAD'], text=True).strip()
    return repo, sha


def external_group(**overrides):
    group = {
        'type': 'betaGroups', 'id': 'grp-ext',
        'attributes': {
            'name': 'publictest1', 'isInternalGroup': False, 'publicLinkEnabled': False,
            'publicLinkId': None, 'publicLinkLimitEnabled': False, 'publicLinkLimit': 10000,
            'feedbackEnabled': True,
        },
    }
    group['attributes'].update(overrides)
    return group


def internal_group():
    return {
        'type': 'betaGroups', 'id': 'grp-qa',
        'attributes': {
            'name': 'Floe QA', 'isInternalGroup': True, 'publicLinkEnabled': False,
            'publicLinkLimitEnabled': False, 'feedbackEnabled': True,
        },
    }


def review_detail(**overrides):
    attributes = {
        'contactFirstName': 'Review', 'contactLastName': 'Contact',
        'contactEmail': 'private-review@example.com', 'contactPhone': '+1 555 0100',
        'demoAccountRequired': False, 'demoAccountName': None, 'demoAccountPassword': None,
        'notes': 'private review notes body',
    }
    attributes.update(overrides)
    return {'type': 'betaAppReviewDetails', 'id': 'bad-1', 'attributes': attributes}


def beta_app_localization(locale, description='old description', **overrides):
    attributes = {
        'locale': locale, 'description': description, 'feedbackEmail': 'beta-feedback@example.com',
        'marketingUrl': 'https://example.com/', 'privacyPolicyUrl': 'https://example.com/privacy',
    }
    attributes.update(overrides)
    return {'type': 'betaAppLocalizations', 'id': 'bal-' + locale, 'attributes': attributes}


def app_info_localization(locale, privacy_policy_url=None):
    return {'type': 'appInfoLocalizations', 'id': 'ail-' + locale,
            'attributes': {'locale': locale, 'privacyPolicyUrl': privacy_policy_url}}


def version_localization(locale, support_url=None):
    return {'type': 'appStoreVersionLocalizations', 'id': 'avl-' + locale,
            'attributes': {'locale': locale, 'supportUrl': support_url}}


class FakeASC:
    """Deterministic App Store Connect double; records every request."""

    def __init__(self, *, audience='APP_STORE_ELIGIBLE', processing='VALID', expired=False,
                 groups=None, submissions=None, detail=None, beta_app_locs=None,
                 build_locs=None, apply_writes=True, apply_review_notes_write=True,
                 apply_demo_required_write=True, apply_privacy_write=True,
                 apply_create_write=True, app_info_locs=None, version_locs=None,
                 fail_discovery_status=None,
                 post_state='WAITING_FOR_REVIEW',
                 fail_review_detail_status=None, platform='IOS', include_non_ios_duplicate=False,
                 patch_sets_public_link=True):
        self.audience = audience
        self.processing = processing
        self.expired = expired
        self.groups = list(groups) if groups is not None else [external_group(), internal_group()]
        self.submissions = list(submissions or [])
        # Fresh detail per fake: the review-notes write path mutates it, so a
        # shared default would leak state across tests.
        self.detail = detail if detail is not None else review_detail()
        self.beta_app_locs = list(beta_app_locs) if beta_app_locs is not None else [
            beta_app_localization('en-US'), beta_app_localization('zh-Hans')]
        self.build_locs = list(build_locs or [])
        self.apply_writes = apply_writes
        self.apply_review_notes_write = apply_review_notes_write
        self.apply_demo_required_write = apply_demo_required_write
        self.apply_privacy_write = apply_privacy_write
        self.apply_create_write = apply_create_write
        self.app_info_locs = list(app_info_locs or [])
        self.version_locs = list(version_locs or [])
        self.fail_discovery_status = fail_discovery_status
        self.post_state = post_state
        self.fail_review_detail_status = fail_review_detail_status
        self.platform = platform
        self.include_non_ios_duplicate = include_non_ios_duplicate
        self.patch_sets_public_link = patch_sets_public_link
        self.attached = set()
        self.calls = []
        self.writes = []

    # -- resources ---------------------------------------------------------
    def app(self):
        return {'type': 'apps', 'id': 'app-1', 'attributes': {'name': 'Floe Agent', 'bundleId': 'org.floeagent.ios', 'sku': 'floe'}}

    def build(self, build_id='build-1', prerelease_id='pr-1'):
        return {
            'type': 'builds', 'id': build_id,
            'attributes': {
                'version': '241', 'uploadedDate': '2026-10-02T00:00:00Z',
                'processingState': self.processing, 'expired': self.expired,
                'buildAudienceType': self.audience,
            },
            'relationships': {
                'app': {'data': {'type': 'apps', 'id': 'app-1'}},
                'preReleaseVersion': {'data': {'type': 'preReleaseVersions', 'id': prerelease_id}},
                'buildBetaDetail': {'data': {'type': 'buildBetaDetails', 'id': 'bbd-1'}},
                'betaGroups': {'data': [{'type': 'betaGroups', 'id': 'grp-ext'}] if build_id in self.attached else []},
            },
        }

    def detail_resource(self):
        return {'type': 'buildBetaDetails', 'id': 'bbd-1',
                'attributes': {'internalBuildState': 'IN_BETA_TESTING', 'externalBuildState': 'READY_FOR_BETA_TESTING'}}

    # -- transport ---------------------------------------------------------
    def call(self, method, path, body=None):
        self.calls.append((method, path, body))
        if method != 'GET':
            self.writes.append((method, path, body))
            return self.write(method, path, body)
        return self.read(path)

    def write(self, method, path, body):
        if method == 'POST' and path == '/v1/betaBuildLocalizations':
            locale = body['data']['attributes']['locale']
            if self.apply_writes:
                self.build_locs = [item for item in self.build_locs
                                   if item['attributes']['locale'] != locale]
                self.build_locs.append({
                    'type': 'betaBuildLocalizations', 'id': 'loc-' + locale,
                    'attributes': {'locale': locale, 'whatsNew': body['data']['attributes']['whatsNew']}})
            return {'data': {'id': 'loc-' + locale}}
        if method == 'PATCH' and path.startswith('/v1/betaBuildLocalizations/'):
            if self.apply_writes:
                locale = path.rsplit('/', 1)[1].replace('loc-', '')
                for item in self.build_locs:
                    if item['id'] == path.rsplit('/', 1)[1]:
                        item['attributes']['whatsNew'] = body['data']['attributes']['whatsNew']
            return {}
        if method == 'POST' and path == '/v1/betaAppLocalizations':
            locale = body['data']['attributes']['locale']
            if any(item['attributes']['locale'] == locale for item in self.beta_app_locs):
                raise AssertionError('duplicate betaAppLocalizations POST for ' + locale)
            if self.apply_writes and self.apply_create_write:
                self.beta_app_locs.append({'type': 'betaAppLocalizations', 'id': 'bal-' + locale,
                                           'attributes': dict(body['data']['attributes'])})
            return {'data': {'id': 'bal-' + locale}}
        if method == 'PATCH' and path.startswith('/v1/betaAppLocalizations/'):
            if self.apply_writes:
                for item in self.beta_app_locs:
                    if item['id'] == path.rsplit('/', 1)[1]:
                        attributes = body['data']['attributes']
                        if 'description' in attributes:
                            item['attributes']['description'] = attributes['description']
                        if 'privacyPolicyUrl' in attributes and self.apply_privacy_write:
                            item['attributes']['privacyPolicyUrl'] = attributes['privacyPolicyUrl']
            return {}
        if method == 'POST' and path == '/v1/betaGroups/grp-ext/relationships/builds':
            if self.apply_writes:
                self.attached.add('build-1')
            return {}
        if method == 'PATCH' and path.startswith('/v1/betaAppReviewDetails/'):
            attributes = dict(body['data']['attributes'])
            if self.apply_writes:
                if 'notes' in attributes and not self.apply_review_notes_write:
                    attributes.pop('notes')
                if 'demoAccountRequired' in attributes and not self.apply_demo_required_write:
                    attributes.pop('demoAccountRequired')
                self.detail['attributes'].update(attributes)
            return {}
        if method == 'PATCH' and path == '/v1/betaGroups/grp-ext':
            if self.apply_writes:
                for group in self.groups:
                    if group['id'] == 'grp-ext':
                        group['attributes'].update(body['data']['attributes'])
                        if not group['attributes'].get('publicLinkId'):
                            group['attributes']['publicLinkId'] = 'abc123'
                        if self.patch_sets_public_link:
                            group['attributes'].setdefault(
                                'publicLink', 'https://testflight.apple.com/join/abc123')
            return {}
        if method == 'POST' and path == '/v1/betaAppReviewSubmissions':
            created = {'type': 'betaAppReviewSubmissions', 'id': 'sub-new',
                       'attributes': {'betaReviewState': self.post_state, 'submittedDate': '2026-10-02T01:00:00Z'}}
            if self.apply_writes:
                self.submissions.append(created)
            return {'data': created}
        raise AssertionError(f'unexpected write {method} {path}')

    def read(self, path):
        base = path.split('?', 1)[0]
        if base == '/v1/apps':
            return {'data': [self.app()]}
        if base == '/v1/builds':
            release_attributes = {'version': '1.7.0'}
            if self.platform is not None:
                release_attributes['platform'] = self.platform
            data = [self.build()]
            included = [self.app(),
                        {'type': 'preReleaseVersions', 'id': 'pr-1', 'attributes': release_attributes},
                        self.detail_resource()]
            if self.include_non_ios_duplicate:
                data.append(self.build('build-2', 'pr-2'))
                included.append({'type': 'preReleaseVersions', 'id': 'pr-2',
                                 'attributes': {'version': '1.7.0', 'platform': 'MAC_OS'}})
            return {'data': data, 'included': included}
        if base == '/v1/builds/build-1':
            return {'data': self.build(),
                    'included': [group for group in self.groups if group['id'] == 'grp-ext'] if 'build-1' in self.attached else []}
        if base == '/v1/betaGroups':
            return {'data': list(self.groups)}
        if base == '/v1/betaGroups/grp-ext':
            return {'data': next(group for group in self.groups if group['id'] == 'grp-ext')}
        if base == '/v1/betaBuildLocalizations':
            return {'data': list(self.build_locs)}
        if base == '/v1/betaAppLocalizations':
            return {'data': list(self.beta_app_locs)}
        if base == '/v1/apps/app-1/betaAppReviewDetail':
            if self.fail_review_detail_status:
                raise pt.ApiError('GET', path, self.fail_review_detail_status, 'NOT_FOUND')
            return {'data': self.detail}
        if base == '/v1/apps/app-1/appInfos':
            if self.fail_discovery_status:
                raise pt.ApiError('GET', path, self.fail_discovery_status, 'FORBIDDEN')
            return {'data': [{'type': 'appInfos', 'id': 'info-1', 'attributes': {}}],
                    'included': list(self.app_info_locs)}
        if base == '/v1/apps/app-1/appStoreVersions':
            if self.fail_discovery_status:
                raise pt.ApiError('GET', path, self.fail_discovery_status, 'FORBIDDEN')
            return {'data': [{'type': 'appStoreVersions', 'id': 'ver-1',
                              'attributes': {'platform': 'IOS', 'versionString': '1.7.0'}}],
                    'included': list(self.version_locs)}
        if base == '/v1/betaAppReviewSubmissions':
            return {'data': list(self.submissions)}
        raise AssertionError(f'unexpected GET {path}')


class PublicTestFlightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.repo, cls.sha = make_source_repo(cls.tmp.name)
        cls.notes = Path(cls.tmp.name) / 'whats-new.json'
        cls.notes.write_text(json.dumps({'en-US': 'Test the repaired slideshow.', 'zh-Hans': '测试修复后的放映。'}))
        cls.descriptions = Path(cls.tmp.name) / 'description.json'
        cls.descriptions.write_text(json.dumps({'en-US': 'Prepared English beta description.', 'zh-Hans': '准备好的中文测试版说明。'}))
        cls.review_notes = Path(cls.tmp.name) / 'review-notes.final.txt'
        cls.review_notes.write_text(REVIEW_NOTES_TEXT)
        cls.draft_review_notes = Path(cls.tmp.name) / 'review-notes.draft.md'
        cls.draft_review_notes.write_text(
            '# TestFlight App Review notes — draft\n'
            'Status: draft, not submitted; do not paste into App Store Connect.\n\n'
            'Submitted version/build: [FROZEN VERSION / BUILD. Candidate is only a plan].\n')

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def inspect(self, fake, **overrides):
        values = {
            'bundle_id': 'org.floeagent.ios', 'version': '1.7.0', 'build': '241', 'tag': 'v1.7.0',
            'source_sha': self.sha, 'group_name': 'publictest1', 'repo_root': self.repo, 'call': fake.call,
            'notes_path': self.notes, 'description_path': self.descriptions,
            'review_notes_path': None,
        }
        values.update(overrides)
        return pt.inspect(**values)

    def submit(self, fake, **overrides):
        values = {
            'bundle_id': 'org.floeagent.ios', 'version': '1.7.0', 'build': '241', 'tag': 'v1.7.0',
            'source_sha': self.sha, 'group_name': 'publictest1', 'repo_root': self.repo, 'call': fake.call,
            'notes_path': self.notes, 'description_path': self.descriptions,
            'review_notes_path': self.review_notes, 'confirm_submit': True,
        }
        values.update(overrides)
        return pt.submit(**values)

    def assert_no_writes(self, fake):
        self.assertEqual([call for call in fake.calls if call[0] != 'GET'], [])

    # -- read-only inspect -------------------------------------------------
    def test_inspect_is_read_only_and_sanitized(self):
        fake = FakeASC()
        result = self.inspect(fake)
        self.assertTrue(result['ok'], result['issues'])
        self.assertEqual([call[0] for call in fake.calls], ['GET'] * len(fake.calls))
        rendered = json.dumps(result, sort_keys=True)
        self.assertNotIn('private-review@example.com', rendered)
        self.assertNotIn('private review notes body', rendered)
        self.assertNotIn('beta-feedback@example.com', rendered)
        self.assertNotIn('old description', rendered)
        self.assertIn('https://example.com/privacy', rendered)
        self.assertTrue(result['notes']['pendingWrite'])
        self.assertEqual(result['submission'], {'count': 0, 'states': []})
        self.assertEqual(result['whatToTestMissingLocales'], ['en-US', 'zh-Hans'])
        self.assertEqual(result['externalGroup']['name'], 'publictest1')
        self.assertFalse(result['externalGroup']['publicLinkEnabled'])
        self.assertIsNone(result['externalGroup']['publicLink'])
        self.assertNotIn('context', result)
        self.assertEqual(result['reviewDetail']['missingFields'], [])
        self.assertFalse(result['reviewDetail']['demoAccountRequired'])
        self.assertTrue(result['reviewDetail']['demoAccountCredentialsComplete'])
        # Without a prepared review-notes file the current note can only be
        # reported as present; its text and match state are never exposed.
        self.assertFalse(result['reviewNotes']['provided'])
        self.assertTrue(result['reviewNotes']['currentNotesPresent'])
        self.assertIsNone(result['reviewNotes']['currentNotesMatchPrepared'])
        self.assertNotIn('private review notes body', rendered)

    def test_inspect_reports_missing_fields_by_name_only(self):
        fake = FakeASC(detail=review_detail(contactPhone=None, notes=None),
                       beta_app_locs=[beta_app_localization('en-US', feedbackEmail=None),
                                      beta_app_localization('zh-Hans', description=None)])
        # Without a prepared description input the empty zh-Hans description
        # cannot be repaired by this helper, so it must still block.
        result = self.inspect(fake, description_path=None)
        self.assertFalse(result['ok'])
        self.assertIn('betaAppReviewDetail is missing required contact field: contactPhone', result['issues'])
        self.assertIn('betaAppReviewDetail notes are empty; provide the prepared review-notes file for submit',
                      result['issues'])
        self.assertIn('betaAppLocalizations feedbackEmail is empty for: en-US', result['issues'])
        self.assertIn('betaAppLocalizations description is empty for: zh-Hans', result['issues'])
        rendered = json.dumps(result, sort_keys=True)
        self.assertNotIn('private-review@example.com', rendered)

    # -- demo account requirement -----------------------------------------
    def test_demo_account_required_true_needs_both_credentials(self):
        for overrides in ({'demoAccountName': None, 'demoAccountPassword': None},
                          {'demoAccountName': 'review-user', 'demoAccountPassword': None},
                          {'demoAccountName': None, 'demoAccountPassword': 'demo-secret'}):
            with self.subTest(overrides=sorted(overrides)):
                fake = FakeASC(detail=review_detail(demoAccountRequired=True, **overrides))
                result = self.inspect(fake)
                self.assertFalse(result['ok'])
                self.assertTrue(any(name in result['reviewDetail']['missingFields']
                                    for name in ('demoAccountName', 'demoAccountPassword')))
                self.assertTrue(any('demoAccountRequired is true' in issue for issue in result['issues']))
                rendered = json.dumps(result, sort_keys=True)
                self.assertNotIn('review-user', rendered)
                self.assertNotIn('demo-secret', rendered)
                with self.assertRaises(ValueError):
                    self.submit(fake)
                self.assert_no_writes(fake)

    def test_demo_account_required_true_with_both_credentials_is_clean(self):
        fake = FakeASC(detail=review_detail(demoAccountRequired=True,
                                            demoAccountName='review-user',
                                            demoAccountPassword='demo-secret'))
        result = self.inspect(fake)
        self.assertTrue(result['ok'], result['issues'])
        self.assertTrue(result['reviewDetail']['demoAccountCredentialsComplete'])
        self.assertTrue(result['reviewDetail']['demoAccountNamePresent'])
        self.assertTrue(result['reviewDetail']['demoAccountPasswordPresent'])
        rendered = json.dumps(result, sort_keys=True)
        self.assertNotIn('review-user', rendered)
        self.assertNotIn('demo-secret', rendered)

    def test_demo_account_not_required_ignores_credentials(self):
        fake = FakeASC()
        result = self.inspect(fake)
        self.assertTrue(result['ok'], result['issues'])
        self.assertNotIn('demoAccountName', result['reviewDetail']['missingFields'])
        self.assertNotIn('demoAccountPassword', result['reviewDetail']['missingFields'])

    def test_demo_account_requirement_unconfirmed_blocks_until_known(self):
        fake = FakeASC(detail=review_detail(demoAccountRequired=None))
        result = self.inspect(fake)
        self.assertFalse(result['ok'])
        self.assertIn('demoAccountRequired', result['reviewDetail']['missingFields'])
        self.assertTrue(any('unconfirmed' in issue for issue in result['issues']))
        with self.assertRaises(ValueError):
            self.submit(fake)
        self.assert_no_writes(fake)

    def test_inspect_cross_checks_internal_only_build(self):
        fake = FakeASC(audience='INTERNAL_ONLY')
        result = self.inspect(fake)
        self.assertFalse(result['ok'])
        self.assertIn('build audience is not APP_STORE_ELIGIBLE (INTERNAL_ONLY builds cannot be externally tested)',
                      result['issues'])
        self.assertEqual(result['buildState']['audience'], 'INTERNAL_ONLY')

    # -- IOS platform binding ----------------------------------------------
    def test_candidate_requires_ios_prerelease_platform(self):
        for platform in (None, 'MAC_OS', 'VISION_OS', 'TV_OS'):
            with self.subTest(platform=platform):
                fake = FakeASC(platform=platform)
                result = self.inspect(fake)
                self.assertFalse(result['ok'])
                self.assertTrue(any('IOS' in issue for issue in result['issues']))
                with self.assertRaises(ValueError):
                    self.submit(fake)
                self.assert_no_writes(fake)

    def test_non_ios_duplicate_build_does_not_shadow_ios_candidate(self):
        fake = FakeASC(include_non_ios_duplicate=True)
        result = self.inspect(fake)
        self.assertTrue(result['ok'], result['issues'])
        self.assertEqual(result['buildState']['buildId'], 'build-1')

    # -- source binding ----------------------------------------------------
    def test_source_tag_must_resolve_to_frozen_sha(self):
        evidence = pt.source_evidence(self.repo, 'v1.7.0', self.sha, 'org.floeagent.ios', '1.7.0', '241')
        self.assertTrue(evidence['verified'])
        self.assertEqual(evidence['tagCommit'], self.sha)
        with self.assertRaisesRegex(ValueError, 'tag_commit_mismatch'):
            pt.source_evidence(self.repo, 'v1.7.0', '0' * 40, 'org.floeagent.ios', '1.7.0', '241')
        with self.assertRaisesRegex(ValueError, 'not present'):
            pt.source_evidence(self.repo, 'v1.9.9', self.sha, 'org.floeagent.ios', '1.7.0', '241')
        with self.assertRaisesRegex(ValueError, 'project_version_mismatch|project_build_mismatch'):
            pt.source_evidence(self.repo, 'v1.7.0', self.sha, 'org.floeagent.ios', '1.6.0', '241')

    def test_source_settings_are_read_from_the_tag_not_the_working_tree(self):
        repo, sha = make_source_repo(Path(self.tmp.name) / 'worktree-src')
        (repo / 'FloeAgent' / 'project.yml').write_text(PROJECT_YML.replace('"241"', '"999"').replace('"1.7.0"', '"9.9.9"'))
        evidence = pt.source_evidence(repo, 'v1.7.0', sha, 'org.floeagent.ios', '1.7.0', '241')
        self.assertTrue(evidence['verified'])

    def test_source_mismatch_blocks_submit_without_writes(self):
        fake = FakeASC()
        with self.assertRaises(ValueError):
            self.submit(fake, source_sha='1' * 40)
        self.assert_no_writes(fake)

    # -- group matching ----------------------------------------------------
    def test_missing_external_group_fails_closed(self):
        for groups in ([internal_group()], [external_group(), external_group()],
                       [external_group(name='some-other-group')],
                       [external_group(isInternalGroup=True), internal_group()]):
            with self.subTest(groups=[g['id'] for g in groups]):
                fake = FakeASC(groups=groups)
                result = self.inspect(fake)
                self.assertFalse(result['ok'])
                with self.assertRaises(ValueError):
                    self.submit(fake)
                self.assert_no_writes(fake)

    # -- submit happy path -------------------------------------------------
    def test_submit_writes_metadata_group_then_creates_one_submission(self):
        fake = FakeASC()
        result = self.submit(fake)
        self.assertTrue(result['submitted'])
        self.assertEqual(result['action'], 'submitted')
        self.assertEqual(result['submissionStates'], ['pending_review'])
        writes = [path for _, path, _ in fake.writes]
        self.assertEqual(writes, [
            '/v1/betaBuildLocalizations',
            '/v1/betaBuildLocalizations',
            '/v1/betaAppLocalizations/bal-en-US',
            '/v1/betaAppLocalizations/bal-zh-Hans',
            '/v1/betaAppReviewDetails/bad-1',
            '/v1/betaGroups/grp-ext/relationships/builds',
            '/v1/betaAppReviewSubmissions',
        ])
        self.assertIn('betaAppReviewDetails.notes', result['writes'])
        note_patch = [body for method, path, body in fake.writes
                      if method == 'PATCH' and path == '/v1/betaAppReviewDetails/bad-1']
        self.assertEqual(len(note_patch), 1)
        self.assertEqual(set(note_patch[0]['data']['attributes']), {'notes'})
        self.assertEqual(note_patch[0]['data']['attributes']['notes'], REVIEW_NOTES_TEXT)
        self.assertEqual(note_patch[0]['data']['id'], 'bad-1')
        self.assertEqual(fake.detail['attributes']['notes'], REVIEW_NOTES_TEXT)
        self.assertIn('build-1', fake.attached)
        self.assertEqual(len(fake.submissions), 1)
        self.assertEqual(fake.submissions[0]['attributes']['betaReviewState'], 'WAITING_FOR_REVIEW')
        self.assertEqual(result['readback']['submission']['states'], ['pending_review'])
        self.assertTrue(result['readback']['ok'])
        rendered = json.dumps(result, sort_keys=True)
        self.assertNotIn('private-review@example.com', rendered)

    def test_submit_second_run_is_duplicate_noop_with_zero_writes(self):
        fake = FakeASC()
        first = self.submit(fake)
        self.assertTrue(first['submitted'])
        fake.writes.clear()
        second = self.submit(fake)
        self.assertFalse(second['submitted'])
        self.assertEqual(second['action'], 'duplicate_noop')
        self.assertEqual(second['writes'], [])
        self.assertEqual(fake.writes, [])
        self.assertEqual(len(fake.submissions), 1)

    def test_submit_existing_in_review_is_reported_not_posted(self):
        fake = FakeASC(submissions=[{'type': 'betaAppReviewSubmissions', 'id': 'sub-old',
                                     'attributes': {'betaReviewState': 'IN_REVIEW'}}])
        result = self.submit(fake)
        self.assertEqual(result['action'], 'duplicate_noop')
        self.assertFalse(result['submitted'])
        self.assert_no_writes(fake)

    # -- rejection recovery ------------------------------------------------
    def test_rejected_submission_reported_by_default_and_recovered_only_with_flag(self):
        fake = FakeASC(submissions=[{'type': 'betaAppReviewSubmissions', 'id': 'sub-old',
                                     'attributes': {'betaReviewState': 'REJECTED'}}])
        result = self.submit(fake)
        self.assertEqual(result['action'], 'rejected_reported')
        self.assertFalse(result['submitted'])
        self.assert_no_writes(fake)
        recovered = self.submit(fake, allow_resubmit_rejected=True)
        self.assertTrue(recovered['submitted'])
        self.assertEqual(recovered['action'], 'submitted')
        self.assertEqual(len(fake.submissions), 2)
        self.assertIn('/v1/betaAppReviewSubmissions', [path for _, path, _ in fake.writes])

    def test_readback_after_post_must_stay_pending(self):
        fake = FakeASC(post_state='REJECTED')
        with self.assertRaises(RuntimeError):
            self.submit(fake)
        self.assertIn('/v1/betaAppReviewSubmissions', [path for _, path, _ in fake.writes])

    def test_multiple_active_submissions_fail_closed(self):
        fake = FakeASC(submissions=[
            {'type': 'betaAppReviewSubmissions', 'id': 'sub-a', 'attributes': {'betaReviewState': 'IN_REVIEW'}},
            {'type': 'betaAppReviewSubmissions', 'id': 'sub-b', 'attributes': {'betaReviewState': 'WAITING_FOR_REVIEW'}},
        ])
        result = self.inspect(fake)
        self.assertFalse(result['ok'])
        self.assertIn('multiple active betaAppReviewSubmissions exist for this build', result['issues'])
        with self.assertRaises(ValueError):
            self.submit(fake)
        self.assert_no_writes(fake)

    def test_unknown_submission_state_blocks_submit_without_writes(self):
        fake = FakeASC(submissions=[
            {'type': 'betaAppReviewSubmissions', 'id': 'sub-a', 'attributes': {'betaReviewState': 'MYSTERY'}},
        ])
        with self.assertRaisesRegex(ValueError, 'unrecognized existing betaAppReviewSubmission state'):
            self.submit(fake)
        self.assert_no_writes(fake)

    def test_artifact_binding_is_recorded_but_never_faked(self):
        fake = FakeASC()
        recorded = self.inspect(fake, artifact_sha256='a' * 64, artifact_source_sha=self.sha)
        self.assertTrue(recorded['artifact']['provided'])
        self.assertFalse(recorded['artifact']['bytesVerified'])
        self.assertTrue(recorded['artifact']['dispatchMetadataOnly'])
        self.assertIn('dispatch metadata only', recorded['artifact']['note'])
        self.assertEqual(recorded['artifact']['sourceSha'], self.sha)
        with self.assertRaises(ValueError):
            self.submit(fake, artifact_sha256='a' * 64, artifact_source_sha='b' * 40)
        self.assert_no_writes(fake)

    # -- write readback ----------------------------------------------------
    def test_notes_readback_mismatch_stops_before_group_and_submission(self):
        fake = FakeASC(apply_writes=False)
        with self.assertRaisesRegex(RuntimeError, 'readback'):
            self.submit(fake)
        paths = [path for _, path, _ in fake.writes]
        self.assertNotIn('/v1/betaGroups/grp-ext/relationships/builds', paths)
        self.assertNotIn('/v1/betaAppReviewSubmissions', paths)

    def test_missing_description_locale_fails_before_writes(self):
        fake = FakeASC(beta_app_locs=[beta_app_localization('en-US')])
        result = self.inspect(fake)
        self.assertFalse(result['ok'])
        self.assertIn('missing betaAppLocalization for zh-Hans', result['issues'])
        self.assertIn('zh-Hans', result['descriptions']['missingLocalizations'])
        with self.assertRaises(ValueError):
            self.submit(fake)
        self.assert_no_writes(fake)

    # -- description repair gating ----------------------------------------
    def test_empty_description_covered_by_input_is_reported_fixable(self):
        fake = FakeASC(beta_app_locs=[beta_app_localization('en-US', description=None),
                                      beta_app_localization('zh-Hans')])
        result = self.inspect(fake)
        self.assertTrue(result['ok'], result['issues'])
        self.assertEqual(result['descriptions']['fixableEmptyDescriptionLocales'], ['en-US'])
        self.assertNotIn('betaAppLocalizations description is empty for: en-US', result['issues'])
        # The explicit submit repairs exactly that locale and reads it back.
        submitted = self.submit(fake)
        self.assertTrue(submitted['submitted'])
        patched = [path for _, path, _ in fake.writes if path.startswith('/v1/betaAppLocalizations/')]
        self.assertIn('/v1/betaAppLocalizations/bal-en-US', patched)
        by_locale = {item['attributes']['locale']: item['attributes']['description']
                     for item in fake.beta_app_locs}
        self.assertEqual(by_locale['en-US'], 'Prepared English beta description.')

    def test_empty_description_for_uncovered_locale_still_blocks(self):
        fake = FakeASC(beta_app_locs=[beta_app_localization('en-US'),
                                      beta_app_localization('zh-Hans'),
                                      beta_app_localization('fr-FR', description=None)])
        result = self.inspect(fake)
        self.assertFalse(result['ok'])
        self.assertIn('betaAppLocalizations description is empty for: fr-FR', result['issues'])
        self.assertEqual(result['descriptions']['fixableEmptyDescriptionLocales'], [])
        with self.assertRaises(ValueError):
            self.submit(fake)
        self.assert_no_writes(fake)

    def test_description_write_checks_all_locales_exist_before_patching(self):
        fake = FakeASC(beta_app_locs=[beta_app_localization('en-US', description=None)])
        with self.assertRaisesRegex(ValueError, 'must already exist'):
            pt.write_descriptions(
                {'app': {'id': 'app-1'}},
                {'en-US': 'new en', 'zh-Hans': 'new zh'}, call=fake.call)
        patched = [path for _, path, _ in fake.writes if path.startswith('/v1/betaAppLocalizations/')]
        self.assertEqual(patched, [])

    # -- review-notes closure ---------------------------------------------
    def test_inspect_compares_prepared_review_notes_without_echoing_text(self):
        fake = FakeASC()
        result = self.inspect(fake, review_notes_path=self.review_notes)
        self.assertTrue(result['ok'], result['issues'])
        self.assertTrue(result['reviewNotes']['provided'])
        self.assertTrue(result['reviewNotes']['pendingWrite'])
        self.assertTrue(result['reviewNotes']['currentNotesPresent'])
        self.assertFalse(result['reviewNotes']['currentNotesMatchPrepared'])
        self.assertEqual(result['reviewNotes']['characters'], len(REVIEW_NOTES_TEXT))
        rendered = json.dumps(result, sort_keys=True)
        self.assertNotIn('private review notes body', rendered)
        self.assertNotIn(REVIEW_NOTES_TEXT, rendered)
        self.assertNotIn('context', result)

    def test_inspect_reports_matching_review_notes_as_no_pending_write(self):
        fake = FakeASC(detail=review_detail(notes=REVIEW_NOTES_TEXT))
        result = self.inspect(fake, review_notes_path=self.review_notes)
        self.assertTrue(result['ok'], result['issues'])
        self.assertFalse(result['reviewNotes']['pendingWrite'])
        self.assertTrue(result['reviewNotes']['currentNotesMatchPrepared'])

    def test_submit_requires_a_final_review_notes_file(self):
        fake = FakeASC()
        with self.assertRaisesRegex(ValueError, 'review-notes'):
            self.submit(fake, review_notes_path=None)
        self.assert_no_writes(fake)

    def test_submit_patches_only_the_existing_review_detail_notes(self):
        fake = FakeASC()
        result = self.submit(fake)
        self.assertTrue(result['submitted'])
        self.assertEqual(fake.detail['attributes']['notes'], REVIEW_NOTES_TEXT)
        self.assertEqual(fake.detail['attributes']['contactEmail'], 'private-review@example.com')
        patches = [(path, body) for method, path, body in fake.writes
                   if method == 'PATCH' and path.startswith('/v1/betaAppReviewDetails/')]
        self.assertEqual([path for path, _ in patches], ['/v1/betaAppReviewDetails/bad-1'])
        self.assertEqual(set(patches[0][1]['data']['attributes']), {'notes'})
        self.assertEqual(patches[0][1]['data']['type'], 'betaAppReviewDetails')
        self.assertEqual(patches[0][1]['data']['id'], 'bad-1')

    def test_invalid_review_detail_id_blocks_before_any_write(self):
        detail = review_detail()
        detail['id'] = 'bad id!'
        fake = FakeASC(detail=detail)
        result = self.inspect(fake, review_notes_path=self.review_notes)
        self.assertFalse(result['ok'])
        self.assertTrue(any('id is missing or invalid' in issue for issue in result['issues']))
        with self.assertRaises(ValueError):
            self.submit(fake)
        self.assert_no_writes(fake)

    def test_review_notes_patch_uses_the_existing_detail_id_not_a_guess(self):
        detail = review_detail()
        detail['id'] = 'bad-42'
        fake = FakeASC(detail=detail)
        result = self.submit(fake)
        self.assertTrue(result['submitted'])
        patches = [path for method, path, _ in fake.writes
                   if path.startswith('/v1/betaAppReviewDetails/')]
        self.assertEqual(patches, ['/v1/betaAppReviewDetails/bad-42'])

    def test_write_review_notes_refuses_missing_or_absent_detail(self):
        fake = FakeASC()
        with self.assertRaisesRegex(ValueError, 'id is missing'):
            pt.write_review_notes({'reviewDetailId': '', 'reviewDetail': {'present': True},
                                   'app': {'id': 'app-1'}}, 'final text', call=fake.call)
        with self.assertRaisesRegex(ValueError, 'never creates'):
            pt.write_review_notes({'reviewDetailId': 'bad-1', 'reviewDetail': {'present': False},
                                   'app': {'id': 'app-1'}}, 'final text', call=fake.call)
        self.assertEqual(fake.writes, [])

    def test_review_notes_readback_mismatch_blocks_before_group_and_submission(self):
        fake = FakeASC(apply_review_notes_write=False)
        with self.assertRaisesRegex(RuntimeError, 'byte-for-byte'):
            self.submit(fake)
        paths = [path for _, path, _ in fake.writes]
        self.assertIn('/v1/betaAppReviewDetails/bad-1', paths)
        self.assertNotIn('/v1/betaGroups/grp-ext/relationships/builds', paths)
        self.assertNotIn('/v1/betaAppReviewSubmissions', paths)

    def test_missing_review_notes_is_fixable_by_valid_input(self):
        fake = FakeASC(detail=review_detail(notes=None))
        before = self.inspect(fake, review_notes_path=self.review_notes)
        self.assertTrue(before['ok'], before['issues'])
        self.assertFalse(before['reviewNotes']['currentNotesPresent'])
        self.assertTrue(before['reviewNotes']['pendingWrite'])
        submitted = self.submit(fake)
        self.assertTrue(submitted['submitted'])
        self.assertEqual(fake.detail['attributes']['notes'], REVIEW_NOTES_TEXT)

    def test_missing_contact_blocks_valid_review_notes_with_zero_writes(self):
        fake = FakeASC(detail=review_detail(contactEmail=None, notes=None))
        result = self.inspect(fake, review_notes_path=self.review_notes)
        self.assertFalse(result['ok'])
        self.assertIn('betaAppReviewDetail is missing required contact field: contactEmail', result['issues'])
        with self.assertRaises(ValueError):
            self.submit(fake)
        self.assert_no_writes(fake)

    def test_missing_review_detail_is_never_created(self):
        fake = FakeASC(fail_review_detail_status=404)
        result = self.inspect(fake, review_notes_path=self.review_notes)
        self.assertFalse(result['ok'])
        self.assertIn('betaAppReviewDetail is missing', ' '.join(result['issues']))
        with self.assertRaises(ValueError):
            self.submit(fake)
        self.assert_no_writes(fake)

    def test_existing_matching_review_notes_are_not_patched(self):
        fake = FakeASC(detail=review_detail(notes=REVIEW_NOTES_TEXT))
        result = self.submit(fake)
        self.assertTrue(result['submitted'])
        self.assertNotIn('betaAppReviewDetails.notes', result['writes'])
        self.assertEqual([path for _, path, _ in fake.writes
                          if path.startswith('/v1/betaAppReviewDetails/')], [])

    def test_draft_and_placeholder_review_notes_are_rejected_before_any_call(self):
        for text in (
            'Status: draft, not submitted.\nFloe Agent review guidance.',
            'Floe Agent review guidance.\nSubmitted: [FROZEN VERSION / BUILD].',
            'Floe Agent review guidance.\nVersion: [PENDING VERIFICATION].',
            'Floe Agent review guidance.\nNote: placeholder text here.',
            '草稿：Floe Agent 审核说明。',
            '状态：尚未提交。Floe Agent 审核说明。',
        ):
            with self.subTest(text=text[:36]):
                path = Path(self.tmp.name) / 'bad-notes.txt'
                path.write_text(text)
                with self.assertRaises(ValueError):
                    pt.load_review_notes(path)
        fake = FakeASC()
        with self.assertRaises(ValueError):
            self.inspect(fake, review_notes_path=self.draft_review_notes)
        self.assertEqual(fake.calls, [])
        with self.assertRaises(ValueError):
            self.submit(fake, review_notes_path=self.draft_review_notes)
        self.assertEqual(fake.calls, [])

    def test_review_notes_length_and_empty_validation(self):
        too_long = Path(self.tmp.name) / 'too-long-notes.txt'
        too_long.write_text('x' * 4001)
        with self.assertRaisesRegex(ValueError, '4000'):
            pt.load_review_notes(too_long)
        maximum = Path(self.tmp.name) / 'max-notes.txt'
        maximum.write_text('y' * 4000)
        self.assertEqual(len(pt.load_review_notes(maximum)), 4000)
        empty = Path(self.tmp.name) / 'empty-notes.txt'
        empty.write_text('   \n')
        with self.assertRaisesRegex(ValueError, 'empty'):
            pt.load_review_notes(empty)
        bad_utf8 = Path(self.tmp.name) / 'bad-utf8-notes.txt'
        bad_utf8.write_bytes(b'\xff\xfe\x00')
        with self.assertRaisesRegex(ValueError, 'UTF-8'):
            pt.load_review_notes(bad_utf8)

    # -- public link default off / real URL readback -----------------------
    def test_public_link_is_off_by_default_and_explicit_when_requested(self):
        fake = FakeASC()
        self.inspect(fake)
        self.assertNotIn('/v1/betaGroups/grp-ext', [path for _, path, _ in fake.writes])
        self.submit(fake)
        self.assertNotIn('/v1/betaGroups/grp-ext', [path for _, path, _ in fake.writes])
        self.assertFalse(fake.groups[0]['attributes']['publicLinkEnabled'])
        enabled = self.submit(FakeASC(), enable_public_link_requested=True)
        self.assertTrue(enabled['publicLink']['publicLinkEnabled'])
        self.assertTrue(enabled['publicLink']['changed'])
        self.assertEqual(enabled['publicLink']['publicLink'],
                         'https://testflight.apple.com/join/abc123')
        self.assertEqual(enabled['publicLink']['publicLinkSource'], 'publicLink')

    def test_submit_public_link_readback_derives_url_from_id_when_api_has_no_url(self):
        fake = FakeASC(patch_sets_public_link=False)
        result = self.submit(fake, enable_public_link_requested=True)
        self.assertEqual(result['publicLink']['publicLink'],
                         'https://testflight.apple.com/join/abc123')
        self.assertEqual(result['publicLink']['publicLinkSource'], 'publicLinkId')

    def test_enable_public_link_requires_real_url_on_readback(self):
        fake = FakeASC(groups=[external_group(publicLinkEnabled=True, publicLink=None,
                                              publicLinkId=None), internal_group()])
        context = {'externalGroup': fake.groups[0]}
        with self.assertRaises(RuntimeError):
            pt.enable_public_link(context, call=fake.call)
        self.assertEqual([path for _, path, _ in fake.writes if path == '/v1/betaGroups/grp-ext'], [])

    def test_inspect_requests_public_link_fields_and_reports_real_url(self):
        url = 'https://testflight.apple.com/join/realabc123'
        fake = FakeASC(groups=[external_group(publicLinkEnabled=True, publicLink=url,
                                              publicLinkId='realabc123'), internal_group()])
        result = self.inspect(fake)
        self.assertEqual(result['externalGroup']['publicLink'], url)
        self.assertEqual(result['externalGroup']['publicLinkSource'], 'publicLink')
        group_reads = [path for method, path, _ in fake.calls
                       if method == 'GET' and path.startswith('/v1/betaGroups?')]
        self.assertTrue(group_reads)
        fields = urllib.parse.parse_qs(urllib.parse.urlparse(group_reads[0]).query)['fields[betaGroups]'][0]
        self.assertIn('publicLinkId', fields)
        self.assertIn('publicLink', fields)

    def test_enabled_public_link_derives_url_from_id_when_link_missing(self):
        fake = FakeASC(groups=[external_group(publicLinkEnabled=True, publicLink=None,
                                              publicLinkId='abc123'), internal_group()])
        result = self.inspect(fake)
        self.assertTrue(result['ok'], result['issues'])
        self.assertEqual(result['externalGroup']['publicLink'],
                         'https://testflight.apple.com/join/abc123')
        self.assertEqual(result['externalGroup']['publicLinkSource'], 'publicLinkId')

    def test_already_enabled_public_link_is_reported_without_patch(self):
        url = 'https://testflight.apple.com/join/realabc123'
        fake = FakeASC(groups=[external_group(publicLinkEnabled=True, publicLink=url,
                                              publicLinkId='realabc123'), internal_group()])
        result = self.submit(fake, enable_public_link_requested=True)
        self.assertFalse(result['publicLink']['changed'])
        self.assertEqual(result['publicLink']['publicLink'], url)
        self.assertEqual([path for _, path, _ in fake.writes if path == '/v1/betaGroups/grp-ext'], [])
        self.assertNotIn('betaGroups.publicLinkEnabled', result['writes'])

    def test_enabled_public_link_without_url_fails_closed(self):
        fake = FakeASC(groups=[external_group(publicLinkEnabled=True, publicLink=None,
                                              publicLinkId=None), internal_group()])
        result = self.inspect(fake)
        self.assertFalse(result['ok'])
        self.assertIsNone(result['externalGroup']['publicLink'])
        self.assertTrue(any('public link' in issue for issue in result['issues']))
        self.assertNotIn('"publicLink": "enabled"', json.dumps(result))
        with self.assertRaises(ValueError):
            self.submit(fake)
        self.assert_no_writes(fake)

    def test_cli_requires_confirmation_and_rejects_public_link_on_inspect(self):
        base = [
            '--version', '1.7.0', '--build', '241', '--tag', 'v1.7.0', '--source-sha', self.sha,
            '--repo-root', str(self.repo),
        ]
        self.assertEqual(pt.main(['--operation', 'submit'] + base), 2)
        self.assertEqual(pt.main(['--operation', 'inspect', '--enable-public-link'] + base), 2)
        self.assertEqual(pt.main(['--operation', 'inspect', '--enable-public-link', '--confirm-submit'] + base), 2)

    # -- API error privacy / pagination ------------------------------------
    def test_api_error_keeps_code_and_pointer_without_raw_text(self):
        secret = 'confidential-reviewer@example.com'
        payload = json.dumps({'errors': [{
            'status': '409', 'code': 'STATE_ERROR', 'title': 'Invalid ' + secret,
            'detail': 'raw response mentions ' + secret,
            'source': {'pointer': '/data/attributes/notes'},
        }]}).encode()
        error = urllib.error.HTTPError(
            'https://api.appstoreconnect.apple.com/v1/betaAppReviewSubmissions', 409, 'Conflict', {}, io.BytesIO(payload))
        original = pt.urllib.request.urlopen
        pt.urllib.request.urlopen = lambda *args, **kwargs: (_ for _ in ()).throw(error)
        try:
            with mock.patch.dict(os.environ, {'ASC_TOKEN': 'test-token'}):
                with self.assertRaises(pt.ApiError) as caught:
                    pt.api('POST', '/v1/betaAppReviewSubmissions')
        finally:
            pt.urllib.request.urlopen = original
        message = str(caught.exception)
        self.assertIn('HTTP 409', message)
        self.assertIn('STATE_ERROR', message)
        self.assertIn('/data/attributes/notes', message)
        self.assertNotIn(secret, message)
        self.assertNotIn('raw response', message)

    def test_pagination_walks_pages_and_rejects_foreign_host(self):
        pages = {
            '/v1/betaGroups?page=1': {'data': [{'id': '1'}], 'links': {'next': pt.BASE + '/v1/betaGroups?page=2'}},
            '/v1/betaGroups?page=2': {'data': [{'id': '2'}], 'links': {}},
        }
        self.assertEqual(pt.rows('/v1/betaGroups?page=1', lambda method, path: pages[path]), [{'id': '1'}, {'id': '2'}])
        with self.assertRaises(ValueError):
            pt.rows('/v1/betaGroups', lambda *args: {'data': [], 'links': {'next': 'https://evil.example/v1/betaGroups'}})

    def test_pagination_repeated_or_cyclic_links_fail_closed(self):
        def self_repeating(method, path):
            return {'data': [], 'links': {'next': pt.BASE + path}}
        with self.assertRaisesRegex(ValueError, 'pagination loop'):
            pt.rows('/v1/betaGroups?page=1', self_repeating)
        cycle = {
            '/v1/betaGroups?page=1': {'data': [], 'links': {'next': pt.BASE + '/v1/betaGroups?page=2'}},
            '/v1/betaGroups?page=2': {'data': [], 'links': {'next': pt.BASE + '/v1/betaGroups?page=1'}},
        }
        with self.assertRaisesRegex(ValueError, 'pagination loop'):
            pt.rows('/v1/betaGroups?page=1', lambda method, path: cycle[path])

    # -- prepared input validation ----------------------------------------
    def test_localization_validation(self):
        for value in ({'en-US': 'ok'}, {'en-US': 'ok', 'zh-Hans': '  '},
                      {'en-US': 'x' * 4001, 'zh-Hans': 'ok'}, ['not', 'a', 'map']):
            with self.subTest(value=str(value)[:40]):
                path = Path(self.tmp.name) / 'bad.json'
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    pt.load_localizations(path)

    def test_duplicate_locale_keys_in_json_fail_closed(self):
        path = Path(self.tmp.name) / 'duplicate.json'
        path.write_text('{"en-US": "first", "en-US": "second", "zh-Hans": "ok"}')
        with self.assertRaisesRegex(ValueError, 'duplicate locale key'):
            pt.load_localizations(path)

    def test_duplicate_beta_app_localizations_fail_closed(self):
        duplicates = [beta_app_localization('en-US', description='first'),
                      beta_app_localization('en-US', description='second'),
                      beta_app_localization('zh-Hans')]
        with self.assertRaisesRegex(ValueError, 'duplicate locale'):
            pt.beta_app_localization_summary(duplicates)
        fake = FakeASC(beta_app_locs=duplicates)
        result = self.inspect(fake)
        self.assertFalse(result['ok'])
        self.assertTrue(any('duplicate locale' in issue for issue in result['issues']))
        with self.assertRaises(ValueError):
            self.submit(fake)
        self.assert_no_writes(fake)

    def test_duplicate_build_localizations_fail_closed(self):
        duplicates = [
            {'type': 'betaBuildLocalizations', 'id': 'loc-a',
             'attributes': {'locale': 'en-US', 'whatsNew': 'first'}},
            {'type': 'betaBuildLocalizations', 'id': 'loc-b',
             'attributes': {'locale': 'en-US', 'whatsNew': 'second'}},
        ]
        with self.assertRaisesRegex(ValueError, 'duplicate locale'):
            pt.localization_map(duplicates, 'betaBuildLocalizations')
        fake = FakeASC(build_locs=duplicates)
        result = self.inspect(fake)
        self.assertFalse(result['ok'])
        self.assertTrue(any('duplicate locale' in issue for issue in result['issues']))
        with self.assertRaises(ValueError):
            self.submit(fake)
        self.assert_no_writes(fake)

    # -- retained release materials ----------------------------------------
    def test_build241_materials_are_valid_helper_inputs(self):
        materials = REPO / 'docs' / 'public-beta' / 'build241'
        for name in ('whats-new.json', 'beta-description.json', 'unverified-fields.json'):
            self.assertTrue((materials / name).is_file(), name)
        notes = pt.load_localizations(materials / 'whats-new.json')
        descriptions = pt.load_localizations(materials / 'beta-description.json')
        self.assertEqual(set(notes), {'en-US', 'zh-Hans'})
        self.assertEqual(set(descriptions), {'en-US', 'zh-Hans'})
        unverified = json.loads((materials / 'unverified-fields.json').read_text())
        self.assertFalse(unverified['nothingDispatchedOrSubmitted'])
        self.assertRegex(unverified['candidate']['sourceCommit'], r'^[0-9a-f]{40}$')
        self.assertEqual(unverified['verifiedFacts']['externalReview']['submissionState'],
                         'pending_review')
        for name in ('review-notes.en-US.md', 'review-notes.zh-Hans.md', 'README.md'):
            self.assertTrue((materials / name).is_file(), name)

    def test_build243_external_review_materials_are_final(self):
        materials = REPO / 'docs' / 'public-beta' / 'build243'
        self.assertEqual(set(pt.load_localizations(materials / 'whats-new.json')),
                         {'en-US', 'zh-Hans'})
        self.assertEqual(set(pt.load_localizations(materials / 'beta-description.json')),
                         {'en-US', 'zh-Hans'})
        self.assertIn('Build 243', pt.load_review_notes(materials / 'review-notes.en-US.md'))

    def test_build241_review_notes_are_marked_draft_or_valid_final_text(self):
        # Retained notes must either be clearly marked as drafts or pass the
        # same final-text validation as new submissions.
        materials = REPO / 'docs' / 'public-beta' / 'build241'
        combined = ''
        for name in ('review-notes.en-US.md', 'review-notes.zh-Hans.md'):
            path = materials / name
            text = path.read_text()
            combined += text.lower()
            marked_draft = ('draft' in text.lower() or '草稿' in text
                            or 'not submitted' in text.lower() or '尚未提交' in text)
            if marked_draft:
                with self.assertRaises(ValueError):
                    pt.load_review_notes(path)
            else:
                self.assertTrue(pt.load_review_notes(path))
        for banned in ('single-object', 'producer/consumer', 'producer-consumer',
                       'old pin', 'qualification', 'vm efficiency'):
            self.assertNotIn(banned, combined)

    # -- workflow wiring ---------------------------------------------------
    def test_workflow_is_fail_closed_and_wired_to_the_helper(self):
        self.assertTrue(WORKFLOW.is_file(), WORKFLOW)
        workflow = yaml.safe_load(WORKFLOW.read_text())
        triggers = workflow.get('on', workflow.get(True))
        inputs = triggers['workflow_dispatch']['inputs']
        self.assertEqual(inputs['operation']['default'], 'inspect')
        self.assertEqual(inputs['operation']['options'], ['inspect', 'submit'])
        self.assertEqual(inputs['enable_public_link']['default'], False)
        self.assertEqual(inputs['allow_resubmit_rejected']['default'], False)
        self.assertNotIn('default', inputs['notes_path'])
        self.assertEqual(inputs['description_path']['default'], '')
        # review_notes_path defaults to a safe empty value: submit must supply
        # a final non-draft file explicitly, and a default inspect stays valid.
        self.assertEqual(inputs['review_notes_path']['default'], '')
        text = WORKFLOW.read_text()
        self.assertIn('FloeAgent/scripts/public_testflight.py', text)
        self.assertIn('FloeAgent/scripts/generate_asc_jwt.py', text)
        self.assertIn('::add-mask::', text)
        self.assertIn('fetch-depth: 0', text)
        self.assertIn('--confirm-submit', text)
        self.assertIn('--review-notes', text)
        self.assertIn('review_notes_path is required for submit', text)
        self.assertIn('submit-external-review', text)
        self.assertNotIn('workflow_call', text)
        helper = MODULE_PATH.read_text()
        self.assertIn("parser.add_argument('--operation', choices=('inspect', 'submit'), default='inspect'", helper)
        for flag in ('--confirm-submit', '--enable-public-link', '--allow-resubmit-rejected', '--review-notes'):
            self.assertIn(flag, helper)

    # -- explicit demoAccountRequired control ------------------------------
    def test_inspect_demo_required_false_reports_pending_write_without_writing(self):
        fake = FakeASC(detail=review_detail(demoAccountRequired=None))
        result = self.inspect(fake, review_notes_path=self.review_notes,
                              demo_account_required=False)
        self.assertTrue(result['ok'], result['issues'])
        report = result['demoAccountRequirement']
        self.assertTrue(report['provided'])
        self.assertIs(report['expected'], False)
        self.assertIsNone(report['actual'])
        self.assertTrue(report['pendingWrite'])
        self.assert_no_writes(fake)

    def test_submit_demo_required_false_patches_only_the_boolean(self):
        fake = FakeASC(detail=review_detail(demoAccountRequired=None, demoAccountName=None,
                                            demoAccountPassword=None))
        result = self.submit(fake, demo_account_required=False)
        self.assertTrue(result['submitted'], result)
        demo_patches = [body for method, path, body in fake.writes
                        if method == 'PATCH' and path.startswith('/v1/betaAppReviewDetails/')
                        and 'demoAccountRequired' in body['data']['attributes']]
        self.assertEqual(len(demo_patches), 1)
        self.assertEqual(set(demo_patches[0]['data']['attributes']), {'demoAccountRequired'})
        self.assertIs(demo_patches[0]['data']['attributes']['demoAccountRequired'], False)
        self.assertIs(fake.detail['attributes']['demoAccountRequired'], False)
        self.assertEqual(fake.detail['attributes']['contactEmail'], 'private-review@example.com')
        self.assertIn('betaAppReviewDetails.demoAccountRequired', result['writes'])
        self.assertFalse(result['readback']['demoAccountRequirement']['pendingWrite'])
        rendered = json.dumps(result, sort_keys=True)
        self.assertNotIn('private-review@example.com', rendered)

    def test_submit_demo_required_false_is_noop_when_already_false(self):
        fake = FakeASC()
        result = self.submit(fake, demo_account_required=False)
        self.assertTrue(result['submitted'])
        self.assertNotIn('betaAppReviewDetails.demoAccountRequired', result['writes'])
        demo_attributes = [body['data']['attributes'] for method, path, body in fake.writes
                           if method == 'PATCH' and path.startswith('/v1/betaAppReviewDetails/')]
        self.assertTrue(all('demoAccountRequired' not in attributes for attributes in demo_attributes))

    def test_demo_required_true_requires_existing_real_credentials(self):
        fake = FakeASC(detail=review_detail(demoAccountRequired=None))
        result = self.inspect(fake, review_notes_path=self.review_notes, demo_account_required=True)
        self.assertFalse(result['ok'])
        self.assertTrue(any('explicitly requested true' in issue for issue in result['issues']))
        with self.assertRaises(ValueError):
            self.submit(fake, demo_account_required=True)
        self.assert_no_writes(fake)

    def test_submit_demo_required_true_uses_existing_credentials_without_printing_them(self):
        fake = FakeASC(detail=review_detail(demoAccountRequired=None, demoAccountName='review-user',
                                            demoAccountPassword='demo-secret'))
        result = self.submit(fake, demo_account_required=True)
        self.assertTrue(result['submitted'], result)
        demo_patches = [body for method, path, body in fake.writes
                        if method == 'PATCH' and path.startswith('/v1/betaAppReviewDetails/')
                        and 'demoAccountRequired' in body['data']['attributes']]
        self.assertEqual(len(demo_patches), 1)
        self.assertEqual(set(demo_patches[0]['data']['attributes']), {'demoAccountRequired'})
        self.assertIs(demo_patches[0]['data']['attributes']['demoAccountRequired'], True)
        self.assertEqual(fake.detail['attributes']['demoAccountName'], 'review-user')
        self.assertEqual(fake.detail['attributes']['demoAccountPassword'], 'demo-secret')
        rendered = json.dumps(result, sort_keys=True)
        self.assertNotIn('review-user', rendered)
        self.assertNotIn('demo-secret', rendered)

    def test_demo_required_readback_mismatch_blocks_before_group_and_submission(self):
        fake = FakeASC(detail=review_detail(demoAccountRequired=None),
                       apply_demo_required_write=False)
        with self.assertRaisesRegex(RuntimeError, 'demoAccountRequired'):
            self.submit(fake, demo_account_required=False)
        paths = [path for _, path, _ in fake.writes]
        self.assertIn('/v1/betaAppReviewDetails/bad-1', paths)
        self.assertNotIn('/v1/betaGroups/grp-ext/relationships/builds', paths)
        self.assertNotIn('/v1/betaAppReviewSubmissions', paths)

    def test_write_demo_required_refuses_missing_or_absent_detail(self):
        fake = FakeASC()
        with self.assertRaisesRegex(ValueError, 'missing or invalid'):
            pt.write_demo_account_required(
                {'reviewDetailId': '', 'reviewDetail': {'present': True}}, False, call=fake.call)
        with self.assertRaisesRegex(ValueError, 'never creates'):
            pt.write_demo_account_required(
                {'reviewDetailId': 'bad-1', 'reviewDetail': {'present': False}}, False, call=fake.call)
        self.assertEqual(fake.writes, [])

    # -- opt-in creation of a missing localization -------------------------
    def test_inspect_create_missing_reports_creatable_and_donor(self):
        fake = FakeASC(beta_app_locs=[beta_app_localization('en-US')])
        result = self.inspect(fake, create_missing_localizations=True,
                              feedback_email_locale='en-US')
        self.assertTrue(result['ok'], result['issues'])
        self.assertEqual(result['descriptions']['creatableMissingLocales'], ['zh-Hans'])
        self.assertTrue(result['descriptions']['feedbackEmailPresentInDonor'])
        self.assert_no_writes(fake)
        rendered = json.dumps(result, sort_keys=True)
        self.assertNotIn('beta-feedback@example.com', rendered)

    def test_create_missing_requires_explicit_feedback_email_locale(self):
        fake = FakeASC(beta_app_locs=[beta_app_localization('en-US')])
        result = self.inspect(fake, create_missing_localizations=True)
        self.assertFalse(result['ok'])
        self.assertTrue(any('feedback-email locale' in issue for issue in result['issues']))
        with self.assertRaises(ValueError):
            self.submit(fake, create_missing_localizations=True)
        self.assert_no_writes(fake)

    def test_create_missing_donor_without_configured_email_fails_closed(self):
        fake = FakeASC(beta_app_locs=[beta_app_localization('en-US', feedbackEmail=None)])
        result = self.inspect(fake, create_missing_localizations=True,
                              feedback_email_locale='en-US')
        self.assertFalse(result['ok'])
        self.assertTrue(any('has no configured feedbackEmail' in issue for issue in result['issues']))
        with self.assertRaises(ValueError):
            self.submit(fake, create_missing_localizations=True, feedback_email_locale='en-US')
        self.assert_no_writes(fake)

    def test_create_missing_donor_locale_must_exist(self):
        fake = FakeASC(beta_app_locs=[beta_app_localization('en-US')])
        result = self.inspect(fake, create_missing_localizations=True,
                              feedback_email_locale='fr-FR')
        self.assertFalse(result['ok'])
        with self.assertRaises(ValueError):
            self.submit(fake, create_missing_localizations=True, feedback_email_locale='fr-FR')
        self.assert_no_writes(fake)

    def test_create_missing_without_description_input_blocks_before_writes(self):
        fake = FakeASC(beta_app_locs=[beta_app_localization('en-US')])
        with self.assertRaises(ValueError):
            self.submit(fake, create_missing_localizations=True, feedback_email_locale='en-US',
                        description_path=None)
        self.assert_no_writes(fake)

    def test_create_missing_without_prepared_description_fails_closed(self):
        fake = FakeASC(beta_app_locs=[beta_app_localization('en-US')])
        with self.assertRaisesRegex(ValueError, 'prepared description'):
            pt.write_descriptions({'app': {'id': 'app-1'}}, None,
                                  privacy_policy_url='https://example.com/privacy',
                                  create_missing=True, feedback_email_locale='en-US',
                                  call=fake.call)
        self.assertEqual(fake.writes, [])

    def test_submit_create_missing_copies_donor_feedback_email_and_reads_back(self):
        fake = FakeASC(beta_app_locs=[beta_app_localization('en-US',
                                                            feedbackEmail='donor-owner@example.com')])
        result = self.submit(fake, create_missing_localizations=True,
                             feedback_email_locale='en-US')
        self.assertTrue(result['submitted'], result)
        created = [item for item in fake.beta_app_locs if item['attributes']['locale'] == 'zh-Hans']
        self.assertEqual(len(created), 1)
        self.assertEqual(created[0]['attributes']['feedbackEmail'], 'donor-owner@example.com')
        self.assertEqual(created[0]['attributes']['description'], '准备好的中文测试版说明。')
        en_us = next(item for item in fake.beta_app_locs if item['attributes']['locale'] == 'en-US')
        self.assertEqual(en_us['attributes']['feedbackEmail'], 'donor-owner@example.com')
        self.assertEqual(en_us['attributes']['marketingUrl'], 'https://example.com/')
        post = [body for method, path, body in fake.writes if method == 'POST'
                and path == '/v1/betaAppLocalizations']
        self.assertEqual(len(post), 1)
        self.assertEqual(set(post[0]['data']['attributes']),
                         {'locale', 'description', 'feedbackEmail'})
        self.assertEqual(post[0]['data']['relationships']['app']['data']['id'], 'app-1')
        rendered = json.dumps(result, sort_keys=True)
        self.assertNotIn('donor-owner@example.com', rendered)
        self.assertIn('betaAppLocalizations', result['writes'])

    def test_create_missing_uses_explicit_donor_locale(self):
        fake = FakeASC(beta_app_locs=[beta_app_localization('fr-FR', feedbackEmail='canal@example.com'),
                                      beta_app_localization('en-US')])
        result = self.submit(fake, create_missing_localizations=True,
                             feedback_email_locale='fr-FR')
        self.assertTrue(result['submitted'], result)
        created = [item for item in fake.beta_app_locs if item['attributes']['locale'] == 'zh-Hans']
        self.assertEqual(len(created), 1)
        self.assertEqual(created[0]['attributes']['feedbackEmail'], 'canal@example.com')
        rendered = json.dumps(result, sort_keys=True)
        self.assertNotIn('canal@example.com', rendered)

    def test_create_missing_readback_mismatch_blocks_before_group_and_submission(self):
        fake = FakeASC(beta_app_locs=[beta_app_localization('en-US')], apply_create_write=False)
        with self.assertRaisesRegex(RuntimeError, 'readback'):
            self.submit(fake, create_missing_localizations=True, feedback_email_locale='en-US')
        paths = [path for _, path, _ in fake.writes]
        self.assertIn('/v1/betaAppLocalizations', paths)
        self.assertNotIn('/v1/betaGroups/grp-ext/relationships/builds', paths)
        self.assertNotIn('/v1/betaAppReviewSubmissions', paths)

    def test_duplicate_locale_blocks_creation_even_with_opt_in(self):
        duplicates = [beta_app_localization('en-US', description='first'),
                      beta_app_localization('en-US', description='second')]
        fake = FakeASC(beta_app_locs=duplicates)
        result = self.inspect(fake, create_missing_localizations=True,
                              feedback_email_locale='en-US')
        self.assertFalse(result['ok'])
        self.assertTrue(any('duplicate locale' in issue for issue in result['issues']))
        with self.assertRaises(ValueError):
            self.submit(fake, create_missing_localizations=True, feedback_email_locale='en-US')
        self.assert_no_writes(fake)

    # -- caller-confirmed privacy policy URL -------------------------------
    def test_privacy_policy_url_format_validation(self):
        for url in ('https://example.com/privacy', 'https://www.floe-agent.com/privacy/zh',
                    'https://sub.example.co.uk/a?b=1#c'):
            self.assertEqual(pt.validate_https_url(url, 'privacy policy URL'), url)
        for url in ('http://example.com/privacy', 'example.com/privacy', 'https://',
                    'https://user:pass@example.com/privacy', 'https://localhost/privacy',
                    'https://example .com/privacy', 'javascript:alert(1)', '',
                    None, '   https://example.com/privacy '):
            with self.subTest(url=str(url)):
                with self.assertRaises(ValueError):
                    pt.validate_https_url(url, 'privacy policy URL')

    def test_inspect_reports_missing_or_pending_privacy_policy_url(self):
        fake = FakeASC(beta_app_locs=[beta_app_localization('en-US', privacyPolicyUrl=None),
                                      beta_app_localization('zh-Hans', privacyPolicyUrl=None)])
        missing = self.inspect(fake)
        # No URL is supplied: inspect stays GET-only and reports the empty
        # current values truthfully instead of inventing or auto-writing one.
        self.assertTrue(missing['ok'], missing['issues'])
        self.assertFalse(missing['privacyPolicy']['provided'])
        self.assertIsNone(missing['privacyPolicy']['expected'])
        self.assertFalse(missing['privacyPolicy']['pendingWrite'])
        self.assertEqual(missing['privacyPolicy']['current'], {'en-US': None, 'zh-Hans': None})
        self.assertIn('privacyPolicyUrl',
                      missing['betaAppLocalizations']['en-US']['missingFields'])
        pending = self.inspect(fake, privacy_policy_url='https://www.floe-agent.com/privacy')
        self.assertTrue(pending['ok'], pending['issues'])
        self.assertEqual(pending['privacyPolicy']['expected'], 'https://www.floe-agent.com/privacy')
        self.assertTrue(pending['privacyPolicy']['pendingWrite'])
        self.assert_no_writes(fake)

    def test_submit_writes_privacy_policy_url_only_when_provided(self):
        url = 'https://www.floe-agent.com/privacy'
        plain = FakeASC(beta_app_locs=[beta_app_localization('en-US', privacyPolicyUrl=None),
                                       beta_app_localization('zh-Hans')])
        plain_result = self.submit(plain)
        self.assertTrue(plain_result['submitted'])
        plain_patches = [body['data']['attributes'] for method, path, body in plain.writes
                         if method == 'PATCH' and path.startswith('/v1/betaAppLocalizations/')]
        self.assertTrue(plain_patches)
        self.assertTrue(all('privacyPolicyUrl' not in attributes for attributes in plain_patches))
        fake = FakeASC(beta_app_locs=[beta_app_localization('en-US', privacyPolicyUrl=None),
                                      beta_app_localization('zh-Hans', privacyPolicyUrl=None)])
        result = self.submit(fake, privacy_policy_url=url)
        self.assertTrue(result['submitted'], result)
        patch_attributes = [body['data']['attributes'] for method, path, body in fake.writes
                            if method == 'PATCH' and path.startswith('/v1/betaAppLocalizations/')]
        self.assertEqual(len(patch_attributes), 2)
        for attributes in patch_attributes:
            self.assertEqual(set(attributes), {'description', 'privacyPolicyUrl'})
            self.assertEqual(attributes['privacyPolicyUrl'], url)
        by_locale = {item['attributes']['locale']: item['attributes'] for item in fake.beta_app_locs}
        self.assertEqual(by_locale['en-US']['privacyPolicyUrl'], url)
        self.assertEqual(by_locale['zh-Hans']['privacyPolicyUrl'], url)
        self.assertFalse(result['readback']['privacyPolicy']['pendingWrite'])

    def test_submit_metadata_completion_flow_is_explicit_and_read_back(self):
        url = 'https://www.floe-agent.com/privacy'
        fake = FakeASC(detail=review_detail(demoAccountRequired=None),
                       beta_app_locs=[beta_app_localization('en-US', privacyPolicyUrl=None)])
        result = self.submit(fake, demo_account_required=False,
                             create_missing_localizations=True,
                             feedback_email_locale='en-US',
                             privacy_policy_url=url)
        self.assertTrue(result['submitted'], result)
        self.assertIn('betaAppReviewDetails.demoAccountRequired', result['writes'])
        self.assertIn('betaAppLocalizations', result['writes'])
        created = next(item for item in fake.beta_app_locs
                       if item['attributes']['locale'] == 'zh-Hans')
        self.assertEqual(created['attributes']['description'], '准备好的中文测试版说明。')
        self.assertEqual(created['attributes']['feedbackEmail'], 'beta-feedback@example.com')
        self.assertEqual(created['attributes']['privacyPolicyUrl'], url)
        en_us = next(item for item in fake.beta_app_locs if item['attributes']['locale'] == 'en-US')
        self.assertEqual(en_us['attributes']['privacyPolicyUrl'], url)
        self.assertIs(fake.detail['attributes']['demoAccountRequired'], False)
        self.assertFalse(result['readback']['demoAccountRequirement']['pendingWrite'])
        self.assertFalse(result['readback']['privacyPolicy']['pendingWrite'])
        created_entry = result['readback']['betaAppLocalizations']['zh-Hans']
        self.assertTrue(created_entry['descriptionSet'])
        self.assertNotIn('feedbackEmail', created_entry['missingFields'])
        self.assertNotIn('privacyPolicyUrl', created_entry['missingFields'])
        rendered = json.dumps(result, sort_keys=True)
        self.assertNotIn('beta-feedback@example.com', rendered)
        self.assertNotIn('private-review@example.com', rendered)

    def test_privacy_policy_url_readback_mismatch_blocks_before_group_and_submission(self):
        fake = FakeASC(beta_app_locs=[beta_app_localization('en-US', privacyPolicyUrl=None),
                                      beta_app_localization('zh-Hans', privacyPolicyUrl=None)],
                       apply_privacy_write=False)
        with self.assertRaisesRegex(RuntimeError, 'privacyPolicyUrl'):
            self.submit(fake, privacy_policy_url='https://www.floe-agent.com/privacy')
        paths = [path for _, path, _ in fake.writes]
        self.assertNotIn('/v1/betaGroups/grp-ext/relationships/builds', paths)
        self.assertNotIn('/v1/betaAppReviewSubmissions', paths)

    # -- read-only public URL discovery ------------------------------------
    def test_inspect_reports_discovered_urls_and_never_substitutes_them(self):
        privacy = 'https://www.floe-agent.com/privacy'
        support = 'https://www.floe-agent.com/support'
        fake = FakeASC(app_info_locs=[app_info_localization('en-US', privacy),
                                      app_info_localization('zh-Hans', 'http://insecure.example.com/p')],
                       version_locs=[version_localization('en-US', support),
                                     version_localization('zh-Hans', None)])
        result = self.inspect(fake)
        discovered = result['privacyPolicy']['discoveredPublicUrls']
        self.assertTrue(discovered['appInfoLocalizations']['available'])
        self.assertEqual(discovered['appInfoLocalizations']['privacyPolicyUrlByLocale'],
                         {'en-US': privacy, 'zh-Hans': None})
        self.assertEqual(discovered['appStoreVersionLocalizations']['supportUrlByLocale'],
                         {'en-US': [support]})
        self.assert_no_writes(fake)
        submitted = self.submit(fake)
        self.assertTrue(submitted['submitted'])
        written_urls = [body['data']['attributes'].get('privacyPolicyUrl')
                        for method, path, body in fake.writes
                        if method == 'PATCH' and path.startswith('/v1/betaAppLocalizations/')]
        self.assertTrue(written_urls)
        self.assertTrue(all(url is None for url in written_urls))

    def test_discovery_conflicting_values_are_reported_as_unknown(self):
        fake = FakeASC(app_info_locs=[
            app_info_localization('en-US', 'https://example.com/one'),
            app_info_localization('en-US', 'https://example.com/two')])
        result = self.inspect(fake)
        self.assertTrue(result['ok'], result['issues'])
        self.assertIsNone(
            result['privacyPolicy']['discoveredPublicUrls']['appInfoLocalizations']
            ['privacyPolicyUrlByLocale']['en-US'])
        self.assert_no_writes(fake)

    def test_discovery_api_error_is_reported_and_not_blocking(self):
        fake = FakeASC(fail_discovery_status=403)
        result = self.inspect(fake)
        self.assertTrue(result['ok'], result['issues'])
        discovered = result['privacyPolicy']['discoveredPublicUrls']
        self.assertFalse(discovered['appInfoLocalizations']['available'])
        self.assertFalse(discovered['appStoreVersionLocalizations']['available'])
        self.assertIn('HTTP 403', discovered['appInfoLocalizations']['problem'])
        self.assert_no_writes(fake)

    # -- option combination and workflow wiring ----------------------------
    def test_inspect_with_all_metadata_options_is_still_get_only(self):
        url = 'https://www.floe-agent.com/privacy'
        fake = FakeASC(detail=review_detail(demoAccountRequired=None),
                       beta_app_locs=[beta_app_localization('en-US', privacyPolicyUrl=None)])
        result = self.inspect(fake, review_notes_path=self.review_notes,
                              demo_account_required=False,
                              create_missing_localizations=True,
                              feedback_email_locale='en-US',
                              privacy_policy_url=url)
        self.assertTrue(result['ok'], result['issues'])
        self.assertTrue(result['demoAccountRequirement']['pendingWrite'])
        self.assertEqual(result['descriptions']['creatableMissingLocales'], ['zh-Hans'])
        self.assertTrue(result['privacyPolicy']['pendingWrite'])
        self.assert_no_writes(fake)
        self.assertTrue(fake.calls)

    def test_cli_rejects_feedback_email_locale_without_create_missing(self):
        base = [
            '--version', '1.7.0', '--build', '241', '--tag', 'v1.7.0', '--source-sha', self.sha,
            '--repo-root', str(self.repo),
        ]
        self.assertEqual(
            pt.main(['--operation', 'inspect', '--feedback-email-locale', 'en-US'] + base), 2)
        with self.assertRaises(SystemExit):
            pt.main(['--operation', 'inspect', '--demo-account-required', 'yes'] + base)
        self.assertEqual(
            pt.main(['--operation', 'inspect', '--demo-account-required', 'unchanged',
                     '--feedback-email-locale', 'en-US'] + base), 2)

    def test_workflow_new_metadata_inputs_are_default_off_and_wired(self):
        workflow = yaml.safe_load(WORKFLOW.read_text())
        triggers = workflow.get('on', workflow.get(True))
        inputs = triggers['workflow_dispatch']['inputs']
        self.assertEqual(inputs['demo_account_required']['default'], 'unchanged')
        self.assertEqual(inputs['demo_account_required']['options'], ['unchanged', 'false', 'true'])
        self.assertEqual(inputs['create_missing_localizations']['default'], False)
        self.assertEqual(inputs['feedback_email_locale']['default'], '')
        self.assertEqual(inputs['privacy_policy_url']['default'], '')
        text = WORKFLOW.read_text()
        for flag in ('--demo-account-required', '--create-missing-localizations',
                     '--feedback-email-locale', '--privacy-policy-url'):
            self.assertIn(flag, text)
        self.assertIn('feedback-email-locale requires --create-missing-localizations', text)
        helper = MODULE_PATH.read_text()
        for flag in ('--demo-account-required', '--create-missing-localizations',
                     '--feedback-email-locale', '--privacy-policy-url'):
            self.assertIn(flag, helper)


if __name__ == '__main__':
    unittest.main()
