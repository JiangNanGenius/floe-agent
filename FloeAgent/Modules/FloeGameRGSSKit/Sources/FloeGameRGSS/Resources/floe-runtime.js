/* SPDX-License-Identifier: MPL-2.0 */
/* Floe RGSS Web runtime harness.
 *
 * This file is served by the existing GameWebArtifactPackage scheme handler.
 * It only touches the package's virtual Emscripten MEMFS and same-origin
 * package URLs. It has no host filesystem mount, no native bridge, no
 * IndexedDB/localStorage/service worker and no general evaluator.
 */
(function () {
  "use strict";

  var config = window.FLOE_RGSS_CONFIG;
  if (!config || typeof config !== "object") {
    throw new Error("missing FLOE_RGSS_CONFIG");
  }
  var engine = String(config.engine || "");
  var gameRoot = "/game";
  var stateLimit = Number(config.stateLimit || 1048576);
  var logs = [];
  var errors = [];
  var ready = false;
  var booted = false;
  var frames = 0;
  var saves = Object.create(null);
  var pendingRestore = null;
  var allowed = Object.create(null);
  var keyMap = Object.create(null);
  var preloaded = Object.create(null);

  function log(text) {
    var value = String(text == null ? "" : text);
    if (value.length > 2048) value = value.slice(0, 2048);
    logs.push(value);
    if (logs.length > 200) logs.splice(0, logs.length - 200);
    if (window.floeGameHost && typeof window.floeGameHost.log === "function") {
      try { window.floeGameHost.log(value); } catch (_) {}
    }
    var frameMatch = /^FLOE_FRAME\s+(\d+)(?:\s|$)/.exec(value);
    if (frameMatch) {
      frames = Math.max(frames, Number(frameMatch[1]) || 1);
      if (!ready) noteReady();
    }
  }

  function noteStderr(text) {
    var value = String(text == null ? "" : text);
    if (value.length > 2048) value = value.slice(0, 2048);
    log("FLOE_STDERR " + value);
    if (/error|failed|abort|exception|unable|invalid/i.test(value)) fail(value);
  }

  function fail(error) {
    var text = String(error && error.message ? error.message : error);
    if (text.length > 2048) text = text.slice(0, 2048);
    errors.push(text);
    if (errors.length > 50) errors.splice(0, errors.length - 50);
    log("FLOE_ERROR " + text);
  }

  function noteReady() {
    frames = Math.max(frames, 1);
    if (ready) return;
    ready = true;
    if (window.floeGameHost && typeof window.floeGameHost.ready === "function") {
      try {
        window.floeGameHost.ready({ input: true, state: true, engine: engine });
      } catch (error) { fail(error); }
    }
  }

  function cleanRelative(value) {
    var text = String(value == null ? "" : value).replace(/\\/g, "/");
    text = text.replace(/^\/+/, "");
    if (text.indexOf(gameRoot.slice(1) + "/") === 0) text = text.slice(gameRoot.length);
    if (!text || text.length > 1024 || text.indexOf("\u0000") >= 0) return null;
    var parts = text.split("/");
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i];
      if (!part || part === "." || part === ".." || part.indexOf(":") >= 0) return null;
      if (/[\u0000-\u001f\u007f]/.test(part)) return null;
    }
    return parts.join("/");
  }

  function encodePath(relative) {
    return relative.split("/").map(function (part) { return encodeURIComponent(part); }).join("/");
  }

  function ensureDirectory(path) {
    var parts = path.split("/").filter(function (part) { return part.length > 0; });
    var current = "";
    for (var i = 0; i < parts.length; i++) {
      current += "/" + parts[i];
      if (!FS.analyzePath(current).exists) FS.mkdir(current);
    }
  }

  function writeVirtual(relative, bytes) {
    var path = gameRoot + "/" + relative;
    var parent = path.slice(0, path.lastIndexOf("/"));
    ensureDirectory(parent);
    FS.writeFile(path, new Uint8Array(bytes));
  }

  function readVirtual(relative) {
    var path = gameRoot + "/" + relative;
    if (!FS.analyzePath(path).exists) return null;
    return FS.readFile(path);
  }

  function base64(bytes) {
    var text = "";
    var chunk = 0x8000;
    for (var i = 0; i < bytes.length; i += chunk) {
      text += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(i + chunk, bytes.length)));
    }
    return btoa(text);
  }

  function fromBase64(value) {
    var text = atob(String(value));
    var bytes = new Uint8Array(text.length);
    for (var i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
    return bytes;
  }

  function describeKey(name) {
    var raw = String(name || "").toLowerCase();
    var special = {
      left: ["ArrowLeft", "ArrowLeft", 37, 0], right: ["ArrowRight", "ArrowRight", 39, 0],
      up: ["ArrowUp", "ArrowUp", 38, 0], down: ["ArrowDown", "ArrowDown", 40, 0],
      enter: ["Enter", "Enter", 13, 0], escape: ["Escape", "Escape", 27, 0],
      space: [" ", "Space", 32, 0], tab: ["Tab", "Tab", 9, 0],
      shift: ["Shift", "ShiftLeft", 16, 1], rightShift: ["Shift", "ShiftRight", 16, 2],
      control: ["Control", "ControlLeft", 17, 1], alt: ["Alt", "AltLeft", 18, 1]
    };
    if (special[raw]) return { key: special[raw][0], code: special[raw][1], keyCode: special[raw][2], location: special[raw][3] };
    if (/^[a-z]$/.test(raw)) return { key: raw, code: "Key" + raw.toUpperCase(), keyCode: raw.toUpperCase().charCodeAt(0), location: 0 };
    if (/^[0-9]$/.test(raw)) return { key: raw, code: "Digit" + raw, keyCode: 48 + Number(raw), location: 0 };
    if (/^f([1-9]|1[0-9]|2[0-4])$/.test(raw)) return { key: raw.toUpperCase(), code: raw.toUpperCase(), keyCode: 111 + Number(raw.slice(1)), location: 0 };
    if (raw.indexOf("key") === 0 && /^key[a-z]$/.test(raw)) {
      var letter = raw.slice(3);
      return { key: letter, code: "Key" + letter.toUpperCase(), keyCode: letter.toUpperCase().charCodeAt(0), location: 0 };
    }
    if (/^(arrow(left|right|up|down)|enter|escape|space|tab|shiftleft|shiftright)$/.test(raw)) {
      var byCode = {
        arrowleft: special.left, arrowright: special.right, arrowup: special.up, arrowdown: special.down,
        enter: special.enter, escape: special.escape, space: special.space, tab: special.tab,
        shiftleft: special.shift, shiftright: special.rightShift
      };
      return byCode[raw];
    }
    return null;
  }

  function registerDeclaration(declaration) {
    if (!declaration || declaration.schemaVersion !== 1) return;
    var keys = [];
    var movement = declaration.movement || {};
    ["left", "right", "up", "down"].forEach(function (direction) {
      (movement[direction] || []).forEach(function (name) { keys.push(name); });
    });
    (declaration.buttons || []).forEach(function (button) {
      if (!button || !Array.isArray(button.keys)) return;
      button.keys.forEach(function (name) { keys.push(name); });
    });
    keys.forEach(function (name) {
      var descriptor = describeKey(name);
      if (!descriptor) return;
      allowed[descriptor.key] = descriptor;
      allowed[descriptor.code] = descriptor;
      allowed[String(descriptor.keyCode)] = descriptor;
      if (/^[a-z]$/i.test(String(name))) {
        keyMap[String(name).toLowerCase()] = descriptor;
        keyMap[descriptor.code] = descriptor;
      }
    });
  }

  function dispatchKeyboard(descriptor, pressed, options) {
    var event = new KeyboardEvent(pressed ? "keydown" : "keyup", {
      key: descriptor.key, code: descriptor.code,
      location: descriptor.location || 0,
      shiftKey: !!(options && options.shiftKey), ctrlKey: !!(options && options.ctrlKey),
      altKey: !!(options && options.altKey), metaKey: !!(options && options.metaKey),
      repeat: !!(options && options.repeat), bubbles: true, cancelable: true
    });
    // Chromium does not apply keyCode/which from the KeyboardEvent init
    // dictionary. The legacy Emscripten/SDL keyboard path still reads them.
    for (var property of ["keyCode", "which", "charCode"]) {
      try { Object.defineProperty(event, property, { value: property === "charCode" ? 0 : descriptor.keyCode }); } catch (_) {}
    }
    var target = document.getElementById("canvas") || document.body || document.documentElement;
    target.dispatchEvent(event);
    return true;
  }

  function resolveKey(input) {
    if (!input || typeof input !== "object") return null;
    var candidates = [input.code, input.key, String(input.keyCode || ""), String(input.which || "")];
    for (var i = 0; i < candidates.length; i++) {
      var value = candidates[i];
      if (value == null) continue;
      var text = String(value);
      if (allowed[text]) return allowed[text];
      if (allowed[text.toLowerCase()]) return allowed[text.toLowerCase()];
    }
    if (input.code && /^Key[A-Z]$/.test(input.code)) {
      var descriptor = describeKey(input.code.slice(3).toLowerCase());
      if (descriptor && allowed[descriptor.key]) return descriptor;
    }
    return null;
  }

  function snapshot() {
    var files = [];
    var total = 0;
    Object.keys(saves).sort().forEach(function (name) {
      var record = saves[name];
      total += record.bytes;
      if (total > Math.floor(stateLimit * 0.70)) return;
      files.push({ name: name, bytes: record.bytes, data: record.data });
    });
    var value = {
      format: "floe-rgss-saves", version: 1, engine: engine,
      files: files, truncated: files.length < Object.keys(saves).length,
      stats: { frames: frames }
    };
    var encoded = JSON.stringify(value);
    if (encoded.length > stateLimit) throw new Error("RGSS save state exceeds host limit");
    return value;
  }

  function applyRestoredFiles(staged) {
    staged.forEach(function (file) {
      writeVirtual(file.name, file.bytes);
      saves[file.name] = { bytes: file.bytes.length, data: base64(file.bytes) };
    });
  }

  function restore(state) {
    if (!state || state.format !== "floe-rgss-saves" || state.version !== 1 || !Array.isArray(state.files)) {
      return false;
    }
    if (state.engine && state.engine !== engine) return false;
    var staged = [];
    var total = 0;
    for (var i = 0; i < state.files.length; i++) {
      var file = state.files[i];
      var name = cleanRelative(file && file.name);
      if (!name || !/^Save[^/]*\.(rxdata|rvdata|rvdata2)$/i.test(name)) return false;
      var bytes = fromBase64(file.data);
      total += bytes.length;
      if (total > Math.floor(stateLimit * 0.70)) return false;
      staged.push({ name: name, bytes: bytes });
    }
    if (!booted) {
      pendingRestore = staged;
      return true;
    }
    applyRestoredFiles(staged);
    return true;
  }

  function onSaveFile(filename) {
    var relative = cleanRelative(filename);
    if (!relative) { fail("invalid save filename"); return; }
    var bytes = readVirtual(relative);
    if (!bytes) { fail("save file missing: " + relative); return; }
    if (bytes.length > Math.floor(stateLimit * 0.70)) { fail("save file exceeds bridge limit: " + relative); return; }
    saves[relative] = { bytes: bytes.length, data: base64(bytes) };
    log("FLOE_SAVE_BRIDGE " + relative + " " + bytes.length);
  }

  function onLoadFileAsync(fullPath, bitmap, callback) {
    var done = callback || function () {};
    var relative = cleanRelative(fullPath);
    if (!relative) { fail("invalid game path: " + fullPath); done(); return; }
    var path = gameRoot + "/" + relative;
    if (FS.analyzePath(path).exists) { done(); return; }
    var attempt = 0;
    var load = function () {
      attempt += 1;
      fetch("game/" + encodePath(relative), { cache: "no-store", credentials: "omit", redirect: "error" })
        .then(function (response) {
          if (!response.ok) throw new Error("HTTP " + response.status + " for " + relative);
          return response.arrayBuffer();
        })
        .then(function (buffer) {
          writeVirtual(relative, new Uint8Array(buffer));
          preloaded[relative] = true;
          done();
        })
        .catch(function (error) {
          if (attempt < 2) { setTimeout(load, 25); return; }
          fail("asset load failed: " + relative + " (" + (error && error.message ? error.message : error) + ")");
          done();
        });
    };
    load();
  }

  function writePreload() {
    if (!FS.analyzePath(gameRoot).exists) FS.mkdir(gameRoot);
    var list = Array.isArray(config.preload) ? config.preload : [];
    for (var i = 0; i < list.length; i++) {
      var relative = cleanRelative(list[i]);
      if (!relative || !config.files || !Object.prototype.hasOwnProperty.call(config.files, relative)) continue;
      var bytes = config.files[relative];
      if (typeof bytes === "string") writeVirtual(relative, fromBase64(bytes));
    }
    if (pendingRestore) {
      applyRestoredFiles(pendingRestore);
      pendingRestore = null;
    }
  }

  function mainLoopSeen() {
    booted = true;
    frames = Math.max(frames, 1);
    setTimeout(noteReady, 300);
    var poll = setInterval(function () {
      if (ready) { clearInterval(poll); return; }
      if (booted) { noteReady(); clearInterval(poll); }
    }, 500);
    setTimeout(function () { clearInterval(poll); }, 5000);
  }

  window.fileAsyncCache = Object.create(null);
  window.loadFileAsync = onLoadFileAsync;
  window.saveFile = onSaveFile;
  window.getMappingKey = function (file) { return String(file).toLowerCase().replace(/\.[^/.]+$/, ""); };

  window.FloeGame = Object.freeze({
    input: function (name, pressed) {
      var raw = String(name || "").toLowerCase();
      var aliases = {
        confirm: ["c", "enter", "space"], cancel: ["x", "escape"],
        action1: ["z", "shift"], action2: ["q"], action3: ["w"],
        action4: ["a"], start: ["enter"], select: ["tab"],
        left: ["left"], right: ["right"], up: ["up"], down: ["down"]
      };
      var names = aliases[raw];
      if (!names) return false;
      var handled = false;
      names.forEach(function (keyName) {
        var descriptor = keyMap[keyName] || describeKey(keyName);
        if (!descriptor) return;
        if (allowed[descriptor.key] || allowed[descriptor.code]) { dispatchKeyboard(descriptor, !!pressed, {}); handled = true; }
      });
      return handled;
    },
    key: function (event) {
      var descriptor = resolveKey(event);
      if (!descriptor) return false;
      return dispatchKeyboard(descriptor, !!(event && event.pressed), event || {});
    },
    pointer: function (phase, x, y, button) {
      if (![ "began", "moved", "ended" ].includes(phase)) return false;
      if (!Number.isFinite(x) || !Number.isFinite(y) || x < 0 || x > 1 || y < 0 || y > 1) return false;
      var canvas = document.getElementById("canvas");
      if (!canvas) return false;
      var rect = canvas.getBoundingClientRect();
      var clientX = rect.left + x * rect.width, clientY = rect.top + y * rect.height;
      var options = { bubbles: true, cancelable: true, clientX: clientX, clientY: clientY, button: Number(button) || 0, buttons: phase === "ended" ? 0 : 1, pointerId: 1, pointerType: "mouse", isPrimary: true };
      var pointer = { began: "pointerdown", moved: "pointermove", ended: "pointerup" }[phase];
      var mouse = { began: "mousedown", moved: "mousemove", ended: "mouseup" }[phase];
      canvas.dispatchEvent(new PointerEvent(pointer, options));
      canvas.dispatchEvent(new MouseEvent(mouse, options));
      return true;
    },
    snapshot: snapshot,
    restore: restore,
    stats: function () { return { ready: ready, booted: booted, frames: frames, logs: logs.slice(), errors: errors.slice(), saves: Object.keys(saves).sort() }; }
  });

  registerDeclaration(config.input);

  if (window.__floeInitialState) {
    try { restore(window.__floeInitialState); } catch (error) { fail(error); }
  }

  window.addEventListener("error", function (event) { fail(event.error || event.message || "script error"); });
  window.addEventListener("unhandledrejection", function (event) { fail(event.reason || "unhandled rejection"); });

  var Module = {
    preRun: [writePreload],
    postRun: [mainLoopSeen],
    print: function (text) { log(text); },
    printErr: function (text) { noteStderr(text); },
    canvas: document.getElementById("canvas"),
    noAudioDecoding: true,
    locateFile: function (name) { return name.indexOf(".wasm") >= 0 ? config.wasmURL : name; },
    setStatus: function () {}
  };
  window.Module = Module;

  var script = document.createElement("script");
  script.src = config.jsURL;
  script.onerror = function () { fail("unable to load mkxp.js"); };
  document.body.appendChild(script);
})();
