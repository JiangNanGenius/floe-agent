#!/usr/bin/env python3
"""Developer-only reproducible CPU/serial MFEM Apple build. No runtime process use."""
import argparse, hashlib, json, os, pathlib, plistlib, shutil, subprocess, tarfile, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[6]
KIT = ROOT / "FloeAgent/Modules/FloeSimulationKit"
PRIVATE = ROOT / "Local/Private/simulation-predevelopment-20261107/fields-mfem02"
CACHE = pathlib.Path.home() / "Library/Caches/CodexBuild/FloeSimulation/0dd039b5b74b/xcode-27B52/mfem"
SHA = "65472f732d273832c64b2c39460649dd862df674222c71bfa82cf2da76705052"
URL = "https://github.com/mfem/mfem/archive/refs/tags/v4.8.tar.gz"
PLATFORMS = {"macos":("macosx","arm64-apple-macos15.0"),"ios":("iphoneos","arm64-apple-ios26.0"),"simulator":("iphonesimulator","arm64-apple-ios26.0-simulator")}

def run(args):
    subprocess.run([str(a) for a in args],check=True)

def source():
    directory = PRIVATE / "source"; directory.mkdir(parents=True,exist_ok=True)
    archive = directory / "mfem-4.8.tar.gz"
    if not archive.exists():
        temporary = archive.with_suffix(".download")
        urllib.request.urlretrieve(URL,temporary)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != SHA:
            temporary.unlink(); raise RuntimeError("MFEM archive digest mismatch")
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA: raise RuntimeError("MFEM archive digest mismatch")
    target = directory / "mfem-src"
    if not (target / "mfem.hpp").is_file():
        with tarfile.open(archive) as tar: tar.extractall(directory,filter="data")
        (directory / "mfem-4.8").rename(target)
    # MFEM configures excluded miniapps even for a library-only build. CMake's
    # iOS platform leaves this variable empty; quote it without changing kernels.
    performance = target / "miniapps/performance/CMakeLists.txt"
    original = text = performance.read_text()
    text = text.replace('if (${CMAKE_SYSTEM_PROCESSOR} MATCHES', 'if ("${CMAKE_SYSTEM_PROCESSOR}" MATCHES')
    text = text.replace('APPLE AND ${CMAKE_SYSTEM_PROCESSOR} MATCHES', 'APPLE AND "${CMAKE_SYSTEM_PROCESSOR}" MATCHES')
    if text != original: performance.write_text(text)
    return target

def build(platform, phase):
    src = source(); sdk, triple = PLATFORMS[platform]
    sysroot = subprocess.check_output(["xcrun","--sdk",sdk,"--show-sdk-path"],text=True).strip()
    builddir = CACHE / platform; builddir.mkdir(parents=True,exist_ok=True)
    flags = f"-target {triple} -isysroot {sysroot} -O2 -fvisibility=hidden"
    cmake = ["cmake","-G","Ninja","-S",src,"-B",builddir,"-DCMAKE_BUILD_TYPE=Release","-DBUILD_SHARED_LIBS=OFF",
             "-DCMAKE_CXX_COMPILER="+subprocess.check_output(["xcrun","--find","clang++"],text=True).strip(),
             "-DCMAKE_CXX_FLAGS="+flags,"-DCMAKE_OSX_ARCHITECTURES=arm64","-DCMAKE_OSX_SYSROOT="+sysroot,"-DCMAKE_SYSTEM_PROCESSOR=arm64","-DCMAKE_MACOSX_BUNDLE=OFF",
             "-DMFEM_USE_EXCEPTIONS=ON","-DMFEM_THREAD_SAFE=ON","-DMFEM_USE_MPI=OFF","-DMFEM_USE_METIS=OFF",
             "-DMFEM_USE_LAPACK=OFF","-DMFEM_USE_OPENMP=OFF","-DMFEM_USE_ZLIB=OFF","-DMFEM_ENABLE_TESTING=OFF",
             "-DMFEM_ENABLE_EXAMPLES=OFF","-DMFEM_ENABLE_MINIAPPS=OFF","-DMFEM_ENABLE_BENCHMARKS=OFF"]
    if platform != "macos": cmake += ["-DCMAKE_SYSTEM_NAME=iOS","-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0"]
    else: cmake += ["-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0"]
    run(cmake); run(["cmake","--build",builddir,"--target","mfem","--parallel","6"])
    if phase == "upstream": return
    native = KIT / "Native/Fields/MFEM"
    run(["xcrun","--sdk",sdk,"clang++","-target",triple,"-isysroot",sysroot,"-std=c++17","-O2","-DNDEBUG",
         "-fvisibility=hidden","-I",builddir,"-I",src,"-I",native/"include","-c",native/"FloeFieldsMFEM.cpp","-o",builddir/"bridge.o"])
    run(["xcrun","libtool","-static","-o",builddir/"libFloeFieldsNative.a",builddir/"libmfem.a",builddir/"bridge.o"])
    (builddir/"BUILD.json").write_text(json.dumps({"upstream":"MFEM 4.8","archiveSHA256":SHA,"platform":platform,"triple":triple,"serial":True,"exceptions":True,"openmp":False,"mpi":False,"bridgeSHA256":hashlib.sha256((native/"FloeFieldsMFEM.cpp").read_bytes()).hexdigest(),"headerSHA256":hashlib.sha256((native/"include/FloeFieldsMFEM.h").read_bytes()).hexdigest()},indent=2)+"\n")

def package():
    native = KIT / "Native/Fields/MFEM"
    builds={p:json.loads((CACHE/p/"BUILD.json").read_text()) for p in PLATFORMS}
    bridge_hash=hashlib.sha256((native/"FloeFieldsMFEM.cpp").read_bytes()).hexdigest()
    header_hash=hashlib.sha256((native/"include/FloeFieldsMFEM.h").read_bytes()).hexdigest()
    if any(b.get("bridgeSHA256")!=bridge_hash or b.get("headerSHA256")!=header_hash for b in builds.values()):raise RuntimeError("Apple slices do not match the current bridge and header")
    vendor = KIT / "Vendor"; output = vendor / "FloeFieldsNative.xcframework"
    staging = CACHE / "FloeFieldsNative.xcframework"
    if staging.exists(): shutil.rmtree(staging)
    args = ["xcodebuild","-create-xcframework"]
    # A static framework namespaces its module map. Two library XCFrameworks
    # otherwise both produce include/module.modulemap in Swift Build's output.
    for platform in PLATFORMS:
        framework = CACHE/platform/"FloeFieldsNative.framework"
        if framework.exists(): shutil.rmtree(framework)
        (framework/"Headers").mkdir(parents=True)
        (framework/"Modules").mkdir()
        shutil.copy2(CACHE/platform/"libFloeFieldsNative.a",framework/"FloeFieldsNative")
        shutil.copy2(native/"include/FloeFieldsMFEM.h",framework/"Headers/FloeFieldsMFEM.h")
        (framework/"Modules/module.modulemap").write_text('framework module FloeFieldsNative { umbrella header "FloeFieldsMFEM.h" export * module * { export * } }\n')
        (framework/"Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"com.floe.simulation.fields.native","CFBundleName":"FloeFieldsNative","CFBundleExecutable":"FloeFieldsNative","CFBundlePackageType":"FMWK","CFBundleVersion":"3","CFBundleShortVersionString":"3.0","MinimumOSVersion":"15.0" if platform=="macos" else "26.0"}))
        args += ["-framework",framework]
    run(args+["-output",staging])
    if output.exists(): raise RuntimeError("Preserve existing framework before replacing it")
    shutil.copytree(staging,output)
    hashes = {str(p.relative_to(output)):hashlib.sha256(p.read_bytes()).hexdigest() for p in output.rglob("*") if p.is_file()}
    (vendor/"FloeFieldsNative.manifest.json").write_text(json.dumps({"upstream":"MFEM 4.8","archiveSHA256":SHA,"sourceURL":URL,"builds":builds,"files":hashes},indent=2)+"\n")
    notices = vendor/"FieldsNotices"; notices.mkdir(exist_ok=True)
    for name in ["LICENSE","NOTICE"]: shutil.copy2(source()/name,notices/("MFEM-4.8-"+name))

if __name__ == "__main__":
    p = argparse.ArgumentParser(); p.add_argument("--platform",choices=[*PLATFORMS,"all"]); p.add_argument("--phase",choices=["upstream","bridge"],default="bridge"); p.add_argument("--package",action="store_true"); a=p.parse_args()
    os.environ["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    if a.package: package()
    elif a.platform:
        for platform in (PLATFORMS if a.platform=="all" else [a.platform]): build(platform,a.phase)
    else: p.error("Choose --platform or --package")
