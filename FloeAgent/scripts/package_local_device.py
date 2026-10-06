from pathlib import Path
import subprocess, json, plistlib, hashlib, shutil, argparse, zipfile
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
# Preserve the successful raw device build before normalization/signing.
subprocess.run(['ditto','-c','-k','--keepParent',str(app),str(out/'raw-device-app.zip')],check=True)
stage=root/'Local/Scratch'/('build'+info['CFBundleVersion']+'-transfer'); assert not stage.exists()
(stage/'Payload').mkdir(parents=True)
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
appuuid=subprocess.check_output(['dwarfdump','--uuid',str(app/info['CFBundleExecutable'])],text=True).split()[1]
ds=symbols/(app.name+'.dSYM');assert ds.exists()
dsymuuid=subprocess.check_output(['dwarfdump','--uuid',str(ds)],text=True).split()[1];assert appuuid==dsymuuid
source=args.source
p={'source_sha':source,'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'xcode_build':info['DTXcodeBuild'],'sdk':info['DTSDKName'],'app_uuid':appuuid,'dsym_uuid':dsymuuid,'qualification':args.qualification}
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
