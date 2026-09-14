#!/usr/bin/env python3
"""Select a deterministic available simulator on the requested SDK major."""
import argparse
import json
import re
import sys


def select_device(inventory, sdk_major, name):
    candidates = []
    for runtime, devices in inventory.get('devices', {}).items():
        match = re.search(r'\.iOS-(\d+(?:-\d+)*)$', runtime)
        if not match:
            continue
        version = tuple(map(int, match[1].split('-')))
        if version[0] != sdk_major:
            continue
        for device in devices:
            if device.get('name') == name and device.get('isAvailable', True):
                candidates.append((version, device.get('state') == 'Booted', device['udid']))
    if not candidates:
        raise ValueError(f'No available {name} simulator for iOS {sdk_major}')
    return max(candidates)[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-major', type=int, required=True)
    parser.add_argument('--name', required=True)
    args = parser.parse_args()
    try:
        print(select_device(json.load(sys.stdin), args.sdk_major, args.name))
    except ValueError as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
