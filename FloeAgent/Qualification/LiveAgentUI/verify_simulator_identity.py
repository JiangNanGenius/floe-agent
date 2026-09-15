"""Verify Xcode's simulated Keychain identity without modifying the App artifact."""
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import sys


def simulated_entitlements(binary):
    result = subprocess.run(['otool', '-X', '-s', '__TEXT', '__entitlements', str(binary)],
                            check=True, capture_output=True, text=True)
    words = [word for line in result.stdout.splitlines() for word in line.split()
             if re.fullmatch(r'[0-9a-fA-F]{8}', word)]
    # The qualification artifact is arm64; otool prints little-endian 32-bit
    # words as integers, not byte-order hex strings.
    data = b''.join(int(word, 16).to_bytes(4, 'little') for word in words).rstrip(b'\0')
    return plistlib.loads(data) if data else {}


def main():
    app, out = map(pathlib.Path, sys.argv[1:])
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'org.floeagent.ios'
    assert info['CFBundleSupportedPlatforms'] == ['iPhoneSimulator']
    exe = app / info['CFBundleExecutable']
    identity = 'QYL72C43K6.' + info['CFBundleIdentifier']
    matches = []
    for binary in [exe, *app.glob('*.debug.dylib')]:
        entitlements = simulated_entitlements(binary)
        if entitlements.get('application-identifier') == identity:
            matches.append({'binary': binary.name, 'applicationIdentifier': identity})
    assert matches, 'App must be built with Xcode simulator signing enabled; post-build codesign is insufficient'
    out.mkdir(parents=True, exist_ok=True)
    (out / 'simulator-signing.json').write_text(json.dumps({
        'purpose': 'Verify the immutable App has Xcode simulated Keychain identity',
        'appExecutableSHA256': hashlib.sha256(exe.read_bytes()).hexdigest(),
        'artifactModified': False, 'simulatedEntitlements': matches,
        'signing': 'Xcode simulator identity; not device/distribution signing'
    }, indent=2) + '\n')
    print('Immutable simulator App has Xcode simulated Keychain identity.')


if __name__ == '__main__':
    main()
