#!/usr/bin/env node
/*
 * Contract test for the Floe pen-input overlay injected by
 * FloeAgent/ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm
 * (FLOE_INK_GATING_SCRIPT region).
 *
 * The script text is extracted from the .mm at run time, so the test always
 * exercises exactly what the native host injects. The harness is a minimal
 * DOM: window/document/canvas event targets with capture+bubble propagation,
 * a MouseEvent constructor and the pinned frontend's map / sectionContainer /
 * stateChangeHandler surface.
 *
 * Covered contracts (review-required, 2026-10-17):
 *  - an App pre-arm (OfficeFileSession/setDrawingMode already dispatched
 *    .uno:Freeline_Unfilled, observed either through the __floePencilOnly
 *    assignment or the engine's current item state) must NOT be re-dispatched
 *    by the first pen stroke: re-executing the same slot deselects the tool in
 *    Writer/Calc;
 *  - an observed inactive state re-arms exactly once per stroke start, and an
 *    observed active state suppresses re-arming;
 *  - 'enabled'/'disabled' describe availability only and never count as the
 *    tool being active or inactive;
 *  - pen strokes become real DOM mouse events on the engine canvas/document
 *    (the frontend's own path to the core), while finger pointer and touch
 *    navigation stay untouched outside an active stroke.
 *
 * This is a frontend contract test. It is not a device Pencil proof: pressure,
 * haptics and real WebKit pointer routing stay with device acceptance, and
 * scripts/office_pen_real_dom_acceptance.js documents the real-DOM -> core
 * acceptance path for the integration owner.
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
const check = (name, ok, detail = '') => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`);
  if (!ok) failures += 1;
};

class Target {
  constructor(name, parent = null) {
    this.name = name;
    this.parent = parent;
    this.listeners = [];
  }
  addEventListener(type, fn, options) {
    this.listeners.push({ type, fn, capture: !!(options && options.capture) });
  }
  removeEventListener(type, fn) {
    this.listeners = this.listeners.filter((l) => !(l.type === type && l.fn === fn));
  }
  querySelector() { return null; }
  contains(node) {
    for (let n = node; n; n = n.parent) if (n === this) return true;
    return false;
  }
  dispatchEvent(event) { return this.dispatch(event); }
  dispatch(event) {
    const chain = [];
    for (let node = this; node; node = node.parent) chain.unshift(node);
    event.target = this;
    // Capture phase: window -> target, capture listeners only.
    for (const node of chain) {
      for (const listener of node.listeners.slice()) {
        if (listener.type !== event.type || !listener.capture || event.stopped) continue;
        listener.fn(event);
        if (event.stoppedImmediate) break;
      }
      if (event.stoppedImmediate) break;
    }
    // Target phase: non-capture listeners on the target itself.
    if (!event.stopped && !event.stoppedImmediate) {
      for (const listener of this.listeners.slice()) {
        if (listener.type === event.type && !listener.capture) listener.fn(event);
      }
    }
    // Bubble phase: target parent -> window, non-capture listeners only.
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

function newWorld(seededState, options = {}) {
  const seed = typeof seededState === 'string' || seededState === undefined
    ? (seededState === undefined ? {} : { '.uno:Freeline_Unfilled': seededState })
    : seededState;
  const window = new Target('window');
  if (options.plainFlag) {
    // Simulate a host where the overlay could not install its accessor: the
    // flag stays a plain writable property, so no App-armed transition is
    // observable and the first stroke must fall back to one dispatch.
    Object.defineProperty(window, '__floePencilOnly',
      { value: false, writable: true, configurable: false });
  }
  const document = new Target('document', window);
  const canvas = new Target('canvas', document);
  const toolbar = new Target('toolbar', document);
  document.readyState = 'complete';
  document.querySelector = () => canvas;
  const uno = [];
  const stateListeners = [];
  const items = { ...seed };
  const map = {
    sendUnoCommand: (cmd) => { uno.push(cmd); },
    on: (name, fn) => { if (name === 'commandstatechanged') stateListeners.push(fn); },
    off: (name, fn) => {
      const i = stateListeners.indexOf(fn);
      if (i >= 0) stateListeners.splice(i, 1);
    },
    isEditMode: () => true,
    getContainer: () => null,
    stateChangeHandler: { getItemValue: (name) => items[name] },
  };
  window.app = options.noMap
    ? { sectionContainer: { canvas } }
    : { map, sectionContainer: { canvas } };
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
  const timers = [];
  const fakeSetTimeout = (fn, delay) => { timers.push({ fn, delay }); return timers.length; };
  new Function('window', 'document', 'MouseEvent', 'setTimeout', script)(window, document, MouseEvent, fakeSetTimeout);
  const advance = (rounds = 1) => {
    for (let i = 0; i < rounds; i += 1) {
      const due = timers.shift();
      if (!due) return false;
      due.fn();
    }
    return true;
  };
  const attachMap = () => { window.app.map = map; };
  return {
    timers, advance, attachMap, map,
    window, document, canvas, uno, stateListeners, items,
    toolbar,
    // Real WebKit delivers pointer contacts targeted at the element under the
    // pen/finger; the overlay listens on window capture, so dispatching on the
    // canvas (or the toolbar) models the browser faithfully.
    pen: (type, x = 10, y = 20, target = canvas) =>
      target.dispatch(makeEvent(type, { pointerType: 'pen', clientX: x, clientY: y })),
    finger: (type, target = canvas) => target.dispatch(makeEvent(type, { pointerType: 'touch' })),
    mouse: (type, target = canvas) => target.dispatch(makeEvent(type, { pointerType: 'mouse' })),
    stateChanged: (value, name = 'Freeline_Unfilled') => {
      for (const fn of stateListeners.slice()) fn({ commandName: name, state: value });
    },
    arm: () => { window.__floePencilOnly = true; },
    state: () => window.__floeOfficePenState(),
  };
}

const canvasEvents = (world) => {
  const seen = [];
  const wrap = world.canvas.dispatch.bind(world.canvas);
  world.canvas.dispatch = (event) => {
    // Record only the replayed core-bound mouse events, not the raw pen
    // pointer contacts the test itself dispatches onto the canvas.
    if (event.type === 'mousedown' || event.type === 'mousemove' || event.type === 'mouseup')
      seen.push(event);
    return wrap(event);
  };
  return seen;
};
const documentEvents = (world) => {
  const seen = [];
  const original = world.document.dispatch.bind(world.document);
  world.document.dispatch = (event) => {
    if (event.target === undefined) seen.push(event);
    return original(event);
  };
  return seen;
};
const stroke = (world) => {
  world.pen('pointerdown');
  world.pen('pointermove');
  world.pen('pointerup');
};

// 1. Disarmed: a pen stroke must not touch the core at all.
{
  const w = newWorld();
  const seen = canvasEvents(w);
  stroke(w);
  check('disarmed pen produces no core input', seen.length === 0 && w.uno.length === 0,
    `canvas=${seen.length} uno=${w.uno.length}`);
}

// 2. App pre-arm via the __floePencilOnly assignment: first stroke re-dispatches nothing.
{
  const w = newWorld();
  const seen = canvasEvents(w);
  w.arm();
  stroke(w);
  check('App-armed first stroke posts core input without re-dispatch',
    w.uno.length === 0 && seen.length === 1 && seen[0].type === 'mousedown' && seen[0].buttons === 1,
    `uno=${w.uno.length} canvas=${seen.map((e) => e.type).join(',')}`);
  stroke(w);
  check('App-armed second stroke still re-dispatches nothing', w.uno.length === 0, JSON.stringify(w.uno));
  check('two strokes counted', w.state().strokes === 2, JSON.stringify(w.state()));
}

// 3. App armed earlier, observed through the engine's current item state.
{
  const w = newWorld('true');
  w.arm();
  stroke(w);
  check('seeded active state suppresses first-stroke dispatch', w.uno.length === 0, JSON.stringify(w.uno));
  check('seeded active stroke still posts core input', w.state().coreEvents === 3, JSON.stringify(w.state()));
}

// 4. Observed inactive state re-arms exactly once; observed active suppresses.
{
  const w = newWorld();
  w.arm();
  stroke(w);
  w.stateChanged(false);
  stroke(w);
  check('observed inactive state re-arms once', w.uno.length === 1, JSON.stringify(w.uno));
  w.stateChanged(true);
  stroke(w);
  check('observed active state suppresses re-arm', w.uno.length === 1, JSON.stringify(w.uno));
}

// 5. Availability states never count as activity changes.
{
  const w = newWorld('enabled');
  w.arm();
  stroke(w);
  check('seeded enabled is not activity: armed App stroke does not dispatch',
    w.uno.length === 0, JSON.stringify(w.uno));
  w.stateChanged('disabled');
  stroke(w);
  check('disabled availability does not clear an armed tool', w.uno.length === 0, JSON.stringify(w.uno));
  check('strokes still posted', w.state().strokes === 2 && w.state().coreEvents === 6, JSON.stringify(w.state()));
}

// 6. No observable arming at all (accessor unavailable): one dispatch allowed.
{
  const w = newWorld(undefined, { plainFlag: true });
  const seen = canvasEvents(w);
  w.window.__floePencilOnly = true;
  stroke(w);
  check('unobserved+unarmed first stroke dispatches once',
    w.uno.length === 1 && w.uno[0] === '.uno:Freeline_Unfilled' && seen.length === 1,
    JSON.stringify(w.uno));
}

// 7. Stroke geometry: down/move/up reach canvas/document with button state.
{
  const w = newWorld();
  const seen = canvasEvents(w);
  const doc = documentEvents(w);
  w.arm();
  w.pen('pointerdown', 12, 34);
  w.pen('pointermove', 16, 40);
  w.pen('pointerup', 18, 44);
  const moves = doc.filter((e) => e.type === 'mousemove');
  const ups = doc.filter((e) => e.type === 'mouseup');
  check('mousedown carries pen coordinates and buttons=1',
    seen.length === 1 && seen[0].clientX === 12 && seen[0].clientY === 34 && seen[0].buttons === 1);
  check('mousemove(buttons=1) and mouseup(buttons=0) posted once each',
    moves.length === 1 && moves[0].buttons === 1 && ups.length === 1 && ups[0].buttons === 0,
    `moves=${moves.length} ups=${ups.length}`);
}

// 8. Finger keeps navigating while armed; no core input from finger.
{
  const w = newWorld();
  const seen = canvasEvents(w);
  w.arm();
  const down = makeEvent('pointerdown', { pointerType: 'touch' });
  w.window.dispatch(down);
  const move = makeEvent('pointermove', { pointerType: 'touch' });
  w.window.dispatch(move);
  check('finger pointer events are stopped and post no core input',
    down.stopped && move.stopped && seen.length === 0 && w.uno.length === 0);
}

// 9. Touch scrolling blocked only inside an active pen stroke.
{
  const w = newWorld();
  w.arm();
  const idle = makeEvent('touchmove');
  w.window.dispatch(idle);
  check('touchmove outside a stroke is untouched', !idle.stopped && !idle.defaultPrevented);
  w.pen('pointerdown');
  const during = makeEvent('touchmove');
  w.window.dispatch(during);
  check('touchmove during a pen stroke is blocked', during.stopped && during.defaultPrevented);
  w.pen('pointerup');
  const after = makeEvent('touchmove');
  w.window.dispatch(after);
  check('touchmove after the stroke is untouched again', !after.stopped);
}

// 10. Mouse pointer passes the finger gate and is not replayed as pen input.
{
  const w = newWorld();
  const seen = canvasEvents(w);
  w.arm();
  const down = makeEvent('pointerdown', { pointerType: 'mouse' });
  w.window.dispatch(down);
  check('mouse pointer passes the gate without core replay',
    !down.stopped && seen.length === 0 && w.uno.length === 0);
}

// 11. Alias aggregation: active unfilled slot wins over a false filled alias.
{
  const w = newWorld({ '.uno:Freeline_Unfilled': 'true', '.uno:Freeline': 'false' });
  w.arm();
  stroke(w);
  check('specific true + generic false stays armed', w.uno.length === 0, JSON.stringify(w.uno));
  // App armed, engine then reports the unfilled slot inactive while the
  // filled alias stays false/true in any order: the next stroke re-arms once
  // and the generic alias cannot mask the specific inactive report.
  const w2 = newWorld();
  w2.arm();
  stroke(w2);
  w2.stateChanged(false);
  w2.stateChanged(true, 'Freeline');
  stroke(w2);
  check('specific false + generic true re-arms once', w2.uno.length === 1, JSON.stringify(w2.uno));
  const w3 = newWorld();
  w3.arm();
  stroke(w3);
  w3.stateChanged(true);
  stroke(w3);
  check('live active keeps suppressing', w3.uno.length === 0, JSON.stringify(w3.uno));
  w3.stateChanged(false);
  w3.stateChanged(false, 'Freeline');
  stroke(w3);
  check('live active->inactive re-arms once', w3.uno.length === 1, JSON.stringify(w3.uno));
}

// 12. Late map: one progressive retry chain subscribes and seeds, no burst.
{
  const w = newWorld(undefined, { noMap: true });
  check('unsubscribed world parks exactly one retry timer', w.timers.length === 1, `timers=${w.timers.length}`);
  const unoBefore = w.uno.length;
  // map appears later with the slot already active from the App's toggle.
  w.items['.uno:Freeline_Unfilled'] = 'true';
  w.attachMap();
  w.advance(1);
  check('retry chain subscribes once the map exists', w.state().toolState !== null, JSON.stringify(w.state()));
  check('retry chain stays single-filed', w.timers.length === 0, `timers=${w.timers.length}`);
  w.arm();
  stroke(w);
  check('late-subscribed seeded active stroke does not dispatch',
    w.uno.length === unoBefore, JSON.stringify(w.uno));
}

// 13. Retry chain gives up bounded when the map never appears.
{
  const w = newWorld(undefined, { noMap: true });
  for (let i = 0; i < 80; i += 1) w.advance(1);
  check('bounded retry chain stops', w.timers.length === 0 && w.state().subscribeAttempts <= 41,
    `attempts=${w.state().subscribeAttempts}`);
}

// 14. Pen contact must start on the document canvas; toolbar taps stay UI.
{
  const w = newWorld();
  const seen = canvasEvents(w);
  w.arm();
  const toolbarDown = makeEvent('pointerdown', { pointerType: 'pen', clientX: 5, clientY: 5 });
  w.toolbar.dispatch(toolbarDown);
  w.pen('pointermove', 6, 6, w.toolbar);
  w.pen('pointerup', 7, 7, w.toolbar);
  check('pen tap on toolbar is not ink and not blocked',
    seen.length === 0 && w.uno.length === 0 && !toolbarDown.stopped && !toolbarDown.defaultPrevented);
  const bodyDown = makeEvent('pointerdown', { pointerType: 'pen' });
  w.document.dispatch(bodyDown);
  check('pen contact outside the canvas is not ink', seen.length === 0 && !bodyDown.defaultPrevented);
  const canvasDown = makeEvent('pointerdown', { pointerType: 'pen', clientX: 30, clientY: 40 });
  w.canvas.dispatch(canvasDown);
  check('canvas pen down becomes ink and cancels compatibility mouse',
    seen.length === 1 && canvasDown.defaultPrevented === true, `prevented=${canvasDown.defaultPrevented}`);
  // An in-progress stroke may leave the canvas and still finish.
  w.pen('pointermove', 40, 50, w.toolbar);
  w.pen('pointerup', 44, 54, w.toolbar);
  check('stroke may end outside the canvas', w.state().strokes === 1, JSON.stringify(w.state()));
}

console.log(failures === 0 ? 'ALL PEN INPUT CONTRACT CHECKS PASSED' : `${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
