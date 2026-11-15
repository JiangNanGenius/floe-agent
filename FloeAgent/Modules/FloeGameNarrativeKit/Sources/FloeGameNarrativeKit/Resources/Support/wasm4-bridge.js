/* SPDX-License-Identifier: MPL-2.0 */
/*
 * FloeGameNarrativeKit WASM-4 bridge (MPL-2.0).
 *
 * The original cartridge is cart.wasm (user content). The upstream WASM-4 web
 * runtime is wasm4.js (ISC, unchanged). This bridge maps the typed FloeGame
 * contract onto the upstream player's gamepad/mouse state and its real
 * SavedGameState save/restore path.
 */
"use strict";

(function () {
  const Support = window.FloeSupport;
  if (!Support) {
    throw new Error("Floe support host did not load");
  }
  const host = Support.host;
  const BIT = { left: 16, right: 32, up: 64, down: 128, confirm: 1, cancel: 2, action1: 1, action2: 2 };
  const KEYBIT = {
    ArrowLeft: 16, ArrowRight: 32, ArrowUp: 64, ArrowDown: 128,
    KeyX: 1, KeyV: 1, Space: 1, Period: 1, KeyZ: 2, KeyC: 2, Comma: 2
  };
  const pressed = Object.create(null);
  const heldKeys = Object.create(null);

  function pad() {
    let bits = 0;
    for (const key in pressed) if (pressed[key] && BIT[key]) bits |= BIT[key];
    for (const code in heldKeys) if (heldKeys[code] && KEYBIT[code]) bits |= KEYBIT[code];
    return bits;
  }

  function gameApp() { return document.querySelector("wasm4-app"); }

  function toBase64(buffer) {
    const bytes = new Uint8Array(buffer);
    let out = "";
    for (let index = 0; index < bytes.length; index += 0x8000) {
      out += String.fromCharCode.apply(null, bytes.subarray(index, index + 0x8000));
    }
    return btoa(out);
  }

  function fromBase64(text) {
    const raw = atob(text);
    const bytes = new Uint8Array(raw.length);
    for (let index = 0; index < raw.length; index++) bytes[index] = raw.charCodeAt(index);
    return bytes.buffer;
  }

  let attempts = 0;

  function boot() {
    attempts += 1;
    const app = gameApp();
    if (!app || !app.runtime || !app.runtime.wasm) {
      if (attempts < 600) {
        setTimeout(boot, 30);
      } else {
        Support.fail("WASM-4 runtime did not start");
      }
      return;
    }
    window.FloeGame = Object.freeze({
      input: function (key, down) {
        if (!(key in BIT)) return false;
        pressed[key] = !!down;
        app.inputState.gamepad[0] = pad();
        return true;
      },
      key: function (event) {
        const code = event && event.code;
        if (!code || !KEYBIT[code]) return false;
        heldKeys[code] = !!event.pressed;
        app.inputState.gamepad[0] = pad();
        return true;
      },
      pointer: function (phase, x, y, button) {
        const input = app.inputState;
        input.mouseX = Math.max(0, Math.min(159, Math.round(x * 160)));
        input.mouseY = Math.max(0, Math.min(159, Math.round(y * 160)));
        if (phase === "ended") input.mouseButtons &= ~(1 << (button || 0));
        else input.mouseButtons |= (1 << (button || 0));
        return true;
      },
      snapshot: function () {
        try { app.saveGameState(); } catch (error) { host.log(String(error)); }
        const saved = app.savedGameState;
        if (!saved || !saved.memory) return {};
        return {
          engine: "wasm4",
          runtime: "wasm4 2.7.1",
          memory: toBase64(saved.memory),
          globals: saved.globals || {},
          diskSize: saved.diskSize || 0,
          disk: saved.diskSize
            ? toBase64(new Uint8Array(saved.diskBuffer, 0, saved.diskSize).slice().buffer)
            : ""
        };
      },
      restore: function (snapshot) {
        const app2 = gameApp();
        if (!app2 || !snapshot || typeof snapshot.memory !== "string") return false;
        try {
          const memory = fromBase64(snapshot.memory);
          if (memory.byteLength !== 65536) return false;
          const disk = snapshot.disk ? fromBase64(snapshot.disk) : new ArrayBuffer(0);
          const diskSize = Number(snapshot.diskSize) || 0;
          if (!Number.isInteger(diskSize) || diskSize < 0 || diskSize > 1024 ||
              disk.byteLength !== diskSize) {
            return false;
          }
          // The upstream SavedGameState owns read()/write() methods. Ask the
          // player to create it; replacing it with JSON loses that prototype.
          app2.saveGameState();
          const saved = app2.savedGameState;
          if (!saved || typeof saved.write !== "function") return false;
          saved.memory = memory;
          saved.globals = snapshot.globals && typeof snapshot.globals === "object" ? snapshot.globals : {};
          saved.diskSize = diskSize;
          saved.diskBuffer = new ArrayBuffer(1024);
          new Uint8Array(saved.diskBuffer).set(new Uint8Array(disk));
          app2.loadGameState();
          return true;
        } catch (error) {
          host.log(String(error));
          return false;
        }
      }
    });
    host.ready({
      engine: "wasm4", runtime: "wasm4 2.7.1",
      input: true, keyboard: true, pointer: true, state: true
    });
  }

  boot();
})();
