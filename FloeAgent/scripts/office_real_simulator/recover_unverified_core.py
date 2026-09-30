#!/usr/bin/env python3
"""Manually convert an explicitly reviewed raw backup through normal gates.

This tool is never called by a runtime or automatic fallback. The operator
supplies the independently retained run/source/hash/size. Extraction is into
the original empty build root, preserving generated absolute build inputs.
No engine configure/build or editor command runs here. A successful conversion
is only a completed-core checkpoint, not an engine or PPT qualification.
"""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import shutil
import subprocess
import sys
import tarfile
import time

from checkpoint_simulator_core import create_checkpoint, sha256_file
from sim_paths import LOCK_PATH, normalize_xcode_version, RESERVE_GIB


def progress(**facts):
    print(json.dumps({'manualCoreRecovery': facts}), file=sys.stderr, flush=True)


def safe_name(name):
    parts = PurePosixPath(name).parts
    if not parts or name.startswith('/') or '..' in parts:
        raise ValueError(f'unsafe archive path: {name}')
    normalized = posixpath.normpath(name)
    if normalized.split('/')[0] not in {
            'source', 'qualification.json', 'qualification-logs'}:
        raise ValueError(f'unexpected archive root: {name}')
    return normalized


def link_target(member, original_root):
    link = member.linkname
    if link.startswith('/'):
        # Only absolute targets under the exact reviewed original build root
        # may become portable. Outside links are quarantined, never followed.
        root = str(original_root).rstrip('/') + '/'
        if not link.startswith(root):
            raise ValueError(f'external link: {member.name} -> {link}')
        target = link[len(root):]
    elif member.islnk():
        target = link
    else:
        target = posixpath.join(posixpath.dirname(member.name), link)
    return safe_name(posixpath.normpath(target))


def inspect_members(members, original_root):
    index = {}
    targets = {}
    for member in members:
        name = safe_name(member.name)
        if name in index:
            raise ValueError(f'duplicate archive member: {name}')
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise ValueError(f'unsupported archive type: {name}')
        index[name] = member
        if member.issym() or member.islnk():
            targets[name] = link_target(member, original_root)
    for name, member in index.items():
        for parent in PurePosixPath(name).parents:
            ancestor = index.get(str(parent))
            if ancestor is not None and not ancestor.isdir():
                raise ValueError(f'archive writes below non-directory: {name}')
        if member.islnk():
            target = index.get(targets[name])
            if target is None or not target.isfile():
                raise ValueError(f'hardlink target is not a regular member: {name}')
    return index, targets


def extract_reviewed(archive, index, targets, destination):
    # Directories and regular files first; links last. No archive.extractall,
    # no write through any link, no overwrite, no special modes/owners.
    completed = 0
    last_report = time.monotonic()
    for name, member in index.items():
        if not (member.isdir() or member.isfile()):
            continue
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if member.isdir():
            path.mkdir(exist_ok=True)
        else:
            with archive.extractfile(member) as source, path.open('xb') as output:
                shutil.copyfileobj(source, output, 1 << 20)
            path.chmod(member.mode & 0o777)
        completed += 1
        if time.monotonic() - last_report >= 60:
            free = shutil.disk_usage(destination).free / 1024**3
            progress(phase='extract', completedEntries=completed,
                     totalEntries=len(index), freeGiB=round(free, 2))
            if free < RESERVE_GIB:
                raise ValueError('recovery stopped at disk reserve')
            last_report = time.monotonic()
    for name, member in index.items():
        if not member.islnk():
            continue
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with (destination / targets[name]).open('rb') as source, path.open('xb') as output:
            shutil.copyfileobj(source, output, 1 << 20)
        path.chmod(member.mode & 0o777)
    for name, member in index.items():
        if not member.issym():
            continue
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(os.path.relpath(destination / targets[name], path.parent))
    # Validate chained links only after all are materialized, before any build
    # input reader runs. A cycle or an escape remains a hard failure.
    for name, member in index.items():
        if member.issym():
            resolved = (destination / name).resolve(strict=False)
            if not resolved.is_relative_to(destination):
                raise ValueError(f'chained link escapes destination: {name}')


def recover(archive_path, record_path, destination, output_dir, *, expect_run,
            expect_source, expect_sha, expect_size, toolchain, runner=None):
    archive_path = Path(archive_path)
    destination = Path(destination).resolve()
    record = json.loads(Path(record_path).read_text())
    lock = json.loads(LOCK_PATH.read_text())
    expected = {
        'checkpointKind': 'unverified-core-recovery-only',
        'reuseAllowed': False, 'restoreRequiresReview': True,
        'nativeBuildPassed': False, 'finalQualification': False,
        'engineBuildCompleted': True, 'workflowRunID': str(expect_run),
        'workflowSourceCommit': expect_source, 'sourceCommit': lock['commit'],
        'archiveSHA256': expect_sha, 'archiveSize': expect_size,
    }
    for key, value in expected.items():
        if record.get(key) != value:
            raise ValueError(f'reviewed backup binding mismatch: {key}')
    for key in ('sdkVersion', 'sdkBuildVersion', 'xcodeVersion'):
        actual = record.get(key)
        if key == 'xcodeVersion':
            actual = normalize_xcode_version(actual or '')
        if not toolchain.get(key) or actual != toolchain[key]:
            raise ValueError(f'backup toolchain mismatch: {key}')
    progress(phase='verify-backup', archiveBytes=archive_path.stat().st_size)
    if archive_path.stat().st_size != expect_size or sha256_file(archive_path) != expect_sha:
        raise ValueError('reviewed archive hash/size mismatch')
    if destination.exists() and any(destination.iterdir()):
        raise ValueError('recovery destination must be empty')
    with tarfile.open(archive_path, 'r:gz') as archive:
        progress(phase='inspect-archive')
        members = []
        last_report = time.monotonic()
        for member in archive:
            members.append(member)
            if time.monotonic() - last_report >= 60:
                progress(phase='inspect-archive', observedEntries=len(members))
                last_report = time.monotonic()
        if len(members) != record.get('fileCount'):
            raise ValueError('raw archive file count mismatch')
        index, targets = inspect_members(members, destination)
        qualification_member = index.get('qualification.json')
        if qualification_member is None or not qualification_member.isfile() or \
                qualification_member.size > 1024 * 1024:
            raise ValueError('invalid embedded qualification file')
        qualification = json.load(archive.extractfile(qualification_member))
        original = Path(qualification['phases']['engine-build']['log']).parent.parent
        if not original.is_absolute() or original != destination:
            raise ValueError('recovery must use the exact original build root')
        for key in ('sdkVersion', 'sdkBuildVersion', 'xcodeVersion'):
            actual = qualification.get(key)
            if key == 'xcodeVersion':
                actual = normalize_xcode_version(actual or '')
            if actual != toolchain[key]:
                raise ValueError(f'embedded qualification mismatch: {key}')
        if qualification.get('commit') != lock['commit'] or \
                qualification.get('platform') != 'iphonesimulator-arm64' or \
                qualification.get('engineBuildCompleted') is not True:
            raise ValueError('embedded qualification source/platform/completion mismatch')
        required = sum(m.size for m in members if m.isfile()) + sum(
            index[targets[name]].size for name, m in index.items() if m.islnk())
        if shutil.disk_usage(destination.parent).free < required + RESERVE_GIB * 1024**3:
            raise ValueError('insufficient recovery disk reserve')
        destination.mkdir(parents=True, exist_ok=True)
        progress(phase='extract', entries=len(index), expandedBytes=required)
        extract_reviewed(archive, index, targets, destination)
    # The normal source/config/linker-input/platform/per-file/whole-tar gates
    # must succeed anew. Never stamp raw recovery data as a ready engine.
    progress(phase='normal-checkpoint-gates')
    checkpoint = create_checkpoint(destination, output_dir, runner=runner)
    receipt = {
        'reviewedRawRunID': str(expect_run), 'reviewedWorkflowSource': expect_source,
        'reviewedRawSHA256': expect_sha, 'reviewedRawSize': expect_size,
        'engineBuildRerun': False, 'editorPhasesExecuted': False,
        'nativeBuildPassed': False, 'finalQualification': False,
        'checkpointSHA256': checkpoint['checkpointSHA256'],
        'checkpointSize': checkpoint['checkpointSize'],
        'omittedOptionalLinks': checkpoint['omittedOptionalLinks'],
        'toolchain': toolchain,
    }
    (Path(output_dir) / 'manual-recovery.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive')
    parser.add_argument('--record', required=True)
    parser.add_argument('--destination', required=True)
    parser.add_argument('--output-dir', required=True)
    parser.add_argument('--expect-run', required=True)
    parser.add_argument('--expect-source', required=True)
    parser.add_argument('--expect-sha', required=True)
    parser.add_argument('--expect-size', type=int, required=True)
    args = parser.parse_args()
    def command(*parts):
        return subprocess.check_output(parts, text=True).strip()
    toolchain = {
        'sdkVersion': command('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'),
        'sdkBuildVersion': command('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-build-version'),
        'xcodeVersion': normalize_xcode_version(command('xcodebuild', '-version')),
    }
    print(json.dumps(recover(args.archive, args.record, args.destination, args.output_dir,
                            expect_run=args.expect_run, expect_source=args.expect_source,
                            expect_sha=args.expect_sha, expect_size=args.expect_size,
                            toolchain=toolchain), indent=2), flush=True)


if __name__ == '__main__':
    main()
