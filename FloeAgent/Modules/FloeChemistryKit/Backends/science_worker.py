"""Crystallography, biological structures and real OpenMM trajectories for the configured worker environment."""
import json, math

def finite(value, low, high, name):
    if isinstance(value,bool) or not isinstance(value,(int,float)) or not math.isfinite(value) or not low <= value <= high:
        raise ValueError('Invalid '+name)
    return value

def integer(value, low, high, name):
    if isinstance(value,bool) or not isinstance(value,int) or not low <= value <= high: raise ValueError('Invalid '+name)
    return value

def structure_json(numbers, coordinates, cell=None, bonds=None):
    value = {'chemicalJson':1,'atoms':{'elements':{'number':numbers},'coords':{'3d':coordinates}}}
    if cell is not None: value['unitCell'] = cell
    if bonds is not None: value['bonds'] = bonds
    return json.dumps(value,separators=(',',':'),allow_nan=False)

def gemmi_execute(request):
    import gemmi
    options = request.get('options',{}); operation = request['operation']; source = request['data']
    if operation in ('gemmi.crystal','gemmi.diffraction'):
        block = gemmi.cif.read_string(source).sole_block()
        small = gemmi.make_small_structure_from_block(block)
        if not small.sites: raise ValueError('CIF contains no small-structure sites')
        if small.cell.volume <= 0: raise ValueError('Invalid crystal cell')
        small.setup_cell_images()
        sites = small.get_all_unit_cell_sites()
        if len(sites)>10000: raise ValueError('Expanded crystal exceeds atom budget')
        numbers = []; coordinates = []
        for site in sites:
            if not 1 <= site.element.atomic_number <= 118: raise ValueError('Unknown site element')
            p = small.cell.orthogonalize(site.fract)
            numbers.append(site.element.atomic_number); coordinates.extend([p.x,p.y,p.z])
        cell = dict(zip(['a','b','c','alpha','beta','gamma'],small.cell.parameters))
        result = {'cjson':structure_json(numbers,coordinates,cell),'atomCount':len(numbers),
                  'spaceGroup':small.spacegroup_hm,'spaceGroupNumber':small.spacegroup_number,
                  'cell':cell,'volume':small.cell.volume,'volumeUnits':'angstrom^3','engine':'Gemmi '+gemmi.__version__}
        if operation == 'gemmi.diffraction':
            hkls = options.get('hkls',[[1,0,0]])
            if not isinstance(hkls,list) or not 0<len(hkls)<=4096: raise ValueError('Invalid reflection list')
            wavelength = finite(options.get('wavelength',1.5406),0.000001,100,'wavelength in angstrom')
            calculator = gemmi.StructureFactorCalculatorX(small.cell)
            reflections = []
            for hkl in hkls:
                if not isinstance(hkl,list) or len(hkl)!=3: raise ValueError('Expected h,k,l')
                hkl = [integer(x,-1000,1000,'Miller index') for x in hkl]
                if hkl == [0,0,0]: raise ValueError('Reflection 0,0,0 is undefined')
                d = small.cell.calculate_d(hkl)
                sf = calculator.calculate_sf_from_small_structure(small,hkl)
                accessible = wavelength<=2*d
                reflections.append({'hkl':hkl,'d':d,'structureFactorReal':sf.real,'structureFactorImag':sf.imag,
                                    'intensity':abs(sf)**2,'accessible':accessible,
                                    'twoTheta':2*math.asin(wavelength/(2*d))*180/math.pi if accessible else None})
            result.update(reflections=reflections,intensityDefinition='kinematic X-ray |F(hkl)|^2',wavelength=wavelength)
        return result
    if operation != 'gemmi.structure': raise ValueError('Unknown Gemmi method')
    structure = gemmi.read_pdb_string(source) if request['format']=='pdb' else gemmi.make_structure_from_block(gemmi.cif.read_string(source).sole_block())
    model_index = integer(options.get('model',0),0,len(structure)-1,'model')
    model = structure[model_index]
    chain_id = options.get('chain')
    numbers = []; coordinates = []; chains = []
    for chain in model:
        if chain_id is not None and chain.name != chain_id: continue
        count = 0; residues = []
        for residue in chain:
            residues.append(residue.name)
            for atom in residue:
                if atom.element.atomic_number==0: raise ValueError('Unknown atom element')
                numbers.append(atom.element.atomic_number); coordinates.extend([atom.pos.x,atom.pos.y,atom.pos.z]); count+=1
        chains.append({'id':chain.name,'residueCount':len(residues),'residues':residues,'atomCount':count})
    if not 0<len(numbers)<=10000: raise ValueError('Empty chain selection or atom budget exceeded')
    return {'cjson':structure_json(numbers,coordinates),'atomCount':len(numbers),'chains':chains,
            'modelCount':len(structure),'engine':'Gemmi '+gemmi.__version__}

def particle_input(request):
    from openmm.app import Element
    source = request['data']; fmt = request['format']; bonds = None
    if fmt == 'cjson':
        data = json.loads(source); numbers=data['atoms']['elements']['number']; positions=data['atoms']['coords']['3d']; bonds=data.get('bonds')
    elif fmt == 'xyz':
        lines=source.splitlines(); n=integer(int(lines[0]),1,10000,'atom count')
        if len(lines)<n+2: raise ValueError('Truncated XYZ')
        numbers=[];positions=[]
        for line in lines[2:n+2]:
            row=line.split()
            if len(row)!=4: raise ValueError('Expected XYZ element and coordinates')
            numbers.append(Element.getBySymbol(row[0]).atomic_number);positions.extend(float(x) for x in row[1:])
    else: raise ValueError('OpenMM worker requires XYZ or CJSON coordinates')
    if not 0<len(numbers)<=10000 or len(positions)!=len(numbers)*3: raise ValueError('Invalid positions')
    for n in numbers: integer(n,1,118,'atomic number')
    for x in positions: finite(x,-1e8,1e8,'coordinate')
    return numbers,positions,bonds

def openmm_execute(request):
    import openmm as mm
    from openmm import unit
    from openmm.app import Element
    options=request.get('options',{}); numbers,positions,bonds=particle_input(request)
    if request['operation']=='openmm.system':
        xml=options.get('systemXML')
        if not isinstance(xml,str) or len(xml.encode())>8*1024*1024: raise ValueError('An explicit serialized OpenMM System is required')
        system=mm.XmlSerializer.deserialize(xml)
        if not isinstance(system,mm.System) or system.getNumParticles()!=len(numbers): raise ValueError('System and input particles do not match')
        model='user-supplied serialized OpenMM System'
    elif request['operation']=='openmm.lennardJones':
        sigma=finite(options.get('sigmaNm',0.34),0.000001,100,'sigma in nm')
        epsilon=finite(options.get('epsilonKJMol',0.997),0,100000,'epsilon in kJ/mol')
        system=mm.System(); force=mm.NonbondedForce();force.setNonbondedMethod(mm.NonbondedForce.NoCutoff)
        for n in numbers:
            system.addParticle(Element.getByAtomicNumber(n).mass)
            force.addParticle(0,sigma,epsilon)
        system.addForce(force);model='explicit nonbonded Lennard-Jones particles; no bonded or electrostatic terms'
    else: raise ValueError('Unknown OpenMM method')
    steps=integer(options.get('steps',100),1,1000000,'steps')
    stride=integer(options.get('sampleEvery',max(1,(steps+127)//128)),1,1000000,'sample interval')
    if (steps+stride-1)//stride>256: raise ValueError('Trajectory sample budget exceeded')
    timestep=finite(options.get('timestepFs',1),0.000001,10,'time step in fs')
    integrator=mm.VerletIntegrator(timestep*unit.femtoseconds)
    platform_name=options.get('platform','CPU');platform=mm.Platform.getPlatformByName(platform_name)
    properties={'Threads':str(integer(options.get('threads',2),1,6,'CPU threads'))} if platform_name=='CPU' else {}
    context=mm.Context(system,integrator,platform,properties)
    context.setPositions([mm.Vec3(*positions[i:i+3]) for i in range(0,len(positions),3)]*unit.angstrom)
    temperature=finite(options.get('temperatureK',0),0,10000,'temperature')
    context.setVelocitiesToTemperature(temperature*unit.kelvin,integer(options.get('seed',42),0,2147483647,'seed'))
    initial=context.getState(getEnergy=True).getPotentialEnergy().value_in_unit(unit.kilojoule_per_mole)
    frames=[];done=0;coordinates=positions
    while done<steps:
        chunk=min(stride,steps-done);integrator.step(chunk);done+=chunk
        state=context.getState(getPositions=True,getEnergy=True)
        energy=state.getPotentialEnergy().value_in_unit(unit.kilojoule_per_mole)
        coordinates=[v for p in state.getPositions().value_in_unit(unit.angstrom) for v in p]
        if not math.isfinite(energy) or not all(math.isfinite(x) for x in coordinates): raise ValueError('Simulation produced non-finite values')
        frames.append({'step':done,'energy':energy,'positions':coordinates})
    return {'cjson':structure_json(numbers,coordinates,bonds=bonds),'trajectory':frames,'initialEnergy':initial,'energy':frames[-1]['energy'],
            'units':'kJ/mol','positionUnits':'angstrom','timestepFs':timestep,'steps':steps,'model':model,
            'platform':platform_name,'systemXML':mm.XmlSerializer.serialize(system),'engine':'OpenMM '+mm.__version__}
