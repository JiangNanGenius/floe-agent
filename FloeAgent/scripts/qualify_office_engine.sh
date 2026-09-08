#!/usr/bin/env bash
# Pinned, isolated engine qualification. This never enables unverified app tools.
set -euo pipefail
mode="${1:---check}"
case "$mode" in --check|--build) ;; *) printf 'Usage: %s [--check|--build]\n' "$0" >&2; exit 64 ;; esac
script_dir="$(cd "$(dirname "$0")" && pwd)"
lock_file="$script_dir/../ThirdParty/Collabora/engine.lock.json"
build_root="${FLOE_OFFICE_BUILD_ROOT:-${TMPDIR:-/tmp}/floe-office-engine}"
mkdir -p "$build_root"
python3 - "$lock_file" "$build_root" <<'PY'
import json,os,shutil,subprocess,sys
lock=json.load(open(sys.argv[1])); root=sys.argv[2]
missing=[x for x in ['git','make','autoconf','automake','glibtool','pkg-config','node','xcrun'] if not shutil.which(x)]
free=shutil.disk_usage(root).free/1024**3
sdk=subprocess.run(['xcrun','--sdk','iphoneos','--show-sdk-path'],capture_output=True,text=True) if shutil.which('xcrun') else None
report={'commit':lock['commit'],'freeGiB':round(free,2),'requiredFreeGiB':lock['minimumFreeGiB'],
 'missingTools':missing,'iphoneosSDKAvailable':sdk is not None and sdk.returncode==0,
 'nativeBuildPassed':False,'embeddedEditorPassed':False,'deviceRoundtripPassed':False,
 'gateNote':lock['minimumFreeGiBNote'],'recommendedFreeGiB':lock['recommendedFreeGiB'],'buildReserveGiB':lock['buildReserveGiB']}
report['preflightPassed']=not missing and report['iphoneosSDKAvailable'] and free>=lock['minimumFreeGiB']
with open(os.path.join(root,'qualification.json'),'w') as f: json.dump(report,f,indent=2)
print(json.dumps(report,indent=2))
if not report['preflightPassed']: sys.exit(2)
PY
[[ "$mode" == "--check" ]] && exit 0
source_dir="$build_root/source"
commit="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["commit"])' "$lock_file")"
repository="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["repository"])' "$lock_file")"
if [[ ! -e "$source_dir" ]]; then
  git init "$source_dir"
  git -C "$source_dir" remote add origin "$repository"
  git -C "$source_dir" fetch --depth=1 origin "$commit"
  git -C "$source_dir" checkout --detach FETCH_HEAD
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$commit" ]] || { echo 'Source commit mismatch' >&2; exit 3; }
git -C "$source_dir" diff --quiet
git -C "$source_dir" diff --cached --quiet
python3 - "$build_root" <<'PYBUILD'
import json,os,shutil,signal,subprocess,sys,time
root=sys.argv[1]; source=os.path.join(root,'source'); engine=os.path.join(source,'engine')
report_path=os.path.join(root,'qualification.json'); report=json.load(open(report_path))
commands=[('engine-configure',engine,['./autogen.sh','--with-distro=CPiOS','--disable-debug','--disable-dbgutil']),
 ('engine-build',engine,['make','-j2']),('editor-autogen',source,['./autogen.sh']),
 ('editor-configure',source,['./configure','--enable-iosapp','--with-app-name=Floe Office Qualification',
 '--with-app-package-name=org.floeagent.officequalification','--enable-experimental','--with-vendor=Floe','--with-lo-builddir='+engine]),
 ('editor-build',source,['make','-j2'])]
def save():
 with open(report_path,'w') as f: json.dump(report,f,indent=2)
for stage,cwd,command in commands:
 report['stage']=stage;save()
 process=subprocess.Popen(command,cwd=cwd,start_new_session=True)
 try:
  while process.poll() is None:
   free=shutil.disk_usage(root).free/1024**3
   if free<report['buildReserveGiB']:
    report['resourceStop']='disk reserve reached';report['freeGiB']=round(free,2);save()
    raise RuntimeError('Native build stopped at the disk reserve; no app integration was enabled')
   time.sleep(2)
  if process.returncode:
   report['failedStage']=stage;report['exitCode']=process.returncode;save()
   raise SystemExit(process.returncode)
 finally:
  if process.poll() is None:
   os.killpg(process.pid,signal.SIGTERM)
   try: process.wait(timeout=20)
   except subprocess.TimeoutExpired: os.killpg(process.pid,signal.SIGKILL);process.wait()
PYBUILD
python3 - "$build_root" <<'PY'
import json,os,sys
root=sys.argv[1]; path=os.path.join(root,'qualification.json')
report=json.load(open(path)); libs=os.path.join(root,'source/engine/workdir/CustomTarget/ios/ios-all-static-libs.list')
if not os.path.isfile(libs) or not open(libs).read().strip(): raise SystemExit('Missing native archive manifest')
report['nativeBuildPassed']=True
report['nativeArchiveManifest']=libs
# This gate deliberately does not certify embedding, licensing or file fidelity.
with open(path,'w') as f: json.dump(report,f,indent=2)
print(json.dumps(report,indent=2))
PY
