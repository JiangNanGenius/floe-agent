#!/usr/bin/env python3
"""Validate and restore a completed-core checkpoint for the simulator build.

A completed-core checkpoint is packed at the successful ``engine-build``
boundary of ``build_simulator_engine.py`` -- before editor-autogen /
editor-configure / editor-build can fail -- and uploaded as its own Actions
artifact by ``office-real-simulator.yml``.  It is deliberately NOT a staged
engine, NOT ``nativeBuildPassed`` and NOT a final qualification: only the
compiled core (static archives, individual ``.o`` inputs, generated headers,
``ios-all-static-libs.list``) plus a per-file SHA-256 manifest are inside.

Restoring is fail-closed and hash/toolchain bound:

* whole-archive SHA-256 and size must equal ``simulator-core-checkpoint.json``;
* the checkpoint record must say ``checkpointKind == engine-build-completed``,
  ``engineBuildCompleted == true``, ``nativeBuildPassed == false``,
  ``finalQualification == false`` and ``editorPhasesExecuted == false``;
* source commit, repository, deployment-patch SHA, platform (iphonesimulator)
  and arch (arm64) must equal the current ``engine.lock.json`` pin;
* SDK version/build and Xcode version must be non-empty and -- because a
  checkpoint is always consumed on another run -- match this runner via
  ``--expect-xcode`` / ``--expect-sdk``;
* the embedded ``core-manifest.json`` hash must match the record, and every
  extracted file is re-hashed/size-checked; links must stay inside the
  destination (they are recreated, never followed);
* the engine archive manifest must still list a non-empty set of ``.a``/``.o``
  inputs and a bounded sample must re-prove ``arm64`` + ``IOSSIMULATOR`` after
  transport.  The portable canonical form inside the checkpoint is verified
  against ``engineArchiveManifestCanonicalSHA256`` and then rewritten to
  destination-absolute paths (Xcode consumes it as ``-filelist``); the raw
  old-runner original is retained as ``...list.original`` and its SHA-256 is
  carried in the resume report.

The destination must already contain the freshly prepared pinned checkout and
must not contain engine build outputs or a previous resume.  The function
never runs engine-configure or engine-build: it writes
``core-checkpoint-restore.json`` with ``engineConfigureRerun: false`` /
``engineBuildRerun: false`` and the driver then plans editor phases only.
"""
import argparse
import hashlib
import json
import posixpath
from pathlib import Path
import sys
import tarfile

import engine_manifest
from sim_paths import (CORE_CHECKPOINT_KIND, CORE_CHECKPOINT_MANIFEST,
                       CORE_CHECKPOINT_QUALIFICATION, CORE_RESUME_REPORT,
                       EDITOR_PHASES, LOCK_PATH, normalize_xcode_version)
from restore_simulator_bundle import artifact_sha256, contained
from stage_simulator_engine import archive_simulator_facts, pick_samples


class CheckpointError(ValueError):
    pass


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def validate_tar_members(members, destination):
    """Refuse absolute/escaping member names, links and hardlinks before extract.

    Python 3.12's ``filter='data'`` does this natively, but the local
    acceptance interpreter is older, so the same rule is enforced here for
    every extraction path.
    """
    failures = []
    names = set()
    for member in members:
        name = member.name
        if name.startswith('/') or posixpath.normpath(name).startswith('..') or \
                posixpath.normpath(name) == '..':
            failures.append(f'archive member escapes destination: {name}')
            continue
        names.add(posixpath.normpath(name))
    for member in members:
        name = posixpath.normpath(member.name)
        if member.issym() or member.islnk():
            link = member.linkname
            if link.startswith('/'):
                failures.append(f'absolute link target: {name} -> {link}')
                continue
            if member.issym():
                resolved = posixpath.normpath(
                    posixpath.join(posixpath.dirname(name), link))
                if resolved.startswith('..'):
                    failures.append(f'symlink escapes destination: {name} -> {link}')
            elif member.islnk() and posixpath.normpath(link) not in names:
                failures.append(f'hardlink target is not in the archive: {name} -> {link}')
    return failures


def verify_checkpoint_record(archive_path, checkpoint, lock, expect_xcode=None,
                             expect_sdk=None, expect_sdk_build=None):
    """Bind the checkpoint archive and its record to the pin and this runner.

    Toolchain identity is SDK version AND SDK build AND Xcode version: an
    equal SDK version with a different build (`xcrun --sdk iphonesimulator
    --show-sdk-build-version`) is a different toolchain and must be rejected.
    """
    failures = []
    archive_path = Path(archive_path)
    actual_sha = artifact_sha256(archive_path)
    if actual_sha != checkpoint.get('checkpointSHA256'):
        failures.append(f"checkpoint SHA-256 {actual_sha} != record "
                        f"{checkpoint.get('checkpointSHA256')}")
    actual_size = archive_path.stat().st_size
    if actual_size != checkpoint.get('checkpointSize'):
        failures.append(f'checkpoint size {actual_size} != record '
                        f'{checkpoint.get("checkpointSize")}')
    if checkpoint.get('checkpointKind') != CORE_CHECKPOINT_KIND:
        failures.append(f"checkpoint kind {checkpoint.get('checkpointKind')!r} "
                        f"!= {CORE_CHECKPOINT_KIND!r}")
    if checkpoint.get('engineBuildCompleted') is not True:
        failures.append('record does not mark engineBuildCompleted true')
    if checkpoint.get('nativeBuildPassed') is not False:
        failures.append('record claims nativeBuildPassed; a checkpoint is not a '
                        'qualified build')
    if checkpoint.get('finalQualification') is not False:
        failures.append('record claims a final qualification')
    if checkpoint.get('editorPhasesExecuted') is not False:
        failures.append('record claims editor phases were executed')
    if checkpoint.get('sourceCommit') != lock['commit']:
        failures.append(f"checkpoint source {checkpoint.get('sourceCommit')} != "
                        f"pinned {lock['commit']}")
    if checkpoint.get('repository') != lock['repository']:
        failures.append(f"checkpoint repository {checkpoint.get('repository')} != "
                        f"{lock['repository']}")
    if checkpoint.get('deploymentPatchSHA256') != lock['sourcePatchSHA256']:
        failures.append('checkpoint deployment patch SHA != lock sourcePatchSHA256')
    if checkpoint.get('platform') != 'iphonesimulator':
        failures.append(f"checkpoint platform {checkpoint.get('platform')}")
    if checkpoint.get('arch') != 'arm64':
        failures.append(f"checkpoint arch {checkpoint.get('arch')}")
    for field in ('sdkVersion', 'sdkBuildVersion', 'xcodeVersion'):
        if not checkpoint.get(field):
            failures.append(f'checkpoint {field} is empty')
    if expect_xcode and normalize_xcode_version(
            checkpoint.get('xcodeVersion') or '') != normalize_xcode_version(expect_xcode):
        failures.append(f"checkpoint Xcode {checkpoint.get('xcodeVersion')!r} != "
                        f"current runner {expect_xcode!r}")
    if expect_sdk and checkpoint.get('sdkVersion') != expect_sdk:
        failures.append(f"checkpoint SDK {checkpoint.get('sdkVersion')!r} != "
                        f"current runner {expect_sdk!r}")
    if expect_sdk_build and checkpoint.get('sdkBuildVersion') != expect_sdk_build:
        failures.append(f"checkpoint SDK build {checkpoint.get('sdkBuildVersion')!r} != "
                        f"current runner {expect_sdk_build!r}")
    if not checkpoint.get('coreManifestSHA256'):
        failures.append('checkpoint coreManifestSHA256 is empty')
    if not checkpoint.get('engineArchiveManifestOriginalSHA256'):
        failures.append('checkpoint engineArchiveManifestOriginalSHA256 is empty')
    if not checkpoint.get('engineArchiveManifestCanonicalSHA256'):
        failures.append('checkpoint engineArchiveManifestCanonicalSHA256 is empty')
    return failures


def verify_manifest_entries(destination, manifest):
    """Re-hash every extracted entry; links are checked lexically, not followed."""
    failures = []
    for entry in manifest.get('files', []):
        name = entry.get('path')
        if not name:
            failures.append('manifest entry without path')
            continue
        try:
            path = contained(destination, name)
        except ValueError as error:
            failures.append(str(error))
            continue
        if 'symlink' in entry:
            if not path.is_symlink() or path.readlink().as_posix() != entry['symlink']:
                failures.append(f'symlink mismatch: {name}')
        elif entry.get('directory'):
            if not path.is_dir():
                failures.append(f'missing directory: {name}')
        else:
            if not path.is_file():
                failures.append(f'missing file: {name}')
                continue
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if digest != entry.get('sha256') or path.stat().st_size != entry.get('size'):
                failures.append(f'hash/size mismatch: {name}')
    return failures


def _load_checkpoint_json(checkpoint_path):
    checkpoint_path = Path(checkpoint_path)
    if not checkpoint_path.is_file():
        raise CheckpointError(f'checkpoint record missing: {checkpoint_path}')
    try:
        return json.loads(checkpoint_path.read_text())
    except ValueError as error:
        raise CheckpointError(f'checkpoint record is not JSON: {error}')


def restore_checkpoint(archive_path, checkpoint_path, build_root,
                       expect_xcode=None, expect_sdk=None,
                       expect_sdk_build=None, runner=None):
    if not (expect_xcode and expect_sdk and expect_sdk_build):
        raise CheckpointError(
            'toolchain identity requires --expect-xcode, --expect-sdk AND '
            '--expect-sdk-build; a checkpoint is never restored without the '
            'exact SDK build identity')
    archive_path = Path(archive_path).resolve()
    build_root = Path(build_root).resolve()
    source = build_root / 'source'
    if not (source / 'engine/configure.ac').is_file():
        raise CheckpointError(
            f'prepared pinned checkout missing under {source}; restore the source '
            'before overlaying a completed-core checkpoint')
    if (build_root / CORE_RESUME_REPORT).exists():
        raise CheckpointError('this build root is already resumed from a checkpoint')
    if (build_root / 'qualification.json').exists():
        raise CheckpointError('qualification.json already exists; refusing to '
                              'overwrite an in-progress build root')
    if (build_root / engine_manifest.ENGINE_LIST_RELATIVE).exists():
        raise CheckpointError('engine build outputs already present; refusing to '
                              'overlay a checkpoint onto a partially built root')

    checkpoint = _load_checkpoint_json(checkpoint_path)
    lock = json.loads(LOCK_PATH.read_text())
    failures = verify_checkpoint_record(archive_path, checkpoint, lock,
                                        expect_xcode, expect_sdk, expect_sdk_build)
    if failures:
        raise CheckpointError('checkpoint binding failed: ' + '; '.join(failures))

    qualification = None
    manifest = None
    manifest_sha = None
    with tarfile.open(archive_path) as archive:
        members = archive.getmembers()
        member_failures = validate_tar_members(members, build_root)
        if member_failures:
            raise CheckpointError('unsafe checkpoint archive: '
                                  + '; '.join(member_failures[:5]))
        names = {member.name for member in members}
        if CORE_CHECKPOINT_MANIFEST not in names:
            raise CheckpointError('checkpoint has no core-manifest.json')
        manifest_bytes = archive.extractfile(CORE_CHECKPOINT_MANIFEST).read()
        manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
        if manifest_sha != checkpoint.get('coreManifestSHA256'):
            raise CheckpointError(
                f'core manifest SHA-256 {manifest_sha} != record '
                f'{checkpoint.get("coreManifestSHA256")}')
        manifest = json.loads(manifest_bytes)
        if CORE_CHECKPOINT_QUALIFICATION in names:
            qualification = json.loads(
                archive.extractfile(CORE_CHECKPOINT_QUALIFICATION).read())
        if sys.version_info >= (3, 12):
            archive.extractall(build_root, filter='data')
        else:  # Python 3.11 and older (e.g. the local acceptance interpreter)
            archive.extractall(build_root)

    failures = []
    if manifest.get('checkpointKind') != CORE_CHECKPOINT_KIND:
        failures.append(f"manifest kind {manifest.get('checkpointKind')!r}")
    if manifest.get('sourceCommit') != lock['commit']:
        failures.append(f"manifest source {manifest.get('sourceCommit')} != "
                        f"pinned {lock['commit']}")
    if manifest.get('engineArchiveManifest') != engine_manifest.ENGINE_LIST_RELATIVE:
        failures.append('manifest engine archive path mismatch')
    failures.extend(verify_manifest_entries(build_root, manifest))
    if failures:
        raise CheckpointError('restore verification failed: ' + '; '.join(failures[:10]))

    manifest_path = build_root / engine_manifest.ENGINE_LIST_RELATIVE
    if not manifest_path.is_file():
        raise CheckpointError('restored engine archive manifest is missing')
    restored_bytes = manifest_path.read_bytes()
    canonical_sha = hashlib.sha256(restored_bytes).hexdigest()
    if canonical_sha != checkpoint.get('engineArchiveManifestCanonicalSHA256'):
        raise CheckpointError(
            f'canonical engine manifest SHA-256 {canonical_sha} != record '
            f'{checkpoint.get("engineArchiveManifestCanonicalSHA256")}')
    try:
        canonical_lines = engine_manifest.canonicalize(
            build_root, engine_manifest.parse_lines(restored_bytes))
    except engine_manifest.ManifestError as error:
        raise CheckpointError(f'restored engine manifest is not usable: {error}')
    if any(Path(line).is_absolute() for line in
           engine_manifest.parse_lines(restored_bytes)):
        raise CheckpointError('restored engine manifest is not the canonical '
                              'portable form (absolute entries)')
    # Xcode consumes the list as -filelist; make every entry valid on THIS
    # runner. The canonical (portable) hash was verified just above and the
    # raw old-runner original ships as ...list.original.
    rewritten = [str((build_root / line).resolve()) for line in canonical_lines]
    manifest_path.write_bytes(engine_manifest.render(rewritten))
    rewritten_sha = sha256_file(manifest_path)

    samples = pick_samples(canonical_lines)
    if not samples:
        raise CheckpointError('no engine static archives to re-prove after restore')
    sample_results = []
    for name in samples:
        archive = (build_root / name).resolve()
        ok, facts = archive_simulator_facts(archive, runner=runner)
        entry = {'archive': name, 'simulatorOnly': ok}
        entry.update(facts if isinstance(facts, dict) else {'reason': facts})
        sample_results.append(entry)
        if not ok:
            raise CheckpointError(
                f'restored archive fails platform/arch gate: {name} {facts}')

    report = {
        'checkpointKind': CORE_CHECKPOINT_KIND,
        'checkpointSHA256': checkpoint.get('checkpointSHA256'),
        'checkpointSize': checkpoint.get('checkpointSize'),
        'archive': str(archive_path),
        'sourceCommit': lock['commit'],
        'repository': lock['repository'],
        'deploymentPatchSHA256': lock['sourcePatchSHA256'],
        'platform': 'iphonesimulator',
        'arch': 'arm64',
        'sdkVersion': checkpoint.get('sdkVersion'),
        'sdkBuildVersion': checkpoint.get('sdkBuildVersion'),
        'xcodeVersion': checkpoint.get('xcodeVersion'),
        'expectXcode': expect_xcode,
        'expectSDK': expect_sdk,
        'expectSDKBuild': expect_sdk_build,
        'toolchainVerified': bool(expect_xcode and expect_sdk and expect_sdk_build),
        'coreManifestVerified': True,
        'engineBuildCompleted': True,
        'engineArchiveManifest': engine_manifest.ENGINE_LIST_RELATIVE,
        'engineArchiveManifestOriginalSHA256': checkpoint.get(
            'engineArchiveManifestOriginalSHA256'),
        'engineArchiveManifestCanonicalSHA256': canonical_sha,
        'engineArchiveManifestRewrittenSHA256': rewritten_sha,
        'engineArchiveManifestRewrittenRoot': str(build_root),
        'manifestRewritten': True,
        'engineArchiveCount': len(canonical_lines),
        'engineArchiveSuffixes': sorted({Path(line).suffix
                                         for line in canonical_lines}),
        'engineConfigureRerun': False,
        'engineBuildRerun': False,
        'editorPhasesOnly': True,
        'resumePhases': list(EDITOR_PHASES),
        'restoredFiles': len(manifest.get('files', [])),
        'platformSampleSize': len(sample_results),
        'platformSamples': sample_results,
        'allSampledObjectsIOSSIMULATOR': True,
        'nativeBuildPassed': False,
        'finalQualification': False,
        'note': 'Completed core restored over a fresh pinned checkout; engine '
                'configure/build are never re-run by this contract. The engine '
                'manifest was canonicalized and rewritten for this runner.',
    }
    (build_root / CORE_RESUME_REPORT).write_text(json.dumps(report, indent=2) + '\n')

    resume_qualification = dict(qualification or {})
    resume_qualification.update({
        'commit': lock['commit'],
        'platform': 'iphonesimulator-arm64',
        'engineBuildCompleted': True,
        'nativeBuildPassed': False,
        'coreCheckpoint': {
            'checkpointKind': CORE_CHECKPOINT_KIND,
            'checkpointSHA256': checkpoint.get('checkpointSHA256'),
            'sourceCommit': lock['commit'],
            'engineArchiveManifestOriginalSHA256': checkpoint.get(
                'engineArchiveManifestOriginalSHA256'),
            'engineArchiveManifestCanonicalSHA256': canonical_sha,
            'engineArchiveManifestRewrittenSHA256': rewritten_sha,
        },
        'resumedFromCheckpoint': True,
        'enginePhasesRerun': False,
        'phasePlan': list(EDITOR_PHASES),
    })
    (build_root / 'qualification.json').write_text(
        json.dumps(resume_qualification, indent=2) + '\n')
    return report


def load_resume_report(build_root):
    """Return the validated resume report, or None when this root is not resumed.

    Raises CheckpointError when a report exists but does not prove the resume
    contract, so the build driver can never silently fall back to rebuilding
    the core.
    """
    path = Path(build_root) / CORE_RESUME_REPORT
    if not path.is_file():
        return None
    try:
        report = json.loads(path.read_text())
    except ValueError as error:
        raise CheckpointError(f'{CORE_RESUME_REPORT} is not JSON: {error}')
    lock = json.loads(LOCK_PATH.read_text())
    failures = []
    if report.get('checkpointKind') != CORE_CHECKPOINT_KIND:
        failures.append(f"kind {report.get('checkpointKind')!r}")
    if report.get('engineConfigureRerun') is not False:
        failures.append('engineConfigureRerun is not false')
    if report.get('engineBuildRerun') is not False:
        failures.append('engineBuildRerun is not false')
    if report.get('editorPhasesOnly') is not True:
        failures.append('editorPhasesOnly is not true')
    if report.get('toolchainVerified') is not True:
        failures.append('toolchainVerified is not true')
    if report.get('coreManifestVerified') is not True:
        failures.append('coreManifestVerified is not true')
    if report.get('engineBuildCompleted') is not True:
        failures.append('engineBuildCompleted is not true')
    if report.get('manifestRewritten') is not True:
        failures.append('manifestRewritten is not true')
    if report.get('sourceCommit') != lock['commit']:
        failures.append(f"sourceCommit {report.get('sourceCommit')} != pinned "
                        f"{lock['commit']}")
    if report.get('platform') != 'iphonesimulator' or report.get('arch') != 'arm64':
        failures.append('platform/arch mismatch')
    manifest_path = Path(build_root) / engine_manifest.ENGINE_LIST_RELATIVE
    rewritten_sha = report.get('engineArchiveManifestRewrittenSHA256')
    if not rewritten_sha:
        failures.append('engineArchiveManifestRewrittenSHA256 is empty')
    elif not manifest_path.is_file() or sha256_file(manifest_path) != rewritten_sha:
        failures.append('rewritten engine manifest is missing or changed on disk')
    if failures:
        raise CheckpointError(
            f'{CORE_RESUME_REPORT} does not satisfy the resume contract: '
            + '; '.join(failures))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive')
    parser.add_argument('checkpoint')
    parser.add_argument('build_root')
    parser.add_argument('--expect-xcode', required=True)
    parser.add_argument('--expect-sdk', required=True)
    parser.add_argument('--expect-sdk-build', required=True,
                        help='xcrun --sdk iphonesimulator --show-sdk-build-version')
    parser.add_argument('--output', default=None)
    args = parser.parse_args()
    try:
        report = restore_checkpoint(args.archive, args.checkpoint, args.build_root,
                                    args.expect_xcode, args.expect_sdk,
                                    args.expect_sdk_build)
    except CheckpointError as error:
        print(f'CHECKPOINT RESTORE FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
