#!/usr/bin/env python3
"""Object-compile the real native bridge and run its production coordinator.

Run through the repository shared-native-window wrapper. This script never
boots, installs or changes a Simulator and never calls Apple's image model.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-dir', type=Path, required=True)
parser.add_argument('--evidence-dir', type=Path, required=True)
parser.add_argument('--jobs', type=int, default=6)
parser.add_argument('--app-products', type=Path)
parser.add_argument('--clang-module-map', type=Path, action='append', default=[])
parser.add_argument('--reuse-contract-evidence', type=Path)
parser.add_argument('--compile-output-tests', type=Path,
                    help='Object-compile the App persistence XCTest source against this production qualification module; does not run it.')
args = parser.parse_args()
if not 1 <= args.jobs <= 16:
    parser.error('--jobs must be 1...16')
root = Path(__file__).resolve().parents[3]
source = root / 'FloeAgent/FloeApp/Media/AppleImagePlayground'
build = args.build_dir.resolve()
evidence = args.evidence_dir.resolve()
build.mkdir(parents=True, exist_ok=True)
evidence.mkdir(parents=True, exist_ok=True)
os.environ['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'


def output(command):
    return subprocess.check_output(command, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


record = {
    'started': time.time(), 'sourceHEAD': output(['git', '-C', str(root), 'rev-parse', 'HEAD']),
    'toolchain': output(['xcodebuild', '-version']),
    'source': {str(p.relative_to(root)): digest(p) for p in source.glob('*.swift')},
    'phases': [], 'limitations': ['No Apple inference, physical device, or full App acceptance.',
                                'Synthetic images exercise encoded bytes and ownership/cancellation only.'],
}


def run(label, command, timeout=180):
    print(label, flush=True)
    phase = {'label': label, 'command': [str(v) for v in command], 'started': time.time()}
    with (evidence / (label + '.log')).open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    phase.update(exitCode=result.returncode, finished=time.time())
    record['phases'].append(phase)
    (evidence / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    if result.returncode:
        print((evidence / (label + '.log')).read_text()[-9000:], flush=True)
        raise SystemExit(result.returncode)


mac_sdk = output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'])
sim_sdk = output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
core = [source / 'AppleImagePlaygroundContract.swift', source / 'AppleImagePlaygroundService.swift']
tests = Path(__file__).parent / 'ContractTests.swift'
record['contractTestSourceSHA256'] = digest(tests)
if args.reuse_contract_evidence:
    prior = json.loads((args.reuse_contract_evidence / 'result.json').read_text())
    assert all(prior['source'][str(p.relative_to(root))] == digest(p) for p in core)
    assert all(any(p['label'] == label and p['exitCode'] == 0 for p in prior['phases'])
               for label in ['contract-compile', 'contract-runtime'])
    if 'contractTestSourceSHA256' in prior:
        assert prior['contractTestSourceSHA256'] == digest(tests)
    else:
        assert tests.stat().st_mtime <= prior['started'], 'Contract test source changed after the retained run.'
    record['reusedContractEvidence'] = str(args.reuse_contract_evidence.resolve())
else:
    run('contract-compile', ['xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '6',
        '-sdk', mac_sdk, '-target', 'arm64-apple-macos26.0', '-parse-as-library',
        '-module-cache-path', str(build / 'ModuleCache-mac'), '-j', str(args.jobs),
        *map(str, core), str(tests), '-o', str(build / 'contract-tests')])
    run('contract-runtime', [str(build / 'contract-tests')], timeout=30)

native_sources = core + [source / 'AppleImagePlaygroundHost.swift']
includes = []
if args.app_products:
    products = args.app_products.resolve()
    if not products.is_dir():
        raise SystemExit('The supplied real App products do not exist; no substitute modules are built.')
    native_sources.append(source / 'AppleImagePlaygroundTool.swift')
    includes = ['-I', str(products), '-F', str(products / 'PackageFrameworks')]
    record['appProducts'] = str(products)
else:
    record['limitations'].append('Tool adapter requires separate App-module object compilation.')
for module_map in args.clang_module_map:
    assert module_map.is_file(), module_map
    includes += ['-Xcc', '-fmodule-map-file=' + str(module_map.resolve())]
run('native-object', ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '6',
    '-sdk', sim_sdk, '-target', 'arm64-apple-ios26.0-simulator', '-parse-as-library',
    '-whole-module-optimization', '-emit-object', '-emit-module',
    '-module-name', 'FloeImagePlaygroundQualification',
    '-module-cache-path', str(build / 'ModuleCache-sim'), '-j', str(args.jobs),
    '-emit-module-path', str(build / 'FloeImagePlaygroundQualification.swiftmodule'),
    *(['-enable-testing'] if args.compile_output_tests else []),
    *includes, *map(str, native_sources), '-o', str(build / 'native.o')])

exports = ['native.o', 'FloeImagePlaygroundQualification.swiftmodule']
for name in exports:
    shutil.copy2(build / name, evidence / name)
if args.compile_output_tests:
    assert args.app_products, 'Persistence XCTest object compilation requires the real App products.'
    output_tests = args.compile_output_tests.resolve()
    original = output_tests.read_text()
    assert original.count('@testable import FloeApp') == 1
    adapted = build / output_tests.name
    adapted.write_text(original.replace('@testable import FloeApp', '@testable import FloeImagePlaygroundQualification'))
    record['outputTestSource'] = str(output_tests.relative_to(root))
    record['outputTestSourceSHA256'] = digest(output_tests)
    platform_developer = Path(os.environ['DEVELOPER_DIR']) / 'Platforms/iPhoneSimulator.platform/Developer'
    test_frameworks = platform_developer / 'Library/Frameworks'
    run('persistence-test-object', ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '6',
        '-sdk', sim_sdk, '-target', 'arm64-apple-ios26.0-simulator', '-parse-as-library',
        '-whole-module-optimization', '-emit-object', '-module-name', 'FloeImagePlaygroundOutputTests',
        '-module-cache-path', str(build / 'ModuleCache-sim'), '-j', str(args.jobs),
        '-I', str(build), '-I', str(platform_developer / 'usr/lib'), '-F', str(test_frameworks), *includes,
        str(adapted), '-o', str(build / 'persistence-tests.o')])
    assert record['outputTestSourceSHA256'] == digest(output_tests), 'XCTest source changed during compilation.'
    exports.append('persistence-tests.o')
    record['limitations'].append('Persistence XCTest source was object-compiled against production qualification sources, not executed in the App.')

for name in exports:
    shutil.copy2(build / name, evidence / name)
record.update(finished=time.time(), state='passed',
    nativeObjectSHA256=digest(evidence / 'native.o'),
    sourceUnchanged=all(digest(root / path) == value for path, value in record['source'].items()))
assert record['sourceUnchanged'], 'Source changed during native compilation.'
(evidence / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps({'state': record['state'], 'phases': [p['label'] for p in record['phases']],
                  'evidence': str(evidence), 'limitations': record['limitations']}), flush=True)
