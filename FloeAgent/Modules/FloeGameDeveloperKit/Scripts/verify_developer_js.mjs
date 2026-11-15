#!/usr/bin/env node
// SPDX-License-Identifier: MPL-2.0
// Real Node checks for the host helper and applicable engine hooks. This does
// not replace WebKit/App acceptance.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const sdk = path.resolve(here, '..', '..');
const fixtureRoot = path.resolve(sdk, '..', 'Fixtures');
const helperPath = path.join(sdk, 'FloeGameKit/Sources/FloeGameWebKit/Resources/Developer/FloeDeveloper.js');
const hookRoot = path.join(sdk, 'FloeGameKit/Sources/FloeGameWebKit/Resources/Developer/Hooks');
const helperSource = fs.readFileSync(helperPath, 'utf8');

function sandboxFor(engine) {
  let reloadCalled = false;
  const element = { style: {}, dispatchEvent: () => true, getBoundingClientRect: () => ({ left: 0, top: 0, width: 800, height: 480 }) };
  const sandbox = {
    console,
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (id) => clearTimeout(id),
    setInterval: (fn, ms) => setInterval(fn, ms),
    clearInterval: (id) => clearInterval(id),
    TextEncoder,
    WebAssembly,
    Date,
    JSON,
    Math,
    Object,
    Array,
    Map,
    Set,
    Number,
    String,
    Boolean,
    Error,
    Promise,
    Intl,
    document: {
      title: 'Floe test',
      readyState: 'complete',
      visibilityState: 'visible',
      body: {},
      activeElement: null,
      getElementById: () => null,
      querySelector: () => element,
      querySelectorAll: () => [],
      createElement: () => element
    },
    location: { pathname: '/index.html', reload: () => { reloadCalled = true; } },
    requestAnimationFrame: () => 0,
    addEventListener: () => {},
    removeEventListener: () => {},
    FloeDeveloperBootstrap: {
      token: '00000000-0000-4000-8000-000000000001',
      engine
    }
  };
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(helperSource, sandbox, { filename: helperPath });
  assert.equal(typeof sandbox.FloeDeveloper, 'object', 'helper installed');
  return { sandbox, reload: () => reloadCalled };
}

function loadHook(sandbox, engine) {
  const source = fs.readFileSync(path.join(hookRoot, engine + '.js'), 'utf8');
  vm.runInContext(source, sandbox, { filename: engine + '.js' });
}

async function tick() { await new Promise((resolve) => setTimeout(resolve, 10)); }

async function testHelper() {
  const { sandbox, reload } = sandboxFor('phaser');
  const D = sandbox.FloeDeveloper;
  let x = 1, y = 2, flag = true;
  const registered = D.register({
    fields: [
      { id: 'test.x', label: 'X', labelZhHans: 'X', group: 'Test', groupZhHans: '测试', kind: 'integer', minimum: 0, maximum: 100,
        get: () => x, set: (value) => { x = value; } },
      { id: 'test.y', label: 'Y', labelZhHans: 'Y', group: 'Test', groupZhHans: '测试', kind: 'readOnlyNumber',
        get: () => y },
      { id: 'test.ratio', label: 'Ratio', labelZhHans: '比例', group: 'Test', groupZhHans: '测试', kind: 'readOnlyNumber',
        get: () => 1.25 },
      { id: 'test.flag', label: 'Flag', labelZhHans: '开关', group: 'Test', groupZhHans: '测试', kind: 'boolean',
        get: () => flag, set: (value) => { flag = value; } }
    ],
    actions: [
      { id: 'test.add', label: 'Add', labelZhHans: '增加', group: 'Test', groupZhHans: '测试',
        parameters: [{ id: 'amount', label: 'Amount', labelZhHans: '数量', kind: 'integer', minimum: -10, maximum: 10, isRequired: true }],
        invoke: (args) => { x += args.amount; return { message: 'Added.' }; } }
    ]
  });
  assert.equal(registered, true);
  const probe = await D.__exchange('probe', {});
  assert.ok(probe.fields.some((field) => field.id === 'test.x'));
  assert.ok(probe.actions.some((action) => action.id === 'test.add'));
  assert.ok(probe.fields.some((field) => field.id === 'page.title'));

  const write = await D.__exchange('write', { changes: [{ id: 'test.x', value: 7 }] });
  assert.equal(write.status, 'applied');
  assert.ok(!('id' in write), 'outcome id stays a native UUID default, not a string');
  assert.equal(x, 7);
  assert.ok(write.changedFieldIDs.includes('test.x'));
  const read = await D.__exchange('read', {});
  assert.equal(read.values['test.ratio'], 1.25, 'fractional read-only values survive validation');

  const bad = await D.__exchange('write', { changes: [{ id: '__proto__', value: 1 }] });
  assert.equal(bad.status, 'rejected');

  const falseWrite = await D.__exchange('write', { changes: [{ id: 'test.flag', value: false }] });
  assert.equal(falseWrite.status, 'applied');
  assert.equal(flag, false);
  assert.equal(falseWrite.state.values['test.flag'], false);

  const action = await D.__exchange('invoke', { id: 'test.add', arguments: { amount: 5 } });
  assert.equal(action.status, 'applied');
  assert.equal(x, 12);
  assert.ok(action.changedFieldIDs.includes('test.x'));

  sandbox.FloeGame = {
    snapshot: () => ({ x, y }),
    restore: (value) => { x = value.x; y = value.y; return true; }
  };
  const snapshot = await D.__exchange('snapshot', {});
  assert.equal(snapshot.snapshot.format, 'floe-developer-snapshot');
  assert.equal(snapshot.snapshot.engine, 'phaser');
  y = 99;
  const restore = await D.__exchange('restore', { snapshot: snapshot.snapshot });
  assert.equal(restore.restored, true);
  assert.equal(y, 2);

  const reset = await D.__exchange('reset', { mode: 'reload' });
  assert.equal(reset.status, 'reloading');
  await new Promise((resolve) => setTimeout(resolve, 120));
  assert.equal(reload(), true, 'reset schedules a real page reload');
  console.log('PASS helper: probe/read/write/action/snapshot/restore/reset/bounds');
}

async function testPushBridge() {
  const { sandbox } = sandboxFor('godot');
  const D = sandbox.FloeDeveloper;
  assert.equal(D.registerPushed({
    runtime: 'Simulated built engine',
    fields: [
      { id: 'engine.timescale', label: 'Time scale', labelZhHans: '时间缩放', group: 'Engine', groupZhHans: '引擎', kind: 'number', minimum: 0, maximum: 4 },
      { id: 'scene.name', label: 'Scene', labelZhHans: '场景', group: 'Engine', groupZhHans: '引擎', kind: 'readOnlyText' }
    ],
    actions: [{ id: 'engine.pause', label: 'Pause', labelZhHans: '暂停', group: 'Engine', groupZhHans: '引擎', isQuick: true }]
  }), true);
  assert.equal(D.updatePushed({ 'engine.timescale': 1, 'scene.name': 'Main' }), true);
  const probe = await D.__exchange('probe', {});
  assert.ok(probe.fields.some((field) => field.id === 'engine.timescale'));
  assert.equal(probe.supports.pause, false, 'push actions are not claimed as synchronous hooks');
  const pending = D.__exchange('write', { changes: [{ id: 'engine.timescale', value: 2 }] });
  await tick();
  const commands = D.takeCommands();
  assert.equal(commands.length, 1);
  assert.equal(commands[0].kind, 'set');
  assert.equal(commands[0].field, 'engine.timescale');
  D.updatePushed({ 'engine.timescale': 2, 'scene.name': 'Main' });
  assert.equal(D.ackCommand(commands[0].id, { ok: true }), true);
  const outcome = await pending;
  assert.equal(outcome.status, 'applied');
  assert.equal(outcome.state.values['engine.timescale'], 2);

  const action = D.__exchange('invoke', { id: 'engine.pause', arguments: {} });
  await tick();
  const actionCommands = D.takeCommands();
  assert.equal(actionCommands.length, 1);
  assert.equal(actionCommands[0].kind, 'action');
  assert.equal(D.ackCommand(actionCommands[0].id, { ok: true }), true);
  const actionOutcome = await action;
  assert.equal(actionOutcome.status, 'applied');
  console.log('PASS push bridge: registration, write queue/read-back, action queue');
}


async function testImportedPhaserSnapshotFallback() {
  const { sandbox } = sandboxFor('phaser');
  const object = () => ({
    setStrokeStyle: () => object(), setVisible: () => object(), setPosition: () => object(),
    setOrigin: () => object(), setText: () => object(), x: 0, y: 0
  });
  const fakeScene = {
    add: {
      rectangle: () => object(), triangle: () => object(), text: () => object(), circle: () => object()
    },
    input: { keyboard: { createCursorKeys: () => ({ left: { isDown: false }, right: { isDown: false }, up: { isDown: false }, down: { isDown: false } }) }, on: () => {} }
  };
  class FakeGame {
    constructor(config) {
      this.config = config;
      config.scene.create.call(fakeScene);
    }
  }
  sandbox.window.Phaser = {
    VERSION: '3.90.0', Game: FakeGame, CANVAS: 1,
    Scale: { FIT: 1, CENTER_HORIZONTALLY: 2 },
    Math: {
      Clamp: (value, low, high) => Math.max(low, Math.min(high, value)),
      Distance: { Between: (ax, ay, bx, by) => Math.hypot(ax - bx, ay - by) }
    }
  };
  sandbox.window.fetch = async (name) => ({ json: async () => ({ title: 'Imported fixture', speed: 180 }) });
  loadHook(sandbox, 'phaser');
  const zip = path.resolve(sdk, '..', 'NativeUIHost/Resources/FloeNativeWeb.zip');
  const gameSource = execFileSync('unzip', ['-p', zip, 'game.js'], { encoding: 'utf8' });
  vm.runInContext(gameSource, sandbox, { filename: 'FloeNativeWeb/game.js' });
  await new Promise((resolve) => setTimeout(resolve, 250));
  const D = sandbox.FloeDeveloper;
  const probe = await D.__exchange('probe', {});
  const fieldIDs = probe.fields.map((field) => field.id);
  assert.ok(fieldIDs.includes('state.score'), 'imported game score is exposed: ' + fieldIDs.join(','));
  assert.ok(fieldIDs.includes('state.x') && fieldIDs.includes('state.y'));
  assert.ok(!fieldIDs.includes('state.engineVersion'), 'protected identity metadata is skipped');
  const write = await D.__exchange('write', { changes: [{ id: 'state.score', value: 2 }] });
  assert.equal(write.status, 'applied');
  assert.equal(write.state.values['state.score'], 2);
  const snapshot = await D.__exchange('snapshot', {});
  const zero = await D.__exchange('write', { changes: [{ id: 'state.score', value: 0 }] });
  assert.equal(zero.status, 'applied');
  const restore = await D.__exchange('restore', { snapshot: snapshot.snapshot });
  assert.equal(restore.restored, true);
  assert.equal(restore.state.values['state.score'], 2);
  console.log('PASS imported FloeNativeWeb game.js scalar fallback: score edit + snapshot restore');
}


async function testMicroStudioNamedState() {
  const { sandbox } = sandboxFor('microStudio');
  let named = { score: 4, lives: 3, speed: 1 };
  const revisions = { value: 0 };
  sandbox.window.FloeGame = {
    snapshot: () => ({ engine: 'microStudio', runtime: 'microstudio 1.0.0', named: { ...named } }),
    restore: (state) => {
      if (!state || !state.named) return false;
      named = { ...state.named };
      revisions.value++;
      return true;
    }
  };
  loadHook(sandbox, 'microStudio');
  const D = sandbox.FloeDeveloper;
  const probe = await D.__exchange('probe', {});
  const score = probe.fields.find((field) => field.label === 'score');
  assert.ok(score, 'named microStudio score field registered');
  const write = await D.__exchange('write', { changes: [{ id: score.id, value: 9 }] });
  assert.equal(write.status, 'applied');
  assert.equal(named.score, 9);
  assert.equal(write.state.values[score.id], 9);
  assert.ok(revisions.value >= 1, 'bridge restore path was used');
  console.log('PASS microStudio named state: score write/read through floe_snapshot/floe_restore_named');
}


async function testWasm4Globals() {
  const { sandbox } = sandboxFor('wasm4');
  let saved = { globals: { score: 0, lives: 3 }, memory: '', disk: '', diskSize: 0 };
  sandbox.window.FloeGame = {
    snapshot: () => ({ engine: 'wasm4', globals: { ...saved.globals } }),
    restore: (state) => { if (!state || !state.globals) return false; saved = { ...saved, globals: { ...state.globals } }; return true; }
  };
  loadHook(sandbox, 'wasm4');
  const D = sandbox.FloeDeveloper;
  const probe = await D.__exchange('probe', {});
  const score = probe.fields.find((field) => field.label === 'score');
  assert.ok(score && !score.isReadOnly, 'WASM-4 saved global is writable');
  const write = await D.__exchange('write', { changes: [{ id: score.id, value: 7 }] });
  assert.equal(write.status, 'applied');
  assert.equal(saved.globals.score, 7);
  assert.equal(write.state.values[score.id], 7);
  console.log('PASS WASM-4 saved globals: score write/read through snapshot restore');
}


async function testMainLoopActions(engine) {
  const { sandbox } = sandboxFor(engine);
  const calls = { pause: 0, resume: 0 };
  sandbox.window.Module = {
    floeCartStarted: true,
    pauseMainLoop: () => { calls.pause++; },
    resumeMainLoop: () => { calls.resume++; }
  };
  sandbox.window.FloeGame = { restart: () => {} };
  loadHook(sandbox, engine);
  const D = sandbox.FloeDeveloper;
  const probe = await D.__exchange('probe', {});
  assert.equal(probe.supports.pause, true, engine + ' pause capability');
  assert.equal(probe.supports.resume, true, engine + ' resume capability');
  const pause = await D.__exchange('invoke', { id: 'engine.pause', arguments: {} });
  assert.equal(pause.status, 'applied'); assert.equal(calls.pause, 1);
  const resume = await D.__exchange('invoke', { id: 'engine.resume', arguments: {} });
  assert.equal(resume.status, 'applied'); assert.equal(calls.resume, 1);
  const step = await D.__exchange('invoke', { id: 'engine.step', arguments: {} });
  assert.equal(step.status, 'applied');
  await new Promise((resolve) => setTimeout(resolve, 60));
  assert.ok(calls.pause >= 2 && calls.resume >= 2, engine + ' frame step uses real main loop');
  console.log('PASS ' + engine + ' main-loop pause/resume/step');
}

async function testRenpyPlayback() {
  const { sandbox } = sandboxFor('renpy');
  const events = [];
  const canvas = { style: {}, dispatchEvent: (event) => { events.push(event); return true; } };
  sandbox.document.activeElement = canvas;
  sandbox.document.documentElement = {};
  sandbox.document.getElementById = (id) => id === 'canvas' ? canvas : null;
  sandbox.KeyboardEvent = class {
    constructor(type, properties) { this.type = type; Object.assign(this, properties); }
  };
  sandbox.setInterval = () => 0;
  const timeout = sandbox.setTimeout;
  sandbox.setTimeout = (callback, ms) => ms >= 120000 ? 0 : timeout(callback, ms);
  const bridgePath = path.join(sdk, 'FloeGamePortableKit/Sources/FloeGamePortableKit/Resources/Overlays/renpy/floe_bridge.js');
  vm.runInContext(fs.readFileSync(bridgePath, 'utf8'), sandbox, { filename: bridgePath });
  loadHook(sandbox, 'renpy');
  const D = sandbox.FloeDeveloper;
  const probe = await D.__exchange('probe', {});
  for (const [id, code] of [
    ['story.advance', 'Enter'], ['story.rollback', 'PageUp'],
    ['story.rollForward', 'PageDown'], ['story.toggleSkip', 'Tab'],
    ['story.gameMenu', 'Escape'], ['story.toggleDialogue', 'KeyH']
  ]) {
    assert.ok(probe.actions.some((action) => action.id === id));
    const before = events.length;
    const result = await D.__exchange('invoke', { id, arguments: {} });
    assert.equal(result.status, 'applied');
    assert.equal(events.length, before + 2);
    assert.equal(events[before].type, 'keydown');
    assert.equal(events[before + 1].type, 'keyup');
    assert.equal(events[before].code, code);
    assert.equal(events[before + 1].code, code);
  }
  assert.equal(events.some((event) => event.code === 'ControlLeft'), false);
  console.log('PASS RenPy actual input bridge: dialogue, rollback, roll-forward, skip, menu and finite key release');
}

async function testInk() {
  const ink = require(path.join(fixtureRoot, 'NarrativeResources/inkjs/inkjs.js'));
  const source = 'VAR gold = 10\n-> start\n=== start ===\nGold: {gold}\n* [Add]\n    ~ gold = gold + 5\n    -> END\n';
  const story = new ink.Compiler(source).Compile();
  while (story.canContinue) story.Continue();
  const { sandbox } = sandboxFor('ink');
  sandbox.window.FloeInkRuntime = {
    story: () => story,
    choices: () => story.currentChoices || [],
    choose: (index) => {
      if (!Number.isInteger(index) || index < 0 || index >= (story.currentChoices || []).length) return false;
      story.ChooseChoiceIndex(index);
      while (story.canContinue) story.Continue();
      return true;
    },
    render: () => {},
    variables: () => {
      const result = {};
      const variables = story.variablesState._globalVariables || {};
      const names = variables instanceof Map ? Array.from(variables.keys()) : Object.keys(variables);
      names.slice(0, 48).forEach((name) => {
        const value = story.variablesState[name];
        if (['boolean', 'number', 'string'].includes(typeof value)) result[name] = value;
      });
      return result;
    },
    setVariable: (name, value) => {
      try { story.variablesState[name] = value; return true; } catch (error) { return false; }
    },
    jump: (target) => {
      try { story.ChoosePathString(target); while (story.canContinue) story.Continue(); return true; }
      catch (error) { return false; }
    }
  };
  loadHook(sandbox, 'ink');
  const D = sandbox.FloeDeveloper;
  const probe = await D.__exchange('probe', {});
  const goldField = probe.fields.find((field) => field.label === 'gold');
  assert.ok(goldField, 'actual inkjs variable registered');
  assert.equal(probe.actions.some((action) => action.id === 'story.jump'), true);
  const write = await D.__exchange('write', { changes: [{ id: goldField.id, value: 25 }] });
  assert.equal(write.status, 'applied');
  assert.equal(story.variablesState['gold'], 25);
  const jump = await D.__exchange('invoke', { id: 'story.jump', arguments: { path: 'start' } });
  assert.equal(jump.status, 'applied');
  const chooseCount = (story.currentChoices || []).length;
  assert.ok(chooseCount >= 1, 'actual inkjs choice is available');
  const choose = await D.__exchange('invoke', { id: 'story.choose', arguments: { index: 0 } });
  assert.equal(choose.status, 'applied');
  console.log('PASS actual inkjs 2.4.0: variable write/read-back, jump, choose');
}

async function testBabylon() {
  const B = require(path.join(fixtureRoot, 'StarterPacks/babylon-9.35.0/runtime/engine.js'));
  const engine = new B.NullEngine();
  const scene = new B.Scene(engine);
  const camera = new B.ArcRotateCamera('camera', -Math.PI / 2, 0.7, 9, new B.Vector3(4, 0, 2.4), scene);
  const renderLoop = () => {};
  const { sandbox } = sandboxFor('babylon');
  sandbox.window.FloeEngine = { BABYLON: B, engine, scene, camera, renderLoop };
  sandbox.window.FloeTemplate = { state: { x: 80, y: 200, score: 0 } };
  loadHook(sandbox, 'babylon');
  const D = sandbox.FloeDeveloper;
  const probe = await D.__exchange('probe', {});
  assert.ok(probe.fields.some((field) => field.id === 'camera.alpha'));
  assert.ok(probe.fields.some((field) => field.id === 'state.score'));
  const write = await D.__exchange('write', { changes: [{ id: 'camera.alpha', value: 1.234 }] });
  assert.equal(write.status, 'applied');
  assert.ok(Math.abs(camera.alpha - 1.234) < 0.0001);
  const jump = await D.__exchange('invoke', { id: 'camera.jump', arguments: { x: 1, y: 2, z: 3 } });
  assert.equal(jump.status, 'applied');
  assert.ok(Math.abs(camera.target.x - 1) < 0.0001);
  if (typeof engine.stopRenderLoop === 'function' && typeof engine.runRenderLoop === 'function') {
    const pause = await D.__exchange('invoke', { id: 'engine.pause', arguments: {} });
    assert.equal(pause.status, 'applied');
    const resume = await D.__exchange('invoke', { id: 'engine.resume', arguments: {} });
    assert.equal(resume.status, 'applied');
  }
  engine.dispose();
  console.log('PASS actual Babylon.js 9.35.0 NullEngine: camera write/read-back and jump');
}

try {
  await testHelper();
  await testPushBridge();
  await testImportedPhaserSnapshotFallback();
  await testMicroStudioNamedState();
  await testWasm4Globals();
  await testMainLoopActions('love');
  await testMainLoopActions('tic80');
  await testRenpyPlayback();
  await testInk();
  await testBabylon();
  console.log('ALL DEVELOPER JS CHECKS PASSED');
  process.exit(0);
} catch (error) {
  console.error('DEVELOPER JS CHECK FAILED');
  console.error(error && error.stack ? error.stack : error);
  process.exit(1);
}
