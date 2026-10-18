#!/usr/bin/env python3
"""Fetch the pinned Collabora monorepo and apply Floe source patches.

Read-only with respect to every tracked Floe file: the checkout lives in the
build root (runner scratch).  Two contracts are consumed before the receipt can
say ``pinnedSourceReady``:

* ``engine.lock.json`` pins the upstream repository/commit and the exact
  deployment patch SHA-256;
* ``engine.patch.lock.json`` may pin browser source patches
  (``browserSourcePatches``).  Every entry names exactly one source file, its
  patch digest, and the original/patched source SHA-256.

All patches and every affected file are validated before anything is applied.
Each affected file must be in one known state: the pinned original or the exact
patched source.  The script never resets, checks out over or cleans the build
root, so an unrelated local edit fails the run without being overwritten.
Application is idempotent: a rerun into the same root verifies and reuses the
already applied patches.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile

from sim_paths import DEPLOYMENT_PATCH, LOCK_PATH

SHA256_RE = re.compile(r'^[0-9a-f]{64}$')
UNSAFE_PATCH_MARKERS = (
    'rename from ', 'rename to ', 'copy from ', 'copy to ',
    'new file mode ', 'deleted file mode ', 'old mode ', 'new mode ',
    'git binary patch', 'binary files ', 'subproject commit ',
)


def run(command, cwd=None, check=True, capture=False, env=None):
    result = subprocess.run([str(item) for item in command], cwd=cwd,
                            check=check, text=True,
                            capture_output=capture, env=env)
    return result


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def is_within(path, parent):
    try:
        Path(path).relative_to(Path(parent))
        return True
    except ValueError:
        return False


def validated_relative(value, label):
    require(isinstance(value, str) and value,
            f'{label} must be a non-empty relative path')
    require('\\' not in value, f'{label} must use POSIX separators: {value!r}')
    require(not value.startswith('/'), f'{label} must be relative: {value!r}')
    parts = PurePosixPath(value).parts
    require(parts and '.' not in parts and '..' not in parts,
            f'{label} escapes its root: {value!r}')
    # ``git apply --include`` treats these characters as a pattern.
    require(not any(character in value for character in '*?['),
            f'{label} must not contain wildcard characters: {value!r}')
    return value


def load_lock(lock_path):
    try:
        lock = json.loads(Path(lock_path).read_text())
    except (OSError, ValueError) as error:
        raise ValueError(f'cannot read engine lock {lock_path}: {error}')
    require(isinstance(lock, dict), f'engine lock {lock_path} is not an object')
    repository = lock.get('repository')
    commit = lock.get('commit')
    patch_sha = lock.get('sourcePatchSHA256')
    require(isinstance(repository, str) and repository,
            'engine lock repository is missing')
    require(isinstance(commit, str) and commit, 'engine lock commit is missing')
    require(isinstance(patch_sha, str) and SHA256_RE.fullmatch(patch_sha),
            'engine lock sourcePatchSHA256 is not a lowercase SHA-256')
    return repository, commit, patch_sha


def patch_targets(source, patch_file, label):
    """Return the worktree paths a patch changes, using git's own parser."""
    result = run(['git', 'apply', '--numstat', str(patch_file)], cwd=source,
                 check=False, capture=True)
    require(result.returncode == 0,
            f'{label} cannot be parsed by git apply: {result.stderr.strip()}')
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    require(lines, f'{label} changes no files')
    paths = []
    for line in lines:
        parts = line.split('\t')
        require(len(parts) == 3,
                f'{label} has an unexpected git apply --numstat line: {line!r}')
        added, removed, path = parts
        require(added != '-' and removed != '-',
                f'{label} contains a binary patch')
        paths.append(validated_relative(path, f'{label} path'))
    return paths


def reject_unsafe_patch(patch_file, label):
    try:
        text = Path(patch_file).read_text()
    except UnicodeDecodeError:
        raise ValueError(f'{label} is not a UTF-8 text patch')
    lowered = text.lower()
    for marker in UNSAFE_PATCH_MARKERS:
        require(marker not in lowered,
                f'{label} uses an unsupported patch operation: {marker.strip()}')


def contained_target(root, relative, label):
    target = Path(root) / relative
    require(target.is_file(), f'{label} is not a file: {relative}')
    require(not target.is_symlink(), f'{label} is a symlink: {relative}')
    require(is_within(target.resolve(), Path(root).resolve()),
            f'{label} escapes the source root: {relative}')
    return target


def load_browser_patches(patch_lock_path, source, repository, commit):
    """Read and fully validate the browser source patch contract."""
    patch_lock_path = Path(patch_lock_path)
    require(patch_lock_path.is_file() and not patch_lock_path.is_symlink(),
            f'browser patch lock is not a regular file: {patch_lock_path}')
    raw = patch_lock_path.read_bytes()
    try:
        lock = json.loads(raw.decode('utf-8'))
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError(
            f'cannot read browser patch lock {patch_lock_path}: {error}')
    require(isinstance(lock, dict),
            f'browser patch lock {patch_lock_path} is not an object')
    require(lock.get('formatVersion') == 1,
            'browser patch lock formatVersion is not 1')
    engine = lock.get('engine')
    if engine is not None:
        require(isinstance(engine, dict), 'browser patch lock engine is invalid')
        require(engine.get('repository') == repository,
                'browser patch lock repository differs from the engine lock')
        require(engine.get('commit') == commit,
                'browser patch lock commit differs from the engine lock')
    entries = lock.get('browserSourcePatches', [])
    if entries is None:
        entries = []
    require(isinstance(entries, list),
            'browserSourcePatches must be a list')
    base = patch_lock_path.parent.resolve()
    patches = []
    seen = set()
    for index, entry in enumerate(entries):
        label = f'browserSourcePatches[{index}]'
        require(isinstance(entry, dict), f'{label} is not an object')
        patch_relative = validated_relative(entry.get('patch'), f'{label}.patch')
        patch_sha = entry.get('patchSHA256')
        require(isinstance(patch_sha, str) and SHA256_RE.fullmatch(patch_sha),
                f'{label}.patchSHA256 is not a lowercase SHA-256')
        require(entry.get('sourceRepository') == repository,
                f'{label} sourceRepository differs from the engine lock')
        require(entry.get('sourceCommit') == commit,
                f'{label} sourceCommit differs from the engine lock')
        source_file = validated_relative(entry.get('sourceFile'),
                                         f'{label}.sourceFile')
        require(source_file not in seen,
                f'{label} duplicates source file {source_file}')
        seen.add(source_file)
        original_sha = entry.get('originalSourceSHA256')
        patched_sha = entry.get('patchedSourceSHA256')
        for key, value in (('originalSourceSHA256', original_sha),
                           ('patchedSourceSHA256', patched_sha)):
            require(isinstance(value, str) and SHA256_RE.fullmatch(value),
                    f'{label}.{key} is not a lowercase SHA-256')
        require(original_sha != patched_sha,
                f'{label} original and patched source SHA-256 are equal')
        patch_file = (base / patch_relative).resolve()
        require(is_within(patch_file, base),
                f'{label} patch escapes the patch lock directory')
        require(patch_file.is_file() and not patch_file.is_symlink(),
                f'{label} patch is not a regular file: {patch_file}')
        actual_patch_sha = sha256(patch_file)
        require(actual_patch_sha == patch_sha,
                f'{label} patch SHA-256 mismatch: '
                f'{actual_patch_sha} != {patch_sha}')
        reject_unsafe_patch(patch_file, label)
        targets = patch_targets(source, patch_file, label)
        require(len(targets) == 1 and targets[0] == source_file,
                f'{label} must change exactly its sourceFile {source_file}, '
                f'found {targets}')
        contained_target(source, source_file, f'{label}.sourceFile')
        patches.append({
            'patch': patch_relative,
            'patchFile': str(patch_file),
            'patchSHA256': patch_sha,
            'sourceRepository': repository,
            'sourceCommit': commit,
            'sourceFile': source_file,
            'originalSourceSHA256': original_sha,
            'patchedSourceSHA256': patched_sha,
        })
    return {'path': str(patch_lock_path), 'sha256': sha256_bytes(raw),
            'patches': patches}


def head_blob_sha(source, relative):
    result = subprocess.run(
        ['git', '-C', str(source), 'show', f'HEAD:{relative}'],
        capture_output=True)
    require(result.returncode == 0,
            f'pinned commit does not contain {relative}: '
            f'{result.stderr.decode("utf-8", "replace").strip()}')
    return sha256_bytes(result.stdout)


def patched_blob_hashes(source, patch_file, paths):
    """Apply the patch to HEAD in a temporary index and hash the results.

    The working tree is never touched.  This proves the patch itself produces
    the locked patched bytes before any real file is changed.
    """
    with tempfile.TemporaryDirectory(prefix='floe-office-patch-') as tmp:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(tmp) / 'index'))
        run(['git', 'read-tree', 'HEAD'], cwd=source, env=env)
        applied = run(['git', 'apply', '--cached', str(patch_file)],
                      cwd=source, check=False, capture=True, env=env)
        require(applied.returncode == 0,
                f'patch {patch_file} does not apply to the pinned sources: '
                f'{applied.stderr.strip()}')
        hashes = {}
        for relative in paths:
            blob = subprocess.run(
                ['git', '-C', str(source), 'cat-file', 'blob',
                 f':{relative}'], env=env, capture_output=True)
            require(blob.returncode == 0,
                    f'temporary index does not contain {relative}: '
                    f'{blob.stderr.decode("utf-8", "replace").strip()}')
            hashes[relative] = sha256_bytes(blob.stdout)
    return hashes


def patch_applies(source, patch_file, paths, reverse=False):
    command = ['git', 'apply']
    if reverse:
        command.append('--reverse')
    command.append('--check')
    command.extend(f'--include={path}' for path in paths)
    command.append(str(patch_file))
    return run(command, cwd=source, check=False, capture=True).returncode == 0


def apply_patch(source, patch_file, paths):
    command = ['git', 'apply']
    command.extend(f'--include={path}' for path in paths)
    command.append(str(patch_file))
    result = run(command, cwd=source, check=False, capture=True)
    require(result.returncode == 0,
            f'git apply failed for {patch_file}: {result.stderr.strip()}')


def tracked_changes(source):
    result = run(['git', 'diff', '--name-status', '-z', 'HEAD'], cwd=source,
                 check=False, capture=True)
    require(result.returncode == 0,
            f'cannot inspect the source diff: {result.stderr.strip()}')
    tokens = result.stdout.split('\0')
    changes = {}
    index = 0
    while index < len(tokens) and tokens[index]:
        status = tokens[index]
        index += 1
        if status[0] in ('R', 'C'):
            require(index + 1 < len(tokens),
                    'malformed rename/copy entry in git diff')
            changes[tokens[index]] = status
            changes[tokens[index + 1]] = status
            index += 2
        else:
            require(index < len(tokens), 'malformed entry in git diff')
            changes[tokens[index]] = status
            index += 1
    return changes


def require_only_known_changes(changes, expected, phase):
    unexpected = sorted(set(changes) - set(expected))
    require(not unexpected,
            f'unexpected tracked change(s) {phase}: ' + ', '.join(unexpected))
    invalid = sorted((path, status) for path, status in changes.items()
                     if status != 'M')
    require(not invalid,
            f'unexpected tracked change status {phase}: '
            + ', '.join(f'{status} {path}' for path, status in invalid))


def prepare(build_root, lock_path=None, deployment_patch=None,
            patch_lock_path=None):
    lock_path = Path(lock_path or LOCK_PATH)
    deployment_patch = Path(deployment_patch or DEPLOYMENT_PATCH)
    if patch_lock_path is None:
        patch_lock_path = lock_path.parent / 'engine.patch.lock.json'
    else:
        patch_lock_path = Path(patch_lock_path)

    repository, commit, expected_patch_sha = load_lock(lock_path)
    require(deployment_patch.is_file() and not deployment_patch.is_symlink(),
            f'deployment patch is not a regular file: {deployment_patch}')
    patch_sha = sha256(deployment_patch)
    require(patch_sha == expected_patch_sha,
            f'deployment patch SHA mismatch: {patch_sha} != '
            f'{expected_patch_sha}')
    reject_unsafe_patch(deployment_patch, 'deployment patch')

    build_root = Path(build_root).resolve()
    build_root.mkdir(parents=True, exist_ok=True)
    source = build_root / 'source'

    if not (source / '.git').exists():
        run(['git', 'init', str(source)])
        run(['git', '-C', str(source), 'remote', 'add', 'origin', repository])
        run(['git', '-C', str(source), 'fetch', '--depth=1', 'origin', commit])
        run(['git', '-C', str(source), 'checkout', '--detach', 'FETCH_HEAD'])

    head = run(['git', '-C', str(source), 'rev-parse', 'HEAD'],
               capture=True).stdout.strip()
    require(head == commit, f'source HEAD {head} != pinned commit {commit}')
    source = source.resolve()

    browser_contract = load_browser_patches(
        patch_lock_path, source, repository, commit)
    deployment_paths = patch_targets(source, deployment_patch, 'deployment patch')
    for relative in deployment_paths:
        contained_target(source, relative, 'deployment patch target')
    browser_files = [entry['sourceFile']
                     for entry in browser_contract['patches']]
    overlap = sorted(set(deployment_paths) & set(browser_files))
    require(not overlap,
            'deployment and browser patches overlap: ' + ', '.join(overlap))
    expected = set(deployment_paths) | set(browser_files)

    staged = run(['git', 'diff', '--cached', '--quiet'], cwd=source,
                 check=False, capture=True)
    require(staged.returncode in (0, 1),
            f'cannot inspect the source index: {staged.stderr.strip()}')
    require(staged.returncode == 0,
            'source index has staged changes; refusing to overwrite them')
    changes = tracked_changes(source)
    require_only_known_changes(changes, expected, 'before preparation')

    deployment_head = {
        relative: head_blob_sha(source, relative)
        for relative in deployment_paths}
    deployment_patched = patched_blob_hashes(
        source, deployment_patch, deployment_paths)
    deployment_states = {}
    for relative in deployment_paths:
        original_sha = deployment_head[relative]
        patched_sha = deployment_patched[relative]
        require(original_sha != patched_sha,
                f'deployment patch does not change {relative}')
        current_sha = sha256(source / relative)
        if current_sha == original_sha:
            deployment_states[relative] = False
        elif current_sha == patched_sha:
            deployment_states[relative] = True
        else:
            raise ValueError(
                f'deployment source {relative} is not in a known state: '
                f'{current_sha} matches neither the pinned original nor the '
                'patched source')
    states = set(deployment_states.values())
    require(len(states) == 1,
            'deployment patch is only partially applied: '
            + ', '.join(sorted(deployment_states)))
    deployment_already_applied = states.pop()
    if deployment_already_applied:
        require(patch_applies(source, deployment_patch, deployment_paths,
                              reverse=True),
                'deployment patch target does not reverse cleanly')
    else:
        require(patch_applies(source, deployment_patch, deployment_paths),
                'deployment patch does not apply cleanly to the pinned source')

    for entry in browser_contract['patches']:
        label = entry['sourceFile']
        target = contained_target(source, label, 'browser patch target')
        head_sha = head_blob_sha(source, label)
        require(entry['originalSourceSHA256'] == head_sha,
                f'{label} originalSourceSHA256 does not match the pinned '
                f'commit blob {head_sha}')
        generated_sha = patched_blob_hashes(
            source, entry['patchFile'], [label])[label]
        require(generated_sha == entry['patchedSourceSHA256'],
                f'{label} patch produces {generated_sha}, but the lock pins '
                f'{entry["patchedSourceSHA256"]}')
        current_sha = sha256(target)
        if current_sha == entry['originalSourceSHA256']:
            entry['alreadyApplied'] = False
            require(patch_applies(source, entry['patchFile'], [label]),
                    f'{label} patch does not apply to the pinned source')
        elif current_sha == entry['patchedSourceSHA256']:
            entry['alreadyApplied'] = True
            require(patch_applies(source, entry['patchFile'], [label],
                                  reverse=True),
                    f'{label} source matches the patched hash but the patch '
                    'does not reverse cleanly')
        else:
            raise ValueError(
                f'{label} source is not in a known state: {current_sha} '
                'matches neither the pinned original nor the patched source')
        entry['verifiedSourceSHA256'] = current_sha

    if not deployment_already_applied:
        apply_patch(source, deployment_patch, deployment_paths)
    for entry in browser_contract['patches']:
        if not entry['alreadyApplied']:
            apply_patch(source, entry['patchFile'], [entry['sourceFile']])

    require(patch_applies(source, deployment_patch, deployment_paths,
                          reverse=True),
            'deployment patch did not apply cleanly')
    deployment_files = []
    for relative in deployment_paths:
        applied_sha = sha256(source / relative)
        require(applied_sha == deployment_patched[relative],
                f'deployment source {relative} patched SHA-256 mismatch: '
                f'{applied_sha} != {deployment_patched[relative]}')
        deployment_files.append({
            'sourceFile': relative,
            'originalSourceSHA256': deployment_head[relative],
            'patchedSourceSHA256': deployment_patched[relative],
            'verifiedSourceSHA256': applied_sha,
            'alreadyApplied': deployment_already_applied,
        })
    for entry in browser_contract['patches']:
        target = contained_target(source, entry['sourceFile'],
                                  'browser patch target')
        applied_sha = sha256(target)
        require(applied_sha == entry['patchedSourceSHA256'],
                f"{entry['sourceFile']} patched SHA-256 mismatch: "
                f"{applied_sha} != {entry['patchedSourceSHA256']}")
        entry['verifiedSourceSHA256'] = applied_sha
        require(patch_applies(source, entry['patchFile'],
                              [entry['sourceFile']], reverse=True),
                f"{entry['sourceFile']} patched source does not reverse cleanly")

    changes = tracked_changes(source)
    require_only_known_changes(changes, expected, 'after preparation')
    require(set(changes) == expected,
            'prepared source does not carry every expected patch: '
            + ', '.join(sorted(expected - set(changes))))

    return {
        'buildRoot': str(build_root),
        'source': str(source),
        'repository': repository,
        'commit': commit,
        'deploymentPatch': str(deployment_patch),
        'deploymentPatchSHA256': patch_sha,
        'deploymentPatchAlreadyApplied': deployment_already_applied,
        'deploymentPatchFiles': deployment_files,
        'browserPatchLock': str(patch_lock_path),
        'browserPatchLockSHA256': browser_contract['sha256'],
        'browserSourcePatches': browser_contract['patches'],
        'pinnedSourceReady': True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build_root', help='Runner scratch build root')
    parser.add_argument('--output', default=None)
    parser.add_argument('--lock', default=None,
                        help='Engine lock (default: pinned engine.lock.json)')
    parser.add_argument('--deployment-patch', default=None,
                        help='Deployment patch (default: pinned patch)')
    parser.add_argument('--patch-lock', default=None,
                        help='Browser patch lock (default: '
                             'engine.patch.lock.json next to --lock)')
    args = parser.parse_args()
    receipt = prepare(args.build_root, lock_path=args.lock,
                      deployment_patch=args.deployment_patch,
                      patch_lock_path=args.patch_lock)
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    if shutil.which('git') is None:
        sys.exit('git is required')
    main()
