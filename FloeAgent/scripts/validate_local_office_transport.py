#!/usr/bin/env python3
"""Read-only validation/storage transport for an already-built device Office host.

No compilation, capability promotion, native manifest rewrite or pin mutation.
Actions archives expire; keep the exact local ZIP and private draft asset.
"""
import argparse
import copy
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import tempfile
import zipfile

import bootstrap_office_host as bootstrap
import pin_office_host_artifact as pinning
import office_engine_repair
import office_compiled_lifecycle as compiled_lifecycle
from office_release_gates import CAPABILITY_FLAGS, validate_capability_claims

ARCHIVE_NAME = 'OfficeNativeHost-local.zip'
MAX_ARCHIVE_BYTES = 2 * 1024**3
MAX_EXPANDED_BYTES = 6 * 1024**3
MAX_ENTRIES = 100_000
MAX_MANIFEST_BYTES = 4 * 1024**2
HEX40 = re.compile(r'[0-9a-f]{40}\Z')
HEX64 = re.compile(r'[0-9a-f]{64}\Z')
# Include embedded lifecycle even when a historical pin helper predates it.
LIFECYCLES = (
    ('schemeTaskLifecycleOverlay', 'schemeOverlaySHA256', 'schemeTaskLifecycle'),
    ('forwardingLifecycleOverlay', 'forwardingOverlaySHA256', 'forwardingLifecycle'),
    ('kitCallbackLifecycleOverlay', 'kitCallbackOverlaySHA256', 'kitCallbackLifecycle'),
    ('embeddedLifecycleOverlay', 'embeddedLifecycleOverlaySHA256', 'embeddedLifecycle'),
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_json(path):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, 'Duplicate JSON key')
            value[key] = item
        return value
    return json.loads(Path(path).read_text(), object_pairs_hook=unique)


def checkout_identity(repo, source_commit, workflow_commit=None):
    require(isinstance(source_commit, str) and HEX40.fullmatch(source_commit), 'Expected exact source commit SHA')
    actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    require(actual == source_commit, 'Checkout source commit differs from requested source')
    if workflow_commit is not None:
        require(workflow_commit == source_commit, 'Workflow ref and input source commit differ')
    result = subprocess.run(['git', '-C', str(repo), 'diff', '--quiet', 'HEAD', '--',
                             'FloeAgent/ThirdParty/Collabora'], check=False)
    require(result.returncode == 0, 'Office source/lock checkout is modified')
    return actual


def safe_extract(archive_path, destination):
    require(archive_path.is_file() and not archive_path.is_symlink(), 'Archive is not a regular owned file')
    require(0 < archive_path.stat().st_size <= MAX_ARCHIVE_BYTES, 'Archive exceeds single-asset transport limit; retain locally and report')
    with zipfile.ZipFile(archive_path) as archive:
        infos = archive.infolist()
        require(0 < len(infos) <= MAX_ENTRIES, 'ZIP entry limit exceeded')
        seen, files, total = set(), set(), 0
        for item in infos:
            name = str(bootstrap.relative(item.filename))
            require(item.orig_filename == item.filename, 'ZIP filename contains NUL')
            require(name.split('/')[0] == 'OfficeNativeHost', 'Unexpected ZIP root')
            require(name not in seen, 'Duplicate ZIP member')
            seen.add(name)
            mode = item.external_attr >> 16
            kind = stat.S_IFMT(mode)
            require(kind in (0, stat.S_IFREG, stat.S_IFDIR), 'ZIP link or special file refused')
            require(not mode & 0o7000, 'ZIP privileged file mode refused')
            require(kind != stat.S_IFDIR or item.is_dir(), 'ZIP file/directory type differs')
            require(not item.flag_bits & 1, 'Encrypted ZIP member refused')
            require(item.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED), 'Unsupported ZIP compression')
            total += item.file_size
            require(0 <= item.file_size <= MAX_ARCHIVE_BYTES and total <= MAX_EXPANDED_BYTES, 'ZIP expansion limit exceeded')
            if not item.is_dir():
                files.add(name)
        for name in seen:
            require(not any(str(parent) in files for parent in Path(name).parents), 'ZIP file shadows a directory')
        require('OfficeNativeHost/native-host.json' in files, 'Missing native qualification manifest')
        for item in infos:
            target = destination / str(bootstrap.relative(item.filename))
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(item) as incoming, target.open('xb') as outgoing:
                    shutil.copyfileobj(incoming, outgoing, length=1024**2)
    return destination / 'OfficeNativeHost'


def device_macho(executable):
    # Check actual bytes, not only a claim copied from a simulator manifest.
    with executable.open('rb') as stream:
        header = stream.read(32)
        require(len(header) == 32, 'Missing Mach-O header')
        magic, cpu, _, filetype, count, size, _, _ = struct.unpack('<IiiIIIII', header)
        require(magic == 0xFEEDFACF and cpu == 0x0100000C and filetype == 6, 'Expected thin arm64 device dylib')
        require(0 < count <= 4096 and 0 < size <= 1024**2, 'Invalid Mach-O load command bounds')
        commands = stream.read(size)
        require(len(commands) == size, 'Truncated Mach-O load commands')
    offset, platforms = 0, []
    for _ in range(count):
        require(offset + 8 <= size, 'Truncated Mach-O command')
        command, length = struct.unpack_from('<II', commands, offset)
        require(length >= 8 and length % 4 == 0 and offset + length <= size, 'Invalid Mach-O command size')
        if command == 0x32:  # LC_BUILD_VERSION; PLATFORM_IOS=2, not IOSSIMULATOR=7.
            require(length >= 24, 'Truncated build version command')
            platforms.append(struct.unpack_from('<I', commands, offset + 8)[0])
        offset += length
    require(offset == size and platforms == [2], 'Mach-O is not an unambiguous iOS device build')


def check_overlay(base, overlay):
    require(isinstance(overlay, dict), 'Missing tracked embedding/lifecycle overlay')
    path = base / bootstrap.relative(overlay['patch'])
    require(not path.is_symlink() and pinning.digest(path) == overlay['sha256'], 'Tracked overlay patch/source checksum differs')


def validate_archive(archive, expected_sha256, repo, source_commit):
    archive, repo = Path(archive), Path(repo)
    require(isinstance(expected_sha256, str) and HEX64.fullmatch(expected_sha256), 'Expected exact ZIP SHA256')
    require(archive.is_file() and not archive.is_symlink() and 0 < archive.stat().st_size <= MAX_ARCHIVE_BYTES, 'Archive exceeds single-asset limit or is not a regular file')
    checkout_identity(repo, source_commit)
    require(pinning.digest(archive) == expected_sha256, 'Archive SHA256 differs')
    base = repo / 'FloeAgent/ThirdParty/Collabora'
    lock_path = base / 'engine.lock.json'
    lock = read_json(lock_path)
    with tempfile.TemporaryDirectory(prefix='office-transport-') as temporary:
        folder = safe_extract(archive, Path(temporary))
        manifest_path = folder / 'native-host.json'
        require(manifest_path.stat().st_size <= MAX_MANIFEST_BYTES, 'Qualification manifest is too large')
        manifest = read_json(manifest_path)
        require(manifest.get('sdk') == 'iphoneos' and manifest.get('arch') == 'arm64', 'Expected iphoneos/arm64 manifest, not simulator')
        for flag in (*pinning.QUALIFICATION_KEYS, 'nativeCompilePassed', 'nativeLinkPassed'):
            require(manifest.get(flag) is True, 'Qualification flag did not actually pass: ' + flag)
        failures = validate_capability_claims(manifest, label='local transport manifest')
        require(not failures, '; '.join(failures))
        claims = manifest.get('capabilityQualification')
        require(isinstance(claims, dict) and all(type(claims.get(key)) is bool for key in CAPABILITY_FLAGS), 'Missing/invalid explicit release capability claims')
        source_root = base / 'FloeOfficeNative'
        require(not any(path.is_symlink() for path in source_root.rglob('*')), 'Host source contains alias')
        require(source_root.is_dir() and not source_root.is_symlink(), 'Host source root is not a real directory')
        sources = {path.name: pinning.digest(path) for path in source_root.iterdir() if path.is_file()}
        require(bool(sources) and manifest.get('hostSourceSHA256') == sources, 'Host source hashes differ from exact checkout')
        require(manifest.get('sourceCommit') == lock['commit'], 'Engine source commit differs')
        if manifest.get('workflowCommit') is not None:
            require(manifest['workflowCommit'] == source_commit, 'Native build source commit differs from transport source')
        check_overlay(base, lock['embeddingOverlay'])
        require(manifest.get('overlaySHA256') == lock['embeddingOverlay']['sha256'], 'Embedding overlay differs')
        require({key for key in lock if key.endswith('LifecycleOverlay')} <= {item[0] for item in LIFECYCLES}, 'Unknown tracked lifecycle contract; update validator first')
        candidate = copy.deepcopy(lock['qualifiedHostArtifact'])
        for section, claim_key, block in LIFECYCLES:
            if section in lock:
                check_overlay(base, lock[section])
                expected = pinning.lifecycle_provenance(lock[section], lock['commit'])
                require(manifest.get(block) == expected, 'Missing/forged lifecycle evidence: ' + block)
                candidate[claim_key] = lock[section]['sha256']
        compiled_member = compiled_lifecycle.validate_manifest(manifest, lock, 'IOS', lock_path=lock_path)
        if compiled_member is not None:
            candidate['embeddedLifecycleMember'] = compiled_member
        else:
            candidate.pop('embeddedLifecycleMember', None)
        repair = pinning.engine_repair_claim(lock_path)
        if repair is not None:
            repair_lock, _ = office_engine_repair.tracked_contract(base / 'engine.patch.lock.json', platform='IOS')
            office_engine_repair.check_patch_file(repair_lock, base / 'engine.patch.lock.json')
            require(not pinning.engine_repair_provenance_failures(manifest, repair), 'Missing/forged engine repair evidence')
            candidate['engineRepair'] = repair
        filters_path = base / 'filter-overlay.lock.json'
        if filters_path.exists():
            filters = read_json(filters_path)
            overlay = manifest.get('filterOverlay')
            require(isinstance(overlay, dict), 'Missing filter overlay evidence')
            require(overlay.get('compilePassed') is True and overlay.get('archiveReplacementPassed') is True, 'Filter overlay compile/archive replacement did not pass')
            require(filters['commit'] == lock['commit'] and overlay.get('patchSHA256') == filters['patchSHA256']
                    and overlay.get('sourceFiles') == filters['files']
                    and overlay.get('headerDependencies', {}) == filters.get('headerDependencies', {}), 'Filter overlay/source evidence differs')
            require(pinning.digest(base / bootstrap.relative(filters['patch'])) == filters['patchSHA256'], 'Filter patch differs')
            require(set(lock['qualifiedHostArtifact'].get('filterOverlay', {})) <= set(overlay), 'Filter overlay omits pinned receipt fields')
            for field in ('archiveSHA256', 'objectSHA256', 'selectedArchiveSHA256'):
                require(isinstance(overlay.get(field), str) and HEX64.fullmatch(overlay[field]), 'Missing/invalid filter archive/object checksum')
            require(overlay.get('originalArchiveSHA256') == filters['originalArchiveSHA256'], 'Filter input archive differs')
            objects = overlay.get('objectSHA256ByMember', {})
            require(isinstance(objects, dict) and set(objects) == set(filters.get('members', {filters['member']: ''}))
                    and all(isinstance(value, str) and HEX64.fullmatch(value) for value in objects.values()), 'Filter replacement member evidence differs')
            selections = overlay.get('selectedArchiveSHA256ByName', {})
            extras = filters.get('additionalArchives', {})
            require(isinstance(selections, dict) and set(selections) == {'libscfiltlo.a', *extras}
                    and all(isinstance(value, str) and HEX64.fullmatch(value) for value in selections.values())
                    and selections['libscfiltlo.a'] == overlay['selectedArchiveSHA256'], 'Filter selected archive evidence differs')
            for name, spec in extras.items():
                declared = overlay.get('additionalArchives', {}).get(name, {})
                require(selections[name] == declared.get('archiveSHA256')
                        and declared.get('originalArchiveSHA256') == spec['originalArchiveSHA256']
                        and set(declared.get('objectSHA256ByMember', {})) == set(spec['members'])
                        and all(isinstance(value, str) and HEX64.fullmatch(value)
                                for value in declared.get('objectSHA256ByMember', {}).values()), 'Additional filter archive evidence differs')
            candidate['filterOverlay'] = overlay
        hashes = pinning.artifact_hashes(folder)
        auxiliary = hashes['frameworkAuxiliarySHA256']
        require(set(auxiliary) == set(lock['qualifiedHostArtifact']['frameworkAuxiliarySHA256']), 'Unknown/missing framework executable or auxiliary file')
        require(auxiliary.get('Headers/FloeOfficeNative.h') == sources.get('FloeOfficeNative.h'), 'Exported public header differs from source')
        require(manifest.get('executableSHA256') == hashes['executableSHA256'], 'Executable differs from native build receipt')
        resources = manifest.get('runtimeResourceSHA256')
        require(isinstance(resources, dict) and bool(resources) and resources == hashes['runtimeResourceSHA256'], 'Unknown/missing/changed runtime resource')
        require(isinstance(manifest.get('runtimeResourceDirectories'), list), 'Missing resource directory inventory')
        info = plistlib.loads((folder / bootstrap.FRAMEWORK / 'Info.plist').read_bytes())
        require(info.get('CFBundleExecutable') == 'FloeOfficeNative' and info.get('CFBundlePackageType') == 'FMWK'
                and info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'Framework Info.plist is not a device framework')
        device_macho(folder / bootstrap.FRAMEWORK / 'FloeOfficeNative')
        candidate.update(hostSourceSHA256=sources, overlaySHA256=lock['embeddingOverlay']['sha256'],
                         manifestSHA256=hashes['manifestSHA256'], executableSHA256=hashes['executableSHA256'],
                         frameworkAuxiliarySHA256=auxiliary, archiveSHA256=expected_sha256, runID=manifest.get('runID'))
        if not manifest.get('runID'):
            # A local manifest has no cloud run identity, so this private
            # validation copy must not inherit the previous pin's transport
            # identity; the real pin records it only from explicit CLI args.
            candidate.pop('localStorageArtifact', None)
        # Reuse the existing source/overlay/pin checks without writing the real
        # lock. A private validation copy points at byte-identical contracts.
        contracts = Path(temporary) / 'contracts'
        contracts.mkdir()
        paths = {'engine.lock.json'}
        paths.update('FloeOfficeNative/' + name for name in sources)
        paths.update(lock[section]['patch'] for section in ('embeddingOverlay', *(x[0] for x in LIFECYCLES)) if section in lock)
        for spec in (lock.get('embeddedLifecycleOverlay', {}).get('compiledMembers') or {}).values():
            paths.add(spec['patch'])
            paths.update(child['patch'] for child in spec.get('additionalArchives', {}).values())
            for archive in [spec, *spec.get('additionalArchives', {}).values()]:
                paths.update(member['patch'] for member in archive.get('additionalMembers', {}).values())
        if filters_path.exists():
            paths.update(('filter-overlay.lock.json', filters['patch']))
            paths.update(spec['patch'] for spec in filters.get('headerDependencies', {}).values() if spec.get('patch'))
        if repair is not None:
            paths.update(('engine.patch.lock.json', repair_lock['repair']['patch']))
        for name in paths:
            relative = bootstrap.relative(name)
            source, target = base / relative, contracts / relative
            require(source.is_file() and not source.is_symlink(), 'Contract source is not a regular file')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        updated = copy.deepcopy(lock)
        updated['qualifiedHostArtifact'] = candidate
        (contracts / 'engine.lock.json').write_text(json.dumps(updated))
        bootstrap.checked_lock(contracts / 'engine.lock.json')
        bootstrap.verify_installed(folder, lock, candidate)
        return {'archiveSHA256': expected_sha256, 'manifestSHA256': hashes['manifestSHA256'],
                'executableSHA256': hashes['executableSHA256'], 'sourceCommit': source_commit,
                'engineCommit': lock['commit'], 'sdk': 'iphoneos', 'arch': 'arm64',
                'capabilityQualification': claims, 'nativeManifestModified': False}


def select_draft_asset(release, tag, source_commit, expected_sha256=None, repo=None):
    require(type(release.get('id')) is int and release['id'] > 0, 'Invalid draft release identity')
    require(release.get('draft') is True and release.get('published_at') is None, 'Transport release must remain a private unpublished draft')
    require(release.get('tag_name') == tag and release.get('target_commitish') == source_commit, 'Draft tag/source target differs')
    assets = [item for item in release.get('assets', []) if item.get('name') == ARCHIVE_NAME]
    require(len(assets) == 1, 'Need exactly one OfficeNativeHost-local.zip draft asset')
    asset = assets[0]
    require(type(asset.get('id')) is int and asset['id'] > 0 and asset.get('state') == 'uploaded', 'Draft asset is not fully uploaded')
    require(type(asset.get('size')) is int and 0 < asset['size'] <= MAX_ARCHIVE_BYTES, 'Draft asset exceeds single-asset limit; report instead of splitting')
    if expected_sha256 is not None:
        require(asset.get('digest') == 'sha256:' + expected_sha256,
                'Draft asset digest differs from the exact ZIP SHA256')
    if repo is not None:
        # Downloads are built from this repo identity and the asset id above,
        # never from a URL supplied inside the response body.
        require(str(asset.get('url', '')).startswith('https://api.github.com/repos/' + repo + '/releases/assets/'),
                'Draft asset origin is not the expected GitHub API')
    return asset


def gh_json(endpoint):
    result = subprocess.run(['gh', 'api', '--method', 'GET', endpoint], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(result.returncode == 0, 'Read-only GitHub metadata request failed')
    require(len(result.stdout) <= 4 * 1024**2, 'GitHub metadata exceeds limit')
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--release-tag')
    parser.add_argument('--release-id',
                        help='numeric id of the private unpublished draft; '
                             'the by-tag endpoint never returns drafts')
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--repo-root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    require(bool(args.archive) != bool(args.release_tag), 'Choose local archive or draft transport, not both')
    require(args.release_tag or not args.release_id, '--release-id only applies to draft transport')
    workflow_sha = os.environ.get('GITHUB_SHA') if os.environ.get('GITHUB_ACTIONS') == 'true' else None
    checkout_identity(args.repo_root, args.source_commit, workflow_sha)
    if workflow_sha:
        require(os.environ.get('GITHUB_WORKFLOW_SHA') == args.source_commit, 'Workflow source and input differ')
    require(not args.output_dir.exists(), 'Use a new owned output directory')
    args.output_dir.mkdir(parents=True)
    native = args.archive
    release = asset = None
    if args.release_tag:
        repo = os.environ.get('GITHUB_REPOSITORY', '')
        require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo), 'Invalid repository identity')
        require(args.release_tag and len(args.release_tag) <= 200 and not any(ord(c) < 32 for c in args.release_tag), 'Invalid transport tag')
        # GitHub's by-tag endpoint returns published releases only, and draft
        # releases are visible only to tokens with push access. Resolve the
        # exact numeric draft by id (the job-local contents:write token reads
        # metadata here and never publishes); the tag/target/draft identity is
        # still asserted below.
        require(bool(args.release_id) and args.release_id.isdigit() and int(args.release_id) > 0,
                'Draft transport needs the numeric --release-id; the by-tag endpoint never returns drafts')
        release = gh_json('repos/' + repo + '/releases/' + args.release_id)
        require(release.get('id') == int(args.release_id), 'Draft release identity differs')
        require(str(release.get('url', '')).startswith('https://api.github.com/repos/' + repo + '/releases/'),
                'Draft release origin is not the expected GitHub API')
        asset = select_draft_asset(release, args.release_tag, args.source_commit, args.sha256, repo)
        native = args.output_dir / ARCHIVE_NAME
        with native.open('xb') as stream:
            result = subprocess.run(['gh', 'api', '--method', 'GET', '-H', 'Accept: application/octet-stream',
                                     f"repos/{repo}/releases/assets/{asset['id']}"], stdout=stream, stderr=subprocess.PIPE)
        require(result.returncode == 0 and native.stat().st_size == asset['size'], 'Draft asset download failed or size differs')
        # Re-read after transfer; do not archive an asset that was swapped or
        # a draft that became public while bytes were downloading.
        fresh = gh_json('repos/' + repo + '/releases/' + str(release['id']))
        require(select_draft_asset(fresh, args.release_tag, args.source_commit, args.sha256, repo)['id'] == asset['id'], 'Draft asset changed during transfer')
    report = validate_archive(native, args.sha256, args.repo_root, args.source_commit)
    if args.release_tag:
        final_release = gh_json('repos/' + repo + '/releases/' + str(release['id']))
        require(select_draft_asset(final_release, args.release_tag, args.source_commit, args.sha256, repo)['id'] == asset['id'], 'Draft changed during validation')
    output = args.output_dir / 'OfficeNativeHost.zip'
    shutil.copyfile(native, output)
    require(pinning.digest(output) == args.sha256, 'Transport changed archive bytes')
    if args.release_tag:
        native.unlink()  # only the successful owned transfer staging copy
    report.update(transportKind='local-device-build-actions-storage', artifactName='office-native-host-unsigned',
                  workflow=os.environ.get('GITHUB_WORKFLOW_REF'), runID=os.environ.get('GITHUB_RUN_ID'),
                  runAttempt=os.environ.get('GITHUB_RUN_ATTEMPT'), workflowCommit=workflow_sha,
                  repository=os.environ.get('GITHUB_REPOSITORY'), draftTransportTag=args.release_tag,
                  draftReleaseID=release.get('id') if release else None,
                  draftAssetID=asset.get('id') if asset else None,
                  requestedRetentionDays=7, permanentDistribution=False)
    (args.output_dir / 'transport-provenance.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Validated device Office archive; original bytes preserved; no build or capability promotion.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        raise SystemExit('Office transport rejected: ' + str(error)) from None
