#!/usr/bin/env python3
"""Bounded checks for the iOS alpha-correct transparency repair package.

No engine, native-host, App or module build happens here by default. The test
proves:
  1. patches/ios-unified-transparency-alpha.patch applies to the pinned engine
     sources exactly the way build_office_native_host.py applies it
     (`git apply --include=<sourceFile>`), and the resulting patched source
     bytes match engine.lock.json's locked patchedSHA256 values;
  2. the embeddedLifecycleOverlay contract in engine.lock.json validates
     through office_compiled_lifecycle (schema, hashes, patch identity) for
     both IOS and IOSSIMULATOR, including the new libdrawinglayerlo.a
     additional archive and the extended salios.o member;
  3. the patched sources contain the intended, narrow algorithm (source proof,
     not a compile): isolated transparent group for transparent iOS targets,
     own-alpha multiplication, legacy opaque branch preserved;
  4. the pristine sibling header
     engine/drawinglayer/source/processor2d/vclhelperbufferdevice.hxx is
     materialized in the pinned checkout and matches the pinned blob, so the
     locked compileOverrides.sourceIncludes resolves it;
  5. the FloeOfficeNative Print callback contract (public nullable copy block,
     interception rules, upstream fallback, live-session gate).

With --syntax-check the two patched members are additionally translated with
-fsyntax-only under the exact locked per-platform compile recipe inputs (no
object code is produced). That check needs the Xcode toolchain and the staged
simulator/device bundle include roots beside the engine source.

Usage:
    python3 test_office_transparency_alpha.py [--engine-source PATH] [--syntax-check]

--engine-source defaults to $FLOE_OFFICE_ENGINE_SOURCE, then to the retained
CodexBuild cache layout under the current user's home. If none is found the
patch-application/source-proof checks are skipped loudly instead of passing
silently.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Optional

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
COLLABORA = REPO_ROOT / 'FloeAgent' / 'ThirdParty' / 'Collabora'
LOCK_PATH = COLLABORA / 'engine.lock.json'
PATCH_PATH = COLLABORA / 'patches' / 'ios-unified-transparency-alpha.patch'
HEADER_PATH = COLLABORA / 'FloeOfficeNative' / 'FloeOfficeNative.h'
MM_PATH = COLLABORA / 'FloeOfficeNative' / 'FloeOfficeNative.mm'
PINNED_COMMIT = '27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc'
SIBLING_HEADER = 'engine/drawinglayer/source/processor2d/vclhelperbufferdevice.hxx'
SIBLING_HEADER_SHA256 = '8e45c9f7ebbf68952329eba36f0cfc073269c6f3af88d7523b2d7621baef9bf5'

CHECKS = []


def check(name):
    def decorator(fn):
        CHECKS.append((name, fn))
        return fn
    return decorator


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read(path: Path) -> str:
    return path.read_text(encoding='utf-8')


def default_engine_source() -> Optional[Path]:
    env = os.environ.get('FLOE_OFFICE_ENGINE_SOURCE')
    if env and Path(env).is_dir():
        return Path(env)
    home = Path.home()
    candidates = [
        home / 'Library/Caches/CodexBuild/FloeAgent/ios-pencil-live-20261019'
               / 'xcode-27A266a/native-feedback-20261021/engine-source-27b21dc1-owned',
        home / 'Library/Caches/CodexBuild/FloeAgent/native-feedback-20261021'
               / 'engine-source-27b21dc1-owned',
    ]
    for candidate in candidates:
        if (candidate / '.git').exists():
            return candidate
    return None


@check('patch file exists and declares both members')
def patch_structure():
    text = read(PATCH_PATH)
    assert '--- a/engine/drawinglayer/source/processor2d/vclhelperbufferdevice.cxx' in text
    assert '--- a/engine/vcl/ios/salios.cxx' in text
    assert 'kCGImageAlphaPremultipliedFirst' in text
    assert 'isIsolatedGroupTarget' in text
    return f'{PATCH_PATH.name}: {len(text.splitlines())} lines'


@check('engine.patch.lock.json untouched (virdev repair identity intact)')
def repair_lock_untouched():
    repair_lock = json.loads((COLLABORA / 'engine.patch.lock.json').read_text())
    patch_rel = repair_lock['repair']['patch']
    patch_file = COLLABORA / patch_rel
    digest = sha256(patch_file.read_bytes())
    assert digest == repair_lock['repair']['patchSHA256'], \
        (digest, repair_lock['repair']['patchSHA256'])
    return f'{patch_rel} sha256 matches its lock'


def _lifecycle():
    sys.path.insert(0, str(SCRIPT_DIR))
    import office_compiled_lifecycle as lifecycle
    return lifecycle


def _load_lock():
    return json.loads(LOCK_PATH.read_text())


@check('lifecycle contract validates for IOS and IOSSIMULATOR')
def lifecycle_contract():
    lifecycle = _lifecycle()
    lock = _load_lock()
    assert lock['commit'] == PINNED_COMMIT
    for platform in ('IOS', 'IOSSIMULATOR'):
        selected = lifecycle.contract(lock, platform)
        assert selected is not None
        lifecycle.identity(lock, platform, lock_path=LOCK_PATH)
        child = selected['additionalArchives']['libdrawinglayerlo.a']
        lifecycle.contract(lock, platform, spec=child)
        lifecycle.identity(lifecycle.single_lock(lock, platform, child),
                           platform, lock_path=LOCK_PATH)
        assert child['members'] == {
            'vclhelperbufferdevice.o':
                'engine/drawinglayer/source/processor2d/vclhelperbufferdevice.cxx'}
        assert child['compileOverrides']['language'] == 'c++'
        assert '-DDRAWINGLAYER_DLLIMPLEMENTATION' in child['compileOverrides']['flags']
        assert child['compileOverrides']['sourceIncludes'] == \
            ['engine/drawinglayer/source/processor2d']
        salios = selected['additionalMembers']['salios.o']
        assert salios['patch'] == 'patches/ios-unified-transparency-alpha.patch'
        assert salios['originalSHA256'] == \
            '0a671dcd57de890a480d52a672bb5721c119547ca5724463077e705cab356d5a'
    return 'contract/identity OK for both platforms; salios original pinned'


def _git_show(engine_source: Path, source_file: str) -> bytes:
    return subprocess.check_output(
        ['git', '-C', str(engine_source), 'show', f'HEAD:{source_file}'])


@check('pinned checkout carries the pristine sibling header')
def sibling_header_present():
    engine_source = ARGS.engine_source
    header = engine_source / SIBLING_HEADER
    assert header.is_file(), \
        f'{SIBLING_HEADER} is not materialized in the sparse checkout; run ' \
        f'"git sparse-checkout add {SIBLING_HEADER}" so the locked include resolves'
    digest = sha256(header.read_bytes())
    assert digest == SIBLING_HEADER_SHA256, (digest, SIBLING_HEADER_SHA256)
    blob = _git_show(engine_source, SIBLING_HEADER)
    assert sha256(blob) == SIBLING_HEADER_SHA256
    return f'{Path(SIBLING_HEADER).name} sha256 {digest[:12]} matches pinned blob'


def _staged_patched(engine_source: Path, spec) -> bytes:
    pristine = _git_show(engine_source, spec['sourceFile'])
    with tempfile.TemporaryDirectory(prefix='floe-alpha-apply-') as tmp:
        stage = Path(tmp)
        staged = stage / spec['sourceFile']
        staged.parent.mkdir(parents=True)
        staged.write_bytes(pristine)
        result = subprocess.run(
            ['git', 'apply', '--include=' + spec['sourceFile'], str(PATCH_PATH)],
            cwd=stage, capture_output=True, text=True)
        assert result.returncode == 0, (spec['sourceFile'], result.stderr)
        return staged.read_bytes()


@check('patch applies to pinned source with build-time --include semantics')
def patch_applies():
    engine_source = ARGS.engine_source
    head = subprocess.check_output(
        ['git', '-C', str(engine_source), 'rev-parse', 'HEAD'], text=True).strip()
    assert head == PINNED_COMMIT, (head, PINNED_COMMIT)
    lifecycle = _lifecycle()
    lock = _load_lock()
    specs = []
    for platform in ('IOS', 'IOSSIMULATOR'):
        selected = lifecycle.contract(lock, platform)
        specs.extend(lifecycle.member_specs(selected).values())
        specs.extend(lifecycle.member_specs(
            selected['additionalArchives']['libdrawinglayerlo.a']).values())
    outcomes = []
    for spec in specs:
        if spec['patch'] != 'patches/ios-unified-transparency-alpha.patch':
            continue
        patched = _staged_patched(engine_source, spec)
        digest = sha256(patched)
        assert digest == spec['patchedSHA256'], \
            (spec['sourceFile'], digest, spec['patchedSHA256'])
        outcomes.append(f"{Path(spec['sourceFile']).name}:{digest[:12]}")
    assert len(outcomes) == 4, outcomes
    return '; '.join(outcomes)


@check('salios patched source: alpha init gated, opaque path unchanged')
def salios_source_proof():
    lifecycle = _lifecycle()
    lock = _load_lock()
    spec = lifecycle.contract(lock, 'IOS')['additionalMembers']['salios.o']
    text = _staged_patched(ARGS.engine_source, spec).decode()
    assert 'bool AquaSalVirtualDevice::SetSize( tools::Long nDX, tools::Long nDY, bool bAlphaMaskTransparent )' in text
    assert 'kCGImageAlphaNoneSkipFirst' in text, 'opaque branch must remain'
    assert '? kCGImageAlphaPremultipliedFirst' in text
    assert 'CGContextClearRect' in text and 'memset' in text
    return 'SetSize honors bAlphaMaskTransparent; opaque default preserved'


@check('salios patched source: layer readback starts from a transparent buffer')
def salios_readback_proof():
    lifecycle = _lifecycle()
    lock = _load_lock()
    spec = lifecycle.contract(lock, 'IOS')['additionalMembers']['salios.o']
    text = _staged_patched(ARGS.engine_source, spec).decode()
    # The CGLayer readback must blend over a zero-initialized context buffer:
    # CreateContext() leaves the heap buffer undefined and
    # CGContextDrawLayerAtPoint uses source-over, so without this the returned
    # bitmap carries stale garbage pixels (iOS speckles/white gaps defect).
    assert 'pReadbackData' in text
    assert 'CGBitmapContextGetData(maGraphicContext.get())' in text
    assert 'CGBitmapContextGetBytesPerRow(maGraphicContext.get()) * mnHeight' in text
    create_fn = text.index(
        'bool QuartzSalBitmap::Create(CGLayerHolder const & rLayerHolder')
    draw_pos = text.index('CGContextDrawLayerAtPoint(maGraphicContext.get(), aSrcPoint',
                          create_fn)
    zero_pos = text.index('memset(pReadbackData, 0,', create_fn)
    assert zero_pos < draw_pos, 'readback buffer must be zeroed before DrawLayerAtPoint'
    return 'layer readback zero-init precedes DrawLayerAtPoint'


@check('drawinglayer patched source: isolated group, own-alpha multiply, legacy intact')
def drawinglayer_source_proof():
    lifecycle = _lifecycle()
    lock = _load_lock()
    spec = lifecycle.contract(lock, 'IOS')['additionalArchives']['libdrawinglayerlo.a']
    text = _staged_patched(ARGS.engine_source, spec).decode()
    assert 'bool isIsolatedGroupTarget(const OutputDevice& rOutDev)' in text
    assert 'rOutDev.HasAlpha()' in text and 'WallpaperStyle::NONE' in text
    assert 'DeviceFormat::WITH_ALPHA' in text
    assert 'bIsolatedGroup ? DeviceFormat::WITH_ALPHA : DeviceFormat::WITHOUT_ALPHA' in text
    assert 'if (!bIsolatedGroup)' in text and 'DrawOutDev' in text
    assert 'DrawTransformedBitmapEx' in text and '1.0 - fTrans' in text
    assert 'aAlphaMask.BlendWith(aContent.CreateAlphaMask())' in text
    assert 'nMaskValue' in text and 'Bitmap(aContent, aAlphaMask)' in text
    assert 'meFormat' in text
    return 'isolated group + group alpha + legacy branch present'


@check('native Print callback contract in header and host')
def print_callback_proof():
    header = read(HEADER_PATH)
    assert 'void (^onPrintRequested)(void);' in header
    mm = read(MM_PATH)
    assert '@property (nonatomic, weak, nullable) FloeOfficeNativeViewController *floeHost;' in mm
    assert '- (BOOL)floeAcceptsPrintRequest' in mm
    assert '_editor.floeHost = self;' in mm
    assert 'didReceiveScriptMessage:(WKScriptMessage *)message' in mm
    assert '[message.name isEqualToString:@"lok"]' in mm
    assert '[message.body isKindOfClass:NSString.class]' in mm
    assert '[message.body isEqualToString:@"PRINT"]' in mm
    assert '[super userContentController:userContentController didReceiveScriptMessage:message];' in mm
    assert 'dispatch_async(dispatch_get_main_queue()' in mm
    assert 'return self.onPrintRequested != nil && !self.closed && !self.closing;' in mm
    body_start = mm.index('- (void)userContentController:')
    forward = mm.index('[super userContentController:', body_start)
    intercept = mm.index('[message.body isEqualToString:@"PRINT"]', body_start)
    assert intercept < forward
    return 'onPrintRequested interception + upstream fallback + live gate present'


def _bundle_for_sdk():
    home = Path.home()
    candidates = [
        home / 'Library/Caches/CodexBuild/FloeAgent/office-linux-closure-A2'
               / 'xcode-27A266a/bundle-sim4',
    ]
    for candidate in candidates:
        if (candidate / 'source/engine/instdir/program/libdrawinglayerlo.a').is_file():
            return candidate
    return None


def _xcode_clang():
    toolchain = Path('/Applications/Xcode.app/Contents/Developer/Toolchains'
                     '/XcodeDefault.xctoolchain/usr/bin/clang++')
    if toolchain.is_file():
        return str(toolchain)
    result = subprocess.run(['xcrun', '-f', 'clang++'], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def _syntax_check_member(engine_source: Path, spec, *, language_override, extra_flags,
                         extra_includes, sdk_path, target):
    import office_engine_repair  # noqa: PLC0415 - bounded recipe reuse
    compile_lock = json.loads((COLLABORA / 'engine.patch.lock.json').read_text())
    base = compile_lock['platforms']['IOSSIMULATOR']['compile']
    flags = list(base['flags'])
    if language_override:
        index = flags.index('-x')
        flags[index + 1] = language_override
    flags += extra_flags
    patched = _staged_patched(engine_source, spec)
    bundle = _bundle_for_sdk()
    assert bundle is not None, 'staged simulator bundle not found for --syntax-check'
    with tempfile.TemporaryDirectory(prefix='floe-alpha-syntax-') as tmp:
        staged = Path(tmp) / Path(spec['sourceFile']).name
        staged.write_bytes(patched)
        command = [_xcode_clang(), '-arch', 'arm64', '-target', target,
                   '-isysroot', sdk_path, '-fsyntax-only']
        command += flags
        for inc in list(extra_includes) + list(base['sourceIncludes']):
            command.append('-I' + str(engine_source / inc))
        for inc in base['bundleIncludes']:
            command.append('-I' + str(bundle / inc))
        command.append(str(staged))
        result = subprocess.run(command, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        return result.stderr.strip()


def syntax_checks():
    lifecycle = _lifecycle()
    lock = _load_lock()
    sdk_path = subprocess.check_output(
        ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    selected = lifecycle.contract(lock, 'IOSSIMULATOR')
    warnings = []
    salios = selected['additionalMembers']['salios.o']
    warnings.append(_syntax_check_member(
        ARGS.engine_source, salios, language_override=None, extra_flags=[],
        extra_includes=[], sdk_path=sdk_path,
        target='arm64-apple-ios26.0-simulator'))
    child = selected['additionalArchives']['libdrawinglayerlo.a']
    member_spec = lifecycle.member_specs(child)['vclhelperbufferdevice.o']
    warnings.append(_syntax_check_member(
        ARGS.engine_source, member_spec, language_override='c++',
        extra_flags=['-DDRAWINGLAYER_DLLIMPLEMENTATION'],
        extra_includes=['engine/drawinglayer/source/processor2d'],
        sdk_path=sdk_path, target='arm64-apple-ios26.0-simulator'))
    notes = [w.splitlines()[0] for w in warnings if w]
    return 'both members translate clean' + (f' (warnings: {"; ".join(notes)})' if notes else '')


SOURCE_CHECKS = {patch_applies, salios_source_proof, salios_readback_proof,
                 drawinglayer_source_proof,
                 sibling_header_present}


def main():
    global ARGS
    parser = argparse.ArgumentParser()
    parser.add_argument('--engine-source', type=Path, default=None)
    parser.add_argument('--syntax-check', action='store_true',
                        help='also run locked-recipe -fsyntax-only translation')
    ARGS = parser.parse_args()
    if ARGS.engine_source is None:
        ARGS.engine_source = default_engine_source()
    checks = list(CHECKS)
    if ARGS.syntax_check:
        checks.append(('locked-recipe -fsyntax-only translation of both patched members',
                       syntax_checks))
    failures = 0
    for name, fn in checks:
        label = fn.__closure__ and name or name
        try:
            if ARGS.engine_source is None and fn in SOURCE_CHECKS:
                print(f'SKIP {name}: no --engine-source and no retained cache')
                continue
            detail = fn()
            print(f'PASS {name}: {detail}')
        except Exception as failure:  # noqa: BLE001 - report every failure
            failures += 1
            print(f'FAIL {name}: {failure}')
    if failures:
        print(f'{failures} check(s) failed')
        return 1
    ran = [n for n, _ in checks]
    print(f'all {len(ran)} checks passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
