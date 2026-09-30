#!/usr/bin/env python3
"""Restore a staged simulator package into a fresh runtime workspace.

Every regular entry is checked against the packager manifest SHA-256; symlinks
are recreated from the manifest (never followed) and must stay inside the
destination.  The archive must be bound to the immutable pin before use:

* whole-artifact SHA-256 must equal ``simulator-provenance.json``
  artifactSHA256/artifactSize retained from the build stage;
* provenance/manifest sourceCommit must equal the current
  ``engine.lock.json`` commit, repository and deployment-patch SHA-256 must
  match the lock, platform must be iphonesimulator and arch arm64;
* the toolchain identity recorded in provenance (SDK version/build and Xcode
  version) must match the qualification record embedded in the tarball; with
  ``--reuse`` it must also match the current runner (``--expect-xcode`` /
  ``--expect-sdk``) so a reused artifact can never silently come from a
  different toolchain or source;
* the platform/architecture gate is re-run on a non-empty deterministic sample
  of the restored archives, so transport or re-extraction can never silently
  substitute device or x86_64 objects.

The destination must be new: previous bundles and artifacts are preserved.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tarfile

import engine_manifest
from sim_paths import LOCK_PATH
from stage_simulator_engine import archive_simulator_facts, pick_samples


class RestoreError(ValueError):
    pass


def contained(base, name):
    # Validate the resolved target while retaining the lexical link path for
    # is_symlink/readlink. Returning resolve() loses every valid symlink.
    path = base / name
    if not path.resolve().is_relative_to(base.resolve()):
        raise RestoreError(f'path escapes destination: {name}')
    return path


def artifact_sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def verify_provenance(archive_path, provenance, lock):
    """Bind the staged tarball and its provenance to the current pin."""
    failures = []
    archive_path = Path(archive_path)
    actual_sha = artifact_sha256(archive_path)
    if actual_sha != provenance.get('artifactSHA256'):
        failures.append(
            f"artifact SHA-256 {actual_sha} != provenance "
            f"{provenance.get('artifactSHA256')}")
    actual_size = archive_path.stat().st_size
    if actual_size != provenance.get('artifactSize'):
        failures.append(
            f'artifact size {actual_size} != provenance '
            f'{provenance.get("artifactSize")}')
    if provenance.get('sourceCommit') != lock['commit']:
        failures.append(
            f"provenance source {provenance.get('sourceCommit')} != pinned "
            f"{lock['commit']}")
    if provenance.get('repository') != lock['repository']:
        failures.append(
            f"provenance repository {provenance.get('repository')} != "
            f"{lock['repository']}")
    if provenance.get('deploymentPatchSHA256') != lock['sourcePatchSHA256']:
        failures.append('provenance deployment patch SHA != lock sourcePatchSHA256')
    if provenance.get('platform') != 'iphonesimulator':
        failures.append(f"provenance platform {provenance.get('platform')}")
    if provenance.get('arch') != 'arm64':
        failures.append(f"provenance arch {provenance.get('arch')}")
    for field in ('sdkVersion', 'sdkBuildVersion', 'xcodeVersion',
                  'deploymentTarget'):
        if not provenance.get(field):
            failures.append(f'provenance {field} is empty')
    if provenance.get('platformSampleSize', 0) < 1:
        failures.append('provenance platform sample is empty')
    if not provenance.get('allSampledObjectsIOSSIMULATOR'):
        failures.append('provenance does not claim all sampled objects IOSSIMULATOR')
    return failures


def verify_embedded_qualification(qualification, provenance, lock):
    failures = []
    if qualification.get('commit') != lock['commit']:
        failures.append(
            f"embedded qualification commit {qualification.get('commit')} != "
            f"pinned {lock['commit']}")
    for field in ('sdkVersion', 'sdkBuildVersion', 'xcodeVersion'):
        if qualification.get(field) != provenance.get(field):
            failures.append(
                f'embedded qualification {field} {qualification.get(field)!r} '
                f'!= provenance {provenance.get(field)!r}')
    return failures


def verify_current_toolchain(provenance, expect_xcode=None, expect_sdk=None):
    from sim_paths import normalize_xcode_version
    failures = []
    if expect_xcode and normalize_xcode_version(provenance.get('xcodeVersion') or '') != normalize_xcode_version(expect_xcode):
        failures.append(
            f"reused artifact Xcode {provenance.get('xcodeVersion')!r} != "
            f"current runner {expect_xcode!r}")
    if expect_sdk and provenance.get('sdkVersion') != expect_sdk:
        failures.append(
            f"reused artifact SDK {provenance.get('sdkVersion')!r} != "
            f"current runner {expect_sdk!r}")
    return failures


def restore(archive_path, destination, provenance_path=None, reuse=False,
            expect_xcode=None, expect_sdk=None):
    archive_path = Path(archive_path).resolve()
    destination = Path(destination).resolve()
    if destination.exists():
        raise RestoreError(f'destination exists; refusing to overwrite {destination}')

    provenance = None
    if provenance_path is not None:
        provenance = json.loads(Path(provenance_path).read_text())
        lock = json.loads(LOCK_PATH.read_text())
        failures = verify_provenance(archive_path, provenance, lock)
        if failures:
            raise RestoreError('provenance binding failed: ' + '; '.join(failures))
        if reuse:
            failures = verify_current_toolchain(provenance, expect_xcode, expect_sdk)
            if failures:
                raise RestoreError('toolchain identity failed: ' + '; '.join(failures))
    else:
        lock = json.loads(LOCK_PATH.read_text())

    destination.mkdir(parents=True)
    qualification = {}
    with tarfile.open(archive_path) as archive:
        members = archive.getmembers()
        names = {member.name for member in members}
        if 'bundle-manifest.json' not in names:
            raise RestoreError('package has no bundle-manifest.json')
        manifest_file = archive.extractfile('bundle-manifest.json')
        manifest = json.loads(manifest_file.read())
        if 'qualification.json' in names:
            qualification = json.loads(archive.extractfile('qualification.json').read())
        if sys.version_info >= (3, 12):
            archive.extractall(destination, filter='data')
        else:  # Python 3.11 and older (e.g. the local acceptance interpreter)
            archive.extractall(destination)

    failures = []
    if manifest.get('sourceCommit') != lock['commit']:
        failures.append(
            f"manifest source {manifest.get('sourceCommit')} != pinned "
            f"{lock['commit']}")
    if provenance is not None:
        if manifest.get('sourceCommit') != provenance.get('sourceCommit'):
            failures.append('manifest sourceCommit != provenance sourceCommit')
        failures.extend(verify_embedded_qualification(qualification, provenance, lock))
    if failures:
        raise RestoreError('source/pin binding failed: ' + '; '.join(failures))

    failures = []
    for entry in manifest['files']:
        name = entry['path']
        path = contained(destination, name)
        if 'symlink' in entry:
            if not path.is_symlink() or os.readlink(path) != entry['symlink']:
                failures.append(f'symlink mismatch: {name}')
        elif entry.get('directory'):
            if not path.is_dir():
                failures.append(f'missing directory: {name}')
        else:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if digest != entry['sha256'] or path.stat().st_size != entry['size']:
                failures.append(f'hash/size mismatch: {name}')
    if failures:
        raise RestoreError('restore verification failed: ' + '; '.join(failures[:10]))

    # Re-prove platform and architecture after transport.
    samples = pick_samples(manifest.get('linkerArchives', []))
    if not samples:
        raise RestoreError(
            'restored manifest has no linker archives; refusing to claim a '
            'verified simulator engine')
    sample_results = []
    for name in samples:
        relative = Path(name).relative_to('source') if name.startswith('source/') \
            else Path(name)
        archive = destination / 'source' / relative
        ok, facts = archive_simulator_facts(archive)
        entry = {'archive': name, 'simulatorOnly': ok}
        entry.update(facts if isinstance(facts, dict) else {'reason': facts})
        sample_results.append(entry)
        if not ok:
            raise RestoreError(f'restored archive fails platform/arch gate: {name} {facts}')

    # The upstream engine manifest is consumed by ios/Mobile.xcodeproj as
    # ``-filelist`` and normally carries build-runner-absolute paths plus .o
    # inputs.  A restore into a different root must make it point at this
    # destination; the packaged 1:1 linkerInputs order is authoritative when
    # present, otherwise entries are resolved relative to the destination.
    # Verification (hashes above) happens first; the rewrite is recorded.
    engine_list = destination / engine_manifest.ENGINE_LIST_RELATIVE
    manifest_rewrite = {'present': False}
    if engine_list.is_file():
        original_bytes = engine_list.read_bytes()
        try:
            rewritten_bytes, evidence = engine_manifest.rewrite_for_destination(
                destination, original_bytes, manifest.get('linkerInputs'))
        except engine_manifest.ManifestError as error:
            raise RestoreError(f'engine archive manifest is not portable: {error}')
        engine_list.write_bytes(rewritten_bytes)
        manifest_rewrite = {
            'present': True,
            'originalSHA256': hashlib.sha256(original_bytes).hexdigest(),
            'rewrittenSHA256': hashlib.sha256(rewritten_bytes).hexdigest(),
            'rewrittenRoot': str(destination),
            **evidence,
        }

    report = {
        'archive': str(archive_path),
        'destination': str(destination),
        'sourceCommit': manifest['sourceCommit'],
        'restoredEntries': len(manifest['files']),
        'linkerInputs': len(manifest['linkerInputs']),
        'platformSamples': sample_results,
        'platformSampleSize': len(sample_results),
        'allSampledObjectsIOSSIMULATOR': True,
        'restoreVerified': True,
        'provenanceBound': provenance is not None,
        'provenanceArtifactSHA256': provenance.get('artifactSHA256') if provenance else None,
        'provenanceXcodeVersion': provenance.get('xcodeVersion') if provenance else None,
        'provenanceSDKVersion': provenance.get('sdkVersion') if provenance else None,
        'reusedRun': bool(reuse),
        'hostKind': 'upstream-mobile-host-only',
        'engineArchiveManifestRewrite': manifest_rewrite,
    }
    (destination / 'restore-report.json').write_text(
        json.dumps(report, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive')
    parser.add_argument('destination')
    parser.add_argument('--provenance', default=None,
                        help='Retained build-stage simulator-provenance.json')
    parser.add_argument('--reuse', action='store_true',
                        help='Artifact came from a previous run; enforce toolchain identity')
    parser.add_argument('--expect-xcode', default=None)
    parser.add_argument('--expect-sdk', default=None)
    args = parser.parse_args()
    try:
        report = restore(args.archive, args.destination, args.provenance,
                         args.reuse, args.expect_xcode, args.expect_sdk)
    except RestoreError as error:
        print(f'RESTORE FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
