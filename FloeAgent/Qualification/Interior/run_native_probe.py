#!/usr/bin/env python3
"""Run component checks under the repository's canonical simulator lock."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess


def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, **kwargs)


def state(udid):
    inventory = json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j'],
                               capture_output=True).stdout)
    return next(d for group in inventory['devices'].values() for d in group
                if d['udid'] == udid)


def project_root(udid):
    container = subprocess.run(['xcrun','simctl','get_app_container',udid,
                                'com.floe.qualification.interior-native-host','data'],
                               capture_output=True, text=True)
    if container.returncode != 0:
        return None
    return Path(container.stdout.strip())/'Documents'/'InteriorResearch-20261112'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--derived-data', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    udid = os.environ.get('FLOE_SIMULATOR_UDID')
    if not udid:
        parser.error('Use select_test_simulator.py --canonical --with-lock')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    before = state(udid)
    (output/'device-before.json').write_text(json.dumps(before, indent=2)+'\n')
    started = before['state'] == 'Shutdown'
    test_code = 1
    receipt = {'scope': 'Native component host, not full-App acceptance',
               'simulator': udid, 'startedByTask': started}
    try:
        if started:
            run(['xcrun', 'simctl', 'boot', udid])
        run(['xcrun', 'simctl', 'bootstatus', udid, '-b'])
        previous_root = project_root(udid)
        previous_names = ({p.name for p in previous_root.iterdir() if p.is_dir()}
                          if previous_root and previous_root.exists() else set())
        receipt['existingProjectCount'] = len(previous_names)
        command = [
            'xcodebuild', 'test-without-building', '-project',
            str(Path(__file__).parent/'FloeInteriorQualification.xcodeproj'),
            '-scheme', 'InteriorNativeChecks', '-destination', 'id='+udid,
            '-derivedDataPath', str(args.derived_data.resolve()),
            '-resultBundlePath', str(output/'native.xcresult'),
            '-parallel-testing-enabled', 'NO',
            '-maximum-concurrent-test-simulator-destinations', '1',
            'CODE_SIGNING_ALLOWED=NO',
        ]
        receipt['command'] = command
        with (output/'test.log').open('w') as log:
            test_code = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).returncode
        receipt['testExitCode'] = test_code
        if (output/'native.xcresult').exists():
            with (output/'test-summary.json').open('w') as summary:
                run(['xcrun','xcresulttool','get','test-results','summary',
                     '--path',str(output/'native.xcresult')], stdout=summary)
            run(['xcrun','xcresulttool','export','attachments','--path',
                 str(output/'native.xcresult'),'--output-path',str(output/'attachments')])
        source = project_root(udid)
        if source and source.exists():
            created = [p for p in source.iterdir() if p.is_dir() and p.name not in previous_names]
            for project in created:
                shutil.copytree(project, output/'native-projects'/project.name)
            receipt['nativeProjectsExported'] = bool(created)
            receipt['nativeProjectCountExported'] = len(created)
        return test_code
    finally:
        if started:
            run(['xcrun','simctl','shutdown',udid])
        after = state(udid)
        receipt['finalDeviceState'] = after['state']
        (output/'device-after.json').write_text(json.dumps(after, indent=2)+'\n')
        (output/'run-receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')


if __name__ == '__main__':
    raise SystemExit(main())
