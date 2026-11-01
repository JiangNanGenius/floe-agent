#!/usr/bin/env python3
"""Read-only recipe checks, verified source preparation and native slice export."""
import argparse, hashlib, json, pathlib, plistlib, shutil, subprocess, tarfile, urllib.request

def sha(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()

def sources(root):
    paths=[p for p in root.rglob('*') if p.is_file() and '.git' not in p.parts and 'target' not in p.parts and (p.suffix in ('.rs','.toml') or p.name=='Cargo.lock' or p.relative_to(root).as_posix()=='ffi/plist.h')]
    return {p.relative_to(root).as_posix():sha(p) for p in sorted(paths)}

def source_digest(root):
    return hashlib.sha256(''.join(k+' '+v+'\n' for k,v in sources(root).items()).encode()).hexdigest()

def require(test, message):
    if not test: raise SystemExit('error: '+message)

def check(lock,project):
    require(lock['commit']=='d32c8189c51c2789496b0768039419c3705498c3','unexpected upstream pin')
    require(lock['release']=='v0.1.68' and lock['assetSHA256']=='c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7','upstream release input changed')
    recipe=lock['nativeDDI']
    require(sha(project/recipe['patch'])==recipe['patchSHA256'],'native patch SHA-256 mismatch')
    require(sha(project/'scripts/build_idevice.sh')==recipe['buildScriptSHA256'],'build recipe SHA-256 mismatch')
    if recipe.get('verifierSHA256'): require(sha(project/'Vendor/verify_idevice.py')==recipe['verifierSHA256'],'verifier SHA-256 mismatch')
    return recipe

def prepare(lock,recipe,project,scratch):
    scratch.mkdir(parents=True,exist_ok=True)
    archive=scratch/'upstream.tar.gz'
    if not archive.exists(): urllib.request.urlretrieve(recipe['sourceArchiveURL'],archive)
    require(sha(archive)==recipe['sourceArchiveSHA256'],'original source archive SHA-256 mismatch')
    root=scratch/'source'
    if not root.exists():
        temporary=scratch/'extract'
        require(not temporary.exists(),'previous extraction incomplete; inspect before retry')
        temporary.mkdir()
        with tarfile.open(archive) as tf:
            for member in tf.getmembers():
                p=pathlib.PurePosixPath(member.name)
                require(not p.is_absolute() and '..' not in p.parts and not member.islnk(),'unsafe archive member')
                if member.issym():
                    require(p.as_posix().endswith('/idevice/README.md') and member.linkname=='../README.md','unexpected archive symlink')
            tf.extractall(temporary)
        entries=list(temporary.iterdir()); require(len(entries)==1,'unexpected original archive layout')
        entries[0].rename(root); temporary.rmdir()
        subprocess.run(['/usr/bin/patch','-p1','--batch','--forward','--input',str((project/recipe['patch']).resolve())],cwd=root,check=True)
    require(source_digest(root)==recipe['patchedSourceSHA256'],'patched source SHA-256 mismatch')
    require(sha(root/'Cargo.lock')==recipe['cargoLockSHA256'],'Cargo.lock changed')

def verify_output(lock,recipe,dest):
    metadata=json.loads((dest/'.floe-native.json').read_text())
    for key in ['sourceArchiveSHA256','patchSHA256','patchedSourceSHA256','cargoLockSHA256']:
        require(metadata[key]==recipe[key],'export input binding mismatch: '+key)
    lib=dest/'ios-arm64/libidevice_ffi.a'; header=dest/'ios-arm64/Headers/idevice.h'
    require(sha(lib)==metadata['librarySHA256'],'patched library SHA-256 mismatch')
    require(sha(header)==metadata['headerSHA256'],'patched header SHA-256 mismatch')
    if recipe.get('librarySHA256'): require(sha(lib)==recipe['librarySHA256'],'library differs from qualified output')
    if recipe.get('headerSHA256'): require(sha(header)==recipe['headerSHA256'],'header differs from qualified output')
    return metadata

def export(lock,recipe,source,library,dest):
    require(source_digest(source)==recipe['patchedSourceSHA256'],'source drift during native build')
    header=source/'ffi/idevice.h'
    required=['floe_ddi_abi_version','floe_ddi_scope_begin','floe_ddi_scope_stop_reason','floe_ddi_scope_reconcile','floe_ddi_scope_end','cryptexd_install_ddi','image_mounter_mount_personalized_with_callback_rsd']
    sysroot=pathlib.Path(subprocess.check_output(['rustc','--print','sysroot'],text=True).strip())
    host=next(line.split(': ',1)[1] for line in subprocess.check_output(['rustc','-vV'],text=True).splitlines() if line.startswith('host: '))
    nm=sysroot/'lib/rustlib'/host/'bin/llvm-nm'
    require(nm.exists(),'rustup component add llvm-tools is required for matching Rust bitcode reader')
    symbols=subprocess.check_output([str(nm),'-g','--defined-only',str(library)],text=True)
    for symbol in required:
        require(symbol in header.read_text(),'header ABI missing '+symbol)
        require('_'+symbol in symbols,'library ABI missing '+symbol)
    require('arm64' in subprocess.check_output(['lipo','-info',str(library)],text=True),'library is not arm64')
    dest.mkdir(parents=True,exist_ok=True); slice=dest/'ios-arm64'; headers=slice/'Headers'; headers.mkdir(parents=True,exist_ok=True)
    shutil.copy2(library,slice/'libidevice_ffi.a'); shutil.copy2(header,headers/'idevice.h')
    (headers/'module.modulemap').write_text('module IDevice {\n  header "idevice.h"\n  export *\n}\n')
    with open(dest/'Info.plist','wb') as f: plistlib.dump({'AvailableLibraries':[{'LibraryIdentifier':'ios-arm64','LibraryPath':'libidevice_ffi.a','HeadersPath':'Headers','SupportedArchitectures':['arm64'],'SupportedPlatform':'ios'}],'CFBundlePackageType':'XFWK','XCFrameworkFormatVersion':'1.0'},f)
    metadata={k:recipe[k] for k in ['sourceArchiveSHA256','patchSHA256','patchedSourceSHA256','cargoLockSHA256']}
    metadata.update(abiVersion=1,upstreamCommit=lock['commit'],librarySHA256=sha(library),headerSHA256=sha(header),target='aarch64-apple-ios',rustc=subprocess.check_output(['rustc','-V'],text=True).strip(),sdk=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-version'],text=True).strip())
    (dest/'.floe-native.json').write_text(json.dumps(metadata,sort_keys=True,indent=2)+'\n')
    verify_output(lock,recipe,dest)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--lock',type=pathlib.Path,required=True);p.add_argument('--project',type=pathlib.Path,required=True);p.add_argument('--prepare',type=pathlib.Path);p.add_argument('--export',dest='output',type=pathlib.Path);p.add_argument('--source',type=pathlib.Path);p.add_argument('--library',type=pathlib.Path);p.add_argument('--verify-output',type=pathlib.Path);a=p.parse_args()
    lock=json.loads(a.lock.read_text());recipe=check(lock,a.project)
    if a.prepare:
        require(subprocess.check_output(['rustc','-V'],text=True).strip()==recipe['rustc'],'Rust toolchain differs from qualified recipe')
        require(subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-version'],text=True).strip()==recipe['sdk'],'iOS SDK differs from qualified recipe')
        prepare(lock,recipe,a.project,a.prepare)
    if a.output:export(lock,recipe,a.source,a.library,a.output)
    if a.verify_output: verify_output(lock,recipe,a.verify_output)
