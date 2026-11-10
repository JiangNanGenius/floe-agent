#!/usr/bin/env python3
"""Collect actual Cargo closure notices and the selected native component texts."""
from pathlib import Path
import argparse, hashlib, json, os, re, tarfile, subprocess

NATIVE = Path(__file__).resolve().parents[1]
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def scalar(text, name):
    match = re.search(r'^'+re.escape(name)+r'\s*=\s*"([^"]*)"\s*$', text, re.M)
    return match.group(1) if match else None

def registry_notices(cargo, name, version, checksum):
    choices = sorted((cargo/'registry/cache').glob('*/'+name+'-'+version+'.crate'))
    archive = next((path for path in choices if sha(path)==checksum),None)
    if archive is None: raise RuntimeError('Exact cached registry source archive missing: '+name+' '+version)
    prefix = name+'-'+version+'/'
    with tarfile.open(archive) as source:
        members = {member.name[len(prefix):]:member for member in source.getmembers()
                   if member.name.startswith(prefix) and member.isfile()
                   and '..' not in Path(member.name).parts}
        def read(member):
            if member.size > 2*1024*1024: raise RuntimeError('Oversized registry notice: '+name)
            return source.extractfile(member).read()
        manifest = read(members['Cargo.toml']).decode('utf-8')
        declared = scalar(manifest,'license-file')
        keys = {key for key in members if len(Path(key).parts)<=3 and
                re.match(r'(?i)^(license|licence|copying|copyright|notice|unlicense)([._-]|$)',Path(key).name)}
        if declared:
            if Path(declared).is_absolute() or '..' in Path(declared).parts: raise RuntimeError('Registry license escapes archive')
            keys.add(declared)
        notices = [(key,read(members[key])) for key in sorted(keys)]
    return scalar(manifest,'license'),notices

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--graph', action='append', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    a = p.parse_args()
    packages = set()
    for graph in a.graph:
        for line in graph.read_text().splitlines():
            match = re.match(r'^([A-Za-z0-9_-]+) v([^\s]+)', line)
            if match: packages.add(match.groups())
    if not packages or any(n in {'tectonic_pdf_io','tectonic_engine_xdvipdfmx'} for n,v in packages):
        raise RuntimeError('Missing/forbidden actual Cargo closure')
    lock = {}
    for block in (NATIVE/'bridge/Cargo.lock').read_text().split('[[package]]')[1:]:
        name, version, checksum = (scalar(block,k) for k in ['name','version','checksum'])
        if checksum: lock[(name,version)] = checksum
    paths = {}
    for manifest in [NATIVE/'bridge/Cargo.toml', NATIVE/'tectonic/Cargo.toml', *(NATIVE/'tectonic/crates').glob('*/Cargo.toml')]:
        text = manifest.read_text()
        paths[(scalar(text,'name'),scalar(text,'version'))] = manifest.parent
    cargo = Path(os.environ.get('CARGO_HOME',str(Path.home()/'.cargo')))
    parts = ['FloeTeXNativeXDV — exact native and Rust component notices\n'
             'The product selects CPL-1.0 for TECkit, FTL for FreeType, MPL-2.0 for Graphite2.\n'
             'The umbrella MIT license does not replace embedded component terms.\n'
             'Source and local modifications are available in the matching immutable Floe source,\n'
             'FloeAgent/Modules/FloeLaTeXKit/Native, with pinned source references.\n']
    rows, missing = [], []
    for name,version in sorted(packages):
        directory = paths.get((name,version))
        checksum = lock.get((name,version))
        if checksum:
            expression, blobs = registry_notices(cargo,name,version,checksum)
        else:
            if directory is None: raise RuntimeError('Exact native path package missing: '+name+' '+version)
            text = (directory/'Cargo.toml').read_text()
            expression = scalar(text,'license')
            files = set()
            declared = scalar(text,'license-file')
            if declared:
                path = (directory/declared).resolve()
                if directory.resolve() not in path.parents: raise RuntimeError('License path escapes package')
                files.add(path)
            for path in directory.iterdir():
                if path.is_file() and re.match(r'(?i)^(license|licence|copying|copyright|notice|unlicense)([._-]|$)',path.name):
                    if directory.resolve() not in path.resolve().parents: raise RuntimeError('Native notice link escapes source')
                    files.add(path)
            if name.startswith('tectonic'): files.add(NATIVE/'tectonic/LICENSE')
            if name=='floe_tex_native_xdv': files.add(NATIVE/'licenses/MPL-2.0.txt')
            if any(not file.is_file() or file.stat().st_size>2*1024*1024 for file in files):
                raise RuntimeError('Missing/oversized native license text: '+name)
            blobs = [(file.name,file.read_bytes()) for file in sorted(files)]
        parts.append('\n=== Component '+name+' '+version+' ===\nLicense expression: '+str(expression)+'\n'
                     +( 'Exact registry source: https://crates.io/api/v1/crates/'+name+'/'+version+'/download\nSHA256: '+checksum+'\n' if checksum else 'Matching pinned native source tree.\n'))
        if not blobs:
            missing.append({'name':name,'version':version,'license':expression})
            if expression not in ['Apache-2.0','Apache-2.0 OR MIT']:
                raise RuntimeError('No original standalone notice or supported standard license: '+name)
            parts.append('This published source archive supplies no separate LICENSE/NOTICE file. '
                         'Apache-2.0 is selected; its complete standard text appears in the collected Apache license sections.\n')
        notices = []
        for filename,data in blobs:
            notices.append({'file':filename,'sha256':hashlib.sha256(data).hexdigest()})
            parts.append('\n=== '+name+' '+version+' / '+filename+' ===\n'+data.decode('utf-8',errors='replace'))
        rows.append({'name':name,'version':version,'licenseExpression':expression,'registryChecksum':checksum,'notices':notices})
    for file in sorted((NATIVE/'licenses').iterdir()):
        if file.is_file(): parts.append('\n=== Native component / '+file.name+' ===\n'+file.read_text(errors='replace'))
    text_path = a.output.with_name(a.output.name+'.txt')
    text_path.parent.mkdir(parents=True,exist_ok=True)
    text_path.write_text('\n'.join(parts))
    receipt = {'schemaVersion':1,'graphs':[{'sha256':sha(g)} for g in a.graph],
        'sourcePin':json.loads((NATIVE/'tectonic.source.json').read_text()),
        'nativeSelectedLicensesSHA256':sha(NATIVE/'licenses/native-xdv-selected-licenses.json'),
        'packages':rows,'packagesWithoutStandaloneNoticeFile':missing,'registryNoticeBytesFrom':'Exact cached .crate archives verified against original Cargo.lock checksums; no extraction-metadata assumption','textSHA256':sha(text_path)}
    a.output.with_name(a.output.name+'.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps({'packages':len(rows),'missingStandaloneNotices':len(missing),'textSHA256':sha(text_path)}))

if __name__=='__main__': main()
