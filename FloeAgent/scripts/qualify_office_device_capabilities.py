#!/usr/bin/env python3
"""Record Office release capabilities from *verified physical-device* receipts.

This is the only path that may set `embeddedEditorPassed`,
`pptxVisibleRenderPassed`, `deviceRoundtripPassed` or
`originalFileWritebackPassed` in `engine.lock.json`. It refuses to run when the
receipts are missing, internally inconsistent, or do not describe a real
edit/save/close/reopen roundtrip on named hardware, so a compile/link result can
never be promoted into device evidence. Nothing is written without `--apply`.

Receipts consumed (all produced by the isolated probe app, never by Floe itself):

  <receipts>/render-receipt.json        host visible-render facts + deck digest
  <receipts>/events.json                probe lifecycle events
  <receipts>/roundtrip-<ext>.json       per-format edit/save/close/reopen receipt
  --original-writeback <file.json>      original-file write-back receipt
  --embedded <file.json>                verify_office_app_embedding.py receipt

Usage:
  python3 qualify_office_device_capabilities.py \
      --receipts ./device --device-model 'iPad14,3' --os-version '26.0' --run-id 123456 \
      --original-writeback ./device/original-writeback.json \
      --embedded ./app-embedding.json [--apply]
"""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / 'fixtures'))

from office_release_gates import CAPABILITY_FLAGS, EVIDENCE, capability_status
from verify_pptx_deck_semantics import DEFAULT_DECK, digest, verify_render_receipt

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / 'ThirdParty/Collabora/engine.lock.json'

ROUNDTRIP_FORMATS = ('docx', 'xlsx', 'pptx')
REQUIRED_EVENTS = {
    'opened': 1,
    'saveRequested': 1,
    'saveCompleted': 1,
    'editingClosed': 1,
    'reopenedReadonly': 1,
}
FORBIDDEN_EVENTS = ('unexpectedClose', 'visibleRenderFailed', 'saveFailed')


def _read_json(path):
    return json.loads(Path(path).read_text())


def _event_counts(events):
    counts = {}
    for event in events if isinstance(events, list) else []:
        name = event.get('event') if isinstance(event, dict) else None
        if name:
            counts[name] = counts.get(name, 0) + 1
    return counts


def verify_render(receipts, deck):
    failures = verify_render_receipt(receipts / 'render-receipt.json', deck)
    events = _read_json(receipts / 'events.json') if (receipts / 'events.json').is_file() else {}
    counts = _event_counts(events.get('events') if isinstance(events, dict) else events)
    if counts.get('visibleRender', 0) < 1:
        failures.append('events.json records no visibleRender event')
    for name in FORBIDDEN_EVENTS:
        if counts.get(name, 0):
            failures.append(f'events.json records a failing event: {name}')
    return failures


def verify_roundtrip(receipts):
    failures = []
    for extension in ROUNDTRIP_FORMATS:
        path = receipts / f'roundtrip-{extension}.json'
        if not path.is_file():
            failures.append(f'missing roundtrip receipt for {extension}: {path.name}')
            continue
        receipt = _read_json(path)
        if receipt.get('documentType') != extension:
            failures.append(f'{path.name}: documentType {receipt.get("documentType")!r} != {extension}')
        for field in ('edited', 'savedWorkingCopy', 'closed', 'reopened'):
            if receipt.get(field) is not True:
                failures.append(f'{path.name}: {field} is not true')
        events = receipt.get('events')
        if not isinstance(events, list) or not events:
            failures.append(f'{path.name}: no device events recorded')
            continue
        counts = _event_counts(events)
        for name, minimum in REQUIRED_EVENTS.items():
            if counts.get(name, 0) < minimum:
                failures.append(f'{path.name}: missing device event {name}')
        for name in FORBIDDEN_EVENTS:
            if counts.get(name, 0):
                failures.append(f'{path.name}: failing device event {name}')
        saved = receipt.get('savedSHA256')
        if not isinstance(saved, str) or len(saved) != 64:
            failures.append(f'{path.name}: saved copy has no sha256 digest')
    return failures


def verify_writeback(receipt_path, deck):
    if receipt_path is None or not Path(receipt_path).is_file():
        return ['no original-file write-back receipt was provided']
    receipt = _read_json(receipt_path)
    failures = []
    if receipt.get('originalFileWriteback') is not True:
        failures.append('write-back receipt does not confirm the original file was written')
    for field in ('documentType', 'savedSHA256'):
        if not receipt.get(field):
            failures.append(f'write-back receipt is missing {field}')
    saved = receipt.get('savedSHA256')
    if isinstance(saved, str) and len(saved) != 64:
        failures.append('write-back receipt savedSHA256 is not a sha256 digest')
    if receipt.get('documentType') == 'pptx' and receipt.get('deckSHA256') not in (None, digest(deck)):
        failures.append('write-back receipt deck digest does not match the fixture')
    if receipt.get('conflictHandled') is True and receipt.get('resolution') not in ('mine', 'theirs'):
        failures.append('a conflict was reported without a recorded resolution')
    return failures


def verify_embedded(receipt_path):
    if receipt_path is None or not Path(receipt_path).is_file():
        return ['no App embedding receipt was provided']
    receipt = _read_json(receipt_path)
    failures = []
    if receipt.get('unsignedPayloadVerified') is not True:
        failures.append('embedding receipt did not verify the App Office payload')
    if not receipt.get('appVersion') or not receipt.get('appBuild'):
        failures.append('embedding receipt carries no App version/build')
    if receipt.get('hostExecutableSHA256') is None:
        failures.append('embedding receipt carries no host executable digest')
    return failures


def qualify(receipts, deck, device_model, os_version, run_id,
            original_writeback=None, embedded=None):
    """Deterministic verdict; callers decide whether to record it."""
    receipts = Path(receipts) if receipts else None
    failures = []
    render_failures = verify_render(receipts, deck) if receipts else ['no device receipts were provided']
    roundtrip_failures = verify_roundtrip(receipts) if receipts else ['no roundtrip receipts were provided']
    writeback_failures = verify_writeback(original_writeback, deck)
    embedded_failures = verify_embedded(embedded)
    failures.extend(render_failures)
    failures.extend(roundtrip_failures)
    failures.extend(writeback_failures)
    failures.extend(embedded_failures)
    for name, value in (('device model', device_model), ('OS version', os_version), ('run id', run_id)):
        if not value:
            failures.append(f'no {name} was recorded')
    if failures:
        return {'capabilities': {}, 'failures': failures, 'releaseReady': False}, failures
    render = _read_json(receipts / 'render-receipt.json')
    writeback = _read_json(original_writeback)
    embedding = _read_json(embedded)
    recorded_at = writeback.get('recordedAt') or render.get('recordedAt')
    evidence = {
        'capabilityQualification': {flag: True for flag in CAPABILITY_FLAGS},
        'embeddedEditorEvidence': {
            'runID': str(run_id), 'appBuildVersion': f"{embedding.get('appVersion')} ({embedding.get('appBuild')})",
            'payloadVerified': True, 'recordedAt': recorded_at},
        'pptxVisibleRenderEvidence': {
            'runID': str(run_id), 'deviceModel': device_model, 'osVersion': os_version,
            'documentType': 'presentation', 'readyTiles': render['readyTiles'],
            'canvasWidth': render['canvasWidth'], 'canvasHeight': render['canvasHeight'],
            'elapsedMs': render.get('elapsedMs', 0), 'recordedAt': recorded_at},
        'deviceRoundtripEvidence': {
            'runID': str(run_id), 'deviceModel': device_model, 'osVersion': os_version,
            'documentTypes': list(ROUNDTRIP_FORMATS), 'recordedAt': recorded_at},
        'originalFileWritebackEvidence': {
            'runID': str(run_id), 'deviceModel': device_model,
            'documentType': writeback['documentType'], 'savedSHA256': writeback['savedSHA256'],
            'recordedAt': recorded_at},
    }
    status = capability_status(evidence)
    if status['failures']:
        return {'capabilities': {}, 'failures': status['failures'], 'releaseReady': False}, status['failures']
    return evidence, []


def apply_to_lock(lock_path, evidence):
    lock_path = Path(lock_path)
    lock = json.loads(lock_path.read_text())
    pin = lock['qualifiedHostArtifact']
    pin['capabilityQualification'] = evidence['capabilityQualification']
    for flag in CAPABILITY_FLAGS:
        key = EVIDENCE[flag]['key']
        pin[key] = evidence[key]
    lock['qualifiedHostArtifact'] = pin
    lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + '\n')
    return pin


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipts', type=Path)
    parser.add_argument('--deck', type=Path, default=DEFAULT_DECK)
    parser.add_argument('--device-model')
    parser.add_argument('--os-version')
    parser.add_argument('--run-id')
    parser.add_argument('--original-writeback', type=Path)
    parser.add_argument('--embedded', type=Path)
    parser.add_argument('--lock', type=Path, default=LOCK)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    evidence, failures = qualify(args.receipts, args.deck, args.device_model, args.os_version,
                                 args.run_id, args.original_writeback, args.embedded)
    if failures:
        print('Office device qualification rejected:', file=sys.stderr)
        for failure in failures:
            print(f'  - {failure}', file=sys.stderr)
        return 1
    if args.apply:
        apply_to_lock(args.lock, evidence)
        print(f'Office capabilities recorded in {args.lock}')
    else:
        print(json.dumps(evidence, indent=2))
        print('dry run: pass --apply to record these capabilities in the pin')
    return 0


if __name__ == '__main__':
    sys.exit(main())
