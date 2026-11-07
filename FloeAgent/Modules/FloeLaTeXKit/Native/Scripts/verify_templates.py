#!/usr/bin/env python3
"""Qualify starter sources with the actual fixed native ABI runner."""
from pathlib import Path
import argparse,json,re,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--runner',type=Path,required=True);p.add_argument('--evidence',type=Path,required=True);p.add_argument('--cache',type=Path,required=True);a=p.parse_args()
native=Path(__file__).resolve().parents[1];source=(native.parent/'Sources/FloeLaTeXCore/Templates.swift').read_text()
fixtures=re.findall(r'\.init\(id:"([^"]+)".*?source:#"""\n(.*?)\n        """#',source,re.S)
a.evidence.mkdir(parents=True,exist_ok=True);results=[]
for name,content in fixtures:
    root=(a.evidence/name).resolve();project=root/'Source';project.mkdir(parents=True,exist_ok=True)
    tex='\n'.join(line[8:] if line.startswith('        ') else line for line in content.splitlines())+'\n'
    (project/'main.tex').write_text(tex);(project/'references.bib').write_text('% References\n')
    if name=='thesis':
        (project/'chapters').mkdir(exist_ok=True);(project/'chapters/introduction.tex').write_text('\\chapter{引言}\n在这里开始写作。\n')
    request={'sourceRoot':str(project),'outputRoot':str(root/'Output'),'mainFile':'main.tex','cacheRoot':str(a.cache.resolve()),'timeoutSeconds':120,'offline':False}
    (root/'request.json').write_text(json.dumps(request));start=time.monotonic()
    process=subprocess.run([str(a.runner.resolve()),str(root/'request.json')],text=True,capture_output=True,timeout=1800)
    (root/'response.json').write_text(process.stdout);(root/'stderr.log').write_text(process.stderr)
    try: response=json.loads(process.stdout.strip().splitlines()[-1])
    except Exception:response={'success':False,'error':'Invalid ABI output'}
    item={'template':name,'success':response.get('success',False),'seconds':round(time.monotonic()-start,3),'error':response.get('error')}
    if item['success']:
        request['offline']=True;(root/'offline-request.json').write_text(json.dumps(request))
        offline=subprocess.run([str(a.runner.resolve()),str(root/'offline-request.json')],text=True,capture_output=True,timeout=180)
        (root/'offline-response.json').write_text(offline.stdout)
        item['offlineSuccess']=json.loads(offline.stdout.strip().splitlines()[-1]).get('success',False)
    results.append(item);print(json.dumps(item,ensure_ascii=False),flush=True)
    (a.evidence/'RESULT.json').write_text(json.dumps(results,indent=2,ensure_ascii=False)+'\n')
if len(results)!=7 or not all(r['success'] and r.get('offlineSuccess') for r in results):raise SystemExit(1)
