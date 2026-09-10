#!/usr/bin/env python3
"""Copy the verified native Office product into Floe's generated device app."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
from bootstrap_office_host import ROOT, LOCK, FRAMEWORK, checked_lock, verify_installed

FONT_EXTENSIONS = {'.ttf', '.otf', '.ttc', '.otc'}
BUNDLED_FONTS = ROOT / 'FloeApp' / 'Resources' / 'Fonts' / 'Bundled'


def embed_bundled_fonts(app):
    """Populate the engine's app-level Fonts/ directory with Floe's bundled
    CJK/utility families. The directory is a declared embed output and starts
    empty upstream; without it the engine renders every CJK glyph as a box
    because it cannot see iOS system fonts."""
    fonts_dir = app / 'Fonts'
    fonts_dir.mkdir(exist_ok=True)
    if not BUNDLED_FONTS.is_dir():
        print('warning: bundled fonts not staged; run scripts/fonts/fetch_fonts.py (CI enforces this)')
        return 0
    copied = 0
    for path in sorted(BUNDLED_FONTS.rglob('*')):
        if path.suffix.lower() not in FONT_EXTENSIONS or not path.is_file():
            continue
        target = fonts_dir / path.name
        if target.exists():
            # Two families can share a filename; prefix the family directory.
            target = fonts_dir / f'{path.parent.name}-{path.name}'
        shutil.copy2(path, target)
        copied += 1
    print(f'embedded {copied} bundled fonts into Fonts/')
    return copied


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
    if signing_identity:
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', signing_identity,
                        '--timestamp=none', str(framework)], check=True)
    return {**verified, 'embeddedFramework': True, 'signedFramework': bool(signing_identity),
            'bundledFonts': bundled_fonts,
            'runtimeOpened': False, 'deviceRoundtripPassed': False}


def main():
    if os.environ.get('PLATFORM_NAME') != 'iphoneos':
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
