#!/usr/bin/env python3
"""GET-only bundle identifier routing diagnostic. Never log raw API bodies."""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

HOST = 'https://api.appstoreconnect.apple.com'
RESOURCE_ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z')
IDENTIFIER = re.compile(r'[A-Za-z0-9][A-Za-z0-9._*-]{0,254}\Z')
ALLOWED_PATH = re.compile(r'/v1/(bundleIds(?:/[A-Za-z0-9._-]+)?|ciProducts(?:/[A-Za-z0-9._-]+/bundleId)?)\Z')


def permitted_path(value):
    parsed = urlsplit(value)
    if parsed.scheme or parsed.netloc:
        if parsed.scheme != 'https' or parsed.netloc != 'api.appstoreconnect.apple.com':
            raise ValueError('Diagnostic endpoint refused')
    if (parsed.fragment or not ALLOWED_PATH.fullmatch(parsed.path)
            or any(part in ('.', '..') for part in parsed.path.split('/'))):
        raise ValueError('Diagnostic endpoint refused')
    return parsed.path + ('?' + parsed.query if parsed.query else '')


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


class ReadOnlyAPI:
    def __init__(self, token, opener=None):
        self.token = token
        self.opener = opener or build_opener(NoRedirect())

    def get(self, path):
        path = permitted_path(path)
        request = Request(HOST + path, method='GET', headers={
            'Authorization': 'Bearer ' + self.token, 'Accept': 'application/json'})
        try:
            response = self.opener.open(request, timeout=30)
        except HTTPError as error:
            response = error
        except (URLError, TimeoutError, OSError):
            return 0, {}
        with response:
            status = response.code
            raw = response.read(4 * 1024 * 1024 + 1)
        if len(raw) > 4 * 1024 * 1024:
            return status, {}
        try:
            payload = json.loads(raw)
        except (ValueError, UnicodeError):
            return status, {}
        return status, payload if isinstance(payload, dict) else {}


def rows(payload, key='data'):
    value = payload.get(key, [])
    return value if isinstance(value, list) else [value] if isinstance(value, dict) else []


def exact(rows_, identifier):
    # Deliberately do not deduplicate an ID: duplicate exact records are ambiguous.
    return [row for row in rows_ if isinstance(row, dict) and row.get('type') == 'bundleIds'
            and isinstance(row.get('attributes'), dict)
            and row['attributes'].get('identifier') == identifier]


def key_names(value):
    return sorted(key for key in value if isinstance(key, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,64}', key)) if isinstance(value, dict) else []


def redacted_row(row):
    if not isinstance(row, dict):
        return {}
    value = {}
    if isinstance(row.get('id'), str) and RESOURCE_ID.fullmatch(row['id']):
        value['id'] = row['id']
    attributes = row.get('attributes', {})
    if isinstance(attributes, dict):
        identifier = attributes.get('identifier')
        if isinstance(identifier, str) and IDENTIFIER.fullmatch(identifier):
            value['identifier'] = identifier
        platform = attributes.get('platform')
        if isinstance(platform, str) and re.fullmatch(r'[A-Z0-9_]{1,32}', platform):
            value['platform'] = platform
    value['responseKeys'] = {'record': key_names(row), 'attributes': key_names(attributes),
                             'relationships': key_names(row.get('relationships', {}))}
    return value


def summary(label, status, payload, identifier):
    data, included = rows(payload), rows(payload, 'included')
    def related(row):
        if not isinstance(row, dict):
            return False
        if row.get('type') == 'bundleIds':
            return row.get('id') == identifier or row.get('attributes', {}).get('identifier') == identifier
        if row.get('type') == 'ciProducts':
            return row.get('relationships', {}).get('bundleId', {}).get('data', {}).get('id') == identifier
        return False
    return {'query': label, 'httpStatus': status, 'count': len(data),
            'exactCount': len(exact(data, identifier)), 'includedCount': len(included),
            'includedExactCount': len(exact(included, identifier)),
            'responseKeys': key_names(payload),
            'records': [redacted_row(row) for row in data if related(row)],
            'included': [redacted_row(row) for row in included if related(row)]}


def diagnose(api, identifier, ci_product_id='', bundle_resource_id='', report=None):
    if identifier != 'org.floeagent.ios':
        raise ValueError('Invalid identifier')
    for value in (ci_product_id, bundle_resource_id):
        if value and not RESOURCE_ID.fullmatch(value):
            raise ValueError('Invalid resource ID')
    if report is None:
        report = {'identifier': identifier, 'queries': []}
    report['identifier'] = identifier
    report.setdefault('counts', {})
    bundle_candidates, product_candidates = set(), set()

    def collect(label, path, resource_id=None):
        combined, included = [], []
        visited = set()
        for page in range(20):
            path = permitted_path(path)
            if path in visited:
                raise ValueError('Repeated pagination link')
            visited.add(path)
            status, payload = api.get(path)
            item = summary(label + '-page-' + str(page + 1), status, payload, identifier)
            if resource_id:
                item['id'] = resource_id
            report['queries'].append(item)
            combined.extend(rows(payload)); included.extend(rows(payload, 'included'))
            report['counts'][label] = {'count': len(combined), 'exactCount': len(exact(combined, identifier)),
                                      'includedCount': len(included), 'includedExactCount': len(exact(included, identifier))}
            next_link = payload.get('links', {}).get('next') if isinstance(payload.get('links'), dict) else None
            if status != 200 or not next_link:
                break
            path = next_link
        else:
            raise ValueError('Diagnostic page bound reached')
        return combined, included

    original, _ = collect('original-encoded-filter', '/v1/bundleIds?' + urlencode({'filter[identifier]': identifier, 'limit': 2}))
    all_rows, _ = collect('all-list-client-exact', '/v1/bundleIds?limit=200')
    products, included = collect('ci-products-including-bundle', '/v1/ciProducts?' + urlencode({
        'limit': 200, 'fields[ciProducts]': 'bundleId', 'include': 'bundleId'}))
    for row in exact(original + all_rows + included, identifier):
        if isinstance(row.get('id'), str) and RESOURCE_ID.fullmatch(row['id']):
            bundle_candidates.add(row['id'])
    for product in products:
        if not isinstance(product, dict) or product.get('type') != 'ciProducts':
            continue
        product_id = product.get('id')
        relationships = product.get('relationships')
        bundle_link = relationships.get('bundleId') if isinstance(relationships, dict) else None
        relationship = bundle_link.get('data') if isinstance(bundle_link, dict) else None
        if isinstance(relationship, dict) and relationship.get('type') == 'bundleIds':
            value = relationship.get('id')
            target_ids = {row.get('id') for row in exact(original + all_rows + included, identifier)}
            if value == identifier or value in target_ids:
                if isinstance(product_id, str) and RESOURCE_ID.fullmatch(product_id):
                    product_candidates.add(product_id)
            if isinstance(value, str) and RESOURCE_ID.fullmatch(value) and (value == identifier or value in target_ids):
                bundle_candidates.add(value)
    if ci_product_id:
        product_candidates.add(ci_product_id)
    if bundle_resource_id:
        bundle_candidates.add(bundle_resource_id)
    if len(product_candidates) > 20 or len(bundle_candidates) > 40:
        raise ValueError('Diagnostic resource bound reached')
    for product in sorted(product_candidates):
        related, _ = collect('ci-product-related-bundle', '/v1/ciProducts/' + product + '/bundleId', product)
        for row in exact(related, identifier):
            if isinstance(row.get('id'), str) and RESOURCE_ID.fullmatch(row['id']):
                bundle_candidates.add(row['id'])
    for resource in sorted(bundle_candidates):
        collect('direct-bundle-read', '/v1/bundleIds/' + resource, resource)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = {'queries': []}
    status = 0
    try:
        with tempfile.TemporaryDirectory(prefix='asc-readonly-', dir=os.environ.get('RUNNER_TEMP')) as directory:
            key = Path(directory) / 'key.p8'
            with key.open('xb') as stream:
                key.chmod(0o600)
                stream.write(base64.b64decode(os.environ['ASC_API_PRIVATE_KEY_BASE64'], validate=True))
            env = {**os.environ, 'ASC_PRIVATE_KEY_PATH': str(key)}
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('generate_asc_jwt.py'))],
                                    env=env, capture_output=True, text=True, check=True)
            diagnose(ReadOnlyAPI(result.stdout.strip()), os.environ.get('EXPECTED_IDENTIFIER', 'org.floeagent.ios'),
                     os.environ.get('CI_PRODUCT_ID', ''), os.environ.get('BUNDLE_RESOURCE_ID', ''), report=report)
    except Exception:
        # Neither raw response nor exception text can enter the retained report.
        report['responseKeys'] = ['diagnosticIncomplete']
        status = 1
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    args.report.chmod(0o600)
    print(json.dumps(report, sort_keys=True))
    return status


if __name__ == '__main__':
    raise SystemExit(main())
