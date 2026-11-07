#!/usr/bin/env python3
"""Pinned headless Netgen build; uses the CAD package's existing OCCT archive."""
import argparse, hashlib, json, os, pathlib, plistlib, shutil, subprocess, tarfile, urllib.request

ROOT=pathlib.Path(__file__).resolve().parents[5]
PRIVATE=ROOT/"Local/Private/simulation-predevelopment-20261107/geometry-native02"
CACHE=pathlib.Path.home()/"Library/Caches/CodexBuild/FloeSimulation/0dd039b5b74b/xcode-27B52/netgen"
SHA="daf6e4fe83f768cc5b6d594bb23b8a8cca47bdadc81ecb0902e0ffd598592055"
URL="https://github.com/NGSolve/netgen/archive/refs/tags/v6.2.2507.tar.gz"
PLATFORMS={"macos":("macosx","arm64-apple-macos15.0"),"ios":("iphoneos","arm64-apple-ios26.0"),"simulator":("iphonesimulator","arm64-apple-ios26.0-simulator")}

def run(args):subprocess.run([str(a) for a in args],check=True)

def source():
    upstream=PRIVATE/"upstream";upstream.mkdir(parents=True,exist_ok=True)
    archive=upstream/"netgen-v6.2.2507.tar.gz"
    if not archive.exists():urllib.request.urlretrieve(URL,archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=SHA:raise RuntimeError("Netgen archive digest mismatch")
    src=upstream/"netgen-src"
    if not (src/"CMakeLists.txt").is_file():
        with tarfile.open(archive) as tar:tar.extractall(upstream,filter="data")
        (upstream/"netgen-6.2.2507").rename(src)
    # Upstream uses a volatile int across threads. Only termination is exposed
    # by our bridge; make that shared flag atomic in every compiled consumer.
    status=src/"libsrc/core/statushandler.hpp";original=text=status.read_text()
    if '#include <atomic>' not in text:text=text.replace('#include <string>','#include <string>\n#include <atomic>')
    text=text.replace('    int terminate;','    std::atomic<int> terminate;')
    if text!=original:status.write_text(text)
    meshfile=src/'libsrc/meshing/meshclass.cpp';text=meshfile.read_text()
    if 'floe_meshing_budget_check' not in text:
        text=text.replace('namespace netgen\n{','extern "C" void floe_meshing_budget_check(int kind, int count);\n\nnamespace netgen\n{',1)
        patches=[
            ('PointIndex Mesh :: AddPoint (const Point3d & p, int layer, POINTTYPE type)', 'floe_meshing_budget_check(0, int(points.Size())+1);'),
            ('ElementIndex Mesh :: AddVolumeElement (const Element & el)', 'floe_meshing_budget_check(1, int(volelements.Size())+1);'),
            ('SurfaceElementIndex Mesh :: AddSurfaceElement (const Element2d & el)', 'floe_meshing_budget_check(2, int(surfelements.Size())+1);'),
            ('void Mesh :: SetNP (int np)', 'floe_meshing_budget_check(0, np);')]
        for signature,check in patches:
            start=text.index(signature);brace=text.index('{',start)
            text=text[:brace+1]+'\n    '+check+text[brace+1:]
        meshfile.write_text(text)
    rules=src/'rules/CMakeLists.txt';text=rules.read_text()
    if 'FLOE_NETGEN_HOST_MAKERLS' not in text:
        text=text.replace('if(EMSCRIPTEN)','if(FLOE_NETGEN_HOST_MAKERLS)\n  add_custom_target(makerls)\n  set(rules_command "${FLOE_NETGEN_HOST_MAKERLS}")\nelseif(EMSCRIPTEN)',1)
        rules.write_text(text)
    return src

def occ_configuration(platform,build):
    slice="ios-arm64" if platform=="ios" else "ios-arm64-simulator"
    binary=ROOT/"FloeAgent/ThirdParty/FloeCADKit/Vendor/OCCT.xcframework"/slice
    archives=list(binary.glob("*.a"))
    if len(archives)!=1:raise RuntimeError("Expected one existing pinned OCCT archive")
    config=build/"occt-config";config.mkdir(parents=True,exist_ok=True)
    libraries="TKBO TKBRep TKBool TKCAF TKCDF TKFillet TKG2d TKG3d TKGeomAlgo TKGeomBase TKHLR TKLCAF TKMath TKMesh TKOffset TKPrim TKService TKShHealing TKTopAlgo TKV3d TKVCAF TKXCAF TKXSBase TKernel TKDEIGES TKDESTEP TKDESTL".split()
    lines=['set(OpenCASCADE_FOUND TRUE)','set(OpenCASCADE_MAJOR_VERSION 7)','set(OpenCASCADE_MINOR_VERSION 8)','set(OpenCASCADE_MAINTENANCE_VERSION 1)','set(OpenCASCADE_BUILD_SHARED_LIBS OFF)','set(OpenCASCADE_WITH_FREETYPE OFF)',f'set(OpenCASCADE_INCLUDE_DIR "{binary/"Headers"}")']
    for name in libraries:
        lines+=[f'add_library({name} INTERFACE IMPORTED)',f'set_target_properties({name} PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "{binary/"Headers"}")']
    lines+=[f'set_target_properties(TKernel PROPERTIES INTERFACE_LINK_LIBRARIES "{archives[0]}")']
    (config/"OpenCASCADEConfig.cmake").write_text('\n'.join(lines)+'\n')
    return config

def build(platform,phase):
    src=source();sdk,triple=PLATFORMS[platform];build=CACHE/platform;build.mkdir(parents=True,exist_ok=True)
    sysroot=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip()
    compiler=subprocess.check_output(['xcrun','--find','clang++'],text=True).strip()
    args=['cmake','-G','Ninja','-S',src,'-B',build,'-DCMAKE_BUILD_TYPE=Release','-DUSE_SUPERBUILD=OFF','-DUSE_GUI=OFF','-DUSE_PYTHON=OFF','-DUSE_MPI=OFF','-DUSE_NATIVE_ARCH=OFF','-DUSE_SPDLOG=OFF','-DUSE_NUMA=OFF','-DUSE_CCACHE=OFF','-DUSE_CGNS=OFF','-DENABLE_UNIT_TESTS=OFF','-DBUILD_TESTING=OFF','-DNGLIB_LIBRARY_TYPE=STATIC','-DNGCORE_LIBRARY_TYPE=STATIC','-DBUILD_STUB_FILES=OFF','-DCMAKE_INSTALL_PREFIX='+str(build/'install'),'-DCMAKE_CXX_COMPILER='+compiler,'-DCMAKE_CXX_FLAGS='+f'-target {triple} -isysroot {sysroot} -O2 -fvisibility=hidden','-DCMAKE_OSX_ARCHITECTURES=arm64','-DCMAKE_OSX_SYSROOT='+sysroot,'-DCMAKE_SYSTEM_PROCESSOR=arm64','-DCMAKE_MACOSX_BUNDLE=OFF']
    args+=['-DNETGEN_VERSION_GIT=v6.2.2507-0-archive']
    if platform=='macos':args+=['-DUSE_OCC=OFF','-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0']
    else:
        hosttool=CACHE/'host-tools/makerls';hosttool.parent.mkdir(exist_ok=True)
        if not hosttool.exists():run(['xcrun','--sdk','macosx','clang++','-O2',src/'rules/makerlsfile.cpp','-o',hosttool])
        args+=['-DUSE_OCC=ON','-DOpenCascade_DIR='+str(occ_configuration(platform,build)),'-DCMAKE_SYSTEM_NAME=iOS','-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0','-DFLOE_NETGEN_HOST_MAKERLS='+str(hosttool)]
    run(args);run(['cmake','--build',build,'--target','nglib','--parallel','6'])
    if phase=='upstream':return
    native=ROOT/'FloeAgent/Modules/FloeSimulationKit/Native/Geometry'
    includes=[build,src/'libsrc/include',src/'libsrc',src/'nglib',src,src/'libsrc/general',src/'libsrc/gprim',src/'libsrc/meshing']
    defines=[]
    if platform!='macos':
        slice='ios-arm64' if platform=='ios' else 'ios-arm64-simulator'
        includes+=[src/'libsrc/occ',ROOT/'FloeAgent/ThirdParty/FloeCADKit/Vendor/OCCT.xcframework'/slice/'Headers']
        defines=['-DOCCGEOMETRY']
    command=['xcrun','--sdk',sdk,'clang++','-target',triple,'-isysroot',sysroot,'-std=c++17','-O2','-DNDEBUG','-fvisibility=hidden',*defines]
    for include in includes:command+=['-I',include]
    run(command+['-c',native/'FloeMeshingNative.cpp','-o',build/'bridge.o'])
    ngcore=list(build.glob('**/libngcore.a'))
    if len(ngcore)!=1:raise RuntimeError('Expected one ngcore archive')
    run(['xcrun','libtool','-static','-o',build/'libFloeMeshingNative.a',build/'libnglib.a',ngcore[0],build/'bridge.o'])
    (build/'BUILD.json').write_text(json.dumps({'upstream':'Netgen 6.2.2507','archiveSHA256':SHA,'platform':platform,'triple':triple,'brep':platform!='macos','bridgeSHA256':hashlib.sha256((native/'FloeMeshingNative.cpp').read_bytes()).hexdigest(),'headerSHA256':hashlib.sha256((native/'include/FloeMeshingNative.h').read_bytes()).hexdigest()},indent=2)+'\n')

def package():
    native=ROOT/'FloeAgent/Modules/FloeSimulationKit/Native/Geometry'
    vendor=ROOT/'FloeAgent/Modules/FloeSimulationKit/Vendor';output=vendor/'FloeMeshingNative.xcframework'
    builds={p:json.loads((CACHE/p/'BUILD.json').read_text()) for p in PLATFORMS}
    for kind,file in [('bridgeSHA256','FloeMeshingNative.cpp'),('headerSHA256','include/FloeMeshingNative.h')]:
        expected=hashlib.sha256((native/file).read_bytes()).hexdigest()
        if any(b.get(kind)!=expected for b in builds.values()):raise RuntimeError('Apple mesh slices have different sources')
    staging=CACHE/'FloeMeshingNative.xcframework'
    if staging.exists():shutil.rmtree(staging)
    args=['xcodebuild','-create-xcframework']
    for platform in PLATFORMS:
        framework=CACHE/platform/'FloeMeshingNative.framework'
        if framework.exists():shutil.rmtree(framework)
        (framework/'Headers').mkdir(parents=True);(framework/'Modules').mkdir()
        shutil.copy2(CACHE/platform/'libFloeMeshingNative.a',framework/'FloeMeshingNative')
        shutil.copy2(native/'include/FloeMeshingNative.h',framework/'Headers/FloeMeshingNative.h')
        (framework/'Modules/module.modulemap').write_text('framework module FloeMeshingNative { umbrella header "FloeMeshingNative.h" export * module * { export * } }\n')
        (framework/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.floe.simulation.meshing.native','CFBundleName':'FloeMeshingNative','CFBundleExecutable':'FloeMeshingNative','CFBundlePackageType':'FMWK','CFBundleVersion':'2','CFBundleShortVersionString':'2.0','MinimumOSVersion':'15.0' if platform=='macos' else '26.0'}))
        args+=['-framework',framework]
    run(args+['-output',staging])
    if output.exists():raise RuntimeError('Preserve the prior mesh artifact before replacing it')
    shutil.copytree(staging,output)
    hashes={str(p.relative_to(output)):hashlib.sha256(p.read_bytes()).hexdigest() for p in output.rglob('*') if p.is_file()}
    (vendor/'FloeMeshingNative.manifest.json').write_text(json.dumps({'upstream':'Netgen 6.2.2507','archiveSHA256':SHA,'sourceURL':URL,'builds':builds,'files':hashes},indent=2)+'\n')
    notices=vendor/'MeshingNotices';notices.mkdir(exist_ok=True)
    for name in ['LICENSE','COPYING.LIB']:
        if (source()/name).exists():shutil.copy2(source()/name,notices/('Netgen-'+name))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--platform',choices=[*PLATFORMS,'all']);p.add_argument('--phase',choices=['upstream','bridge'],default='bridge');p.add_argument('--package',action='store_true');a=p.parse_args();os.environ['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
    if a.package:package()
    elif a.platform:
        for platform in (PLATFORMS if a.platform=='all' else [a.platform]):build(platform,a.phase)
    else:p.error('Choose --platform or --package')
