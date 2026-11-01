// SPDX-License-Identifier: MPL-2.0
//
// Read-only C04A viewer. Derived from the pinned iOS EngineeringViewers
// viewer.js, reduced to the read-only paths and served only by the App's
// local origin. All file/resource bytes arrive through the session manifest,
// are length+digest verified here, and are handed to the exact pinned
// dxf.js/occt-import-js/mesh.js readers. Nothing is fetched from a CDN.
const params = new URLSearchParams(location.search);
const session = params.get('session') || '';
const view = document.getElementById('view');
const status = document.getElementById('status');
const statusText = document.getElementById('statusText');
const errorBox = document.getElementById('error');
const errorTitle = document.getElementById('errorTitle');
const errorText = document.getElementById('errorText');
const native = window.C04Bridge;

let manifest = null;
let dxfViewer = null;
let embedded = null;
let resizeObserver = null;
let cadWorker = null;
let occtWorker = null;
let disposed = false;
let ready = false;
let frameSequence = 0;
let initialDxf = null;
let initialMeshCamera = null;
const blobUrls = [];

function post(value) {
  try {
    native?.postEvent(JSON.stringify({ session, ...value }));
  } catch (_) {}
}

function say(text) {
  statusText.textContent = text;
  status.hidden = false;
}

function fail(code, message) {
  if (disposed) return;
  status.hidden = true;
  errorTitle.textContent = 'Unable to display this file';
  errorText.textContent = String(message ?? code).slice(0, 400);
  errorBox.hidden = false;
  post({ type: 'error', code, message: String(message ?? code).slice(0, 300) });
}

function readyWith(facts) {
  if (disposed) return;
  ready = true;
  frameSequence = Math.max(frameSequence, 1);
  status.hidden = true;
  errorBox.hidden = true;
  post({ type: 'ready', facts: { ...facts, rendered: true, frameSequence } });
}

function waitFrames(count = 2) {
  return new Promise(resolve => {
    let left = Math.max(1, count);
    const step = () => {
      left -= 1;
      if (left <= 0) resolve();
      else requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  });
}

function resourceUrl(entry) {
  return '/resource/' + encodeURIComponent(session) + '/' + encodeURIComponent(entry.token);
}

function digestHex(buffer) {
  return [...new Uint8Array(buffer)]
    .map(value => value.toString(16).padStart(2, '0'))
    .join('');
}

async function fetchVerified(entry) {
  if (!entry || typeof entry.token !== 'string' || typeof entry.sha256 !== 'string') {
    throw new Error('invalidResource');
  }
  const response = await fetch(resourceUrl(entry), {
    cache: 'no-store',
    credentials: 'omit',
  });
  if (!response.ok) throw new Error('resourceFetch');
  const buffer = await response.arrayBuffer();
  if (buffer.byteLength !== entry.byteCount) throw new Error('resourceLength');
  if (!(crypto && crypto.subtle)) throw new Error('cryptoUnavailable');
  const digest = await crypto.subtle.digest('SHA-256', buffer);
  if (digestHex(digest) !== entry.sha256.toLowerCase()) {
    throw new Error('resourceDigestMismatch');
  }
  return new Uint8Array(buffer);
}

function fileFor(entry, bytes) {
  return new File([bytes], entry.name, {
    type: entry.mediaType || 'application/octet-stream',
  });
}

function runWorker(worker, message, transfer = []) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      try { worker.terminate(); } catch (_) {}
      reject(new Error('workerTimeout'));
    }, 45000);
    worker.onmessage = ({ data }) => {
      clearTimeout(timer);
      if (data && data.error) reject(new Error(String(data.error)));
      else resolve(data);
    };
    worker.onerror = event => {
      clearTimeout(timer);
      reject(new Error(event?.message || 'workerError'));
    };
    worker.postMessage(message, transfer);
  });
}

function dxfUnits(code) {
  switch (Number(code) || 0) {
    case 1: return 'in';
    case 2: return 'ft';
    case 4: return 'mm';
    case 5: return 'cm';
    case 6: return 'm';
    case 10: return 'yd';
    default: return 'unknown';
  }
}

function dispose() {
  disposed = true;
  try { resizeObserver?.disconnect(); } catch (_) {}
  try { dxfViewer?.Destroy(); } catch (_) {}
  try { embedded?.Destroy(); } catch (_) {}
  try { cadWorker?.terminate(); } catch (_) {}
  try { occtWorker?.terminate(); } catch (_) {}
  for (const url of blobUrls.splice(0)) {
    try { URL.revokeObjectURL(url); } catch (_) {}
  }
  dxfViewer = null;
  embedded = null;
  cadWorker = null;
  occtWorker = null;
}

function fitDxf() {
  if (!dxfViewer) return;
  const bounds = dxfViewer.bounds || dxfViewer.GetBounds();
  if (!bounds) return;
  const origin = dxfViewer.GetOrigin();
  dxfViewer.FitView(
    bounds.minX - origin.x, bounds.maxX - origin.x,
    bounds.minY - origin.y, bounds.maxY - origin.y);
  dxfViewer.Render();
}

function resetDxf() {
  if (!dxfViewer) return;
  if (!initialDxf) { fitDxf(); return; }
  dxfViewer.SetView({ x: initialDxf.x, y: initialDxf.y }, initialDxf.width);
  dxfViewer.Render();
}

function zoomDxf(factor) {
  if (!dxfViewer) return;
  const camera = dxfViewer.GetCamera();
  const width = (camera.right - camera.left) / camera.zoom;
  dxfViewer.SetView({ x: camera.position.x, y: camera.position.y }, width * factor);
  dxfViewer.Render();
}

function captureDxfView() {
  const camera = dxfViewer.GetCamera();
  return {
    x: camera.position.x,
    y: camera.position.y,
    width: (camera.right - camera.left) / camera.zoom,
  };
}

async function loadDxf(bytes, format, limitations) {
  const { DxfViewer, Color } = await import('./dxf.js');
  const dark = document.body.classList.contains('dark');
  const surface = document.createElement('div');
  surface.style.cssText = 'width:100%;height:100%';
  view.replaceChildren(surface);
  const viewer = new DxfViewer(surface, {
    autoResize: true,
    retainParsedDxf: true,
    preserveDrawingBuffer: true,
    clearColor: new Color(dark ? '#181e28' : '#f5f6f8'),
    colorCorrection: true,
  });
  dxfViewer = viewer;
  const url = URL.createObjectURL(new Blob([bytes]));
  blobUrls.push(url);
  await viewer.Load({
    url,
    fonts: [new URL('MiSans-Regular.ttf', location.href).href],
    workerFactory: () => new Worker(new URL('dxf-worker.js', location.href), { type: 'module' }),
  });
  if (!viewer.bounds) throw new Error('noGeometry');
  fitDxf();
  initialDxf = captureDxfView();
  viewer.Render();
  await waitFrames(2);
  const parsed = viewer.GetDxf();
  const header = parsed?.header || {};
  const units = dxfUnits(header['$INSUNITS'] ?? header.INSUNITS);
  const b = viewer.GetBounds() || viewer.bounds;
  readyWith({
    format,
    sourceUnits: units,
    displayUnits: units,
    bounds: {
      min: [Number(b.minX), Number(b.minY), 0],
      max: [Number(b.maxX), Number(b.maxY), 0],
    },
    entityCount: Array.isArray(parsed?.entities) ? parsed.entities.length : 0,
    meshCount: 0,
    triangleCount: 0,
    vertexCount: 0,
    missingResourceCount: manifest?.missing?.length ?? 0,
    limitations: limitations || 'Tessellated 2D display; dimensions, line styles and layouts may be simplified. Read-only.',
  });
}

async function loadDwg(bytes) {
  cadWorker = new Worker(new URL('cad-worker.js', location.href), { type: 'module' });
  try {
    const result = await runWorker(cadWorker, { bytes, format: 'dwg' }, [bytes.buffer]);
    if (!result?.dxf) throw new Error('dwgProjection');
    await loadDxf(
      result.dxf,
      'dwg',
      'Read-only DWG projection. The native DWG document is not modified; some annotations, line styles and layouts may be simplified.');
  } finally {
    try { cadWorker?.terminate(); } catch (_) {}
    cadWorker = null;
  }
}

async function loadOcct(bytes, format) {
  occtWorker = new Worker(new URL('occt-worker.js', location.href));
  try {
    const result = await runWorker(occtWorker, { bytes, extension: format }, [bytes.buffer]);
    if (!result?.buffer) throw new Error('occtMesh');
    const stl = new File([result.buffer], 'display.stl', { type: 'model/stl' });
    await loadMesh([stl], format, result.info);
  } finally {
    try { occtWorker?.terminate(); } catch (_) {}
    occtWorker = null;
  }
}

async function loadMesh(files, format, surfaceInfo) {
  const OV = await import('./mesh.js');
  const dark = document.body.classList.contains('dark');
  const parent = document.createElement('div');
  parent.style.cssText = 'width:100%;height:100%';
  view.replaceChildren(parent);
  embedded = new OV.EmbeddedViewer(parent, {
    backgroundColor: new OV.RGBAColor(...(dark ? [24, 30, 40, 255] : [245, 246, 248, 255])),
    defaultColor: new OV.RGBColor(120, 165, 190),
    onModelLoaded: () => {
      // The caller assigns `embedded` after the constructor returns.
      setTimeout(() => { void finishMesh(format, surfaceInfo); }, 0);
    },
    onModelLoadFailed: () => fail('renderFailed', 'The model could not be read.'),
  });
  resizeObserver = new ResizeObserver(() => {
    try { embedded?.Resize(); } catch (_) {}
  });
  resizeObserver.observe(parent);
  embedded.LoadModelFromFileList(files);
}

async function finishMesh(format, surfaceInfo) {
  if (disposed || !embedded || ready) return;
  try {
    const model = embedded.GetModel();
    if (!model || model.MeshCount() === 0) throw new Error('noGeometry');
    const viewer = embedded.GetViewer();
    const sphere = viewer.GetBoundingSphere(() => true);
    if (sphere) viewer.FitSphereToWindow(sphere, false);
    viewer.Render();
    initialMeshCamera = viewer.GetCamera().Clone();
    await waitFrames(2);
    const box = viewer.GetBoundingBox(() => true);
    const meshCount = model.MeshCount();
    const triangleCount = typeof model.TriangleCount === 'function'
      ? model.TriangleCount()
      : (surfaceInfo?.triangles ?? 0);
    const vertexCount = typeof model.VertexCount === 'function'
      ? model.VertexCount()
      : (surfaceInfo?.vertices ?? 0);
    const sourceUnits = (format === 'gltf' || format === 'glb') ? 'm' : 'unknown';
    let displayUnits = sourceUnits;
    if (['step', 'stp', 'iges', 'igs'].includes(format)) displayUnits = 'mm';
    const limitations = [
      surfaceInfo?.limitations,
      'Rendered surface mesh only. Dimensions, materials, tolerances and manufacturing validity are not verified.',
    ].filter(Boolean).join(' ');
    let bounds;
    if (box) {
      bounds = {
        min: [box.min.x, box.min.y, box.min.z],
        max: [box.max.x, box.max.y, box.max.z],
      };
    } else if (sphere) {
      bounds = {
        center: [sphere.center.x, sphere.center.y, sphere.center.z],
        radius: sphere.radius,
      };
    } else {
      throw new Error('noBounds');
    }
    readyWith({
      format,
      sourceUnits,
      displayUnits,
      bounds,
      meshCount,
      triangleCount,
      vertexCount,
      missingResourceCount: manifest?.missing?.length ?? 0,
      limitations: limitations.slice(0, 512),
    });
  } catch (error) {
    fail('renderFailed', error?.message || 'renderFailed');
  }
}

function orbitMesh(deltaYaw) {
  if (!embedded) return false;
  const viewer = embedded.GetViewer();
  const camera = viewer.GetCamera().Clone();
  const center = camera.center;
  const up = camera.up;
  const length = Math.hypot(up.x, up.y, up.z) || 1;
  const axis = { x: up.x / length, y: up.y / length, z: up.z / length };
  const v = {
    x: camera.eye.x - center.x,
    y: camera.eye.y - center.y,
    z: camera.eye.z - center.z,
  };
  const cos = Math.cos(deltaYaw);
  const sin = Math.sin(deltaYaw);
  const dot = v.x * axis.x + v.y * axis.y + v.z * axis.z;
  const cross = {
    x: axis.y * v.z - axis.z * v.y,
    y: axis.z * v.x - axis.x * v.z,
    z: axis.x * v.y - axis.y * v.x,
  };
  const rotated = {
    x: v.x * cos + cross.x * sin + axis.x * dot * (1 - cos),
    y: v.y * cos + cross.y * sin + axis.y * dot * (1 - cos),
    z: v.z * cos + cross.z * sin + axis.z * dot * (1 - cos),
  };
  camera.eye.x = center.x + rotated.x;
  camera.eye.y = center.y + rotated.y;
  camera.eye.z = center.z + rotated.z;
  viewer.SetCamera(camera);
  viewer.Render();
  return true;
}

function zoomMesh(factor) {
  if (!embedded) return false;
  const viewer = embedded.GetViewer();
  const camera = viewer.GetCamera().Clone();
  camera.eye.x = camera.center.x + (camera.eye.x - camera.center.x) * factor;
  camera.eye.y = camera.center.y + (camera.eye.y - camera.center.y) * factor;
  camera.eye.z = camera.center.z + (camera.eye.z - camera.center.z) * factor;
  viewer.SetCamera(camera);
  viewer.Render();
  return true;
}

function fitMesh() {
  if (!embedded) return false;
  const viewer = embedded.GetViewer();
  const sphere = viewer.GetBoundingSphere(() => true);
  if (sphere) viewer.FitSphereToWindow(sphere, false);
  viewer.Render();
  return true;
}

function resetMesh() {
  if (!embedded || !initialMeshCamera) return false;
  const viewer = embedded.GetViewer();
  viewer.SetCamera(initialMeshCamera.Clone());
  viewer.Render();
  return true;
}

function parseGltfJson(buffer, isGlb) {
  const bytes = new Uint8Array(buffer);
  let jsonBytes = bytes;
  if (isGlb) {
    if (bytes.length < 20 ||
        bytes[0] !== 0x67 || bytes[1] !== 0x6c || bytes[2] !== 0x54 || bytes[3] !== 0x46) {
      throw new Error('invalidGlb');
    }
    const view = new DataView(buffer);
    const version = view.getUint32(4, true);
    const length = view.getUint32(8, true);
    if (version !== 2 || length !== bytes.length) throw new Error('invalidGlb');
    const chunkLength = view.getUint32(12, true);
    const chunkType = view.getUint32(16, true);
    if (chunkType !== 0x4e4f534a || 20 + chunkLength > bytes.length) {
      throw new Error('invalidGlb');
    }
    jsonBytes = bytes.subarray(20, 20 + chunkLength);
  }
  return JSON.parse(new TextDecoder().decode(jsonBytes));
}

async function checkGltfCompression(file, format) {
  if (format !== 'gltf' && format !== 'glb') return;
  const buffer = await file.slice(0, 8 * 1024 * 1024).arrayBuffer();
  if (buffer.byteLength < 8) return;
  let documentValue;
  try {
    documentValue = parseGltfJson(buffer, format === 'glb');
  } catch (_) {
    return; // the actual reader reports the typed parse failure
  }
  const required = Array.isArray(documentValue?.extensionsRequired)
    ? documentValue.extensionsRequired
    : [];
  const unsupported = required.filter(name => [
    'KHR_draco_mesh_compression',
    'EXT_meshopt_compression',
    'KHR_texture_basisu',
  ].includes(name));
  if (unsupported.length) {
    throw new Error('unsupportedCompression');
  }
}

function command(name) {
  try {
    if (dxfViewer) {
      switch (name) {
        case 'zoomIn': zoomDxf(0.8); return true;
        case 'zoomOut': zoomDxf(1.25); return true;
        case 'fit': fitDxf(); return true;
        case 'reset': resetDxf(); return true;
        default: return false;
      }
    }
    if (embedded) {
      switch (name) {
        case 'zoomIn': return zoomMesh(0.88);
        case 'zoomOut': return zoomMesh(1.14);
        case 'fit': return fitMesh();
        case 'reset': return resetMesh();
        case 'orbitLeft': return orbitMesh(0.12);
        case 'orbitRight': return orbitMesh(-0.12);
        default: return false;
      }
    }
    return false;
  } catch (_) {
    return false;
  }
}

function imageSize(dataUrl) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve({ width: image.naturalWidth, height: image.naturalHeight });
    image.onerror = () => reject(new Error('captureImage'));
    image.src = dataUrl;
  });
}

async function capture(requestId) {
  try {
    await waitFrames(1);
    let dataUrl = '';
    if (dxfViewer) {
      dxfViewer.Render();
      const canvas = dxfViewer.GetCanvas();
      dataUrl = canvas.toDataURL('image/png');
    } else if (embedded) {
      const viewer = embedded.GetViewer();
      viewer.Render();
      const canvas = viewer.GetCanvas();
      dataUrl = canvas.toDataURL('image/png');
      if (!dataUrl || dataUrl.length < 1000) {
        dataUrl = viewer.GetImageAsDataUrl(canvas.width, canvas.height, false);
      }
    } else {
      throw new Error('notReady');
    }
    if (!dataUrl || !dataUrl.startsWith('data:image/png;base64,')) {
      throw new Error('capturePng');
    }
    const size = await imageSize(dataUrl);
    if (size.width < 1 || size.height < 1 ||
        size.width > 8192 || size.height > 8192) {
      throw new Error('captureDimensions');
    }
    frameSequence += 1;
    post({
      type: 'capture',
      requestId,
      dataUrl,
      width: size.width,
      height: size.height,
      frameSequence,
    });
  } catch (error) {
    post({
      type: 'captureError',
      requestId,
      message: String(error?.message ?? error).slice(0, 200),
    });
  }
}

async function load() {
  try {
    if (!native || typeof native.postEvent !== 'function') {
      throw new Error('nativeBridge');
    }
    if (!/^[0-9a-f-]{36}$/i.test(session)) throw new Error('session');
    say('Loading…');
    const manifestResponse = await fetch(
      '/session/' + encodeURIComponent(session) + '/manifest.json',
      { cache: 'no-store', credentials: 'omit' });
    if (!manifestResponse.ok) throw new Error('manifest');
    manifest = await manifestResponse.json();
    if (!manifest || manifest.session !== session) throw new Error('manifestSession');
    document.body.classList.toggle('dark', manifest.options?.theme === 'dark');
    const mainBytes = await fetchVerified(manifest.main);
    const files = [fileFor(manifest.main, mainBytes)];
    for (const entry of manifest.resources ?? []) {
      files.push(fileFor(entry, await fetchVerified(entry)));
    }
    const format = String(manifest.format || '').toLowerCase();
    if (format === 'dxf') {
      await loadDxf(mainBytes, 'dxf');
    } else if (format === 'dwg') {
      await loadDwg(mainBytes);
    } else if (['step', 'stp', 'iges', 'igs', 'brep'].includes(format)) {
      await loadOcct(mainBytes, format);
    } else if (['glb', 'gltf', 'obj', 'stl', '3mf'].includes(format)) {
      await checkGltfCompression(files[0], format);
      await loadMesh(files, format);
    } else {
      throw new Error('unsupportedFormat');
    }
  } catch (error) {
    fail(
      String(error?.message || 'loadFailed').includes('Compression')
        ? 'unsupportedCompression'
        : 'loadFailed',
      error?.message || 'loadFailed');
  }
}

window.floeCadViewer = { command, capture, dispose };
window.addEventListener('pagehide', dispose);
window.addEventListener('unhandledrejection', event => {
  if (!ready) fail('renderFailed', event.reason?.message || 'renderFailed');
});
window.addEventListener('error', event => {
  if (!ready) fail('renderFailed', event.message || 'renderFailed');
});

load();
