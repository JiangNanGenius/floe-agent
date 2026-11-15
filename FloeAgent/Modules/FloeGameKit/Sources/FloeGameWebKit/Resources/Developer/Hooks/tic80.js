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
    if (!window.Module && attempts++ < 300) { setTimeout(boot, 100); return; }
    var actions = [];
    if (canPause()) {
      actions.push({ id: "engine.pause", label: "Pause", labelZhHans: "暂停", group: "Engine", groupZhHans: "引擎", symbol: "pause.fill", isQuick: true, detail: "Pauses the real TIC-80 Emscripten main loop.", detailZhHans: "暂停真实 TIC-80 Emscripten 主循环。", invoke: function () { module().pauseMainLoop(); paused = true; return { message: "TIC-80 paused.", messageZhHans: "TIC-80 已暂停。" }; } });
      actions.push({ id: "engine.resume", label: "Resume", labelZhHans: "继续", group: "Engine", groupZhHans: "引擎", symbol: "play.fill", isQuick: true, invoke: function () { module().resumeMainLoop(); paused = false; return { message: "TIC-80 resumed.", messageZhHans: "TIC-80 已继续。" }; } });
      actions.push({ id: "engine.step", label: "Step frame", labelZhHans: "单步帧", group: "Engine", groupZhHans: "引擎", symbol: "forward.frame", detail: "Resumes for about one 60 Hz frame, then pauses again.", detailZhHans: "恢复约一个 60Hz 帧后再次暂停。", invoke: function () {
        var m = module();
        if (!paused) m.pauseMainLoop();
        m.resumeMainLoop();
        setTimeout(function () { try { m.pauseMainLoop(); paused = true; } catch (error) {} }, 20);
        return { message: "Stepped about one frame.", messageZhHans: "已单步约一帧。" };
      } });
    }
    D.setRuntime("TIC-80");
    D.notice("tic80-no-state", "The reviewed TIC-80 player exposes real main-loop pause/resume/step but no cart state API; live values require a rebuilt cart-side transport.", "已审查的 TIC-80 播放器提供真实主循环暂停/继续/单步，但没有卡带状态 API；实时值需要重建的卡带侧传输。");
    D.register({
      actions: actions,
      pause: canPause() ? function () { module().pauseMainLoop(); paused = true; } : undefined,
      resume: canPause() ? function () { module().resumeMainLoop(); paused = false; } : undefined,
      diagnostics: function () { return { paused: String(paused), mainLoop: canPause() ? "available" : "missing" }; }
    });
  }
  boot();
})();
