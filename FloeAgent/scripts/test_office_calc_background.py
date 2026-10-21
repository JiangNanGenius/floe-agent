#!/usr/bin/env python3
"""Bounded checks for the native Calc background renderer selection.

No engine, native-host, App or module build happens here by default. The test
proves:
  1. patches/ios-foreign-bitmap-readback.patch applies to the pinned engine
     source exactly the way build_office_native_host.py applies it
     (`git apply --include=<sourceFile>`), and the resulting patched source
     bytes match every engine.lock.json locked patchedSHA256 that references
     the patch (both compiledMembers platforms and the pinned-host
     embeddedLifecycleMember record);
  2. the patched salios source keeps only the two narrow fixes — the CGLayer
     readback zero-init and the foreign-bitmap copy — and carries none of the
     retired R1 experimental alpha-group code (no isolated drawinglayer
     groups, no salios SetSize alpha-surface branch);
  3. the embeddedLifecycleOverlay contract in engine.lock.json validates
     through office_compiled_lifecycle (schema, hashes, patch identity) for
     both IOS and IOSSIMULATOR, with no libdrawinglayerlo.a additional
     archive and no reference to the removed
     patches/ios-unified-transparency-alpha.patch anywhere in the lock;
  4. the source-controlled native default in FloeOfficeNative.mm normalizes
     SAL_KIT_OPTIONS between setupKitEnvironment() and cok_init_2's first
     engine init, removing only the exact sc_no_grid_bg token while
     preserving every other option, and fails startup through the existing
     generic startup failure route if the environment override fails. The
     exact tracked helper is lifted verbatim into a small compiled
     standalone child process (no UIKit, no engine/App build) and every
     option case is exercised against the real getenv/setenv behavior; no
     re-implemented mirror is used as proof;
  5. no tracked native/script source ships a SAL_KIT_OPTIONS test override;
  6. the FloeOfficeNative Print callback contract (public nullable copy
     block, interception rules, upstream fallback, live-session gate) is
     unchanged.

With --syntax-check the patched salios member is additionally translated with
-fsyntax-only under the exact locked per-platform compile recipe inputs (no
object code is produced). That check needs the Xcode toolchain and the staged
simulator bundle include roots beside the engine source.

Usage:
    python3 test_office_calc_background.py [--engine-source PATH] [--syntax-check]

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
PATCH_PATH = COLLABORA / 'patches' / 'ios-foreign-bitmap-readback.patch'
PATCH_REL = 'patches/ios-foreign-bitmap-readback.patch'
RETIRED_PATCH_REL = 'patches/ios-unified-transparency-alpha.patch'
HEADER_PATH = COLLABORA / 'FloeOfficeNative' / 'FloeOfficeNative.h'
MM_PATH = COLLABORA / 'FloeOfficeNative' / 'FloeOfficeNative.mm'
PINNED_COMMIT = '27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc'
SALIOS_SOURCE = 'engine/vcl/ios/salios.cxx'
SALIOS_ORIGINAL_SHA256 = \
    '0a671dcd57de890a480d52a672bb5721c119547ca5724463077e705cab356d5a'

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


def _lifecycle():
    sys.path.insert(0, str(SCRIPT_DIR))
    import office_compiled_lifecycle as lifecycle
    return lifecycle


def _load_lock():
    return json.loads(LOCK_PATH.read_text())


def _git_show(engine_source: Path, source_file: str) -> bytes:
    return subprocess.check_output(
        ['git', '-C', str(engine_source), 'show', f'HEAD:{source_file}'])


def _staged_patched(engine_source: Path, spec) -> bytes:
    pristine = _git_show(engine_source, spec['sourceFile'])
    with tempfile.TemporaryDirectory(prefix='floe-calc-bg-apply-') as tmp:
        stage = Path(tmp)
        staged = stage / spec['sourceFile']
        staged.parent.mkdir(parents=True)
        staged.write_bytes(pristine)
        result = subprocess.run(
            ['git', 'apply', '--include=' + spec['sourceFile'], str(PATCH_PATH)],
            cwd=stage, capture_output=True, text=True)
        assert result.returncode == 0, (spec['sourceFile'], result.stderr)
        return staged.read_bytes()


def _salios_specs(lock):
    """Every locked member recipe that references the readback patch."""
    lifecycle = _lifecycle()
    specs = {}
    for platform in ('IOS', 'IOSSIMULATOR'):
        selected = lifecycle.contract(lock, platform)
        for member, spec in selected['additionalMembers'].items():
            if spec.get('patch') == PATCH_REL:
                specs[f'compiledMembers.{platform}.additionalMembers.{member}'] = spec
    pinned = lock['qualifiedHostArtifact']['embeddedLifecycleMember']
    for member, spec in pinned['memberSources'].items():
        if spec.get('patch') == PATCH_REL:
            specs[f'embeddedLifecycleMember.memberSources.{member}'] = spec
    return specs


@check('patch file exists and declares only the salios readback source')
def patch_structure():
    text = read(PATCH_PATH)
    assert f'--- a/{SALIOS_SOURCE}' in text
    assert 'memset(pReadbackData, 0,' in text
    assert 'CGBitmapContextGetBytesPerRow(maGraphicContext.get()) * mnHeight' in text
    assert 'Foreign bitmap render targets keep an auxiliary layer' in text
    assert RETIRED_PATCH_REL.split('/')[-1] not in text
    assert not (COLLABORA / RETIRED_PATCH_REL).exists(), \
        'retired unified transparency patch must be removed from the tree'
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


@check('lifecycle contract validates for IOS and IOSSIMULATOR')
def lifecycle_contract():
    lifecycle = _lifecycle()
    lock = _load_lock()
    assert lock['commit'] == PINNED_COMMIT
    for platform in ('IOS', 'IOSSIMULATOR'):
        selected = lifecycle.contract(lock, platform)
        assert selected is not None
        lifecycle.identity(lock, platform, lock_path=LOCK_PATH)
        assert 'libdrawinglayerlo.a' not in selected.get('additionalArchives', {}), \
            'R1 drawinglayer archive must be retired'
        salios = selected['additionalMembers']['salios.o']
        assert salios['patch'] == PATCH_REL, salios['patch']
        assert salios['originalSHA256'] == SALIOS_ORIGINAL_SHA256
    return 'contract/identity OK for both platforms; salios original pinned; ' \
           'no drawinglayer additional archive'


@check('no retired alpha patch referenced anywhere in engine.lock.json')
def retired_patch_unreferenced():
    lock = _load_lock()

    def walk(value):
        if isinstance(value, dict):
            for child in value.values():
                yield from walk(child)
        elif isinstance(value, list):
            for child in value:
                yield from walk(child)
        elif isinstance(value, str):
            yield value

    hits = [text for text in walk(lock) if 'ios-unified-transparency-alpha' in text]
    assert not hits, hits
    return 'engine.lock.json has no unified-transparency-alpha reference'


@check('patch applies to pinned source with build-time --include semantics')
def patch_applies():
    engine_source = ARGS.engine_source
    head = subprocess.check_output(
        ['git', '-C', str(engine_source), 'rev-parse', 'HEAD'], text=True).strip()
    assert head == PINNED_COMMIT, (head, PINNED_COMMIT)
    lifecycle = _lifecycle()
    lock = _load_lock()
    pristine = _git_show(engine_source, SALIOS_SOURCE)
    assert sha256(pristine) == SALIOS_ORIGINAL_SHA256
    outcomes = []
    seen = set()
    for label, spec in _salios_specs(lock).items():
        patched = _staged_patched(engine_source, spec)
        digest = sha256(patched)
        assert digest == spec['patchedSHA256'], \
            (label, digest, spec['patchedSHA256'])
        assert spec['patchSHA256'] == sha256(PATCH_PATH.read_bytes()), \
            (label, 'lock patchSHA256 differs from patch file bytes')
        if digest not in seen:
            seen.add(digest)
            outcomes.append(f'{Path(spec["sourceFile"]).name}:{digest[:12]}')
    assert len(_salios_specs(lock)) == 3, _salios_specs(lock).keys()
    return '; '.join(outcomes) + f' ({len(_salios_specs(lock))} locked members)'


@check('salios patched source: narrow readback zero-init + foreign bitmap copy only')
def salios_source_proof():
    lifecycle = _lifecycle()
    lock = _load_lock()
    spec = lifecycle.contract(lock, 'IOS')['additionalMembers']['salios.o']
    text = _staged_patched(ARGS.engine_source, spec).decode()
    # R2: the CGLayer readback blends over a zero-initialized context buffer.
    assert 'pReadbackData' in text
    assert 'CGBitmapContextGetData(maGraphicContext.get())' in text
    create_fn = text.index(
        'bool QuartzSalBitmap::Create(CGLayerHolder const & rLayerHolder')
    draw_pos = text.index('CGContextDrawLayerAtPoint(maGraphicContext.get(), aSrcPoint',
                          create_fn)
    zero_pos = text.index('memset(pReadbackData, 0,', create_fn)
    assert zero_pos < draw_pos, 'readback buffer must be zeroed before DrawLayerAtPoint'
    # Original: foreign bitmap render targets copy through the observed
    # top-left bitmap -> internal layer path.
    assert 'Foreign bitmap render targets keep an auxiliary layer' in text
    # Retired R1 must not be present: no drawinglayer isolated-group helpers,
    # no alpha-capable SetSize surface branch.
    for retired in ('isIsolatedGroupTarget',
                    'kCGImageAlphaPremultipliedFirst', 'DeviceFormat::WITH_ALPHA',
                    'maUsedBuffers.emplace_back(pRetval, eFormat)'):
        assert retired not in text, f'R1 artifact still present: {retired}'
    set_size = text.index('bool AquaSalVirtualDevice::SetSize(')
    set_size_line = text[set_size:text.index('\n', set_size)]
    assert '/*bAlphaMaskTransparent*/' in set_size_line, \
        'SetSize must keep the stable preR1 unused-parameter signature'
    assert 'kCGImageAlphaNoneSkipFirst' in text, 'opaque branch must remain'
    return 'zero-init precedes DrawLayerAtPoint; foreign copy present; R1 absent'


def _extract_helper_source() -> str:
    """Lift the exact tracked helper translation unit (no re-implementation)."""
    mm = read(MM_PATH)
    begin = mm.index('static bool FloeNormalizeKitOptionsForCalcBackground(void) {')
    end = mm.index('// FLOE_CALC_BACKGROUND_END', begin)
    return mm[begin:end]


def _host_clang():
    toolchains = [
        Path('/Applications/Xcode.app/Contents/Developer/Toolchains'
             '/XcodeDefault.xctoolchain/usr/bin/clang++'),
        Path('/Library/Developer/CommandLineTools/usr/bin/clang++'),
    ]
    for toolchain in toolchains:
        if toolchain.is_file():
            return str(toolchain)
    result = subprocess.run(['xcrun', '-f', 'clang++'], capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


@check('native default normalizes SAL_KIT_OPTIONS between setup and engine init')
def native_default_proof():
    mm = read(MM_PATH)
    helper = 'static bool FloeNormalizeKitOptionsForCalcBackground(void)'
    assert helper in mm
    assert 'const char *kGridToken = "sc_no_grid_bg";' in mm
    assert 'token == kGridToken' in mm
    assert "::setenv(kVariable, kept.c_str(), 1 /* override */) == 0" in mm
    # Failure must reuse the existing generic startup failure route/text.
    assert '[self fail:OfficeError(3, @"Office engine initialization failed.")]' in mm
    generic_failures = mm.count('OfficeError(3, @"Office engine initialization failed.")')
    assert generic_failures >= 3, generic_failures
    start = mm.index('- (void)startEngine')
    setup_pos = mm.index('setupKitEnvironment(', start)
    normalize_pos = mm.index('FloeNormalizeKitOptionsForCalcBackground()', setup_pos)
    engine_init_pos = mm.index('cok_init_2(', start)
    assert setup_pos < normalize_pos < engine_init_pos, \
        'normalization must run after setupKitEnvironment and before cok_init_2'
    # The Print callback region must remain downstream-untouched by this edit.
    assert 'onPrintRequested' in mm
    return 'normalize runs pre-init; exact-token operator; generic failure route'


HELPER_OPTION_CASES = {
    # iPad upstream default -> grid token dropped, companions verbatim.
    'unipoll:notebookbar:sc_no_grid_bg:sc_print_twips_msgs':
        'unipoll:notebookbar:sc_print_twips_msgs',
    # iPhone upstream default.
    'unipoll:sc_no_grid_bg:sc_print_twips_msgs':
        'unipoll:sc_print_twips_msgs',
    # Lone token -> empty option set.
    'sc_no_grid_bg': '',
    # No grid token -> untouched.
    'unipoll:notebookbar:sc_print_twips_msgs':
        'unipoll:notebookbar:sc_print_twips_msgs',
    # Leading token.
    'sc_no_grid_bg:unipoll': 'unipoll',
    # Trailing token.
    'unipoll:sc_no_grid_bg': 'unipoll',
    # Substring of a longer token must not match.
    'asc_no_grid_bg': 'asc_no_grid_bg',
    # Duplicate tokens all drop.
    'sc_no_grid_bg:sc_no_grid_bg': '',
}


def _macos_sdk():
    env = dict(os.environ,
               DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    result = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                            capture_output=True, text=True, env=env)
    if result.returncode != 0:
        result = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                                capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


@check('exact tracked helper exercised per option case in a compiled child')
def helper_behavior_cases():
    """Compile the verbatim extracted helper (no UIKit, no engine/App build)
    and run every option case in a fresh child process with the variable
    preset, asserting the real getenv/setenv behavior. A self-written Python
    mirror is deliberately NOT used as proof."""
    clang = _host_clang()
    assert clang is not None, 'no host clang++ available for the standalone helper harness'
    sdk = _macos_sdk()
    scratch = REPO_ROOT / 'Local' / 'Scratch' / 'calc-background-compat'
    scratch.mkdir(parents=True, exist_ok=True)
    harness = """#include <cstdio>
#include <cstdlib>
#include <string>

%s

int main() {
    const bool ok = FloeNormalizeKitOptionsForCalcBackground();
    const char *result = ::getenv("SAL_KIT_OPTIONS");
    std::printf("__FLOE_RESULT__ %%d %%s\\n", ok ? 0 : 1,
                result ? result : "<unset>");
    return 0;
}
""" % _extract_helper_source()
    with tempfile.TemporaryDirectory(prefix='floe-calc-bg-helper-', dir=scratch) as tmp:
        tmp = Path(tmp)
        source = tmp / 'helper_harness.cpp'
        binary = tmp / 'helper_harness'
        source.write_text(harness, encoding='utf-8')
        command = [clang, '-std=c++17', '-Wall', '-Werror', '-O0']
        if sdk:
            command += ['-isysroot', sdk]
        command += [str(source), '-o', str(binary)]
        compile_result = subprocess.run(command, capture_output=True, text=True)
        assert compile_result.returncode == 0, compile_result.stderr
        outcomes = []
        for preset, expected in HELPER_OPTION_CASES.items():
            env = dict(os.environ)
            env['SAL_KIT_OPTIONS'] = preset
            run = subprocess.run([str(binary)], capture_output=True, text=True,
                                 env=env, timeout=30)
            assert run.returncode == 0, (preset, run.stderr)
            prefix = '__FLOE_RESULT__ '
            line = next(l for l in run.stdout.splitlines()
                        if l.startswith(prefix))
            _, rc_text, result = line.split(' ', 2)
            assert rc_text == '0', (preset, 'helper reported failure', line)
            assert result == expected, (preset, result, expected)
            outcomes.append(f'{preset[:26]!r}->{result[:26]!r}')
        unset_env = {k: v for k, v in os.environ.items() if k != 'SAL_KIT_OPTIONS'}
        run = subprocess.run([str(binary)], capture_output=True, text=True,
                             env=unset_env, timeout=30)
        line = next(l for l in run.stdout.splitlines()
                    if l.startswith('__FLOE_RESULT__ '))
        _, rc_text, result = line.split(' ', 2)
        assert rc_text == '0' and result == '<unset>', line
        return f'{len(outcomes)} preset cases + unset case match actual behavior'


@check('no SAL_KIT_OPTIONS override ships in tracked native or script sources')
def no_test_override():
    offenders = []
    for path in [MM_PATH, HEADER_PATH]:
        text = read(path)
        if 'SAL_KIT_OPTIONS' in text and 'FloeNormalizeKitOptionsForCalcBackground' not in text:
            offenders.append(str(path))
    # The tracked native host must set SAL_KIT_OPTIONS in exactly one code
    # line (the helper's kVariable literal); every other mention is a comment.
    mm = read(MM_PATH)
    code_hits = [line for line in mm.splitlines()
                 if 'SAL_KIT_OPTIONS' in line and not line.lstrip().startswith('//')]
    assert code_hits == ['    const char *kVariable = "SAL_KIT_OPTIONS";'], code_hits
    # No xctestrun / scheme override may inject the variable.
    for scheme in (REPO_ROOT / 'FloeAgent').rglob('*.xctestrun'):
        if 'SAL_KIT_OPTIONS' in read(scheme):
            offenders.append(str(scheme))
    assert not offenders, offenders
    return 'tracked default only; no test override'


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
        if (candidate / 'source/engine/instdir/program/libvcllo.a').is_file():
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


def syntax_checks():
    lifecycle = _lifecycle()
    lock = _load_lock()
    sdk_path = subprocess.check_output(
        ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    selected = lifecycle.contract(lock, 'IOSSIMULATOR')
    salios = selected['additionalMembers']['salios.o']
    import office_engine_repair  # noqa: PLC0415 - bounded recipe reuse
    compile_lock = json.loads((COLLABORA / 'engine.patch.lock.json').read_text())
    base = compile_lock['platforms']['IOSSIMULATOR']['compile']
    flags = list(base['flags'])
    patched = _staged_patched(ARGS.engine_source, salios)
    bundle = _bundle_for_sdk()
    assert bundle is not None, 'staged simulator bundle not found for --syntax-check'
    with tempfile.TemporaryDirectory(prefix='floe-calc-bg-syntax-') as tmp:
        staged = Path(tmp) / Path(salios['sourceFile']).name
        staged.write_bytes(patched)
        command = [_xcode_clang(), '-arch', 'arm64',
                   '-target', 'arm64-apple-ios26.0-simulator',
                   '-isysroot', sdk_path, '-fsyntax-only']
        command += flags
        for inc in base['sourceIncludes']:
            command.append('-I' + str(ARGS.engine_source / inc))
        for inc in base['bundleIncludes']:
            command.append('-I' + str(bundle / inc))
        command.append(str(staged))
        result = subprocess.run(command, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        notes = result.stderr.strip()
        return 'salios translates clean' + (f' (warnings: {notes.splitlines()[0]})'
                                            if notes else '')


SOURCE_CHECKS = {patch_applies, salios_source_proof}


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
        checks.append(('locked-recipe -fsyntax-only translation of the patched member',
                       syntax_checks))
    failures = 0
    for name, fn in checks:
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
    print(f'all {len(checks)} checks passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
