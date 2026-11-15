/* SPDX-License-Identifier: MPL-2.0 */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D) return;
  var attempts = 0;
  function boot() {
    if (!window.FloeGame) { attempts++; if (attempts < 300) setTimeout(boot, 100); return; }
    var snapshot = null;
    try { snapshot = window.FloeGame.snapshot(); } catch (e) {}
    var fields = [];
    if (snapshot && snapshot.named && typeof snapshot.named === "object" && !Array.isArray(snapshot.named)) {
      Object.keys(snapshot.named).slice(0, 32).forEach(function (key) {
        var value = snapshot.named[key];
        var kind;
        if (typeof value === "boolean") kind = "boolean";
        else if (typeof value === "number" && isFinite(value)) kind = "number";
        else if (typeof value === "string" && value.length <= 256) kind = "text";
        else return;
        fields.push({ id: "state." + key.replace(/[^A-Za-z0-9]/g, ""), label: key, labelZhHans: key, group: "State", groupZhHans: "状态", kind: kind, symbol: "number",
          get: function () {
            try { var next = window.FloeGame.snapshot(); return next && next.named ? next.named[key] : undefined; }
            catch (e) { return undefined; }
          },
          set: function (nextValue) {
            var next = window.FloeGame.snapshot();
            if (!next || !next.named) throw new Error("The project named state is unavailable.");
            var named = {};
            Object.keys(next.named).forEach(function (name) { named[name] = next.named[name]; });
            named[key] = nextValue;
            if (window.FloeGame.restore({ named: named }) === false) throw new Error("The project refused the named restore.");
          }
        });
      });
    } else {
      for (var index = 0; index < 16; index++) {
        (function (slot) {
          fields.push({ id: "state.slot" + slot, label: "State slot " + slot, labelZhHans: "状态槽 " + slot, group: "State", groupZhHans: "状态", kind: "readOnlyNumber", symbol: "number", get: function () {
            try { var next = window.FloeGame.snapshot(); return next && next.values && typeof next.values[slot] === "number" ? next.values[slot] : 0; }
            catch (e) { return 0; }
          } });
        })(index);
      }
    }
    D.setRuntime("microStudio");
    if (!snapshot || !snapshot.named) {
      D.notice("named-fields", "For writable named microStudio state, return an object from the project's floe_snapshot and implement floe_restore_named.", "如需可写的具名 microStudio 状态，请让工程的 floe_snapshot 返回对象并实现 floe_restore_named。");
    }
    D.register({ fields: fields });
  }
  boot();
})();
