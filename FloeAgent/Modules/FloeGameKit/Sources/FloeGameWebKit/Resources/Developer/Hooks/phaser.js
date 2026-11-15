/* SPDX-License-Identifier: MPL-2.0 */
/* Floe Phaser host hook. Uses only the observed Phaser game/scene graph. */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D) return;
  var attempts = 0;

  function game() {
    try {
      if (window.FloeTemplate && window.FloeTemplate.game) return window.FloeTemplate.game;
      if (window.game && window.game.scene && window.game.loop) return window.game;
      return null;
    } catch (e) { return null; }
  }
  function template() { return window.FloeTemplate || null; }
  function state() { var t = template(); return t && t.state ? t.state : null; }
  function activeScene() {
    var g = game();
    if (!g) return null;
    try {
      var scenes = g.scene.getScenes(true);
      return scenes && scenes.length ? scenes[0] : null;
    } catch (e) { return null; }
  }
  function sceneKeys() {
    var g = game();
    if (!g || !g.scene || !g.scene.keys) return [];
    return Object.keys(g.scene.keys).slice(0, 64);
  }
  function fps() {
    var g = game();
    try { return g && g.loop && Number.isFinite(g.loop.actualFps) ? g.loop.actualFps : 0; } catch (e) { return 0; }
  }
  function registryEntries() {
    var g = game();
    if (!g || !g.registry || !g.registry.list) return [];
    var entries = [];
    Object.keys(g.registry.list).slice(0, 24).forEach(function (key) {
      var value = g.registry.list[key];
      if (typeof value === "boolean" || typeof value === "number" || typeof value === "string") {
        entries.push([key, value]);
      }
    });
    return entries;
  }
  function field(id, en, zh, group, groupZh, kind, extra) {
    var value = { id: id, label: en, labelZhHans: zh, group: group, groupZhHans: groupZh, kind: kind };
    if (extra) Object.keys(extra).forEach(function (key) { value[key] = extra[key]; });
    return value;
  }
  function action(id, en, zh, symbol, extra) {
    var value = { id: id, label: en, labelZhHans: zh, group: "Engine", groupZhHans: "引擎", symbol: symbol };
    if (extra) Object.keys(extra).forEach(function (key) { value[key] = extra[key]; });
    return value;
  }
  function sceneSpeed() {
    var s = activeScene();
    try { return s && s.time ? s.time.timeScale : 1; } catch (e) { return 1; }
  }
  function setSceneSpeed(value) {
    var g = game();
    if (!g) return false;
    var scenes = g.scene.getScenes(true);
    scenes.forEach(function (scene) {
      if (scene.time) scene.time.timeScale = value;
      if (scene.physics && scene.physics.world && typeof scene.physics.world.timeScale === "number") {
        scene.physics.world.timeScale = 1 / value;
      }
    });
    return true;
  }
  function boot() {
    // Imported Phaser projects often hide their Phaser.Game instance but do
    // expose the reviewed window.FloeGame snapshot/restore contract. In that
    // case expose only its bounded primitive scalars; never crawl prototypes
    // or evaluate project text.
    if (window.FloeGame && typeof window.FloeGame.snapshot === "function" &&
        !window.FloeTemplate && !game()) {
      D.registerScalarSnapshotFallback("state");
      D.setRuntime("Phaser " + (window.Phaser && window.Phaser.VERSION ? window.Phaser.VERSION : ""));
      return;
    }
    if (!window.Phaser || !game()) {
      attempts++;
      if (attempts < 300) setTimeout(boot, 100);
      return;
    }
    register();
  }

  function register() {
    var fields = [];
    var actions = [];
    var t = template();
    if (!state()) {
      D.registerScalarSnapshotFallback("state");
    }
    if (state()) {
      fields.push(field("state.x", "Player X", "玩家 X", "Game state", "游戏状态", "number", {
        symbol: "arrow.left.and.right", minimum: 16, maximum: 784,
        get: function () { return state().x; },
        set: function (v) { if (t.setPosition) t.setPosition(v, state().y); else state().x = v; }
      }));
      fields.push(field("state.y", "Player Y", "玩家 Y", "Game state", "游戏状态", "number", {
        symbol: "arrow.up.and.down", minimum: 16, maximum: 464,
        get: function () { return state().y; },
        set: function (v) { if (t.setPosition) t.setPosition(state().x, v); else state().y = v; }
      }));
      fields.push(field("state.score", "Score", "分数", "Game state", "游戏状态", "integer", {
        symbol: "star", minimum: 0, maximum: 999999, step: 1,
        get: function () { return state().score; },
        set: function (v) { if (t.setScore) t.setScore(v); else state().score = v; }
      }));
    }
    fields.push(field("engine.fps", "FPS", "FPS", "Engine", "引擎", "readOnlyNumber", { symbol: "speedometer", get: fps }));
    fields.push(field("scene.keys", "Scenes", "场景", "Scenes", "场景", "readOnlyText", { symbol: "square.stack", get: function () { return sceneKeys().join(", ") || "—"; } }));
    var scene = activeScene();
    if (scene && scene.cameras && scene.cameras.main) {
      var camera = scene.cameras.main;
      fields.push(field("camera.x", "Camera X", "相机 X", "Camera", "相机", "number", {
        symbol: "arrow.left.and.right", get: function () { return camera.scrollX; },
        set: function (v) { camera.setScroll(v, camera.scrollY); }
      }));
      fields.push(field("camera.y", "Camera Y", "相机 Y", "Camera", "相机", "number", {
        symbol: "arrow.up.and.down", get: function () { return camera.scrollY; },
        set: function (v) { camera.setScroll(camera.scrollX, v); }
      }));
      fields.push(field("camera.zoom", "Camera zoom", "相机缩放", "Camera", "相机", "number", {
        symbol: "plus.magnifyingglass", minimum: 0.1, maximum: 8,
        get: function () { return camera.zoom; }, set: function (v) { camera.setZoom(v); }
      }));
    }
    registryEntries().forEach(function (entry) {
      var key = entry[0];
      var value = entry[1];
      var kind = typeof value === "boolean" ? "boolean" : (typeof value === "number" ? "number" : "text");
      fields.push(field("registry." + key, key, key, "Registry", "注册表", kind, {
        symbol: "tray", get: function () { var g = game(); return g && g.registry ? g.registry.get(key) : value; },
        set: function (v) { var g = game(); if (g && g.registry) g.registry.set(key, v); }
      }));
    });

    if (game().loop && typeof game().loop.sleep === "function" && typeof game().loop.wake === "function") {
      actions.push(action("engine.pause", "Pause", "暂停", "pause.fill", {
        isQuick: true, detail: "Pauses the Phaser time step (game loop).", detailZhHans: "暂停 Phaser 时间步（游戏循环）。",
        invoke: function () { game().loop.sleep(); return { message: "Game loop paused.", messageZhHans: "游戏循环已暂停。" }; }
      }));
      actions.push(action("engine.resume", "Resume", "继续", "play.fill", {
        isQuick: true, invoke: function () { game().loop.wake(); return { message: "Game loop resumed.", messageZhHans: "游戏循环已继续。" }; }
      }));
    }
    var keys = sceneKeys();
    if (keys.length) {
      actions.push(action("scene.start", "Start scene", "启动场景", "rectangle.stack", {
        role: "jump", parameters: [{ id: "sceneKey", label: "Scene key", labelZhHans: "场景键", kind: "choice",
          options: keys.map(function (key) { return { value: key, label: key, labelZhHans: key }; }), isRequired: true }],
        invoke: function (args) { game().scene.start(args.sceneKey); return { message: "Starting scene " + args.sceneKey + ".", messageZhHans: "正在启动场景 " + args.sceneKey + "。" }; }
      }));
      actions.push(action("scene.restart", "Restart scene", "重启场景", "arrow.counterclockwise", {
        role: "destructive", confirmation: "required",
        invoke: function () { var s = activeScene(); if (!s) throw new Error("No active scene."); s.scene.restart(); return { message: "Scene restarting.", messageZhHans: "场景正在重启。" }; }
      }));
    }
    if (activeScene()) {
      actions.push(action("camera.jump", "Jump camera", "跳转相机", "camera", {
        role: "jump", parameters: [
          { id: "x", label: "X", labelZhHans: "X", kind: "number", isRequired: true, defaultValue: 0 },
          { id: "y", label: "Y", labelZhHans: "Y", kind: "number", isRequired: true, defaultValue: 0 }
        ],
        invoke: function (args) { var s = activeScene(); if (!s || !s.cameras || !s.cameras.main) throw new Error("No camera."); s.cameras.main.centerOn(args.x, args.y); return { message: "Camera moved.", messageZhHans: "相机已移动。" }; }
      }));
    }
    if (activeScene()) {
      fields.push(field("engine.speed", "Scene speed", "场景速度", "Engine", "引擎", "number", {
        symbol: "gauge.with.dots.needle.67percent", minimum: 0.25, maximum: 4, step: 0.25,
        detail: "Applies to Phaser scene clocks and Arcade Physics; raw-delta code may not change.",
        detailZhHans: "作用于 Phaser 场景时钟和 Arcade Physics；原始 delta 代码可能不改变。",
        get: sceneSpeed, set: setSceneSpeed
      }));
    }
    D.setRuntime("Phaser " + (window.Phaser && window.Phaser.VERSION ? window.Phaser.VERSION : ""));
    D.register({
      fields: fields,
      actions: actions,
      diagnostics: function () { return { game: game() ? "attached" : "missing", scenes: String(sceneKeys().length), fps: String(Math.round(fps())) }; }
    });
  }

  boot();
})();
