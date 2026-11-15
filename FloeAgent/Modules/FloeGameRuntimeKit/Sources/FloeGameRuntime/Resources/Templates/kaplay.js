// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floe contributors. See licenses/FLOE-STARTER-MIT.txt.
addEventListener('floe-template-ready', () => {
  const t = window.FloeTemplate, k = kaplay({ global: false, canvas: t.canvas, width: 800, height: 480, letterbox: true, background: [24, 59, 46], debug: false });
  for (let y = 0; y < 480; y += 64) for (let x = 0; x < 800; x += 64) k.add([k.rect(60, 60), k.pos(x + 2, y + 2), k.color(40 + (x % 128 ? 6 : 0), 85, 63)]);
  k.add([k.rect(170, 120), k.pos(550, 80), k.color(151, 108, 67)]);
  const coins = [160, 300, 440].map(x => k.add([k.circle(9), k.pos(x, 200), k.color(255, 207, 85), k.anchor('center')]));
  const hero = k.add([k.circle(14), k.pos(t.state.x, t.state.y), k.color(142, 214, 255), k.anchor('center')]);
  k.onUpdate(() => { t.step(k.dt()); hero.pos = k.vec2(t.state.x, t.state.y); coins.forEach((coin, index) => { coin.hidden = index < t.state.score; }); });
  t.ready();
});
