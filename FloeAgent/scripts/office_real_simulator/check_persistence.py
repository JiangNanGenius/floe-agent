#!/usr/bin/env python3
"""Persistence gate on the file that survived the run.

Two gates inspect artifacts, not the web view existence flag:

render: handled by check_render.py;

persistence: the PPTX is read back out of the HOST app container
``Documents/TestFiles`` and must be a valid OOXML zip with 2 seeded slides + 1
inserted slide (= 3), a changed SHA-256, and a phase receipt whose EXACT phase
set is all ok.  The receipt is the one extracted by ``extract_receipt.py``
(typed xcresult attachment or the UITest runner container) -- the host app
container never contains the UITest runner's file, so it is not consulted.

Missing file, missing receipt, missing/failed/extra phases all fail closed and
still write the result JSON for evidence.

This proves host-app render and persistence only when the pinned upstream host
actually writes edited content back; it is not Floe app acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

from sim_paths import (FIXTURE_BASENAME, HOST_BUNDLE_ID, SCENARIO_PHASES)

EXPECTED_FINAL_SLIDES = 3
EXPECTED_PHASES = SCENARIO_PHASES


def run(command):
    return subprocess.run([str(item) for item in command], text=True,
                          capture_output=True)


def count_slides(path):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError(f'corrupt zip: {path}')
        slides = sorted(name for name in archive.namelist()
                        if name.startswith('ppt/slides/slide')
                        and name.endswith('.xml'))
    return len(slides)


def validate_receipt(receipt):
    """Require a nonempty receipt with exact expected phase coverage, all ok."""
    failures = []
    if not isinstance(receipt, dict) or not receipt:
        return False, ['receipt empty or not an object']
    phases = receipt.get('phases')
    if not isinstance(phases, list) or not phases:
        return False, ['receipt phases missing or empty']
    observed = {}
    for phase in phases:
        if not isinstance(phase, dict) or 'phase' not in phase:
            failures.append('malformed phase entry')
            continue
        observed[phase['phase']] = bool(phase.get('ok'))
    names = set(observed)
    missing = [name for name in EXPECTED_PHASES if name not in names]
    if missing:
        failures.append(f'missing phases: {missing}')
    extra = sorted(name for name in names if name not in EXPECTED_PHASES)
    if extra:
        failures.append(f'unexpected phases: {extra}')
    failed = [name for name, ok in observed.items() if not ok]
    if failed:
        failures.append(f'phases not ok: {failed}')
    return not failures, failures


def container_for(simulator):
    result = run(['xcrun', 'simctl', 'get_app_container', simulator,
                  HOST_BUNDLE_ID, 'data'])
    return result.stdout.strip() if result.returncode == 0 else ''


def check_persistence(simulator, seeded_sha256, receipt_path,
                      receipt_source=None):
    result = {
        'seededSHA256': seeded_sha256,
        'expectedSlideCount': EXPECTED_FINAL_SLIDES,
        'expectedPhases': list(EXPECTED_PHASES),
        'receiptPath': str(receipt_path) if receipt_path else None,
        'receiptSource': receipt_source,
        'hostKind': 'upstream-mobile-host-only',
        'blockingFailures': [],
    }

    container = container_for(simulator)
    result['container'] = container
    persisted = Path(container) / 'Documents/TestFiles' / FIXTURE_BASENAME \
        if container else None
    if persisted is None or not persisted.is_file():
        result['persistedPath'] = str(persisted) if persisted else None
        result['persistedPresent'] = False
        result['receiptPresent'] = False
        result['receiptFailures'] = ['not evaluated: persisted fixture missing']
        result['blockingFailures'].append(
            f'persisted fixture missing: {persisted}')
        result['persistencePassed'] = False
        return result
    data = persisted.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    slides = count_slides(persisted)
    result.update({
        'persistedPath': str(persisted),
        'persistedSHA256': digest,
        'bytesChanged': digest != seeded_sha256,
        'slideCount': slides,
        'slideCountCorrect': slides == EXPECTED_FINAL_SLIDES,
    })

    receipt = None
    receipt_failures = ['receipt was never read']
    receipt_ok = False
    if receipt_path is None:
        receipt_failures = ['no receipt path provided (runner/host separation)']
    else:
        path = Path(receipt_path)
        if not path.is_file():
            receipt_failures = [f'receipt file missing: {path}']
        else:
            try:
                candidate = json.loads(path.read_text())
                # extract_receipt.py writes a "found: false" report only as
                # a separate report; a receipt file must itself be a receipt.
                if isinstance(candidate, dict) and candidate.get('found') is False \
                        and 'phases' not in candidate:
                    receipt_failures = [
                        f'receipt placeholder without phases: {path}']
                else:
                    receipt = candidate
                    receipt_ok, receipt_failures = validate_receipt(receipt)
            except (json.JSONDecodeError, OSError) as error:
                receipt_failures = [f'receipt unreadable: {error}']
    result.update({
        'receiptPresent': receipt is not None,
        'receiptPhasesAllOk': receipt_ok,
        'receiptFailures': receipt_failures,
    })

    result['writeBackAbsent'] = not result['bytesChanged']
    result['persistencePassed'] = (
        result['bytesChanged'] and result['slideCountCorrect']
        and result['receiptPresent'] and receipt_ok)
    if not result['persistencePassed']:
        if not result['bytesChanged']:
            result['blockingFailures'].append(
                'host did not write edited content back to Documents/TestFiles '
                '(seeded hash unchanged)')
        if not result['slideCountCorrect']:
            result['blockingFailures'].append(
                f"slide count {slides} != {EXPECTED_FINAL_SLIDES}")
        if not receipt_ok:
            result['blockingFailures'].extend(receipt_failures)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('simulator')
    parser.add_argument('seeded_sha256')
    parser.add_argument('--receipt', required=True,
                        help='Receipt extracted from the xcresult/runner container')
    parser.add_argument('--receipt-source', default=None)
    parser.add_argument('--output', default=None)
    args = parser.parse_args()
    result = check_persistence(args.simulator, args.seeded_sha256,
                               args.receipt, args.receipt_source)
    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    if not result['persistencePassed']:
        print('PERSISTENCE GATE FAILED: '
              + '; '.join(result['blockingFailures']), file=sys.stderr)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
