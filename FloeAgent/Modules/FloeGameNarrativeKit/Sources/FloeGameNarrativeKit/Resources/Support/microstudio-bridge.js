/* SPDX-License-Identifier: MPL-2.0 */
/*
 * FloeGameNarrativeKit microStudio bridge (MPL-2.0).
 *
 * The original microScript sources and resource metadata are loaded from
 * game/microstudio-sources.json and game/resources.json (user content, not
 * this file). The upstream language scripts (language.js) and canvas2d engine
 * (microengine.js) are unchanged MIT runtime files. This bridge creates the
 * upstream #code element from the JSON source document, sets the same globals
 * as the official exporter, and constructs the real upstream Player.
 */
"use strict";

(function () {
  const Support = window.FloeSupport;
  if (!Support) {
    throw new Error("Floe support host did not load");
  }
  const host = Support.host;
  const KEY = {
    left: "ArrowLeft", right: "ArrowRight", up: "ArrowUp", down: "ArrowDown",
    confirm: "Space", cancel: "Escape", action1: "Space", action2: "KeyE",
    action3: "KeyQ", action4: "KeyF", start: "Enter", select: "Tab"
  };
  const MS_KEYS = {
    ArrowLeft: 1, ArrowRight: 1, ArrowUp: 1, ArrowDown: 1,
    KeyA: 1, KeyD: 1, KeyW: 1, KeyS: 1,
    KeyZ: 1, KeyX: 1, Space: 1, Enter: 1, Escape: 1, Tab: 1
  };

  function fire(type, code) {
    try {
      document.dispatchEvent(new KeyboardEvent(type, {
        key: code, code: code, bubbles: true, cancelable: true, view: window
      }));
    } catch (error) {
      host.log(String(error));
    }
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
    document.dispatchEvent(synthetic);
  }

  function gameCanvas() { return document.querySelector("#canvaswrapper canvas"); }

  let player = null;
  let supportsState = false;

  function snapshotValue() {
    try { return player.call("floe_snapshot", [0]); }
    catch (error) { return null; }
  }

  function hasState() {
    const value = snapshotValue();
    return Array.isArray(value) ||
      (value && typeof value === "object" && !Array.isArray(value));
  }

  function waitForLoad() {
    return new Promise(function (resolve) {
      if (document.readyState === "complete") resolve();
      else window.addEventListener("load", resolve, { once: true });
    });
  }

  async function boot() {
    let values;
    try {
      values = await Promise.all([
        Support.fetchJSON("game/microstudio-sources.json"),
        Support.fetchJSON("game/resources.json")
      ]);
    } catch (error) {
      Support.fail("microStudio project data could not be loaded: " + error.message);
      return;
    }
    const sourceDocument = values[0];
    const runtimeDocument = values[1];
    if (!sourceDocument || typeof sourceDocument.code !== "string" ||
        !runtimeDocument || !runtimeDocument.resources || typeof runtimeDocument.resources !== "object") {
      Support.fail("microStudio project data is invalid");
      return;
    }

    window.fonts = [];
    window.skip_service_worker = true;
    window.resources = runtimeDocument.resources;
    window.graphics = typeof runtimeDocument.graphics === "string" ? runtimeDocument.graphics : "M1";
    window.orientation = typeof runtimeDocument.orientation === "string" ? runtimeDocument.orientation : "landscape";
    window.aspect = typeof runtimeDocument.aspect === "string" ? runtimeDocument.aspect : "16/9";
    window.ms_libs = [];
    window.exported_project = true;
    window.ms_use_server = false;

    let code = document.getElementById("code");
    if (!code) {
      code = document.createElement("script");
      code.id = "code";
      code.type = "text/x-microscript";
      document.body.appendChild(code);
    }
    code.textContent = sourceDocument.code;

    await waitForLoad();
    try {
      player = new Player(function (event) {
        if (event && event.name === "started") {
          window.setTimeout(function () {
            supportsState = hasState();
            host.ready({
              engine: "microStudio", runtime: "microstudio 1.0.0",
              input: true, keyboard: true, pointer: true, state: supportsState
            });
          }, 0);
        } else if (event && event.name === "log") {
          host.log(String(event.data));
        } else if (event && event.name === "error") {
          host.log(typeof event.data === "string" ? event.data : JSON.stringify(event.data));
        }
      });
      window.FloeGame = Object.freeze({
        input: function (name, pressed) {
          const codeName = KEY[name];
          if (!codeName) return false;
          fire(pressed ? "keydown" : "keyup", codeName);
          return true;
        },
        key: function (event) {
          if (!event || typeof event.code !== "string" || !MS_KEYS[event.code]) return false;
          dispatchKey(event, !!event.pressed);
          return true;
        },
        pointer: function (phase, x, y, button) {
          const canvas = gameCanvas();
          if (!canvas) return false;
          const rect = canvas.getBoundingClientRect();
          const clientX = rect.left + x * rect.width;
          const clientY = rect.top + y * rect.height;
          const type = phase === "ended" ? "mouseup" : (phase === "began" ? "mousedown" : "mousemove");
          document.dispatchEvent(new MouseEvent(type, {
            clientX: clientX, clientY: clientY, button: Math.max(0, button | 0),
            buttons: phase === "ended" ? 0 : (1 << Math.max(0, button | 0)),
            bubbles: true, cancelable: true, view: window
          }));
          return true;
        },
        snapshot: function () {
          if (!player) return {};
          const value = snapshotValue();
          if (Array.isArray(value)) {
            return { engine: "microStudio", runtime: "microstudio 1.0.0", values: value };
          }
          if (value && typeof value === "object") {
            return { engine: "microStudio", runtime: "microstudio 1.0.0", named: value };
          }
          return {};
        },
        restore: function (state) {
          if (!player || !state) return false;
          try {
            if (Array.isArray(state.values)) {
              player.call("floe_restore", state.values);
              return true;
            }
            if (state.named && typeof state.named === "object" && !Array.isArray(state.named)) {
              player.call("floe_restore_named", [state.named]);
              return true;
            }
            return false;
          } catch (error) {
            host.log(String(error));
            return false;
          }
        }
      });
      // No sprite/map load callback occurs in a source-only project. The
      // upstream readiness check also handles pending assets correctly.
      if (player.runtime && !player.runtime.started) player.runtime.checkStartReady();
    } catch (error) {
      Support.fail("microStudio player could not start: " + error.message);
    }
  }

  boot().catch(function (error) {
    Support.fail("microStudio bridge failed: " + (error && error.message ? error.message : error));
  });
})();
