/* SPDX-License-Identifier: MPL-2.0 */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D) return;
  var attempts = 0;
  var paused = false;

  function module() { return window.Module || null; }
  function canPause() {
    var m = module();
    return !!(m && typeof m.pauseMainLoop === "function" && typeof m.resumeMainLoop === "function");
  }
  function boot() {
    if (!window.FloeGame) { attempts++; if (attempts < 300) setTimeout(boot, 100); return; }
    var actions = [];
    if (canPause()) {
      actions.push({ id: "engine.pause", label: "Pause", labelZhHans: "暂停", group: "Engine", groupZhHans: "引擎", symbol: "pause.fill", isQuick: true, detail: "Pauses the real Emscripten main loop.", detailZhHans: "暂停真实 Emscripten 主循环。", invoke: function () { module().pauseMainLoop(); paused = true; return { message: "Main loop paused.", messageZhHans: "主循环已暂停。" }; } });
      actions.push({ id: "engine.resume", label: "Resume", labelZhHans: "继续", group: "Engine", groupZhHans: "引擎", symbol: "play.fill", isQuick: true, invoke: function () { module().resumeMainLoop(); paused = false; return { message: "Main loop resumed.", messageZhHans: "主循环已继续。" }; } });
      actions.push({ id: "engine.step", label: "Step frame", labelZhHans: "单步帧", group: "Engine", groupZhHans: "引擎", symbol: "forward.frame", detail: "Resumes for about one 60 Hz frame, then pauses again.", detailZhHans: "恢复约一个 60Hz 帧后再次暂停。", invoke: function () {
        var m = module();
        if (!paused) m.pauseMainLoop();
        m.resumeMainLoop();
        setTimeout(function () { try { m.pauseMainLoop(); paused = true; } catch (error) {} }, 20);
        return { message: "Stepped about one frame.", messageZhHans: "已单步约一帧。" };
      } });
    }
    if (typeof window.FloeGame.restart === "function") {
      actions.push({ id: "engine.restart", label: "Restart game", labelZhHans: "重新开始游戏", group: "Engine", groupZhHans: "引擎", symbol: "arrow.counterclockwise", role: "destructive", confirmation: "required", detail: "Reloads the real love.js runtime.", detailZhHans: "重新加载真实 love.js 运行时。", invoke: function () { window.FloeGame.restart(); return { status: "reloading", message: "Restarting.", messageZhHans: "正在重新开始。" }; } });
    }
    D.setRuntime("LÖVE");
    D.notice("live-fields-plan", "Live LÖVE values require a project-side Lua registration and a host transport; the reviewed runtime exposes real main-loop pause/resume/step only.", "实时 LÖVE 值需要工程侧 Lua 登记和宿主传输；已审查运行时只提供真实主循环暂停/继续/单步。");
    D.register({
      actions: actions,
      pause: canPause() ? function () { module().pauseMainLoop(); paused = true; } : undefined,
      resume: canPause() ? function () { module().resumeMainLoop(); paused = false; } : undefined,
      diagnostics: function () { return { paused: String(paused), mainLoop: canPause() ? "available" : "missing" }; }
    });
  }
  boot();
})();
