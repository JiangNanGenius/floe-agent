#!/usr/bin/env python3
"""Verify the immutable App source or an explicitly pinned recovery chain.

Recovery attests both the IPA and the record connecting its digest to the
original device-build artifact. Its controller SHA is never called the App SHA.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

REPOSITORY = "JiangNanGenius/floe-agent"


def require(value, message):
    if not value:
        raise ValueError(message)


def digest_file(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def validate_record(record, policy, *, tag, source_sha, ipa):
    require(record.get('schemaVersion') == 1, 'Unsupported recovery record')
    require(record.get('sourceTag') == tag and record.get('sourceCommit') == source_sha,
            'Recovery record does not bind the requested immutable App source')
    for name in ('sourceCommit', 'sourceRun', 'sourceArtifactID', 'sourceArtifactDigest',
                 'deviceArchiveSHA256', 'packagingController', 'packagingRun'):
        require(record.get(name) == policy[name], 'Recovery trust mismatch: ' + name)
    require(record.get('appRebuilt') is False and record.get('unsigned') is True,
            'Expected original unsigned device recovery without compilation')
    require(record.get('ipaName') == ipa.name and record.get('ipaBytes') == ipa.stat().st_size
            and record.get('ipaSHA256') == digest_file(ipa), 'Recovery record IPA digest/identity mismatch')


def verify(ipa, tag, source_sha, trust, provenance=None, invoke=subprocess.run):
    ipa = Path(ipa)
    require(re.fullmatch(r'v\d+\.\d+\.\d+(?:-beta\.\d+)?', tag), 'Invalid release tag')
    require(re.fullmatch(r'[0-9a-f]{40}', source_sha), 'Invalid source digest')
    require(ipa.is_file() and not ipa.is_symlink(), 'Expected a regular IPA')
    policy = trust.get(tag)
    if policy is None:
        require(provenance is None, 'Recovery record requires an explicit trusted policy')
        invoke(['gh', 'attestation', 'verify', str(ipa), '--repo', REPOSITORY,
                '--source-digest', source_sha,
                '--signer-workflow', REPOSITORY + '/.github/workflows/release-unsigned-ipa.yml'], check=True)
        return {'mode': 'original-source', 'sourceCommit': source_sha}
    require(policy['sourceCommit'] == source_sha, 'Trusted App source differs from immutable tag')
    require(re.fullmatch(r'[0-9a-f]{40}', policy['packagingController']), 'Invalid trusted controller')
    require(policy['signerWorkflow'] == '.github/workflows/developer-ipa-from-recovery.yml',
            'Unexpected recovery signing workflow')
    require(provenance is not None, 'Attested recovery record is mandatory')
    record_path = Path(provenance)
    require(record_path.name == 'BUILD191-RECOVERY-PROVENANCE.json' and record_path.is_file()
            and not record_path.is_symlink() and record_path.stat().st_size < 65536,
            'Missing or invalid recovery record')
    # Verify signatures before trusting the JSON, and never fall back on failure.
    for subject in (ipa, record_path):
        invoke(['gh', 'attestation', 'verify', str(subject), '--repo', REPOSITORY,
                '--source-digest', policy['packagingController'],
                '--signer-workflow', REPOSITORY + '/' + policy['signerWorkflow']], check=True)
    record = json.loads(record_path.read_text())
    validate_record(record, policy, tag=tag, source_sha=source_sha, ipa=ipa)
    return {'mode': 'attested-recovery', 'sourceCommit': source_sha,
            'packagingController': policy['packagingController'], 'packagingRun': policy['packagingRun']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', required=True, type=Path)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--trust', required=True, type=Path)
    parser.add_argument('--provenance', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.ipa, args.tag, args.source_sha,
                            json.loads(args.trust.read_text()), args.provenance)))
