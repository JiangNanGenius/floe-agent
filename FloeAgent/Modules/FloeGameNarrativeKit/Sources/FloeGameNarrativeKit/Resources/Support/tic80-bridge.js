/* SPDX-License-Identifier: MPL-2.0 */
/*
 * FloeGameNarrativeKit TIC-80 bridge (MPL-2.0).
 *
 * The original cartridge is cart.tic (user content). The upstream emscripten
 * player is tic80.js/tic80js.wasm (MIT, unchanged). This bridge forwards the
 * typed FloeGame input/pointer contract as real DOM events to the player's own
 * canvas listeners; it does not evaluate project code itself.
 */
"use strict";

(function () {
  const Support = window.FloeSupport;
  if (!Support) {
    throw new Error("Floe support host did not load");
  }
  const host = Support.host;
  const canvas = document.getElementById("canvas");
  // Verified TIC-80 v1.4.1 defaults: arrows + Z=A, X=B, A=X, S=Y.
  const KEY = {
    left: "ArrowLeft", right: "ArrowRight", up: "ArrowUp", down: "ArrowDown",
    confirm: "KeyZ", cancel: "KeyX", action1: "KeyZ", action2: "KeyX",
    action3: "KeyA", action4: "KeyS", start: "Enter", select: "Tab"
  };
  const TIC_KEYS = {
    ArrowLeft: 1, ArrowRight: 1, ArrowUp: 1, ArrowDown: 1,
    KeyZ: 1, KeyX: 1, KeyA: 1, KeyS: 1, Enter: 1
  };

  function keyEvent(type, code) {
    return new KeyboardEvent(type, {
      key: code, code: code, bubbles: true, cancelable: true, view: window
    });
  }

  function fire(type, code) {
    try { canvas.dispatchEvent(keyEvent(type, code)); } catch (error) { host.log(String(error)); }
  }

  function dispatchKey(event, pressed) {
    const detail = {
      key: event.key || event.code, code: event.code, keyCode: event.keyCode || 0,
      which: event.which || 0, location: event.location || 0,
      shiftKey: !!event.shiftKey, ctrlKey: !!event.ctrlKey,
      altKey: !!event.altKey, metaKey: !!event.metaKey, repeat: !!event.repeat,
      bubbles: true, cancelable: true
    };
    const synthetic = new KeyboardEvent(pressed ? "keydown" : "keyup", detail);
    for (const property of ["keyCode", "which", "charCode"]) {
      try { Object.defineProperty(synthetic, property, { value: detail[property] || 0 }); } catch (ignored) {}
    }
    canvas.dispatchEvent(synthetic);
  }

  window.FloeGame = Object.freeze({
    input: function (name, pressed) {
      const code = KEY[name];
      if (!code) return false;
      canvas.focus();
      fire(pressed ? "keydown" : "keyup", code);
      return true;
    },
    key: function (event) {
      if (!event || typeof event.code !== "string" || !TIC_KEYS[event.code]) return false;
      canvas.focus();
      dispatchKey(event, !!event.pressed);
      return true;
    },
    pointer: function (phase, x, y, button) {
      const rect = canvas.getBoundingClientRect();
      const clientX = rect.left + x * rect.width;
      const clientY = rect.top + y * rect.height;
      const type = phase === "ended" ? "mouseup" : (phase === "began" ? "mousedown" : "mousemove");
      const event = new MouseEvent(type, {
        clientX: clientX, clientY: clientY, button: Math.max(0, button | 0),
        buttons: phase === "ended" ? 0 : (1 << Math.max(0, button | 0)),
        bubbles: true, cancelable: true, view: window
      });
      canvas.dispatchEvent(event);
      return true;
    },
    snapshot: function () { return null; },
    restore: function () { return false; }
  });

  let attempts = 0;
  function poll() {
    attempts += 1;
    if (window.Module && window.Module.floeCartStarted) {
      canvas.focus();
      host.ready({
        engine: "tic80", runtime: "tic80 1.4.1", input: true,
        keyboard: true, pointer: true, state: false
      });
      return;
    }
    if (attempts < 600) {
      setTimeout(poll, 30);
      return;
    }
    Support.fail("TIC-80 did not report a preloaded cartridge");
  }
  poll();
})();
