#!/usr/bin/env python3
"""Verify unsigned Floe device-app Office payload, not runtime UI or document fidelity."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
from bootstrap_office_host import LOCK, ROOT, FRAMEWORK, checked_lock, verify_installed, digest


def verify_payload(source, app, lock_path=LOCK):
    lock, pin = checked_lock(lock_path)
    source, app = Path(source), Path(app)
    verify_installed(source, lock, pin)
    if app.is_symlink() or app.suffix != '.app':
        raise ValueError('Expected an unsigned generated Floe app')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'org.floeagent.ios':
        raise ValueError('Unexpected application identity')
    manifest = json.loads((source / 'native-host.json').read_text())
    expected = {('Frameworks/' + FRAMEWORK + '/FloeOfficeNative'): pin['executableSHA256']}
    expected.update({'Frameworks/' + FRAMEWORK + '/' + name: checksum
                     for name, checksum in pin['frameworkAuxiliarySHA256'].items()})
    expected.update(manifest['runtimeResourceSHA256'])
    for name in list(expected) + manifest['runtimeResourceDirectories']:
        path = app / name
        if path.is_symlink() or any(parent.is_symlink() for parent in path.parents if parent != app and parent.is_relative_to(app)):
            raise ValueError('Embedded Office payload contains an alias')
    for name, checksum in expected.items():
        if digest(app / name) != checksum:
            raise ValueError('Embedded Office payload differs from qualification: ' + name)
    for name in manifest['runtimeResourceDirectories']:
        if not (app / name).is_dir():
            raise ValueError('Embedded Office resource directory is missing: ' + name)
    return {'hostRunID': pin['runID'], 'sourceCommit': lock['commit'],
        'hostExecutableSHA256': pin['executableSHA256'],
        'verifiedResourceFiles': len(manifest['runtimeResourceSHA256']),
        'verifiedResourceDirectories': len(manifest['runtimeResourceDirectories']),
        'appVersion': info.get('CFBundleShortVersionString'), 'appBuild': info.get('CFBundleVersion'),
        'unsignedPayloadVerified': True, 'engineOpened': False,
        'embeddedEditorPassed': False, 'originalFileWritebackPassed': False, 'deviceRoundtripPassed': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    _, pin = checked_lock(LOCK)
    source = ROOT / 'Vendor/Office' / pin['runID'] / 'OfficeNativeHost'
    result = verify_payload(source, args.app)
    info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    name = info['CFBundleExecutable']
    if Path(name).name != name:
        raise ValueError('Unexpected Floe executable path')
    binary = args.app / name
    linked = subprocess.check_output(['xcrun', 'otool', '-L', str(binary)], text=True)
    if '@rpath/FloeOfficeNative.framework/FloeOfficeNative' not in linked:
        raise ValueError('Floe executable does not link its Office host')
    result.update(appExecutableSHA256=digest(binary), appLinksOfficeHost=True,
        appPlatformLoadCommands=subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True))
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
