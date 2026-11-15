#!/usr/bin/env python3
"""Prepare the pinned official RPG Maker MV CoreScript resource.

Reads an existing checkout only; writes a new prepared resource. `--check` is
read-only. The prepared runtime is MIT CoreScript plus reviewed MIT web libs;
no RTP, editor asset, MZ runtime or game data is copied.
"""
import argparse, hashlib, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
import make_resource_manifest as mrm

PIN = '182e31449707ba7e406db0485c44c2a9d11e2dcd'
CORE = ['rpg_core', 'rpg_managers', 'rpg_objects', 'rpg_scenes', 'rpg_sprites', 'rpg_windows']
EXPECTED = {
    'rpg_core.js': 'cce476804212b28049fef8b5c117577d0e356eac4abe33804628931e1826dd41',
    'rpg_managers.js': 'aef81821786b12a3c27f8db510089663f6c2aabb1b1708dd065f765f3d1f9c18',
    'rpg_objects.js': 'd4278c2161193d9105787ee6b1ff5167c07ed23af4deef190b7705a326f1926e',
    'rpg_scenes.js': 'b10b50dcb62793e42fd807fa3034fb82a89c6cb7ab32afafbb366d6d0a7f248a',
    'rpg_sprites.js': '3b434c9b81c4081d00dd9eca3900fe7564545c6b5a70e3b00cd263de4170a4c8',
    'rpg_windows.js': '81343a9b3fb1c957f1c6098776f8ca263aac8431f3996b647caab36d6a03c5f3',
}

def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

def verify_checkout(checkout):
    result = subprocess.run(['git', '-C', str(checkout), 'rev-parse', 'HEAD'],
                            capture_output=True, text=True, check=False)
    if result.returncode != 0 or result.stdout.strip() != PIN:
        raise SystemExit(f'checkout HEAD mismatch: expected {PIN}, got {result.stdout.strip()!r}')

def build(checkout, output):
    for name in CORE:
        order = json.loads((checkout / f'{name}.json').read_text())
        parts = []
        for rel in order:
            if not rel.startswith(f'js/{name}/') or not rel.endswith('.js'):
                raise SystemExit('invalid module order entry: ' + rel)
            parts.append((checkout / rel).read_bytes())
        (output / 'js').mkdir(parents=True, exist_ok=True)
        (output / 'js' / 'libs').mkdir(parents=True, exist_ok=True)
        (output / 'js' / f'{name}.js').write_bytes(b'\n'.join(parts))
    for src in sorted((checkout / 'js' / 'libs').glob('*.js')):
        shutil.copy2(src, output / 'js' / 'libs' / src.name)
    licenses = Path(__file__).resolve().parent / 'Licenses' / 'RPGMakerMV'
    (output / 'licenses').mkdir(parents=True, exist_ok=True)
    for src in licenses.iterdir():
        if src.is_file(): shutil.copy2(src, output / 'licenses' / src.name)
    (output / 'README-PREPARED.md').write_text(
        '# Prepared RPG Maker MV CoreScript v1.3b\n\n'
        f'- Upstream: https://github.com/rpgtkoolmv/corescript\n- Commit: `{PIN}`\n'
        '- License: MIT (KADOKAWA CORPORATION./YOJI OJIMA); vendored libraries retain MIT notices.\n'
        '- Dist files were concatenated from the pinned module order with exact SHA-256 checks.\n'
        '- No RTP, editor asset, MZ runtime or sample game data is included.\n', encoding='utf-8')
    for name, expected in EXPECTED.items():
        actual = sha(output / 'js' / name)
        if actual != expected:
            raise SystemExit(f'built hash mismatch {name}: {actual}')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--checkout', required=True)
    ap.add_argument('--output', required=True)
    ap.add_argument('--manifest', required=True)
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--force', action='store_true')
    args = ap.parse_args()
    checkout = Path(args.checkout).resolve()
    output = Path(args.output).resolve()
    manifest = Path(args.manifest).resolve()
    if args.check:
        mrm.check(output, manifest)
        print('OK RPG Maker MV CoreScript prepared resource')
        return
    verify_checkout(checkout)
    if output.exists():
        if not args.force: raise SystemExit('output exists; use --force')
        shutil.rmtree(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.floe-mv-', dir=output.parent))
    try:
        build(checkout, stage)
        os.replace(stage, output)
    finally:
        if stage.exists(): shutil.rmtree(stage)
    mrm.write(output, manifest, 'rpg-maker-mv-corescript-1.3b',
              'rpg-maker-mv-corescript', 'rpgMakerMV', '1.3b',
              'rpg-maker-mv-corescript',
              ['Official KADOKAWA/YOJI OJIMA CoreScript v1.3b, commit ' + PIN + ', MIT.',
               'No RTP, editor assets, MZ runtime or sample game data are included.'])
    print('WROTE', output)

if __name__ == '__main__':
    main()
