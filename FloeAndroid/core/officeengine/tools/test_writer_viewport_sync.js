#!/usr/bin/env node
/*
 * Focused semantic checks for floe-writer-viewport-sync.js.
 *
 * WHAT THIS IS: a deterministic stub-sandbox check of the overlay's event
 * ordering and identity decisions. It is NOT device evidence and does not
 * prove first paint, tile delivery, permissions or readiness.
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
  const state = {
    mainWidth: opts.mainWidth == null ? 0 : opts.mainWidth,
    mainHeight: opts.mainHeight == null ? 0 : opts.mainHeight,
    docWidth: opts.docWidth == null ? 0 : opts.docWidth,
    docHeight: opts.docHeight == null ? 0 : opts.docHeight,
    canvasWidth: opts.canvasWidth == null ? 0 : opts.canvasWidth,
    canvasHeight: opts.canvasHeight == null ? 0 : opts.canvasHeight,
  };

  const elements = {
    'main-document-content': { getBoundingClientRect: () => ({ width: state.mainWidth, height: state.mainHeight }) },
    'document-container': { getBoundingClientRect: () => ({ width: state.docWidth, height: state.docHeight }) },
    'document-canvas': { width: 300, height: 150, getBoundingClientRect: () => ({ width: state.canvasWidth, height: state.canvasHeight }) },
  };
  const body = { getBoundingClientRect: () => ({ width: 1280, height: 720 }) };
  const documentElement = { clientWidth: 1280, clientHeight: 720 };

  const loadListeners = [];
  const rafQueue = [];
  const captured = [];
  const handlers = {};
  let resizeCalls = 0;

  const layer = { _docType: opts.docType || 'text' };
  const layout = opts.noOnResize ? {} : {
    onResize: function () {
      resizeCalls++;
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
    innerHeight: 720,
    addEventListener: function (type, fn) { if (type === 'load') loadListeners.push(fn); },
    removeEventListener: function (type, fn) {
      if (type !== 'load') return;
      const index = loadListeners.indexOf(fn);
      if (index >= 0) loadListeners.splice(index, 1);
    },
    COOLMessageHandler: { postMobileMessage: (message) => captured.push(message) },
    requestAnimationFrame: function (fn) {
      rafQueue.push(fn);
      return rafQueue.length;
    },
  };
  if (opts.noRaf) win.requestAnimationFrame = undefined;

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
  eq(env.pendingFrames(), 0, 'no recurring frame remains');
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
  eq(env.captured.length, 1, 'later events cannot post a second packet');
}

// 2. Non-Writer documents are untouched.
{
  const env = makeEnv({ docType: 'spreadsheet' });
  env.inject();
  env.fireLoad();
  env.fireDocLoaded(true);
  env.flushFrame();
  eq(env.resizeCalls(), 0, 'Calc/Impress path is not taken');
  eq(env.captured.length, 0, 'non-Writer posts no geometry');
}

// 3. A stale document/layout identity is refused before the frame runs.
{
  const env = makeEnv({});
  env.inject();
  env.fireLoad();
  env.fireDocLoaded(true);
  env.app.activeDocument = { activeLayout: { onResize: () => { throw new Error('stale-must-not-call'); } } };
  env.applyWriterStatus();
  env.flushFrame();
  eq(env.resizeCalls(), 0, 'stale layout is never invoked');
  eq(env.captured.length, 1, 'stale identity is reported once');
  const packet = parsePacket(env.captured[0]);
  ok(!!packet && packet.sync === 'stale', 'packet records stale refusal');
}

// 4. Missing onResize/requestAnimationFrame fails closed with no call.
{
  const env = makeEnv({ noOnResize: true });
  env.inject();
  env.fireLoad();
  env.fireDocLoaded(true);
  env.flushFrame();
  eq(env.resizeCalls(), 0, 'missing onResize is not callable');
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

console.log('PASS: ' + checks + ' writer viewport-sync checks');
