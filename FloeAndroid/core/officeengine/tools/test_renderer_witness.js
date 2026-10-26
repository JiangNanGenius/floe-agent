#!/usr/bin/env node
/*
 * Focused semantic checks for inject_render_witness.js (the drawImage
 * successful-return wrapper hook chosen by Main, the pinned mobile renderer contract).
 *
 * WHAT THIS IS: a deterministic stub-sandbox test of the witness DECISION
 * LOGIC. The stubs reproduce the pinned payload's observable semantics
 * (single shared container context; visibility hidden->unset only after the
 * draw pass; tile identity via RenderManager.getTiles(); the Tile.js:31 epoch
 * lastRendered init vs BitmapTileManager.js:1805 relative stamp clock-domain
 * split). WHAT THIS IS NOT: device evidence, engine execution, or any claim
 * that a real document rendered.
 *
 * Run: node core/officeengine/tools/test_renderer_witness.js   (exit 0 = all checks passed)
 */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const SNIPPET_PATH = path.join(__dirname, '../src/main/assets/floe-office/renderer-witness.js');
const SNIPPET_SRC = fs.readFileSync(SNIPPET_PATH, 'utf8');

let failures = 0;
let checks = 0;
function ok(cond, name) {
  checks++;
  if (!cond) { failures++; console.log('FAIL: ' + name); }
  else console.log('pass: ' + name);
}
function eq(a, b, name) { ok(a === b, name + ' (got ' + JSON.stringify(a) + ', want ' + JSON.stringify(b) + ')'); }

// 0. The nonce token occurs EXACTLY once in the shipped snippet (code line),
//    so a single textual replacement by native is unambiguous.
eq(SNIPPET_SRC.split('__FLOE_NONCE_JSON__').length - 1, 1, 'nonce token occurs exactly once in snippet');

// ---------------------------------------------------------------- sandbox ---
function makeSandbox(opts) {
  opts = opts || {};
  const captured = [];
  const rafQueue = [];
  const domContentLoaded = [];

  const canvas = {
    width: opts.canvasWidth != null ? opts.canvasWidth : 1080,
    height: opts.canvasHeight != null ? opts.canvasHeight : 1600,
    style: { visibility: opts.initialVisibility || 'hidden' },
    isConnected: opts.canvasAttached !== false,
    getBoundingClientRect: function () { return { width: this.width, height: this.height }; },
  };

  // Context stub. Two variants: own drawImage property (default) or
  // prototype-inherited (to exercise the delete-restore path).
  const proto = {};
  let throwOnDraw = false;
  const originalDrawImage = function drawImage() {
    if (throwOnDraw) throw new Error('simulated-context-failure');
    return undefined;
  };
  const context = opts.protoStyle ? Object.create(proto) : {};
  if (opts.protoStyle) proto.drawImage = originalDrawImage;
  else context.drawImage = originalDrawImage;

  const redrawRequests = [];
  const sectionContainer = {
    canvas: canvas,
    context: context,
    inRedrawCallback: false,
    requestReDraw: function () { redrawRequests.push(Date.now()); },
  };

  const tileStateListeners = [];
  const tiles = new Map(); // key -> {image, distanceFromView, lastRendered}
  const RenderManager = {
    getTiles: () => tiles,
    onTileStateChanged: (cb) => tileStateListeners.push(cb),
    offTileStateChanged: (cb) => {
      const i = tileStateListeners.indexOf(cb);
      if (i >= 0) tileStateListeners.splice(i, 1);
    },
    isVectorRendering: () => false,
  };

  const observers = [];
  class MutationObserverStub {
    constructor(cb) { this.cb = cb; this.targets = []; this.disconnected = false; observers.push(this); }
    observe(t, o) { this.targets.push({ t, o }); }
    disconnect() { this.disconnected = true; }
    fire() { if (!this.disconnected) this.cb([], this); }
  }

  const documentStub = {
    readyState: opts.readyState || 'complete',
    documentElement: { nodeName: 'html' },
    body: { nodeName: 'body' },
    getElementById: (id) => (id === 'document-canvas' && opts.canvasAttached !== false ? canvas : null),
    addEventListener: (ev, fn) => { if (ev === 'DOMContentLoaded') domContentLoaded.push(fn); },
  };

  const performanceStub = {
    timeOrigin: 1793000000000, // epoch ms, like a real page
    now: () => 1234.5,         // relative ms — the clock-domain split
  };

  const sandbox = {
    performance: performanceStub,
    getComputedStyle: c => ({ visibility: c.style.visibility, display: 'block' }),
    document: documentStub,
    MutationObserver: MutationObserverStub,
    requestAnimationFrame: (fn) => { rafQueue.push(fn); return rafQueue.length; },
    cancelAnimationFrame: () => {},
    app: {
      sectionContainer: opts.noContainer ? null : sectionContainer,
      file: { fileBasedView: false },
      activeDocument: { activeLayout: { type: 'ViewLayoutWriter' } },
      map: { _docLoaded: true },
    },
    RenderManager: RenderManager,
    COOLMessageHandler: { postMobileMessage: (m) => captured.push(m) },
    console: console,
  };
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);

  return {
    sandbox, captured, canvas, context, originalDrawImage, sectionContainer,
    tiles, tileStateListeners, redrawRequests, observers, domContentLoaded,
    setThrow: (v) => { throwOnDraw = v; },
    fireDomContentLoaded: () => { while (domContentLoaded.length) domContentLoaded.shift()(); },
    fireAllObservers: () => { observers.slice().forEach((o) => o.fire()); },
    inject: (nonceJson) => {
      // replace-all semantics (Kotlin String.replace also replaces all);
      // the exact token must occur exactly once in the snippet (code line).
      const src = SNIPPET_SRC.split('__FLOE_NONCE_JSON__').join(nonceJson);
      return vm.runInContext(src, sandbox, { filename: 'inject_render_witness.js' });
    },
    // Simulate one engine draw pass through the (possibly wrapped) context.
    drawPass: (entries, flipVisibility) => {
      for (const e of entries) sandbox_eval_draw(context, e);
      if (flipVisibility) { canvas.style.visibility = 'unset'; }
    },
    flushRaf: () => { while (rafQueue.length) rafQueue.shift()(performanceStub.now()); },
  };
}
function sandbox_eval_draw(context, image) { context.drawImage(image, 0, 0, 256, 256, 0, 0, 256, 256); }

const PACKET_RE = /^floe-renderwitness nonce=(\S+) kind=(ready|pending) draws=(\d+) width=(\d+) height=(\d+)$/;
function parsePacket(s) {
  const m = PACKET_RE.exec(s);
  if (!m) return null;
  return { nonce: m[1], kind: m[2], draws: parseInt(m[3], 10), width: parseInt(m[4], 10), height: parseInt(m[5], 10), raw: s };
}

// ------------------------------------------------------------------ cases ---

// 1. Fail-closed unreplaced token: no global created, error returned.
{
  const env = makeSandbox({});
  const r = vm.runInContext(SNIPPET_SRC, env.sandbox, { filename: 'raw' });
  ok(typeof r === 'string' && r.startsWith('error:'), 'unreplaced nonce token fails closed with error result');
  ok(env.sandbox.__floeRenderWitness === undefined, 'unreplaced token installs no global witness');
}

// 2. Install before engine exists, then canvasCreated -> installed, pending only.
{
  const env = makeSandbox({ noContainer: true, canvasAttached: false, readyState: 'loading' });
  const r = env.inject('"tokA:1"');
  eq(r, 'installed', 'install returns installed');
  env.fireDomContentLoaded();
  eq(env.sandbox.__floeRenderWitness.installed, false, 'not installed while sectionContainer missing');
  // Engine brings up canvas + container (CanvasTileLayer._setup equivalent).
  env.sandbox.app.sectionContainer = {
    canvas: env.canvas, context: env.context, inRedrawCallback: false,
    requestReDraw: () => env.redrawRequests.push(1),
  };
  env.canvas.width = 1080; env.canvas.height = 1600; env.canvas.isConnected = true;
  env.fireAllObservers(); // bodyMo sees the canvas appear
  eq(env.sandbox.__floeRenderWitness.installed, true, 'install completes on canvas-creation mutation');
  eq(env.captured.length, 0, 'no push before ready (pending is pull-only)');
  const q = parsePacket(env.sandbox.__floeRenderWitness.query());
  ok(q && q.kind === 'pending' && q.draws === 0, 'query pending with draws=0 after install');
}

// 3. Skeleton-only pass: visibility flips, NO tile draw -> stays pending.
{
  const env = makeSandbox({});
  env.inject('"tokB:1"');
  // First pass paints skeleton (fills/rects, no drawImage) then flips visibility.
  env.canvas.style.visibility = 'unset';
  env.fireAllObservers();
  const q = parsePacket(env.sandbox.__floeRenderWitness.query());
  ok(q && q.kind === 'pending' && q.draws === 0, 'skeleton-only pass (no drawImage) stays pending');
  eq(env.captured.length, 0, 'skeleton-only pass pushes nothing');
}

// 4. Non-tile image + non-viewport tile draws are NOT counted.
{
  const env = makeSandbox({});
  env.inject('"tokC:1"');
  const tileImgVisible = { tag: 'tile-visible' };
  const tileImgFar = { tag: 'tile-far' };
  env.tiles.set('k1', { image: tileImgVisible, distanceFromView: 0, lastRendered: env.sandbox.performance.timeOrigin });
  env.tiles.set('k2', { image: tileImgFar, distanceFromView: 4242, lastRendered: 999 });
  env.context.drawImage({ tag: 'gif-frame' }, 0, 0);        // non-tile image
  env.context.drawImage(tileImgFar, 0, 0);                   // tile but not viewport
  const q = parsePacket(env.sandbox.__floeRenderWitness.query());
  ok(q && q.draws === 0 && q.kind === 'pending', 'non-tile and non-viewport draws not counted');
  // Throwing draw of the visible tile: not counted, throw propagates.
  env.setThrow(true);
  let threw = false;
  try { env.context.drawImage(tileImgVisible, 0, 0); } catch (e) { threw = true; }
  ok(threw, 'drawImage exception propagates to caller');
  env.setThrow(false);
  const q2 = parsePacket(env.sandbox.__floeRenderWitness.query());
  eq(q2.draws, 0, 'throwing draw not counted (successful-return semantics)');
}

// 5. Happy path incl. blank (pure-white) tile: draw counted, pass completes -> ready push.
{
  const env = makeSandbox({});
  env.inject('"tokD:7"');
  const blankWhiteTile = { tag: 'blank-white-bitmap' }; // pixels irrelevant: identity gate
  env.tiles.set('k1', {
    image: blankWhiteTile, distanceFromView: 0,
    // stale clock-domain values must not matter at all:
    lastRendered: env.sandbox.performance.timeOrigin,
  });
  env.context.drawImage(blankWhiteTile, 0, 0, 256, 256, 10, 10, 256, 256);
  let q = parsePacket(env.sandbox.__floeRenderWitness.query());
  ok(q && q.draws === 1 && q.kind === 'pending', 'draw counted while canvas still hidden (pass incomplete)');
  env.canvas.style.visibility = 'unset'; // redrawCallback post-drawSections flip
  env.fireAllObservers();
  eq(env.captured.length, 1, 'exactly one ready push');
  const p = parsePacket(env.captured[0]);
  ok(!!p, 'push packet matches frozen 5-field format exactly');
  if (p) {
    eq(p.nonce, 'tokD:7', 'nonce echoed');
    eq(p.kind, 'ready', 'kind=ready');
    eq(p.draws, 1, 'draws=1');
    eq(p.width, 1080, 'width from canvas');
    eq(p.height, 1600, 'height from canvas');
  }
  // Wrapper restored exactly; observers torn down; listener removed.
  ok(env.context.drawImage === env.originalDrawImage, 'context.drawImage restored to exact original after proof');
  ok(env.observers.every((o) => o.disconnected), 'observers disconnected after ready');
  eq(env.tileStateListeners.length, 0, 'tile-state listener removed after ready');
  // Sticky proof + no duplicate push on later draws/mutations.
  env.tiles.set('k2', { image: blankWhiteTile, distanceFromView: 0, lastRendered: 5 });
  env.canvas.style.visibility = 'hidden'; env.fireAllObservers();
  const q2 = parsePacket(env.sandbox.__floeRenderWitness.query());
  eq(q2.kind, 'ready', 'query after ready retains owned proof');
  eq(env.captured.length, 1, 'no duplicate push after ready');
}

// 6. Clock-domain regression documentation: identical outcomes for epoch vs
//    relative lastRendered stamps (the superseded predicate's failure mode).
{
  const envA = makeSandbox({});
  envA.inject('"tokE:1"');
  const img = { tag: 't' };
  envA.tiles.set('k', { image: img, distanceFromView: 0, lastRendered: envA.sandbox.performance.timeOrigin }); // epoch init
  envA.context.drawImage(img, 0, 0);
  envA.canvas.style.visibility = 'unset'; envA.fireAllObservers();
  const rA = parsePacket(envA.sandbox.__floeRenderWitness.query()).kind;

  const envB = makeSandbox({});
  envB.inject('"tokE:1"');
  envB.tiles.set('k', { image: img, distanceFromView: 0, lastRendered: 7 }); // relative stamp
  envB.context.drawImage(img, 0, 0);
  envB.canvas.style.visibility = 'unset'; envB.fireAllObservers();
  const rB = parsePacket(envB.sandbox.__floeRenderWitness.query()).kind;
  eq(rA, 'ready', 'epoch-stamped tile: ready via draw-return witness');
  eq(rB, 'ready', 'relative-stamped tile: ready via draw-return witness');
  ok(rA === rB, 'gate independent of lastRendered clock domain (superseded predicate was not)');
}

// 7. Late install: visibility already unset, one requestReDraw, fresh witness.
{
  const env = makeSandbox({ initialVisibility: 'unset' });
  const r = env.inject('"tokF:2"');
  eq(r, 'installed', 'late install returns installed');
  eq(env.redrawRequests.length, 1, 'late install requests exactly one normal redraw');
  const img = { tag: 'late-tile' };
  env.tiles.set('k', { image: img, distanceFromView: 0, lastRendered: env.sandbox.performance.timeOrigin });
  eq(parsePacket(env.sandbox.__floeRenderWitness.query()).kind, 'pending', 'stale stamps alone never ready');
  env.context.drawImage(img, 0, 0); // the requested redraw pass
  eq(env.captured.length, 0, 'late draw waits for the completed frame callback');
  env.flushRaf();
  eq(env.captured.length, 1, 'ready pushed after newly witnessed draw');
  eq(parsePacket(env.captured[0]).kind, 'ready', 'late-install ready packet');
}

// 8. Duplicate injection same nonce -> 'dup', single wrapper.
{
  const env = makeSandbox({});
  env.inject('"tokG:1"');
  const r2 = env.inject('"tokG:1"');
  eq(r2, 'dup', 'same-nonce re-injection returns dup');
  const img = { tag: 'x' };
  env.tiles.set('k', { image: img, distanceFromView: 0, lastRendered: 1 });
  env.context.drawImage(img, 0, 0);
  eq(parsePacket(env.sandbox.__floeRenderWitness.query()).draws, 1, 'no double counting after dup injection');
}

// 9. New-nonce re-injection: old cancelled/restored, fresh witness owns new nonce.
{
  const env = makeSandbox({});
  env.inject('"tokH:1"');
  const first = env.sandbox.__floeRenderWitness;
  const r = env.inject('"tokH:2"');
  eq(r, 'installed', 'new-nonce injection installs fresh witness');
  ok(first.cancelled, 'old witness cancelled by re-injection');
  const img = { tag: 'y' };
  env.tiles.set('k', { image: img, distanceFromView: 0, lastRendered: 1 });
  env.context.drawImage(img, 0, 0);
  env.canvas.style.visibility = 'unset'; env.fireAllObservers();
  eq(env.captured.length, 1, 'only the fresh witness pushes');
  eq(parsePacket(env.captured[0]).nonce, 'tokH:2', 'ready packet carries the NEW nonce');
}

// 10. cancel(): restores wrapper, no further counting or pushes.
{
  const env = makeSandbox({});
  env.inject('"tokI:1"');
  const w = env.sandbox.__floeRenderWitness;
  w.cancel();
  ok(env.context.drawImage === env.originalDrawImage, 'cancel restores exact original drawImage');
  const img = { tag: 'z' };
  env.tiles.set('k', { image: img, distanceFromView: 0, lastRendered: 1 });
  env.context.drawImage(img, 0, 0);
  env.canvas.style.visibility = 'unset'; env.fireAllObservers();
  eq(env.captured.length, 0, 'cancel: never sends readiness afterwards');
  const q = parsePacket(w.query());
  ok(q && q.kind === 'pending' && q.draws === 0, 'cancelled witness stays pending with draws=0');
}

// 11. Prototype-inherited drawImage: restore via delete leaves prototype intact.
{
  const env = makeSandbox({ protoStyle: true });
  env.inject('"tokJ:1"');
  const img = { tag: 'proto' };
  env.tiles.set('k', { image: img, distanceFromView: 0, lastRendered: 1 });
  env.context.drawImage(img, 0, 0);
  env.canvas.style.visibility = 'unset'; env.fireAllObservers();
  eq(parsePacket(env.captured[0] || '').kind, 'ready', 'proto-style context reaches ready');
  ok(!Object.prototype.hasOwnProperty.call(env.context, 'drawImage'),
     'restore deletes own wrapper when drawImage was prototype-inherited');
  ok(typeof env.context.drawImage === 'function', 'prototype drawImage still callable after restore');
}

// 12. Zero-size canvas never ready (positive width/height requirement).
{
  const env = makeSandbox({ canvasWidth: 0, canvasHeight: 0 });
  env.inject('"tokK:1"');
  const img = { tag: 's' };
  env.tiles.set('k', { image: img, distanceFromView: 0, lastRendered: 1 });
  env.context.drawImage(img, 0, 0);
  env.canvas.style.visibility = 'unset'; env.fireAllObservers();
  eq(parsePacket(env.sandbox.__floeRenderWitness.query()).kind, 'pending', 'zero-size canvas stays pending');
  env.canvas.width = 1080; env.canvas.height = 1600; env.canvas.isConnected = true;
  env.fireAllObservers();
  eq(parsePacket(env.sandbox.__floeRenderWitness.query()).kind, 'ready', 'sized canvas completes ready');
}

// Full-pass regression: a prior skeleton may already be visible. A tile
// draw in the next, still-running/throwing section pass must not grant ready.
{
  const env = makeSandbox({ initialVisibility: 'unset' });
  env.inject('"fullpass:1"');
  const image = { tag: 'blank-document-tile' };
  env.tiles.set('visible', { image, distanceFromView: 0 });
  env.sandbox.app.sectionContainer.inRedrawCallback = true;
  env.context.drawImage(image, 0, 0);
  eq(parsePacket(env.sandbox.__floeRenderWitness.query()).kind, 'pending', 'mid-pass visible canvas is not complete');
  env.flushRaf();
  eq(parsePacket(env.sandbox.__floeRenderWitness.query()).kind, 'pending', 'a later section failure leaving draw-in-progress cannot grant ready');
  env.sandbox.app.sectionContainer.inRedrawCallback = false;
  eq(parsePacket(env.sandbox.__floeRenderWitness.query()).kind, 'ready', 'completed pass with real blank tile reaches ready');
}
{
  const env = makeSandbox({ initialVisibility: 'unset' });
  env.inject('"layout:1"');
  const image = { tag: 'tile' };
  env.tiles.set('visible', { image, distanceFromView: 0 });
  env.canvas.isConnected = false;
  env.context.drawImage(image, 0, 0);
  env.flushRaf();
  eq(parsePacket(env.sandbox.__floeRenderWitness.query()).kind, 'pending', 'detached canvas never grants ready');
  env.canvas.isConnected = true;
  eq(parsePacket(env.sandbox.__floeRenderWitness.query()).kind, 'ready', 'owned connected canvas can finish');
}

console.log('---');
console.log('checks=' + checks + ' failures=' + failures);
process.exit(failures ? 1 : 0);
