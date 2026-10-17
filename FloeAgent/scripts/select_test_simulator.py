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

Canonical single-device mode (local hosts only): --canonical resolves the ONE
existing project device pinned in the host-local private config and NEVER
creates, clones, erases or falls back to another device; a missing or
unavailable pinned device is an actionable error. --with-lock first validates
the pinned device against the live (read-only) simctl inventory, then holds
an exclusive flock and only then runs the wrapped command with
FLOE_SIMULATOR_UDID exported; the child never starts for a missing or
unavailable device. While the policy config exists on the host, the legacy
--create escape hatch also fails closed with an actionable error. Generic
simulator builds and CI ephemeral runners (which have no private config) are
unaffected.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

CANONICAL_POLICY = 'single-existing-device'
CANONICAL_CONFIG_ENV = 'FLOE_SIMULATOR_CONFIG'
DEFAULT_CANONICAL_CONFIG = (
    Path(__file__).resolve().parents[2]
    / 'Local' / 'Private' / 'simulator-single-device-20261018' / 'device.json')


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


def canonical_config_path(cli_value=None):
    """CLI flag > FLOE_SIMULATOR_CONFIG > repo-local private default."""
    if cli_value:
        return Path(cli_value)
    env_value = os.environ.get(CANONICAL_CONFIG_ENV)
    if env_value:
        return Path(env_value)
    return DEFAULT_CANONICAL_CONFIG


def _parse_canonical_config(path):
    """Return (config_dict_or_None, error_message_or_None). Never crashes."""
    path = Path(path)
    if not path.is_file():
        return None, None
    try:
        config = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        return None, f'Single-simulator config {path} is unreadable: {error}'
    if not isinstance(config, dict):
        return None, f'Single-simulator config {path} must contain one JSON object'
    return config, None


def legacy_create_blocker():
    """Actionable error when the local policy pins one device and --create is used.

    A missing config (ephemeral CI runner) is inert; a present-but-corrupt one
    fails closed.
    """
    path = canonical_config_path(None)
    if not path.is_file():
        return None
    config, error = _parse_canonical_config(path)
    if error:
        return (f'{error}; --create fails closed on this host because the '
                'policy file is present but unusable. Repair or remove the '
                'config deliberately; nothing is created.')
    if config.get('policy') != CANONICAL_POLICY:
        return None
    return (
        f'the local single-simulator policy pins device '
        f'{config.get("deviceUDID", "?")} ("{config.get("deviceName", "?")}"): '
        '--create is disabled on this host. Reuse the canonical device via '
        '--canonical [--with-lock ...]; creating an additional simulator '
        'requires an explicit user-approved exception.')


def load_canonical_config(path):
    path = Path(path)
    if not path.is_file():
        raise ValueError(
            f'No single-simulator config at {path}. Create it as a Git-ignored, '
            f'host-private file ({{"policy": "{CANONICAL_POLICY}", "deviceUDID": '
            f'"...", "deviceName": "...", "sdkMajor": N, "family": "iPad"}}) '
            f'pointing at ONE existing simulator; nothing is created automatically.')
    config, error = _parse_canonical_config(path)
    if error:
        raise ValueError(error)
    if config.get('policy') != CANONICAL_POLICY:
        raise ValueError(
            f'Single-simulator config {path} has policy '
            f'{config.get("policy")!r}, expected {CANONICAL_POLICY!r}')
    for key in ('deviceUDID', 'sdkMajor'):
        if not config.get(key):
            raise ValueError(f'Single-simulator config {path} is missing {key}')
    return config


def resolve_canonical_device(config, inventory):
    """Return the pinned UDID after validating it exists in the live inventory.

    Never creates, clones, boots, erases or substitutes another device; a
    missing, deleted or unavailable pinned device is an actionable error.
    """
    udid = str(config['deviceUDID']).upper()
    sdk_major = int(config['sdkMajor'])
    matches = []
    for runtime, devices in inventory.get('devices', {}).items():
        version = runtime_ios_version(runtime)
        if version is None or version[0] != sdk_major:
            continue
        for device in devices:
            if str(device.get('udid', '')).upper() == udid:
                matches.append((runtime, device))
    if not matches:
        raise ValueError(
            f'Canonical Floe simulator {udid} is not present on an iOS {sdk_major} '
            'runtime in this host inventory. Do not create or clone a substitute: '
            'point the single-simulator config at the restored device or restore '
            'the device, then retry.')
    runtime, device = matches[0]
    if device.get('isDeleted') or not device.get('isAvailable', True):
        raise ValueError(
            f'Canonical Floe simulator {udid} is unavailable (marked deleted or '
            f'its runtime {runtime} is missing). Restore availability first; '
            'nothing is created automatically.')
    expected_type = config.get('deviceType')
    actual_type = device.get('deviceTypeIdentifier')
    if expected_type and actual_type and expected_type != actual_type:
        raise ValueError(
            f'Canonical Floe simulator {udid} device type changed '
            f'({actual_type!r} != configured {expected_type!r}); re-check the '
            'single-simulator config before using it.')
    return device['udid']


def acquire_device_lock(config, config_path, *, wait_seconds=0.0):
    """Take the exclusive local lock for the canonical simulator; returns the fd.

    The caller must close the fd to release. flock is per open file
    description, so separate processes contend correctly.
    """
    import fcntl
    raw = config.get('lockPath')
    config_dir = Path(config_path).resolve().parent
    lock_path = Path(raw) if raw else config_dir / 'device.lock'
    if not lock_path.is_absolute():
        lock_path = config_dir / lock_path
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    deadline = time.monotonic() + max(float(wait_seconds), 0.0)
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError:
            if time.monotonic() >= deadline:
                os.close(fd)
                raise ValueError(
                    f'The single-simulator lock {lock_path} is held by another '
                    'Floe task. Local simulator runs are serialized: wait and '
                    'retry, or raise --lock-wait if the holder is legitimately long.')
            time.sleep(0.5)


def _subprocess_runner(command):
    result = subprocess.run(command, capture_output=True, text=True)
    return result.returncode, result.stdout


def main(argv=None, runner=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--sdk-major', type=int)
    parser.add_argument('--name')
    parser.add_argument('--family', default=None,
                        help='Device-name prefix fallback, e.g. iPhone or iPad')
    parser.add_argument('--create', action='store_true',
                        help='Create a task-specific device when none is '
                             'available (disabled on hosts with the local '
                             'single-simulator policy)')
    parser.add_argument('--canonical', action='store_true',
                        help='Resolve the ONE pinned local device; never creates')
    parser.add_argument('--config', default=None,
                        help='Single-simulator config path (default: $'
                             + CANONICAL_CONFIG_ENV + ' or the repo private path)')
    parser.add_argument('--with-lock', nargs=argparse.REMAINDER, metavar='COMMAND',
                        help='Canonical mode: validate the pinned device against '
                             'the live inventory, hold the exclusive device lock '
                             'and exec COMMAND with FLOE_SIMULATOR_UDID exported')
    parser.add_argument('--lock-wait', type=float, default=0.0,
                        help='Seconds to wait for the device lock (0 = fail fast)')
    args = parser.parse_args(argv)
    if runner is None:
        runner = _subprocess_runner
    try:
        if args.canonical:
            if args.sdk_major is not None or args.name is not None or args.family \
                    or args.create:
                raise ValueError(
                    '--canonical must be used alone; it never creates, substitutes '
                    'or falls back by name/family')
            config_path = canonical_config_path(args.config)
            config = load_canonical_config(config_path)
            if args.with_lock:
                command = list(args.with_lock)
                if command[:1] == ['--']:
                    command = command[1:]
                if not command:
                    raise ValueError('--with-lock needs the command to wrap')
                # Fail closed BEFORE the child runs: the pinned device must be
                # present and available in the read-only live inventory. This
                # never boots, creates, clones or substitutes a device.
                inventory = _simctl_json(['list', 'devices', '-j'], runner)
                udid = resolve_canonical_device(config, inventory)
                fd = acquire_device_lock(config, config_path,
                                         wait_seconds=args.lock_wait)
                try:
                    child = subprocess.run(
                        command,
                        env={**os.environ, 'FLOE_SIMULATOR_UDID': udid})
                    return child.returncode
                finally:
                    os.close(fd)
            inventory = json.load(sys.stdin)
            print(resolve_canonical_device(config, inventory))
            return 0
        if args.sdk_major is None or args.name is None:
            parser.error('--sdk-major and --name are required unless --canonical is used')
        if args.create:
            blocker = legacy_create_blocker()
            if blocker:
                raise ValueError(blocker)
        inventory = json.load(sys.stdin)
        try:
            udid = select_device(inventory, args.sdk_major, args.name, args.family)
        except ValueError:
            if not args.create:
                raise
            udid = create_family_device(args.name, args.sdk_major, args.family,
                                        runner=runner)
        print(udid)
        return 0
    except ValueError as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    raise SystemExit(main())
