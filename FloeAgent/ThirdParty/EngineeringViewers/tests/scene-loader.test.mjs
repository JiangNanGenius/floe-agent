// SPDX-License-Identifier: MPL-2.0
// Light behavior fixtures for the bundled local glTF/GLB viewer path. These
// exercise the real three.js r176 GLTFLoader parse pipeline (hierarchy, skin,
// morph, sparse accessors, three interpolation kinds and cameras) without a
// WebGL context. Rendering/decoder playback remains a device qualification.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, existsSync} from 'node:fs';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import * as THREE from 'three';
import {GLTFLoader} from 'three/examples/jsm/loaders/GLTFLoader.js';

if (typeof globalThis.self === 'undefined') globalThis.self = globalThis;
if (typeof globalThis.ProgressEvent === 'undefined') {
  globalThis.ProgressEvent = class ProgressEvent extends Event {
    constructor(type, init = {}) {
      super(type);
      this.lengthComputable = !!init.lengthComputable;
      this.loaded = init.loaded || 0;
      this.total = init.total || 0;
    }
  };
}

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const resources = path.resolve(root, '../../FloeApp/Resources/EngineeringViewers');
const align4 = value => (value + 3) & ~3;

function makeFixture() {
  const chunks = [];
  let offset = 0;
  const add = (typed) => {
    const bytes = new Uint8Array(typed.buffer, typed.byteOffset, typed.byteLength);
    const start = align4(offset);
    if (start > offset) chunks.push(new Uint8Array(start - offset));
    chunks.push(bytes);
    offset = start + bytes.length;
    return {byteOffset: start, byteLength: bytes.length};
  };
  const pos = add(new Float32Array([0, 0, 0, 1, 0, 0, 0, 1, 0]));
  const nor = add(new Float32Array([0, 0, 1, 0, 0, 1, 0, 0, 1]));
  const idx = add(new Uint16Array([0, 1, 2]));
  const joints = add(new Uint8Array([0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0]));
  const weights = add(new Float32Array([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]));
  const ibm = add(new Float32Array([
    1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
    1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1,
    1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1
  ]));
  const times = add(new Float32Array([0, 1]));
  const translation = add(new Float32Array([0, 0, 0, 1, 0, 0]));
  const rotation = add(new Float32Array([0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]));
  const scale = add(new Float32Array([1, 1, 1, 2, 2, 2]));
  const morph = add(new Float32Array([0, 0, 0, 0, 0.1, 0, 0, 0, 0]));
  const sparseBase = add(new Float32Array([0, 0, 0, 0, 0, 0, 0, 0, 0]));
  const sparseIndices = add(new Uint16Array([1]));
  const sparseValues = add(new Float32Array([0, 1, 0]));
  const total = align4(offset);
  const buffer = Buffer.concat(chunks.map(chunk => Buffer.from(chunk)), total).subarray(0, total);
  const view = (segment, target) => ({
    buffer: 0, byteOffset: segment.byteOffset, byteLength: segment.byteLength,
    ...(target ? {target} : {})
  });
  const gltf = {
    asset: {version: '2.0', generator: 'floe-viewer-fixture'},
    scene: 0,
    scenes: [{nodes: [0]}],
    nodes: [
      {name: 'Root', children: [1, 2, 3, 4, 5, 6]},
      {name: 'Body', mesh: 0, skin: 0},
      {name: 'Joint1', children: [3]},
      {name: 'Joint2'},
      {name: 'Joint3'},
      {name: 'Camera', camera: 0, translation: [3, 3, 3]},
      {name: 'SparsePatch', mesh: 1}
    ],
    cameras: [{name: 'Inspection Camera', type: 'perspective',
      perspective: {yfov: 0.7, znear: 0.01, zfar: 100, aspectRatio: 1.5}}],
    meshes: [
      {name: 'MorphBody', primitives: [{
        attributes: {POSITION: 0, NORMAL: 1, JOINTS_0: 3, WEIGHTS_0: 4},
        indices: 2, material: 0, targets: [{POSITION: 10}]
      }]},
      {name: 'SparsePatch', primitives: [{attributes: {POSITION: 11}, material: 0}]}
    ],
    materials: [{name: 'Blue', pbrMetallicRoughness: {
      baseColorFactor: [0.2, 0.5, 0.9, 1], metallicFactor: 0.2, roughnessFactor: 0.6
    }}],
    skins: [{name: 'Rig', inverseBindMatrices: 5, joints: [2, 3, 4]}],
    animations: [
      {name: 'Slide', samplers: [{input: 6, output: 7, interpolation: 'LINEAR'}],
        channels: [{sampler: 0, target: {node: 1, path: 'translation'}}]},
      {name: 'ScaleStep', samplers: [{input: 6, output: 9, interpolation: 'STEP'}],
        channels: [{sampler: 0, target: {node: 1, path: 'scale'}}]},
      {name: 'TurnCubic', samplers: [{input: 6, output: 8, interpolation: 'CUBICSPLINE'}],
        channels: [{sampler: 0, target: {node: 1, path: 'rotation'}}]}
    ],
    accessors: [
      {bufferView: 0, componentType: 5126, count: 3, type: 'VEC3', min: [0, 0, 0], max: [1, 1, 0]},
      {bufferView: 1, componentType: 5126, count: 3, type: 'VEC3'},
      {bufferView: 2, componentType: 5123, count: 3, type: 'SCALAR'},
      {bufferView: 3, componentType: 5121, count: 3, type: 'VEC4'},
      {bufferView: 4, componentType: 5126, count: 3, type: 'VEC4'},
      {bufferView: 5, componentType: 5126, count: 3, type: 'MAT4'},
      {bufferView: 6, componentType: 5126, count: 2, type: 'SCALAR', min: [0], max: [1]},
      {bufferView: 7, componentType: 5126, count: 2, type: 'VEC3'},
      {bufferView: 8, componentType: 5126, count: 6, type: 'VEC4'},
      {bufferView: 9, componentType: 5126, count: 2, type: 'VEC3'},
      {bufferView: 10, componentType: 5126, count: 3, type: 'VEC3', min: [0, 0, 0], max: [0, 0.1, 0]},
      {bufferView: 11, componentType: 5126, count: 3, type: 'VEC3', min: [0, 0, 0], max: [1, 1, 0],
        sparse: {count: 1, indices: {bufferView: 12, componentType: 5123},
          values: {bufferView: 13}}}
    ],
    bufferViews: [
      view(pos, 34962), view(nor, 34962), view(idx), view(joints), view(weights),
      view(ibm), view(times), view(translation), view(rotation), view(scale),
      view(morph), view(sparseBase), view(sparseIndices), view(sparseValues)
    ],
    buffers: [{byteLength: buffer.length,
      uri: 'data:application/octet-stream;base64,' + buffer.toString('base64')}]
  };
  return {gltf, buffer};
}

function toGLB(gltf, buffer) {
  const json = {...gltf, buffers: [{byteLength: buffer.length}]};
  const jsonBytes = Buffer.from(JSON.stringify(json));
  const jsonPadded = Buffer.alloc(align4(jsonBytes.length), 0x20);
  jsonBytes.copy(jsonPadded);
  const binPadded = Buffer.alloc(align4(buffer.length), 0);
  buffer.copy(binPadded);
  const total = 12 + 8 + jsonPadded.length + 8 + binPadded.length;
  const header = Buffer.alloc(12);
  header.write('glTF', 0, 'ascii');
  header.writeUInt32LE(2, 4);
  header.writeUInt32LE(total, 8);
  const jsonHeader = Buffer.alloc(8);
  jsonHeader.writeUInt32LE(jsonPadded.length, 0);
  jsonHeader.writeUInt32LE(0x4E4F534A, 4);
  const binHeader = Buffer.alloc(8);
  binHeader.writeUInt32LE(binPadded.length, 0);
  binHeader.writeUInt32LE(0x004E4942, 4);
  return new Uint8Array(Buffer.concat([header, jsonHeader, jsonPadded, binHeader, binPadded]));
}

async function parseFixture(payload) {
  const gltf = await new GLTFLoader().parseAsync(payload, '');
  let meshes = 0;
  let skinned = 0;
  let morph = 0;
  let sparseY = null;
  gltf.scene.traverse((object) => {
    if (!object.isMesh) return;
    meshes += 1;
    if (object.isSkinnedMesh) skinned += 1;
    if (object.morphTargetInfluences?.length) morph += 1;
    if (!object.isSkinnedMesh && object.geometry?.attributes?.position) {
      sparseY = object.geometry.attributes.position.getY(1);
    }
  });
  return {gltf, meshes, skinned, morph, sparseY};
}

test('three GLTFLoader parses hierarchy, skin, morph, cameras and animation interpolation', async () => {
  const {gltf, buffer} = makeFixture();
  const json = await parseFixture(JSON.stringify(gltf));
  const binary = await parseFixture(toGLB(gltf, buffer).buffer);
  for (const parsed of [json, binary]) {
    assert.equal(parsed.gltf.scenes.length, 1);
    assert.equal(parsed.gltf.cameras.length, 1);
    assert.equal(parsed.gltf.cameras[0].name, 'Camera');
    assert.equal(parsed.meshes, 2);
    assert.equal(parsed.skinned, 1);
    assert.equal(parsed.morph, 1);
    assert.equal(parsed.sparseY, 1);
    assert.deepEqual(parsed.gltf.animations.map(clip => clip.name).sort(),
      ['ScaleStep', 'Slide', 'TurnCubic']);
    assert.equal(parsed.gltf.animations.length, 3);
    const interpolation = parsed.gltf.parser.json.animations
      .map(animation => animation.samplers[0].interpolation).sort();
    assert.deepEqual(interpolation, ['CUBICSPLINE', 'LINEAR', 'STEP']);
  }
  const rootNode = json.gltf.scene.getObjectByName('Root');
  assert.ok(rootNode);
  assert.equal(rootNode.children.length, 6);
});

test('GLTFLoader keeps separately named scenes and scene-local placement', async () => {
  const {gltf} = makeFixture();
  gltf.nodes.push({name: 'AlternativeRoot', mesh: 1, translation: [10, 0, 0]});
  gltf.scenes = [{name: 'Assembly', nodes: [0]}, {name: 'Alternative', nodes: [7]}];
  const loaded = await new GLTFLoader().parseAsync(JSON.stringify(gltf), '');
  assert.deepEqual(loaded.scenes.map(item => item.name), ['Assembly', 'Alternative']);
  const alternative = loaded.scenes[1].getObjectByName('AlternativeRoot');
  assert.ok(alternative);
  assert.equal(alternative.position.x, 10);
  assert.equal(loaded.scenes[0].getObjectByName('AlternativeRoot'), undefined);
  assert.equal(loaded.animations.length, 3);
});

test('bundled decoder inventory is local, hashed and licensed', () => {
  const bom = JSON.parse(readFileSync(path.join(resources, 'DECODER_BOM.json'), 'utf8'));
  const hash = file => createHash('sha256').update(readFileSync(path.join(resources, file))).digest('hex');
  for (const [file, digest] of Object.entries(bom.sha256)) {
    assert.equal(hash(file), digest, file);
  }
  assert.equal(hash('scene.js'), bom.sceneBundleSHA256);
  for (const file of ['draco_decoder.wasm', 'basis_transcoder.wasm']) {
    assert.ok(readFileSync(path.join(resources, file)).subarray(0, 4).equals(Buffer.from([0, 0x61, 0x73, 0x6d])));
  }
  for (const file of ['license.draco.txt', 'license.basis-transcoder.txt',
    'license.meshopt.txt', 'license.ktx-parse.txt', 'license.zstddec.txt']) {
    assert.ok(existsSync(path.join(resources, file)), file);
  }
  const scene = readFileSync(path.join(resources, 'scene.js'), 'utf8');
  for (const token of ['KTX2Loader', 'DRACOLoader', 'MeshoptDecoder', 'GLTFLoader']) {
    assert.ok(scene.includes(token), token);
  }
  const index = readFileSync(path.join(resources, 'index.html'), 'utf8');
  assert.ok(index.includes("default-src 'none'"));
  assert.ok(!index.includes('https://') && !index.includes('http://'));
});

test('built scene bundle is importable local ESM', async () => {
  const module = await import(pathToFileURL(path.join(resources, 'scene.js')).href);
  assert.equal(typeof module.createEngineeringScene, 'function');
});

test('scene URL modifier allows only same-origin bundled decoder assets', async () => {
  const module = await import(pathToFileURL(path.join(resources, 'scene.js')).href);
  const previous = globalThis.location;
  globalThis.location = {
    href: 'http://127.0.0.1:8765/index.html',
    origin: 'http://127.0.0.1:8765'
  };
  try {
    // The decoder loaders use the same LoadingManager as model resources; a
    // blanket external-URL block would replace these with a placeholder PNG
    // and break Draco/KTX2 without any explicit error.
    assert.equal(module.bundledDecoderURL('./basis_transcoder.js'),
      'http://127.0.0.1:8765/basis_transcoder.js');
    assert.equal(module.bundledDecoderURL('./draco_decoder.wasm'),
      'http://127.0.0.1:8765/draco_decoder.wasm');
    assert.equal(module.bundledDecoderURL('basis_transcoder.js'),
      'http://127.0.0.1:8765/basis_transcoder.js');
    assert.equal(module.bundledDecoderURL('https://example.com/basis_transcoder.js'), null);
    assert.equal(module.bundledDecoderURL('textures/quadrants.png'), null);
    assert.equal(module.bundledDecoderURL('data:image/png;base64,AA'), null);
  } finally {
    if (previous === undefined) delete globalThis.location;
    else globalThis.location = previous;
  }
});

test('viewer static source never adds a remote scene fetch', () => {
  const viewer = readFileSync(path.join(resources, 'viewer.js'), 'utf8');
  assert.ok(viewer.includes("import('./scene.js')"));
  assert.ok(viewer.includes('floeEngineeringSceneCommand'));
  assert.ok(viewer.includes('floeEngineeringSceneCapture'));
  const entry = readFileSync(path.join(root, 'scene-entry.js'), 'utf8');
  assert.ok(!/https?:\/\//.test(entry));
  assert.ok(entry.includes('setURLModifier'));
  assert.ok(entry.includes('TRANSPARENT_PIXEL'));
});
