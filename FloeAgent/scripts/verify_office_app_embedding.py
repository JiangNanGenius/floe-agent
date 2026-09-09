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



def linked_libraries(binary):
    output = subprocess.check_output(['xcrun', 'otool', '-L', str(binary)], text=True)
    return [line.strip().split(' (compatibility version', 1)[0]
            for line in output.splitlines()[1:] if line.strip()]


def runtime_paths(binary):
    output = subprocess.check_output(['xcrun', 'otool', '-l', str(binary)], text=True)
    found = []
    reading = False
    for line in output.splitlines():
        line = line.strip()
        if line.startswith('cmd '):
            reading = line == 'cmd LC_RPATH'
        elif reading and line.startswith('path '):
            found.append(line[5:].split(' (offset ', 1)[0])
            reading = False
    return found


def resolves_to(reference, target, *, app, loader, paths):
    def expand(value):
        for prefix, directory in [('@executable_path', app), ('@loader_path', loader.parent)]:
            if value == prefix or value.startswith(prefix + '/'):
                return directory / value[len(prefix):].lstrip('/')
        return Path(value) if value.startswith('/') else None
    candidates = []
    if reference.startswith('@rpath/'):
        for entry in paths:
            parent = expand(entry)
            if parent is not None:
                candidates.append(parent / reference[len('@rpath/'):])
    else:
        value = expand(reference)
        if value is not None:
            candidates.append(value)
    return any(path.resolve() == target.resolve() for path in candidates)


def verify_office_load_chain(app, executable):
    """Require a real direct or Xcode Debug-dylib load chain, not a stray file."""
    app = Path(app)
    binary = app / executable
    if Path(executable).name != executable or binary.is_symlink() or not binary.is_file():
        raise ValueError('Unexpected Floe executable path')
    host_reference = '@rpath/FloeOfficeNative.framework/FloeOfficeNative'
    host = app / 'Frameworks/FloeOfficeNative.framework/FloeOfficeNative'
    if not host.is_file() or any(path.is_symlink() for path in [host, *host.parents] if path.is_relative_to(app)):
        raise ValueError('Floe Office host is missing or aliased')
    main_libraries = linked_libraries(binary)
    main_paths = runtime_paths(binary)
    loaders = [(binary, main_libraries, main_paths)]
    debug_name = executable + '.debug.dylib'
    debug = app / debug_name
    for reference in main_libraries:
        if reference not in ('@rpath/' + debug_name, '@executable_path/' + debug_name, '@loader_path/' + debug_name):
            continue
        if not resolves_to(reference, debug, app=app, loader=binary, paths=main_paths):
            continue
        if debug.is_symlink() or not debug.is_file():
            raise ValueError('Floe debug code binary is missing or aliased')
        loaders.append((debug, linked_libraries(debug), runtime_paths(debug) + main_paths))
    for loader, libraries, paths in loaders:
        if host_reference in libraries and resolves_to(host_reference, host, app=app, loader=loader, paths=paths):
            return {'appCodeBinaryPath': loader.name, 'appCodeBinarySHA256': digest(loader),
                    'officeLoadChain': [binary.name] + ([loader.name] if loader != binary else []) + [host_reference],
                    'appLinksOfficeHost': True}
    raise ValueError('Floe executable has no resolvable load chain to its Office host')


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
    result.update(verify_office_load_chain(args.app, name))
    result.update(appExecutableSHA256=digest(binary),
        appPlatformLoadCommands=subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True))
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
