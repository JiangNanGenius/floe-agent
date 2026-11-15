/* SPDX-License-Identifier: MPL-2.0 */
/*
 * FloeGameNarrativeKit TIC-80 boot configuration (MPL-2.0).
 *
 * This only configures the unchanged upstream tic80.js player (MIT) to load the
 * original cart.tic through its own Module.arguments/FS preload path. It adds
 * no evaluator, host file access or native bridge.
 */
"use strict";

window.Module = {
  canvas: document.getElementById("canvas"),
  arguments: ["cart.tic"],
  print: function (text) {
    if (window.floeGameHost && typeof window.floeGameHost.log === "function") {
      window.floeGameHost.log(String(text));
    }
  },
  printErr: function (text) {
    if (window.floeGameHost && typeof window.floeGameHost.log === "function") {
      window.floeGameHost.log(String(text));
    }
  },
  onRuntimeInitialized: function () {
    const module = window.Module;
    const start = module._sokol_start;
    module._sokol_start = function () {
      const result = start.apply(this, arguments);
      module.floeCartStarted = true;
      return result;
    };
  }
};
