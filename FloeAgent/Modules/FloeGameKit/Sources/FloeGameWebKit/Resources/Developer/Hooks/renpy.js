/* SPDX-License-Identifier: MPL-2.0 */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D) return;
  var attempts = 0;
  function playback(id, label, labelZh, code, key, keyCode, symbol) {
    return {
      id: id, label: label, labelZhHans: labelZh,
      group: "Story playback", groupZhHans: "剧情播放", symbol: symbol,
      detail: "Uses the default Ren'Py keymap. The game controls availability and custom bindings.",
      detailZhHans: "使用 Ren'Py 默认按键，具体行为以游戏自身设置为准。",
      invoke: async function () {
        var game = window.FloeGame;
        var down = { code: code, key: key, keyCode: keyCode, which: keyCode, pressed: true };
        if (!game || game.key(down) === false) throw new Error("The game did not accept the playback input.");
        // A finite key pulse never leaves Ctrl or another key held across a
        // closed inspector/run. Both events use the existing game input port.
        await new Promise(function (resolve) { setTimeout(resolve, 45); });
        game.key({ code: code, key: key, keyCode: keyCode, which: keyCode, pressed: false });
        return { message: "Playback input sent.", messageZhHans: "已发送剧情操作。" };
      }
    };
  }
  function boot() {
    if (!window.FloeGame) { attempts++; if (attempts < 300) setTimeout(boot, 100); return; }
    var actions = [];
    if (typeof window.FloeGame.key === "function") {
      actions.push(playback("story.advance", "Advance dialogue", "推进对白", "Enter", "Enter", 13, "forward.end"));
      actions.push(playback("story.rollback", "Roll back", "剧情回退", "PageUp", "PageUp", 33, "backward"));
      actions.push(playback("story.rollForward", "Roll forward", "向前恢复", "PageDown", "PageDown", 34, "forward"));
      actions.push(playback("story.toggleSkip", "Toggle skipping", "切换快进", "Tab", "Tab", 9, "forward.fill"));
      actions.push(playback("story.gameMenu", "Game menu", "游戏菜单", "Escape", "Escape", 27, "line.3.horizontal"));
      actions.push(playback("story.toggleDialogue", "Show or hide dialogue", "显示或隐藏对白", "KeyH", "h", 72, "text.bubble"));
    }
    if (typeof window.FloeGame.restart === "function") {
      actions.push({ id: "engine.restart", label: "Restart game", labelZhHans: "重新开始游戏", group: "Engine", groupZhHans: "引擎", symbol: "arrow.counterclockwise", role: "destructive", confirmation: "required", detail: "Reloads the official Ren'Py Web runtime.", detailZhHans: "重新加载官方 Ren'Py 网页运行时。", invoke: function () { window.FloeGame.restart(); return { status: "reloading", message: "Restarting.", messageZhHans: "正在重新开始。" }; } });
    }
    D.setRuntime("Ren'Py");
    D.notice("story-controls", "Playback uses Ren'Py's default keyboard bindings; custom games may change or disable them. Live store fields require an explicit project transport.", "剧情操作使用 Ren'Py 默认键位，游戏可能改绑或禁用；实时变量需要工程接入调试数据。");
    D.register({ actions: actions });
  }
  boot();
})();
