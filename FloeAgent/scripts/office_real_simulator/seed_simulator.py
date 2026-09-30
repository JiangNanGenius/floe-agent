#!/usr/bin/env python3
"""Install the host app and seed the synthetic PPTX into its container.

The fixture is placed at Documents/TestFiles/<fixture>, exactly where the
upstream document browser and UITests look ("On My iPad" -> app container ->
TestFiles). Seeding happens while the app is not running, so no import or
file-provider dialog is involved: this is a genuine local open in-place, not a
copy-in through another app.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from sim_paths import FIXTURE_BASENAME, HOST_BUNDLE_ID


def run(command, check=True):
    result = subprocess.run([str(item) for item in command], text=True,
                            capture_output=True)
    if check and result.returncode != 0:
        raise RuntimeError(
            f'command failed ({result.returncode}): {command}\n{result.stderr}')
    return result


def seed(simulator, app_path, fixture, expected_sha256=None):
    run(['xcrun', 'simctl', 'install', simulator, app_path])
    container = run(['xcrun', 'simctl', 'get_app_container', simulator,
                     HOST_BUNDLE_ID, 'data']).stdout.strip()
    if not container:
        raise RuntimeError('app container unavailable after install')
    fixture = Path(fixture)
    digest = hashlib.sha256(fixture.read_bytes()).hexdigest()
    if expected_sha256 and digest != expected_sha256:
        raise ValueError(f'fixture sha256 {digest} != expected {expected_sha256}')
    target_dir = Path(container) / 'Documents/TestFiles'
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / FIXTURE_BASENAME
    target.write_bytes(fixture.read_bytes())
    if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
        raise ValueError('seeded fixture failed verification')
    return {
        'simulator': simulator,
        'appInstalled': str(app_path),
        'bundleID': HOST_BUNDLE_ID,
        'container': container,
        'seededPath': str(target),
        'fixtureSHA256': digest,
        'seeded': True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('simulator')
    parser.add_argument('app_path')
    parser.add_argument('fixture')
    parser.add_argument('--expected-sha256', default=None)
    parser.add_argument('--output', default=None)
    args = parser.parse_args()
    receipt = seed(args.simulator, args.app_path, args.fixture,
                   args.expected_sha256)
    if args.output:
        Path(args.output).write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
