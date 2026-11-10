#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Build/run macOS arm64 networking component tests; no App or guest boot."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

HERE = Path(__file__).resolve().parent
FLOE = HERE.parents[1]
ENGINE = FLOE / 'ThirdParty/ARM64EMU'
VENDOR = FLOE / 'Vendor/FloeSlirp'
SLICE = VENDOR / 'FloeSlirp.xcframework/macos-arm64'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path, help='fresh build/output directory')
    parser.add_argument('--jobs', type=int, default=6, choices=range(1, 7))
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    (out / 'objects').mkdir()
    (out / 'backend').mkdir()
    inputs = {str(p): sha(p) for root in [ENGINE, VENDOR, HERE]
              for p in root.rglob('*') if p.is_file() and '__pycache__' not in p.parts}
    commands = []
    started = time.monotonic()
    result = {'status': 'failed', 'scope': 'macOS component host only; no Linux/App/Simulator/M1',
              'jobs': args.jobs, 'inputs': inputs}

    def run(command, log):
        command = list(map(str, command))
        commands.append(command)
        ran = subprocess.run(command, capture_output=True, text=True)
        log.write_text(ran.stdout + ran.stderr)
        if ran.returncode:
            raise RuntimeError(f'exit {ran.returncode}: see {log}')

    try:
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        cc = ['xcrun', '--sdk', 'macosx', 'clang']
        flags = ['-target', 'arm64-apple-macos15.0', '-isysroot', sdk, '-O2', '-g',
                 '-std=c11', '-UNDEBUG', '-fvisibility=hidden', '-fno-math-errno',
                 '-D_POSIX_C_SOURCE=200809L', '-D_DARWIN_C_SOURCE',
                 '-DG_INTL_STATIC_COMPILATION', '-DPCRE2_STATIC',
                 '-DSLIRP_FLOE_HOST_HOOKS', '-DVN_ADVERTISE_RX_GSO=0']
        for inc in [ENGINE/'include', ENGINE/'Source/src', ENGINE/'Source/src/net',
                    ENGINE/'Bridge', SLICE/'Headers', HERE, HERE/'backend']:
            flags += ['-I', str(inc)]
        libs = [SLICE/'FloeSlirp-macos.a', '-framework', 'Foundation', '-framework',
                'Security', '-framework', 'CoreFoundation', '-framework', 'AppKit',
                '-framework', 'Carbon', '-lresolv', '-liconv', '-lm', '-lobjc']
        units = sorted((ENGINE/'Sources').glob('*.c'))
        assert len(units) == 30

        def compile_unit(source):
            run(cc+flags+['-c', source, '-o', out/'objects'/(source.stem+'.o')],
                out/'objects'/(source.stem+'.log'))

        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            list(pool.map(compile_unit, units))
        objects = [p for p in sorted((out/'objects').glob('*.o'))
                   if p.stem not in ['23_runtime', '24_parallel_runtime', '25_virtio_net']]
        assert len(objects) == 27
        run(cc+flags+[HERE/'QueueCompletionTests.c', *objects, *libs,
                      '-o', out/'QueueCompletionTests'], out/'queue-link.log')
        run([out/'QueueCompletionTests', out], out/'queue-run.log')
        assert 'HELD_TAIL_SUITE_OK' in (out/'queue-run.log').read_text()
        test_flags = flags+['-DFLOE_USERNET_TEST_HOOKS']
        backend_objects = []
        for source in [ENGINE/'Source/src/net'/('usernet_'+n+'.c') for n in ['core', 'poll', 'host']]+[HERE/'backend/guest_frame.c']:
            obj = out/'backend'/(source.stem+'.o')
            run(cc+test_flags+['-c', source, '-o', obj], out/'backend'/(source.stem+'-compile.log'))
            backend_objects.append(obj)
        for name in ['test_backend', 'test_waitset', 'test_ceiling', 'test_nat64']:
            binary = out/'backend'/name
            run(cc+test_flags+[HERE/'backend'/(name+'.c'), *backend_objects, *libs,
                               '-o', binary], out/'backend'/(name+'-link.log'))
            run([binary], out/'backend'/(name+'-run.log'))
        assert all(sha(Path(p)) == digest for p, digest in inputs.items()), 'input drift'
        result['status'] = 'passed'
        result['engineTranslationUnits'] = 30
        result['executablesRun'] = 5
        print('NETWORK_COMPONENTS_OK queue/oracle + backend/wait/ceiling/NAT64-mechanism')
    except Exception as error:
        result['error'] = str(error)
        raise
    finally:
        result.update(seconds=time.monotonic()-started, commands=commands)
        (out/'RESULT.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
