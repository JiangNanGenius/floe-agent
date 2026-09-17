#!/usr/bin/env python3
"""Select a deterministic available simulator on the requested SDK major.

Selection order for one request:
1. An available device with the exact requested name on a runtime whose iOS
   major equals --sdk-major (the original, strict behavior).
2. With --family, any available device whose name starts with the family
   prefix (e.g. "iPhone") on a runtime of the same iOS major. Runner images
   change which device models a runtime ships (this is why a previously
   present "iPhone 17 Pro" can disappear between runs of the same SDK), so
   the family fallback keeps the iPhone leg running on an installed iOS 27
   iPhone instead of failing the whole phase.
3. With --create and still nothing, create one task-specific device of an
   exactly available device type on the newest available runtime of the
   requested iOS major, strictly matching both the runtime major and the
   device product family, and return its UDID.

Runtimes of any other SDK major and unavailable devices are never selected
and never used for creation.
"""
import argparse
import json
import re
import subprocess
import sys


def runtime_ios_version(runtime):
    match = re.search(r'\.iOS-(\d+(?:-\d+)*)$', runtime)
    if not match:
        return None
    return tuple(map(int, match[1].split('-')))


def matching_runtimes(inventory, sdk_major):
    runtimes = []
    for runtime, devices in inventory.get('devices', {}).items():
        version = runtime_ios_version(runtime)
        if version is None or version[0] != sdk_major:
            continue
        runtimes.append((version, devices))
    return runtimes


def belongs_to_family(device, family):
    if family is None:
        return True
    device_type = device.get('deviceTypeIdentifier')
    if device_type:
        return device_type.rsplit('.', 1)[-1].startswith(family + '-')
    return device.get('name', '').startswith(family + ' ')


def device_candidates(devices, family):
    candidates = []
    for device in devices:
        if not device.get('isAvailable', True):
            continue
        if not belongs_to_family(device, family):
            continue
        candidates.append((device.get('state') == 'Booted', device['udid']))
    return candidates


def select_device(inventory, sdk_major, name, family=None):
    """Return a UDID from the given `simctl list devices -j` inventory."""
    candidates = []
    for version, devices in matching_runtimes(inventory, sdk_major):
        for device in devices:
            # A renamed device must still belong to the requested family.
            if (device.get('name') != name or not device.get('isAvailable', True)
                    or not belongs_to_family(device, family)):
                continue
            candidates.append((version, device.get('state') == 'Booted', device['udid']))
    if not candidates and family is not None:
        for version, devices in matching_runtimes(inventory, sdk_major):
            for booted, udid in device_candidates(devices, family):
                candidates.append((version, booted, udid))
    if not candidates:
        if family:
            raise ValueError(
                f'No available {name} or other {family} simulator for iOS {sdk_major}')
        raise ValueError(f'No available {name} simulator for iOS {sdk_major}')
    return max(candidates)[2]


def _simctl_json(arguments, runner):
    code, stdout = runner(['xcrun', 'simctl'] + arguments)
    if code != 0:
        raise ValueError(f'simctl {" ".join(arguments)} failed with exit code {code}')
    return json.loads(stdout)


def create_family_device(name, sdk_major, family, runner=None):
    """Create a task-specific device of an available type on the requested SDK major.

    Strictly matches both the runtime iOS major and the device product
    family. The exact requested device type is preferred; otherwise the
    remaining family types are tried in deterministic order. Returns the new UDID.
    """
    if runner is None:
        def runner(command):
            result = subprocess.run(command, capture_output=True, text=True)
            return result.returncode, result.stdout

    runtime_list = _simctl_json(['list', 'runtimes', '-j'], runner)
    runtimes = []
    for runtime in runtime_list.get('runtimes', []):
        if not runtime.get('isAvailable', True):
            continue
        version = runtime_ios_version(runtime.get('identifier', ''))
        if version is None or version[0] != sdk_major:
            continue
        runtimes.append((version, runtime['identifier']))
    if not runtimes:
        raise ValueError(f'No available iOS {sdk_major} runtime to create a simulator on')
    runtime_identifier = max(runtimes)[1]

    type_list = _simctl_json(['list', 'devicetypes', '-j'], runner)
    types = []
    for device_type in type_list.get('devicetypes', []):
        if device_type.get('productFamily') != family:
            continue
        types.append((device_type.get('name') == name,
                      device_type.get('name', ''), device_type['identifier']))
    if not types:
        raise ValueError(f'No available {family} simulator device type to create')
    # Exact requested type first, then deterministic name order.
    types.sort(key=lambda item: (item[0], item[1]), reverse=True)

    errors = []
    for _, type_name, type_identifier in types:
        code, stdout = runner(['xcrun', 'simctl', 'create', f'{type_name} Floe CI',
                               type_identifier, runtime_identifier])
        udid = stdout.strip()
        if code == 0 and udid:
            return udid
        errors.append(f'{type_name}: exit {code}')
    raise ValueError(
        f'Could not create an iOS {sdk_major} {family} simulator on '
        f'{runtime_identifier} ({"; ".join(errors)})')


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--sdk-major', type=int, required=True)
    parser.add_argument('--name', required=True)
    parser.add_argument('--family', default=None,
                        help='Device-name prefix fallback, e.g. iPhone or iPad')
    parser.add_argument('--create', action='store_true',
                        help='Create a task-specific device when none is available')
    args = parser.parse_args()
    try:
        inventory = json.load(sys.stdin)
        try:
            udid = select_device(inventory, args.sdk_major, args.name, args.family)
        except ValueError:
            if not args.create:
                raise
            udid = create_family_device(args.name, args.sdk_major, args.family)
        print(udid)
    except ValueError as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
