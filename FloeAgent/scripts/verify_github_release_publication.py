#!/usr/bin/env python3
"""Read-only gate proving a published GitHub App release is an installable delivery.

Every public App release must be a published stable (draft=false, prerelease=false)
release on the immutable tag, marked latest, carrying the verified unsigned device
IPA plus its checksum sidecar. A source archive alone is never an installable
delivery: the historical source-only fallback (v1.7.34, build 275) is a recorded
exception, not a precedent. AltStore/Feather feed freshness depends on exactly
these published assets, so both ``release-unsigned-ipa.yml`` publish jobs call
this verifier immediately after every create/edit and the local or manual release
runbook must run it before any delivery is marked complete.

Nothing here performs a network call or a publication. The caller captures the
GitHub state with read-only ``gh api`` dumps (release, tag ref, tag object and
releases/latest) and passes the JSON files in. When a staged asset directory is
provided, the verifier re-binds the local bytes with the same full IPA audit the
retained-artifact verifier applies (no signing material, exactly one app bundle,
exact bundle/version/build identity, sidecar content) and requires them to match
the remote asset digest and size, so a passing report proves the published
bytes, not just a filename. The staged IPA must additionally be a real iOS
*device* build: its ``Info.plist`` must name the iphoneos SDK/platform and the
app's actual main executable must be an arm64 Mach-O with an iOS device
``LC_BUILD_VERSION``/``LC_VERSION_MIN_IPHONEOS`` load command. A simulator
binary renamed to the canonical unsigned asset therefore cannot pass even when
its version/build identity and digest match. Every failure is fail-closed and
lists the exact attach/repair actions for the existing published release; the
tag is never moved.

The source binding is taken from the Git objects, not from filenames: the tag
ref itself must be ``refs/tags/<expected tag>``; for an annotated tag the tag
object under the ref's object SHA must carry that same expected tag name and
peel to the expected commit. A tag object dump for some other tag cannot be
substituted.

Source-only classification exists only for non-App artifacts (for example the
Linux guest image releases). An App-shaped tag (vX.Y.Z or vX.Y.Z-beta.N) can
never pass as source-only: the verifier refuses that combination so an
IPA-required App release cannot silently satisfy a source-only fallback.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import struct
import sys
import zipfile

_HERE = Path(__file__).resolve().parent

# Reuse the retained-artifact verifier's identity contracts (bundle identifier,
# tag/digest regexes and the full IPA audit) instead of redefining them here.
_spec = importlib.util.spec_from_file_location(
    'floe_direct_unsigned', _HERE / 'verify_direct_unsigned_artifact.py')
_direct = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_direct)

BUNDLE_IDENTIFIER = _direct.BUNDLE_IDENTIFIER
SHA256_RE = _direct.SHA256_RE
DIGEST_RE = _direct.DIGEST_RE
ASSET_NAME_RE = re.compile(r'^Floe-Agent-([0-9]+\.[0-9]+\.[0-9]+)-build([0-9]+)-unsigned\.ipa$')
TRANSPORT_NAME_RE = re.compile(r'^local-device(\.zip)?(\.part[0-9]{2,})?$')

MODE_APP = 'app'
MODE_SOURCE_ONLY = 'source-only'


class PublicationError(ValueError):
    """The published release state violates the installable-delivery contract."""


class UsageError(ValueError):
    """The verifier inputs themselves are incomplete or malformed."""


def require(condition: object, message: str) -> None:
    if not condition:
        raise PublicationError(message)


def load_json(path: Path, label: str) -> dict:
    require(isinstance(path, Path) and path.is_file() and not path.is_symlink(),
            f'Missing or unsafe {label} JSON input: {path}')
    try:
        payload = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError) as error:
        raise UsageError(f'Unreadable {label} JSON input {path}: {error}') from error
    require(isinstance(payload, dict), f'Expected a JSON object in the {label} input')
    return payload


def peel_tag_commit(tag_ref: dict, tag_object: dict, expected_tag: str) -> tuple[str, str]:
    """Return (commit_sha, tag_style) bound by the actual Git objects.

    The ref name, the ref's object SHA, the annotated tag object's own SHA and
    its tag name must all agree with the requested tag. Otherwise a tag object
    dump for an unrelated tag could substitute the expected commit.
    """
    require(tag_ref.get('ref') == f'refs/tags/{expected_tag}',
            f"Tag ref JSON names ref {tag_ref.get('ref')!r}, expected 'refs/tags/{expected_tag}'; "
            'refusing to bind an unrelated tag object (anti-tag-substitution)')
    object_ref = tag_ref.get('object')
    require(isinstance(object_ref, dict) and object_ref.get('type') in ('tag', 'commit')
            and SHA256_RE.fullmatch(str(object_ref.get('sha') or '')),
            'Tag ref JSON has no usable object {type, sha}; refusing to guess the source')
    if object_ref['type'] == 'commit':
        return object_ref['sha'], 'lightweight'
    require(tag_object.get('sha') == object_ref['sha'],
            f"Tag object JSON is {tag_object.get('sha')!r}, not the ref's object "
            f"{object_ref['sha']!r}; refusing an unrelated tag object")
    require(tag_object.get('tag') == expected_tag,
            f"Tag object JSON names tag {tag_object.get('tag')!r}, expected {expected_tag!r}; "
            'refusing to bind a different tag')
    inner = tag_object.get('object')
    require(isinstance(inner, dict) and inner.get('type') == 'commit'
            and SHA256_RE.fullmatch(str(inner.get('sha') or '')),
            'Annotated tag object JSON does not peel to a commit; refusing to guess')
    return inner['sha'], 'annotated'


# Mach-O constants for the executable proof. A published App IPA must be a real
# arm64 iOS device binary, not merely a zip whose Info.plist identity matches.
_MH_MAGIC_64 = 0xFEEDFACF
_MH_EXECUTE = 0x2
_CPU_TYPE_ARM64 = 0x0100000C
_LC_VERSION_MIN_IPHONEOS = 0x25
_LC_BUILD_VERSION = 0x32
_PLATFORM_IOS = 2
_MAX_LOAD_COMMANDS = 4096
_MAX_LOAD_COMMAND_BYTES = 1024 * 1024
_MAX_EXECUTABLE_BYTES = 512 * 1024 * 1024


def macho_images(data: bytes) -> list:
    """Return the thin Mach-O images inside a thin or universal binary."""
    require(len(data) >= 8, 'App main executable is truncated')
    if struct.unpack_from('<I', data, 0)[0] in (_MH_MAGIC_64, 0xFEEDFACE):
        return [data]
    magic = struct.unpack_from('>I', data, 0)[0]
    if magic not in (0xCAFEBABE, 0xCAFEBABF):
        raise PublicationError('App main executable is not a Mach-O binary')
    wide = magic == 0xCAFEBABF
    count = struct.unpack_from('>I', data, 4)[0]
    width = 32 if wide else 20
    require(0 < count <= 64 and 8 + count * width <= len(data),
            'Universal app executable has an invalid architecture table')
    images = []
    for index in range(count):
        fields = struct.unpack_from('>IIQQII' if wide else '>IIIII', data,
                                    8 + index * width)
        offset, size = fields[2], fields[3]
        require(size > 0 and offset + size <= len(data),
                'Universal app executable slice lies outside the file')
        images.append(data[offset:offset + size])
    return images


def macho_device_platform(image: bytes) -> tuple[int, int]:
    """Return (cputype, load-command style) only for an iOS device executable."""
    require(len(image) >= 32, 'App executable Mach-O header is truncated')
    magic, cpu, _, filetype, count, size, _, _ = struct.unpack_from('<IiiIIIII', image, 0)
    require(magic == _MH_MAGIC_64,
            'App main executable is not a 64-bit Mach-O binary')
    require(cpu == _CPU_TYPE_ARM64,
            f'App main executable is not arm64 (cputype {cpu:#x}); a device IPA must ship arm64')
    require(filetype == _MH_EXECUTE,
            'App main executable is not an MH_EXECUTE Mach-O image')
    require(0 < count <= _MAX_LOAD_COMMANDS and 0 <= size <= _MAX_LOAD_COMMAND_BYTES
            and 32 + size <= len(image),
            'App executable has invalid Mach-O load-command bounds')
    commands = image[32:32 + size]
    offset, platforms = 0, []
    for _ in range(count):
        require(offset + 8 <= size, 'App executable has a truncated load command')
        command, length = struct.unpack_from('<II', commands, offset)
        require(length >= 8 and length % 4 == 0 and offset + length <= size,
                'App executable has an invalid load-command size')
        if command == _LC_BUILD_VERSION:
            require(length >= 24, 'App executable has a truncated LC_BUILD_VERSION')
            platforms.append((struct.unpack_from('<I', commands, offset + 8)[0],
                              'LC_BUILD_VERSION'))
        elif command == _LC_VERSION_MIN_IPHONEOS:
            platforms.append((_PLATFORM_IOS, 'LC_VERSION_MIN_IPHONEOS'))
        offset += length
    require(offset == size, 'App executable load commands do not fill the declared size')
    require(len(platforms) == 1,
            'App executable must carry exactly one iOS platform declaration')
    require(platforms[0][0] == _PLATFORM_IOS,
            f'App main executable builds for platform {platforms[0][0]}, not iOS device '
            f'({_PLATFORM_IOS}); simulator or foreign-platform binaries are refused')
    return cpu, platforms[0][1]


def audit_staged_ipa(staged_dir: Path, expect: dict) -> dict:
    """Audit one staged local IPA with the shared unsigned + device contracts.

    This is the single audit used both by the pre-attestation local publish step
    and by the post-publish verifier, so a canonical-named simulator or malformed
    IPA is rejected before any attestation or public release write.
    """
    require(staged_dir.is_dir() and not staged_dir.is_symlink(),
            f'staged asset directory is not a regular directory: {staged_dir}')
    ipa_name = expect['ipa_name']
    staged_ipa = staged_dir / ipa_name
    staged_sidecar = staged_dir / (ipa_name + '.sha256')
    require(staged_ipa.is_file() and not staged_ipa.is_symlink(),
            f'staged directory has no {ipa_name}')
    require(staged_sidecar.is_file() and not staged_sidecar.is_symlink(),
            f'staged directory has no {ipa_name}.sha256')
    # Full retained-artifact audit: unsigned (no signing material), exactly one
    # app bundle, Info.plist bundle/version/build identity, sidecar content.
    local_plist, local_fields = _direct.verify_ipa(staged_ipa, staged_sidecar, {
        'bundle_id': expect['bundle_id'], 'version': expect['version'],
        'build': expect['build']})
    # A canonical filename and matching plist identity are not enough: the
    # actual main executable must be an arm64 iOS device Mach-O.
    device_binary = verify_device_executable(staged_ipa, local_plist,
                                             local_fields['appRoot'])
    return {'sha256': local_fields['sha256'], 'bytes': local_fields['bytes'],
            'appRoot': local_fields['appRoot'],
            'minimumOSVersion': local_plist.get('MinimumOSVersion'),
            'deviceBinary': device_binary}


def verify_device_executable(ipa: Path, plist: dict, app_root: str) -> dict:
    """Prove the staged IPA is a real arm64 iOS device build, not a simulator one."""
    sdk = plist.get('DTSDKName')
    platform = plist.get('DTPlatformName')
    require(isinstance(sdk, str) and sdk.startswith('iphoneos'),
            f'App Info.plist DTSDKName is {sdk!r}, not an iphoneos device SDK; a simulator '
            'build renamed to the canonical unsigned asset is refused')
    require(platform == 'iphoneos',
            f'App Info.plist DTPlatformName is {platform!r}, not iphoneos; a simulator '
            'build renamed to the canonical unsigned asset is refused')
    executable = plist.get('CFBundleExecutable')
    require(isinstance(executable, str) and executable not in ('', '.', '..')
            and '/' not in executable and '\\' not in executable,
            f'App Info.plist CFBundleExecutable is not a simple file name: {executable!r}')
    member = f'{app_root}/{executable}'
    with zipfile.ZipFile(ipa) as bundle:
        info = bundle.getinfo(member) if member in bundle.namelist() else None
        require(info is not None and not info.is_dir(),
                f'app main executable {member!r} is missing from the staged IPA')
        require(0 < info.file_size <= _MAX_EXECUTABLE_BYTES,
                'app main executable is empty or larger than the audit bound')
        data = bundle.read(member)
    images = macho_images(data)
    require(images, 'app main executable contains no Mach-O image')
    for image in images:
        # Raises for non-arm64, non-MH_EXECUTE or non-iOS-device slices.
        macho_device_platform(image)
    return {'executable': executable, 'architecture': 'arm64', 'platform': 'IOS',
            'slices': len(images), 'deviceLoadCommands': True}


def asset_index(assets: object) -> dict:
    require(isinstance(assets, list), 'Release JSON has no asset list')
    index: dict = {}
    for entry in assets:
        require(isinstance(entry, dict) and isinstance(entry.get('name'), str),
                'Release asset entry is malformed')
        index.setdefault(entry['name'], []).append(entry)
    return index


def classify_names(index: dict, *, violations: list, tag: str) -> list:
    """Return every asset name while failing on unsafe exposure."""
    for name in index:
        if name.endswith(('.mobileprovision', '.p12', '.dSYM')):
            violations.append(f'release {tag} exposes signing or symbol material: {name}')
        if name == 'FloeAgent.ipa' or (name.endswith('.ipa') and not name.endswith('-unsigned.ipa')):
            violations.append(f'release {tag} exposes a signed/simulator or unlabeled IPA: {name}')
        if TRANSPORT_NAME_RE.fullmatch(name):
            violations.append(f'release {tag} exposes a private transport archive: {name}')
        if 'symbols' in name or name.endswith('.xcarchive'):
            violations.append(f'release {tag} exposes a private artifact name: {name}')
    return sorted(index)


def verify_app_publish(*, release: dict, tag_ref: dict, tag_object: dict, latest: dict,
                      expect: dict, staged_dir: Path | None,
                      allow_prerelease: bool, prerelease_reason: str) -> dict:
    violations: list = []
    require(release.get('tag_name') == expect['tag'],
            f"Release JSON is for tag {release.get('tag_name')!r}, expected {expect['tag']!r}")
    require(isinstance(release.get('id'), int) and release['id'] > 0,
            'Release JSON has no numeric release id')
    require(release.get('draft') is False,
            f"release {expect['tag']} is still a draft; delivery is incomplete (safe partial "
            'state: finish assets, verify, then publish — never publish first)')
    require(release.get('published_at') not in (None, ''),
            f"release {expect['tag']} has no published_at timestamp")

    if release.get('prerelease') is not False:
        if not allow_prerelease:
            violations.append(
                f"release {expect['tag']} is a prerelease; the normal App release must be stable "
                '(draft=false, prerelease=false) or the AltStore/Feather latest pointer goes stale')
        else:
            require(bool(prerelease_reason),
                    'an App release may only be a prerelease with --prerelease-reason')

    commit, tag_style = peel_tag_commit(tag_ref, tag_object, expect['tag'])
    require(commit == expect['source_sha'],
            f"tag {expect['tag']} peels to {commit}, expected immutable source {expect['source_sha']}; "
            'refusing to bind a published release to the wrong build (anti-cross-build)')

    index = asset_index(release.get('assets'))
    names = classify_names(index, violations=violations, tag=expect['tag'])

    ipa_name, sidecar_name = expect['ipa_name'], expect['ipa_name'] + '.sha256'
    ipa_assets = index.get(ipa_name, [])
    sidecar_assets = index.get(sidecar_name, [])
    if len(ipa_assets) != 1:
        violations.append(f'missing or duplicated installable asset: expected exactly one {ipa_name!r} '
                          '(attach it to the existing published release; do not move the tag)')
    if len(sidecar_assets) != 1:
        violations.append(f'missing or duplicated checksum asset: expected exactly one {sidecar_name!r}')

    ipa_remote = ipa_assets[0] if len(ipa_assets) == 1 else None
    sidecar_remote = sidecar_assets[0] if len(sidecar_assets) == 1 else None
    for role, entry in (('IPA', ipa_remote), ('checksum', sidecar_remote)):
        if entry is not None and entry.get('state') != 'uploaded':
            violations.append(f'{role} asset {entry.get("name")!r} has state {entry.get("state")!r}, '
                              'not "uploaded" (partial upload failure; re-upload and re-verify)')

    digest = (ipa_remote or {}).get('digest')
    remote_sha = digest.removeprefix('sha256:') if isinstance(digest, str) else None
    if ipa_remote is not None:
        require(remote_sha is not None and DIGEST_RE.fullmatch(digest),
                f'remote asset {ipa_name!r} carries no sha256 digest for verification')
        if expect.get('ipa_sha256') and remote_sha != expect['ipa_sha256']:
            violations.append(f'remote IPA digest {remote_sha} != expected {expect["ipa_sha256"]}')
        if expect.get('ipa_bytes') is not None and ipa_remote.get('size') != expect['ipa_bytes']:
            violations.append(f'remote IPA size {ipa_remote.get("size")} != expected {expect["ipa_bytes"]}')

    staged: dict = {}
    if staged_dir is not None:
        staged = audit_staged_ipa(staged_dir, expect)
        if ipa_remote is not None:
            if staged['sha256'] != remote_sha:
                violations.append(
                    f'staged IPA digest {staged["sha256"]} != published remote digest '
                    f'{remote_sha} (the remote bytes are not the audited local build)')
            if staged['bytes'] != ipa_remote.get('size'):
                violations.append(f'staged IPA bytes {staged["bytes"]} != published remote size '
                                  f'{ipa_remote.get("size")}')

    if allow_prerelease:
        latest_state: dict = {'required': False, 'reason': prerelease_reason}
    else:
        require(isinstance(latest, dict) and latest.get('tag_name'),
                'latest-release JSON is required for a stable App release')
        latest_state = {'required': True, 'tag': latest.get('tag_name')}
        if latest.get('tag_name') != expect['tag']:
            violations.append(
                f"releases/latest points at {latest.get('tag_name')!r}, not {expect['tag']!r}; "
                'the newest stable App release must own the latest pointer so AltStore/Feather '
                'and GitHub "latest" resolve this installable build')

    return {
        'kind': MODE_APP,
        'installableDelivery': not violations,
        'tag': expect['tag'],
        'releaseId': release.get('id'),
        'releaseUrl': release.get('html_url'),
        'draft': release.get('draft'),
        'prerelease': release.get('prerelease'),
        'publishedAt': release.get('published_at'),
        'sourceCommit': commit,
        'tagStyle': tag_style,
        'version': expect['version'],
        'build': expect['build'],
        'bundleIdentifier': expect['bundle_id'],
        'ipa': None if ipa_remote is None else {
            'name': ipa_remote.get('name'), 'id': ipa_remote.get('id'),
            'state': ipa_remote.get('state'), 'bytes': ipa_remote.get('size'),
            'digest': ipa_remote.get('digest')},
        'sidecar': None if sidecar_remote is None else {
            'name': sidecar_remote.get('name'), 'id': sidecar_remote.get('id'),
            'state': sidecar_remote.get('state')},
        'staged': staged or None,
        'latest': latest_state,
        'otherAssetNames': [name for name in names if name not in (ipa_name, sidecar_name)],
        'violations': violations,
    }


def verify_source_only_publish(*, release: dict, tag_ref: dict | None,
                               tag_object: dict | None, expect_tag: str, reason: str) -> dict:
    violations: list = []
    require(release.get('tag_name') == expect_tag,
            f"Release JSON is for tag {release.get('tag_name')!r}, expected {expect_tag!r}")
    require(release.get('draft') is False, f'release {expect_tag} is still a draft')
    require(release.get('published_at') not in (None, ''), f'release {expect_tag} is not published')
    index = asset_index(release.get('assets'))
    names = classify_names(index, violations=violations, tag=expect_tag)
    for name in names:
        if name.endswith(('.ipa', '.dSYM', '.mobileprovision')):
            violations.append(f'source-only release {expect_tag} unexpectedly carries a binary: {name}')
    if tag_ref is not None and tag_object is not None:
        source_commit, tag_style = peel_tag_commit(tag_ref, tag_object, expect_tag)
    else:
        source_commit, tag_style = None, 'not-provided'
    return {
        'kind': MODE_SOURCE_ONLY,
        'installableDelivery': False,
        'sourceOnlyReason': reason,
        'tag': expect_tag,
        'releaseId': release.get('id'),
        'releaseUrl': release.get('html_url'),
        'draft': release.get('draft'),
        'prerelease': release.get('prerelease'),
        'publishedAt': release.get('published_at'),
        'sourceCommit': source_commit,
        'tagStyle': tag_style,
        'assetNames': names,
        'violations': violations,
    }


def run(args: argparse.Namespace) -> dict:
    release = load_json(args.release_json, 'release')
    if args.mode == MODE_APP:
        for label, path in (('tag-ref', args.tag_ref_json), ('tag-object', args.tag_object_json)):
            if path is None:
                raise UsageError(f'--{label}-json is required for an App release so the source '
                                 'commit is bound from the real ref, not from a filename')
        if args.latest_json is None and not args.allow_prerelease:
            raise UsageError('--latest-json is required for a stable App release unless '
                             '--allow-prerelease records an explicit prerelease decision')
        if not isinstance(args.expect_version, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',
                                                                        args.expect_version):
            raise UsageError('--expect-version must be MAJOR.MINOR.PATCH')
        if not isinstance(args.expect_build, str) or not re.fullmatch(r'[0-9]+', args.expect_build):
            raise UsageError('--expect-build must be numeric')
        if not isinstance(args.expect_source_sha, str) or not SHA256_RE.fullmatch(
                args.expect_source_sha):
            raise UsageError('--expect-source-sha must be a full 40-hex commit SHA')
        expect = {
            'tag': args.expect_tag,
            'version': args.expect_version,
            'build': args.expect_build,
            'source_sha': args.expect_source_sha,
            'bundle_id': args.bundle_id or BUNDLE_IDENTIFIER,
            'ipa_name': f'Floe-Agent-{args.expect_version}-build{args.expect_build}-unsigned.ipa',
            'ipa_sha256': args.expect_ipa_sha256,
            'ipa_bytes': args.expect_ipa_bytes,
        }
        if not ASSET_NAME_RE.fullmatch(expect['ipa_name']):
            raise UsageError('derived IPA asset name is not canonical')
        return verify_app_publish(
            release=release,
            tag_ref=load_json(args.tag_ref_json, 'tag-ref'),
            tag_object=load_json(args.tag_object_json, 'tag-object'),
            latest=load_json(args.latest_json, 'latest') if args.latest_json else {},
            expect=expect,
            staged_dir=args.staged_dir,
            allow_prerelease=args.allow_prerelease,
            prerelease_reason=args.prerelease_reason or '')
    # source-only mode is reserved for explicitly non-App artifacts.
    if _direct.TAG_RE.fullmatch(args.expect_tag):
        raise UsageError(f'--mode source-only cannot classify the App-shaped tag {args.expect_tag!r}; '
                         'an App release must carry the verified unsigned IPA (the historical '
                         'source-only fallback is not a supported delivery mode)')
    if not args.source_only_reason:
        raise UsageError('--source-only-reason is required for an explicit non-App source release')
    return verify_source_only_publish(
        release=release,
        tag_ref=load_json(args.tag_ref_json, 'tag-ref') if args.tag_ref_json else None,
        tag_object=load_json(args.tag_object_json, 'tag-object') if args.tag_object_json else None,
        expect_tag=args.expect_tag,
        reason=args.source_only_reason)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=(MODE_APP, MODE_SOURCE_ONLY), default=MODE_APP)
    parser.add_argument('--release-json', required=True, type=Path,
                        help='gh api repos/<repo>/releases/tags/<tag> JSON dump')
    parser.add_argument('--tag-ref-json', type=Path,
                        help='gh api repos/<repo>/git/ref/tags/<tag> JSON dump')
    parser.add_argument('--tag-object-json', type=Path,
                        help='gh api repos/<repo>/git/tags/<object-sha> JSON dump')
    parser.add_argument('--latest-json', type=Path,
                        help='gh api repos/<repo>/releases/latest JSON dump')
    parser.add_argument('--expect-tag', required=True)
    parser.add_argument('--expect-version')
    parser.add_argument('--expect-build')
    parser.add_argument('--expect-source-sha')
    parser.add_argument('--bundle-id', default='')
    parser.add_argument('--expect-ipa-sha256')
    parser.add_argument('--expect-ipa-bytes', type=int)
    parser.add_argument('--staged-dir', type=Path,
                        help='directory holding the audited local ipa + .sha256 sidecar to bind '
                             'byte-for-byte against the published assets')
    parser.add_argument('--allow-prerelease', action='store_true',
                        help='explicit prerelease decision (beta-style); requires a reason and '
                             'waives only the latest-pointer check')
    parser.add_argument('--prerelease-reason', default='')
    parser.add_argument('--source-only-reason', default='')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args(argv)
    try:
        report = run(args)
    except UsageError as error:
        print(f'Publication verifier usage error: {error}', file=sys.stderr)
        return 2
    except (PublicationError, ValueError) as error:
        print(f'Publication verification failed: {error}', file=sys.stderr)
        return 1
    violations = report.get('violations', [])
    if violations:
        report['repairActions'] = [
            violation if not violation.startswith('missing or duplicated')
            else violation + ' — attach the verified asset pair, keep the immutable tag'
            for violation in violations]
    text = json.dumps(report, indent=2) + '\n'
    if args.report:
        args.report.write_text(text, encoding='utf-8')
    if violations:
        print('Publication is NOT an installable delivery yet:', file=sys.stderr)
        for violation in violations:
            print(f'  - {violation}', file=sys.stderr)
        return 1
    print(text, end='')
    return 0


if __name__ == '__main__':
    sys.exit(main())
