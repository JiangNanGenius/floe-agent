#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Actual namespace, environment, timeout and cancellation qualification."""
from pathlib import Path
import argparse,hashlib,json,os,platform,signal,subprocess,sys,time,uuid
from verify_linux_toolchain import qualify

def descendants(pid):
    found=set();pending=[pid]
    while pending:
        current=pending.pop()
        try:children=Path('/proc/'+str(current)+'/task/'+str(current)+'/children').read_text().split()
        except (FileNotFoundError,ProcessLookupError):continue
        for value in children:
            child=int(value)
            if child not in found:found.add(child);pending.append(child)
    return found

def identity(pid):
    try:
        text=Path('/proc/'+str(pid)+'/stat').read_text();return text[text.rindex(')')+2:].split()[19]
    except (FileNotFoundError,ProcessLookupError):return None

def lifecycle(worker,root,cancel):
    name='cancel-real-worker' if cancel else 'timeout-real-worker'
    folder=root/name;source=folder/'Source';source.mkdir(parents=True)
    text=r'\documentclass{article}\begin{document}First page.\newpage\loop\iftrue\repeat\end{document}'
    data=text.encode();(source/'main.tex').write_bytes(data)
    request={'protocol':'floe.latex.worker','version':1,'environmentID':'independent-linux-lifecycle','requestID':str(uuid.uuid4()),'timeoutSeconds':30 if cancel else 1,'buildTimestamp':int(time.time()),'manifest':{'id':str(uuid.uuid4()),'revision':0,'engine':'xeLaTeX','mainFile':'main.tex','files':[{'path':'main.tex','byteCount':len(data),'sha256':hashlib.sha256(data).hexdigest()}]}}
    path=folder/'request.json';path.write_text(json.dumps(request))
    observed={};result={'case':name,'started':time.time()};child=None
    try:
        with (folder/'stdout').open('wb') as out,(folder/'stderr').open('wb') as err:
            child=subprocess.Popen([sys.executable,'-B',str(worker),'build','--request',str(path)],stdout=out,stderr=err,start_new_session=True)
            sent=False;deadline=time.monotonic()+45
            while child.poll() is None:
                for pid in descendants(child.pid):
                    start=identity(pid)
                    if start is not None:observed[pid]=start
                log=folder/'Output/worker.log'
                engine_started=log.is_file() and 'This is' in log.read_text(errors='replace')
                if cancel and not sent and len(observed)>=3 and engine_started:
                    child.send_signal(signal.SIGTERM);sent=True
                if time.monotonic()>deadline:raise TimeoutError('Real worker did not stop')
                time.sleep(.02)
        assert child.returncode==1,'Expected a failed/cancelled real TeX build'
        receipt=json.loads((folder/'receipt.json').read_text());result['receipt']=receipt
        assert receipt.get('workerStopped') is True and receipt.get('success') is False,receipt
        if cancel:assert sent and receipt.get('cancelled') is True
        else:assert 'time limit' in receipt.get('error','').lower()
        assert len(observed)>=3,'Did not observe the actual namespace/engine process tree'
        until=time.monotonic()+3
        while time.monotonic()<until and any(identity(p)==stamp for p,stamp in observed.items()):time.sleep(.02)
        remaining=[p for p,stamp in observed.items() if identity(p)==stamp]
        assert not remaining,'A typesetting descendant survived: '+str(remaining)
        result.update(success=True,observedProcessCount=len(observed),remainingProcesses=remaining)
    except Exception as error:result.update(success=False,error=str(error))
    finally:
        if child is not None and child.poll() is None:
            os.killpg(child.pid,signal.SIGTERM)
            try:child.wait(timeout=5)
            except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
    result['duration']=time.time()-result['started'];(root/(name+'.json')).write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='receipt'}),flush=True)
    return result

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--worker',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();assert platform.system()=='Linux','Requires actual Linux namespaces'
    root=args.output.absolute();root.mkdir(parents=True,exist_ok=False);worker=args.worker.resolve()
    canary=Path('/tmp/floe-latex-private-'+uuid.uuid4().hex);value=('Private synthetic canary '+uuid.uuid4().hex).encode();canary.write_bytes(value)
    os.environ['FLOE_LATEX_CANARY']='SYNTHETIC_ENVIRONMENT_VALUE'
    text=r'''\documentclass{article}
\begin{document}
\directlua{local f=io.open("__PRIVATE_CANARY_PATH__","r"); if f then f:close(); tex.sprint("READLEAK") else tex.sprint("READISOLATED") end}
\directlua{local f=io.open("./main.tex","a"); if f then f:close(); tex.sprint("SOURCEWRITABLE") else tex.sprint("SOURCEREADONLY") end}
\directlua{tex.sprint(os.getenv("FLOE_LATEX_CANARY") and "ENVLEAK" or "ENVISOLATED")}
\directlua{local f=io.open("/proc/net/route","r"); local t=f:read("*a"); f:close(); tex.sprint(t:find("00000000",1,true) and "NETLEAK" or "NETISOLATED")}
\directlua{local f=io.open("__PRIVATE_CANARY_PATH__","w"); if f then f:write("private namespace only");f:close() end}
\end{document}
'''.replace('__PRIVATE_CANARY_PATH__',str(canary))
    try:
        result=qualify(worker,root,('isolation-lua','luaLaTeX',{'main.tex':text},['READISOLATED','SOURCEREADONLY','ENVISOLATED','NETISOLATED'],[],True))
        assert canary.read_bytes()==value,'The document changed an unmounted private file'
        results=[result,lifecycle(worker,root,False),lifecycle(worker,root,True)]
        summary={'scope':'Real Linux process/file/network/environment checks, not App authorization or Apple review','workerSHA256':hashlib.sha256(worker.read_bytes()).hexdigest(),'passed':sum(r['success'] for r in results),'total':len(results)}
        (root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
        return 0 if summary['passed']==summary['total'] else 1
    finally:canary.unlink(missing_ok=True)

if __name__=='__main__':raise SystemExit(main())
