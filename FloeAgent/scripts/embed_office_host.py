#!/usr/bin/env python3
"""Copy the verified native Office product into Floe's generated app.

Device builds embed the pinned ``iphoneos`` host (unchanged pinned flow).
Simulator builds embed the verified ``iphonesimulator`` host only when one was
explicitly installed (``FLOE_OFFICE_SIM_HOST_DIR``); otherwise they keep the
long-standing honest Office skip. Both paths re-verify every pinned hash at
build time — embedding never trusts the presence of a directory alone.

Every App build also stages the bundled CJK/utility fonts once into the
engine-scanned ``program/resource/common/fonts`` directory and prunes the
identical font binaries from the packaged ``Bundled/`` resources (licences and
provenance stay). Simulator builds without an Office host stage the same fonts,
so the App registrar and the no-Office simulator keep working.
"""
import json
import os
from collections import Counter
from pathlib import Path
import plistlib
import shutil
import subprocess
from bootstrap_office_host import (ROOT, LOCK, FRAMEWORK, checked_lock,
                                   verify_installed, verify_simulator_host)
from office_font_config import (BEGIN_MARK, language_packaging_failures,
                                language_resource_report, validate_merged_config)

FONT_EXTENSIONS = {'.ttf', '.otf', '.ttc', '.otc'}
BUNDLED_FONTS = ROOT / 'FloeApp' / 'Resources' / 'Fonts' / 'Bundled'
# The engine's quartz backend scans $BRAND_BASE_DIR/program/resource/common/fonts
# and $BRAND_BASE_DIR/share/fonts/truetype and registers every file it finds
# there for the process before it caches the available CoreText font list
# (pinned vcl/quartz/salgdi.cxx AddLocalTempFontDirs, then GetCoretextFontList).
# The app-level Fonts/ directory is on neither path: fonts staged there were
# never discovered by the engine, so the bundled CJK families go into the
# engine-scanned internal font directory instead.
ENGINE_FONT_DIR = ('program', 'resource', 'common', 'fonts')


def engine_font_dir(app):
    fonts_dir = app
    for component in ENGINE_FONT_DIR:
        fonts_dir = fonts_dir / component
    return fonts_dir


def prune_bundled_font_copies(app):
    """Remove font binaries from the App-resource ``Bundled/`` folder.

    ``project.yml`` still packages ``FloeApp/Resources/Fonts/Bundled`` so the
    per-family ``LICENSE.txt`` and ``provenance.json`` files keep their
    existing bundle paths (the Settings licence viewer and the third-party
    inventory depend on them). The font binaries themselves are staged once
    into the engine-scanned directory by :func:`embed_bundled_fonts`; keeping
    the source copies in the built bundle would duplicate ~375 MB of identical
    bytes inside one IPA.

    Only regular font files directly below ``app/Bundled`` are removed. A
    symlinked font is an unexpected build alias and fails closed.
    """
    root = app / 'Bundled'
    if not root.is_dir():
        return 0
    removed = 0
    for path in sorted(root.rglob('*')):
        if path.suffix.lower() not in FONT_EXTENSIONS:
            continue
        if path.is_symlink():
            raise ValueError('duplicate App font pruning refuses a symlinked font')
        if not path.is_file():
            continue
        path.unlink()
        removed += 1
    return removed


def embed_bundled_fonts(app):
    """Stage Floe's bundled CJK/utility families once, in the engine-scanned
    internal font directory.

    The engine renders CJK from files registered by its quartz backend, whose
    discovery roots are ``program/resource/common/fonts`` and
    ``share/fonts/truetype``. The App registrar uses the same first root, so
    one physical copy serves both loaders. The App-resource ``Bundled/``
    copies are pruned afterwards; their licence and provenance files stay.
    """
    fonts_dir = engine_font_dir(app)
    fonts_dir.mkdir(parents=True, exist_ok=True)
    if not BUNDLED_FONTS.is_dir():
        print('warning: bundled fonts not staged; run scripts/fonts/fetch_fonts.py (CI enforces this)')
        return 0
    sources = [
        path for path in sorted(BUNDLED_FONTS.rglob('*'))
        if path.suffix.lower() in FONT_EXTENSIONS and path.is_file() and not path.is_symlink()
    ]
    # Deterministic target names make re-running the post-build step
    # idempotent: a name shared by two families is prefixed with its family
    # directory, every other file keeps its basename. Never branch on
    # target.exists(), because that turns a stale file from an earlier build
    # into a second physical copy.
    basename_counts = Counter(path.name for path in sources)
    staged = []
    for path in sources:
        name = path.name if basename_counts[path.name] == 1 else f'{path.parent.name}-{path.name}'
        target = fonts_dir / name
        if target.is_symlink():
            raise ValueError('engine font staging refuses a symlinked destination')
        shutil.copy2(path, target)
        staged.append((path, target))
    if not staged:
        print('warning: bundled font directory has no font files; nothing staged')
        return 0
    removed = prune_bundled_font_copies(app)
    for source, target in staged:
        if not target.is_file() or target.stat().st_size != source.stat().st_size:
            raise ValueError(f'staged font verification failed: {target.name}')
    remaining = [
        path for path in (app / 'Bundled').rglob('*')
        if path.suffix.lower() in FONT_EXTENSIONS and path.is_file()
    ] if (app / 'Bundled').is_dir() else []
    if remaining:
        raise ValueError('duplicate App font copies remain after staging: '
                         + ', '.join(sorted(path.name for path in remaining)[:5]))
    print(f'embedded {len(staged)} bundled fonts into {"/".join(ENGINE_FONT_DIR)}/ '
          f'(removed {removed} duplicate App-resource copies)')
    return len(staged)


def verify_font_and_language_payload(app, host_resources, *, font_dirs=None):
    """Build-233 payload facts for the embedded font/language configuration.

    * A host artifact rebuilt with the R4 font-substitution overlay carries the
      marked block; if it does, every Floe alias must resolve to a family this
      app really installs, or the embedding fails.
    * An artifact that predates the overlay is reported as such (the release
      gate refuses it); it is never silently accepted as repaired.
    * Every language resource the host output produced must reach the app.
    """
    coolkit = app / 'coolkitconfig.xcu'
    facts = {'fontSubstitutionsPresent': False, 'fontSubstitutionsRepaired': False}
    if coolkit.is_file() and BEGIN_MARK in coolkit.read_text(encoding='utf-8', errors='ignore'):
        font_dirs = font_dirs or [app / 'program/resource/common/fonts',
                                  app / 'share/fonts/truetype']
        main_xcd = app / 'share/registry/main.xcd'
        validation = validate_merged_config(
            coolkit, font_dirs,
            vendor_config=main_xcd if main_xcd.is_file() else None)
        if validation['failures']:
            raise ValueError('embedded Office font substitutions do not resolve: '
                             + '; '.join(validation['failures']))
        facts.update(fontSubstitutionsPresent=True, fontSubstitutionsRepaired=True,
                     fontSubstitutionAliases=validation['resolvedCount'])
    else:
        facts['fontSubstitutionNote'] = (
            'pinned host artifact predates the Build 233 font-substitution overlay; '
            'a rebuilt and re-pinned host is required')
    host_language = language_resource_report(host_resources)
    app_language = language_resource_report(app)
    failures = language_packaging_failures(host_language, app_language)
    if failures:
        raise ValueError('embedded Office language resources are incomplete: '
                         + '; '.join(failures))
    facts.update(hostLanguageResources=host_language, appLanguageResources=app_language,
                 languageResourceGap=host_language['missingLanguages'])
    return facts


def embed(source, app, lock_path=LOCK, *, signing_identity=None):
    lock, pin = checked_lock(lock_path)
    source, app = Path(source), Path(app)
    verified = verify_installed(source, lock, pin)
    # Only generated Floe app products are eligible; never original documents,
    # arbitrary application bundles, or a framework supplied at runtime.
    if app.is_symlink() or app.suffix != '.app':
        raise ValueError('Office embedding requires a generated Floe app bundle')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'org.floeagent.ios':
        raise ValueError('Office embedding destination is not Floe')
    resources = source / 'OfficeRuntimeResources'
    outputs = [(source / FRAMEWORK, app / 'Frameworks' / FRAMEWORK)]
    outputs += [(path, app / path.name) for path in sorted(resources.iterdir())]
    for _, target in outputs:
        if target.is_symlink() or any(parent.is_symlink() for parent in target.parents if parent != app and parent.is_relative_to(app)):
            raise ValueError('Office app output contains an unexpected alias')
    # These exact output paths are reserved to Office in the Xcode file list.
    # Remove old generated resource trees so deleted assets cannot survive an
    # incremental build; the verified source and user data are never modified.
    for original, target in outputs:
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()
        if original.is_dir():
            shutil.copytree(original, target)
        else:
            shutil.copy2(original, target)
    framework = app / 'Frameworks' / FRAMEWORK
    (framework / 'FloeOfficeNative').chmod(0o755)
    bundled_fonts = embed_bundled_fonts(app)
    payload = verify_font_and_language_payload(app, resources)
    if signing_identity:
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', signing_identity,
                        '--timestamp=none', str(framework)], check=True)
    return {**verified, 'embeddedFramework': True, 'signedFramework': bool(signing_identity),
            'bundledFonts': bundled_fonts, **payload,
            'runtimeOpened': False, 'deviceRoundtripPassed': False}


def embed_simulator(source, app):
    """Embed the verified iphonesimulator Office host into the simulator app.

    The simulator host carries its own receipt and pin gates
    (``bootstrap_office_host.verify_simulator_host``); the device pin and the
    device host are never consulted here. Simulator bundles are not code
    signed, so no signing step runs on this path.
    """
    source, app = Path(source), Path(app)
    verified = verify_simulator_host(source, LOCK)
    if app.is_symlink() or app.suffix != '.app':
        raise ValueError('Office simulator embedding requires a generated Floe app bundle')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'org.floeagent.ios':
        raise ValueError('Office simulator embedding destination is not Floe')
    resources = source / 'OfficeRuntimeResources'
    outputs = [(source / FRAMEWORK, app / 'Frameworks' / FRAMEWORK)]
    outputs += [(path, app / path.name) for path in sorted(resources.iterdir())]
    for _, target in outputs:
        if target.is_symlink() or any(parent.is_symlink() for parent in target.parents if parent != app and parent.is_relative_to(app)):
            raise ValueError('Office simulator app output contains an unexpected alias')
    for original, target in outputs:
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()
        if original.is_dir():
            shutil.copytree(original, target)
        else:
            shutil.copy2(original, target)
    framework = app / 'Frameworks' / FRAMEWORK
    (framework / 'FloeOfficeNative').chmod(0o755)
    bundled_fonts = embed_bundled_fonts(app)
    payload = verify_font_and_language_payload(app, resources)
    return {**verified, 'embeddedFramework': True, 'signedFramework': False,
            'simulatorHost': True, 'bundledFonts': bundled_fonts, **payload,
            'runtimeOpened': False, 'deviceRoundtripPassed': False}


def main():
    platform_name = os.environ.get('PLATFORM_NAME')
    if platform_name == 'iphonesimulator':
        app = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['WRAPPER_NAME']
        host_dir = os.environ.get('FLOE_OFFICE_SIM_HOST_DIR', '').strip()
        if not host_dir:
            # The fonts are App payload, not Office payload: a no-Office
            # simulator build still registers the bundled families and still
            # must contain exactly one copy of each. Office itself keeps the
            # long-standing honest skip.
            facts = {
                'platform': 'iphonesimulator',
                'embeddedFramework': False,
                'signedFramework': False,
                'officeHostSkipped': True,
                'bundledFonts': embed_bundled_fonts(app),
                'runtimeOpened': False,
                'deviceRoundtripPassed': False,
            }
            print(json.dumps(facts, indent=2))
            return
        print(json.dumps(embed_simulator(Path(host_dir), app), indent=2))
        return
    if platform_name != 'iphoneos':
        print('Native Office has no Simulator slice; device embedding skipped')
        return
    _, pin = checked_lock(LOCK)
    source = ROOT / 'Vendor/Office' / pin['runID'] / 'OfficeNativeHost'
    app = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['WRAPPER_NAME']
    signing = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') if os.environ.get('CODE_SIGNING_ALLOWED') != 'NO' else None
    if os.environ.get('CODE_SIGNING_ALLOWED') != 'NO' and not signing:
        raise ValueError('A signed Floe build requires an Office framework signing identity')
    print(json.dumps(embed(source, app, signing_identity=signing), indent=2))


if __name__ == '__main__':
    main()
