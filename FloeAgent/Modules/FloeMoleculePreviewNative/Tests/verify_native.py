#!/usr/bin/env python3
"""Numerical oracle for a real native executable; RDKit/Python are test-only."""
import argparse
import hashlib
import json
import math
import pathlib
import statistics
import subprocess
import time

import numpy as np
from rdkit import Chem, rdBase
from rdkit.Chem import rdDepictor

MODULE = pathlib.Path(__file__).resolve().parents[1]
REPO = MODULE.parents[2]
EXAMPLES = {
    'ethanol': 'CCO', 'benzene': 'c1ccccc1', 'cyclohexane': 'C1CCCCC1',
    'lactic-R': 'C[C@H](O)C(=O)O', 'lactic-S': 'C[C@@H](O)C(=O)O',
    'alkene-E': 'F/C=C/F', 'alkene-Z': 'F/C=C\\F',
    'isotope-charge': '[13CH3][NH3+]', 'aspirin': 'CC(=O)Oc1ccccc1C(=O)O'
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--probe', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    fixture_root = MODULE / 'Qualification/Fixtures'
    fixture_root.mkdir(parents=True, exist_ok=True)
    rows = []
    failures = []

    def invoke(request, switch=None):
        raw = json.dumps(request).encode()
        started = time.monotonic()
        process = subprocess.run([str(args.probe.resolve())]+([switch] if switch else []),
                                 input=raw, capture_output=True, timeout=12, check=True)
        return json.loads(process.stdout), (time.monotonic()-started)*1000

    def case(name, action):
        try:
            details = action()
            rows.append({'name': name, 'passed': True, **details})
        except Exception as error:
            failures.append(name)
            rows.append({'name': name, 'passed': False, 'error': repr(error)})

    native_results = {}
    fixtures = []
    for name, smiles in EXAMPLES.items():
        mol = Chem.MolFromSmiles(smiles)
        rdDepictor.Compute2DCoords(mol)
        block = Chem.MolToMolBlock(mol)
        path = fixture_root / (name+'.mol')
        path.write_text(block)
        fixtures.append({'id': name, 'smiles': smiles, 'file': path.name, 'sha256': digest(block.encode())})

        def check_molecule(name=name, smiles=smiles, mol=mol, block=block):
            request = {'input': block, 'format': 'mol'}
            reply, wall = invoke(request)
            (args.output/(name+'.reply.json')).write_text(json.dumps(reply, indent=2)+'\n')
            assert reply['ok'], reply
            result = reply['result']
            native_results[name] = result
            generated = Chem.MolFromMolBlock(result['molblock'], removeHs=False)
            assert generated is not None
            # Independent parsing of the real 3D output must recover the exact
            # chemical identity, including isotope, charge and specified stereo.
            actual = Chem.RemoveHs(generated)
            assert Chem.MolToSmiles(actual, isomericSmiles=True) == Chem.MolToSmiles(mol, isomericSmiles=True)
            assert result['atomCount'] == Chem.AddHs(mol).GetNumAtoms()
            assert result['bondCount'] == Chem.AddHs(mol).GetNumBonds()
            assert result['inputAtomToOutput'] == list(range(mol.GetNumAtoms()))
            cjson = json.loads(result['cjson'])
            xyz = np.asarray(cjson['atoms']['coords']['3d']).reshape(-1, 3)
            assert np.isfinite(xyz).all() and np.ptp(xyz, axis=0).max() > 0.5
            assert [a.GetAtomicNum() for a in mol.GetAtoms()] == cjson['atoms']['elements']['number'][:mol.GetNumAtoms()]
            assert [a.GetFormalCharge() for a in mol.GetAtoms()] == cjson['atoms']['formalCharges'][:mol.GetNumAtoms()]
            assert [a.GetIsotope() for a in mol.GetAtoms()] == cjson['atoms']['isotopes'][:mol.GetNumAtoms()]
            heavy = xyz[:mol.GetNumAtoms()]
            metrics = {}
            if name == 'ethanol':
                u, v = heavy[0]-heavy[1], heavy[2]-heavy[1]
                angle = math.degrees(math.acos(np.dot(u, v)/np.linalg.norm(u)/np.linalg.norm(v)))
                assert 95 < angle < 125
                assert 1.3 < np.linalg.norm(u) < 1.7 and 1.2 < np.linalg.norm(v) < 1.7
                metrics['CCOAngleDegrees'] = angle
            if name in ('benzene', 'cyclohexane'):
                centered = heavy-heavy.mean(axis=0)
                _, _, vt = np.linalg.svd(centered)
                distances = centered @ vt[-1]
                rms = float(np.sqrt(np.mean(distances**2)))
                assert rms < 0.02 if name == 'benzene' else rms > 0.15
                metrics['heavyAtomPlaneRMSAngstrom'] = rms
            duplicate, _ = invoke(request)
            assert duplicate['ok'] and duplicate['result']['cjson'] == result['cjson']
            return {'nativeMilliseconds': result['totalMilliseconds'], 'processWallMilliseconds': wall,
                    'atomCount': result['atomCount'], 'optimizationStatus': result['optimizationStatus'],
                    'inputSHA256': digest(block.encode()), 'outputSHA256': digest(result['molblock'].encode()), **metrics}
        case('MOL-2D-'+name, check_molecule)

    (fixture_root/'index.json').write_text(json.dumps(fixtures, indent=2)+'\n')

    def negative(name, request, expected, switch=None):
        def perform():
            reply, wall = invoke(request, switch)
            assert reply['ok'] is False and reply['code'] == expected, reply
            return {'code': reply['code'], 'processWallMilliseconds': wall}
        case(name, perform)

    negative('invalid-valence', {'input':'C(C)(C)(C)(C)C','format':'smiles'}, 'invalidMolecule')
    negative('multiple-fragments', {'input':'CC.O','format':'smiles'}, 'multipleFragments')
    negative('atom-budget', {'input':'C'*129,'format':'smiles'}, 'atomLimit')
    negative('preparse-graph-budget', {'input':'C'*10000,'format':'smiles'}, 'atomLimit')
    negative('preparse-v3000-budget', {'input':'test\n  Floe 2D\n\n  0  0  0     0  0            999 V3000\nM  V30 BEGIN CTAB\nM  V30 COUNTS 1000000000 0 0 0 0\n','format':'mol'}, 'atomLimit')
    negative('unsupported-raster', {'input':'image','format':'png'}, 'unsupportedFormat')
    negative('pre-cancel', {'input':'CCO','format':'smiles'}, 'cancelled', '--cancel')
    negative('cancel-during-embedding', {'input':'C'*80,'format':'smiles'}, 'cancelled', '--cancel-embedding')
    negative('timeout-budget', {'input':'C'*100,'format':'smiles','options':{'timeoutMilliseconds':1}}, 'timeout')

    def no_optimization():
        reply, _ = invoke({'input':'CCO','format':'smiles','options':{'forceField':'none'}})
        assert reply['ok'] and reply['result']['optimizationStatus']=='skipped'
        assert reply['result']['energy'] is None
        return {'status': reply['result']['optimizationStatus']}
    case('preview-without-energy-calculation', no_optimization)
    def unavailable_parameters():
        reply, _ = invoke({'input':'[Xe]','format':'smiles'})
        assert reply['ok'] and reply['result']['optimizationStatus']=='parametersUnavailable'
        assert reply['result']['forceField']=='MMFF94' and reply['result']['energy'] is None
        return {'status': reply['result']['optimizationStatus'], 'silentForceFieldFallback': False}
    case('missing-parameters-keeps-explicit-unoptimized-preview', unavailable_parameters)
    timings = [r['nativeMilliseconds'] for r in rows if 'nativeMilliseconds' in r]
    report = {'oracle': 'Test-only RDKit '+rdBase.rdkitVersion, 'probe': str(args.probe.resolve()),
              'probeSHA256': digest(args.probe.read_bytes()), 'passed': not failures,
              'caseCount': len(rows), 'failedCases': failures, 'cases': rows,
              'nativeMedianMilliseconds': statistics.median(timings) if timings else None,
              'nativeMaxMilliseconds': max(timings) if timings else None,
              'scope': 'Actual macOS arm64 C++ executable; not iPad/Simulator timing or full-App acceptance.'}
    (args.output/'RESULT.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report['passed'] else 1)


if __name__ == '__main__':
    main()
