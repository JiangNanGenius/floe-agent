// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floe contributors. See licenses/FLOE-STARTER-MIT.txt.
(function () {
  let state = null, ready = false;
  window.FloeGodot = {
    inputCallback: null, restoreCallback: null, pointerCallback: null,
    update: text => {
      state = JSON.parse(text);
      if (!ready) { ready = true; if (window.floeGameHost) window.floeGameHost.ready({ engine: 'godot', version: state.engineVersion, input: true, state: true }); }
    }
  };
  window.FloeGame = Object.freeze({
    input: (key, pressed) => { if (!['left', 'right', 'up', 'down'].includes(key) || !window.FloeGodot.inputCallback) return false; window.FloeGodot.inputCallback(key, !!pressed); return true; },
    pointer: (phase, x, y) => { if (!window.FloeGodot.pointerCallback || !Number.isFinite(x) || !Number.isFinite(y)) return false; window.FloeGodot.pointerCallback(x, y); return true; },
    snapshot: () => state ? { ...state } : null,
    restore: saved => {
      if (!state || !saved || saved.engine !== 'godot' || saved.engineVersion !== state.engineVersion || ![saved.x, saved.y, saved.score].every(Number.isFinite) || !window.FloeGodot.restoreCallback) return false;
      window.FloeGodot.restoreCallback(JSON.stringify(saved)); return true;
    }
  });
})();
