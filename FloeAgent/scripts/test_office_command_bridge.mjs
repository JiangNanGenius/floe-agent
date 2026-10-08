#!/usr/bin/env node
// Real JavaScript contract test for the Office command bridge.
//
// The bridge script is extracted from `OfficeCommandBridge.swift` (the exact
// string injected into the pinned engine web view) and evaluated against a
// mocked `window.app` map. This proves the dispatch/undo selection semantics
// without a device: step validation, partial-dispatch failure reporting,
// per-command undo issuance, and the opaque selection fingerprint shape.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, '..', 'FloeApp', 'Workspace', 'OfficeCommandBridge.swift'), 'utf8');
const match = source.match(/static let script = #"""\n([\s\S]*?)\n    """#/);
assert.ok(match, 'the bridge script must be extractable from OfficeCommandBridge.swift');
const script = match[1];

function makeWorld({ throwOnCommand = null, editMode = true, readOnly = false } = {}) {
  const calls = [];
  const events = new Map();
  let stateListener = null;
  const map = {
    sendUnoCommand(name, args) {
      calls.push({ name, args });
      if (throwOnCommand && name === throwOnCommand) throw new Error('engine refused ' + name);
      events.set(name, (events.get(name) || 0) + 1);
      if (stateListener) stateListener({ commandName: name, state: true });
    },
    isEditMode: () => editMode,
    setPart(index) { calls.push({ setPart: index }); },
    on(event, listener) { if (event === 'commandstatechanged') stateListener = listener; },
    off() {},
    dialog: { hasOpenedDialog: () => false },
  };
  const world = {
    window: {
      app: {
        map,
        file: { readOnly, textCursor: null },
        calc: null,
        socket: { sendMessage(payload) { calls.push({ socket: payload }); } },
      },
    },
  };
  world.window.app.definitions = {
    graphicSelection: { hasActiveSelection: () => false, getSelectionHandles: () => [] },
  };
  world.window.window = world.window;
  vm.createContext(world.window);
  vm.runInContext(script, world.window);
  return { window: world.window, calls, events };
}

function dispatch(window, commands) {
  return window.__floeOfficeCommandDispatch({ commands });
}

// 1. A valid batch dispatches every step in order through the engine APIs.
{
  const world = makeWorld();
  const result = dispatch(world.window, [
    { id: 'word.style', steps: [{ kind: 'uno', name: '.uno:StyleApply', arguments: { Style: { type: 'string', value: 'Heading 1' } } }] },
    { id: 'word.insertTable', steps: [{ kind: 'uno', name: '.uno:InsertTable', arguments: { Columns: { type: 'long', value: 2 } } }] },
  ]);
  assert.equal(result.ok, true);
  assert.equal(result.token, 1);
  assert.deepEqual(world.calls.map(call => call.name), ['.uno:StyleApply', '.uno:InsertTable']);
  assert.equal(world.calls[0].args.Style.value, 'Heading 1');
  const fresh = world.window.__floeOfficeCommandFreshState(result.token);
  assert.equal(fresh.fresh.slice().sort().join(','), '.uno:InsertTable,.uno:StyleApply');
}

// 2. Arbitrary/unknown step shapes are refused before any engine call.
{
  const world = makeWorld();
  const result = dispatch(world.window, [{ id: 'x', steps: [{ kind: 'eval', code: 'boom' }] }]);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'invalid-step');
  assert.equal(world.calls.length, 0);
}

// 3. A mid-batch engine refusal is reported as a failure (the Swift side then
// restores/undoes); earlier steps are visible, so the caller must not treat the
// partial dispatch as applied.
{
  const world = makeWorld({ throwOnCommand: '.uno:InsertTable' });
  const result = dispatch(world.window, [
    { id: 'a', steps: [{ kind: 'uno', name: '.uno:StyleApply', arguments: {} }] },
    { id: 'b', steps: [{ kind: 'uno', name: '.uno:InsertTable', arguments: {} }] },
  ]);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'dispatch-failed');
  assert.deepEqual(world.calls.map(call => call.name), ['.uno:StyleApply', '.uno:InsertTable']);
}

// 5. Read-only/not-ready sessions refuse dispatch; socket steps carry the
// pinned "uno …" payload; setPart selection is dispatched for slide reorder.
{
  const readOnlyWorld = makeWorld({ readOnly: true });
  assert.equal(dispatch(readOnlyWorld.window, [{ id: 'a', steps: [{ kind: 'uno', name: '.uno:Bold', arguments: {} }] }]).reason, 'read-only');

  const offWorld = makeWorld({ editMode: false });
  assert.equal(dispatch(offWorld.window, [{ id: 'a', steps: [{ kind: 'uno', name: '.uno:Bold', arguments: {} }] }]).reason, 'not-ready');

  const moveWorld = makeWorld();
  const move = dispatch(moveWorld.window, [{ id: 'pptx.moveSlide', steps: [
    { kind: 'socket', payload: 'uno .uno:DuplicatePage {"InsertPos":{"type":"int16","value":3}}' },
    { kind: 'selectPart', index: 0 },
    { kind: 'uno', name: '.uno:DeletePage', arguments: {} },
  ] }]);
  assert.equal(move.ok, true);
  assert.equal(moveWorld.calls[0].socket, 'uno .uno:DuplicatePage {"InsertPos":{"type":"int16","value":3}}');
  assert.equal(moveWorld.calls[1].setPart, 0);
  assert.equal(moveWorld.calls[2].name, '.uno:DeletePage');
  assert.equal(dispatch(moveWorld.window, [{ id: 'x', steps: [{ kind: 'socket', payload: 'windowkey id=1' }] }]).reason, 'invalid-step');
}

// 6. The selection fingerprint is an opaque shape and reports null safely when
// the engine exposes no stable selection identity.
{
  const world = makeWorld();
  assert.equal(world.window.__floeOfficeSelectionFingerprint(), null,
    'no active graphic selection and no cursor yields null');
  world.window.app.definitions.graphicSelection.hasActiveSelection = () => true;
  assert.equal(world.window.__floeOfficeSelectionFingerprint(), 'graphic:[]');
  world.window.app.definitions.graphicSelection.hasActiveSelection = () => false;
  world.window.app.file.textCursor = { rectangle: { x1: 1, y1: 2, x2: 3, y2: 4 } };
  assert.equal(world.window.__floeOfficeSelectionFingerprint(), 'cursor:1,2,3,4');
  world.window.app.file.textCursor = null;
  assert.equal(world.window.__floeOfficeSelectionFingerprint(), null);
}

console.log('test_office_command_bridge.mjs: all checks passed');
