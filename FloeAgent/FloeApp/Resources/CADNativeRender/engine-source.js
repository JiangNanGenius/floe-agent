// SPDX-License-Identifier: MPL-2.0
// Bundled at development time. Runtime imports/network/installers are forbidden.
import * as THREE from 'three';
import { WebGLPathTracer } from 'three-gpu-pathtracer/src/core/WebGLPathTracer.js';
import { HDRLoader } from 'three/addons/loaders/HDRLoader.js';
import { EXRLoader } from 'three/addons/loaders/EXRLoader.js';

const backend = 'three-gpu-pathtracer-webgl2';
const revision = '0.0.24-three0.181.1-bvh0.9.5';
const token = new URL(location.href).searchParams.get('session');
const limit = 64 * 1024 * 1024;
let stopped = false, renderer, tracer, scene, inputParts = [], inputBytes = 0, inputIndex = 0;
const disposables = new Set();
const bridge = window.webkit?.messageHandlers?.cadNativeRender;
const send = body => bridge.postMessage({ ...body, session: token });
const check = (ok, message) => { if (!ok) throw new Error(message); };
const pause = () => new Promise(resolve => setTimeout(resolve, 0));
const bytes = text => Uint8Array.from(atob(text), x => x.charCodeAt(0));
const colour = rgb => new THREE.Color().setRGB(...rgb, THREE.LinearSRGBColorSpace);
function dispose() {
  if (stopped) return;
  stopped = true;
  tracer?.dispose();
  for (const value of disposables) value.dispose?.();
  disposables.clear();
  renderer?.dispose(); renderer?.forceContextLoss();
  renderer?.domElement.remove();
  inputParts = []; inputBytes = 0;
}
async function fail(error) {
  if (!stopped) await send({ kind: 'error', message: String(error?.message || error).slice(0, 1000) }).catch(() => {});
  dispose();
}
async function imageTexture(name, assets, linear = false) {
  check(typeof assets[name] === 'string', 'The frozen scene image is missing.');
  const data = bytes(assets[name]);
  let texture;
  if (/\.(hdr|exr)$/.test(name)) {
    const loader = name.endsWith('.hdr') ? new HDRLoader() : new EXRLoader();
    const image = loader.setDataType(THREE.FloatType).parse(data.buffer);
    texture = new THREE.DataTexture(image.data, image.width, image.height, THREE.RGBAFormat, image.type);
    texture.colorSpace = THREE.LinearSRGBColorSpace;
  } else {
    const url = URL.createObjectURL(new Blob([data], { type: name.endsWith('.png') ? 'image/png' : 'image/jpeg' }));
    try { texture = await new THREE.TextureLoader().loadAsync(url); }
    finally { URL.revokeObjectURL(url); }
    texture.colorSpace = linear ? THREE.LinearSRGBColorSpace : THREE.SRGBColorSpace;
  }
  texture.needsUpdate = true; disposables.add(texture);
  return texture;
}
async function run(request) {
  check(request.schemaVersion === 1 && request.backend === backend, 'Unsupported frozen render input.');
  const s = request.settings, input = request.scene;
  check([s.width,s.height].every(x => Number.isInteger(x) && x >= 64 && x <= 4096) && s.width * s.height <= 8388608, 'Invalid image size.');
  const samples = { preview: 16, studio: 64, final: 256 }[s.quality];
  check(samples && Number.isFinite(s.exposureEV) && Math.abs(s.exposureEV) <= 6, 'Invalid render settings.');
  check(Number.isInteger(s.maximumBounces) && s.maximumBounces >= 2 && s.maximumBounces <= 16, 'Invalid bounce count.');
  check(input.meshes.length > 0 && input.meshes.reduce((n,m) => n + m.indices.length / 3, 0) <= 250000, 'The local scene is too large.');
  const canvas = document.createElement('canvas'); document.body.append(canvas);
  const gl = canvas.getContext('webgl2', { preserveDrawingBuffer: true, antialias: false, alpha: false });
  check(gl && gl.getExtension('EXT_color_buffer_float'), 'Local WebGL2 floating-point rendering is unavailable.');
  const maxSize = Math.min(gl.getParameter(gl.MAX_TEXTURE_SIZE), gl.getParameter(gl.MAX_RENDERBUFFER_SIZE));
  check(s.width <= maxSize && s.height <= maxSize, 'Choose a smaller image for this device.');
  canvas.addEventListener('webglcontextlost', event => { event.preventDefault(); if (!stopped) void fail(new Error('The local graphics context was released. Try a smaller image.')); });
  renderer = new THREE.WebGLRenderer({ canvas, context: gl, antialias: false, preserveDrawingBuffer: true });
  renderer.debug.onShaderError = () => { void fail(new Error('The local path tracing shader could not be compiled. Try a smaller scene.')); };
  renderer.setPixelRatio(1); renderer.setSize(s.width, s.height, false);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  // A fixed photometric reference, matching the former millisecond exposure.
  renderer.toneMappingExposure = 0.001 * Math.pow(2, s.exposureEV);
  scene = new THREE.Scene(); scene.background = colour(input.backgroundColor);
  const aspect = s.width / s.height, c = input.camera;
  const camera = c.orthographicHalfHeight
    ? new THREE.OrthographicCamera(-c.orthographicHalfHeight*aspect, c.orthographicHalfHeight*aspect, c.orthographicHalfHeight, -c.orthographicHalfHeight, 0.0001, 1e9)
    : new THREE.PerspectiveCamera(c.verticalFOV, aspect, 0.0001, 1e9);
  camera.position.fromArray(c.eye); camera.up.fromArray(c.up); camera.lookAt(new THREE.Vector3().fromArray(c.target));
  const textures = new Map();
  for (const m of input.meshes) {
    if (stopped) return;
    const geometry = new THREE.BufferGeometry(); disposables.add(geometry);
    geometry.setAttribute('position', new THREE.Float32BufferAttribute(m.positions, 3));
    geometry.setIndex(new THREE.Uint32BufferAttribute(m.indices, 1));
    if (m.normals.length) geometry.setAttribute('normal', new THREE.Float32BufferAttribute(m.normals, 3)); else geometry.computeVertexNormals();
    if (m.uvs.length) geometry.setAttribute('uv', new THREE.Float32BufferAttribute(m.uvs, 2));
    const a = m.material;
    const material = new THREE.MeshPhysicalMaterial({ color: colour(a.color), metalness:a.metallic, roughness:a.roughness,
      opacity:a.opacity, transparent:a.opacity < 0.999, emissive:colour(a.emissive), emissiveIntensity:1, side:THREE.DoubleSide });
    disposables.add(material);
    if (a.baseColorImage && m.uvs.length) {
      const key = `${a.baseColorImage}:${a.imageIsLinear}:${a.flipImageV}`;
      if (!textures.has(key)) {
        const texture = await imageTexture(a.baseColorImage, input.assets, a.imageIsLinear);
        texture.flipY = a.flipImageV; textures.set(key, texture);
      }
      material.map = textures.get(key);
    }
    scene.add(new THREE.Mesh(geometry, material));
  }
  if (input.environmentImage) {
    const environment = await imageTexture(input.environmentImage, input.assets, false);
    environment.mapping = THREE.EquirectangularReflectionMapping;
    scene.environment = environment;
    scene.environmentIntensity = input.environmentIntensity;
    scene.environmentRotation.y = input.environmentRotation * Math.PI / 180;
    if (input.environmentShowsBackground) { scene.background = environment; scene.backgroundIntensity=input.environmentIntensity; scene.backgroundRotation.copy(scene.environmentRotation); }
  }
  for (const l of input.lights) {
    if (!l.intensity || !l.color.some(x => x > 0)) continue;
    let light;
    if (l.kind === 'directional') light = new THREE.DirectionalLight(colour(l.color), l.intensity);
    else if (l.kind === 'point') { light = new THREE.PointLight(colour(l.color)); light.power = l.intensity; }
    else {
      if (!l.outerAngle) continue;
      light = new THREE.SpotLight(colour(l.color)); light.power=l.intensity;
      light.angle=l.outerAngle * Math.PI / 360; light.penumbra=1-l.innerAngle/l.outerAngle;
    }
    light.position.fromArray(l.position);
    if (light.target) { light.target.position.fromArray(l.position).add(new THREE.Vector3().fromArray(l.direction)); scene.add(light.target); }
    scene.add(light);
  }
  tracer = new WebGLPathTracer(renderer);
  tracer.rasterizeScene = false; // Never report a raster fallback as path tracing.
  tracer.dynamicLowRes = false; tracer.fadeDuration = 0; tracer.renderDelay = 0; tracer.minSamples = 1;
  tracer.bounces = s.maximumBounces; tracer.tiles.set(3,3); tracer.textureSize.set(512,512);
  tracer.setScene(scene,camera);
  let lastProgress = 0;
  while (!stopped && tracer.samples < samples) {
    tracer.renderSample();
    if (performance.now()-lastProgress > 700) { lastProgress=performance.now(); await send({kind:'progress',samples:Math.floor(tracer.samples),target:samples}); }
    await pause();
  }
  if (stopped) return;
  const completedSamples = Math.floor(tracer.samples);
  check(completedSamples >= samples, 'The path tracer did not complete the requested samples.');
  const blob = await new Promise(resolve => canvas.toBlob(resolve,'image/png'));
  check(blob && blob.size > 0 && blob.size <= limit, 'The rendered PNG is missing or too large.');
  const url = await new Promise((resolve,reject) => { const reader=new FileReader(); reader.onload=()=>resolve(reader.result); reader.onerror=reject; reader.readAsDataURL(blob); });
  const base64 = url.slice(url.indexOf(',')+1), chunkSize=196608;
  await send({kind:'pngBegin',byteCount:blob.size,samples:completedSamples,backend,revision});
  for (let offset=0,index=0; offset<base64.length && !stopped; offset+=chunkSize,index++) {
    await send({kind:'pngChunk',index,data:base64.slice(offset,offset+chunkSize)});
  }
  if (!stopped) await send({kind:'complete',samples:completedSamples,backend,revision});
  dispose();
}
window.FloeCADNativeRender = {
  appendInput(chunk,index,final) {
    check(!stopped && index === inputIndex++, 'Invalid frozen-input sequence.');
    const data = bytes(chunk); inputBytes+=data.length; check(inputBytes<=limit,'The frozen scene is too large.'); inputParts.push(data);
    if (final) {
      const all=new Uint8Array(inputBytes); let offset=0;
      for(const part of inputParts){ all.set(part,offset); offset+=part.length; }
      inputParts=[];
      const request=JSON.parse(new TextDecoder().decode(all));
      void run(request).catch(fail);
    }
    return true;
  },
  dispose,
};
window.addEventListener('error', event => { void fail(event.error || new Error('The local renderer could not start.')); });
window.addEventListener('unhandledrejection', event => { void fail(event.reason || new Error('The local renderer stopped.')); });
void send({kind:'ready',backend,revision}).catch(fail);
