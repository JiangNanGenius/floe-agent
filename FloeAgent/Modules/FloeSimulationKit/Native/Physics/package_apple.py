#!/usr/bin/env python3
"""Namespaced static frameworks; optionally repackage already verified archive bytes."""
import argparse, hashlib, json, os, plistlib, shutil, subprocess
from pathlib import Path

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def framework(library, headers, destination, sdk):
    destination.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(library, destination / 'FloeRapierNative')
    (destination / 'Headers').mkdir()
    shutil.copyfile(headers / 'FloeRapierNative.h', destination / 'Headers/FloeRapierNative.h')
    (destination / 'Modules').mkdir()
    (destination / 'Modules/module.modulemap').write_text('framework module FloeRapierNative {\n header "FloeRapierNative.h"\n export *\n}\n')
    (destination / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable':'FloeRapierNative','CFBundleIdentifier':'org.floe.simulation.rapier',
        'CFBundleName':'FloeRapierNative','CFBundlePackageType':'FMWK','CFBundleVersion':'1',
        'CFBundleShortVersionString':'0.1.0','CFBundleSupportedPlatforms':[{'macosx':'MacOSX','iphoneos':'iPhoneOS','iphonesimulator':'iPhoneSimulator'}[sdk]],
        'MinimumOSVersion':'15.0' if sdk == 'macosx' else '26.0'}))
    assert digest(destination / 'FloeRapierNative') == digest(library)
    return destination

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--reuse-verified', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--build-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    manifest = json.loads(args.manifest.read_text())
    for name, sha in manifest['sourceFiles'].items():
        p = root / name; p.resolve().relative_to(root.resolve())
        if digest(p) != sha: raise ValueError('Native input changed: ' + name)
    for name, sha in manifest['files'].items():
        p = args.reuse_verified / name; p.resolve().relative_to(args.reuse_verified.resolve())
        if digest(p) != sha: raise ValueError('Unverified native slice: ' + name)
    if args.output.exists() or args.build_root.exists(): raise ValueError('Use new task-owned output and packaging directories.')
    args.build_root.mkdir(parents=True)
    inputs = []
    original_archives = {}
    for slice_id, sdk in [('macos-arm64','macosx'),('ios-arm64','iphoneos'),('ios-arm64-simulator','iphonesimulator')]:
        library = args.reuse_verified / slice_id / 'libfloe_rapier_native.a'
        original_archives[slice_id] = digest(library)
        directory = args.build_root / slice_id / 'FloeRapierNative.framework'
        inputs += ['-framework', str(framework(library, root/'include', directory, sdk))]
    subprocess.run(['xcodebuild','-create-xcframework',*inputs,'-output',str(args.output)],
        env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'),check=True)
    for slice_id, sha in original_archives.items():
        if digest(args.output / slice_id / 'FloeRapierNative.framework/FloeRapierNative') != sha:
            raise ValueError('Repackaging altered a native archive.')
    manifest['layout'] = 'namespaced-static-framework'
    manifest['archiveBytesReused'] = original_archives
    manifest['packagerSHA256'] = digest(Path(__file__).resolve())
    manifest['files'] = {str(p.relative_to(args.output)):digest(p) for p in sorted(args.output.rglob('*')) if p.is_file()}
    (args.output.parent/'FloeRapierNative.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps({'layout':manifest['layout'],'unchangedArchiveSHA256':original_archives},indent=2))

if __name__ == '__main__': main()
