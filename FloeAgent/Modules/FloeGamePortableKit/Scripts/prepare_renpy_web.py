#!/usr/bin/env python3
"""Prepare the official Ren'Py 8.5.3 Web (Beta) support resource.

Downloads only on execution; `--check` is read-only. The SDK is optional and is
used by the official launcher build command, never as a product runtime.
"""
import argparse, hashlib, json, os, shutil, tarfile, tempfile, urllib.request, zipfile
from pathlib import Path
import make_resource_manifest as mrm

WEB_URL = 'https://www.renpy.org/dl/8.5.3/renpy-8.5.3-web.zip'
WEB_SHA = '954db897e65f51ea63cb2fb7b203d02be0447f4e22069514020bbe6c6691fdfc'
SDK_URL = 'https://www.renpy.org/dl/8.5.3/renpy-8.5.3-sdkarm.tar.bz2'
SDK_SHA = '0579782517f203ba3535dcc2dab54e34bfc318f2f2a7510a5130b6f809f901f6'

def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

def download(cache, url, name, expected):
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / name
    if not path.is_file() or sha(path) != expected:
        with urllib.request.urlopen(url, timeout=300) as response, open(path, 'wb') as out:
            shutil.copyfileobj(response, out)
    if sha(path) != expected:
        raise SystemExit('download hash mismatch: ' + name)
    return path

def safe_zip(path, dest):
    with zipfile.ZipFile(path) as archive:
        for info in archive.infolist():
            if info.filename.startswith('/') or '..' in Path(info.filename).parts:
                raise SystemExit('unsafe zip member: ' + info.filename)
        archive.extractall(dest)

def safe_tar(path, dest):
    with tarfile.open(path, 'r:bz2') as archive:
        for member in archive.getmembers():
            if member.name.startswith('/') or '..' in Path(member.name).parts or member.issym() or member.islnk():
                raise SystemExit('unsafe tar member: ' + member.name)
        archive.extractall(dest)

def build(cache, stage, sdk_output):
    web = download(cache, WEB_URL, 'renpy-8.5.3-web.zip', WEB_SHA)
    extracted = Path(tempfile.mkdtemp(prefix='floe-renpy-web-'))
    try:
        safe_zip(web, extracted)
        source = extracted / 'web'
        if not source.is_dir(): raise SystemExit('web support directory missing')
        shutil.copytree(source, stage / 'web')
    finally:
        shutil.rmtree(extracted, ignore_errors=True)
    licenses = Path(__file__).resolve().parent / 'Licenses' / 'RenPy'
    (stage / 'licenses').mkdir(parents=True, exist_ok=True)
    for src in licenses.iterdir():
        if src.is_file(): shutil.copy2(src, stage / 'licenses' / src.name)
    (stage / 'sdk-metadata.json').write_text(json.dumps({
        'schemaVersion': 1, 'version': '8.5.3.26051504',
        'sdkURL': SDK_URL, 'sdkSHA256': SDK_SHA,
        'webURL': WEB_URL, 'webSHA256': WEB_SHA,
        'buildCommand': "renpy.sh launcher web_build <project> --destination <out>"
    }, sort_keys=True) + '\n')
    (stage / 'README-PREPARED.md').write_text(
        '# Prepared Ren\'Py 8.5.3 Web (Beta) — Floe distribution profile\n\n'
        f'- Web support SHA-256: `{WEB_SHA}`\n'
        f'- SDK SHA-256: `{SDK_SHA}` (version 8.5.3.26051504)\n'
        '- Source pins: Ren\'Py `8.5.3.26051504` / `39895c1e017f0b36ffea2447d97eccd69d76ee1c`; build repository `7bfab40c1174f622f644b24669afd5fb167fbb79`.\n'
        '- Build route: `renpy.sh launcher web_build <project> --destination <out>`.\n'
        '- Runtime is single-threaded; networking and Python threading are unavailable.\n'
        '- LGPL components actually linked/embedded: FFmpeg 4.3.1, FriBidi 1.0.7, chardet 5.2.0, SDL_gfxPrimitives and pygame portions.\n'
        '- Complete corresponding source and relink route: `licenses/RENPY-8.5.3-COMPONENT-ADDENDUM.md`; publish with the binary or provide the LGPL 6(c) written offer.\n'
        '- Saves are engine-internal (IDBFS `/home/web_user/.renpy`); host persistence is required for durability.\n', encoding='utf-8')
    if sdk_output:
        sdk = download(cache, SDK_URL, 'renpy-8.5.3-sdkarm.tar.bz2', SDK_SHA)
        sdk_output = Path(sdk_output).resolve()
        if sdk_output.exists(): shutil.rmtree(sdk_output)
        sdk_output.parent.mkdir(parents=True, exist_ok=True)
        safe_tar(sdk, sdk_output.parent)
        # The archive extracts to its own top-level directory; rename if needed.
        candidates = [p for p in sdk_output.parent.iterdir() if p.is_dir() and p.name.startswith('renpy-8.5.3-sdkarm')]
        if len(candidates) == 1 and candidates[0] != sdk_output:
            if sdk_output.exists(): shutil.rmtree(sdk_output)
            candidates[0].rename(sdk_output)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cache', required=True)
    ap.add_argument('--output', required=True)
    ap.add_argument('--manifest', required=True)
    ap.add_argument('--sdk-output')
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--force', action='store_true')
    args = ap.parse_args()
    cache = Path(args.cache).resolve(); output = Path(args.output).resolve()
    manifest = Path(args.manifest).resolve()
    if args.check:
        mrm.check(output, manifest)
        print("OK Ren'Py prepared resource")
        return
    if output.exists():
        if not args.force: raise SystemExit('output exists; use --force')
        shutil.rmtree(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.floe-renpy-out-', dir=output.parent))
    try:
        build(cache, stage, args.sdk_output)
        os.replace(stage, output)
    finally:
        if stage.exists(): shutil.rmtree(stage)
    mrm.write(output, manifest, 'renpy-8.5.3-web', 'renpy-web', 'renpy', '8.5.3', 'renpy-web',
              ["Official renpy-8.5.3-web.zip sha256 " + WEB_SHA + '; SDK 8.5.3.26051504 sha256 ' + SDK_SHA + '.',
               'Source pins: renpy 39895c1e017f0b36ffea2447d97eccd69d76ee1c; renpy-build 7bfab40c1174f622f644b24669afd5fb167fbb79.',
               'Single-threaded Web (Beta) runtime; networking and Python threading are unavailable.',
               'LGPL FFmpeg 4.3.1, FriBidi 1.0.7, chardet 5.2.0, SDL_gfx and pygame portions; source/relink in licenses/RENPY-8.5.3-COMPONENT-ADDENDUM.md.',
               'Saves are engine-internal; host persistence is required for durability.'])
    print('WROTE', output)

if __name__ == '__main__':
    main()
