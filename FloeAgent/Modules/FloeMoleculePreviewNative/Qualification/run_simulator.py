#!/usr/bin/env python3
"""Run only under the repository's canonical --with-lock wrapper."""
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[3]
BUNDLE = 'com.floe.qualification.native-molecule-preview'
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=pathlib.Path, required=True)
    parser.add_argument('--derived-data', type=pathlib.Path, required=True)
    parser.add_argument('--only-testing', action='append', default=[])
    args = parser.parse_args()
    udid = os.environ.get('FLOE_SIMULATOR_UDID')
    if not udid:
        raise SystemExit('Use select_test_simulator.py --canonical --with-lock; no device is selected here.')
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)

    def output(command):
        return subprocess.check_output(command, env=env, text=True).strip()

    inventory = json.loads(output(['xcrun', 'simctl', 'list', 'devices', '-j']))
    device = next(d for group in inventory['devices'].values() for d in group if d['udid'] == udid)
    started = device['state'] == 'Shutdown'
    result = {'device': device, 'taskStartedDevice': started, 'time': time.time()}
    (evidence/'BEFORE.json').write_text(json.dumps(result, indent=2)+'\n')
    code = 1
    try:
        if started:
            subprocess.run(['xcrun', 'simctl', 'boot', udid], env=env, check=True)
        subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], env=env, check=True)
        command = ['xcodebuild', '-project', str(HERE/'FloeNativeMoleculePreview.xcodeproj'),
                   '-scheme', 'NativeMoleculePreview', '-destination', 'id='+udid,
                   '-derivedDataPath', str(args.derived_data.resolve()), '-jobs', '6',
                   '-parallel-testing-enabled', 'NO', '-maximum-concurrent-test-simulator-destinations', '1',
                   '-resultBundlePath', str(evidence/'result.xcresult'), 'CODE_SIGNING_ALLOWED=NO',
                   'test-without-building']
        command += ['-only-testing:'+item for item in args.only_testing]
        (evidence/'COMMAND.json').write_text(json.dumps(command, indent=2)+'\n')
        with (evidence/'test.log').open('wb') as log:
            code = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
        result['testExitCode'] = code
        if (evidence/'result.xcresult').exists():
            subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(evidence/'result.xcresult'),
                            '--output-path', str(evidence/'screenshots')], env=env, check=True)
        try:
            container = pathlib.Path(output(['xcrun', 'simctl', 'get_app_container', udid, BUNDLE, 'data']))
            owned = container/'Library/Application Support/NativeMoleculePreview'
            if owned.is_dir(): shutil.copytree(owned, evidence/'native-store')
        except subprocess.CalledProcessError:
            result['storeExport'] = 'Host container unavailable after test failure'
    finally:
        if started:
            subprocess.run(['xcrun', 'simctl', 'terminate', udid, BUNDLE], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(['xcrun', 'simctl', 'shutdown', udid], env=env, check=True)
        result['afterBooted'] = output(['xcrun', 'simctl', 'list', 'devices', 'booted'])
        result['elapsedSeconds'] = time.time()-result['time']
        (evidence/'RESULT.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({'exitCode':code, 'evidence':str(evidence), 'taskStartedDevice':started}))
    return code


if __name__ == '__main__':
    sys.exit(main())
