// SPDX-License-Identifier: MPL-2.0
// Light algorithm tests for the static Online3DViewer adapter. They use the
// real pinned OV Camera/Model/Node types and a controlled renderer that returns
// synthetic PNG headers. They do NOT claim to prove actual WebGL pixels; the
// App-level WKWebView tests own that evidence.
import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import {readFileSync, existsSync} from 'node:fs';
import {fileURLToPath, pathToFileURL} from 'node:url';
import * as OV from 'online-3d-viewer';
import {createEngineeringStaticScene} from '../static-scene-entry.js';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

function controlledPNGDataURL(width, height, seed) {
  const bytes = Buffer.alloc(32);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(bytes, 0);
  bytes.writeUInt32BE(13, 8);
  bytes.write('IHDR', 12, 'ascii');
  bytes.writeUInt32BE(width, 16);
  bytes.writeUInt32BE(height, 20);
  bytes[24] = seed & 0x7f;
  bytes[25] = (seed >> 8) & 0x7f;
  return 'data:image/png;base64,' + bytes.toString('base64');
}

function makeModel() {
  const model = new OV.Model();
  const mesh = new OV.Mesh();
  mesh.SetName('Body');
  const meshIndex = model.AddMesh(mesh);
  const rootNode = model.GetRootNode();
  rootNode.SetName('Root');
  const group = new OV.Node();
  group.SetName('Group');
  group.AddMeshIndex(meshIndex);
  rootNode.AddChildNode(group);
  for (let index = 0; index < 3; index += 1) {
    const child = new OV.Node();
    child.SetName(`Part ${index}`);
    rootNode.AddChildNode(child);
  }
  return model;
}

function makeViewer({projection = OV.ProjectionMode.Perspective} = {}) {
  let camera = new OV.Camera(
    new OV.Coord3D(4, 3, 5), new OV.Coord3D(0, 0, 0), new OV.Coord3D(0, 1, 0), 45);
  let mode = projection;
  const calls = [];
  const viewer = {
    GetCamera() { return camera; },
    SetCamera(next) {
      calls.push(['camera', [next.eye.x, next.eye.y, next.eye.z],
        [next.center.x, next.center.y, next.center.z], next.fov]);
      camera = next;
    },
    GetProjectionMode() { return mode; },
    SetProjectionMode(next) {
      calls.push(['projection', next]);
      mode = next;
    },
    GetBoundingBox() {
      return {min: {x: -1, y: -1, z: -1}, max: {x: 1, y: 1, z: 1}};
    },
    GetBoundingSphere() {
      return {center: {x: 0, y: 0, z: 0}, radius: Math.sqrt(3)};
    },
    Render() { calls.push(['render']); },
    FitSphereToWindow() { calls.push(['fit']); },
    GetImageAsDataUrl(width, height) {
      calls.push(['image', width, height]);
      return controlledPNGDataURL(width, height, calls.length);
    },
  };
  return {viewer, calls, getCamera: () => camera, getMode: () => mode};
}

function makeController(options = {}) {
  const model = makeModel();
  const fake = makeViewer(options);
  const states = [];
  const controller = createEngineeringStaticScene({
    OV,
    viewer: fake.viewer,
    model,
    package: {
      name: 'part.stl',
      provenance: {sourceSHA256: 'a'.repeat(64)},
      missingReferences: [],
      diagnostics: {},
    },
    backend: 'online3DViewer',
    onState: (state) => states.push(state),
  });
  return {controller, fake, states, model};
}

test('static state preserves actual imported nodes, instances, counts and bounds', () => {
  const {controller, states} = makeController();
  const state = JSON.parse(controller.state());
  assert.equal(state.backend, 'online3DViewer');
  assert.equal(state.nodeCount, 5);
  assert.equal(state.meshCount, 1);
  assert.equal(state.instancedMeshCount, 1);
  assert.equal(state.materialCount, 0);
  assert.equal(state.textureCount, 0);
  assert.deepEqual(state.clips, []);
  assert.deepEqual(state.cameras, []);
  assert.equal(state.activeSceneIndex, 0);
  assert.ok(state.bounds && state.bounds.radius > 0);
  assert.equal(state.nodes.length, 5);
  assert.equal(state.truncatedNodes, false);
  assert.equal(states.length, 0);
});

test('static hierarchy is fully pageable with stable scene-local paths', () => {
  const {controller} = makeController();
  const page = JSON.parse(controller.command({action: 'hierarchy', offset: 1, limit: 2}));
  assert.equal(page.total, 5);
  assert.equal(page.offset, 1);
  assert.equal(page.sceneIndex, 0);
  assert.equal(page.nodes.length, 2);
  assert.equal(page.nextOffset, 3);
  assert.equal(new Set(page.nodes.map((node) => node.path)).size, 2);
  assert.ok(page.nodes.every((node) => node.path.startsWith('scene0/node')));
  assert.ok(page.nodes.every((node) => !/^face:|^edge:|^body:/.test(node.path)));
  const tail = JSON.parse(controller.command({action: 'hierarchy', offset: 3, limit: 10}));
  assert.equal(tail.nodes.length, 2);
  assert.equal(tail.nextOffset, null);
});

test('static commands refuse scene/camera/clip/playback authority', () => {
  const {controller} = makeController();
  assert.throws(() => controller.command({action: 'scene', index: 1}), /one display scene/);
  assert.doesNotThrow(() => controller.command({action: 'scene', index: 0}));
  assert.throws(() => controller.command({action: 'camera', index: 0}), /no source scene cameras/);
  assert.throws(() => controller.command({action: 'clip', index: 0}), /no animation clips/);
  assert.throws(() => controller.command({action: 'play'}), /no animation playback/);
  assert.throws(() => controller.command({action: 'nodeVisibility', path: 'x', visible: false}), /not exposed/);
});

test('static capture applies the requested projection and restores order and camera exactly', () => {
  const {controller, fake} = makeController();
  const before = controller.cameraSnapshot();
  assert.equal(before.projection, 'perspective');
  const result = JSON.parse(controller.capture({
    views: [
      {azimuthDegrees: 35, elevationDegrees: 20},
      {azimuthDegrees: 215, elevationDegrees: 20},
    ],
    width: 320,
    height: 240,
    projection: 'orthographic',
    maximumPNGBytes: 1024 * 1024,
    maximumTotalBytes: 4 * 1024 * 1024,
  }));
  assert.equal(result.frames.length, 2);
  for (const frame of result.frames) {
    assert.equal(frame.projection, 'orthographic');
    assert.equal(frame.renderer, 'online3DViewer');
    assert.equal(frame.width, 320);
    assert.equal(frame.height, 240);
    assert.equal(frame.sourceSHA256, 'a'.repeat(64));
  }
  assert.notEqual(result.frames[0].dataURL, result.frames[1].dataURL);
  assert.deepEqual(controller.cameraSnapshot(), before);
  const projectionCalls = fake.calls.filter((call) => call[0] === 'projection')
    .map((call) => call[1]);
  assert.deepEqual(projectionCalls,
    [OV.ProjectionMode.Orthographic, OV.ProjectionMode.Perspective]);
  const cameraCalls = fake.calls.filter((call) => call[0] === 'camera');
  assert.ok(cameraCalls.length >= 3);
  assert.deepEqual(cameraCalls.at(-1)[1], before.eye);
  assert.equal(fake.getMode(), OV.ProjectionMode.Perspective);
});

test('omitted projection keeps the live orthographic camera type', () => {
  const {controller, fake} = makeController({projection: OV.ProjectionMode.Orthographic});
  const before = controller.cameraSnapshot();
  const result = JSON.parse(controller.capture({
    views: [{azimuthDegrees: 0, elevationDegrees: 10}],
    width: 128,
    height: 96,
  }));
  assert.equal(result.frames.length, 1);
  assert.equal(result.frames[0].projection, 'orthographic');
  assert.equal(result.frames[0].width, 128);
  assert.equal(result.frames[0].height, 96);
  assert.equal(fake.calls.filter((call) => call[0] === 'projection').length, 0);
  assert.deepEqual(controller.cameraSnapshot(), before);
});

test('camera restoration failure discards already rendered frames', () => {
  const {controller, fake} = makeController();
  const before = controller.cameraSnapshot();
  const setCamera = fake.viewer.SetCamera;
  fake.viewer.SetCamera = (next) => {
    if (next.eye.x === before.eye[0] && next.eye.y === before.eye[1]
        && next.eye.z === before.eye[2]) {
      throw new Error('injected restoration failure');
    }
    setCamera(next);
  };
  const result = JSON.parse(controller.capture({
    views: [{azimuthDegrees: 35, elevationDegrees: 20}],
    width: 320, height: 240, projection: 'orthographic',
  }));
  assert.equal(fake.calls.filter((call) => call[0] === 'image').length, 1);
  assert.deepEqual(result.frames, []);
  assert.ok(result.failures.some((failure) =>
    /view.*restored.*discarded.*injected restoration failure/.test(failure.reason)));
});

test('static capture reports unsupported clip/time/projection instead of a first frame', () => {
  const {controller} = makeController();
  const views = [{azimuthDegrees: 0, elevationDegrees: 10}];
  for (const [extra, pattern] of [
    [{clipIndex: 0}, /animation clips/],
    [{timeSeconds: 2}, /timeline/],
    [{projection: 'isometric'}, /unsupported projection/],
  ]) {
    const result = JSON.parse(controller.capture({views, width: 128, height: 96, ...extra}));
    assert.equal(result.frames.length, 0);
    assert.match(result.failures[0].reason, pattern);
  }
});

test('the built static bundle is an importable local ESM with no remote source', async () => {
  const resources = path.resolve(root, '../../FloeApp/Resources/EngineeringViewers');
  assert.ok(existsSync(path.join(resources, 'static-scene.js')));
  const module = await import(pathToFileURL(path.join(resources, 'static-scene.js')).href);
  assert.equal(typeof module.createEngineeringStaticScene, 'function');
  const viewer = readFileSync(path.join(resources, 'viewer.js'), 'utf8');
  assert.ok(viewer.includes("import('./static-scene.js')"));
  assert.ok(viewer.includes('floeEngineeringSceneCapture'));
  assert.ok(viewer.includes('online3DViewer'));
  const source = readFileSync(path.join(root, 'static-scene-entry.js'), 'utf8');
  assert.ok(!/https?:\/\//.test(source));
  const html = readFileSync(path.join(resources, 'index.html'), 'utf8');
  assert.ok(html.includes("default-src 'none'"));
});
