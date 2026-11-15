from pathlib import Path
import subprocess, json, plistlib, hashlib, argparse, os, sys, tempfile, zipfile
parser=argparse.ArgumentParser()
parser.add_argument("--products",type=Path,required=True)
parser.add_argument("--source",required=True)
parser.add_argument("--qualification",required=True)
args=parser.parse_args()
root=Path(__file__).resolve().parents[2]
products=args.products.resolve()
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()==args.source
assert not subprocess.check_output(['git','status','--porcelain','--','FloeAgent'],cwd=root,text=True).strip(), 'Commit App source before packaging'
apps=list(products.glob('*.app')); assert len(apps)==1,apps
app=apps[0]; info=plistlib.loads((app/'Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='org.floeagent.ios'
assert info['CFBundleVersion'].isdigit()
assert info['DTSDKName'].startswith('iphoneos')
out=root/'Local/Artifacts'/('build'+info['CFBundleVersion']);out.mkdir(exist_ok=True)
assert not (out/'local-device.zip').exists(), 'Never overwrite an existing release package'
raw_archive = out / 'raw-device-app.zip'
raw_exists = f'Existing raw device archive must be preserved: {raw_archive}'
if os.path.lexists(raw_archive):
    raise SystemExit(raw_exists)
stage=root/'Local/Scratch'/('build'+info['CFBundleVersion']+'-transfer'); assert not stage.exists()
# Store the completed archive atomically. A competing producer may claim its
# name at any point while ditto is compressing the original device App.
with tempfile.TemporaryDirectory(prefix='.raw-device-app-', dir=out) as scratch:
    candidate = Path(scratch) / raw_archive.name
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(app), str(candidate)], check=True)
    try:
        os.link(candidate, raw_archive)
    except FileExistsError:
        raise SystemExit(raw_exists) from None
stage.mkdir(parents=True)
(stage/'Payload').mkdir()
subprocess.run(['ditto',str(app),str(stage/'Payload'/app.name)],check=True)
normalized=stage/'Payload'/app.name
subprocess.run(['python3',str(root/'FloeAgent/scripts/prepare_app_store_bundle.py'),'--app',str(normalized),'--report',str(stage/'bundle-normalization.json')],check=True)
stub=normalized/'Frameworks/libc++.tbd'
if stub.exists():
 sdk=Path(subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],text=True).strip())
 assert not stub.is_symlink() and stub.read_bytes()==(sdk/'usr/lib/libc++.tbd').read_bytes()
 stub.unlink()
symbols=stage/'symbols';symbols.mkdir()
for dsym in products.glob('*.dSYM'):
 subprocess.run(['ditto',str(dsym),str(symbols/dsym.name)],check=True)
ds=symbols/(app.name+'.dSYM')
strip_report = json.loads(subprocess.check_output([
    sys.executable, '-B', str(root/'FloeAgent/scripts/strip_device_main.py'),
    str(app), str(normalized), str(ds),
], text=True))
source=args.source
p={'source_sha':source,'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'xcode_build':info['DTXcodeBuild'],'sdk':info['DTSDKName'],'app_uuid':strip_report['uuid'],'dsym_uuid':strip_report['dsym_uuid'],'qualification':args.qualification,'main_executable_strip':strip_report}
(stage/'provenance.json').write_text(json.dumps(p,indent=2)+'\n')
subprocess.run(['ditto','-c','-k','.',str(out/'local-device.zip')],cwd=stage,check=True)
h=hashlib.sha256()
with (out/'local-device.zip').open('rb') as f:
 for block in iter(lambda:f.read(8*1024*1024),b''): h.update(block)
p['transport_sha256']=h.hexdigest()
(out/'provenance.json').write_text(json.dumps(p,indent=2)+'\n')
print(json.dumps(p,indent=2))

with zipfile.ZipFile(out/"local-device.zip") as archive:
 assert archive.testzip() is None
