#!/usr/bin/env python3
"""Build Floe's native Office framework from qualified inputs; no device claims."""
import argparse
import copy
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

from package_office_engine import digest
from prepare_office_native_sources import DEFAULT_LOCK
from qualify_office_mobile import qualify
from office_release_gates import false_capabilities
from office_font_config import (KNOWN_ENGINE_BUNDLED_FAMILIES, language_resource_report,
                                merge_font_config, validate_overlay)

HOST = DEFAULT_LOCK.parent / "FloeOfficeNative"
NAME = "FloeOfficeNative"
# The Swift import probe is copied verbatim from this fixture into the build
# output as ImportProbe.swift. It must type-check against the real public
# header, so a probe type that disagrees with how Clang imports the Objective-C
# API (e.g. NSDictionary<NSString *, id> * -> [String: Any]) fails the gate.
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
SWIFT_IMPORT_PROBE = SCRIPT_DIR / "fixtures" / "office_native_host_api.swift"
HOST_PUBLIC_HEADER = HOST / (NAME + ".h")
SWIFT_IMPORT_TARGET = "arm64-apple-ios26.0"
# The cloud Floe-simulator qualification type-checks the same probe against
# the iphonesimulator SDK; the triple must name the simulator environment or
# the probe would type-check against device UIKit declarations only.
SWIFT_IMPORT_TARGET_BY_SDK = {
    'iphoneos': 'arm64-apple-ios26.0',
    'iphonesimulator': 'arm64-apple-ios26.0-simulator',
}
EXCLUDED_SOURCES = {"main.m", "AppDelegate.mm", "SceneDelegate.mm",
    "DocumentBrowserViewController.mm", "TemplateCollectionViewController.mm", "TemplateSectionHeaderView.m"}
SYSTEM_FRAMEWORKS = ('UIKit', 'Foundation', 'CoreFoundation', 'CoreGraphics', 'CoreText', 'Security')


def run_identity(environment=None):
    """The CI run that produced this manifest.

    The pin records runID/workflowCommit from the artifact manifest and
    bootstrap_office_host.py re-downloads Vendor/Office/<runID>/OfficeNativeHost,
    so a manifest without run identity would leave the pin pointing at an older
    artifact. Absent values stay absent, so local qualification runs are
    unchanged.
    """
    environment = os.environ if environment is None else environment
    identity = {}
    if environment.get('GITHUB_RUN_ID'):
        identity['runID'] = environment['GITHUB_RUN_ID']
    if environment.get('GITHUB_SHA'):
        identity['workflowCommit'] = environment['GITHUB_SHA']
    return identity


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


def verify_swift_import_probe(*, sdk=None, platform_sdk='iphoneos'):
    """Type-check the *generated* import probe against the real public header.

    This is the same Swift-import gate the cloud build runs after linking the
    framework, but without needing the multi-GB Collabora engine build: the
    framework is recreated as a header-only Clang module (``DEFINES_MODULE``
    produces an umbrella ``framework module`` over the public header), and the
    exact probe fixture that ``build_host`` copies verbatim into
    ``ImportProbe.swift`` is type-checked against it.

    It catches a probe whose Swift annotation disagrees with the Objective-C
    import — the cloud failure was ``NSDictionary?`` against a property declared
    ``NSDictionary<NSString *, id> *``, which Swift imports as ``[String: Any]?``
    — and proves every other referenced host API still resolves. This never
    links an engine and never grants a release capability.

    ``platform_sdk`` selects the Apple platform SDK (``iphoneos`` pinned
    default, ``iphonesimulator`` for the cloud Floe-simulator qualification)
    and with it the probe target triple; ``sdk`` may still override the SDK
    *path* explicitly as before.
    """
    header = HOST_PUBLIC_HEADER
    if not header.is_file():
        raise FileNotFoundError(f'missing host public header: {header}')
    if not SWIFT_IMPORT_PROBE.is_file():
        raise FileNotFoundError(f'missing Swift import probe: {SWIFT_IMPORT_PROBE}')
    if platform_sdk not in SWIFT_IMPORT_TARGET_BY_SDK:
        raise ValueError(f'Unsupported Swift import probe platform SDK: {platform_sdk}')
    if sdk is None:
        sdk = subprocess.check_output(['xcrun', '--sdk', platform_sdk, '--show-sdk-path'],
                                      text=True).strip()
    modulemap = ('framework module ' + NAME + ' {\n'
                 '  umbrella header "' + NAME + '.h"\n'
                 '  export *\n}\n')
    with tempfile.TemporaryDirectory(prefix='floe-office-import-probe-') as temporary:
        framework = Path(temporary) / (NAME + '.framework')
        (framework / 'Headers').mkdir(parents=True)
        (framework / 'Modules').mkdir(parents=True)
        shutil.copyfile(header, framework / 'Headers' / (NAME + '.h'))
        (framework / 'Modules' / 'module.modulemap').write_text(modulemap)
        probe = Path(temporary) / 'ImportProbe.swift'
        shutil.copyfile(SWIFT_IMPORT_PROBE, probe)
        command = ['xcrun', 'swiftc', '-typecheck', '-sdk', sdk,
                   '-target', SWIFT_IMPORT_TARGET_BY_SDK[platform_sdk],
                   '-F', str(framework.parent), str(probe)]
        result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise AssertionError('generated ImportProbe does not match the Swift-imported host API:\n'
                             + result.stderr.strip())
    return {
        'swiftImportProbe': str(SWIFT_IMPORT_PROBE.relative_to(REPO_ROOT)),
        'swiftProbeSHA256': digest(SWIFT_IMPORT_PROBE),
        'hostHeaderSHA256': digest(header),
        'swiftImportTarget': SWIFT_IMPORT_TARGET_BY_SDK[platform_sdk],
        'platformSDK': platform_sdk,
        'swiftImportProbeCompiled': True,
        # A type-check of a header-only module is not an engine/device result.
        'engineVisibleRenderPassed': False,
        'deviceVisibleRenderPassed': False,
    }


def check_built_framework_import(output, framework, sdk):
    """Probe the built module and record the exact compiler target used."""
    sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
    probe = output / 'ImportProbe.swift'
    shutil.copyfile(SWIFT_IMPORT_PROBE, probe)
    module_command = ['xcrun', 'swiftc', '-typecheck', '-sdk', sdk_path,
        '-target', SWIFT_IMPORT_TARGET_BY_SDK[sdk],
        '-F', str(framework.parent), str(probe)]
    with (output / 'swift-import.log').open('w') as log:
        result = subprocess.run(module_command, stdout=log, stderr=subprocess.STDOUT)
    return {'swiftImportTarget': module_command[module_command.index('-target') + 1],
            'swiftProbeSHA256': digest(probe),
            'swiftModuleImportPassed': result.returncode == 0}


def build_host(root, output, *, build=True, filter_overlay=None, sdk='iphoneos',
               lock_path=DEFAULT_LOCK):
    """Build the Floe native Office framework for one Apple platform SDK.

    The pinned device qualification keeps the ``iphoneos`` default. The cloud
    Floe-simulator qualification passes ``sdk='iphonesimulator'`` against a
    staged simulator engine; the receipt then records the SDK, the products
    path and the Swift-import triple it actually used. The xlsx chart/filter
    overlay stays a device-only input and is never applied to a simulator
    host (its replacement archives are device objects).

    ``lock_path`` selects the overlay lock the build prepares and reports
    against. The cloud before/after diagnostic passes a lock copy without the
    kit callback overlay to build the unpatched variant from the same staged
    engine; the pinned device flow always uses the tracked default lock.
    """
    if sdk not in SWIFT_IMPORT_TARGET_BY_SDK:
        raise ValueError(f'Unsupported native host SDK: {sdk}')
    lock_path = Path(lock_path).resolve()
    root, output = Path(root).resolve(), Path(output).resolve()
    base = qualify(root, output, build=False, sdk=sdk, lock_path=lock_path)
    report = {**base, 'kind': 'Floe native framework qualification', 'target': NAME,
              'stage': 'prepare-host', 'hostCompilePassed': False,
              'hostLinkPassed': False, 'swiftModuleImportPassed': False,
              'originalFileWritebackPassed': False}
    # A compile/link qualification can never prove the release capabilities.
    # The block is explicit so a pin can never read an absent flag as passed.
    report['capabilityQualification'] = false_capabilities()
    # Provenance of the scheme lifecycle overlay carried in the produced host:
    # an older host (absent block) cannot satisfy a new-overlay claim, and
    # bootstrap_office_host enforces it once the host pin records the hash.
    lock = json.loads(lock_path.read_text())
    scheme_overlay = lock.get("schemeTaskLifecycleOverlay")
    if scheme_overlay is not None:
        report['schemeTaskLifecycle'] = {
            'patchSHA256': scheme_overlay['sha256'],
            'sourceCommit': lock['commit'],
            'files': {name: spec['preparedSHA256']
                      for name, spec in scheme_overlay['files'].items()}}
    # Same contract for the forwarding lifecycle overlay: the produced host
    # records the exact patched source it compiled, so a future pin carrying
    # forwardingOverlaySHA256 cannot be satisfied by a pre-overlay host.
    forwarding_overlay = lock.get("forwardingLifecycleOverlay")
    if forwarding_overlay is not None:
        report['forwardingLifecycle'] = {
            'patchSHA256': forwarding_overlay['sha256'],
            'sourceCommit': lock['commit'],
            'files': {name: spec['preparedSHA256']
                      for name, spec in forwarding_overlay['files'].items()}}
    # Same contract for the kit callback lifecycle overlay: the host records
    # the exact patched Kit sources it compiled, so a future pin carrying
    # kitCallbackOverlaySHA256 cannot be satisfied by a pre-overlay host.
    kit_overlay = lock.get("kitCallbackLifecycleOverlay")
    if kit_overlay is not None:
        report['kitCallbackLifecycle'] = {
            'patchSHA256': kit_overlay['sha256'],
            'sourceCommit': lock['commit'],
            'files': {name: spec['preparedSHA256']
                      for name, spec in kit_overlay['files'].items()}}
    report.update(run_identity())
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
    if shutil.disk_usage(output).free < lock['buildReserveGiB'] * 1024**3:
        raise RuntimeError('Native host build stopped at disk reserve')
    with (output / 'native-host-build.log').open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    framework = output / (f'products/Release-{sdk}/' + NAME + '.framework')
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
    # Floe-owned font substitution config (Build 233 R4): merge the additive
    # user-layer overlay into the packaged coolkitconfig.xcu before the
    # resource hashes are recorded, so the pin covers exactly the bytes the
    # app embeds. Structural validation only here: the Floe staged fonts are
    # copied into the app later by embed_office_host.py, but the real pinned
    # share/registry/main.xcd is present and every locale/alias path is
    # checked against it.
    main_xcd = resources / 'share/registry/main.xcd'
    if not main_xcd.is_file():
        raise ValueError('Office font validation requires the packaged VCL registry: main.xcd')
    structural = validate_overlay(require_targets=False,
                                  vendor_config=main_xcd)
    if structural['failures']:
        raise ValueError('Floe font substitution overlay is invalid: '
                         + '; '.join(structural['failures']))
    coolkit = resources / 'coolkitconfig.xcu'
    if not coolkit.is_file():
        raise ValueError('Framework omitted the kit configuration: coolkitconfig.xcu')
    merged, merge_facts = merge_font_config(coolkit.read_bytes())
    coolkit.write_bytes(merged)
    report['fontSubstitutionConfig'] = {
        'overlaySHA256': digest(lock_path.parent / 'FloeOfficeFontSubstitutions.xcu'),
        'aliases': len(structural['aliases']),
        'locales': structural['locales'],
        'aliasOverrides': len(structural['aliasOverrides']),
        'aliasAdditions': len(structural['aliasAdditions']),
        'schemaCheckedAgainst': 'share/registry/main.xcd' if main_xcd.is_file() else None,
        'hostConfigSHA256': digest(coolkit),
        'engineBundledTargets': sorted(KNOWN_ENGINE_BUNDLED_FAMILIES),
        **merge_facts,
    }
    # Build 233 R5: record which configured-language UI resources the upstream
    # build actually produced. A gap is reported, never fabricated.
    report['languageResources'] = language_resource_report(resources)
    report['runtimeResourceSHA256'] = {str(path.relative_to(resources)): digest(path)
        for path in sorted(resources.rglob('*')) if path.is_file()}
    report['runtimeResourceDirectories'] = [str(path.relative_to(resources))
        for path in sorted(resources.rglob('*')) if path.is_dir()]
    report['stage'] = 'host-packaged'
    save()
    report.update(check_built_framework_import(output, framework, base['sdk']))
    report['stage'] = 'qualified-host' if report['swiftModuleImportPassed'] else 'swift-import-failed'
    save()
    if not report['swiftModuleImportPassed']:
        raise RuntimeError('Native framework Swift import failed; inspect swift-import.log')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', nargs='?', type=Path)
    parser.add_argument('output', nargs='?', type=Path)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--filter-overlay', type=Path)
    parser.add_argument('--verify-swift-import-probe', action='store_true',
                        help='type-check the generated ImportProbe against the real header without a build')
    args = parser.parse_args()
    if args.verify_swift_import_probe:
        print(json.dumps(verify_swift_import_probe(), indent=2))
    else:
        if args.bundle is None or args.output is None:
            parser.error('bundle and output are required unless --verify-swift-import-probe is set')
        result = build_host(args.bundle, args.output, build=not args.prepare_only,
                            filter_overlay=args.filter_overlay)
        print(json.dumps({key: value for key, value in result.items() if key != 'runtimeResourceSHA256'}, indent=2))
