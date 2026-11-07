#!/usr/bin/env python3
"""Read-only input and artifact digest verification; never rebuilds or rewrites pins."""
import argparse, hashlib, json, pathlib

KIT=pathlib.Path(__file__).resolve().parents[1]
COMPONENTS={'rapier':('FloeRapierNative','Physics'),'fields':('FloeFieldsNative','Fields/MFEM'),'geometry':('FloeMeshingNative','Geometry')}

def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
    return h.hexdigest()

def verify(name):
    library,native=COMPONENTS[name];vendor=KIT/'Vendor'
    manifest=json.loads((vendor/(library+'.manifest.json')).read_text())
    bundle=vendor/(library+'.xcframework');files=manifest['files']
    if not files:raise ValueError('The artifact manifest contains no files')
    for relative,expected in files.items():
        path=bundle/relative
        path.resolve().relative_to(bundle.resolve())
        if digest(path)!=expected:raise ValueError('Artifact digest mismatch: '+relative)
    source=KIT/'Native'/native
    if name=='rapier':
        if 'packagerSHA256' in manifest and digest(source/'package_apple.py')!=manifest['packagerSHA256']:raise ValueError('Rapier packager source mismatch')
        for relative,expected in manifest['sourceFiles'].items():
            path=source/relative;path.resolve().relative_to(source.resolve())
            if digest(path)!=expected:raise ValueError('Rapier input digest mismatch: '+relative)
        if set(manifest['slices'])!={'macos-arm64','ios-arm64','ios-arm64-simulator'}:raise ValueError('Missing Rapier Apple slice')
    else:
        builds=manifest['builds']
        if set(builds)!={'macos','ios','simulator'}:raise ValueError('Missing native Apple slice')
        bridge='FloeFieldsMFEM.cpp' if name=='fields' else 'FloeMeshingNative.cpp'
        header='FloeFieldsMFEM.h' if name=='fields' else 'FloeMeshingNative.h'
        for platform,build in builds.items():
            if build['bridgeSHA256']!=digest(source/bridge) or build['headerSHA256']!=digest(source/'include'/header):raise ValueError('Native source mismatch: '+platform)
    return {'status':'verified','artifactFiles':len(files),'slices':3}

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true',help='Read-only verification (also the default)');parser.add_argument('--component',choices=COMPONENTS);args=parser.parse_args()
    results={}
    for name in ([args.component] if args.component else COMPONENTS):
        try:results[name]=verify(name)
        except Exception as error:results[name]={'status':'failed','error':str(error)}
    print(json.dumps(results,indent=2))
    raise SystemExit(0 if all(v['status']=='verified' for v in results.values()) else 1)
