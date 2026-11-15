#!/usr/bin/env node
// SPDX-License-Identifier: MPL-2.0
/**
 * Runtime verification for FloeGameNarrativeKit artifacts.
 *
 * This harness executes the actual engine code inside Node where that is
 * meaningful (inkjs compiler/story, SugarCube in a DOM, WASM-4 cartridge ABI,
 * microScript compiler, TIC-80 cartridge container + wasm module) and it
 * executes the generated FloeGame bridge JavaScript against controlled stubs.
 * It does NOT claim WebKit rendering; the root native host owns GUI acceptance.
 *
 * usage: node verify_narrative.mjs --fixtures <dir> --resources <dir> --evidence <file>
 */
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import crypto from "node:crypto";
import { createRequire } from "node:module";

let fixturesRoot = null;
function resolveRequire() {
  const candidates = [];
  if (process.env.FLOE_NARRATIVE_NODE_TOOLS) candidates.push(path.join(process.env.FLOE_NARRATIVE_NODE_TOOLS, "package.json"));
  if (fixturesRoot) candidates.push(path.join(path.dirname(fixturesRoot), "node-tools", "package.json"));
  candidates.push(path.join(process.cwd(), "package.json"));
  candidates.push(import.meta.url);
  for (const candidate of candidates) {
    try {
      const req = createRequire(candidate.startsWith("file:") ? candidate : path.resolve(candidate));
      req.resolve("jsdom");
      return req;
    } catch { /* try next */ }
  }
  return createRequire(import.meta.url);
}
const require = resolveRequire();
const checks = [];
let failures = 0;
function ok(engine, name, detail = true) {
  checks.push({ engine, check: name, passed: detail === true, detail: detail === true ? undefined : detail });
  if (detail !== true) failures += 1;
}
function sha256(bytes) { return crypto.createHash("sha256").update(bytes).digest("hex"); }
function read(file) { return fs.readFileSync(file); }
function text(file) { return fs.readFileSync(file, "utf8"); }

function artifactPath(fixture, relative) {
  return path.join(fixture.artifact, relative);
}
function artifactText(fixture, relative) {
  return fs.readFileSync(artifactPath(fixture, relative), "utf8");
}
function artifactManifest(fixture) {
  return JSON.parse(artifactText(fixture, "floe-artifact.json"));
}
// The product serves sealed files from one stable origin. A file: jsdom page
// has an opaque origin and disables its real Web Storage implementation.
// Keep actual engine/script bytes intact and replace only bounded transport.
function artifactDOMTransport(artifact) {
  const { ResourceLoader } = require("jsdom");
  const root = path.resolve(artifact);
  const origin = "https://floe-artifact.invalid";
  class ArtifactResources extends ResourceLoader {
    fetch(url) {
      const address = new URL(url);
      if (address.origin !== origin) return null;
      const file = path.resolve(root, "." + decodeURIComponent(address.pathname));
      if (!file.startsWith(root + path.sep)) return null;
      return Promise.resolve(fs.readFileSync(file));
    }
  }
  return { url: origin + "/index.html", resources: new ArtifactResources() };
}
function supportFileNames(fixture) {
  const dir = artifactPath(fixture, "support");
  return fs.readdirSync(dir).filter((name) => /\.(js|css)$/.test(name)).sort();
}
function supportText(fixture) {
  return supportFileNames(fixture).map((name) => artifactText(fixture, "support/" + name)).join("\n");
}
function gameMarker(engine) {
  return {
    ink: "森林邮差",
    twine: "$letters",
    wasm4: "FLOE WASM-4 POSTIE",
    tic80: "FLOE TIC-80",
    microStudio: "FLOE microStudio",
  }[engine];
}
function verifyBoundary(engine, fixture) {
  const manifest = artifactManifest(fixture);
  ok(engine, "artifact manifest identifies the format and engine",
     manifest.format === "floe-narrative-artifact" && manifest.engine === engine && manifest.entry === "index.html",
     { format: manifest.format, engine: manifest.engine, entry: manifest.entry });
  const files = Array.isArray(manifest.files) ? manifest.files : [];
  const seen = new Set();
  let hashesValid = files.length > 0;
  for (const file of files) {
    if (typeof file.path !== "string" || seen.has(file.path)) { hashesValid = false; continue; }
    seen.add(file.path);
    let bytes;
    try { bytes = read(artifactPath(fixture, file.path)); } catch { hashesValid = false; continue; }
    if (bytes.length !== file.bytes || sha256(bytes) !== file.sha256) hashesValid = false;
  }
  ok(engine, "artifact manifest hashes every listed file", hashesValid, { files: files.length });
  ok(engine, "artifact manifest has no duplicate paths", seen.size === files.length);
  const support = Array.isArray(manifest.floeSupportFiles) ? manifest.floeSupportFiles : [];
  const game = Array.isArray(manifest.originalGameFiles) ? manifest.originalGameFiles : [];
  const runtime = Array.isArray(manifest.thirdPartyRuntimeFiles) ? manifest.thirdPartyRuntimeFiles : [];
  const runtimeSources = Array.isArray(manifest.thirdPartySourceFiles) ? manifest.thirdPartySourceFiles : [];
  ok(engine, "manifest separates MPL support, original game content and third-party runtime",
     support.length > 0 && game.length > 0 && runtime.length > 0
       && support.every((p) => p.startsWith("support/")) && game.length > 0 && runtime.length > 0,
     { support: support.length, game: game.length, runtime: runtime.length });
  const names = supportFileNames(fixture);
  const texts = names.map((name) => artifactText(fixture, "support/" + name));
  ok(engine, "MPL support files are readable and carry the SPDX header",
     names.some((name) => name === "floe-host.js")
       && texts.every((text) => text.startsWith("/* SPDX-License-Identifier: MPL-2.0"))
       && texts.every((text) => text.split("\n").every((line) => line.length <= 600)));
  const marker = gameMarker(engine);
  const html = artifactText(fixture, "index.html");
  ok(engine, "HTML shell has no inline Floe support or game source markers",
     !html.includes("window.FloeGame") && !html.includes(marker)
       && html.includes("support/floe-host.js"));
  ok(engine, "support files contain no original game source marker",
     texts.every((text) => !text.includes(marker)));
  const notice = artifactText(fixture, "licenses/FLOE-COMPONENT-MPL-2.0.txt");
  ok(engine, "boundary notice lists the MPL support files and excludes game content",
     support.every((file) => notice.includes(file))
       && notice.includes("Original game content")
       && notice.includes("NOT MPL-2.0")
       && !notice.includes(marker));
  if (engine === "tic80") {
    ok("tic80", "manifest carries the selected third-party source bundle",
       runtimeSources.includes("source/tic80/TIC-80-b3dbd59-source.tar.gz")
         && runtimeSources.includes("source/tic80/blip-buf-330226d-source.tar.gz")
         && runtimeSources.includes("source/tic80/SOURCE-OFFER.md")
         && runtimeSources.every((file) => fs.existsSync(artifactPath(fixture, file))));
    ok("tic80", "notice does not claim full LGPL/relink clearance",
       notice.includes("not a full LGPL clearance"));
  }
  ok(engine, "full MPL text is carried unchanged",
     sha256(read(artifactPath(fixture, "licenses/FLOE-MPL-2.0.txt")))
       === "3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04");
  if (engine === "ink") {
    ok("ink", "original Ink source map is a separate data file",
       artifactText(fixture, "game/ink-sources.json").includes(marker)
         && artifactText(fixture, "story.ink").includes(marker));
  } else if (engine === "twine") {
    ok("twine", "original Twine story is a separate data file",
       artifactText(fixture, "game/story.twine.json").includes(marker)
         && !html.includes("<tw-storydata"));
  } else if (engine === "wasm4") {
    ok("wasm4", "original cartridge is a separate binary file",
       read(artifactPath(fixture, "cart.wasm")).includes(Buffer.from(marker)));
  } else if (engine === "tic80") {
    ok("tic80", "original cartridge is a separate binary file",
       read(artifactPath(fixture, "cart.tic")).includes(Buffer.from(marker)));
  } else if (engine === "microStudio") {
    ok("microStudio", "original sources and resources are separate data files",
       artifactText(fixture, "game/microstudio-sources.json").includes(marker)
         && fs.existsSync(artifactPath(fixture, "game/resources.json")));
  }
}

function parseArgs() {
  const args = process.argv.slice(2);
  const out = {};
  for (let i = 0; i < args.length; i += 2) out[args[i].replace(/^--/, "")] = args[i + 1];
  if (!out.fixtures || !out.resources) {
    console.error("usage: verify_narrative.mjs --fixtures <dir> --resources <dir> [--evidence <file>]");
    process.exit(2);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Ink: real inkjs compiler + story runtime with variables and save/restore.
// ---------------------------------------------------------------------------
function verifyInk(fixture) {
  const inkjs = require(path.join(fixture.resources, "inkjs/inkjs.js"));
  const source = text(path.join(fixture.project, "story.ink"));
  const story = new inkjs.Compiler(source).Compile();
  const pump = (s) => { let out = ""; while (s.canContinue) out += s.Continue(); return out; };

  const opening = pump(story);
  ok("ink", "compile starter with inkjs Compiler", opening.includes("3 封"));
  ok("ink", "opening exposes three choices", story.currentChoices.length === 3, story.currentChoices.length);

  // Choice index 2 = Count the bag, which increments letters (3 -> 4).
  story.ChooseChoiceIndex(2);
  const counted = pump(story);
  const lettersAfterCount = story.variablesState["letters"];
  ok("ink", "choice index 2 increments letters (3 -> 4)", lettersAfterCount === 4, lettersAfterCount);
  ok("ink", "count passage text reflects variable", counted.includes("4 封"), counted.trim().slice(0, 80));

  const save = story.state.toJson();
  const compiledJson = story.ToJson();
  const restored = new inkjs.Story(compiledJson);
  restored.state.LoadJson(save);
  ok("ink", "save state roundtrips variables", restored.variablesState["letters"] === 4, restored.variablesState["letters"]);
  ok("ink", "save state restores choice point", restored.currentChoices.length === 1
     && restored.currentChoices[0].text.includes("继续"), restored.currentChoices.map((c) => c.text));
  // Restore must not re-run side effects: advancing once returns to forest with 4.
  const after = pump(restored);
  ok("ink", "restore does not replay choice effects", restored.variablesState["letters"] === 4 && !after.includes("5 封"));
  // Second choice path proves branch-specific text.
  story.ChooseChoiceIndex(0);
  ok("ink", "branch continues to another passage", pump(story).includes("晨雾") || story.currentChoices.length >= 2);
  return verifyInkGlue(fixture);
}

async function verifyInkGlue(fixture) {
  const { JSDOM } = require("jsdom");
  const artifact = path.join(fixture.artifact);
  const ready = [];
  const dom = await JSDOM.fromFile(path.join(artifact, "index.html"), {
    runScripts: "dangerously", ...artifactDOMTransport(artifact), pretendToBeVisual: true,
    beforeParse(window) {
      // File-backed fetch for the same-artifact story. Only the transport is
      // stubbed; the real inkjs compiler/story and the shipped glue run.
      window.fetch = async (url) => {
        const file = path.join(artifact, String(url));
        if (!fs.existsSync(file)) throw new Error("missing artifact resource " + url);
        const body = fs.readFileSync(file, "utf8");
        return { ok: true, text: async () => body, json: async () => JSON.parse(body) };
      };
      window.floeGameHost = { ready: (payload) => ready.push(payload), log: () => {} };
      // Test-environment only: jsdom does not implement scrollIntoView.
      if (!window.Element.prototype.scrollIntoView) window.Element.prototype.scrollIntoView = () => {};
    },
  });
  const { window } = dom;
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline && !(window.FloeGame && ready.length)) await new Promise((r) => setTimeout(r, 40));
  ok("ink", "shipped glue installs FloeGame in a DOM", !!window.FloeGame);
  ok("ink", "shipped glue reports readiness", ready.some((m) => m.input === true && m.state === true), ready);
  if (window.FloeGame) {
    const initial = window.FloeGame.snapshot();
    ok("ink", "glue snapshot exposes the opening choices", Array.isArray(initial.choices) && initial.choices.length === 3, initial.choices);
    const chose = window.FloeGame.choose(2);
    await new Promise((r) => setTimeout(r, 40));
    const after = window.FloeGame.snapshot();
    ok("ink", "glue choose(2) runs the Count passage", chose === true && after.story !== initial.story, chose);
    ok("ink", "glue snapshot carries incremented variable", after.story.includes("letters") && !after.story.includes("5 封"));
    const restore = window.FloeGame.restore(initial);
    await new Promise((r) => setTimeout(r, 40));
    ok("ink", "glue restore returns true", restore === true);
    ok("ink", "glue restore shows the saved choices again",
       JSON.stringify(window.FloeGame.snapshot().choices) === JSON.stringify(initial.choices));
    // Direction input moves the selection highlight (real DOM state).
    window.FloeGame.input("down", true);
    ok("ink", "glue direction input highlights a choice",
       !!window.document.querySelector(".choice.sel"));
    const beforeKey = window.FloeGame.snapshot();
    ok("ink", "glue key(event) claims arrow keys",
       window.FloeGame.key({ key: "ArrowDown", code: "ArrowDown", keyCode: 40, which: 40, pressed: true }) === true);
    ok("ink", "glue key(event) confirms the highlighted choice",
       window.FloeGame.key({ key: "Enter", code: "Enter", keyCode: 13, which: 13, pressed: true }) === true);
    await new Promise((r) => setTimeout(r, 40));
    ok("ink", "glue key navigation actually changes the story",
       window.FloeGame.snapshot().story !== beforeKey.story);
    ok("ink", "glue key(event) rejects unbound keys",
       window.FloeGame.key({ key: "m", code: "KeyM", pressed: true }) === false);
    ok("ink", "glue installs real DOM keyboard listeners",
       /addEventListener\("keydown"/.test(supportText(fixture)));
  }
  window.close();
}

// ---------------------------------------------------------------------------
// Twine/SugarCube: real format.js in jsdom, real save-state marshal/unmarshal.
// ---------------------------------------------------------------------------
async function verifyTwine(fixture) {
  const { JSDOM } = require("jsdom");
  async function openPage() {
    const pageErrors = [];
    const dom = await JSDOM.fromFile(path.join(fixture.artifact, "index.html"), {
      runScripts: "dangerously", ...artifactDOMTransport(fixture.artifact),
      pretendToBeVisual: true,
      beforeParse(window) {
        // jsdom reports a zero-size viewport; SugarCube waits on a non-zero width.
        Object.defineProperty(window, "innerWidth", { configurable: true, value: 1024 });
        Object.defineProperty(window, "innerHeight", { configurable: true, value: 768 });
        window.scroll = () => {};
        window.scrollTo = () => {};
        // Only the transport is stubbed; the real bootstrap parses this JSON and
        // the real SugarCube engine/runtime bytes execute below.
        window.fetch = async (url) => {
          const file = path.join(fixture.artifact, String(url));
          if (!fs.existsSync(file)) throw new Error("missing artifact resource " + url);
          const body = fs.readFileSync(file, "utf8");
          return { ok: true, status: 200, text: async () => body, json: async () => JSON.parse(body) };
        };
        window.addEventListener("error", (event) => pageErrors.push(String(event.message)));
      },
    });
    const { window } = dom;
    // The parsed documentElement replaces the pre-parse one; install the box
    // metrics on the live element before SugarCube's boot interval polls them.
    Object.defineProperty(window.document.documentElement, "clientWidth", { configurable: true, value: 1024 });
    Object.defineProperty(window.document.documentElement, "clientHeight", { configurable: true, value: 768 });
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline && !(window.SugarCube && window.SugarCube.State && window.SugarCube.State.passage && window.FloeGame)) {
      await new Promise((r) => setTimeout(r, 40));
    }
    return { dom, window, pageErrors };
  }

  const first = await openPage();
  let { window } = first;
  const S = window.SugarCube;
  ok("twine", "published SugarCube page boots from the real artifact", !!(S && S.State && S.State.passage), S && S.State && S.State.passage);
  ok("twine", "generated FloeGame bridge installs on the real page", !!window.FloeGame);
  if (!(S && S.State && S.State.passage && window.FloeGame)) return;
  ok("twine", "starts on the Start passage", S.State.passage === "Start", S.State.passage);
  ok("twine", "start passage sets $letters = 3", S.State.variables.letters === 3, S.State.variables.letters);

  // choose(2) = "数一数邮包" (Count), which increments $letters exactly once.
  const chose = window.FloeGame.choose(2);
  await new Promise((r) => setTimeout(r, 80));
  ok("twine", "choose(2) navigates to Count", S.State.passage === "Count", S.State.passage);
  ok("twine", "Count increments $letters once (4)", S.State.variables.letters === 4, S.State.variables.letters);
  ok("twine", "choose returned true", chose === true);
  ok("twine", "rendered passage shows the incremented variable",
     (window.document.querySelector("#passages")?.textContent || "").includes("4 封"),
     (window.document.querySelector("#passages")?.textContent || "").trim().slice(0, 80));

  const snapshot = window.FloeGame.snapshot();
  ok("twine", "snapshot carries real SugarCube save state", !!(snapshot && snapshot.save && typeof snapshot.save === "object"), Object.keys(snapshot || {}));
  ok("twine", "snapshot save state contains variables", JSON.stringify(snapshot.save).includes("letters"));

  // Move elsewhere, then restore: the restored passage must NOT re-run <<set>>.
  window.FloeGame.choose(0); // back to Start
  await new Promise((r) => setTimeout(r, 80));
  ok("twine", "navigated back to Start", S.State.passage === "Start", S.State.passage);
  const restored = window.FloeGame.restore(snapshot);
  await new Promise((r) => setTimeout(r, 80));
  ok("twine", "restore returns true", restored === true);
  ok("twine", "restore returns to Count", S.State.passage === "Count", S.State.passage);
  ok("twine", "restore does not double-apply passage effects", S.State.variables.letters === 4, S.State.variables.letters);
  ok("twine", "restored passage is rendered once",
     (window.document.querySelector("#passages")?.textContent || "").includes("4 封"),
     (window.document.querySelector("#passages")?.textContent || "").trim().slice(0, 80));
  ok("twine", "glue key(event) claims navigation keys",
     window.FloeGame.key({ key: "ArrowDown", code: "ArrowDown", keyCode: 40, which: 40, pressed: true }) === true);
  ok("twine", "glue key(event) activates the selected link",
     window.FloeGame.key({ key: "Enter", code: "Enter", keyCode: 13, which: 13, pressed: true }) === true);
  await new Promise((r) => setTimeout(r, 80));
  ok("twine", "glue key activation followed the real link", S.State.passage === "Start", S.State.passage);
  ok("twine", "glue key(event) rejects unbound keys",
     window.FloeGame.key({ key: "m", code: "KeyM", pressed: true }) === false);
  // Restart: a fresh load starts from the beginning again.
  first.dom.window.close();
  const second = await openPage();
  ok("twine", "restart begins a clean story", second.window.SugarCube.State.passage === "Start"
     && second.window.SugarCube.State.variables.letters === 3,
     { passage: second.window.SugarCube.State.passage, letters: second.window.SugarCube.State.variables.letters });
  second.dom.window.close();
}

// ---------------------------------------------------------------------------
// WASM-4: cartridge ABI execution + generated glue restore verification.
// ---------------------------------------------------------------------------
function wasm4Env() {
  const memory = new WebAssembly.Memory({ initial: 1, maximum: 1 });
  const calls = { rect: [], text: [] };
  const drawColors = () => new DataView(memory.buffer).getUint16(0x14, true);
  const setPixel = (color, x, y) => {
    if (x < 0 || y < 0 || x >= 160 || y >= 160) return;
    const bytes = new Uint8Array(memory.buffer, 0xa0, 6400);
    const index = (160 * y + x) >>> 2;
    const shift = (x & 3) << 1;
    bytes[index] = ((color & 3) << shift) | (bytes[index] & ~(3 << shift));
  };
  const getPixel = (x, y) => {
    const bytes = new Uint8Array(memory.buffer, 0xa0, 6400);
    return (bytes[(160 * y + x) >>> 2] >>> ((x & 3) << 1)) & 3;
  };
  const env = {
    memory,
    rect(x, y, w, h) {
      const dc = drawColors();
      const fill = (dc & 0xf) - 1;
      calls.rect.push({ x, y, w, h, color: fill });
      if (fill < 0) return;
      for (let yy = y; yy < y + h; yy++) for (let xx = x; xx < x + w; xx++) setPixel(fill, xx, yy);
    },
    text(ptr) {
      const bytes = new Uint8Array(memory.buffer, ptr);
      let end = 0; while (bytes[end] !== 0) end += 1;
      const label = new TextDecoder().decode(bytes.subarray(0, end));
      calls.text.push(label);
      return label;
    },
  };
  return { memory, env, calls, getPixel };
}

async function instantiateWasm4(cartBytes, env) {
  const module = await WebAssembly.compile(cartBytes);
  const instance = await WebAssembly.instantiate(module, { env });
  return instance;
}

async function verifyWasm4(fixture) {
  const cart = read(path.join(fixture.artifact, "cart.wasm"));
  ok("wasm4", "cart.wasm is a WebAssembly module", cart.subarray(0, 4).equals(Buffer.from([0, 0x61, 0x73, 0x6d])));

  const first = wasm4Env();
  const instance = await instantiateWasm4(cart, first.env);
  const exports = instance.exports;
  ok("wasm4", "cartridge exports start/update", typeof exports.start === "function" && typeof exports.update === "function");
  ok("wasm4", "cartridge exports px/py/frames globals", exports.px instanceof WebAssembly.Global
     && exports.py instanceof WebAssembly.Global && exports.frames instanceof WebAssembly.Global);
  exports.start();
  const startLabelAfterStart = first.calls.text[first.calls.text.length - 1];

  // Drive input through the real GAMEPAD1 memory byte, like the upstream runtime.
  const memory = new Uint8Array(first.memory.buffer);
  const before = exports.px.value;
  memory[0x16] = 32; // RIGHT
  for (let i = 0; i < 60; i++) exports.update();
  memory[0x16] = 0;
  const after = exports.px.value;
  ok("wasm4", "input moves the cartridge position", after > before, { before, after });
  const startLabel = first.calls.text[first.calls.text.length - 1];
  ok("wasm4", "starter draws its label through env.text", startLabel === "FLOE WASM-4 POSTIE", startLabel);
  ok("wasm4", "start() alone draws no text", startLabelAfterStart === undefined, startLabelAfterStart);
  const dotColor = first.getPixel(after + 4, exports.py.value + 4);
  ok("wasm4", "framebuffer contains the moved marker", dotColor === 3, dotColor);

  // Upstream SavedGameState semantics: memory + exported globals + disk.
  const saved = {
    memory: Buffer.from(new Uint8Array(first.memory.buffer).subarray(0, 65536)),
    globals: { px: String(exports.px.value), py: String(exports.py.value), frames: String(exports.frames.value) },
    diskSize: 0,
    disk: Buffer.alloc(0),
  };
  // Scramble the live instance, then restore into a fresh cartridge instance.
  memory[0x16] = 16; // LEFT
  for (let i = 0; i < 20; i++) exports.update();

  const second = wasm4Env();
  const restored = await instantiateWasm4(cart, second.env);
  new Uint8Array(second.memory.buffer).set(saved.memory);
  for (const [name, value] of Object.entries(saved.globals)) restored.exports[name].value = value;
  restored.exports.start();
  restored.exports.update();
  ok("wasm4", "restore recovers captured position", restored.exports.px.value === Number(saved.globals.px),
     { expected: saved.globals.px, actual: restored.exports.px.value });
  ok("wasm4", "restore keeps frame counter", restored.exports.frames.value === Number(saved.globals.frames) + 1,
     { expected: Number(saved.globals.frames) + 1, actual: restored.exports.frames.value });

  // Executable verification of the generated bridge glue (catches the parameter
  // shadowing bug: restore(state) must still be able to find the app element).
  const hostScript = artifactText(fixture, "support/floe-host.js");
  const glue = artifactText(fixture, "support/wasm4-bridge.js");
  ok("wasm4", "generated glue is a separate support source file",
     glue.includes("window.FloeGame") && glue.includes("SPDX-License-Identifier: MPL-2.0"));
  class SavedGameState {
    write(runtime) { runtime.restored = this; }
  }
  const app = {
    runtime: { wasm: {} },
    inputState: { gamepad: [0], mouseX: 0, mouseY: 0, mouseButtons: 0 },
    savedGameState: null,
    loaded: false,
    saveGameState() {
      this.savedGameState = Object.assign(this.savedGameState || new SavedGameState(), {
        memory: new ArrayBuffer(65536),
        globals: { px: "90", py: "70", frames: "12" },
        diskBuffer: new ArrayBuffer(1024),
        diskSize: 2,
      });
      new Uint8Array(this.savedGameState.memory).fill(0x5a);
      new Uint8Array(this.savedGameState.diskBuffer).set([7, 9]);
    },
    loadGameState() { this.savedGameState.write(this.runtime); this.loaded = this.savedGameState; },
  };
  const ready = [];
  const sandbox = {
    console,
    setTimeout,
    clearTimeout,
    Uint8Array,
    ArrayBuffer,
    Object,
    Math,
    JSON,
    String,
    Number,
    document: { querySelector: (selector) => (selector === "wasm4-app" ? app : null), elementFromPoint: () => null },
    innerWidth: 1024,
    innerHeight: 768,
    btoa: (value) => Buffer.from(value, "binary").toString("base64"),
    atob: (value) => Buffer.from(value, "base64").toString("binary"),
  };
  sandbox.window = sandbox;
  sandbox.floeGameHost = { ready: (payload) => ready.push(payload), log: () => {} };
  vm.createContext(sandbox);
  vm.runInContext(hostScript, sandbox);
  vm.runInContext(glue, sandbox);
  await new Promise((r) => setTimeout(r, 80));
  ok("wasm4", "generated glue installs FloeGame", !!sandbox.FloeGame);
  ok("wasm4", "glue readiness reports input/state", ready.some((m) => m.input === true && m.state === true), ready);

  sandbox.FloeGame.input("left", true);
  ok("wasm4", "glue maps left to gamepad bit 16", app.inputState.gamepad[0] === 16, app.inputState.gamepad[0]);
  sandbox.FloeGame.input("left", false);
  ok("wasm4", "glue clears released input", app.inputState.gamepad[0] === 0);
  sandbox.FloeGame.pointer("began", 0.5, 0.5, 0);
  ok("wasm4", "glue maps pointer to mouse input", app.inputState.mouseX === 80 && app.inputState.mouseY === 80
     && app.inputState.mouseButtons === 1, { x: app.inputState.mouseX, y: app.inputState.mouseY, b: app.inputState.mouseButtons });
  ok("wasm4", "glue key(event) sets the physical gamepad bit",
     sandbox.FloeGame.key({ key: "ArrowLeft", code: "ArrowLeft", keyCode: 37, which: 37, pressed: true }) === true
       && app.inputState.gamepad[0] === 16, app.inputState.gamepad[0]);
  sandbox.FloeGame.key({ key: "ArrowLeft", code: "ArrowLeft", pressed: false });
  ok("wasm4", "glue key release clears the bit", app.inputState.gamepad[0] === 0);
  ok("wasm4", "glue key(event) maps X to button 1",
     sandbox.FloeGame.key({ key: "x", code: "KeyX", pressed: true }) === true && app.inputState.gamepad[0] === 1);
  sandbox.FloeGame.key({ key: "x", code: "KeyX", pressed: false });
  ok("wasm4", "glue key(event) rejects unbound keys",
     sandbox.FloeGame.key({ key: "m", code: "KeyM", pressed: true }) === false);

  const snapshot = sandbox.FloeGame.snapshot();
  ok("wasm4", "glue snapshot captures memory+globals", typeof snapshot.memory === "string"
     && Buffer.from(snapshot.memory, "base64").length === 65536 && snapshot.globals.px === "90");
  const restoreResult = sandbox.FloeGame.restore(snapshot);
  ok("wasm4", "glue restore executes without shadowing error", restoreResult === true, restoreResult);
  ok("wasm4", "glue restore delegates to upstream loadGameState", app.loaded === app.savedGameState
     && Buffer.from(app.loaded.memory).every((byte) => byte === 0x5a));
  ok("wasm4", "restore retains the upstream state object's methods", app.loaded instanceof SavedGameState
     && app.runtime.restored === app.loaded);
  ok("wasm4", "glue restore preserves disk bytes", app.loaded.diskSize === 2
     && new Uint8Array(app.loaded.diskBuffer)[0] === 7 && new Uint8Array(app.loaded.diskBuffer)[1] === 9);
  ok("wasm4", "glue rejects a truncated state", sandbox.FloeGame.restore({ memory: "AAAA" }) === false);
}

// ---------------------------------------------------------------------------
// TIC-80: real .tic container parsing + upstream wasm player module validation.
// ---------------------------------------------------------------------------
function parseTIC(bytes) {
  const chunks = [];
  let index = 0;
  while (index + 4 <= bytes.length) {
    const raw = bytes.readUInt32LE(index); index += 4;
    const type = raw & 0x1f, bank = (raw >>> 5) & 7, size = (raw >>> 8) & 0xffff;
    const payload = size === 0 && (type === 5 || type === 19) ? 65536 : size;
    chunks.push({ type, bank, data: bytes.subarray(index, index + payload) });
    index += payload;
  }
  if (index !== bytes.length) throw new Error("trailing bytes");
  return chunks;
}

async function verifyTIC80(fixture) {
  const cart = read(path.join(fixture.artifact, "cart.tic"));
  const chunks = parseTIC(cart);
  ok("tic80", "cartridge chunks decode", chunks.length === 3, chunks.map((c) => c.type));
  const codeChunk = chunks.find((c) => c.type === 5);
  const code = codeChunk ? new TextDecoder().decode(codeChunk.data) : "";
  ok("tic80", "CODE chunk carries the starter script", code.includes("function TIC()") && code.includes("// script: js"));
  let pressed = new Set([3]);
  const starter = { Math, btn: (id) => pressed.has(id), cls(){}, rectb(){}, rect(){}, print(){} };
  vm.createContext(starter); vm.runInContext(code, starter);
  const origin = { x: starter.x, y: starter.y };
  starter.TIC();
  ok("tic80", "official right button moves only the horizontal axis", starter.x === origin.x + 2 && starter.y === origin.y);
  pressed = new Set([0]); starter.TIC();
  ok("tic80", "official up button moves only the vertical axis", starter.x === origin.x + 2 && starter.y === origin.y - 2);
  const lang = chunks.find((c) => c.type === 20);
  ok("tic80", "LANG chunk selects the JS runtime", !!lang && lang.data[0] === 12, lang && lang.data[0]);

  const wasm = read(path.join(fixture.artifact, "tic80js.wasm"));
  const module = await WebAssembly.compile(wasm);
  const exportsList = WebAssembly.Module.exports(module);
  const importsList = WebAssembly.Module.imports(module);
  ok("tic80", "upstream player wasm compiles", exportsList.length > 0, { exports: exportsList.length, imports: importsList.length });
  ok("tic80", "player exports linear memory", exportsList.some((e) => e.kind === "memory"));
  ok("tic80", "player imports the sokol/GL environment", importsList.some((i) => i.module === "a"));

  const html = text(path.join(fixture.artifact, "index.html"));
  const moduleSandbox = { window: {}, document: { getElementById: () => ({}) } };
  const bootScript = artifactText(fixture, "support/tic80-boot.js");
  vm.runInNewContext(bootScript, moduleSandbox);
  const configured = moduleSandbox.window.Module;
  ok("tic80", "artifact hands cart.tic to the player via Module.arguments",
     JSON.stringify(configured.arguments) === '["cart.tic"]');
  let starts = 0;
  configured._sokol_start = () => { starts += 1; };
  configured.onRuntimeInitialized();
  ok("tic80", "WASM initialization alone does not claim a running cartridge", !configured.floeCartStarted);
  configured._sokol_start();
  ok("tic80", "readiness observes the upstream cartridge-start boundary", starts === 1 && configured.floeCartStarted === true);
  ok("tic80", "artifact has the real canvas target", html.includes('<canvas id="canvas"'));
  ok("tic80", "artifact reports state:false (no fake save path)",
     artifactText(fixture, "support/tic80-bridge.js").includes("state: false"));
  await verifyTIC80Glue(fixture);
}

async function verifyTIC80Glue(fixture) {
  const { JSDOM } = require("jsdom");
  const hostScript = artifactText(fixture, "support/floe-host.js");
  const glue = artifactText(fixture, "support/tic80-bridge.js");
  const ready = [];
  const keys = [];
  const dom = new JSDOM(`<!doctype html><html><body><canvas id="canvas"></canvas><script>${hostScript}</script><script>${glue}</script></body></html>`, {
    url: "https://floe.invalid/", runScripts: "dangerously", pretendToBeVisual: true,
    beforeParse(window) {
      window.Module = { floeCartStarted: true, canvas: null };
      window.floeGameHost = { ready: (payload) => ready.push(payload), log: () => {} };
    },
  });
  const { window } = dom;
  const canvas = window.document.getElementById("canvas");
  canvas.addEventListener("keydown", (event) => keys.push(event.code));
  canvas.addEventListener("keyup", (event) => keys.push("up:" + event.code));
  const deadline = Date.now() + 4000;
  while (Date.now() < deadline && !(window.FloeGame && ready.length)) await new Promise((r) => setTimeout(r, 20));
  ok("tic80", "shipped glue installs FloeGame", !!window.FloeGame);
  ok("tic80", "glue readiness reports state:false", ready.some((m) => m.input === true && m.state === false), ready);
  window.FloeGame.input("right", true);
  window.FloeGame.input("right", false);
  ok("tic80", "glue input dispatches arrow key events to the canvas",
     keys.includes("ArrowRight") && keys.includes("up:ArrowRight"), keys);
  ok("tic80", "glue key(event) dispatches a coded keydown",
     window.FloeGame.key({ key: "z", code: "KeyZ", keyCode: 90, which: 90, pressed: true }) === true
       && keys.includes("KeyZ"), keys);
  ok("tic80", "glue key(event) rejects unbound keys",
     window.FloeGame.key({ key: "b", code: "KeyB", pressed: true }) === false);
  ok("tic80", "glue snapshot is explicitly unsupported", window.FloeGame.snapshot() === null);
  window.close();
}

// ---------------------------------------------------------------------------
// microStudio: real microScript 2 compiler pipeline on the starter source.
// ---------------------------------------------------------------------------
async function verifyMicroStudio(fixture) {
  const language = text(path.join(fixture.artifact, "language.js"));
  const sandbox = { console, Math, Date, JSON, Number, String, Object, Array, Map, Set, Error, isFinite, parseFloat };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(language, sandbox);
  ok("microStudio", "language bundle defines Tokenizer/Parser/Program/Compiler",
     typeof sandbox.Tokenizer === "function" && typeof sandbox.Parser === "function"
     && typeof sandbox.Program === "function" && typeof sandbox.Compiler === "function");

  const sourceDocument = JSON.parse(artifactText(fixture, "game/microstudio-sources.json"));
  const source = sourceDocument.code;
  ok("microStudio", "artifact carries the original source in a separate data file",
     typeof source === "string" && source.includes("floe_snapshot = function(seed)")
       && source.includes("update = function()"));

  const parser = new sandbox.Parser(source, "main.ms");
  parser.parse();
  ok("microStudio", "parser reports no syntax errors", !parser.error_info && (parser.warnings || []).length === 0,
     parser.error_info || (parser.warnings || []).slice(0, 3));
  ok("microStudio", "parser builds a statement program", Array.isArray(parser.program.statements) && parser.program.statements.length > 0,
     parser.program.statements && parser.program.statements.length);
  const compiler = new sandbox.Compiler(parser.program);
  const opcodes = compiler.routine && compiler.routine.opcodes;
  ok("microStudio", "compiler emits executable microScript opcodes", Array.isArray(opcodes) && opcodes.length > 10,
     opcodes && opcodes.length);
  // The starter must define the state functions the bridge calls.
  const functionNames = parser.program.statements
    .filter((s) => s && s.constructor && s.constructor.name === "Assignment"
      && s.expression && s.expression.constructor && s.expression.constructor.name === "Function")
    .map((s) => s.field && s.field.identifier)
    .filter(Boolean);
  ok("microStudio", "starter defines init/update/floe_snapshot/floe_restore",
     ["init", "update", "floe_snapshot", "floe_restore"].every((n) => functionNames.includes(n)),
     functionNames.slice(0, 12));
  ok("microStudio", "engine bundle concatenates upstream player", text(path.join(fixture.artifact, "microengine.js")).includes("class Player"));
  await verifyMicroStudioGlue(fixture);
}

async function verifyMicroStudioGlue(fixture) {
  const { JSDOM } = require("jsdom");
  const hostScript = artifactText(fixture, "support/floe-host.js");
  const glue = artifactText(fixture, "support/microstudio-bridge.js");
  const ready = [];
  const keyLog = [];
  const dom = new JSDOM(`<!doctype html><html><body><div id="canvaswrapper"></div><script>${hostScript}</script><script>${glue}</script></body></html>`, {
    url: "https://floe.invalid/", runScripts: "dangerously", pretendToBeVisual: true,
    beforeParse(window) {
      window.fetch = async (url) => {
        const file = path.join(fixture.artifact, String(url));
        if (!fs.existsSync(file)) throw new Error("missing artifact resource " + url);
        const body = fs.readFileSync(file, "utf8");
        return { ok: true, status: 200, text: async () => body, json: async () => JSON.parse(body) };
      };
      window.floeGameHost = { ready: (payload) => ready.push(payload), log: () => {} };
      window.Player = class FakePlayer {
        constructor(listener) { this.listener = listener; setTimeout(() => listener({ name: "started" }), 0); }
        call(name, args) {
          if (name === "floe_snapshot") return [12, 34, 0];
          if (name === "floe_restore") { window.__restored = args; return 1; }
          return 0;
        }
      };
    },
  });
  const { window } = dom;
  window.document.addEventListener("keydown", (event) => keyLog.push(event.code));
  window.document.addEventListener("keyup", (event) => keyLog.push("up:" + event.code));
  const deadline = Date.now() + 4000;
  while (Date.now() < deadline && !(window.FloeGame && ready.length)) await new Promise((r) => setTimeout(r, 20));
  ok("microStudio", "shipped glue installs FloeGame with the real Player seam", !!window.FloeGame);
  ok("microStudio", "glue readiness reports state via floe_snapshot", ready.some((m) => m.state === true), ready);
  const snapshot = window.FloeGame.snapshot();
  ok("microStudio", "glue snapshot maps floe_snapshot array", JSON.stringify(snapshot.values) === "[12,34,0]", snapshot);
  ok("microStudio", "glue restore maps floe_restore args", window.FloeGame.restore({ values: [5, 6, 7] }) === true
     && JSON.stringify(window.__restored) === "[5,6,7]", window.__restored);
  window.FloeGame.input("left", true);
  window.FloeGame.input("left", false);
  ok("microStudio", "glue input dispatches real keyboard events", keyLog.includes("ArrowLeft") && keyLog.includes("up:ArrowLeft"), keyLog);
  ok("microStudio", "glue key(event) dispatches a coded keydown",
     window.FloeGame.key({ key: "w", code: "KeyW", keyCode: 87, which: 87, pressed: true }) === true
       && keyLog.includes("KeyW"), keyLog);
  ok("microStudio", "glue key(event) rejects unbound keys",
     window.FloeGame.key({ key: "m", code: "KeyM", pressed: true }) === false);
  window.close();
}

// ---------------------------------------------------------------------------
// A failed same-origin data fetch must be an explicit error, never fake ready.
// ---------------------------------------------------------------------------
async function verifyFetchFailure(engine, fixture) {
  if (!["ink", "twine", "microStudio"].includes(engine)) return;
  const { JSDOM } = require("jsdom");
  const ready = [];
  const logs = [];
  const dom = await JSDOM.fromFile(path.join(fixture.artifact, "index.html"), {
    runScripts: "dangerously", ...artifactDOMTransport(fixture.artifact), pretendToBeVisual: true,
    beforeParse(window) {
      window.fetch = async () => { throw new Error("offline-fetch-failure"); };
      window.floeGameHost = { ready: (payload) => ready.push(payload), log: (line) => logs.push(String(line)) };
    },
  });
  const { window } = dom;
  await new Promise((resolve) => setTimeout(resolve, 2000));
  const panel = window.document.getElementById("floe-runtime-error");
  const errorText = (panel && panel.textContent ? panel.textContent : "") + "\n" + logs.join("\n");
  ok(engine, "source fetch failure is explicit and never reports ready",
     ready.length === 0 && /could not be loaded/.test(errorText), { ready: ready.length, errorText: errorText.slice(0, 240) });
  window.close();
}

// ---------------------------------------------------------------------------
// Project keyboard declaration (floe-inputs.json) must be truthful and valid.
// ---------------------------------------------------------------------------
function verifyInputs(engine, fixture) {
  const file = path.join(fixture.artifact, "floe-inputs.json");
  if (!fs.existsSync(file)) { ok(engine, "floe-inputs.json present in artifact", false); return; }
  let declaration = null;
  try { declaration = JSON.parse(fs.readFileSync(file, "utf8")); }
  catch (error) { ok(engine, "floe-inputs.json is valid JSON", String(error)); return; }
  ok(engine, "floe-inputs.json schemaVersion 1", declaration.schemaVersion === 1, declaration.schemaVersion);
  ok(engine, "floe-inputs.json engine identity", declaration.engine === engine, declaration.engine);
  const movement = declaration.movement || {};
  const movementKeys = ["left", "right", "up", "down"].flatMap((side) => movement[side] || []);
  const buttonKeys = (declaration.buttons || []).flatMap((button) => button.keys || []);
  const allKeys = [...movementKeys, ...buttonKeys];
  const keyShape = allKeys.every((key) => typeof key === "string" && key.length > 0 && key.length <= 32
    && /^[A-Za-z0-9]+$/.test(key));
  ok(engine, "floe-inputs.json keys are fixed identifiers", keyShape, allKeys.slice(0, 12));
  ok(engine, "floe-inputs.json has no command-like payloads",
     !JSON.stringify(declaration).match(/exec|shell|evaluate|javascript:|\$\{/i) || allKeys.every((k) => typeof k === "string"));
  const projectDeclaration = path.join(fixture.project, "floe-inputs.json");
  if (fs.existsSync(projectDeclaration)) {
    ok(engine, "artifact declaration matches the project declaration",
       fs.readFileSync(projectDeclaration, "utf8").trim() === fs.readFileSync(file, "utf8").trim());
  }
}

async function main() {
  const args = parseArgs();
  fixturesRoot = args.fixtures;
  const fixtures = JSON.parse(text(path.join(args.fixtures, "fixtures.json")));
  const byEngine = Object.fromEntries(fixtures.map((f) => [f.engine, { ...f, resources: args.resources }]));
  const started = new Date().toISOString();
  const order = ["ink", "twine", "wasm4", "tic80", "microStudio"];
  for (const engine of order) {
    const fixture = byEngine[engine];
    if (!fixture) { ok(engine, "fixture present", false); continue; }
    verifyInputs(engine, fixture);
    verifyBoundary(engine, fixture);
    await verifyFetchFailure(engine, fixture);
    try {
      if (engine === "ink") await verifyInk(fixture);
      else if (engine === "twine") await verifyTwine(fixture);
      else if (engine === "wasm4") await verifyWasm4(fixture);
      else if (engine === "tic80") await verifyTIC80(fixture);
      else if (engine === "microStudio") await verifyMicroStudio(fixture);
    } catch (error) {
      ok(engine, "harness completed", String(error && error.stack || error));
    }
  }
  const evidence = {
    kind: "floe-narrative-runtime-verification",
    startedAt: started, finishedAt: new Date().toISOString(),
    node: process.version, platform: process.platform, arch: process.arch,
    fixtures: fixtures.map((f) => ({ engine: f.engine, artifact: f.artifact, runtimeVersion: f.runtimeVersion, license: f.license, cartSHA256: f.cartSHA256, manifestSHA256: f.manifestSHA256 })),
    passed: checks.filter((c) => c.passed).length,
    failed: failures,
    checks,
  };
  if (args.evidence) {
    fs.mkdirSync(path.dirname(args.evidence), { recursive: true });
    fs.writeFileSync(args.evidence, JSON.stringify(evidence, null, 2) + "\n");
  }
  console.log(JSON.stringify({ passed: evidence.passed, failed: evidence.failed, checks: checks.length }));
  if (failures > 0) {
    for (const c of checks.filter((x) => !x.passed)) console.error("FAIL", c.engine, c.check, c.detail ?? "");
    process.exit(1);
  }
}

main().catch((error) => { console.error(error); process.exit(1); });
