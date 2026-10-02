#!/usr/bin/env python3
"""Apply (or check) the pinned single-member Office engine archive repair.

This is the production form of the verified Build 241 blank-slideshow repair:
upstream LibreOffice/core commit bd7373b5e4f0044122d8b8b561417866bd987717
(``fix(iOS): correct blank slides when presenting``) changes exactly one
function in ``engine/vcl/source/gdi/virdev.cxx``
(``VirtualDevice::SetOutputSizePixelScaleOffsetAndKitBuffer``): on iOS it
calls ``SetSize(w, h, false)`` instead of the unsupported no-op
``SetSizeUsingBuffer``.  The pinned Collabora engine predates that commit, so
its ``libvcllo.a`` member ``virdev.o`` still contains the blank-slide call.
The heavy core engine is never rebuilt here: the pinned source file is
recompiled alone with the recorded gbuild-derived command, proven byte-identical
against the pinned archive member *before* the patch is applied, and exactly one
archive member is then replaced while member order, member count, every other
member's bytes and the bundle manifest stay auditable.

The contract is the tracked ``engine.patch.lock.json`` next to
``engine.lock.json``.  It binds, per Apple platform (IOSSIMULATOR / IOS):

* the pinned engine repository/commit and the exact upstream patch identity
  (patch file + SHA-256, upstream commit, original/patched source SHA-256);
* the input bundle identity (staged simulator engine run/artifact hashes, or
  the qualified device complete-inputs archive hash);
* the archive path, member name/position/count, original and patched archive
  and member SHA-256, and the replaced member's ar header fields (mtime,
  uid/gid/mode) so the patched archive is bit-reproducible;
* the reconstructed compile recipe (SDK, target triple, flags, and the ordered
  include roots that come from the pinned git source checkout vs. the built
  bundle) plus the exact toolchain identity (Xcode / SDK build) that the
  pinned archives were built with and this runner must match.

Every step fails closed on any mismatch (source, recipe, member, archive,
manifest, toolchain, platform or SDK drift, unsafe paths).  ``--check`` is
strictly read-only and reports the bundle state as ``patched`` /
``original`` / ``mismatch``.  No full core rebuild, no redownload of retained
packages, and no other archive member is ever touched.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile
import time

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))
sys.path.insert(0, str(THIS_DIR / 'office_real_simulator'))

from sim_paths import normalize_xcode_version  # noqa: E402
from verify_office_engine import contained as bundle_contained  # noqa: E402,E501
from verify_office_engine import verify as verify_bundle  # noqa: E402

DEFAULT_LOCK = THIS_DIR.parent / 'ThirdParty/Collabora/engine.patch.lock.json'
RECEIPT_NAME = 'engine-repair.json'
PLATFORMS = ('IOSSIMULATOR', 'IOS')
SDK_BY_PLATFORM = {'IOSSIMULATOR': 'iphonesimulator', 'IOS': 'iphoneos'}
PLATFORM_BY_SDK = {value: key for key, value in SDK_BY_PLATFORM.items()}


class RepairError(ValueError):
    pass


def digest(path):
    checksum = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


# --------------------------------------------------------------------------
# BSD ar archive access (long names via #1/N members; __.SYMDEF table first).
# --------------------------------------------------------------------------

class ArMember:
    def __init__(self, name, mtime, uid, gid, mode, offset, size, header_offset):
        self.name = name
        self.mtime = mtime
        self.uid = uid
        self.gid = gid
        self.mode = mode
        self.offset = offset          # offset of the member content
        self.size = size              # content size (long-name header stripped)
        self.header_offset = header_offset  # offset of the 60-byte ar header

    @property
    def header(self):
        return {
            'name': self.name, 'mtime': self.mtime, 'uid': self.uid,
            'gid': self.gid, 'mode': self.mode, 'size': self.size,
        }


def read_ar_members(path):
    """Walk a BSD ar archive; return the ordered member list."""
    members = []
    with Path(path).open('rb') as stream:
        if stream.read(8) != b'!<arch>\n':
            raise RepairError(f'not a BSD ar archive: {path}')
        while True:
            header_offset = stream.tell()
            header = stream.read(60)
            if not header:
                break
            if len(header) != 60 or header[58:60] != b'`\n':
                raise RepairError(f'corrupt ar member header in {path}')
            raw_name = header[0:16].decode('latin1')
            try:
                mtime = int(header[16:28].decode('latin1').strip())
                uid = int(header[28:34].decode('latin1').strip())
                gid = int(header[34:40].decode('latin1').strip())
                mode = header[40:48].decode('latin1').strip()
                size = int(header[48:58].decode('latin1').strip())
            except ValueError as failure:
                raise RepairError(f'corrupt ar member header in {path}: {failure}')
            if raw_name.startswith('#1/'):
                name_length = int(raw_name[3:].strip())
                name = stream.read(name_length).split(b'\x00')[0].decode('latin1')
                size -= name_length
            else:
                name = raw_name.strip().rstrip('/')
            offset = stream.tell()
            members.append(ArMember(name, mtime, uid, gid, mode, offset, size,
                                    header_offset))
            stream.seek(size + (size % 2), 1)
    return members


def rewrite_member_mtime(path, member, mtime):
    """Pin one ar member header mtime field (12-byte decimal, space padded)."""
    field = f'{mtime:<12}'.encode('ascii')
    if len(field) != 12:
        raise RepairError(f'mtime field overflow: {mtime}')
    with Path(path).open('r+b') as stream:
        stream.seek(member.header_offset + 16)
        if stream.read(12) == field:
            return False
        stream.seek(member.header_offset + 16)
        stream.write(field)
    return True


def read_member(path, member):
    with Path(path).open('rb') as stream:
        stream.seek(member.offset)
        return stream.read(member.size)


def snapshot_members(path):
    """Ordered per-member digests and ar headers captured BEFORE any mutation.

    The post-mutation audit must compare against bytes read before the
    archive changed; comparing ``read_member(before)`` with
    ``read_member(after)`` after the rewrite reads the same mutated file twice
    and cannot prove that an unrelated member stayed untouched.  Member
    content is streamed one member at a time (bounded chunk), so the whole
    archive is never held in memory.
    """
    members = read_ar_members(path)
    snapshots = []
    with Path(path).open('rb') as stream:
        for member in members:
            stream.seek(member.offset)
            checksum = hashlib.sha256()
            remaining = member.size
            while remaining > 0:
                chunk = stream.read(min(1 << 20, remaining))
                if not chunk:
                    raise RepairError(
                        f'truncated ar member {member.name} in {path}')
                checksum.update(chunk)
                remaining -= len(chunk)
            snapshots.append({
                'name': member.name, 'mtime': member.mtime, 'uid': member.uid,
                'gid': member.gid, 'mode': member.mode, 'size': member.size,
                'sha256': checksum.hexdigest(),
            })
    return snapshots


def find_member(members, name, expected_position=None, expected_count=None):
    """Locate one member by name; enforce the locked layout when given."""
    matches = [member for member in members if member.name == name]
    if not matches:
        raise RepairError(f'archive has no member named {name}')
    if len(matches) != 1:
        raise RepairError(f'archive has {len(matches)} members named {name}; refusing ambiguity')
    if expected_count is not None and len(members) != expected_count:
        raise RepairError(
            f'archive member count {len(members)} != locked {expected_count}')
    position = members.index(matches[0]) + 1
    if expected_position is not None and position != expected_position:
        raise RepairError(
            f'member {name} position {position} != locked {expected_position}')
    return matches[0], position


# --------------------------------------------------------------------------
# Toolchain / source / bundle validation.
# --------------------------------------------------------------------------

def xcode_identity():
    result = subprocess.run(['xcodebuild', '-version'], capture_output=True,
                            text=True, check=True)
    return normalize_xcode_version(result.stdout)


def sdk_identity(sdk):
    def show(*args):
        return subprocess.check_output(['xcrun', '--sdk', sdk, *args],
                                       text=True).strip()
    return {'sdkPath': show('--show-sdk-path'),
            'sdkVersion': show('--show-sdk-version'),
            'sdkBuildVersion': show('--show-sdk-build-version')}


def check_toolchain(entry):
    expected = entry['compile']
    failures = []
    actual_xcode = xcode_identity()
    if actual_xcode != normalize_xcode_version(expected['xcodeVersion']):
        failures.append(
            f'current Xcode {actual_xcode!r} != locked {expected["xcodeVersion"]!r}')
    sdk = SDK_BY_PLATFORM[entry['platform']]
    identity = sdk_identity(sdk)
    if identity['sdkBuildVersion'] != expected['sdkBuildVersion']:
        failures.append(
            f'current {sdk} SDK build {identity["sdkBuildVersion"]!r} != locked '
            f'{expected["sdkBuildVersion"]!r}')
    if identity['sdkVersion'] != expected['sdkVersion']:
        failures.append(
            f'current {sdk} SDK version {identity["sdkVersion"]!r} != locked '
            f'{expected["sdkVersion"]!r}')
    return failures, {'xcodeVersion': actual_xcode, **identity}


def check_engine_source(engine_source, lock):
    """The git checkout that supplies the pinned source file and include roots."""
    engine_source = Path(engine_source).resolve()
    if not (engine_source / '.git').exists():
        raise RepairError(f'engine source is not a git checkout: {engine_source}')
    head = subprocess.check_output(
        ['git', '-C', str(engine_source), 'rev-parse', 'HEAD'], text=True).strip()
    if head != lock['engine']['commit']:
        raise RepairError(
            f'engine source commit {head} != locked {lock["engine"]["commit"]}')
    source_file = engine_source / lock['repair']['sourceFile']
    if digest(source_file) != lock['repair']['originalSourceSHA256']:
        raise RepairError(
            f'pinned source file {lock["repair"]["sourceFile"]} differs from the lock')
    missing = [name for name in entry_includes(lock, engine_source, 'sourceIncludes')
               if not (engine_source / name).is_dir()]
    if missing:
        raise RepairError('engine source checkout is missing locked include roots: '
                          + ', '.join(missing[:5]))
    return source_file


def entry_includes(lock, engine_source, key):
    return lock['platforms'][lock['selectedPlatform']]['compile'][key]


def load_lock(lock_path, platform):
    lock_path = Path(lock_path).resolve()
    lock = json.loads(lock_path.read_text())
    if lock.get('formatVersion') != 1:
        raise RepairError(f'unsupported engine patch lock format in {lock_path}')
    section = lock.get('platforms', {}).get(platform)
    if section is None:
        raise RepairError(
            f'no engine repair contract for platform {platform}; '
            'refusing to improvise without a tracked lock entry')
    if section['platform'] != platform:
        raise RepairError(f'lock platform section mislabeled: {section["platform"]}')
    if SDK_BY_PLATFORM[platform] != section['compile']['sdk']:
        raise RepairError(f'lock SDK does not match platform {platform}')
    lock['selectedPlatform'] = platform
    lock['lockPath'] = str(lock_path)
    lock['lockSHA256'] = digest(lock_path)
    return lock, section, lock_path


def check_patch_file(lock, lock_path):
    repair = lock['repair']
    patch = Path(lock_path).parent / repair['patch']
    if not patch.is_file() or patch.is_symlink():
        raise RepairError(f'patch file missing next to the lock: {patch}')
    if digest(patch) != repair['patchSHA256']:
        raise RepairError(f'patch file checksum mismatch: {patch}')
    return patch


def apply_patch_to_copy(patch, source_file, scratch, expected_sha256):
    """Apply the tracked patch to a scratch copy and verify the exact bytes."""
    relative = Path('engine') / 'vcl/source/gdi/virdev.cxx'
    target_dir = scratch / 'tree'
    target = target_dir / relative
    target.parent.mkdir(parents=True)
    shutil.copyfile(source_file, target)
    for mode in ('--check', None):
        command = ['git', 'apply']
        if mode:
            command.append(mode)
        command.append(str(patch))
        result = subprocess.run(command, cwd=target_dir, capture_output=True,
                                text=True)
        if result.returncode:
            raise RepairError(
                f'git apply {mode or ""} failed for {patch}: {result.stderr.strip()}')
    patched = target_dir / relative
    if digest(patched) != expected_sha256:
        raise RepairError(
            'patched source bytes differ from the locked patched source SHA-256')
    return patched


def check_bundle_manifest(bundle, section, lock):
    bundle = Path(bundle).resolve()
    manifest_path = bundle / 'bundle-manifest.json'
    if not manifest_path.is_file():
        raise RepairError(f'bundle has no bundle-manifest.json: {bundle}')
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('sourceCommit') != lock['engine']['commit']:
        raise RepairError(
            f'bundle sourceCommit {manifest.get("sourceCommit")} != locked '
            f'{lock["engine"]["commit"]}')
    entry = next((item for item in manifest.get('files', [])
                  if item.get('path') == section['archiveBundlePath']), None)
    if entry is None or 'symlink' in entry or entry.get('directory'):
        raise RepairError(
            f'bundle manifest lacks a file entry for {section["archiveBundlePath"]}')
    archive = bundle_contained(bundle, section['archiveBundlePath'])
    return manifest, entry, archive


def archive_state(archive, entry, section):
    """Classify one archive against the lock: original / patched / mismatch."""
    actual = digest(archive)
    observed = {'sha256': actual, 'size': archive.stat().st_size}
    if actual == section['archive']['originalSHA256']:
        state = 'original'
    elif actual == section['archive']['patchedSHA256']:
        state = 'patched'
    else:
        state = 'mismatch'
    manifest_match = (entry.get('sha256') == actual
                      and entry.get('size') == observed['size'])
    return state, observed, manifest_match


# --------------------------------------------------------------------------
# Compile recipe reconstruction.
# --------------------------------------------------------------------------

def build_compile_command(section, engine_source, bundle, source_file, output,
                          aux_bundle=None, depfile=None):
    compile_spec = section['compile']
    sdk = compile_spec['sdk']
    sdk_path = subprocess.check_output(
        ['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
    command = ['xcrun', '--sdk', sdk, 'clang++', '-arch', 'arm64',
               '-target', compile_spec['target'], '-isysroot', sdk_path]
    for flag in compile_spec['flags']:
        command.append(flag)
    for name in compile_spec['sourceIncludes']:
        command.append('-I' + str(Path(engine_source) / name))
    aux = compile_spec.get('auxiliaryIncludes', [])
    for name in compile_spec['bundleIncludes']:
        root = None
        if (Path(bundle) / name).is_dir():
            root = bundle
        elif aux_bundle is not None and name in aux and \
                (Path(aux_bundle) / name).is_dir():
            root = aux_bundle
        elif name in aux:
            raise RepairError(
                f'locked auxiliary include root missing from the auxiliary '
                f'input: {name}')
        # Roots absent from BOTH the bundle and the auxiliary input are not
        # part of this translation unit's include closure (dependency-proven
        # for this repair); a future source change that needs one fails
        # closed at compile time with a missing-header error.
        if root is not None:
            command.append('-I' + str(Path(root) / name))
    command.extend(['-c', str(source_file), '-o', str(output)])
    if depfile is not None:
        # -MMD records every user header the translation unit actually
        # includes; the caller binds that closure to the verified auxiliary
        # manifest so the auxiliary input is proven, not assumed.
        command.extend(['-MMD', '-MF', str(depfile)])
    return command


def load_evidence(path, label):
    """Read a real on-disk report; locked metadata alone is never accepted."""
    path = Path(path)
    if not path.is_file():
        raise RepairError(
            f'{label} missing: {path}; the producer binds the actual input '
            'provenance instead of copying the tracked metadata')
    try:
        report = json.loads(path.read_text())
    except ValueError as failure:
        raise RepairError(f'{label} is not valid JSON: {path}: {failure}')
    if not isinstance(report, dict):
        raise RepairError(f'{label} is not a JSON object: {path}')
    return report, digest(path)


def require_evidence_field(report, field, expected, label):
    actual = report.get(field)
    if actual != expected:
        raise RepairError(
            f'{label} {field} {actual!r} != locked expected {expected!r}')


def require_evidence_true(report, field, label):
    if report.get(field) is not True:
        raise RepairError(f'{label} does not record {field}=true')


def verify_input_evidence(section, bundle, lock, lock_path):
    """Bind the actual restored/repacked bundle to the locked input identity.

    The tracked ``section['input']`` is only the expected identity; this
    function consumes the real evidence the upstream steps wrote next to the
    bundle (``restore-report.json`` for a restored simulator engine,
    ``bundle-repair.json`` for the repaired complete-inputs device bundle) and
    fails closed on missing, mismatched or unknown values.
    """
    bundle = Path(bundle).resolve()
    expected = section['input']
    kind = expected.get('kind')
    if kind == 'office-real-simulator-engine':
        report, report_sha = load_evidence(
            bundle / 'restore-report.json', 'restore report')
        require_evidence_field(report, 'baseEngineRunID',
                               str(expected['runID']), 'restore-report.json')
        require_evidence_field(report, 'provenanceArtifactSHA256',
                               expected['artifactSHA256'], 'restore-report.json')
        require_evidence_field(report, 'sourceCommit',
                               lock['engine']['commit'], 'restore-report.json')
        if expected.get('artifactName') is not None:
            require_evidence_field(report, 'engineArtifactName',
                                   expected['artifactName'], 'restore-report.json')
        require_evidence_true(report, 'restoreVerified', 'restore-report.json')
        require_evidence_true(report, 'provenanceBound', 'restore-report.json')
        require_evidence_true(report, 'allSampledObjectsIOSSIMULATOR',
                              'restore-report.json')
        evidence = {
            'kind': kind,
            'report': 'restore-report.json',
            'reportSHA256': report_sha,
            'runID': str(report['baseEngineRunID']),
            'artifactSHA256': report['provenanceArtifactSHA256'],
            'engineArtifactName': report.get('engineArtifactName'),
            'sourceCommit': report['sourceCommit'],
            'restoreVerified': True,
            'provenanceBound': True,
            'restoredEntries': report.get('restoredEntries'),
            'linkerInputs': report.get('linkerInputs'),
            'allSampledObjectsIOSSIMULATOR': True,
            'outerArtifactName': expected.get('outerArtifactName'),
            'outerArtifactSHA256': expected.get('outerArtifactSHA256'),
            # The restore report binds the inner engine tarball; the packaging
            # ZIP hash is not carried by any retained per-run report.
            'outerArtifactHashVerified': False,
        }
        return evidence
    if kind == 'office-engine-complete-inputs':
        report, report_sha = load_evidence(
            bundle / 'bundle-repair.json', 'bundle repair report')
        require_evidence_field(report, 'originalArchiveSHA256',
                               expected['artifactSHA256'], 'bundle-repair.json')
        verified = report.get('verified')
        if not isinstance(verified, dict):
            raise RepairError('bundle-repair.json carries no verified manifest block')
        require_evidence_field(verified, 'sourceCommit',
                               lock['engine']['commit'], 'bundle-repair.json verified')
        for field in ('filesVerified', 'archivesVerified', 'objectsVerified',
                      'linkerInputsVerified'):
            value = verified.get(field)
            if not isinstance(value, int) or value <= 0:
                raise RepairError(
                    f'bundle-repair.json verified {field} {value!r} is not a '
                    'positive count')
        # Cross-check the packaging repair against the tracked embedding lock:
        # the report must describe exactly the allowed alias removals and the
        # restored empty directory, not arbitrary packaging edits.
        embedding_lock_path = Path(lock_path).parent / 'engine.lock.json'
        embedding, embedding_sha = load_evidence(
            embedding_lock_path, 'embedding lock')
        qualified = embedding.get('qualifiedEmbeddingArtifact')
        if not isinstance(qualified, dict):
            raise RepairError('embedding lock carries no qualifiedEmbeddingArtifact')
        removed = [entry.get('path') for entry in report.get('removedUnusedTestAliases', [])]
        aliases = qualified.get('omittedTestAliases')
        if not isinstance(aliases, dict) or removed != list(aliases.keys()):
            raise RepairError(
                'bundle-repair.json removed aliases do not match the tracked '
                'embedding lock omissions')
        require_evidence_field(report, 'restoredEmptyDirectories',
                               qualified.get('restoredEmptyDirectories'),
                               'bundle-repair.json')
        evidence = {
            'kind': kind,
            'report': 'bundle-repair.json',
            'reportSHA256': report_sha,
            'originalArchiveSHA256': report['originalArchiveSHA256'],
            'originalManifestSHA256': report.get('originalManifestSHA256'),
            'sourceCommit': verified['sourceCommit'],
            'filesVerified': verified['filesVerified'],
            'archivesVerified': verified['archivesVerified'],
            'objectsVerified': verified['objectsVerified'],
            'linkerInputsVerified': verified['linkerInputsVerified'],
            'removedUnusedTestAliases': removed,
            'restoredEmptyDirectories': report['restoredEmptyDirectories'],
            'embeddingLockSHA256': embedding_sha,
            # The run identity is bound through the tracked run/artifact pair
            # and the real archive hash verified above; bundle-repair.json
            # itself does not carry a run ID.
            'runID': str(expected['runID']),
            'artifactID': expected.get('artifactID'),
            'artifactName': expected.get('artifactName'),
            'runIDBinding': 'artifact SHA-256 verified against bundle-repair.json',
        }
        return evidence
    raise RepairError(
        f"unknown input kind {kind!r}; refusing an unverified input identity")


def verify_auxiliary_closure(section, aux_bundle, depfile):
    """Bind the compile's real header closure to the verified aux manifest.

    ``depfile`` is the ``-MMD`` dependency list of the actual repair compile.
    Every dependency resolved inside one of the locked ``auxiliaryIncludes``
    roots must exist as a regular file and match its entry in the fully
    verified auxiliary ``bundle-manifest.json``; the closure may not be empty.
    """
    roots = [PurePosixPath(name) for name in section['compile'].get('auxiliaryIncludes', [])]
    if not roots:
        return []
    aux_bundle = Path(aux_bundle).resolve()
    if not Path(depfile).is_file():
        raise RepairError(
            f'auxiliary dependency file missing: {depfile}; cannot prove the '
            'auxiliary header closure')
    manifest = json.loads((aux_bundle / 'bundle-manifest.json').read_text())
    entries = {entry['path']: entry for entry in manifest.get('files', [])
               if not entry.get('directory') and 'symlink' not in entry}
    closure = []
    for dependency in parse_depfile(depfile):
        try:
            relative = dependency.relative_to(aux_bundle)
        except ValueError:
            continue
        name = relative.as_posix()
        if not any(name == root.as_posix()
                   or name.startswith(root.as_posix() + '/') for root in roots):
            continue
        entry = entries.get(name)
        if entry is None:
            raise RepairError(
                f'auxiliary header {name} is not covered by the verified '
                'auxiliary bundle manifest')
        if dependency.is_symlink() or not dependency.is_file():
            raise RepairError(f'auxiliary header {name} is not a regular file')
        if (dependency.stat().st_size != entry.get('size')
                or digest(dependency) != entry.get('sha256')):
            raise RepairError(
                f'auxiliary header {name} differs from the verified auxiliary '
                'bundle manifest')
        closure.append({'path': name, 'sha256': entry['sha256'],
                        'size': entry['size']})
    if not closure:
        raise RepairError(
            'the repair compile referenced no header under the locked '
            'auxiliary include roots; refusing an unbound auxiliary input')
    closure.sort(key=lambda item: item['path'])
    return closure


def parse_depfile(path):
    """Absolute dependency paths from a clang ``-MMD`` make rule file."""
    text = Path(path).read_text().replace('\\\n', ' ')
    dependencies = []
    for line in text.splitlines():
        payload = line.split(':', 1)[1] if ':' in line else line
        dependencies.extend(payload.split())
    resolved = []
    for token in dependencies:
        candidate = Path(token)
        if not candidate.is_absolute():
            candidate = (Path(path).resolve().parent / candidate)
        resolved.append(candidate.resolve())
    return resolved


def check_aux_bundle(section, aux_bundle, lock, lock_path):
    """Bind the auxiliary include source to the verified repaired simulator
    engine of the SAME pinned commit, so platform-mixed includes can never
    silently come from a different source.  Consumes the retained restore
    report and canonical repair receipt, then verifies the complete auxiliary
    bundle manifest."""
    if 'auxiliaryInput' not in section:
        raise RepairError('lock lists auxiliaryIncludes but no auxiliaryInput identity')
    expected = section['auxiliaryInput']
    aux_bundle = Path(aux_bundle).resolve()
    report, report_sha = load_evidence(
        aux_bundle / 'restore-report.json', 'auxiliary restore report')
    require_evidence_field(report, 'baseEngineRunID', str(expected['runID']),
                           'auxiliary restore report')
    require_evidence_field(report, 'provenanceArtifactSHA256',
                           expected['artifactSHA256'],
                           'auxiliary restore report')
    require_evidence_field(report, 'sourceCommit', lock['engine']['commit'],
                           'auxiliary restore report')
    require_evidence_true(report, 'restoreVerified', 'auxiliary restore report')
    require_evidence_true(report, 'provenanceBound', 'auxiliary restore report')
    require_evidence_true(report, 'allSampledObjectsIOSSIMULATOR',
                          'auxiliary restore report')
    manifest_path = aux_bundle / 'bundle-manifest.json'
    if not manifest_path.is_file():
        raise RepairError(f'auxiliary bundle has no bundle-manifest.json: {aux_bundle}')
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('sourceCommit') != lock['engine']['commit']:
        raise RepairError('auxiliary bundle source differs from the pinned commit')
    simulator = lock['platforms'].get('IOSSIMULATOR')
    archive = aux_bundle / simulator['archiveBundlePath']
    if digest(archive) != simulator['archive']['patchedSHA256']:
        raise RepairError(
            'auxiliary bundle is not the verified repaired simulator engine '
            '(its libvcllo.a does not match the tracked patched archive SHA)')
    # The auxiliary bundle must carry the canonical repair receipt for the
    # simulator platform: a hand-restored tree without the tracked contract
    # can never satisfy the device repair's auxiliary include roots.
    canonical = manifest_block(aux_bundle, lock_path=lock_path,
                               platform='IOSSIMULATOR')
    # Full auxiliary manifest verification (every file, directory and symlink).
    verified = verify_bundle(aux_bundle, prepare=False)
    return {
        'bundle': str(aux_bundle),
        'restoreReport': 'restore-report.json',
        'restoreReportSHA256': report_sha,
        'runID': str(report['baseEngineRunID']),
        'artifactSHA256': report['provenanceArtifactSHA256'],
        'sourceCommit': report['sourceCommit'],
        'patchedArchiveSHA256': simulator['archive']['patchedSHA256'],
        'manifestFilesVerified': verified['filesVerified'],
        'engineRepairReceipt': canonical,
        'restoreVerified': True,
        'provenanceBound': True,
    }


def run_compile(command, log_path):
    with Path(log_path).open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RepairError(f'compile failed (see {log_path})')


# --------------------------------------------------------------------------
# Public operations.
# --------------------------------------------------------------------------

def repair_state(bundle, section, lock, engine_source=None):
    """Read-only state report used by --check and before --apply."""
    bundle = Path(bundle).resolve()
    manifest, entry, archive = check_bundle_manifest(bundle, section, lock)
    state, observed, manifest_match = archive_state(archive, entry, section)
    report = {
        'platform': section['platform'],
        'bundle': str(bundle),
        'bundleSourceCommit': manifest.get('sourceCommit'),
        'archiveBundlePath': section['archiveBundlePath'],
        'archiveSHA256': observed['sha256'],
        'archiveSize': observed['size'],
        'manifestEntryMatchesArchive': manifest_match,
        'state': state if (manifest_match or state == 'mismatch') else
                 f'{state}+stale-manifest',
        'receiptPresent': (bundle / RECEIPT_NAME).is_file(),
    }
    if state in ('original', 'patched'):
        members = read_ar_members(archive)
        member, position = find_member(
            members, section['member']['name'],
            section['member']['position'], section['member']['count'])
        content = read_member(archive, member)
        expected_sha = (section['member']['originalSHA256'] if state == 'original'
                        else section['member']['patchedSHA256'])
        report['memberVerified'] = digest_bytes(content) == expected_sha
        report['memberPosition'] = position
        report['memberCount'] = len(members)
        report['memberHeaderMatchesLock'] = (
            member.mtime == section['member']['mtime']
            and member.uid == section['member']['uid']
            and member.gid == section['member']['gid']
            and member.mode == section['member']['mode'])
    if engine_source is not None:
        failures, identity = check_toolchain(section)
        report['toolchainMatchesLock'] = not failures
        report['toolchainFailures'] = failures
        report['xcodeVersion'] = identity.get('xcodeVersion')
        report['sdkBuildVersion'] = identity.get('sdkBuildVersion')
    return report


def apply(bundle, engine_source, lock_path, platform, receipt_out=None,
          aux_bundle=None):
    lock, section, lock_path = load_lock(lock_path, platform)
    bundle = Path(bundle).resolve()
    engine_source = Path(engine_source).resolve()
    patch = check_patch_file(lock, lock_path)
    source_file = check_engine_source(engine_source, lock)
    input_evidence = verify_input_evidence(section, bundle, lock, lock_path)
    aux_evidence = None
    if section['compile'].get('auxiliaryIncludes'):
        aux_evidence = check_aux_bundle(section, aux_bundle, lock, lock_path)
    else:
        aux_bundle = None

    # Input identity from the lock (staged engine or complete-inputs archive).
    input_spec = section['input']
    state = repair_state(bundle, section, lock, engine_source=engine_source)
    if not state['manifestEntryMatchesArchive']:
        raise RepairError(
            'bundle manifest does not match its archive; restore a fresh bundle')
    if state['state'] == 'patched':
        raise RepairError(
            'archive already carries the patched member; refusing to re-apply')
    if state['state'] != 'original':
        raise RepairError(
            f'archive is neither the locked original nor the locked patched '
            f'archive (sha256 {state["archiveSHA256"]}); refuse to touch it')
    toolchain_failures, identity = check_toolchain(section)
    if toolchain_failures:
        raise RepairError('toolchain identity failed: ' + '; '.join(toolchain_failures))
    # The complete input manifest is re-verified before anything is mutated;
    # the final verification after the manifest-entry update repeats it.
    try:
        verify_bundle(bundle, prepare=False)
    except ValueError as failure:
        raise RepairError(f'input bundle verification failed: {failure}')

    manifest, manifest_entry, archive = check_bundle_manifest(bundle, section, lock)
    members_before = read_ar_members(archive)
    if not members_before or not members_before[0].name.startswith('__.SYMDEF'):
        raise RepairError('archive has no leading __.SYMDEF ranlib table')
    symdef_before = members_before[0]
    # Independent pre-mutation snapshot: per-member digests and headers are
    # captured from the untouched archive and later compared against the
    # rewritten one, so the unrelated-member audit cannot be satisfied by
    # reading the same mutated bytes twice.
    snapshot_before = snapshot_members(archive)
    symdef_bytes_before = read_member(archive, symdef_before)
    member, position = find_member(
        members_before, section['member']['name'],
        section['member']['position'], section['member']['count'])
    original_member = read_member(archive, member)
    if digest_bytes(original_member) != section['member']['originalSHA256']:
        raise RepairError(
            'locked member SHA does not match the archive member; the archive '
            'drifted from the tracked contract')
    if snapshot_before[members_before.index(member)]['sha256'] != \
            section['member']['originalSHA256']:
        raise RepairError('pre-mutation member snapshot disagrees with the lock')

    started = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    closure = None
    with tempfile.TemporaryDirectory(prefix='floe-engine-repair-') as temporary:
        work = Path(temporary)
        # 1. Pristine reconstruction proof: compile the pinned source unchanged
        #    and require byte-identity with the pinned archive member.
        pristine_object = work / 'virdev.pristine.o'
        pristine_source = work / 'virdev.pristine.cxx'
        shutil.copyfile(source_file, pristine_source)
        depfile = work / 'pristine.d' if section['compile'].get('auxiliaryIncludes') else None
        command = build_compile_command(section, engine_source, bundle,
                                        pristine_source, pristine_object,
                                        aux_bundle=aux_bundle, depfile=depfile)
        run_compile(command, work / 'pristine-compile.log')
        if digest(pristine_object) != section['member']['originalSHA256']:
            raise RepairError(
                'pristine recompile is not byte-identical to the pinned member; '
                'the reconstructed recipe does not reproduce this archive '
                '(refusing to proceed with a different toolchain or flags)')
        if depfile is not None:
            closure = verify_auxiliary_closure(section, aux_bundle, depfile)

        # 2. Patched compile from the tracked patch only.
        patched_source = apply_patch_to_copy(
            patch, source_file, work, lock['repair']['patchedSourceSHA256'])
        patched_object = work / 'virdev.patched.o'
        command = build_compile_command(section, engine_source, bundle,
                                        patched_source, patched_object,
                                        aux_bundle=aux_bundle)
        run_compile(command, work / 'patched-compile.log')
        if digest(patched_object) != section['member']['patchedSHA256']:
            raise RepairError(
                'patched compile does not reproduce the locked patched member '
                'SHA-256; the recipe or toolchain drifted')

        # 3. Replace exactly one member; pin the ar header for reproducibility.
        replacement = work / 'virdev.o'
        shutil.copyfile(patched_object, replacement)
        os.chmod(replacement, int(str(section['member']['mode']), 8))
        os.utime(replacement, (section['member']['mtime'], section['member']['mtime']))
        if (section['member']['uid'], section['member']['gid']) != (os.getuid(), os.getgid()):
            try:
                os.chown(replacement, section['member']['uid'], section['member']['gid'])
            except PermissionError as failure:
                raise RepairError(
                    f'cannot pin the member uid/gid to the locked values: {failure}')
        subprocess.run(['ar', 'r', str(archive), str(replacement)],
                       check=True, capture_output=True)
        subprocess.run(['ranlib', str(archive)], check=True, capture_output=True)

    # 4. Independent whole-archive audit against the pre-mutation snapshot:
    #    count/order, every non-target member's digest and header, the explicit
    #    __.SYMDEF rule and the locked whole-archive hash.  The audit never
    #    proves "unchanged" by reading the rewritten archive twice: it compares
    #    the mutated bytes against digests taken before any mutation.
    members_after = read_ar_members(archive)
    snapshot_after = snapshot_members(archive)
    names_before = [item['name'] for item in snapshot_before]
    names_after = [item['name'] for item in snapshot_after]
    if names_before != names_after:
        raise RepairError('member order or count changed during replacement')
    symdef_after = members_after[0]
    if not symdef_after.name.startswith('__.SYMDEF') or \
            read_member(archive, symdef_after) != symdef_bytes_before:
        raise RepairError('ranlib table content changed; refusing')
    rewrite_member_mtime(archive, symdef_after, section['archive']['symdefMTime'])
    snapshot_after = snapshot_members(archive)
    symdef_snapshot_before = snapshot_before[0]
    symdef_snapshot_after = snapshot_after[0]
    if (symdef_snapshot_after['mtime'], symdef_snapshot_after['uid'],
            symdef_snapshot_after['gid'], symdef_snapshot_after['mode'],
            symdef_snapshot_after['size']) != \
       (section['archive']['symdefMTime'], symdef_snapshot_before['uid'],
            symdef_snapshot_before['gid'], symdef_snapshot_before['mode'],
            symdef_snapshot_before['size']) or \
            symdef_snapshot_after['sha256'] != symdef_snapshot_before['sha256']:
        raise RepairError('ranlib table drifted from the locked identity')
    changed = []
    target_after = None
    for before, after in zip(snapshot_before, snapshot_after):
        if after['name'] == section['member']['name']:
            target_after = after
            continue
        if after['name'].startswith('__.SYMDEF'):
            continue
        if (before['mtime'], before['uid'], before['gid'], before['mode'],
                before['size']) != (after['mtime'], after['uid'], after['gid'],
                after['mode'], after['size']) \
                or before['sha256'] != after['sha256']:
            changed.append(before['name'])
    if changed:
        raise RepairError('unrelated archive members changed: ' + ', '.join(changed[:5]))
    if target_after is None:
        raise RepairError('the replaced member disappeared during replacement')
    if target_after['sha256'] != section['member']['patchedSHA256']:
        raise RepairError(
            'replaced member digest does not match the locked patched member')
    if (target_after['mtime'], target_after['uid'], target_after['gid'],
            target_after['mode']) != \
       (section['member']['mtime'], section['member']['uid'],
            section['member']['gid'], section['member']['mode']):
        raise RepairError('replaced member header drifted from the locked identity')
    patched_archive_sha = digest(archive)
    if patched_archive_sha != section['archive']['patchedSHA256']:
        raise RepairError(
            f'patched archive SHA {patched_archive_sha} != locked '
            f'{section["archive"]["patchedSHA256"]}')

    # 5. Update exactly the one bundle-manifest entry and re-verify everything.
    manifest_path = bundle / 'bundle-manifest.json'
    manifest_sha_before = digest(manifest_path)
    updated = dict(manifest_entry)
    updated['size'] = archive.stat().st_size
    updated['sha256'] = patched_archive_sha
    manifest['files'] = [updated if item is manifest_entry else item
                         for item in manifest['files']]
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    try:
        verification = verify_bundle(bundle, prepare=False)
    except ValueError as failure:
        raise RepairError(f'patched bundle verification failed: {failure}')

    try:
        lock_display = str(Path(lock_path).relative_to(THIS_DIR.parent.parent))
    except ValueError:
        lock_display = str(Path(lock_path))
    receipt = {
        'kind': 'floe-office-single-member-engine-repair',
        'platform': platform,
        'startedAt': started,
        'completedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'lock': {'path': lock_display,
                 'sha256': lock['lockSHA256']},
        'engine': dict(lock['engine']),
        'repair': {
            'patch': lock['repair']['patch'],
            'patchSHA256': lock['repair']['patchSHA256'],
            'upstreamCommit': lock['repair']['upstreamCommit'],
            'upstreamRepository': lock['repair']['upstreamRepository'],
            'sourceFile': lock['repair']['sourceFile'],
            'originalSourceSHA256': lock['repair']['originalSourceSHA256'],
            'patchedSourceSHA256': lock['repair']['patchedSourceSHA256'],
        },
        'input': dict(input_spec),
        'inputEvidence': input_evidence,
        'auxiliaryInput': (dict(section['auxiliaryInput'])
                           if 'auxiliaryInput' in section else None),
        'auxiliaryInputEvidence': aux_evidence,
        'bundle': {
            'root': str(bundle),
            'sourceCommit': manifest.get('sourceCommit'),
            'manifestSHA256': {'before': manifest_sha_before,
                               'after': digest(manifest_path)},
            'manifestEntry': {'path': section['archiveBundlePath'],
                              'size': updated['size'], 'sha256': updated['sha256']},
        },
        'archive': {
            'bundlePath': section['archiveBundlePath'],
            'originalSHA256': section['archive']['originalSHA256'],
            'patchedSHA256': patched_archive_sha,
            'memberCount': len(members_after),
            'memberOrderPreserved': True,
            'unrelatedMembersUnchanged': True,
            'symdefMTime': section['archive']['symdefMTime'],
            'memberAudit': {
                'method': 'pre-mutation per-member digest and header snapshot',
                'membersSnapshotted': len(snapshot_before),
                'symdefContentPreserved': True,
            },
            'member': {
                'name': section['member']['name'],
                'position': position,
                'originalSHA256': section['member']['originalSHA256'],
                'patchedSHA256': section['member']['patchedSHA256'],
                'mtime': section['member']['mtime'],
                'uid': section['member']['uid'],
                'gid': section['member']['gid'],
                'mode': section['member']['mode'],
            },
        },
        'compile': {
            'sdk': section['compile']['sdk'],
            'target': section['compile']['target'],
            'flags': section['compile']['flags'],
            'sourceIncludeCount': len(section['compile']['sourceIncludes']),
            'bundleIncludeCount': len(section['compile']['bundleIncludes']),
            'auxiliaryIncludeCount': len(section['compile'].get('auxiliaryIncludes', [])),
            'auxiliaryHeaderClosureCount': len(closure or []),
            'auxiliaryHeaderClosureSHA256': (
                digest_bytes(json.dumps(closure, sort_keys=True).encode())
                if closure else None),
            'pristineRecompileByteIdentical': True,
            'patchedObjectSHA256': section['member']['patchedSHA256'],
            'xcodeVersion': identity['xcodeVersion'],
            'sdkVersion': identity['sdkVersion'],
            'sdkBuildVersion': identity['sdkBuildVersion'],
            'sdkPath': identity['sdkPath'],
            'flagDerivation': section['compile'].get('flagDerivation'),
        },
        'bundleVerify': verification,
        'hostKind': 'fullFloeAppSimulator' if platform == 'IOSSIMULATOR'
                    else 'floeNativeOfficeHost',
    }
    receipt_path = Path(receipt_out) if receipt_out else bundle / RECEIPT_NAME
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


def expected_manifest_block(lock, section):
    """The compact engineRepair identity a host manifest/receipt must carry."""
    return {
        'patchSHA256': lock['repair']['patchSHA256'],
        'upstreamCommit': lock['repair']['upstreamCommit'],
        'sourceFile': lock['repair']['sourceFile'],
        'originalSourceSHA256': lock['repair']['originalSourceSHA256'],
        'patchedSourceSHA256': lock['repair']['patchedSourceSHA256'],
        'platform': section['platform'],
        'sdk': section['compile']['sdk'],
        'target': section['compile']['target'],
        'archiveBundlePath': section['archiveBundlePath'],
        'originalArchiveSHA256': section['archive']['originalSHA256'],
        'patchedArchiveSHA256': section['archive']['patchedSHA256'],
        'member': {
            'name': section['member']['name'],
            'position': section['member']['position'],
            'count': section['member']['count'],
            'originalSHA256': section['member']['originalSHA256'],
            'patchedSHA256': section['member']['patchedSHA256'],
        },
        'lockSHA256': lock['lockSHA256'],
    }


def receipt_manifest_block(receipt):
    """The same identity from an apply receipt (produced by this module)."""
    return {
        'patchSHA256': receipt['repair']['patchSHA256'],
        'upstreamCommit': receipt['repair']['upstreamCommit'],
        'sourceFile': receipt['repair']['sourceFile'],
        'originalSourceSHA256': receipt['repair']['originalSourceSHA256'],
        'patchedSourceSHA256': receipt['repair']['patchedSourceSHA256'],
        'platform': receipt['platform'],
        'sdk': receipt['compile']['sdk'],
        'target': receipt['compile']['target'],
        'archiveBundlePath': receipt['archive']['bundlePath'],
        'originalArchiveSHA256': receipt['archive']['originalSHA256'],
        'patchedArchiveSHA256': receipt['archive']['patchedSHA256'],
        'member': {
            'name': receipt['archive']['member']['name'],
            'position': receipt['archive']['member']['position'],
            'count': receipt['archive']['memberCount'],
            'originalSHA256': receipt['archive']['member']['originalSHA256'],
            'patchedSHA256': receipt['archive']['member']['patchedSHA256'],
        },
        'lockSHA256': receipt['lock']['sha256'],
    }


def manifest_block(bundle_root, lock_path=DEFAULT_LOCK, platform=None):
    """Fail-closed engineRepair block for a (repaired) bundle.

    Returns None when the tracked repair lock has no contract for the
    platform (backward compatibility). Raises RepairError when the contract
    exists but the bundle carries no receipt, or the receipt disagrees with
    the tracked lock in any field.
    """
    lock, section, lock_path = load_lock(lock_path, platform)
    receipt_path = Path(bundle_root) / RECEIPT_NAME
    if not receipt_path.is_file():
        raise RepairError(
            f'tracked engine repair contract for {platform} but the bundle has '
            f'no {RECEIPT_NAME}; run office_engine_repair.py apply first')
    receipt = json.loads(receipt_path.read_text())
    expected = expected_manifest_block(lock, section)
    actual = receipt_manifest_block(receipt)
    if actual != expected:
        differences = sorted(key for key in expected
                             if json.dumps(expected[key], sort_keys=True)
                             != json.dumps(actual.get(key), sort_keys=True))
        raise RepairError(
            'bundle engine repair receipt disagrees with the tracked lock: '
            + ', '.join(differences))
    return actual


def tracked_contract(lock_path=DEFAULT_LOCK, platform=None):
    """(lock, section) when a tracked contract exists for the platform, else
    (None, None). Used by consumers that must fail closed once a contract is
    tracked but stay backward compatible before one exists."""
    lock_path = Path(lock_path)
    if not lock_path.is_file():
        return None, None
    try:
        lock, section, _ = load_lock(lock_path, platform)
        return lock, section
    except RepairError as failure:
        if 'no engine repair contract for platform' in str(failure):
            return None, None
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('apply', 'check'))
    parser.add_argument('--platform', choices=PLATFORMS, required=True)
    parser.add_argument('--bundle', type=Path, required=True,
                        help='Restored, verified engine bundle root (bundle-manifest.json inside)')
    parser.add_argument('--engine-source', type=Path, default=None,
                        help='Git checkout of the pinned engine commit supplying '
                             'the source file and include roots (required for apply)')
    parser.add_argument('--aux-bundle', type=Path, default=None,
                        help='Restored, verified repaired simulator engine tree '
                             'supplying auxiliary include roots when the lock '
                             'section declares auxiliaryIncludes (IOS)')
    parser.add_argument('--lock', type=Path, default=DEFAULT_LOCK)
    parser.add_argument('--receipt-out', type=Path, default=None,
                        help='Where to write the repair receipt (default <bundle>/engine-repair.json)')
    args = parser.parse_args()
    try:
        if args.command == 'check':
            _, section, _ = load_lock(args.lock, args.platform)
            report = repair_state(args.bundle, section,
                                  json.loads(Path(args.lock).read_text()),
                                  engine_source=args.engine_source)
            report['readOnly'] = True
            print(json.dumps(report, indent=2))
            return 0 if not str(report['state']).startswith('mismatch') else 1
        if args.engine_source is None:
            raise RepairError('apply requires --engine-source')
        receipt = apply(args.bundle, args.engine_source, args.lock,
                        args.platform, receipt_out=args.receipt_out,
                        aux_bundle=args.aux_bundle)
        print(json.dumps(receipt, indent=2))
        return 0
    except RepairError as failure:
        print(f'engine repair: {failure}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
