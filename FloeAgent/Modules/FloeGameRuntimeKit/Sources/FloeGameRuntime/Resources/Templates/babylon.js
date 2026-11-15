// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floe contributors. See licenses/FLOE-STARTER-MIT.txt.
addEventListener('floe-template-ready', () => {
  const t = window.FloeTemplate, B = BABYLON;
  const engine = new B.Engine(t.canvas, true, { preserveDrawingBuffer: true, stencil: true });
  const scene = new B.Scene(engine); scene.clearColor = new B.Color4(0.07, 0.13, 0.19, 1);
  const camera = new B.ArcRotateCamera('camera', -Math.PI / 2, 0.7, 9, new B.Vector3(4, 0, 2.4), scene);
  camera.lowerRadiusLimit = 6; camera.upperRadiusLimit = 12;
  new B.HemisphericLight('sky', new B.Vector3(0, 1, 0), scene);
  function material(name, color) { const m = new B.StandardMaterial(name, scene); m.diffuseColor = B.Color3.FromHexString(color); return m; }
  const green = material('ground', '#315f48'), blue = material('hero', '#8ed6ff'), gold = material('coin', '#ffcf55');
  const ground = B.MeshBuilder.CreateGround('ground', { width: 8, height: 4.8 }, scene); ground.position.set(4, 0, 2.4); ground.material = green;
  const hero = B.MeshBuilder.CreateSphere('hero', { diameter: 0.3, segments: 12 }, scene); hero.material = blue;
  const coins = [1.6, 3, 4.4].map((x, i) => { const mesh = B.MeshBuilder.CreateBox('coin-' + i, { size: 0.18 }, scene); mesh.position.set(x, 0.15, 2); mesh.material = gold; return mesh; });
  const house = B.MeshBuilder.CreateBox('house', { width: 1.6, height: 0.8, depth: 1 }, scene); house.position.set(6, 0.4, 1.2); house.material = material('house', '#976c43');
  engine.runRenderLoop(() => { t.step(engine.getDeltaTime() / 1000); hero.position.set(t.state.x / 100, 0.2, t.state.y / 100); coins.forEach((coin, i) => coin.setEnabled(i >= t.state.score)); scene.render(); });
  addEventListener('resize', () => engine.resize()); t.ready();
});
