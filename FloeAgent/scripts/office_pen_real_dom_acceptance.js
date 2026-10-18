/*
 * Real-DOM -> core acceptance injector for the Floe Office pen-input overlay.
 *
 * Purpose: let the integration owner (root) verify, inside the REAL editor
 * WKWebView of a rebuilt host, that an injected PointerEvent with
 * pointerType 'pen' travels through the injected overlay and the pinned
 * frontend's own event path into core `mouse type=...` socket messages,
 * instead of calling `_postMouseEvent` directly (which would bypass the very
 * bridge under test).
 *
 * Usage (root, in the live editor web view, drawing mode already armed via the
 * App's toggleDrawing):
 *   1. evaluate OFFICE_PEN_ACCEPTANCE_INSTALL (below) once; it wraps
 *      window.app.socket.sendMessage and returns a recorder handle.
 *   2. evaluate OFFICE_PEN_ACCEPTANCE_RUN; it dispatches two real
 *      PointerEvent pen strokes at document coordinates and returns the
 *      recorded `mouse ...` messages plus window.__floeOfficePenState().
 *
 * Acceptance: the returned mouse messages must contain, in order, at least
 *   mouse type=buttondown ... buttons=1
 *   mouse type=move ... buttons=1        (one or more)
 *   mouse type=buttonup ... buttons=0
 * for EACH injected stroke, with x/y following the injected client
 * coordinates through the frontend's own canvas->document conversion. A
 * finger stroke (pointerType 'touch') injected the same way must produce no
 * core mouse messages and must still scroll/navigate.
 *
 * Live-ink + navigation acceptance (new in this round):
 *   evaluate OFFICE_PEN_LIVE_RUN while a synthetic pen contact is still
 *   down (no pointerup): window.__floeOfficePenPreview() must report the
 *   live SVG path (stroke true, ordered points, style matching
 *   __floeOfficeInkLastDispatch.expected mapped through
 *   app.twipsToPixels/app.dpiScale) and the composited canvas must show a
 *   WK snapshot delta; after pointerup the preview path must remain until
 *   the geometric paint probe clears it (lastPreviewClear 'painted'), never
 *   'timeout' on a healthy renderer, and the saved document must contain
 *   exactly the canonical vectors (root's App tests assert custGeom counts).
 *   OFFICE_PEN_TOUCH_ARBITRATION dispatches a real first-finger ->
 *   second-finger -> pinch-move -> touchend TouchEvent sequence through the
 *   actual pinned handlers while drawing mode is ON with no pen contact:
 *   no event may be defaultPrevented by the gate, the container's own
 *   touchEventInProgress must be left set exactly as the pinned code does,
 *   a following full pen contact must still replay (the gate's
 *   touch->Pencil recovery clears the flag before each replayed mouse
 *   event), and the finger sequence itself must produce no core mouse
 *   messages.
 *   OFFICE_PEN_WRITER_INSET returns the Writer page-top inset compensation
 *   inputs (docType, pageRectangleList[0], twipsToPixels/dpiScale, the
 *   derived CSS inset, viewedRectangle, anchor, canvas geometry, text
 *   cursor) plus the gate's applied writerInsetTwips/writerPageOriginTwips,
 *   for the real-App alignment assertions described at its definition.
 *
 * This is not device Pencil acceptance: pressure, haptics, real pinch feel,
 * actual pixel paint and physical WebKit pointer/touch interop remain with
 * device testing. Synthetic TouchEvent dispatch here exercises the pinned
 * handler chain, not iOS gesture plumbing.
 */
const OFFICE_PEN_ACCEPTANCE_INSTALL = `(() => {
  const map = window.app && window.app.map;
  const socket = map && map.socket;
  if (!socket || typeof socket.sendMessage !== 'function')
    return { ok: false, reason: 'socket-unavailable' };
  if (window.__floePenAcceptanceInstalled) return { ok: true, already: true };
  window.__floePenAcceptanceInstalled = true;
  window.__floePenAcceptanceMouse = [];
  const original = socket.sendMessage.bind(socket);
  socket.sendMessage = (message, ...rest) => {
    if (typeof message === 'string' && message.indexOf('mouse ') === 0)
      window.__floePenAcceptanceMouse.push(message);
    return original(message, ...rest);
  };
  window.__floePenAcceptanceReset = () => { window.__floePenAcceptanceMouse.length = 0; };
  return { ok: true };
})()`;

const OFFICE_PEN_ACCEPTANCE_RUN = `(() => {
  const target = window;
  const fire = (type, x, y) => target.dispatchEvent(new PointerEvent(type, {
    pointerType: 'pen', isPrimary: true, pointerId: 77,
    clientX: x, clientY: y, button: 0, buttons: type === 'pointerup' ? 0 : 1,
    bubbles: true, cancelable: true, view: window
  }));
  const stroke = (x0, y0) => {
    fire('pointerdown', x0, y0);
    fire('pointermove', x0 + 8, y0 + 6);
    fire('pointermove', x0 + 16, y0 + 12);
    fire('pointerup', x0 + 20, y0 + 16);
  };
  if (typeof window.__floePenAcceptanceReset === 'function') window.__floePenAcceptanceReset();
  stroke(300, 400);
  stroke(340, 460);
  return {
    mouse: (window.__floePenAcceptanceMouse || []).slice(),
    penState: window.__floeOfficePenState ? window.__floeOfficePenState() : null
  };
})()`;

// Live-ink presentation check. Run this while the contact is still down:
// it injects a pen contact plus three trusted moves (one animation frame
// apart), snapshots the gate's own preview state, and returns a function
// that completes the contact. The caller must see stroke=true with ordered
// points BEFORE invoking finish(), then a 'painted' clear after the engine
// repaints. The preview must match the bridge's verified scalars and the
// live zoom scale, and must never consume coalesced or predicted samples.
const OFFICE_PEN_LIVE_RUN = `(async () => {
  const canvas = window.app && window.app.sectionContainer && window.app.sectionContainer.canvas;
  const penState = window.__floeOfficePenState && window.__floeOfficePenState();
  if (!canvas || !penState || !penState.drawing)
    return { ok: false, reason: 'surface-unavailable' };
  const rect = canvas.getBoundingClientRect();
  const x = rect.left + rect.width * 0.4, y = rect.top + rect.height * 0.6;
  const send = (type, px, py, buttons) => canvas.dispatchEvent(new PointerEvent(type, {
    bubbles: true, cancelable: true, composed: true, pointerType: 'pen',
    pointerId: 555, isPrimary: true, clientX: px, clientY: py,
    button: 0, buttons, pressure: buttons ? 0.5 : 0
  }));
  const frame = () => new Promise((resolve) => requestAnimationFrame(resolve));
  send('pointerdown', x, y, 1);
  for (let i = 1; i <= 3; i += 1) { send('pointermove', x + i * 12, y + i * 6, 1); await frame(); }
  const during = {
    preview: window.__floeOfficePenPreview ? window.__floeOfficePenPreview() : null,
    penState: window.__floeOfficePenState(),
    expectedStyle: (window.__floeOfficeInkLastDispatch || {}).expected || null,
    twipsToPixels: (window.app && window.app.twipsToPixels) || null,
    dpiScale: (window.app && window.app.dpiScale) || null
  };
  window.__floeLiveRunFinish = () => {
    send('pointerup', x + 48, y + 24, 0);
    delete window.__floeLiveRunFinish;
    return window.__floeOfficePenPreview();
  };
  window.__floeLiveRunInspect = () => window.__floeOfficePenPreview();
  return { ok: true, during };
})()`;

// Touch arbitration + touch->Pencil transition. Requires
// OFFICE_PEN_ACCEPTANCE_INSTALL first: run reset, evaluate this (it drives
// a real two-finger pinch through the pinned container's own ontouch*
// handlers with drawing mode ON and no pen contact), then compare the
// recorded socket messages and the zoom delta. Acceptance: nothing in the
// touch phase produces core mouse messages; the first finger's touchstart
// is not defaultPrevented by the gate; app.map.getZoom() changes on pinch;
// container.touchEventInProgress is true afterwards (the pinned onTouchEnd
// line 1558); the immediately following full pen contact DOES produce the
// canonical buttondown/move/up sequence because the gate restores that one
// flag before each replay; and the whole run adds no finger ink.
const OFFICE_PEN_TOUCH_ARBITRATION = `(() => {
  const canvas = window.app && window.app.sectionContainer && window.app.sectionContainer.canvas;
  const container = window.app && window.app.sectionContainer;
  const penState = window.__floeOfficePenState && window.__floeOfficePenState();
  if (!canvas || !container || !penState || !penState.drawing)
    return { ok: false, reason: 'surface-unavailable' };
  const rect = canvas.getBoundingClientRect();
  const cx = rect.left + rect.width * 0.5, cy = rect.top + rect.height * 0.5;
  const mkTouch = (id, x, y) => new Touch({
    identifier: id, target: canvas, clientX: x, clientY: y,
    pageX: x, pageY: y, screenX: x, screenY: y
  });
  const dispatchTouch = (type, ids) => {
    const touches = ids.map((id) => mkTouch(id[0], id[1], id[2]));
    const event = new TouchEvent(type, {
      bubbles: true, cancelable: true,
      touches, targetTouches: touches, changedTouches: touches.slice(-1)
    });
    canvas.dispatchEvent(event);
    return { prevented: event.defaultPrevented, zoom: window.app.map.getZoom() };
  };
  const a = [1, cx - 60, cy], b = [2, cx + 60, cy];
  const steps = [];
  steps.push(['first-touchstart', dispatchTouch('touchstart', [a])]);
  steps.push(['second-touchstart', dispatchTouch('touchstart', [a, b])]);
  steps.push(['pinch-move-1', dispatchTouch('touchmove', [
    [1, cx - 60, cy], [2, cx + 140, cy]])]);
  steps.push(['pinch-move-2', dispatchTouch('touchmove', [
    [1, cx - 60, cy], [2, cx + 260, cy]])]);
  steps.push(['touchend', dispatchTouch('touchend', [])]);
  const zoomAfter = window.app.map.getZoom();
  const flagAfterPinch = container.touchEventInProgress === true;
  const before = (window.__floePenAcceptanceMouse || []).length;
  const x = rect.left + rect.width * 0.35, y = rect.top + rect.height * 0.62;
  const send = (type, px, py, buttons) => canvas.dispatchEvent(new PointerEvent(type, {
    bubbles: true, cancelable: true, composed: true, pointerType: 'pen',
    pointerId: 556, isPrimary: true, clientX: px, clientY: py,
    button: 0, buttons, pressure: buttons ? 0.5 : 0
  }));
  send('pointerdown', x, y, 1); send('pointermove', x + 14, y + 6, 1); send('pointerup', x + 24, y + 10, 0);
  const mouse = (window.__floePenAcceptanceMouse || []).slice(before);
  return {
    ok: true, steps, zoomAfter, zoomChanged: steps[0][1].zoom !== zoomAfter,
    flagAfterPinch,
    recoveredForPen: container.touchEventInProgress === false,
    penMouseAfterTouch: mouse,
    penState: window.__floeOfficePenState()
  };
})()`;

// Writer page-top inset alignment diagnostic (2026-10-19 ghosting round).
// Evaluate in the live editor web view (any time; ideally before a stroke,
// after arming drawing mode, and after a stroke settles). It returns every
// input the gate's derived Writer compensation uses plus the gate's own
// applied value, so the App run can assert:
//   - docType === 'text' documents: gateState.writerInsetTwips equals
//     [0, pageY] when the top inset is in bounds, else null (fail-open);
//     gateState.writerPageOriginTwips preserves the raw [pageX, pageY] pair.
//     Page X is diagnostic only and is never subtracted from the replay:
//     the C5 build subtracted both axes and the actual App measured Word
//     X drift 19.3 CSS (38.8 after pinch) against a raw-X 0.75 CSS baseline;
//   - derivedInsetCss is the APPLIED [0, pageY] inset. After the corrected
//     stroke the canonical-canvas drift metric must fall from ~17.24 css px
//     on Y (measured 2026-10-19, page top ~278 twips at zoom 100/dpr 2) to
//     the strict tolerance while X stays at the raw-pointer baseline. The
//     C5 test aborted at X before its Y assertion, but root's exported C5
//     attachments measured Y drift 1.76 CSS (plain/rapid) and 3.26 CSS
//     (post-pinch); the corrected run must still reach/pass the unchanged
//     Y assertion;
//   - spreadsheet/presentation documents: pageRect0 null or unused and
//     writerInsetTwips null (controls must stay untouched);
//   - textCaretCheck: a MOUSE (not pen, not drawing mode) click on a text
//     line followed by reading app.file.textCursor.rectangle tells whether
//     the writer window-origin shift also affects text placement (open
//     question in the handoff; the gate compensation only ever touches the
//     replayed pen stream in drawing mode).
const OFFICE_PEN_WRITER_INSET = `(() => {
  const app = window.app || {};
  const docLayer = app.map && app.map._docLayer;
  const pages = app.file && app.file.writer && app.file.writer.pageRectangleList;
  const first = pages && pages.length ? pages[0] : null;
  const ttP = Number(app.twipsToPixels);
  const dpr = Number(app.dpiScale);
  const scaleOk = Number.isFinite(ttP) && ttP > 0 && Number.isFinite(dpr) && dpr > 0;
  const stateFn = window.__floeOfficePenState;
  const canvas = app.sectionContainer && app.sectionContainer.canvas;
  let canvasInfo = null;
  if (canvas && typeof canvas.getBoundingClientRect === 'function') {
    const r = canvas.getBoundingClientRect();
    canvasInfo = { left: r.left, top: r.top, width: r.width, height: r.height,
                   backing: [canvas.width, canvas.height] };
  }
  const vr = app.activeDocument && app.activeDocument.activeLayout
    && app.activeDocument.activeLayout.viewedRectangle;
  return {
    docType: docLayer ? docLayer._docType : null,
    pageCount: pages ? pages.length : 0,
    pageRect0: first ? [first[0], first[1], first[2], first[3]] : null,
    twipsToPixels: scaleOk ? ttP : null,
    dpiScale: scaleOk ? dpr : null,
    derivedInsetCss: (first && scaleOk)
      ? [0, Number(first[1]) * ttP / dpr] : null,
    viewedRect: vr ? { x1: vr.x1, y1: vr.y1, width: vr.width, height: vr.height } : null,
    anchor: (app.sectionContainer && typeof app.sectionContainer.getDocumentAnchor === 'function')
      ? app.sectionContainer.getDocumentAnchor() : null,
    textCursor: (app.file && app.file.textCursor && app.file.textCursor.rectangle)
      ? [app.file.textCursor.rectangle.x1, app.file.textCursor.rectangle.y1,
         app.file.textCursor.rectangle.x2, app.file.textCursor.rectangle.y2] : null,
    gateState: stateFn ? stateFn() : null,
    canvas: canvasInfo
  };
})()`;

module.exports = {
  OFFICE_PEN_ACCEPTANCE_INSTALL,
  OFFICE_PEN_ACCEPTANCE_RUN,
  OFFICE_PEN_LIVE_RUN,
  OFFICE_PEN_TOUCH_ARBITRATION,
  OFFICE_PEN_WRITER_INSET,
};
