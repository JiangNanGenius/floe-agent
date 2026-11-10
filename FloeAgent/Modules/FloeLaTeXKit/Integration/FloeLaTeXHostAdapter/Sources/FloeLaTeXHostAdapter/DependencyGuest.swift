// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Compiled internal helper, executed only by LaTeXShellTransport in its
/// already-resolved Linux environment. Project text is structured data; it
/// cannot supply commands, package sources, URLs or installation flags.
enum LaTeXDependencyGuest {
    static let source = #"""
import base64,json,os,pathlib,re,shutil,subprocess,sys,time,uuid
sys.dont_write_bytecode=True
os.environ.update(TMPDIR='/tmp',TMP='/tmp',TEMP='/tmp',LANG='C.UTF-8',LC_ALL='C.UTF-8')
PREFIX='FLOE_LATEX_DEPENDENCIES '
LOGS=[]
PROGRAMS={'python3','bwrap','kpsewhich','pdfinfo','xelatex','lualatex','pdflatex','latex','bibtex','biber','makeindex','xindy','makeglossaries','dvipdfmx','upmendex','fc-list'}
TEX_EXTENSIONS={'sty','cls','tex','def','fd','clo','bst','bbx','cbx','lbx','enc','map','tfm'}
def require(condition,message):
    if not condition:raise RuntimeError(message)
def package_name(value):
    return isinstance(value,str) and len(value)<=192 and re.fullmatch(r'[a-z0-9][a-z0-9+.-]*(?::[a-z0-9][a-z0-9-]*)?',value) is not None and value.split(':')[0] not in {'texlive','texlive-full'} and not value.split(':')[0].endswith('-doc')
def tex_name(value):
    return isinstance(value,str) and len(value)<=192 and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.+-]*',value) is not None and value.rsplit('.',1)[-1] in TEX_EXTENSIONS
def font_name(value):
    return isinstance(value,str) and 0<len(value)<=256 and not value.startswith('-') and not any(ord(c)<32 or c in '\\{}\x7f' for c in value)
def runtime_file(path):
    if not os.path.isabs(path) or not os.path.isfile(path):return False
    resolved=os.path.realpath(path)
    return any(resolved.startswith(prefix) for prefix in ('/usr/','/bin/','/sbin/','/lib/','/lib64/','/etc/texmf/','/var/lib/texmf/','/var/cache/fontconfig/'))
def bounded(command,timeout=60,check=True,environment=None):
    result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf-8',errors='replace',timeout=timeout,env=environment)
    if len(result.stdout.encode())+len(result.stderr.encode())>8*1024*1024: raise RuntimeError('Resource lookup output exceeded the limit')
    if check and result.returncode: raise RuntimeError('Resource lookup failed: '+command[0]+': '+result.stderr[-2000:])
    return result
def receipt(value):
    envelope=dict(protocolName='floe.latex.dependencies',version=1,projectID=INPUT['projectID'],revision=INPUT['revision'],inputDigest=INPUT['inputDigest'],result=dict(value,preparationLogs=LOGS))
    raw=json.dumps(envelope,separators=(',',':'),ensure_ascii=False).encode()
    if len(raw)>196608: raise RuntimeError('Resource receipt exceeded the limit')
    print(PREFIX+base64.b64encode(raw).decode(),flush=True)
def versions(packages):
    if not packages: return {}
    require(len(packages)<=512 and all(package_name(p) for p in packages),'Invalid package identity')
    result=bounded(['dpkg-query','-W','-f=${binary:Package}\t${Version}\t${db:Status-Status}\n']+packages,check=False)
    values={}
    for line in result.stdout.splitlines():
        parts=line.split('\t')
        if len(parts)==3 and parts[2]=='installed' and package_name(parts[0]): values[parts[0]]=parts[1][:256]
    return values
def probe(programs,files,fonts):
    require(len(programs)<=32 and all(p in PROGRAMS for p in programs),'Invalid required program')
    require(len(files)<=2048 and all(tex_name(f) for f in files),'Invalid required TeX file')
    require(len(fonts)<=128 and all(font_name(f) for f in fonts),'Invalid required font')
    resolved={};missing_programs=[];missing_files=[];missing_fonts=[]
    if fonts and 'fc-list' not in programs: programs=programs+['fc-list']
    for program in programs:
        found=shutil.which(program)
        if found: resolved['program:'+program]=found
        else: missing_programs.append(program)
    kpse=shutil.which('kpsewhich')
    # Match the compiler's read-only system resources. A user's private TeX
    # tree/home font outside its namespace must not be advertised as usable.
    environment=dict(PATH=os.environ.get('PATH','/usr/bin:/bin'),LANG='C.UTF-8',LC_ALL='C.UTF-8',HOME='/nonexistent/floe-dependencies',TEXMFHOME='/nonexistent/floe-dependencies',TEXINPUTS=':',BIBINPUTS=':',BSTINPUTS=':')
    deadline=time.monotonic()+120
    for name in files:
        if time.monotonic()>deadline: raise RuntimeError('Resource lookup time limit exceeded')
        result=bounded([kpse,name],timeout=15,check=False,environment=environment) if kpse else None
        paths=result.stdout.splitlines() if result and result.returncode==0 else []
        path=next((p for p in paths if runtime_file(p)),None)
        if path: resolved['texFile:'+name]=path
        else: missing_files.append(name)
    if missing_files and not shutil.which('apt-file'):missing_programs.append('apt-file')
    families=set()
    if fonts and shutil.which('fc-list'):
        output=bounded(['fc-list','--format','%{family}|%{fullname}|%{postscriptname}\n',':'],environment=environment).stdout
        for line in output.splitlines():
            for field in line.split('|'):
                families.update(name.strip().casefold() for name in field.split(',') if name.strip())
    for font in fonts:
        # fc-match always has a best fallback. Only an exact installed family,
        # full name/PostScript name or exact TeX font file satisfies the name.
        if font.casefold() in families: resolved['fontFamily:'+font]=font
        else:
            path=None
            if kpse and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.+-]*',font):
                for suffix in ('.otf','.ttf','.ttc'):
                    result=bounded([kpse,font+suffix],timeout=15,check=False,environment=environment)
                    candidate=result.stdout.strip()
                    if result.returncode==0 and runtime_file(candidate): path=candidate;break
            if path: resolved['fontFamily:'+font]=path
            else: missing_fonts.append(font)
    return dict(missingPrograms=sorted(set(missing_programs)),missingFiles=sorted(set(missing_files)),missingFonts=sorted(set(missing_fonts)),resolved=resolved)
def privilege():
    if os.geteuid()==0:return []
    if not shutil.which('sudo'):raise RuntimeError('The selected environment needs package-manager permission')
    return ['sudo','-n']
def streamed(command):
    # Keep long package-manager output in this operation's authorized guest
    # stage. Emit a bounded tail and a small receipt through jobs, whose UI
    # summary cannot represent long stdout. Cancellation remains in the same
    # original process group; no detached installer escapes the owning job.
    directory=INPUT['logDirectory']
    require(re.fullmatch(r'\.floe-latex/[0-9a-f-]{36}/preparation-[0-9a-f-]{36}',directory) is not None,'Invalid preparation log directory')
    require(directory.split('/')[1]==str(uuid.UUID(INPUT['projectID'])),'Mismatched preparation log owner')
    current=pathlib.Path.cwd()
    for part in directory.split('/'):
        current=current/part
        require(not current.is_symlink(),'Preparation log path is a symbolic link')
        current.mkdir(exist_ok=True)
    path=current/(INPUT['action']+'-'+uuid.uuid4().hex+'.log')
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    tail=b'';saved=0;truncated=False
    with os.fdopen(fd,'wb') as log:
        process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        try:
            while True:
                data=process.stdout.read(32768)
                if not data:break
                tail=(tail+data)[-8192:]
                remaining=max(0,16*1024*1024-saved)
                log.write(data[:remaining]);saved+=min(remaining,len(data))
                if len(data)>remaining:truncated=True
            code=process.wait()
        finally:
            process.stdout.close()
            if process.poll() is None:process.terminate();process.wait()
    entry=dict(path=str(path.relative_to(pathlib.Path.cwd())),byteCount=saved,truncated=truncated,exitStatus=code)
    LOGS.append(entry)
    print('Preparation log: '+json.dumps(entry,separators=(',',':')),flush=True)
    print(tail.decode('utf-8',errors='replace'),flush=True)
    if code:raise RuntimeError('Package preparation failed; its original log was retained at '+entry['path'])
def apt_base():
    if not shutil.which('apt-get'):raise RuntimeError('Use this Linux distribution package manager to prepare the missing resources')
    return privilege()+['env','DEBIAN_FRONTEND=noninteractive','apt-get','-o','DPkg::Lock::Timeout=120']
def estimate_download(packages):
    require(bool(packages) and len(packages)<=512 and all(package_name(p) for p in packages),'Invalid installation package')
    apt=apt_base()
    estimate=bounded(apt+['--print-uris','-y','--no-install-recommends','install']+packages,timeout=120)
    total=0
    for line in estimate.stdout.splitlines():
        match=re.fullmatch(r"'[^']+'\s+\S+\s+(\d+)\s+\S+",line.strip())
        if match:total+=int(match.group(1))
    if total>2**53:raise RuntimeError('Invalid package download estimate')
    return total
def install(packages,update):
    packages=sorted(set(packages));require(bool(packages) and len(packages)<=512 and all(package_name(p) for p in packages),'Invalid installation package')
    apt=apt_base()
    if update:streamed(apt+['update'])
    total=estimate_download(packages)
    print('FLOE_LATEX_DOWNLOAD_BYTES '+str(total),flush=True)
    streamed(apt+['install','-y','--no-install-recommends']+packages)
    actual=versions(packages)
    if any(not any(k.split(':')[0]==p.split(':')[0] for k in actual) for p in packages):raise RuntimeError('Package installation did not verify its installed version')
    return dict(packages=actual,downloadBytes=total)
def resolve(files,update):
    require(bool(files) and len(files)<=512 and all(tex_name(f) for f in files),'Invalid resource lookup')
    if not shutil.which('apt-file'):raise RuntimeError('The repository file index is unavailable')
    if update:streamed(privilege()+['apt-file','update'])
    packages=set();unresolved=[]
    deadline=time.monotonic()+120
    for name in files:
        if time.monotonic()>deadline:raise RuntimeError('Package index lookup time limit exceeded')
        # Search actual runtime files, excluding sources/documentation and
        # selecting only a package that contains this exact requested file.
        pattern=r'/(?:texmf(?:-dist)?)/(?:tex|bibtex/bst|fonts)/(?:.*/)?'+re.escape(name)+r'$'
        output=bounded(['apt-file','--regexp','search',pattern],timeout=30,check=False)
        if output.returncode not in (0,1):raise RuntimeError('The package Contents index is unavailable or could not be read')
        providers=set()
        for line in output.stdout.splitlines():
            if ': ' not in line:continue
            package,path=line.split(': ',1)
            if package_name(package) and re.search(pattern,path):providers.add(package)
        if providers:packages.add(sorted(providers)[0])
        else:unresolved.append(name)
    if len(packages)>512:raise RuntimeError('Too many resource provider packages')
    return dict(packages=sorted(packages),unresolved=unresolved)
def main():
    require(isinstance(INPUT,dict) and INPUT.get('action') in {'probe','resolve','install','versions','estimate'},'Invalid preparation operation')
    require(isinstance(INPUT.get('revision'),int) and INPUT['revision']>=0,'Invalid project revision')
    require(re.fullmatch('[0-9a-f]{64}',INPUT.get('inputDigest','')) is not None,'Invalid project input identity')
    action=INPUT['action']
    if action=='probe':value=probe(INPUT['programs'],INPUT['files'],INPUT['fonts'])
    elif action=='resolve':value=resolve(INPUT['files'],INPUT['update'])
    elif action=='install':value=install(INPUT['packages'],INPUT['update'])
    elif action=='estimate':value={'downloadBytes':estimate_download(INPUT['packages'])}
    else:value={'packages':versions(INPUT['packages'])}
    receipt(value)
if __name__=='__main__':main()
"""#
}
