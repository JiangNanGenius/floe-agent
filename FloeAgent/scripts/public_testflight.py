#!/usr/bin/env python3
"""Fail-closed helper for the external/public TestFlight review path.

This is intentionally separate from ``xcode-cloud-control.yml`` +
``prepare_testflight.py``, which only manage the private internal Floe QA
group. This helper never touches that internal path.

Operations:
  inspect (default)  read-only. Prints a sanitized status summary. Never
                     performs a non-GET request.
  submit             explicit, confirmed. Verifies the immutable source tag,
                     build state, review contact/demo facts and the single
                     existing external group before writing the prepared
                     What-to-Test / Beta description and the prepared
                     ``betaAppReviewDetail.notes`` text, attaching the build to
                     that group and creating the ``betaAppReviewSubmissions``
                     record once.

Safety properties:
  * Every candidate/locale/group failure is fail-closed before any write.
  * Only a build whose pre-release relationship says platform ``IOS`` can match
    the candidate; a missing or different platform is rejected.
  * Review notes are a separate prepared text file (``--review-notes``),
    validated at 1..4000 characters with draft markers and unreplaced
    placeholders rejected. The helper only ever PATCHes the ``notes`` attribute
    of the already existing ``betaAppReviewDetails/{id}``; it never creates a
    review detail and never touches contact or demo-account fields. The notes
    readback must be byte-identical before the group attach and review POST.
  * ``demoAccountRequired`` must be confirmed; when true both demo credential
    fields must be set. Only presence booleans are reported, never values.
  * Duplicate localization locales are fatal instead of being silently
    overwritten, and pagination refuses cycles.
  * Existing pending/approved submissions are reported, never re-POSTed.
  * A REJECTED submission requires ``--allow-resubmit-rejected`` to recover.
  * Public-link enablement is a separate explicit option, default off, and it
    only ever targets the already matched existing external group. An enabled
    link is reported only as the real read-back URL (``publicLink`` or a URL
    derived from ``publicLinkId``), never as an ``enabled`` placeholder.
  * Raw API response text is never echoed. Failures keep Apple's status and
    error ``code`` plus an optional field pointer; ``title``/``detail`` (which
    can echo user data) are dropped. Contact values and feedback addresses are
    never printed, only the names of missing fields and public URLs.
  * All list reads paginate; every write is read back and compared.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BASE = 'https://api.appstoreconnect.apple.com'
DEFAULT_BUNDLE = 'org.floeagent.ios'
DEFAULT_GROUP = 'publictest1'
LOCALES = ('en-US', 'zh-Hans')
MAX_TEXT = 4000
# Apple: "Review notes have a maximum of 4,000 characters."
# (BetaAppReviewDetail.Attributes, App Store Connect API; publicdocs evidence in
# Local/Private/build241/public-beta/apple-docs/).
MAX_REVIEW_NOTES = 4000

# Markers that prove a review-notes draft was not replaced by final product
# text. Matching is intentionally conservative: a false positive only refuses a
# file, while a false negative would submit internal draft wording.
_REVIEW_NOTES_DRAFT_MARKERS = (
    ('draft', re.compile(r'\bdraft\b', re.I)),
    ('not submitted', re.compile(r'\bnot\s+submitted\b', re.I)),
    ('do not paste', re.compile(r'\bdo not paste\b', re.I)),
    ('not final', re.compile(r'\bnot\s+final\b', re.I)),
    ('not released', re.compile(r'\bnot\s+released\b', re.I)),
    ('placeholder', re.compile(r'\bplaceholder\b', re.I)),
    ('草稿', re.compile('草稿')),
    ('尚未提交', re.compile('尚未提交')),
    ('不要粘贴', re.compile('不要粘贴')),
    ('待核验', re.compile('待核验')),
    ('待补全', re.compile('待补全')),
    ('尚未发布', re.compile('尚未发布')),
)
_REVIEW_NOTES_PLACEHOLDER_WORDS = (
    'PENDING', 'FROZEN', 'TBD', 'TODO', 'CANDIDATE', 'VERIFY', 'UNRESOLVED',
    'PLACEHOLDER', '待核验', '冻结', '候选', '待定', '待补全',
)
_REVIEW_NOTES_PLACEHOLDER_RE = re.compile(
    r'\[[^\]\n]{0,200}?(?:' + '|'.join(_REVIEW_NOTES_PLACEHOLDER_WORDS) + r')[^\]\n]{0,200}?\]',
    re.I)
_BRACKETED_TOKEN_RE = re.compile(r'\[([^\]\n]*)\]')
_UPPERCASE_BRACKET_TOKEN_RE = re.compile(r'[A-Z]{2,}(?:[ _/:\-]+[A-Z0-9]{2,})+')

TAG_RE = re.compile(r'^v[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9._-]+)?$')
SHA1_RE = re.compile(r'^[0-9a-f]{40}$')
SHA256_RE = re.compile(r'^[0-9a-f]{64}$')
ID_RE = re.compile(r'^[A-Za-z0-9_-]+$')
PUBLIC_LINK_RE = re.compile(r'^https://testflight\.apple\.com/join/[A-Za-z0-9_-]+$')

PENDING_STATES = frozenset(('WAITING_FOR_REVIEW', 'IN_REVIEW'))
AUDIENCE_EXTERNAL = 'APP_STORE_ELIGIBLE'
IOS_PLATFORM = 'IOS'
PUBLIC_LINK_FIELDS = 'name,isInternalGroup,publicLinkEnabled,publicLinkId,publicLink'

REVIEW_DETAIL_FIELDS = (
    'contactFirstName', 'contactLastName', 'contactEmail', 'contactPhone',
    'demoAccountRequired', 'demoAccountName', 'demoAccountPassword', 'notes',
)
BETA_APP_LOCALIZATION_FIELDS = ('description', 'feedbackEmail', 'marketingUrl', 'privacyPolicyUrl')


class ApiError(RuntimeError):
    """Sanitized App Store Connect transport error.

    Only the HTTP status, Apple error ``code`` and an optional JSON:API field
    pointer are retained; ``title``/``detail`` may echo submitted content and
    are deliberately not included.
    """

    def __init__(self, method, path, status, code='UNKNOWN', pointer=None):
        self.method = method
        self.path = path
        self.status = status
        self.code = code
        self.pointer = pointer
        message = f'App Store Connect {method} {path.split("?", 1)[0]} failed with HTTP {status} code={code}'
        if pointer:
            message += f' field={pointer}'
        super().__init__(message)


def api(method, path, body=None):
    if not path.startswith('/v1/'):
        raise ValueError('Unexpected API path')
    token = os.environ.get('ASC_TOKEN', '').strip()
    if not token:
        raise RuntimeError('ASC_TOKEN is not set')
    request = urllib.request.Request(
        BASE + path,
        method=method,
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
        data=None if body is None else json.dumps(body).encode(),
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as error:
        code, pointer = 'UNKNOWN', None
        try:
            payload = json.loads(error.read() or b'{}')
            errors = payload.get('errors') or []
            if errors:
                # Apple machine codes and field pointers are safe; the
                # human-readable title/detail are not echoed on purpose.
                code = str(errors[0].get('code') or 'UNKNOWN')
                pointer = (errors[0].get('source') or {}).get('pointer')
        except (ValueError, TypeError):
            pass
        raise ApiError(method, path, error.code, code, pointer) from None
    except urllib.error.URLError:
        raise ApiError(method, path, 0, 'TRANSPORT') from None


def paged(path, call=api):
    """Follow ASC pagination, refusing redirects and repeated pages.

    A repeated page (or any cycle back to an already visited page) is fatal:
    Apple pagination must be strictly forward, and following a loop forever
    would both hang and produce duplicated data.
    """
    data, included = [], []
    seen = set()
    while path:
        if path in seen:
            raise ValueError('pagination loop detected; refusing to follow a repeated page')
        seen.add(path)
        value = call('GET', path)
        data.extend(value.get('data', []))
        included.extend(value.get('included', []))
        next_url = (value.get('links') or {}).get('next')
        if next_url and not next_url.startswith(BASE + '/v1/'):
            raise ValueError('Unexpected pagination destination')
        path = next_url[len(BASE):] if next_url else None
    return data, included


def rows(path, call=api):
    return paged(path, call)[0]


def query(**values):
    return urllib.parse.urlencode({key: value for key, value in values.items() if value is not None})


# --------------------------------------------------------------------------
# Source / project verification
# --------------------------------------------------------------------------

def git_commit(repo_root, tag):
    if not TAG_RE.match(tag):
        raise ValueError('tag must look like v<major>.<minor>.<patch>')
    result = subprocess.run(
        ['git', '-C', str(repo_root), 'rev-parse', '--verify', tag + '^{commit}'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    if result.returncode != 0:
        raise ValueError('source tag is not present in this checkout')
    return result.stdout.strip()


def git_file(repo_root, ref, path):
    """Read a file at the exact verified ref, never the working tree."""
    result = subprocess.run(
        ['git', '-C', str(repo_root), 'show', f'{ref}:{path}'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    return result.stdout if result.returncode == 0 else None


def parse_project_settings(text):
    settings = {}
    for name in ('MARKETING_VERSION', 'CURRENT_PROJECT_VERSION', 'PRODUCT_BUNDLE_IDENTIFIER'):
        match = re.search(r'^\s*' + name + r':\s*"?([^"\s]+)', text, re.M)
        if not match:
            raise ValueError(f'project.yml is missing {name}')
        settings[name] = match.group(1)
    return settings


def source_evidence(repo_root, tag, source_sha, bundle_id, version, build):
    """Bind the API candidate to an immutable local tag + checkout settings."""
    if not SHA1_RE.match(source_sha or ''):
        raise ValueError('source SHA must be 40 lowercase hex characters')
    problems = []
    commit = git_commit(repo_root, tag)
    if commit != source_sha:
        problems.append('tag_commit_mismatch')
    settings = {}
    text = git_file(repo_root, source_sha, 'FloeAgent/project.yml')
    if text is None:
        problems.append('project_yml_missing_at_source_sha')
    else:
        settings = parse_project_settings(text)
        if settings['PRODUCT_BUNDLE_IDENTIFIER'] != bundle_id:
            problems.append('project_bundle_mismatch')
        if settings['MARKETING_VERSION'] != version:
            problems.append('project_version_mismatch')
        if settings['CURRENT_PROJECT_VERSION'] != build:
            problems.append('project_build_mismatch')
    if problems:
        raise ValueError('source verification failed: ' + ','.join(problems))
    return {
        'tag': tag,
        'tagCommit': commit,
        'sourceSha': source_sha,
        'projectBundleId': settings['PRODUCT_BUNDLE_IDENTIFIER'],
        'projectVersion': settings['MARKETING_VERSION'],
        'projectBuild': settings['CURRENT_PROJECT_VERSION'],
        'verified': True,
    }


def artifact_evidence(artifact_sha256, artifact_source_sha, source_sha):
    if not artifact_sha256 and not artifact_source_sha:
        return {'provided': False, 'bytesVerified': False}
    if artifact_sha256 and not SHA256_RE.match(artifact_sha256):
        raise ValueError('artifact SHA-256 must be 64 lowercase hex characters')
    if artifact_source_sha and not SHA1_RE.match(artifact_source_sha):
        raise ValueError('artifact source SHA must be 40 lowercase hex characters')
    if artifact_source_sha and artifact_source_sha != source_sha:
        raise ValueError('artifact source SHA does not match the frozen source SHA')
    return {
        'provided': True,
        'sha256': artifact_sha256 or None,
        'sourceSha': artifact_source_sha or None,
        'bytesVerified': False,
        'dispatchMetadataOnly': True,
        'note': ('recorded from dispatch metadata only; the helper never downloads or hashes the IPA, '
                 'and tag/project verification does not verify built artifact bytes'),
    }


# --------------------------------------------------------------------------
# Prepared localization inputs
# --------------------------------------------------------------------------

def _unique_object(pairs):
    """``json.loads`` hook that refuses duplicate keys instead of overwriting."""
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('duplicate locale key in localization file: ' + str(key))
        value[key] = item
    return value


def load_localizations(path):
    try:
        value = json.loads(Path(path).read_text(), object_pairs_hook=_unique_object)
    except json.JSONDecodeError as error:
        raise ValueError('localization file is not valid JSON: ' + error.msg) from None
    if not isinstance(value, dict) or set(value) != set(LOCALES):
        raise ValueError('localization file must contain exactly en-US and zh-Hans')
    for locale, text in value.items():
        if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
            raise ValueError(f'{locale} text must be 1..{MAX_TEXT} characters')
    return value


def _review_notes_problems(text):
    """Return draft/placeholder problem labels for prepared review-notes text.

    Labels only: the raw notes text (which may contain unreleased internal
    wording) is never echoed into an issue or report.
    """
    problems = set()
    for label, pattern in _REVIEW_NOTES_DRAFT_MARKERS:
        if pattern.search(text):
            problems.add('draft marker: ' + label)
    if _REVIEW_NOTES_PLACEHOLDER_RE.search(text):
        problems.add('unreplaced placeholder')
    for match in _BRACKETED_TOKEN_RE.finditer(text):
        if _UPPERCASE_BRACKET_TOKEN_RE.search(match.group(1)):
            problems.add('unreplaced placeholder')
    return sorted(problems)


def load_review_notes(path):
    """Load and validate the single prepared Beta App Review notes text.

    The file must be final product text: 1..4000 characters (Apple's documented
    maximum) with no draft banner, no unreplaced bracketed placeholder and no
    other obvious draft marker. Newlines are normalized to LF and the outer
    whitespace is stripped so the value PATCHed can be compared byte-for-byte
    with the readback.
    """
    try:
        raw = Path(path).read_text()
    except (OSError, UnicodeDecodeError):
        raise ValueError('review notes file could not be read as UTF-8 text') from None
    text = raw.replace('\r\n', '\n').replace('\r', '\n').strip()
    if not text:
        raise ValueError('review notes must not be empty')
    if len(text) > MAX_REVIEW_NOTES:
        raise ValueError(f'review notes must be 1..{MAX_REVIEW_NOTES} characters')
    problems = _review_notes_problems(text)
    if problems:
        raise ValueError('review notes are not final text (' + '; '.join(problems)
                         + '); submit only accepts final product review notes')
    return text


def localization_map(items, source):
    """Index API localizations by locale; duplicates/missing locales are fatal.

    Silently letting a later record overwrite an earlier one could hide a
    duplicate that Apple would resolve differently, so every caller that needs
    a locale lookup goes through this fail-closed helper.
    """
    result = {}
    for item in items:
        locale = (item.get('attributes') or {}).get('locale')
        if not locale:
            raise ValueError(source + ' entry is missing its locale')
        if locale in result:
            raise ValueError(source + ' returned duplicate locale ' + str(locale)
                             + '; refusing to guess')
        result[locale] = item
    return result


# --------------------------------------------------------------------------
# Read context (GET only)
# --------------------------------------------------------------------------

def fetch_app(bundle_id, call=api):
    value = call('GET', '/v1/apps?' + query(**{
        'filter[bundleId]': bundle_id, 'limit': '10', 'fields[apps]': 'name,bundleId',
    }))
    apps = [item for item in value.get('data', [])
            if item.get('attributes', {}).get('bundleId') == bundle_id]
    if len(apps) != 1:
        raise ValueError('expected exactly one app for the frozen bundle ID')
    return apps[0]


def fetch_candidate(app_id, bundle_id, version, build, call=api):
    """Find the unique IOS build and fully verify the inclusion relationships.

    The marketing version alone is not enough: another platform can carry the
    same version/build strings. Only a pre-release relationship whose platform
    is explicitly ``IOS`` may match; a missing platform is treated exactly like
    a different one so the result stays fail-closed.
    """
    path = '/v1/builds?' + query(**{
        'filter[app]': app_id, 'filter[version]': build, 'limit': '200', 'sort': '-uploadedDate',
        'fields[builds]': 'version,uploadedDate,processingState,expired,buildAudienceType,preReleaseVersion,app,buildBetaDetail',
        'fields[preReleaseVersions]': 'version,platform',
        'fields[buildBetaDetails]': 'internalBuildState,externalBuildState',
        'fields[apps]': 'name,bundleId',
        'include': 'preReleaseVersion,app,buildBetaDetail',
    })
    builds, included = paged(path, call)
    index = {(item['type'], item['id']): item for item in included}
    matches = []
    rejected_platform = False
    for item in builds:
        attrs = item.get('attributes', {})
        relations = item.get('relationships', {})
        app_ref = (relations.get('app') or {}).get('data') or {}
        release_ref = (relations.get('preReleaseVersion') or {}).get('data') or {}
        if attrs.get('version') != build:
            continue
        if app_ref.get('id') != app_id or index.get(('apps', app_id), {}).get('attributes', {}).get('bundleId') != bundle_id:
            continue
        release = index.get(('preReleaseVersions', release_ref.get('id')))
        if not release or release.get('attributes', {}).get('version') != version:
            continue
        if release.get('attributes', {}).get('platform') != IOS_PLATFORM:
            rejected_platform = True
            continue
        matches.append(item)
    if len(matches) != 1:
        if rejected_platform:
            raise ValueError('expected exactly one IOS build for the frozen version/build; '
                             'non-IOS or platform-missing pre-release candidates were rejected')
        raise ValueError('expected exactly one build for the frozen version/build')
    candidate = matches[0]
    relations = candidate.get('relationships', {})
    detail_ref = (relations.get('buildBetaDetail') or {}).get('data') or {}
    detail = index.get(('buildBetaDetails', detail_ref.get('id'))) if detail_ref.get('id') else None
    if detail is None:
        raise ValueError('build beta detail relationship is incomplete')
    return candidate, detail


def build_groups(build_id, call=api):
    value = call('GET', f'/v1/builds/{build_id}?include=betaGroups')
    relationship = (value.get('data', {}).get('relationships') or {}).get('betaGroups') or {}
    identifiers = [item['id'] for item in relationship.get('data', [])]
    total = relationship.get('meta', {}).get('paging', {}).get('total', len(identifiers))
    groups = [item for item in value.get('included', [])
              if item['type'] == 'betaGroups' and item['id'] in set(identifiers)]
    if len(identifiers) != len(set(identifiers)) or total != len(identifiers) \
            or {item['id'] for item in groups} != set(identifiers):
        raise RuntimeError('Incomplete build beta-group relationship; do not infer missing access')
    return groups


def fetch_external_group(app_id, group_name, call=api):
    params = query(**{
        'filter[app]': app_id, 'limit': '200',
        # publicLink/publicLinkId are requested explicitly so an enabled link
        # can be reported as its real URL instead of an ``enabled`` placeholder.
        # Public-link enablement remains a default-off explicit option.
        'fields[betaGroups]': ('name,isInternalGroup,publicLinkEnabled,publicLinkId,publicLink,'
                               'publicLinkLimitEnabled,feedbackEnabled'),
    })
    groups = rows('/v1/betaGroups?' + params, call)
    external = [g for g in groups if g.get('attributes', {}).get('name') == group_name
                and not g.get('attributes', {}).get('isInternalGroup', True)]
    internal = [g for g in groups if g.get('attributes', {}).get('name') == group_name
                and g.get('attributes', {}).get('isInternalGroup', True)]
    if len(external) != 1:
        raise ValueError(f'expected exactly one existing external group named {group_name!r}')
    if internal:
        raise ValueError(f'an internal group also uses the name {group_name!r}; resolve the ambiguity first')
    return groups, external[0]


def fetch_review_detail(app_id, call=api):
    try:
        value = call('GET', f'/v1/apps/{app_id}/betaAppReviewDetail?' + query(**{
            'fields[betaAppReviewDetails]': ','.join(REVIEW_DETAIL_FIELDS),
        }))
    except ApiError as error:
        if error.status == 404:
            return None
        raise
    return value.get('data')


def fetch_beta_app_localizations(app_id, call=api):
    localizations, _ = paged('/v1/betaAppLocalizations?' + query(**{
        'filter[app]': app_id, 'limit': '200',
        'fields[betaAppLocalizations]': 'locale,' + ','.join(BETA_APP_LOCALIZATION_FIELDS),
    }), call)
    return localizations


def fetch_build_localizations(build_id, call=api):
    localizations, _ = paged('/v1/betaBuildLocalizations?' + query(**{
        'filter[build]': build_id, 'limit': '200', 'fields[betaBuildLocalizations]': 'locale,whatsNew',
    }), call)
    return localizations


def fetch_submissions(build_id, call=api):
    submissions, _ = paged('/v1/betaAppReviewSubmissions?' + query(**{
        'filter[build]': build_id, 'limit': '200',
        'fields[betaAppReviewSubmissions]': 'betaReviewState,submittedDate,build',
    }), call)
    return submissions


def classify_submission(submission):
    state = submission['attributes'].get('betaReviewState')
    if state in PENDING_STATES:
        return 'pending_review'
    if state == 'APPROVED':
        return 'approved'
    if state == 'REJECTED':
        return 'rejected'
    return 'unknown:' + str(state)


def review_detail_summary(detail, prepared_notes=None):
    """Report review-detail field presence only; contact/demo values never leave.

    ``demoAccountRequired`` is the switch: when it is true both credential
    fields must be set; when false the credentials are not required; when it is
    missing/unknown the helper reports the field as unconfirmed and blocks
    submission rather than guessing.

    When ``prepared_notes`` is supplied, the existing ``notes`` value is
    compared with it and only the match/pending booleans are exposed; the old
    notes text itself is never returned or echoed.
    """
    if detail is None:
        return {
            'present': False,
            'missingFields': list(REVIEW_DETAIL_FIELDS),
            'notesPresent': False,
            'notesMatchPrepared': None if prepared_notes is None else False,
            'notesPendingWrite': None if prepared_notes is None else True,
            'demoAccountRequired': None,
            'demoAccountNamePresent': False,
            'demoAccountPasswordPresent': False,
            'demoAccountCredentialsRequired': None,
            'demoAccountCredentialsComplete': None,
        }
    attributes = detail.get('attributes', {})
    required = attributes.get('demoAccountRequired')
    if required not in (True, False):
        required = None
    name_present = bool(attributes.get('demoAccountName'))
    password_present = bool(attributes.get('demoAccountPassword'))
    missing = [name for name in ('contactFirstName', 'contactLastName', 'contactEmail', 'contactPhone')
               if attributes.get(name) in (None, '')]
    if not attributes.get('notes'):
        missing.append('notes')
    if required is None:
        missing.append('demoAccountRequired')
        credentials_complete = None
    elif required:
        if not name_present:
            missing.append('demoAccountName')
        if not password_present:
            missing.append('demoAccountPassword')
        credentials_complete = name_present and password_present
    else:
        credentials_complete = True
    notes_match = None
    notes_pending = None
    if prepared_notes is not None:
        notes_match = (attributes.get('notes') or '') == prepared_notes
        notes_pending = not notes_match
    return {
        'present': True,
        'missingFields': missing,
        'notesPresent': bool(attributes.get('notes')),
        'notesMatchPrepared': notes_match,
        'notesPendingWrite': notes_pending,
        'demoAccountRequired': required,
        'demoAccountNamePresent': name_present,
        'demoAccountPasswordPresent': password_present,
        'demoAccountCredentialsRequired': required,
        'demoAccountCredentialsComplete': credentials_complete,
    }


def beta_app_localization_summary(localizations):
    result = {}
    for locale, item in localization_map(localizations, 'betaAppLocalizations').items():
        attributes = item.get('attributes', {})
        entry = {'descriptionSet': bool(attributes.get('description'))}
        for name in BETA_APP_LOCALIZATION_FIELDS:
            if name in ('marketingUrl', 'privacyPolicyUrl'):
                entry[name] = attributes.get(name) or None
        entry['missingFields'] = [name for name in BETA_APP_LOCALIZATION_FIELDS
                                  if attributes.get(name) in (None, '')]
        result[locale] = entry
    return result


def resolve_public_link(attributes):
    """Resolve an enabled public link to a real URL; never fabricate one.

    Prefers Apple's ``publicLink`` attribute and only falls back to the
    documented ``https://testflight.apple.com/join/<publicLinkId>`` form when
    the ID itself is present. A disabled link resolves to ``(None, None)``; an
    enabled link with neither field resolves to ``(None, None)`` so callers
    can fail closed instead of printing an ``enabled`` placeholder.
    """
    if not attributes.get('publicLinkEnabled'):
        return None, None
    value = attributes.get('publicLink')
    if isinstance(value, str) and PUBLIC_LINK_RE.match(value):
        return value, 'publicLink'
    link_id = attributes.get('publicLinkId')
    if isinstance(link_id, str) and ID_RE.match(link_id):
        return 'https://testflight.apple.com/join/' + link_id, 'publicLinkId'
    return None, None


def build_summary(candidate, detail):
    attributes = candidate.get('attributes', {})
    detail_attributes = detail.get('attributes', {})
    return {
        'buildId': candidate['id'],
        'bundleId': None,  # filled by caller from the verified app
        'version': None,
        'build': attributes.get('version'),
        'uploadedDate': attributes.get('uploadedDate'),
        'processingState': attributes.get('processingState'),
        'expired': attributes.get('expired'),
        'audience': attributes.get('buildAudienceType'),
        'internalBuildState': detail_attributes.get('internalBuildState'),
        'externalBuildState': detail_attributes.get('externalBuildState'),
    }


def collect_context(*, bundle_id, version, build, tag, source_sha, group_name,
                    repo_root, call=api, artifact_sha256=None, artifact_source_sha=None,
                    descriptions=None, review_notes=None):
    """Read-only collection. Returns (context, issues); never mutates.

    ``descriptions`` is the already validated prepared input (en-US/zh-Hans).
    When present it lets the collection distinguish an empty current
    description that this exact input can repair from an empty description on
    a locale the input does not cover (which still blocks).

    ``review_notes`` is the already validated single prepared review-notes
    text. When present, a current note that differs is reported as fixable by
    the explicit submit (PATCH of the existing detail only) instead of being
    echoed or treated as an unfixable blocker.
    """
    context = {'issues': []}
    issues = context['issues']

    try:
        context['source'] = source_evidence(repo_root, tag, source_sha, bundle_id, version, build)
    except ValueError as error:
        context['source'] = {'verified': False, 'problem': str(error)}
        issues.append('source verification failed: ' + str(error))

    try:
        context['artifact'] = artifact_evidence(artifact_sha256, artifact_source_sha, source_sha)
    except ValueError as error:
        context['artifact'] = {'provided': True, 'bytesVerified': False, 'problem': str(error)}
        issues.append(str(error))

    try:
        context['app'] = fetch_app(bundle_id, call)
    except ValueError as error:
        issues.append(str(error))
        return context, issues

    try:
        candidate, detail = fetch_candidate(context['app']['id'], bundle_id, version, build, call)
        context['candidate'] = candidate
        context['detail'] = detail
    except ValueError as error:
        issues.append(str(error))
        return context, issues

    summary = build_summary(candidate, detail)
    summary['bundleId'] = bundle_id
    summary['version'] = version
    context['build'] = summary
    attributes = candidate.get('attributes', {})
    if attributes.get('processingState') != 'VALID':
        issues.append('build processing state is not VALID')
    if attributes.get('expired') is not False:
        issues.append('build is expired or expiry is unknown')
    if attributes.get('buildAudienceType') != AUDIENCE_EXTERNAL:
        issues.append('build audience is not APP_STORE_ELIGIBLE (INTERNAL_ONLY builds cannot be externally tested)')

    try:
        context['groups'], context['externalGroup'] = fetch_external_group(context['app']['id'], group_name, call)
    except ValueError as error:
        issues.append(str(error))

    try:
        visible = build_groups(candidate['id'], call)
        context['visibleGroups'] = visible
        external = context.get('externalGroup')
        context['externalGroupAttached'] = bool(external) and external['id'] in {g['id'] for g in visible}
    except (ValueError, RuntimeError) as error:
        issues.append(str(error))

    detail_resource = fetch_review_detail(context['app']['id'], call)
    context['reviewDetailId'] = (detail_resource or {}).get('id')
    context['reviewDetail'] = review_detail_summary(detail_resource, prepared_notes=review_notes)
    detail_summary = context['reviewDetail']
    if not detail_summary['present']:
        issues.append('betaAppReviewDetail is missing; external review contact information is not set')
    else:
        if not context['reviewDetailId'] or not ID_RE.match(context['reviewDetailId']):
            issues.append('betaAppReviewDetail id is missing or invalid; refusing to guess, use or create one')
        for name in ('contactFirstName', 'contactLastName', 'contactEmail', 'contactPhone'):
            if name in detail_summary['missingFields']:
                issues.append('betaAppReviewDetail is missing required contact field: ' + name)
        # A prepared review-notes file turns an empty or stale note into a
        # fixable field for the explicit submit (PATCH of the existing detail
        # only). Without one, an empty note stays a named blocker but the old
        # note text is never read out or inspected.
        if review_notes is not None:
            if detail_summary['notesPendingWrite']:
                context['reviewNotesFixable'] = True
        elif not detail_summary['notesPresent']:
            issues.append('betaAppReviewDetail notes are empty; provide the prepared review-notes file for submit')
        if detail_summary['demoAccountRequired'] is None:
            issues.append('betaAppReviewDetail demoAccountRequired is unconfirmed (field is empty); '
                          'cannot confirm whether demo credentials are required')
        elif detail_summary['demoAccountRequired'] and not detail_summary['demoAccountCredentialsComplete']:
            missing_demo = [name for name in ('demoAccountName', 'demoAccountPassword')
                            if name in detail_summary['missingFields']]
            issues.append('betaAppReviewDetail demoAccountRequired is true but missing field(s): '
                          + ','.join(missing_demo))
    try:
        context['betaAppLocalizations'] = beta_app_localization_summary(
            fetch_beta_app_localizations(context['app']['id'], call))
    except ValueError as error:
        issues.append(str(error))
        context['betaAppLocalizations'] = {}
    present_locales = set(context['betaAppLocalizations'])
    for locale in sorted(set(LOCALES) - present_locales):
        issues.append('betaAppLocalizations is missing locale: ' + locale)
    if descriptions is not None:
        for locale in sorted(descriptions):
            if locale not in present_locales:
                issues.append('missing betaAppLocalization for ' + locale)
    # Apple requires a description for every betaAppLocalization before a beta
    # review submission. An empty description on a locale covered by this
    # prepared input is exactly what the explicit submit may repair; every
    # other empty description (including locales this input does not cover)
    # still blocks, and missing localizations are never created here.
    context['descriptionFixableLocales'] = []
    for locale, entry in sorted(context['betaAppLocalizations'].items()):
        if not entry.get('descriptionSet'):
            if descriptions is not None and locale in descriptions:
                context['descriptionFixableLocales'].append(locale)
            else:
                issues.append('betaAppLocalizations description is empty for: ' + locale)
        if locale in LOCALES and 'feedbackEmail' in entry.get('missingFields', []):
            issues.append('betaAppLocalizations feedbackEmail is empty for: ' + locale)
    try:
        context['buildLocalizations'] = fetch_build_localizations(candidate['id'], call)
        build_locales = localization_map(context['buildLocalizations'], 'betaBuildLocalizations')
    except ValueError as error:
        issues.append(str(error))
        context['buildLocalizations'] = []
        build_locales = {}
    context['missingWhatToTestLocales'] = [
        locale for locale in LOCALES
        if not (build_locales.get(locale) or {}).get('attributes', {}).get('whatsNew')]
    context['submissions'] = fetch_submissions(candidate['id'], call)
    states = [classify_submission(item) for item in context['submissions']]
    if len([state for state in states if state in ('pending_review', 'approved')]) > 1:
        issues.append('multiple active betaAppReviewSubmissions exist for this build')
    return context, issues


def inspect_summary(context, issues, whats_new=None, descriptions=None, review_notes=None):
    group = context.get('externalGroup')
    group_attributes = (group or {}).get('attributes', {})
    try:
        build_localizations = localization_map(context.get('buildLocalizations', []), 'betaBuildLocalizations')
    except ValueError:
        # collect_context already recorded the duplicate-locale issue; never let
        # a dict overwrite silently decide what the build localizations are.
        build_localizations = {}
    existing_notes = {locale: item.get('attributes', {}).get('whatsNew')
                      for locale, item in build_localizations.items()}
    notes_report = None
    if whats_new is not None:
        notes_pending = any(existing_notes.get(locale) != text for locale, text in whats_new.items())
        notes_report = {'locales': sorted(whats_new), 'valid': True, 'pendingWrite': notes_pending}
    review_detail = context.get('reviewDetail') or {}
    review_notes_report = {
        'provided': review_notes is not None,
        'characters': len(review_notes) if review_notes is not None else None,
        'pendingWrite': bool(review_detail.get('notesPendingWrite')) if review_notes is not None else False,
        'currentNotesPresent': bool(review_detail.get('notesPresent')),
        'currentNotesMatchPrepared': review_detail.get('notesMatchPrepared') if review_notes is not None else None,
    }
    description_report = None
    if descriptions is not None:
        # The context stores a sanitized locale map; report only readiness and
        # which current empty descriptions this exact input would repair.
        current = context.get('betaAppLocalizations', {})
        description_report = {
            'locales': sorted(descriptions),
            'missingLocalizations': sorted(locale for locale in descriptions if locale not in current),
            'fixableEmptyDescriptionLocales': sorted(context.get('descriptionFixableLocales', [])),
        }
    submission_states = [classify_submission(item) for item in context.get('submissions', [])]
    public_link, public_link_source = (None, None)
    if group is not None:
        public_link, public_link_source = resolve_public_link(group_attributes)
        if group_attributes.get('publicLinkEnabled') and public_link is None:
            message = ('external group public link is enabled but the API returned no usable '
                       'publicLink/publicLinkId; no URL can be reported')
            if message not in issues:
                issues.append(message)
    summary = {
        'operation': 'inspect',
        'ok': not issues,
        'issues': sorted(set(issues)),
        'source': context.get('source'),
        'artifact': context.get('artifact'),
        'bundleId': context.get('build', {}).get('bundleId'),
        'version': context.get('build', {}).get('version'),
        'build': context.get('build', {}).get('build'),
        'buildState': {key: context['build'][key] for key in
                       ('buildId', 'processingState', 'expired', 'audience',
                        'internalBuildState', 'externalBuildState')} if 'build' in context else None,
        'externalGroup': {
            'name': group_attributes.get('name'),
            'isInternalGroup': group_attributes.get('isInternalGroup'),
            'publicLinkEnabled': group_attributes.get('publicLinkEnabled'),
            'publicLink': public_link,
            'publicLinkSource': public_link_source,
            'feedbackEnabled': group_attributes.get('feedbackEnabled'),
            'attachedToBuild': context.get('externalGroupAttached'),
        } if group is not None else None,
        'reviewDetail': context.get('reviewDetail'),
        'betaAppLocalizations': context.get('betaAppLocalizations'),
        'buildLocalizations': sorted(locale for locale, text in existing_notes.items() if text),
        'whatToTestMissingLocales': context.get('missingWhatToTestLocales', []),
        'notes': notes_report,
        'reviewNotes': review_notes_report,
        'descriptions': description_report,
        'submission': {
            'count': len(submission_states),
            'states': submission_states,
        },
        'publicLinkConfigurationRequested': False,
    }
    return summary


def inspect_with_context(*, bundle_id=DEFAULT_BUNDLE, version, build, tag, source_sha,
                         group_name=DEFAULT_GROUP, repo_root='.', call=api, notes_path=None,
                         review_notes_path=None, description_path=None,
                         artifact_sha256=None, artifact_source_sha=None):
    # Prepared input is validated before any read so a malformed or draft file
    # can never influence which repairs are considered possible.
    whats_new = load_localizations(notes_path) if notes_path else None
    review_notes = load_review_notes(review_notes_path) if review_notes_path else None
    descriptions = load_localizations(description_path) if description_path else None
    context, issues = collect_context(
        bundle_id=bundle_id, version=version, build=build, tag=tag, source_sha=source_sha,
        group_name=group_name, repo_root=repo_root, call=call,
        artifact_sha256=artifact_sha256, artifact_source_sha=artifact_source_sha,
        descriptions=descriptions, review_notes=review_notes)
    summary = inspect_summary(context, issues, whats_new=whats_new, descriptions=descriptions,
                              review_notes=review_notes)
    summary['context'] = context
    return summary


def inspect(*, bundle_id=DEFAULT_BUNDLE, version, build, tag, source_sha, group_name=DEFAULT_GROUP,
            repo_root='.', call=api, notes_path=None, review_notes_path=None, description_path=None,
            artifact_sha256=None, artifact_source_sha=None):
    """Read-only sanitized summary; no context or raw values are returned."""
    return public_summary(inspect_with_context(
        bundle_id=bundle_id, version=version, build=build, tag=tag, source_sha=source_sha,
        group_name=group_name, repo_root=repo_root, call=call,
        notes_path=notes_path, review_notes_path=review_notes_path, description_path=description_path,
        artifact_sha256=artifact_sha256, artifact_source_sha=artifact_source_sha))


# --------------------------------------------------------------------------
# Explicit write path
# --------------------------------------------------------------------------

def public_summary(summary):
    return {key: value for key, value in summary.items() if key != 'context'}


def write_notes(context, notes, call=api):
    existing = localization_map(context.get('buildLocalizations', []), 'betaBuildLocalizations')
    for locale, text in sorted(notes.items()):
        current = existing.get(locale)
        if current is not None:
            if current.get('attributes', {}).get('whatsNew') != text:
                call('PATCH', '/v1/betaBuildLocalizations/' + current['id'], {'data': {
                    'type': 'betaBuildLocalizations', 'id': current['id'],
                    'attributes': {'whatsNew': text}}})
        else:
            call('POST', '/v1/betaBuildLocalizations', {'data': {
                'type': 'betaBuildLocalizations',
                'attributes': {'locale': locale, 'whatsNew': text},
                'relationships': {'build': {'data': {'type': 'builds', 'id': context['candidate']['id']}}}}})
    readback_raw = fetch_build_localizations(context['candidate']['id'], call)
    readback = {locale: item.get('attributes', {}).get('whatsNew')
                for locale, item in localization_map(readback_raw, 'betaBuildLocalizations').items()}
    if any(readback.get(locale) != text for locale, text in notes.items()):
        raise RuntimeError('What-to-Test readback did not match the prepared input')


def write_descriptions(context, descriptions, call=api):
    raw = fetch_beta_app_localizations(context['app']['id'], call)
    existing = localization_map(raw, 'betaAppLocalizations')
    missing = sorted(locale for locale in descriptions if locale not in existing)
    if missing:
        raise ValueError('betaAppLocalization missing for locale(s): ' + ','.join(missing)
                         + '; every required localization must already exist before any description write')
    for locale, text in sorted(descriptions.items()):
        current = existing[locale]
        if current.get('attributes', {}).get('description') != text:
            call('PATCH', '/v1/betaAppLocalizations/' + current['id'], {'data': {
                'type': 'betaAppLocalizations', 'id': current['id'],
                'attributes': {'description': text}}})
    readback_raw = fetch_beta_app_localizations(context['app']['id'], call)
    readback = {locale: item.get('attributes', {}).get('description')
                for locale, item in localization_map(readback_raw, 'betaAppLocalizations').items()}
    if any(readback.get(locale) != text for locale, text in descriptions.items()):
        raise RuntimeError('Beta description readback did not match the prepared input')


def write_review_notes(context, review_notes, call=api):
    """PATCH only the existing ``betaAppReviewDetails/{id}.notes`` and read back.

    This never creates a review detail, never touches contact fields and never
    touches the demo-account fields. The PATCH body carries exactly one
    official attribute (``notes``) plus the existing resource id. The readback
    must equal the prepared text byte-for-byte, otherwise the function raises
    before the group attach and review submission can run.
    """
    detail_id = context.get('reviewDetailId') or ''
    if not ID_RE.match(detail_id):
        raise ValueError('existing betaAppReviewDetail id is missing or invalid; refusing to guess or create one')
    detail_summary = context.get('reviewDetail') or {}
    if not detail_summary.get('present'):
        raise ValueError('betaAppReviewDetail is missing; the helper never creates one')
    if detail_summary.get('notesMatchPrepared') is True:
        return False
    call('PATCH', '/v1/betaAppReviewDetails/' + detail_id, {'data': {
        'type': 'betaAppReviewDetails', 'id': detail_id,
        'attributes': {'notes': review_notes}}})
    readback_raw = fetch_review_detail(context['app']['id'], call)
    readback_notes = ((readback_raw or {}).get('attributes') or {}).get('notes')
    if readback_notes != review_notes:
        raise RuntimeError('betaAppReviewDetail notes readback did not match the prepared text byte-for-byte')
    return True


def attach_to_external_group(context, call=api):
    group = context['externalGroup']
    if context.get('externalGroupAttached'):
        return False
    if not ID_RE.match(group['id']):
        raise ValueError('unexpected external group ID')
    call('POST', f'/v1/betaGroups/{group["id"]}/relationships/builds',
         {'data': [{'type': 'builds', 'id': context['candidate']['id']}]})
    visible = build_groups(context['candidate']['id'], call)
    if group['id'] not in {item['id'] for item in visible}:
        raise RuntimeError('external group membership readback did not match')
    context['visibleGroups'] = visible
    context['externalGroupAttached'] = True
    return True


def create_review_submission(context, allow_resubmit_rejected, call=api):
    existing = context.get('submissions', [])
    if existing:
        states = [classify_submission(item) for item in existing]
        if any(state in ('pending_review', 'approved') for state in states):
            return {'action': 'duplicate_noop', 'submissionStates': states, 'submitted': False}
        if all(state == 'rejected' for state in states):
            if not allow_resubmit_rejected:
                return {'action': 'rejected_reported', 'submissionStates': states, 'submitted': False}
        else:
            raise ValueError('unrecognized existing betaAppReviewSubmission state')
    created = call('POST', '/v1/betaAppReviewSubmissions', {'data': {
        'type': 'betaAppReviewSubmissions',
        'relationships': {'build': {'data': {'type': 'builds', 'id': context['candidate']['id']}}}}})
    submission_id = (created.get('data') or {}).get('id')
    readback = fetch_submissions(context['candidate']['id'], call)
    if not readback:
        raise RuntimeError('betaAppReviewSubmission readback is empty')
    pending = [item for item in readback if classify_submission(item) in ('pending_review', 'approved')]
    if len(pending) != 1:
        raise RuntimeError('betaAppReviewSubmission readback is not unique')
    if submission_id and pending[0].get('id') != submission_id:
        raise RuntimeError('betaAppReviewSubmission readback did not match the created record')
    state = classify_submission(pending[0])
    return {'action': 'submitted' if state == 'pending_review' else state,
            'submissionStates': [state], 'submitted': True, 'submissionId': pending[0].get('id')}


def _read_public_link(group_id, call=api):
    """GET the matched group and resolve its enabled public link, or fail."""
    value = call('GET', f'/v1/betaGroups/{group_id}?' + query(**{
        'fields[betaGroups]': PUBLIC_LINK_FIELDS}))
    attributes = value.get('data', {}).get('attributes', {})
    if not attributes.get('publicLinkEnabled'):
        raise RuntimeError('public link readback did not confirm enablement')
    return resolve_public_link(attributes)


def enable_public_link(context, call=api):
    group = context['externalGroup']
    attributes = group.get('attributes', {})
    if attributes.get('publicLinkEnabled'):
        url, source = resolve_public_link(attributes)
        if url is None:
            url, source = _read_public_link(group['id'], call)
        if url is None:
            raise RuntimeError('public link is enabled but no usable publicLink/publicLinkId could be read back')
        return {'changed': False, 'publicLinkEnabled': True,
                'publicLink': url, 'publicLinkSource': source}
    body = {'data': {'type': 'betaGroups', 'id': group['id'],
                     'attributes': {'publicLinkEnabled': True}}}
    call('PATCH', '/v1/betaGroups/' + group['id'], body)
    url, source = _read_public_link(group['id'], call)
    if url is None:
        raise RuntimeError('public link readback confirmed enablement but returned no usable publicLink/publicLinkId')
    return {'changed': True, 'publicLinkEnabled': True,
            'publicLink': url, 'publicLinkSource': source}


def submit(*, bundle_id=DEFAULT_BUNDLE, version, build, tag, source_sha, group_name=DEFAULT_GROUP,
           repo_root='.', call=api, notes_path=None, review_notes_path=None, description_path=None,
           confirm_submit=False, enable_public_link_requested=False, allow_resubmit_rejected=False,
           artifact_sha256=None, artifact_source_sha=None):
    if not confirm_submit:
        raise ValueError('submit requires explicit confirmation (--confirm-submit)')
    if not notes_path:
        raise ValueError('submit requires a validated What-to-Test notes file')
    if not review_notes_path:
        raise ValueError('submit requires a validated final review-notes file (--review-notes)')
    notes = load_localizations(notes_path)
    review_notes = load_review_notes(review_notes_path)
    descriptions = load_localizations(description_path) if description_path else None
    pre = inspect_with_context(
        bundle_id=bundle_id, version=version, build=build, tag=tag, source_sha=source_sha,
        group_name=group_name, repo_root=repo_root, call=call,
        notes_path=notes_path, review_notes_path=review_notes_path, description_path=description_path,
        artifact_sha256=artifact_sha256, artifact_source_sha=artifact_source_sha)
    context = pre.pop('context')
    if not pre['ok']:
        raise ValueError('candidate is not ready for submission: ' + '; '.join(pre['issues']))
    existing_states = [classify_submission(item) for item in context.get('submissions', [])]
    unknown = [state for state in existing_states if state.startswith('unknown:')]
    if unknown:
        raise ValueError('unrecognized existing betaAppReviewSubmission state: ' + ','.join(unknown))
    if any(state in ('pending_review', 'approved') for state in existing_states):
        return {
            'operation': 'submit', 'action': 'duplicate_noop', 'submitted': False,
            'submissionStates': existing_states, 'writes': [], 'preflight': public_summary(pre),
            'note': 'existing submission reported only; no POST and no metadata write was performed',
        }
    if existing_states and not allow_resubmit_rejected:
        return {
            'operation': 'submit', 'action': 'rejected_reported', 'submitted': False,
            'submissionStates': existing_states, 'writes': [], 'preflight': public_summary(pre),
            'note': 'rejected submission reported only; pass --allow-resubmit-rejected for one explicit recovery POST',
        }
    writes = []
    write_notes(context, notes, call)
    writes.append('betaBuildLocalizations')
    if descriptions:
        write_descriptions(context, descriptions, call)
        writes.append('betaAppLocalizations')
    if write_review_notes(context, review_notes, call):
        writes.append('betaAppReviewDetails.notes')
    if not context.get('externalGroupAttached'):
        attach_to_external_group(context, call)
        writes.append('betaGroups.relationships.builds')
    outcome = create_review_submission(context, allow_resubmit_rejected, call)
    writes.append('betaAppReviewSubmissions')
    link = None
    if enable_public_link_requested:
        link = enable_public_link(context, call)
        if link.get('changed'):
            writes.append('betaGroups.publicLinkEnabled')
    readback = inspect(bundle_id=bundle_id, version=version, build=build, tag=tag, source_sha=source_sha,
                       group_name=group_name, repo_root=repo_root, call=call,
                       notes_path=notes_path, review_notes_path=review_notes_path,
                       description_path=description_path,
                       artifact_sha256=artifact_sha256, artifact_source_sha=artifact_source_sha)
    if not readback['ok']:
        raise RuntimeError('post-write readback is not clean: ' + '; '.join(readback['issues']))
    if readback['reviewNotes']['currentNotesMatchPrepared'] is not True:
        raise RuntimeError('review-notes readback did not confirm the prepared final text')
    active_states = [state for state in readback['submission']['states']
                     if state in ('pending_review', 'approved')]
    if active_states != outcome['submissionStates']:
        raise RuntimeError('submission readback did not match the created record')
    return {'operation': 'submit', 'action': outcome['action'], 'submitted': True,
            'submissionStates': outcome['submissionStates'], 'writes': writes,
            'publicLink': link, 'readback': readback}


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--operation', choices=('inspect', 'submit'), default='inspect')
    parser.add_argument('--bundle-id', default=DEFAULT_BUNDLE)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--group-name', default=DEFAULT_GROUP)
    parser.add_argument('--notes', type=Path, default=None)
    parser.add_argument('--review-notes', type=Path, default=None,
                        help='Prepared Beta App Review notes text (final text, 1..4000 characters, '
                             'no draft markers); required for submit')
    parser.add_argument('--description', type=Path, default=None)
    parser.add_argument('--repo-root', type=Path, default=Path('.'))
    parser.add_argument('--artifact-sha256', default=None)
    parser.add_argument('--artifact-source-sha', default=None)
    parser.add_argument('--confirm-submit', action='store_true')
    parser.add_argument('--enable-public-link', action='store_true')
    parser.add_argument('--allow-resubmit-rejected', action='store_true')
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.enable_public_link and args.operation != 'submit':
        print('enable-public-link is only valid with --operation submit', file=sys.stderr)
        return 2
    if args.operation == 'submit' and not args.confirm_submit:
        print('submit requires --confirm-submit', file=sys.stderr)
        return 2
    try:
        if args.operation == 'inspect':
            result = inspect(
                bundle_id=args.bundle_id, version=args.version, build=args.build, tag=args.tag,
                source_sha=args.source_sha, group_name=args.group_name, repo_root=args.repo_root,
                notes_path=args.notes, review_notes_path=args.review_notes,
                description_path=args.description,
                artifact_sha256=args.artifact_sha256, artifact_source_sha=args.artifact_source_sha)
            print(json.dumps(result, indent=2, sort_keys=True))
            return 0 if result['ok'] else 2
        result = submit(
            bundle_id=args.bundle_id, version=args.version, build=args.build, tag=args.tag,
            source_sha=args.source_sha, group_name=args.group_name, repo_root=args.repo_root,
            notes_path=args.notes, review_notes_path=args.review_notes,
            description_path=args.description,
            confirm_submit=args.confirm_submit,
            enable_public_link_requested=args.enable_public_link,
            allow_resubmit_rejected=args.allow_resubmit_rejected,
            artifact_sha256=args.artifact_sha256, artifact_source_sha=args.artifact_source_sha)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (ValueError, RuntimeError) as error:
        print(f'public-testflight failed: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
