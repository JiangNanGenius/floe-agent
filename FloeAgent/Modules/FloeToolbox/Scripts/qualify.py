#!/usr/bin/env python3
"""Focused module qualification. Run from the Floe repository; no App/signing changes."""
import argparse, hashlib, json, os, subprocess, sys, time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('mode',choices=['test','ios']);p.add_argument('--output',required=True,type=Path);p.add_argument('--scratch',required=True,type=Path);p.add_argument('--inside-native-window',action='store_true');p.add_argument('--filter');a=p.parse_args()
module=Path(__file__).resolve().parents[1];repo=module.parents[2];a.output=a.output.resolve();a.scratch=a.scratch.resolve();a.output.mkdir(parents=True,exist_ok=True)
if not a.inside_native_window:
 wrapper=repo/'Local/Private/shared-native-window/with_native_window.py'
 if not wrapper.exists():raise SystemExit('Missing shared native-build lock; use the project qualification entry point.')
 raise SystemExit(subprocess.call([sys.executable,str(wrapper),'--label','toolbox-r4-'+a.mode,'--',sys.executable,str(Path(__file__).resolve()),*sys.argv[1:],'--inside-native-window'],cwd=repo))
def hashes():
 paths=[module/'Package.swift']
 for folder in ['Sources','Tests','Integration']:
  paths+=sorted(f for f in (module/folder).rglob('*') if f.is_file())
 return {str(f.relative_to(module)):hashlib.sha256(f.read_bytes()).hexdigest() for f in paths}
record={'started':time.time(),'baseSource':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),'inputs':hashes(),'commands':[],'kind':a.mode,'limitations':['Component evidence only; not full App or hardware acceptance.']}
env=dict(os.environ);developer=env.get('DEVELOPER_DIR')
if not developer:raise SystemExit('Set DEVELOPER_DIR to the currently verified Xcode.')
record['toolchain']=subprocess.check_output(['xcodebuild','-version'],env=env,text=True).strip();a.scratch.mkdir(parents=True,exist_ok=True)
def run(command,name):
 log=a.output/(name+'.log')
 with log.open('w') as f:r=subprocess.run(list(map(str,command)),cwd=repo,env=env,stdout=f,stderr=subprocess.STDOUT)
 record['commands'].append({'argv':list(map(str,command)),'exit':r.returncode,'log':log.name})
 if r.returncode:raise RuntimeError(name+' failed; see '+str(log))
try:
 if a.mode=='test':run(['swift','test','--package-path',module,'--scratch-path',a.scratch,'--jobs','6']+(['--filter',a.filter] if a.filter else []),'tests')
 else:
  sdk=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],env=env,text=True).strip();record['sdk']=sdk
  out=a.scratch/'Objects';out.mkdir(exist_ok=True);wire=module/'Sources/FloeToolboxUSBWire'
  run(['xcrun','--sdk','iphoneos','clang','-target','arm64-apple-ios26.0','-isysroot',sdk,'-Wall','-Wextra','-Werror','-I',wire/'include','-c',wire/'FloeUSBWire.c','-o',out/'FloeToolboxUSBWire.o'],'USBWire-ios26')
  mm=out/'FloeToolboxUSBWire.modulemap';mm.write_text('module FloeToolboxUSBWire { header "'+str(wire/'include/FloeUSBWire.h')+'" export * }\n')
  for name in ['Core','RemoteFiles','UI','Clients','Utilities','Diagnostics','USB','FileTransports','Workbenches']:
   target='FloeToolbox'+name
   command=['xcrun','--sdk','iphoneos','swiftc','-swift-version','6','-parse-as-library','-whole-module-optimization','-emit-module','-emit-object','-sdk',sdk,'-target','arm64-apple-ios26.0','-module-cache-path',a.scratch/'ModuleCache','-I',out,'-Xcc','-fmodule-map-file='+str(mm),'-module-name',target,'-emit-module-path',out/(target+'.swiftmodule'),'-o',out/(target+'.o')]
   command+=sorted((module/'Sources'/target).glob('*.swift'));run(command,target+'-ios26')
  record['objects']={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(out.glob('*.o'))}
 record['inputsUnchanged']=record['inputs']==hashes()
 if not record['inputsUnchanged']:raise RuntimeError('Source changed during qualification; result is not a frozen-source acceptance.')
 record['passed']=True
except Exception as error:record['passed']=False;record['error']=str(error)
record['finished']=time.time();(a.output/'qualification.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({k:record[k] for k in ['passed','kind','error'] if k in record}));raise SystemExit(0 if record['passed'] else 1)
