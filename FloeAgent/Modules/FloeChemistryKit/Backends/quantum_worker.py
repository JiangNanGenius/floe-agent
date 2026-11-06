"""xTB CLI adapter. Executable and job directory come from the resolved host environment, never model arguments."""
import json, math, os, pathlib, re, shutil, signal, subprocess, time, uuid

def quantum_execute(request, read_molecule, cjson):
    from rdkit import Chem
    from science_worker import integer, finite
    executable=os.environ.get('CHEMISTRY_XTB_EXECUTABLE') or shutil.which('xtb')
    if not executable or not pathlib.Path(executable).is_file(): raise ValueError('Configure the xTB executable in this execution environment')
    base=os.environ.get('CHEMISTRY_JOB_DIRECTORY')
    if not base or not pathlib.Path(base).is_dir(): raise ValueError('An explicit owned chemistry job directory is required')
    options=request.get('options',{});mol=read_molecule(request)
    if not mol.GetNumConformers() or not mol.GetConformer().Is3D(): raise ValueError('Generate three-dimensional coordinates before xTB calculation')
    if mol.GetNumAtoms()>2000: raise ValueError('xTB atom budget exceeded')
    job=pathlib.Path(base).resolve()/('xtb-'+uuid.uuid4().hex);job.mkdir(mode=0o700)
    source=Chem.MolToXYZBlock(mol)
    (job/'input.xyz').write_text(source)
    gfn=integer(options.get('gfn',2),0,2,'GFN method')
    charge=integer(options.get('charge',sum(a.GetFormalCharge() for a in mol.GetAtoms())),-100,100,'charge')
    uhf=integer(options.get('uhf',0),0,100,'unpaired electrons')
    command=[str(pathlib.Path(executable).resolve()),'input.xyz','--gfn',str(gfn),'--chrg',str(charge),'--uhf',str(uhf),'--json','--norestart']
    optimize=request['operation']=='xtb.optimize'
    if optimize:
        level=options.get('optimizationLevel','normal')
        if level not in ['loose','normal','tight','vtight']: raise ValueError('Invalid optimization level')
        command+=['--opt',level]
    elif request['operation']!='xtb.singlepoint': raise ValueError('Unknown xTB operation')
    timeout=finite(options.get('timeoutSeconds',300),1,3600,'timeout')
    env=dict(os.environ,OMP_NUM_THREADS=str(integer(options.get('threads',2),1,6,'threads')),OPENBLAS_NUM_THREADS='2')
    log=job/'xtb.out';started=time.monotonic()
    with log.open('wb') as output:
        process=subprocess.Popen(command,cwd=job,env=env,stdout=output,stderr=subprocess.STDOUT)
        def cancel(signum,frame):
            process.terminate()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.kill();process.wait()
            raise InterruptedError('xTB calculation cancelled; partial artifacts are retained')
        previous=signal.signal(signal.SIGTERM,cancel)
        try:
            while process.poll() is None:
                if log.stat().st_size>8*1024*1024 or time.monotonic()-started>timeout:
                    process.terminate()
                    try:process.wait(timeout=5)
                    except subprocess.TimeoutExpired:process.kill();process.wait()
                    raise ValueError('xTB output or time budget exceeded; artifacts are retained')
                time.sleep(0.05)
        finally:signal.signal(signal.SIGTERM,previous)
    text=log.read_text(errors='replace')
    if process.returncode!=0: raise ValueError('xTB failed (exit '+str(process.returncode)+'); '+text[-1500:])
    energies=re.findall(r'TOTAL ENERGY\s+([-+0-9.EeDd]+)',text)
    if not energies: raise ValueError('xTB returned no verified total energy')
    energy=float(energies[-1].replace('D','E').replace('d','e'))
    if not math.isfinite(energy): raise ValueError('xTB energy is non-finite')
    result={'energy':energy,'units':'hartree','engine':'xTB CLI','method':'GFN'+str(gfn)+'-xTB','charge':charge,'uhf':uhf,
            'elapsedSeconds':time.monotonic()-started,'artifactDirectory':str(job)}
    banner=re.search(r'xtb version\s+([^\n]+)',text)
    if banner:result['engineVersion']=banner.group(1).strip()
    charges=job/'charges'
    if charges.exists():
        values=[float(x) for x in charges.read_text().split()]
        if len(values)!=mol.GetNumAtoms() or not all(math.isfinite(x) for x in values): raise ValueError('Invalid xTB atomic charges')
        result['charges']=values
    properties=job/'xtbout.json'
    if properties.exists() and properties.stat().st_size<=8*1024*1024:result['properties']=json.loads(properties.read_text())
    if optimize:
        final=job/'xtbopt.xyz'
        if not final.exists():raise ValueError('xTB optimization produced no coordinates')
        optimized=Chem.MolFromXYZBlock(final.read_text())
        if optimized is None or optimized.GetNumAtoms()!=mol.GetNumAtoms():raise ValueError('Invalid optimized xTB geometry')
        for i in range(mol.GetNumAtoms()):mol.GetConformer().SetAtomPosition(i,optimized.GetConformer().GetAtomPosition(i))
        result.update(cjson=cjson(mol),converged='GEOMETRY OPTIMIZATION CONVERGED' in text.upper())
    return result
