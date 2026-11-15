/* SPDX-License-Identifier: MPL-2.0 */
/*
 * FloeGameNarrativeKit Ink bridge (MPL-2.0).
 *
 * The original Ink source graph is loaded from game/ink-sources.json (user
 * content, not this file). The pinned inkjs 2.4.0 compiler/story runtime is
 * loaded from vendor/inkjs.js (MIT, unchanged). This bridge only compiles the
 * bounded source map through inkjs' fileHandler and exposes the typed
 * FloeGame contract.
 */
"use strict";

(function () {
  const Support = window.FloeSupport;
  if (!Support) {
    throw new Error("Floe support host did not load");
  }
  const host = Support.host;
  const textEl = document.getElementById("text");
  const choicesEl = document.getElementById("choices");
  let story = null;
  let choices = [];
  let selected = 0;
  let lastText = "";

  function log(error) { host.log(String(error)); }

  function esc(text) {
    return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;");
  }

  function resolveInkPath(name) {
    if (typeof name !== "string" || !name || name.length > 1024 ||
        /[\u0000-\u001f\u007f]/.test(name)) {
      throw new Error("invalid INCLUDE path");
    }
    const normalised = name.replace(/\\/g, "/");
    if (normalised.charAt(0) === "/" || /^[A-Za-z]:/.test(normalised)) {
      throw new Error("absolute INCLUDE path");
    }
    const parts = [];
    for (const part of normalised.split("/")) {
      if (!part || part === ".") continue;
      if (part === "..") {
        if (!parts.length) throw new Error("INCLUDE path escapes the project");
        parts.pop();
      } else {
        if (part.indexOf(":") >= 0) throw new Error("unsafe INCLUDE path");
        parts.push(part);
      }
    }
    if (!parts.length) throw new Error("empty INCLUDE path");
    return parts.join("/");
  }

  function render() {
    let out = "";
    try {
      while (story.canContinue) {
        const text = story.Continue();
        if (text && text.trim()) out += text;
      }
    } catch (error) {
      log(error);
    }
    if (out) lastText = (lastText ? lastText + "\n" : "") + out.trim();
    textEl.innerHTML = esc(lastText);
    choicesEl.innerHTML = "";
    choices = story.currentChoices || [];
    selected = Math.min(selected, Math.max(0, choices.length - 1));
    choices.forEach(function (choice, index) {
      const button = document.createElement("button");
      button.className = "choice" + (index === selected ? " sel" : "");
      button.textContent = choice.text;
      button.addEventListener("click", function () { choose(index); });
      choicesEl.appendChild(button);
    });
    const selectedElement = choicesEl.querySelector(".sel");
    if (selectedElement && typeof selectedElement.scrollIntoView === "function") {
      selectedElement.scrollIntoView({ block: "nearest" });
    }
  }

  function choose(index) {
    if (!story || !choices.length || index < 0 || index >= choices.length) return false;
    try {
      story.ChooseChoiceIndex(index);
      selected = 0;
      render();
      return true;
    } catch (error) {
      log(error);
      return false;
    }
  }

  function move(delta) {
    if (!choices.length) return false;
    selected = (selected + delta + choices.length) % choices.length;
    Array.prototype.forEach.call(choicesEl.children, function (element, index) {
      element.classList.toggle("sel", index === selected);
    });
    return true;
  }

  async function boot() {
    let sourceDocument;
    try {
      sourceDocument = await Support.fetchJSON("game/ink-sources.json");
    } catch (error) {
      Support.fail("Ink source data could not be loaded: " + error.message);
      return;
    }
    const sources = sourceDocument && sourceDocument.files;
    const entryName = sourceDocument && sourceDocument.entry;
    if (!sources || typeof sources !== "object" || typeof entryName !== "string" ||
        typeof sources[entryName] !== "string") {
      Support.fail("Embedded ink source map is incomplete");
      return;
    }
    const fileHandler = {
      ResolveInkFilename: function (name) {
        const resolved = resolveInkPath(name);
        if (!Object.prototype.hasOwnProperty.call(sources, resolved)) {
          throw new Error("INCLUDE not found in embedded sources: " + resolved);
        }
        return resolved;
      },
      LoadInkFileContents: function (name) {
        if (!Object.prototype.hasOwnProperty.call(sources, name)) {
          throw new Error("INCLUDE not found in embedded sources: " + name);
        }
        return sources[name];
      }
    };
    try {
      story = new inkjs.Compiler(sources[entryName], {
        sourceFilename: entryName,
        fileHandler: fileHandler
      }).Compile();
    } catch (error) {
      Support.fail("Ink story failed to compile: " + error.message);
      return;
    }

    window.FloeGame = Object.freeze({
      input: function (direction, pressed) {
        if (!story || !pressed) return !!story;
        if (direction === "down") return move(1);
        if (direction === "up") return move(-1);
        if (direction === "right" || direction === "confirm") return choose(selected);
        return false;
      },
      choose: choose,
      key: function (event) {
        if (!story || !event || typeof event.code !== "string") return false;
        if (event.code === "ArrowUp") {
          if (event.pressed) move(-1);
          return true;
        }
        if (event.code === "ArrowDown") {
          if (event.pressed) move(1);
          return true;
        }
        if (event.code === "ArrowRight" || event.code === "Enter" || event.code === "Space") {
          if (event.pressed) choose(selected);
          return true;
        }
        return false;
      },
      pointer: function (phase, x, y) {
        if (phase !== "ended" || !choices.length) return false;
        const element = document.elementFromPoint(x * innerWidth, y * innerHeight);
        if (element && element.classList && element.classList.contains("choice")) {
          element.click();
          return true;
        }
        return false;
      },
      snapshot: function () {
        if (!story) return {};
        return {
          engine: "ink",
          runtime: "inkjs 2.4.0",
          story: story.state.toJson(),
          text: lastText.slice(0, 65536),
          choices: choices.map(function (choice) { return choice.text; }).slice(0, 64)
        };
      },
      restore: function (state) {
        if (!story || !state || typeof state.story !== "string") return false;
        try {
          story.state.LoadJson(state.story);
          lastText = typeof state.text === "string" ? state.text.slice(0, 65536) : "";
          selected = 0;
          render();
          return true;
        } catch (error) {
          log(error);
          return false;
        }
      }
    });

    window.FloeInkRuntime = Object.freeze({
      story: function () { return story; },
      choices: function () { return choices; },
      choose: choose,
      render: render,
      variables: function () {
        var output = {};
        try {
          var variables = story.variablesState._globalVariables || {};
          var names = variables instanceof Map ? Array.from(variables.keys()) : Object.keys(variables);
          names.slice(0, 48).forEach(function (name) {
            var value = story.variablesState[name];
            if (typeof value === "boolean" || typeof value === "number" || typeof value === "string") output[name] = value;
          });
        } catch (error) { log(error); }
        return output;
      },
      setVariable: function (name, value) {
        if (typeof name !== "string" || !/^[A-Za-z0-9_.-]{1,128}$/.test(name)) return false;
        try {
          if (typeof story.variablesState.$ === "function") story.variablesState.$(name, value);
          else story.variablesState[name] = value;
          return true;
        } catch (error) { log(error); return false; }
      },
      jump: function (path) {
        if (typeof path !== "string" || !/^[A-Za-z0-9_.-]{1,128}$/.test(path)) return false;
        try { story.ChoosePathString(path); render(); return true; }
        catch (error) { log(error); return false; }
      }
    });

    function forwardKey(event, pressed) {
      try {
        const detail = {
          key: event.key, code: event.code, keyCode: event.keyCode, which: event.which,
          location: event.location, shiftKey: event.shiftKey, ctrlKey: event.ctrlKey,
          altKey: event.altKey, metaKey: event.metaKey, repeat: event.repeat, pressed: pressed
        };
        if (window.FloeGame && window.FloeGame.key(detail)) event.preventDefault();
      } catch (error) {
        log(error);
      }
    }
    addEventListener("keydown", function (event) { forwardKey(event, true); });
    addEventListener("keyup", function (event) { forwardKey(event, false); });
    render();
    host.ready({
      engine: "ink", runtime: "inkjs 2.4.0", input: true, choose: true,
      pointer: true, state: true, choices: choices.length
    });
  }

  boot().catch(function (error) {
    Support.fail("Ink bridge failed: " + (error && error.message ? error.message : error));
  });
})();
