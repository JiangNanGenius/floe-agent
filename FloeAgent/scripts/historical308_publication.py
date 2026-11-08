#!/usr/bin/env python3
"""Explicit build308 controller authority; never impersonate the original App SHA.

The frozen V2 prepares the original device payload and attests two subjects.
This continuation accepts only a separately reviewed, completed producer run.
Normal releases retain their original-source verifier and workflow unchanged.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('historical308_frozen_v2', HERE / 'historical308_source_binding.py')
b = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(b)
MODE = 'historical-source-binding-v2'
PUBLISH_WORKFLOW = '.github/workflows/publish-historical308.yml'
POLICY_FILE = 'historical308-reviewed-macos26-v2.json'
REVIEW_FILE = 'historical308-publication-review-macos26-v2.json'
ACTIVATION_KEYS = ('mode sourceCommit packagingController controllerRef packagingRun packagingRunAttempt '
                   'signerWorkflow unsignedArtifactID unsignedArtifactDigest unsignedArtifactSize policySHA256 reviewSHA256')


def require(value, path, reason):
    b.require(value, 'historicalPublication', path, reason)


def authority(activation, authority_root=HERE):
    """Trusted main-branch data, not fields from a binding or a dispatch payload."""
    b.exact(activation, ACTIVATION_KEYS, 'activation')
    require(activation['mode'] == MODE and b.hexadecimal(activation['packagingController'], b.COMMIT)
            and b.hexadecimal(activation['sourceCommit'], b.COMMIT), 'activation.controller',
            'Freeze the reviewed controller and fill its full immutable SHA before activation')
    require(all(b.positive(activation[k]) for k in ('packagingRun', 'packagingRunAttempt',
            'unsignedArtifactID', 'unsignedArtifactSize'))
            and isinstance(activation['unsignedArtifactDigest'], str)
            and re.fullmatch(r'sha256:[0-9a-f]{64}', activation['unsignedArtifactDigest']),
            'activation.producer', 'Pin the actual successful producer attempt and artifact identity')
    controller = {'commit': activation['packagingController'], 'ref': activation['controllerRef'],
                  'runID': activation['packagingRun'], 'runAttempt': activation['packagingRunAttempt'],
                  'workflow': activation['signerWorkflow']}
    b.validate_controller(controller)
    policy_path = Path(authority_root) / 'release-policies' / POLICY_FILE
    review_path = Path(authority_root) / 'release-policies' / REVIEW_FILE
    require(b.hexadecimal(activation['policySHA256']) and b.hexadecimal(activation['reviewSHA256'])
            and b.digest(policy_path) == activation['policySHA256']
            and b.digest(review_path) == activation['reviewSHA256'], 'activation.policy',
            'Preparation policy and reviewed whole-device data must match the independent authority')
    policy = b.read_json(policy_path); b.validate_policy(policy)
    review = b.read_json(review_path)
    b.exact(review, 'schemaVersion kind reviewedMainSHA256 normalizerSHA256 review canonicalEntries protectedLatest', 'publicationReview')
    require(type(review['schemaVersion']) is int and review['schemaVersion'] == 1
            and review['kind'] == 'floe.historical308.publication-review-v2'
            and review['reviewedMainSHA256'] == b.digest(HERE / 'historical308_source_binding.py')
            and review['normalizerSHA256'] == b.digest(HERE / 'historical308_normalization_v2.py'),
            'publicationReview.code', 'Use the frozen reviewed V2 validator and Apple normalizer')
    require(activation['sourceCommit'] == policy['app']['sourceCommit']
            and controller['commit'] != policy['app']['sourceCommit'], 'activation.source',
            'The fixed controller is distinct from the original immutable App source')
    b.exact(review['review'], 'signedIPA deviceManifest sourceRaw transportRaw metadata normalizationProof', 'publicationReview.review')
    require(review['review']['deviceManifest'] == policy['expectedManifest']
            and b.positive(review['canonicalEntries']), 'publicationReview.manifest', 'The full reviewed canonical manifest is required')
    b.exact(review['protectedLatest'], 'tag build', 'publicationReview.protectedLatest')
    require(review['protectedLatest'] == {'tag': 'v1.8.5', 'build': '325'},
            'publicationReview.latest', 'This bounded backfill preserves build325 and its complete feed history')
    return policy, review, controller


def activated(authority_root=HERE):
    trust = b.read_json(Path(authority_root) / 'feather_recovery_trust.json')
    entry = trust.get(b.TAG)
    require(isinstance(entry, dict) and entry.get('mode') == MODE, 'activation',
            'Build308 needs a separately reviewed explicit historical source-binding activation')
    return entry


def publisher_context(activation, authority_root=HERE, env=os.environ):
    policy, review, controller = authority(activation, authority_root)
    require(env.get('GITHUB_REPOSITORY') == b.REPOSITORY
            and env.get('GITHUB_SHA') == controller['commit']
            and env.get('GITHUB_REF') == controller['ref']
            and env.get('GITHUB_WORKFLOW_REF') == b.REPOSITORY + '/' + PUBLISH_WORKFLOW + '@' + controller['ref'],
            'publisher.context', 'Dispatch the reviewed immutable controller tag; never override the Actions context')
    return policy, review, controller


def stage_prepared_archive(archive, destination, activation):
    archive, destination = Path(archive), Path(destination)
    b.archive_identity(archive, {'archiveSHA256': activation['unsignedArtifactDigest'].removeprefix('sha256:'),
        'archiveBytes': activation['unsignedArtifactSize']}, 'producer.archive')
    require(not destination.exists(), 'producer.stage', 'Use a new owned staging directory')
    b.recovery.safe_extract_zip(archive, destination)
    files = [p for p in destination.rglob('*') if p.is_file()]
    expected = {b.IPA_NAME, b.IPA_NAME + '.sha256', b.BINDING_NAME,
                'DEVICE-MANIFEST.json', 'APPLEDOUBLE-METADATA.json', 'NORMALIZATION-PROOF.json'}
    require(len(files) == len(expected) and {p.name for p in files} == expected,
            'producer.stage', 'The preparation artifact must contain exactly the two subjects, checksum and three private proofs')
    # Only paths/ZIP headers are inspected here, never the unverified binding JSON.
    return {p.name: p for p in files}


def producer_artifact(activation, controller, api_get):
    artifact = api_get(f"actions/artifacts/{activation['unsignedArtifactID']}")
    require(artifact.get('id') == activation['unsignedArtifactID'] and artifact.get('expired') is False
            and artifact.get('name') == f"historical308-preparation-{controller['runID']}-{controller['runAttempt']}"
            and artifact.get('digest') == activation['unsignedArtifactDigest']
            and artifact.get('size_in_bytes') == activation['unsignedArtifactSize']
            and artifact.get('workflow_run', {}).get('id') == controller['runID']
            and artifact.get('workflow_run', {}).get('head_sha') == controller['commit'],
            'producer.artifact', 'The retained preparation artifact must belong to the pinned completed producer attempt')
    run = api_get(f"actions/runs/{controller['runID']}/attempts/{controller['runAttempt']}")
    require(b.timestamp(run.get('run_started_at'), 'producer.started') <=
            b.timestamp(artifact.get('created_at'), 'producer.artifactCreated') <=
            b.timestamp(run.get('updated_at'), 'producer.completed'), 'producer.attempt',
            'The preparation artifact was not created during the pinned attempt')


def raw_device_manifest(ipa, policy, review):
    b.publication.audit_staged_ipa(Path(ipa).parent, {'ipa_name': b.IPA_NAME,
        'bundle_id': b.BUNDLE, 'version': b.VERSION, 'build': b.BUILD})
    with tempfile.TemporaryDirectory(prefix='floe-historical308-raw-') as owned:
        payload = Path(owned) / 'payload'
        b.extract_selected(ipa, payload, 'payload')
        manifest, entries = b.file_manifest(b.app_in(payload))
        require(manifest == policy['expectedManifest'] and len(entries) == review['canonicalEntries'],
                'ipa.rawManifest', 'The raw IPA already must equal the full reviewed payload; verification never normalizes or repairs it')
    return manifest, entries


def verify(ipa, binding, activation, *, authority_root=HERE, prepared_directory=None,
           api_get=b.github_api, invoke=subprocess.run):
    policy, reviewed, controller = authority(activation, authority_root)
    ipa, binding = Path(ipa), Path(binding)
    require(ipa.name == b.IPA_NAME and ipa.is_file() and not ipa.is_symlink() and ipa.stat().st_size > 0,
            'ipa', 'A regular build308 unsigned IPA subject is required')
    require(binding.name == b.BINDING_NAME and binding.is_file() and not binding.is_symlink()
            and 0 < binding.stat().st_size <= 65536, 'binding', 'A bounded regular binding subject is required')
    # Preserve V2's exact source-ref/digest, signer-digest/workflow, hosted runner
    # and run/attempt verification. BOTH real cryptographic verifications precede
    # any untrusted binding JSON read or live source/run/artifact authority read.
    b.verify_subject(ipa, controller, invoke)
    b.verify_subject(binding, controller, invoke)
    record = b.read_json(binding)
    b.check_sources(policy, controller, api_get, completed_controller=True)
    producer_artifact(activation, controller, api_get)
    observed = reviewed['review']
    reconstruction = {'manifest': policy['expectedManifest'], 'sourceRaw': observed['sourceRaw'],
        'transportRaw': observed['transportRaw'], 'signedIPA': observed['signedIPA'],
        'metadata': {'summary': observed['metadata']}, 'normalizationProofSummary': observed['normalizationProof']}
    expected = b.binding_for(policy, activation['policySHA256'], controller, reconstruction, ipa)
    require(b.canonical(record) == b.canonical(expected), 'binding',
            'The signed binding differs from the independent source, complete review or exact producer/controller identity')
    manifest, entries = raw_device_manifest(ipa, policy, reviewed)
    if prepared_directory is not None:
        paths = {p.name: p for p in Path(prepared_directory).rglob('*') if p.is_file()}
        device = b.read_json(paths['DEVICE-MANIFEST.json'], maximum=16 * 1024 * 1024)
        proof = b.read_json(paths['NORMALIZATION-PROOF.json'], maximum=16 * 1024 * 1024)
        metadata = b.read_json(paths['APPLEDOUBLE-METADATA.json'], maximum=16 * 1024 * 1024)
        b.exact(metadata, 'summary entries', 'producer.metadata')
        mapped = metadata['entries']
        require(isinstance(mapped, list) and all(isinstance(entry, dict)
                and isinstance(entry.get('structure'), dict) and b.positive(entry['structure'].get('bytes'))
                for entry in mapped), 'producer.metadata', 'Bounded paired metadata records are required')
        require(b.canonical(device) == b.canonical(entries)
                and hashlib.sha256(b.canonical(proof)).hexdigest() == observed['normalizationProof']['sha256']
                and metadata['summary'] == observed['metadata']
                and len(mapped) == observed['metadata']['mappings']
                and sum(entry['structure']['bytes'] for entry in mapped) == observed['metadata']['bytes']
                and hashlib.sha256(b.canonical(mapped)).hexdigest() == observed['metadata']['sha256'], 'producer.proofs',
                'The exact preparation artifact must retain the complete canonical manifest and reviewed private proof data')
    return {'verified': True, 'mode': MODE, 'sourceCommit': policy['app']['sourceCommit'],
        'packagingController': controller['commit'], 'packagingRef': controller['ref'],
        'packagingRun': controller['runID'], 'packagingRunAttempt': controller['runAttempt'],
        'ipaSHA256': b.digest(ipa), 'deviceManifest': manifest,
        'canonicalEntries': len(entries), 'appRebuilt': False, 'unsigned': True}


def public_assets(release, staged, *, complete):
    """Plan missing uploads, or prove all three remote asset digests and URLs.

    A retry can add a missing approved asset. It never clobbers a different
    existing asset, removes a foreign asset, changes a tag or replaces latest.
    """
    require(release.get('tag_name') == b.TAG and release.get('prerelease') is False
            and type(release.get('draft')) is bool and b.positive(release.get('id')),
            'release', 'Expected the existing build308 stable release')
    expected = {b.IPA_NAME, b.IPA_NAME + '.sha256', b.BINDING_NAME}
    index = b.publication.asset_index(release.get('assets'))
    require(set(index) <= expected and all(len(v) == 1 for v in index.values()),
            'release.assets', 'Only the canonical IPA, checksum and minimal binding may be public')
    for name, values in index.items():
        item, local = values[0], Path(staged) / name
        require(local.is_file() and not local.is_symlink() and item.get('state') == 'uploaded'
                and item.get('digest') == 'sha256:' + b.digest(local) and item.get('size') == local.stat().st_size
                and item.get('browser_download_url') == f'https://github.com/{b.REPOSITORY}/releases/download/{b.TAG}/{name}',
                'release.assets.' + name, 'An existing remote asset differs from the audited subject; no clobber is allowed')
    missing = sorted(expected - set(index))
    if complete:
        require(not missing and release['draft'] is False and release.get('published_at'),
                'release', 'Publication is incomplete; all attested bytes must be uploaded and public')
    return missing


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--authority-root', type=Path, default=HERE)
    p.add_argument('--ipa', required=True, type=Path)
    p.add_argument('--binding', required=True, type=Path)
    p.add_argument('--prepared-directory', type=Path)
    p.add_argument('--report', required=True, type=Path)
    args = p.parse_args()
    result = verify(args.ipa, args.binding, activated(args.authority_root),
        authority_root=args.authority_root, prepared_directory=args.prepared_directory)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open('x') as output:
        output.write(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
