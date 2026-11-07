#!/usr/bin/env python3
"""Build the locked in-process Rapier bridge for Apple's three local slices."""
import argparse, hashlib, json, os, shutil, subprocess
from pathlib import Path

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-root', required=True, type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--replace', action='store_true', help='Replace only this task-owned artifact after building the new slices.')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    output = args.output or root.parents[1] / 'Vendor' / 'FloeRapierNative.xcframework'
    build = args.build_root.resolve()
    build.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(build).free < 3 * 1024 ** 3:
        raise SystemExit('At least 3 GiB of free build space is required.')
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', IPHONEOS_DEPLOYMENT_TARGET='26.0', MACOSX_DEPLOYMENT_TARGET='15.0')
    libraries = []
    source_files=[root/'Cargo.toml',root/'Cargo.lock',root/'src/lib.rs',root/'include/FloeRapierNative.h',root/'include/module.modulemap']
    source_hashes={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files}
    for target, sdk in [('aarch64-apple-darwin','macosx'),('aarch64-apple-ios','iphoneos'),('aarch64-apple-ios-sim','iphonesimulator')]:
        if any(hashlib.sha256(p.read_bytes()).hexdigest()!=source_hashes[str(p.relative_to(root))] for p in source_files): raise SystemExit('Native source changed during the build; retain this failure and rebuild from one fixed input.')
        print('Building ' + target, flush=True)
        env['SDKROOT'] = subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'], env=env, text=True).strip()
        subprocess.run(['cargo','build','--locked','--release','--jobs','6','--manifest-path',str(root/'Cargo.toml'),'--target-dir',str(build),'--target',target],env=env,check=True)
        libraries += ['-library', str(build/target/'release'/'libfloe_rapier_native.a'), '-headers',str(root/'include')]
    staging = build/'FloeRapierNative.xcframework'
    if staging.exists(): shutil.rmtree(staging)
    subprocess.run(['xcodebuild','-create-xcframework',*libraries,'-output',str(staging)],env=env,check=True)
    output.parent.mkdir(parents=True,exist_ok=True)
    if output.exists():
        if not args.replace: raise SystemExit('Output exists; select a new output or explicitly replace this task-owned artifact.')
        previous=output.with_name(output.name+'.previous')
        if previous.exists(): raise SystemExit('A previous artifact needs review before replacement.')
        output.rename(previous)
    else: previous=None
    try: shutil.copytree(staging,output)
    except Exception:
        if output.exists(): shutil.rmtree(output)
        if previous: previous.rename(output)
        raise
    if previous: shutil.rmtree(previous)
    metadata = json.loads(subprocess.check_output(['cargo','metadata','--locked','--format-version','1','--manifest-path',str(root/'Cargo.toml')],env=env,text=True))
    notices=[]
    for package in metadata['packages']:
        item={'name':package['name'],'version':package['version'],'license':package.get('license'),'repository':package.get('repository')}
        notices.append(item)
        license_root=Path(package['manifest_path']).parent
        destination=output.parent/'RapierNotices'/(package['name']+'-'+package['version'])
        for pattern in ['LICENSE*','COPYING*','NOTICE*']:
            for license_file in license_root.glob(pattern):
                if license_file.is_file():
                    destination.mkdir(parents=True,exist_ok=True)
                    shutil.copyfile(license_file,destination/license_file.name)
    files={str(p.relative_to(output)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(output.rglob('*')) if p.is_file()}
    manifest={'bridgeVersion':'0.1.0','rapierVersion':'0.36.1','sourceFiles':source_hashes,'cargoLockSHA256':hashlib.sha256((root/'Cargo.lock').read_bytes()).hexdigest(),'slices':['macos-arm64','ios-arm64','ios-arm64-simulator'],'dependencies':notices,'files':files}
    (output.parent/'FloeRapierNative.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('Saved ' + str(output), flush=True)

if __name__ == '__main__': main()
