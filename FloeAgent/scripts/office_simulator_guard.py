#!/usr/bin/env python3
"""Fail closed when the App's Office editor escapes the host import guard.

`FloeOfficeNative` is linked into iphoneos builds only. The App's simulator
target compiles `OfficeDocumentEditorView.swift` with
`canImport(FloeOfficeNative)` false, so any reference to a host type outside
that guard is a hard compile error in the exact CI step that builds the App
regression host (`ci.yml`, build-test -> "Build App regression host once").
The rebuilt presentation host added `hostSupportsVisibleRender(_:)` and
`startRenderWatchdog(for:)` outside that guard: the device path stayed correct
while the simulator target stopped compiling.

Two contracts are pinned here, statically:

* every host-typed reference in the App sources stays inside
  `#if canImport(FloeOfficeNative)`;
* the real-device visible-render gate stays *inside* that guard and unweakened:
  the runtime selectors are still installed, the render watchdog is still armed
  for a presentation, and `.openOnly` is only ever chosen for an older host
  that cannot report a painted surface.

These checks are source contracts; they never claim engine or device render
success. Engine and device qualification stay separate gates.
"""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
EDITOR = ROOT / 'FloeApp/Workspace/OfficeDocumentEditorView.swift'
APP_SOURCE_ROOTS = (ROOT / 'FloeApp', ROOT / 'Sources')
# Vendor/ThirdParty hold vendored code and .build holds resolved checkouts;
# neither is App-target source. `Tests` is a separate target with its own
# device-only skip paths and is deliberately out of this scan.
SKIP_PARTS = {'Vendor', 'ThirdParty', '.build'}

GUARD_IMPORT = 'canImport(FloeOfficeNative)'
HOST_SYMBOL = re.compile(r'\bFloeOfficeNative[A-Za-z0-9_]*\b')

# `cancel…` helpers restructure app-owned state only; the unguarded close path
# calls them, so they must stay outside the guard.
GUARDED_DECLARATIONS = (
    'startOpenWatchdog',
    'hostSupportsVisibleRender',
    'startRenderWatchdog',
)
UNGUARDED_DECLARATIONS = ('cancelOpenWatchdog', 'cancelRenderWatchdog')

# Device-only arming that must stay inside the import guard: without the pinned
# host there is no controller to probe and no runtime selector to install.
ARMING_SNIPPETS = (
    'hostSupportsVisibleRender = Self.hostSupportsVisibleRender(native)',
    'OfficeRenderRequirement.forDocument(',
    'setOnVisibleRenderReady:',
    'setOnVisibleRenderFailed:',
    'startRenderWatchdog(for: native)',
)

DECLARATION = re.compile(r'private\s+(?:static\s+)?func\s+([A-Za-z0-9_]+)\s*\(')


def strip_comments(line, in_block_comment=False):
    """Return (code, in_block_comment) with comments removed, strings kept."""
    out = []
    index = 0
    in_string = False
    while index < len(line):
        character = line[index]
        if in_block_comment:
            if character == '*' and line[index + 1:index + 2] == '/':
                in_block_comment = False
                index += 2
                continue
            index += 1
            continue
        if in_string:
            out.append(character)
            if character == '\\':
                if index + 1 < len(line):
                    out.append(line[index + 1])
                index += 2
                continue
            if character == '"':
                in_string = False
            index += 1
            continue
        if character == '"':
            in_string = True
            out.append(character)
            index += 1
            continue
        if character == '/' and line[index + 1:index + 2] == '/':
            break
        if character == '/' and line[index + 1:index + 2] == '*':
            in_block_comment = True
            index += 2
            continue
        out.append(character)
        index += 1
    return ''.join(out), in_block_comment


def line_states(text):
    """Yield (line number, code, guard depth). Directives are not code.

    A `#else` branch of a `canImport(FloeOfficeNative)` guard is *not* guarded:
    that branch compiles exactly when the framework is absent.
    """
    stack = []
    in_block_comment = False
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        depth = sum(1 for guarded in stack if guarded)
        if stripped.startswith('#if'):
            stack.append(GUARD_IMPORT in stripped)
            continue
        if stripped.startswith('#elseif'):
            if stack:
                stack[-1] = GUARD_IMPORT in stripped
            continue
        if stripped.startswith('#else'):
            if stack:
                stack[-1] = False
            continue
        if stripped.startswith('#endif'):
            if stack:
                stack.pop()
            continue
        code, in_block_comment = strip_comments(line, in_block_comment)
        yield number, code, depth


def unguarded_host_references(text, label='<source>'):
    """Every host-typed reference that the simulator target would compile.

    Comments are ignored; a match inside a string literal is still reported,
    because naming the device-only host in App text has no legitimate use and a
    conservative scan is cheaper to trust than a clever one.
    """
    violations = []
    for number, code, depth in line_states(text):
        if depth:
            continue
        for match in HOST_SYMBOL.finditer(code):
            violations.append(f'{label}:{number}: {match.group(0)} outside '
                              f'#if {GUARD_IMPORT}')
    return violations


def app_sources():
    for base in APP_SOURCE_ROOTS:
        if not base.is_dir():
            continue
        for path in sorted(base.rglob('*.swift')):
            if any(part in SKIP_PARTS for part in path.parts) or not path.is_file():
                continue
            yield path


def declaration_guard_state(text):
    """Map each private func declaration to the guard depth at its line."""
    states = {}
    for number, code, depth in line_states(text):
        match = DECLARATION.search(code)
        if match:
            states.setdefault(match.group(1), (number, depth))
    return states


def check():
    """Assert the conditional-compilation boundary; return an honest receipt."""
    violations = []
    scanned = 0
    for path in app_sources():
        scanned += 1
        violations.extend(unguarded_host_references(path.read_text(encoding='utf-8'),
                                                   str(path.relative_to(ROOT))))
    if violations:
        raise AssertionError(
            'host-typed references compile for the simulator target:\n  '
            + '\n  '.join(violations))

    editor = EDITOR.read_text(encoding='utf-8')
    states = declaration_guard_state(editor)
    for name in GUARDED_DECLARATIONS:
        state = states.get(name)
        if state is None or state[1] == 0:
            raise AssertionError(f'{name}(…) is missing or outside #if {GUARD_IMPORT}')
    for name in UNGUARDED_DECLARATIONS:
        state = states.get(name)
        if state is None or state[1] != 0:
            raise AssertionError(
                f'{name}(…) must stay outside #if {GUARD_IMPORT}: the close path calls it '
                'when the framework is absent')

    # The device gate is armed inside the guard, from the runtime capability
    # probe, and a presentation keeps requiring a painted surface on the pinned
    # host. Only an older host that can never report that signal downgrades.
    arming = {}
    for _, code, depth in line_states(editor):
        for snippet in ARMING_SNIPPETS:
            if snippet in code and snippet not in arming:
                arming[snippet] = depth
    for snippet in ARMING_SNIPPETS:
        depth = arming.get(snippet)
        if depth is None:
            raise AssertionError(f'visible-render arming is missing: {snippet}')
        if depth == 0:
            raise AssertionError(f'visible-render arming escaped #if {GUARD_IMPORT}: {snippet}')
    if 'if requirement == .visibleRenderRequired, !hostSupportsVisibleRender {' not in editor:
        raise AssertionError('the .openOnly downgrade is no longer conditioned on an old host')
    if editor.count('requirement = .openOnly') != 1:
        raise AssertionError('the .openOnly downgrade must exist exactly once, conditioned on an old host')

    return {
        'simulatorGuardPassed': True,
        'appSourcesScanned': scanned,
        'guardedHostDeclarations': list(GUARDED_DECLARATIONS),
        'unguardedStateHelpers': list(UNGUARDED_DECLARATIONS),
        'visibleRenderGateArmedInGuard': True,
        'engineVisibleRenderPassed': False,
        'deviceVisibleRenderPassed': False,
    }


if __name__ == '__main__':
    print(json.dumps(check(), indent=2))
