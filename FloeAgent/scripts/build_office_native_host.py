#!/usr/bin/env python3
"""Build Floe's native Office framework from qualified inputs; no device claims."""
import argparse
import copy
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

from package_office_engine import digest
from prepare_office_native_sources import DEFAULT_LOCK
from qualify_office_mobile import qualify

HOST = DEFAULT_LOCK.parent / "FloeOfficeNative"
NAME = "FloeOfficeNative"
EXCLUDED_SOURCES = {"main.m", "AppDelegate.mm", "SceneDelegate.mm",
    "DocumentBrowserViewController.mm", "TemplateCollectionViewController.mm", "TemplateSectionHeaderView.m"}
SYSTEM_FRAMEWORKS = ('UIKit', 'Foundation', 'CoreFoundation', 'CoreGraphics', 'CoreText', 'Security')


def framework_project(project, host_directory):
    project = copy.deepcopy(project)
    objects = project['objects']
    target = next(value for value in objects.values()
                  if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'Mobile')
    target.update(name=NAME, productName=NAME, productType='com.apple.product-type.framework')
    objects[target['productReference']].update(path=NAME + '.framework', explicitFileType='wrapper.framework')
    removed = set()
    for key in target['buildPhases']:
        phase = objects[key]
        if phase['isa'] == 'PBXSourcesBuildPhase':
            kept = []
            for entry in phase['files']:
                filename = Path(objects[objects[entry]['fileRef']]['path']).name
                if filename in EXCLUDED_SOURCES:
                    removed.add(filename)
                else:
                    kept.append(entry)
            phase['files'] = kept + ['F10E00000000000000000002', 'F10E00000000000000000007']
        if phase['isa'] == 'PBXResourcesBuildPhase':
            phase['files'] = [entry for entry in phase['files']
                if objects[objects[entry]['fileRef']].get('isa') != 'PBXVariantGroup'
                and objects[objects[entry]['fileRef']].get('path') not in
                    {'Assets.xcassets', 'Templates', 'Settings.bundle'}]
    if removed != EXCLUDED_SOURCES:
        raise ValueError('Pinned upstream application source boundaries changed')
    objects.update({
        'F10E00000000000000000001': {'isa': 'PBXFileReference', 'lastKnownFileType': 'sourcecode.cpp.objcpp',
            'path': str(host_directory / (NAME + '.mm')), 'sourceTree': '<absolute>'},
        'F10E00000000000000000002': {'isa': 'PBXBuildFile', 'fileRef': 'F10E00000000000000000001'},
        'F10E00000000000000000003': {'isa': 'PBXFileReference', 'lastKnownFileType': 'sourcecode.c.h',
            'path': str(host_directory / (NAME + '.h')), 'sourceTree': '<absolute>'},
        'F10E00000000000000000004': {'isa': 'PBXBuildFile', 'fileRef': 'F10E00000000000000000003',
            'settings': {'ATTRIBUTES': ['Public']}},
        'F10E00000000000000000005': {'isa': 'PBXHeadersBuildPhase', 'buildActionMask': 2147483647,
            'files': ['F10E00000000000000000004'], 'runOnlyForDeploymentPostprocessing': 0},
        'F10E00000000000000000006': {'isa': 'PBXFileReference', 'lastKnownFileType': 'sourcecode.cpp.cpp',
            'path': str(host_directory / 'FloeOfficeAttachment.cpp'), 'sourceTree': '<absolute>'},
        'F10E00000000000000000007': {'isa': 'PBXBuildFile', 'fileRef': 'F10E00000000000000000006'},
    })
    target['buildPhases'].insert(0, 'F10E00000000000000000005')
    for key in objects[target['buildConfigurationList']]['buildConfigurations']:
        settings = objects[key]['buildSettings']
        for name in ('ASSETCATALOG_COMPILER_APPICON_NAME', 'CODE_SIGN_ENTITLEMENTS',
                     'DEVELOPMENT_TEAM', 'PROVISIONING_PROFILE_SPECIFIER'):
            settings.pop(name, None)
        settings.update(PRODUCT_NAME=NAME, PRODUCT_MODULE_NAME=NAME,
            PRODUCT_BUNDLE_IDENTIFIER='org.floeagent.office.native',
            INFOPLIST_FILE=str(host_directory / 'Info.plist'),
            MACH_O_TYPE='mh_dylib', DEFINES_MODULE='YES', CLANG_ENABLE_MODULES='YES',
            SKIP_INSTALL='NO', INSTALL_PATH='$(LOCAL_LIBRARY_DIR)/Frameworks',
            DYLIB_INSTALL_NAME_BASE='@rpath', APPLICATION_EXTENSION_API_ONLY='NO')
        # A framework does not inherit the application product's implicit UIKit
        # linkage. Static engine archives also require their own Apple symbols.
        flags = settings['OTHER_LDFLAGS']
        for framework in SYSTEM_FRAMEWORKS:
            flags.extend(['-framework', framework])
    return project


def build_host(root, output, *, build=True, filter_overlay=None):
    root, output = Path(root).resolve(), Path(output).resolve()
    base = qualify(root, output, build=False)
    report = {**base, 'kind': 'Floe native framework qualification', 'target': NAME,
              'stage': 'prepare-host', 'hostCompilePassed': False,
              'hostLinkPassed': False, 'swiftModuleImportPassed': False,
              'originalFileWritebackPassed': False}
    receipt = output / 'native-host.json'

    def save():
        receipt.write_text(json.dumps(report, indent=2) + '\n')

    save()
    host = output / 'source/ios/Mobile'
    report['hostSourceSHA256'] = {}
    for name in (NAME + '.h', NAME + '.mm', 'FloeOfficeAttachment.cpp', 'FloeOfficeAttachment.hxx'):
        shutil.copyfile(HOST / name, host / name)
        report['hostSourceSHA256'][name] = digest(host / name)
    (host / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': '$(EXECUTABLE_NAME)', 'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
        'CFBundleName': NAME, 'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1',
        'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '26.0'}))
    project_path = output / 'source/ios/Mobile.xcodeproj/project.pbxproj'
    project = framework_project(plistlib.loads(project_path.read_bytes()), host)
    if filter_overlay is not None:
        from build_office_filter_overlay import select_linker_archive
        linker, filter_report = select_linker_archive(root, filter_overlay, output)
        report['filterOverlay'] = filter_report
        for settings in (obj.get('buildSettings', {}) for obj in project['objects'].values()):
            flags = settings.get('OTHER_LDFLAGS', [])
            if '-filelist' in flags:
                if flags.count('-filelist') != 1:
                    raise ValueError('Ambiguous native host linker input list')
                flags[flags.index('-filelist') + 1] = str(linker)
    project_path.write_bytes(plistlib.dumps(project))
    command = list(base['command'])
    command[command.index('-target') + 1] = NAME
    command[command.index('-resultBundlePath') + 1] = str(output / 'NativeHost.xcresult')
    report.update(stage='host-prepared', projectSHA256=digest(project_path), command=command)
    save()
    if not build:
        return report
    lock = json.loads(DEFAULT_LOCK.read_text())
    if shutil.disk_usage(output).free < lock['buildReserveGiB'] * 1024**3:
        raise RuntimeError('Native host build stopped at disk reserve')
    with (output / 'native-host-build.log').open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    framework = output / ('products/Release-iphoneos/' + NAME + '.framework')
    executable = framework / NAME
    passed = result.returncode == 0 and executable.is_file()
    report.update(exitCode=result.returncode, hostCompilePassed=passed, hostLinkPassed=passed,
                  nativeCompilePassed=passed, nativeLinkPassed=passed,
                  stage='host-built' if passed else 'host-build-failed')
    save()
    if not passed:
        raise RuntimeError('Native host failed; inspect native-host-build.log')
    report['executableSHA256'] = digest(executable)
    report['platformLoadCommands'] = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(executable)], text=True)
    report['dynamicLibraries'] = subprocess.check_output(['xcrun', 'otool', '-L', str(executable)], text=True)
    # The engine bootstrap resolves mainBundle, not bundleForClass. Deliver its
    # resources separately for the app target to copy without nested bundles.
    resources = output / 'OfficeRuntimeResources'
    resources.mkdir()
    for entry in list(framework.iterdir()):
        if entry.name not in {NAME, 'Info.plist', 'Headers', 'Modules', '_CodeSignature'}:
            shutil.move(str(entry), resources / entry.name)
    for required in ['cool.html', 'rc', 'ICU.dat', 'program', 'share']:
        if not (resources / required).exists():
            raise ValueError('Framework omitted a required engine resource: ' + required)
    report['runtimeResourceSHA256'] = {str(path.relative_to(resources)): digest(path)
        for path in sorted(resources.rglob('*')) if path.is_file()}
    report['runtimeResourceDirectories'] = [str(path.relative_to(resources))
        for path in sorted(resources.rglob('*')) if path.is_dir()]
    report['stage'] = 'host-packaged'
    save()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    probe = output / 'ImportProbe.swift'
    shutil.copyfile(Path(__file__).resolve().parent / 'fixtures/office_native_host_api.swift', probe)
    report['swiftProbeSHA256'] = digest(probe)
    module_command = ['xcrun', 'swiftc', '-typecheck', '-sdk', sdk, '-target', 'arm64-apple-ios26.0',
        '-F', str(framework.parent), str(probe)]
    with (output / 'swift-import.log').open('w') as log:
        result = subprocess.run(module_command, stdout=log, stderr=subprocess.STDOUT)
    report.update(swiftModuleImportPassed=result.returncode == 0,
                  stage='qualified-host' if result.returncode == 0 else 'swift-import-failed')
    save()
    if result.returncode:
        raise RuntimeError('Native framework Swift import failed; inspect swift-import.log')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--filter-overlay', type=Path)
    args = parser.parse_args()
    result = build_host(args.bundle, args.output, build=not args.prepare_only,
                        filter_overlay=args.filter_overlay)
    print(json.dumps({key: value for key, value in result.items() if key != 'runtimeResourceSHA256'}, indent=2))
