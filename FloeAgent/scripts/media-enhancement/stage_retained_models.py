#!/usr/bin/env python3
"""Prepare exact retained model bytes for a later, separately qualified release.

Standard library only. Never downloads, compiles, converts or runs a model.
The source is read-only. Output raw release assets map directly to the existing
ModelArtifactStore per-file downloader; ZIP extraction is not a runtime contract.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import pathlib

SPECS = {
    'floe-model-rife-v4': ('MIT', ['MIT License', 'Practical-RIFE']),
    'floe-model-realesrgan-x2plus': ('BSD-3-Clause', ['BSD 3-Clause', 'Apache License', 'BasicSR']),
    'floe-model-realesrgan-x4plus': ('BSD-3-Clause', ['BSD 3-Clause', 'Apache License', 'BasicSR']),
}
RETAINED_MANIFESTS = {'floe-model-rife-v4': '05fc0094fbe1370c822b3dd15f10b3b391af2ddc7737856c8055a3a0f0266731', 'floe-model-realesrgan-x2plus': 'ff2b5aedee5b27061d1bbdead0978b63bbb6c7f4edbae5ed448458c08402f1aa', 'floe-model-realesrgan-x4plus': '651f3e2105928db4f6dc3b2e4161d51e6728bbd693bc254474dd436ffeb47c27'}
ESR_WEIGHTS = {
    '49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb',
    '4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1',
}

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(data)
    return h.hexdigest()

def encoded(value):
    return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()

def safe_member(path):
    member = pathlib.PurePosixPath(path)
    if member.is_absolute() or not path or any(p in ('', '.', '..') for p in path.split('/')) or '\\' in path:
        raise ValueError(f'unsafe model member: {path}')
    return member

def stage(source, output):
    if output.exists():
        raise ValueError('output already exists; use a new empty staging directory')
    if source == output or source in output.parents or output in source.parents:
        raise ValueError('source and output must be disjoint')
    models = []
    output.mkdir(parents=True)
    assets = output / 'assets'
    assets.mkdir()
    for name, (license_name, markers) in SPECS.items():
        bundle = source / name
        original_manifest = (bundle / 'manifest.json').read_bytes()
        if hashlib.sha256(original_manifest).hexdigest() != RETAINED_MANIFESTS[name]:
            raise ValueError(f'{name}: source is not the exact retained manifest')
        manifest = json.loads(original_manifest)
        contract = json.loads((bundle / 'contract.json').read_bytes())
        provenance = json.loads((bundle / 'PROVENANCE.json').read_bytes())
        if (manifest['id'], manifest['version'], manifest['capability']) != (contract['id'], contract['version'], contract['capability']):
            raise ValueError(f'{name}: manifest/contract identity mismatch')
        notices = (bundle / 'LICENSE.txt').read_text()
        if not all(marker in notices for marker in markers):
            raise ValueError(f'{name}: missing required upstream notices')
        if 'realesrgan' in name and provenance.get('weightsSha256') not in ESR_WEIGHTS:
            raise ValueError(f'{name}: weights outside the primary scoped license decision')
        members = {}
        for entry in manifest['files']:
            relative = entry['path']
            safe_member(relative)
            path = bundle / relative
            if relative in members or path.is_symlink() or any(parent.is_symlink() for parent in path.parents if parent != source.parent):
                raise ValueError(f'{name}: duplicate or symlink member')
            if not path.is_file() or digest(path) != entry['sha256'] or path.stat().st_size != entry['sizeBytes']:
                raise ValueError(f'{name}: retained byte mismatch: {relative}')
            members[relative] = path.read_bytes()
        actual = {p.relative_to(bundle).as_posix() for p in bundle.rglob('*') if p.is_file()}
        if actual != set(members) | {'manifest.json'}:
            raise ValueError(f'{name}: unlisted retained files')
        distribution = {
            'schemaVersion': 1, 'id': contract['id'], 'version': contract['version'],
            'retainedManifestSHA256': hashlib.sha256(original_manifest).hexdigest(),
            'originalProvenance': 'PROVENANCE.json',
            'licenseDecision': ('upstream-trained-link-MIT' if 'rife' in name else 'primary-inference-official-project-BSD-distribution'),
            'licenseDecisionIsNewAuthorGrant': False,
            'license': license_name, 'architectureLicense': 'MIT' if 'rife' in name else 'Apache-2.0',
            'licenseEvidence': contract.get('licenseEvidence'),
            'weightsLicenseEvidence': provenance.get('weightsLicenseEvidence'),
            'sourceCommit': contract['sourceCommit'],
            'runtimeContract': {'layout': 'model.mlmodelc', 'imageFeaturePrecision': 'RGB8', 'hdr': False,
                                'alpha': 'external-plane-SDR', 'computePrecision': 'FLOAT32',
                                'timestep': 'interior-phase-tensor' if 'rife' in name else None},
            'qualification': 'pending-current-round-host-and-device',
            'publication': 'not-published',
        }
        members['ORIGINAL-MANIFEST.json'] = original_manifest
        members['DISTRIBUTION.json'] = encoded(distribution)
        entries = [{'path': p, 'sha256': hashlib.sha256(data).hexdigest(), 'sizeBytes': len(data)} for p, data in sorted(members.items())]
        new_manifest = {key: manifest[key] for key in ('id', 'version', 'capability', 'license')}
        new_manifest['files'] = entries
        members['manifest.json'] = encoded(new_manifest)
        files = []
        for relative, data in sorted(members.items()):
            # GitHub release assets are flat; the signed catalog restores paths.
            asset_name = name + '--' + relative.replace('/', '--')
            if (assets / asset_name).exists():
                raise ValueError('release asset name collision')
            (assets / asset_name).write_bytes(data)
            target = output / 'bundles' / name / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            os.link(assets / asset_name, target)
            files.append({'path': relative, 'assetName': asset_name, 'sha256': hashlib.sha256(data).hexdigest(), 'sizeBytes': len(data)})
        models.append({'id': contract['id'], 'version': contract['version'], 'kind': 'coreml',
                       'capability': contract['capability'], 'skillID': 'floe-video', 'license': license_name,
                       'sourceCommit': contract['sourceCommit'], 'runtimeContract': distribution['runtimeContract'],
                       'originalManifestSHA256': distribution['retainedManifestSHA256'],
                       'manifestSHA256': hashlib.sha256(members['manifest.json']).hexdigest(),
                       'files': files, 'status': 'pending-qualification'})
    candidate = {'schemaVersion': 1, 'status': 'pending-qualification', 'models': models}
    (output / 'CANDIDATE.json').write_bytes(encoded(candidate))
    return candidate

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--retained', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    result = stage(args.retained.resolve(), args.output.resolve())
    print(json.dumps({'models': len(result['models']), 'files': sum(len(m['files']) for m in result['models']), 'status': result['status']}))

if __name__ == '__main__':
    main()
