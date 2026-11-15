/* SPDX-License-Identifier: MPL-2.0 */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D) return;
  var attempts = 0;
  function runtime() { return window.FloeInkRuntime || null; }
  function field(id, en, zh, group, groupZh, kind, extra) {
    var v = { id: id, label: en, labelZhHans: zh, group: group, groupZhHans: groupZh, kind: kind };
    if (extra) Object.keys(extra).forEach(function (k) { v[k] = extra[k]; });
    return v;
  }
  function boot() {
    if (!runtime() || !runtime().story()) { attempts++; if (attempts < 300) setTimeout(boot, 100); return; }
    var R = runtime();
    var variables = R.variables();
    var names = Object.keys(variables).slice(0, 48);
    var fields = [
      field("story.path", "Current path", "当前路径", "Story", "故事", "readOnlyText", { symbol: "point.topleft.down.to.point.bottomright.curvepath", get: function () { try { return R.story().state.currentPathString || "—"; } catch (e) { return "—"; } } }),
      field("story.choices", "Choices", "选项", "Story", "故事", "readOnlyText", { symbol: "list.bullet", get: function () { try { return R.choices().map(function (c) { return c.text; }).join(" · ") || "—"; } catch (e) { return "—"; } } })
    ];
    names.forEach(function (name, index) {
      var value = variables[name];
      var kind = typeof value === "boolean" ? "boolean" : (typeof value === "number" ? "number" : "text");
      var extra = {};
      extra.symbol = "textformat";
      extra.get = function () { return R.variables()[name]; };
      if (kind !== "readOnlyText") extra.set = function (v) { if (!R.setVariable(name, v)) throw new Error("Ink rejected the variable."); };
      fields.push(field("variables.v" + index, name, name, "Variables", "变量", kind, extra));
    });
    var actions = [
      { id: "story.choose", label: "Choose", labelZhHans: "选择", group: "Story", groupZhHans: "故事", symbol: "hand.tap", parameters: [
        { id: "index", label: "Choice index", labelZhHans: "选项序号", kind: "integer", minimum: 0, maximum: 999, step: 1, isRequired: true, defaultValue: 0 }
      ], invoke: function (args) { if (!R.choose(args.index)) throw new Error("No choice at that index."); return { message: "Choice selected.", messageZhHans: "已选择。" }; } },
      { id: "story.jump", label: "Jump to knot", labelZhHans: "跳转节点", group: "Story", groupZhHans: "故事", symbol: "arrow.turn.down.right", role: "jump", parameters: [
        { id: "path", label: "Knot path", labelZhHans: "节点路径", kind: "text", maximumLength: 128, isRequired: true }
      ], invoke: function (args) { if (!R.jump(args.path)) throw new Error("Ink rejected the path."); return { message: "Jumped.", messageZhHans: "已跳转。" }; } },
      { id: "variables.set", label: "Set variable", labelZhHans: "设置变量", group: "Variables", groupZhHans: "变量", symbol: "number", parameters: [
        { id: "name", label: "Name", labelZhHans: "名称", kind: "text", maximumLength: 128, isRequired: true },
        { id: "value", label: "Value", labelZhHans: "值", kind: "text", maximumLength: 8192, isRequired: true }
      ], invoke: function (args) {
        var raw = String(args.value);
        var value = raw === "true" ? true : (raw === "false" ? false : (/^-?\d+(\.\d+)?$/.test(raw) ? Number(raw) : raw));
        if (!R.setVariable(args.name, value)) throw new Error("Ink rejected the variable.");
        return { message: "Variable updated.", messageZhHans: "变量已更新。" };
      } }
    ];
    D.setRuntime("inkjs");
    D.register({ fields: fields, actions: actions, diagnostics: function () { return { choices: String(R.choices().length), path: String(R.story().state.currentPathString || "") }; } });
  }
  boot();
})();
