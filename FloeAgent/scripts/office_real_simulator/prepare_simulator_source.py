#!/usr/bin/env python3
"""Fetch the pinned Collabora monorepo and apply the deployment overlay.

Read-only with respect to every tracked Floe file: the checkout lives in the
build root (runner scratch). The only source change is Floe's pinned
``ios-deployment-target.patch`` (iOS 26 min target, SHA-256 verified against
engine.lock.json); application is idempotent so a rerun into the same root is
safe. No device binary or platform metadata is touched.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

from sim_paths import DEPLOYMENT_PATCH, LOCK_PATH


def run(command, cwd=None, check=True, capture=False):
    result = subprocess.run([str(item) for item in command], cwd=cwd,
                            check=check, text=True,
                            capture_output=capture)
    return result


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def load_lock():
    lock = json.loads(LOCK_PATH.read_text())
    return lock['repository'], lock['commit'], lock['sourcePatchSHA256']


def prepare(build_root):
    repository, commit, expected_patch_sha = load_lock()
    patch_sha = sha256(DEPLOYMENT_PATCH)
    if patch_sha != expected_patch_sha:
        raise ValueError(
            f'deployment patch SHA mismatch: {patch_sha} != {expected_patch_sha}')
    build_root = Path(build_root).resolve()
    build_root.mkdir(parents=True, exist_ok=True)
    source = build_root / 'source'

    if not (source / '.git').exists():
        run(['git', 'init', str(source)])
        run(['git', '-C', str(source), 'remote', 'add', 'origin', repository])
        run(['git', '-C', str(source), 'fetch', '--depth=1', 'origin', commit])
        run(['git', '-C', str(source), 'checkout', '--detach', 'FETCH_HEAD'])

    head = run(['git', '-C', str(source), 'rev-parse', 'HEAD'], capture=True).stdout.strip()
    if head != commit:
        raise ValueError(f'source HEAD {head} != pinned commit {commit}')

    # Idempotent patch application: reverse if already applied, then apply.
    reverse_ok = run(
        ['git', 'apply', '--reverse', '--check', str(DEPLOYMENT_PATCH)],
        cwd=source, check=False, capture=True).returncode == 0
    if reverse_ok:
        run(['git', 'apply', '--reverse', str(DEPLOYMENT_PATCH)], cwd=source)
    run(['git', 'diff', '--exit-code'], cwd=source, check=True,
        capture=True)
    run(['git', 'apply', '--check', str(DEPLOYMENT_PATCH)], cwd=source)
    run(['git', 'apply', str(DEPLOYMENT_PATCH)], cwd=source)

    return {
        'buildRoot': str(build_root),
        'source': str(source),
        'repository': repository,
        'commit': commit,
        'deploymentPatch': str(DEPLOYMENT_PATCH),
        'deploymentPatchSHA256': patch_sha,
        'pinnedSourceReady': True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build_root', help='Runner scratch build root')
    parser.add_argument('--output', default=None)
    args = parser.parse_args()
    receipt = prepare(args.build_root)
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    if shutil.which('git') is None:
        sys.exit('git is required')
    main()
