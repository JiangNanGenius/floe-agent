/* SPDX-License-Identifier: MPL-2.0 */
/* RGSS: live fields are provided by the bounded guest file-RPC transport.
   This WebKit hook only reports the Web harness snapshot fallback. */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D) return;
  if (window.FloeGame) {
    D.notice("rgss-web-harness", "This RGSS Web harness exposes save-state snapshot/restore; live party fields use the guest file-RPC transport.", "此 RGSS 网页宿主提供存档状态快照/恢复；实时队伍字段使用客体文件 RPC 传输。");
  } else {
    D.notice("rgss-guest-required", "RGSS live controls require the host's bounded guest file-RPC transport.", "RGSS 实时控制需要宿主的有界客体文件 RPC 传输。");
  }
  D.setRuntime("RGSS");
})();
