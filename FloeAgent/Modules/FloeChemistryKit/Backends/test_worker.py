import json, pathlib, subprocess, sys, unittest

WORKER = pathlib.Path(__file__).with_name('chemistry_worker.py')
def run(operation, data, options=None, fmt='smi'):
    request = dict(operation=operation,format=fmt,data=data,options=options or {})
    result = subprocess.run([sys.executable,str(WORKER)],input=json.dumps(request),text=True,capture_output=True,check=True)
    return json.loads(result.stdout)

class ChemistryWorkerTests(unittest.TestCase):
    def test_descriptor_and_stereo(self):
        value = run('rdkit.describe','C[C@H](O)F')['result']
        self.assertIn('@',value['canonicalSmiles'])
        self.assertAlmostEqual(run('rdkit.describe','CCO')['result']['mass'],46.069,places=2)
    def test_embedding_and_roundtrip(self):
        value = run('rdkit.embed','CCO')['result']
        self.assertTrue(value['conformers'][0]['converged'])
        self.assertEqual(len(json.loads(value['cjson'])['atoms']['coords']['3d']),27)
        other = run('rdkit.describe',value['cjson'],fmt='cjson')['result']
        self.assertEqual(other['formula'],'C2H6O')
        self.assertEqual(value['units'],'kcal/mol')
    def test_conformers_stereo_and_isotopes(self):
        value = run('rdkit.conformers','CCCC',{'conformers':3})['result']
        self.assertEqual(len(value['conformers']),3)
        original = 'C[C@H](O)F'
        embedded = run('rdkit.embed',original)['result']
        reloaded = run('rdkit.describe',embedded['cjson'],fmt='cjson')['result']
        self.assertIn('@',reloaded['canonicalSmiles'])
        self.assertNotIn('cjson',run('rdkit.describe',original)['result'])
        isotope = run('rdkit.describe','[13CH4]')['result']
        reloaded = run('rdkit.describe',isotope['cjson'],fmt='cjson')['result']
        self.assertIn('13',reloaded['canonicalSmiles'])
    def test_fingerprints_and_substructure(self):
        self.assertEqual(run('rdkit.similarity','CCO',{'query':'CCO'})['result']['tanimoto'],1)
        self.assertEqual(len(run('rdkit.substructure','CCO',{'smarts':'[OX2H]'})['result']['matches']),1)
    def test_rules_and_failures(self):
        value = run('rdkit.reaction',json.dumps({'reactants':['CCO']}),{'smarts':'[C:1][O:2]>>[C:1]=[O:2]'},'reaction.json')
        self.assertTrue(value['ok']); self.assertIn('CC=O',value['result']['products'][0])
        self.assertFalse(run('rdkit.embed','not-a-smiles')['ok'])
        self.assertFalse(run('rdkit.embed','CCO',{'iterations':-1})['ok'])

if __name__=='__main__': unittest.main()
