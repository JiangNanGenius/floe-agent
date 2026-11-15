/* SPDX-License-Identifier: MPL-2.0 */
/*
 * FloeGameNarrativeKit Twine/SugarCube bridge (MPL-2.0).
 *
 * SugarCube (BSD-2-Clause, unchanged upstream bytes) is loaded from
 * vendor/sugarcube-engine.js. The original story model is loaded separately
 * from game/story.twine.json by support/twine-bootstrap.js. This file only
 * exposes the typed FloeGame contract over SugarCube.State/Engine.
 */
"use strict";

(function () {
  const Support = window.FloeSupport;
  if (!Support) {
    throw new Error("Floe support host did not load");
  }
  const host = Support.host;

  function engineReady() {
    return !!(window.SugarCube && window.SugarCube.State && window.SugarCube.State.passage);
  }

  let selectedLink = 0;

  function links() {
    return Array.prototype.slice.call(document.querySelectorAll("#passages a.link-internal"));
  }

  function paintSelection() {
    links().forEach(function (link, index) {
      link.style.outline = index === selectedLink ? "2px solid #ffd76a" : "";
    });
  }

  function clickLink(index) {
    const list = links();
    if (index < 0 || index >= list.length) return false;
    selectedLink = 0;
    list[index].click();
    return true;
  }

  function boot() {
    if (!engineReady()) {
      setTimeout(boot, 30);
      return;
    }
    const State = window.SugarCube.State;
    const Engine = window.SugarCube.Engine;
    window.FloeGame = Object.freeze({
      input: function (direction, pressed) {
        if (!pressed) return true;
        if (direction === "right" || direction === "confirm") return clickLink(0);
        return false;
      },
      choose: function (index) { return clickLink(index); },
      key: function (event) {
        if (!event || typeof event.code !== "string") return false;
        const list = links();
        if (!list.length) return false;
        if (event.code === "ArrowUp" || event.code === "ArrowDown") {
          if (event.pressed) {
            selectedLink = (selectedLink + (event.code === "ArrowDown" ? 1 : -1) + list.length) % list.length;
            paintSelection();
          }
          return true;
        }
        if (event.code === "Enter" || event.code === "Space" || event.code === "ArrowRight") {
          if (event.pressed) clickLink(Math.min(selectedLink, list.length - 1));
          return true;
        }
        const digit = /^Digit([1-9])$/.exec(event.code);
        if (digit) {
          if (event.pressed) clickLink(Number(digit[1]) - 1);
          return true;
        }
        return false;
      },
      pointer: function (phase, x, y) {
        if (phase !== "ended") return false;
        const element = document.elementFromPoint(x * innerWidth, y * innerHeight);
        if (element && element.closest && element.closest("a.link-internal")) {
          element.closest("a.link-internal").click();
          return true;
        }
        return false;
      },
      snapshot: function () {
        return {
          engine: "twine",
          runtime: "sugarcube 2.37.3",
          save: State.marshalForSave(),
          passage: State.passage,
          variables: JSON.parse(JSON.stringify(State.variables || {})),
          turns: State.turns || 0
        };
      },
      restore: function (state) {
        if (!state || !state.save || typeof state.save !== "object") return false;
        try {
          State.unmarshalForSave(state.save);
          Engine.show();
          return true;
        } catch (error) {
          host.log(String(error));
          return false;
        }
      }
    });

    window.FloeTwineRuntime = Object.freeze({
      state: function () { return State; },
      engine: function () { return Engine; },
      variables: function () {
        var output = {};
        try {
          var variables = State.variables || {};
          Object.keys(variables).slice(0, 48).forEach(function (name) {
            var value = variables[name];
            if (typeof value === "boolean" || typeof value === "number" || typeof value === "string") output[name] = value;
          });
        } catch (error) { host.log(String(error)); }
        return output;
      },
      jump: function (passage) {
        if (typeof passage !== "string" || !passage || passage.length > 256) return false;
        try { Engine.play(passage); return true; }
        catch (error) { host.log(String(error)); return false; }
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
        host.log(String(error));
      }
    }
    addEventListener("keydown", function (event) { forwardKey(event, true); });
    addEventListener("keyup", function (event) { forwardKey(event, false); });
    host.ready({
      engine: "twine", runtime: "sugarcube 2.37.3", input: false,
      choose: true, pointer: true, state: true
    });
  }

  boot();
})();
