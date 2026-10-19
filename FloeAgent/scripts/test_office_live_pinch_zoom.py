#!/usr/bin/env python3
"""Execute the real ZoomControl/CanvasSectionContainer pinch methods.

This is a source-level behavioral check, not Simulator, engine, App or
physical-device acceptance. It reads the pinned blobs, applies the tracked
cc1 -> cancel-propagation -> live-pinch patch chain to a temporary fixture,
verifies the locked hashes, and runs methods extracted from the actual patched
TypeScript with faithful app/layout/section stubs.

Architecture facts checked against the pinned sources, not assumed:

* ``Map._limitZoom`` is a plain min/max range clamp (no rounding, no
  ``zoomSnap``), so a live frame may use the fractional target directly;
* ``DocumentBase.getZoomScale``/``getScaleZoom``/``InternPointUtil.SCALE``
  drive fractional 1.2^z scales, so adjacent ratios (1.03/1.06) produce
  distinct frame scales before the gesture ends;
* the end commit takes the nearest integer level to the range-clamped finger
  zoom (``Math.round(_limitZoom(raw))``) synchronously, while the historical
  outward ceil/floor value is retained only as the ``OverviewFade`` guard
  input. The rounding step is therefore at most half a zoom level; it is not
  a claim that the committed level never differs from the fractional fingers.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LOCK = ROOT / 'ThirdParty/Collabora/browser.patch.lock.json'
ZOOM_FILE = 'browser/src/canvas/sections/ZoomControl.ts'
CANVAS_FILE = 'browser/src/canvas/CanvasSectionContainer.ts'
MAP_FILE = 'browser/src/map/Map.js'
DOCUMENT_FILE = 'browser/src/app/DocumentBase.ts'
INTERN_FILE = 'browser/src/app/InternUtil.ts'
CC1_PATCH = 'ios-batched-touch-start.patch'
CANCEL_PATCH = 'ios-pinch-cancel-propagation.patch'
LIVE_PATCH = 'ios-live-pinch-zoom.patch'
ZOOM_METHODS = ('inDocumentArea', 'zoomTo', 'animateZoom', 'onAnimate',
                'onAnimationEnded', 'onMultiTouchStart',
                'onMultiTouchMove', 'onMultiTouchEnd')
CANVAS_METHODS = ('onTouchCancel', 'clearMousePositions',
                  'getSectionWithName', 'propagateOnMultiTouchEnd')

sys.path.insert(0, str(ROOT / 'scripts'))
import test_office_batched_touch_start as cc1  # noqa: E402


class CheckError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise CheckError(message)


def digest(data):
    if isinstance(data, bytes):
        return hashlib.sha256(data).hexdigest()
    return hashlib.sha256(Path(data).read_bytes()).hexdigest()


def run(command, cwd=None, timeout=90):
    return subprocess.run(
        [str(item) for item in command], cwd=cwd, text=True,
        capture_output=True, timeout=timeout)


def pinned_blob(source, commit, relative):
    result = run(['git', '-C', source, 'show', f'{commit}:{relative}'])
    require(result.returncode == 0,
            f'cannot read pinned blob {commit}:{relative}: {result.stderr.strip()}')
    return result.stdout.encode()


def extract_js_function(text, name):
    match = re.search(
        r'^\s*' + re.escape(name) + r'\s*:\s*function\s*\([^)]*\)\s*\{',
        text, re.M)
    require(match is not None, f'{name} not found in the pinned JavaScript')
    return bracket_block(text, text.index('{', match.start()))


def extract_js_method(text, name):
    match = re.search(
        r'^\tpublic\s+' + re.escape(name) + r'\s*\(', text, re.M)
    require(match is not None, f'{name} not found in the pinned TypeScript')
    return bracket_block(text, text.index('{', match.end()))


def bracket_block(text, index):
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
            require(end >= 0, 'unterminated comment while extracting source')
            position = end + 1
        elif char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                return text[index:position + 1]
        position += 1
    raise CheckError('unterminated block while extracting source')


def load_contract(lock_path):
    require(lock_path.is_file(), f'missing browser patch lock: {lock_path}')
    lock = json.loads(lock_path.read_text())
    entries = lock.get('browserSourcePatches')
    require(isinstance(entries, list), 'browserSourcePatches is not a list')
    by_name = {}
    for entry in entries:
        require(isinstance(entry, dict), 'browserSourcePatches entry is not an object')
        name = Path(entry.get('patch', '')).name
        require(name and name not in by_name, f'duplicate/empty patch name: {name!r}')
        by_name[name] = entry
    engine = lock.get('engine') or {}
    for name in (CC1_PATCH, CANCEL_PATCH, LIVE_PATCH):
        require(name in by_name, f'browser lock is missing {name}')
        entry = by_name[name]
        patch_path = lock_path.parent / entry['patch']
        require(patch_path.is_file(), f'{name} patch file is missing')
        require(digest(patch_path) == entry.get('patchSHA256'),
                f'{name} patch SHA-256 differs from the lock')
        require(entry.get('sourceRepository') == engine.get('repository'),
                f'{name} sourceRepository differs from the engine block')
        require(entry.get('sourceCommit') == engine.get('commit'),
                f'{name} sourceCommit differs from the engine block')
    return lock, by_name


def build_fixture(source, commit, entries, folder, lock_dir):
    paths = {ZOOM_FILE: pinned_blob(source, commit, ZOOM_FILE),
             CANVAS_FILE: pinned_blob(source, commit, CANVAS_FILE)}
    for relative, data in paths.items():
        target = folder / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    run(['git', 'init', '-q'], folder)
    for name in (CC1_PATCH, CANCEL_PATCH, LIVE_PATCH):
        entry = entries[name]
        fixture = folder / entry['sourceFile']
        require(digest(fixture.read_bytes()) == entry['originalSourceSHA256'],
                f'{name} does not start from its locked original')
        check = run(['git', 'apply', '--check', '-p1',
                     lock_dir / entry['patch']], folder)
        require(check.returncode == 0,
                f'{name} does not apply: {check.stderr.strip()}')
        applied = run(['git', 'apply', '-p1',
                       lock_dir / entry['patch']], folder)
        require(applied.returncode == 0,
                f'{name} failed to apply: {applied.stderr.strip()}')
        require(digest(fixture.read_bytes()) == entry['patchedSourceSHA256'],
                f'{name} did not produce its locked patched source')
        reverse = run(['git', 'apply', '--check', '--reverse', '-p1',
                       lock_dir / entry['patch']], folder)
        require(reverse.returncode == 0,
                f'{name} does not reverse cleanly from its patched source')
    return {relative: (folder / relative).read_text() for relative in paths}


HARNESS_HEADER = r'''const assert = require('node:assert/strict');

const calls = [];
const app = {
	dpiScale: 2,
	map: {
		_zoom: 10,
		_docLayer: { _docType: 'text' },
		getZoom() { return this._zoom; },
		getMinZoom() { return 5; },
		getMaxZoom() { return 20; },
		_limitZoom(z) { return Math.max(this.getMinZoom(), Math.min(this.getMaxZoom(), z)); },
	},
	activeDocument: {
		activeLayout: null,
		getScaleZoom(scale, from) { return from + Math.log(scale) / Math.log(1.2); },
		getZoomScale(to, from) { return Math.pow(1.2, to) / Math.pow(1.2, from); },
	},
	sectionContainer: {
		animatingSection: null,
		animatingOwner: null,
		animationElapsed: 0,
		animationDuration: 0,
		getAnimatingSectionName() { return this.animatingSection; },
		requestReDraw() { calls.push(['requestReDraw']); },
		getDocumentAnchorSection() { return { myTopLeft: [0, 0], size: [2000, 2000] }; },
		isInZoomAnimation() { return !!layout.inZoomAnim; },
		startAnimating(section, options) {
			if (this.animatingSection) return false;
			this.animatingSection = 'zoom control';
			this.animatingOwner = section;
			this.animationDuration = (options && options.duration) || 0;
			this.animationElapsed = 0;
			section.isAnimating = true;
			return true;
		},
		tick(dt) {
			if (!this.animatingOwner) return false;
			this.animationElapsed += dt;
			this.animatingOwner.onAnimate(0, this.animationElapsed);
			if (this.animationElapsed >= this.animationDuration) {
				const section = this.animatingOwner;
				section.isAnimating = false;
				section.onAnimationEnded(0, this.animationElapsed);
				this.animatingSection = null;
				this.animatingOwner = null;
				return false;
			}
			return true;
		},
	},
	overview: { beyond: false, requests: [] },
	drawingMode: false,
};

const layout = {
	inZoomAnim: false,
	scale: 1,
	beginZoom(anchor) { calls.push(['beginZoom', anchor.pX, anchor.pY]); this.inZoomAnim = true; this.scale = 1; },
	stepZoom(scale) { calls.push(['stepZoom', scale]); this.scale = scale; },
	endZoom(target, anchor) { calls.push(['endZoom', target, anchor ? anchor.pX : null, anchor ? anchor.pY : null]); this.inZoomAnim = false; this.scale = undefined; app.map._zoom = target; },
	applyZoom(target, anchor) { calls.push(['applyZoom', target, anchor ? anchor.pX : null, anchor ? anchor.pY : null]); app.map._zoom = target; },
	canvasToDocumentPoint(point) { return { pX: point.pX + 100, pY: point.pY + 200, clone() { return this; } }; },
	zoomAnchorPoint() { return { pX: 0, pY: 0 }; },
};
app.activeDocument.activeLayout = layout;

const OverviewFade = {
	handleZoomBeyondLimit(z) { app.overview.requests.push(z); return app.overview.beyond; },
};
const OtherViewCellCursorSection = { closePopups() { calls.push(['closePopups']); } };
const window = { L: { Browser: { cypressTest: false } } };

class ZoomControl {
	zoomDurationMs = 250;
	zoomTarget = null;
	zoomAnchor = null;
	zoomEndScale = 1;
	pinchStartDistance = null;
	pinchStartZoom = null;
	pinchAnchor = null;
	pinchTargetZoom = null;
	pinchLive = false;
	get layout() { return app.activeDocument.activeLayout; }
	startAnimating(options) {
		return app.sectionContainer.startAnimating(this, options);
	}
'''

HARNESS_MIDDLE = r'''}

class CanvasSectionContainer {
	multiTouch = false;
	positionOnMouseDown = null;
	positionOnMouseUp = null;
	positionOnClick = null;
	positionOnDoubleClick = null;
	dragDistance = null;
	draggingSomething = false;
	sectionOnMouseDown = null;
	touchCenter = null;
	touchEventInProgress = false;
	lowestPropagatedBoundSection = null;
	targetSection = null;
	windowSectionList = [];
	sections = [];
	sectionsByName = new Map();
	constructor(sections) {
		this.sections = sections;
		this.sectionsByName = new Map(sections.map((s) => [s.name, s]));
	}
	stopLongPress() { calls.push(['stopLongPress']); }
'''

HARNESS_FOOTER = r'''}

function reset(options = {}) {
	calls.length = 0;
	app.map._zoom = options.startZoom === undefined ? 10 : options.startZoom;
	app.map._docLayer._docType = options.docType || 'text';
	app.sectionContainer.animatingSection = options.animating || null;
	app.sectionContainer.animatingOwner = null;
	app.sectionContainer.animationElapsed = 0;
	app.sectionContainer.animationDuration = 0;
	app.overview.beyond = !!options.beyond;
	app.overview.requests.length = 0;
	app.drawingMode = !!options.drawingMode;
	layout.inZoomAnim = false;
	layout.scale = 1;
	return new ZoomControl();
}
function move(zoom, distance, point = { pX: 100, pY: 100 }) {
	zoom.onMultiTouchMove(point, distance, { type: 'touchmove' });
}
function pinch(start, target, steps = 1, docType = 'text') {
	const zoom = reset({ startZoom: start, docType });
	zoom.onMultiTouchStart({ type: 'touchstart' });
	move(zoom, 100);
	for (let i = 1; i <= steps; i++) {
		const level = start + ((target - start) * i) / steps;
		move(zoom, 100 * Math.pow(1.2, level - start));
	}
	return zoom;
}
function stepScales() { return entries('stepZoom').map((call) => call[1]); }
function guards() { return app.overview.requests.slice(); }
function nameCalls() { return calls.map((call) => call[0]); }
function entries(name) { return calls.filter((call) => call[0] === name); }
function end(zoom, type = 'touchend') { zoom.onMultiTouchEnd({ type }); }
function assertCleared(zoom) {
	assert.equal(zoom.pinchStartDistance, null);
	assert.equal(zoom.pinchStartZoom, null);
	assert.equal(zoom.pinchAnchor, null);
	assert.equal(zoom.pinchTargetZoom, null);
	assert.equal(zoom.pinchLive, false);
}
function close(actual, expected) {
	assert.ok(Math.abs(actual - expected) < 1e-9, `${actual} != ${expected}`);
}
const checks = [];
function scenario(name, fn) { fn(); checks.push(name); }
'''

HARNESS_SCENARIOS = r'''
scenario('first move opens the real zoom-frame at the pinch anchor', () => {
	const zoom = reset();
	zoom.onMultiTouchStart({ type: 'touchstart' });
	move(zoom, 100);
	assert.deepEqual(nameCalls(), ['beginZoom', 'stepZoom']);
	assert.deepEqual(entries('beginZoom')[0].slice(1), [200, 300]);
	assert.equal(entries('stepZoom')[0][1], 1);
	assert.equal(zoom.pinchTargetZoom, null);
	assert.equal(zoom.pinchLive, true);
	assert.equal(entries('endZoom').length, 0);
});

scenario('adjacent fractional ratios paint distinct live frame scales before end', () => {
	const zoom = reset();
	zoom.onMultiTouchStart({ type: 'touchstart' });
	move(zoom, 100);
	calls.length = 0;
	move(zoom, 103);
	const firstScale = entries('stepZoom')[0][1];
	const firstTarget = zoom.pinchTargetZoom;
	close(firstScale, 1.03);
	assert.ok(firstTarget > 10 && firstTarget < 10.2);
	assert.ok(nameCalls().includes('requestReDraw'));
	assert.equal(entries('endZoom').length, 0);
	calls.length = 0;
	move(zoom, 106);
	const secondScale = entries('stepZoom')[0][1];
	close(secondScale, 1.06);
	assert.ok(secondScale - firstScale > 0.02);
	assert.ok(zoom.pinchTargetZoom > firstTarget);
	assert.equal(entries('endZoom').length, 0);
	assert.ok(nameCalls().includes('requestReDraw'));
});

scenario('observed Word pinch-out raw 12.844 commits nearest 13, not outward 12', () => {
	const raw = 14 + Math.log(0.81) / Math.log(1.2);
	const zoom = pinch(14, raw, 6);
	close(zoom.pinchTargetZoom, raw);
	const live = stepScales()[stepScales().length - 1];
	close(live, 0.81);
	calls.length = 0;
	end(zoom);
	assert.deepEqual(guards(), [12]);
	assert.deepEqual(nameCalls(), ['stepZoom', 'endZoom', 'requestReDraw']);
	close(entries('stepZoom')[0][1], Math.pow(1.2, -1));
	assert.equal(entries('endZoom')[0][1], 13);
	assert.equal(app.map._zoom, 13);
	// Historical outward commit 12 produced -14.27 %; nearest 13 gives +2.88 %.
	const outward = Math.floor(raw);
	assert.equal(outward, 12);
	const oldStep = Math.pow(1.2, outward - raw) - 1;
	const newStep = Math.pow(1.2, 13 - raw) - 1;
	assert.ok(oldStep < -0.142 && oldStep > -0.143, `outward ${oldStep}`);
	assert.ok(newStep > 0.0288 && newStep < 0.0289, `nearest ${newStep}`);
	assertCleared(zoom);
});

scenario('in-range fractional target commits its nearest level with live frames intact', () => {
	const zoom = pinch(10, 10.3);
	close(stepScales()[stepScales().length - 1], Math.pow(1.2, 0.3));
	calls.length = 0;
	end(zoom);
	assert.deepEqual(guards(), [11]);
	assert.deepEqual(nameCalls(), ['stepZoom', 'endZoom', 'requestReDraw']);
	close(entries('stepZoom')[0][1], 1);
	assert.equal(entries('endZoom')[0][1], 10);
	assert.equal(app.map._zoom, 10);
	assert.equal(entries('closePopups').length, 0);
	assertCleared(zoom);
});

scenario('tiny gesture returns to the unchanged level 14 without re-raster', () => {
	const zoom = pinch(14, 13.85);
	calls.length = 0;
	end(zoom);
	assert.deepEqual(guards(), [13]);
	assert.deepEqual(nameCalls(), ['stepZoom', 'endZoom', 'requestReDraw']);
	close(entries('stepZoom')[0][1], 1);
	assert.equal(entries('endZoom')[0][1], 14);
	assert.equal(app.map._zoom, 14);
	assert.equal(entries('closePopups').length, 0);
	assertCleared(zoom);
});

scenario('exact integer level commits unchanged after a fractional live frame', () => {
	const zoom = pinch(10, 12);
	close(stepScales()[stepScales().length - 1], Math.pow(1.2, 2));
	calls.length = 0;
	end(zoom);
	assert.deepEqual(guards(), [12]);
	close(entries('stepZoom')[0][1], Math.pow(1.2, 2));
	assert.equal(entries('endZoom')[0][1], 12);
	assert.equal(app.map._zoom, 12);
	assertCleared(zoom);
});

scenario('half-level ties round up and just-inside values keep the nearest level', () => {
	function commit(raw) {
		const zoom = pinch(10, raw);
		calls.length = 0;
		end(zoom);
		return {
			commit: app.map._zoom,
			guard: guards()[0],
			scale: entries('stepZoom')[0][1],
		};
	}
	const rows = {
		t125: commit(12.5),
		t135: commit(13.5),
		t145: commit(14.5),
		t13499: commit(13.4999),
		t135001: commit(13.5001),
	};
	assert.equal(rows.t125.commit, 13);
	assert.equal(rows.t135.commit, 14);
	assert.equal(rows.t145.commit, 15);
	assert.equal(rows.t13499.commit, 13);
	assert.equal(rows.t135001.commit, 14);
	assert.deepEqual([rows.t125.guard, rows.t135.guard, rows.t145.guard], [13, 14, 15]);
	assert.deepEqual([rows.t13499.guard, rows.t135001.guard], [14, 14]);
	for (const row of Object.values(rows)) {
		assert.ok(Number.isInteger(row.commit));
		close(row.scale, Math.pow(1.2, row.commit - 10));
	}
});

scenario('range bounds clamp the live frame and the nearest commit exactly', () => {
	function run(start, raw) {
		const zoom = pinch(start, raw);
		const live = stepScales()[stepScales().length - 1];
		calls.length = 0;
		end(zoom);
		return {
			guard: guards()[0],
			commit: app.map._zoom,
			scale: entries('stepZoom')[0][1],
			live,
		};
	}
	const max = run(16, 20);
	const above = run(16, 20.4);
	const min = run(8, 5);
	const below = run(8, 4.6);
	const inside = run(8, 5.6);
	const nearMax = run(16, 18.4);
	assert.deepEqual(
		[max.commit, above.commit, min.commit, below.commit, inside.commit, nearMax.commit],
		[20, 20, 5, 5, 6, 18]);
	assert.deepEqual(
		[max.guard, above.guard, min.guard, below.guard, inside.guard, nearMax.guard],
		[20, 21, 5, 4, 5, 19]);
	close(max.live, Math.pow(1.2, 4));
	close(above.live, Math.pow(1.2, 4));
	close(min.live, Math.pow(1.2, -3));
	close(below.live, Math.pow(1.2, -3));
	assert.ok(above.scale <= Math.pow(1.2, 4));
	assert.ok(below.scale >= Math.pow(1.2, -3));
	assert.ok(inside.commit > inside.guard);
});

scenario('no-move end leaves the view untouched and clears state', () => {
	const zoom = reset();
	zoom.onMultiTouchStart({ type: 'touchstart' });
	end(zoom);
	assert.deepEqual(nameCalls(), []);
	assert.equal(app.map._zoom, 10);
	assertCleared(zoom);
});

scenario('first-move-only end closes the frame at the start level', () => {
	const zoom = reset();
	zoom.onMultiTouchStart({ type: 'touchstart' });
	move(zoom, 100);
	calls.length = 0;
	end(zoom);
	assert.deepEqual(nameCalls(), ['endZoom', 'requestReDraw']);
	assert.equal(entries('endZoom')[0][1], 10);
	assert.equal(app.map._zoom, 10);
	assertCleared(zoom);
});

scenario('touchcancel closes the frame without committing any zoom', () => {
	const zoom = reset();
	const document = { name: 'document', boundsList: [], interactable: true };
	zoom.name = 'ZoomControl';
	zoom.interactable = true;
	const container = new CanvasSectionContainer([document]);
	container.windowSectionList = [zoom];
	container.multiTouch = true;
	container.sectionOnMouseDown = 'document';
	zoom.onMultiTouchStart({ type: 'touchstart' });
	move(zoom, 100);
	move(zoom, 106);
	calls.length = 0;
	container.onTouchCancel({ type: 'touchcancel' });
	assert.equal(app.map._zoom, 10);
	assert.equal(entries('endZoom')[0][1], 10);
	assert.equal(entries('endZoom').length, 1);
	assert.equal(entries('applyZoom').length, 0);
	assert.equal(nameCalls().filter((name) => name === 'stepZoom').length, 1);
	assert.equal(entries('stepZoom')[0][1], 1);
	assert.equal(nameCalls()[nameCalls().length - 1], 'stopLongPress');
	assert.equal(container.multiTouch, false);
	assert.equal(container.sectionOnMouseDown, null);
	assertCleared(zoom);
});

scenario('touchcancel without a multi-touch gesture does not propagate', () => {
	const zoom = reset();
	const document = { name: 'document', boundsList: [], interactable: true };
	zoom.name = 'ZoomControl';
	zoom.interactable = true;
	const container = new CanvasSectionContainer([document]);
	container.windowSectionList = [zoom];
	container.onTouchCancel({ type: 'touchcancel' });
	assert.equal(entries('endZoom').length, 0);
	assert.equal(container.multiTouch, false);
});

scenario('sequential gestures start from the newly committed nearest zoom', () => {
	const raw = 14 + Math.log(0.81) / Math.log(1.2);
	const zoom = pinch(14, raw, 3);
	end(zoom);
	assert.equal(app.map._zoom, 13);
	calls.length = 0;
	app.overview.requests.length = 0;
	zoom.onMultiTouchStart({ type: 'touchstart' });
	assert.equal(zoom.pinchStartZoom, 13);
	move(zoom, 100);
	calls.length = 0;
	move(zoom, 100 * Math.pow(1.2, 1));
	close(entries('stepZoom')[0][1], Math.pow(1.2, 1));
	end(zoom);
	assert.deepEqual(guards(), [14]);
	assert.equal(entries('endZoom')[0][1], 14);
	assert.equal(app.map._zoom, 14);
	assertCleared(zoom);
});

scenario('a genuinely overlapping animation keeps the bounded end-only nearest commit', () => {
	const raw = 14 + Math.log(0.81) / Math.log(1.2);
	const zoom = reset({ animating: 'MouseControl', startZoom: 14 });
	zoom.onMultiTouchStart({ type: 'touchstart' });
	move(zoom, 100);
	move(zoom, 100 * Math.pow(1.2, raw - 14));
	assert.equal(entries('beginZoom').length, 0);
	assert.equal(entries('stepZoom').length, 0);
	calls.length = 0;
	end(zoom);
	assert.equal(entries('endZoom').length, 0);
	assert.deepEqual(nameCalls(), ['applyZoom']);
	assert.equal(entries('applyZoom')[0][1], 13);
	assert.equal(app.map._zoom, 13);
	// The outward guard still decides the overview hand-off first; zoomTo then
	// consults its own guard for the nearest commit target.
	assert.deepEqual(guards(), [12, 13]);
});

scenario('overview hand-off keeps the outward guard input at both limits', () => {
	const high = reset({ startZoom: 20, beyond: true });
	high.onMultiTouchStart({ type: 'touchstart' });
	move(high, 100);
	move(high, 100 * Math.pow(1.2, 20.6 - 20));
	calls.length = 0;
	end(high);
	assert.deepEqual(guards(), [21]);
	assert.deepEqual(nameCalls(), ['endZoom', 'requestReDraw']);
	assert.equal(entries('endZoom')[0][1], 20);
	assert.equal(entries('applyZoom').length, 0);
	assert.equal(app.map._zoom, 20);
	assertCleared(high);

	const low = reset({ startZoom: 5, beyond: true });
	low.onMultiTouchStart({ type: 'touchstart' });
	move(low, 100);
	move(low, 100 * Math.pow(1.2, 4.4 - 5));
	calls.length = 0;
	end(low);
	assert.deepEqual(guards(), [4]);
	assert.deepEqual(nameCalls(), ['endZoom', 'requestReDraw']);
	assert.equal(entries('endZoom')[0][1], 5);
	assert.equal(app.map._zoom, 5);
	assertCleared(low);
});

scenario('spreadsheet closePopups hook runs only for a changed nearest target', () => {
	const raw = 14 + Math.log(0.81) / Math.log(1.2);
	const zoom = pinch(14, raw, 1, 'spreadsheet');
	calls.length = 0;
	end(zoom);
	assert.equal(entries('closePopups').length, 1);
	assert.equal(entries('endZoom')[0][1], 13);

	const unchanged = pinch(10, 10.3, 1, 'spreadsheet');
	calls.length = 0;
	end(unchanged);
	assert.equal(entries('closePopups').length, 0);
	assert.equal(entries('endZoom')[0][1], 10);

	const writer = pinch(14, raw);
	calls.length = 0;
	end(writer);
	assert.equal(entries('closePopups').length, 0);
	assert.equal(entries('endZoom')[0][1], 13);
});

scenario('Word, Calc and Impress share the observed nearest commit and Calc hook', () => {
	const raw = 14 + Math.log(0.81) / Math.log(1.2);
	const rows = {};
	for (const docType of ['text', 'spreadsheet', 'presentation']) {
		const zoom = pinch(14, raw, 2, docType);
		calls.length = 0;
		end(zoom);
		rows[docType] = {
			commit: app.map._zoom,
			guard: guards()[0],
			closes: entries('closePopups').length,
		};
	}
	assert.deepEqual(rows, {
		text: { commit: 13, guard: 12, closes: 0 },
		spreadsheet: { commit: 13, guard: 12, closes: 1 },
		presentation: { commit: 13, guard: 12, closes: 0 },
	});
});

scenario('ordinary and pen modes share one identical pinch path', () => {
	function gesture(drawingMode) {
		const zoom = reset({ drawingMode });
		zoom.onMultiTouchStart({ type: 'touchstart' });
		move(zoom, 100);
		move(zoom, 103);
		move(zoom, 106);
		end(zoom);
		return calls.map((call) => JSON.stringify(call));
	}
	assert.deepEqual(gesture(false), gesture(true));
});

scenario('a gesture outside the document anchor never starts a live frame', () => {
	const zoom = reset();
	zoom.onMultiTouchStart({ type: 'touchstart' });
	move(zoom, 100, { pX: 3000, pY: 3000 });
	move(zoom, 106, { pX: 3000, pY: 3000 });
	assert.deepEqual(nameCalls(), []);
	assert.equal(zoom.pinchTargetZoom, null);
	end(zoom);
	assert.deepEqual(nameCalls(), []);
	assert.equal(app.map._zoom, 10);
});

scenario('an interrupted gesture is closed before the next start resets state', () => {
	const zoom = reset();
	zoom.onMultiTouchStart({ type: 'touchstart' });
	move(zoom, 100);
	move(zoom, 106);
	calls.length = 0;
	zoom.onMultiTouchStart({ type: 'touchstart' });
	assert.deepEqual(nameCalls(), ['stepZoom', 'endZoom', 'requestReDraw']);
	assert.equal(entries('endZoom')[0][1], 10);
	assert.equal(app.map._zoom, 10);
	assert.equal(zoom.pinchStartZoom, 10);
	assert.equal(zoom.pinchLive, false);
});

scenario('programmatic animated zoom is unchanged in target, duration and slot', () => {
	const zoom = reset();
	zoom.zoomTo(11);
	assert.equal(app.sectionContainer.animatingSection, 'zoom control');
	assert.equal(layout.inZoomAnim, true);
	assert.equal(entries('beginZoom').length, 1);
	let elapsed = 0;
	let frames = 0;
	while (app.sectionContainer.animatingSection && frames++ < 40) {
		app.sectionContainer.tick(16.7);
		elapsed += 16.7;
	}
	assert.equal(app.sectionContainer.animatingSection, null);
	assert.equal(app.map._zoom, 11);
	assert.equal(entries('endZoom')[0][1], 11);
	assert.ok(elapsed >= 250 && elapsed <= 250 + 2 * 16.7);
	assert.ok(entries('stepZoom').length > 2);
	assert.deepEqual(guards(), [11]);
});

scenario('programmatic pointer-anchored zoom still commits directly', () => {
	const zoom = reset();
	zoom.zoomTo(11, { pX: 1, pY: 2 }, false);
	assert.deepEqual(nameCalls(), ['applyZoom']);
	assert.equal(entries('applyZoom')[0][1], 11);
	assert.equal(app.map._zoom, 11);
	assert.deepEqual(guards(), [11]);
	assert.equal(app.sectionContainer.animatingSection, null);
});

scenario('no asynchronous settle state or input hooks are added', () => {
	const zoom = reset();
	const expected = [
		'pinchAnchor', 'pinchLive', 'pinchStartDistance', 'pinchStartZoom',
		'pinchTargetZoom', 'zoomAnchor', 'zoomDurationMs', 'zoomEndScale',
		'zoomTarget',
	].sort();
	assert.deepEqual(Object.keys(zoom).sort(), expected);
	for (const name of ['pinchSettling', 'settleTimer', 'startPinchSettle',
		'finishPinchSettle', 'onMouseDown', 'closeZoomFrameForLayoutSwap']) {
		assert.equal(typeof zoom[name], 'undefined', name);
	}
});

scenario('guard input is outward at every level while the commit is nearest and clamped', () => {
	const samples = [5.6, 8.4, 9.5, 10.49, 10.5, 11.5, 12.84, 13.5, 14.5, 15.9];
	const rows = [];
	for (const raw of samples) {
		const zoom = pinch(10, raw);
		calls.length = 0;
		end(zoom);
		const guard = guards()[0];
		const commit = app.map._zoom;
		rows.push({ raw, guard, commit });
		assert.equal(guard, raw > 10 ? Math.ceil(raw) : Math.floor(raw));
		const clamped = Math.max(5, Math.min(20, raw));
		assert.equal(commit, Math.max(5, Math.min(20, Math.round(clamped))));
		assert.ok(Math.abs(commit - clamped) <= 0.5 + 1e-12);
	}
	assert.deepEqual(
		rows.map((row) => row.commit),
		[6, 8, 10, 10, 11, 12, 13, 14, 15, 16]);
});

scenario('nearest commit bounds the rounding step to at most half a level', () => {
	const samples = [
		10.0001, 10.4999, 10.5, 10.5001, 11.4999, 12.0001,
		12.4999, 13.5, 14.4999, 15.5001, 18.5,
	];
	let worstUp = 0;
	let worstDown = 0;
	for (const raw of samples) {
		const commit = Math.round(raw);
		const pct = Math.pow(1.2, commit - raw) - 1;
		worstUp = Math.max(worstUp, pct);
		worstDown = Math.min(worstDown, pct);
		assert.ok(pct <= 0.0954452 + 1e-9, `${raw} up ${pct}`);
		assert.ok(pct >= -0.0871293 - 1e-9, `${raw} down ${pct}`);
	}
	assert.ok(worstUp > 0.095 && worstUp <= 0.0954452);
	assert.ok(worstDown < -0.087 && worstDown >= -0.0871293);
	// The historical outward rule could move a whole level: -16.67 % when a
	// shrink lands just below an integer, +20 % when a grow lands just above.
	const outwardDown = Math.pow(1.2, Math.floor(12.9999) - 12.9999) - 1;
	const outwardUp = Math.pow(1.2, Math.ceil(12.0001) - 12.0001) - 1;
	assert.ok(outwardDown < -0.1666 && outwardDown > -0.1667);
	assert.ok(outwardUp > 0.1999 && outwardUp < 0.2001);
});

console.log(JSON.stringify({ checks }));
'''


def run_harness(folder, methods, label):
    script = folder / f'{label}.ts'
    script.write_text(HARNESS_HEADER + methods[0] + HARNESS_MIDDLE
                      + methods[1] + HARNESS_FOOTER + HARNESS_SCENARIOS)
    result = run(['node', '--experimental-strip-types', script], cwd=folder)
    if result.returncode != 0:
        raise CheckError(f'{label} Node harness failed:\n{result.stdout}\n{result.stderr}')
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    require(bool(lines), f'{label} Node harness printed no result')
    return json.loads(lines[-1])['checks']


def source_checks(source, commit):
    checks = []
    map_text = pinned_blob(source, commit, MAP_FILE).decode()
    limit = extract_js_function(map_text, '_limitZoom')
    require('Math.max(min, Math.min(max, zoom))' in limit,
            'Map._limitZoom is not the expected min/max clamp')
    for forbidden in ('Math.round', 'Math.floor', 'Math.ceil', 'zoomSnap', 'snap'):
        require(forbidden not in limit,
                f'Map._limitZoom unexpectedly contains {forbidden}')
    checks.append('pinned Map._limitZoom is a range clamp only (no rounding/snap)')
    grep = run(['git', '-C', source, 'grep', '-n', 'zoomSnap', '--', 'browser/src'])
    require(grep.returncode == 1, 'pinned browser source unexpectedly references zoomSnap')
    checks.append('pinned browser source has no zoomSnap option')

    document_text = pinned_blob(source, commit, DOCUMENT_FILE).decode()
    get_scale = extract_js_method(document_text, 'getZoomScale')
    get_zoom = extract_js_method(document_text, 'getScaleZoom')
    require('InternPointUtil.scale(toZoom) / InternPointUtil.scale(from)' in get_scale,
            'DocumentBase.getZoomScale is not the expected pure ratio')
    require('Math.log(scale) / Math.log(InternPointUtil.SCALE)' in get_zoom,
            'DocumentBase.getScaleZoom is not the expected fractional logarithm')
    intern_text = pinned_blob(source, commit, INTERN_FILE).decode()
    require('public static SCALE = 1.2;' in intern_text,
            'InternPointUtil.SCALE is not 1.2')
    checks.append('fractional 1.2^z zoom math is the pinned source path')

    # The animation slot is a single section-wide resource. Record its real
    # users: programmatic ZoomControl zoom, momentum ScrollSection and kinetic
    # MouseControl swipe. A caret/selection blink must not live there, or the
    # first-move fallback would disable live pinch in ordinary editing.
    animation = run(['git', '-C', source, 'grep', '-n', 'this.startAnimating(', '--',
                     'browser/src'])
    require(animation.returncode == 0,
            'cannot enumerate startAnimating call sites')
    users = set()
    for line in animation.stdout.splitlines():
        path, _line, body = line.split(':', 2)
        if 'this.startAnimating(' in body:
            users.add(Path(path).name)
    require(users == {'ZoomControl.ts', 'ScrollSection.ts', 'MouseControl.ts'},
            f'unexpected animation-slot users: {sorted(users)}')
    checks.append('animation slot is used only by programmatic zoom, smooth scroll '
                  'and kinetic swipe; no caret/selection blink occupies it')
    return checks


def check(source, lock_path):
    lock, entries = load_contract(lock_path)
    source_root = cc1.resolve_source(source)
    commit = lock['engine']['commit']
    require(entries[CC1_PATCH]['sourceFile'] == CANVAS_FILE,
            'cc1 patch sourceFile differs from the Canvas file')
    require(entries[LIVE_PATCH]['sourceFile'] == ZOOM_FILE,
            'live patch sourceFile differs from ZoomControl')
    require(entries[CANCEL_PATCH]['sourceFile'] == CANVAS_FILE,
            'cancel patch sourceFile differs from the Canvas file')
    require(entries[CANCEL_PATCH]['originalSourceSHA256']
            == entries[CC1_PATCH]['patchedSourceSHA256'],
            'cancel patch does not continue the cc1 patched source')
    checks = ['tracked cc1 -> cancel -> live patch chain is ordered by source state']
    require(all(entry['sourceFile'].startswith('browser/src/')
                for entry in entries.values()),
            'browser patch chain must not touch native/Pencil sources')
    checks.append('browser patch chain touches only browser/src sources '
                  '(no native Pencil/palm gate change)')
    checks.extend(source_checks(source_root, commit))

    with tempfile.TemporaryDirectory(prefix='floe-live-pinch-') as temporary:
        folder = Path(temporary)
        texts = build_fixture(source_root, commit, entries, folder, lock_path.parent)
        checks.append('patch chain applies and produces every locked patched source hash')
        zoom_text = texts[ZOOM_FILE]
        require(zoom_text.count('Math.round(') == 1,
                'the pinch commit must be the only Math.round in ZoomControl')
        require(zoom_text.count('Math.ceil(') == 1
                and zoom_text.count('Math.floor(') == 1,
                'the outward ceil/floor value must appear only once (guard input)')
        require('const guardZoom' in zoom_text and 'const commitZoom' in zoom_text,
                'guardZoom/commitZoom source split is missing')
        for forbidden in ('setTimeout', 'setInterval', 'pinchSettling',
                          'startPinchSettle', 'finishPinchSettle'):
            require(forbidden not in zoom_text,
                    f'patched ZoomControl unexpectedly contains {forbidden}')
        checks.append('actual patched commit is nearest with a guard-only outward '
                      'value and no timer/settle surface')
        for relative, expected in ((ZOOM_FILE, entries[LIVE_PATCH]),
                                   (CANVAS_FILE, entries[CANCEL_PATCH])):
            require(digest((folder / relative).read_bytes())
                    == expected['patchedSourceSHA256'],
                    f'{relative} final source differs from the lock')
            headers = re.findall(r'^(?:---|\+\+\+) ([^\t\n]+)',
                                 (lock_path.parent / expected['patch']).read_text(), re.M)
            require(headers == [f'a/{relative}', f'b/{relative}'],
                    f"{expected['patch']} modifies more than {relative}")

        zoom_methods = '\n\n'.join(
            cc1.extract_method(texts[ZOOM_FILE], name) for name in ZOOM_METHODS)
        canvas_methods = '\n\n'.join(
            cc1.extract_method(texts[CANVAS_FILE], name) for name in CANVAS_METHODS)
        require('propagateOnMultiTouchEnd(cancelSection, e)' in canvas_methods,
                'onTouchCancel does not propagate the cancelled gesture')
        cancel_body = cc1.extract_method(texts[CANVAS_FILE], 'onTouchCancel')
        require(cancel_body.index('propagateOnMultiTouchEnd')
                < cancel_body.index('clearMousePositions'),
                'onTouchCancel clears the target before propagating the cancel')
        checks.append('actual patched onTouchCancel propagates before clearing state')
        executed = run_harness(folder, (zoom_methods, canvas_methods), 'live-pinch')
        checks.extend(executed)

    return {
        'kind': 'pinned-source live pinch behavior with extracted actual methods',
        'checksPassed': checks,
        'source': {
            'repository': lock['engine']['repository'],
            'commit': commit,
            'checkout': str(source_root),
            'files': {
                ZOOM_FILE: {
                    'originalSHA256': entries[LIVE_PATCH]['originalSourceSHA256'],
                    'patchedSHA256': entries[LIVE_PATCH]['patchedSourceSHA256'],
                },
                CANVAS_FILE: {
                    'originalSHA256': entries[CC1_PATCH]['originalSourceSHA256'],
                    'cc1PatchedSHA256': entries[CC1_PATCH]['patchedSourceSHA256'],
                    'patchedSHA256': entries[CANCEL_PATCH]['patchedSourceSHA256'],
                },
            },
        },
        'patches': {name: {'path': str(lock_path.parent / entry['patch']),
                           'sha256': entry['patchSHA256']}
                    for name, entry in entries.items()},
        'node': run(['node', '--version']).stdout.strip(),
        'limitations': [
            'source-level check only; it does not run WebKit, the engine or the App',
            'the layout/app/section stubs are faithful minimal models',
            'the nearest commit changes the committed level (and still size) '
            'versus historical outward results; only the Word case is video-measured',
            'real visible mid-gesture compositor frames, touch-phase timing, '
            'ordinary/pen device behavior and save/reopen remain root acceptance',
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--source', type=Path, default=None,
                        help='pinned Office source checkout')
    parser.add_argument('--lock', type=Path, default=DEFAULT_LOCK)
    args = parser.parse_args()
    try:
        report = check(args.source, args.lock)
    except (CheckError, OSError, ValueError, json.JSONDecodeError) as failure:
        print(f'live pinch test: {failure}', file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
