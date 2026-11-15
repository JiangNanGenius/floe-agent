#!/usr/bin/env python3
"""Build the pinned, small RDKit dependency closure for the preview bridge."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import struct
import subprocess
import tarfile
import urllib.request

MODULE = pathlib.Path(__file__).resolve().parents[1]
REPO = MODULE.parents[2]
NAME = 'FloeMoleculePreviewBridge'
PIN = json.loads((MODULE / 'UPSTREAM.json').read_text())
DEFAULT_SOURCE = REPO / 'Local/Scratch/chemistry-3d-native-20261115'
PRIVATE = REPO / 'Local/Private/chemistry-3d-native-20261115/engine'
ARTIFACTS = REPO / 'Local/Artifacts/MoleculePreviewNative/20261115'
FRAMEWORK = MODULE / 'Vendor' / (NAME + '.xcframework')
PLATFORMS = {
    'macos': ('macosx', 'macos-arm64', 'macos', None, 'MacOSX', '15.0'),
    'ios': ('iphoneos', 'ios-arm64', 'ios', None, 'iPhoneOS', '26.0'),
    'simulator': ('iphonesimulator', 'ios-arm64-simulator', 'ios', 'simulator', 'iPhoneSimulator', '26.0'),
}


def sha(path):
    return hashlib.file_digest(open(path, 'rb'), 'sha256').hexdigest()


def own_sources():
    paths = [MODULE / 'UPSTREAM.json', MODULE / 'Package.swift', MODULE / 'Tests/probe.cpp', MODULE / 'DEPENDENCIES.json']
    for sub in ('Native', 'Sources', 'Scripts', 'Licenses'):
        paths += [p for p in (MODULE / sub).rglob('*') if p.is_file() and '__pycache__' not in str(p)]
    return [{'path': str(p.relative_to(MODULE)), 'sha256': sha(p)} for p in sorted(paths)]


def file_rows(root):
    return [{'path': str(p.relative_to(root)), 'sha256': sha(p), 'bytes': p.stat().st_size}
            for p in sorted(root.rglob('*')) if p.is_file()]


def native_rows(rows):
    return [row for row in rows if row['path'].startswith('Native/') or row['path']=='UPSTREAM.json']


def verify_object_platform(binary, expected, minimum):
    # Inspect the actual compiled bridge object, independently of the wrapper plist.
    payload = subprocess.check_output(['ar', '-p', str(binary), 'bridge.cpp.o'])
    header = struct.unpack_from('<8I', payload)
    assert header[0] == 0xfeedfacf and header[1] == 0x100000c, 'Expected a real arm64 Mach-O object'
    offset = 32
    found = False
    for _ in range(header[4]):
        command, size = struct.unpack_from('<2I', payload, offset)
        if command == 0x32:
            platform, deployment = struct.unpack_from('<2I', payload, offset+8)
            assert platform == expected, 'Actual compiled Mach-O platform differs'
            parts = [int(p) for p in minimum.split('.')]
            assert deployment == (parts[0]<<16 | parts[1]<<8), 'Actual compiled minimum OS differs'
            found = True
        offset += size
    assert found, 'Missing actual Mach-O platform load command'


def check():
    receipt = json.loads((MODULE / 'BUILD_SAVED.json').read_text())
    assert receipt['sourceFiles'] == own_sources(), 'Bridge/source/build script changed after the saved build'
    assert receipt['upstream'] == PIN, 'Upstream pin changed'
    assert receipt['files'] == file_rows(FRAMEWORK), 'Artifact contents changed'
    dependencies = json.loads((MODULE / 'DEPENDENCIES.json').read_text())
    assert sha('/opt/homebrew/include/boost/version.hpp') == dependencies['Boost']['versionHeaderSHA256']
    assert sha(MODULE.parent/'FloeChemistryNative/Vendor/avogadrolibs/thirdparty/nlohmann/json.hpp') == dependencies['nlohmann-json']['jsonHeaderSHA256']
    info = plistlib.loads((FRAMEWORK / 'Info.plist').read_bytes())
    assert {i['LibraryIdentifier'] for i in info['AvailableLibraries']} == {PLATFORMS[p][1] for p in receipt['platforms']}
    for p in receipt['platforms']:
        _, identifier, platform, variant, _, _ = PLATFORMS[p]
        row = next(i for i in info['AvailableLibraries'] if i['LibraryIdentifier'] == identifier)
        assert row['SupportedPlatform'] == platform and row.get('SupportedPlatformVariant') == variant
        assert row['SupportedArchitectures'] == ['arm64']
        binary = FRAMEWORK / identifier / row['LibraryPath'] / NAME
        assert binary.read_bytes()[:8] == b'!<arch>\n', 'Expected real static archive'
        verify_object_platform(binary, {'macos':1, 'ios':2, 'simulator':7}[p], PLATFORMS[p][5])
        assert native_rows(receipt['compiledReceipts'][p]['sourceFiles']) == native_rows(own_sources())
    print('PASS: exact pinned preview source, all artifact bytes and Apple platform metadata verified (read-only).')


def prepare_source(root):
    root.mkdir(parents=True, exist_ok=True)
    archive = root / ('rdkit-' + PIN['commit'][:8] + '.tar.gz')
    if not archive.exists():
        temporary = archive.with_suffix('.download')
        urllib.request.urlretrieve(PIN['archive'], temporary)
        assert sha(temporary) == PIN['sha256'], 'RDKit archive checksum mismatch'
        temporary.replace(archive)
    assert sha(archive) == PIN['sha256'], 'RDKit archive checksum mismatch'
    source = root / ('rdkit-' + PIN['commit'])
    if not source.exists():
        with tarfile.open(archive) as package:
            package.extractall(root, filter='data')
    cmake = source / 'CMakeLists.txt'
    original = root / 'RDKit-CMakeLists.original.txt'
    if not original.exists():
        shutil.copy2(cmake, original)
    content = original.read_text()
    # A reviewed Apple static-only port switch; no host/platform spoofing.
    old = '  set(RDK_BUILD_STATIC_LIBS_ONLY OFF)'
    assert content.count(old) == 1
    content = content.replace(old, '  set(RDK_BUILD_STATIC_LIBS_ONLY ON) # Floe Apple static preview port')
    content += '\ninclude("${FLOE_PREVIEW_SOURCE_DIR}/Native/Bridge.cmake")\n'
    if not cmake.exists() or cmake.read_text() != content:
        cmake.write_text(content)
    return source, {'originalCMakeSHA256': sha(original), 'portedCMakeSHA256': sha(cmake),
                    'change': 'Build Apple libraries statically; include the bounded preview bridge. Upstream calculation sources unchanged.'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--platforms', nargs='+', choices=PLATFORMS, default=list(PLATFORMS))
    parser.add_argument('--source-root', type=pathlib.Path, default=DEFAULT_SOURCE)
    parser.add_argument('--scratch-root', type=pathlib.Path,
                        default=pathlib.Path.home() / 'Library/Caches/CodexBuild/FloeMoleculePreviewNative/main/Xcode27.2')
    parser.add_argument('--package-only', action='store_true')
    parser.add_argument('--no-package', action='store_true')
    args = parser.parse_args()
    if args.check:
        check()
        return
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    tmp = args.source_root.resolve() / 'tmp'
    tmp.mkdir(parents=True, exist_ok=True)
    env['TMPDIR'] = str(tmp)
    now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    attempt = PRIVATE / now
    attempt.mkdir(parents=True)
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    (PRIVATE / 'LATEST_ATTEMPT.json').write_text(json.dumps({'path': str(attempt)}) + '\n')
    toolchain = subprocess.check_output(['xcodebuild', '-version'], env=env, text=True).strip()

    def run(command, name):
        log = attempt / name
        with log.open('wb') as out:
            result = subprocess.run([str(x) for x in command], env=env, stdout=out, stderr=subprocess.STDOUT)
        if result.returncode:
            print(log.read_text(errors='replace')[-10000:], flush=True)
            raise SystemExit('FAILED; original log retained: ' + str(log))

    if not args.package_only:
        source, port = prepare_source(args.source_root.resolve())
        off = ['RDK_BUILD_PYTHON_WRAPPERS', 'RDK_BUILD_CPP_TESTS', 'BUILD_TESTING',
               'RDK_BUILD_INCHI_SUPPORT', 'RDK_BUILD_AVALON_SUPPORT', 'RDK_BUILD_PGSQL',
               'RDK_BUILD_COORDGEN_SUPPORT', 'RDK_BUILD_MAEPARSER_SUPPORT', 'RDK_BUILD_CHEMDRAW_SUPPORT',
               'RDK_BUILD_PUBCHEMSHAPE_SUPPORT', 'RDK_BUILD_DESCRIPTORS3D', 'RDK_BUILD_FREESASA_SUPPORT',
               'RDK_USE_BOOST_SERIALIZATION', 'RDK_USE_BOOST_IOSTREAMS', 'RDK_USE_BOOST_STACKTRACE',
               'RDK_INSTALL_INTREE', 'RDK_INSTALL_DEV_COMPONENT', 'RDK_BUILD_COMPRESSED_SUPPLIERS',
               'RDK_BUILD_SWIG_WRAPPERS', 'RDK_BUILD_MINIMAL_LIB', 'RDK_BUILD_CFFI_LIB', 'RDK_BUILD_CONTRIB',
               'RDK_TEST_MULTITHREADED', 'RDK_BUILD_CAIRO_SUPPORT', 'RDK_BUILD_FREETYPE_SUPPORT',
               'RDK_INSTALL_COMIC_FONTS']
        for platform in args.platforms:
            sdk, identifier, _, _, _, minimum = PLATFORMS[platform]
            build = args.scratch_root.resolve() / platform
            build.mkdir(parents=True, exist_ok=True)
            disk = shutil.disk_usage(build)
            if disk.free < 2*1024**3:
                raise SystemExit('Need at least 2 GiB available on the actual scratch volume; use a measured, task-owned alternative.')
            sdkpath = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], env=env, text=True).strip()
            config = ['cmake', '-S', source, '-B', build, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release',
                      '-DCMAKE_C_COMPILER=/usr/bin/clang', '-DCMAKE_CXX_COMPILER=/usr/bin/clang++',
                      '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_SYSROOT='+sdkpath,
                      '-DCMAKE_OSX_DEPLOYMENT_TARGET='+minimum, '-DBUILD_SHARED_LIBS=OFF',
                      '-DRDK_BUILD_THREADSAFE_SSS=ON', '-DRDK_BUILD_STATIC_LIBS_ONLY=ON',
                      '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON', '-DCMAKE_CXX_FLAGS_RELEASE=-O2 -DNDEBUG',
                      '-DBoost_DIR=/opt/homebrew/lib/cmake/Boost-1.90.0',
                      '-DEigen3_DIR=/opt/homebrew/share/eigen3/cmake',
                      '-DFLOE_PREVIEW_SOURCE_DIR='+str(MODULE),
                      '-DFLOE_JSON_INCLUDE_DIR='+str(MODULE.parent/'FloeChemistryNative/Vendor/avogadrolibs/thirdparty')]
            config += ['-D'+key+'=OFF' for key in off]
            if platform != 'macos':
                config += ['-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH',
                           '-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH']
            print('Configuring '+platform+'; scratch='+str(build), flush=True)
            run(config, 'configure-'+platform+'.log')
            target = 'MoleculePreviewProbe' if platform == 'macos' else NAME
            print('Compiling only '+target+' dependency closure on '+platform+' (6 jobs)', flush=True)
            run(['cmake', '--build', build, '--target', target, '-j', '6'], 'build-'+platform+'.log')
            archives = sorted((build / 'lib').glob('*.a')) + [build / ('lib'+NAME+'.a')]
            assert all(p.is_file() for p in archives)
            output = ARTIFACTS / platform
            output.mkdir(exist_ok=True)
            aggregate = output / ('lib'+NAME+'.a')
            run(['xcrun', 'libtool', '-static', '-o', aggregate, *archives], 'aggregate-'+platform+'.log')
            if platform == 'macos':
                shutil.copy2(build / 'MoleculePreviewProbe', output / 'MoleculePreviewProbe')
            compiled = {'toolchain': toolchain, 'upstream': PIN, 'port': port,
                        'sourceFiles': own_sources(), 'sdk': sdk, 'sdkPath': sdkpath, 'minimumOS': minimum,
                        'scratch': str(build), 'archives': [{'name': p.name, 'sha256': sha(p)} for p in archives],
                        'outputSHA256': sha(aggregate), 'outputBytes': aggregate.stat().st_size, 'attempt': str(attempt)}
            (output / 'BUILD.json').write_text(json.dumps(compiled, indent=2)+'\n')
            print('Saved '+platform+' real static archive: '+str(aggregate.stat().st_size)+' bytes', flush=True)
    if args.no_package:
        return
    inputs = []
    for platform in args.platforms:
        _, _, _, _, supported, minimum = PLATFORMS[platform]
        output = ARTIFACTS / platform
        compiled = json.loads((output / 'BUILD.json').read_text())
        assert native_rows(compiled['sourceFiles']) == native_rows(own_sources()), 'Do not package an artifact from different native calculation sources'
        binary = output / ('lib'+NAME+'.a')
        assert sha(binary) == compiled['outputSHA256']
        wrapper = attempt / platform / (NAME+'.framework')
        (wrapper / 'Headers').mkdir(parents=True)
        (wrapper / 'Modules').mkdir()
        shutil.copy2(binary, wrapper / NAME)
        shutil.copy2(MODULE / 'Native/include' / (NAME+'.h'), wrapper / 'Headers' / (NAME+'.h'))
        shutil.copy2(MODULE / 'Native/framework.modulemap', wrapper / 'Modules/module.modulemap')
        info = {'CFBundleExecutable': NAME, 'CFBundleIdentifier': 'com.floe.native.molecule-preview',
                'CFBundleName': NAME, 'CFBundlePackageType': 'FMWK', 'CFBundleShortVersionString': '0.1',
                'CFBundleVersion': '1', 'CFBundleSupportedPlatforms': [supported], 'MinimumOSVersion': minimum}
        (wrapper / 'Info.plist').write_bytes(plistlib.dumps(info))
        inputs += ['-framework', wrapper]
    staged = attempt / (NAME+'.xcframework')
    run(['xcodebuild', '-create-xcframework', *inputs, '-output', staged], 'package.log')
    FRAMEWORK.parent.mkdir(exist_ok=True)
    if FRAMEWORK.exists():
        FRAMEWORK.rename(attempt / ('previous-'+FRAMEWORK.name))
    shutil.copytree(staged, FRAMEWORK)
    public_receipt_keys = ['toolchain', 'upstream', 'port', 'sourceFiles', 'sdk', 'minimumOS', 'archives', 'outputSHA256', 'outputBytes']
    record = {'schemaVersion': 1, 'toolchain': toolchain, 'upstream': PIN,
              'platforms': args.platforms, 'sourceFiles': own_sources(), 'files': file_rows(FRAMEWORK),
              'compiledReceipts': {p: {key: value for key, value in json.loads((ARTIFACTS / p / 'BUILD.json').read_text()).items()
                                      if key in public_receipt_keys} for p in args.platforms}}
    (MODULE / 'BUILD_SAVED.json').write_text(json.dumps(record, indent=2)+'\n')
    print('Saved namespaced static XCFramework: '+str(FRAMEWORK), flush=True)
    check()


if __name__ == '__main__':
    main()
