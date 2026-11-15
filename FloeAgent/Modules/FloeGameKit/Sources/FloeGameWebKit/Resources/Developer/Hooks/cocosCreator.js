/* SPDX-License-Identifier: MPL-2.0 */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D) return;
  var attempts = 0;
  function director() {
    try {
      if (window.cc && window.cc.director) return window.cc.director;
      if (window.director) return window.director;
      return null;
    } catch (e) { return null; }
  }
  function sceneName(d) {
    try { var scene = d && d.getScene ? d.getScene() : null; return scene && scene.name ? String(scene.name) : "—"; }
    catch (e) { return "—"; }
  }
  function field(id, en, zh, group, groupZh, kind, extra) {
    var v = { id: id, label: en, labelZhHans: zh, group: group, groupZhHans: groupZh, kind: kind };
    if (extra) Object.keys(extra).forEach(function (k) { v[k] = extra[k]; });
    return v;
  }
  function boot() {
    if (window.FloeDeveloper !== D) return;
    if (window.__floeCocosBridge) {
      D.setRuntime("Cocos Creator 3.x");
      D.notice("cocos-component",
        "The project FloeDeveloperBridge component owns the live fields/actions and persists across scenes.",
        "工程 FloeDeveloperBridge 组件负责实时字段/动作，并跨场景保持。");
      D.register({});
      return;
    }
    var d = director();
    if (!d) { attempts++; if (attempts < 100) setTimeout(boot, 100); return; }
    var fields = [
      field("scene.name", "Scene", "场景", "Engine", "引擎", "readOnlyText", { symbol: "square.stack", get: function () { return sceneName(d); } }),
      field("engine.frames", "Frames", "帧数", "Engine", "引擎", "readOnlyNumber", { symbol: "film", get: function () { try { return d.getTotalFrames ? d.getTotalFrames() : 0; } catch (e) { return 0; } } }),
      field("engine.fps", "FPS", "FPS", "Engine", "引擎", "readOnlyNumber", { symbol: "speedometer", get: function () { try { return window.game && window.game.frameRate ? window.game.frameRate : 0; } catch (e) { return 0; } } }),
      field("engine.paused", "Paused", "已暂停", "Engine", "引擎", "readOnlyBoolean", { symbol: "pause", get: function () { try { return !!d.isPaused && d.isPaused(); } catch (e) { return false; } } })
    ];
    var actions = [
      { id: "engine.pause", label: "Pause", labelZhHans: "暂停", group: "Engine", groupZhHans: "引擎", symbol: "pause.fill", isQuick: true, invoke: function () { if (d.pause) d.pause(); return { message: "Director paused.", messageZhHans: "Director 已暂停。" }; } },
      { id: "engine.resume", label: "Resume", labelZhHans: "继续", group: "Engine", groupZhHans: "引擎", symbol: "play.fill", isQuick: true, invoke: function () { if (d.resume) d.resume(); return { message: "Director resumed.", messageZhHans: "Director 已继续。" }; } }
    ];
    D.setRuntime("Cocos Creator");
    D.notice("cocos-fallback",
      "This Cocos page has no installed project component; only observed director pause/resume and counters are available. Install the FloeDeveloperBridge component for the full scene/step bridge.",
      "此 Cocos 页面未安装工程组件；仅提供实际观察到的 director 暂停/恢复与计数。安装 FloeDeveloperBridge 组件可获得完整场景/单步桥。");
    D.register({ fields: fields, actions: actions, pause: function () { if (d.pause) d.pause(); }, resume: function () { if (d.resume) d.resume(); } });
  }
  boot();
})();
