import hashlib, json, math, os, pathlib, subprocess, sys, tempfile, unittest, uuid
from test_worker import WORKER, run
from test_science_worker import CIF

def envelope(operation='rdkit.describe', data='CCO', options=None, fmt='smi'):
    request = json.dumps(dict(operation=operation,format=fmt,data=data,options=options or {}),ensure_ascii=False)
    identity = {key:str(uuid.uuid4()).upper() for key in ['projectID','runID','objectID','taskID','hostRunID','attemptID']}
    identity.update(objectRevision=0,inputDigest='a'*64,environmentID='configured.protocol-test')
    return dict(protocol='floe.chemistry.worker',version=1,identity=identity,requestJSON=request,requestDigest=hashlib.sha256(request.encode()).hexdigest())

def execute(value, env=None):
    source = value if isinstance(value,str) else json.dumps(value,ensure_ascii=False)
    result = subprocess.run([sys.executable,str(WORKER)],input=source,text=True,capture_output=True,check=True,env=env)
    return json.loads(result.stdout)

class ProtocolTests(unittest.TestCase):
    def test_bound_actual_rdkit_and_identity(self):
        request=envelope(); value=execute(request)
        self.assertTrue(value['ok'],value)
        self.assertEqual(value['identity'],request['identity'])
        self.assertEqual(value['requestDigest'],request['requestDigest'])
        self.assertEqual(value['protocol'],'floe.chemistry.worker')
        self.assertEqual(value['result']['formula'],'C2H6O')
        self.assertAlmostEqual(value['result']['mass'],46.069,places=2)
        self.assertNotIn('requestJSON',value)

    def test_bound_engine_and_inner_validation_failure(self):
        request=envelope(data='invalid smiles')
        value=execute(request)
        self.assertFalse(value['ok']); self.assertEqual(value['identity'],request['identity'])
        request=envelope()
        request['requestJSON']='{"operation":"rdkit.describe","format":"smi","data":"O","options":[]}'
        request['requestDigest']=hashlib.sha256(request['requestJSON'].encode()).hexdigest()
        value=execute(request)
        self.assertFalse(value['ok']); self.assertEqual(value['requestDigest'],request['requestDigest'])
        self.assertIn('Options',value['error'])

    def test_bound_science_and_quantum_results(self):
        self.assertTrue(os.environ.get('CHEMISTRY_XTB_EXECUTABLE'),'Supply configured xTB for this actual worker test')
        cases=[
            envelope('gemmi.diffraction',CIF,{'hkls':[[1,0,0]]},'cif'),
            envelope('openmm.lennardJones','2\nargon\nAr 0 0 0\nAr 4 0 0\n',{'steps':2,'sampleEvery':1},'xyz'),
            envelope('xtb.singlepoint','3\n水\nO 0 0 0\nH 1.2 0 0\nH -0.2 1.1 0\n',{'threads':2},'xyz')
        ]
        values=[]
        for request in cases:
            value=execute(request)
            self.assertTrue(value['ok'],value)
            self.assertEqual(value['identity'],request['identity'])
            self.assertEqual(value['requestDigest'],request['requestDigest'])
            values.append(value['result'])
        self.assertAlmostEqual(values[0]['reflections'][0]['d'],4.12)
        self.assertEqual(len(values[1]['trajectory']),2)
        self.assertEqual(values[2]['units'],'hartree')
        self.assertTrue(math.isfinite(values[2]['energy']) and values[2]['energy']<0)

    def test_tampered_binding_and_truncated_nonfinite_input(self):
        request=envelope(); request['requestJSON']+=' '
        value=execute(request)
        self.assertFalse(value['ok']); self.assertNotIn('identity',value)
        request=envelope(); request['identity']['objectRevision']=True
        self.assertFalse(execute(request)['ok'])
        self.assertFalse(execute('{"operation":')['ok'])
        self.assertFalse(execute('{"operation":"rdkit.describe","format":"smi","data":"O","options":{"seed":1e999}}')['ok'])
        self.assertFalse(execute(dict(operation='unknown.method',format='smi',data='O'))['ok'])

    def test_capabilities_require_usable_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            fake=pathlib.Path(directory)/'xtb'
            fake.write_text('not executable')
            env=dict(os.environ,CHEMISTRY_XTB_EXECUTABLE=str(fake),CHEMISTRY_JOB_DIRECTORY=directory)
            value=execute(dict(operation='capabilities',format='',data='',options={}),env)['result']
            self.assertEqual(value['protocolVersion'],1)
            self.assertIn('rdkit.describe',value['methods'])
            self.assertIn('gemmi.crystal',value['methods'])
            self.assertIn('openmm.system',value['methods'])
            self.assertIn('CPU',value['openmmPlatforms'])
            self.assertNotIn('xtb.singlepoint',value['methods'])
            self.assertIn('xtb',value['unavailable'])
            self.assertTrue(value['engines']['rdkit'])

if __name__=='__main__': unittest.main()
