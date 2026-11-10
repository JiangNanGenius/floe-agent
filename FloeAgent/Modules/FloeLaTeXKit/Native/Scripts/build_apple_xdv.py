#!/usr/bin/env python3
"""Build the new XDV-only Apple ABI; never qualify/relabel the old GPL PDF archive."""
from pathlib import Path
import argparse, hashlib, json, os, re, shutil, subprocess, sys, tarfile, time, urllib.request

NATIVE = Path(__file__).resolve().parents[1]
CACHE = Path.home() / 'Library/Caches/CodexBuild/FloeLaTeXXDV/main/Xcode27.2/apple'
ALLOW_SOURCE_DOWNLOADS = False

def run(args, *, cwd=None, env=None, log=None):
    args = [str(a) for a in args]
    print('Running ' + args[0] + ' ' + ' '.join(args[1:4]), flush=True)
    with open(log, 'a') if log else open(os.devnull, 'w') as stream:
        subprocess.run(args, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True)

def native_symbol_command(binary):
    # Rust ships newer embedded LLVM metadata than Apple's independent nm.
    # Use the installed compiler's own reader; never ignore unreadable members.
    info=subprocess.check_output(['rustc','-vV'],text=True)
    host=next(line.split(': ',1)[1] for line in info.splitlines() if line.startswith('host: '))
    sysroot=Path(subprocess.check_output(['rustc','--print','sysroot'],text=True).strip())
    tool=sysroot/'lib/rustlib'/host/'bin/llvm-nm'
    if not tool.is_file():
        raise RuntimeError('Install llvm-tools for the active Rust toolchain before auditing native symbols')
    version=subprocess.check_output([str(tool),'--version'],text=True).strip()
    return [str(tool),'-g','--defined-only',str(binary)],{'tool':tool.name,'version':version,'definedGlobalSymbolsOnly':True}

def fetch_sources():
    result = {}
    for item in json.loads((NATIVE/'dependencies.json').read_text())['dependencies']:
        directory = CACHE/'sources'/item['name']
        stamp = directory/'.source-sha256'
        if stamp.exists() and stamp.read_text().strip() == item['sha256']:
            result[item['name']] = directory
            continue
        archive = CACHE/'downloads'/(item['name']+'-'+item['version']+'.archive')
        archive.parent.mkdir(parents=True, exist_ok=True)
        if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != item['sha256']:
            if not ALLOW_SOURCE_DOWNLOADS: raise RuntimeError('Pinned dependency source unavailable; explicit --allow-source-downloads required: '+item['name'])
            temporary = archive.with_suffix('.part')
            try:
                request = urllib.request.Request(item['url'], headers={'User-Agent':'Floe-native-build/1'})
                with urllib.request.urlopen(request, timeout=60) as response, temporary.open('wb') as out:
                    shutil.copyfileobj(response,out,length=1024*1024)
                if hashlib.sha256(temporary.read_bytes()).hexdigest() != item['sha256']:
                    raise RuntimeError('Source digest mismatch: '+item['name'])
                temporary.replace(archive)
            finally:
                temporary.unlink(missing_ok=True)
        stage = directory.with_name(directory.name+'-extract')
        if stage.exists(): shutil.rmtree(stage)
        stage.mkdir(parents=True)
        with tarfile.open(archive) as source:
            # Also support the host's Python 3.9, which has no data filter.
            base = stage.resolve()
            members = source.getmembers()
            for member in members:
                target = (stage/member.name).resolve()
                if not (target == base or base in target.parents) or member.isdev() or member.isfifo():
                    raise RuntimeError('Unsafe source archive entry: '+member.name)
                if member.issym() or member.islnk():
                    link = (target.parent/member.linkname if member.issym() else stage/member.linkname).resolve()
                    if not (link == base or base in link.parents):
                        raise RuntimeError('Unsafe source archive link: '+member.name)
            source.extractall(stage, members=members)
        children = list(stage.iterdir())
        unpacked = children[0] if len(children)==1 and children[0].is_dir() else stage
        if directory.exists(): shutil.rmtree(directory)
        if unpacked == stage: stage.rename(directory)
        else:
            unpacked.rename(directory)
            stage.rmdir()
        (directory/'.source-sha256').write_text(item['sha256']+'\n')
        result[item['name']] = directory
    return result

def cmake(source, build, prefix, sdk, deployment, extra, jobs, log):
    env=dict(os.environ,PKG_CONFIG_PATH=str(prefix/'lib/pkgconfig'),PKG_CONFIG_LIBDIR=str(prefix/'lib/pkgconfig'))
    run(['cmake','-S',source,'-B',build,'-G','Ninja',
        '-DCMAKE_BUILD_TYPE=Release','-DBUILD_SHARED_LIBS=OFF',
        '-DCMAKE_SYSTEM_NAME=iOS','-DCMAKE_OSX_ARCHITECTURES=arm64',
        '-DCMAKE_OSX_SYSROOT='+sdk,'-DCMAKE_OSX_DEPLOYMENT_TARGET='+deployment,
        '-DCMAKE_INSTALL_PREFIX='+str(prefix),'-DCMAKE_PREFIX_PATH='+str(prefix),
        '-DCMAKE_FIND_ROOT_PATH='+str(prefix)+';'+sdk,
        '-DCMAKE_C_FLAGS=-fPIC','-DCMAKE_CXX_FLAGS=-fPIC',*extra],env=env,log=log)
    run(['cmake','--build',build,'--parallel',jobs],env=env,log=log)
    run(['cmake','--install',build],env=env,log=log)

def build_icu(sources, prefix, sdk, platform, jobs, log):
    if (prefix/'lib/libicuuc.a').exists() and (prefix/'lib/libicudata.a').exists() and (prefix/'include/unicode/utypes.h').exists():
        return
    source = sources['icu']/'source'
    host = CACHE/'icu-host'
    host.mkdir(parents=True,exist_ok=True)
    host_env = dict(os.environ)
    if not (host/'bin/icupkg').exists():
        run([source/'runConfigureICU','MacOSX','--enable-static','--disable-shared',
             '--disable-tests','--disable-samples','--with-data-packaging=static'],cwd=host,env=host_env,log=log)
        run(['make','-j',jobs],cwd=host,env=host_env,log=log)
    build = CACHE/platform/'icu'
    build.mkdir(parents=True,exist_ok=True)
    minimum = '-mios-simulator-version-min=26.0' if platform=='simulator' else '-miphoneos-version-min=26.0'
    env = dict(os.environ, CC='clang', CXX='clang++',
        CFLAGS=f'-arch arm64 -isysroot {sdk} {minimum} -fPIC',
        CXXFLAGS=f'-arch arm64 -isysroot {sdk} {minimum} -fPIC',
        LDFLAGS=f'-arch arm64 -isysroot {sdk} {minimum}')
    run([source/'configure','--host=aarch64-apple-darwin','--build=aarch64-apple-darwin25',
         '--with-cross-build='+str(host),'--prefix='+str(prefix),'--enable-static',
         '--disable-shared','--disable-tests','--disable-samples','--disable-tools','--disable-extras',
         '--with-data-packaging=static'],cwd=build,env=env,log=log)
    run(['make','-j',jobs],cwd=build,env=env,log=log)
    run(['make','install'],cwd=build,env=env,log=log)

def build(platform, jobs, sources):
    sdk_name = 'iphonesimulator' if platform=='simulator' else 'iphoneos'
    target = 'aarch64-apple-ios-sim' if platform=='simulator' else 'aarch64-apple-ios'
    sdk = subprocess.check_output(['xcrun','--sdk',sdk_name,'--show-sdk-path'],text=True).strip()
    prefix = CACHE/platform/'install'
    prefix.mkdir(parents=True,exist_ok=True)
    pc=prefix/'lib/pkgconfig'
    pc.mkdir(parents=True,exist_ok=True)
    zversion=re.search(r'#define ZLIB_VERSION\s+"([^"]+)"',(Path(sdk)/'usr/include/zlib.h').read_text()).group(1)
    (pc/'zlib.pc').write_text('prefix='+sdk+'/usr\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: zlib\nDescription: Apple SDK public zlib\nVersion: '+zversion+'\nLibs: -L${libdir} -lz\nCflags: -I${includedir}\n')
    log = CACHE/platform/'build.log'
    deps_stamp = prefix/'dependencies.complete'
    if not deps_stamp.exists():
        cmake(sources['libpng'],CACHE/platform/'png',prefix,sdk,'26.0',
              ['-DPNG_SHARED=OFF','-DPNG_STATIC=ON','-DPNG_TESTS=OFF','-DPNG_TOOLS=OFF'],jobs,log)
        cmake(sources['graphite2'],CACHE/platform/'graphite',prefix,sdk,'26.0',
              ['-DGRAPHITE2_BUILD_SHARED=OFF','-DGRAPHITE2_BUILD_STATIC=ON','-DGRAPHITE2_NFILEFACE=ON','-DGRAPHITE2_NSEGCACHE=ON'],jobs,log)
        cmake(sources['freetype'],CACHE/platform/'freetype',prefix,sdk,'26.0',
              ['-DFT_DISABLE_HVF=ON','-DFT_DISABLE_BZIP2=ON','-DFT_DISABLE_BROTLI=ON','-DFT_DISABLE_HARFBUZZ=ON','-DFT_DISABLE_PNG=OFF'],jobs,log)
        build_icu(sources,prefix,sdk,platform,jobs,log)
        cmake(sources['harfbuzz'],CACHE/platform/'harfbuzz',prefix,sdk,'26.0',
              ['-DHB_BUILD_TESTS=OFF','-DHB_BUILD_UTILS=OFF','-DHB_BUILD_GPU=OFF','-DHB_BUILD_GPU_DEMO=OFF',
               '-DHB_BUILD_RASTER=OFF','-DHB_BUILD_VECTOR=OFF','-DHB_BUILD_SUBSET=OFF',
               '-DFREETYPE_LIBRARY_RELEASE='+str(prefix/'lib/libfreetype.a'),
               '-DFREETYPE_INCLUDE_DIR_ft2build='+str(prefix/'include/freetype2'),
               '-DFREETYPE_INCLUDE_DIR_freetype2='+str(prefix/'include/freetype2'),
               '-DICU_ROOT='+str(prefix),
               '-DHB_HAVE_FREETYPE=ON','-DHB_HAVE_GRAPHITE2=ON','-DHB_HAVE_ICU=ON','-DHB_HAVE_CORETEXT=ON'],jobs,log)
        deps_stamp.write_text(json.dumps({'source':json.loads((NATIVE/'dependencies.json').read_text()),'platform':platform})+'\n')
    env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
        SDKROOT=sdk,IPHONEOS_DEPLOYMENT_TARGET='26.0',
        PKG_CONFIG_ALLOW_CROSS='1',PKG_CONFIG_PATH=str(prefix/'lib/pkgconfig'),
        PKG_CONFIG_LIBDIR=str(prefix/'lib/pkgconfig'),
        TECTONIC_PKGCONFIG_FORCE_SEMI_STATIC='1',
        CARGO_TARGET_DIR=str(CACHE/'rust'),
        CARGO_PROFILE_RELEASE_DEBUG='0')
    env['CC_'+target.replace('-','_')]=str(Path('/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang'))
    env['CXX_'+target.replace('-','_')]=str(Path('/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++'))
    # Rust rlibs embed native archives. A changed static dependency must rebuild
    # those bridges, even when pkg-config paths and Cargo.lock are unchanged.
    fingerprint=hashlib.sha256(b''.join(hashlib.sha256(p.read_bytes()).digest() for p in sorted((prefix/'lib').glob('*.a')))).hexdigest()
    link_stamp=CACHE/platform/'rust-dependency-fingerprint'
    if not link_stamp.exists() or link_stamp.read_text().strip()!=fingerprint:
        for package in ['tectonic_bridge_freetype2','tectonic_bridge_harfbuzz','tectonic_bridge_icu','tectonic_bridge_graphite2','floe_tex_native_xdv']:
            run(['cargo','clean','--manifest-path',NATIVE/'bridge/Cargo.toml','--release','--target',target,'-p',package],env=env,log=log)
    graph=subprocess.check_output(['cargo','tree','--manifest-path',str(NATIVE/'bridge/Cargo.toml'),'--locked','--target',target,'--edges','normal,build','--prefix','none'],env=env,text=True)
    for forbidden in ['tectonic_pdf_io ', 'tectonic_engine_xdvipdfmx ']:
        if forbidden in graph: raise RuntimeError('Forbidden PDF dependency in actual Cargo closure: '+forbidden)
    (CACHE/platform/'cargo-closure.txt').write_text(graph)
    run(['cargo','build','--manifest-path',NATIVE/'bridge/Cargo.toml','--lib','--release','--locked','--target',target,'-j',jobs],env=env,log=log)
    link_stamp.write_text(fingerprint+'\n')
    raw=CACHE/'rust'/target/'release/libfloe_tex_native_xdv.a'
    merged=CACHE/platform/'libFloeTeXNativeXDV.a'
    libraries=[prefix/'lib'/name for name in ['libpng16.a','libgraphite2.a','libfreetype.a','libharfbuzz.a','libharfbuzz-icu.a','libicuuc.a','libicui18n.a','libicudata.a']]
    for library in libraries:
        if not library.is_file(): raise RuntimeError('Missing static dependency: '+str(library))
    # The Rust staticlib already includes the complete native dependency closure.
    shutil.copy2(raw,merged)
    members=subprocess.check_output(['/usr/bin/ar','-t',str(merged)],text=True)
    for forbidden in ['dvipdfmx.o','dpx-','tectonic_pdf_io','tectonic_engine_xdvipdfmx']:
        if forbidden in members: raise RuntimeError('Forbidden PDF object in new archive: '+forbidden)
    (CACHE/platform/'archive-members.txt').write_text(members)
    symbol_command,symbol_info=native_symbol_command(merged)
    symbol_result=subprocess.run(symbol_command,capture_output=True,text=True)
    (CACHE/platform/'defined-symbols.txt').write_text(symbol_result.stdout)
    (CACHE/platform/'symbol-audit.stderr').write_text(symbol_result.stderr)
    if symbol_result.returncode!=0:
        raise RuntimeError('The matching LLVM reader failed; retain the actual symbol-audit stderr')
    symbols=symbol_result.stdout
    for forbidden in ['_dvipdfmx_main','_pdf_files_init','_pdf_doc_get_page','_tt_engine_xdvipdfmx']:
        if forbidden in symbols: raise RuntimeError('Forbidden PDF symbol in new archive: '+forbidden)
    for required in ['_floe_tex_compile','_floe_tex_image_metadata','_floe_tex_apple_set_pdf_gate','_floe_tex_legacy_outline']:
        if required not in symbols: raise RuntimeError('Required real Apple/native implementation missing: '+required)
    symbol_info.update(archiveSHA256=hashlib.sha256(merged.read_bytes()).hexdigest(),requiredNativeExportsVerified=True,forbiddenPDFExportsAbsent=True)
    (CACHE/platform/'symbol-audit.json').write_text(json.dumps(symbol_info,indent=2)+'\n')
    return merged,prefix

def main():
    global ALLOW_SOURCE_DOWNLOADS
    parser=argparse.ArgumentParser()
    parser.add_argument('--platform',choices=['device','simulator','both'],default='both')
    parser.add_argument('--jobs',type=int,default=6)
    parser.add_argument('--allow-source-downloads',action='store_true',help='Explicitly fetch only the existing pinned five native dependencies if absent')
    parser.add_argument('--fetch-only',action='store_true')
    parser.add_argument('--package',action='store_true',help='Create device + simulator XCFramework after both builds')
    args=parser.parse_args()
    os.environ['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
    run([sys.executable,'-B',NATIVE/'Scripts/prepare_xdv_source.py','--check'])
    CACHE.mkdir(parents=True,exist_ok=True)
    ALLOW_SOURCE_DOWNLOADS=args.allow_source_downloads
    for name in ['FloeTeXAppleMetadata.h','FloeTeXAppleMetadata.m','FloeTeXLegacyOutline.h','FloeTeXLegacyOutline.c']:
        if not (NATIVE/'apple'/name).is_file(): raise RuntimeError('Missing real Apple source: '+name)
    sources=fetch_sources()
    if args.fetch_only:
        print(json.dumps({k:str(v) for k,v in sources.items()}),flush=True);return
    result={}
    for platform in ['device','simulator'] if args.platform=='both' else [args.platform]:
        library,prefix=build(platform,args.jobs,sources)
        result[platform]={'library':str(library),'prefix':str(prefix),'sha256':hashlib.sha256(library.read_bytes()).hexdigest()}
    (CACHE/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    if args.package:
        vendor=NATIVE/'Production/Vendor'
        vendor.mkdir(parents=True,exist_ok=True)
        framework=vendor/'FloeTeXNativeXDV.xcframework'
        if framework.exists(): raise RuntimeError('Keep the existing XDV artifact; choose a new owned build output')
        notices=vendor/'FloeTeXNativeXDV.NOTICES'
        run([sys.executable,NATIVE/'Scripts/collect_xdv_notices.py',
             '--graph',CACHE/'device/cargo-closure.txt',
             '--graph',CACHE/'simulator/cargo-closure.txt','--output',notices],log=CACHE/'notices.log')
        command=['xcodebuild','-create-xcframework']
        for platform in ['device','simulator']:
            library=CACHE/platform/'libFloeTeXNativeXDV.a'
            if not library.is_file(): raise RuntimeError('Build both Apple platforms before packaging')
            command+=['-library',library,'-headers',NATIVE/'include']
        include=NATIVE/'include-xdv'
        include.mkdir(exist_ok=True)
        for header in [NATIVE/'include/FloeTeXNative.h',NATIVE/'apple/FloeTeXAppleMetadata.h',NATIVE/'apple/FloeTeXLegacyOutline.h']:
            shutil.copy2(header,include/header.name)
        # SwiftPM imports the namespaced C target; never flatten a generic map.
        (include/'module.modulemap').unlink(missing_ok=True)
        command=[include if value==NATIVE/'include' else value for value in command]
        command+=['-output',framework]
        run(command,log=CACHE/'packaging.log')
        manifest={'schemaVersion':2,'product':'FloeTeXNativeXDV','output':'real XeTeX/BibTeX XDV + bounded display list; Apple renderer required for PDF','forbiddenPDFCargoAndObjectAuditPassed':True,
            'licensing':{'selectedBranches':json.loads((NATIVE/'licenses/native-xdv-selected-licenses.json').read_text()),
                'noticesSHA256':hashlib.sha256(notices.with_name(notices.name+'.txt').read_bytes()).hexdigest(),
                'noticeReceiptSHA256':hashlib.sha256(notices.with_name(notices.name+'.json').read_bytes()).hexdigest()},'engine':json.loads((NATIVE/'tectonic.source.json').read_text()),'dependencies':json.loads((NATIVE/'dependencies.json').read_text()),
            'toolchain':subprocess.check_output(['xcodebuild','-version'],text=True).strip(),'minimumOS':'26.0','symbolAudits':{platform:json.loads((CACHE/platform/'symbol-audit.json').read_text()) for platform in ['device','simulator']},'rustc':subprocess.check_output(['rustc','-Vv'],text=True).strip(),'cargo':subprocess.check_output(['cargo','--version'],text=True).strip(),
            'files':{str(p.relative_to(framework)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(framework.rglob('*')) if p.is_file()}}
        (vendor/'FloeTeXNativeXDV.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(result,indent=2),flush=True)

if __name__=='__main__':main()
