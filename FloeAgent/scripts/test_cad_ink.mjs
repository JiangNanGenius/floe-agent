// SPDX-License-Identifier: MPL-2.0
// Capability, transform, bounds, cancellation and error tests for the CAD
// Pencil annotation work. Runs against the pinned assets in
// FloeAgent/FloeApp/Resources/EngineeringViewers without modifying them.
//
//   node FloeAgent/scripts/test_cad_ink.mjs
//
// The last section talks to whichever engine binary is actually bundled. It
// asserts the truthful outcome for that binary (capabilities advertised ->
// atomic addStroke works; capabilities absent -> ink is gated off and the
// operation is rejected), so it stays valid across a rebuilt WASM.
//
// Exit code 0 means every assertion passed. The printed CAPABILITY block records
// the bundled engine's real surface.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const viewers = path.resolve(scriptDir, '../FloeApp/Resources/EngineeringViewers');
const load = name => pathToFileURL(path.join(viewers, name)).href;

const ink = await import(load('cad-ink.js'));
const { default: init, CadSession } = await import(load('floe_cad_engine.js'));
await init({ module_or_path: fs.readFileSync(path.join(viewers, 'floe_cad_engine_bg.wasm')) });

const failures = [];
const passes = [];
function check(name, condition, detail = '') {
  if (condition) passes.push(name);
  else failures.push(detail ? `${name} — ${detail}` : name);
}
const close = (a, b, epsilon = 1e-6) => Math.abs(a - b) <= epsilon;

const inspect = session => JSON.parse(session.inspect(0, 500));
const edit = (session, request) => {
  try { session.edit(JSON.stringify(request)); return null; }
  catch (error) { return String(error?.message ?? error); }
};
const openFixture = (file, format) => new CadSession(fs.readFileSync(path.join(viewers, file)), format);
const operationsFrom = message => {
  const match = /expected one of ((?:`[^`]+`(?:, )?)+)/.exec(String(message ?? ''));
  return match ? match[1].split(',').map(token => token.trim().replace(/^`|`$/g, '')).filter(Boolean) : [];
};

// Exact projection of FloeAgent/ThirdParty/CADEngine/src/lib.rs capabilities().
const indexWidths = [0, 5, 9, 13, 15, 18, 20, 25, 30, 35, 40, 50, 53, 60, 70, 80, 90, 100, 106, 120, 140, 158, 200, 211];
const engineMetadata = {
  capabilities: {
    version: 1,
    coordinateUnits: 'unitless drawing units; stroke points are world coordinates [x,y,z] with Z preserved',
    addStroke: {
      pointCount: { min: 2, max: 256 },
      coordinateBounds: 'finite, abs(value) <= 1e12',
      segments: 'points - 1 LINE entities',
      layer: 'FLOE_ANNOTATION',
      layerPolicy: 'created on demand; whole stroke rejected when the layer is locked',
      color: { field: 'color', type: 'ACI index', min: 1, max: 255, default: 'ByLayer' },
      lineWeight: { field: 'lineWeight', unit: '1/100 mm', allowed: indexWidths, default: 'ByLayer' },
      atomicity: 'all segments applied or none',
      history: 'one undo/redo snapshot per stroke',
    },
  },
  diagnostics: [],
  omittedDiagnostics: 0,
};

// ---------------------------------------------------------------------------
// 1. Screen <-> world transform (dxf.js SetView/_CanvasToSceneCoord model),
//    including zoom, pan, origin and a retina device pixel ratio.
// ---------------------------------------------------------------------------
const view = {
  canvasWidth: 1000,
  canvasHeight: 500,
  origin: { x: 100, y: -50 },
  camera: { left: -200, right: 200, top: 100, bottom: -100, zoom: 1, position: { x: 10, y: 20 } },
};
{
  const center = ink.screenToWorld({ x: 500, y: 250 }, view);
  check('screenToWorld center is origin+camera.position', close(center.x, 110) && close(center.y, -30), JSON.stringify(center));

  const p = { x: 750, y: 125 };
  const zoomed = { ...view, camera: { ...view.camera, zoom: 2 } };
  const w1 = ink.screenToWorld(p, view);
  const w2 = ink.screenToWorld(p, zoomed);
  check('zoom scales world offset from center',
    close((w1.x - center.x) / 2, w2.x - center.x) && close((w1.y - center.y) / 2, w2.y - center.y),
    `${JSON.stringify(w1)} ${JSON.stringify(w2)}`);

  const panned = { ...view, camera: { ...view.camera, position: { x: 30, y: -40 } } };
  const wp = ink.screenToWorld(p, panned);
  check('pan shifts world by camera delta', close(wp.x - w1.x, 20) && close(wp.y - w1.y, -60), `${wp.x - w1.x},${wp.y - w1.y}`);

  const round = ink.worldToScreen(w1, view);
  check('worldToScreen inverts screenToWorld', close(round.x, p.x, 1e-8) && close(round.y, p.y, 1e-8), JSON.stringify(round));

  const retina = { ...view, canvasWidth: 2000, canvasHeight: 1000 };
  const rc = ink.screenToWorld({ x: 1000, y: 500 }, retina);
  check('CSS-space transform is stable at 2x device pixel ratio', close(rc.x, 110) && close(rc.y, -30), JSON.stringify(rc));

  const shifted = ink.sceneToWorld({ x: 1, y: 2 }, { x: 5, y: 7 });
  check('origin compensation adds GetOrigin', shifted.x === 6 && shifted.y === 9, JSON.stringify(shifted));

  check('clientToCanvas subtracts rect origin', JSON.stringify(ink.clientToCanvas({ x: 40, y: 60 }, { left: 10, top: 15 })) === JSON.stringify({ x: 30, y: 45 }));

  const perPixel = ink.worldPerCssPixel({ ...view, camera: { ...view.camera, zoom: 2 } });
  check('worldPerCssPixel accounts for zoom', close(perPixel, 0.2), String(perPixel));
  const tolerance = ink.cssToleranceToWorld(2, { ...view, camera: { ...view.camera, zoom: 1 } });
  check('CSS tolerance converts to world units', close(tolerance, 0.8), String(tolerance));

  let threw = false;
  try { ink.screenToScene({ x: 0, y: 0 }, { camera: view.camera, canvasWidth: 0, canvasHeight: 0 }); } catch { threw = true; }
  check('screenToScene rejects zero canvas', threw);

  threw = false;
  try { ink.worldPerCssPixel({ camera: { ...view.camera, zoom: 0 }, canvasWidth: 1000 }); } catch { threw = true; }
  check('worldPerCssPixel rejects non-positive zoom', threw);
}

// ---------------------------------------------------------------------------
// 2. Capability metadata parsing and readiness gating.
// ---------------------------------------------------------------------------
{
  const caps = ink.readStrokeCapabilities(engineMetadata);
  check('capabilities: addStroke is read as supported', caps.supported, JSON.stringify(caps));
  check('capabilities: pointCount is 2..256', caps.pointCount.min === 2 && caps.pointCount.max === 256, JSON.stringify(caps.pointCount));
  check('capabilities: ACI color range is 1..255', caps.color.min === 1 && caps.color.max === 255, JSON.stringify(caps.color));
  check('capabilities: canonical widths include 25 not 17', caps.lineWeights.includes(25) && !caps.lineWeights.includes(17));
  check('capabilities: annotation layer is declared', caps.layer === ink.ANNOTATION_LAYER);

  check('missing metadata is unsupported',
    ink.readStrokeCapabilities({}).supported === false
    && ink.readStrokeCapabilities({}).reason === 'capabilities-missing');
  check('malformed pointCount is unsupported',
    ink.readStrokeCapabilities({ capabilities: { addStroke: { pointCount: { min: 1, max: 5 } } } }).reason === 'pointCount-invalid');

  const informational = ['[Warning] Reading DWG file version: AC1032 (AC24)',
    '[Warning] AC18 inner header: page_map_address=0x5040, section_map_id=15',
    '[Warning] AC18: Read 16 page records from page map',
    '[Warning] AC18: Read 12 section descriptors from section map'];
  check('informational DWG notices are not blocking',
    informational.every(ink.isInformationalDiagnostic) && !ink.hasBlockingDiagnostics({ diagnostics: informational }));
  check('a real error diagnostic is blocking', ink.hasBlockingDiagnostics({ diagnostics: ['[Error] truncated section'] }));
  check('omitted diagnostics are blocking', ink.hasBlockingDiagnostics({ omittedDiagnostics: 2 }));

  check('ink is ready with valid metadata and no diagnostics',
    ink.inkReadiness({ ...engineMetadata }).ready === true);
  check('ink is gated by diagnostics',
    ink.inkReadiness({ ...engineMetadata, diagnostics: ['[Error] bad'] }).reason === 'diagnostics');
  check('ink is gated when metadata is absent',
    ink.inkReadiness({ diagnostics: [] }).reason === 'capabilities-missing');
  check('five ACI colors include adaptive ACI 7',
    ink.ACI_COLORS.length === 5
    && ink.ACI_COLORS.some(c => c.aci === 7 && c.adaptive)
    && ink.aciCssColor(7, true) === '#ffffff' && ink.aciCssColor(7, false) === '#111111');
  check('canonical width presets are canonical',
    ink.LINE_WEIGHT_PRESETS.every(p => indexWidths.includes(p.value)));
}

// ---------------------------------------------------------------------------
// 3. Stroke reduction, request building and capability-bounded validation.
// ---------------------------------------------------------------------------
{
  const collinear = [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 2, y: 0 }, { x: 3, y: 0 }];
  const reduced = ink.reduceStroke(collinear, { tolerance: 0.01, maxPoints: 128 });
  check('collinear stroke collapses to endpoints', reduced.length === 2 && reduced[0].x === 0 && reduced[1].x === 3, JSON.stringify(reduced));

  const corner = [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 1, y: 2 }];
  const kept = ink.reduceStroke(corner, { tolerance: 0.1, maxPoints: 128 });
  check('sharp corner survives reduction', kept.some(p => p.x === 1 && p.y === 0) && kept.length >= 3, JSON.stringify(kept));

  const many = Array.from({ length: 1000 }, (_, i) => ({ x: i * 0.01, y: Math.sin(i / 20) }));
  const bounded = ink.reduceStroke(many, { tolerance: 0.0001, maxPoints: ink.DEFAULT_MAX_POINTS });
  check('reduction is bounded by the engine max (256)', bounded.length <= 256 && bounded.length >= 2, String(bounded.length));
  check('reduction keeps endpoints', close(bounded[0].x, many[0].x) && close(bounded.at(-1).x, many.at(-1).x));

  const request = ink.buildStrokeRequest(many, { maxPoints: 256, tolerance: 0.0001, color: 1, lineWeight: 25 });
  check('buildStrokeRequest emits one typed addStroke', request.operation === 'addStroke' && request.points.length <= 256, JSON.stringify(request).slice(0, 80));
  check('buildStrokeRequest preserves world coordinates', request.points[0].length === 3 && close(request.points[0][0], many[0].x) && request.points[0][2] === 0);
  check('buildStrokeRequest carries color and canonical width', request.color === 1 && request.lineWeight === 25);
  check('buildStrokeRequest drops a single point', ink.buildStrokeRequest([{ x: 1, y: 1 }]) === null);

  const caps = ink.readStrokeCapabilities(engineMetadata);
  check('valid request passes validation', ink.validateStrokeRequest(request, caps).ok === true, JSON.stringify(ink.validateStrokeRequest(request, caps)));
  check('one-point request fails validation', ink.validateStrokeRequest({ operation: 'addStroke', points: [[0, 0, 0]] }, caps).reason === 'pointCount-out-of-range');
  check('non-canonical width fails validation', ink.validateStrokeRequest({ operation: 'addStroke', points: [[0, 0, 0], [1, 1, 0]], lineWeight: 17 }, caps).reason === 'lineWeight-not-canonical');
  check('out-of-range ACI color fails validation', ink.validateStrokeRequest({ operation: 'addStroke', points: [[0, 0, 0], [1, 1, 0]], color: 256 }, caps).reason === 'color-out-of-range');
  check('non-finite coordinate fails validation', ink.validateStrokeRequest({ operation: 'addStroke', points: [[0, 0, 0], [Number.POSITIVE_INFINITY, 1, 0]] }, caps).reason === 'coordinate-out-of-range');
  check('validation refuses an unsupported engine', ink.validateStrokeRequest(request, ink.readStrokeCapabilities({})).ok === false);
}

// ---------------------------------------------------------------------------
// 4. Capture bounds and explicit cancellation/commit semantics.
// ---------------------------------------------------------------------------
{
  const capture = ink.createStrokeCapture({ maxCaptured: 3 });
  capture.begin();
  check('capture accepts finite samples', capture.add({ x: 0, y: 0 }) && capture.add({ x: 1, y: 1 }) && capture.add({ x: 2, y: 2 }));
  check('capture rejects samples beyond its bound', capture.add({ x: 3, y: 3 }) === false && capture.size === 3);
  check('capture rejects non-finite samples', capture.add({ x: Number.NaN, y: 0 }) === false);
  capture.cancel();
  check('cancel clears every sample and deactivates', capture.active === false && capture.size === 0 && capture.peek().length === 0);

  capture.begin();
  capture.add({ x: 5, y: 5 });
  const taken = capture.take();
  check('take hands off samples and resets', taken.length === 1 && capture.active === false && capture.size === 0);

  const spaced = ink.createStrokeCapture({ minWorldDistance: 1 });
  spaced.begin();
  check('minWorldDistance ignores near-duplicate samples', spaced.add({ x: 0, y: 0 }) && !spaced.add({ x: 0.4, y: 0 }) && spaced.add({ x: 2, y: 0 }));

  const inactive = ink.createStrokeCapture();
  check('inactive capture rejects samples', inactive.add({ x: 0, y: 0 }) === false);
}

// ---------------------------------------------------------------------------
// 5. Pointer routing: pen-only by default, finger only when enabled.
// ---------------------------------------------------------------------------
{
  check('pen always draws', ink.isDrawPointer('pen') === true && ink.isDrawPointer('pen', { drawWithFinger: false }) === true);
  check('touch does not draw by default', ink.isDrawPointer('touch') === false);
  check('touch draws only with the explicit finger switch', ink.isDrawPointer('touch', { drawWithFinger: true }) === true);
  check('mouse never draws', ink.isDrawPointer('mouse') === false && ink.isDrawPointer('mouse', { drawWithFinger: true }) === false);
}

// ---------------------------------------------------------------------------
// 6. Editor wiring contract: with a metadata-capable engine one Pen stroke is
//    exactly one atomic edit, and cancel / lost capture / close never commit.
//    Uses a minimal DOM shim; no browser or GUI automation is involved.
// ---------------------------------------------------------------------------
{
  const listeners = {};
  const windowListeners = {};
  const classList = () => {
    const set = new Set();
    return { add: c => set.add(c), remove: c => set.delete(c), contains: c => set.has(c), toggle: (c, on) => { const next = on === undefined ? !set.has(c) : !!on; next ? set.add(c) : set.delete(c); return next; } };
  };
  class El {
    constructor(tag = '#text') { this.tag = tag; this.children = []; this.parentElement = null; this.classList = classList(); this.style = {}; this.dataset = {}; this.attributes = {}; this.textContent = ''; this.hidden = false; this.disabled = false; this.isConnected = false; }
    append(...nodes) { for (const n of nodes) this.appendChild(n); }
    appendChild(node) { const n = node instanceof El ? node : Object.assign(new El(), { textContent: String(node) }); n.parentElement = this; n.isConnected = true; this.children.push(n); return n; }
    insertBefore(node, ref) { const n = node instanceof El ? node : Object.assign(new El(), { textContent: String(node) }); n.parentElement = this; n.isConnected = true; const at = ref == null ? this.children.length : this.children.indexOf(ref); this.children.splice(at < 0 ? this.children.length : at, 0, n); return n; }
    replaceChildren(...nodes) { this.children = []; this.append(...nodes); }
    remove() { const at = this.parentElement?.children.indexOf(this) ?? -1; if (at >= 0) this.parentElement.children.splice(at, 1); this.parentElement = null; this.isConnected = false; }
    setAttribute(k, v) { this.attributes[k] = String(v); }
    getAttribute(k) { return this.attributes[k] ?? null; }
    addEventListener(t, fn) { (this._listeners ??= {})[t] = (this._listeners[t] ?? []).concat(fn); }
    removeEventListener(t, fn) { this._listeners[t] = (this._listeners?.[t] ?? []).filter(f => f !== fn); }
    closest(sel) { let node = this; while (node) { if (sel.split(',').some(s => s.trim().replace(/^\./, '') === node.tag || node.className?.split(/\s+/).includes(s.trim().replace(/^\./, '')))) return node; node = node.parentElement; } return null; }
    getContext() { return { setTransform() {}, clearRect() {}, beginPath() {}, moveTo() {}, lineTo() {}, stroke() {} }; }
    getBoundingClientRect() { return { left: 0, top: 0, width: this.clientWidth ?? 0, height: this.clientHeight ?? 0 }; }
  }
  class FakeOption extends El { constructor(text, value) { super('option'); this.textContent = text; this.value = value; } }

  const header = new El('header');
  const body = new El('body');
  const documentShim = {
    body, createElement: tag => new El(tag), createTextNode: text => Object.assign(new El(), { textContent: String(text) }),
    querySelector: sel => sel === 'header' ? header : null,
    addEventListener: (t, fn) => { (listeners[t] ??= []).push(fn); },
    removeEventListener: (t, fn) => { listeners[t] = (listeners[t] ?? []).filter(f => f !== fn); },
  };
  const canvas = new El('canvas');
  canvas.clientWidth = 1000; canvas.clientHeight = 500; canvas.setPointerCapture = () => {};
  const host = new El('div'); host.append(canvas);
  const camera = { left: -200, right: 200, top: 100, bottom: -100, zoom: 1, position: { x: 0, y: 0 } };
  const viewerShim = {
    GetCanvas: () => canvas, GetCamera: () => camera, GetOrigin: () => ({ x: 0, y: 0 }),
    GetBounds: () => ({ minX: 0, maxX: 100, minY: 0, maxY: 100 }), SetView() {}, Render() {}, Subscribe() {}, Unsubscribe() {},
  };
  const previousGlobals = {
    document: globalThis.document, window: globalThis.window, Option: globalThis.Option, getComputedStyle: globalThis.getComputedStyle,
  };
  globalThis.document = documentShim;
  globalThis.Option = FakeOption;
  globalThis.getComputedStyle = () => ({ position: 'relative' });
  globalThis.window = {
    devicePixelRatio: 2,
    addEventListener: (t, fn) => { (windowListeners[t] ??= []).push(fn); },
    removeEventListener: (t, fn) => { windowListeners[t] = (windowListeners[t] ?? []).filter(f => f !== fn); },
    webkit: { messageHandlers: { floeEngineering: { postMessage: async () => {} } } },
  };
  const dispatch = (type, event) => { for (const fn of listeners[type] ?? []) fn(event); };
  const pointer = (type, over = {}) => {
    const event = { pointerType: 'pen', pointerId: 1, button: 0, clientX: 100, clientY: 100, target: canvas, preventDefault() {}, stopPropagation() { this.stopped = true; }, ...over };
    dispatch(type, event); return event;
  };
  const metadataInfo = { ...engineMetadata, format: 'dxf', entityCount: 0, offset: 0, entities: [], canUndo: false, canRedo: false };
  const calls = [];
  const engineStub = { call: async (operation, args) => { calls.push({ operation, args }); return { info: metadataInfo, dxf: new Uint8Array([1]) }; } };
  const { installCadEditor } = await import(load('cad-editor.js'));

  // Without metadata the Pen toggle must exist but stay disabled and inert.
  const gated = installCadEditor({ engine: engineStub, initial: { ...metadataInfo, capabilities: undefined }, render: async () => {}, viewer: viewerShim, zh: false, dark: false, onDirty() {} });
  const gatedPen = header.children.find(child => child.id === 'cadPen');
  check('wiring: Pen toggle exists next to Edit', !!gatedPen && header.children.filter(child => child.id).length === 2);
  check('wiring: Pen disabled without addStroke metadata', gatedPen.disabled === true);
  const beforeGated = calls.length;
  gatedPen.onclick();
  check('wiring: disabled Pen performs no edit', calls.length === beforeGated);
  gated.destroy();

  // With metadata a single captured pen stroke must be one addStroke edit.
  const editor = installCadEditor({ engine: engineStub, initial: metadataInfo, render: async () => {}, viewer: viewerShim, zh: false, dark: false, onDirty() {} });
  const pen = header.children.find(child => child.id === 'cadPen');
  check('wiring: Pen enabled with addStroke metadata', pen.disabled === false);
  pen.onclick();
  check('wiring: Pen reports pressed state', pen.getAttribute('aria-pressed') === 'true');
  pointer('pointerdown', { clientX: 100, clientY: 100 });
  const moved = pointer('pointermove', { clientX: 200, clientY: 100 });
  check('wiring: pen events are blocked from viewer drag', moved.stopped === true);
  pointer('pointermove', { clientX: 300, clientY: 200 });
  pointer('pointerup', { clientX: 300, clientY: 200 });
  await new Promise(resolve => setTimeout(resolve, 10));
  const edits = calls.filter(call => call.operation === 'edit');
  check('wiring: one stroke is exactly one atomic edit', edits.length === 1, JSON.stringify(calls));
  check('wiring: the edit is addStroke with bounded world points',
    edits[0]?.args?.edit?.operation === 'addStroke'
    && edits[0].args.edit.points.length >= 2 && edits[0].args.edit.points.length <= 256,
    JSON.stringify(edits[0]?.args));
  check('wiring: the edit carries the selected color and canonical width',
    edits[0]?.args?.edit?.color === 1 && edits[0]?.args?.edit?.lineWeight === 25);

  const beforeCancel = calls.length;
  pointer('pointerdown', { clientX: 100, clientY: 100 });
  pointer('pointermove', { clientX: 250, clientY: 180 });
  pointer('pointercancel', { clientX: 250, clientY: 180 });
  pointer('pointerdown', { clientX: 100, clientY: 100 });
  pointer('lostpointercapture', { clientX: 150, clientY: 150 });
  const panel = body.children.find(child => child.id === 'cadPanel');
  pointer('pointerdown', { clientX: 100, clientY: 100 });
  panel.children.find(child => child.textContent === 'Close').onclick();
  await new Promise(resolve => setTimeout(resolve, 10));
  check('wiring: cancel / lost capture / close never commit', calls.length === beforeCancel, String(calls.length - beforeCancel));

  editor.destroy();
  check('wiring: destroy disposes document listeners', (listeners.pointerdown ?? []).length === 0);

  // While an engine mutation is pending, ink and conflicting actions stay
  // disabled and a second stroke must not start.
  let resolvePending = null;
  const pendingCalls = [];
  const busyEngine = { call: operation => { pendingCalls.push(operation); return new Promise(resolve => { resolvePending = () => resolve({ info: metadataInfo, dxf: new Uint8Array([1]) }); }); } };
  const busyEditor = installCadEditor({ engine: busyEngine, initial: metadataInfo, render: async () => {}, viewer: viewerShim, zh: false, dark: false, onDirty() {} });
  const busyPen = header.children.find(child => child.id === 'cadPen');
  busyPen.onclick();
  pointer('pointerdown', { clientX: 100, clientY: 100 });
  pointer('pointermove', { clientX: 220, clientY: 140 });
  pointer('pointerup', { clientX: 220, clientY: 140 });
  check('wiring: pen disabled while a mutation is pending', busyPen.disabled === true);
  check('wiring: pending mutation started exactly once', pendingCalls.length === 1, String(pendingCalls.length));
  pointer('pointerdown', { clientX: 40, clientY: 40 });
  pointer('pointermove', { clientX: 60, clientY: 60 });
  pointer('pointerup', { clientX: 60, clientY: 60 });
  check('wiring: second stroke ignored while busy', pendingCalls.length === 1, String(pendingCalls.length));
  resolvePending();
  await new Promise(resolve => setTimeout(resolve, 10));
  check('wiring: busy clears and pen re-enables', busyPen.disabled === false);
  busyEditor.destroy();

  globalThis.document = previousGlobals.document;
  globalThis.window = previousGlobals.window;
  globalThis.Option = previousGlobals.Option;
  globalThis.getComputedStyle = previousGlobals.getComputedStyle;
}

// ---------------------------------------------------------------------------
// 7. The actually bundled engine: report and verify its truthful state.
// ---------------------------------------------------------------------------
let bundled = { capabilities: null, operations: null };
{
  const dxf = openFixture('sample-plate.dxf', 'dxf');
  const dwg = openFixture('sample-editable.dwg', 'dwg');
  const dxfInfo = inspect(dxf);
  const caps = ink.readStrokeCapabilities(dxfInfo);
  bundled = {
    capabilitiesSupported: caps.supported,
    pointCount: caps.pointCount ?? null,
    layer: caps.layer ?? null,
    addStrokeRejected: edit(dxf, { operation: 'addStroke', points: [[0, 0, 0], [1, 1, 0]] }),
  };
  bundled.operations = operationsFrom(bundled.addStrokeRejected);

  if (caps.supported) {
    // Rebuilt engine: the atomic one-stroke path must work end to end.
    const base = inspect(dwg).entityCount;
    const strokeRequest = ink.buildStrokeRequest(
      [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 10 }],
      { maxPoints: caps.pointCount.max, color: 1, lineWeight: 25 });
    const valid = ink.validateStrokeRequest(strokeRequest, caps);
    check('rebuilt engine: built request validates', valid.ok === true, JSON.stringify(valid));
    const error = edit(dwg, strokeRequest);
    check('rebuilt engine: one addStroke commits', error === null, String(error));
    const after = inspect(dwg);
    check('rebuilt engine: stroke adds points-1 segments', after.entityCount === base + 2, `${base}->${after.entityCount}`);
    dwg.undo();
    check('rebuilt engine: one undo removes the whole stroke', inspect(dwg).entityCount === base, String(inspect(dwg).entityCount));

    const invalidBase = inspect(dwg).entityCount;
    const invalid = edit(dwg, { operation: 'addStroke', points: [[1, 1, 0]] });
    check('rebuilt engine: single-point stroke is rejected', typeof invalid === 'string' && invalid.length > 0, String(invalid));
    check('rebuilt engine: rejected stroke leaves no partial', inspect(dwg).entityCount === invalidBase);
  } else {
    // Bundled old engine: metadata is absent, so ink must be gated off and the
    // operation must be rejected without mutating the drawing.
    const before = inspect(dwg).entityCount;
    check('bundled engine: ink readiness is gated off',
      ink.inkReadiness(dxfInfo).ready === false && ink.inkReadiness(dxfInfo).reason === 'capabilities-missing');
    check('bundled engine: addStroke is rejected as an unknown operation',
      typeof bundled.addStrokeRejected === 'string' && bundled.addStrokeRejected.includes('unknown variant'), String(bundled.addStrokeRejected));
    check('bundled engine: rejected ink did not mutate the drawing', inspect(dwg).entityCount === before);
  }

  const dwgInfo = inspect(dwg);
  check('dwg informational diagnostics do not block readiness',
    ink.hasBlockingDiagnostics(dwgInfo) === false
    && (caps.supported ? ink.inkReadiness(dwgInfo).ready === true : ink.inkReadiness(dwgInfo).reason === 'capabilities-missing'));
}

// ---------------------------------------------------------------------------
// Verdict
// ---------------------------------------------------------------------------
const capability = {
  engineOperations: bundled.operations,
  addStrokeMetadata: bundled.capabilitiesSupported,
  pointCount: bundled.pointCount,
  annotationLayer: bundled.layer,
  bundledInkReady: bundled.capabilitiesSupported,
};
console.log(`cad-ink: ${passes.length} passed, ${failures.length} failed`);
if (failures.length) {
  for (const failure of failures) console.log(`  FAIL ${failure}`);
}
console.log(`CAPABILITY ${JSON.stringify(capability)}`);
process.exit(failures.length ? 1 : 0);
