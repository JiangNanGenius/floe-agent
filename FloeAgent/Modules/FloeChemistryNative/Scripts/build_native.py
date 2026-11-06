#!/usr/bin/env python3
"""Build the pinned core, or rewrap its saved archives without compiling them."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess

packaging_module = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true', help='Read-only artifact/source/packaging verification')
parser.add_argument('--repackage-existing', action='store_true', help='Reuse saved archive bytes; never invoke CMake or libtool')
parser.add_argument('--targets', nargs='+', default=['macos', 'ios', 'simulator'], choices=['macos', 'ios', 'simulator'])
parser.add_argument('--module-root', type=pathlib.Path, default=packaging_module)
parser.add_argument('--output', type=pathlib.Path)
parser.add_argument('--packaging-receipt', type=pathlib.Path)
parser.add_argument('--work-directory', type=pathlib.Path)
args = parser.parse_args()
module = args.module_root.resolve()
repo = module.parents[2]
framework = args.output.resolve() if args.output else module / 'Vendor/FloeChemistryBridge.xcframework'
receipt = module / 'BUILD_SAVED.json'
packaging_receipt = args.packaging_receipt.resolve() if args.packaging_receipt else module / 'PACKAGING_SAVED.json'
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
name = 'FloeChemistryBridge'
target_info = {
    'macos': ('macos-arm64', 'macos', None, 'MacOSX', '15.0'),
    'ios': ('ios-arm64', 'ios', None, 'iPhoneOS', '26.0'),
    'simulator': ('ios-arm64-simulator', 'ios', 'simulator', 'iPhoneSimulator', '26.0'),
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fail(message):
    raise SystemExit(message)


def saved_build():
    record = json.loads(receipt.read_text())
    if not record.get('sourceFiles') or not record.get('files'):
        fail('Missing native source/artifact provenance')
    for item in record['sourceFiles']:
        file = module / item['path']
        if digest(file) != item['sha256']:
            fail('Native source differs from saved artifact: ' + item['path'])
    return record


def archive_rows(record):
    result = {}
    for target in record['targets']:
        identifier = target_info[target][0]
        matches = [item for item in record['files'] if item['path'].startswith(identifier + '/')
                   and (item['path'].endswith('.a') or item['path'].endswith('.framework/' + name))]
        if len(matches) != 1:
            fail('Expected one compiled archive for ' + target)
        result[target] = matches[0]
    return result


def file_rows(root):
    return [{'path': str(p.relative_to(root)), 'sha256': digest(p)}
            for p in sorted(root.rglob('*')) if p.is_file()]


def verify_files(root, rows):
    expected = {row['path']: row['sha256'] for row in rows}
    actual = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            fail('Unexpected symlink in artifact: ' + str(path))
        if path.is_file():
            actual[str(path.relative_to(root))] = digest(path)
    if actual != expected:
        fail('Artifact file set or digest mismatch: ' + str(root))


def verify_layout(root, record, wrapper):
    if wrapper.get('schemaVersion') != 1 or wrapper.get('format') != 'static-framework-xcframework':
        fail('Unsupported packaging receipt')
    if wrapper.get('sourceBuildReceiptSHA256') != digest(receipt):
        fail('Compiled BUILD_SAVED receipt binding differs')
    for item in wrapper.get('packagingSourceFiles', []):
        if digest(packaging_module / item['path']) != item['sha256']:
            fail('Packaging source differs: ' + item['path'])
    if not wrapper.get('packagingSourceFiles'):
        fail('Missing packaging source provenance')
    verify_files(root, wrapper['files'])
    info = plistlib.loads((root / 'Info.plist').read_bytes())
    entries = {item['LibraryIdentifier']: item for item in info['AvailableLibraries']}
    rows = archive_rows(record)
    if set(entries) != {target_info[t][0] for t in record['targets']}:
        fail('XCFramework platform set differs from compiled receipt')
    if set(wrapper['archives']) != set(record['targets']):
        fail('Packaging archive set differs from compiled receipt')
    for target, compiled in rows.items():
        identifier, platform, variant, supported, minimum = target_info[target]
        entry = entries[identifier]
        relative = identifier + '/' + name + '.framework/' + name
        binary = root / relative
        if entry.get('LibraryPath') != name + '.framework' or 'HeadersPath' in entry:
            fail('XCFramework must export a namespaced framework, not flat headers')
        if entry.get('SupportedPlatform') != platform or entry.get('SupportedPlatformVariant') != variant:
            fail('XCFramework platform metadata mismatch: ' + target)
        if entry.get('SupportedArchitectures') != ['arm64']:
            fail('Unexpected framework architecture: ' + target)
        if digest(binary) != compiled['sha256'] or binary.read_bytes()[:8] != b'!<arch>\n':
            fail('Static archive bytes differ from compiled provenance: ' + target)
        actual = wrapper['archives'][target]
        if actual.get('path') != relative or actual.get('sha256') != compiled['sha256'] or actual.get('bytes') != binary.stat().st_size:
            fail('Packaging archive receipt mismatch: ' + target)
        bundle = binary.parent
        if (bundle / 'Headers' / (name + '.h')).read_bytes() != (module / 'Native/include' / (name + '.h')).read_bytes():
            fail('Framework public header differs from compiled input')
        if (bundle / 'Modules/module.modulemap').read_bytes() != (packaging_module / 'Native/framework.modulemap').read_bytes():
            fail('Framework module map differs from packaging input')
        bundle_info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        if bundle_info.get('CFBundleExecutable') != name or bundle_info.get('CFBundlePackageType') != 'FMWK' or bundle_info.get('CFBundleSupportedPlatforms') != [supported]:
            fail('Framework bundle metadata mismatch: ' + target)
        if bundle_info.get('MinimumOSVersion') != minimum:
            fail('Framework minimum OS differs from saved platform target: ' + target)


if args.check:
    record = saved_build()
    if packaging_receipt.exists():
        verify_layout(framework, record, json.loads(packaging_receipt.read_text()))
        print('XCFramework integrity verified; static archive bytes and packaging provenance verified')
    else:
        # Original flat-library receipts remain readable during migration.
        verify_files(framework, record['files'])
        print('XCFramework integrity verified (original library packaging)')
    raise SystemExit(0)

evidence = repo / 'Local/Private/chemistry-predevelopment-20261106/native'
attempt = args.work_directory.resolve() if args.work_directory else evidence / 'attempts' / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
attempt.mkdir(parents=True, exist_ok=False)
if args.work_directory is None:
    (evidence / 'LATEST_ATTEMPT.json').write_text(json.dumps({'path': str(attempt)}) + '\n')


def run(command, log):
    with (attempt / log).open('wb') as output:
        subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT, check=True)


archives = {}
source_record = None
if args.repackage_existing:
    source_record = saved_build()
    source_framework = module / 'Vendor/FloeChemistryBridge.xcframework'
    current_wrapper = module / 'PACKAGING_SAVED.json'
    if current_wrapper.exists():
        verify_layout(source_framework, source_record, json.loads(current_wrapper.read_text()))
    else:
        verify_files(source_framework, source_record['files'])
    source_entries = {row['LibraryIdentifier']: row for row in plistlib.loads((source_framework / 'Info.plist').read_bytes())['AvailableLibraries']}
    for target, compiled in archive_rows(source_record).items():
        identifier = target_info[target][0]
        entry = source_entries[identifier]
        binary_path = entry.get('BinaryPath', entry['LibraryPath'])
        path = source_framework / identifier / binary_path
        if digest(path) != compiled['sha256']:
            fail('Input archive differs from compiled receipt: ' + target)
        archives[target] = path
else:
    for target in args.targets:
        sdk = {'macos': 'macosx', 'ios': 'iphoneos', 'simulator': 'iphonesimulator'}[target]
        sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], env=env, text=True).strip()
        cache = pathlib.Path.home() / 'Library/Caches/CodexBuild/FloeChemistry/main/Xcode27.2' / ('native-' + target)
        configure = ['cmake', '-S', str(module / 'Native'), '-B', str(cache), '-G', 'Ninja',
                     '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=arm64',
                     '-DCMAKE_OSX_SYSROOT=' + sdk_path, '-DEigen3_DIR=/opt/homebrew/share/eigen3/cmake',
                     '-DCMAKE_OSX_DEPLOYMENT_TARGET=' + target_info[target][4]]
        if target != 'macos':
            configure.append('-DCMAKE_SYSTEM_NAME=iOS')
        run(configure, 'configure-' + target + '.log')
        run(['cmake', '--build', str(cache), '--target', name, '-j', '6'], 'build-' + target + '.log')
        exported = evidence / target / ('lib' + name + '.a')
        exported.parent.mkdir(parents=True, exist_ok=True)
        inputs = [cache / ('lib' + name + '.a'), cache / 'avogadro/thirdparty/libpugixml.a', cache / 'avogadro/thirdparty/libstruct.a']
        inputs += [cache / 'avogadro/avogadro' / sub / ('lib' + lib + '.a') for sub, lib in [('core', 'Core'), ('io', 'IO'), ('calc', 'Calc'), ('quantumio', 'QuantumIO')]]
        run(['xcrun', 'libtool', '-static', '-o', str(exported)] + [str(x) for x in inputs], 'aggregate-' + target + '.log')
        archives[target] = exported
        print('Saved native artifact:', target, exported.stat().st_size, flush=True)

# A framework keeps Headers and Modules namespaced under its own product.
# Merely changing the flat Headers folder name still collides in Xcode's include output.
framework_inputs = []
for target, archive in archives.items():
    bundle = attempt / target / (name + '.framework')
    (bundle / 'Headers').mkdir(parents=True)
    (bundle / 'Modules').mkdir()
    shutil.copy2(archive, bundle / name)
    shutil.copy2(module / 'Native/include' / (name + '.h'), bundle / 'Headers' / (name + '.h'))
    shutil.copy2(packaging_module / 'Native/framework.modulemap', bundle / 'Modules/module.modulemap')
    info = {'CFBundleIdentifier': 'org.floe.chemistry.bridge', 'CFBundleName': name,
            'CFBundleExecutable': name, 'CFBundlePackageType': 'FMWK',
            'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1',
            'CFBundleSupportedPlatforms': [target_info[target][3]], 'MinimumOSVersion': target_info[target][4]}
    if target == 'macos':
        info['LSMinimumSystemVersion'] = target_info[target][4]
    (bundle / 'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=True))
    framework_inputs += ['-framework', str(bundle)]
stage = attempt / (name + '.xcframework')
run(['xcodebuild', '-create-xcframework'] + framework_inputs + ['-output', str(stage)], 'create-xcframework.log')
if framework.exists():
    framework.rename(attempt / 'previous.xcframework')
framework.parent.mkdir(parents=True, exist_ok=True)
shutil.copytree(stage, framework)

if not args.repackage_existing:
    if receipt.exists():
        shutil.copy2(receipt, attempt / 'previous.BUILD_SAVED.json')
    source_paths = ['Native/bridge.cpp', 'Native/CMakeLists.txt', 'Native/include/FloeChemistryBridge.h', 'Native/include/module.modulemap', 'UPSTREAM.json']
    source_record = {'upstream': json.loads((module / 'UPSTREAM.json').read_text()), 'targets': args.targets,
                     'sourceFiles': [{'path': p, 'sha256': digest(module / p)} for p in source_paths], 'files': file_rows(framework)}
    receipt.write_text(json.dumps(source_record, indent=2) + '\n')

# Repackaging never rewrites BUILD_SAVED or its compiled-input hashes.
wrapper = {'schemaVersion': 1, 'format': 'static-framework-xcframework',
           'operation': 'repackage-existing' if args.repackage_existing else 'compiled-and-packaged',
           'sourceBuildReceipt': 'BUILD_SAVED.json', 'sourceBuildReceiptSHA256': digest(receipt),
           'packagingSourceFiles': [{'path': p, 'sha256': digest(packaging_module / p)} for p in ['Scripts/build_native.py', 'Native/framework.modulemap']],
           'archives': {}, 'files': file_rows(framework)}
for target, compiled in archive_rows(source_record).items():
    relative = target_info[target][0] + '/' + name + '.framework/' + name
    binary = framework / relative
    if digest(binary) != compiled['sha256']:
        fail('Packaging changed static archive bytes: ' + target)
    wrapper['archives'][target] = {'path': relative, 'sourceBuildPath': compiled['path'], 'bytes': binary.stat().st_size, 'sha256': compiled['sha256']}
verify_layout(framework, source_record, wrapper)
packaging_receipt.parent.mkdir(parents=True, exist_ok=True)
packaging_receipt.write_text(json.dumps(wrapper, indent=2) + '\n')
print('Saved namespaced static-framework XCFramework:', framework)
