# SPDX-License-Identifier: MPL-2.0
import base64
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import numpy as np
from test_science import asset,request,run
from biology_worker import execute

def sbml_model(rules='',events='',reaction=True):
    import libsbml
    doc=libsbml.SBMLDocument(3,2);m=doc.createModel();m.setId('Synthetic')
    c=m.createCompartment();c.setId('cell');c.setSize(2);c.setConstant(True);c.setSpatialDimensions(3)
    for name,value in [('A',10),('B',0)]:
        s=m.createSpecies();s.setId(name);s.setCompartment('cell');s.setInitialAmount(value);s.setHasOnlySubstanceUnits(True);s.setBoundaryCondition(False);s.setConstant(False)
    k=m.createParameter();k.setId('k');k.setValue(0.2);k.setConstant(not bool(rules))
    if reaction:
        r=m.createReaction();r.setId('r');r.setReversible(False)
        a=r.createReactant();a.setSpecies('A');a.setStoichiometry(1);a.setConstant(True)
        b=r.createProduct();b.setSpecies('B');b.setStoichiometry(1);b.setConstant(True)
        law=r.createKineticLaw();law.setMath(libsbml.parseL3Formula('k*A'))
    if rules=='rate':
        r=m.createRateRule();r.setVariable('k');r.setMath(libsbml.parseL3Formula('0.1'))
    elif rules=='assignment':
        r=m.createAssignmentRule();r.setVariable('k');r.setMath(libsbml.parseL3Formula('0.2 + time*0.1'))
    elif rules=='algebraic':
        r=m.createAlgebraicRule();r.setMath(libsbml.parseL3Formula('A-B'))
    if events:
        e=m.createEvent();e.setId('pulse');e.setUseValuesFromTriggerTime(True)
        t=e.createTrigger();t.setPersistent(True);t.setInitialValue(False);t.setMath(libsbml.parseL3Formula('time>=1'))
        a=e.createEventAssignment();a.setVariable('A');a.setMath(libsbml.parseL3Formula('5'))
    return asset('externalDataset','sbml','sbml',libsbml.writeSBMLToString(doc).encode())

class ExtensionTests(unittest.TestCase):
    def test_native_image_regions_are_current_bounded_and_global(self):
        values=np.zeros((8,8));values[2:4,4:6]=100
        p=dict(width=8,height=8,channels=1,slices=1,frames=1,bitDepth=16,samples=values.reshape(-1).tolist(),pixelSizeX=0.5,pixelSizeY=0.5,calibrationUnit='µm')
        a=asset('microscopyImage',p,'json',b'{}')
        self.assertEqual(json.loads(run(a,'micro.series')['text'])[0]['shape'],[1,1,1,8,8])
        tile=json.loads(run(a,'micro.tile',{'region':[4,2,2,2]})['text']);self.assertEqual(tile['samples'],[100]*4)
        result=run(a,'micro.segment',dict(region=[3,1,4,4],threshold=50))
        self.assertEqual(result['metrics']['objects'],1);self.assertEqual(result['rows'][0][3:],[4.5,2.5])
    def test_sbml_units_analytical_conservation_and_fresh_sweep(self):
        a=sbml_model();r=run(a,'net.sbml.simulate',{'timeEnd':2,'points':5})
        self.assertAlmostEqual(r['metrics']['final_A'],10*np.exp(-0.4),places=6)
        for row in r['rows']:self.assertAlmostEqual(row[1]+row[2],10,places=7)
        self.assertEqual(r['details']['quantity'],'species amounts')
        sweep=run(a,'net.sbml.sweep',dict(timeEnd=2,points=5,parameter='k',values=[0.2,0.4]))
        self.assertAlmostEqual(sweep['rows'][0][1],10*np.exp(-0.4),places=6)
        self.assertAlmostEqual(sweep['rows'][1][1],10*np.exp(-0.8),places=6)
    def test_sbml_rate_assignment_rules_events_and_explicit_rejection(self):
        for kind in ['rate','assignment']:
            r=run(sbml_model(rules=kind),'net.sbml.simulate',dict(timeEnd=2,points=5))
            self.assertAlmostEqual(r['metrics']['final_A'],10*np.exp(-0.6),places=5)
        r=run(sbml_model(events='pulse',reaction=False),'net.sbml.simulate',dict(timeEnd=2,points=5))
        self.assertAlmostEqual(r['metrics']['final_A'],5,places=7)
        reply=execute(request(sbml_model(rules='algebraic'),'net.sbml.simulate'))
        self.assertFalse(reply['success']);self.assertIn('Algebraic',reply['error']['message'])
    def test_pyramid_region_global_coordinates_and_file_identity(self):
        import tifffile
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'source.ome.tif'
            large=np.zeros((2048,2048),dtype=np.uint16);large[200:220,300:320]=1000
            with tifffile.TiffWriter(path,ome=True) as writer:
                writer.write(large,subifds=1,tile=(64,64),metadata={'axes':'YX','PhysicalSizeX':0.5,'PhysicalSizeY':0.5,'PhysicalSizeXUnit':'µm','PhysicalSizeYUnit':'µm'})
                writer.write(large[::2,::2],subfiletype=1,tile=(64,64))
            raw=path.read_bytes();a=asset('externalDataset','tiff','tiff',b'')
            req=request(a,'micro.series');identity=req['identity']
            digest=hashlib.sha256(raw).hexdigest();folder=Path(tmp)/'inputs';folder.mkdir();(folder/(digest+'.bin')).write_bytes(raw)
            a['fileReference']=dict(id=identity['objectID'],projectID=identity['projectID'].upper(),fileName='source.ome.tif',byteCount=len(raw),sha256=digest,environmentID=identity['environmentID'])
            def call(op,options):
                r=request(a,op,options);r['identity']['projectID']=identity['projectID']
                reply=execute(r,workspace=str(Path(tmp).resolve()))
                if not reply['success']:raise AssertionError(reply['error'])
                return reply['result']
            series=json.loads(call('micro.series',{})['text']);self.assertEqual(len(series[0]['levels']),2)
            tile=call('micro.tile',dict(level=1,region=[140,90,32,32]));p=json.loads(tile['text'])
            self.assertEqual(len(p['samples']),1024);self.assertEqual(p['pixelSizeX'],1)
            result=call('micro.segment',dict(level=1,region=[140,90,32,32],threshold=100))
            self.assertEqual(result['metrics']['objects'],1);self.assertEqual(result['rows'][0][1],100)
            self.assertAlmostEqual(result['rows'][0][3],309);self.assertAlmostEqual(result['rows'][0][4],209)
            self.assertAlmostEqual(result['rows'][0][5],154.5)
            bad=request(a,'micro.tile');self.assertFalse(execute(bad,workspace=str(Path(tmp).resolve()))['success']) # foreign project identity
            (folder/(digest+'.bin')).write_bytes(raw[:-1]+b'x')
            with self.assertRaisesRegex(AssertionError,'digest'):call('micro.tile',{})
    def test_current_structure_coordinates_are_authoritative(self):
        from test_science import SAMPLES
        raw=(SAMPLES/'1ubq.pdb').read_bytes();source=asset('externalDataset','pdb','pdb',raw)
        atoms=json.loads(run(source,'struct.parse')['text'])
        for i,a in enumerate(atoms):a.update(id=i,serial=i+1,model=1,x=a['x']+10)
        typed=asset('proteinStructure',dict(atoms=atoms,title='edited'),'pdb',raw);typed['revision']=2
        original=run(source,'struct.geometry');edited=run(typed,'struct.geometry')
        self.assertAlmostEqual(edited['rows'][0][0]-original['rows'][0][0],10,places=5)

if __name__=='__main__':unittest.main()
