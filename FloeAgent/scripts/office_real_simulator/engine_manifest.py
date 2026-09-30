#!/usr/bin/env python3
"""Portable handling of the engine's ``ios-all-static-libs.list``.

The pinned upstream generator (``engine/bin/lo-all-static-libs``, invoked by
``engine/ios/CustomTarget_iOS_setup.mk``) emits one path per line -- normally
*absolute* paths under the build runner's root (``$WORKDIR``/``$INSTDIR``) and
also individual ``.o`` files (e.g. NSS builtins/freebl objects are not inside
any ``.a``).  ``ios/Mobile.xcodeproj`` consumes the file directly as
``-filelist``, so its contents must name files that exist on the machine doing
the Xcode link.

Runner-absolute paths are not portable.  This module keeps the linkage honest
without touching compiled inputs:

* ``canonicalize`` maps raw entries (absolute-under-build-root, engine-relative
  or already canonical) to build-root-relative ``source/...`` paths, rejecting
  missing files, paths outside the build root, unsupported suffixes and an
  empty list;
* ``rewrite_for_destination`` rewrites a raw or canonical list to paths under
  the destination root.  When the packaged 1:1 ``linkerInputs`` order is
  available it is used (the packager builds it from the same file, in order);
  otherwise entries are resolved relative to the destination and anything still
  unresolved is reported so a caller can fail closed.
"""
from pathlib import Path

ENGINE_LIST_RELATIVE = 'source/engine/workdir/CustomTarget/ios/ios-all-static-libs.list'
ACCEPTED_SUFFIXES = ('.a', '.o')


class ManifestError(ValueError):
    pass


def parse_lines(data):
    if isinstance(data, bytes):
        data = data.decode('utf-8', errors='replace')
    return [line.strip() for line in data.splitlines() if line.strip()]


def render(lines):
    return ('\n'.join(lines) + '\n').encode()


def _candidates(root, line):
    path = Path(line)
    if path.is_absolute():
        return [path]
    candidates = [root / 'source' / 'engine' / path]
    if path.parts and path.parts[0] == 'source':
        candidates.insert(0, root / path)
    return candidates


def canonicalize(build_root, lines):
    """Return build-root-relative ``source/...`` entries for a raw list."""
    root = Path(build_root).resolve()
    canonical = []
    failures = []
    for line in lines:
        resolved = None
        for candidate in _candidates(root, line):
            try:
                resolved = candidate.resolve(strict=True)
                break
            except (FileNotFoundError, NotADirectoryError, OSError):
                continue
        if resolved is None:
            failures.append(f'missing engine manifest entry: {line}')
            continue
        if not resolved.is_relative_to(root):
            failures.append(f'engine manifest entry escapes the build root: {line}')
            continue
        if resolved.suffix not in ACCEPTED_SUFFIXES:
            failures.append(f'unsupported engine manifest input: {line}')
            continue
        canonical.append(str(resolved.relative_to(root)))
    if failures:
        raise ManifestError('; '.join(failures[:5]))
    if not canonical:
        raise ManifestError('engine archive manifest is empty')
    return canonical


def rewrite_for_destination(destination, raw, linker_inputs=None):
    """Rewrite a raw/canonical list to destination-absolute entries.

    Returns ``(rendered_bytes, evidence)``.  ``linker_inputs`` are the
    package manifest's build-root-relative inputs in the same order as the
    raw list; when their count matches, that pairing is authoritative even if
    the old runner root no longer exists.
    """
    destination = Path(destination).resolve()
    lines = parse_lines(raw)
    evidence = {
        'originalLineCount': len(lines),
        'pairingUsed': False,
        'unresolved': [],
    }
    if not lines:
        raise ManifestError('engine archive manifest is empty')
    if linker_inputs and len(linker_inputs) == len(lines):
        rewritten = []
        for entry in linker_inputs:
            resolved = (destination / entry).resolve()
            if not resolved.is_relative_to(destination) or \
                    resolved.suffix not in ACCEPTED_SUFFIXES:
                raise ManifestError(
                    f'packaged linker input is not a portable engine input: {entry}')
            rewritten.append(str(resolved))
        evidence['pairingUsed'] = True
    else:
        rewritten = []
        for line in lines:
            path = Path(line)
            if path.is_absolute() and path.resolve().is_relative_to(destination):
                rewritten.append(str(path.resolve()))
                continue
            candidates = [destination / 'source' / 'engine' / path] \
                if not path.is_absolute() else []
            if path.parts and path.parts[0] == 'source':
                candidates.insert(0, destination / path)
            resolved = None
            for candidate in candidates:
                if candidate.resolve().is_relative_to(destination) and candidate.exists():
                    resolved = candidate.resolve()
                    break
            if resolved is None:
                evidence['unresolved'].append(line)
                rewritten.append(line)
            else:
                rewritten.append(str(resolved))
    if evidence['unresolved']:
        raise ManifestError(
            'cannot make engine manifest portable; unresolved entries: '
            + '; '.join(evidence['unresolved'][:5]))
    evidence['rewrittenLineCount'] = len(rewritten)
    return render(rewritten), evidence
