/* SPDX-License-Identifier: MPL-2.0 */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D) return;
  var attempts = 0;
  function engine() { return window.FloeEngine && window.FloeEngine.scene ? window.FloeEngine : null; }
  function state() { var t = window.FloeTemplate; return t && t.state ? t.state : null; }
  function field(id, en, zh, group, groupZh, kind, extra) {
    var v = { id: id, label: en, labelZhHans: zh, group: group, groupZhHans: groupZh, kind: kind };
    if (extra) Object.keys(extra).forEach(function (k) { v[k] = extra[k]; });
    return v;
  }
  function action(id, en, zh, symbol, extra) {
    var v = { id: id, label: en, labelZhHans: zh, group: "Engine", groupZhHans: "引擎", symbol: symbol };
    if (extra) Object.keys(extra).forEach(function (k) { v[k] = extra[k]; });
    return v;
  }
  function boot() {
    if (!engine()) { attempts++; if (attempts < 300) setTimeout(boot, 100); return; }
    var E = engine(), B = E.BABYLON, scene = E.scene, camera = E.camera;
    var fields = [];
    if (state()) {
      fields.push(field("state.x", "Player X", "玩家 X", "Game state", "游戏状态", "number", { symbol: "arrow.left.and.right", minimum: 0, maximum: 800, get: function () { return state().x; }, set: function (v) { state().x = v; } }));
      fields.push(field("state.y", "Player Y", "玩家 Y", "Game state", "游戏状态", "number", { symbol: "arrow.up.and.down", minimum: 0, maximum: 480, get: function () { return state().y; }, set: function (v) { state().y = v; } }));
      fields.push(field("state.score", "Score", "分数", "Game state", "游戏状态", "integer", { symbol: "star", minimum: 0, maximum: 999999, step: 1, get: function () { return state().score; }, set: function (v) { state().score = v; } }));
    }
    fields.push(field("camera.alpha", "Camera alpha", "相机 α", "Camera", "相机", "number", { symbol: "rotate.3d", minimum: -Math.PI * 2, maximum: Math.PI * 2, get: function () { return camera.alpha; }, set: function (v) { camera.alpha = v; } }));
    fields.push(field("camera.beta", "Camera beta", "相机 β", "Camera", "相机", "number", { symbol: "rotate.3d", minimum: 0.01, maximum: Math.PI - 0.01, get: function () { return camera.beta; }, set: function (v) { camera.beta = v; } }));
    fields.push(field("camera.radius", "Camera radius", "相机距离", "Camera", "相机", "number", { symbol: "arrow.up.left.and.arrow.down.right", minimum: 0.1, maximum: 1000, get: function () { return camera.radius; }, set: function (v) { camera.radius = v; } }));
    fields.push(field("camera.target.x", "Target X", "目标 X", "Camera", "相机", "number", { symbol: "scope", minimum: -10000, maximum: 10000, get: function () { return camera.target.x; }, set: function (v) { camera.setTarget(new B.Vector3(v, camera.target.y, camera.target.z)); } }));
    fields.push(field("camera.target.y", "Target Y", "目标 Y", "Camera", "相机", "number", { symbol: "scope", minimum: -10000, maximum: 10000, get: function () { return camera.target.y; }, set: function (v) { camera.setTarget(new B.Vector3(camera.target.x, v, camera.target.z)); } }));
    fields.push(field("camera.target.z", "Target Z", "目标 Z", "Camera", "相机", "number", { symbol: "scope", minimum: -10000, maximum: 10000, get: function () { return camera.target.z; }, set: function (v) { camera.setTarget(new B.Vector3(camera.target.x, camera.target.y, v)); } }));
    fields.push(field("animation.speed", "Animation speed", "动画速度", "Engine", "引擎", "number", { symbol: "hare", minimum: 0, maximum: 4, step: 0.1, detail: "Babylon scene animation time scale; not global simulation speed.", detailZhHans: "Babylon 场景动画时间缩放；不是全局模拟速度。", get: function () { return scene.animationTimeScale; }, set: function (v) { scene.animationTimeScale = v; } }));
    fields.push(field("engine.fps", "FPS", "FPS", "Engine", "引擎", "readOnlyNumber", { symbol: "speedometer", get: function () { return E.engine.getFps(); } }));
    fields.push(field("scene.name", "Scene", "场景", "Engine", "引擎", "readOnlyText", { symbol: "square.stack", get: function () { return scene.name || "—"; } }));
    fields.push(field("scene.meshes", "Meshes", "网格", "Engine", "引擎", "readOnlyNumber", { symbol: "cube", get: function () { return scene.meshes.length; } }));
    var actions = [
      action("engine.pause", "Pause", "暂停", "pause.fill", { isQuick: true, invoke: function () { E.engine.stopRenderLoop(E.renderLoop); return { message: "Render loop stopped.", messageZhHans: "渲染循环已停止。" }; } }),
      action("engine.resume", "Resume", "继续", "play.fill", { isQuick: true, invoke: function () { E.engine.runRenderLoop(E.renderLoop); return { message: "Render loop resumed.", messageZhHans: "渲染循环已继续。" }; } }),
      action("camera.jump", "Jump camera", "跳转相机", "camera", { role: "jump", parameters: [
        { id: "x", label: "X", labelZhHans: "X", kind: "number", isRequired: true, defaultValue: 0 },
        { id: "y", label: "Y", labelZhHans: "Y", kind: "number", isRequired: true, defaultValue: 0 },
        { id: "z", label: "Z", labelZhHans: "Z", kind: "number", isRequired: true, defaultValue: 0 }
      ], invoke: function (args) { camera.setTarget(new B.Vector3(args.x, args.y, args.z)); return { message: "Camera target moved.", messageZhHans: "相机目标已移动。" }; } })
    ];
    D.setRuntime("Babylon.js " + (B.Engine.Version || ""));
    D.register({ fields: fields, actions: actions, pause: function () { E.engine.stopRenderLoop(E.renderLoop); }, resume: function () { E.engine.runRenderLoop(E.renderLoop); }, diagnostics: function () { return { scene: scene.name || "", meshes: String(scene.meshes.length) }; } });
  }
  boot();
})();
