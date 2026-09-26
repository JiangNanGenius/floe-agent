#!/usr/bin/env python3
"""Record the exact reason the pinned Office host cannot run in iOS Simulator.

The Floe Office editor is the real Collabora engine. It is compiled for
`iphoneos` arm64 only: the pinned `FloeOfficeNative.framework` is a plain
(not XCFramework) device framework and the engine static libraries in
`engine.lock.json` are iphoneos-arm64 objects. Upstream can build an
`iphonesimulator` engine (`--enable-ios-simulator`), but Floe never configured
that, so no simulator slice exists in any pinned artifact.

This script turns that claim into build/link evidence instead of a comment:

1. read the pinned framework's Mach-O build version and confirm its platform is
   `IOS` (a simulator slice would report `IOSSIMULATOR`);
2. confirm the architecture slice list contains no simulator-only arch;
3. attempt a real link against the simulator SDK and require the linker to
   refuse with the exact device/simulator mismatch diagnostic;
4. optionally verify the framework binary matches the executable SHA-256 pinned
   in `engine.lock.json` (the pin, never a rebuild).

It never compiles, links, renders or certifies an editor; it proves the
simulator-host blocker. A receipt is always written when `--output` is given.
Exit code 0 means the blocker was proven; any other outcome fails closed.
"""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

FRAMEWORK_NAME = 'FloeOfficeNative'
SIMULATOR_PLATFORM = 'IOSSIMULATOR'
PROBE_SOURCE = 'int main(void) { return 0; }\n'


def sha256(path):
    checksum = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


def run(command):
    result = subprocess.run([str(item) for item in command],
                            capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


def parse_build_version(text):
    """Parse `vtool -show-build` output into platform/minos/sdk.

    Returns an empty platform when the output carries no LC_BUILD_VERSION. The
    older LC_VERSION_MIN_IPHONEOS form has no platform field; it is reported as
    `LEGACY-IOS` rather than guessed into a simulator capability.
    """
    facts = {'platform': '', 'minimumOS': '', 'sdk': ''}
    match = re.search(r'^\s*platform\s+(\S+)\s*$', text, re.MULTILINE)
    if match:
        facts['platform'] = match.group(1).upper()
    else:
        if re.search(r'^\s*cmd\s+LC_VERSION_MIN_IPHONEOS\s*$', text, re.MULTILINE):
            facts['platform'] = 'LEGACY-IOS'
    match = re.search(r'^\s*minos\s+(\S+)\s*$', text, re.MULTILINE)
    if match:
        facts['minimumOS'] = match.group(1)
    match = re.search(r'^\s*sdk\s+(\S+)\s*$', text, re.MULTILINE)
    if match:
        facts['sdk'] = match.group(1)
    return facts


def parse_architectures(text):
    text = text.strip()
    if not text:
        return []
    return [item.strip() for item in text.split() if item.strip()]


def simulator_target(arch, minimum_os):
    version = minimum_os or '26.0'
    return f'{arch}-apple-ios{version}-simulator'


def probe(framework, minimum_os='26.0', arch='arm64', workdir=None,
          expected_executable_sha256=None, sdk='iphonesimulator'):
    """Run the platform and simulator-link probes against one framework."""
    framework = Path(framework).resolve()
    binary = framework / FRAMEWORK_NAME
    receipt = {
        'frameworkPath': str(framework),
        'frameworkBinary': str(binary),
        'frameworkBinaryExists': binary.is_file(),
        'realEngineInSimulator': False,
        'simulatorHostBlockerProven': False,
    }
    if not binary.is_file():
        receipt['error'] = f'{binary} is missing'
        return receipt

    receipt['frameworkBinarySHA256'] = sha256(binary)
    if expected_executable_sha256:
        receipt['expectedExecutableSHA256'] = expected_executable_sha256
        receipt['matchesPinnedExecutable'] = (
            receipt['frameworkBinarySHA256'] == expected_executable_sha256)

    code, out, err = run(['vtool', '-show-build', binary])
    receipt['vtoolCommand'] = f'vtool -show-build {binary}'
    receipt['vtoolExitCode'] = code
    if code != 0:
        receipt['error'] = (err or out).strip() or 'vtool failed'
        return receipt
    facts = parse_build_version(out)
    receipt.update({
        'platform': facts['platform'],
        'minimumOS': facts['minimumOS'],
        'sdk': facts['sdk'],
        'platformIsSimulator': facts['platform'] == SIMULATOR_PLATFORM,
    })

    code, out, err = run(['lipo', '-archs', binary])
    receipt['architectures'] = parse_architectures(out if code == 0 else '')
    receipt['lipoExitCode'] = code
    receipt['containsSimulatorArchitecture'] = any(
        item in ('x86_64',) for item in receipt['architectures'])

    temporary = Path(workdir) if workdir else Path(tempfile.mkdtemp(prefix='floe-office-sim-probe-'))
    temporary.mkdir(parents=True, exist_ok=True)
    source = temporary / 'simulator-link-probe.c'
    source.write_text(PROBE_SOURCE)
    output = temporary / 'simulator-link-probe.out'
    target = simulator_target(arch, receipt['minimumOS'] or minimum_os)
    command = ['xcrun', '--sdk', sdk, 'clang', '-target', target,
               str(source), '-F', str(framework.parent),
               '-framework', FRAMEWORK_NAME, '-o', str(output)]
    code, out, err = run(command)
    diagnostic = (err or out).strip()
    first_line = diagnostic.splitlines()[0] if diagnostic else ''
    refuses_device_objects = (
        code != 0
        and "built for 'iOS'" in diagnostic
        and ('iOS-simulator' in diagnostic or 'iOS Simulator' in diagnostic))
    receipt.update({
        'simulatorLinkAttempted': True,
        'simulatorTarget': target,
        'simulatorLinkCommand': ' '.join(command),
        'simulatorLinkExitCode': code,
        'simulatorLinkRefused': refuses_device_objects,
        'simulatorLinkDiagnostic': first_line,
    })
    receipt['simulatorHostBlockerProven'] = bool(
        receipt['frameworkBinaryExists']
        and receipt['platform']
        and not receipt['platformIsSimulator']
        and receipt['simulatorLinkRefused']
        and (expected_executable_sha256 is None
             or receipt.get('matchesPinnedExecutable') is True))
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('framework', help='Path to the extracted FloeOfficeNative.framework directory')
    parser.add_argument('--minimum-ios', default='26.0')
    parser.add_argument('--arch', default='arm64')
    parser.add_argument('--sdk', default='iphonesimulator')
    parser.add_argument('--expected-executable-sha256', default=None,
                        help='Executable SHA-256 pinned in engine.lock.json')
    parser.add_argument('--output', default=None, help='Receipt JSON path')
    arguments = parser.parse_args()

    if shutil.which('vtool') is None or shutil.which('lipo') is None:
        parser.error('vtool/lipo are required (install the Xcode tools)')
    if not sys.platform.startswith('darwin'):
        parser.error('the simulator blocker can only be proven on macOS')

    receipt = probe(arguments.framework,
                    minimum_os=arguments.minimum_ios,
                    arch=arguments.arch,
                    expected_executable_sha256=arguments.expected_executable_sha256,
                    sdk=arguments.sdk)
    receipt['probeHost'] = {
        'platform': platform.platform(),
        'machine': platform.machine(),
    }
    if arguments.output:
        output = Path(arguments.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print(json.dumps(receipt, indent=2, sort_keys=True))
    return 0 if receipt.get('simulatorHostBlockerProven') else 1


if __name__ == '__main__':
    sys.exit(main())
