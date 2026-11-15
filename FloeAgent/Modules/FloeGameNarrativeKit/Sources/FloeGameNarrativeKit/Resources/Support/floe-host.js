/* SPDX-License-Identifier: MPL-2.0 */
/*
 * FloeGameNarrativeKit shared Web support (MPL-2.0).
 *
 * This is readable Source Code Form, not minified output. It contains only
 * reusable Floe support code: host fallbacks, bounded same-origin JSON loading,
 * and explicit error reporting. Game story text, source code, maps, cartridges
 * and assets live in separate game/* or cart.* files and are never copied into
 * this file. The full MPL text is in licenses/FLOE-MPL-2.0.txt.
 */
(function () {
  "use strict";

  const fallbackHost = { ready: function () {}, log: function () {} };
  const host = window.floeGameHost || fallbackHost;

  function showError(message) {
    try {
      const body = document.body;
      if (!body) return;
      let panel = document.getElementById("floe-runtime-error");
      if (!panel) {
        panel = document.createElement("div");
        panel.id = "floe-runtime-error";
        panel.setAttribute("role", "alert");
        panel.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:2147483647;" +
          "padding:10px 14px;background:#5a1414;color:#fff;font:14px/1.4 system-ui;white-space:pre-wrap";
        body.appendChild(panel);
      }
      panel.textContent = String(message);
    } catch (ignored) {
      /* A failed error panel must not hide the log below. */
    }
  }

  function fail(message) {
    const text = String(message);
    showError(text);
    try { host.log("[floe] " + text); } catch (ignored) {}
    if (typeof host.error === "function") {
      try { host.error(text); } catch (ignored) {}
    }
  }

  async function fetchJSON(url) {
    const response = await fetch(url, { cache: "no-store" });
    if (!response || !response.ok) {
      throw new Error("could not load " + url +
        " (status " + (response ? response.status : "missing") + ")");
    }
    const value = await response.json();
    return value;
  }

  window.FloeSupport = Object.freeze({
    host: host,
    fail: fail,
    fetchJSON: fetchJSON,
    element: function (id) { return document.getElementById(id); }
  });
})();
