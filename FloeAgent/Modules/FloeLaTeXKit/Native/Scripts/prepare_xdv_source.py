#!/usr/bin/env python3
"""Read-only source verification, or explicit preparation of the pinned XDV fork."""
from pathlib import Path, PurePosixPath
import argparse, hashlib, json, os, shutil, subprocess, tarfile, tempfile, urllib.request

NATIVE = Path(__file__).resolve().parents[1]
REVISION = '8c0126a9653239a2e6e0a5274af9b8510f643030'
ARCHIVE_SHA256 = '980f2862937cc084eae921ade500c0390c9ae196e973636e0e1b13f5c9479f01'
ARCHIVE_URL = 'https://codeload.github.com/tectonic-typesetting/tectonic/tar.gz/'+REVISION
IGNORED = {'.git', 'target', '__pycache__', '.DS_Store'}

def sha(data): return hashlib.sha256(data).hexdigest()
def file_sha(path): return sha(path.read_bytes())
def safe_relative(value):
    path = PurePosixPath(value)
    if path.is_absolute() or '..' in path.parts or not path.parts or '\\' in value:
        raise RuntimeError('Invalid relative source identity')
    return Path(*path.parts)

def load_inputs():
    metadata = json.loads((NATIVE/'tectonic.source.json').read_text())
    manifest_path = NATIVE/'patches/production-xdv-source-manifest.json'
    local_path = NATIVE/'patches/production-xdv-local-sources.json'
    if file_sha(manifest_path) != metadata['productionSourceManifestSHA256']:
        raise RuntimeError('Pinned upstream/source manifest changed')
    if file_sha(local_path) != metadata['productionLocalSourcesSHA256']:
        raise RuntimeError('Pinned local source manifest changed')
    manifest = json.loads(manifest_path.read_text())
    upstream = manifest['upstream']
    if upstream['revision'] != REVISION or upstream['archiveURL'] != ARCHIVE_URL or upstream['archiveSHA256'] != ARCHIVE_SHA256:
        raise RuntimeError('Only the reviewed upstream revision/archive is accepted')
    patch = NATIVE/safe_relative(manifest['patchFile'])
    if file_sha(patch) != manifest['patchSHA256']:
        raise RuntimeError('Complete production source patch changed')
    local = json.loads(local_path.read_text())
    for directory in local['exactDirectories']:
        expected = {row['path'] for row in local['files'] if row['path'].startswith(directory+'/')}
        actual = {path.relative_to(NATIVE).as_posix() for path in (NATIVE/directory).rglob('*')
                  if path.is_file() and not any(part in IGNORED for part in path.relative_to(NATIVE/directory).parts)}
        if actual != expected: raise RuntimeError('Unreviewed local source file set: '+directory)
    for row in local['files']:
        path = NATIVE/safe_relative(row['path'])
        if not path.is_file() or path.is_symlink() or file_sha(path) != row['sha256']:
            raise RuntimeError('Local bridge/Apple/build input changed: '+row['path'])
    for row in manifest['files']: safe_relative(row['path'])
    return manifest, patch

def verify_tree(root, manifest, state):
    key = 'afterSHA256' if state == 'patched' else 'baseSHA256'
    expected = {row['path']:row[key] for row in manifest['files'] if row[key] is not None}
    if not root.is_dir(): raise RuntimeError('Pinned source tree is absent; use explicit --apply')
    actual = set()
    for path in root.rglob('*'):
        relative = path.relative_to(root)
        if any(part in IGNORED for part in relative.parts): continue
        if path.is_symlink(): raise RuntimeError('Source contains an unreviewed symbolic link: '+str(relative))
        if path.is_file(): actual.add(relative.as_posix())
    if actual != set(expected):
        missing = sorted(set(expected)-actual)
        extra = sorted(actual-set(expected))
        raise RuntimeError('Source file set differs: missing='+str(missing[:3])+', extra='+str(extra[:3]))
    for name, digest in expected.items():
        if file_sha(root/safe_relative(name)) != digest:
            raise RuntimeError('Source identity differs: '+name)
    return len(expected)

def archive_path(argument, allow_downloads):
    if argument is not None:
        path = argument.resolve()
        if not path.is_file() or file_sha(path) != ARCHIVE_SHA256:
            raise RuntimeError('Supplied upstream archive does not match the pinned digest')
        return path
    path = Path.home()/'Library/Caches/CodexBuild/FloeLaTeXXDV/main/Xcode27.2/upstream'/('tectonic-'+REVISION+'.tar.gz')
    if path.is_file() and file_sha(path) == ARCHIVE_SHA256: return path
    if not allow_downloads:
        raise RuntimeError('Supply --archive or explicitly allow the one pinned source download')
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.part')
    try:
        request = urllib.request.Request(ARCHIVE_URL, headers={'User-Agent':'Floe-source-reproduction/1'})
        with urllib.request.urlopen(request, timeout=60) as response, temporary.open('wb') as output:
            while True:
                data = response.read(1024*1024)
                if not data: break
                if output.tell()+len(data)>32*1024*1024: raise RuntimeError('Source archive exceeds bound')
                output.write(data)
        if file_sha(temporary) != ARCHIVE_SHA256: raise RuntimeError('Downloaded source archive digest mismatch')
        temporary.replace(path)
    finally: temporary.unlink(missing_ok=True)
    return path

def extract_archive(archive, root):
    prefix = 'tectonic-'+REVISION+'/'
    total = 0
    with tarfile.open(archive) as source:
        members = source.getmembers()
        if len(members)>10000: raise RuntimeError('Source archive entry bound exceeded')
        for member in members:
            if member.name == prefix[:-1]: continue
            if not member.name.startswith(prefix) or not (member.isfile() or member.isdir()):
                raise RuntimeError('Unexpected source archive entry')
            relative = safe_relative(member.name[len(prefix):])
            target = root/relative
            if member.isdir(): target.mkdir(parents=True, exist_ok=True); continue
            total += member.size
            if member.size>64*1024*1024 or total>128*1024*1024:
                raise RuntimeError('Expanded source archive exceeds bound')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.extractfile(member).read())
            target.chmod(member.mode & 0o777)

def apply_to_stage(root, manifest, patch):
    command = ['patch','-t','-N','-F','0','-p','1','-i',str(patch)]
    subprocess.run([*command,'--dry-run'], cwd=root, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    subprocess.run(command, cwd=root, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    for row in manifest['files']:
        if row['afterSHA256'] is not None: (root/safe_relative(row['path'])).chmod(int(row['afterMode'],8))
    verify_tree(root, manifest, 'patched')

def atomic_write(path, data, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.floe-source-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as output: output.write(data)
        Path(temporary).chmod(mode)
        os.replace(temporary,path)
    finally: Path(temporary).unlink(missing_ok=True)

def prepare(root, manifest, patch, archive, allow_downloads):
    if root.exists():
        try:
            verify_tree(root, manifest, 'patched')
            return 'already-patched'
        except RuntimeError: verify_tree(root, manifest, 'upstream')
        # Work only on reviewed changed files; preserve .git, caches, and every
        # unrelated file. No mutation happens until all patched bytes validate.
        with tempfile.TemporaryDirectory(prefix='floe-source-patch-',dir=root.parent) as temporary:
            stage = Path(temporary)
            changed = [row for row in manifest['files'] if row['baseSHA256']!=row['afterSHA256']]
            for row in changed:
                if row['baseSHA256'] is not None:
                    destination = stage/safe_relative(row['path'])
                    destination.parent.mkdir(parents=True,exist_ok=True)
                    shutil.copy2(root/safe_relative(row['path']),destination)
            command = ['patch','-t','-N','-F','0','-p','1','-i',str(patch)]
            subprocess.run([*command,'--dry-run'],cwd=stage,check=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            subprocess.run(command,cwd=stage,check=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            originals = []
            for row in changed:
                path = root/safe_relative(row['path'])
                data = path.read_bytes() if path.exists() else None
                if (sha(data) if data is not None else None) != row['baseSHA256']:
                    raise RuntimeError('Source changed during preparation')
                result = stage/safe_relative(row['path'])
                if (file_sha(result) if result.exists() else None) != row['afterSHA256']:
                    raise RuntimeError('Patch result differs from reviewed source')
                originals.append((path,data,path.stat().st_mode&0o777 if data is not None else 0o644))
            applied = []
            try:
                for row, original in zip(changed, originals):
                    path,data,mode = original
                    if (file_sha(path) if path.exists() else None) != row['baseSHA256']:
                        raise RuntimeError('Source changed before source commit')
                    if row['afterSHA256'] is None: path.unlink()
                    else: atomic_write(path,(stage/safe_relative(row['path'])).read_bytes(),int(row['afterMode'],8))
                    applied.append(original)
                verify_tree(root,manifest,'patched')
            except BaseException:
                for path,data,mode in reversed(applied):
                    if data is None: path.unlink(missing_ok=True)
                    else: atomic_write(path,data,mode)
                raise
        return 'patched-existing-upstream'
    source = archive_path(archive,allow_downloads)
    root.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.floe-pinned-source-',dir=root.parent) as temporary:
        stage = Path(temporary)/'tree'
        stage.mkdir()
        extract_archive(source,stage)
        verify_tree(stage,manifest,'upstream')
        apply_to_stage(stage,manifest,patch)
        if root.exists(): raise RuntimeError('Source target appeared during preparation')
        stage.rename(root)
    return 'prepared-from-pinned-archive'

def main():
    p = argparse.ArgumentParser()
    operation = p.add_mutually_exclusive_group(required=True)
    operation.add_argument('--check',action='store_true',help='Read only; never download, patch, or refresh metadata')
    operation.add_argument('--apply',action='store_true',help='Explicitly prepare the reviewed production source')
    p.add_argument('--source-root',type=Path,default=NATIVE/'tectonic')
    p.add_argument('--state',choices=['patched','upstream'],default='patched',help='Expected state for --check')
    p.add_argument('--archive',type=Path,help='Existing exact pinned upstream archive')
    p.add_argument('--allow-source-downloads',action='store_true',help='Allow only the fixed upstream archive when absent')
    a = p.parse_args()
    if a.check and (a.archive is not None or a.allow_source_downloads):
        p.error('--check never accepts download or apply inputs')
    manifest,patch = load_inputs()
    root = a.source_root.resolve()
    if a.check:
        count = verify_tree(root,manifest,a.state)
        print(json.dumps({'state':a.state,'files':count,'revision':REVISION,'mutation':False}))
    else:
        outcome = prepare(root,manifest,patch,a.archive,a.allow_source_downloads)
        print(json.dumps({'state':'patched','files':verify_tree(root,manifest,'patched'),'revision':REVISION,'operation':outcome}))

if __name__=='__main__': main()
