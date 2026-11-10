#!/usr/bin/env python3
"""Read-only: admit only the reviewed XDV product; reject the old PDF experiment."""
from pathlib import Path
import argparse, hashlib, json, re, subprocess, sys, plistlib

NATIVE = Path(__file__).resolve().parents[1]
PRODUCT = 'FloeTeXNativeXDV'
BINARY_TARGET = 'FloeTeXNativeXDVBinary'
PRODUCT_PATH = 'Native/Production/Vendor/FloeTeXNativeXDV.xcframework'
FORBIDDEN_SYMBOLS = ['_dvipdfmx_main','_pdf_files_init','_pdf_doc_get_page','_tt_engine_xdvipdfmx']

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

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--package-root',type=Path,default=NATIVE.parent)
    p.add_argument('--source-root',type=Path,default=NATIVE/'tectonic')
    p.add_argument('--binary',type=Path,help='Optional actual static archive or App executable')
    p.add_argument('--artifact-manifest',type=Path,help='Optional exact production XCFramework manifest')
    a = p.parse_args()
    package = a.package_root.resolve()
    swift = (package/'Package.swift').read_text()
    targets = re.findall(r'\.binaryTarget\s*\(\s*name\s*:\s*"([^"]+)"\s*,\s*path\s*:\s*"([^"]+)"',swift)
    if targets != [(BINARY_TARGET,PRODUCT_PATH)] or len(re.findall(r'\.binaryTarget\s*\(',swift)) != 1:
        raise RuntimeError('The production package must declare only the reviewed XDV binary target/path')
    dependency = r'\.target\s*\(\s*name\s*:\s*"FloeTeXNativeXDV"\s*,\s*condition\s*:\s*\.when\s*\(\s*platforms\s*:\s*\[\s*\.iOS\s*\]\s*,?\s*\)\s*,?\s*\)'
    if not re.search(dependency,swift):
        raise RuntimeError('The two-slice native dependency must be explicitly limited to iOS')
    binary_dependency=dependency.replace('FloeTeXNativeXDV\"','FloeTeXNativeXDVBinary\"')
    if not re.search(binary_dependency,swift) or 'path:"Sources/FloeTeXNativeXDVBridge"' not in swift:
        raise RuntimeError('The reviewed archive must be reached through the iOS namespaced C bridge')
    wrapper=package/'Sources/FloeTeXNativeXDVBridge'
    for expected in [NATIVE/'include/FloeTeXNative.h',NATIVE/'apple/FloeTeXAppleMetadata.h',NATIVE/'apple/FloeTeXLegacyOutline.h']:
        if (wrapper/'include'/expected.name).read_bytes()!=expected.read_bytes():
            raise RuntimeError('The namespaced C bridge header differs from the reviewed native ABI')
    if re.search(r'"[^"\n]*Native/Experiment(?:/|")',swift):
        raise RuntimeError('The experimental binary path entered the production package')
    old_import = re.compile(r'\bimport\s+(?:(?:struct|class|enum|protocol|func|let|var|typealias)\s+)?FloeTeXNative(?:Experiment)?\b')
    for source in (package/'Sources').rglob('*.swift'):
        if old_import.search(source.read_text()):
            raise RuntimeError('Old experimental ABI imported by production: '+str(source.relative_to(package)))
    subprocess.run([sys.executable,'-B',str(NATIVE/'Scripts/prepare_xdv_source.py'),
                    '--check','--source-root',str(a.source_root.resolve())],check=True)
    artifact_checked = False
    if a.artifact_manifest is not None:
        record = json.loads(a.artifact_manifest.read_text())
        if record.get('product')!=PRODUCT or record.get('forbiddenPDFCargoAndObjectAuditPassed') is not True:
            raise RuntimeError('Missing actual production Cargo/object audit record')
        framework = a.artifact_manifest.parent/(PRODUCT+'.xcframework')
        if not record.get('files') or 'Info.plist' not in record['files']:
            raise RuntimeError('Production artifact manifest has no actual framework identities')
        info = plistlib.loads((framework/'Info.plist').read_bytes())
        slices = info.get('AvailableLibraries',[])
        if len(slices)!=2 or {(row.get('SupportedPlatform'),row.get('SupportedPlatformVariant','')) for row in slices}!={('ios',''),('ios','simulator')} or any(row.get('SupportedArchitectures')!=['arm64'] for row in slices):
            raise RuntimeError('Production artifact must contain the reviewed two arm64 iOS slices')
        for item in slices:
            if (framework/item['LibraryIdentifier']/item['HeadersPath']/'module.modulemap').exists():
                raise RuntimeError('A generic static-library module map would collide with existing native packages')
        for relative,digest in record['files'].items():
            rel = Path(relative)
            if rel.is_absolute() or '..' in rel.parts: raise RuntimeError('Invalid artifact file identity')
            path = framework/rel
            if not path.is_file() or path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
                raise RuntimeError('Production artifact identity differs: '+relative)
        notices = a.artifact_manifest.parent/(PRODUCT+'.NOTICES.txt')
        if hashlib.sha256(notices.read_bytes()).hexdigest()!=record['licensing']['noticesSHA256']:
            raise RuntimeError('Production component notices do not match the linked artifact manifest')
        artifact_checked = True
    native_seen = False
    if a.binary is not None:
        symbol_command,_=native_symbol_command(a.binary)
        result = subprocess.run(symbol_command,capture_output=True,text=True,check=True)
        for symbol in FORBIDDEN_SYMBOLS:
            if symbol in result.stdout: raise RuntimeError('Forbidden old PDF backend symbol: '+symbol)
        native_seen = '_floe_tex_compile' in result.stdout
        with a.binary.open('rb') as stream: archive = stream.read(8)==b'!<arch>\n'
        if archive:
            members = subprocess.check_output(['ar','-t',str(a.binary)],text=True)
            for token in ['dvipdfmx.o','dpx-','tectonic_pdf_io','tectonic_engine_xdvipdfmx']:
                if token in members: raise RuntimeError('Forbidden PDF object in actual native archive')
            if not native_seen: raise RuntimeError('Actual native archive has no real compile entrypoint')
    print(json.dumps({'status':'pass','productionPackage':'FloeLaTeXKit','productionBinaryTarget':PRODUCT,
        'sourceOnly':a.binary is None and not artifact_checked,'artifactHashesChecked':artifact_checked,
        'binarySymbolsChecked':a.binary is not None,'nativeCompileEntrypointSeen':native_seen,
        'nativeExperiment':'Separate historical GPL PDF archive; excluded from production'}))

if __name__=='__main__': main()
