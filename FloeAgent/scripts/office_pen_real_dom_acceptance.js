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
 * This is not device Pencil acceptance: pressure, haptics and real WebKit
 * pointer routing remain with physical-device testing.
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

module.exports = { OFFICE_PEN_ACCEPTANCE_INSTALL, OFFICE_PEN_ACCEPTANCE_RUN };
