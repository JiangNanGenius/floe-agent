/* SPDX-License-Identifier: MPL-2.0 */
(function () {
  "use strict";
  var D = window.FloeDeveloper;
  if (!D) return;
  var attempts = 0;
  function boot() {
    if (!window.FloeGame) { attempts++; if (attempts < 300) setTimeout(boot, 100); return; }
    var fields = [];
    try {
      var snapshot = window.FloeGame.snapshot();
      var globals = snapshot && snapshot.globals ? snapshot.globals : {};
      Object.keys(globals).slice(0, 16).forEach(function (key, index) {
        var value = globals[key];
        var kind = typeof value === "boolean" ? "boolean" :
          (typeof value === "number" && isFinite(value) ? "number" : "readOnlyText");
        var descriptor = { id: "cart.global" + index, label: key, labelZhHans: key, group: "Cartridge", groupZhHans: "卡带", kind: kind, symbol: "cpu",
          get: function () {
            try { var next = window.FloeGame.snapshot(); return next && next.globals ? next.globals[key] : value; }
            catch (e) { return value; }
          } };
        if (kind !== "readOnlyText") {
          descriptor.set = function (nextValue) {
            var next = window.FloeGame.snapshot();
            if (!next || !next.globals) throw new Error("WASM-4 saved globals are unavailable.");
            var updated = {};
            Object.keys(next.globals).forEach(function (name) { updated[name] = next.globals[name]; });
            updated[key] = nextValue;
            next.globals = updated;
            if (window.FloeGame.restore(next) === false) throw new Error("WASM-4 refused the snapshot restore.");
          };
        }
        fields.push(descriptor);
      });
    } catch (e) {}
    D.setRuntime("WASM-4");
    D.register({ fields: fields });
  }
  boot();
})();
