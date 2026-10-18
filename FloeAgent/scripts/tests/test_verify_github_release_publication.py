"""Hermetic tests for the published-release installable-delivery verifier.

These exercise the exact script at ``FloeAgent/scripts/verify_github_release_publication.py``
with synthetic ``gh api`` JSON dumps and a synthetic unsigned IPA zip, so no
network, Xcode or App build is involved.

The scenarios encode the 2026-10-18 normal-release rule and the 275 incident:

* a stable published App release with the canonical verified IPA pair, bound to
  the tag commit and to the local bytes, and owning the latest pointer passes;
* a source-only release (release 414521170 shape: published, zero assets) fails
  with attach guidance and never counts as an installable delivery;
* draft, prerelease, stale latest, signed/simulator/transport assets, wrong
  build, modified bytes, partial uploads and a wrong tag peel all fail closed;
* an older historic source-only release does not affect a new valid release,
  while a new intended release missing its IPA fails rather than falling back;
* repairing the same published release (attach the pair, re-verify) is
  idempotent;
* source-only classification is opt-in and refused for App-shaped tags.
"""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SCRIPT = REPO / 'FloeAgent' / 'scripts' / 'verify_github_release_publication.py'
spec = importlib.util.spec_from_file_location('publication_verifier', SCRIPT)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)

SOURCE = 'e321aeb542a36f6d54832ced9b51939cfa6a0f62'
TAG = 'v1.7.34'
VERSION = '1.7.34'
BUILD = '275'
IPA_NAME = f'Floe-Agent-{VERSION}-build{BUILD}-unsigned.ipa'
OTHER_TAG = 'v1.7.35'
TAG_OBJECT_SHA = 'f' * 40


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def macho(*, platform=2, cpu=0x0100000C, command='LC_BUILD_VERSION') -> bytes:
    """Build a minimal arm64 MH_EXECUTE Mach-O with one platform command."""
    if command == 'LC_BUILD_VERSION':
        body = struct.pack('<IIIIII', 0x32, 24, platform, 0x000D0000, 0x001A0000, 0)
    elif command == 'LC_VERSION_MIN_IPHONEOS':
        body = struct.pack('<IIII', 0x25, 16, 0x000D0000, 0x001A0000)
    elif command == 'LC_UUID':
        # A structurally valid executable that makes no platform declaration.
        body = struct.pack('<II', 0x1B, 24) + b'\0' * 16
    elif command == 'none':
        body = b''
    else:
        raise ValueError(command)
    header = struct.pack('<IiiIIIII', 0xFEEDFACF, cpu, 0, 0x2,
                         1 if body else 0, len(body), 0, 0)
    return header + body


def fat_macho(images) -> bytes:
    """Wrap thin Mach-O images in a big-endian universal binary."""
    count = len(images)
    offset = 8 + 20 * count
    entries, payload = b'', b''
    for image in images:
        entries += struct.pack('>IIIII', 0x0100000C, 0, offset + len(payload),
                               len(image), 12)
        payload += image
    return struct.pack('>II', 0xCAFEBABE, count) + entries + payload


def make_ipa(*, version=VERSION, build=BUILD, bundle='org.floeagent.ios',
             signed=False, sdk='iphoneos26.0', platform_name='iphoneos',
             executable: bytes | None = None) -> bytes:
    buffer = io.BytesIO()
    plist = plistlib.dumps({'CFBundleIdentifier': bundle,
                            'CFBundleShortVersionString': version,
                            'CFBundleVersion': build,
                            'CFBundleExecutable': 'Floe Agent',
                            'MinimumOSVersion': '26.0',
                            'DTSDKName': sdk,
                            'DTPlatformName': platform_name},
                           fmt=plistlib.FMT_BINARY)
    with zipfile.ZipFile(buffer, 'w') as bundle_zip:
        bundle_zip.writestr('Payload/Floe Agent.app/Info.plist', plist)
        bundle_zip.writestr('Payload/Floe Agent.app/Floe Agent',
                            macho() if executable is None else executable)
        if signed:
            bundle_zip.writestr('Payload/Floe Agent.app/embedded.mobileprovision', b'profile')
    return buffer.getvalue()


def asset(name: str, *, size: int, digest: str | None, state: str = 'uploaded',
          asset_id: int = 1) -> dict:
    return {'id': asset_id, 'name': name, 'state': state, 'size': size,
            'digest': None if digest is None else 'sha256:' + digest}


def release_json(assets=(), *, tag=TAG, draft=False, prerelease=False,
                 published_at='2026-10-17T19:35:02Z') -> dict:
    return {'id': 414521170, 'tag_name': tag, 'draft': draft, 'prerelease': prerelease,
            'published_at': published_at, 'html_url':
                f'https://github.com/JiangNanGenius/floe-agent/releases/tag/{tag}',
            'assets': list(assets)}


def tag_ref(commit=SOURCE, style='annotated') -> dict:
    if style == 'annotated':
        return {'ref': f'refs/tags/{TAG}',
                'object': {'type': 'tag', 'sha': TAG_OBJECT_SHA}}
    return {'ref': f'refs/tags/{TAG}', 'object': {'type': 'commit', 'sha': commit}}


def tag_object(commit=SOURCE, *, tag=TAG, sha=TAG_OBJECT_SHA) -> dict:
    return {'tag': tag, 'sha': sha, 'object': {'type': 'commit', 'sha': commit}}


class Fixture:
    """A temp directory holding JSON dumps and an optional staged asset folder."""

    def __init__(self, ipa_bytes: bytes | None = None, *, sidecar_bytes: bytes | None = None,
                 sidecar_name: str | None = None, extra_staged=(), staged_dir: bool = True):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.ipa_bytes = ipa_bytes if ipa_bytes is not None else make_ipa()
        self.ipa_digest = sha256(self.ipa_bytes)
        self.staged: Path | None = None
        if staged_dir:
            self.staged = self.root / 'staged'
            self.staged.mkdir()
            (self.staged / IPA_NAME).write_bytes(self.ipa_bytes)
            sidecar = sidecar_bytes
            if sidecar is None:
                sidecar = f'{self.ipa_digest}  {sidecar_name or IPA_NAME}\n'.encode()
            (self.staged / (IPA_NAME + '.sha256')).write_bytes(sidecar)
            for name in extra_staged:
                (self.staged / name).write_text('extra\n')

    def close(self):
        self._tmp.cleanup()

    def write(self, name: str, payload: dict) -> Path:
        path = self.root / name
        path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
        return path

    def args(self, *, release: dict, latest: dict | None = None,
             ref: dict | None = None, obj: dict | None = None,
             mode='app', staged=True, extra=()) -> list:
        argv = ['--mode', mode,
                '--release-json', str(self.write('release.json', release)),
                '--expect-tag', TAG]
        if mode == 'app':
            argv += ['--tag-ref-json', str(self.write('tag-ref.json', ref or tag_ref())),
                     '--tag-object-json', str(self.write('tag-object.json', obj or tag_object())),
                     '--expect-version', VERSION, '--expect-build', BUILD,
                     '--expect-source-sha', SOURCE]
            if latest is not None:
                argv += ['--latest-json', str(self.write('latest.json', latest))]
            if staged:
                argv += ['--staged-dir', str(self.staged)]
        argv += list(extra)
        return argv


def valid_assets(ipa_bytes: bytes, *, digest: str | None = None,
                 state: str = 'uploaded') -> list:
    payload = ipa_bytes
    return [asset(IPA_NAME, size=len(payload), digest=digest or sha256(payload), state=state,
                  asset_id=11),
            asset(IPA_NAME + '.sha256', size=120, digest='a' * 64, asset_id=12)]


def run(argv) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = verifier.main(argv)
    return code, out.getvalue(), err.getvalue()


class PublicationVerifierTests(unittest.TestCase):

    def fixture(self, **kwargs) -> Fixture:
        fixture = Fixture(**kwargs)
        self.addCleanup(fixture.close)
        return fixture

    def test_stable_latest_release_with_bound_verified_pair_passes(self):
        fixture = self.fixture()
        code, out, err = run(fixture.args(
            release=release_json(valid_assets(fixture.ipa_bytes)),
            latest={'tag_name': TAG}))
        self.assertEqual(code, 0, err)
        report = json.loads(out)
        self.assertTrue(report['installableDelivery'])
        self.assertEqual(report['ipa']['name'], IPA_NAME)
        self.assertEqual(report['ipa']['digest'], 'sha256:' + fixture.ipa_digest)
        self.assertEqual(report['staged']['sha256'], fixture.ipa_digest)
        self.assertEqual(report['sourceCommit'], SOURCE)

    def test_source_only_release_with_zero_assets_fails_with_attach_guidance(self):
        # Exact 275 shape: published stable release, zero assets, source bodies.
        fixture = self.fixture()
        release = release_json([], tag=TAG)
        code, out, err = run(fixture.args(release=release, latest={'tag_name': TAG}))
        self.assertEqual(code, 1)
        self.assertIn(IPA_NAME, err)
        self.assertIn(IPA_NAME + '.sha256', err)
        self.assertIn('NOT an installable delivery', err)
        # Repeating the readback stays fail-closed and identical (no state).
        code2, _, err2 = run(fixture.args(release=release, latest={'tag_name': TAG}))
        self.assertEqual(code2, 1)
        self.assertEqual(err, err2)

    def test_older_source_only_release_does_not_block_a_new_valid_release(self):
        # The verifier judges the requested release; a historic asset-less
        # release stays published but the new tag passes its own contract.
        fixture = self.fixture()
        report_path = fixture.root / 'report.json'
        code, _, err = run(fixture.args(
            release=release_json(valid_assets(fixture.ipa_bytes)),
            latest={'tag_name': TAG},
            extra=['--report', str(report_path)]))
        self.assertEqual(code, 0, err)
        self.assertTrue(json.loads(report_path.read_text())['installableDelivery'])

    def test_new_intended_release_missing_ipa_fails_instead_of_falling_back(self):
        fixture = self.fixture()
        code, _, err = run(fixture.args(
            release=release_json([], tag=TAG), latest={'tag_name': TAG}))
        self.assertEqual(code, 1)
        self.assertIn('missing or duplicated installable asset', err)

    def test_draft_release_is_incomplete_not_a_success(self):
        fixture = self.fixture()
        code, _, err = run(fixture.args(
            release=release_json(valid_assets(fixture.ipa_bytes), draft=True),
            latest={'tag_name': TAG}))
        self.assertEqual(code, 1)
        self.assertIn('draft', err)
        self.assertIn('incomplete', err)

    def test_prerelease_fails_by_default_and_needs_explicit_reason(self):
        fixture = self.fixture()
        release = release_json(valid_assets(fixture.ipa_bytes), prerelease=True)
        code, _, err = run(fixture.args(release=release, latest={'tag_name': TAG}))
        self.assertEqual(code, 1)
        self.assertIn('prerelease', err)
        # Explicit beta exception: no latest requirement, but a reason is mandatory.
        code2, _, err2 = run(fixture.args(release=release, extra=['--allow-prerelease']))
        self.assertEqual(code2, 1)
        self.assertIn('prerelease-reason', err2)
        code3, out3, err3 = run(fixture.args(
            release=release, extra=['--allow-prerelease',
                                    '--prerelease-reason', 'beta tag route']))
        self.assertEqual(code3, 0, err3)
        report = json.loads(out3)
        self.assertFalse(report['latest']['required'])
        self.assertTrue(report['installableDelivery'])

    def test_stale_latest_pointer_fails(self):
        fixture = self.fixture()
        code, _, err = run(fixture.args(
            release=release_json(valid_assets(fixture.ipa_bytes)),
            latest={'tag_name': OTHER_TAG}))
        self.assertEqual(code, 1)
        self.assertIn('releases/latest', err)

    def test_latest_json_required_for_stable_app_release(self):
        fixture = self.fixture()
        code, _, err = run(fixture.args(release=release_json(valid_assets(fixture.ipa_bytes))))
        self.assertEqual(code, 2)
        self.assertIn('--latest-json', err)

    def test_signed_simulator_or_unlabeled_ipa_asset_is_refused(self):
        fixture = self.fixture()
        assets = valid_assets(fixture.ipa_bytes) + [
            asset('FloeAgent.ipa', size=100, digest='b' * 64, asset_id=13),
            asset('Floe-Agent-1.7.34-signed.ipa', size=100, digest='c' * 64, asset_id=14)]
        code, _, err = run(fixture.args(
            release=release_json(assets), latest={'tag_name': TAG},
            staged=False))
        self.assertEqual(code, 1)
        self.assertIn('FloeAgent.ipa', err)
        self.assertIn('signed', err)

    def test_staged_signed_payload_is_refused_by_the_reused_ipa_audit(self):
        fixture = self.fixture(ipa_bytes=make_ipa(signed=True))
        code, _, err = run(fixture.args(
            release=release_json(valid_assets(fixture.ipa_bytes)),
            latest={'tag_name': TAG}))
        self.assertEqual(code, 1)
        self.assertIn('signing material', err)

    def test_wrong_build_asset_names_are_not_the_canonical_delivery(self):
        fixture = self.fixture()
        wrong = f'FloeAgent-{VERSION}-{BUILD}-unsigned.ipa'
        assets = [asset(wrong, size=len(fixture.ipa_bytes), digest=fixture.ipa_digest),
                  asset(wrong + '.sha256', size=10, digest='a' * 64)]
        code, _, err = run(fixture.args(
            release=release_json(assets), latest={'tag_name': TAG}))
        self.assertEqual(code, 1)
        self.assertIn(IPA_NAME, err)

    def test_partial_upload_state_fails(self):
        fixture = self.fixture()
        assets = [asset(IPA_NAME, size=len(fixture.ipa_bytes), digest=fixture.ipa_digest,
                        state='open', asset_id=11),
                  asset(IPA_NAME + '.sha256', size=10, digest='a' * 64)]
        code, _, err = run(fixture.args(
            release=release_json(assets), latest={'tag_name': TAG}, staged=False))
        self.assertEqual(code, 1)
        self.assertIn('not "uploaded"', err)

    def test_modified_remote_bytes_or_size_fail(self):
        fixture = self.fixture()
        for overrides in ({'digest': 'd' * 64}, {'size': len(fixture.ipa_bytes) + 1}):
            with self.subTest(**overrides):
                assets = valid_assets(fixture.ipa_bytes, digest=overrides.get('digest'))
                if 'size' in overrides:
                    assets[0]['size'] = overrides['size']
                code, _, err = run(fixture.args(
                    release=release_json(assets), latest={'tag_name': TAG}))
                self.assertEqual(code, 1)

    def test_tag_peel_must_reach_the_expected_source_commit(self):
        fixture = self.fixture()
        code, _, err = run(fixture.args(
            release=release_json(valid_assets(fixture.ipa_bytes)),
            latest={'tag_name': TAG}, obj=tag_object('a' * 40)))
        self.assertEqual(code, 1)
        self.assertIn('anti-cross-build', err)

    def test_tag_ref_must_name_the_expected_tag(self):
        fixture = self.fixture()
        ref = tag_ref()
        ref['ref'] = f'refs/tags/{OTHER_TAG}'
        code, _, err = run(fixture.args(
            release=release_json(valid_assets(fixture.ipa_bytes)),
            latest={'tag_name': TAG}, ref=ref))
        self.assertEqual(code, 1)
        self.assertIn('refs/tags', err)
        self.assertIn('anti-tag-substitution', err)

    def test_annotated_tag_object_must_match_the_ref_object_sha(self):
        fixture = self.fixture()
        code, _, err = run(fixture.args(
            release=release_json(valid_assets(fixture.ipa_bytes)),
            latest={'tag_name': TAG}, obj=tag_object(sha='e' * 40)))
        self.assertEqual(code, 1)
        self.assertIn('unrelated tag object', err)

    def test_annotated_tag_object_must_name_the_expected_tag(self):
        fixture = self.fixture()
        code, _, err = run(fixture.args(
            release=release_json(valid_assets(fixture.ipa_bytes)),
            latest={'tag_name': TAG}, obj=tag_object(tag=OTHER_TAG)))
        self.assertEqual(code, 1)
        self.assertIn('different tag', err)

    def test_canonical_simulator_ipa_is_refused_despite_matching_identity(self):
        # The asset name, plist identity, staged digest and remote digest all
        # match; only the actual SDK/platform and Mach-O platform expose it.
        simulator = make_ipa(sdk='iphonesimulator26.0', platform_name='iphonesimulator',
                             executable=macho(platform=7))
        fixture = self.fixture(ipa_bytes=simulator)
        code, _, err = run(fixture.args(
            release=release_json(valid_assets(fixture.ipa_bytes)),
            latest={'tag_name': TAG}))
        self.assertEqual(code, 1)
        self.assertIn('iphoneos', err)

    def test_device_plist_with_simulator_executable_is_refused(self):
        fixture = self.fixture(ipa_bytes=make_ipa(executable=macho(platform=7)))
        code, _, err = run(fixture.args(
            release=release_json(valid_assets(fixture.ipa_bytes)),
            latest={'tag_name': TAG}))
        self.assertEqual(code, 1)
        self.assertIn('simulator or foreign-platform', err)

    def test_executable_without_a_platform_load_command_is_refused(self):
        fixture = self.fixture(ipa_bytes=make_ipa(executable=macho(command='LC_UUID')))
        code, _, err = run(fixture.args(
            release=release_json(valid_assets(fixture.ipa_bytes)),
            latest={'tag_name': TAG}))
        self.assertEqual(code, 1)
        self.assertIn('platform declaration', err)

    def test_legacy_version_min_iphoneos_device_binary_passes(self):
        fixture = self.fixture(ipa_bytes=make_ipa(
            executable=macho(command='LC_VERSION_MIN_IPHONEOS')))
        code, out, err = run(fixture.args(
            release=release_json(valid_assets(fixture.ipa_bytes)),
            latest={'tag_name': TAG}))
        self.assertEqual(code, 0, err)
        report = json.loads(out)
        self.assertTrue(report['installableDelivery'])
        self.assertTrue(report['staged']['deviceBinary']['deviceLoadCommands'])

    def test_pre_attestation_staged_audit_reuses_the_device_guard(self):
        # The local publish job calls this exact helper before attestation and
        # before any public release write.
        fixture = self.fixture()
        fields = verifier.audit_staged_ipa(fixture.staged, {
            'ipa_name': IPA_NAME, 'bundle_id': 'org.floeagent.ios',
            'version': VERSION, 'build': BUILD})
        self.assertTrue(fields['deviceBinary']['deviceLoadCommands'])
        self.assertEqual(fields['deviceBinary']['platform'], 'IOS')
        simulator = self.fixture(ipa_bytes=make_ipa(
            sdk='iphonesimulator26.0', platform_name='iphonesimulator',
            executable=macho(platform=7)))
        with self.assertRaises(verifier.PublicationError):
            verifier.audit_staged_ipa(simulator.staged, {
                'ipa_name': IPA_NAME, 'bundle_id': 'org.floeagent.ios',
                'version': VERSION, 'build': BUILD})

    def test_universal_arm64_device_binary_passes(self):
        fixture = self.fixture(ipa_bytes=make_ipa(executable=fat_macho([macho(), macho()])))
        code, out, err = run(fixture.args(
            release=release_json(valid_assets(fixture.ipa_bytes)),
            latest={'tag_name': TAG}))
        self.assertEqual(code, 0, err)
        report = json.loads(out)
        self.assertEqual(report['staged']['deviceBinary']['slices'], 2)

    def test_private_transport_and_symbol_asset_names_are_refused(self):
        fixture = self.fixture()
        assets = valid_assets(fixture.ipa_bytes) + [
            asset('local-device.zip.part03', size=10, digest='a' * 64, asset_id=20),
            asset('release-symbols-1.7.34-build275.zip', size=10, digest='b' * 64, asset_id=21)]
        code, _, err = run(fixture.args(
            release=release_json(assets), latest={'tag_name': TAG}, staged=False))
        self.assertEqual(code, 1)
        self.assertIn('private transport archive', err)
        self.assertIn('private artifact name', err)

    def test_public_evidence_extras_remain_allowed(self):
        fixture = self.fixture()
        assets = valid_assets(fixture.ipa_bytes) + [
            asset('SHA256SUMS.txt', size=200, digest='a' * 64, asset_id=30),
            asset('PROVENANCE.json', size=900, digest='b' * 64, asset_id=31),
            asset('TEST-SUMMARY.txt', size=300, digest='c' * 64, asset_id=32)]
        code, out, err = run(fixture.args(
            release=release_json(assets), latest={'tag_name': TAG}, staged=False))
        self.assertEqual(code, 0, err)
        self.assertEqual(sorted(json.loads(out)['otherAssetNames']),
                         ['PROVENANCE.json', 'SHA256SUMS.txt', 'TEST-SUMMARY.txt'])

    def test_repair_attach_then_reverify_is_idempotent(self):
        fixture = self.fixture()
        missing = release_json([])
        code, _, _ = run(fixture.args(release=missing, latest={'tag_name': TAG}))
        self.assertEqual(code, 1)
        repaired = release_json(valid_assets(fixture.ipa_bytes))
        for _ in range(2):
            code, _, err = run(fixture.args(release=repaired, latest={'tag_name': TAG}))
            self.assertEqual(code, 0, err)

    def test_source_only_mode_is_refused_for_app_tags(self):
        fixture = self.fixture()
        code, _, err = run(fixture.args(
            release=release_json([]), mode='source-only',
            extra=['--source-only-reason', 'historic fallback']))
        self.assertEqual(code, 2)
        self.assertIn('source-only', err)

    def test_source_only_mode_works_for_explicit_non_app_artifacts(self):
        fixture = self.fixture(staged_dir=False)
        release = release_json([asset('SHA512SUMS', size=10, digest='a' * 64)],
                              tag='floe-linux-guest-smp3-20261004.1')
        code, out, err = run(['--mode', 'source-only',
                              '--release-json', str(fixture.write('release.json', release)),
                              '--expect-tag', 'floe-linux-guest-smp3-20261004.1',
                              '--source-only-reason', 'non-App image artifacts'])
        self.assertEqual(code, 0, err)
        report = json.loads(out)
        self.assertFalse(report['installableDelivery'])
        self.assertEqual(report['kind'], 'source-only')

    def test_missing_release_json_fails_closed(self):
        fixture = self.fixture()
        code, _, err = run(['--release-json', str(fixture.root / 'absent.json'),
                            '--expect-tag', TAG])
        self.assertEqual(code, 1)  # absent input is never a green result
        self.assertIn('Missing or unsafe release JSON input', err)


if __name__ == '__main__':
    unittest.main()
