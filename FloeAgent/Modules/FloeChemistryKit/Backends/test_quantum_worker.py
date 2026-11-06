import math,os,unittest
from test_worker import run

WATER='3\nwater\nO 0 0 0\nH 1.2 0 0\nH -0.2 1.1 0\n'
class QuantumTests(unittest.TestCase):
    def test_actual_xtb_singlepoint_and_optimization(self):
        self.assertTrue(os.environ.get('CHEMISTRY_XTB_EXECUTABLE'),'Supply a verified xTB executable; do not skip this check')
        value=run('xtb.singlepoint',WATER,{'threads':2},'xyz')
        self.assertTrue(value['ok'],value);first=value['result']
        self.assertEqual(first['units'],'hartree');self.assertTrue(math.isfinite(first['energy']) and first['energy']<0)
        self.assertAlmostEqual(sum(first['charges']),0,places=5)
        value=run('xtb.optimize',WATER,{'threads':2},'xyz')
        self.assertTrue(value['ok'],value);result=value['result']
        self.assertLessEqual(result['energy'],first['energy']);self.assertTrue(result['converged'])
        self.assertIn('cjson',result)
        self.assertFalse(run('xtb.singlepoint',WATER,{'gfn':3},'xyz')['ok'])

if __name__=='__main__':unittest.main()
