#!/usr/bin/env python3
"""Verify the single-copy font packaging contract on a built Floe app.

The App stages each bundled CJK/utility family once into the engine-scanned
``program/resource/common/fonts`` directory (scripts/embed_office_host.py) and
prunes the identical binaries from the packaged ``Bundled/`` folder, which
keeps only the per-family licence/provenance files. Both the native Office
engine and the App's CoreText registrar read that one directory.

Exit status is non-zero when any of these fails:

* a source font hash is missing from the engine-scanned directory;
* a source font hash still appears under ``Bundled/``;
* any audited font hash appears more than once across the two audited roots;
* a per-family licence file is missing or its bytes differ from the source;
* a font file is exposed through a symbolic link.

The audited duplicate set is the two large font roots that carried the same
23 curated files: ``Bundled/**`` and ``program/resource/common/fonts/**``.
Other App resources are reported as ``outsideAuditedRoots`` for visibility but
do not fail the default check. In particular,
``EngineeringViewers/MiSans-Regular.ttf`` is a third active consumer copy loaded
by EngineeringViewers/viewer.js:66 through its own local-preview-server root;
it is not one of the 23 duplicate pairs, and deleting it or widening WebKit
read access is out of scope.

``--require-global-unique`` is an optional diagnostic for a hypothetical future
state with no consumer copies. Do not use it as the release gate: it would
misclassify the necessary DXF font copy as a failure.

This is an artifact check only; it cannot prove CoreText registration or
Office CJK rendering. Those remain device/App acceptance evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

FONT_EXTENSIONS = {'.ttf', '.otf', '.ttc', '.otc'}
AUDITED_ROOTS = ('Bundled', 'program/resource/common/fonts')
LICENSE_NAME = 'LICENSE.txt'
SCRIPT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = SCRIPT_ROOT / 'FloeApp/Resources/Fonts/Bundled'


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def font_files(root: Path) -> list[Path]:
    if not root.is_dir():
        return []
    return sorted(
        path for path in root.rglob('*')
        if path.suffix.lower() in FONT_EXTENSIONS and path.is_file()
    )


def expected_fonts(source: Path) -> dict[str, dict]:
    expected: dict[str, dict] = {}
    for path in font_files(source):
        digest = sha256_file(path)
        family = path.parent.name
        entry = expected.setdefault(digest, {
            'sha256': digest,
            'bytes': path.stat().st_size,
            'families': [],
            'sourceNames': [],
            'licenseFiles': {},
        })
        entry['families'].append(family)
        entry['sourceNames'].append(f"{family}/{path.name}")
        license_path = source / family / LICENSE_NAME
        if license_path.is_file():
            entry['licenseFiles'][family] = license_path
    return expected


def audit(app: Path, source: Path, require_global_unique: bool) -> dict:
    if not app.is_dir():
        raise SystemExit(f'error: app bundle does not exist: {app}')
    if not source.is_dir():
        raise SystemExit(f'error: source font directory does not exist: {source}')

    expected = expected_fonts(source)
    if not expected:
        raise SystemExit(f'error: no staged source fonts under {source}')

    audited: dict[str, list[str]] = {}
    symlinked: list[str] = []
    for relative in AUDITED_ROOTS:
        root = app / relative
        for path in font_files(root):
            rel = path.relative_to(app).as_posix()
            if path.is_symlink():
                symlinked.append(rel)
                continue
            audited.setdefault(sha256_file(path), []).append(rel)

    outside: dict[str, list[str]] = {}
    audited_paths = set(path for paths in audited.values() for path in paths)
    expected_sizes = {entry['bytes'] for entry in expected.values()}
    for path in font_files(app):
        rel = path.relative_to(app).as_posix()
        if rel in audited_paths or path.is_symlink():
            continue
        if path.stat().st_size not in expected_sizes:
            continue
        digest = sha256_file(path)
        if digest in expected:
            outside.setdefault(digest, []).append(rel)

    problems: list[str] = []
    bundled_prefix = 'Bundled/'
    for digest, entry in expected.items():
        occurrences = audited.get(digest, [])
        if not occurrences:
            problems.append('missing from the built app: ' + ', '.join(entry['sourceNames']))
            continue
        if len(occurrences) > 1:
            problems.append('duplicate font bytes: ' + ', '.join(occurrences))
        if any(path.startswith(bundled_prefix) for path in occurrences):
            problems.append('font binary still packaged under Bundled/: '
                            + ', '.join(p for p in occurrences if p.startswith(bundled_prefix)))
        if len(occurrences) != 1:
            continue
        if require_global_unique and digest in outside:
            problems.append('font bytes also shipped outside the audited roots: '
                            + ', '.join(outside[digest]))

    license_checks: list[dict] = []
    for digest, entry in expected.items():
        for family, license_path in entry['licenseFiles'].items():
            built = app / 'Bundled' / family / LICENSE_NAME
            same = built.is_file() and built.read_bytes() == license_path.read_bytes()
            license_checks.append({
                'family': family,
                'path': built.relative_to(app).as_posix(),
                'present': built.is_file(),
                'matchesSource': same,
            })
            if not built.is_file():
                problems.append(f'missing font licence: Bundled/{family}/{LICENSE_NAME}')
            elif not same:
                problems.append(f'font licence differs from source: Bundled/{family}/{LICENSE_NAME}')

    if symlinked:
        problems.append('symlinked font files are not allowed: ' + ', '.join(sorted(symlinked)))

    report = {
        'app': str(app),
        'source': str(source),
        'expectedFontHashes': len(expected),
        'auditedRoots': list(AUDITED_ROOTS),
        'auditedFontFiles': sum(len(paths) for paths in audited.values()),
        'engineFontFiles': sum(1 for paths in audited.values()
                               for path in paths if path.startswith('program/')),
        'bundledFontFiles': sum(1 for paths in audited.values()
                                for path in paths if path.startswith(bundled_prefix)),
        'duplicates': {digest: paths for digest, paths in audited.items() if len(paths) > 1},
        'outsideAuditedRoots': outside,
        'extraAuditedFontFiles': sorted(
            path for digest, paths in audited.items() if digest not in expected for path in paths
        ),
        'licenses': license_checks,
        'problems': problems,
        'pass': not problems,
    }
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description='Verify the built App font single-copy contract')
    parser.add_argument('--app', required=True, help='path to the built Floe Agent.app')
    parser.add_argument('--source', default=str(DEFAULT_SOURCE),
                        help='staged source font directory (default: FloeAgent/FloeApp/Resources/Fonts/Bundled)')
    parser.add_argument('--json', help='write the full report as JSON')
    parser.add_argument('--require-global-unique', action='store_true',
                        help='optional diagnostic only: reject an audited font hash shipped in another App resource; do not use for release acceptance while the DXF viewer copy is active')
    args = parser.parse_args(argv)

    report = audit(Path(args.app), Path(args.source), args.require_global_unique)
    if args.json:
        Path(args.json).write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: report[k] for k in (
        'expectedFontHashes', 'auditedFontFiles', 'engineFontFiles', 'bundledFontFiles',
        'outsideAuditedRoots', 'pass', 'problems')}, indent=2))
    return 0 if report['pass'] else 1


if __name__ == '__main__':
    sys.exit(main())
