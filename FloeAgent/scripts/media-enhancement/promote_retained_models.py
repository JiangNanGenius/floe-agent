#!/usr/bin/env python3
"""Produce staged models.json promotion only after qualified exact-byte public read-back.

This is intentionally a separate step from staging. Does not publish or sign.
Qualification JSON is the primary owner's reviewed evidence, indexed by model
ID with manifestSHA256, hostPassed/devicePassed and hostEvidence/deviceEvidence.
Every public asset under the supplied immutable release tag is independently read back;
remote bytes must match CANDIDATE.json. Output is a models.json candidate, requiring ordinary hub build/sign/publication
by the release owner. This script never writes catalog.json or catalog.sig.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import pathlib
import urllib.parse
import urllib.request


def promote(candidate, qualification, staged, release_base):
    base = urllib.parse.urlparse(release_base)
    if base.scheme != 'https' or base.hostname != 'github.com' or base.username or base.password or base.query or base.fragment:
        raise ValueError('use an immutable HTTPS github.com release URL without credentials')
    parts = base.path.strip('/').split('/')
    if len(parts) != 5 or parts[2:4] != ['releases', 'download'] or parts[-1] in ('latest', 'main', 'master'):
        raise ValueError('use /owner/repository/releases/download/immutable-tag')
    existing = {m['id']: m for m in staged['models']}
    for model in candidate['models']:
        evidence = qualification.get('models', {}).get(model['id'], {})
        if (evidence.get('manifestSHA256') != model['manifestSHA256'] or
            evidence.get('hostPassed') is not True or evidence.get('devicePassed') is not True or
            not evidence.get('hostEvidence') or not evidence.get('deviceEvidence')):
            raise ValueError(f"{model['id']}: exact manifest host/device qualification is required")
        files = []
        for file in model['files']:
            url = release_base.rstrip('/') + '/' + urllib.parse.quote(file['assetName'], safe='')
            h = hashlib.sha256()
            count = 0
            with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'Floe-model-release-readback'}), timeout=120) as response:
                final = urllib.parse.urlparse(response.url)
                if final.scheme != 'https' or not (final.hostname == 'github.com' or (final.hostname or '').endswith('.githubusercontent.com')):
                    raise ValueError('unexpected release asset redirect')
                for chunk in iter(lambda: response.read(1024 * 1024), b''):
                    count += len(chunk)
                    if count > file['sizeBytes']:
                        raise ValueError('remote asset exceeded its exact byte bound')
                    h.update(chunk)
            if count != file['sizeBytes'] or h.hexdigest() != file['sha256']:
                raise ValueError(f"{model['id']}: published asset byte mismatch: {file['path']}")
            files.append({key: file[key] for key in ('path', 'sha256', 'sizeBytes')} | {'url': url})
        target = existing[model['id']]
        target.update(version=model['version'], files=files, status='ready',
                      conversionStatus='qualified-exact-retained-bytes', deviceQualification='passed',
                      runtimeContract=model['runtimeContract'], manifestSHA256=model['manifestSHA256'])
        target.pop('preparedAssets', None)
    return staged


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=pathlib.Path, required=True)
    parser.add_argument('--qualification', type=pathlib.Path, required=True)
    parser.add_argument('--models', type=pathlib.Path, required=True)
    parser.add_argument('--release-base', required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.output.resolve() == args.models.resolve():
        raise ValueError('promotion must be a separate reviewable output')
    result = promote(json.loads(args.candidate.read_text()), json.loads(args.qualification.read_text()), json.loads(args.models.read_text()), args.release_base)
    args.output.write_text(json.dumps(result, separators=(',', ':'), sort_keys=True) + '\n')

if __name__ == '__main__':
    main()
