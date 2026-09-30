#!/usr/bin/env python3
"""Pack the completed simulator core at the successful engine-build boundary.

Called by ``office-real-simulator.yml`` immediately after
``build_simulator_engine.py --phases engine`` succeeds and BEFORE
editor-autogen/editor-configure/editor-build run, so a downstream failure
(such as the real run 36704184429 lxml failure) can reuse the ~175 min
core build once its checkpoint upload succeeds. The caller uploads this as
its own Actions artifact and blocks editor work when retention fails.

This is a separate, honest contract -- not ``nativeBuildPassed`` and not a
final qualification:

* engine-build must have completed (``engineBuildCompleted == true``) and the
  record explicitly says ``nativeBuildPassed: false``,
  ``finalQualification: false``, ``editorPhasesExecuted: false``;
* exact source commit / repository / deployment patch, platform
  (iphonesimulator) and arch (arm64), SDK version+build and Xcode version are
  recorded from the build's own preflight/qualification;
* the real ``ios-all-static-libs.list`` produced by the pinned engine (absolute
  runner-root paths plus individual ``.o`` files; consumed by Xcode as
  ``-filelist``) is canonicalized to portable build-root-relative
  ``source/...`` entries inside the tarball, with the untouched original kept
  as ``...list.original`` and both SHA-256 values recorded; compiled archives
  and objects are copied byte-for-byte, never rewritten;
* every canonical entry is checked to exist inside the build root with a
  supported suffix (``.a``/``.o``), an empty or outside-root list is rejected,
  and a bounded sample must prove ``arm64`` + ``IOSSIMULATOR`` before packing;
* a ``core-manifest.json`` with per-file size/SHA-256 and portable relative
  symlinks (never absolute, never escaping the build root) ships inside the
  tarball; ``simulator-core-checkpoint.json`` binds the whole-archive SHA-256,
  size and manifest hash for ``resume_simulator_core.py``.

Only the engine build outputs are packed.  The top-level checkout is
reconstructible from the pin, so a resume re-prepares the pinned source and
overlays this core instead of trusting a runner-local tree.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import time

import engine_manifest
from sim_paths import (CORE_CHECKPOINT_JSON, CORE_CHECKPOINT_KIND,
                       CORE_CHECKPOINT_MANIFEST, CORE_CHECKPOINT_QUALIFICATION,
                       CORE_CHECKPOINT_TAR, EDITOR_CONFIGURE_INPUTS, LOCK_PATH,
                       normalize_xcode_version)
from stage_simulator_engine import archive_simulator_facts, pick_samples

HEADER_SUFFIXES = {'.h', '.hpp', '.hxx', '.inc', '.inl', '.ipp', '.tcc'}
EXCLUDED = {'.git', 'node_modules', '.DS_Store'}
ENGINE_SUBTREES = ('config_host', 'include', 'instdir',
                   'workdir/CustomTarget/ios', 'workdir/UnoApiHeadersTarget')
COPYRIGHT_PATTERNS = ('COPYING*', 'LICENSE*', 'NOTICE*')


class CheckpointError(ValueError):
    pass


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def collect_engine_paths(build_root, extra_paths=(), omitted_optional_links=None):
    """Collect the engine build outputs a resume needs.

    Mirrors the build-input selection that ``package_office_engine.py`` uses
    for the device package (all static archives, generated headers/config,
    instdir resources and the iOS custom target), scoped to ``source/engine``,
    plus every canonical archive/object entry from the real engine manifest.
    Symlinks are recorded relative and must stay inside the build root.
    """
    build_root = Path(build_root).resolve()
    source = build_root / 'source'
    engine = source / 'engine'
    paths = set()
    links = {}
    visited = set()

    def collect(path, headers_only=False):
        if path.name in EXCLUDED:
            return
        if path.is_symlink():
            try:
                target = path.resolve(strict=False)
            except (OSError, RuntimeError) as error:
                raise CheckpointError(f'invalid dependency link: {path}') from error
            if not target.is_relative_to(build_root):
                raise CheckpointError(
                    f'dependency escapes build root: {path.relative_to(build_root)}')
            if not target.exists():
                # UnpackedTarball also includes links for disabled optional
                # dependencies (e.g. zxing -> unbuilt zint/backend). Only the
                # header-only discovery walk may omit such non-header links.
                # Required subtrees, headers, configure and linker inputs stay
                # fail-closed. Record every omission in the hashed manifest.
                if headers_only and path.suffix not in HEADER_SUFFIXES and \
                        target.suffix not in HEADER_SUFFIXES and \
                        not path.name.startswith(('LICENSE', 'COPYING', 'NOTICE')) and \
                        not target.name.startswith(('LICENSE', 'COPYING', 'NOTICE')):
                    if omitted_optional_links is not None:
                        omitted_optional_links.append({
                            'path': str(path.relative_to(build_root)),
                            'target': str(target.relative_to(build_root)),
                            'reason': 'missing optional non-header dependency'})
                    return
                raise CheckpointError(f'required dependency link missing: {path}')
            if headers_only and target.is_file() and \
                    target.suffix not in HEADER_SUFFIXES and \
                    not target.name.startswith(('LICENSE', 'COPYING', 'NOTICE')):
                return
            links[path] = os.path.relpath(target, path.parent)
            paths.add(path)
            if target != engine:
                collect(target, headers_only)
            return
        key = (path, headers_only)
        if key in visited:
            return
        visited.add(key)
        if path.is_dir():
            paths.add(path)
            for child in sorted(path.iterdir()):
                collect(child, headers_only)
        elif path.is_file():
            if not headers_only or path.suffix in HEADER_SUFFIXES or \
                    path.name.startswith(('LICENSE', 'COPYING', 'NOTICE')):
                paths.add(path)

    for subtree in ENGINE_SUBTREES:
        collect(engine / subtree)
    unpacked = engine / 'workdir/UnpackedTarball'
    if unpacked.exists():
        collect(unpacked, headers_only=True)
    for path in sorted(engine.rglob('*.a')):
        collect(path)
    for pattern in COPYRIGHT_PATTERNS:
        for path in sorted(engine.glob(pattern)):
            collect(path)
    # Exact editor-configure inputs, including engine/config_host.mk which
    # lives at the engine root rather than inside config_host/.
    for relative in EDITOR_CONFIGURE_INPUTS:
        collect(build_root / relative)
    for relative in ('source/engine/config_host_lang.mk',):
        path = build_root / relative
        if path.is_file():
            collect(path)
    for path in extra_paths:
        collect(Path(path))
    return paths, links


def _validate_qualification(build_root, lock, qualification):
    failures = []
    if qualification.get('commit') != lock['commit']:
        failures.append(f"qualification commit {qualification.get('commit')} != "
                        f"pinned {lock['commit']}")
    if qualification.get('platform') != 'iphonesimulator-arm64':
        failures.append(f"qualification platform {qualification.get('platform')}")
    phases = qualification.get('phases') or {}
    for name in ('engine-configure', 'engine-build'):
        phase = phases.get(name)
        if not isinstance(phase, dict) or not phase.get('seconds'):
            failures.append(f'engine phase {name} is not recorded as completed')
    if qualification.get('engineBuildCompleted') is not True:
        failures.append('engineBuildCompleted is not true (checkpoint boundary '
                        'is only after a successful engine-build)')
    if qualification.get('nativeBuildPassed') is True:
        failures.append('nativeBuildPassed is already true; a completed-core '
                        'checkpoint is not a final qualification')
    for field in ('sdkVersion', 'sdkBuildVersion', 'xcodeVersion'):
        if not qualification.get(field):
            failures.append(f'qualification {field} is empty')
    return failures


def create_checkpoint(build_root, output_dir, runner=None, toolchain=None):
    build_root = Path(build_root).resolve()
    output_dir = Path(output_dir).resolve()
    qualification_path = build_root / 'qualification.json'
    if not qualification_path.is_file():
        raise CheckpointError(f'qualification.json missing under {build_root}')
    qualification = json.loads(qualification_path.read_text())
    lock = json.loads(LOCK_PATH.read_text())
    failures = _validate_qualification(build_root, lock, qualification)
    if failures:
        raise CheckpointError('not at a completed-engine boundary: '
                              + '; '.join(failures))
    missing_inputs = [relative for relative in EDITOR_CONFIGURE_INPUTS
                      if not (build_root / relative).is_file()]
    if missing_inputs:
        raise CheckpointError(
            'engine build did not produce the top-level editor-configure inputs '
            '(a resume could never run configure): ' + ', '.join(missing_inputs))

    manifest_path = build_root / engine_manifest.ENGINE_LIST_RELATIVE
    if not manifest_path.is_file():
        raise CheckpointError(f'engine archive manifest is missing: {manifest_path}')
    original_bytes = manifest_path.read_bytes()
    original_sha = sha256_bytes(original_bytes)
    try:
        raw_lines = engine_manifest.parse_lines(original_bytes)
        canonical = engine_manifest.canonicalize(build_root, raw_lines)
    except engine_manifest.ManifestError as error:
        raise CheckpointError(f'engine archive manifest is not usable: {error}')
    canonical_bytes = engine_manifest.render(canonical)
    canonical_sha = sha256_bytes(canonical_bytes)
    if not canonical:
        raise CheckpointError('engine archive manifest canonicalized to nothing')
    samples = pick_samples(canonical)
    if not samples:
        raise CheckpointError('no engine static archives to prove before packing')
    sample_results = []
    for name in samples:
        ok, facts = archive_simulator_facts(build_root / name, runner=runner)
        entry = {'archive': name, 'simulatorOnly': ok}
        entry.update(facts if isinstance(facts, dict) else {'reason': facts})
        sample_results.append(entry)
        if not ok:
            raise CheckpointError(f'archive fails platform/arch gate: {name} {facts}')

    if output_dir.exists() and any(output_dir.iterdir()):
        raise CheckpointError(f'checkpoint output directory is not empty: {output_dir}')
    output_dir.mkdir(parents=True, exist_ok=True)

    started = time.time()
    extra_paths = [build_root / line for line in canonical]
    omitted_optional_links = []
    paths, links = collect_engine_paths(build_root, extra_paths=extra_paths,
                                      omitted_optional_links=omitted_optional_links)
    original_member = engine_manifest.ENGINE_LIST_RELATIVE + '.original'
    entries = []
    for path in sorted(paths):
        relative = str(path.relative_to(build_root))
        if relative == engine_manifest.ENGINE_LIST_RELATIVE:
            item = {'path': relative, 'size': len(canonical_bytes),
                    'sha256': canonical_sha}
        elif path in links:
            item = {'path': relative, 'symlink': links[path]}
        elif path.is_dir():
            item = {'path': relative, 'directory': True}
        else:
            item = {'path': relative, 'size': path.stat().st_size,
                    'sha256': sha256_file(path)}
        entries.append(item)
    entries.append({'path': original_member, 'size': len(original_bytes),
                    'sha256': original_sha})
    entries.sort(key=lambda item: item['path'])
    manifest = {
        'formatVersion': 2,
        'checkpointKind': CORE_CHECKPOINT_KIND,
        'sourceCommit': lock['commit'],
        'repository': lock['repository'],
        'deploymentPatchSHA256': lock['sourcePatchSHA256'],
        'platform': 'iphonesimulator',
        'arch': 'arm64',
        'engineArchiveManifest': engine_manifest.ENGINE_LIST_RELATIVE,
        'engineArchiveManifestOriginalSHA256': original_sha,
        'engineArchiveManifestCanonicalSHA256': canonical_sha,
        'engineArchiveCount': len(canonical),
        'engineArchiveUniqueCount': len(set(canonical)),
        'files': entries,
        'omittedOptionalLinks': omitted_optional_links,
    }
    manifest_bytes = json.dumps(manifest, indent=2).encode()
    qualification_bytes = qualification_path.read_bytes()

    archive_path = output_dir / CORE_CHECKPOINT_TAR
    temporary = archive_path.with_suffix('.partial')
    try:
        with tarfile.open(temporary, 'w:gz', compresslevel=1,
                          dereference=False) as archive:
            for name, data in ((CORE_CHECKPOINT_MANIFEST, manifest_bytes),
                               (CORE_CHECKPOINT_QUALIFICATION,
                                qualification_bytes)):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            for path in sorted(paths):
                relative = str(path.relative_to(build_root))
                info = archive.gettarinfo(str(path), arcname=relative)
                if relative == engine_manifest.ENGINE_LIST_RELATIVE:
                    # The canonical form is what a later runner consumes; the
                    # original raw list ships as ...list.original.
                    info.type = tarfile.REGTYPE
                    info.linkname = ''
                    info.size = len(canonical_bytes)
                    archive.addfile(info, io.BytesIO(canonical_bytes))
                elif path in links:
                    info.linkname = links[path]
                    archive.addfile(info)
                elif path.is_dir():
                    archive.addfile(info)
                else:
                    # Materialize hard links too: every hashed file is portable.
                    info.type = tarfile.REGTYPE
                    info.linkname = ''
                    info.size = path.stat().st_size
                    with path.open('rb') as stream:
                        archive.addfile(info, stream)
            info = tarfile.TarInfo(original_member)
            info.size = len(original_bytes)
            archive.addfile(info, io.BytesIO(original_bytes))
        temporary.replace(archive_path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise

    engine_log = build_root / 'qualification-logs/engine-build.log'
    record = {
        'checkpointKind': CORE_CHECKPOINT_KIND,
        'checkpointFormatVersion': 2,
        'checkpointSHA256': sha256_file(archive_path),
        'checkpointSize': archive_path.stat().st_size,
        'coreManifestSHA256': sha256_bytes(manifest_bytes),
        'qualificationSHA256': sha256_bytes(qualification_bytes),
        'sourceCommit': lock['commit'],
        'repository': lock['repository'],
        'deploymentPatchSHA256': lock['sourcePatchSHA256'],
        'platform': 'iphonesimulator',
        'arch': 'arm64',
        'sdkVersion': qualification.get('sdkVersion'),
        'sdkBuildVersion': qualification.get('sdkBuildVersion'),
        'xcodeVersion': normalize_xcode_version(qualification.get('xcodeVersion') or ''),
        'deploymentTarget': '26.0',
        'engineConfigureCompleted': True,
        'engineBuildCompleted': True,
        'engineBuildSeconds': (qualification.get('phases') or {}).get(
            'engine-build', {}).get('seconds'),
        'engineArchiveManifest': engine_manifest.ENGINE_LIST_RELATIVE,
        'engineArchiveManifestOriginalSHA256': original_sha,
        'engineArchiveManifestCanonicalSHA256': canonical_sha,
        'engineArchiveManifestRewrittenSHA256': None,
        'engineArchiveCount': len(canonical),
        'engineArchiveUniqueCount': len(set(canonical)),
        'engineArchiveSuffixes': sorted({Path(line).suffix for line in canonical}),
        'editorConfigureInputs': list(EDITOR_CONFIGURE_INPUTS),
        'editorConfigureInputsPresent': True,
        'engineBuildLogSHA256': sha256_file(engine_log) if engine_log.is_file() else None,
        'platformSampleSize': len(sample_results),
        'platformSamples': sample_results,
        'allSampledObjectsIOSSIMULATOR': all(entry['simulatorOnly']
                                             for entry in sample_results),
        'nativeBuildPassed': False,
        'finalQualification': False,
        'editorPhasesExecuted': False,
        'coreFileCount': len(entries),
        'omittedOptionalLinks': omitted_optional_links,
        'coreFileListSHA256': sha256_bytes(manifest_bytes),
        'checkpointSeconds': round(time.time() - started, 1),
        'createdAtUTC': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'createdBy': 'office_real_simulator.checkpoint_simulator_core',
        'note': 'Completed-core checkpoint at the engine-build boundary; not a '
                'staged engine and not a final qualification. Editor phases have '
                'not run. The engine manifest inside the tarball is the portable '
                'canonical form; the untouched original ships as ...list.original.',
    }
    if toolchain:
        record.update(toolchain)
    (output_dir / CORE_CHECKPOINT_JSON).write_text(
        json.dumps(record, indent=2) + '\n')
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build_root')
    parser.add_argument('--output-dir', required=True)
    args = parser.parse_args()
    try:
        record = create_checkpoint(args.build_root, args.output_dir)
    except CheckpointError as error:
        print(f'CHECKPOINT FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
