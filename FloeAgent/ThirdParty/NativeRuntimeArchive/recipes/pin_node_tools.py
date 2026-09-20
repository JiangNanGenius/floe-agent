#!/usr/bin/env python3
"""Fetch pinned Node artifacts; verify archive and installed bytes without changing the lock."""
import argparse, hashlib, json, pathlib, shutil, subprocess, tarfile, tempfile, zipfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
LOCK = pathlib.Path(__file__).with_name('node_tools.lock.json')
CACHE = ROOT / 'Vendor/NodeMobile/cache'
RESOURCES = ROOT / 'FloeApp/Resources/NodeTools'
def digest(data):
    return hashlib.sha256(data).hexdigest()
def safe_name(name):
    path = pathlib.PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or '\\' in name or '\x00' in name:
        raise ValueError(f'Unsafe archive member: {name}')
    return path

def members(archive, runtime):
    if runtime:
        with zipfile.ZipFile(archive) as source:
            for member in source.infolist():
                path = safe_name(member.filename)
                if not path.parts or path.parts[0] != 'NodeMobile.xcframework' or member.is_dir():
                    continue
                if (member.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError('Framework archive contains symlinks')
                yield pathlib.PurePosixPath(*path.parts[1:]), source.read(member), (member.external_attr >> 16) & 0o777
    else:
        with tarfile.open(archive, 'r:gz') as source:
            for member in source:
                path = safe_name(member.name)
                if not path.parts or path.parts[0] != 'package':
                    raise ValueError('Unexpected package archive root')
                if member.isdir(): continue
                if not member.isfile(): raise ValueError('Package archive contains non-regular files')
                yield pathlib.PurePosixPath(*path.parts[1:]), source.extractfile(member).read(), member.mode & 0o777

def process(entry, runtime, check):
    archive = CACHE / pathlib.PurePosixPath(entry['url']).name
    destination = ROOT / 'Vendor/NodeMobile/NodeMobile.xcframework' if runtime else RESOURCES / entry['name']
    if not archive.is_file():
        if check: raise ValueError(f'Missing pinned archive: {archive}')
        CACHE.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=CACHE, delete=False) as temporary: temporary_path = pathlib.Path(temporary.name)
        try:
            subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error', entry['url'], '-o', str(temporary_path)], check=True)
            if digest(temporary_path.read_bytes()) != entry['sha256']: raise ValueError(f'Digest mismatch: {entry["name"]}')
            temporary_path.replace(archive)
        finally: temporary_path.unlink(missing_ok=True)
    if digest(archive.read_bytes()) != entry['sha256']: raise ValueError(f'Digest mismatch: {entry["name"]}')
    if check:
        expected = set()
        for relative, data, _ in members(archive, runtime):
            target = destination / relative
            expected.add(relative.as_posix())
            if target.is_symlink() or not target.is_file() or digest(target.read_bytes()) != digest(data):
                raise ValueError(f'Installed artifact mismatch: {target}')
        actual = {p.relative_to(destination).as_posix() for p in destination.rglob('*') if p.is_file() or p.is_symlink()}
        if actual != expected: raise ValueError(f'Unexpected installed files: {destination}')
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=destination.parent, prefix='.node-stage-') as temporary:
            staging = pathlib.Path(temporary) / 'payload'; staging.mkdir()
            for relative, data, mode in members(archive, runtime):
                target = staging / relative; target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data); target.chmod(mode or 0o644)
            previous = pathlib.Path(temporary) / 'previous'
            if destination.exists(): destination.rename(previous)
            try: staging.rename(destination)
            except BaseException:
                if previous.exists(): previous.rename(destination)
                raise
    print(f'{"Verified" if check else "Installed"} {entry["name"]} {entry["version"]}')

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--check', action='store_true'); args = parser.parse_args()
    before = LOCK.read_bytes(); lock = json.loads(before)
    license = lock['runtime']['license']
    if digest((RESOURCES / license['file']).read_bytes()) != license['sha256']:
        raise ValueError('Bundled Node license does not match the reviewed source')
    process(lock['runtime'], True, args.check)
    for entry in lock['tools']: process(entry, False, args.check)
    if LOCK.read_bytes() != before: raise ValueError('Lock changed during verification')
if __name__ == '__main__': main()
