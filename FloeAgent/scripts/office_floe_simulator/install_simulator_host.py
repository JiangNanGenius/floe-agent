#!/usr/bin/env python3
"""Install a verified simulator Office host into the Floe app build tree.

The zip produced by ``build_simulator_framework`` is extracted into a fresh
directory under ``Vendor/Office/`` and verified end-to-end by
``bootstrap_office_host.verify_simulator_host`` (source commit, overlay SHAs,
staged-engine provenance, toolchain identity, per-file hashes). Only then is
the generated ``Vendor/Office/native-host.xcconfig`` rewritten with the
simulator framework search path and link flag.

The existing device ``FLOE_OFFICE_HOST_DIR`` line is preserved verbatim when
present (the device pin and the device host are never touched by this flow).

Normal simulator builds are untouched: with no verified artifact installed the
xcconfig carries no simulator Office lines, ``canImport(FloeOfficeNative)``
stays false and every Office surface keeps its honest no-engine state.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile
import zipfile

THIS_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = THIS_DIR.parent
REPO_ROOT = SCRIPTS_DIR.parent.parent
sys.path.insert(0, str(THIS_DIR))
sys.path.insert(0, str(SCRIPTS_DIR))

from bootstrap_office_host import LOCK, verify_simulator_host, SIMULATOR_RECEIPT  # noqa: E402
from sim_host_paths import HOST_BUNDLE_NAME  # noqa: E402

DEVICE_LINE = re.compile(r'^FLOE_OFFICE_HOST_DIR\s*=\s*(.+)$')


class InstallSimulatorHostError(ValueError):
    pass


def rewrite_xcconfig(xcconfig_path, simulator_folder, repo_root=REPO_ROOT):
    """Preserve the device line; write/refresh the simulator lines."""
    xcconfig_path = Path(xcconfig_path)
    device_line = None
    if xcconfig_path.is_file():
        for line in xcconfig_path.read_text().splitlines():
            match = DEVICE_LINE.match(line.strip())
            if match:
                device_line = match.group(1).strip()
                break
    simulator_folder = Path(simulator_folder).resolve()
    relative = simulator_folder.relative_to(Path(repo_root).resolve() / 'FloeAgent')
    name = str(relative)
    if any(char in name for char in '\n\r$#="') or '//' in name:
        raise InstallSimulatorHostError('Office simulator source cannot be represented in an Xcode configuration')
    lines = ['// Generated from the verified native Office qualification pin.']
    if device_line:
        lines.append('FLOE_OFFICE_HOST_DIR = ' + device_line)
    lines.append('FLOE_OFFICE_SIM_HOST_DIR = $(PROJECT_DIR)/' + name)
    lines.append('FLOE_OFFICE_SIM_LDFLAG = -framework FloeOfficeNative')
    xcconfig_path.parent.mkdir(parents=True, exist_ok=True)
    xcconfig_path.write_text('\n'.join(lines) + '\n')


def install(zip_path, repo_root=REPO_ROOT, *, set_xcconfig=True):
    repo_root = Path(repo_root).resolve()
    with tempfile.TemporaryDirectory(prefix='floe-sim-host-') as temporary:
        stage = Path(temporary)
        with zipfile.ZipFile(zip_path) as archive:
            names = archive.namelist()
            if not names or any(Path(name).parts[0] != HOST_BUNDLE_NAME for name in names):
                raise InstallSimulatorHostError(
                    'simulator host archive must extract one owned bundle root')
            archive.extractall(stage)
        bundle = stage / HOST_BUNDLE_NAME
        receipt = json.loads((bundle / SIMULATOR_RECEIPT).read_text())
        key = f"simulator-{receipt['stagedEngine']['runID']}-{receipt['variant']}"
        destination = repo_root / 'FloeAgent' / 'Vendor' / 'Office' / key / HOST_BUNDLE_NAME
        if destination.exists() or destination.is_symlink():
            raise InstallSimulatorHostError(f'destination already exists: {destination}')
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(bundle), str(destination))
        facts = verify_simulator_host(destination, LOCK)
        if set_xcconfig:
            rewrite_xcconfig(
                repo_root / 'FloeAgent' / 'Vendor' / 'Office' / 'native-host.xcconfig',
                destination, repo_root=repo_root)
        facts['installedAt'] = str(destination)
        facts['installKey'] = key
        return facts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zip', type=Path, required=True,
                        help='OfficeNativeHostSimulator.zip from build_simulator_framework')
    parser.add_argument('--repo-root', type=Path, default=REPO_ROOT)
    parser.add_argument('--no-xcconfig', action='store_true',
                        help='Only extract+verify; do not touch native-host.xcconfig')
    args = parser.parse_args()
    facts = install(args.zip, args.repo_root, set_xcconfig=not args.no_xcconfig)
    print(json.dumps(facts, indent=2))


if __name__ == '__main__':
    main()
