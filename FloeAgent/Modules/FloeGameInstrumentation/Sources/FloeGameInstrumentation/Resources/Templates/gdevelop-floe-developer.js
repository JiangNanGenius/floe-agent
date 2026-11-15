/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Floe GDevelop export bridge 1.0.0.
 *
 * This file is part of the PRIVATE Floe playable copy of an official GDJS Web
 * export. The reviewed exporter stamps these exact bytes into the exported
 * directory and loads the file from index.html. It is never added to a user's
 * project or to an ordinary public build by a project edit.
 *
 * Host gate: the file returns before registering callbacks, creating objects or
 * starting a timer unless the compiled Floe host already injected
 * window.FloeDeveloper. A normal exported game therefore has no menu, HUD,
 * polling loop or command surface. No native API, network API or evaluator is
 * exposed to game data.
 *
 * The bridge binds only public GDJS runtime objects:
 *   gdjs.callbacksRuntimeSceneLoaded (captured scene)
 *   RuntimeScene.getName/getVariables/getObjects/getTimeManager/getGame
 *   RuntimeGame.pause/isPaused
 *   RuntimeScene.renderAndStep (single-frame step while paused)
 *   TimeManager.getTimeScale/setTimeScale/getTimeFromStart
 *   Variable getType/getValue/setNumber/setString/setBoolean
 *   RuntimeObject getX/getY/setX/setY/setPosition
 */
(function () {
  "use strict";

  var host = window.FloeDeveloper;
  if (!host ||
      typeof host.registerPushed !== "function" ||
      typeof host.updatePushed !== "function" ||
      typeof host.takeCommands !== "function" ||
      typeof host.ackCommand !== "function") {
    return;
  }
  if (window.__floeGDevelopBridge) return;
  if (typeof window.gdjs === "undefined" || !window.gdjs) return;

  var VERSION = "1.0.0";
  var MAX_VARIABLE_FIELDS = 120;
  var MAX_OBJECT_FIELDS = 96;
  var MAX_TEXT_BYTES = 4096;
  var CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g;
  var usedIDs = Object.create(null);
  var variableFields = Object.create(null);
  var objectFields = Object.create(null);
  var currentScene = null;
  var timer = null;
  var detached = false;
  var registered = false;

  function slug(value, fallback) {
    var text = String(value == null ? "" : value).toLowerCase()
      .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
    if (!text) text = fallback;
    if (!/^[a-z]/.test(text)) text = "v-" + text;
    return text.slice(0, 40) || fallback;
  }

  function uniqueID(prefix, name, fallback) {
    var base = prefix + slug(name, fallback);
    var value = base;
    var index = 2;
    while (usedIDs[value]) { value = base + "-" + index; index += 1; }
    usedIDs[value] = true;
    return value;
  }

  function cleanText(value) {
    var text = typeof value === "string" ? value : String(value == null ? "" : value);
    text = text.replace(CONTROL, " ");
    if (text.length > MAX_TEXT_BYTES) text = text.slice(0, MAX_TEXT_BYTES);
    return text;
  }

  function finite(value) {
    return typeof value === "number" && isFinite(value);
  }

  function projectData() {
    try { return window.gdjs.projectData || null; } catch (error) { return null; }
  }

  function sceneLayout(name) {
    var data = projectData();
    if (!data || !Array.isArray(data.layouts)) return null;
    for (var index = 0; index < data.layouts.length; index += 1) {
      if (data.layouts[index] && data.layouts[index].name === name) return data.layouts[index];
    }
    return null;
  }

  function firstLayout() {
    var data = projectData();
    if (!data || !Array.isArray(data.layouts) || data.layouts.length === 0) return null;
    for (var index = 0; index < data.layouts.length; index += 1) {
      if (data.layouts[index] && data.layouts[index].name === data.firstLayout) return data.layouts[index];
    }
    return data.layouts[0] || null;
  }

  function declaredKind(type) {
    if (type === "string") return "text";
    if (type === "boolean") return "boolean";
    return "number";
  }

  function primitive(variable) {
    if (!variable || typeof variable.name !== "string" || !variable.name) return false;
    var type = variable.type || "number";
    return type === "number" || type === "string" || type === "boolean";
  }

  function registerVariable(scope, name, type, prefix) {
    var id = uniqueID(prefix, name, "variable");
    var kind = declaredKind(type);
    var descriptor = {
      id: id,
      label: (scope === "game" ? "Global " : "Scene ") + name,
      labelZhHans: (scope === "game" ? "全局 " : "场景 ") + name,
      group: "GDevelop variables",
      groupZhHans: "GDevelop 变量",
      kind: kind,
      symbol: "curlybraces"
    };
    if (kind === "text") descriptor.maximumLength = MAX_TEXT_BYTES;
    if (kind === "number") { descriptor.minimum = -1000000000000; descriptor.maximum = 1000000000000; }
    variableFields[id] = { scope: scope, name: name, kind: kind };
    return descriptor;
  }

  function registerObject(name, index) {
    var xID = uniqueID("object.", name + "-x", "object-" + index + "-x");
    var yID = uniqueID("object.", name + "-y", "object-" + index + "-y");
    objectFields[xID] = { name: name, axis: "x" };
    objectFields[yID] = { name: name, axis: "y" };
    return [
      { id: xID, label: name + " X", labelZhHans: name + " X", group: "GDevelop positions", groupZhHans: "GDevelop 位置", kind: "number", symbol: "arrow.left.and.right", minimum: -1000000, maximum: 1000000 },
      { id: yID, label: name + " Y", labelZhHans: name + " Y", group: "GDevelop positions", groupZhHans: "GDevelop 位置", kind: "number", symbol: "arrow.up.and.down", minimum: -1000000, maximum: 1000000 }
    ];
  }

  function buildDescriptors() {
    var fields = [
      { id: "scene.name", label: "Scene", labelZhHans: "场景", group: "GDevelop", groupZhHans: "GDevelop", kind: "readOnlyText", symbol: "square.stack" },
      { id: "scene.timescale", label: "Time scale", labelZhHans: "时间缩放", group: "GDevelop", groupZhHans: "GDevelop", kind: "number", symbol: "gauge.with.dots.needle.67percent", minimum: 0, maximum: 4, step: 0.05 },
      { id: "scene.elapsed", label: "Elapsed", labelZhHans: "已运行", group: "GDevelop", groupZhHans: "GDevelop", kind: "readOnlyNumber", symbol: "clock" },
      { id: "engine.paused", label: "Paused", labelZhHans: "已暂停", group: "GDevelop", groupZhHans: "GDevelop", kind: "readOnlyBoolean", symbol: "pause" }
    ];
    usedIDs["scene.name"] = true;
    usedIDs["scene.timescale"] = true;
    usedIDs["scene.elapsed"] = true;
    usedIDs["engine.paused"] = true;
    var data = projectData();
    if (data) {
      var globals = Array.isArray(data.variables) ? data.variables : [];
      for (var index = 0; index < globals.length && Object.keys(variableFields).length < MAX_VARIABLE_FIELDS; index += 1) {
        if (!primitive(globals[index])) continue;
        fields.push(registerVariable("game", globals[index].name, globals[index].type, "var.g."));
      }
      var layouts = Array.isArray(data.layouts) ? data.layouts : [];
      var seen = Object.create(null);
      for (var layoutIndex = 0; layoutIndex < layouts.length && Object.keys(variableFields).length < MAX_VARIABLE_FIELDS; layoutIndex += 1) {
        var variables = layouts[layoutIndex] && Array.isArray(layouts[layoutIndex].variables) ? layouts[layoutIndex].variables : [];
        for (var variableIndex = 0; variableIndex < variables.length && Object.keys(variableFields).length < MAX_VARIABLE_FIELDS; variableIndex += 1) {
          var variable = variables[variableIndex];
          if (!primitive(variable) || seen[variable.name]) continue;
          seen[variable.name] = true;
          fields.push(registerVariable("scene", variable.name, variable.type, "var.s."));
        }
      }
    }
    var first = firstLayout();
    var objects = first && Array.isArray(first.objects) ? first.objects : [];
    var objectCount = 0;
    for (var objectIndex = 0; objectIndex < objects.length; objectIndex += 1) {
      var object = objects[objectIndex];
      if (!object || typeof object.name !== "string" || !object.name) continue;
      if (Object.keys(objectFields).length >= MAX_OBJECT_FIELDS) break;
      Array.prototype.push.apply(fields, registerObject(object.name, objectCount));
      objectCount += 1;
    }
    var actions = [
      { id: "engine.pause", label: "Pause", labelZhHans: "暂停", group: "GDevelop", groupZhHans: "GDevelop", symbol: "pause.fill", isQuick: true },
      { id: "engine.resume", label: "Resume", labelZhHans: "继续", group: "GDevelop", groupZhHans: "GDevelop", symbol: "play.fill", isQuick: true },
      { id: "engine.step", label: "Step frame", labelZhHans: "单步一帧", group: "GDevelop", groupZhHans: "GDevelop", symbol: "forward.frame.fill", parameters: [
        { id: "frames", label: "Frames", labelZhHans: "帧数", kind: "integer", minimum: 1, maximum: 10, isRequired: true, defaultValue: 1 }
      ] },
      { id: "engine.setSpeed", label: "Set speed", labelZhHans: "设置速度", group: "GDevelop", groupZhHans: "GDevelop", symbol: "speedometer", parameters: [
        { id: "speed", label: "Speed", labelZhHans: "速度", kind: "number", minimum: 0, maximum: 4, step: 0.05, isRequired: true, defaultValue: 1 }
      ] },
      { id: "object.setPosition", label: "Move object", labelZhHans: "移动对象", group: "GDevelop positions", groupZhHans: "GDevelop 位置", symbol: "move.3d", parameters: [
        { id: "object", label: "Object", labelZhHans: "对象", kind: "text", maximumLength: 128, isRequired: true },
        { id: "x", label: "X", labelZhHans: "X", kind: "number", minimum: -1000000, maximum: 1000000, isRequired: true },
        { id: "y", label: "Y", labelZhHans: "Y", kind: "number", minimum: -1000000, maximum: 1000000, isRequired: true }
      ] },
      { id: "variable.set", label: "Set variable", labelZhHans: "设置变量", group: "GDevelop variables", groupZhHans: "GDevelop 变量", symbol: "curlybraces", parameters: [
        { id: "scope", label: "Scope", labelZhHans: "作用域", kind: "choice", isRequired: true, defaultValue: "scene", options: [ { value: "scene", label: "Scene", labelZhHans: "场景" }, { value: "game", label: "Global", labelZhHans: "全局" } ] },
        { id: "name", label: "Name", labelZhHans: "名称", kind: "text", maximumLength: 128, isRequired: true },
        { id: "value", label: "Value", labelZhHans: "值", kind: "text", maximumLength: MAX_TEXT_BYTES, isRequired: true },
        { id: "type", label: "Type", labelZhHans: "类型", kind: "choice", defaultValue: "auto", options: [ { value: "auto", label: "Keep type", labelZhHans: "保持类型" }, { value: "number", label: "Number", labelZhHans: "数字" }, { value: "string", label: "Text", labelZhHans: "文本" }, { value: "boolean", label: "Boolean", labelZhHans: "布尔" } ] }
      ] }
    ];
    return { fields: fields, actions: actions };
  }

  function stop() {
    detached = true;
    if (timer !== null) { clearInterval(timer); timer = null; }
    try { host.setRuntime && host.setRuntime("GDevelop"); } catch (error) {}
  }

  function capture(scene) {
    if (detached) return;
    if (scene && typeof scene.getName === "function") currentScene = scene;
  }

  function installSceneCapture() {
    try {
      if (typeof window.gdjs.registerRuntimeSceneLoadedCallback === "function") {
        window.gdjs.registerRuntimeSceneLoadedCallback(capture);
        return true;
      }
      if (Array.isArray(window.gdjs.callbacksRuntimeSceneLoaded)) {
        window.gdjs.callbacksRuntimeSceneLoaded.push(capture);
        return true;
      }
    } catch (error) {}
    return false;
  }

  function game() {
    try { return currentScene && typeof currentScene.getGame === "function" ? currentScene.getGame() : null; }
    catch (error) { return null; }
  }

  function timeManager() {
    try { return currentScene && typeof currentScene.getTimeManager === "function" ? currentScene.getTimeManager() : null; }
    catch (error) { return null; }
  }

  function readVariable(scope, name) {
    var container = null;
    try {
      if (scope === "game") {
        var runtimeGame = game();
        container = runtimeGame && typeof runtimeGame.getVariables === "function" ? runtimeGame.getVariables() : null;
      } else {
        container = currentScene && typeof currentScene.getVariables === "function" ? currentScene.getVariables() : null;
      }
    } catch (error) { return null; }
    if (!container || typeof container.get !== "function") return null;
    try {
      var variable = container.get(name);
      return variable && typeof variable.getType === "function" ? variable : null;
    } catch (error) { return null; }
  }

  function variableValue(variable, kind) {
    try {
      var type = variable.getType();
      var value = variable.getValue();
      if (kind === "number") {
        if (type === "number" && finite(value)) return value;
        if (type === "boolean") return value ? 1 : 0;
        var parsed = Number(value);
        return finite(parsed) ? parsed : undefined;
      }
      if (kind === "text") return cleanText(value);
      if (kind === "boolean") {
        if (type === "boolean") return !!value;
        if (type === "number") return value !== 0;
        return String(value) === "true";
      }
    } catch (error) {}
    return undefined;
  }

  function setVariable(variable, kind, value) {
    if (!variable) return false;
    try {
      var type = typeof variable.getType === "function" ? variable.getType() : "number";
      if (type === "structure" || type === "array") return false;
      if (kind === "boolean") {
        variable.setBoolean(value === true || value === "true" || value === "1");
        return true;
      }
      if (kind === "text" || type === "string") {
        variable.setString(cleanText(value));
        return true;
      }
      var number = typeof value === "number" ? value : Number(value);
      if (!finite(number)) return false;
      variable.setNumber(number);
      return true;
    } catch (error) { return false; }
  }

  function objectInstance(name) {
    try {
      if (!currentScene || typeof currentScene.getObjects !== "function") return null;
      var list = currentScene.getObjects(String(name));
      return list && list.length > 0 ? list[0] : null;
    } catch (error) { return null; }
  }

  function readObject(name, axis) {
    var instance = objectInstance(name);
    if (!instance) return undefined;
    try {
      var value = axis === "x" ? instance.getX() : instance.getY();
      return finite(value) ? value : undefined;
    } catch (error) { return undefined; }
  }

  function writeObject(name, axis, value) {
    var instance = objectInstance(name);
    if (!instance || !finite(value)) return false;
    try {
      if (axis === "x") instance.setX(value); else instance.setY(value);
      return true;
    } catch (error) { return false; }
  }

  function moveObject(name, x, y) {
    var instance = objectInstance(name);
    if (!instance) return false;
    try {
      if (typeof instance.setPosition === "function") instance.setPosition(x, y);
      else { instance.setX(x); instance.setY(y); }
      return true;
    } catch (error) { return false; }
  }

  function applySet(command) {
    var field = command && command.field;
    if (typeof field !== "string") return { ok: false, message: "Invalid field." };
    if (field === "scene.timescale") {
      var manager = timeManager();
      try {
        if (!manager || typeof manager.setTimeScale !== "function") return { ok: false, message: "The GDevelop TimeManager is unavailable." };
        var scale = Number(command.value);
        if (!finite(scale) || scale < 0 || scale > 4) return { ok: false, message: "Time scale must be between 0 and 4." };
        manager.setTimeScale(scale);
        return { ok: true };
      } catch (error) { return { ok: false, message: String(error) }; }
    }
    var variable = variableFields[field];
    if (variable) {
      var target = readVariable(variable.scope, variable.name);
      if (!target) return { ok: false, message: "The variable is not available in the current scene." };
      return setVariable(target, variable.kind, command.value)
        ? { ok: true } : { ok: false, message: "The variable rejected this value." };
    }
    var object = objectFields[field];
    if (object) {
      return writeObject(object.name, object.axis, Number(command.value))
        ? { ok: true } : { ok: false, message: "The object is not available in the current scene." };
    }
    return { ok: false, message: "Unknown or read-only field." };
  }

  function newVariable(container, name, kind, value) {
    if (!container || typeof container.get !== "function") return false;
    var variable = container.get(name);
    if (!variable) return false;
    if (kind === "boolean") { variable.setBoolean(value === "true" || value === "1"); return true; }
    if (kind === "string") { variable.setString(cleanText(value)); return true; }
    if (kind === "number") {
      var number = Number(value);
      if (!finite(number)) return false;
      variable.setNumber(number);
      return true;
    }
    var type = typeof variable.getType === "function" ? variable.getType() : "number";
    if (type === "structure" || type === "array") return false;
    if (type === "boolean") { variable.setBoolean(value === "true" || value === "1"); return true; }
    if (type === "string") { variable.setString(cleanText(value)); return true; }
    var automatic = Number(value);
    if (finite(automatic) && String(value).trim() !== "") { variable.setNumber(automatic); return true; }
    variable.setString(cleanText(value));
    return true;
  }

  function applyAction(command) {
    var action = command && command.action;
    var args = command && command.arguments && typeof command.arguments === "object" ? command.arguments : {};
    try {
      if (action === "engine.pause") {
        var pausedGame = game();
        if (!pausedGame || typeof pausedGame.pause !== "function") return { ok: false, message: "The GDevelop RuntimeGame is unavailable." };
        pausedGame.pause(true);
        return { ok: true };
      }
      if (action === "engine.resume") {
        var resumedGame = game();
        if (!resumedGame || typeof resumedGame.pause !== "function") return { ok: false, message: "The GDevelop RuntimeGame is unavailable." };
        resumedGame.pause(false);
        return { ok: true };
      }
      if (action === "engine.setSpeed") {
        var manager = timeManager();
        var speed = Number(args.speed);
        if (!manager || typeof manager.setTimeScale !== "function") return { ok: false, message: "The GDevelop TimeManager is unavailable." };
        if (!finite(speed) || speed < 0 || speed > 4) return { ok: false, message: "Speed must be between 0 and 4." };
        manager.setTimeScale(speed);
        return { ok: true };
      }
      if (action === "engine.step") {
        var stepGame = game();
        if (!stepGame || typeof stepGame.isPaused !== "function" || !stepGame.isPaused()) {
          return { ok: false, message: "Pause the game before stepping a frame." };
        }
        if (!currentScene || typeof currentScene.renderAndStep !== "function") {
          return { ok: false, message: "The current GDevelop scene cannot be stepped." };
        }
        var frames = Math.max(1, Math.min(10, Math.floor(Number(args.frames) || 1)));
        for (var index = 0; index < frames; index += 1) currentScene.renderAndStep(1000 / 60);
        return { ok: true };
      }
      if (action === "object.setPosition") {
        var name = args.object;
        var x = Number(args.x);
        var y = Number(args.y);
        if (typeof name !== "string" || !name) return { ok: false, message: "Choose an object name." };
        if (!finite(x) || !finite(y)) return { ok: false, message: "Position must be finite numbers." };
        return moveObject(name, x, y)
          ? { ok: true } : { ok: false, message: "The object has no instance in the current scene." };
      }
      if (action === "variable.set") {
        var scope = args.scope === "game" ? "game" : "scene";
        var variableName = args.name;
        if (typeof variableName !== "string" || !variableName) return { ok: false, message: "Choose a variable name." };
        var container = null;
        if (scope === "game") {
          var runtimeGame = game();
          container = runtimeGame && typeof runtimeGame.getVariables === "function" ? runtimeGame.getVariables() : null;
        } else {
          container = currentScene && typeof currentScene.getVariables === "function" ? currentScene.getVariables() : null;
        }
        var kind = args.type === "number" || args.type === "string" || args.type === "boolean" ? args.type : "auto";
        return newVariable(container, variableName, kind, args.value)
          ? { ok: true } : { ok: false, message: "The variable container rejected this value." };
      }
    } catch (error) {
      return { ok: false, message: String(error) };
    }
    return { ok: false, message: "Unknown action." };
  }

  function publish() {
    if (detached) return;
    if (window.FloeDeveloper !== host) { stop(); return; }
    if (!currentScene) return;
    var values = {};
    try {
      values["scene.name"] = cleanText(currentScene.getName ? currentScene.getName() : "—");
      var manager = timeManager();
      if (manager) {
        if (typeof manager.getTimeScale === "function") values["scene.timescale"] = Number(manager.getTimeScale());
        if (typeof manager.getTimeFromStart === "function") values["scene.elapsed"] = Number(manager.getTimeFromStart()) / 1000;
      }
      var runtimeGame = game();
      values["engine.paused"] = !!(runtimeGame && typeof runtimeGame.isPaused === "function" && runtimeGame.isPaused());
    } catch (error) {}
    Object.keys(variableFields).forEach(function (id) {
      var variable = variableFields[id];
      var target = readVariable(variable.scope, variable.name);
      if (!target) return;
      var value = variableValue(target, variable.kind);
      if (value !== undefined) values[id] = value;
    });
    Object.keys(objectFields).forEach(function (id) {
      var object = objectFields[id];
      var value = readObject(object.name, object.axis);
      if (value !== undefined) values[id] = value;
    });
    try { host.updatePushed(values); } catch (error) { stop(); return; }
    var commands;
    try { commands = host.takeCommands(); } catch (error) { stop(); return; }
    if (!Array.isArray(commands)) return;
    commands.forEach(function (command) {
      var result;
      try {
        if (command && command.kind === "set") result = applySet(command);
        else if (command && command.kind === "action") result = applyAction(command);
        else result = { ok: false, message: "Unknown command." };
      } catch (error) { result = { ok: false, message: String(error) }; }
      try { host.ackCommand(command.id, result); } catch (error) { stop(); }
    });
  }

  if (!installSceneCapture()) return;
  var descriptors = buildDescriptors();
  try {
    var accepted = host.registerPushed({
      runtime: "GDevelop Web export",
      fields: descriptors.fields,
      actions: descriptors.actions
    });
    if (accepted === false) return;
  } catch (error) {
    return;
  }
  registered = true;
  window.__floeGDevelopBridge = { version: VERSION, installed: true };
  try { host.setRuntime && host.setRuntime("GDevelop"); } catch (error) {}
  timer = setInterval(publish, 100);
})();
