/* SPDX-License-Identifier: MPL-2.0 */
/*
 * FloeGameNarrativeKit Twine bootstrap (MPL-2.0).
 *
 * The original Twine story model is loaded from game/story.twine.json (user
 * content, not this file). This bootstrap builds the genuine <tw-storydata>
 * document from that JSON using DOM text nodes/attributes only (never
 * innerHTML), then loads the unchanged upstream SugarCube engine from
 * vendor/sugarcube-engine.js and the typed Floe bridge from
 * support/twine-bridge.js.
 */
"use strict";

(function () {
  const Support = window.FloeSupport;
  if (!Support) {
    throw new Error("Floe support host did not load");
  }

  const attributeName = /^[A-Za-z_:][A-Za-z0-9_.:-]*$/;

  function setSafeAttributes(element, attributes) {
    if (!attributes || typeof attributes !== "object") return;
    for (const key of Object.keys(attributes)) {
      const value = attributes[key];
      if (!attributeName.test(key) || /^on/i.test(key) || typeof value !== "string") continue;
      element.setAttribute(key, value);
    }
  }

  function buildStoryData(story) {
    if (!story || typeof story !== "object" ||
        !Array.isArray(story.passages) || typeof story.start !== "string" || !story.start) {
      throw new Error("invalid Twine story model");
    }
    if (!story.passages.some(function (passage) { return passage && passage.pid === story.start; })) {
      throw new Error("Twine start passage is missing");
    }
    const storyData = document.createElement("tw-storydata");
    setSafeAttributes(storyData, story.storyAttributes);
    storyData.setAttribute("name", typeof story.title === "string" ? story.title : "Twine story");
    storyData.setAttribute("startnode", story.start);
    storyData.setAttribute("format", typeof story.format === "string" ? story.format : "SugarCube");
    storyData.setAttribute("format-version", typeof story.formatVersion === "string" ? story.formatVersion : "2.37.3");
    storyData.setAttribute("ifid", typeof story.ifid === "string" && story.ifid ? story.ifid : "FLOE-UNKNOWN");
    storyData.setAttribute("creator", "Floe");
    storyData.setAttribute("creator-version", "1.0");
    for (const passage of story.passages) {
      if (!passage || typeof passage.pid !== "string" || typeof passage.name !== "string" ||
          typeof passage.text !== "string") {
        throw new Error("invalid Twine passage entry");
      }
      const element = document.createElement("tw-passagedata");
      setSafeAttributes(element, passage.attributes);
      element.setAttribute("pid", passage.pid);
      element.setAttribute("name", passage.name);
      element.setAttribute("tags", typeof passage.tags === "string" ? passage.tags : "");
      element.setAttribute("position", typeof passage.position === "string" ? passage.position : "100,100");
      element.setAttribute("size", typeof passage.size === "string" ? passage.size : "100,100");
      element.textContent = passage.text;
      storyData.appendChild(element);
    }
    return storyData;
  }

  function loadScript(source) {
    return new Promise(function (resolve, reject) {
      const script = document.createElement("script");
      script.src = source;
      script.onload = function () { resolve(); };
      script.onerror = function () { reject(new Error("could not load " + source)); };
      document.body.appendChild(script);
    });
  }

  async function boot() {
    let story;
    try {
      story = await Support.fetchJSON("game/story.twine.json");
    } catch (error) {
      Support.fail("Twine story data could not be loaded: " + error.message);
      return;
    }
    let storyData;
    try {
      storyData = buildStoryData(story);
    } catch (error) {
      Support.fail("Twine story data is invalid: " + error.message);
      return;
    }
    const mount = document.getElementById("floe-story-mount") || document.body;
    mount.appendChild(storyData);
    try {
      await loadScript("vendor/sugarcube-engine.js");
      await loadScript("support/twine-bridge.js");
    } catch (error) {
      Support.fail("Twine engine could not start: " + error.message);
    }
  }

  boot().catch(function (error) {
    Support.fail("Twine bootstrap failed: " + (error && error.message ? error.message : error));
  });
})();
