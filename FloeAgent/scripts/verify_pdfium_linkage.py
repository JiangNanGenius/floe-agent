#!/usr/bin/env python3
"""Reject mixed PDFium/Office FPDF bindings in the actual linked application."""
import argparse
import json
import pathlib
import plistlib
import re
import subprocess


def bindings(imports):
    return re.findall(r'\b(_FPDF\w*)\s+\(from ([^)]+)\)', imports)


def verify(imports):
    resolved = bindings(imports)
    required = {'_FPDF_LoadMemDocument64', '_FPDF_CloseDocument', '_FPDF_NewXObjectFromPage'}
    missing = required - {name for name, _ in resolved}
    wrong = [(name, library) for name, library in resolved if library != 'CPDFium']
    if missing or wrong:
        raise ValueError(f'Unsafe PDF engine bindings: missing={sorted(missing)}, wrong={wrong}')
    return resolved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    parser.add_argument('--report', type=pathlib.Path)
    args = parser.parse_args()
    info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    binary = args.app / info['CFBundleExecutable']
    imports = subprocess.check_output(['xcrun', 'dyld_info', '-imports', str(binary)], text=True)
    resolved = verify(imports)
    report = {'bundleID': info['CFBundleIdentifier'], 'build': info['CFBundleVersion'],
              'pdfiumBindings': dict(resolved), 'passed': True}
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(f'PDF engine linkage verified: {len(resolved)} FPDF imports resolve to CPDFium')


if __name__ == '__main__':
    main()
