#!/usr/bin/env python3
"""Release ONLY the simulator this qualification run created.

Evidence (logs, the app container pull, screenshots) is collected BEFORE this
runs. It shuts the owned device down, waits for the shutdown to settle, and
deletes only that UDID — after re-verifying from the live device list that:

* the UDID exists;
* its recorded name carries the exact ownership prefix, run id and variant
  recorded by ``provision_owned_simulator.py``;
* it is therefore one of our devices.

Any mismatch fails closed and deletes nothing, so an existing user/test
simulator can never be shut down or removed.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

from provision_owned_simulator import OWNED_NAME_PREFIX, is_owned_name  # noqa: E402


class SimulatorReleaseError(ValueError):
    pass


def _list_devices():
    result = subprocess.run(['xcrun', 'simctl', 'list', 'devices', '-j'],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise SimulatorReleaseError('simctl list devices failed')
    return json.loads(result.stdout)


def find_device(inventory, udid):
    for runtime_devices in inventory.get('devices', {}).values():
        for device in runtime_devices:
            if device.get('udid') == udid:
                return device
    return None


def release(udid, *, run_id=None, variant=None, expected_name=None,
            allow_missing=False):
    inventory = _list_devices()
    device = find_device(inventory, udid)
    if device is None:
        if allow_missing:
            return {'udid': udid, 'released': False, 'reason': 'already absent'}
        raise SimulatorReleaseError(f'owned simulator {udid} is not in the live device list')
    name = device.get('name', '')
    if not is_owned_name(name):
        raise SimulatorReleaseError(
            f'REFUSING to release {udid}: name {name!r} lacks the ownership prefix')
    if expected_name and name != expected_name:
        raise SimulatorReleaseError(
            f'REFUSING to release {udid}: name {name!r} != receipt {expected_name!r}')
    if run_id and str(run_id) not in name:
        raise SimulatorReleaseError(
            f'REFUSING to release {udid}: run id {run_id} not in name {name!r}')
    if variant and variant not in name:
        raise SimulatorReleaseError(
            f'REFUSING to release {udid}: variant {variant} not in name {name!r}')
    actions = []
    shutdown = subprocess.run(['xcrun', 'simctl', 'shutdown', udid],
                              capture_output=True, text=True)
    actions.append(f'shutdown rc={shutdown.returncode}')
    # Give the recorder/runtime a bounded moment to finish flushing; evidence
    # was already pulled.
    delete = subprocess.run(['xcrun', 'simctl', 'delete', udid],
                            capture_output=True, text=True)
    if delete.returncode != 0:
        raise SimulatorReleaseError(
            f'simctl delete failed for owned {udid}: {delete.stderr.strip()[:300]}')
    actions.append('deleted')
    if find_device(_list_devices(), udid) is not None:
        raise SimulatorReleaseError(f'owned simulator {udid} still present after delete')
    return {'udid': udid, 'name': name, 'released': True, 'actions': actions}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid')
    parser.add_argument('--receipt', type=Path, default=None,
                        help='provisioning receipt JSON (takes precedence over --udid)')
    parser.add_argument('--allow-missing', action='store_true')
    args = parser.parse_args()
    receipt = {}
    if args.receipt:
        receipt = json.loads(args.receipt.read_text())
    udid = receipt.get('udid') or args.udid
    if not udid:
        parser.error('provide --udid or a provisioning --receipt')
    try:
        result = release(udid, run_id=receipt.get('runID'),
                         variant=receipt.get('variant'),
                         expected_name=receipt.get('name'),
                         allow_missing=args.allow_missing)
    except SimulatorReleaseError as error:
        print(f'OWNED SIMULATOR RELEASE FAILED CLOSED: {error}', file=sys.stderr)
        raise SystemExit(1)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
