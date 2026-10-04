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


def github_api(path):
    return json.loads(subprocess.check_output(
        ['gh', 'api', f'repos/{REPOSITORY}/{path}'], text=True))


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


def verify(ipa, tag, source_sha, trust, provenance=None, invoke=subprocess.run,
           api_get=github_api):
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
    if policy.get('mode') == 'tagged-workflow-dispatch':
        require(provenance is None, 'Dispatch policy does not accept a recovery record')
        require(policy['signerWorkflow'] == '.github/workflows/release-unsigned-ipa.yml',
                'Unexpected dispatch signing workflow')
        require(re.fullmatch(r'sha256:[0-9a-f]{64}', policy['unsignedArtifactDigest']),
                'Invalid pinned unsigned artifact digest')
        require(ipa.name == f"Floe-Agent-{policy['version']}-build{policy['build']}-unsigned.ipa"
                and ipa.stat().st_size == policy['ipaBytes']
                and digest_file(ipa) == policy['ipaSHA256'],
                'Dispatch IPA identity or digest differs from the reviewed release')
        # The signed attestation identifies the dispatch controller commit.
        # Verify its successful exact-tag release run and retained artifact
        # separately; the controller SHA is never presented as the App SHA.
        invoke(['gh', 'attestation', 'verify', str(ipa), '--repo', REPOSITORY,
                '--source-digest', policy['packagingController'],
                '--signer-workflow', REPOSITORY + '/' + policy['signerWorkflow']], check=True)
        run = api_get(f"actions/runs/{policy['packagingRun']}")
        require(run['id'] == policy['packagingRun'] and run['head_repository']['full_name'] == REPOSITORY
                and run['event'] == 'workflow_dispatch' and run['head_branch'] == 'main'
                and run['head_sha'] == policy['packagingController']
                and run['path'] == policy['signerWorkflow'] and run['conclusion'] == 'success',
                'Dispatch release run does not match the reviewed controller')
        artifact = api_get(f"actions/artifacts/{policy['unsignedArtifactID']}")
        require(artifact['id'] == policy['unsignedArtifactID'] and not artifact['expired']
                and artifact['name'] == f"unsigned-ipa-{policy['version']}-build{policy['build']}"
                and artifact['digest'] == policy['unsignedArtifactDigest']
                and artifact['size_in_bytes'] == policy['unsignedArtifactSize']
                and artifact['workflow_run']['id'] == policy['packagingRun']
                and artifact['workflow_run']['head_sha'] == policy['packagingController'],
                'Retained unsigned artifact does not match the reviewed release')
        return {'mode': 'tagged-workflow-dispatch', 'sourceCommit': source_sha,
                'packagingController': policy['packagingController'],
                'packagingRun': policy['packagingRun']}
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
