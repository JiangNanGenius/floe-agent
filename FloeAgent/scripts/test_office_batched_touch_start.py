#!/usr/bin/env python3
"""Execute the pinned CanvasSectionContainer touch state machine with and
without the reviewed simultaneous-two-touch-start patch.

The test never edits the shared Office source checkout.  It reads the pinned
blob from git, applies ``patches/ios-batched-touch-start.patch`` to a temporary
single-file fixture, verifies the locked source hashes, and extracts the real
touch methods from both the original and patched blobs into a small Node
harness with faithful section/event/propagation stubs.

This is a source-level behavioral check.  It is not Simulator, engine, App or
physical-device acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PATCH = ROOT / 'ThirdParty/Collabora/patches/ios-batched-touch-start.patch'
DEFAULT_LOCK = ROOT / 'ThirdParty/Collabora/browser.patch.lock.json'
SOURCE_FILE = 'browser/src/canvas/CanvasSectionContainer.ts'
METHODS = (
    'onTouchStart', 'onTouchMove', 'onTouchEnd', 'onTouchCancel',
    'clearMousePositions', 'convertPositionToSectionLocale',
    'convertPositionToCanvasLocale', 'convertPointToCanvasLocale',
    'findSectionContainingPoint', 'doesSectionIncludePoint',
    'getSectionWithName',
)
PATCHED_CHECKS = [
    'simultaneous two-touch start initializes start and first-touch target',
    'simultaneous two-touch move reaches the existing multi-touch propagation',
    'sequential one-then-two keeps the first touch target and start',
    'single-finger start, move and end still use the mouse path',
    'batched pinch end waits for the last finger and resets multi-touch',
    'batched pinch cancel resets state and the next single touch works',
    'batched birth does not borrow a target from the second touch or center',
    'consecutive batched gestures re-target from the new first touch',
    'batched gesture after a single-touch gesture discards the stale target',
    'cancel then an immediate batched gesture seeds fresh state',
]
ORIGINAL_CHECK = (
    'pinned original drops simultaneous two-touch start before any move propagation'
)


class CheckError(RuntimeError):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise CheckError(message)


def run(command, cwd=None, timeout=90, env=None):
    result = subprocess.run(
        [str(item) for item in command], cwd=cwd, text=True,
        capture_output=True, timeout=timeout, env=env)
    return result


def resolve_source(explicit):
    candidates = []
    if explicit:
        candidates.append(Path(explicit))
    configured = os.environ.get('FLOE_OFFICE_SOURCE')
    if configured:
        candidates.append(Path(configured))
    repo_root = ROOT.parent
    worktree_ancestor = repo_root.parents[2] if len(repo_root.parents) > 2 else repo_root
    candidates.extend([
        repo_root / 'Local/Scratch/office-linux-closure-A2/source',
        worktree_ancestor / 'Local/Scratch/office-linux-closure-A2/source',
    ])
    for candidate in candidates:
        candidate = candidate.resolve()
        if (candidate / '.git').exists() and (candidate / SOURCE_FILE).is_file():
            return candidate
    raise CheckError(
        'pinned Office source checkout not found; pass --source <source root> '
        'or set FLOE_OFFICE_SOURCE')


def load_contract(lock_path, patch_path):
    require(lock_path.is_file(), f'missing lock file: {lock_path}')
    require(patch_path.is_file() and not patch_path.is_symlink(),
            f'missing patch file: {patch_path}')
    lock = json.loads(lock_path.read_text())
    require(lock.get('formatVersion') == 1,
            'browser.patch.lock.json formatVersion is not 1')
    engine = lock.get('engine') or {}
    entries = lock.get('browserSourcePatches')
    require(isinstance(entries, list) and bool(entries),
            'browser.patch.lock.json must carry browserSourcePatches entries')
    resolved_patch = patch_path.resolve()
    entry = next(
        (candidate for candidate in entries
         if (lock_path.parent / candidate.get('patch', '')).resolve() == resolved_patch),
        None)
    require(entry is not None,
            'browserSourcePatches does not name the tracked batched-touch patch')
    require(digest(patch_path.read_bytes()) == entry.get('patchSHA256'),
            'tracked patch SHA-256 differs from the lock entry')
    require(entry.get('sourceFile') == SOURCE_FILE,
            'lock sourceFile differs from the patched source path')
    require(entry.get('sourceCommit') == engine.get('commit'),
            'browser patch sourceCommit differs from the pinned engine commit')
    require(entry.get('sourceRepository') == engine.get('repository'),
            'browser patch repository differs from the pinned engine repository')
    for key in ('originalSourceSHA256', 'patchedSourceSHA256', 'patchSHA256'):
        value = entry.get(key)
        require(isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value),
                f'lock entry {key} is not a lowercase SHA-256')
    return lock, entry


def pinned_blob(source_root, commit, relative):
    result = run(['git', '-C', source_root, 'show', f'{commit}:{relative}'])
    require(result.returncode == 0,
            f'cannot read pinned blob {commit}:{relative}: {result.stderr.strip()}')
    return result.stdout.encode()


def apply_to_fixture(fixture, patch_path, original):
    target = fixture / SOURCE_FILE
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(original)
    for extra in (['--check'], []):
        result = run(['git', 'apply', *extra, patch_path], cwd=fixture)
        require(result.returncode == 0,
                f'git apply {" ".join(extra)} failed: {result.stderr.strip()}')
    patched = target.read_bytes()
    reverse = run(['git', 'apply', '--check', '--reverse', patch_path], cwd=fixture)
    require(reverse.returncode == 0,
            f'git apply --reverse --check failed: {reverse.stderr.strip()}')
    return patched


def extract_method(text, name):
    match = re.search(
        r'^\t(?:public|private)\s+' + re.escape(name) + r'\s*\(', text, re.M)
    require(match is not None, f'{name} not found in the pinned source')
    index = text.index('{', match.end())
    depth = 0
    position = index
    quote = None
    while position < len(text):
        char = text[position]
        if quote:
            if char == '\\':
                position += 2
                continue
            if char == quote:
                quote = None
        elif char in ('"', "'", '`'):
            quote = char
        elif char == '/' and position + 1 < len(text) and text[position + 1] == '/':
            newline = text.find('\n', position)
            position = len(text) if newline < 0 else newline
            continue
        elif char == '/' and position + 1 < len(text) and text[position + 1] == '*':
            end = text.find('*/', position + 2)
            require(end >= 0, f'unterminated comment while extracting {name}')
            position = end + 1
        elif char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                return text[match.start():position + 1]
        position += 1
    raise CheckError(f'unterminated method while extracting {name}')


def extract_methods(source):
    text = source.decode('utf-8')
    body = '\n\n'.join(extract_method(text, name) for name in METHODS)
    # Type assertions have no runtime meaning.  Node's type stripping does not
    # accept the angle-bracket form used by this pinned file, so erase exactly
    # those assertions before executing the extracted methods.
    body = body.replace('(<MouseEvent><any>e)', '(e as any)')
    body = body.replace('<MouseEvent><any>e', 'e as any')
    require('<any>' not in body, 'angle-bracket type assertion survived extraction')
    return body


HARNESS_HEADER = r'''const assert = require('node:assert/strict');
const app = { dpiScale: 2, idleHandler: { notifyActive() {} } };

class CanvasSectionContainer {
	positionOnMouseDown: any = null;
	positionOnMouseUp: any = null;
	positionOnClick: any = null;
	positionOnDoubleClick: any = null;
	mousePosition: any = null;
	dragDistance: any = null;
	draggingSomething: boolean = false;
	sectionOnMouseDown: any = null;
	sectionUnderMouse: any = null;
	multiTouch: boolean = false;
	touchCenter: any = null;
	longPressTimer: any = null;
	touchEventInProgress: boolean = false;
	lowestPropagatedBoundSection: any = null;
	targetSection: any = null;
	windowSectionList: any[] = [];
	sections: any[];
	sectionsByName: Map<string, any>;
	canvas: any;
	calls: any[] = [];
	constructor(sections: any[], canvas: any) {
		this.sections = sections;
		this.sectionsByName = new Map(sections.map((s: any) => [s.name, s]));
		this.canvas = canvas;
	}
	startLongPress(e: any) { this.calls.push({ name: 'startLongPress' }); }
	stopLongPress() { this.calls.push({ name: 'stopLongPress' }); }
	propagateOnMouseDown(s: any, p: any, e: any) { this.calls.push({ name: 'mouseDown', section: s.name, position: p.slice() }); }
	propagateOnMouseMove(s: any, p: any, d: any, e: any) { this.calls.push({ name: 'mouseMove', section: s.name, position: p.slice(), dragDistance: d.slice() }); }
	propagateOnMouseUp(s: any, p: any, e: any) { this.calls.push({ name: 'mouseUp', section: s.name, position: p.slice() }); }
	propagateOnMultiTouchStart(s: any, e: any) { this.calls.push({ name: 'multiStart', section: s.name, event: e }); }
	propagateOnMultiTouchMove(s: any, p: any, d: any, e: any) { this.calls.push({ name: 'multiMove', section: s.name, position: p.slice(), distance: d, event: e }); }
	propagateOnMultiTouchEnd(s: any, e: any) { this.calls.push({ name: 'multiEnd', section: s.name, event: e }); }
'''

HARNESS_COMMON = r'''}

function section(name: string, left: number, top: number, width: number, height: number) {
	return {
		name, myTopLeft: [left, top], size: [width, height], interactable: true,
		isLocated: true, windowSection: false, showSection: true, documentObject: null,
		isHit(point: number[]) { return point[0] >= left && point[0] <= left + width && point[1] >= top && point[1] <= top + height; },
	};
}
function ev(points: number[][], changed = points) {
	const touchList = (list: number[][]) => list.map(([x, y], i) => ({ clientX: x, clientY: y, identifier: i }));
	return { touches: touchList(points), changedTouches: touchList(changed) };
}
function takeCalls(c: any) { const calls = c.calls.slice(); c.calls.length = 0; return calls; }
function names(calls: any[]) { return calls.map((call: any) => call.name); }
function close(actual: number, expected: number) { assert.ok(Math.abs(actual - expected) < 1e-9, `${actual} != ${expected}`); }

const canvas = { getBoundingClientRect() { return { left: 0, top: 0, right: 1133, bottom: 640 }; } };
const checks: string[] = [];
function scenario(name: string, fn: () => void) { fn(); checks.push(name); }
'''

ORIGINAL_BODY = r'''
// The probe's first q.mt=0 is a pre-handler snapshot. After onTouchStart the
// pinned branch sets multiTouch=true but leaves the start and section null;
// root's later move records show mt=1 and still no propagation.
const document = section('document', 0, 0, 2266, 1280);
const c: any = new CanvasSectionContainer([document], canvas);
c.onTouchStart(ev([[568, 302], [565, 307.5]]));
assert.equal(c.multiTouch, true);
assert.equal(c.positionOnMouseDown, null);
assert.equal(c.sectionOnMouseDown, null);
assert.deepEqual(names(takeCalls(c)), ['stopLongPress']);
c.onTouchMove(ev([[560, 300], [580, 320]]));
assert.deepEqual(names(takeCalls(c)), []);
console.log(JSON.stringify({ checks: ['pinned original drops simultaneous two-touch start before any move propagation'] }));
'''

PATCHED_BODY = r'''
scenario('simultaneous two-touch start initializes start and first-touch target', () => {
	const document = section('document', 0, 0, 2266, 1280);
	const c: any = new CanvasSectionContainer([document], canvas);
	const start = ev([[568, 302], [565, 307.5]]);
	c.onTouchStart(start);
	assert.equal(c.multiTouch, true);
	assert.deepEqual(c.positionOnMouseDown, [1136, 604]);
	assert.equal(c.sectionOnMouseDown, 'document');
	const calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress', 'multiStart']);
	assert.equal(calls[1].section, 'document');
	assert.strictEqual(calls[1].event, start);
});

scenario('simultaneous two-touch move reaches the existing multi-touch propagation', () => {
	const document = section('document', 0, 0, 2266, 1280);
	const c: any = new CanvasSectionContainer([document], canvas);
	c.onTouchStart(ev([[568, 302], [565, 307.5]]));
	takeCalls(c);
	const move = ev([[560, 300], [580, 320]]);
	c.onTouchMove(move);
	const calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress', 'multiMove']);
	assert.equal(calls[1].section, 'document');
	assert.deepEqual(calls[1].position, [1140, 620]);
	close(calls[1].distance, Math.sqrt(800));
	assert.strictEqual(calls[1].event, move);
	assert.deepEqual(c.touchCenter, [1140, 620]);
	assert.equal(c.draggingSomething, false);
	assert.equal(c.mousePosition, null);
});

scenario('sequential one-then-two keeps the first touch target and start', () => {
	const document = section('document', 0, 0, 2266, 1280);
	const toolbar = section('toolbar', 0, 0, 400, 200);
	const c: any = new CanvasSectionContainer([document, toolbar], canvas);
	c.onTouchStart(ev([[90, 80]]));
	assert.equal(c.multiTouch, false);
	assert.deepEqual(c.positionOnMouseDown, [180, 160]);
	assert.equal(c.sectionOnMouseDown, 'toolbar');
	let calls = takeCalls(c);
	assert.deepEqual(names(calls), ['startLongPress', 'mouseDown']);
	assert.equal(calls[1].section, 'toolbar');

	c.onTouchMove(ev([[100, 90]]));
	calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress', 'mouseMove']);
	assert.equal(calls[1].section, 'toolbar');
	assert.deepEqual(calls[1].dragDistance, [20, 20]);

	assert.equal(c.touchEventInProgress, false);
	c.onTouchStart(ev([[100, 90], [700, 400]]));
	assert.equal(c.multiTouch, true);
	assert.deepEqual(c.positionOnMouseDown, [180, 160]);
	assert.equal(c.sectionOnMouseDown, 'toolbar');
	calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress', 'multiStart']);
	assert.equal(calls[1].section, 'toolbar');

	c.onTouchMove(ev([[100, 90], [700, 400]]));
	calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress', 'multiMove']);
	assert.equal(calls[1].section, 'toolbar');
	assert.deepEqual(calls[1].position, [800, 490]);
	close(calls[1].distance, Math.sqrt(600 * 600 + 310 * 310));

	c.onTouchEnd(ev([], [[100, 90], [700, 400]]));
	calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress', 'multiEnd']);
	assert.equal(calls[1].section, 'toolbar');
	assert.equal(c.multiTouch, false);

	c.onTouchStart(ev([[90, 80]]));
	assert.equal(c.multiTouch, false);
	assert.deepEqual(c.positionOnMouseDown, [180, 160]);
	assert.equal(c.sectionOnMouseDown, 'toolbar');
});

scenario('single-finger start, move and end still use the mouse path', () => {
	const document = section('document', 0, 0, 2266, 1280);
	const c: any = new CanvasSectionContainer([document], canvas);
	c.onTouchStart(ev([[568, 302]]));
	assert.equal(c.multiTouch, false);
	assert.deepEqual(c.positionOnMouseDown, [1136, 604]);
	assert.equal(c.sectionOnMouseDown, 'document');
	let calls = takeCalls(c);
	assert.deepEqual(names(calls), ['startLongPress', 'mouseDown']);

	c.onTouchMove(ev([[570, 304]]));
	calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress', 'mouseMove']);
	assert.equal(calls[1].section, 'document');
	assert.deepEqual(calls[1].position, [1140, 608]);
	assert.deepEqual(calls[1].dragDistance, [4, 4]);
	assert.equal(c.draggingSomething, true);

	c.onTouchEnd(ev([], [[570, 304]]));
	calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress', 'mouseUp']);
	assert.equal(calls[1].section, 'document');
	assert.deepEqual(calls[1].position, [1140, 608]);
	assert.equal(c.multiTouch, false);
	assert.equal(c.touchEventInProgress, true);
});

scenario('batched pinch end waits for the last finger and resets multi-touch', () => {
	const document = section('document', 0, 0, 2266, 1280);
	const c: any = new CanvasSectionContainer([document], canvas);
	c.onTouchStart(ev([[568, 302], [565, 307.5]]));
	c.onTouchMove(ev([[560, 300], [580, 320]]));
	takeCalls(c);

	c.onTouchEnd(ev([[560, 300]], [[565, 307.5]]));
	let calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress']);
	assert.equal(c.multiTouch, true);

	c.onTouchEnd(ev([], [[560, 300]]));
	calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress', 'multiEnd']);
	assert.equal(calls[1].section, 'document');
	assert.equal(c.multiTouch, false);

	c.onTouchStart(ev([[90, 80]]));
	assert.equal(c.multiTouch, false);
	assert.deepEqual(c.positionOnMouseDown, [180, 160]);
});

scenario('batched pinch cancel resets state and the next single touch works', () => {
	const document = section('document', 0, 0, 2266, 1280);
	const c: any = new CanvasSectionContainer([document], canvas);
	c.onTouchStart(ev([[568, 302], [565, 307.5]]));
	c.onTouchMove(ev([[560, 300], [580, 320]]));
	takeCalls(c);

	c.onTouchCancel(ev([]));
	const calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress']);
	assert.equal(c.multiTouch, false);
	assert.equal(c.positionOnMouseDown, null);
	assert.equal(c.sectionOnMouseDown, null);
	assert.equal(c.touchCenter, null);
	assert.equal(c.draggingSomething, false);
	assert.equal(c.touchEventInProgress, false);

	c.onTouchStart(ev([[568, 302]]));
	takeCalls(c);
	c.onTouchMove(ev([[570, 304]]));
	const moveCalls = takeCalls(c);
	assert.deepEqual(names(moveCalls), ['stopLongPress', 'mouseMove']);
	assert.equal(c.multiTouch, false);
	assert.deepEqual(c.positionOnMouseDown, [1136, 604]);
});

scenario('batched birth does not borrow a target from the second touch or center', () => {
	const document = section('document', 0, 0, 2266, 1280);
	const toolbar = section('toolbar', 0, 0, 400, 200);
	const outside: any = new CanvasSectionContainer([document, toolbar], canvas);
	outside.onTouchStart(ev([[1500, 700], [800, 500]]));
	assert.equal(outside.multiTouch, true);
	assert.deepEqual(outside.positionOnMouseDown, [3000, 1400]);
	assert.equal(outside.sectionOnMouseDown, null);
	assert.deepEqual(names(takeCalls(outside)), ['stopLongPress']);
	outside.onTouchMove(ev([[1500, 700], [800, 500]]));
	assert.equal(takeCalls(outside).filter((call: any) => call.name === 'multiMove').length, 0);
	assert.equal(outside.sectionOnMouseDown, null);

	const toolbarFirst: any = new CanvasSectionContainer([document, toolbar], canvas);
	toolbarFirst.onTouchStart(ev([[90, 80], [800, 500]]));
	assert.equal(toolbarFirst.sectionOnMouseDown, 'toolbar');
	const targetCalls = takeCalls(toolbarFirst);
	assert.deepEqual(names(targetCalls), ['stopLongPress', 'multiStart']);
	assert.equal(targetCalls[1].section, 'toolbar');
});

scenario('consecutive batched gestures re-target from the new first touch', () => {
	const left = section('left', 0, 0, 1000, 1280);
	const right = section('right', 1200, 0, 1066, 1280);
	const c: any = new CanvasSectionContainer([left, right], canvas);
	c.onTouchStart(ev([[100, 200], [150, 250]]));
	assert.deepEqual(c.positionOnMouseDown, [200, 400]);
	assert.equal(c.sectionOnMouseDown, 'left');
	takeCalls(c);
	c.onTouchMove(ev([[700, 200], [750, 250]]));
	takeCalls(c);
	c.onTouchEnd(ev([], [[700, 200], [750, 250]]));
	takeCalls(c);
	assert.equal(c.multiTouch, false);
	assert.equal(c.touchEventInProgress, true);
	assert.deepEqual(c.positionOnMouseDown, [200, 400]);
	assert.equal(c.sectionOnMouseDown, 'left');

	c.onTouchStart(ev([[700, 200], [750, 250]]));
	assert.deepEqual(c.positionOnMouseDown, [1400, 400]);
	assert.equal(c.sectionOnMouseDown, 'right');
	assert.equal(c.touchEventInProgress, false);
	assert.equal(c.touchCenter, null);
	let calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress', 'multiStart']);
	assert.equal(calls[1].section, 'right');
	c.onTouchMove(ev([[700, 200], [750, 250]]));
	calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress', 'multiMove']);
	assert.equal(calls[1].section, 'right');
	assert.deepEqual(calls[1].position, [250, 450]);
	close(calls[1].distance, Math.sqrt(5000));
});

scenario('batched gesture after a single-touch gesture discards the stale target', () => {
	const left = section('left', 0, 0, 1000, 1280);
	const right = section('right', 1200, 0, 1066, 1280);
	const c: any = new CanvasSectionContainer([left, right], canvas);
	c.onTouchStart(ev([[100, 200]]));
	takeCalls(c);
	c.onTouchMove(ev([[700, 200]]));
	takeCalls(c);
	c.onTouchEnd(ev([], [[700, 200]]));
	takeCalls(c);
	assert.equal(c.multiTouch, false);
	assert.equal(c.touchEventInProgress, true);
	assert.deepEqual(c.positionOnMouseDown, [200, 400]);
	assert.equal(c.sectionOnMouseDown, 'left');

	c.onTouchStart(ev([[700, 200], [750, 250]]));
	assert.deepEqual(c.positionOnMouseDown, [1400, 400]);
	assert.equal(c.sectionOnMouseDown, 'right');
	assert.equal(c.touchEventInProgress, false);
	assert.equal(c.draggingSomething, false);
	assert.equal(c.touchCenter, null);
	const calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress', 'multiStart']);
	assert.equal(calls[1].section, 'right');
});

scenario('cancel then an immediate batched gesture seeds fresh state', () => {
	const document = section('document', 0, 0, 2266, 1280);
	const toolbar = section('toolbar', 0, 0, 400, 200);
	const c: any = new CanvasSectionContainer([document, toolbar], canvas);
	c.onTouchStart(ev([[568, 302], [565, 307.5]]));
	c.onTouchMove(ev([[560, 300], [580, 320]]));
	takeCalls(c);
	c.onTouchCancel(ev([]));
	assert.equal(c.multiTouch, false);
	assert.equal(c.positionOnMouseDown, null);
	assert.equal(c.sectionOnMouseDown, null);
	takeCalls(c);

	c.onTouchStart(ev([[90, 80], [150, 120]]));
	assert.deepEqual(c.positionOnMouseDown, [180, 160]);
	assert.equal(c.sectionOnMouseDown, 'toolbar');
	let calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress', 'multiStart']);
	assert.equal(calls[1].section, 'toolbar');
	c.onTouchMove(ev([[100, 90], [160, 130]]));
	calls = takeCalls(c);
	assert.deepEqual(names(calls), ['stopLongPress', 'multiMove']);
	assert.equal(calls[1].section, 'toolbar');
});

console.log(JSON.stringify({ checks }, null, 0));
'''


def run_harness(folder, methods, body, label):
    script = folder / f'{label}.ts'
    script.write_text(HARNESS_HEADER + methods + HARNESS_COMMON + body)
    environment = dict(os.environ)
    environment['NODE_NO_WARNINGS'] = '1'
    result = run(['node', '--experimental-strip-types', script], cwd=folder, timeout=90, env=environment)
    if result.returncode != 0:
        raise CheckError(
            f'{label} Node harness failed:\n{result.stdout}\n{result.stderr}')
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    require(bool(lines), f'{label} Node harness printed no result')
    return json.loads(lines[-1])['checks']


def check(source, patch, lock_path):
    patch = Path(patch).resolve()
    lock_path = Path(lock_path).resolve()
    lock, entry = load_contract(lock_path, patch)
    source_root = resolve_source(source)
    commit = lock['engine']['commit']
    original = pinned_blob(source_root, commit, SOURCE_FILE)

    checks = []
    require(digest(original) == entry['originalSourceSHA256'],
            'pinned source blob SHA-256 differs from the locked original')
    checks.append('pinned blob matches the locked original source SHA-256')

    patch_headers = re.findall(r'^(?:---|\+\+\+) ([^\t\n]+)', patch.read_text(), re.M)
    require(patch_headers == [f'a/{SOURCE_FILE}', f'b/{SOURCE_FILE}'],
            'patch must modify only the locked source file')
    checks.append('patch modifies only the locked source file')

    working = (source_root / SOURCE_FILE).read_bytes()
    if working == original:
        result = run(['git', '-C', source_root, 'apply', '--check', patch])
        require(result.returncode == 0,
                f'git apply --check on the pinned checkout failed: {result.stderr.strip()}')
        checks.append('pinned checkout accepts the patch with git apply --check')
    elif digest(working) == entry['patchedSourceSHA256']:
        result = run(['git', '-C', source_root, 'apply', '--check', '--reverse', patch])
        require(result.returncode == 0,
                'pinned checkout carries the patched source but does not reverse-apply cleanly')
        checks.append('pinned checkout already carries the exact patched source')
    else:
        raise CheckError(
            'pinned checkout is neither the locked original nor the patched source')

    with tempfile.TemporaryDirectory(prefix='floe-batched-touch-') as temporary:
        folder = Path(temporary)
        patched = apply_to_fixture(folder, patch, original)
        require(digest(patched) == entry['patchedSourceSHA256'],
                'patched fixture SHA-256 differs from the locked patched source')
        checks.append('patch applies cleanly and produces the locked patched source SHA-256')

        baseline = run_harness(folder, extract_methods(original), ORIGINAL_BODY, 'original')
        require(baseline == [ORIGINAL_CHECK],
                f'original-source baseline did not show the known failure: {baseline}')
        checks.append('original-source baseline reproduces the dropped two-touch start')

        executed = run_harness(folder, extract_methods(patched), PATCHED_BODY, 'patched')
        require(executed == PATCHED_CHECKS,
                f'patched behavioral checks differ: {executed}')
        checks.extend(executed)

    node_version = run(['node', '--version']).stdout.strip()
    return {
        'kind': 'pinned-source behavioral regression with extracted touch methods',
        'checksPassed': checks,
        'source': {
            'repository': lock['engine']['repository'],
            'commit': commit,
            'file': SOURCE_FILE,
            'originalSHA256': entry['originalSourceSHA256'],
            'patchedSHA256': entry['patchedSourceSHA256'],
            'checkout': str(source_root),
        },
        'patch': {'path': str(patch), 'sha256': entry['patchSHA256']},
        'lock': {'path': str(lock_path), 'entry': entry},
        'node': node_version,
        'limitations': [
            'source-level check only; it does not run a browser, WebKit, engine or App',
            'propagation sinks and section geometry are faithful minimal stubs',
            'real zoom, drawing, save/reopen and physical-device behavior remain root acceptance',
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=None,
                        help='pinned Office source checkout (contains browser/src/...)')
    parser.add_argument('--patch', type=Path, default=DEFAULT_PATCH)
    parser.add_argument('--lock', type=Path, default=DEFAULT_LOCK)
    args = parser.parse_args()
    try:
        report = check(args.source, args.patch, args.lock)
    except (CheckError, OSError, ValueError, json.JSONDecodeError) as failure:
        print(f'batched touch test: {failure}', file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
