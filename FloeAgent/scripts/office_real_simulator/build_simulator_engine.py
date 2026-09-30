#!/usr/bin/env python3
"""Configure and build the REAL Collabora engine for iphonesimulator arm64.

Phases (each recorded in qualification.json with timing and free space):

1. engine-configure  - CPiOS distro + --enable-ios-simulator in source/engine
2. engine-build      - gmake -j2 (hundreds of native static archives)
3. editor-configure  - online --enable-iosapp (creates the top-level symlinks
                       and ios/Mobile/Config.xcconfig consumed by Xcode)
4. editor-build      - gmake builds browser/dist for the app

A watchdog stops a phase if free space falls to the reserve (engine.lock.json
pins: minimum 12 GiB, reserve 6 GiB) and terminates the whole process group, so
a runner can never fill its disk silently. This script produces no stub and
never converts device binaries.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

from sim_paths import (HOST_APP_NAME, HOST_BUNDLE_ID, HOST_VENDOR,
                       MINIMUM_FREE_GIB, RESERVE_GIB, normalize_xcode_version)

REQUIRED_TOOLS = ('git', 'gmake', 'gperf', 'autoconf', 'automake', 'glibtool',
                   'pkg-config', 'node', 'perl', 'xcrun')

ENGINE_CONFIGURE_ARGS = [
    '--with-distro=CPiOS',
    '--enable-ios-simulator',
    '--disable-debug',
    '--disable-dbgutil',
    '--disable-symbols',
    '--with-lang=en-US zh-CN zh-TW',
]


def free_gib(path):
    return shutil.disk_usage(str(path)).free / 1024**3


def sdk_info():
    path = subprocess.run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'],
                          capture_output=True, text=True)
    version = subprocess.run(['xcrun', '--sdk', 'iphonesimulator',
                              '--show-sdk-version'],
                             capture_output=True, text=True)
    build = subprocess.run(['xcrun', '--sdk', 'iphonesimulator',
                            '--show-sdk-build-version'],
                           capture_output=True, text=True)
    return {
        'sdkPath': path.stdout.strip() if path.returncode == 0 else '',
        'sdkVersion': version.stdout.strip() if version.returncode == 0 else '',
        'sdkBuildVersion': build.stdout.strip() if build.returncode == 0 else '',
    }


def toolchain_info():
    clang = subprocess.run(['xcrun', '--find', 'clang'], capture_output=True, text=True)
    xcode = subprocess.run(['xcrun', '--find', 'xcodebuild'], capture_output=True,
                           text=True)
    xcode_version = subprocess.run(['xcodebuild', '-version'], capture_output=True,
                                   text=True)
    return {
        'clang': clang.stdout.strip() if clang.returncode == 0 else '',
        'xcodebuild': xcode.stdout.strip() if xcode.returncode == 0 else '',
        'xcodeVersion': normalize_xcode_version(xcode_version.stdout)
        if xcode_version.returncode == 0 else '',
    }


def preflight(build_root, source):
    missing = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
    sdk = sdk_info()
    free = free_gib(build_root)
    report = {
        'commit': None,  # filled by caller
        'platform': 'iphonesimulator-arm64',
        'freeGiB': round(free, 2),
        'requiredFreeGiB': MINIMUM_FREE_GIB,
        'buildReserveGiB': RESERVE_GIB,
        'missingTools': missing,
        'iphonesimulatorSDKAvailable': bool(sdk['sdkPath']),
        **sdk,
        **toolchain_info(),
        'engineConfigureArguments': ENGINE_CONFIGURE_ARGS,
        'nativeBuildPassed': False,
        'preflightPassed': (
            not missing and bool(sdk['sdkPath']) and free >= MINIMUM_FREE_GIB),
    }
    if not (source / 'engine/configure.ac').is_file():
        report['preflightPassed'] = False
        report['sourceError'] = 'pinned source not prepared'
    return report


def run_phase(name, cwd, command, qualification_path, log_dir, env=None):
    """Run one phase under the disk-reserve watchdog; fail fast on reserve."""
    report = json.loads(Path(qualification_path).read_text())
    report['stage'] = name
    started = time.time()
    Path(qualification_path).write_text(json.dumps(report, indent=2))
    log_path = Path(log_dir) / f'{name}.log'
    full_env = {**os.environ, 'MAKE': shutil.which('gmake') or 'gmake'}
    if env:
        full_env.update(env)
    with log_path.open('w') as log:
        process = subprocess.Popen([str(item) for item in command], cwd=str(cwd),
                                   stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True, env=full_env,
                                   text=True)
        try:
            while process.poll() is None:
                free = free_gib(cwd)
                if free < RESERVE_GIB:
                    os.killpg(process.pid, signal.SIGTERM)
                    time.sleep(5)
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    raise RuntimeError(
                        f'{name} stopped at disk reserve ({round(free,2)} GiB free)')
                time.sleep(5)
        except RuntimeError:
            raise
        if process.returncode != 0:
            raise RuntimeError(f'{name} failed with exit code {process.returncode}; '
                               f'see {log_path}')
    duration = round(time.time() - started, 1)
    report = json.loads(Path(qualification_path).read_text())
    report['phases'] = report.get('phases', {})
    report['phases'][name] = {
        'seconds': duration,
        'freeGiBAfter': round(free_gib(cwd), 2),
        'log': str(log_path),
    }
    Path(qualification_path).write_text(json.dumps(report, indent=2))


def build(build_root):
    build_root = Path(build_root).resolve()
    build_root.mkdir(parents=True, exist_ok=True)
    source = build_root / 'source'
    log_dir = build_root / 'qualification-logs'
    log_dir.mkdir(parents=True, exist_ok=True)
    qualification_path = build_root / 'qualification.json'

    if qualification_path.exists():
        report = json.loads(qualification_path.read_text())
    else:
        head = subprocess.run(['git', '-C', str(source), 'rev-parse', 'HEAD'],
                              capture_output=True, text=True, check=True).stdout.strip()
        report = preflight(build_root, source)
        report['commit'] = head
        qualification_path.write_text(json.dumps(report, indent=2))
    if not report.get('preflightPassed'):
        raise RuntimeError(f'preflight failed: {json.dumps(report, indent=2)}')

    engine_dir = source / 'engine'
    editor_configure_args = [
        '--enable-iosapp',
        f'--with-app-name={HOST_APP_NAME}',
        f'--with-app-package-name={HOST_BUNDLE_ID}',
        '--enable-experimental',
        f'--with-vendor={HOST_VENDOR}',
        f'--with-lo-builddir={engine_dir}',
    ]
    phases = [
        ('engine-configure', engine_dir,
         ['perl', './autogen.sh', *ENGINE_CONFIGURE_ARGS]),
        ('engine-build', engine_dir, ['gmake', '-j2']),
        ('editor-autogen', source, ['./autogen.sh']),
        ('editor-configure', source, ['./configure', *editor_configure_args]),
        ('editor-build', source, ['gmake', '-j2']),
    ]
    for name, cwd, command in phases:
        run_phase(name, cwd, command, qualification_path, log_dir)

    manifest = engine_dir / 'workdir/CustomTarget/ios/ios-all-static-libs.list'
    if not manifest.is_file() or not manifest.read_text().strip():
        raise RuntimeError('missing engine static archive manifest')
    report = json.loads(qualification_path.read_text())
    report['nativeBuildPassed'] = True
    report['nativeArchiveManifest'] = str(manifest)
    qualification_path.write_text(json.dumps(report, indent=2))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build_root')
    args = parser.parse_args()
    print(json.dumps(build(args.build_root), indent=2))


if __name__ == '__main__':
    try:
        main()
    except RuntimeError as error:
        print(f'BUILD FAILED: {error}', file=sys.stderr)
        sys.exit(1)
