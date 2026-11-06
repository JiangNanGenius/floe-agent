#!/usr/bin/env python3
"""Build pinned Avogadro Core/IO/Calc/QuantumIO as a static Apple XCFramework."""
import argparse, datetime, hashlib, json, os, pathlib, subprocess, shutil

module = pathlib.Path(__file__).resolve().parents[1]
repo = module.parents[2]
evidence = repo / 'Local/Private/chemistry-predevelopment-20261106/native'
framework = module / 'Vendor/FloeChemistryBridge.xcframework'
parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
parser.add_argument('--targets', nargs='+', default=['macos', 'ios', 'simulator'], choices=['macos', 'ios', 'simulator'])
args = parser.parse_args()
receipt = module / 'BUILD_SAVED.json'
if args.check:
    record = json.loads(receipt.read_text())
    if not record.get('sourceFiles'): raise SystemExit('Missing native source provenance')
    for item in record['sourceFiles']:
        if hashlib.sha256((module/item['path']).read_bytes()).hexdigest()!=item['sha256']:
            raise SystemExit('Native source differs from saved artifact: '+item['path'])
    for item in record['files']:
        file = framework / item['path']
        if hashlib.sha256(file.read_bytes()).hexdigest() != item['sha256']:
            raise SystemExit('Artifact digest mismatch: ' + str(file))
    print('XCFramework integrity verified')
    raise SystemExit(0)

evidence.mkdir(parents=True, exist_ok=True)
attempt = evidence / 'attempts' / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
attempt.mkdir(parents=True)
(evidence/'LATEST_ATTEMPT.json').write_text(json.dumps({'path':str(attempt)})+'\n')
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
def run(command, log=None):
    if log:
        with (attempt/log).open('wb') as output:
            subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT, check=True)
    else:
        subprocess.run(command, env=env, check=True)

libraries = []
for target in args.targets:
    sdk = {'macos':'macosx','ios':'iphoneos','simulator':'iphonesimulator'}[target]
    sdk_path = subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],env=env,text=True).strip()
    cache = pathlib.Path.home() / 'Library/Caches/CodexBuild/FloeChemistry/main/Xcode27.2' / ('native-'+target)
    configure = ['cmake','-S',str(module/'Native'),'-B',str(cache),'-G','Ninja',
                 '-DCMAKE_BUILD_TYPE=Release','-DCMAKE_OSX_ARCHITECTURES=arm64',
                 '-DCMAKE_OSX_SYSROOT='+sdk_path,'-DEigen3_DIR=/opt/homebrew/share/eigen3/cmake',
                 '-DCMAKE_OSX_DEPLOYMENT_TARGET='+('15.0' if target=='macos' else '26.0')]
    if target!='macos': configure.append('-DCMAKE_SYSTEM_NAME=iOS')
    run(configure, 'configure-'+target+'.log')
    run(['cmake','--build',str(cache),'--target','FloeChemistryBridge','-j','6'],'build-'+target+'.log')
    # Export a recoverable aggregate immediately after each successful build.
    exported = evidence / target / 'libFloeChemistryBridge.a'
    exported.parent.mkdir(parents=True, exist_ok=True)
    inputs = [cache/'libFloeChemistryBridge.a',cache/'avogadro/thirdparty/libpugixml.a',cache/'avogadro/thirdparty/libstruct.a']
    inputs += [cache/'avogadro/avogadro'/sub/('lib'+name+'.a') for sub,name in [('core','Core'),('io','IO'),('calc','Calc'),('quantumio','QuantumIO')]]
    run(['xcrun','libtool','-static','-o',str(exported)]+[str(x) for x in inputs], 'aggregate-'+target+'.log')
    libraries += ['-library',str(exported),'-headers',str(module/'Native/include')]
    print('Saved native artifact:',target,exported.stat().st_size,flush=True)

stage = attempt/'FloeChemistryBridge.xcframework'
run(['xcodebuild','-create-xcframework']+libraries+['-output',str(stage)],'create-xcframework.log')
if framework.exists(): framework.rename(attempt/'previous.xcframework')
shutil.copytree(stage,framework)
files = [{'path':str(p.relative_to(framework)),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(framework.rglob('*')) if p.is_file()]
source_files = [module/'Native/bridge.cpp',module/'Native/CMakeLists.txt',module/'Native/include/FloeChemistryBridge.h',module/'Native/include/module.modulemap',module/'UPSTREAM.json']
source_hashes = [{'path':str(p.relative_to(module)),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in source_files]
receipt.write_text(json.dumps({'upstream':json.loads((module/'UPSTREAM.json').read_text()),'targets':args.targets,'sourceFiles':source_hashes,'files':files},indent=2)+'\n')
print('Saved XCFramework:',framework)
