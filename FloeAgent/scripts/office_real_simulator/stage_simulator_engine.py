#!/usr/bin/env python3
"""Package the simulator build and prove its platform before it is reused.

Reuses the proven generic packager (scripts/package_office_engine.py, read-only
import), then adds the gates a simulator qualification cannot skip:

* architecture: ``lipo -archs`` must report exactly ``arm64`` for every sampled
  archive and for a bounded deterministic sample of its object members;
* platform: ``vtool -show-build`` cannot read ``.a`` archives (it errors with
  "file is not mach-o"), so members are extracted with ``ar x`` first and every
  sampled member must report platform ``IOSSIMULATOR`` only;
* an empty linker-archive list is an error: a build that produced nothing to
  link must never be staged with an "all sampled objects are simulator" claim;
* record source commit, deployment patch SHA, SDK version/build, Xcode version
  and the packager manifest, bound to the current engine.lock.json pin;
* hash the final tarball so a runtime job can prove it reused this exact file.

The heavy artifact is staged once; runtime retries download this same file.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from sim_paths import LOCK_PATH

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))

import package_office_engine  # noqa: E402

ARTIFACT_NAME = 'office-engine-iphonesimulator-arm64.tar.gz'
SAMPLE_SIZE = 12
MEMBER_SAMPLE_SIZE = 5


def sha256(path):
    return package_office_engine.digest(Path(path))


def run_tool(command, cwd=None):
    """Run one tool, returning (returncode, combined output). Injectable in tests."""
    result = subprocess.run([str(item) for item in command], cwd=cwd,
                            capture_output=True, text=True)
    return result.returncode, (result.stdout or '') + (result.stderr or '')


def _member_sample(members):
    names = sorted(name for name in members
                   if name.endswith('.o') and not name.startswith('__.SYMDEF'))
    if not names:
        return []
    indexes = sorted({0, len(names) // 4, len(names) // 2,
                      3 * len(names) // 4, len(names) - 1})
    return [names[index] for index in indexes][:MEMBER_SAMPLE_SIZE]


def archive_simulator_facts(path, runner=None):
    """Prove one static archive is arm64/IOSSIMULATOR only.

    Returns ``(ok, facts)``; facts is a dict on success and a reason string on
    failure so a caller can surface the exact blocker.
    """
    # Checkpoint creation and restore explicitly pass their optional runner.
    # The CLI supplies None; resolve it here instead of calling it as a tool.
    runner = run_tool if runner is None else runner
    archive = Path(path).resolve()
    if not archive.is_file():
        return False, f'archive missing: {archive}'
    code, output = runner(['lipo', '-archs', str(archive)])
    if code != 0:
        return False, f'lipo -archs failed: {output.strip()[:200]}'
    archive_archs = output.split()
    if archive_archs != ['arm64']:
        return False, f'archive architectures {archive_archs} != [arm64]'

    with tempfile.TemporaryDirectory(prefix='office-arch-') as tmp:
        code, output = runner(['ar', 'x', str(archive)], cwd=tmp)
        if code != 0:
            return False, f'ar x failed: {output.strip()[:200]}'
        members = [name for name in sorted(Path(tmp).iterdir())
                   if name.is_file()]
        sample = _member_sample([name.name for name in members])
        if not sample:
            return False, 'archive has no object members to verify'
        member_facts = []
        for name in sample:
            member = Path(tmp) / name
            code, output = runner(['vtool', '-show-build', str(member)])
            if code != 0:
                return False, f'vtool failed on {name}: {output.strip()[:200]}'
            platforms = sorted({line.split()[1].upper()
                                for line in output.splitlines()
                                if line.strip().startswith('platform ')
                                and len(line.split()) > 1})
            if not platforms:
                return False, f'no LC_BUILD_VERSION in {name}'
            if set(platforms) - {'IOSSIMULATOR'}:
                return False, f'{name} platforms {platforms}'
            code, output = runner(['lipo', '-archs', str(member)])
            member_archs = output.split()
            if member_archs != ['arm64']:
                return False, f'{name} architectures {member_archs} != [arm64]'
            member_facts.append({'member': name, 'platforms': platforms,
                                 'architectures': member_archs})
    return True, {
        'archiveArchitectures': archive_archs,
        'memberSampleCount': len(member_facts),
        'memberSamples': member_facts,
        'simulatorOnly': True,
    }


# Backwards-compatible name used by the restore path.
def archive_objects_are_simulator(path, runner=run_tool):
    return archive_simulator_facts(path, runner=runner)


def pick_samples(linker_archives):
    archives = [name for name in linker_archives if name.endswith('.a')]
    if not archives:
        return []
    wanted = set()
    indexes = sorted({0, len(archives) - 1, len(archives) // 4,
                      len(archives) // 2, 3 * len(archives) // 4})
    for index in indexes:
        wanted.add(archives[index])
    keywords = ('libsc', 'libsd', 'liboox', 'libvcl', 'libsvx', 'libsfx')
    for keyword in keywords:
        hit = next((name for name in archives if Path(name).name.startswith(keyword)),
                   None)
        if hit:
            wanted.add(hit)
    samples = sorted(wanted)[:SAMPLE_SIZE]
    return samples


def archive_path_for(source_root, manifest_name):
    source_root = Path(source_root)
    if manifest_name.startswith('source/'):
        return source_root / Path(manifest_name).relative_to('source')
    return source_root / manifest_name


def stage(build_root):
    build_root = Path(build_root).resolve()
    # Generic packager writes source/relative layout and the hardcoded name.
    manifest = package_office_engine.package(build_root)
    packed = build_root / 'office-engine-ios-arm64.tar.gz'
    destination = build_root / ARTIFACT_NAME
    packed.replace(destination)

    lock = json.loads(LOCK_PATH.read_text())
    if manifest['sourceCommit'] != lock['commit']:
        raise RuntimeError(
            f"packaged source {manifest['sourceCommit']} != pinned "
            f"{lock['commit']}")

    samples = pick_samples(manifest.get('linkerArchives', []))
    if not samples:
        raise RuntimeError(
            'linker archive list is empty; refusing to stage an unverifiable '
            'engine (allSampledObjectsIOSSIMULATOR must never be vacuously true)')
    sample_results = []
    bad = []
    source_root = build_root / 'source'
    for name in samples:
        archive = archive_path_for(source_root, name)
        ok, facts = archive_simulator_facts(archive)
        entry = {'archive': name, 'simulatorOnly': ok}
        entry['arm64Only'] = bool(ok)
        entry.update(facts if isinstance(facts, dict) else {'reason': facts})
        sample_results.append(entry)
        if not ok:
            bad.append((name, facts))
    if bad:
        raise RuntimeError(f'non-simulator or non-arm64 objects found: {bad[:3]}')

    qualification = json.loads((build_root / 'qualification.json').read_text())
    if qualification.get('commit') != lock['commit']:
        raise RuntimeError(
            f"qualification commit {qualification.get('commit')} != pinned "
            f"{lock['commit']}")
    provenance = {
        'artifact': ARTIFACT_NAME,
        'artifactSHA256': sha256(destination),
        'artifactSize': destination.stat().st_size,
        'sourceCommit': qualification['commit'],
        'repository': lock['repository'],
        'platform': 'iphonesimulator',
        'arch': 'arm64',
        'sdkVersion': qualification.get('sdkVersion'),
        'sdkBuildVersion': qualification.get('sdkBuildVersion'),
        'xcodeVersion': qualification.get('xcodeVersion'),
        'deploymentTarget': '26.0',
        'deploymentPatchSHA256': lock['sourcePatchSHA256'],
        'manifestEntryCount': len(manifest['files']),
        'linkerInputCount': len(manifest['linkerInputs']),
        'platformSampleSize': len(sample_results),
        'platformSamples': sample_results,
        'allSampledObjectsIOSSIMULATOR': bool(sample_results) and all(
            entry['simulatorOnly'] for entry in sample_results),
        'architectureCheck': 'lipo -archs on archive and member sample; vtool -show-build on extracted members',
        'hostKind': 'upstream-mobile-host-only',
        'hostKindIsFullFloeApp': False,
        'nativeEditorRuntimeVerified': False,
        'note': 'Staged real simulator engine; runtime PPTX scenario is a separate gate.',
    }
    (build_root / 'simulator-provenance.json').write_text(
        json.dumps(provenance, indent=2) + '\n')
    return provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build_root')
    args = parser.parse_args()
    print(json.dumps(stage(args.build_root), indent=2))


if __name__ == '__main__':
    main()
