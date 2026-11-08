# SPDX-License-Identifier: MPL-2.0
"""Fixed TeX toolchain worker for an explicitly resolved Linux exec.shell job.

Not a host interpreter, package installer, .latexmkrc runner or command tool.
The App owns the environment/run binding, transport and verified read-back.
"""
from pathlib import Path
import argparse,base64,gzip,hashlib,json,os,re,shutil,signal,subprocess,sys,time
PROTOCOL='floe.latex.worker';VERSION=1
ENGINES={'xeLaTeX':'xelatex','luaLaTeX':'lualatex','pdfLaTeX':'pdflatex','latex':'latex'}
TOOLS=['bibtex','biber','makeindex','xindy','makeglossaries','dvipdfmx','texcount','latexmk','bwrap','chktex','latexindent','latexdiff','upmendex','kpsewhich','pygmentize','asy','dvisvgm','gs','epstopdf','pdfinfo','pdftotext']
VERSION_ARGS={'pygmentize':['-V'],'pdfinfo':['-v'],'pdftotext':['-v']}
MAX_FILES=10000;MAX_FILE=256*1024*1024;MAX_PROJECT=1024*1024*1024;MAX_OUTPUT=256*1024*1024
ARTIFACT_SUFFIXES={'.pdf','.gz','.log','.aux','.bbl','.blg','.bcf','.xml','.idx','.ind','.ilg','.glo','.gls','.glg','.acn','.acr','.alg','.toc','.lof','.lot','.out','.ist','.nlo','.nls','.nlg','.fls'}
class WorkerError(Exception):pass
class Stopped(WorkerError):pass
child=None;cancelled=False
ISOLATION_NAMESPACES=('mnt','pid','net','ipc','uts','user')
# Root-without-USERNS bubblewrap does not clear the bounding set itself.
# Only this immutable system-Python launcher gets SETPCAP; every document
# executable is entered after all five capability sets read back as zero.
ROOT_PAYLOAD_LAUNCHER="# Fixed trusted launcher embedded in the hashed worker, never document code.\n# It runs inside bubblewrap's private namespaces/read-only system tree.\nimport ctypes,os,sys\nfrom pathlib import Path\n\nlibc=ctypes.CDLL(None,use_errno=True)\nlibc.prctl.argtypes=[ctypes.c_int,ctypes.c_ulong,ctypes.c_ulong,ctypes.c_ulong,ctypes.c_ulong]\nlibc.prctl.restype=ctypes.c_int\n\ndef prctl(option,a=0,b=0,c=0,d=0):\n    if libc.prctl(option,a,b,c,d)!=0:\n        error=ctypes.get_errno()\n        raise OSError(error,'TeX privilege launcher prctl '+str(option)+': '+os.strerror(error))\n\nif len(sys.argv)<2 or not os.path.isabs(sys.argv[1]):\n    raise RuntimeError('TeX privilege launcher requires a fixed absolute executable')\n\n# Refuse any gain of privilege before entering the document executable.\nprctl(38,1)  # PR_SET_NO_NEW_PRIVS\nlast=int(Path('/proc/sys/kernel/cap_last_cap').read_text().strip())\nif not 8<=last<=4096:\n    raise RuntimeError('Unsupported Linux capability range')\nfor capability in [value for value in range(last+1) if value!=8]+[8]:\n    prctl(24,capability)  # PR_CAPBSET_DROP; SETPCAP dropped last\nprctl(47,4)  # PR_CAP_AMBIENT / PR_CAP_AMBIENT_CLEAR_ALL\n\nclass Header(ctypes.Structure):\n    _fields_=[('version',ctypes.c_uint32),('pid',ctypes.c_int)]\nclass Capabilities(ctypes.Structure):\n    _fields_=[('effective',ctypes.c_uint32),('permitted',ctypes.c_uint32),('inheritable',ctypes.c_uint32)]\nlibc.capset.argtypes=[ctypes.POINTER(Header),ctypes.POINTER(Capabilities)]\nlibc.capset.restype=ctypes.c_int\nheader=Header(0x20080522,0)\nempty=(Capabilities*2)()\nif libc.capset(ctypes.byref(header),empty)!=0:\n    error=ctypes.get_errno()\n    raise OSError(error,'TeX privilege launcher capset: '+os.strerror(error))\n\nstatus=dict(line.split(':',1) for line in Path('/proc/self/status').read_text().splitlines() if ':' in line)\nkeys=('CapInh','CapPrm','CapEff','CapBnd','CapAmb')\nremaining={key:status[key].strip() for key in keys if int(status[key],16)!=0}\nif remaining or status['NoNewPrivs'].strip()!='1':\n    raise RuntimeError('TeX privilege launcher refused payload: '+repr(remaining))\nos.execv(sys.argv[1],sys.argv[1:])\n"
ISOLATION_PROBE="""# floe-latex-isolation-probe-v1
import json,os
from pathlib import Path
status=dict(line.split(':',1) for line in Path('/proc/self/status').read_text().splitlines() if ':' in line)
print(json.dumps({'namespaces':{name:os.readlink('/proc/self/ns/'+name) for name in ('mnt','pid','net','ipc','uts','user')},'status':{key:status.get(key,'').strip() for key in ('CapInh','CapPrm','CapEff','CapBnd','CapAmb','NoNewPrivs')}}))
"""

def namespace_ids():
    return {name:os.readlink('/proc/self/ns/'+name) for name in ISOLATION_NAMESPACES}

def isolated_command(args,cwd=None,source=None,output=None,cache=None):
    program=shutil.which('bwrap')
    if not program:raise WorkerError('Install bubblewrap in the selected Linux environment to isolate document inputs and workers')
    command=[program,'--die-with-parent','--new-session']
    # Floe's Linux project runner already runs as guest root in a chroot.
    # Linux refuses CLONE_NEWUSER from a chroot. Bubblewrap officially
    # supports root without a user namespace: it still creates a private
    # mount namespace and must remove all payload capabilities. Non-root
    # callers always require a user namespace; there is no try/fallback mode.
    root_mode=os.geteuid()==0
    if not root_mode:command+=['--unshare-user']
    command+=['--unshare-pid','--unshare-ipc','--unshare-uts','--unshare-net','--cap-drop','ALL']
    if root_mode:command+=['--cap-add','CAP_SETPCAP']
    command+=['--clearenv']
    # Construct an empty filesystem. Never bind /, the user's home, a task
    # workspace, another project, credentials, or the host environment.
    for path in ['/usr','/bin','/sbin','/lib','/lib64','/etc/alternatives','/etc/fonts','/etc/texmf','/etc/ld.so.cache','/etc/locale.alias','/etc/papersize','/etc/paperspecs','/var/lib/texmf','/var/cache/fontconfig']:
        if Path(path).exists():command+=['--ro-bind',path,path]
    command+=['--proc','/proc','--dev','/dev','--tmpfs','/tmp','--tmpfs','/run']
    if source is not None:command+=['--ro-bind',str(source),str(source)]
    for path in [output,cache]:
        if path is not None:command+=['--bind',str(path),str(path)]
    command+=['--chdir',str(cwd) if cwd is not None else '/']
    if root_mode:args=['/usr/bin/python3','-I','-B','-c',ROOT_PAYLOAD_LAUNCHER]+args
    return command+['--']+args

def verify_isolation():
    # Resolve the trusted helper before reading Linux namespace state so a
    # missing dependency remains actionable. The payload Python is in the
    # read-only system tree, never the task's writable venv or document root.
    command=isolated_command(['/usr/bin/python3','-I','-B','-c',ISOLATION_PROBE])
    parent=namespace_ids()
    result=subprocess.run(command,env={'PATH':os.environ.get('PATH','/usr/bin:/bin')},capture_output=True,timeout=10)
    if result.returncode!=0:raise WorkerError('The selected environment cannot isolate TeX files, network and worker processes: '+result.stderr.decode(errors='replace')[-1024:])
    try:
        proof=json.loads(result.stdout)
        required=ISOLATION_NAMESPACES[:5] if os.geteuid()==0 else ISOLATION_NAMESPACES
        if any(not proof['namespaces'].get(name) or proof['namespaces'][name]==parent[name] for name in required):raise ValueError('namespace did not change')
        status=proof['status']
        remaining={key:status[key] for key in ('CapInh','CapPrm','CapEff','CapBnd','CapAmb') if int(status[key],16)!=0}
        if remaining:raise ValueError('payload retained capabilities: '+json.dumps(remaining,sort_keys=True))
        if status['NoNewPrivs']!='1':raise ValueError('payload could gain privileges')
    except (KeyError,TypeError,ValueError) as error:
        raise WorkerError('The selected environment did not confirm TeX namespace and privilege isolation: '+str(error)) from error

def stop(signum,frame):
    global cancelled
    cancelled=True
    if child is not None and child.poll() is None:
        child.terminate()
        try:child.wait(timeout=3)
        except subprocess.TimeoutExpired:child.kill();child.wait()
    raise Stopped('Typesetting cancelled')

def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        while True:
            data=stream.read(1024*1024)
            if not data:break
            h.update(data)
    return h.hexdigest()

def child_path(root,path):
    if not isinstance(path,str) or not path or len(path.encode())>4096 or '\\' in path or ':' in path or any(ord(c)<32 for c in path):raise WorkerError('Invalid project path')
    parts=path.split('/')
    if any(not p or p in ['.','..'] or len(p.encode())>255 for p in parts):raise WorkerError('Invalid project path')
    value=root
    for part in parts:
        value=value/part
        if value.is_symlink():raise WorkerError('Symbolic links are not project files')
    if root.resolve() not in value.resolve().parents:raise WorkerError('Project path escaped its root')
    return value

def probe():
    try:verify_isolation()
    except (WorkerError,OSError,subprocess.TimeoutExpired) as error:
        return {'protocol':PROTOCOL,'version':VERSION,'engines':{},'tools':{},'workerStopped':True,'unavailableReason':str(error)}
    engines={};tools={}
    for name in list(ENGINES.values())+TOOLS:
        program=shutil.which(name)
        if program is None:continue
        try:
            p=subprocess.run(isolated_command([program]+VERSION_ARGS.get(name,['--version'])),capture_output=True,timeout=5,env={'PATH':os.environ.get('PATH','/usr/bin:/bin')})
            index_banner=False
            if name=='makeindex' and p.returncode!=0:
                # makeindex has no --version flag. A tiny stdin index verifies
                # the installed binary inside its disposable filesystem.
                p=subprocess.run(isolated_command([program],cwd=Path('/tmp')),input=b'\\indexentry{Floe}{1}\n',capture_output=True,timeout=5,env={'PATH':os.environ.get('PATH','/usr/bin:/bin')});index_banner=True
            if p.returncode==0:
                lines=(p.stderr if index_banner else (p.stdout or p.stderr)).decode(errors='replace').splitlines()
                value=lines[0][:1024] if lines else 'Installed executable verified'
                (engines if name in ENGINES.values() else tools)[name]=value
        except (OSError,subprocess.TimeoutExpired):pass
    return {'protocol':PROTOCOL,'version':VERSION,'engines':engines,'tools':tools,'shellEscape':False,'workerStopped':True}

def run_program(args,cwd,env,log,deadline,source,output,cache):
    global child
    if cancelled:raise Stopped('Typesetting cancelled')
    phase=Path(args[0]).name
    args=isolated_command(args,cwd,source,output,cache)
    # Clear inherited tokens, proxies, agent sockets and loader injection.
    # Only this document's fixed typesetting variables enter its namespace.
    separator=args.index('--')
    settings=[]
    for key,value in env.items():settings+=['--setenv',key,value]
    args[separator:separator]=settings
    remaining=deadline-time.monotonic()
    if remaining<=0:raise WorkerError('Document time limit reached')
    # Bubblewrap's monitor stays in the exec.shell job's process group. Its
    # private PID namespace joins descendants when that owned monitor stops.
    with log.open('ab') as output:
        output.write(('\nFLOE PHASE: '+phase+'\n').encode());output.flush()
        child=subprocess.Popen(args,cwd=cwd,env=env,stdout=output,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL)
        try:
            while child.poll() is None:
                if log.stat().st_size>16*1024*1024:child.terminate();raise WorkerError('Typesetting log limit reached')
                if time.monotonic()>=deadline:child.terminate();raise WorkerError('Document time limit reached')
                time.sleep(.05)
            if child.returncode!=0:raise WorkerError(phase+' failed with exit status '+str(child.returncode))
        finally:
            if child.poll() is None:
                child.terminate()
                try:child.wait(timeout=3)
                except subprocess.TimeoutExpired:child.kill();child.wait()
            child=None

def build(request_path):
    if request_path.stat().st_size>16*1024*1024:raise WorkerError('Build manifest limit reached')
    request=json.loads(request_path.read_text());root=request_path.parent.resolve();source=root/'Source';output=root/'Output'
    if source.is_symlink() or output.is_symlink():raise WorkerError('Build roots cannot be symbolic links')
    if request.get('protocol')!=PROTOCOL or request.get('version')!=VERSION:raise WorkerError('Unsupported worker protocol')
    manifest=request['manifest'];files=manifest['files']
    if not files or len(files)>MAX_FILES:raise WorkerError('Project file count limit reached')
    total=0;names=set()
    for item in files:
        path=child_path(source,item['path']);key=item['path'].lower();size=item['byteCount']
        if key in names or not isinstance(size,int) or not 0<=size<=MAX_FILE or not path.is_file() or path.stat().st_size!=size or digest(path)!=item['sha256']:raise WorkerError('Project input changed during transfer')
        names.add(key);total+=size
        if total>MAX_PROJECT:raise WorkerError('Project size limit reached')
    main=child_path(source,manifest['mainFile'])
    if manifest['mainFile'].lower() not in names:raise WorkerError('Main file is outside the project manifest')
    engine=ENGINES.get(manifest['engine']);program=shutil.which(engine) if engine else None
    if not program:raise WorkerError('The selected TeX engine is not installed in this environment')
    verify_isolation()
    output.mkdir(exist_ok=True)
    cache=root/'Cache'
    if cache.is_symlink():raise WorkerError('Build cache cannot be a symbolic link')
    cache.mkdir(exist_ok=True)
    for item in files:
        relative=Path(item['path']).parent
        if str(relative)!='.':child_path(output,str(relative)).mkdir(parents=True,exist_ok=True)
    log=output/'worker.log'
    # Kpathsea's paranoid filename mode blocks legitimate Lua font data and
    # auxiliary programs. Actual access is bounded by the verified namespace:
    # system resources/source are read-only; only output/cache are writable.
    env=dict(PATH=os.environ.get('PATH','/usr/bin:/bin'),LANG='C.UTF-8',HOME=str(cache),XDG_CACHE_HOME=str(cache),TEXMFVAR=str(cache),TEXMFCONFIG=str(cache),TEXMFCACHE=str(cache),TEXINPUTS=str(source)+'//:',BIBINPUTS=str(source)+'//:',BSTINPUTS=str(source)+'//:',TEXMFOUTPUT=str(output),openin_any='a',openout_any='a',SOURCE_DATE_EPOCH=str(max(0,int(request.get('buildTimestamp',time.time())))),FORCE_SOURCE_DATE='1',TZ='UTC')
    timeout=max(1,min(600,int(request.get('timeoutSeconds',120))));deadline=time.monotonic()+timeout
    args=[program,'-no-shell-escape','-recorder','-synctex=1','-interaction=nonstopmode','-file-line-error','-halt-on-error','-jobname=document','-output-directory='+str(output)]
    if engine=='lualatex':args+=['--nosocket']
    args+=['./'+manifest['mainFile']]
    run_program(args,source,env,log,deadline,source,output,cache)
    def tool(name,arguments,cwd=output):
        path=shutil.which(name)
        if not path:raise WorkerError('This document requires '+name+' in the selected environment')
        run_program([path]+arguments,cwd,env,log,deadline,source,output,cache)
    aux=output/'document.aux';bcf=output/'document.bcf'
    if bcf.is_file():tool('biber',['--input-directory',str(output),'--output-directory',str(output),'document'])
    elif aux.is_file() and any(b'\\bibdata{' in p.read_bytes() for p in output.rglob('*.aux') if p.is_file() and not p.is_symlink() and p.stat().st_size<16*1024*1024):tool('bibtex',['document'])
    for index in sorted(output.glob('*.idx')):
        tool('makeindex',['-o',str(index.with_suffix('.ind')),str(index)])
    for extension,result,transcript in [('glo','gls','glg'),('acn','acr','alg'),('nlo','nls','nlg')]:
        for entry in sorted(output.glob('*.'+extension)):
            style=output/'document.ist'
            arguments=['-s','nomencl.ist' if extension=='nlo' else (str(style) if style.is_file() else 'gglo.ist'),'-t',str(entry.with_suffix('.'+transcript)),'-o',str(entry.with_suffix('.'+result)),str(entry)]
            tool('makeindex',arguments)
    previous=None
    for attempt in range(6):
        run_program(args,source,env,log,deadline,source,output,cache)
        state=hashlib.sha256(b''.join(p.read_bytes() for p in sorted(output.rglob('*')) if p.suffix in ['.aux','.toc','.lof','.lot','.out'] and p.is_file() and not p.is_symlink() and p.stat().st_size<16*1024*1024)).hexdigest()
        if state==previous:break
        previous=state
    if engine=='latex':tool('dvipdfmx',['-o',str(output/'document.pdf'),str(output/'document.dvi')])
    pdf=output/'document.pdf'
    if not pdf.is_file() or pdf.open('rb').read(5)!=b'%PDF-':raise WorkerError('The engine did not produce a PDF')
    sync=output/'document.synctex.gz'
    if sync.is_file():
        if sync.stat().st_size>32*1024*1024:raise WorkerError('Source map limit reached')
        with gzip.open(sync,'rb') as stream:data=stream.read(64*1024*1024+1)
        if len(data)>64*1024*1024:raise WorkerError('Source map expansion limit reached')
        text=data.decode('utf8')
        text=re.sub(r'(?m)^(Input:\d+:)'+re.escape(str(source))+'/',r'\1',text)
        with sync.open('wb') as stream:
            with gzip.GzipFile(filename='',fileobj=stream,mode='wb',mtime=0) as zipped:zipped.write(text.encode())
    artifacts=collect_artifacts(output)
    version=subprocess.run([program,'--version'],capture_output=True,timeout=5).stdout.decode(errors='replace').splitlines()[0]
    return dict(identity(request),success=True,workerStopped=True,engineVersion=version,pdf='document.pdf',artifacts=artifacts)

def identity(request):
    manifest=request['manifest']
    return {'protocol':PROTOCOL,'version':VERSION,'projectID':manifest['id'],'revision':manifest['revision'],'requestID':request['requestID'],'environmentID':request['environmentID']}

def collect_artifacts(output):
    artifacts=[];total=0
    if not output.exists():return artifacts
    for count,path in enumerate(sorted(output.rglob('*'))):
        if count>=MAX_FILES*4:raise WorkerError('Build output file count limit reached')
        if path.is_symlink():raise WorkerError('An output was replaced by a symbolic link')
        if not path.is_file() or path.suffix not in ARTIFACT_SUFFIXES:continue
        size=path.stat().st_size;total+=size
        if size>MAX_FILE or total>MAX_OUTPUT:raise WorkerError('Build output limit reached')
        artifacts.append({'path':path.relative_to(output).as_posix(),'byteCount':size,'sha256':digest(path)})
        if len(artifacts)>MAX_FILES:raise WorkerError('Build artifact count limit reached')
    return artifacts

def failed_receipt(request_path,error):
    value={'protocol':PROTOCOL,'version':VERSION,'success':False,'workerStopped':child is None,'cancelled':cancelled,'error':str(error)[:8192]}
    try:
        request=json.loads(request_path.read_text());value.update(identity(request))
        value['artifacts']=collect_artifacts(request_path.parent/'Output')
    except (OSError,KeyError,ValueError,WorkerError):pass
    return value

def read_range(path,offset,length):
    if offset<0 or not 1<=length<=16384 or path.is_symlink():raise WorkerError('Invalid artifact byte range')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as stream:
        size=os.fstat(stream.fileno()).st_size
        if offset>size:raise WorkerError('Artifact offset exceeded its length')
        stream.seek(offset);data=stream.read(length)
    return {'protocol':PROTOCOL,'version':VERSION,'offset':offset,'bytes':base64.b64encode(data).decode()}

def main():
    p=argparse.ArgumentParser();p.add_argument('action',choices=['probe','build','read','receipt','cleanup']);p.add_argument('--request',type=Path);p.add_argument('--file');p.add_argument('--offset',type=int,default=0);p.add_argument('--length',type=int,default=8192);a=p.parse_args()
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    if a.action=='probe':result=probe()
    elif a.action in ['read','receipt']:
        if a.request is None:raise WorkerError('Missing build request')
        root=a.request.absolute().parent
        if root.is_symlink() or a.request.is_symlink():raise WorkerError('Build roots cannot be symbolic links')
        path=child_path(root/'Output',a.file) if a.action=='read' else root/'receipt.json'
        result=read_range(path,a.offset,a.length)
    elif a.action=='cleanup':
        if a.request is None or a.request.is_symlink():raise WorkerError('Missing build request')
        root=a.request.absolute().parent
        if root.is_symlink() or not (root/'receipt.json').is_file():raise WorkerError('No stopped build receipt exists')
        receipt=json.loads((root/'receipt.json').read_text());request=json.loads(a.request.read_text())
        expected=identity(request)
        if receipt.get('workerStopped') is not True or any(receipt.get(k)!=v for k,v in expected.items()):raise WorkerError('Build cleanup identity changed')
        # Only a private UUID request directory, verified against its manifest.
        if root.name.lower()!=str(request['requestID']).lower() or root.parent.name.lower()!=str(request['manifest']['id']).lower() or root.parent.parent.name!='.floe-latex':raise WorkerError('Build cleanup root changed')
        shutil.rmtree(root)
        result=dict(expected,success=True,workerStopped=True,cleaned=True)
    else:
        if a.request is None:raise WorkerError('Missing build request')
        request=a.request.resolve()
        try:result=build(request)
        except Exception as error:result=failed_receipt(request,error)
        data=json.dumps(result,separators=(',',':')).encode()
        temporary=request.parent/'receipt.tmp';temporary.write_bytes(data);temporary.replace(request.parent/'receipt.json')
        # Keep job summaries small. The host reads the complete durable receipt
        # in bounded chunks, then verifies this exact length and digest.
        result={k:v for k,v in result.items() if k!='artifacts'}
        if 'error' in result:result['error']=result['error'][:512]
        result.update(receiptBytes=len(data),receiptSHA256=hashlib.sha256(data).hexdigest())
    print('FLOE_LATEX_RECEIPT '+base64.b64encode(json.dumps(result,separators=(',',':')).encode()).decode(),flush=True)
    if result.get('success') is False:raise SystemExit(1)
if __name__=='__main__':main()
