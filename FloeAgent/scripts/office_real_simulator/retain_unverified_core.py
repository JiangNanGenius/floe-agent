#!/usr/bin/env python3
"""Quarantine compiled files when checkpoint validation fails.

This is recovery data, never a qualified checkpoint or staged engine. Preserve
the pinned source tree and outputs without interpreting linker lists, rewriting
symlinks or depending on platform tools. A later recovery requires a separate
review and the normal source/hash/platform gates; no runtime consumes this tar.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import time

from sim_paths import RESERVE_GIB

EXCLUDED_NAMES = {'.git', 'node_modules', '.DS_Store'}


def retain(build_root, output_dir):
    root = Path(build_root).resolve()
    output = Path(output_dir).resolve()
    if output.is_relative_to(root):
        raise ValueError('recovery output must be outside the build root')
    qualification = json.loads((root / 'qualification.json').read_text())
    if qualification.get('engineBuildCompleted') is not True:
        raise ValueError('no completed engine build to retain')
    if not (root / 'source/engine').is_dir():
        raise ValueError('compiled source/engine tree missing')
    if output.exists() and any(output.iterdir()):
        raise ValueError('recovery output already contains files')
    output.mkdir(parents=True, exist_ok=True)
    artifact = output / 'unverified-core.tar.gz'
    temporary = output / 'unverified-core.tar.gz.partial'
    count = 0
    last_report = time.monotonic()

    def include(info):
        nonlocal count, last_report
        if set(Path(info.name).parts) & EXCLUDED_NAMES:
            return None
        if not (info.isfile() or info.isdir() or info.issym() or info.islnk()):
            raise ValueError(f'unsupported recovery file type: {info.name}')
        free = shutil.disk_usage(output).free / 1024**3
        if free < RESERVE_GIB:
            raise RuntimeError('recovery archive stopped at disk reserve')
        count += 1
        now = time.monotonic()
        if now - last_report >= 60:
            print(json.dumps({'recoveryFiles': count,
                              'archiveBytes': temporary.stat().st_size,
                              'freeGiB': round(free, 2),
                              'reuseAllowed': False}), flush=True)
            last_report = now
        return info

    try:
        # Do not dereference absolute/escaping links. They are quarantined data,
        # not authority to extract anything or to bypass the normal restore gate.
        with tarfile.open(temporary, 'w:gz', compresslevel=1,
                          dereference=False) as archive:
            for name in ('source', 'qualification.json', 'qualification-logs'):
                path = root / name
                if path.exists():
                    archive.add(path, arcname=name, filter=include)
        temporary.replace(artifact)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    digest = hashlib.sha256()
    with artifact.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            digest.update(chunk)
    record = {
        'checkpointKind': 'unverified-core-recovery-only',
        'reuseAllowed': False,
        'restoreRequiresReview': True,
        'nativeBuildPassed': False,
        'finalQualification': False,
        'sourceCommit': qualification.get('commit'),
        'workflowSourceCommit': os.environ.get('GITHUB_SHA'),
        'workflowRunID': os.environ.get('GITHUB_RUN_ID'),
        'sdkVersion': qualification.get('sdkVersion'),
        'sdkBuildVersion': qualification.get('sdkBuildVersion'),
        'xcodeVersion': qualification.get('xcodeVersion'),
        'archiveSHA256': digest.hexdigest(),
        'archiveSize': artifact.stat().st_size,
        'fileCount': count,
        'engineBuildCompleted': True,
        'note': 'Opaque recovery data. Not platform validated. Never use as a '
                'checkpoint or staged engine; review before safe extraction.',
    }
    (output / 'unverified-core.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build_root')
    parser.add_argument('--output-dir', required=True)
    args = parser.parse_args()
    print(json.dumps(retain(args.build_root, args.output_dir), indent=2), flush=True)
