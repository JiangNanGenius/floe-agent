#!/usr/bin/env python3
"""Retrieve the phase receipt the UITest wrote, from the places it can live.

A UI test runs in its own runner process, so ``FileManager`` documents in the
test code are the *runner's* data container -- never the host app container the
persistence gate reads for the PPTX.  The old gate looked for the receipt in
the host container and therefore claimed a path that could never contain it.

Retrieval order:

1. the typed ``sim-qual-receipt`` XCTAttachment exported from the xcresult
   (authoritative; survives app termination and is captured in the artifact);
   ``xcresulttool export attachments`` writes a ``manifest.json`` that maps
   ``suggestedHumanReadableName``/``exportedFileName`` to the exported file;
2. the explicitly resolved UITest runner data container
   (``simctl get_app_container <sim> <runner-bundle-id> data`` ->
   ``Documents/sim-qual-receipt.json``) as a diagnostics fallback.

The script never invents a receipt: when neither source exists it writes a
report with ``found: false`` and every location searched, and the persistence
gate fails closed with that evidence.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

from sim_paths import RECEIPT_ATTACHMENT_NAME, RECEIPT_FILENAME


def find_attachment(attachments_dir, name=RECEIPT_ATTACHMENT_NAME):
    """Return the exported file path for the named attachment, or None."""
    attachments_dir = Path(attachments_dir)
    manifest_path = attachments_dir / 'manifest.json'
    if not manifest_path.is_file():
        return None
    try:
        manifest = json.loads(manifest_path.read_text())
    except (json.JSONDecodeError, OSError):
        return None
    entries = manifest if isinstance(manifest, list) else manifest.get('attachments', [])
    for group in entries:
        if not isinstance(group, dict):
            continue
        for attachment in group.get('attachments', []):
            if not isinstance(attachment, dict):
                continue
            suggested = attachment.get('suggestedHumanReadableName', '')
            exported = attachment.get('exportedFileName', '')
            if (suggested == name or suggested.startswith(name + '_')
                    or suggested.startswith(name + '.')
                    or Path(exported).name.startswith(name)):
                candidate = attachments_dir / exported
                if candidate.is_file():
                    return candidate
    return None


def runner_container(simulator, runner_bundle_id):
    result = subprocess.run(
        ['xcrun', 'simctl', 'get_app_container', simulator,
         runner_bundle_id, 'data'],
        capture_output=True, text=True)
    if result.returncode != 0:
        return None, result.stderr.strip()
    path = result.stdout.strip()
    return (Path(path), '') if path else (None, 'empty simctl output')


def extract(attachments_dir, simulator, runner_bundle_id, output, report_path,
            name=RECEIPT_ATTACHMENT_NAME):
    searched = []
    report = {
        'attachmentName': name,
        'found': False,
        'source': None,
        'output': None,
        'searched': searched,
    }
    attachment = None
    if attachments_dir:
        searched.append(str(Path(attachments_dir) / 'manifest.json'))
        attachment = find_attachment(attachments_dir, name)
    if attachment is not None:
        report['found'] = True
        report['source'] = 'xcresult-attachment'
        report['exportedFileName'] = attachment.name
        report['path'] = str(attachment)
    elif simulator and runner_bundle_id:
        container, error = runner_container(simulator, runner_bundle_id)
        candidate = container / 'Documents' / RECEIPT_FILENAME if container else None
        searched.append(str(candidate) if candidate else 'runner-container-unavailable')
        if candidate is not None and candidate.is_file():
            report['found'] = True
            report['source'] = 'runner-container'
            report['path'] = str(candidate)
            attachment = candidate
        elif error:
            report['runnerContainerError'] = error
    elif simulator:
        report['runnerContainerError'] = 'runner bundle id not provided'

    if report['found'] and output:
        Path(output).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(report['path'], output)
        report['output'] = str(output)
    if report_path:
        Path(report_path).parent.mkdir(parents=True, exist_ok=True)
        Path(report_path).write_text(json.dumps(report, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--attachments', default=None,
                        help='Directory passed to xcresulttool export attachments')
    parser.add_argument('--simulator', default=None)
    parser.add_argument('--runner-bundle-id', default=None)
    parser.add_argument('--name', default=RECEIPT_ATTACHMENT_NAME)
    parser.add_argument('--output', default=None,
                        help='Copy the resolved receipt here for the gate')
    parser.add_argument('--report', default=None)
    args = parser.parse_args()
    report = extract(args.attachments, args.simulator, args.runner_bundle_id,
                     args.output, args.report, args.name)
    print(json.dumps(report, indent=2))
    if not report['found']:
        print('RECEIPT NOT FOUND; persistence gate will fail closed',
              file=sys.stderr)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
