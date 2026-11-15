// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floe contributors. See licenses/FLOE-STARTER-MIT.txt.
(async function () {
  'use strict';
  const config = await (await fetch('game.json')).json();
  const state = { x: 80, y: 200, score: 0, frames: 0, engine: config.engine, engineVersion: config.engineVersion };
  const keys = { left: false, right: false, up: false, down: false };
  const canvas = document.getElementById('game');
  const label = document.getElementById('score');
  let goal = null;
  const clamp = (value, low, high) => Math.max(low, Math.min(high, value));
  function input(key, pressed) {
    if (!Object.hasOwn(keys, key)) return false;
    keys[key] = !!pressed; goal = null; return true;
  }
  function pointer(phase, x, y) {
    if (!['began', 'moved', 'ended'].includes(phase) || !Number.isFinite(x) || !Number.isFinite(y)) return false;
    goal = { x: clamp(x, 0, 1) * 800, y: clamp(y, 0, 1) * 480 }; return true;
  }
  const arrows = { ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'up', ArrowDown: 'down' };
  addEventListener('keydown', event => { if (arrows[event.key]) { event.preventDefault(); input(arrows[event.key], true); } });
  addEventListener('keyup', event => { if (arrows[event.key]) { event.preventDefault(); input(arrows[event.key], false); } });
  addEventListener('blur', () => { for (const key of Object.keys(keys)) keys[key] = false; });
  canvas.addEventListener('pointerdown', event => {
    const rect = canvas.getBoundingClientRect();
    pointer('began', (event.clientX - rect.left) / rect.width, (event.clientY - rect.top) / rect.height);
  });
  function step(dt) {
    state.frames++;
    let dx = Number(keys.right) - Number(keys.left), dy = Number(keys.down) - Number(keys.up);
    if (goal) { dx = Math.abs(goal.x - state.x) < 4 ? 0 : Math.sign(goal.x - state.x); dy = Math.abs(goal.y - state.y) < 4 ? 0 : Math.sign(goal.y - state.y); }
    const speed = Number.isFinite(config.speed) ? clamp(config.speed, 20, 600) : 180;
    const scale = speed * clamp(dt, 0, 0.05) / (Math.hypot(dx, dy) || 1);
    state.x = clamp(state.x + dx * scale, 16, 784); state.y = clamp(state.y + dy * scale, 16, 464);
    const coins = [160, 300, 440];
    if (state.score < coins.length && Math.hypot(state.x - coins[state.score], state.y - 200) < 24) {
      state.score++; if (window.floeGameHost) window.floeGameHost.log('Collected ' + state.score);
    }
    label.textContent = config.title + ' · ' + state.score + ' / 3';
  }
  function restore(saved) {
    if (!saved || saved.engine !== state.engine || saved.engineVersion !== state.engineVersion ||
        ![saved.x, saved.y, saved.score].every(Number.isFinite)) throw Error('Incompatible save');
    state.x = clamp(saved.x, 16, 784); state.y = clamp(saved.y, 16, 464); state.score = clamp(Math.floor(saved.score), 0, 3); goal = null;
    for (const key of Object.keys(keys)) keys[key] = false;
    return true;
  }
  window.FloeGame = Object.freeze({ input, pointer, snapshot: () => ({ ...state }), restore });
  window.FloeTemplate = Object.freeze({ config, state, step, canvas, ready: () => {
    if (window.floeGameHost) window.floeGameHost.ready({ engine: config.engine, version: config.engineVersion, input: true, state: true });
  }});
  dispatchEvent(new Event('floe-template-ready'));
})().catch(error => { if (window.floeGameHost) window.floeGameHost.log(String(error)); throw error; });
