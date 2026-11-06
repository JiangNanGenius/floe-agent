import json, math, unittest
from test_worker import run

CIF='''data_CsCl
_cell_length_a 4.12
_cell_length_b 4.12
_cell_length_c 4.12
_cell_angle_alpha 90
_cell_angle_beta 90
_cell_angle_gamma 90
_space_group_name_H-M_alt 'P 1'
loop_
_atom_site_label
_atom_site_type_symbol
_atom_site_fract_x
_atom_site_fract_y
_atom_site_fract_z
Cs1 Cs 0 0 0
Cl1 Cl 0.5 0.5 0.5
'''
PDB='ATOM      1  N   GLY A   1       0.000   0.000   0.000  1.00  0.00           N  \nATOM      2  CA  GLY A   1       1.400   0.000   0.000  1.00  0.00           C  \nEND\n'

class ScienceTests(unittest.TestCase):
    def test_crystal_and_diffraction(self):
        value=run('gemmi.diffraction',CIF,{'hkls':[[1,0,0],[1,1,0]]},'cif')
        self.assertTrue(value['ok'],value)
        result=value['result'];self.assertEqual(result['atomCount'],2)
        self.assertAlmostEqual(result['volume'],4.12**3)
        self.assertAlmostEqual(result['reflections'][0]['d'],4.12)
        self.assertAlmostEqual(result['reflections'][1]['d'],4.12/math.sqrt(2))
        self.assertGreater(result['reflections'][0]['intensity'],0)
    def test_biological_chain_selection(self):
        value=run('gemmi.structure',PDB,{'chain':'A'},'pdb')
        self.assertTrue(value['ok'],value)
        self.assertEqual(value['result']['chains'][0]['residues'],['GLY'])
        self.assertFalse(run('gemmi.structure',PDB,{'chain':'missing'},'pdb')['ok'])
    def test_real_openmm_trajectory_and_system_roundtrip(self):
        source='2\nargon pair\nAr 0 0 0\nAr 4 0 0\n'
        value=run('openmm.lennardJones',source,{'steps':20,'sampleEvery':5},'xyz')
        self.assertTrue(value['ok'],value)
        result=value['result'];self.assertEqual(len(result['trajectory']),4)
        expected=4*0.997*((0.34/0.4)**12-(0.34/0.4)**6)
        self.assertAlmostEqual(result['initialEnergy'],expected,places=5)
        self.assertTrue(math.isfinite(result['energy']))
        self.assertNotEqual(result['trajectory'][0]['positions'],result['trajectory'][-1]['positions'])
        other=run('openmm.system',source,{'systemXML':result['systemXML'],'steps':2},'xyz')
        self.assertTrue(other['ok'],other)
        self.assertFalse(run('openmm.system',source,{'steps':2},'xyz')['ok'])

if __name__=='__main__':unittest.main()
