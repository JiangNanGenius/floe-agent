/* SPDX-License-Identifier: MPL-2.0 */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D) return;
  var attempts = 0;
  function engine() { return window.FloeEngine && window.FloeEngine.kaplay ? window.FloeEngine : null; }
  function template() { return window.FloeTemplate || null; }
  function state() { var t = template(); return t && t.state ? t.state : null; }
  function field(id, en, zh, group, groupZh, kind, extra) {
    var v = { id: id, label: en, labelZhHans: zh, group: group, groupZhHans: groupZh, kind: kind };
    if (extra) Object.keys(extra).forEach(function (k) { v[k] = extra[k]; });
    return v;
  }
  function boot() {
    if (!engine() || !state()) { attempts++; if (attempts < 300) setTimeout(boot, 100); return; }
    var k = engine().kaplay;
    var fields = [
      field("state.x", "Player X", "玩家 X", "Game state", "游戏状态", "number", { symbol: "arrow.left.and.right", minimum: 0, maximum: 800, get: function () { return state().x; }, set: function (v) { state().x = v; } }),
      field("state.y", "Player Y", "玩家 Y", "Game state", "游戏状态", "number", { symbol: "arrow.up.and.down", minimum: 0, maximum: 480, get: function () { return state().y; }, set: function (v) { state().y = v; } }),
      field("state.score", "Score", "分数", "Game state", "游戏状态", "integer", { symbol: "star", minimum: 0, maximum: 999999, step: 1, get: function () { return state().score; }, set: function (v) { state().score = v; } }),
      field("state.frames", "Frames", "帧数", "Game state", "游戏状态", "readOnlyNumber", { symbol: "film", get: function () { return state().frames; } }),
      field("engine.fps", "FPS", "FPS", "Engine", "引擎", "readOnlyNumber", { symbol: "speedometer", get: function () { try { return k.debug && k.debug.fps ? k.debug.fps() : 0; } catch (e) { return 0; } } }),
      field("engine.frames", "Engine frames", "引擎帧数", "Engine", "引擎", "readOnlyNumber", { symbol: "film", get: function () { try { return k.debug && k.debug.numFrames ? k.debug.numFrames() : 0; } catch (e) { return 0; } } })
    ];
    D.setRuntime("KAPLAY");
    D.notice("no-pause", "KAPLAY's reviewed public API has no supported global pause/time-scale control.", "已审查的 KAPLAY 公共 API 不支持全局暂停/时间缩放。");
    D.register({ fields: fields, diagnostics: function () { return { game: "attached" }; } });
  }
  boot();
})();
