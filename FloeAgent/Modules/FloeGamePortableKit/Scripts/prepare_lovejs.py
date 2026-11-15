#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Prepare the pinned love.js 11.4.1 npm distribution and compatibility runtime.

Requires network for the first download/`npm ci`; `--check` is read-only. The
prepared CLI is a build tool for the host's existing jobs service; the package
never executes it as a game runtime.
"""
import argparse, hashlib, json, os, shutil, subprocess, sys, tarfile, tempfile, urllib.request
from pathlib import Path
import make_resource_manifest as mrm
import patch_love_persistence

TARBALL_SHA = '9eb2db1f789254faed8e5cf7eeeded46a7e56ecbc931c88be809526c448d25fb'
URL = 'https://registry.npmjs.org/love.js/-/love.js-11.4.1.tgz'
EXPECTED = {
    'runtime/compat/love.js': '12db012a5cf4e0661f9eaf154c4c10c3cba7a7db31e6a36856028bbaf5f942f0',
    'runtime/compat/love.wasm': 'ecc9e098bb8af918d20fbe3f26d23495c5184ff6b5d203d2e4b27bf17a771d6f',
    'runtime/release/love.js': 'eb20a4d947dc99e08e906e946c5b783e3f542f60a3107167a1e92d07bfe531d4',
    'runtime/release/love.wasm': 'f9302c4034de06ead29f6526cc0c61dc73f7fdf7368edb3f568332af587cacf2',
    'runtime/release/love.worker.js': '720c1d0160a6fc61c2a7deda7462310eaacdbad5cd559aba46976dfb7dcd4627',
}

def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

def download(cache, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.is_file() or sha(path) != TARBALL_SHA:
        with urllib.request.urlopen(URL, timeout=120) as response, open(path, 'wb') as out:
            shutil.copyfileobj(response, out)
    if sha(path) != TARBALL_SHA:
        raise SystemExit('love.js tarball hash mismatch')

def safe_extract(tar, dest):
    for member in tar.getmembers():
        name = member.name
        if name.startswith('/') or '..' in Path(name).parts or member.issym() or member.islnk():
            raise SystemExit('unsafe tar member: ' + name)
    tar.extractall(dest)

def build(cache, stage):
    tarball = cache / 'love.js-11.4.1.tgz'
    download(cache, tarball)
    with tempfile.TemporaryDirectory(prefix='floe-love-') as td:
        with tarfile.open(tarball, 'r:gz') as tar:
            safe_extract(tar, td)
        package = Path(td) / 'package'
        lock = Path(__file__).resolve().parent / 'lovejs-package-lock.json'
        if not lock.is_file():
            raise SystemExit('pinned love.js package-lock.json is missing')
        shutil.copy2(lock, package / 'package-lock.json')
        env = dict(os.environ, npm_config_cache=str(cache / 'npm-cache'))
        result = subprocess.run(['npm', 'ci', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund',
                                 '--cache', str(cache / 'npm-cache')],
                                cwd=package, env=env, capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit('npm ci failed: ' + (result.stderr or result.stdout)[-2000:])
        # CLI and its pinned production dependency tree.
        (stage / 'cli').mkdir(parents=True, exist_ok=True)
        for name in ['index.js', 'package.json', 'package-lock.json', 'LICENSE', 'readme.md']:
            shutil.copy2(package / name, stage / 'cli' / name)
        shutil.copytree(package / 'node_modules', stage / 'cli' / 'node_modules')
        shutil.copytree(package / 'src', stage / 'cli' / 'src')
        # Both upstream runtimes are retained; the compatibility one is used by default.
        for flavor in ['compat', 'release']:
            target = stage / 'runtime' / flavor
            target.mkdir(parents=True, exist_ok=True)
            for name in ['love.js', 'love.wasm', 'index.html']:
                shutil.copy2(package / 'src' / flavor / name, target / name)
            if (package / 'src' / flavor / 'love.worker.js').is_file():
                shutil.copy2(package / 'src' / flavor / 'love.worker.js', target / 'love.worker.js')
            shutil.copytree(package / 'src' / flavor / 'theme', target / 'theme')
        node = subprocess.run(['node', '--version'], capture_output=True, text=True).stdout.strip()
        npm = subprocess.run(['npm', '--version'], capture_output=True, text=True).stdout.strip()
        (stage / 'cli' / 'toolchain.json').write_text(json.dumps({'node': node, 'npm': npm,
            'tarballSHA256': TARBALL_SHA, 'lockSHA256': sha(lock)}, sort_keys=True) + '\n')
    licenses = Path(__file__).resolve().parent / 'Licenses' / 'LOVE'
    (stage / 'licenses').mkdir(parents=True, exist_ok=True)
    for src in licenses.iterdir():
        if src.is_file(): shutil.copy2(src, stage / 'licenses' / src.name)
    (stage / 'README-PREPARED.md').write_text(
        '# Prepared love.js 11.4.1 — Floe distribution profile\n\n'
        f'- npm tarball SHA-256: `{TARBALL_SHA}`\n'
        '- Source commit: `8f9a7b85da9149b6d4d0af46442ead1e71f76477` (npm gitHead; the WASM is byte-identical, text is CRLF-normalized).\n'
        '- Compatibility runtime: LÖVE 11.4.0, single-threaded; release variant retained.\n'
        '- mpg123 1.25.6 is LGPL-2.1; exact source, vendor delta and relink path are in `licenses/LOVE-11.4-COMPONENT-ADDENDUM.md`.\n'
        '- OpenAL Soft and LuaJIT are named by LÖVE but are not linked here; see the addendum.\n'
        '- `cli/` is the upstream tool with pinned production dependencies; it is build tooling, not a game runtime.\n'
        '- The unpatched loader flushes IDBFS only on beforeunload; Root\'s patched floePrepareToStop candidate passed actual native WebKit cross-player save.\n', encoding='utf-8')
    for rel, expected in EXPECTED.items():
        actual = sha(stage / rel)
        if actual != expected:
            raise SystemExit(f'runtime hash mismatch {rel}: {actual}')
    # Verify exact upstream bytes first, then apply the separately supplied
    # readable MPL addition only to the supported single-threaded variant.
    # The CLI copies its own src/compat loader when assembling a game, so both
    # copies must contain the same acknowledged-close hook.
    modifications = [patch_love_persistence.patch_file(stage / path) for path in
                     ['runtime/compat/love.js', 'cli/src/compat/love.js']]
    for item in modifications:
        item['file'] = str(Path(item['file']).relative_to(stage))
    (stage / 'runtime-patches.json').write_text(json.dumps(modifications, indent=2) + '\n')
    shutil.copy2(Path(__file__).resolve().parent.parent / 'LICENSE', stage / 'licenses/FLOE-MPL-2.0.txt')
    shutil.copy2(Path(patch_love_persistence.__file__), stage / 'licenses/FLOE-love_persistence_patch.py')
    (stage / 'licenses/FLOE-PERSISTENCE-NOTICE.txt').write_text(
        'The readable Floe acknowledged-close addition and patch tool are MPL-2.0.\n'
        'Original generated loader code retains upstream MIT/NCSA terms and notices.\n'
        'Original WASM bytes are unchanged. Only the compatibility variant is patched\n'
        'and behavior-qualified; the retained upstream pthread variant is not claimed\n'
        'as working in this iOS WebKit profile. See runtime-patches.json.\n')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cache', required=True)
    ap.add_argument('--output', required=True)
    ap.add_argument('--manifest', required=True)
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--force', action='store_true')
    args = ap.parse_args()
    cache = Path(args.cache).resolve(); output = Path(args.output).resolve()
    manifest = Path(args.manifest).resolve()
    if args.check:
        mrm.check(output, manifest)
        print('OK love.js prepared resource')
        return
    if output.exists():
        if not args.force: raise SystemExit('output exists; use --force')
        shutil.rmtree(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.floe-love-out-', dir=output.parent))
    try:
        build(cache, stage)
        os.replace(stage, output)
    finally:
        if stage.exists(): shutil.rmtree(stage)
    mrm.write(output, manifest, 'lovejs-11.4.1', 'lovejs', 'love', '11.4.1', 'lovejs',
              ['npm love.js@11.4.1 sha256 ' + TARBALL_SHA + '; npm gitHead 8f9a7b85da9149b6d4d0af46442ead1e71f76477.',
               'WASM byte-identical to the public source commit; text files are CRLF-normalized copies.',
               'LÖVE 11.4.0 compatibility runtime, single-threaded; release variant retained.',
               'mpg123 1.25.6 LGPL-2.1 is statically linked; exact source/relink in licenses/LOVE-11.4-COMPONENT-ADDENDUM.md.',
               'OpenAL Soft and LuaJIT are named by LÖVE but are not linked in this Emscripten build.',
               'Compatibility loader includes the source-supplied MPL acknowledged-close addition; upstream bytes checked before patching.',
               'Actual compatibility WebKit save/read across a fresh player is qualified; retained pthread runtime is not claimed iOS-ready.'])
    print('WROTE', output)

if __name__ == '__main__':
    main()
