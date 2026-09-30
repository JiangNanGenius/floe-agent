#!/usr/bin/env python3
"""Provision a unique, task-owned iPad simulator for one qualification run.

The matrix variants (and repeated runs) must never share a simulator: sharing
one let concurrent/repeated runs shut each other down and overwrite each
other's app container, so a remembered edit could be falsely reused. This
creates a FRESH device with a unique, recognisably owned name on the newest
available runtime of the requested iOS major, boots it and prints its UDID.

Only the created device is ever shut down or deleted (see
``release_owned_simulator.py``); existing user/test simulators are never
listed for reuse and never touched.
"""
import argparse
import json
import re
import subprocess
import sys
import uuid

OWNED_NAME_PREFIX = 'Floe Office Real SIM'


class SimulatorProvisionError(ValueError):
    pass


def _run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise SimulatorProvisionError(
            f'{" ".join(command)} failed ({result.returncode}): '
            f'{result.stderr.strip()[:400]}')
    return result.stdout


def runtime_ios_version(runtime):
    match = re.search(r'\.iOS-(\d+(?:-\d+)*)$', runtime)
    if not match:
        return None
    return tuple(map(int, match[1].split('-')))


def newest_runtime(inventory, sdk_major):
    runtimes = []
    for runtime in inventory.get('runtimes', []):
        if not runtime.get('isAvailable', True):
            continue
        version = runtime_ios_version(runtime.get('identifier', ''))
        if version is None or version[0] != sdk_major:
            continue
        runtimes.append((version, runtime['identifier']))
    if not runtimes:
        raise SimulatorProvisionError(
            f'no available iOS {sdk_major} runtime to create the owned simulator on')
    return max(runtimes)[1]


def newest_ipad_device_type(inventory):
    types = [(entry.get('name', ''), entry['identifier'])
             for entry in inventory.get('devicetypes', [])
             if entry.get('productFamily') == 'iPad'
             and entry.get('identifier')]
    if not types:
        raise SimulatorProvisionError('no available iPad device type')
    # Prefer the largest Pro model, deterministically.
    types.sort(key=lambda item: ('Pro' in item[0], item[0]), reverse=True)
    return types[0][1]


def owned_name(run_id, variant):
    return f'{OWNED_NAME_PREFIX} {run_id} {variant} {uuid.uuid4().hex[:8]}'


def is_owned_name(name):
    return isinstance(name, str) and name.startswith(OWNED_NAME_PREFIX + ' ')


def provision(sdk_major, run_id, variant):
    runtimes = json.loads(_run(['xcrun', 'simctl', 'list', 'runtimes', '-j']))
    runtime_identifier = newest_runtime(runtimes, sdk_major)
    device_types = json.loads(_run(['xcrun', 'simctl', 'list', 'devicetypes', '-j']))
    device_type = newest_ipad_device_type(device_types)
    name = owned_name(run_id, variant)
    udid = _run(['xcrun', 'simctl', 'create', name, device_type,
                runtime_identifier]).strip()
    if not udid:
        raise SimulatorProvisionError('simctl create returned no UDID')
    _run(['xcrun', 'simctl', 'boot', udid])
    boot = subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'],
                          capture_output=True, text=True)
    if boot.returncode != 0:
        # Never leave a half-booted owned device behind on failure.
        subprocess.run(['xcrun', 'simctl', 'shutdown', udid], capture_output=True)
        subprocess.run(['xcrun', 'simctl', 'delete', udid], capture_output=True)
        raise SimulatorProvisionError(f'bootstatus failed: {boot.stderr.strip()[:400]}')
    devices = json.loads(_run(['xcrun', 'simctl', 'list', 'devices', '-j']))
    recorded_name = None
    for runtime_devices in devices.get('devices', {}).values():
        for device in runtime_devices:
            if device.get('udid') == udid:
                recorded_name = device.get('name')
    if recorded_name != name:
        raise SimulatorProvisionError(
            f'created device name mismatch: {recorded_name!r} != {name!r}')
    return {'udid': udid, 'name': name, 'runtime': runtime_identifier,
            'deviceType': device_type, 'sdkMajor': sdk_major,
            'runID': str(run_id), 'variant': variant, 'owned': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-major', type=int, default=27)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--variant', required=True)
    parser.add_argument('--output', default=None,
                        help='Write the provisioning receipt JSON here')
    args = parser.parse_args()
    try:
        receipt = provision(args.sdk_major, args.run_id, args.variant)
    except SimulatorProvisionError as error:
        print(f'OWNED SIMULATOR PROVISION FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
    if args.output:
        from pathlib import Path
        Path(args.output).write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
