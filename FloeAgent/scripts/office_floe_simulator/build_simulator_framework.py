#!/usr/bin/env python3
"""Build the genuine FloeOfficeNative framework for iphonesimulator.

Input is a restored staged real engine (see ``restore_staged_engine.py``) at
the pinned source commit. The full current native overlay stack is applied by
the existing pinned preparation (embedding -> scheme -> forwarding -> kit
callback); the ``nokit`` variant builds from a lock copy without the kit
callback overlay so a before/after cloud diagnosis never repeats the heavy
core engine build (the overlay only changes kit/Kit.cpp|hpp, which compile in
this host phase, not the LO core archives).

The product is an ``OfficeNativeHostSimulator`` bundle:

    FloeOfficeNative.framework        genuine native framework (arm64 simulator)
    OfficeRuntimeResources/           engine runtime resources (cool.html, ...)
    native-host-simulator.json        the pin the Floe app build verifies

The receipt records exact provenance: staged engine run/artifact hash, source
commit, every overlay patch SHA (and whether the kit callback overlay was
applied), toolchain identity, resource hashes and the Swift import probe
result. Nothing here claims device or release capability.
"""
import argparse
import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

THIS_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = THIS_DIR.parent
sys.path.insert(0, str(THIS_DIR))
sys.path.insert(0, str(SCRIPTS_DIR))

from build_office_native_host import build_host, NAME  # noqa: E402
from office_release_gates import false_capabilities  # noqa: E402
from package_office_engine import digest  # noqa: E402
from verify_office_engine import contained  # noqa: E402
from sim_host_paths import (HOST_BUNDLE_NAME, HOST_RECEIPT_NAME,  # noqa: E402
                            HOST_ZIP_NAME, LOCK_PATH, VARIANTS)

SDK = 'iphonesimulator'

# Overlay inputs the preparation/build resolve relative to the lock
# directory (see prepare_office_native_sources.prepare and
# build_office_native_host.build_host).
FONT_OVERLAY_NAME = 'FloeOfficeFontSubstitutions.xcu'
OVERLAY_PATCH_LOCK_KEYS = (
    ('embeddingOverlay', 'patch'),
    ('schemeTaskLifecycleOverlay', 'patch'),
    ('forwardingLifecycleOverlay', 'patch'),
    ('kitCallbackLifecycleOverlay', 'patch'),
)


class SimulatorHostBuildError(ValueError):
    pass


def overlay_patch_refs(lock):
    """Every overlay patch path the lock references, in application order."""
    refs = []
    for section, key in OVERLAY_PATCH_LOCK_KEYS:
        overlay = lock.get(section) if isinstance(lock.get(section), dict) else None
        if overlay and overlay.get(key):
            refs.append(overlay[key])
    source_patch = lock.get('sourcePatch')
    if source_patch:
        refs.append(source_patch)
    # De-duplicate while preserving order.
    return list(dict.fromkeys(refs))


def validate_lock_resources(lock_path):
    """Fail-closed path contract: every overlay input the build resolves
    relative to ``lock_path.parent`` must be an existing regular file
    contained in that directory with the digest the lock pins.

    A copied diagnostic lock (nokit) lives outside the tracked Collabora
    directory, so its adjacent patches/font overlay must be staged real files;
    the tracked lock's own directory is validated identically.
    """
    lock_path = Path(lock_path).resolve()
    root = lock_path.parent
    lock = json.loads(lock_path.read_text())
    for section, key in OVERLAY_PATCH_LOCK_KEYS:
        overlay = lock.get(section)
        if not isinstance(overlay, dict) or not overlay.get(key):
            continue
        patch = contained(root, overlay[key])
        if not patch.is_file() or patch.is_symlink():
            raise SimulatorHostBuildError(
                f'overlay patch missing or not a regular file for {section}: {patch}')
        if digest(patch) != overlay['sha256']:
            raise SimulatorHostBuildError(
                f'adjacent overlay patch checksum mismatch: {patch}')
    font_overlay = root / FONT_OVERLAY_NAME
    if not font_overlay.is_file() or font_overlay.is_symlink():
        raise SimulatorHostBuildError(
            f'font overlay missing next to the lock: {font_overlay}')
    return {'lockPath': str(lock_path), 'overlayRoot': str(root),
            'patchCount': len(overlay_patch_refs(lock)),
            'fontOverlaySHA256': digest(font_overlay)}


def variant_lock(variant, workdir):
    """Return (lock_path, kit_applied).

    ``kit`` uses the tracked lock in place. ``nokit`` drops only the kit
    callback overlay section and stages the lock copy in a private directory
    that ALSO carries verified, byte-identical copies of every adjacent
    overlay input (the patches tree and the additive font overlay), because
    preparation and the host build resolve those relative to the lock
    directory. The tracked lock is never mutated; copied digests are checked
    against the tracked files so a nokit receipt can never diverge from the
    pinned overlay bytes.
    """
    tracked_lock = json.loads(LOCK_PATH.read_text())
    if variant == 'kit':
        validate_lock_resources(LOCK_PATH)
        return LOCK_PATH, True
    if variant != 'nokit':
        raise SimulatorHostBuildError(
            f'unknown variant {variant!r}; expected one of {VARIANTS}')
    staged = Path(workdir).resolve() / 'nokit-lock'
    staged.mkdir(parents=True, exist_ok=True)
    tracked_root = LOCK_PATH.parent
    shutil.copytree(tracked_root / 'patches', staged / 'patches',
                    dirs_exist_ok=True)
    shutil.copyfile(tracked_root / FONT_OVERLAY_NAME, staged / FONT_OVERLAY_NAME)
    lock = copy.deepcopy(tracked_lock)
    lock.pop('kitCallbackLifecycleOverlay', None)
    path = staged / 'engine.lock.json'
    path.write_text(json.dumps(lock, indent=2) + '\n')
    facts = validate_lock_resources(path)
    # The copied adjacent inputs must be byte-identical to the pinned ones.
    for ref in overlay_patch_refs(lock):
        if digest(staged / ref) != digest(tracked_root / ref):
            raise SimulatorHostBuildError(
                f'staged nokit overlay diverged from the pin: {ref}')
    if facts['fontOverlaySHA256'] != digest(tracked_root / FONT_OVERLAY_NAME):
        raise SimulatorHostBuildError('staged nokit font overlay diverged from the pin')
    return path, False


def sdk_identity():
    sdk_path = subprocess.check_output(
        ['xcrun', '--sdk', SDK, '--show-sdk-path'], text=True).strip()
    sdk_version = subprocess.check_output(
        ['xcrun', '--sdk', SDK, '--show-sdk-version'], text=True).strip()
    sdk_build = subprocess.check_output(
        ['xcrun', '--sdk', SDK, '--show-sdk-build-version'], text=True).strip()
    xcode = subprocess.run(['xcodebuild', '-version'], capture_output=True,
                           text=True, check=True).stdout
    return {'sdkPath': sdk_path, 'sdkVersion': sdk_version,
            'sdkBuildVersion': sdk_build,
            'xcodeVersion': '; '.join(line.strip() for line in xcode.splitlines() if line.strip())}


def package_host(build_report, restored_dir, output_dir, *, variant,
                 kit_applied, base_run_id, identity):
    """Assemble the installable host bundle and its pin receipt."""
    output_dir = Path(output_dir)
    bundle = output_dir / HOST_BUNDLE_NAME
    if bundle.exists():
        raise SimulatorHostBuildError(f'output exists: {bundle}')
    build_root = output_dir / 'build'
    framework = build_root / f'products/Release-{SDK}/{NAME}.framework'
    resources = build_root / 'OfficeRuntimeResources'
    if not framework.is_dir() or not resources.is_dir():
        raise SimulatorHostBuildError('framework build products are incomplete')
    bundle.mkdir(parents=True)
    shutil.copytree(framework, bundle / framework.name)
    shutil.copytree(resources, bundle / resources.name)
    framework_aux = {str(path.relative_to(bundle / framework.name)): digest(path)
                     for path in sorted((bundle / framework.name).rglob('*')) if path.is_file()
                     and path.name != NAME}

    restore_report = json.loads((Path(restored_dir) / 'restore-report.json').read_text())
    receipt = {
        'kind': 'Floe native Office simulator host qualification',
        'hostKind': 'fullFloeAppSimulator',
        'variant': variant,
        'kitCallbackOverlayApplied': kit_applied,
        'platform': SDK,
        'arch': 'arm64',
        'deploymentTarget': '26.0',
        'sourceCommit': build_report['sourceCommit'],
        'sdk': build_report['sdk'],
        'swiftImportTarget': build_report['swiftImportTarget'],
        'sdkVersion': identity['sdkVersion'],
        'sdkBuildVersion': identity['sdkBuildVersion'],
        'xcodeVersion': identity['xcodeVersion'],
        'stagedEngine': {
            'runID': str(base_run_id),
            'artifactSHA256': restore_report.get('provenanceArtifactSHA256'),
            'sourceCommit': restore_report.get('sourceCommit'),
            'engineNeverRebuild': True,
        },
        'overlaySHA256': build_report['overlaySHA256'],
        'schemeTaskLifecycle': build_report.get('schemeTaskLifecycle'),
        'forwardingLifecycle': build_report.get('forwardingLifecycle'),
        'kitCallbackLifecycle': build_report.get('kitCallbackLifecycle'),
        'filterOverlay': {
            'applied': False,
            'reason': 'device-only linker archives; never applied to a simulator host',
        },
        'hostSourceSHA256': build_report['hostSourceSHA256'],
        'executableSHA256': build_report['executableSHA256'],
        'frameworkAuxiliarySHA256': framework_aux,
        'platformLoadCommands': build_report['platformLoadCommands'],
        'swiftModuleImportPassed': build_report['swiftModuleImportPassed'],
        'swiftProbeSHA256': build_report['swiftProbeSHA256'],
        'nativeCompilePassed': build_report['nativeCompilePassed'],
        'nativeLinkPassed': build_report['nativeLinkPassed'],
        'runtimeResourceSHA256': build_report['runtimeResourceSHA256'],
        'runtimeResourceDirectories': build_report['runtimeResourceDirectories'],
        'fontSubstitutionConfig': build_report.get('fontSubstitutionConfig'),
        'languageResources': build_report.get('languageResources'),
        'capabilityQualification': false_capabilities(),
        'deviceHostPinUntouched': True,
        'nativeEditorRuntimeVerified': False,
        'note': 'Compile/link/framework packaging only. Preview/edit/idle/save '
                'acceptance is the separate cloud simulator scenario gate.',
    }
    (bundle / HOST_RECEIPT_NAME).write_text(json.dumps(receipt, indent=2) + '\n')
    return bundle, receipt


def zip_bundle(bundle, output_dir):
    output_dir = Path(output_dir)
    zip_path = output_dir / HOST_ZIP_NAME
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(bundle.rglob('*')):
            if path.is_dir():
                # Empty runtime directories are part of the verified
                # inventory; the receipt records them, so the archive must
                # carry them too.
                archive.write(path, path.relative_to(bundle.parent).as_posix() + '/')
        for path in sorted(bundle.rglob('*')):
            if path.is_file():
                archive.write(path, path.relative_to(bundle.parent))
    return zip_path


def build_framework(restored_dir, output_dir, *, variant, base_run_id,
                    github_run_id=None):
    if variant not in VARIANTS:
        raise SimulatorHostBuildError(f'unknown variant {variant!r}; expected one of {VARIANTS}')
    output_dir = Path(output_dir).resolve()
    if output_dir.exists():
        raise SimulatorHostBuildError(f'output exists: {output_dir}')
    output_dir.mkdir(parents=True)
    # qualify() requires a fresh build directory and creates it itself.
    build_dir = output_dir / 'build'
    identity = sdk_identity()
    with tempfile.TemporaryDirectory(prefix='floe-sim-lock-') as temporary:
        lock_path, kit_applied = variant_lock(variant, temporary)
        report = build_host(Path(restored_dir).resolve(), build_dir, build=True,
                            sdk=SDK, lock_path=lock_path)
    if github_run_id:
        report['simulatorHostWorkflowRunID'] = str(github_run_id)
    (output_dir / 'native-host-build-report.json').write_text(
        json.dumps({key: value for key, value in report.items()
                    if key != 'runtimeResourceSHA256'}, indent=2) + '\n')
    bundle, receipt = package_host(report, restored_dir, output_dir,
                                   variant=variant, kit_applied=kit_applied,
                                   base_run_id=base_run_id, identity=identity)
    zip_path = zip_bundle(bundle, output_dir)
    manifest = {'variant': variant, 'kitCallbackOverlayApplied': kit_applied,
                'bundle': str(bundle), 'zip': str(zip_path),
                'zipSHA256': digest(zip_path), 'receipt': str(bundle / HOST_RECEIPT_NAME),
                'baseEngineRunID': str(base_run_id),
                'platform': SDK, 'arch': 'arm64',
                'hostReceipt': receipt['kind']}
    (output_dir / 'package-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--restored', type=Path, required=True,
                        help='Restored staged engine directory')
    parser.add_argument('--output', type=Path, required=True,
                        help='Fresh output directory for build + package')
    parser.add_argument('--variant', choices=VARIANTS, default='kit')
    parser.add_argument('--base-run-id', required=True,
                        help='office-real-simulator build-stage run that produced the engine')
    parser.add_argument('--github-run-id', default=None)
    args = parser.parse_args()
    manifest = build_framework(args.restored, args.output, variant=args.variant,
                               base_run_id=args.base_run_id,
                               github_run_id=args.github_run_id)
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
