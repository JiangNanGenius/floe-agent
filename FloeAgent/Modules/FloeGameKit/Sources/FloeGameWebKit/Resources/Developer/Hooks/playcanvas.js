/* SPDX-License-Identifier: MPL-2.0 */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D) return;
  var attempts = 0;
  function engine() { return window.FloeEngine && window.FloeEngine.app ? window.FloeEngine : null; }
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
    var E = engine(), app = E.app, camera = E.camera;
    var fields = [];
    if (state()) {
      fields.push(field("state.x", "Player X", "玩家 X", "Game state", "游戏状态", "number", { symbol: "arrow.left.and.right", minimum: 0, maximum: 800, get: function () { return state().x; }, set: function (v) { state().x = v; } }));
      fields.push(field("state.y", "Player Y", "玩家 Y", "Game state", "游戏状态", "number", { symbol: "arrow.up.and.down", minimum: 0, maximum: 480, get: function () { return state().y; }, set: function (v) { state().y = v; } }));
      fields.push(field("state.score", "Score", "分数", "Game state", "游戏状态", "integer", { symbol: "star", minimum: 0, maximum: 999999, step: 1, get: function () { return state().score; }, set: function (v) { state().score = v; } }));
    }
    fields.push(field("engine.speed", "Time scale", "时间缩放", "Engine", "引擎", "number", { symbol: "gauge.with.dots.needle.67percent", minimum: 0, maximum: 4, step: 0.25, get: function () { return app.timeScale; }, set: function (v) { app.timeScale = v; } }));
    var position = camera && camera.getPosition ? camera.getPosition() : null;
    if (position) {
      fields.push(field("camera.x", "Camera X", "相机 X", "Camera", "相机", "number", { symbol: "arrow.left.and.right", get: function () { return camera.getPosition().x; }, set: function (v) { var p = camera.getPosition(); camera.setPosition(v, p.y, p.z); } }));
      fields.push(field("camera.y", "Camera Y", "相机 Y", "Camera", "相机", "number", { symbol: "arrow.up.and.down", get: function () { return camera.getPosition().y; }, set: function (v) { var p = camera.getPosition(); camera.setPosition(p.x, v, p.z); } }));
      fields.push(field("camera.z", "Camera Z", "相机 Z", "Camera", "相机", "number", { symbol: "arrow.up.left.and.arrow.down.right", get: function () { return camera.getPosition().z; }, set: function (v) { var p = camera.getPosition(); camera.setPosition(p.x, p.y, v); } }));
    }
    fields.push(field("engine.fps", "FPS", "FPS", "Engine", "引擎", "readOnlyNumber", { symbol: "speedometer", get: function () { return app.stats && app.stats.frame && app.stats.frame.fps ? app.stats.frame.fps : 0; } }));
    fields.push(field("scene.entities", "Entities", "实体", "Engine", "引擎", "readOnlyNumber", { symbol: "cube", get: function () { return app.root ? app.root.children.length : 0; } }));
    fields.push(field("engine.paused", "Paused", "已暂停", "Engine", "引擎", "readOnlyBoolean", { symbol: "pause", get: function () { return app.timeScale === 0; } }));
    var actions = [
      action("engine.pause", "Pause", "暂停", "pause.fill", { isQuick: true, invoke: function () { app.timeScale = 0; return { message: "Game paused.", messageZhHans: "游戏已暂停。" }; } }),
      action("engine.resume", "Resume", "继续", "play.fill", { isQuick: true, invoke: function () { app.timeScale = 1; return { message: "Game resumed.", messageZhHans: "游戏已继续。" }; } }),
      action("camera.jump", "Jump camera", "跳转相机", "camera", { role: "jump", parameters: [
        { id: "x", label: "X", labelZhHans: "X", kind: "number", isRequired: true, defaultValue: 0 },
        { id: "y", label: "Y", labelZhHans: "Y", kind: "number", isRequired: true, defaultValue: 0 },
        { id: "z", label: "Z", labelZhHans: "Z", kind: "number", isRequired: true, defaultValue: 0 }
      ], invoke: function (args) { camera.setPosition(args.x, args.y, args.z); return { message: "Camera moved.", messageZhHans: "相机已移动。" }; } })
    ];
    D.setRuntime("PlayCanvas");
    D.register({ fields: fields, actions: actions, pause: function () { app.timeScale = 0; }, resume: function () { app.timeScale = 1; }, setSpeed: function (v) { app.timeScale = v; }, diagnostics: function () { return { frame: String(app.frame), entities: String(app.root ? app.root.children.length : 0) }; } });
  }
  boot();
})();
