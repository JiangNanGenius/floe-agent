#!/usr/bin/env python3
"""Check the real checkpoint CLI/tools on a tiny synthetic simulator archive.

Run before the expensive Office core. No Office source is compiled and no
sample checkpoint is uploaded or retained. The receipt is explicitly a tool
preflight, never an engine/App/PPT qualification.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import engine_manifest
from sim_paths import (CORE_CHECKPOINT_JSON, CORE_CHECKPOINT_TAR,
                       EDITOR_CONFIGURE_INPUTS, LOCK_PATH)
from build_simulator_engine import sdk_info, toolchain_info
from stage_simulator_engine import archive_simulator_facts

SCRIPTS = Path(__file__).resolve().parent


def verify(output):
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    sdk = sdk_info()
    tools = toolchain_info()
    lock = json.loads(LOCK_PATH.read_text())
    if not all(sdk.values()) or not tools.get('xcodeVersion'):
        raise RuntimeError('missing actual simulator SDK/toolchain identity')
    with tempfile.TemporaryDirectory(prefix='checkpoint-tool-probe-',
                                     dir=output.parent) as directory:
        root = Path(directory)
        source = root / 'probe.c'
        source.write_text('void floe_checkpoint_probe(void) {}\n')
        obj = root / 'probe.o'
        archive = root / 'libprobe.a'
        subprocess.run(['xcrun', '--sdk', 'iphonesimulator', 'clang',
                        '-target', 'arm64-apple-ios26.0-simulator',
                        '-isysroot', sdk['sdkPath'], '-c', str(source),
                        '-o', str(obj)], check=True)
        subprocess.run(['ar', 'rcs', str(archive), str(obj)], check=True)
        passed, facts = archive_simulator_facts(archive)
        if not passed:
            raise RuntimeError(f'synthetic simulator archive rejected: {facts}')
        # Negative gate: changing the target to iPhoneOS must still fail.
        device_obj = root / 'device.o'
        device_archive = root / 'libdevice.a'
        subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-ios26.0',
                        '-isysroot', sdk['sdkPath'], '-c', str(source),
                        '-o', str(device_obj)], check=True)
        subprocess.run(['ar', 'rcs', str(device_archive), str(device_obj)], check=True)
        device_passed, device_facts = archive_simulator_facts(device_archive)
        if device_passed:
            raise RuntimeError('iPhoneOS archive wrongly accepted as simulator')

        build = root / 'build'
        for name in EDITOR_CONFIGURE_INPUTS:
            target = build / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.suffix == '.a':
                shutil.copyfile(archive, target)
            else:
                target.write_text('synthetic tool preflight input\n')
        manifest = build / engine_manifest.ENGINE_LIST_RELATIVE
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text('\n'.join(str(build / name)
                                     for name in EDITOR_CONFIGURE_INPUTS
                                     if name.endswith('.a')) + '\n')
        (build / 'qualification.json').write_text(json.dumps({
            'commit': lock['commit'], 'platform': 'iphonesimulator-arm64',
            **sdk, **tools, 'syntheticToolProbe': True,
            'engineBuildCompleted': True, 'nativeBuildPassed': False,
            'phases': {'engine-configure': {'seconds': 0.01},
                       'engine-build': {'seconds': 0.01}},
        }))
        checkpoint = root / 'checkpoint'
        created = subprocess.run([
            sys.executable, str(SCRIPTS / 'checkpoint_simulator_core.py'),
            str(build), '--output-dir', str(checkpoint)],
            check=True, capture_output=True, text=True)
        created_record = json.loads(created.stdout)
        destination = root / 'destination'
        (destination / 'source/engine').mkdir(parents=True)
        (destination / 'source/engine/configure.ac').write_text('synthetic\n')
        restored = subprocess.run([
            sys.executable, str(SCRIPTS / 'resume_simulator_core.py'),
            str(checkpoint / CORE_CHECKPOINT_TAR),
            str(checkpoint / CORE_CHECKPOINT_JSON), str(destination),
            '--expect-xcode', tools['xcodeVersion'],
            '--expect-sdk', sdk['sdkVersion'],
            '--expect-sdk-build', sdk['sdkBuildVersion']],
            check=True, capture_output=True, text=True)
        restored_record = json.loads(restored.stdout)
        if not (created_record['allSampledObjectsIOSSIMULATOR']
                and restored_record['coreManifestVerified']
                and restored_record['allSampledObjectsIOSSIMULATOR']):
            raise RuntimeError('actual checkpoint CLI round trip was not verified')
    receipt = {'kind': 'synthetic-checkpoint-tool-preflight',
               'passed': True, 'actualCLIAndTools': True,
               'simulatorArchiveFacts': facts,
               'deviceArchiveRejected': not device_passed,
               'deviceArchiveRejection': device_facts,
               **sdk, **tools, 'nativeBuildPassed': False,
               'finalQualification': False,
               'note': 'Tiny synthetic C archive only. No Office core, Floe App '
                       'or PPT execution; sample checkpoints deleted.'}
    output.write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.output), indent=2), flush=True)
