#!/usr/bin/env python3
"""Run only behind select_test_simulator.py --canonical --with-lock. Never create/reset devices."""
import argparse, json, os, pathlib, re, subprocess, sys

repo = pathlib.Path(__file__).resolve().parents[4]
qualification = pathlib.Path(__file__).resolve().parent
udid = os.environ.get('FLOE_SIMULATOR_UDID')
parser=argparse.ArgumentParser()
parser.add_argument('--result-name',default='ipad-ui-first')
parser.add_argument('--only-test',choices=['native-drawing','native-compute'])
args=parser.parse_args()
if not re.fullmatch('[A-Za-z0-9_-]+',args.result_name): raise SystemExit('Invalid evidence name.')
if not udid: raise SystemExit('Use the repository canonical simulator lock wrapper.')
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
inventory = json.loads(subprocess.check_output(['xcrun','simctl','list','devices','-j'],env=env))
device = next((d for ds in inventory['devices'].values() for d in ds if d['udid']==udid),None)
if not device or not device.get('isAvailable'): raise SystemExit('Pinned simulator is unavailable.')
if device['state']!='Shutdown': raise SystemExit('Pinned simulator is already running; preserve its current owner and state.')
result = repo/('Local/Artifacts/chemistry-predevelopment-20261106/'+args.result_name+'.xcresult')
if result.exists(): raise SystemExit('Preserve the existing result; select a new explicit evidence path for a changed run.')
result.parent.mkdir(parents=True,exist_ok=True)
command = ['xcodebuild','-project',str(qualification/'FloeChemistryQualification.xcodeproj'),
           '-scheme','ChemistryQualificationUI','-destination','platform=iOS Simulator,id='+udid,
           '-derivedDataPath',str(pathlib.Path.home()/'Library/Caches/CodexBuild/FloeChemistry/main/Xcode27.2/qualification'),
           '-jobs','6','-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1',
           '-resultBundlePath',str(result),'test','CODE_SIGNING_ALLOWED=NO']
if args.only_test:
    method = 'testNativeDrawingAndReopen' if args.only_test=='native-drawing' else 'testNativeProjectComputeAndReopen'
    command.append('-only-testing:ChemistryHostUITests/ChemistryHostUITests/'+method)
try:
    status = subprocess.run(command,env=env).returncode
finally:
    # This task observed Shutdown under the exclusive lock and owns this run only.
    subprocess.run(['xcrun','simctl','shutdown',udid],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
raise SystemExit(status)
