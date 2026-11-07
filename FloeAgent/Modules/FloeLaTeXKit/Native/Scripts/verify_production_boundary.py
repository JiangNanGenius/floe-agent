#!/usr/bin/env python3
"""Read-only check: the MPL App package must not link the GPL experiment."""
from pathlib import Path
import argparse,json,subprocess
p=argparse.ArgumentParser();p.add_argument('--binary',type=Path);a=p.parse_args()
module=Path(__file__).resolve().parents[2]
manifest=(module/'Package.swift').read_text()
assert '.binaryTarget(' not in manifest,'Native binaries must remain in the isolated experiment'
assert 'name:"FloeTeXNative"' not in manifest,'GPL native dependency entered the production graph'
for source in (module/'Sources').rglob('*.swift'):
 assert 'import FloeTeXNative' not in source.read_text(),'Native TeX ABI imported by the production package: '+str(source)
if a.binary:
 result=subprocess.run(['nm','-g',str(a.binary)],capture_output=True,text=True,check=True)
 for symbol in ['_floe_tex_compile','_tt_xetex_simple_main','_dvipdfmx_main']:
  assert symbol not in result.stdout,'Unexpected native experiment symbol: '+symbol
print(json.dumps({'status':'pass','productionPackage':'FloeLaTeXKit','nativeExperiment':'explicit separate package, excluded from production dependency graph','binaryChecked':str(a.binary) if a.binary else None}))
