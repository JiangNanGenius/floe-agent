// SPDX-License-Identifier: MPL-2.0
// Floe G05-R1 first-document-paint witness for the pinned Collabora mobile
// dist (APK 26.04.4.2 code937, source commit 2333344185...). Candidate for
// WebView.evaluateJavascript — NOT installed anywhere by this lane.
//
// Contract: main-render-integration/READINESS_PROTOCOL.md (frozen).
//   * Native replaces the SINGLE nonce token — the exact identifier on the
//     `const NONCE = ...;` line below, which is its only occurrence in this
//     file — with a JSON-quoted "<sessionToken>:<generation>" string. Left
//     unreplaced, the snippet fails closed at runtime (caught ReferenceError
//     -> returns 'error:...' before any global is created); no reusable
//     global nonce is baked in.
//   * Packet (push on ready transition + query() return, same string):
//     floe-renderwitness nonce=<nonce> kind=<ready|pending> draws=<N> width=<W> height=<H>
//   * window.__floeRenderWitness exposes query() and cancel().
//
// Hook (Main architecture decision 2026-10-26): a successful-return wrapper on
// ONLY app.sectionContainer.context.drawImage (the single shared 2D context of
// #document-canvas: CanvasSectionContainer.js:215-216 stores canvas+context
// (alpha:false), :1880 `newSection.context = this.context` gives every section
// the SAME context object; TilesSection pane drawing also targets it,
// TilesSection.js:75; `_paintContext()` is pane geometry, not another context,
// CanvasTileLayer.js:33-58). No global Canvas prototype is touched and
// getContext is never called by the witness (so alpha attributes cannot
// change). The wrapper counts a draw ONLY when the original drawImage RETURNS
// without throwing AND the drawn image is identity-identical to `tile.image`
// of a current RenderManager.getTiles() entry with distanceFromView === 0 —
// i.e. an actual visible document tile bitmap committed by
// TilesSection.drawTileToCanvasCrop (TilesSection.js:617-623).
// Ready additionally requires the completed full draw pass / visible canvas:
// CanvasSectionContainer.redrawCallback sets visibility 'hidden'->'unset'
// ONLY after drawSections() returned (CanvasSectionContainer.js:611-627), so
// a throwing draw pass leaves the canvas hidden and the gate false; plus
// positive canvas width/height.
//
// SUPERSEDED FINDING (retained per Main): the earlier lastRendered-counter
// gate was wrong in clock domains — Tile.js:31 initializes
// `lastRendered = performance.timeOrigin` (epoch ms) while
// BitmapTileManager.js:1805 touchImage writes `performance.now()` (relative
// ms), so `lastRendered > timeOrigin` can never become true; and touchImage
// runs BEFORE drawImage ("about to render" comment, BitmapTileManager.ts:2390),
// i.e. it is an issue stamp, not a successful-return counter. This hook does
// not read lastRendered at all.
//
// Late installation (after the first pass already painted): the witness
// requests ONE normal app.sectionContainer.requestReDraw() so a successful
// draw return is newly witnessed through the wrapper; stale stamps are never
// trusted. No polling anywhere: installation is event-driven
// (DOMContentLoaded / canvas-creation MutationObserver / tile-state listener),
// readiness is draw-return + canvas-style MutationObserver + native query().
// Teardown restores the exact context (delete own property, or reassign the
// saved own value) after proof or cancel.
(() => {
  try {
    const NONCE = __FLOE_NONCE_JSON__;

    const existing = window.__floeRenderWitness;
    if (existing && existing.installed && existing.nonce === NONCE) return 'dup';
    if (existing && typeof existing.cancel === 'function') {
      try { existing.cancel(); } catch (_) {}
    }

    const W = {
      installed: false, cancelled: false, ready: false,
      nonce: NONCE, draws: 0,
      listener: null, rafPending: false,
    };
    window.__floeRenderWitness = W;
    let bodyMo = null, canvasMo = null, wrapState = null, redrewForLateInstall = false;

    const packet = () => {
      const c = canvasNow();
      const w = c && typeof c.width === 'number' ? c.width : 0;
      const h = c && typeof c.height === 'number' ? c.height : 0;
      return 'floe-renderwitness nonce=' + NONCE +
        ' kind=' + (W.ready ? 'ready' : 'pending') +
        ' draws=' + W.draws + ' width=' + w + ' height=' + h;
    };

    const send = (str) => {
      if (W.cancelled) return;
      try {
        if (window.COOLMessageHandler && window.COOLMessageHandler.postMobileMessage)
          window.COOLMessageHandler.postMobileMessage(str);
        else if (window.postMobileMessage) window.postMobileMessage(str);
      } catch (_) { /* bridge gone during teardown: drop quietly */ }
    };

    const container = () => (window.app && window.app.sectionContainer) || null;
    const canvasNow = () => {
      const sc = container();
      if (sc && sc.canvas) return sc.canvas;
      try { return document.getElementById('document-canvas'); } catch (_) { return null; }
    };

    const restoreWrapper = () => {
      if (!wrapState) return;
      try {
        if (wrapState.ctx.drawImage === wrapState.wrapper) {
          if (wrapState.hadOwn) wrapState.ctx.drawImage = wrapState.original;
          else delete wrapState.ctx.drawImage;
        }
      } catch (_) {}
      wrapState = null;
    };

    const teardown = () => {
      restoreWrapper();
      try { if (W.listener && window.RenderManager && window.RenderManager.offTileStateChanged)
        window.RenderManager.offTileStateChanged(W.listener); } catch (_) {}
      W.listener = null;
      try { if (canvasMo) canvasMo.disconnect(); } catch (_) {}
      try { if (bodyMo) bodyMo.disconnect(); } catch (_) {}
      canvasMo = null; bodyMo = null;
    };

    const passComplete = () => {
      const c = canvasNow();
      const sc = container();
      if (!c || !sc || sc.inRedrawCallback !== false || c.isConnected !== true) return false;
      const style = window.getComputedStyle(c);
      const rect = c.getBoundingClientRect();
      return style.visibility !== 'hidden' && style.visibility !== 'collapse' &&
        style.display !== 'none' && c.width > 0 && c.height > 0 && rect.width > 0 && rect.height > 0;
    };

    const maybeReady = () => {
      if (W.ready || W.cancelled) return;
      if (W.draws >= 1 && passComplete()) {
        W.ready = true;          // sticky owned proof
        teardown();              // restore exact context; no steady-state cost
        send(packet());          // single kind=ready push
      }
    };

    // Successful-return drawImage wrapper on the container context ONLY.
    const countTileDraw = (image) => {
      try {
        const rm = window.RenderManager;
        if (!rm || typeof rm.getTiles !== 'function' || !image) return;
        let matched = false;
        rm.getTiles().forEach((t) => {
          if (!matched && t && t.image === image && t.distanceFromView === 0) matched = true;
        });
        if (matched) {
          W.draws += 1;
          if (!W.rafPending) {
            W.rafPending = true;
            requestAnimationFrame(() => { W.rafPending = false; maybeReady(); });
          }
        }
      } catch (_) { /* counting must never break the engine draw path */ }
    };

    const installWrapper = (sc) => {
      const ctx = sc.context;
      if (!ctx) return false;
      const hadOwn = Object.prototype.hasOwnProperty.call(ctx, 'drawImage');
      const original = ctx.drawImage;
      if (typeof original !== 'function') return false;
      const wrapper = function () {
        const result = original.apply(this, arguments); // throws propagate: NOT counted
        if (!W.ready && !W.cancelled) countTileDraw(arguments[0]);
        return result;
      };
      ctx.drawImage = wrapper;
      wrapState = { ctx: ctx, original: original, hadOwn: hadOwn, wrapper: wrapper };
      return true;
    };

    const armCanvasObserver = () => {
      const c = canvasNow();
      if (!c || canvasMo) return;
      try {
        canvasMo = new MutationObserver(() => { if (!W.ready && !W.cancelled) maybeReady(); });
        canvasMo.observe(c, { attributes: true, attributeFilter: ['style'] });
      } catch (_) { canvasMo = null; }
    };

    const tryInstall = () => {
      if (W.installed || W.cancelled) return;
      const sc = container();
      if (!sc || !sc.context || !sc.canvas) return; // engine not ready: wait for next event
      if (!installWrapper(sc)) return;
      W.installed = true;
      try { if (bodyMo) { bodyMo.disconnect(); bodyMo = null; } } catch (_) {}
      armCanvasObserver();
      // Late install: the first pass may already have painted before the
      // wrapper existed. Request ONE normal redraw so a successful draw
      // return is newly witnessed (never trust stale stamps).
      const c = sc.canvas;
      const vis = (c.style && c.style.visibility) || '';
      if (vis !== 'hidden' && !redrewForLateInstall) {
        redrewForLateInstall = true;
        try { if (typeof sc.requestReDraw === 'function') sc.requestReDraw(); } catch (_) {}
      }
      maybeReady(); // normally pending (draws=0); honest either way
    };

    // Tile-state listener doubles as an install trigger (engine alive) — the
    // maintained public API (RenderManagerBase, consumer PreloadMapOverlay.js:23).
    const armTileStateTrigger = () => {
      try {
        const rm = window.RenderManager;
        if (rm && typeof rm.onTileStateChanged === 'function' && !W.listener) {
          W.listener = () => { if (!W.installed) tryInstall(); };
          rm.onTileStateChanged(W.listener);
        }
      } catch (_) {}
    };

    W.query = () => { maybeReady(); return packet(); };
    W.cancel = () => {
      W.cancelled = true;
      teardown(); // never sends readiness again; query() stays honest (pending
                  // unless a ready proof was already owned before cancel)
    };

    const boot = () => {
      if (W.cancelled) return;
      armTileStateTrigger();
      tryInstall();
      if (!W.installed) {
        // #document-canvas + app.sectionContainer are created synchronously in
        // CanvasTileLayer._setup (CanvasTileLayer.js:263-267); watch for them
        // instead of polling.
        try {
          bodyMo = new MutationObserver(() => { if (!W.installed) tryInstall(); });
          bodyMo.observe(document.documentElement || document.body,
                         { childList: true, subtree: true });
        } catch (_) { bodyMo = null; }
      }
    };

    if (document.readyState === 'loading')
      document.addEventListener('DOMContentLoaded', boot, { once: true });
    else boot();
    return 'installed';
  } catch (e) {
    return 'error:' + String(e && e.message ? e.message : e).slice(0, 80);
  }
})()
