/* SPDX-License-Identifier: MPL-2.0 */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D) return;
  D.setRuntime("Unity WebGL");
  D.notice("unity-push-bridge", "Unity fields/actions use the C#/jslib push bridge; add Project/unity-floe-developer.* to a WebGL build.", "Unity 字段/动作使用 C#/jslib 推送桥；请把 Project/unity-floe-developer.* 加入 WebGL 构建。");
  D.register({});
})();
