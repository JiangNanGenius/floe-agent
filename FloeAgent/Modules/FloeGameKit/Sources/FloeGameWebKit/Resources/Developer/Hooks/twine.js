/* SPDX-License-Identifier: MPL-2.0 */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D) return;
  var attempts = 0;
  function runtime() { return window.FloeTwineRuntime || null; }
  function field(id, en, zh, group, groupZh, kind, extra) {
    var v = { id: id, label: en, labelZhHans: zh, group: group, groupZhHans: groupZh, kind: kind };
    if (extra) Object.keys(extra).forEach(function (k) { v[k] = extra[k]; });
    return v;
  }
  function boot() {
    if (!runtime() || !runtime().state()) { attempts++; if (attempts < 300) setTimeout(boot, 100); return; }
    var R = runtime();
    var variables = R.variables();
    var names = Object.keys(variables).slice(0, 48);
    var fields = [
      field("story.passage", "Passage", "段落", "Story", "故事", "readOnlyText", { symbol: "book.pages", get: function () { try { return R.state().passage || "—"; } catch (e) { return "—"; } } }),
      field("story.turns", "Turns", "回合", "Story", "故事", "readOnlyNumber", { symbol: "arrow.triangle.2.circlepath", get: function () { try { return R.state().turns || 0; } catch (e) { return 0; } } })
    ];
    names.forEach(function (name, index) {
      var value = variables[name];
      var kind = typeof value === "boolean" ? "boolean" : (typeof value === "number" ? "number" : "text");
      var extra = { symbol: "textformat", get: function () { return R.variables()[name]; } };
      if (kind !== "readOnlyText") extra.set = function (v) { R.state().variables[name] = v; };
      fields.push(field("variables.v" + index, name, name, "Variables", "变量", kind, extra));
    });
    var actions = [
      { id: "story.goto", label: "Go to passage", labelZhHans: "跳转段落", group: "Story", groupZhHans: "故事", symbol: "arrow.turn.down.right", role: "jump", parameters: [
        { id: "passage", label: "Passage", labelZhHans: "段落", kind: "text", maximumLength: 256, isRequired: true }
      ], invoke: function (args) { if (!R.jump(args.passage)) throw new Error("SugarCube rejected the passage."); return { message: "Passage opened.", messageZhHans: "已打开段落。" }; } },
      { id: "variables.set", label: "Set variable", labelZhHans: "设置变量", group: "Variables", groupZhHans: "变量", symbol: "number", parameters: [
        { id: "name", label: "Name", labelZhHans: "名称", kind: "text", maximumLength: 128, isRequired: true },
        { id: "value", label: "Value", labelZhHans: "值", kind: "text", maximumLength: 8192, isRequired: true }
      ], invoke: function (args) {
        var raw = String(args.value);
        var value = raw === "true" ? true : (raw === "false" ? false : (/^-?\d+(\.\d+)?$/.test(raw) ? Number(raw) : raw));
        R.state().variables[args.name] = value;
        return { message: "Variable updated.", messageZhHans: "变量已更新。" };
      } }
    ];
    D.setRuntime("SugarCube");
    D.register({ fields: fields, actions: actions, diagnostics: function () { return { passage: String(R.state().passage || ""), turns: String(R.state().turns || 0) }; } });
  }
  boot();
})();
