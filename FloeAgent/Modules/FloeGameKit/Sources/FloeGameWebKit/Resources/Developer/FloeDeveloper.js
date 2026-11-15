/* SPDX-License-Identifier: MPL-2.0 */
/*
 * FloeDeveloper 1.0.0 — host-injected, development-only page helper.
 *
 * This file is a fixed resource of the compiled host. It is not project code
 * and it is never exported into a production game. It exposes only typed,
 * bounded registration/read/write/snapshot/restore operations. There is no
 * arbitrary JavaScript/Ruby/shell evaluator and no host/network/filesystem
 * capability. Engine hooks and explicit project registration supply the
 * getters, setters and actions; the helper validates every value and field id.
 */
(function () {
  "use strict";

  var bootstrap = window.FloeDeveloperBootstrap || {};
  if (window.FloeDeveloper && window.FloeDeveloper.__floe === 1) {
    if (typeof window.FloeDeveloper.__rebind === "function") window.FloeDeveloper.__rebind(bootstrap);
    return;
  }
  var LIMITS = {
    fields: 256,
    actions: 128,
    parameters: 8,
    choices: 64,
    stringBytes: 8192,
    labelBytes: 256,
    detailBytes: 1024,
    changes: 32,
    requestBytes: Number(bootstrap.maximumRequestBytes) || 262144,
    responseBytes: Number(bootstrap.maximumResponseBytes) || 4194304,
    snapshotBytes: 4194304,
    history: 100,
    notices: 16
  };
  var RESERVED = {
    "__proto__": 1, "prototype": 1, "constructor": 1, "toString": 1,
    "valueOf": 1, "hasOwnProperty": 1, "isPrototypeOf": 1,
    "propertyIsEnumerable": 1, "__defineGetter__": 1, "__defineSetter__": 1,
    "__lookupGetter__": 1, "__lookupSetter__": 1
  };
  var KINDS = {
    boolean: 1, integer: 1, number: 1, text: 1, choice: 1,
    readOnlyText: 1, readOnlyNumber: 1, readOnlyBoolean: 1
  };
  var state = {
    token: String(bootstrap.token || ""),
    engine: String(bootstrap.engine || ""),
    runtime: "",
    active: true,
    detached: false,
    revision: 0,
    installedAt: Date.now(),
    frameCount: 0,
    fps: 0,
    lastFrameAt: 0,
    noticeRevision: 0
  };
  var fields = new Map();
  var actions = new Map();
  var notices = [];
  var hooks = Object.create(null);
  var history = [];
  var pushState = {
    values: Object.create(null),
    revision: 0,
    commands: [],
    pending: Object.create(null),
    nextCommand: 1
  };

  function idValid(id, maxBytes) {
    if (typeof id !== "string" || !id || (maxBytes && byteLength(id) > maxBytes)) return false;
    if (Object.prototype.hasOwnProperty.call(RESERVED, id)) return false;
    return /^[a-z][A-Za-z0-9]*(?:[._-][A-Za-z0-9]+)*$/.test(id) && id.length <= 128;
  }

  function optionValid(value) {
    return typeof value === "string" && value.length > 0 && value.length <= 128 &&
      /^[A-Za-z0-9][A-Za-z0-9_.:@-]*$/.test(value) &&
      !Object.prototype.hasOwnProperty.call(RESERVED, value);
  }

  function byteLength(text) {
    try {
      if (typeof TextEncoder === "function") return new TextEncoder().encode(text).length;
    } catch (ignored) {}
    var bytes = 0;
    for (var index = 0; index < text.length; index++) {
      var code = text.charCodeAt(index);
      if (code < 0x80) bytes += 1;
      else if (code < 0x800) bytes += 2;
      else if (code >= 0xd800 && code <= 0xdbff) { bytes += 4; index++; }
      else bytes += 3;
    }
    return bytes;
  }

  function text(value, maxBytes) {
    var result = typeof value === "string" ? value : String(value == null ? "" : value);
    if (byteLength(result) > maxBytes) result = result.slice(0, maxBytes);
    return result;
  }

  function messageText(value, maxBytes) {
    return text(value == null ? "" : value, maxBytes);
  }

  function hasControl(value) {
    return /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value);
  }

  function valueValid(value, kind, field) {
    if (kind === "boolean" || kind === "readOnlyBoolean") return typeof value === "boolean";
    if (kind === "integer") {
      if (typeof value !== "number" || !isFinite(value) || Math.floor(value) !== value) return false;
      if (typeof field.minimum === "number" && value < field.minimum) return false;
      if (typeof field.maximum === "number" && value > field.maximum) return false;
      return true;
    }
    if (kind === "number" || kind === "readOnlyNumber") {
      if (typeof value !== "number" || !isFinite(value)) return false;
      if (typeof field.minimum === "number" && value < field.minimum) return false;
      if (typeof field.maximum === "number" && value > field.maximum) return false;
      return true;
    }
    if (kind === "text" || kind === "readOnlyText") {
      return typeof value === "string" && byteLength(value) <= Math.min(field.maximumLength || LIMITS.stringBytes, LIMITS.stringBytes) && !hasControl(value);
    }
    if (kind === "choice") {
      if (typeof value !== "string" || hasControl(value)) return false;
      for (var index = 0; index < field.options.length; index++) {
        if (field.options[index].value === value) return true;
      }
      return false;
    }
    return false;
  }

  function normalizeField(input) {
    if (!input || typeof input !== "object" || !idValid(input.id) || fields.has(input.id)) return null;
    var kind = String(input.kind || "");
    if (!KINDS[kind]) return null;
    if (typeof input.get !== "function") return null;
    var readOnly = kind.indexOf("readOnly") === 0 || input.isReadOnly === true;
    var pushed = input.push === true;
    if (!readOnly && !pushed && typeof input.set !== "function") return null;
    var options = [];
    if (kind === "choice") {
      if (!Array.isArray(input.options) || !input.options.length || input.options.length > LIMITS.choices) return null;
      var seen = Object.create(null);
      for (var index = 0; index < input.options.length; index++) {
        var option = input.options[index];
        if (!option || !optionValid(option.value) || seen[option.value]) return null;
        seen[option.value] = 1;
        options.push({
          value: option.value,
          label: text(option.label || option.value, LIMITS.labelBytes),
          labelZhHans: text(option.labelZhHans || option.label || option.value, LIMITS.labelBytes)
        });
      }
    }
    var minimum = typeof input.minimum === "number" && isFinite(input.minimum) ? input.minimum : undefined;
    var maximum = typeof input.maximum === "number" && isFinite(input.maximum) ? input.maximum : undefined;
    if (minimum !== undefined && maximum !== undefined && minimum > maximum) return null;
    return {
      id: input.id,
      label: text(input.label || input.id, LIMITS.labelBytes),
      labelZhHans: text(input.labelZhHans || input.label || input.id, LIMITS.labelBytes),
      group: text(input.group || "general", LIMITS.labelBytes),
      groupZhHans: text(input.groupZhHans || input.group || "常规", LIMITS.labelBytes),
      kind: kind,
      symbol: input.symbol ? text(input.symbol, 64) : undefined,
      detail: input.detail ? text(input.detail, LIMITS.detailBytes) : undefined,
      detailZhHans: input.detailZhHans ? text(input.detailZhHans, LIMITS.detailBytes) : undefined,
      minimum: minimum,
      maximum: maximum,
      step: typeof input.step === "number" && isFinite(input.step) && input.step > 0 ? input.step : undefined,
      maximumLength: typeof input.maximumLength === "number" ? Math.max(1, Math.min(LIMITS.stringBytes, Math.floor(input.maximumLength))) : undefined,
      options: options,
      isReadOnly: readOnly,
      push: pushed,
      get: input.get,
      set: readOnly ? null : (pushed ? function () {} : input.set)
    };
  }

  function normalizeAction(input) {
    if (!input || typeof input !== "object" || !idValid(input.id) || actions.has(input.id)) return null;
    var pushed = input.push === true;
    if (!pushed && typeof input.invoke !== "function") return null;
    var role = input.role === "destructive" || input.role === "jump" ? input.role : "safe";
    var confirmation = input.confirmation === "required" ? "required" : "none";
    var parameters = [];
    var seen = Object.create(null);
    if (Array.isArray(input.parameters)) {
      if (input.parameters.length > LIMITS.parameters) return null;
      for (var index = 0; index < input.parameters.length; index++) {
        var parameter = input.parameters[index];
        if (!parameter || !idValid(parameter.id) || seen[parameter.id] || !KINDS[parameter.kind] ||
            parameter.kind.indexOf("readOnly") === 0) return null;
        seen[parameter.id] = 1;
        var options = [];
        if (parameter.kind === "choice") {
          if (!Array.isArray(parameter.options) || !parameter.options.length || parameter.options.length > LIMITS.choices) return null;
          var optionSeen = Object.create(null);
          for (var optionIndex = 0; optionIndex < parameter.options.length; optionIndex++) {
            var choice = parameter.options[optionIndex];
            if (!choice || !optionValid(choice.value) || optionSeen[choice.value]) return null;
            optionSeen[choice.value] = 1;
            options.push({
              value: choice.value,
              label: text(choice.label || choice.value, LIMITS.labelBytes),
              labelZhHans: text(choice.labelZhHans || choice.label || choice.value, LIMITS.labelBytes)
            });
          }
        }
        var minimum = typeof parameter.minimum === "number" && isFinite(parameter.minimum) ? parameter.minimum : undefined;
        var maximum = typeof parameter.maximum === "number" && isFinite(parameter.maximum) ? parameter.maximum : undefined;
        if (minimum !== undefined && maximum !== undefined && minimum > maximum) return null;
        parameters.push({
          id: parameter.id,
          label: text(parameter.label || parameter.id, LIMITS.labelBytes),
          labelZhHans: text(parameter.labelZhHans || parameter.label || parameter.id, LIMITS.labelBytes),
          kind: parameter.kind,
          detail: parameter.detail ? text(parameter.detail, LIMITS.detailBytes) : undefined,
          detailZhHans: parameter.detailZhHans ? text(parameter.detailZhHans, LIMITS.detailBytes) : undefined,
          minimum: minimum,
          maximum: maximum,
          step: typeof parameter.step === "number" && isFinite(parameter.step) && parameter.step > 0 ? parameter.step : undefined,
          maximumLength: typeof parameter.maximumLength === "number" ? Math.max(1, Math.min(LIMITS.stringBytes, Math.floor(parameter.maximumLength))) : undefined,
          options: options,
          isRequired: parameter.isRequired !== false,
          defaultValue: parameter.defaultValue
        });
      }
    }
    return {
      id: input.id,
      label: text(input.label || input.id, LIMITS.labelBytes),
      labelZhHans: text(input.labelZhHans || input.label || input.id, LIMITS.labelBytes),
      group: text(input.group || "actions", LIMITS.labelBytes),
      groupZhHans: text(input.groupZhHans || input.group || "动作", LIMITS.labelBytes),
      symbol: input.symbol ? text(input.symbol, 64) : undefined,
      detail: input.detail ? text(input.detail, LIMITS.detailBytes) : undefined,
      detailZhHans: input.detailZhHans ? text(input.detailZhHans, LIMITS.detailBytes) : undefined,
      role: role,
      confirmation: confirmation,
      parameters: parameters,
      isQuick: input.isQuick === true,
      push: pushed,
      invoke: pushed ? function () {} : input.invoke
    };
  }

  function addNotice(code, message, messageZhHans) {
    if (notices.length >= LIMITS.notices) return;
    for (var index = 0; index < notices.length; index++) {
      if (notices[index].code === code) return;
    }
    notices.push({
      code: idValid(code) ? code : "notice",
      message: text(message, LIMITS.detailBytes),
      messageZhHans: text(messageZhHans || message, LIMITS.detailBytes)
    });
    state.noticeRevision++;
  }

  function publicField(field) {
    return {
      id: field.id, label: field.label, labelZhHans: field.labelZhHans,
      group: field.group, groupZhHans: field.groupZhHans, kind: field.kind,
      symbol: field.symbol, detail: field.detail, detailZhHans: field.detailZhHans,
      minimum: field.minimum, maximum: field.maximum, step: field.step,
      maximumLength: field.maximumLength, options: field.options,
      isReadOnly: field.isReadOnly
    };
  }

  function publicAction(action) {
    return {
      id: action.id, label: action.label, labelZhHans: action.labelZhHans,
      group: action.group, groupZhHans: action.groupZhHans,
      symbol: action.symbol, detail: action.detail, detailZhHans: action.detailZhHans,
      role: action.role, confirmation: action.confirmation,
      parameters: action.parameters.map(function (parameter) {
        return {
          id: parameter.id, label: parameter.label, labelZhHans: parameter.labelZhHans,
          kind: parameter.kind, detail: parameter.detail, detailZhHans: parameter.detailZhHans,
          minimum: parameter.minimum, maximum: parameter.maximum, step: parameter.step,
          maximumLength: parameter.maximumLength, options: parameter.options,
          isRequired: parameter.isRequired, defaultValue: parameter.defaultValue
        };
      }),
      isQuick: action.isQuick
    };
  }

  function readField(field) {
    try {
      var raw = field.get();
      if (!valueValid(raw, field.kind, field)) {
        return { error: "The hook returned an invalid " + field.kind + " value." };
      }
      return { value: raw };
    } catch (error) {
      return { error: messageText(error && error.message ? error.message : error, LIMITS.detailBytes) };
    }
  }

  function readState() {
    var values = Object.create(null);
    var errors = Object.create(null);
    fields.forEach(function (field) {
      var result = readField(field);
      if (Object.prototype.hasOwnProperty.call(result, "value")) values[field.id] = result.value;
      else errors[field.id] = result.error;
    });
    return {
      revision: state.revision,
      capturedAt: Date.now(),
      values: values,
      fieldErrors: errors
    };
  }

  function sameValue(left, right) {
    return left === right || (typeof left === "number" && typeof right === "number" && Object.is(left, right));
  }

  function validateParameters(action, args) {
    var resolved = Object.create(null);
    var supplied = args && typeof args === "object" && !Array.isArray(args) ? args : {};
    var allowed = Object.create(null);
    for (var index = 0; index < action.parameters.length; index++) {
      var parameter = action.parameters[index];
      allowed[parameter.id] = 1;
      if (Object.prototype.hasOwnProperty.call(supplied, parameter.id)) {
        if (!valueValid(supplied[parameter.id], parameter.kind, parameter)) {
          throw new Error("Invalid parameter " + parameter.id);
        }
        resolved[parameter.id] = supplied[parameter.id];
      } else if (parameter.defaultValue !== undefined) {
        if (!valueValid(parameter.defaultValue, parameter.kind, parameter)) throw new Error("Invalid default " + parameter.id);
        resolved[parameter.id] = parameter.defaultValue;
      } else if (parameter.isRequired) {
        throw new Error("Missing parameter " + parameter.id);
      }
    }
    var keys = Object.keys(supplied);
    for (var keyIndex = 0; keyIndex < keys.length; keyIndex++) {
      if (!allowed[keys[keyIndex]]) throw new Error("Unknown parameter " + keys[keyIndex]);
    }
    return resolved;
  }

  function collectDiagnostics() {
    var canvasCount = 0;
    try { canvasCount = document.querySelectorAll("canvas").length; } catch (ignored) {}
    var visibility = "unknown";
    try { visibility = document.visibilityState || "unknown"; } catch (ignored) {}
    var readyState = "unknown";
    try { readyState = document.readyState || "unknown"; } catch (ignored) {}
    var width = 0, height = 0, ratio = 1;
    try {
      width = Number(window.innerWidth) || 0;
      height = Number(window.innerHeight) || 0;
      ratio = Number(window.devicePixelRatio) || 1;
    } catch (ignored) {}
    var details = {
      engine: state.engine,
      runtime: state.runtime || "unknown",
      fields: String(fields.size),
      actions: String(actions.size),
      url: (function () { try { return String(location.pathname || "").slice(0, 512); } catch (ignored) { return ""; } })()
    };
    var result = {
      fps: state.fps || undefined,
      frames: state.frameCount,
      viewportWidth: width,
      viewportHeight: height,
      visibility: visibility,
      canvases: canvasCount,
      title: (function () { try { return text(document.title || "", 256); } catch (ignored) { return ""; } })(),
      readyState: readyState,
      uptimeMilliseconds: Date.now() - state.installedAt,
      webAssembly: typeof WebAssembly === "object",
      devicePixelRatio: ratio,
      details: details
    };
    if (typeof hooks.diagnostics === "function") {
      try {
        var extra = hooks.diagnostics();
        if (extra && typeof extra === "object" && !Array.isArray(extra)) {
          Object.keys(extra).slice(0, 32).forEach(function (key) {
            if (key.length > 0 && key.length <= 128 && extra[key] != null) {
              result.details[key] = text(String(extra[key]), LIMITS.detailBytes);
            }
          });
        }
      } catch (error) {
        addNotice("diagnostics-hook", "The engine diagnostics hook failed.", "引擎诊断钩子失败。");
      }
    }
    return result;
  }

  function capabilitySnapshot() {
    var supportsSnapshot = typeof hooks.snapshot === "function" ||
      !!(window.FloeGame && typeof window.FloeGame.snapshot === "function");
    var supportsRestore = typeof hooks.restore === "function" ||
      !!(window.FloeGame && typeof window.FloeGame.restore === "function");
    return {
      protocolVersion: 1,
      bridgeVersion: "1.0.0",
      engine: state.engine,
      runtime: state.runtime || "unknown",
      supports: {
        liveState: fields.size > 0 || actions.size > 0,
        snapshot: supportsSnapshot,
        restore: supportsRestore,
        pause: typeof hooks.pause === "function",
        resume: typeof hooks.resume === "function",
        speed: typeof hooks.setSpeed === "function",
        reset: typeof hooks.reset === "function" ? "hook" : "reload",
        screenshot: true,
        fields: fields.size > 0,
        actions: actions.size > 0,
        projectRegistration: true
      },
      fields: Array.from(fields.values()).map(publicField),
      actions: Array.from(actions.values()).map(publicAction),
      notices: notices.slice(),
      diagnostics: collectDiagnostics()
    };
  }

  function scheduleReload() {
    setTimeout(function () {
      try { window.location.reload(); } catch (error) { addNotice("reload-failed", String(error), String(error)); }
    }, 60);
  }

  function snapshotEnvelope() {
    var gameState = null;
    if (typeof hooks.snapshot === "function") {
      gameState = hooks.snapshot();
    } else if (window.FloeGame && typeof window.FloeGame.snapshot === "function") {
      gameState = window.FloeGame.snapshot();
    } else {
      throw new Error("This engine has no complete snapshot hook.");
    }
    if (!gameState || typeof gameState !== "object" || Array.isArray(gameState)) {
      throw new Error("The engine snapshot is not an object.");
    }
    var envelope = {
      format: "floe-developer-snapshot",
      version: 1,
      engine: state.engine,
      capturedAt: Date.now(),
      state: gameState
    };
    var bytes = JSON.stringify(envelope);
    if (byteLength(bytes) > LIMITS.snapshotBytes) throw new Error("The snapshot exceeds the byte limit.");
    return envelope;
  }

  function restoreEnvelope(payload) {
    var envelope = payload && payload.snapshot;
    if (!envelope || typeof envelope !== "object" || Array.isArray(envelope) ||
        envelope.format !== "floe-developer-snapshot" || envelope.version !== 1 ||
        envelope.engine !== state.engine || !envelope.state ||
        typeof envelope.state !== "object" || Array.isArray(envelope.state)) {
      throw new Error("The snapshot does not belong to this engine.");
    }
    var restored = false;
    if (typeof hooks.restore === "function") {
      restored = hooks.restore(envelope.state);
    } else if (window.FloeGame && typeof window.FloeGame.restore === "function") {
      restored = window.FloeGame.restore(envelope.state);
    } else {
      throw new Error("This engine has no restore hook.");
    }
    if (restored === false) throw new Error("The engine refused the restore.");
    state.revision++;
    return { restored: true, state: readState() };
  }


  function queueCommand(command) {
    if (pushState.commands.length + Object.keys(pushState.pending).length >= 32) {
      return Promise.reject(new Error("Too many development commands are waiting for the game."));
    }
    var id = pushState.nextCommand++;
    var wire = {};
    Object.keys(command).forEach(function (key) { wire[key] = command[key]; });
    wire.id = id;
    return new Promise(function (resolve, reject) {
      var timer = setTimeout(function () {
        if (!pushState.pending[id]) return;
        delete pushState.pending[id];
        reject(new Error("The game did not acknowledge the development command."));
      }, 2500);
      pushState.pending[id] = { resolve: resolve, reject: reject, timer: timer };
      pushState.commands.push(wire);
    });
  }

  function waitForPushValue(id, value, timeoutMilliseconds) {
    return new Promise(function (resolve) {
      var started = Date.now();
      function check() {
        if (sameValue(pushState.values[id], value)) { resolve(true); return; }
        if (Date.now() - started >= timeoutMilliseconds) { resolve(false); return; }
        setTimeout(check, 20);
      }
      check();
    });
  }

  function registerPushed(descriptor) {
    if (!descriptor || typeof descriptor !== "object" || state.detached) return false;
    var pushedFields = [];
    if (Array.isArray(descriptor.fields)) {
      descriptor.fields.forEach(function (input) {
        if (!input || typeof input !== "object" || !idValid(input.id)) return;
        var copy = {};
        Object.keys(input).forEach(function (key) { if (key !== "get" && key !== "set") copy[key] = input[key]; });
        copy.push = true;
        copy.get = function () { return pushState.values[input.id]; };
        if (input.kind !== "readOnlyText" && input.kind !== "readOnlyNumber" &&
            input.kind !== "readOnlyBoolean" && input.isReadOnly !== true) {
          copy.set = function () {};
        }
        pushedFields.push(copy);
      });
    }
    var pushedActions = [];
    if (Array.isArray(descriptor.actions)) {
      descriptor.actions.forEach(function (input) {
        if (!input || typeof input !== "object" || !idValid(input.id)) return;
        var copy = {};
        Object.keys(input).forEach(function (key) { if (key !== "invoke") copy[key] = input[key]; });
        copy.push = true;
        copy.invoke = function () {};
        pushedActions.push(copy);
      });
    }
    return api.register({ runtime: descriptor.runtime, fields: pushedFields, actions: pushedActions,
                          notices: descriptor.notices, notice: descriptor.notice });
  }

  function updatePushed(values) {
    if (!values || typeof values !== "object" || Array.isArray(values)) return false;
    var applied = 0;
    Object.keys(values).forEach(function (id) {
      var field = fields.get(id);
      if (!field) return;
      var value = values[id];
      if (!valueValid(value, field.kind, field)) return;
      pushState.values[id] = value;
      applied++;
    });
    if (applied) pushState.revision++;
    return applied > 0;
  }

  function takeCommands() {
    return pushState.commands.splice(0, pushState.commands.length);
  }

  function ackCommand(id, result) {
    var pending = pushState.pending[id];
    if (!pending) return false;
    delete pushState.pending[id];
    clearTimeout(pending.timer);
    if (result && result.ok === false) {
      pending.reject(new Error(messageText(result.message || "The game rejected the development command.", LIMITS.detailBytes)));
    } else {
      pending.resolve(result && typeof result === "object" ? result : { ok: true });
    }
    return true;
  }

  var scalarFallbackPrefixes = Object.create(null);
  var PROTECTED_SNAPSHOT_KEYS = {
    engine: 1, engineVersion: 1, version: 1, runtime: 1, format: 1,
    savedAt: 1, timestamp: 1, project: 1, projectID: 1, build: 1,
    buildID: 1, saveVersion: 1, schemaVersion: 1, id: 1, uuid: 1
  };
  var READ_ONLY_SNAPSHOT_KEYS = {
    frames: 1, frame: 1, fps: 1, time: 1, elapsed: 1, playtime: 1,
    timestamp: 1, savedAt: 1
  };

  function registerScalarSnapshotFallback(prefix) {
    prefix = typeof prefix === "string" && /^[a-z][A-Za-z0-9]{0,31}$/.test(prefix) ? prefix : "snapshot";
    if (scalarFallbackPrefixes[prefix]) return false;
    if (!window.FloeGame || typeof window.FloeGame.snapshot !== "function" ||
        typeof window.FloeGame.restore !== "function") return false;
    var snapshot;
    try { snapshot = window.FloeGame.snapshot(); }
    catch (error) { return false; }
    if (!snapshot || typeof snapshot !== "object" || Array.isArray(snapshot)) return false;
    scalarFallbackPrefixes[prefix] = true;
    var fields = [];
    Object.keys(snapshot).sort().slice(0, 24).forEach(function (key) {
      if (!/^[A-Za-z][A-Za-z0-9_.-]{0,63}$/.test(key) || PROTECTED_SNAPSHOT_KEYS[key]) return;
      var value = snapshot[key];
      var kind;
      if (typeof value === "boolean") kind = "boolean";
      else if (typeof value === "number" && isFinite(value) && Math.abs(value) <= 1000000000000) kind = Math.floor(value) === value ? "integer" : "number";
      else if (typeof value === "string" && value.length <= 256) kind = "text";
      else return;
      var idKey = key.replace(/[^A-Za-z0-9]/g, "");
      if (!idKey) return;
      var fieldID = prefix + "." + idKey;
      if (READ_ONLY_SNAPSHOT_KEYS[key]) {
        kind = kind === "integer" || kind === "number" ? "readOnlyNumber" : (kind === "boolean" ? "readOnlyBoolean" : "readOnlyText");
      }
      var human = key.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/[_-]+/g, " ");
      var descriptor = {
        id: fieldID,
        label: human,
        labelZhHans: human,
        group: "Snapshot",
        groupZhHans: "快照",
        kind: kind,
        symbol: "camera.metering.matrix",
        get: function () {
          var next = window.FloeGame.snapshot();
          return next ? next[key] : undefined;
        }
      };
      if (kind.indexOf("readOnly") !== 0) {
        descriptor.set = function (nextValue) {
          var current = window.FloeGame.snapshot();
          if (!current || typeof current !== "object") throw new Error("The game has no snapshot state.");
          var merged = {};
          Object.keys(current).forEach(function (name) { merged[name] = current[name]; });
          merged[key] = nextValue;
          if (window.FloeGame.restore(merged) === false) throw new Error("The game refused the snapshot restore.");
        };
      }
      fields.push(descriptor);
    });
    if (!fields.length) return false;
    return api.register({ fields: fields, notice: {
      code: "scalar-snapshot-fallback",
      message: "This imported game exposes only a scalar snapshot/restore protocol; writable fields use that bounded game API.",
      messageZhHans: "此导入游戏只提供标量快照/恢复协议；可写字段使用该有界游戏 API。"
    }});
  }

  async function writeOutcome(payload) {
    if (!payload || !Array.isArray(payload.changes) || payload.changes.length === 0 ||
        payload.changes.length > LIMITS.changes) {
      throw new Error("Invalid field change list.");
    }
    var applied = [];
    var rejected = [];
    for (var index = 0; index < payload.changes.length; index++) {
      var change = payload.changes[index];
      if (!change || typeof change !== "object" || !idValid(change.id)) {
        rejected.push({ id: change && typeof change.id === "string" ? change.id : "unknown", reason: "Invalid field id." });
        continue;
      }
      var field = fields.get(change.id);
      if (!field) { rejected.push({ id: change.id, reason: "Unknown field." }); continue; }
      if (field.isReadOnly || !field.set) { rejected.push({ id: change.id, reason: "Field is read-only." }); continue; }
      if (!valueValid(change.value, field.kind, field)) {
        rejected.push({ id: change.id, reason: "Value does not match the field type." }); continue;
      }
      try {
        if (field.push) {
          var ack = await queueCommand({ kind: "set", field: change.id, value: change.value });
          if (!ack || ack.ok === false) {
            rejected.push({ id: change.id, reason: messageText((ack && ack.message) || "The game rejected the field update.", LIMITS.detailBytes) });
            continue;
          }
          var kept = await waitForPushValue(change.id, change.value, 800);
          if (!kept) {
            rejected.push({ id: change.id, reason: "The game did not publish the new value." });
            continue;
          }
        } else {
          field.set(change.value);
        }
        var after = readField(field);
        if (!Object.prototype.hasOwnProperty.call(after, "value") || !sameValue(after.value, change.value)) {
          rejected.push({ id: change.id, reason: after.error || "The engine did not keep the new value." });
        } else {
          applied.push(change.id);
        }
      } catch (error) {
        rejected.push({ id: change.id, reason: messageText(error && error.message ? error.message : error, LIMITS.detailBytes) });
      }
    }
    if (applied.length) state.revision++;
    var status = rejected.length ? "rejected" : "applied";
    var message = rejected.length
      ? "Applied " + applied.length + " field(s); rejected " + rejected.length + "."
      : "Applied " + applied.length + " field(s).";
    var messageZh = rejected.length
      ? "已修改 " + applied.length + " 个字段，拒绝 " + rejected.length + " 个。"
      : "已修改 " + applied.length + " 个字段。";
    return {
      actionID: "fields.write",
      status: status,
      message: message,
      messageZhHans: messageZh,
      changedFieldIDs: applied,
      state: readState(),
      rejected: rejected
    };
  }

  async function invokeOutcome(payload) {
    if (!payload || !idValid(payload.id)) throw new Error("Invalid action id.");
    var action = actions.get(payload.id);
    if (!action) throw new Error("Unknown action.");
    var resolved = validateParameters(action, payload.arguments);
    var before = readState();
    var result;
    try {
      if (action.push) {
        result = await queueCommand({ kind: "action", action: payload.id, arguments: resolved });
      } else {
        result = await action.invoke(resolved);
      }
    } catch (error) {
      return {
        id: payload.id, actionID: payload.id, status: "rejected",
        message: messageText(error && error.message ? error.message : error, LIMITS.detailBytes),
        messageZhHans: messageText(error && error.message ? error.message : error, LIMITS.detailBytes),
        changedFieldIDs: [], state: readState()
      };
    }
    var after = readState();
    var changed = [];
    fields.forEach(function (field, id) {
      var left = Object.prototype.hasOwnProperty.call(before.values, id) ? before.values[id] : undefined;
      var right = Object.prototype.hasOwnProperty.call(after.values, id) ? after.values[id] : undefined;
      if (!sameValue(left, right)) changed.push(id);
    });
    state.revision++;
    var message = result && typeof result === "object" ? (result.message || "Action applied.") : (result || "Action applied.");
    var messageZh = result && typeof result === "object" ? (result.messageZhHans || message) : message;
    var status = result && typeof result === "object" && result.status ? String(result.status) : "applied";
    if (status !== "applied" && status !== "reloading" && status !== "rejected" && status !== "unsupported") status = "applied";
    history.push({ action: payload.id, status: status, message: messageText(message, LIMITS.detailBytes), at: Date.now() });
    if (history.length > LIMITS.history) history.splice(0, history.length - LIMITS.history);
    if (status === "reloading") scheduleReload();
    return {
      actionID: payload.id, status: status,
      message: messageText(message, LIMITS.detailBytes),
      messageZhHans: messageText(messageZh, LIMITS.detailBytes),
      changedFieldIDs: changed, state: after
    };
  }

  function resetOutcome(payload) {
    var mode = payload && typeof payload.mode === "string" ? payload.mode : "reload";
    if (mode !== "reload" && mode !== "restart" && mode !== "hook") throw new Error("Invalid reset mode.");
    if (typeof hooks.reset === "function") {
      var result = hooks.reset(mode);
      if (result === false) throw new Error("The engine refused the reset.");
      return { status: "applied", message: "The engine reset hook completed.", messageZhHans: "引擎重置钩子已完成。" };
    }
    scheduleReload();
    return {
      status: "reloading",
      message: "The game is reloading from its boot state.",
      messageZhHans: "游戏正在从启动状态重新加载。"
    };
  }

  async function exchange(operation, payload) {
    if (!state.active || state.detached) throw new Error("The development helper is detached.");
    if (typeof operation !== "string") throw new Error("Invalid operation.");
    var requestText = JSON.stringify(payload === undefined ? {} : payload);
    if (byteLength(requestText) > LIMITS.requestBytes) throw new Error("The request exceeds the byte limit.");
    var value;
    switch (operation) {
      case "probe": value = capabilitySnapshot(); break;
      case "read": value = readState(); break;
      case "diagnostics": value = collectDiagnostics(); break;
      case "write": value = await writeOutcome(payload); break;
      case "invoke": value = await invokeOutcome(payload); break;
      case "snapshot": value = { snapshot: snapshotEnvelope() }; break;
      case "restore": value = restoreEnvelope(payload); break;
      case "reset": value = resetOutcome(payload); break;
      case "detach":
        state.detached = true;
        value = { detached: true };
        break;
      default: throw new Error("Unsupported operation.");
    }
    var responseText = JSON.stringify(value);
    if (byteLength(responseText) > LIMITS.responseBytes) throw new Error("The response exceeds the byte limit.");
    return value;
  }

  var api = {
    __floe: 1,
    version: "1.0.0",
    token: state.token,
    engine: state.engine,
    register: function (descriptor) {
      if (!descriptor || typeof descriptor !== "object" || state.detached) return false;
      var accepted = 0;
      if (descriptor.runtime) state.runtime = text(descriptor.runtime, 256);
      if (descriptor.notice && descriptor.notice.code) {
        addNotice(descriptor.notice.code, descriptor.notice.message, descriptor.notice.messageZhHans);
      }
      if (Array.isArray(descriptor.notices)) {
        descriptor.notices.forEach(function (notice) {
          if (notice && notice.code) addNotice(notice.code, notice.message, notice.messageZhHans);
        });
      }
      if (descriptor.snapshot) hooks.snapshot = descriptor.snapshot;
      if (descriptor.restore) hooks.restore = descriptor.restore;
      if (descriptor.reset) hooks.reset = descriptor.reset;
      if (descriptor.diagnostics) hooks.diagnostics = descriptor.diagnostics;
      if (descriptor.pause) hooks.pause = descriptor.pause;
      if (descriptor.resume) hooks.resume = descriptor.resume;
      if (descriptor.setSpeed) hooks.setSpeed = descriptor.setSpeed;
      if (Array.isArray(descriptor.fields)) {
        for (var index = 0; index < descriptor.fields.length && fields.size < LIMITS.fields; index++) {
          var field = normalizeField(descriptor.fields[index]);
          if (!field) {
            addNotice("field-rejected", "A field was rejected by the development bridge.", "开发桥拒绝了某个字段。");
            continue;
          }
          fields.set(field.id, field);
          accepted++;
        }
      }
      if (Array.isArray(descriptor.actions)) {
        for (var actionIndex = 0; actionIndex < descriptor.actions.length && actions.size < LIMITS.actions; actionIndex++) {
          var action = normalizeAction(descriptor.actions[actionIndex]);
          if (!action) {
            addNotice("action-rejected", "An action was rejected by the development bridge.", "开发桥拒绝了某个动作。");
            continue;
          }
          actions.set(action.id, action);
          accepted++;
        }
      }
      state.revision++;
      return accepted > 0 || !!(descriptor.snapshot || descriptor.restore || descriptor.reset);
    },
    setRuntime: function (name) { state.runtime = text(name, 256); },
    notice: function (code, message, messageZhHans) { addNotice(code, message, messageZhHans); },
    registerPushed: registerPushed,
    registerScalarSnapshotFallback: registerScalarSnapshotFallback,
    updatePushed: updatePushed,
    takeCommands: takeCommands,
    ackCommand: ackCommand,
    __exchange: exchange,
    __detach: function () { state.detached = true; state.active = false; },
    __rebind: function (next) {
      if (!next || typeof next !== "object") return false;
      if (typeof next.token === "string" && next.token) state.token = next.token;
      if (typeof next.engine === "string" && next.engine) state.engine = next.engine;
      state.detached = false;
      state.active = true;
      return true;
    },
    __debugState: function () {
      return { fields: Array.from(fields.keys()), actions: Array.from(actions.keys()), notices: notices.slice(), history: history.slice(), revision: state.revision, pushed: pushState.revision, pendingCommands: pushState.commands.length };
    }
  };
  Object.freeze(api);
  try {
    Object.defineProperty(window, "FloeDeveloper", { value: api, writable: false, configurable: false });
  } catch (ignored) {
    window.FloeDeveloper = api;
  }

  if (typeof window.requestAnimationFrame === "function") {
    var frame = function (time) {
      state.frameCount++;
      if (state.lastFrameAt && time > state.lastFrameAt) {
        var delta = time - state.lastFrameAt;
        var current = 1000 / Math.max(delta, 1);
        state.fps = state.fps ? (state.fps * 0.85 + current * 0.15) : current;
      }
      state.lastFrameAt = time;
      if (!state.detached) window.requestAnimationFrame(frame);
    };
    try { window.requestAnimationFrame(frame); } catch (ignored) {}
  }

  // Universal project/page inspector. Engine hooks add the game-specific
  // fields; these entries are always real browser facts.
  api.register({
    runtime: "browser",
    fields: [
      { id: "page.title", label: "Page title", labelZhHans: "页面标题", group: "page", groupZhHans: "页面", kind: "readOnlyText", symbol: "doc.text", get: function () { return text(document.title || "", 256); } },
      { id: "page.viewport", label: "Viewport", labelZhHans: "视口", group: "page", groupZhHans: "页面", kind: "readOnlyText", symbol: "rectangle", get: function () { return String(window.innerWidth || 0) + " × " + String(window.innerHeight || 0); } },
      { id: "page.visibility", label: "Visibility", labelZhHans: "可见性", group: "page", groupZhHans: "页面", kind: "readOnlyText", get: function () { return document.visibilityState || "unknown"; } },
      { id: "page.readyState", label: "Document state", labelZhHans: "文档状态", group: "page", groupZhHans: "页面", kind: "readOnlyText", get: function () { return document.readyState || "unknown"; } },
      { id: "page.canvases", label: "Canvas count", labelZhHans: "画布数量", group: "page", groupZhHans: "页面", kind: "readOnlyNumber", get: function () { return document.querySelectorAll("canvas").length; } },
      { id: "page.webAssembly", label: "WebAssembly", labelZhHans: "WebAssembly", group: "page", groupZhHans: "页面", kind: "readOnlyBoolean", get: function () { return typeof WebAssembly === "object"; } },
      { id: "runtime.fps", label: "Page FPS", labelZhHans: "页面 FPS", group: "runtime", groupZhHans: "运行时", kind: "readOnlyNumber", get: function () { return Math.round((state.fps || 0) * 10) / 10; } },
      { id: "runtime.frames", label: "Page frames", labelZhHans: "页面帧数", group: "runtime", groupZhHans: "运行时", kind: "readOnlyNumber", get: function () { return state.frameCount; } },
      { id: "runtime.uptime", label: "Bridge uptime", labelZhHans: "桥运行时长", group: "runtime", groupZhHans: "运行时", kind: "readOnlyNumber", get: function () { return Math.round((Date.now() - state.installedAt) / 1000); } }
    ],
    actions: [
      { id: "page.reload", label: "Reload game", labelZhHans: "重新加载游戏", group: "page", groupZhHans: "页面", symbol: "arrow.clockwise", detail: "Reloads the current artifact into its boot state. Progress not saved by the game is lost.", detailZhHans: "将当前产物重新加载到启动状态；游戏未保存的进度会丢失。", role: "destructive", confirmation: "required", invoke: function () { scheduleReload(); return { status: "reloading", message: "The game is reloading.", messageZhHans: "游戏正在重新加载。" }; } }
    ]
  });
})();
