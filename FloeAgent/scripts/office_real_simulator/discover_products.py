#!/usr/bin/env python3
"""Discover the built host app, xctestrun and UI-test runner by exact identity.

``xcodebuild build-for-testing`` puts products under
``Build/Products/<Configuration>-<sdk>/`` (for example
``Debug-iphonesimulator/Mobile.app``), not directly under ``Build/Products``.
The old workflow searched with ``find -maxdepth 1`` and never found the app.

This module resolves the products from the ``*.xctestrun`` file the build
produced and verifies them against the exact host bundle identifier:

* parse the xctestrun plist (``TestHostPath`` / ``UITargetAppPath`` with the
  ``__TESTROOT__`` / ``__TESTHOST__`` macros substituted);
* read each candidate ``Mobile.app`` Info.plist and require the exact expected
  ``CFBundleIdentifier`` -- a mismatched product fails, it is never silently
  replaced by whatever app happens to be present;
* verify the xctestrun's app-under-test path points at that same app, and read
  the runner app bundle identifier (needed to retrieve the UITest runner data
  container for the phase receipt fallback).
"""
import argparse
import json
from pathlib import Path
import plistlib
import sys

from sim_paths import HOST_BUNDLE_ID


class ProductDiscoveryError(ValueError):
    pass


def _read_plist(path):
    with Path(path).open('rb') as stream:
        return plistlib.load(stream)


def bundle_identifier(app_path):
    info = Path(app_path) / 'Info.plist'
    if not info.is_file():
        return None
    try:
        return _read_plist(info).get('CFBundleIdentifier')
    except (plistlib.InvalidFileException, ValueError, OSError):
        return None


def _apps(products_dir):
    candidates = []
    for path in sorted(Path(products_dir).rglob('*.app')):
        if not path.is_dir():
            continue
        # Never descend into a nested app/xctest bundle (PlugIns, Watch, ...).
        if any(parent.suffix in {'.app', '.xctest', '.appex'}
               for parent in path.parents):
            continue
        candidates.append(path)
    return candidates


def find_host_app(products_dir, expected_bundle_id=HOST_BUNDLE_ID):
    apps = _apps(products_dir)
    matches = [path for path in apps if bundle_identifier(path) == expected_bundle_id]
    if len(matches) == 1:
        return matches[0]
    if not matches:
        found = {str(path): bundle_identifier(path) for path in apps}
        raise ProductDiscoveryError(
            f'no built app with bundle id {expected_bundle_id} under '
            f'{products_dir}; found {json.dumps(found)}')
    raise ProductDiscoveryError(
        f'ambiguous host app for {expected_bundle_id}: '
        f'{[str(path) for path in matches]}')


def find_xctestrun(products_dir):
    matches = sorted(Path(products_dir).glob('*.xctestrun'))
    if not matches:
        matches = sorted(Path(products_dir).rglob('*.xctestrun'))
    if not matches:
        raise ProductDiscoveryError(f'no *.xctestrun under {products_dir}')
    if len(matches) > 1:
        raise ProductDiscoveryError(
            f'ambiguous xctestrun files: {[str(path) for path in matches]}')
    return matches[0]


def _substitute(value, test_root):
    if not isinstance(value, str):
        return value
    value = value.replace('__TESTROOT__', str(test_root))
    return value


def _test_configs(xctestrun):
    """Collect every test-target config dict, tolerating nested formats."""
    found = []

    def walk(value):
        if isinstance(value, dict):
            if any(key in value for key in ('TestHostPath', 'TestBundlePath',
                                            'UITargetAppPath')):
                found.append(value)
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(xctestrun)
    return found


def discover(products_dir, expected_bundle_id=HOST_BUNDLE_ID):
    products_dir = Path(products_dir).resolve()
    if not products_dir.is_dir():
        raise ProductDiscoveryError(f'products directory missing: {products_dir}')

    xctestrun_path = find_xctestrun(products_dir)
    try:
        xctestrun = _read_plist(xctestrun_path)
    except (plistlib.InvalidFileException, ValueError, OSError) as error:
        raise ProductDiscoveryError(f'unreadable xctestrun {xctestrun_path}: {error}')

    host_app = find_host_app(products_dir, expected_bundle_id)
    app_id = bundle_identifier(host_app)
    if app_id != expected_bundle_id:
        raise ProductDiscoveryError(
            f'host app {host_app} has bundle id {app_id}, expected '
            f'{expected_bundle_id}')

    configs = _test_configs(xctestrun)
    if not configs:
        raise ProductDiscoveryError(f'xctestrun {xctestrun_path} has no test configs')

    test_host_paths = []
    target_app_paths = []
    runner_bundle_id = None
    for config in configs:
        for key in ('TestHostPath', 'UITargetAppPath'):
            value = _substitute(config.get(key), products_dir)
            if not value:
                continue
            path = Path(value)
            if key == 'TestHostPath' and path.suffix == '.app':
                test_host_paths.append(path)
            if key == 'UITargetAppPath':
                if not path.exists():
                    raise ProductDiscoveryError(
                        f'xctestrun app-under-test path does not exist: {path}')
                target_app_paths.append(path)
        if not runner_bundle_id and config.get('TestHostBundleIdentifier'):
            runner_bundle_id = config['TestHostBundleIdentifier']

    for path in target_app_paths:
        declared_id = bundle_identifier(path)
        if declared_id and declared_id != expected_bundle_id:
            raise ProductDiscoveryError(
                f'xctestrun points at bundle id {declared_id} '
                f'({path}), expected {expected_bundle_id}')
        if path.resolve() != host_app.resolve():
            raise ProductDiscoveryError(
                f'xctestrun app-under-test {path} != discovered host {host_app}')

    runner_app = None
    for path in test_host_paths:
        if path.exists() and path.resolve() != host_app.resolve():
            runner_app = path
            break
    if runner_app is None:
        # Fall back to a sibling Runner.app next to the host app.
        sibling = host_app.parent / 'MobileUITests-Runner.app'
        if sibling.is_dir():
            runner_app = sibling
    if runner_app is None:
        raise ProductDiscoveryError(
            f'could not locate the UI-test runner app for {host_app}; '
            f'xctestrun TestHostPath entries: {[str(p) for p in test_host_paths]}')

    runner_id = bundle_identifier(runner_app) or runner_bundle_id
    if not runner_id:
        raise ProductDiscoveryError(f'runner app {runner_app} has no bundle id')

    return {
        'productsDir': str(products_dir),
        'appPath': str(host_app),
        'appBundleIdentifier': app_id,
        'xctestrunPath': str(xctestrun_path),
        'runnerAppPath': str(runner_app),
        'runnerBundleIdentifier': runner_id,
        'testHostBundleIdentifier': runner_bundle_id,
        'discovery': 'xctestrun+exact-bundle-id',
    }


def _write_github_output(path, receipt):
    outputs = {
        'app_path': receipt['appPath'],
        'xctestrun_path': receipt['xctestrunPath'],
        'runner_app_path': receipt['runnerAppPath'],
        'runner_bundle_id': receipt['runnerBundleIdentifier'],
    }
    Path(path).write_text(
        '\n'.join(f'{key}={value}' for key, value in outputs.items()) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('products_dir')
    parser.add_argument('--bundle-id', default=HOST_BUNDLE_ID)
    parser.add_argument('--receipt', default=None)
    parser.add_argument('--github-output', default=None)
    args = parser.parse_args()
    try:
        receipt = discover(args.products_dir, args.bundle_id)
    except ProductDiscoveryError as error:
        print(f'PRODUCT DISCOVERY FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
    if args.receipt:
        Path(args.receipt).write_text(json.dumps(receipt, indent=2) + '\n')
    if args.github_output:
        _write_github_output(args.github_output, receipt)
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
