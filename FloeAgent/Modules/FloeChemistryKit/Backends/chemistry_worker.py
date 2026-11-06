#!/usr/bin/env python3
"""Trusted JSON worker for an explicitly resolved Mac/Linux environment. No network or shell execution."""
import hashlib, importlib, json, math, os, pathlib, re, shutil, signal, subprocess, sys, tempfile, time, uuid

MAX_INPUT = 16 * 1024 * 1024
MAX_ATOMS = 10000
METHODS = ['rdkit.describe', 'rdkit.embed', 'rdkit.conformers', 'rdkit.similarity', 'rdkit.substructure', 'rdkit.reaction']
SCIENCE_METHODS = ['gemmi.crystal', 'gemmi.diffraction', 'gemmi.structure', 'openmm.lennardJones', 'openmm.system']
QUANTUM_METHODS = ['xtb.singlepoint', 'xtb.optimize']
PROTOCOL = 'floe.chemistry.worker'

def strict_json(source):
    def reject(value):
        raise ValueError('Non-finite JSON number')
    value = json.loads(source, parse_constant=reject)
    def check(node, depth=0):
        if depth > 64: raise ValueError('JSON nesting limit exceeded')
        if isinstance(node, float) and not math.isfinite(node): raise ValueError('Non-finite JSON number')
        if isinstance(node, dict):
            for item in node.values(): check(item, depth+1)
        elif isinstance(node, list):
            for item in node: check(item, depth+1)
    check(value)
    return value

def validate_request(request):
    if not isinstance(request, dict) or not set(request) <= {'operation','format','data','options'}:
        raise ValueError('Expected a chemistry request')
    if request.get('operation') not in METHODS+SCIENCE_METHODS+QUANTUM_METHODS+['capabilities']:
        raise ValueError('Unknown worker method')
    if not isinstance(request.get('format'), str) or len(request['format'].encode()) > 64:
        raise ValueError('Invalid source format')
    if not isinstance(request.get('data'), str) or len(request['data'].encode()) > MAX_INPUT:
        raise ValueError('Invalid or oversized chemistry source')
    if not isinstance(request.get('options', {}), dict): raise ValueError('Options must be an object')
    return request

def decode_request(raw):
    value = strict_json(raw)
    if not isinstance(value, dict): raise ValueError('Expected a JSON object')
    if 'protocol' not in value:
        return value, None
    if set(value) != {'protocol','version','identity','requestJSON','requestDigest'} or value['protocol'] != PROTOCOL or type(value['version']) is not int or value['version'] != 1:
        raise ValueError('Unsupported worker protocol')
    identity = value['identity']
    uuid_fields = ['projectID','runID','objectID','taskID','hostRunID','attemptID']
    if not isinstance(identity, dict) or set(identity) != set(uuid_fields+['objectRevision','inputDigest','environmentID']):
        raise ValueError('Invalid execution identity')
    for field in uuid_fields:
        text = identity[field]
        if not isinstance(text, str) or str(uuid.UUID(text)).lower() != text.lower():
            raise ValueError('Invalid execution '+field)
    bounded_integer(identity['objectRevision'], 0, 2**64-1, 'object revision')
    if not isinstance(identity['environmentID'], str) or not 0 < len(identity['environmentID'].encode()) <= 4096:
        raise ValueError('Invalid execution environment')
    for digest in (identity['inputDigest'], value['requestDigest']):
        if not isinstance(digest, str) or re.fullmatch('[0-9a-f]{64}', digest) is None:
            raise ValueError('Invalid execution checksum')
    source = value['requestJSON']
    if not isinstance(source, str) or len(source.encode()) > MAX_INPUT or hashlib.sha256(source.encode()).hexdigest() != value['requestDigest']:
        raise ValueError('Worker request checksum does not match')
    binding = dict(protocol=PROTOCOL, version=1, identity=identity, requestDigest=value['requestDigest'])
    # Decode the inner request later so a valid envelope's engine/input failure remains bound.
    return source, binding

def xtb_version(executable):
    path = pathlib.Path(executable)
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError('Configure a runnable xTB executable')
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen([str(path.resolve()), '--version'], stdout=output, stderr=subprocess.STDOUT)
        started = time.monotonic()
        try:
            while process.poll() is None:
                if time.monotonic()-started > 5 or os.fstat(output.fileno()).st_size > 65536:
                    raise ValueError('xTB version probe exceeded its output or time limit')
                time.sleep(0.02)
            if os.fstat(output.fileno()).st_size > 65536: raise ValueError('xTB version response is oversized')
            output.seek(0); text = output.read(65536).decode(errors='replace')
            version = re.search(r'xtb version\s+([^\n]+)', text, re.IGNORECASE)
            if process.returncode != 0 or version is None: raise ValueError('xTB did not return a valid version')
            return version.group(1).strip()
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=1)
                except subprocess.TimeoutExpired: process.kill(); process.wait()

def capabilities():
    methods = []; engines = {}; unavailable = {}; platforms = []
    try:
        from rdkit import Chem, rdBase
        from rdkit.Chem import AllChem, Descriptors, Lipinski, rdMolDescriptors, rdFingerprintGenerator
        if Chem.MolFromSmiles('O') is None: raise ValueError('RDKit molecule initialization failed')
        engines['rdkit'] = rdBase.rdkitVersion; methods += METHODS
    except Exception as error: unavailable['rdkit'] = str(error)[:4096]
    try:
        import gemmi
        if abs(gemmi.UnitCell(1,1,1,90,90,90).calculate_d([1,0,0])-1) > 1e-9:
            raise ValueError('Gemmi cell initialization failed')
        engines['gemmi'] = gemmi.__version__; methods += SCIENCE_METHODS[:3]
    except Exception as error: unavailable['gemmi'] = str(error)[:4096]
    try:
        import openmm as mm
        from openmm import unit
        failures = []
        for name in ['CPU','Reference']:
            context = None; integrator = None
            try:
                platform = mm.Platform.getPlatformByName(name)
                system = mm.System(); system.addParticle(39.948)
                integrator = mm.VerletIntegrator(0.001)
                context = mm.Context(system, integrator, platform, {'Threads':'1'} if name == 'CPU' else {})
                context.setPositions([mm.Vec3(0,0,0)])
                energy = context.getState(getEnergy=True).getPotentialEnergy().value_in_unit(unit.kilojoule_per_mole)
                if not math.isfinite(energy): raise ValueError('Non-finite probe energy')
                platforms.append(name)
            except Exception as error: failures.append(name+': '+str(error))
            finally:
                del context; del integrator
        if not platforms: raise ValueError('No usable OpenMM CPU/Reference platform: '+'; '.join(failures))
        engines['openmm'] = mm.__version__; methods += SCIENCE_METHODS[3:]
    except Exception as error: unavailable['openmm'] = str(error)[:4096]
    try:
        executable = os.environ.get('CHEMISTRY_XTB_EXECUTABLE') or shutil.which('xtb')
        if not executable: raise ValueError('Configure xTB in this environment')
        engines['xtb'] = xtb_version(executable)
        if 'rdkit' not in engines: raise ValueError('xTB requires RDKit geometry interchange')
        root = os.environ.get('CHEMISTRY_JOB_DIRECTORY')
        if not root or not pathlib.Path(root).is_dir() or not os.access(root, os.W_OK | os.X_OK):
            raise ValueError('Configure an explicit writable owned chemistry job directory')
        methods += QUANTUM_METHODS
    except Exception as error: unavailable['xtb'] = str(error)[:4096]
    return dict(protocolVersion=1, methods=methods, engines=engines, unavailable=unavailable, openmmPlatforms=platforms)

def bounded_integer(value, low, high, name):
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ValueError('Invalid ' + name)
    return value

def read_molecule(request):
    from rdkit import Chem
    fmt, data = request['format'], request['data']
    if fmt in ('smi', 'smiles'):
        mol = Chem.MolFromSmiles(data)
    elif fmt in ('mol', 'sdf'):
        mol = Chem.MolFromMolBlock(data.split('$$$$')[0], removeHs=False)
    elif fmt == 'pdb':
        mol = Chem.MolFromPDBBlock(data, removeHs=False)
    elif fmt == 'xyz':
        mol = Chem.MolFromXYZBlock(data)
    elif fmt == 'cjson':
        value = json.loads(data)
        numbers = value['atoms']['elements']['number']
        if not 0 < len(numbers) <= MAX_ATOMS: raise ValueError('Atom count exceeds worker limit')
        edit = Chem.RWMol()
        for n in numbers:
            edit.AddAtom(Chem.Atom(bounded_integer(n, 1, 118, 'atomic number')))
        connections = value.get('bonds', {}).get('connections', {}).get('index', [])
        orders = value.get('bonds', {}).get('order', [])
        if len(connections) % 2 or len(orders) != len(connections)//2: raise ValueError('Invalid bonds')
        types = {1:Chem.BondType.SINGLE,2:Chem.BondType.DOUBLE,3:Chem.BondType.TRIPLE}
        for i, order in enumerate(orders):
            a = bounded_integer(connections[i*2], 0, len(numbers)-1, 'bond index')
            b = bounded_integer(connections[i*2+1], 0, len(numbers)-1, 'bond index')
            if order not in types: raise ValueError('Unsupported bond order')
            edit.AddBond(a, b, types[order])
        mol = edit.GetMol()
        charges = value['atoms'].get('formalCharges', [])
        if charges:
            if len(charges) != len(numbers): raise ValueError('Invalid charges')
            for atom, charge in zip(mol.GetAtoms(), charges): atom.SetFormalCharge(bounded_integer(charge,-100,100,'charge'))
        isotopes = value['atoms'].get('isotopes', [])
        if isotopes:
            if len(isotopes) != len(numbers): raise ValueError('Invalid isotopes')
            for atom, isotope in zip(mol.GetAtoms(), isotopes): atom.SetIsotope(bounded_integer(isotope,0,400,'isotope'))
        coords = value['atoms'].get('coords', {}).get('3d', [])
        if coords:
            if len(coords) != len(numbers)*3 or not all(isinstance(x,(int,float)) and math.isfinite(x) for x in coords): raise ValueError('Invalid coordinates')
            conf = Chem.Conformer(len(numbers)); conf.Set3D(True)
            for i in range(len(numbers)): conf.SetAtomPosition(i, coords[i*3:i*3+3])
            mol.AddConformer(conf)
        Chem.SanitizeMol(mol)
        if coords: Chem.AssignAtomChiralTagsFromStructure(mol)
    else:
        raise ValueError('Unsupported RDKit input format')
    if mol is None or not 0 < mol.GetNumAtoms() <= MAX_ATOMS: raise ValueError('Cannot parse molecule or atom limit exceeded')
    return mol

def cjson(mol, conf_id=-1):
    atoms = {'elements':{'number':[a.GetAtomicNum() for a in mol.GetAtoms()]},
             'formalCharges':[a.GetFormalCharge() for a in mol.GetAtoms()],
             'isotopes':[a.GetIsotope() for a in mol.GetAtoms()]}
    if mol.GetNumConformers():
        conf = mol.GetConformer(conf_id)
        atoms['coords'] = {'3d':[v for i in range(mol.GetNumAtoms()) for v in conf.GetAtomPosition(i)]}
    value = {'chemicalJson':1,'atoms':atoms,'bonds':{'connections':{'index':[i for b in mol.GetBonds() for i in (b.GetBeginAtomIdx(),b.GetEndAtomIdx())]},
                                                  'order':[int(b.GetBondTypeAsDouble()) for b in mol.GetBonds()]}}
    if any(b.GetIsAromatic() for b in mol.GetBonds()):
        from rdkit import Chem
        copy = Chem.Mol(mol); Chem.Kekulize(copy, clearAromaticFlags=True)
        value['bonds']['order'] = [int(b.GetBondTypeAsDouble()) for b in copy.GetBonds()]
    return json.dumps(value, separators=(',',':'), allow_nan=False)

def evaluate(request):
    operation = request['operation']
    if operation.startswith('xtb.'):
        from quantum_worker import quantum_execute
        return quantum_execute(request,read_molecule,cjson)
    if operation.startswith('gemmi.'):
        from science_worker import gemmi_execute
        return gemmi_execute(request)
    if operation.startswith('openmm.'):
        from science_worker import openmm_execute
        return openmm_execute(request)
    if operation == 'capabilities':
        return capabilities()
    from rdkit import Chem, DataStructs, rdBase
    from rdkit.Chem import AllChem, Descriptors, Lipinski, rdMolDescriptors, rdFingerprintGenerator
    operation = request['operation']; options = request.get('options', {})
    if operation == 'rdkit.reaction':
        reactants = json.loads(request['data'])['reactants']
        if not isinstance(reactants,list) or not 0 < len(reactants) <= 16: raise ValueError('Invalid reaction inputs')
        reaction = AllChem.ReactionFromSmarts(options['smarts'])
        if reaction is None: raise ValueError('Invalid reaction SMARTS')
        molecules = tuple(Chem.MolFromSmiles(x) for x in reactants)
        if any(m is None for m in molecules): raise ValueError('Invalid reactant SMILES')
        limit = bounded_integer(options.get('maxProducts',64),1,256,'product count')
        products = reaction.RunReactants(molecules,maxProducts=limit)
        rows = []
        for row in products:
            for mol in row: Chem.SanitizeMol(mol)
            rows.append([Chem.MolToSmiles(m,isomericSmiles=True) for m in row])
        return {'products':rows,'limitReached':len(rows)==limit,'method':'reaction SMARTS rules','engine':'RDKit '+rdBase.rdkitVersion}
    mol = read_molecule(request)
    result = {'engine':'RDKit '+rdBase.rdkitVersion,'canonicalSmiles':Chem.MolToSmiles(mol,isomericSmiles=True),
              'formula':rdMolDescriptors.CalcMolFormula(mol),'mass':Descriptors.MolWt(mol),'exactMass':Descriptors.ExactMolWt(mol),
              'logP':Descriptors.MolLogP(mol),'TPSA':Descriptors.TPSA(mol),
              'HBD':Lipinski.NumHDonors(mol),'HBA':Lipinski.NumHAcceptors(mol),'rotatableBonds':Lipinski.NumRotatableBonds(mol),
              'atomCount':mol.GetNumAtoms(),'bondCount':mol.GetNumBonds()}
    if operation in ('rdkit.embed','rdkit.conformers'):
        mol = Chem.AddHs(mol)
        if mol.GetNumAtoms() > 2000: raise ValueError('Embedding atom budget exceeded')
        params = AllChem.ETKDGv3(); params.randomSeed = bounded_integer(options.get('seed',42),0,2147483647,'seed')
        params.numThreads = 1
        count = bounded_integer(options.get('conformers',1 if operation=='rdkit.embed' else 10),1,128,'conformers')
        ids = list(AllChem.EmbedMultipleConfs(mol,numConfs=count,params=params))
        if not ids: raise ValueError('3D embedding failed')
        iterations = bounded_integer(options.get('iterations',200),1,10000,'iterations')
        field = options.get('forcefield','MMFF94')
        if field == 'MMFF94':
            if not AllChem.MMFFHasAllMoleculeParams(mol): raise ValueError('MMFF94 parameters missing; choose another method explicitly')
            values = AllChem.MMFFOptimizeMoleculeConfs(mol,numThreads=1,maxIters=iterations)
        elif field == 'UFF':
            if not AllChem.UFFHasAllMoleculeParams(mol): raise ValueError('UFF parameters missing')
            values = AllChem.UFFOptimizeMoleculeConfs(mol,numThreads=1,maxIters=iterations)
        else: raise ValueError('Unknown force field')
        best = min(range(len(values)),key=lambda i:values[i][1])
        result.update(cjson=cjson(mol,ids[best]),molblock=Chem.MolToMolBlock(mol,confId=ids[best]),
                      energy=values[best][1],units='kcal/mol',forcefield=field,
                      conformers=[{'id':i,'energy':energy,'converged':status==0} for i,(status,energy) in zip(ids,values)],
                      atomCount=mol.GetNumAtoms(),bondCount=mol.GetNumBonds())
    elif operation == 'rdkit.similarity':
        query = Chem.MolFromSmiles(options['query'])
        if query is None: raise ValueError('Invalid comparison SMILES')
        generator = rdFingerprintGenerator.GetMorganGenerator(radius=2,fpSize=2048)
        result.update(tanimoto=DataStructs.TanimotoSimilarity(generator.GetFingerprint(mol),generator.GetFingerprint(query)),fingerprint='Morgan radius=2 size=2048')
    elif operation == 'rdkit.substructure':
        query = Chem.MolFromSmarts(options['smarts'])
        if query is None: raise ValueError('Invalid SMARTS query')
        result['matches'] = mol.GetSubstructMatches(query,maxMatches=1024)
    elif operation == 'rdkit.describe':
        result['molblock'] = Chem.MolToMolBlock(mol)
        stereo = any(a.GetChiralTag()!=Chem.ChiralType.CHI_UNSPECIFIED for a in mol.GetAtoms()) or any(b.GetStereo()!=Chem.BondStereo.STEREONONE for b in mol.GetBonds())
        if not stereo or (mol.GetNumConformers() and mol.GetConformer().Is3D()): result['cjson'] = cjson(mol)
        else: result['structureNote'] = 'Stereo is retained in canonicalSmiles and molblock; generate 3D coordinates before applying CJSON.'
    else: raise ValueError('Unknown worker method')
    return result

def main():
    binding = None
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT+1)
        if len(raw) > MAX_INPUT: raise ValueError('Input exceeds worker limit')
        request, binding = decode_request(raw)
        request = validate_request(strict_json(request) if isinstance(request, str) else request)
        result = evaluate(request)
        output = json.dumps(dict(binding or {},ok=True,result=result),allow_nan=False,separators=(',',':'))
        if len(output.encode()) > 64*1024*1024: raise ValueError('Output exceeds worker limit')
    except Exception as error:
        message = str(error).encode()[:16000].decode(errors='ignore') or 'Chemistry worker failed'
        output = json.dumps(dict(binding or {},ok=False,error=message,errorType=type(error).__name__),allow_nan=False)
    sys.stdout.write(output+'\n')

if __name__ == '__main__': main()
