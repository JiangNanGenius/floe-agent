#!/usr/bin/env python3
"""Update beta notes and enable an already-processed build for existing Floe QA."""
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request

BASE = 'https://api.appstoreconnect.apple.com'


def api(method, path, body=None):
    if not path.startswith('/v1/'):
        raise ValueError('Unexpected API path')
    request = urllib.request.Request(BASE + path, method=method,
        headers={'Authorization': 'Bearer ' + os.environ['ASC_TOKEN'], 'Content-Type': 'application/json'},
        data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as error:
        # Do not print request headers, tokens, or arbitrary response data.
        raise RuntimeError(f'App Store Connect {method} failed with HTTP {error.code}') from None


def rows(path, call=api):
    result = []
    while path:
        value = call('GET', path)
        result.extend(value.get('data', []))
        next_url = value.get('links', {}).get('next')
        if next_url and not next_url.startswith(BASE + '/v1/'):
            raise ValueError('Unexpected pagination destination')
        path = next_url[len(BASE):] if next_url else None
    return result


def build_groups(build_id, call=api):
    # App Store Connect supports this included relationship on the build read.
    # The direct /builds/{id}/betaGroups resource can reject GET with HTTP 403.
    value = call('GET', f'/v1/builds/{build_id}?include=betaGroups')
    relationship = value['data']['relationships']['betaGroups']
    identifiers = {item['id'] for item in relationship['data']}
    total = relationship.get('meta', {}).get('paging', {}).get('total', len(identifiers))
    groups = [item for item in value.get('included', [])
              if item['type'] == 'betaGroups' and item['id'] in identifiers]
    if total != len(identifiers) or {item['id'] for item in groups} != identifiers:
        raise RuntimeError('Incomplete build beta-group relationship; do not infer missing access')
    return groups


def prepare(build_id, bundle, version, number, notes, call=api):
    if not re.fullmatch(r'[A-Za-z0-9_-]+', build_id):
        raise ValueError('Invalid build ID')
    value = call('GET', f'/v1/builds/{build_id}?include=app,preReleaseVersion')
    build = value['data']
    included = {(item['type'], item['id']): item for item in value.get('included', [])}
    app_id = build['relationships']['app']['data']['id']
    release_id = build['relationships']['preReleaseVersion']['data']['id']
    if (build['attributes']['version'] != number or build['attributes']['processingState'] != 'VALID'
        or build['attributes'].get('expired', False)
        or included[('apps', app_id)]['attributes']['bundleId'] != bundle
        or included[('preReleaseVersions', release_id)]['attributes']['version'] != version):
        raise ValueError('Build is not the expected valid, unexpired candidate')
    query = urllib.parse.urlencode({'filter[app]': app_id, 'limit': 200})
    groups = [g for g in rows('/v1/betaGroups?' + query, call)
              if g['attributes']['name'] == 'Floe QA' and g['attributes']['isInternalGroup']
              and not g['attributes'].get('publicLinkEnabled', False)]
    if len(groups) != 1:
        raise ValueError('Expected one existing private internal Floe QA group')
    if not notes or any(locale not in ('en-US', 'zh-Hans') or not text.strip() or len(text) > 4000
                        for locale, text in notes.items()):
        raise ValueError('Invalid beta notes')
    localizations = rows('/v1/betaBuildLocalizations?' + urllib.parse.urlencode({'filter[build]': build_id, 'limit': 200}), call)
    for locale, text in notes.items():
        current = [item for item in localizations if item['attributes']['locale'] == locale]
        if len(current) > 1:
            raise ValueError('Ambiguous localization')
        if current:
            if current[0]['attributes'].get('whatsNew') != text:
                call('PATCH', '/v1/betaBuildLocalizations/' + current[0]['id'], {'data': {
                    'type': 'betaBuildLocalizations', 'id': current[0]['id'], 'attributes': {'whatsNew': text}}})
        else:
            call('POST', '/v1/betaBuildLocalizations', {'data': {'type': 'betaBuildLocalizations',
                'attributes': {'locale': locale, 'whatsNew': text},
                'relationships': {'build': {'data': {'type': 'builds', 'id': build_id}}}}})
    group_id = groups[0]['id']
    visible = build_groups(build_id, call)
    if group_id not in {g['id'] for g in visible}:
        call('POST', f'/v1/betaGroups/{group_id}/relationships/builds',
             {'data': [{'type': 'builds', 'id': build_id}]})
    visible = build_groups(build_id, call)
    actual = rows('/v1/betaBuildLocalizations?' + urllib.parse.urlencode({'filter[build]': build_id, 'limit': 200}), call)
    if group_id not in {g['id'] for g in visible}:
        raise RuntimeError('Floe QA build visibility not confirmed')
    actual_notes = {item['attributes']['locale']: item['attributes'].get('whatsNew') for item in actual}
    if any(actual_notes.get(locale) != text for locale, text in notes.items()):
        raise RuntimeError('Beta notes readback did not match')
    return {'buildID': build_id, 'version': version, 'build': number, 'processing': 'VALID',
            'group': 'Floe QA', 'betaNotesVerified': sorted(notes)}


if __name__ == '__main__':
    project = Path('FloeAgent/project.yml').read_text()
    def setting(name):
        return re.search(r'^\s*' + name + r':\s*"?([^"\s]+)', project, re.M).group(1)
    result = prepare(os.environ['BUILD_ID'], setting('PRODUCT_BUNDLE_IDENTIFIER'),
                     setting('MARKETING_VERSION'), setting('CURRENT_PROJECT_VERSION'),
                     json.loads(Path('docs/TESTFLIGHT_1.7_WHATS_NEW.json').read_text()))
    print(json.dumps(result))
