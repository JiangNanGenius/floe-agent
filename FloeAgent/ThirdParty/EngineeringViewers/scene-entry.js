// SPDX-License-Identifier: MPL-2.0
// Local-only glTF/GLB scene viewer. three.js r176 and all decoders are bundled
// by build.mjs into scene.js or copied beside it; there is no CDN/remote URL.
import * as THREE from 'three';
import {GLTFLoader} from 'three/examples/jsm/loaders/GLTFLoader.js';
import {DRACOLoader} from 'three/examples/jsm/loaders/DRACOLoader.js';
import {KTX2Loader} from 'three/examples/jsm/loaders/KTX2Loader.js';
import {MeshoptDecoder} from 'three/examples/jsm/libs/meshopt_decoder.module.js';
import {OrbitControls} from 'three/examples/jsm/controls/OrbitControls.js';
import {RoomEnvironment} from 'three/examples/jsm/environments/RoomEnvironment.js';

const MAX_NODES = 200;
const MAX_CAPTURE_FRAMES = 8;
const TRANSPARENT_PIXEL = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
const PNG_PREFIX = 'data:image/png;base64,';

function decodeBytes(file) {
  const binary = atob(file.base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function normalizeReference(value) {
  try {
    return decodeURIComponent(String(value).split('?')[0]).replace(/^\.\//, '');
  } catch {
    return String(value).split('?')[0].replace(/^\.\//, '');
  }
}

function clamp(value, minimum, maximum) {
  return Math.min(Math.max(value, minimum), maximum);
}

// The bundled Draco and KTX2/Basis decoders are loaded through the SAME
// LoadingManager as model resources. Treat only the exact same-origin local
// decoder files as loader infrastructure so the block-external-resources
// rule below cannot turn them into an inert placeholder image. Model
// resources registered from the package are checked first.
const BUNDLED_DECODER_FILES = new Set([
  'draco_decoder.js', 'draco_decoder.wasm', 'draco_wasm_wrapper.js',
  'basis_transcoder.js', 'basis_transcoder.wasm'
]);

export function bundledDecoderURL(value) {
  try {
    const resolved = new URL(String(value), location.href);
    if (resolved.origin !== location.origin) return null;
    const name = resolved.pathname.split('/').pop();
    return BUNDLED_DECODER_FILES.has(name) ? resolved.href : null;
  } catch {
    return null;
  }
}

// Report the PNG dimensions that were actually produced instead of copying the
// requested width/height into the frame metadata.
function pngDimensions(dataURL) {
  if (typeof dataURL !== 'string' || !dataURL.startsWith(PNG_PREFIX)) return null;
  let binary;
  try {
    // Only the 24-byte PNG signature/IHDR prefix is needed; do not decode the
    // whole (possibly multi-megabyte) frame just to read its dimensions.
    const payload = dataURL.slice(PNG_PREFIX.length);
    binary = atob(payload.slice(0, Math.min(payload.length, 64)));
  } catch {
    return null;
  }
  if (binary.length < 24) return null;
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  for (let index = 0; index < signature.length; index += 1) {
    if (binary.charCodeAt(index) !== signature[index]) return null;
  }
  if (binary.charCodeAt(12) !== 0x49 || binary.charCodeAt(13) !== 0x48
      || binary.charCodeAt(14) !== 0x44 || binary.charCodeAt(15) !== 0x52) return null;
  const readUInt32 = (offset) => (
    (binary.charCodeAt(offset) << 24)
    | (binary.charCodeAt(offset + 1) << 16)
    | (binary.charCodeAt(offset + 2) << 8)
    | binary.charCodeAt(offset + 3)
  ) >>> 0;
  const width = readUInt32(16);
  const height = readUInt32(20);
  return width > 0 && height > 0 ? {width, height} : null;
}

export function createEngineeringScene({container, package: pkg, config = {}, say, onState, onProgress, onReady, onError}) {
  const scene = new THREE.Scene();
  const host = document.createElement('div');
  host.style.cssText = 'position:relative;width:100%;height:100%;min-height:1px;';
  container.append(host);
  const widthNow = () => Math.max(1, host.clientWidth || container.clientWidth || 1);
  const heightNow = () => Math.max(1, host.clientHeight || container.clientHeight || 1);

  let renderer;
  try {
    renderer = new THREE.WebGLRenderer({antialias: true, alpha: false, preserveDrawingBuffer: true});
  } catch (error) {
    host.remove();
    throw new Error(say
      ? say('此设备无法创建 WebGL 场景。', 'This device could not create a WebGL scene.')
      : String(error?.message ?? error));
  }
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.setSize(widthNow(), heightNow(), false);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1;
  renderer.domElement.style.cssText = 'display:block;width:100%;height:100%;touch-action:none;';
  scene.background = new THREE.Color(config.dark ? 0x181e28 : 0xf5f6f8);
  host.append(renderer.domElement);

  const pmrem = new THREE.PMREMGenerator(renderer);
  let environmentTarget = null;
  try {
    environmentTarget = pmrem.fromScene(new RoomEnvironment(), 0.04);
    scene.environment = environmentTarget.texture;
  } catch {
    // Lighting still works from the explicit lights below; the environment is
    // an appearance improvement, not a correctness requirement.
  }
  const ambient = new THREE.HemisphereLight(0xffffff, 0x444a55, 1.25);
  ambient.name = 'Floe Hemisphere';
  scene.add(ambient);
  const key = new THREE.DirectionalLight(0xffffff, 1.5);
  key.position.set(4, 8, 6);
  key.name = 'Floe Key';
  scene.add(key);
  const fill = new THREE.DirectionalLight(0xffffff, 0.5);
  fill.position.set(-6, -2, -4);
  fill.name = 'Floe Fill';
  scene.add(fill);

  const freeCamera = new THREE.PerspectiveCamera(45, widthNow() / heightNow(), 0.001, 100_000);
  freeCamera.position.set(3, 3, 5);
  let camera = freeCamera;
  let controls = new OrbitControls(camera, renderer.domElement);
  controls.enableDamping = true;
  controls.dampingFactor = 0.08;
  controls.screenSpacePanning = false;
  controls.addEventListener('change', () => scheduleRender());

  const manager = new THREE.LoadingManager();
  const objectURLs = [];
  const resourceMap = new Map();
  const blockedReferences = new Set();
  const failedReferences = new Set();
  const main = pkg.files?.[0];
  if (!main) throw new Error(say ? say('文件为空', 'No file') : 'No file');
  const mainName = main.name;
  const mainDirectory = mainName.includes('/') ? mainName.slice(0, mainName.lastIndexOf('/') + 1) : '';
  function registerResource(name, url) {
    resourceMap.set(name, url);
    resourceMap.set(encodeURI(name), url);
    if (mainDirectory && name.startsWith(mainDirectory)) {
      const relative = name.slice(mainDirectory.length);
      if (!resourceMap.has(relative)) resourceMap.set(relative, url);
      resourceMap.set(encodeURI(relative), url);
    }
    const base = name.split('/').pop();
    if (base && !resourceMap.has(base)) resourceMap.set(base, url);
  }
  for (const file of pkg.files.slice(1)) {
    const url = URL.createObjectURL(new Blob([decodeBytes(file)], {type: 'application/octet-stream'}));
    objectURLs.push(url);
    registerResource(file.name, url);
  }
  manager.setURLModifier((url) => {
    if (!url) return url;
    if (url.startsWith('data:') || url.startsWith('blob:')) return url;
    const normalized = normalizeReference(url);
    const mapped = resourceMap.get(url) || resourceMap.get(normalized);
    if (mapped) return mapped;
    const decoder = bundledDecoderURL(url);
    if (decoder) return decoder;
    // Do NOT let three resolve an external/remote URI. Return a local inert
    // data URL and keep the exact reference for the diagnostics contract.
    blockedReferences.add(normalized);
    return TRANSPARENT_PIXEL;
  });
  manager.onError = (url) => {
    // A decoder asset is loader infrastructure, not a missing model
    // resource: let the scene load fail explicitly instead of reporting a
    // model texture/buffer as missing.
    if (bundledDecoderURL(url)) {
      publish(true);
      return;
    }
    const normalized = normalizeReference(url);
    if (!/^(data|blob):/i.test(normalized)) failedReferences.add(normalized);
    publish(true);
  };

  const loader = new GLTFLoader(manager);
  const draco = new DRACOLoader(manager).setDecoderPath('./');
  draco.setDecoderConfig({type: 'wasm'});
  loader.setDRACOLoader(draco);
  let ktx2 = null;
  try {
    ktx2 = new KTX2Loader(manager).setTranscoderPath('./').detectSupport(renderer);
    // r176's pool handles message replies only. A worker startup/decoding
    // exception otherwise leaves its texture promise pending until the page
    // times out, hiding the real failure from the native error bridge.
    const pool = ktx2.workerPool;
    const setCreator = pool.setWorkerCreator.bind(pool);
    pool.setWorkerCreator = (factory) => setCreator(() => {
      const worker = factory();
      const report = (message) => {
        if (!disposed) onError?.(new Error(`Texture decoder: ${message}`));
      };
      worker.addEventListener('error', (event) => report(event.message || 'worker failed'), {once: true});
      worker.addEventListener('messageerror', () => report('invalid worker response'), {once: true});
      return worker;
    });
    loader.setKTX2Loader(ktx2);
  } catch {
    ktx2 = null;
  }
  loader.setMeshoptDecoder(MeshoptDecoder);

  let model = null;
  let modelScenes = [];
  let activeSceneIndex = 0;
  let loadedAsset = null;
  let animations = [];
  let mixer = null;
  let activeAction = null;
  let activeClipIndex = null;
  let playing = false;
  let loopMode = 'repeat';
  let speed = 1;
  let disposed = false;
  let ready = false;
  let lastPublish = 0;
  let raf = 0;
  let timeSeconds = 0;
  let durationSeconds = 0;
  let nodeObjects = new Map();
  let nodeList = [];
  let nodeListTruncated = false;
  let totalNodeCount = 0;
  let bounds = null;
  let boundingSphere = null;
  let lastFrame = performance.now();
  let missing = [];
  let unsupported = [];
  let runtimeWarnings = [];
  let cameraEntries = [];
  let animationMeta = [];
  let activeCameraIndex = null;
  let needsRender = true;

  const clock = new THREE.Clock();
  const resizeObserver = new ResizeObserver(() => resize());
  resizeObserver.observe(host);

  function scheduleRender() {
    if (!disposed) needsRender = true;
  }

  function resize() {
    if (disposed) return;
    const width = widthNow();
    const height = heightNow();
    renderer.setSize(width, height, false);
    const aspect = width / height;
    if (camera.isPerspectiveCamera) {
      camera.aspect = aspect;
      camera.updateProjectionMatrix();
    } else if (camera.isOrthographicCamera) {
      const heightSize = camera.top - camera.bottom;
      const center = (camera.top + camera.bottom) / 2;
      camera.left = -heightSize * aspect / 2;
      camera.right = heightSize * aspect / 2;
      camera.top = center + heightSize / 2;
      camera.bottom = center - heightSize / 2;
      camera.updateProjectionMatrix();
    }
    renderer.render(scene, camera);
  }

  function computeBounds(precise = false) {
    if (!model) return;
    model.updateWorldMatrix(true, true);
    const box = new THREE.Box3().setFromObject(model, precise);
    if (box.isEmpty()) {
      bounds = {center: [0, 0, 0], radius: 1, minimum: [-1, -1, -1], maximum: [1, 1, 1]};
      boundingSphere = new THREE.Sphere(new THREE.Vector3(), 1);
      return;
    }
    const sphere = box.getBoundingSphere(new THREE.Sphere());
    const radius = Math.max(sphere.radius, 0.0001);
    bounds = {
      center: [sphere.center.x, sphere.center.y, sphere.center.z],
      radius,
      minimum: [box.min.x, box.min.y, box.min.z],
      maximum: [box.max.x, box.max.y, box.max.z]
    };
    boundingSphere = sphere;
  }

  function buildNodeTree() {
    nodeObjects = new Map();
    nodeList = [];
    nodeListTruncated = false;
    totalNodeCount = 0;
    if (!model) return;
    let sequence = 0;
    const walk = (object, path) => {
      totalNodeCount += 1;
      const ownPath = path || `${object.type}#${sequence++}`;
      nodeObjects.set(ownPath, object);
      nodeList.push({
        path: ownPath,
        name: object.name || object.type,
        type: object.type,
        childCount: object.children.length,
        meshName: object.isMesh ? (object.geometry?.name || null) : null,
        instanceCount: object.isInstancedMesh ? object.count : 0,
        visible: object.visible
      });
      for (const child of object.children) walk(child, `${ownPath}/${child.name || child.type}#${sequence++}`);
    };
    walk(model, '');
    nodeListTruncated = nodeList.length > MAX_NODES;
  }

  function buildCameras(gltf) {
    cameraEntries = [];
    animationMeta = gltf.parser?.json?.animations || [];
    const list = [];
    model?.traverse(object => { if (object.isCamera) list.push(object); });
    list.forEach((original, index) => {
      let clone;
      try {
        original.updateWorldMatrix(true, false);
        clone = original.clone();
        clone.position.setFromMatrixPosition(original.matrixWorld);
        clone.quaternion.setFromRotationMatrix(original.matrixWorld);
        clone.scale.set(1, 1, 1);
        if (clone.isPerspectiveCamera) clone.aspect = widthNow() / heightNow();
        if (clone.isOrthographicCamera) {
          const aspect = widthNow() / heightNow();
          const heightSize = clone.top - clone.bottom;
          clone.left = -heightSize * aspect / 2;
          clone.right = heightSize * aspect / 2;
        }
        clone.updateProjectionMatrix();
      } catch {
        return;
      }
      cameraEntries.push({index, name: original.name || `Camera ${index + 1}`, type: clone.isOrthographicCamera ? 'orthographic' : 'perspective'});
      cameraEntries[cameraEntries.length - 1].camera = clone;
      cameraEntries[cameraEntries.length - 1].original = original;
    });
  }

  function installCameraControls(next) {
    try { controls.dispose(); } catch {}
    camera = next;
    controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.08;
    controls.screenSpacePanning = false;
    controls.addEventListener('change', () => scheduleRender());
    if (boundingSphere) controls.target.copy(boundingSphere.center);
    const radius = Math.max(boundingSphere?.radius || 1, 0.0001);
    controls.minDistance = Math.max(radius * 0.01, 0.00001);
    controls.maxDistance = Math.max(radius * 50, 10);
    controls.update();
    scheduleRender();
  }

  function selectCamera(index) {
    if (index === null || index === undefined) {
      activeCameraIndex = null;
      installCameraControls(freeCamera);
      fit();
      return true;
    }
    const entry = cameraEntries.find((item) => item.index === index);
    if (!entry) return false;
    activeCameraIndex = index;
    installCameraControls(entry.camera);
    if (boundingSphere) {
      const radius = Math.max(boundingSphere.radius, 0.0001);
      const forward = new THREE.Vector3(0, 0, -1).applyQuaternion(camera.quaternion);
      controls.target.copy(camera.position).addScaledVector(forward, radius);
      controls.update();
    }
    scheduleRender();
    return true;
  }

  function frameCamera() {
    if (!boundingSphere) return;
    const target = boundingSphere.center;
    const radius = Math.max(boundingSphere.radius, 0.0001);
    if (camera.isPerspectiveCamera) {
      const distance = radius / Math.sin(THREE.MathUtils.degToRad(camera.fov) / 2) * 1.35;
      const direction = new THREE.Vector3(0.8, 0.55, 1).normalize();
      camera.position.copy(target).addScaledVector(direction, distance);
    } else {
      const aspect = widthNow() / heightNow();
      const heightSize = radius * 2.4;
      camera.top = heightSize / 2;
      camera.bottom = -heightSize / 2;
      camera.left = -heightSize * aspect / 2;
      camera.right = heightSize * aspect / 2;
      camera.zoom = 1;
      camera.position.copy(target).add(new THREE.Vector3(0, 0, radius * 3));
      camera.updateProjectionMatrix();
    }
    camera.near = Math.max(radius / 10_000, 0.000001);
    camera.far = Math.max(radius * 10_000, 100);
    camera.updateProjectionMatrix();
    if (controls) {
      controls.target.copy(target);
      controls.update();
    }
    camera.lookAt(target);
    scheduleRender();
  }

  function fit() {
    frameCamera();
  }

  function loopValue(mode) {
    if (mode === 'once') return THREE.LoopOnce;
    if (mode === 'pingpong') return THREE.LoopPingPong;
    return THREE.LoopRepeat;
  }

  function applyLoop() {
    if (!activeAction) return;
    activeAction.setLoop(loopValue(loopMode), loopMode === 'once' ? 1 : Infinity);
    activeAction.clampWhenFinished = loopMode === 'once';
  }

  function setupClip(index, preserveTime = 0) {
    if (!mixer || !model) return false;
    if (index === null || index === undefined || !animations[index]) {
      if (activeAction) activeAction.stop();
      activeAction = null;
      activeClipIndex = null;
      durationSeconds = 0;
      timeSeconds = 0;
      playing = false;
      return true;
    }
    if (activeAction) activeAction.stop();
    activeClipIndex = index;
    durationSeconds = animations[index].duration || 0;
    activeAction = mixer.clipAction(animations[index]);
    activeAction.reset();
    activeAction.enabled = true;
    activeAction.paused = false;
    activeAction.setEffectiveWeight(1);
    activeAction.setEffectiveTimeScale(1);
    applyLoop();
    activeAction.play();
    activeAction.time = clamp(preserveTime, 0, durationSeconds);
    mixer.update(0);
    timeSeconds = activeAction.time;
    playing = true;
    return true;
  }

  function setPlayback(next) {
    if (!activeAction) { playing = false; return; }
    if (next && !playing) {
      if (loopMode === 'once' && timeSeconds >= durationSeconds - 0.0001) {
        activeAction.reset();
        activeAction.play();
        timeSeconds = 0;
      }
      activeAction.paused = false;
      playing = true;
    } else if (!next && playing) {
      activeAction.paused = true;
      playing = false;
    }
  }

  function seek(seconds) {
    if (!activeAction || !durationSeconds) return false;
    const value = clamp(Number(seconds) || 0, 0, durationSeconds);
    activeAction.time = value;
    mixer.update(0);
    timeSeconds = value;
    scheduleRender();
    return true;
  }

  function selectClip(index) {
    const parsed = index === null || index === undefined ? null : Number(index);
    const wasPlaying = playing;
    const result = setupClip(Number.isFinite(parsed) ? parsed : null);
    if (!wasPlaying) setPlayback(false);
    return result;
  }

  function stateObject() {
    const textures = new Set();
    const materials = new Set();
    let meshes = 0;
    let skinned = 0;
    let morph = 0;
    let instanced = 0;
    if (model) {
      model.traverse((object) => {
        if (object.isMesh) meshes += 1;
        if (object.isSkinnedMesh) skinned += 1;
        if (object.morphTargetInfluences?.length) morph += 1;
        if (object.isInstancedMesh) instanced += 1;
        const list = Array.isArray(object.material) ? object.material : object.material ? [object.material] : [];
        for (const material of list) {
          materials.add(material.uuid);
          for (const key of ['map', 'normalMap', 'roughnessMap', 'metalnessMap', 'emissiveMap', 'aoMap', 'alphaMap', 'clearcoatMap', 'transmissionMap', 'thicknessMap', 'sheenColorMap']) {
            if (material[key]) textures.add(material[key].uuid);
          }
        }
      });
    }
    return {
      documentName: pkg.name,
      sourceSHA256: pkg.provenance?.sourceSHA256 || '',
      backend: 'threeGLTF',
      ready,
      nodeCount: totalNodeCount,
      meshCount: meshes,
      instancedMeshCount: instanced,
      skinnedMeshCount: skinned,
      morphMeshCount: morph,
      materialCount: materials.size,
      textureCount: textures.size,
      lightCount: model ? countLights(model) : 0,
      nodes: nodeList.slice(0, MAX_NODES),
      cameras: cameraEntries.map(({index, name, type}) => ({index, name, type})),
      scenes: modelScenes.map((item, index) => ({index, name: item.name || `Scene ${index + 1}`})),
      activeSceneIndex,
      clips: animations.map((clip, index) => {
        const meta = animationMeta[index] || {};
        const interpolations = Array.from(new Set((meta.samplers || [])
          .map(sampler => sampler.interpolation || 'LINEAR'))).sort();
        return {
          index,
          name: clip.name || `Animation ${index + 1}`,
          durationSeconds: clip.duration || 0,
          channelCount: meta.channels?.length ?? clip.tracks?.length ?? 0,
          interpolations
        };
      }),
      activeCameraIndex,
      activeClipIndex,
      timeSeconds,
      durationSeconds,
      playing,
      loopMode,
      speed,
      bounds,
      missingResources: missing,
      unsupportedExtensions: unsupported,
      warnings: runtimeWarnings,
      truncatedNodes: nodeListTruncated
    };
  }

  function activateScene(index) {
    if (!Number.isInteger(index) || index < 0 || index >= modelScenes.length) return false;
    playing = false;
    activeAction?.stop();
    mixer?.stopAllAction();
    if (model) { mixer?.uncacheRoot(model); scene.remove(model); }
    activeAction = null;
    activeClipIndex = null;
    timeSeconds = 0;
    durationSeconds = 0;
    model = modelScenes[index];
    activeSceneIndex = index;
    scene.add(model);
    mixer = new THREE.AnimationMixer(model);
    mixer.addEventListener('finished', () => {
      playing = false;
      if (activeAction) timeSeconds = activeAction.time;
      publish(true);
    });
    model.updateWorldMatrix(true, true);
    computeBounds();
    buildNodeTree();
    buildCameras(loadedAsset);
    selectCamera(null);
    if (animations.length) setupClip(0);
    fit();
    return true;
  }

  function countLights(root) {
    let count = 0;
    root.traverse((object) => { if (object.isLight) count += 1; });
    return count;
  }

  function publish(force = false) {
    if (!ready || disposed) return;
    const now = performance.now();
    if (!force && now - lastPublish < 250) return;
    lastPublish = now;
    try { onState?.(stateObject()); } catch {}
  }

  function tick() {
    if (disposed) return;
    raf = requestAnimationFrame(tick);
    const now = performance.now();
    const delta = Math.min((now - lastFrame) / 1000, 0.1);
    lastFrame = now;
    if (mixer) {
      if (playing) {
        mixer.update(delta * speed);
        if (activeAction) {
          timeSeconds = activeAction.time;
          if (loopMode === 'once' && activeAction.time >= durationSeconds) {
            playing = false;
            timeSeconds = durationSeconds;
          }
        }
      } else if (activeAction) {
        timeSeconds = activeAction.time;
      }
    }
    const controlsChanged = controls ? controls.update() : false;
    if (playing && activeCameraIndex !== null) {
      const entry = cameraEntries.find(item => item.index === activeCameraIndex);
      if (entry?.original) {
        entry.original.updateWorldMatrix(true, false);
        camera.position.setFromMatrixPosition(entry.original.matrixWorld);
        camera.quaternion.setFromRotationMatrix(entry.original.matrixWorld);
      }
    }
    if (playing) {
      renderer.render(scene, camera);
      needsRender = false;
      publish(false);
    } else if (needsRender || controlsChanged) {
      renderer.render(scene, camera);
      needsRender = false;
    }
  }

  function command(raw) {
    let payload = raw;
    try { if (typeof raw === 'string') payload = JSON.parse(raw); } catch { return JSON.stringify(stateObject()); }
    if (!payload || typeof payload !== 'object') return JSON.stringify(stateObject());
    if (payload.action === 'hierarchy') {
      const offset = Math.max(0, Math.min(nodeList.length, Math.trunc(Number(payload.offset) || 0)));
      const limit = Math.max(1, Math.min(1000, Math.trunc(Number(payload.limit) || 200)));
      const nodes = nodeList.slice(offset, offset + limit);
      return JSON.stringify({sourceSHA256: pkg.provenance?.sourceSHA256 || '',
        sceneIndex: activeSceneIndex, total: nodeList.length, offset,
        nextOffset: offset + nodes.length < nodeList.length ? offset + nodes.length : null, nodes});
    }
    switch (payload.action) {
      case 'play': {
        const value = payload.value ?? payload.seconds;
        if (typeof value === 'number') seek(value);
        setPlayback(true);
        break;
      }
      case 'pause': setPlayback(false); break;
      case 'seek': seek(payload.seconds); break;
      case 'clip': selectClip(payload.index ?? null); break;
      case 'loop':
        if (['once', 'repeat', 'pingpong'].includes(payload.mode)) { loopMode = payload.mode; applyLoop(); }
        break;
      case 'speed':
        if (Number.isFinite(Number(payload.speed))) speed = clamp(Number(payload.speed), 0.1, 8);
        break;
      case 'camera': selectCamera(payload.index === null || payload.index === undefined ? null : Number(payload.index)); break;
      case 'scene': activateScene(Number(payload.index)); break;
      case 'fit': fit(); break;
      case 'nodeVisibility': {
        const nodePath = String(payload.path ?? '');
        const object = nodeObjects.get(nodePath);
        if (object) object.visible = payload.visible !== false;
        const entry = nodeList.find(item => item.path === nodePath);
        if (entry) entry.visible = object?.visible ?? false;
        break;
      }
      default: break;
    }
    publish(true);
    scheduleRender();
    return JSON.stringify(stateObject());
  }

  function restorePlayback(saved) {
    if (saved.clip !== activeClipIndex) {
      setupClip(saved.clip, saved.time);
    } else if (activeAction) {
      activeAction.time = clamp(saved.time, 0, durationSeconds);
      mixer.update(0);
    }
    loopMode = saved.loopMode;
    speed = saved.speed;
    applyLoop();
    if (activeAction) {
      activeAction.paused = !saved.playing;
      playing = saved.playing;
      timeSeconds = activeAction.time;
    } else {
      playing = false;
      timeSeconds = 0;
    }
  }

  function restoreCameraState(saved) {
    camera = saved.camera;
    if (camera.isPerspectiveCamera) camera.aspect = saved.aspect;
    if (camera.isOrthographicCamera) {
      camera.left = saved.left; camera.right = saved.right;
      camera.top = saved.top; camera.bottom = saved.bottom;
    }
    camera.zoom = saved.zoom;
    camera.position.copy(saved.position);
    camera.quaternion.copy(saved.quaternion);
    camera.near = saved.near;
    camera.far = saved.far;
    camera.updateProjectionMatrix();
    installCameraControls(camera);
    if (saved.target) {
      controls.target.copy(saved.target);
      controls.update();
      camera.lookAt(saved.target);
    }
  }

  async function capture(raw) {
    let request = raw;
    try { if (typeof raw === 'string') request = JSON.parse(raw); } catch { request = {}; }
    request = request && typeof request === 'object' ? request : {};
    const views = Array.isArray(request.views) ? request.views.slice(0, MAX_CAPTURE_FRAMES) : [];
    if (!views.length) return JSON.stringify({frames: [], failures: [{viewIndex: 0, reason: 'no capture views'}]});
    const width = clamp(Number(request.width) || 1024, 64, 2048);
    const height = clamp(Number(request.height) || 768, 64, 2048);
    const maximumPNGBytes = clamp(Number(request.maximumPNGBytes) || 8 * 1024 * 1024, 1024, 16 * 1024 * 1024);
    const maximumTotalBytes = clamp(Number(request.maximumTotalBytes) || 32 * 1024 * 1024, 1024, 32 * 1024 * 1024);
    const requestedClip = request.clipIndex === null || request.clipIndex === undefined ? null : Number(request.clipIndex);
    const requestedTime = request.timeSeconds === null || request.timeSeconds === undefined ? null : Number(request.timeSeconds);
    const requestedProjection = request.projection === null || request.projection === undefined
      ? null : String(request.projection);
    if (requestedProjection !== null && !['perspective', 'orthographic'].includes(requestedProjection)) {
      return JSON.stringify({
        frames: [],
        failures: views.map((_, index) => ({viewIndex: index, reason: 'unsupported projection'})),
        sourceSHA256: pkg.provenance?.sourceSHA256 || ''
      });
    }
    const savedProjection = camera.isOrthographicCamera ? 'orthographic' : 'perspective';
    const savedFov = camera.isPerspectiveCamera ? camera.fov : 45;
    const saved = {
      camera,
      aspect: camera.aspect,
      left: camera.left, right: camera.right, top: camera.top, bottom: camera.bottom,
      zoom: camera.zoom,
      position: camera.position.clone(),
      quaternion: camera.quaternion.clone(),
      near: camera.near, far: camera.far,
      target: controls.target.clone(),
      renderWidth: renderer.domElement.width, renderHeight: renderer.domElement.height,
      pixelRatio: renderer.getPixelRatio(),
      clip: activeClipIndex, time: timeSeconds, playing, loopMode, speed
    };
    const failures = [];
    const frames = [];
    let totalBytes = 0;
    try {
      if (!boundingSphere) throw new Error('no scene bounds');
      const previousSize = new THREE.Vector2();
      renderer.getSize(previousSize);
      renderer.setPixelRatio(1);
      renderer.setSize(width, height, false);
      let clip = requestedClip !== null && Number.isFinite(requestedClip) ? requestedClip : activeClipIndex;
      if (clip !== null && !animations[clip]) clip = activeClipIndex;
      if (clip !== activeClipIndex) setupClip(clip);
      if (activeAction) {
        activeAction.paused = true;
        playing = false;
        const seconds = requestedTime !== null && Number.isFinite(requestedTime)
          ? clamp(requestedTime, 0, durationSeconds) : timeSeconds;
        activeAction.time = seconds;
        mixer.update(0);
        timeSeconds = seconds;
      }
      computeBounds(true);
      const target = boundingSphere.center.clone();
      const radius = Math.max(boundingSphere.radius, 0.0001);
      for (let index = 0; index < views.length; index += 1) {
        const view = views[index] || {};
        const azimuth = Number(view.azimuthDegrees) || 0;
        const elevation = clamp(Number(view.elevationDegrees) || 0, -89, 89);
        const distanceScale = clamp(Number(view.distanceScale) || 1, 0.1, 5);
        try {
          const viewTarget = target.clone();
          if (Array.isArray(view.target) && view.target.length === 3 && view.target.every(Number.isFinite)) {
            viewTarget.set(Number(view.target[0]), Number(view.target[1]), Number(view.target[2]));
          }
          const azimuthRadians = THREE.MathUtils.degToRad(azimuth);
          const elevationRadians = THREE.MathUtils.degToRad(elevation);
          const direction = new THREE.Vector3(
            Math.cos(elevationRadians) * Math.sin(azimuthRadians),
            Math.sin(elevationRadians),
            Math.cos(elevationRadians) * Math.cos(azimuthRadians));
          const projection = requestedProjection || savedProjection;
          const useTemporaryCamera = projection !== savedProjection;
          let renderCamera = camera;
          if (useTemporaryCamera) {
            // Explicit projection is rendered with a disposable camera; the
            // scene's active camera/controls/playback authority is untouched.
            const near = Math.max(radius / 10_000, 0.000001);
            const far = Math.max(radius * 10_000, 100);
            const boundingDistance = radius
              / Math.sin(THREE.MathUtils.degToRad(savedFov) / 2) * 1.35 * distanceScale;
            if (projection === 'perspective') {
              renderCamera = new THREE.PerspectiveCamera(savedFov, width / height, near, far);
            } else {
              const halfHeight = boundingDistance * Math.tan(THREE.MathUtils.degToRad(savedFov) / 2);
              const halfWidth = halfHeight * (width / height);
              renderCamera = new THREE.OrthographicCamera(
                -halfWidth, halfWidth, halfHeight, -halfHeight, near, far);
            }
            renderCamera.position.copy(viewTarget).addScaledVector(direction, boundingDistance);
            renderCamera.up.set(0, 1, 0);
            renderCamera.lookAt(viewTarget);
            renderCamera.updateProjectionMatrix();
          } else {
            const distance = camera.isPerspectiveCamera
              ? radius / Math.sin(THREE.MathUtils.degToRad(camera.fov) / 2) * 1.35 * distanceScale
              : radius * 3 * distanceScale;
            camera.position.copy(viewTarget).addScaledVector(direction, distance);
            if (camera.isPerspectiveCamera) {
              camera.aspect = width / height;
            } else {
              const heightSize = radius * 2.4 * distanceScale;
              camera.top = heightSize / 2;
              camera.bottom = -heightSize / 2;
              camera.left = -heightSize * (width / height) / 2;
              camera.right = heightSize * (width / height) / 2;
              camera.zoom = 1;
            }
            camera.near = Math.max(radius / 10_000, 0.000001);
            camera.far = Math.max(radius * 10_000, 100);
            camera.updateProjectionMatrix();
            camera.lookAt(viewTarget);
          }
          renderer.render(scene, renderCamera);
          const dataURL = renderer.domElement.toDataURL('image/png');
          const dimensions = pngDimensions(dataURL);
          if (!dimensions) throw new Error('the renderer did not return a PNG frame');
          const byteEstimate = Math.ceil(dataURL.length * 3 / 4);
          if (byteEstimate > maximumPNGBytes) throw new Error('png exceeds frame limit');
          if (totalBytes + byteEstimate > maximumTotalBytes) throw new Error('capture exceeds total limit');
          totalBytes += byteEstimate;
          const frameState = stateObject();
          frames.push({
            dataURL, width: dimensions.width, height: dimensions.height, viewIndex: index,
            azimuthDegrees: azimuth, elevationDegrees: elevation,
            projection, renderer: 'threeGLTF',
            timeSeconds, clipIndex: clip,
            sourceSHA256: pkg.provenance?.sourceSHA256 || '',
            state: frameState
          });
        } catch (error) {
          failures.push({viewIndex: index, reason: String(error?.message ?? error)});
        }
      }
      renderer.setPixelRatio(saved.pixelRatio);
      renderer.setSize(previousSize.x, previousSize.y, false);
    } catch (error) {
      failures.push({viewIndex: 0, reason: String(error?.message ?? error)});
    } finally {
      restoreCameraState(saved);
      restorePlayback(saved);
      computeBounds();
      renderer.setPixelRatio(saved.pixelRatio);
      renderer.setSize(widthNow(), heightNow(), false);
      if (camera.isPerspectiveCamera) camera.aspect = widthNow() / heightNow();
      camera.updateProjectionMatrix();
      scheduleRender();
      publish(true);
    }
    return JSON.stringify({frames, failures, sourceSHA256: pkg.provenance?.sourceSHA256 || ''});
  }

  function reviewContext() {
    const state = stateObject();
    return {
      type: 'glTF scene',
      source: pkg.name,
      sourceSHA256: state.sourceSHA256,
      backend: 'three.js r176 GLTFLoader',
      nodeCount: state.nodeCount,
      meshCount: state.meshCount,
      instancedMeshCount: state.instancedMeshCount,
      skinnedMeshCount: state.skinnedMeshCount,
      morphMeshCount: state.morphMeshCount,
      cameraCount: state.cameras.length,
      clipCount: state.clips.length,
      scenes: state.scenes,
      activeSceneIndex: state.activeSceneIndex,
      activeCameraIndex: state.activeCameraIndex,
      activeClipIndex: state.activeClipIndex,
      timeSeconds: state.timeSeconds,
      bounds: state.bounds,
      missingResources: state.missingResources,
      unsupportedExtensions: state.unsupportedExtensions,
      warnings: state.warnings,
      hierarchy: state.nodes.slice(0, 60),
      cameras: state.cameras,
      clips: state.clips,
      limitations: 'Rendered scene only. Hierarchy/material/animation presence does not prove engineering dimensions, tolerances, manufacturing validity or lossless CAD import.'
    };
  }

  async function load() {
    if (disposed) return;
    onProgress?.(0.1);
    const mainBytes = decodeBytes(main);
    const extension = mainName.split('.').pop().toLowerCase();
    const payload = extension === 'gltf' ? new TextDecoder().decode(mainBytes) : mainBytes.buffer;
    const gltf = await loader.parseAsync(payload, '');
    if (disposed) {
      disposeObject(gltf.scene);
      throw new Error('disposed');
    }
    loadedAsset = gltf;
    modelScenes = gltf.scenes?.length ? gltf.scenes : gltf.scene ? [gltf.scene] : [];
    if (!modelScenes.length) throw new Error(say ? say('文件没有场景。', 'The file has no scene.') : 'no scene');
    animations = gltf.animations || [];
    const defaultIndex = Math.max(0, modelScenes.indexOf(gltf.scene));
    activateScene(defaultIndex);
    missing = Array.from(new Set([...(pkg.missingReferences || []), ...blockedReferences, ...failedReferences]));
    unsupported = Array.from(new Set([...(pkg.diagnostics?.unsupportedExtensions || []), ...(pkg.diagnostics?.unsupportedRequiredExtensions || [])]));
    if (missing.length) runtimeWarnings.push(say
      ? say(`缺少 ${missing.length} 个引用资源，已显示可读取部分。`, `${missing.length} referenced resources are missing; readable parts are shown.`)
      : `${missing.length} referenced resources are missing`);
    if (unsupported.length) runtimeWarnings.push(say
      ? say(`未支持的扩展：${unsupported.join(', ')}`, `Unsupported extensions: ${unsupported.join(', ')}`)
      : `Unsupported extensions: ${unsupported.join(', ')}`);
    if (pkg.diagnostics?.sparseAccessorCount > 0) runtimeWarnings.push(say
      ? '稀疏访问器由查看器解码，不代表 CAD 导入无损。'
      : 'Sparse accessors are decoded by the viewer; CAD import remains lossy.');
    if (animations.length) setupClip(0);
    fit();
    ready = true;
    onProgress?.(1);
    onReady?.(stateObject());
    publish(true);
    lastFrame = performance.now();
    if (!raf) raf = requestAnimationFrame(tick);
  }

  function disposeObject(root) {
    if (!root) return;
    root.traverse((object) => {
      object.geometry?.dispose?.();
      const materials = Array.isArray(object.material) ? object.material : object.material ? [object.material] : [];
      for (const material of materials) {
        for (const key of Object.keys(material)) {
          const value = material[key];
          if (value && value.isTexture) value.dispose();
        }
        material.dispose?.();
      }
    });
  }

  function dispose() {
    if (disposed) return;
    disposed = true;
    cancelAnimationFrame(raf);
    resizeObserver.disconnect();
    try { controls.dispose(); } catch {}
    try { mixer?.stopAllAction(); } catch {}
    for (const assetScene of modelScenes) disposeObject(assetScene);
    modelScenes = [];
    loadedAsset = null;
    for (const url of objectURLs) { try { URL.revokeObjectURL(url); } catch {} }
    try { draco.dispose(); } catch {}
    try { ktx2?.dispose(); } catch {}
    try { environmentTarget?.dispose(); } catch {}
    try { pmrem.dispose(); } catch {}
    try { renderer.dispose(); } catch {}
    try { renderer.forceContextLoss?.(); } catch {}
    renderer.domElement.remove();
    host.remove();
    nodeObjects.clear();
    nodeList = [];
  }

  return {
    load,
    dispose,
    fit,
    command,
    capture,
    reviewContext,
    state: () => JSON.stringify(stateObject())
  };
}
