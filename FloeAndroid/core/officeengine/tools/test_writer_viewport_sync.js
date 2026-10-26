#!/usr/bin/env node
/*
 * Focused semantic checks for floe-writer-viewport-sync.js.
 *
 * WHAT THIS IS: a deterministic stub-sandbox check of the overlay's event
 * ordering, identity decisions and measured zero-height body binding. It is
 * NOT device evidence and does not prove first paint, tile delivery,
 * permissions or readiness.
 *
 * Run: node core/officeengine/tools/test_writer_viewport_sync.js
 *      (exit 0 = every authored check passed)
 */
'use strict';
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const SNIPPET_PATH = path.join(__dirname, '../overlays/dist/floe-writer-viewport-sync.js');
const SNIPPET_SRC = fs.readFileSync(SNIPPET_PATH, 'utf8');

let checks = 0;
function ok(condition, name) {
  checks++;
  if (!condition) throw new Error('FAIL: ' + name);
}
function eq(actual, expected, name) {
  ok(actual === expected, name + ' (got ' + JSON.stringify(actual) + ', want ' + JSON.stringify(expected) + ')');
}

function element(width, height) {
  return { getBoundingClientRect: function () { return { width: width, height: height }; } };
}

function parsePacket(message) {
  const pattern = /^floe-viewport-geometry main=(\d+x\d+)>(\d+x\d+) doc=(\d+x\d+)>(\d+x\d+) canvas=(\d+x\d+)>(\d+x\d+) viewport=(\d+x\d+) html=(\d+x\d+) body=(\d+x\d+) sync=(applied|absent|failed|stale)$/;
  const match = pattern.exec(message);
  if (!match) return null;
  return {
    mainBefore: match[1], mainAfter: match[2],
    docBefore: match[3], docAfter: match[4],
    canvasBefore: match[5], canvasAfter: match[6],
    viewport: match[7], html: match[8], body: match[9], sync: match[10],
  };
}

function makeEnv(options) {
  const opts = options || {};
  let viewportHeight = opts.innerHeight == null ? 720 : opts.innerHeight;
  const state = {
    mainWidth: opts.mainWidth == null ? 0 : opts.mainWidth,
    mainHeight: opts.mainHeight == null ? 0 : opts.mainHeight,
    docWidth: opts.docWidth == null ? 0 : opts.docWidth,
    docHeight: opts.docHeight == null ? 0 : opts.docHeight,
    canvasWidth: opts.canvasWidth == null ? 0 : opts.canvasWidth,
    canvasHeight: opts.canvasHeight == null ? 0 : opts.canvasHeight,
    bodyHeight: opts.bodyHeight == null ? 720 : opts.bodyHeight,
    htmlHeight: opts.htmlHeight == null ? 720 : opts.htmlHeight,
  };

  const elements = {
    'main-document-content': { getBoundingClientRect: () => ({ width: state.mainWidth, height: state.mainHeight }) },
    'document-container': { getBoundingClientRect: () => ({ width: state.docWidth, height: state.docHeight }) },
    'document-canvas': { width: 300, height: 150, getBoundingClientRect: () => ({ width: state.canvasWidth, height: state.canvasHeight }) },
  };
  // Mirrors the real body: its rect reflects the current inline height, so a
  // stale inline 0px stays 0x0 until the overlay actually binds a new value.
  const mutationOrder = [];
  const bodyStyleAssignments = [];
  const bodyStyle = {
    _height: opts.inlineBodyHeight == null
      ? (state.bodyHeight > 0 ? state.bodyHeight + 'px' : '0px')
      : opts.inlineBodyHeight,
    get height() { return this._height; },
    set height(value) {
      this._height = value;
      bodyStyleAssignments.push(value);
      mutationOrder.push('body:' + value);
      const px = /^([0-9.]+)px$/.exec(value);
      if (px) state.bodyHeight = parseFloat(px[1]);
      else if (value === '100vh' || value === '100dvh')
        state.bodyHeight = viewportHeight;
    },
  };
  function currentBodyHeight() {
    return bodyStyle._height === '100vh' || bodyStyle._height === '100dvh'
      ? viewportHeight
      : state.bodyHeight;
  }
  const body = {
    getBoundingClientRect: () => ({ width: 1280, height: currentBodyHeight() }),
    style: bodyStyle,
  };
  const rootStyleProps = {};
  const rootStyle = {
    setProperty: function (name, value) {
      rootStyleProps[name] = value;
      mutationOrder.push('inset:' + value);
    },
  };
  const documentElement = {
    clientWidth: 1280,
    clientHeight: state.htmlHeight,
    style: rootStyle,
  };

  const loadListeners = [];
  const rafQueue = [];
  const captured = [];
  const handlers = {};
  const resizeBodyHeights = [];
  let resizeCalls = 0;
  let rafCalls = 0;
  let scrollCalls = 0;

  const layer = { _docType: opts.docType || 'text' };
  const layout = opts.noOnResize ? {} : {
    onResize: function () {
      resizeCalls++;
      mutationOrder.push('resize');
      // The real layout measures #document-container; record the body height
      // at that exact instant so the test can prove the binding ran first.
      resizeBodyHeights.push(currentBodyHeight());
      if (opts.throwOnResize) throw new Error('simulated-layout-error');
      state.canvasWidth = 2560;
      state.canvasHeight = 1071;
    },
  };
  const documentModel = { activeLayout: layout };
  const map = {
    _docLoaded: false,
    _docLayer: layer,
    on: function (name, fn) { (handlers[name] = handlers[name] || []).push(fn); },
    off: function (name, fn) { handlers[name] = (handlers[name] || []).filter((f) => f !== fn); },
  };
  const app = {
    map: opts.mapPresent === false ? null : map,
    sectionContainer: {
      getWidth: () => state.canvasWidth,
      getHeight: () => state.canvasHeight,
    },
    activeDocument: documentModel,
  };
  const win = {
    app: app,
    innerWidth: 1280,
    get innerHeight() { return viewportHeight; },
    addEventListener: function (type, fn) { if (type === 'load') loadListeners.push(fn); },
    removeEventListener: function (type, fn) {
      if (type !== 'load') return;
      const index = loadListeners.indexOf(fn);
      if (index >= 0) loadListeners.splice(index, 1);
    },
    COOLMessageHandler: { postMobileMessage: (message) => captured.push(message) },
    scroll: function () {
      scrollCalls++;
      mutationOrder.push('scroll');
    },
    requestAnimationFrame: function (fn) {
      rafCalls++;
      rafQueue.push(fn);
      return rafCalls;
    },
  };
  if (opts.noRaf) win.requestAnimationFrame = undefined;
  if (!opts.noVisualViewport) {
    win.visualViewport = {
      height: opts.visualViewportHeight == null ? 720 : opts.visualViewportHeight,
      offsetTop: opts.visualViewportOffsetTop == null ? 0 : opts.visualViewportOffsetTop,
    };
  }

  const documentStub = {
    readyState: opts.readyState || 'loading',
    body: body,
    documentElement: documentElement,
    getElementById: function (id) { return elements[id] || null; },
    addEventListener: function () {},
  };

  const sandbox = {
    window: win,
    document: documentStub,
    app: app,
    COOLMessageHandler: win.COOLMessageHandler,
    requestAnimationFrame: win.requestAnimationFrame,
    Number: Number,
    Math: Math,
    Error: Error,
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);

  return {
    sandbox: sandbox,
    app: app,
    map: map,
    layer: layer,
    layout: layout,
    documentModel: documentModel,
    captured: captured,
    handlers: handlers,
    state: state,
    resizeCalls: () => resizeCalls,
    rafCalls: () => rafCalls,
    scrollCalls: () => scrollCalls,
    bodyHeight: () => currentBodyHeight(),
    bodyInlineHeight: () => bodyStyle.height,
    bodyStyleAssignments: () => bodyStyleAssignments.slice(),
    bodyHeightsAtResize: () => resizeBodyHeights.slice(),
    rootInset: () => rootStyleProps['--viewport-bottom-inset'],
    mutationOrder: () => mutationOrder.slice(),
    setViewportHeight: function (value) { viewportHeight = value; },
    inject: function () { vm.runInContext(SNIPPET_SRC, sandbox, { filename: 'floe-writer-viewport-sync.js' }); },
    fireLoad: function () { loadListeners.slice().forEach((fn) => fn()); },
    fireDocLoaded: function (status) {
      map._docLoaded = status !== false;
      (handlers.docloaded || []).slice().forEach((fn) => fn({ status: status !== false }));
    },
    applyWriterStatus: function () {
      state.mainWidth = 2560;
      state.mainHeight = 1071;
      state.docWidth = 2560;
      state.docHeight = 1071;
    },
    flushFrame: function () {
      while (rafQueue.length) rafQueue.shift()();
    },
    pendingFrames: () => rafQueue.length,
  };
}

// 1. Writer waits for both real edges; docloaded precedes status; exactly one
//    frame is used, and the body rectangle is real (not rectSize('body') 0x0).
{
  const env = makeEnv({});
  env.inject();
  env.fireLoad();
  eq(env.resizeCalls(), 0, 'page load alone does not resize');
  eq(env.captured.length, 0, 'page load alone posts nothing');
  env.fireDocLoaded(true);
  eq(env.resizeCalls(), 0, 'docloaded edge alone does not resize synchronously');
  eq(env.captured.length, 0, 'docloaded edge alone posts nothing');
  env.applyWriterStatus(); // pinned Socket.js status call, after docloaded
  eq(env.resizeCalls(), 0, 'status update still waits for the owned frame');
  eq(env.pendingFrames(), 1, 'exactly one frame scheduled after both edges');
  env.flushFrame();
  eq(env.resizeCalls(), 1, 'one frame invokes the exact layout onResize once');
  eq(env.rafCalls(), 1, 'exactly one animation frame was requested');
  eq(env.pendingFrames(), 0, 'no recurring frame remains');
  eq(env.bodyInlineHeight(), '720px', 'already-positive body is not re-bound');
  eq(env.bodyStyleAssignments().length, 0, 'already-positive body gets no style mutation');
  eq(env.scrollCalls(), 0, 'already-positive body does not scroll the visual origin');
  eq(env.rootInset(), undefined, 'already-positive body leaves the inset untouched');
  eq(env.mutationOrder().join(','), 'resize', 'already-positive body reaches only the exact resize');
  eq(env.bodyHeightsAtResize()[0], 720, 'body was already positive at resize');
  eq(env.captured.length, 1, 'one numeric packet posted');
  const packet = parsePacket(env.captured[0]);
  ok(!!packet, 'packet matches the strict numeric-only shape');
  if (packet) {
    eq(packet.mainBefore, '0x0', 'pre-frame main geometry is the unresolved state');
    eq(packet.mainAfter, '2560x1071', 'post-frame main geometry is numeric');
    eq(packet.docBefore, '0x0', 'pre-frame document-container geometry is the unresolved state');
    eq(packet.docAfter, '2560x1071', 'post-frame document geometry is numeric');
    eq(packet.canvasBefore, '0x0', 'pre-frame canvas geometry is zero');
    eq(packet.canvasAfter, '2560x1071', 'post-resize canvas geometry is positive');
    eq(packet.body, '1280x720', 'body uses the real body element rect, never 0x0');
    eq(packet.sync, 'applied', 'in-frame exact onResize succeeded');
  }
  env.fireLoad();
  env.fireDocLoaded(true);
  eq(env.resizeCalls(), 1, 'later load/docloaded events cannot resize again');
  eq(env.rafCalls(), 1, 'later load/docloaded events cannot request another frame');
  eq(env.captured.length, 1, 'later events cannot post a second packet');
}

// 2. Non-Writer documents are untouched, even with the same zero body.
{
  const env = makeEnv({
    docType: 'spreadsheet',
    bodyHeight: 0,
    htmlHeight: 656,
    inlineBodyHeight: '0px',
    innerHeight: 655,
    visualViewportHeight: 655,
  });
  env.inject();
  env.fireLoad();
  env.fireDocLoaded(true);
  env.flushFrame();
  eq(env.resizeCalls(), 0, 'Calc/Impress path is not taken');
  eq(env.captured.length, 0, 'non-Writer posts no geometry');
  eq(env.bodyInlineHeight(), '0px', 'non-Writer body binding is not applied');
  eq(env.bodyStyleAssignments().length, 0, 'non-Writer body style is not mutated');
  eq(env.scrollCalls(), 0, 'non-Writer does not scroll the visual origin');
  eq(env.rootInset(), undefined, 'non-Writer inset is untouched');
  eq(env.bodyHeight(), 0, 'non-Writer body is not mutated');
}

// 3. A stale document/layout identity is refused before any style mutation,
//    even when the measured body is still zero.
{
  const env = makeEnv({
    bodyHeight: 0,
    htmlHeight: 656,
    inlineBodyHeight: '0px',
    innerHeight: 655,
    visualViewportHeight: 655,
  });
  env.inject();
  env.fireLoad();
  env.fireDocLoaded(true);
  env.app.activeDocument = { activeLayout: { onResize: () => { throw new Error('stale-must-not-call'); } } };
  env.applyWriterStatus();
  env.flushFrame();
  eq(env.resizeCalls(), 0, 'stale layout is never invoked');
  eq(env.bodyInlineHeight(), '0px', 'stale identity leaves the inline body height untouched');
  eq(env.bodyStyleAssignments().length, 0, 'stale identity performs no style mutation');
  eq(env.scrollCalls(), 0, 'stale identity performs no scroll mutation');
  eq(env.rootInset(), undefined, 'stale identity leaves the inset untouched');
  eq(env.bodyHeight(), 0, 'stale identity leaves the body untouched');
  eq(env.rafCalls(), 1, 'stale identity still uses only its owned frame');
  eq(env.captured.length, 1, 'stale identity is reported once');
  const packet = parsePacket(env.captured[0]);
  ok(!!packet && packet.sync === 'stale', 'packet records stale refusal');
}

// 4. Missing onResize/requestAnimationFrame fails closed with no call.
{
  const env = makeEnv({
    noOnResize: true,
    bodyHeight: 0,
    htmlHeight: 656,
    inlineBodyHeight: '0px',
    innerHeight: 655,
    visualViewportHeight: 655,
  });
  env.inject();
  env.fireLoad();
  env.fireDocLoaded(true);
  env.flushFrame();
  eq(env.resizeCalls(), 0, 'missing onResize is not callable');
  eq(env.bodyInlineHeight(), '0px', 'missing onResize does not bind/mutate the body');
  eq(env.bodyStyleAssignments().length, 0, 'missing onResize performs no style mutation');
  eq(env.scrollCalls(), 0, 'missing onResize performs no scroll mutation');
  eq(env.rootInset(), undefined, 'missing onResize leaves the inset untouched');
  eq(env.bodyHeight(), 0, 'missing onResize leaves the body zero');
  const packet = parsePacket(env.captured[0]);
  ok(!!packet && packet.sync === 'absent', 'missing onResize reports absent');
}
{
  const env = makeEnv({ noRaf: true });
  env.inject();
  env.fireLoad();
  env.fireDocLoaded(true);
  eq(env.resizeCalls(), 0, 'missing requestAnimationFrame performs no resize');
  const packet = parsePacket(env.captured[0]);
  ok(!!packet && packet.sync === 'absent', 'missing frame API reports absent');
}

// 5. A real layout exception is surfaced, not swallowed, and reports failed.
{
  const env = makeEnv({ throwOnResize: true });
  env.inject();
  env.fireLoad();
  env.fireDocLoaded(true);
  let raised = false;
  try { env.flushFrame(); } catch (error) { raised = /simulated-layout-error/.test(String(error)); }
  ok(raised, 'layout exception propagates to the host error path');
  const packet = parsePacket(env.captured[0]);
  ok(!!packet && packet.sync === 'failed', 'failed attempt is recorded numerically');
}

// 6. Bundle-ordering fallback: map absent at deferred injection, then present
//    at the single real load edge; the same one-frame Writer path runs.
{
  const env = makeEnv({ mapPresent: false });
  env.inject();
  eq(env.resizeCalls(), 0, 'map absent at injection leaves the engine untouched');
  eq(env.captured.length, 0, 'map absent at injection posts nothing');
  env.app.map = env.map;
  env.map._docLoaded = true;
  env.fireLoad();
  eq(env.pendingFrames(), 1, 'load-edge reinstall schedules exactly one frame');
  env.flushFrame();
  eq(env.resizeCalls(), 1, 'load-edge reinstall reaches the exact layout once');
  const packet = parsePacket(env.captured[0]);
  ok(!!packet && packet.sync === 'applied', 'load-edge reinstall reports one applied packet');
}

// 7. The other real edge order: docloaded first, Writer status/paint layout
//    applied after that edge, then page load; still exactly one owned frame.
{
  const env = makeEnv({});
  env.inject();
  env.fireDocLoaded(true);
  eq(env.resizeCalls(), 0, 'docloaded-first waits for page load');
  eq(env.captured.length, 0, 'docloaded-first posts nothing before page load');
  env.applyWriterStatus();
  eq(env.resizeCalls(), 0, 'status application still does not resize synchronously');
  env.fireLoad();
  eq(env.pendingFrames(), 1, 'page load after docloaded schedules exactly one frame');
  eq(env.resizeCalls(), 0, 'layout is untouched until the owned frame runs');
  env.flushFrame();
  eq(env.resizeCalls(), 1, 'owned frame invokes the exact layout once');
  const packet = parsePacket(env.captured[0]);
  ok(!!packet && packet.sync === 'applied', 'docloaded-first order records one applied packet');
}

// 8. Actual measured Writer failure: body 0 with positive HTML and viewport.
//    With no positive visualViewport at the boundary, the owned frame installs
//    the live vh/dvh constraint before the exact onResize, then reports the
//    repaired numeric body.
{
  const env = makeEnv({
    bodyHeight: 0,
    htmlHeight: 656,
    inlineBodyHeight: '0px',
    innerHeight: 655,
    visualViewportHeight: 0, // pinned handler saw no positive visual viewport
  });
  env.inject();
  env.fireLoad();
  env.fireDocLoaded(true);
  env.applyWriterStatus(); // main/doc/canvas become positive, body stays zero
  eq(env.bodyHeight(), 0, 'pre-frame body is the measured zero height');
  eq(env.pendingFrames(), 1, 'zero body still schedules exactly one owned frame');
  eq(env.resizeCalls(), 0, 'zero body is not resized synchronously');
  env.flushFrame();
  eq(env.resizeCalls(), 1, 'zero body reaches the exact onResize once');
  eq(env.bodyInlineHeight(), '100dvh', 'live viewport-unit fallback is installed');
  eq(env.bodyStyleAssignments().join(','), '100vh,100dvh', 'vh fallback is assigned before dvh');
  eq(env.scrollCalls(), 0, 'zero visual viewport does not fake a scroll origin');
  eq(env.rootInset(), '0px', 'zero visual viewport resets the stale inset');
  eq(env.mutationOrder().join(','), 'body:100vh,body:100dvh,inset:0px,resize',
    'zero-vv fallback mutates body and inset before the exact resize');
  eq(env.bodyHeightsAtResize()[0], 655, 'body was positive before the exact resize');
  eq(env.bodyHeight(), 655, 'body is positive after the owned frame');
  eq(env.rafCalls(), 1, 'zero-body repair requests exactly one frame');
  const packet = parsePacket(env.captured[0]);
  ok(!!packet && packet.sync === 'applied', 'zero-body repair reports applied');
  if (packet) {
    eq(packet.viewport, '1280x655', 'packet reports the measured positive viewport');
    eq(packet.html, '1280x656', 'packet reports the positive HTML height');
    eq(packet.body, '1280x655', 'packet reports the now-positive body height');
    eq(packet.mainAfter, '2560x1071', 'main geometry is positive after the fix');
    eq(packet.docAfter, '2560x1071', 'document geometry is positive after the fix');
    eq(packet.canvasAfter, '2560x1071', 'canvas geometry is positive after the fix');
  }
  env.fireLoad();
  env.fireDocLoaded(true);
  eq(env.rafCalls(), 1, 'later edges cannot request another frame or poll');
  eq(env.resizeCalls(), 1, 'later edges cannot resize again');
  eq(env.captured.length, 1, 'later edges cannot post a second packet');
}

// 9. The pinned visualViewport source is preferred when it already reports a
//    positive height; no fixed fallback constant is used.
{
  const env = makeEnv({
    bodyHeight: 0,
    htmlHeight: 656,
    inlineBodyHeight: '0px',
    innerHeight: 720,
    visualViewportHeight: 640,
  });
  env.inject();
  env.fireLoad();
  env.fireDocLoaded(true);
  env.applyWriterStatus();
  env.flushFrame();
  eq(env.bodyInlineHeight(), '640px', 'pinned visual viewport height wins over window height');
  eq(env.bodyStyleAssignments().join(','), '640px', 'pinned path assigns one live pixel height');
  eq(env.scrollCalls(), 1, 'pinned path scrolls to the visual origin once');
  eq(env.rootInset(), '16px', 'pinned path sets the bounded 656-0-640 inset');
  eq(env.mutationOrder().join(','), 'scroll,body:640px,inset:16px,resize',
    'pinned path completes scroll, body, inset before the exact resize');
  eq(env.bodyHeightsAtResize()[0], 640, 'pinned body height was positive before resize');
  eq(env.rafCalls(), 1, 'pinned binding path uses one frame');
  const packet = parsePacket(env.captured[0]);
  ok(!!packet && packet.sync === 'applied', 'pinned binding path reports applied');
  if (packet) eq(packet.body, '1280x640', 'packet reports the pinned viewport body');
}

// 10. No visualViewport API at all: the fallback must be live CSS viewport
//     units, not a frozen innerHeight pixel, so normal orientation and
//     soft-keyboard viewport changes can re-resolve it.
{
  const env = makeEnv({
    noVisualViewport: true,
    bodyHeight: 0,
    htmlHeight: 656,
    inlineBodyHeight: '0px',
    innerHeight: 655,
  });
  env.inject();
  env.fireLoad();
  env.fireDocLoaded(true);
  env.applyWriterStatus();
  env.flushFrame();
  eq(env.bodyInlineHeight(), '100dvh', 'no-vv fallback stays viewport-relative');
  eq(env.bodyStyleAssignments().join(','), '100vh,100dvh', 'no-vv fallback keeps vh then dvh');
  eq(env.rootInset(), '0px', 'no-vv fallback neutralises the stale inset');
  eq(env.mutationOrder().join(','), 'body:100vh,body:100dvh,inset:0px,resize',
    'no-vv fallback completes body and inset before the exact resize');
  eq(env.scrollCalls(), 0, 'no-vv fallback does not fake a scroll origin');
  eq(env.bodyHeightsAtResize()[0], 655, 'no-vv body was positive before resize');
  eq(env.rafCalls(), 1, 'no-vv fallback still uses exactly one frame');
  env.setViewportHeight(420);
  eq(env.bodyHeight(), 420, 'no-vv CSS fallback re-resolves after a viewport change');
  eq(env.bodyInlineHeight(), '100dvh', 'no-vv fallback remains viewport-relative after the change');
  eq(env.rafCalls(), 1, 'orientation-compatible CSS re-resolve schedules no extra frame');
  const packet = parsePacket(env.captured[0]);
  ok(!!packet && packet.sync === 'applied', 'no-vv fallback reports applied');
  if (packet) eq(packet.body, '1280x655', 'no-vv packet reports the live viewport body');
}

console.log('PASS: ' + checks + ' writer viewport-sync checks');
