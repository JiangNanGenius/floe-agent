#!/usr/bin/env node
// SPDX-License-Identifier: MPL-2.0
// Source-level interoperability checks for the generated project bridges.
// These consume the actual template/jslib/hook files; runtime limits are
// reported in HANDOFF.md and are not upgraded to engine execution claims.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.resolve(here, '..');
const next = path.resolve(packageRoot, '..', '..');
const project = path.join(packageRoot, 'Sources/FloeGameDeveloperCore/Resources/Project');
const hooks = path.join(packageRoot, '../FloeGameKit/Sources/FloeGameWebKit/Resources/Developer/Hooks');

function text(name, root = project) { return fs.readFileSync(path.join(root, name), 'utf8'); }
function check(name, callback) { callback(); console.log('PASS ' + name); }

check('Unity descriptor is valid JSON and matches publish keys', () => {
    const source = text('unity-floe-developer.cs');
    const block = source.match(/string descriptor = ([\s\S]*?);\s*\n\s*FloeDeveloperRegister/);
    assert.ok(block, 'descriptor concatenation found');
    const literals = [...block[1].matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((match) => JSON.parse('"' + match[1] + '"'));
    const descriptor = JSON.parse(literals.join(''));
    assert.equal(descriptor.runtime, 'Unity WebGL');
    assert.ok(descriptor.fields.every((field) => typeof field.id === 'string'));
    assert.ok(descriptor.fields.some((field) => field.id === 'engine.timescale'));
    assert.ok(descriptor.actions.some((action) => action.id === 'engine.pause'));
    assert.ok(source.includes('Registered = true'));
    const behaviour = text('unity-floe-developer-behaviour.cs');
    assert.ok(behaviour.includes('class FloeDeveloperBridgeBehaviour'));
    assert.ok(behaviour.includes('RuntimeInitializeOnLoadMethod'));
    assert.ok(behaviour.includes('instance = go.AddComponent<FloeDeveloperBridgeBehaviour>()'));
});

check('Unity jslib maps PublishState names to real field IDs', () => {
    const jslib = text('unity-floe-developer.jslib');
    const pushed = [];
    const sandbox = {
        LibraryManager: { library: {} },
        mergeInto: (library, methods) => Object.assign(library, methods),
        UTF8ToString: () => JSON.stringify({ scene_name: 'Main', paused: true, time_scale: 2, frames: 7 }),
        lengthBytesUTF8: (value) => Buffer.byteLength(value),
        stringToUTF8: () => {},
        _malloc: (size) => { sandbox.lastSize = size; return 1; },
        _free: () => {},
        window: { FloeDeveloper: {
            registerPushed: (descriptor) => { sandbox.registered = descriptor; },
            updatePushed: (values) => pushed.push(values),
            takeCommands: () => [{ id: 4, kind: 'action', action: 'engine.pause' }],
            ackCommand: (id, result) => { sandbox.ack = { id, result }; }
        } }
    };
    vm.createContext(sandbox);
    vm.runInContext(jslib, sandbox, { filename: 'unity-floe-developer.jslib' });
    sandbox.LibraryManager.library.FloeDeveloperPublish(1);
    assert.deepEqual(JSON.parse(JSON.stringify(pushed[0])), {
        'scene.name': 'Main', 'engine.paused': true, 'engine.timescale': 2, 'engine.frames': 7
    });
    sandbox.LibraryManager.library.FloeDeveloperAck(4, 0);
    assert.equal(sandbox.ack.id, 4);
    assert.equal(sandbox.ack.result.ok, false);
});

check('Godot autoload remains active while tree paused', () => {
    const source = text('godot-floe-developer.gd');
    assert.ok(source.includes('process_mode = Node.PROCESS_MODE_ALWAYS'));
    assert.ok(source.includes('get_tree().paused = true'));
    assert.ok(source.includes('get_tree().paused = false'));
    assert.ok(source.includes('ackCommand('));
    assert.ok(source.includes("'engine.timescale'"));
});

check('GDevelop uses RuntimeScene callbacks and real TimeManager setters', () => {
    const source = text('gdevelop-floe-developer.js');
    assert.ok(source.includes('callbacksRuntimeSceneLoaded'));
    assert.ok(!source.includes('onRuntimeSceneLoaded'));
    assert.ok(source.includes('getTimeScale'));
    assert.ok(source.includes('setTimeScale'));
    assert.ok(source.includes('getTimeFromStart'));
    assert.ok(source.includes('ackCommand(command.id, { ok: applied'));
    assert.ok(!source.includes('manager.timeScale'));
    const fixture = path.join(packageRoot, '../FloeGameGDevelopKit/Tests/FloeGameGDevelopKitTests/Fixtures/official-5.6.287-export/timemanager.js');
    const fixtureSource = fs.readFileSync(fixture, 'utf8');
    assert.ok(fixtureSource.includes('setTimeScale('));
    assert.ok(fixtureSource.includes('getTimeScale()'));
    const runtimeRoot = path.dirname(fixture);
    const commands = [], acknowledgements = [], published = [];
    let frame;
    const sandbox = {
        console, setTimeout, clearTimeout,
        setInterval: (callback) => { frame = callback; return 1; },
        gdjs: { callbacksRuntimeSceneLoaded: [], callbacksFirstRuntimeSceneLoaded: [] },
        FloeDeveloper: {
            registerPushed: (descriptor) => { sandbox.descriptor = descriptor; },
            updatePushed: (values) => published.push(values),
            takeCommands: () => commands.splice(0),
            ackCommand: (id, result) => acknowledgements.push({ id, ...result })
        }
    };
    sandbox.window = sandbox;
    vm.createContext(sandbox);
    for (const file of ['libs/jshashtable.js', 'timer.js', 'timemanager.js']) {
        vm.runInContext(fs.readFileSync(path.join(runtimeRoot, file), 'utf8'), sandbox, { filename: file });
    }
    vm.runInContext(source, sandbox, { filename: 'gdevelop-floe-developer.js' });
    const manager = new sandbox.gdjs.TimeManager();
    // Synthetic scene facade, actual pinned TimeManager/Timer/Hashtable.
    // No global RuntimeGame is exposed, matching the normal export route.
    const scene = { getName: () => 'Engine QA', getTimeManager: () => manager };
    sandbox.gdjs.callbacksRuntimeSceneLoaded.forEach((callback) => callback(scene));
    frame();
    assert.equal(published.at(-1)['scene.name'], 'Engine QA');
    commands.push({ id: 1, kind: 'set', field: 'scene.timescale', value: 2 });
    frame();
    manager.update(10, 60);
    assert.equal(manager.getTimeScale(), 2);
    assert.equal(manager.getElapsedTime(), 20);
    commands.push({ id: 2, kind: 'action', action: 'engine.pause' });
    frame();
    manager.update(10, 60);
    assert.equal(manager.getElapsedTime(), 0);
    commands.push({ id: 3, kind: 'action', action: 'engine.resume' });
    frame();
    manager.update(10, 60);
    assert.equal(manager.getElapsedTime(), 10);
    commands.push({ id: 4, kind: 'action', action: 'engine.setSpeed', arguments: { speed: 0 } });
    frame();
    assert.equal(manager.getTimeScale(), 0);
    commands.push({ id: 5, kind: 'action', action: 'unsupported.action' });
    frame();
    assert.equal(acknowledgements.at(-1).ok, false);
    assert.equal(acknowledgements.slice(0, 4).every((ack) => ack.ok), true);
});

check('Cocos component imports cc, persists and owns a scene-independent tick', () => {
    const source = text('cocos-floe-developer.ts');
    assert.ok(source.includes("from 'cc'"));
    assert.ok(source.includes('director.addPersistRootNode'));
    assert.ok(source.includes('setInterval'));
    assert.ok(source.includes('ackCommand(command.id, { ok: applied'));
    assert.ok(!source.includes('window.cc.director'));
    assert.ok(!source.includes('window.director'));
});

check('RenPy is narrowed to a registration API with no phantom publisher', () => {
    const source = text('renpy-floe-developer.rpy');
    assert.ok(source.includes('FloeDeveloperStore'));
    assert.ok(!source.includes('run_script'));
    assert.ok(!source.includes('registerPushed'));
});

check('LÖVE/TIC-80 hooks use actual Emscripten main-loop controls', () => {
    for (const engine of ['love', 'tic80']) {
        const source = text(engine + '.js', hooks);
        assert.ok(source.includes('pauseMainLoop'), engine + ' pause');
        assert.ok(source.includes('resumeMainLoop'), engine + ' resume');
        assert.ok(source.includes('engine.step'), engine + ' step');
    }
    const loveRuntime = fs.readFileSync(path.join(next, 'Fixtures/PortableResources/lovejs-11.4.1/runtime/compat/love.js'), 'utf8');
    assert.ok(loveRuntime.includes('Module["pauseMainLoop"]'));
    assert.ok(loveRuntime.includes('Module["resumeMainLoop"]'));
    const ticRuntime = fs.readFileSync(path.join(next, 'Fixtures/NarrativeResources/tic80/tic80.js'), 'utf8');
    assert.ok(ticRuntime.includes('pauseMainLoop'));
    assert.ok(ticRuntime.includes('resumeMainLoop'));
});

console.log('ALL PROJECT BRIDGE SOURCE CHECKS PASSED');
