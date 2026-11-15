/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Optional project-side registration for a browser/Web engine build.
 * Copy this file into a project revision ONLY when the project wants custom
 * fields/actions. It never runs in a production export unless the export
 * includes it; the development helper itself is host-injected.
 */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D) return;
  D.register({
    fields: [
      { id: "project.score", label: "Score", labelZhHans: "分数", group: "Project", groupZhHans: "工程", kind: "integer", minimum: 0, maximum: 999999, step: 1,
        get: function () { return window.gameState && window.gameState.score || 0; },
        set: function (value) { if (window.gameState) window.gameState.score = value; } }
    ],
    actions: [
      { id: "project.resetLevel", label: "Reset level", labelZhHans: "重置关卡", group: "Project", groupZhHans: "工程", symbol: "arrow.counterclockwise", role: "destructive", confirmation: "required",
        invoke: function () { if (window.game && window.game.scene) window.game.scene.restart(); return { message: "Level reset.", messageZhHans: "关卡已重置。" }; } }
    ]
  });
})();
