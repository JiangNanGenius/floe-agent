#!/usr/bin/env python3
"""Resolve the real-engine UITest receipt and frames from the xcresult export.

``xcrun xcresulttool export attachments`` names the exported files itself: the
``exportedFileName`` is frequently a GUID with a file extension and is NOT the
attachment's ``name``. The export directory's ``manifest.json`` (schema 0.4,
the default) maps both identities::

    [
      {
        "testIdentifier": "...",
        "attachments": [
          {"exportedFileName": "3F2A….png",
           "suggestedHumanReadableName": "01-preview.png",
           "configurationName": "...", "deviceId": "...", ...},
          {"exportedFileName": "9C1B….json",
           "suggestedHumanReadableName": "office-real-engine-receipt.json", ...}
        ]
      },
      ...
    ]

This resolver validates every match before it is accepted, and fails closed:

* the exported path must be a relative, non-symlink regular file contained in
  the export directory (no absolute path and no ``..`` escape);
* an attachment name that matches more than one export is ambiguous and fails;
* a missing receipt or any missing/ambiguous frame fails (nothing is
  fabricated);
* malformed manifest JSON or a manifest that is not the documented shape
  fails.

The runner's OWN data container is the only fallback for the typed receipt
(the UI test runs in a separate runner process, so its Documents directory is
never the host app container).

The independent upstream ``office_real_simulator`` pipeline is untouched.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

RECEIPT_ATTACHMENT_NAME = 'office-real-engine-receipt'
RECEIPT_FILENAME = 'office-real-engine-receipt.json'
# Named simulator frames the scenario attaches, in lifecycle order.
FRAME_TOKENS = ('01-preview', '02-edit', '03-idle-120s', '04-reopen',
                '05-persisted')
IMAGE_EXTENSIONS = ('.png', '.jpg', '.jpeg', '.data')


class AttachmentResolveError(ValueError):
    pass


def _strip_extension(name):
    suffix = Path(name).suffix.lower()
    if suffix in IMAGE_EXTENSIONS or suffix in ('.json', '.txt'):
        return name[: -len(suffix)]
    return name


def load_manifest(attachments_dir):
    manifest_path = Path(attachments_dir) / 'manifest.json'
    if not manifest_path.is_file():
        raise AttachmentResolveError(f'manifest.json missing under {attachments_dir}')
    try:
        manifest = json.loads(manifest_path.read_text())
    except json.JSONDecodeError as error:
        raise AttachmentResolveError(f'manifest.json malformed: {error}') from error
    if not isinstance(manifest, list):
        raise AttachmentResolveError('manifest.json is not the documented array schema')
    entries = []
    for group in manifest:
        if not isinstance(group, dict) or not isinstance(group.get('attachments'), list):
            raise AttachmentResolveError('manifest group lacks an attachments array')
        for attachment in group['attachments']:
            if not isinstance(attachment, dict) \
                    or not isinstance(attachment.get('exportedFileName'), str) \
                    or not isinstance(attachment.get('suggestedHumanReadableName'), str):
                raise AttachmentResolveError('manifest attachment entry is malformed')
            entries.append(attachment)
    return entries


def safe_export_path(attachments_dir, exported_name):
    """Validate an exported file name and return its contained path."""
    root = Path(attachments_dir).resolve()
    relative = Path(exported_name)
    if relative.is_absolute() or '..' in relative.parts or not relative.parts:
        raise AttachmentResolveError(
            f'exported attachment path escapes the export directory: {exported_name!r}')
    candidate = (root / relative)
    resolved = candidate.resolve()
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise AttachmentResolveError(
            f'exported attachment resolves outside the export directory: {exported_name!r}'
        ) from error
    if candidate.is_symlink():
        raise AttachmentResolveError(
            f'exported attachment is a symlink: {exported_name!r}')
    if not resolved.is_file():
        raise AttachmentResolveError(
            f'exported attachment missing or not a regular file: {exported_name!r}')
    return resolved


def _name_matches(suggested, token):
    """Match only a name or Xcode's exact name_index_UUID export spelling."""
    name = _strip_extension(suggested)
    if suggested == token or name == token:
        return True
    # Actual Xcode 27 exports append an occurrence index and attachment UUID
    # to suggestedHumanReadableName; exportedFileName has a different UUID.
    # A prefix/substring match would accept unrelated or ambiguous evidence.
    identifier = r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
    return re.fullmatch(re.escape(token) + r'_[0-9]+_' + identifier, name) is not None


def find_named(entries, attachments_dir, token):
    """Return the one validated file for a token; duplicates are ambiguous."""
    matches = [entry for entry in entries
               if _name_matches(entry['suggestedHumanReadableName'], token)]
    if not matches:
        return None, [f'no attachment named {token!r} in the manifest']
    if len(matches) > 1:
        return None, [
            f"ambiguous attachment name {token!r}: {len(matches)} exports "
            f"{[entry['exportedFileName'] for entry in matches]}"]
    path = safe_export_path(attachments_dir, matches[0]['exportedFileName'])
    return path, []


def runner_receipt_path(simulator, runner_bundle_id):
    """The typed receipt in the UITest RUNNER's own data container."""
    if not simulator or not runner_bundle_id:
        return None
    result = subprocess.run(
        ['xcrun', 'simctl', 'get_app_container', simulator,
         runner_bundle_id, 'data'],
        capture_output=True, text=True)
    if result.returncode != 0:
        return None
    container = result.stdout.strip()
    if not container:
        return None
    candidate = Path(container) / 'Documents' / RECEIPT_FILENAME
    return candidate if candidate.is_file() and not candidate.is_symlink() else None


def resolve(attachments_dir, output_dir, *, simulator=None,
            runner_bundle_id=None, frame_tokens=FRAME_TOKENS):
    """Resolve and stage the receipt + named frames. Returns a JSON report.

    Raises AttachmentResolveError when the receipt or a frame cannot be
    resolved unambiguously.
    """
    attachments_dir = Path(attachments_dir).resolve()
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    entries = load_manifest(attachments_dir)
    failures = []
    resolved = {}

    receipt_path, receipt_errors = find_named(
        entries, attachments_dir, RECEIPT_ATTACHMENT_NAME)
    receipt_source = 'xcresult-attachment'
    if receipt_path is None and not any(
            _name_matches(entry['suggestedHumanReadableName'], RECEIPT_ATTACHMENT_NAME)
            for entry in entries):
        fallback = runner_receipt_path(simulator, runner_bundle_id)
        if fallback is not None:
            receipt_path, receipt_source = fallback, 'runner-container'
        else:
            failures += receipt_errors
            if simulator:
                failures.append(
                    f'runner container fallback unavailable '
                    f'({runner_bundle_id or "no runner bundle id"})')
    elif receipt_path is None:
        # An ambiguous export must not be hidden by a runner-container copy.
        failures += receipt_errors
    if receipt_path is not None:
        target = output_dir / RECEIPT_FILENAME
        shutil.copyfile(receipt_path, target)
        resolved['receipt'] = {
            'path': str(target), 'source': receipt_source,
            'exportedFileName': receipt_path.name,
            'sha256Bytes': receipt_path.stat().st_size,
        }

    frames = {}
    for token in frame_tokens:
        path, errors = find_named(entries, attachments_dir, token)
        if path is None:
            failures += [f'frame {token}: {error}' for error in errors]
            continue
        extension = path.suffix if path.suffix else '.png'
        target = output_dir / f'{token}{extension}'
        shutil.copyfile(path, target)
        frames[token] = {'path': str(target), 'exportedFileName': path.name}
    resolved['frames'] = frames
    resolved['missingFrames'] = [token for token in frame_tokens
                                 if token not in frames]
    resolved['failures'] = failures
    resolved['resolved'] = not failures
    return resolved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--attachments', required=True,
                        help='Directory passed to xcresulttool export attachments')
    parser.add_argument('--output', required=True,
                        help='Curated directory for the receipt and named frames')
    parser.add_argument('--simulator', default=None)
    parser.add_argument('--runner-bundle-id', default=None)
    parser.add_argument('--report', default=None)
    args = parser.parse_args()
    try:
        report = resolve(args.attachments, args.output,
                         simulator=args.simulator,
                         runner_bundle_id=args.runner_bundle_id)
    except AttachmentResolveError as error:
        report = {'resolved': False, 'failures': [str(error)]}
    if args.report:
        Path(args.report).parent.mkdir(parents=True, exist_ok=True)
        Path(args.report).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    if not report.get('resolved'):
        print('ATTACHMENT RESOLUTION FAILED CLOSED; no receipt/frames fabricated',
              file=sys.stderr)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
