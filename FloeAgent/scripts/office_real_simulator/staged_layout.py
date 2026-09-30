#!/usr/bin/env python3
"""Resolve and validate the staged-engine artifact layout.

``gh run download RUN -n office-real-simulator-engine -D <staged>`` extracts
the artifact's *contents* directly into ``<staged>`` -- it does NOT create a
directory named after the artifact.  The previous workflow looked under
``<staged>/office-real-sim-engine-bundle/`` and could never find the tarball.
This module is the single place that knows the real layout, so the build and
runtime jobs cannot drift apart again.

Required entries (flat, directly under the staged directory):
  office-engine-iphonesimulator-arm64.tar.gz   heavy engine package
  simulator-provenance.json                    build-stage provenance record

Locating is strict: missing required files raise with the actual directory
listing so a failed download/upload surfaces exactly.  A legacy nested
``office-real-sim-engine-bundle/`` directory is reported explicitly (never
silently accepted) because accepting it again would hide a recurrence.
"""
import argparse
import json
from pathlib import Path
import sys

from sim_paths import (STAGED_ENGINE_TAR, STAGED_PROVENANCE,
                       STAGED_QUALIFICATION)

REQUIRED = (STAGED_ENGINE_TAR, STAGED_PROVENANCE)
OPTIONAL = (STAGED_QUALIFICATION,)
LEGACY_NESTED_DIR = 'office-real-sim-engine-bundle'


class StagedLayoutError(ValueError):
    pass


def _listing(directory):
    try:
        names = sorted(entry.name for entry in Path(directory).iterdir())
    except OSError as error:
        return f'<unreadable: {error}>'
    if not names:
        return '<empty>'
    shown = names[:25]
    suffix = '' if len(names) == len(shown) else f' ... (+{len(names) - len(shown)})'
    return ', '.join(shown) + suffix


def resolve(staged_dir):
    """Return the resolved staged-engine paths, or raise StagedLayoutError."""
    staged = Path(staged_dir).resolve()
    if not staged.is_dir():
        raise StagedLayoutError(f'staged directory does not exist: {staged}')

    missing = [name for name in REQUIRED if not (staged / name).is_file()]
    nested = staged / LEGACY_NESTED_DIR
    if missing and nested.is_dir():
        found = [name for name in REQUIRED if (nested / name).is_file()]
        if found:
            raise StagedLayoutError(
                'artifact layout mismatch: files are nested under '
                f'{LEGACY_NESTED_DIR}/ but the download must extract flat into '
                f'{staged}; found nested: {", ".join(found)}. Fix the download '
                'or the workflow paths, do not accept both layouts.')
    if missing:
        raise StagedLayoutError(
            f'staged artifact is missing {", ".join(missing)}; '
            f'present under {staged}: {_listing(staged)}')
    # A stale nested directory is recorded (not silently accepted or removed)
    # so a recurrence of the old layout is visible in the artifact evidence.

    facts = {
        'stagedDir': str(staged),
        'layout': 'flat-artifact-contents',
        'engineTarball': str(staged / STAGED_ENGINE_TAR),
        'provenance': str(staged / STAGED_PROVENANCE),
        'engineTarballSize': (staged / STAGED_ENGINE_TAR).stat().st_size,
        'nestedLegacyDirectoryPresent': nested.is_dir(),
        'required': list(REQUIRED),
    }
    for name in OPTIONAL:
        path = staged / name
        if path.is_file():
            facts[name] = str(path)
    return facts


GITHUB_OUTPUT_KEYS = ('stagedDir', 'layout', 'engineTarball', 'provenance',
                      'engineTarballSize')


def _write_github_output(path, facts):
    lines = []
    for key in GITHUB_OUTPUT_KEYS:
        value = facts.get(key)
        if isinstance(value, (str, int, bool)):
            lines.append(f'{key}={value}')
    Path(path).write_text('\n'.join(lines) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('staged_dir', help='Directory given to gh run download -D')
    parser.add_argument('--json', default=None, help='Write the layout receipt here')
    parser.add_argument('--github-output', default=None,
                        help='Append key=value lines for GitHub Actions outputs')
    args = parser.parse_args()
    try:
        facts = resolve(args.staged_dir)
    except StagedLayoutError as error:
        print(f'STAGED LAYOUT ERROR: {error}', file=sys.stderr)
        raise SystemExit(1)
    if args.json:
        Path(args.json).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json).write_text(json.dumps(facts, indent=2) + '\n')
    if args.github_output:
        _write_github_output(args.github_output, facts)
    print(json.dumps(facts, indent=2))


if __name__ == '__main__':
    main()
