#!/usr/bin/env node
/*
 * Contract test for the Floe pen-input + live-ink overlay injected by
 * FloeAgent/ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm
 * (FLOE_INK_GATING_SCRIPT region).
 *
 * The script text is extracted from the .mm at run time, so the test always
 * exercises exactly what the native host injects. The harness models the
 * CURRENT production surface: window/document/canvas targets with
 * capture+bubble propagation, the ordered map._docLayer.postKeyboardEvent
 * Escape channel, per-type map.on subscriptions, a fake composited document
 * canvas (sectionContainer.context.getImageData) whose painted regions the
 * test controls in backing-pixel coordinates, deterministic timers and
 * animation frames, and the app.twipsToPixels/dpiScale zoom scale.
 *
 * Covered contracts:
 *  - armed/disarmed routing: the App arm dispatches the freehand tool once;
 *    down/move/up replay through the pinned canvas mouse path; every
 *    completed contact re-arms exactly once behind an ordered Escape pair;
 *    commandstatechanged observations (including 'disabled' and stale cache
 *    values) never decide whether the next contact draws and the cached
 *    getItemValue is never consulted at all;
 *  - finger pointer events on the canvas stay stopped during drawing while
 *    ordinary mouse and toolbar input keep working;
 *  - pinch regression fix: with drawing armed and no Pencil contact, canvas
 *    touchstart/touchmove/touchend/touchcancel are untouched, so the pinned
 *    CanvasSectionContainer receives the FIRST finger's touchstart and can
 *    hand two-finger gestures to its own ZoomControl; during an active
 *    Pencil contact touchstart/touchmove are blocked, a stray
 *    touchend/touchcancel is held while the container has no open gesture
 *    (its single-finger branch would truncate the live stroke) and an open
 *    pinch's touchend is delivered; the container's leftover
 *    touchEventInProgress flag must never swallow the next Pencil contact's
 *    canonical replay;
 *  - live ink presentation: the ongoing contact draws an SVG preview before
 *    pointerup using the bridge's last verified {color,width,transparency}
 *    mapped through twipsToPixels/dpiScale. The preview consumes exactly the
 *    trusted samples the canonical replay forwards: coalesced and predicted
 *    events must never be read (one shared geometry, no divergence).
 *    Constant engine-legal width only. The canonical replay is byte-identical
 *    with the preview available or unavailable;
 *  - handoff: the only eraser before the stroke vanishes is GEOMETRIC PAINT
 *    EVIDENCE — per-probe pre-release canvas snapshots along the stroke's
 *    own path plus pixels that moved toward that stroke's composited ink
 *    colour. ModifiedStatus (transition-based, may not fire per stroke and
 *    can arrive before the handoff exists) never clears. Overlapping and
 *    rapid contacts each keep their own pending path (bounded), so a second
 *    stroke cannot blink the first. Non-evidence exits are the honest
 *    bounded ones only: probe give-up, wall-clock deadline, unreadable
 *    canvas degrading to the deadline, overflow of the pending cap, resize,
 *    pagehide and the fail-closed path. Evidence ownership is adversarially
 *    checked: same-colour neighbour strokes (far and at overlap distance)
 *    can never cross-clear each other; only identical-geometry strokes are
 *    a documented, inherent ambiguity;
 *  - Writer page-TOP inset input compensation: in a text document the
 *    replayed pen stream's Y is shifted by the live page-1 top inset derived
 *    from app.file.writer.pageRectangleList (twips -> CSS through
 *    twipsToPixels/dpiScale), fixing the measured real-App Word ghosting
 *    (engine anchored committed ink one page inset below the pen; see the
 *    gate comment and the 2026-10-19 handoff). X is replayed exactly raw even
 *    when the page-1 X origin is nonzero: the actual C5 App run measured
 *    19.3 CSS Word X drift (38.8 after pinch) because both axes had been
 *    subtracted. Preview and paint probes keep raw pen coordinates, so near
 *    evidence settles with no jump. The Y compensation fails open (absent,
 *    non-text, negative, oversized, non-finite, broken scale) and recomputes
 *    per contact; XLSX/PPTX streams stay byte-identical. No hardcoded pixel
 *    constant;
 *  - zero-move contact: the canonical replay for a tap is exactly
 *    mousedown+mouseup at the same point (no fabricated move) and the
 *    preview shows the dot path.
 *
 * History note (kept honestly): this file was stale against the production
 * gate between 6c964870 and this round. Its previous expectations of a
 * background subscribe/retry chain and getItemValue seeding describe the
 * removed pre-continuous-stroke design and failed 7 checks and crashed once
 * against the shipped script (retained in
 * Local/Private/ios-closure-20261018/pencil-live-input/pen-mjs-original-failures.log).
 * The rewrite preserves every still-valid rejection/handle/re-arm semantic
 * in current production terms; it weakens nothing silently.
 *
 * This is a frontend contract test. It is not a device Pencil proof: pressure,
 * haptics, real WebKit pointer/touch interop and actual pixel paint stay with
 * device acceptance; scripts/office_pen_real_dom_acceptance.js documents the
 * real-DOM -> core acceptance path for the integration owner.
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const mmPath = join(repoRoot, 'ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm');
const mm = readFileSync(mmPath, 'utf8');
const begin = mm.indexOf('// FLOE_INK_GATING_SCRIPT_BEGIN');
const end = mm.indexOf('// FLOE_INK_GATING_SCRIPT_END');
if (begin < 0 || end < 0) throw new Error('ink gating script markers not found');
const region = mm.slice(begin, end);
const open = region.indexOf('R"FLOE_JS(');
const close = region.lastIndexOf(')FLOE_JS"');
if (open < 0 || close < 0) throw new Error('raw JS literal not found');
const script = region.slice(open + 'R"FLOE_JS('.length, close);
if (!script.includes('__floePencilOnly')) throw new Error('extracted script looks wrong');

let failures = 0;
let checks = 0;
const check = (name, ok, detail = '') => {
  checks += 1;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`);
  if (!ok) failures += 1;
};

class Target {
  constructor(name, parent = null) {
    this.name = name;
    this.tagName = name;
    this.parent = parent;
    this.children = [];
    this.listeners = [];
    this.attrs = {};
  }
  addEventListener(type, fn, options) {
    this.listeners.push({ type, fn, capture: !!(options && options.capture) });
  }
  removeEventListener(type, fn) {
    this.listeners = this.listeners.filter((l) => !(l.type === type && l.fn === fn));
  }
  setAttribute(name, value) { this.attrs[name] = String(value); }
  getAttribute(name) { return this.attrs[name] === undefined ? null : this.attrs[name]; }
  appendChild(child) { child.parent = this; this.children.push(child); return child; }
  removeChild(child) {
    const i = this.children.indexOf(child);
    if (i >= 0) this.children.splice(i, 1);
    child.parent = null;
    return child;
  }
  remove() { if (this.parent) this.parent.removeChild(this); }
  querySelector() { return null; }
  contains(node) {
    for (let n = node; n; n = n.parent) if (n === this) return true;
    return false;
  }
  get paths() { return this.children.filter((c) => c.tagName === 'path'); }
  dispatchEvent(event) { return this.dispatch(event); }
  dispatch(event) {
    const chain = [];
    for (let node = this; node; node = node.parent) chain.unshift(node);
    event.target = this;
    for (const node of chain) {
      for (const listener of node.listeners.slice()) {
        if (listener.type !== event.type || !listener.capture || event.stopped) continue;
        listener.fn(event);
        if (event.stoppedImmediate) break;
      }
      if (event.stoppedImmediate) break;
    }
    if (!event.stopped && !event.stoppedImmediate) {
      for (const listener of this.listeners.slice()) {
        if (listener.type === event.type && !listener.capture) listener.fn(event);
      }
    }
    for (const node of chain.reverse().slice(1)) {
      if (event.stopped) break;
      for (const listener of node.listeners.slice()) {
        if (listener.type === event.type && !listener.capture) listener.fn(event);
      }
    }
    return !event.defaultPrevented;
  }
}

const makeEvent = (type, extra = {}) => ({
  type,
  pointerType: '',
  pointerId: 0,
  clientX: 0,
  clientY: 0,
  stopped: false,
  stoppedImmediate: false,
  defaultPrevented: false,
  stopPropagation() { this.stopped = true; },
  stopImmediatePropagation() { this.stopped = true; this.stoppedImmediate = true; },
  preventDefault() { this.defaultPrevented = true; },
  ...extra,
});

const CSS_PER_TWIP = 0.1; // app.twipsToPixels 0.2 / app.dpiScale 2 in this world
const MM100 = (mm100) => (mm100 / 100) * (1440 / 25.4) * CSS_PER_TWIP;
const RED = [255, 0, 0];
const GREEN = [0, 255, 0];
const BLACK = [0, 0, 0];

function newWorld(options = {}) {
  const windowTarget = new Target('window');
  const document = new Target('document', windowTarget);
  const documentElement = new Target('html', document);
  document.appendChild(documentElement);
  document.documentElement = documentElement; // what the production script reads
  const canvas = new Target('canvas', document);
  document.appendChild(canvas);
  const toolbar = new Target('toolbar', document);
  document.appendChild(toolbar);
  document.readyState = 'complete';
  document.querySelector = () => canvas;
  document.createElement = (tag) => new Target(tag);
  if (!options.noCreateElementNS)
    document.createElementNS = (ns, tag) => new Target(tag);

  // Deterministic time and frames.
  let now = 0;
  let timerId = 0;
  const timers = new Map();
  const setTimeoutFake = (fn, delay) => {
    const id = ++timerId;
    timers.set(id, { at: now + (delay || 0), fn });
    return id;
  };
  const clearTimeoutFake = (id) => { timers.delete(id); };
  const advanceTimers = (ms) => {
    now += ms;
    const due = [...timers.entries()].filter(([, t]) => t.at <= now)
      .sort((a, b) => a[1].at - b[1].at);
    for (const [id, t] of due) {
      if (!timers.delete(id)) continue;
      t.fn();
    }
  };
  const frames = [];
  windowTarget.requestAnimationFrame = (fn) => { frames.push(fn); return frames.length; };
  const pumpFrames = (count = 1) => {
    for (let i = 0; i < count; i += 1) {
      const queued = frames.splice(0, frames.length);
      for (const fn of queued) fn();
    }
  };

  // Fake composited document canvas. paintArea marks BACKING-pixel regions
  // that "the engine" has painted with the given colour; getImageData
  // reflects them. The gate's handoff probe must observe movement toward
  // its own stroke's composited ink colour, not merely "something changed".
  const painted = []; // {x0, y0, x1, y1, rgb}
  const context = options.noContext ? null : {
    getImageData: (x, y, w, h) => {
      if (w <= 0 || h <= 0) throw new Error('bad rect');
      const data = new Uint8ClampedArray(w * h * 4);
      for (let py = 0; py < h; py += 1) {
        for (let px = 0; px < w; px += 1) {
          let rgb = null;
          for (const region of painted) {
            if (x + px >= region.x0 && x + px <= region.x1
                && y + py >= region.y0 && y + py <= region.y1) rgb = region.rgb;
          }
          const i = (py * w + px) * 4;
          data[i] = rgb ? rgb[0] : 255;
          data[i + 1] = rgb ? rgb[1] : 255;
          data[i + 2] = rgb ? rgb[2] : 255;
          data[i + 3] = 255;
        }
      }
      return { data };
    },
  };
  canvas.getBoundingClientRect = () => ({ left: 0, top: 0, right: 600, bottom: 800, width: 600, height: 800 });
  canvas.width = 1200; // backing scale = 2 in this world
  canvas.height = 1600;
  if (!options.noGetContext)
    canvas.getContext = () => context;

  // The pinned container is inspectable; this world's document has no stale
  // graphic selection by default (individual tests install their own).
  const sectionContainer = {
    canvas,
    context,
    getSectionWithName: () => null,
  };
  const keyboardEvents = [];
  const uno = [];
  const handlers = {};
  const map = {
    sendUnoCommand: (cmd) => { uno.push(cmd); },
    on: (name, fn) => { (handlers[name] = handlers[name] || []).push(fn); },
    off: (name, fn) => {
      const list = handlers[name] || [];
      const i = list.indexOf(fn);
      if (i >= 0) list.splice(i, 1);
    },
    isEditMode: () => true,
    getContainer: () => null,
    _docLayer: options.noDocLayer ? null : {
      postKeyboardEvent: (kind, char, key) => { keyboardEvents.push([kind, key]); },
    },
    stateChangeHandler: {
      getItemValue: () => {
        cacheReads += 1; // the production gate must never consult the stale cache
        return 'true';
      },
    },
  };
  let cacheReads = 0;
  windowTarget.app = {
    map,
    sectionContainer,
    dpiScale: 2,
    twipsToPixels: 0.2,
    activeDocument: { getZoomPercent: () => 100 },
    CSections: { ShapeHandlesSection: { name: 'shapeHandlesSection' } },
    definitions: { graphicSelection: { handlesSection: null } },
  };
  if (options.noMap) delete windowTarget.app.map;

  class MouseEvent {
    constructor(type, init = {}) {
      this.type = type;
      this.bubbles = !!init.bubbles;
      this.cancelable = !!init.cancelable;
      this.clientX = init.clientX;
      this.clientY = init.clientY;
      this.button = init.button;
      this.buttons = init.buttons;
      this.stopped = false;
      this.stoppedImmediate = false;
      this.defaultPrevented = false;
      this.stopPropagation = () => { this.stopped = true; };
      this.stopImmediatePropagation = () => { this.stopped = true; this.stoppedImmediate = true; };
      this.preventDefault = () => { this.defaultPrevented = true; };
    }
  }

  new Function('window', 'document', 'MouseEvent', 'setTimeout', 'clearTimeout', script)(
    windowTarget, document, MouseEvent, setTimeoutFake, clearTimeoutFake);

  let pointerId = 900;
  const world = {
    window: windowTarget, document, documentElement, canvas, toolbar, map, uno,
    keyboardEvents, handlers, advanceTimers, pumpFrames, sectionContainer,
    get cacheReads() { return cacheReads; },
    // Paint a backing-pixel band (radius 24) around each client-space point.
    paintArea: (points, rgb = RED) => {
      for (const [cx, cy] of points) {
        const bx = cx * 2, by = cy * 2;
        painted.push({ x0: bx - 24, y0: by - 24, x1: bx + 24, y1: by + 24, rgb });
      }
    },
    pen: (type, x = 10, y = 20, target = canvas, extra = {}) =>
      target.dispatch(makeEvent(type, {
        pointerType: 'pen', pointerId: extra.pointerId === undefined ? pointerId : extra.pointerId,
        clientX: x, clientY: y, ...extra,
      })),
    touch: (type, target = canvas) => {
      const event = makeEvent(type, { pointerType: 'touch' });
      target.dispatch(event);
      return event;
    },
    stateChanged: (value, name = 'Freeline_Unfilled') => {
      for (const fn of (handlers.commandstatechanged || []).slice())
        fn({ commandName: `.uno:${name}`, state: value });
    },
    arm: () => { windowTarget.__floePencilOnly = true; },
    state: () => windowTarget.__floeOfficePenState(),
    preview: () => windowTarget.__floeOfficePenPreview(),
    // A deterministic contact: fresh pointerId, caller's points, trusted
    // events only. Returns the point list it used.
    strokeAt: (points) => {
      const id = ++pointerId;
      world.pen('pointerdown', points[0][0], points[0][1], canvas, { pointerId: id });
      for (let i = 1; i < points.length; i += 1)
        world.pen('pointermove', points[i][0], points[i][1], canvas, { pointerId: id });
      const last = points[points.length - 1];
      world.pen('pointerup', last[0], last[1], canvas, { pointerId: id });
      return points;
    },
    stroke: (moves = 1, base = [10, 20]) =>
      world.strokeAt(Array.from({ length: moves + 1 },
        (_, i) => [base[0] + i * 8, base[1] + i * 4])),
  };
  return world;
}

const recordedMouse = (world) => {
  const seen = [];
  const wrapCanvas = world.canvas.dispatch.bind(world.canvas);
  world.canvas.dispatch = (event) => {
    if (['mousedown', 'mousemove', 'mouseup'].includes(event.type)) seen.push(event);
    return wrapCanvas(event);
  };
  const wrapDocument = world.document.dispatch.bind(world.document);
  world.document.dispatch = (event) => {
    if (['mousemove', 'mouseup'].includes(event.type)) seen.push(event);
    return wrapDocument(event);
  };
  return seen;
};

const overlayPaths = (world) => {
  const layer = world.documentElement.children
    .find((c) => c.id === 'floe-ink-live-preview');
  if (!layer) return { layer: null, paths: [] };
  return { layer, paths: layer.children[0] ? layer.children[0].paths : [] };
};

const setStyle = (world, color, width, transparency) => {
  world.window.__floeOfficeInkLastDispatch = {
    token: 1, expected: { color, width, transparency },
  };
};

// --- routing / arming -------------------------------------------------------

// 1. Disarmed: a pen stroke must not touch the core at all.
{
  const w = newWorld();
  const seen = recordedMouse(w);
  w.stroke(1);
  check('disarmed/no-core-input', seen.length === 0 && w.uno.length === 0,
    `canvas=${seen.length} uno=${w.uno.length}`);
}

// 2. Arm dispatches the tool exactly once; the first contact re-dispatches
//    nothing on down; the completed contact re-arms exactly once behind an
//    ordered Escape input+up pair.
{
  const w = newWorld();
  const seen = recordedMouse(w);
  w.arm();
  check('arm/one-dispatch-one-escape-pair',
    w.uno.length === 1 && w.uno[0] === '.uno:Freeline_Unfilled'
    && w.keyboardEvents.length === 2
    && w.keyboardEvents[0][0] === 'input' && w.keyboardEvents[0][1] === 1281
    && w.keyboardEvents[1][0] === 'up' && w.keyboardEvents[1][1] === 1281,
    JSON.stringify({ uno: w.uno, keys: w.keyboardEvents.length }));
  w.pen('pointerdown', 12, 14, w.canvas, { pointerId: 11 });
  check('down/no-new-dispatch', w.uno.length === 1, JSON.stringify(w.uno));
  check('down/mousedown-carries-coordinates-and-buttons',
    seen.length === 1 && seen[0].type === 'mousedown'
    && seen[0].clientX === 12 && seen[0].clientY === 14 && seen[0].buttons === 1,
    JSON.stringify(seen.map((e) => [e.type, e.buttons])));
  w.pen('pointermove', 16, 18, w.canvas, { pointerId: 11 });
  w.pen('pointerup', 18, 20, w.canvas, { pointerId: 11 });
  check('up/exactly-one-rearm-after-completed-contact',
    w.uno.length === 2 && w.uno[1] === '.uno:Freeline_Unfilled'
    && w.keyboardEvents.length === 4, JSON.stringify(w.uno));
  check('strokes-counted-and-armed',
    w.state().strokes === 1 && w.state().armedDispatches === 2, JSON.stringify(w.state()));
  const move = seen.find((e) => e.type === 'mousemove');
  const up = seen.find((e) => e.type === 'mouseup');
  check('geometry/move-and-up-replay-once-with-button-state',
    seen.length === 3 && move.buttons === 1 && up.buttons === 0,
    JSON.stringify(seen.map((e) => [e.type, e.buttons])));
}

// 3. commandstatechanged never decides drawing: availability strings, an
//    observed inactive state and stale cache values cannot suppress or
//    duplicate re-arming; the cache itself is never read. ModifiedStatus
//    reports (any order, even before pointerup) must not clear a preview.
{
  const w = newWorld();
  w.arm();
  w.stateChanged('disabled');
  w.stateChanged(false);
  w.stateChanged(true, 'Freeline');
  w.stroke(1);
  w.stateChanged(true, 'ModifiedStatus'); // already-dirty document noise
  w.stroke(1);
  check('observation/never-gates-rearm', w.uno.length === 3, JSON.stringify(w.uno));
  check('observation/strokes-still-post',
    w.state().strokes === 2 && w.state().coreEvents === 6, JSON.stringify(w.state()));
  check('cache/never-read', w.cacheReads === 0, String(w.cacheReads));
  w.advanceTimers(1200); // the old buggy 1200 ms model-armed cap must not exist
  check('modified/never-clears-preview', w.preview().pending === 2,
    JSON.stringify(w.preview()));
}

// --- finger/mouse arbitration -----------------------------------------------

// 4. Finger pointer events on the canvas stay stopped during drawing while
//    toolbar fingers and ordinary mouse pointers pass, and none may draw.
{
  const w = newWorld();
  const seen = recordedMouse(w);
  w.arm();
  const down = makeEvent('pointerdown', { pointerType: 'touch' });
  w.canvas.dispatch(down);
  const move = makeEvent('pointermove', { pointerType: 'touch' });
  w.canvas.dispatch(move);
  const bar = makeEvent('pointerdown', { pointerType: 'touch' });
  w.toolbar.dispatch(bar);
  const mouseDown = makeEvent('pointerdown', { pointerType: 'mouse' });
  w.canvas.dispatch(mouseDown);
  check('finger/canvas-pointer-stopped', down.stopped && down.defaultPrevented
    && move.stopped, JSON.stringify({ d: down.defaultPrevented, m: move.defaultPrevented }));
  check('finger/toolbar-pointer-passes', !bar.stopped && !bar.defaultPrevented);
  check('mouse/pointer-passes-gate', !mouseDown.stopped);
  check('finger/no-core-replay', seen.length === 0 && w.uno.length === 1, JSON.stringify(w.uno));
}

// 5. Pinch regression: with drawing armed and NO Pencil contact, all four
//    canvas touch types are untouched so the pinned CanvasSectionContainer
//    sees the first finger's touchstart and routes gestures to ZoomControl.
{
  const w = newWorld();
  w.arm();
  const results = ['touchstart', 'touchmove', 'touchend', 'touchcancel']
    .map((t) => w.touch(t));
  check('pinch/idle-canvas-touches-untouched',
    results.every((e) => !e.stopped && !e.defaultPrevented),
    JSON.stringify(results.map((e) => [e.stopped, e.defaultPrevented])));
  const second = ['touchstart', 'touchmove'].map((t) => w.touch(t));
  check('pinch/still-untouched-after-two-finger-sequence',
    second.every((e) => !e.stopped && !e.defaultPrevented));
}

// 6. During an active Pencil contact: canvas touchstart/touchmove are
//    blocked. A stray touchend/touchcancel (the container has no open
//    multi-touch gesture) is held, because the pinned single-finger
//    onTouchEnd branch would propagate a mouse-up into the live replayed
//    stroke; when a real pinch IS open (container.multiTouch === true) the
//    touchend must pass so the gesture state can close.
{
  const w = newWorld();
  const seen = recordedMouse(w);
  w.arm();
  w.pen('pointerdown', 10, 12, w.canvas, { pointerId: 21 });
  const ts = w.touch('touchstart');
  const tm = w.touch('touchmove');
  const te = w.touch('touchend');
  const tc = w.touch('touchcancel');
  check('contact/touchstart-and-touchmove-blocked', ts.stopped && tm.defaultPrevented,
    JSON.stringify({ ts: ts.stopped, tm: tm.defaultPrevented }));
  check('contact/stray-touchend-held-while-no-gesture-open',
    te.stopped && tc.stopped, JSON.stringify({ te: te.stopped, tc: tc.stopped }));
  w.sectionContainer.multiTouch = true; // a pinch the container opened
  const openTe = w.touch('touchend');
  check('contact/open-gesture-touchend-delivered',
    !openTe.stopped && !openTe.defaultPrevented, JSON.stringify({ s: openTe.stopped }));
  w.sectionContainer.multiTouch = false;
  w.pen('pointercancel', 10, 12, w.canvas, { pointerId: 21 });
  check('contact/pen-stream-survives-finger-noise',
    seen.filter((e) => e.type === 'mousedown').length === 1);
  // After the contact ends, touches flow again for the next pinch.
  const after = w.touch('touchstart');
  check('contact/flow-resumes-after-contact', !after.stopped && !after.defaultPrevented);
}

// 6b. Touch -> Pencil transition: a finished finger gesture leaves the
//     pinned container with touchEventInProgress=true (its onTouchEnd line
//     1558) and the container's own mouse path only clears that flag behind
//     the flag-gated branch. The whole next Pencil contact's replayed
//     mousedown/mousemove/mouseup must still reach the canonical surface:
//     the gate restores exactly that one boolean before each replay and
//     never fabricates a touch/click/reset event.
{
  const w = newWorld();
  const seen = recordedMouse(w);
  w.arm();
  // Simulate the exact state the pinned container keeps after
  // first finger -> second finger -> pinch moves -> touchend.
  w.sectionContainer.touchEventInProgress = true;
  w.pen('pointerdown', 10, 10, w.canvas, { pointerId: 22 });
  check('transition/down-replays-and-recovers',
    seen.length === 1 && seen[0].type === 'mousedown'
    && w.sectionContainer.touchEventInProgress === false,
    JSON.stringify({ seen: seen.length, flag: w.sectionContainer.touchEventInProgress }));
  // A stray finger lifts mid-stroke and re-sets the flag: the following
  // move/up replays must each recover it again, keeping one stroke intact.
  w.sectionContainer.touchEventInProgress = true;
  w.pen('pointermove', 16, 14, w.canvas, { pointerId: 22 });
  check('transition/move-replays-and-recovers',
    seen.length === 2 && seen[1].type === 'mousemove'
    && w.sectionContainer.touchEventInProgress === false);
  w.sectionContainer.touchEventInProgress = true;
  w.pen('pointerup', 20, 16, w.canvas, { pointerId: 22 });
  check('transition/up-replays-and-recovers',
    seen.length === 3 && seen[2].type === 'mouseup'
    && w.sectionContainer.touchEventInProgress === false
    && w.state().strokes === 1, JSON.stringify(w.state()));
}

// 7. Contacts must start on the canvas; toolbar and body are not ink. An
//    in-progress stroke may leave the canvas and still finish.
{
  const w = newWorld();
  const seen = recordedMouse(w);
  w.arm();
  const barDown = makeEvent('pointerdown', { pointerType: 'pen', pointerId: 31, clientX: 5, clientY: 5 });
  w.toolbar.dispatch(barDown);
  w.pen('pointermove', 6, 6, w.toolbar, { pointerId: 31 });
  w.pen('pointerup', 7, 7, w.toolbar, { pointerId: 31 });
  check('hit/toolbar-pen-is-not-ink',
    seen.length === 0 && !barDown.stopped && !barDown.defaultPrevented);
  const bodyDown = makeEvent('pointerdown', { pointerType: 'pen', pointerId: 32 });
  w.document.dispatch(bodyDown);
  check('hit/outside-canvas-down-is-not-ink', seen.length === 0 && !bodyDown.defaultPrevented);
  w.pen('pointerdown', 30, 40, w.canvas, { pointerId: 33 });
  w.pen('pointermove', 34, 44, w.toolbar, { pointerId: 33 });
  w.pen('pointerup', 36, 46, w.toolbar, { pointerId: 33 });
  check('hit/stroke-may-end-outside-canvas', w.state().strokes === 1, JSON.stringify(w.state()));
}

// 8. Ownership: another pointer cannot move or end the live contact.
{
  const w = newWorld();
  w.arm();
  w.pen('pointerdown', 10, 10, w.canvas, { pointerId: 41 });
  w.pen('pointermove', 20, 20, w.canvas, { pointerId: 42 });
  w.pen('pointerup', 25, 25, w.canvas, { pointerId: 42 });
  check('ownership/other-id-keeps-stroke-active',
    w.state().activeStroke === true && w.state().strokes === 0, JSON.stringify(w.state()));
  w.pen('pointerup', 30, 30, w.canvas, { pointerId: 41 });
  check('ownership/owning-id-completes',
    w.state().activeStroke === false && w.state().strokes === 1, JSON.stringify(w.state()));
}

// 9. Late map: with no map the arm fails closed and honestly; once the map
//    exists, arming succeeds and strokes flow (production has no background
//    subscribe chain any more — the old seeded/retry expectations are
//    superseded by the continuous-stroke re-arm design).
{
  const w = newWorld({ noMap: true });
  check('late-map/arm-fails-closed', w.window.__floeSetOfficeDrawingMode(true) === false
    && w.state().drawing === false && w.state().error === 'engine-unavailable',
    JSON.stringify(w.state()));
  w.window.app.map = w.map;
  check('late-map/recovers-after-map-arrives',
    w.window.__floeSetOfficeDrawingMode(true) === true && w.state().drawing === true);
  w.stroke(1);
  check('late-map/stroke-completes-after-recovery', w.state().strokes === 1,
    JSON.stringify(w.state()));
}

// --- live ink preview --------------------------------------------------------

// 10. The preview surface is created lazily (nothing before a contact) and
//     the ongoing contact draws before pointerup with the verified style at
//     the current zoom.
{
  const w = newWorld();
  w.arm();
  check('preview/no-surface-before-contact', overlayPaths(w).layer === null);
  setStyle(w, 0xFF0000, 150, 60);
  w.pen('pointerdown', 10, 20, w.canvas, { pointerId: 51 });
  const first = overlayPaths(w);
  check('preview/surface-on-down', !!first.layer && first.paths.length === 1);
  check('preview/style-color-width-opacity',
    first.paths[0].attrs.stroke === '#ff0000'
    && first.paths[0].attrs['stroke-width'] === String(MM100(150))
    && first.paths[0].attrs['stroke-opacity'] === '0.4'
    && first.paths[0].attrs.fill === 'none'
    && first.paths[0].attrs['stroke-linecap'] === 'round',
    JSON.stringify(first.paths[0].attrs));
  check('preview/single-point-dot-visible', /M10\.0 20\.0 L10\.1 20\.0$/.test(w.preview().d), w.preview().d);
  w.pen('pointermove', 14, 24, w.canvas, { pointerId: 51 });
  w.pumpFrames(1);
  w.pen('pointermove', 18, 28, w.canvas, { pointerId: 51 });
  w.pumpFrames(1);
  const live = w.preview();
  check('preview/ink-before-pointerup',
    live.stroke === true && live.points === 3 && /M10\.0 20\.0 L14\.0 24\.0 L18\.0 28\.0/.test(live.d),
    JSON.stringify({ p: live.points, d: live.d }));
  check('preview/activeStroke-true-while-down', w.state().activeStroke === true);
}

// 11. One geometry: the preview consumes EXACTLY the trusted samples the
//     canonical replay forwards. Coalesced intermediates (which the core
//     never receives) and predicted events must not be read at all, so the
//     live line can never diverge from the eventual engine vector.
{
  const w = newWorld();
  const seen = recordedMouse(w);
  w.arm();
  setStyle(w, 0x00FF00, 100, 0);
  let coalescedRead = 0;
  let predictedRead = 0;
  w.pen('pointerdown', 10, 20, w.canvas, { pointerId: 61 });
  w.canvas.dispatch(makeEvent('pointermove', {
    pointerType: 'pen', pointerId: 61, clientX: 13, clientY: 23,
    getCoalescedEvents: () => { coalescedRead += 1; return [
      makeEvent('pointermove', { clientX: 11, clientY: 21 }),
      makeEvent('pointermove', { clientX: 12, clientY: 22 }),
    ]; },
    getPredictedEvents: () => { predictedRead += 1; return [makeEvent('pointermove', { clientX: 99, clientY: 99 })]; },
  }));
  w.pumpFrames(1);
  w.pen('pointerup', 13, 23, w.canvas, { pointerId: 61 });
  check('coalesced/never-read', coalescedRead === 0, String(coalescedRead));
  check('predicted/never-read', predictedRead === 0, String(predictedRead));
  const canonical = seen.filter((e) => e.type === 'mousedown' || e.type === 'mousemove')
    .map((e) => [e.clientX, e.clientY]);
  const drawn = [[10, 20], [13, 23]];
  check('geometry/preview-equals-canonical-samples',
    JSON.stringify(canonical) === JSON.stringify(drawn), JSON.stringify(canonical));
  check('geometry/d-string-matches-trusted-path',
    w.preview().pending === 1 && w.state().coreEvents === 3, JSON.stringify(w.state()));
}

// 12. Style discipline: no last dispatch falls back to the documented pen
//     default unverified; garbage expected values are rejected, never trusted.
{
  const w = newWorld();
  w.arm();
  w.pen('pointerdown', 10, 10, w.canvas, { pointerId: 71 });
  const fallback = w.preview().style;
  check('style/default-pen-fallback',
    fallback.color === '#000000' && fallback.cssPx === MM100(50)
    && fallback.opacity === 1 && fallback.verified === false, JSON.stringify(fallback));
  const w2 = newWorld();
  w2.arm();
  setStyle(w2, 1.5, 700, 101); // non-integer color, out-of-range width/transparency
  w2.pen('pointerdown', 10, 10, w2.canvas, { pointerId: 72 });
  check('style/invalid-expected-rejected',
    w2.preview().style.verified === false && w2.preview().style.color === '#000000',
    JSON.stringify(w2.preview().style));
}

// 13. The zoom mapping reacts to the frontend scale, not to a synthetic
//     constant: halving twipsToPixels halves the CSS width.
{
  const w = newWorld();
  w.arm();
  setStyle(w, 0x000000, 200, 0);
  w.window.app.twipsToPixels = 0.1;
  w.pen('pointerdown', 10, 10, w.canvas, { pointerId: 81 });
  check('zoom/width-follows-twipsToPixels',
    w.preview().style.cssPx === (2.0 * (1440 / 25.4) * (0.1 / 2)),
    JSON.stringify(w.preview().style));
}

// 14. Invalid coordinates: a NaN contact point draws no preview but still
//     replays canonical input exactly once (presentation is best-effort).
{
  const w = newWorld();
  const seen = recordedMouse(w);
  w.arm();
  w.pen('pointerdown', NaN, 20, w.canvas, { pointerId: 91 });
  check('invalid/no-preview-for-nan-down', w.preview().stroke === false);
  check('invalid/canonical-still-replays',
    seen.length === 1 && seen[0].type === 'mousedown', JSON.stringify(seen.map((e) => e.type)));
  w.pen('pointermove', 12, 22, w.canvas, { pointerId: 91 });
  w.pen('pointerup', 14, 24, w.canvas, { pointerId: 91 });
  check('invalid/stroke-completes-without-preview',
    w.state().strokes === 1 && w.preview().pending === 0, JSON.stringify(w.state()));
}

// 15. Pathological long contact stays bounded and keeps the newest point.
{
  const w = newWorld();
  w.arm();
  w.pen('pointerdown', 0, 0, w.canvas, { pointerId: 101 });
  for (let i = 1; i <= 3100; i += 1)
    w.pen('pointermove', i % 600, i % 800, w.canvas, { pointerId: 101 });
  w.pumpFrames(1);
  const live = w.preview();
  check('bound/points-decimated', live.points <= 3000, String(live.points));
  check('bound/newest-point-kept', live.d.trim().endsWith('L100.0 700.0'), live.d.slice(-40));
}

// 16. Handoff on real geometric paint evidence only: after up the preview
//     survives (no blink), a repaint that moves the sampled pixels toward
//     THIS stroke's composited colour clears it. No ModifiedStatus needed —
//     an already-dirty document never reports per stroke.
{
  const w = newWorld();
  w.arm();
  setStyle(w, 0xFF0000, 150, 0);
  const pts = w.strokeAt([[100, 100], [150, 120], [200, 140]]);
  check('handoff/kept-after-up',
    w.preview().pending === 1 && overlayPaths(w).paths.length === 1
    && w.state().previewHandoffs === 1, JSON.stringify(w.preview()));
  w.pumpFrames(2); // probe ticks with white evidence: must not clear
  check('handoff/survives-without-paint', w.preview().pending === 1);
  w.paintArea(pts); // engine painted this stroke's own geometry
  w.pumpFrames(2);
  check('handoff/cleared-on-painted', w.preview().pending === 0
    && overlayPaths(w).paths.length === 0 && w.state().lastPreviewClear === 'painted',
    JSON.stringify(w.state()));
  check('handoff/stroke-counted', w.state().strokes === 1 && w.state().activeStroke === false);
}

// 17. Decoy repaint (wrong colour) is not evidence: an unrelated dark
//     repaint over the same area must not fake completion.
{
  const w = newWorld();
  w.arm();
  setStyle(w, 0xFF0000, 150, 0);
  const pts = w.strokeAt([[100, 100], [150, 120], [200, 140]]);
  w.paintArea(pts, BLACK); // black caret/UI-style repaint over red's probes
  w.pumpFrames(6);
  check('evidence/wrong-colour-not-painted', w.preview().pending === 1,
    JSON.stringify(w.preview()));
  w.paintArea(pts, RED);
  w.pumpFrames(2);
  check('evidence/right-colour-clears', w.preview().pending === 0
    && w.state().lastPreviewClear === 'painted');
}

// 18. Rapid overlapping strokes: completed contacts coexist; a new contact
//     never drops a pending handoff (no blink), and each clears on its own
//     paint. Style-alpha overlap: two half-transparent strokes overlapping
//     in space clear only on their own composited colour.
{
  const w = newWorld();
  w.arm();
  setStyle(w, 0xFF0000, 400, 60); // semi-transparent thick red
  const a = w.strokeAt([[100, 100], [200, 140]]);
  setStyle(w, 0x00FF00, 400, 60); // overlapping green
  const bPts = [[150, 130], [250, 170]];
  w.pen('pointerdown', bPts[0][0], bPts[0][1], w.canvas, { pointerId: 111 });
  check('overlap/new-down-keeps-prior-handoff',
    w.preview().pending === 1 && overlayPaths(w).paths.length === 2,
    JSON.stringify({ p: w.preview().pending, paths: overlayPaths(w).paths.length }));
  w.pen('pointermove', bPts[1][0], bPts[1][1], w.canvas, { pointerId: 111 });
  w.pen('pointerup', bPts[1][0], bPts[1][1], w.canvas, { pointerId: 111 });
  check('overlap/two-pending-handoffs', w.preview().pending === 2
    && w.state().previewHandoffs === 2, JSON.stringify(w.preview()));
  w.paintArea(a, [255, 153, 153]); // stroke A's red 40% composited over white
  w.pumpFrames(2);
  const state = w.preview();
  check('overlap/red-clears-green-waits',
    state.pending === 1 && state.probes.length === 1
    && overlayPaths(w).paths.length === 1, JSON.stringify(state));
  w.paintArea(bPts, [153, 255, 153]); // stroke B's green 40% composite
  w.pumpFrames(2);
  check('overlap/both-cleared-independently', w.preview().pending === 0
    && overlayPaths(w).paths.length === 0 && w.state().previewClears === 2,
    JSON.stringify(w.state()));
}

// 19. Delayed paint: evidence past the old 24-frame blind window still
//     clears; the probe keeps running with a bounded stride.
{
  const w = newWorld();
  w.arm();
  setStyle(w, 0xFF0000, 150, 0);
  const pts = w.strokeAt([[300, 300], [350, 320], [400, 340]]);
  w.pumpFrames(40); // beyond every-frame window; old build had stopped probing
  check('delayed/still-pending-frames-40', w.preview().pending === 1
    && w.preview().probes[0].frames >= 40, JSON.stringify(w.preview().probes));
  w.paintArea(pts);
  w.pumpFrames(8); // next stride tick is <=4 frames away
  check('delayed/late-paint-clears', w.preview().pending === 0
    && w.state().lastPreviewClear === 'painted', JSON.stringify(w.preview()));
}

// 20. Never-painted content is bounded by an honest probe give-up (frames)
//     or wall-clock deadline (starved rAF), never earlier.
{
  const w = newWorld();
  w.arm();
  setStyle(w, 0xFF0000, 150, 0);
  w.strokeAt([[100, 100], [150, 120]]);
  w.pumpFrames(120);
  check('bound/midway-still-pending', w.preview().pending === 1);
  w.pumpFrames(140);
  check('bound/probe-gave-up', w.preview().pending === 0
    && w.state().lastPreviewClear === 'probe-gave-up', JSON.stringify(w.state()));
  w.advanceTimers(7000);
  check('bound/late-deadline-is-no-op', w.preview().pending === 0);
  const w2 = newWorld();
  w2.arm();
  w2.strokeAt([[100, 100], [150, 120]]);
  w2.advanceTimers(6100); // rAF starved (backgrounded webview)
  check('bound/deadline-clears-hidden', w2.preview().pending === 0
    && w2.state().lastPreviewClear === 'deadline', JSON.stringify(w2.state()));
}

// 21. Unreadable canvas degrades to the deadline path only; a model event
//     cannot settle it (the removed 'model-settled' behaviour regression).
{
  const w = newWorld({ noContext: true, noGetContext: true });
  w.arm();
  w.stroke(1);
  check('unreadable/probe-unavailable', w.preview().probes[0].probe === 'unavailable',
    JSON.stringify(w.preview()));
  w.stateChanged(true, 'ModifiedStatus');
  w.pumpFrames(12);
  check('unreadable/model-event-does-not-settle', w.preview().pending === 1,
    JSON.stringify(w.preview()));
  w.advanceTimers(6100);
  check('unreadable/deadline-bounds-it', w.preview().pending === 0
    && w.state().lastPreviewClear === 'deadline');
}

// 22. Pending handoffs are capped: the ninth completed contact honestly
//     evicts the oldest instead of growing unbounded.
{
  const w = newWorld({ noContext: true, noGetContext: true });
  w.arm();
  for (let i = 0; i < 9; i += 1) w.stroke(1, [10 + i, 20 + i]);
  check('cap/pending-bounded', w.preview().pending === 8, JSON.stringify(w.preview()));
  check('cap/oldest-evicted', w.state().lastPreviewClear === 'overflow'
    && w.state().previewHandoffs === 9, JSON.stringify(w.state()));
}

// 23. Viewport resize and pagehide tear down every preview within bounds;
//     pagehide keeps its existing disarms.
{
  const w = newWorld();
  w.arm();
  w.stroke(1);
  w.stroke(1);
  w.window.dispatch(makeEvent('resize'));
  check('teardown/resize-clears-all', w.preview().pending === 0
    && w.state().lastPreviewClear === 'viewport-resized'
    && overlayPaths(w).paths.length === 0, JSON.stringify(w.state()));
  w.window.__floeSetOfficeDrawingMode(true);
  w.stroke(1);
  w.window.dispatch(makeEvent('pagehide'));
  check('teardown/pagehide-clears-and-disarms',
    w.preview().pending === 0 && w.state().drawing === false
    && w.state().lastPreviewClear === 'pagehide', JSON.stringify(w.state()));
}

// 24. Fail-closed shape-handle loss. A handle that already fails on down
//     never starts a preview for that contact (and keeps prior completed
//     handoffs intact); a handle that breaks mid-contact drops only its own
//     stroke preview. The ordered Escape still runs and the honest error
//     stays observable through __floeOfficePenState().
{
  const w = newWorld();
  w.arm();
  w.stroke(1); // completed, pending handoff #1
  const definition = w.window.app.CSections.ShapeHandlesSection;
  let working = {
    name: definition.name, showSection: false,
    setShowSection(show) { this.showSection = show; },
    sectionProperties: { subSections: [] },
  };
  w.window.app.sectionContainer.getSectionWithName = (name) =>
    (name === working.name ? working : null);
  w.pen('pointerdown', 10, 10, w.canvas, { pointerId: 131 });
  check('failclosed/mid-contact-armed',
    w.preview().stroke === true && w.state().activeStroke === true,
    JSON.stringify(w.preview()));
  const throwing = {
    name: definition.name, showSection: true,
    setShowSection(show) { if (show === false) throw new Error('hide failed'); },
    sectionProperties: { subSections: [] },
  };
  working = throwing;
  w.pen('pointermove', 14, 14, w.canvas, { pointerId: 131 });
  check('failclosed/stroke-preview-dropped',
    w.state().error === 'shape-handle-unavailable' && w.preview().stroke === false
    && w.state().lastPreviewClear === 'fail-closed' && w.state().drawing === false,
    JSON.stringify(w.state()));
  check('failclosed/prior-handoff-kept', w.preview().pending === 1,
    JSON.stringify(w.preview()));
  check('failclosed/no-completed-stroke-for-failed-contact', w.state().strokes === 1,
    JSON.stringify(w.state()));
}

// 25. Canonical invariance: the replayed mouse stream and counters are
//     identical whether the preview is available or the DOM cannot be
//     created at all (presentation must never touch the persistent path).
{
  const wOn = newWorld();
  setStyle(wOn, 0xFF0000, 150, 0);
  wOn.arm();
  const seenOn = recordedMouse(wOn);
  wOn.stroke(2);
  const wOff = newWorld({ noCreateElementNS: true });
  setStyle(wOff, 0xFF0000, 150, 0);
  wOff.arm();
  const seenOff = recordedMouse(wOff);
  wOff.stroke(2);
  const shape = (seen) => JSON.stringify(seen.map((e) => [e.type, e.clientX, e.clientY, e.buttons]));
  check('canonical/mouse-stream-identical', shape(seenOn) === shape(seenOff),
    `${shape(seenOn)} vs ${shape(seenOff)}`);
  check('canonical/counters-identical',
    JSON.stringify({ s: wOn.state().strokes, c: wOn.state().coreEvents })
    === JSON.stringify({ s: wOff.state().strokes, c: wOff.state().coreEvents }),
    JSON.stringify(wOn.state()));
  check('canonical/unavailable-degrades-quietly',
    wOff.preview().available === false && wOff.state().strokes === 1, JSON.stringify(wOff.preview()));
}

// 26. Ten rapid contacts: every handoff is counted, every painted contact
//     clears, and the overlay never accumulates orphan nodes.
{
  const w = newWorld();
  w.arm();
  setStyle(w, 0xFF0000, 150, 0); // paintArea's red must match the stroke target
  for (let i = 0; i < 10; i += 1) {
    const pts = w.strokeAt([[50 + i * 30, 100], [80 + i * 30, 140]]);
    w.paintArea(pts);
    w.pumpFrames(3);
  }
  check('lifecycle/ten-strokes-ten-handoffs', w.state().previewHandoffs === 10
    && w.state().strokes === 10, JSON.stringify(w.state()));
  check('lifecycle/no-orphan-nodes', w.preview().pending === 0
    && overlayPaths(w).paths.length === 0, String(overlayPaths(w).paths.length));
  w.advanceTimers(10000);
  w.pumpFrames(10);
  check('lifecycle/everything-settles', w.preview().pending === 0
    && w.state().previewClears === 10, JSON.stringify(w.state()));
}

// --- Writer page-top inset compensation + adversarial handoff ownership -----

// Turns this world into a Writer document whose page-1 origin is
// `rects[0] = [xTw, yTw, ...]`. The y component is the top inset below the
// document-space origin (the real App geometry: paper top measured at
// canvas-local device px 37 == ~278 twips at zoom 100); the x component is
// diagnostic-only input that the replay never subtracts.
const setWriterPages = (world, rects) => {
  world.window.app.map._docLayer._docType = 'text';
  world.window.app.file = { writer: { pageRectangleList: rects } };
};

// 27. The Y compensation is derived from the live page geometry, applied to
//     the replayed pen stream's Y only, and the preview/probes keep the raw
//     pen coordinates so the compensated engine paint lands where the
//     near probes already look (zero settle jump, near evidence only).
{
  const w = newWorld();
  w.arm();
  setStyle(w, 0xFF0000, 150, 0);
  setWriterPages(w, [[0, 278, 12240, 15840]]);
  const seen = recordedMouse(w);
  const dy = 278 * 0.2 / 2; // world scale: ttP 0.2 device px/twip, dpr 2
  w.pen('pointerdown', 100, 200, w.canvas, { pointerId: 201 });
  w.pen('pointermove', 110, 210, w.canvas, { pointerId: 201 });
  w.pen('pointermove', 120, 220, w.canvas, { pointerId: 201 });
  w.pumpFrames(1); // d is applied on the frame tick, like production
  check('inset/down-shifted-by-derived-page-inset',
    seen.length === 3 && seen[0].type === 'mousedown'
    && Math.abs(seen[0].clientY - (200 - dy)) < 1e-9 && seen[0].clientX === 100,
    JSON.stringify(seen.map((e) => [e.type, e.clientX, e.clientY])));
  check('inset/shape-preserved-for-move-and-up-so-far',
    Math.abs(seen[1].clientY - (210 - dy)) < 1e-9
    && Math.abs(seen[2].clientY - (220 - dy)) < 1e-9
    && seen[1].clientX === 110 && seen[2].clientX === 120
    && seen[1].buttons === 1 && seen[2].buttons === 1,
    JSON.stringify(seen.map((e) => [e.type, e.clientY, e.buttons])));
  check('inset/diagnostic-exposed',
    JSON.stringify(w.state().writerInsetTwips) === '[0,278]'
    && JSON.stringify(w.state().writerPageOriginTwips) === '[0,278]',
    JSON.stringify([w.state().writerInsetTwips, w.state().writerPageOriginTwips]));
  const paths = overlayPaths(w).paths;
  check('inset/preview-keeps-raw-pen-coordinates',
    paths.length === 1
    && paths[0].getAttribute('d') === 'M100.0 200.0 L110.0 210.0 L120.0 220.0',
    paths.length ? paths[0].getAttribute('d') : 'none');
  w.pen('pointerup', 120, 220, w.canvas, { pointerId: 201 });
  check('inset/up-shifted',
    seen.length === 4 && seen[3].type === 'mouseup'
    && Math.abs(seen[3].clientY - (220 - dy)) < 1e-9 && seen[3].buttons === 0,
    JSON.stringify(seen[3] && [seen[3].type, seen[3].clientY]));
  // The compensated engine paints under the pen; near evidence settles it.
  w.paintArea([[100, 200], [110, 210], [120, 220]]);
  w.pumpFrames(1);
  check('inset/settles-on-near-evidence-no-far-tier',
    w.preview().pending === 0 && w.state().lastPreviewClear === 'painted',
    JSON.stringify(w.state()));
}

// 28. Axis isolation: a nonzero page-1 X origin must never move the
//     replayed stream. 193 twips is the exact C5 Word horizontal
//     overcompensation (19.3 CSS) at this world's 0.2 twipsToPixels / dpr 2
//     scale; the raw-X D9 run measured 0.75 CSS. The valid Y inset still
//     applies exactly once, and the preview stays on the raw pen path.
{
  const w = newWorld();
  w.arm();
  setStyle(w, 0xFF0000, 150, 0);
  setWriterPages(w, [[193, 278, 12240, 15840]]);
  const seen = recordedMouse(w);
  const dx = 193 * 0.2 / 2; // 19.3 CSS: must NOT be subtracted
  const dy = 278 * 0.2 / 2;
  check('inset/c5-horizontal-regression-is-nonzero',
    Math.abs(dx - 19.3) < 1e-9 && dy > 0,
    `${dx}/${dy}`);
  w.pen('pointerdown', 100, 200, w.canvas, { pointerId: 241 });
  w.pen('pointermove', 110, 210, w.canvas, { pointerId: 241 });
  w.pen('pointermove', 120, 220, w.canvas, { pointerId: 241 });
  w.pumpFrames(1);
  check('inset/page-x-remains-raw',
    seen.length === 3
    && seen.every((e, i) => e.clientX === [100, 110, 120][i])
    && seen.every((e, i) => Math.abs(e.clientY - ([200, 210, 220][i] - dy)) < 1e-9),
    JSON.stringify(seen.map((e) => [e.type, e.clientX, e.clientY])));
  check('inset/page-x-not-subtracted-diagnostic',
    JSON.stringify(w.state().writerInsetTwips) === '[0,278]'
    && JSON.stringify(w.state().writerPageOriginTwips) === '[193,278]',
    JSON.stringify([w.state().writerInsetTwips, w.state().writerPageOriginTwips]));
  const pathsX = overlayPaths(w).paths;
  check('inset/nonzero-x-preview-stays-raw',
    pathsX.length === 1
    && pathsX[0].getAttribute('d') === 'M100.0 200.0 L110.0 210.0 L120.0 220.0',
    pathsX.length ? pathsX[0].getAttribute('d') : 'none');
  w.pen('pointerup', 120, 220, w.canvas, { pointerId: 241 });
  check('inset/nonzero-x-up-stays-raw',
    seen.length === 4 && seen[3].type === 'mouseup' && seen[3].clientX === 120
    && Math.abs(seen[3].clientY - (220 - dy)) < 1e-9,
    JSON.stringify(seen[3] && [seen[3].type, seen[3].clientX, seen[3].clientY]));
}

// 29. Fail-open matrix: non-text documents (XLSX/PPTX controls stay
//     byte-identical), absent/negative/oversized/non-finite page rects and
//     broken scales all replay the raw coordinates with no diagnostic.
{
  const cases = [
    ['spreadsheet-untouched', (w) => {
      w.window.app.map._docLayer._docType = 'spreadsheet';
      w.window.app.file = { writer: { pageRectangleList: [[0, 278, 1, 1]] } };
    }],
    ['missing-page-rects', (w) => { w.window.app.map._docLayer._docType = 'text'; }],
    ['negative-inset', (w) => setWriterPages(w, [[0, -50, 1, 1]])],
    ['oversized-inset', (w) => setWriterPages(w, [[0, 99999, 1, 1]])],
    ['non-finite-inset', (w) => setWriterPages(w, [[0, NaN, 1, 1]])],
    ['broken-scale', (w) => { setWriterPages(w, [[0, 278, 1, 1]]); w.window.app.twipsToPixels = 0; }],
  ];
  for (const [name, setup] of cases) {
    const w = newWorld();
    w.arm();
    setup(w);
    const seen = recordedMouse(w);
    w.pen('pointerdown', 50, 60, w.canvas, { pointerId: 210 });
    check(`inset/fail-open-${name}`,
      seen.length === 1 && seen[0].clientX === 50 && seen[0].clientY === 60
      && w.state().writerInsetTwips === null,
      JSON.stringify([seen[0] && seen[0].clientY, w.state().writerInsetTwips]));
  }
}

// 30. An unusable X diagnostic cannot suppress a valid Y inset: the axes
//     are independent, X stays raw and only the bounded Y term applies.
{
  const w = newWorld();
  w.arm();
  setWriterPages(w, [[NaN, 278, 1, 1]]);
  const seen = recordedMouse(w);
  const dy = 278 * 0.2 / 2;
  w.pen('pointerdown', 50, 60, w.canvas, { pointerId: 215 });
  check('inset/invalid-x-does-not-suppress-valid-y',
    seen.length === 1 && seen[0].clientX === 50
    && Math.abs(seen[0].clientY - (60 - dy)) < 1e-9
    && JSON.stringify(w.state().writerInsetTwips) === '[0,278]'
    && w.state().writerPageOriginTwips === null,
    JSON.stringify([seen[0] && [seen[0].clientX, seen[0].clientY],
      w.state().writerInsetTwips, w.state().writerPageOriginTwips]));
}

// 31. The inset is recomputed per contact: a zoom change between contacts
//     (twipsToPixels) rescales the compensation from the same page rect.
{
  const w = newWorld();
  w.arm();
  setWriterPages(w, [[0, 278, 12240, 15840]]);
  const seen = recordedMouse(w);
  w.pen('pointerdown', 10, 100, w.canvas, { pointerId: 221 });
  w.pen('pointerup', 10, 100, w.canvas, { pointerId: 221 });
  w.window.app.twipsToPixels = 0.28; // e.g. pinch-zoom between contacts
  w.pen('pointerdown', 10, 100, w.canvas, { pointerId: 222 });
  const dy1 = 278 * 0.2 / 2;
  const dy2 = 278 * 0.28 / 2;
  check('inset/recomputed-per-contact',
    Math.abs(seen[0].clientY - (100 - dy1)) < 1e-9
    && Math.abs(seen[2].clientY - (100 - dy2)) < 1e-9
    && dy1 !== dy2,
    JSON.stringify(seen.map((e) => e.clientY)));
}

// 32. Adversarial ownership: a same-colour neighbour stroke painting its
//     own path must never clear this stroke's handoff (no wide windows —
//     evidence stays on the stroke's own near patches).
{
  const w = newWorld();
  w.arm();
  setStyle(w, 0xFF0000, 150, 0);
  const a = w.strokeAt([[100, 100], [140, 120], [180, 140]]);
  const b = [[300, 100], [340, 120], [380, 140]]; // 200 css px away
  w.strokeAt(b);
  check('ownership/two-pending', w.preview().pending === 2,
    String(w.preview().pending));
  w.paintArea(b); // engine painted ONLY the neighbour, same colour
  w.pumpFrames(4);
  check('ownership/neighbour-paint-keeps-own-pending',
    w.preview().pending === 1 && overlayPaths(w).paths.length === 1,
    JSON.stringify(w.preview()));
  w.paintArea(a);
  w.pumpFrames(2);
  check('ownership/own-paint-clears',
    w.preview().pending === 0 && w.state().previewClears === 2
    && w.state().lastPreviewClear === 'painted', JSON.stringify(w.state()));
}

// 33. Adversarial ownership at overlap distance: a same-colour stroke 40
//     css px away (outside the 7x7 near patches and its paint radius)
//     still cannot cross-clear; its own paint does.
{
  const w = newWorld();
  w.arm();
  setStyle(w, 0xFF0000, 150, 0);
  const a = w.strokeAt([[100, 100], [140, 120]]);
  const b = [[100, 140], [140, 160]];
  w.strokeAt(b);
  w.paintArea(b);
  w.pumpFrames(4);
  check('ownership/offset-overlap-no-cross-clear', w.preview().pending === 1,
    JSON.stringify(w.preview()));
  w.paintArea(a);
  w.pumpFrames(2);
  check('ownership/offset-overlap-own-clears',
    w.preview().pending === 0 && w.state().previewClears === 2,
    JSON.stringify(w.state()));
}

// 34. Documented residual ambiguity: two same-colour strokes on IDENTICAL
//     geometry are indistinguishable to any geometric evidence scheme; one
//     paint legitimately settles both. Recorded, not silently accepted.
{
  const w = newWorld();
  w.arm();
  setStyle(w, 0xFF0000, 150, 0);
  const a = w.strokeAt([[100, 100], [140, 120]]);
  w.strokeAt([[100, 100], [140, 120]]);
  w.paintArea(a);
  w.pumpFrames(2);
  check('ownership/identical-geometry-ambiguity-documented',
    w.preview().pending === 0 && w.state().previewClears === 2,
    JSON.stringify(w.state()));
}

// 35. Zero-move contact (a handwriting dot): the canonical replay is
//     exactly mousedown+mouseup at the SAME point — the gate fabricates no
//     intermediate move — and the presentation shows the single-point dot
//     path. Persistence of the dot is core-side (see handoff engine trace).
{
  const w = newWorld();
  w.arm();
  setWriterPages(w, [[0, 278, 12240, 15840]]);
  const seen = recordedMouse(w);
  w.pen('pointerdown', 60, 80, w.canvas, { pointerId: 231 });
  w.pen('pointerup', 60, 80, w.canvas, { pointerId: 231 });
  const dy = 278 * 0.2 / 2;
  check('dot/canonical-two-events-same-point',
    seen.length === 2 && seen[0].type === 'mousedown' && seen[1].type === 'mouseup'
    && seen[0].clientX === seen[1].clientX && seen[0].clientY === seen[1].clientY
    && Math.abs(seen[0].clientY - (80 - dy)) < 1e-9,
    JSON.stringify(seen.map((e) => [e.type, e.clientX, e.clientY])));
  check('dot/stroke-counted', w.state().strokes === 1 && w.state().coreEvents === 2,
    JSON.stringify(w.state()));
  const paths = overlayPaths(w).paths;
  check('dot/preview-dot-path', paths.length === 1
    && paths[0].getAttribute('d') === 'M60.0 80.0 L60.1 80.0',
    paths.length ? paths[0].getAttribute('d') : 'none');
}

// 36. Production text contracts for this round: the far-window fallback is
//     gone (root review: wide same-colour windows are not ownership), and
//     the compensation is derived, bounded and text-only.
check('inset/no-far-window-tier-in-production',
  !script.includes('PREVIEW_FAR_MARGIN') && !script.includes('farEvidence'));
check('inset/derived-bounded-text-only',
  script.includes('pageRectangleList') && script.includes('WRITER_INSET_MAX_TWIPS')
  && script.includes("_docType !== 'text'"));
check('inset/x-not-compensated-in-source',
  !script.includes('clientX -=') && !script.includes('writerInsetCss.x'));

console.log(`${checks} checks, ${failures} failed`);
console.log(failures === 0 ? 'ALL PEN INPUT CONTRACT CHECKS PASSED' : `${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
