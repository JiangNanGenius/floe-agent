#!/usr/bin/env python3
"""Configure and build the REAL Collabora engine for iphonesimulator arm64.

Phases (each recorded in qualification.json with timing and free space):

1. engine-configure  - CPiOS distro + --enable-ios-simulator in source/engine
2. engine-build      - gmake -j2 (hundreds of native static archives)
3. editor-autogen    - online ./autogen.sh (creates the top-level configure)
4. editor-configure  - online --enable-iosapp (creates the top-level symlinks
                       and ios/Mobile/Config.xcconfig consumed by Xcode;
                       configure.ac hard-fails on Darwin unless
                       ``/usr/bin/env python3 -c "import lxml"`` succeeds)
5. editor-build      - gmake builds browser/dist for the app

A watchdog stops a phase if free space falls to the reserve (engine.lock.json
pins: minimum 12 GiB, reserve 6 GiB) and terminates the whole process group, so
a runner can never fill its disk silently. This script produces no stub and
never converts device binaries.

Python binding: the real failure of run 36704184429 was that the driver itself
ran under the prepared venv but every child (``perl ./autogen.sh``,
``./configure``) inherited the runner PATH, so configure's
``/usr/bin/env python3`` resolved to a Python without lxml/polib. Every phase
subprocess now receives ``PATH`` with the prepared venv's bin directory first,
and ``verify_child_python`` proves -- with the exact command configure runs --
that the child interpreter imports the pinned lxml/polib before the heavy
engine build is allowed to start.

Checkpoint boundary: after a successful ``engine-build`` the caller (the
workflow) packs a completed-core checkpoint before editor-autogen/configure
run.  ``--phases editor`` refuses to run unless this build root already
carries a completed engine build or a validated checkpoint resume report;
when a resume report is present, engine-configure/engine-build are
structurally excluded from the phase plan.
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

from sim_paths import (CONFIGURE_PYTHON_CHECK, EDITOR_CONFIGURE_INPUTS,
                       EDITOR_PHASES, ENGINE_PHASES, HOST_APP_NAME,
                       HOST_BUNDLE_ID, HOST_VENDOR, MINIMUM_FREE_GIB,
                       PINNED_PYTHON_PACKAGES, RESERVE_GIB,
                       normalize_xcode_version)
from resume_simulator_core import CheckpointError, load_resume_report

REQUIRED_TOOLS = ('git', 'gmake', 'gperf', 'autoconf', 'automake', 'glibtool',
                  'pkg-config', 'node', 'perl', 'xcrun', 'wget')

ENGINE_CONFIGURE_ARGS = [
    '--with-distro=CPiOS',
    '--enable-ios-simulator',
    '--disable-debug',
    '--disable-dbgutil',
    '--disable-symbols',
    '--with-lang=en-US zh-CN zh-TW',
]

PYTHON_PROBE = (
    'import json, os, shutil, sys\n'
    'prefix = getattr(sys, "prefix", "")\n'
    'base_prefix = getattr(sys, "base_prefix", prefix)\n'
    'info = {"executable": sys.executable,\n'
    '        "whichPython3": shutil.which("python3") or "",\n'
    '        "prefix": prefix,\n'
    '        "basePrefix": base_prefix,\n'
    '        "baseExecutable": getattr(sys, "_base_executable", ""),\n'
    '        "pyvenvCfg": os.path.isfile(os.path.join(prefix, "pyvenv.cfg")),\n'
    '        "versions": {}}\n'
    'for name in ("lxml", "polib"):\n'
    '    try:\n'
    '        from importlib import metadata\n'
    '        info["versions"][name] = metadata.version(name)\n'
    '    except Exception:\n'
    '        info["versions"][name] = ""\n'
    'try:\n'
    '    import lxml  # noqa: F401\n'
    '    import polib  # noqa: F401\n'
    '    info["importsOk"] = True\n'
    'except Exception as error:\n'
    '    info["importsOk"] = False\n'
    '    info["importError"] = f"{type(error).__name__}: {error}"\n'
    'print(json.dumps(info))\n'
)


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


def default_python_bin():
    """The lexical bin directory of the running interpreter.

    A venv's ``bin/python`` is a symlink to the base interpreter, so
    ``Path(sys.executable).resolve().parent`` silently yields the *base* bin
    and would recreate the exact configure failure this driver fixes.  Keep
    the lexical absolute path and let ``verify_child_python`` prove the venv
    identity through ``sys.prefix``/``pyvenv.cfg``.
    """
    return os.path.dirname(os.path.abspath(sys.executable))


def child_environment(python_bin, base_env=None):
    """Environment for every phase subprocess.

    The prepared venv's bin directory is placed first on PATH so the exact
    upstream check ``/usr/bin/env python3 -c "import lxml"`` resolves to the
    pinned interpreter instead of the runner's bare python3.  The path is kept
    lexical (no realpath) so a symlinked venv bin stays first.
    """
    env = dict(os.environ if base_env is None else base_env)
    bin_dir = os.path.abspath(str(python_bin))
    existing = env.get('PATH') or os.defpath
    env['PATH'] = os.pathsep.join([bin_dir, existing])
    env['MAKE'] = shutil.which('gmake') or 'gmake'
    env['FLOE_OFFICE_PYTHON_BIN'] = bin_dir
    return env


def _same_directory(left, right):
    """Compare filesystem locations without following the final symlink.

    ``/var`` and ``/private/var`` (and similar aliases) are normalized by
    realpathing only the *directory*; the executable symlink itself is
    preserved so a venv bin is never collapsed into the base interpreter bin.
    """
    def normalize(value):
        return os.path.realpath(os.path.dirname(os.path.abspath(value)))
    return normalize(left) == os.path.realpath(os.path.abspath(right))


def _same_venv_root(prefix, python_bin):
    if not prefix:
        return False
    return (os.path.realpath(os.path.abspath(prefix))
            == os.path.realpath(str(Path(os.path.abspath(python_bin)).parent)))


def _default_probe_runner(command, env):
    result = subprocess.run([str(item) for item in command],
                            capture_output=True, text=True, env=env)
    return result.returncode, (result.stdout or '') + (result.stderr or '')


def verify_child_python(python_bin, runner=None, base_env=None):
    """Prove the phase-child ``python3`` is the prepared venv with pinned deps.

    Runs the probe through the prepared interpreter directly and through the
    exact mechanism configure.ac uses (``/usr/bin/env python3``), then checks
    the venv bin/root identity (sys.prefix, pyvenv.cfg -- never a realpath-only
    executable comparison, because a venv python is a symlink to the base one)
    and the pinned lxml/polib versions.  Any failure is returned in
    ``failures`` so a caller can fail before the expensive build.
    """
    runner = runner or _default_probe_runner
    python_bin = os.path.abspath(str(python_bin))
    env = child_environment(python_bin, base_env)
    failures = []
    report = {
        'pythonBin': python_bin,
        'expectedPython3': os.path.join(python_bin, 'python3'),
        'expectedVenvRoot': str(Path(python_bin).parent),
        'configureCheckCommand': CONFIGURE_PYTHON_CHECK,
        'pinnedPackages': dict(PINNED_PYTHON_PACKAGES),
        'failures': failures,
    }

    probes = {
        'direct': [str(Path(python_bin) / 'python3'), '-c', PYTHON_PROBE],
        'configure': ['/usr/bin/env', 'python3', '-c', PYTHON_PROBE],
    }
    parsed = {}
    for label, command in probes.items():
        code, output = runner(command, env)
        if code != 0:
            failures.append(f'{label} python probe exited {code}: {output.strip()[:300]}')
            continue
        try:
            parsed[label] = json.loads(output.strip().splitlines()[-1])
        except (ValueError, IndexError):
            failures.append(f'{label} python probe returned unparseable output: '
                            f'{output.strip()[:300]}')

    direct = parsed.get('direct', {})
    configure = parsed.get('configure', {})
    if direct.get('executable'):
        report['directInterpreter'] = direct['executable']
    if configure.get('whichPython3') or configure.get('executable'):
        report['configurePython3'] = configure.get('whichPython3') or configure.get('executable')
    for label, info in (('direct', direct), ('configure', configure)):
        if not info:
            continue
        if not info.get('importsOk'):
            failures.append(f'{label} python cannot import lxml/polib: '
                            f'{info.get("importError", "unknown error")}')
    for label, info in (('direct', direct), ('configure', configure)):
        versions = info.get('versions') or {}
        for name, pinned in PINNED_PYTHON_PACKAGES:
            if versions.get(name) != pinned:
                failures.append(f'{label} {name} version {versions.get(name)!r} '
                                f'!= pinned {pinned!r}')
    for label, info in (('direct', direct), ('configure', configure)):
        if not info:
            continue
        resolved = info.get('executable') if label == 'direct' else \
            (info.get('whichPython3') or info.get('executable'))
        if not resolved:
            failures.append(f'{label} did not report a python3 path')
        elif not _same_directory(resolved, python_bin):
            failures.append(f'{label} python3 {resolved} is not in the prepared '
                            f'venv bin {python_bin}')
        prefix = info.get('prefix') or ''
        base_prefix = info.get('basePrefix') or ''
        if not _same_venv_root(prefix, python_bin):
            failures.append(f'{label} sys.prefix {prefix!r} is not the prepared '
                            f'venv root {Path(python_bin).parent}')
        if not info.get('pyvenvCfg'):
            failures.append(f'{label} interpreter has no pyvenv.cfg; refusing a '
                            'non-venv python')
        if prefix and base_prefix and (
                os.path.realpath(os.path.abspath(prefix))
                == os.path.realpath(os.path.abspath(base_prefix))):
            failures.append(f'{label} interpreter is a base interpreter, not a venv')
    report['lxmlVersion'] = (configure.get('versions') or {}).get('lxml')
    report['polibVersion'] = (configure.get('versions') or {}).get('polib')
    report['passed'] = not failures
    return report


def preflight(build_root, source, python_bin=None, python_check=None):
    missing = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
    sdk = sdk_info()
    free = free_gib(build_root)
    check = python_check if python_check is not None else verify_child_python(
        python_bin or default_python_bin())
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
        'pythonCheckCommand': CONFIGURE_PYTHON_CHECK,
        'pythonBin': check.get('pythonBin'),
        'directPython': check.get('directInterpreter'),
        'resolvedPython3': check.get('configurePython3'),
        'lxmlVersion': check.get('lxmlVersion'),
        'polibVersion': check.get('polibVersion'),
        'pinnedPythonPackages': dict(PINNED_PYTHON_PACKAGES),
        'pythonEnvironmentReady': bool(check.get('passed')),
        'pythonEnvironmentFailures': list(check.get('failures', [])),
        'nativeBuildPassed': False,
        'preflightPassed': (
            not missing and bool(sdk['sdkPath']) and free >= MINIMUM_FREE_GIB
            and bool(check.get('passed'))),
    }
    if not (source / 'engine/configure.ac').is_file():
        report['preflightPassed'] = False
        report['sourceError'] = 'pinned source not prepared'
    return report


def phase_plan(mode):
    if mode == 'engine':
        return list(ENGINE_PHASES)
    if mode == 'editor':
        return list(EDITOR_PHASES)
    if mode == 'all':
        return list(ENGINE_PHASES) + list(EDITOR_PHASES)
    raise ValueError(f'unknown phase mode: {mode}')


def resume_phase_plan(resume_report):
    """A resumed build never re-enters engine-configure/engine-build."""
    if not resume_report:
        return None
    plan = list(EDITOR_PHASES)
    overlap = sorted(set(plan) & set(ENGINE_PHASES))
    if overlap:
        raise RuntimeError(f'resume plan would rerun engine phases: {overlap}')
    return plan


def run_phase(name, cwd, command, qualification_path, log_dir, env=None):
    """Run one phase under the disk-reserve watchdog; fail fast on reserve."""
    report = json.loads(Path(qualification_path).read_text())
    report['stage'] = name
    started = time.time()
    Path(qualification_path).write_text(json.dumps(report, indent=2))
    log_path = Path(log_dir) / f'{name}.log'
    full_env = child_environment(default_python_bin()) if env is None else env
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


def build(build_root, python_bin=None, mode='all', python_runner=None,
          phase_runner=None, phase_commands=None):
    build_root = Path(build_root).resolve()
    build_root.mkdir(parents=True, exist_ok=True)
    source = build_root / 'source'
    log_dir = build_root / 'qualification-logs'
    log_dir.mkdir(parents=True, exist_ok=True)
    qualification_path = build_root / 'qualification.json'
    phase_runner = phase_runner or run_phase

    if qualification_path.exists():
        report = json.loads(qualification_path.read_text())
    else:
        report = {}
    head = subprocess.run(['git', '-C', str(source), 'rev-parse', 'HEAD'],
                          capture_output=True, text=True, check=True).stdout.strip()
    check = verify_child_python(python_bin or default_python_bin(),
                                runner=python_runner)
    fresh = preflight(build_root, source, python_bin=python_bin,
                      python_check=check)
    report.update(fresh)
    report['commit'] = head
    if not report.get('preflightPassed'):
        qualification_path.write_text(json.dumps(report, indent=2))
        raise RuntimeError(f'preflight failed: {json.dumps(report, indent=2)}')

    resume_report = load_resume_report(build_root)
    plan = resume_phase_plan(resume_report) or phase_plan(mode)
    if mode == 'editor' and not resume_report and \
            not report.get('engineBuildCompleted'):
        raise RuntimeError(
            'editor phases require a completed engine build in this build root '
            '(engineBuildCompleted) or a validated completed-core checkpoint '
            'resume; refusing to run editor configure without one')
    if resume_report:
        report['resumedFromCheckpoint'] = {
            'checkpointKind': resume_report.get('checkpointKind'),
            'checkpointSHA256': resume_report.get('checkpointSHA256'),
            'sourceCommit': resume_report.get('sourceCommit'),
            'archive': resume_report.get('archive'),
            'engineConfigureRerun': False,
            'engineBuildRerun': False,
        }
    report['phasePlan'] = plan
    report['enginePhasesRerun'] = any(name in plan for name in ENGINE_PHASES)
    qualification_path.write_text(json.dumps(report, indent=2))

    engine_dir = source / 'engine'
    editor_configure_args = [
        '--enable-iosapp',
        f'--with-app-name={HOST_APP_NAME}',
        f'--with-app-package-name={HOST_BUNDLE_ID}',
        '--enable-experimental',
        f'--with-vendor={HOST_VENDOR}',
        f'--with-lo-builddir={engine_dir}',
    ]
    commands = {
        'engine-configure': (engine_dir,
                             ['perl', './autogen.sh', *ENGINE_CONFIGURE_ARGS]),
        'engine-build': (engine_dir, ['gmake', '-j2']),
        'editor-autogen': (source, ['./autogen.sh']),
        'editor-configure': (source, ['./configure', *editor_configure_args]),
        'editor-build': (source, ['gmake', '-j2']),
    }
    if phase_commands is not None:
        commands.update(phase_commands)
    phase_env = child_environment(python_bin or default_python_bin())
    for name in plan:
        if name == 'editor-autogen':
            # Check at the engine/editor boundary: a fresh --phases all must
            # first let engine-build create these inputs. Editor-only/resumed
            # runs still refuse before invoking any editor subprocess.
            missing_inputs = [relative for relative in EDITOR_CONFIGURE_INPUTS
                              if not (build_root / relative).is_file()]
            if missing_inputs:
                raise RuntimeError(
                    'editor phases require engine outputs that are missing: '
                    + ', '.join(missing_inputs))
        cwd, command = commands[name]
        phase_runner(name, cwd, command, qualification_path, log_dir, phase_env)

    if 'engine-build' in plan:
        report = json.loads(qualification_path.read_text())
        report['engineBuildCompleted'] = True
        report['nativeBuildPassed'] = False
        qualification_path.write_text(json.dumps(report, indent=2))

    if 'editor-build' in plan:
        manifest = engine_dir / 'workdir/CustomTarget/ios/ios-all-static-libs.list'
        if not manifest.is_file() or not manifest.read_text().strip():
            raise RuntimeError('missing engine static archive manifest')
        report = json.loads(qualification_path.read_text())
        report['nativeBuildPassed'] = True
        report['nativeArchiveManifest'] = str(manifest)
        qualification_path.write_text(json.dumps(report, indent=2))
    return json.loads(qualification_path.read_text())


def run_preflight_only(build_root, python_bin, output=None):
    build_root = Path(build_root).resolve()
    source = build_root / 'source'
    check = verify_child_python(python_bin or default_python_bin())
    report = preflight(build_root, source, python_bin=python_bin,
                       python_check=check)
    if output:
        output = Path(output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return 0 if report['preflightPassed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build_root')
    parser.add_argument('--python-bin', default=None,
                        help='Directory of the prepared venv (child PATH binding)')
    parser.add_argument('--phases', choices=('engine', 'editor', 'all'),
                        default='all',
                        help='Which half of the build to run (workflow splits '
                             'engine from editor to checkpoint the core)')
    parser.add_argument('--preflight-only', action='store_true',
                        help='Cheap dependency/toolchain/disk preflight; no build')
    parser.add_argument('--output', default=None,
                        help='Write the preflight report here (--preflight-only)')
    args = parser.parse_args()
    if args.preflight_only:
        raise SystemExit(run_preflight_only(args.build_root, args.python_bin,
                                            args.output))
    print(json.dumps(build(args.build_root, python_bin=args.python_bin,
                           mode=args.phases), indent=2))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, CheckpointError) as error:
        print(f'BUILD FAILED: {error}', file=sys.stderr)
        sys.exit(1)
