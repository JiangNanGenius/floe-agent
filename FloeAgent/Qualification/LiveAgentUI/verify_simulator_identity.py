"""Verify Xcode's simulated Keychain identity without modifying the App artifact."""
import hashlib
import json
import pathlib
import plistlib
import struct
import sys


def simulated_entitlements(binary):
    # Read the exact section bytes. otool's last partial word can otherwise
    # truncate XML whose size is not a multiple of four.
    with pathlib.Path(binary).open('rb') as stream:
        header = stream.read(32)
        if len(header) != 32:
            raise ValueError('Truncated Mach-O header')
        magic, cpu, _, _, count, commands_size, _, _ = struct.unpack('<8I', header)
        if magic != 0xFEEDFACF or cpu != 0x0100000C:
            raise ValueError('Expected the qualified thin arm64 simulator binary')
        if count > 4096 or commands_size > 16 * 1024 * 1024:
            raise ValueError('Invalid Mach-O load commands')
        commands = stream.read(commands_size)
        offset = 0
        for _ in range(count):
            if offset + 8 > len(commands):
                raise ValueError('Truncated Mach-O load command')
            command, size = struct.unpack_from('<II', commands, offset)
            if size < 8 or offset + size > len(commands):
                raise ValueError('Invalid Mach-O command size')
            if command == 0x19:  # LC_SEGMENT_64, followed by section_64 records.
                if size < 72:
                    raise ValueError('Truncated segment')
                sections = struct.unpack_from('<I', commands, offset + 64)[0]
                if 72 + sections * 80 > size:
                    raise ValueError('Truncated section table')
                for index in range(sections):
                    base = offset + 72 + index * 80
                    name, segment = struct.unpack_from('<16s16s', commands, base)
                    if name.rstrip(b'\0') == b'__entitlements' and segment.rstrip(b'\0') == b'__TEXT':
                        length, position = struct.unpack_from('<QI', commands, base + 40)
                        if length > 1024 * 1024:
                            raise ValueError('Oversized simulated entitlements')
                        stream.seek(position)
                        data = stream.read(length)
                        if len(data) != length:
                            raise ValueError('Truncated simulated entitlements')
                        return plistlib.loads(data.rstrip(b'\0'))
            offset += size
    return {}


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
