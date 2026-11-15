/* SPDX-License-Identifier: MPL-2.0 */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D || typeof D.setRuntime !== "function") return;
  D.setRuntime("GDevelop");
  if (window.__floeGDevelopHookInstalled) return;
  window.__floeGDevelopHookInstalled = true;

  var attempts = 0;
  function check() {
    var host = window.FloeDeveloper;
    if (!host || host !== D) return;
    var bridge = window.__floeGDevelopBridge;
    if (bridge && bridge.installed === true) {
      D.notice("gdevelop-bridge",
        "The private GDevelop export includes the Floe development bridge; live scene, variables, positions, time scale and pause/step are available.",
        "私有 GDevelop 导出已包含 Floe 开发桥；可使用实时场景、变量、位置、时间缩放与暂停/单步。");
      return;
    }
    attempts += 1;
    if (attempts < 50) { setTimeout(check, 100); return; }
    D.notice("gdevelop-undecorated",
      "This GDevelop page was not decorated by the Floe exporter or run preparer. Use Floe's build/run path, or install the project hook and export a private playable copy.",
      "此 GDevelop 页面未由 Floe 导出器或运行准备器装饰。请使用 Floe 构建/运行路径，或安装工程钩子后导出私有试玩副本。");
  }
  setTimeout(check, 100);
  D.register({});
})();
