// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floe contributors. See licenses/FLOE-STARTER-MIT.txt.
addEventListener('floe-template-ready', async () => {
  try {
    const t = window.FloeTemplate;
    const device = await pc.createGraphicsDevice(t.canvas, { deviceTypes: [pc.DEVICETYPE_WEBGL2], antialias: true, alpha: false, preserveDrawingBuffer: true });
    const app = new pc.AppBase(t.canvas), options = new pc.AppOptions(); options.graphicsDevice = device;
    options.componentSystems = [pc.RenderComponentSystem, pc.CameraComponentSystem, pc.LightComponentSystem]; options.resourceHandlers = [];
    app.init(options); app.setCanvasFillMode(pc.FILLMODE_FILL_WINDOW); app.setCanvasResolution(pc.RESOLUTION_AUTO);
    app.scene.ambientLight = new pc.Color(0.6, 0.6, 0.6);
    function material(r, g, b) { const m = new pc.StandardMaterial(); m.diffuse = new pc.Color(r, g, b); m.update(); return m; }
    const blue = material(0.56, 0.84, 1), gold = material(1, 0.81, 0.33);
    function mesh(name, type, size, position, mat) { const e = new pc.Entity(name); e.addComponent('render', { type, material: mat }); e.setLocalScale(...size); e.setPosition(...position); app.root.addChild(e); return e; }
    mesh('ground', 'box', [8, 0.05, 4.8], [4, -0.05, 2.4], material(0.19, 0.37, 0.28));
    mesh('house', 'box', [1.6, 0.8, 1], [6, 0.4, 1.2], material(0.59, 0.42, 0.26));
    const hero = mesh('hero', 'sphere', [0.3, 0.3, 0.3], [0.8, 0.2, 2], blue);
    const coins = [1.6, 3, 4.4].map((x, i) => mesh('coin-' + i, 'box', [0.18, 0.18, 0.18], [x, 0.15, 2], gold));
    const camera = new pc.Entity('camera'); camera.addComponent('camera', { clearColor: new pc.Color(0.07, 0.13, 0.19) }); camera.setPosition(4, 7, 7.8); camera.lookAt(4, 0, 2.4); app.root.addChild(camera);
    const light = new pc.Entity('sun'); light.addComponent('light', { type: 'directional', color: new pc.Color(1, 1, 1), intensity: 1 }); light.setLocalEulerAngles(45, 30, 0); app.root.addChild(light);
    app.on('update', dt => { t.step(dt); hero.setPosition(t.state.x / 100, 0.2, t.state.y / 100); coins.forEach((coin, i) => { coin.enabled = i >= t.state.score; }); });
    window.FloeEngine = Object.freeze({ pc, app, camera, hero, coins, t });
    addEventListener('resize', () => app.resizeCanvas()); app.start(); t.ready();
  } catch (error) { if (window.floeGameHost) window.floeGameHost.log(String(error)); throw error; }
});
