// SPDX-License-Identifier: MPL-2.0
// Read-only adapter over the bundled Online3DViewer 0.18 static importer.
//
// It consumes the SAME imported model, viewer and OV namespace that viewer.js
// already created for a static mesh or for the local OCCT display conversion.
// No second three.js copy, WebGL context, document model or remote decoder is
// introduced. The adapter only reports the actual imported scene and renders
// bounded temporary capture cameras; it never writes or imports a file.

const MAX_STATE_NODES = 200;
const MAX_CAPTURE_FRAMES = 8;
const PNG_PREFIX = 'data:image/png;base64,';

function clamp(value, minimum, maximum) {
  return Math.min(Math.max(value, minimum), maximum);
}

function finiteNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function projectionName(OV, mode) {
  return mode === OV.ProjectionMode.Orthographic ? 'orthographic' : 'perspective';
}

function projectionValue(OV, name) {
  if (name === 'orthographic') return OV.ProjectionMode.Orthographic;
  if (name === 'perspective') return OV.ProjectionMode.Perspective;
  return null;
}

// Reads the actual IHDR dimensions of the PNG data URL. The adapter never
// substitutes the requested size for the bytes that were really returned.
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

function count(model, method) {
  try {
    const value = model?.[method]?.();
    return Math.max(0, Math.trunc(finiteNumber(value, 0)));
  } catch {
    return 0;
  }
}

function meshName(model, index) {
  try {
    const name = model.GetMesh(index)?.GetName?.();
    if (name) return String(name);
  } catch {}
  return `Mesh ${index + 1}`;
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

/**
 * Creates the read-only scene controller for an already imported static model.
 * `OV` is the exact namespace exported by mesh.js; `viewer` and `model` come
 * from the existing EmbeddedViewer. The returned object is registered by
 * viewer.js on the same window.floeEngineeringScene* bridge used by glTF.
 */
export function createEngineeringStaticScene({OV, viewer, model, package: pkg,
  backend, conversion = null, onState = null, say = null}) {
  if (!OV || !viewer || !model || typeof model.GetRootNode !== 'function') {
    throw new Error(say
      ? say('静态三维查看器状态不可用。', 'The static 3D viewer state is unavailable.')
      : 'The static 3D viewer state is unavailable.');
  }
  const sourceSHA256 = String(pkg?.provenance?.sourceSHA256 || '');
  const documentName = String(pkg?.name || '');
  const backendName = String(backend || 'online3DViewer');
  const diagnostics = pkg?.diagnostics || {};
  const missingResources = asArray(pkg?.missingReferences).map(String);
  const unsupportedExtensions = Array.from(new Set([
    ...asArray(diagnostics.unsupportedExtensions),
    ...asArray(diagnostics.unsupportedRequiredExtensions),
  ].map(String)));
  const warnings = [];
  if (missingResources.length) {
    warnings.push(say
      ? say(`缺少 ${missingResources.length} 个引用资源。`, `${missingResources.length} referenced resources are missing.`)
      : `${missingResources.length} referenced resources are missing.`);
  }
  if (unsupportedExtensions.length) {
    const english = `Unsupported extensions: ${unsupportedExtensions.join(', ')}`;
    warnings.push(say ? say(`未支持的扩展：${unsupportedExtensions.join(', ')}`, english) : english);
  }
  if (backendName === 'occt') {
    warnings.push(String(conversion?.limitations
      || 'Display triangulation is lossy; names, colors, analytic surfaces and tolerances are not preserved.'));
  }
  let disposed = false;

  // Build the COMPLETE source-model node tree once. Paths are scene-local and
  // stable for these bytes; they are deliberately not CAD face/edge ids.
  const nodes = [];
  const walk = (node, parentPath) => {
    if (!node) return;
    const id = typeof node.GetId === 'function' ? node.GetId() : nodes.length;
    const path = parentPath ? `${parentPath}/${id}` : `scene0/node${id}`;
    const meshIndices = asArray(node.GetMeshIndices?.());
    const childNodes = asArray(node.GetChildNodes?.());
    const rawName = node.GetName?.();
    nodes.push({
      path,
      name: String(rawName || (meshIndices.length ? 'Mesh' : 'Node')),
      type: meshIndices.length ? 'MeshNode' : (childNodes.length ? 'Group' : 'Node'),
      childCount: childNodes.length,
      meshName: meshIndices.length ? meshName(model, meshIndices[0]) : null,
      instanceCount: meshIndices.length,
      visible: true,
    });
    for (const child of childNodes) walk(child, path);
  };
  walk(model.GetRootNode(), '');

  function actualBounds() {
    let sphere = null;
    let box = null;
    try { sphere = viewer.GetBoundingSphere(() => true); } catch {}
    try { box = viewer.GetBoundingBox(() => true); } catch {}
    if (!sphere || !box) return null;
    const center = sphere.center;
    const radius = Math.max(finiteNumber(sphere.radius, 0), 0.0001);
    return {
      minimum: [finiteNumber(box.min?.x, 0), finiteNumber(box.min?.y, 0), finiteNumber(box.min?.z, 0)],
      maximum: [finiteNumber(box.max?.x, 0), finiteNumber(box.max?.y, 0), finiteNumber(box.max?.z, 0)],
      center: [finiteNumber(center?.x, 0), finiteNumber(center?.y, 0), finiteNumber(center?.z, 0)],
      radius,
    };
  }

  function countTextures() {
    // Count distinct texture bindings actually present on imported materials.
    const textures = new Set();
    const materialCount = count(model, 'MaterialCount');
    for (let index = 0; index < materialCount; index += 1) {
      let material = null;
      try { material = model.GetMaterial(index); } catch {}
      if (!material) continue;
      for (const slot of ['diffuseMap', 'bumpMap', 'normalMap', 'emissiveMap']) {
        const map = material[slot];
        if (map && typeof map.IsValid === 'function' && map.IsValid()) {
          // Count the texture data, not the slot: one texture used by several
          // slots is still one imported texture.
          textures.add(`${String(map.name || '')}:${map.buffer?.byteLength ?? 0}`);
        }
      }
    }
    return textures.size;
  }

  function stateObject() {
    const bounds = actualBounds();
    const meshCount = count(model, 'MeshCount');
    return {
      documentName,
      sourceSHA256,
      backend: backendName,
      ready: !disposed,
      nodeCount: nodes.length,
      meshCount,
      instancedMeshCount: count(model, 'MeshInstanceCount'),
      skinnedMeshCount: 0,
      morphMeshCount: 0,
      materialCount: count(model, 'MaterialCount'),
      textureCount: countTextures(),
      lightCount: 0,
      nodes: nodes.slice(0, MAX_STATE_NODES),
      cameras: [],
      scenes: [{index: 0, name: documentName || 'Scene 1'}],
      activeSceneIndex: 0,
      clips: [],
      activeCameraIndex: null,
      activeClipIndex: null,
      timeSeconds: 0,
      durationSeconds: 0,
      playing: false,
      loopMode: 'repeat',
      speed: 1,
      bounds,
      missingResources,
      unsupportedExtensions,
      warnings,
      truncatedNodes: nodes.length > MAX_STATE_NODES,
    };
  }

  function state() {
    return JSON.stringify(stateObject());
  }

  function publishState() {
    try { onState?.(stateObject()); } catch {}
  }

  function hierarchyPage(payload) {
    const total = nodes.length;
    const offset = Math.max(0, Math.min(total, Math.trunc(finiteNumber(payload.offset, 0))));
    const limit = Math.max(1, Math.min(1000, Math.trunc(finiteNumber(payload.limit, 200))));
    const page = nodes.slice(offset, offset + limit).map((node) => ({...node}));
    return {
      sourceSHA256,
      sceneIndex: 0,
      total,
      offset,
      nextOffset: offset + page.length < total ? offset + page.length : null,
      nodes: page,
    };
  }

  function fit() {
    try {
      const sphere = viewer.GetBoundingSphere(() => true);
      if (sphere) viewer.FitSphereToWindow(sphere, false);
      viewer.Render();
    } catch {}
  }

  function cameraSnapshot() {
    const camera = viewer.GetCamera();
    return {
      projection: projectionName(OV, viewer.GetProjectionMode()),
      eye: [finiteNumber(camera?.eye?.x, 0), finiteNumber(camera?.eye?.y, 0), finiteNumber(camera?.eye?.z, 0)],
      center: [finiteNumber(camera?.center?.x, 0), finiteNumber(camera?.center?.y, 0), finiteNumber(camera?.center?.z, 0)],
      up: [finiteNumber(camera?.up?.x, 0), finiteNumber(camera?.up?.y, 0), finiteNumber(camera?.up?.z, 0)],
      fov: finiteNumber(camera?.fov, 45),
    };
  }

  function command(raw) {
    let payload = raw;
    try { if (typeof raw === 'string') payload = JSON.parse(raw); } catch { return state(); }
    if (!payload || typeof payload !== 'object') return state();
    if (payload.action === 'hierarchy') return JSON.stringify(hierarchyPage(payload));
    switch (payload.action) {
      case 'scene':
        if (finiteNumber(payload.index, -1) !== 0) {
          throw new Error('This original static model has one display scene.');
        }
        break;
      case 'camera':
        if (payload.index !== null && payload.index !== undefined) {
          throw new Error('This original static model has no source scene cameras.');
        }
        break;
      case 'clip':
        if (payload.index !== null && payload.index !== undefined) {
          throw new Error('This original static model has no animation clips.');
        }
        break;
      case 'play':
      case 'pause':
      case 'seek':
        throw new Error('This original static model has no animation playback.');
      case 'loop':
      case 'speed':
        // Playback settings are meaningless without clips; keep the call
        // harmless instead of inventing an animation state.
        break;
      case 'fit':
        fit();
        break;
      case 'nodeVisibility':
        throw new Error('Node visibility is not exposed for this original static model.');
      default:
        throw new Error(`Unsupported scene command: ${String(payload.action)}`);
    }
    publishState();
    return state();
  }

  function failureFrames(views, reason) {
    return {
      frames: [],
      failures: views.map((_, viewIndex) => ({viewIndex, reason})),
      sourceSHA256,
    };
  }

  function capture(raw) {
    let request = raw;
    try { if (typeof raw === 'string') request = JSON.parse(raw); } catch { request = {}; }
    request = request && typeof request === 'object' ? request : {};
    const views = asArray(request.views).slice(0, MAX_CAPTURE_FRAMES);
    if (!views.length) {
      return JSON.stringify({frames: [], failures: [{viewIndex: 0, reason: 'no capture views'}], sourceSHA256});
    }
    const width = clamp(Math.trunc(finiteNumber(request.width, 1024)), 64, 2048);
    const height = clamp(Math.trunc(finiteNumber(request.height, 768)), 64, 2048);
    const maximumPNGBytes = clamp(finiteNumber(request.maximumPNGBytes, 8 * 1024 * 1024),
      1024, 16 * 1024 * 1024);
    const maximumTotalBytes = clamp(finiteNumber(request.maximumTotalBytes, 32 * 1024 * 1024),
      1024, 32 * 1024 * 1024);
    const requestedProjection = request.projection === null || request.projection === undefined
      ? null : String(request.projection);
    if (requestedProjection !== null && !['perspective', 'orthographic'].includes(requestedProjection)) {
      return JSON.stringify(failureFrames(views, 'unsupported projection'));
    }
    if (request.clipIndex !== null && request.clipIndex !== undefined) {
      return JSON.stringify(failureFrames(views,
        'animation clips are unavailable for this original static model'));
    }
    if (request.timeSeconds !== null && request.timeSeconds !== undefined
        && finiteNumber(request.timeSeconds, 0) > 0) {
      return JSON.stringify(failureFrames(views,
        'an animation timeline is unavailable for this original static model'));
    }
    let savedProjection;
    let savedCamera;
    let sphere;
    try {
      savedProjection = viewer.GetProjectionMode();
      savedCamera = viewer.GetCamera().Clone();
      sphere = viewer.GetBoundingSphere(() => true);
    } catch (error) {
      return JSON.stringify(failureFrames(views, String(error?.message ?? error)));
    }
    if (!sphere) return JSON.stringify(failureFrames(views, 'no scene bounds'));
    const center = sphere.center;
    const target = {
      x: finiteNumber(center?.x, 0),
      y: finiteNumber(center?.y, 0),
      z: finiteNumber(center?.z, 0),
    };
    const radius = Math.max(finiteNumber(sphere.radius, 0), 0.0001);
    const savedFov = clamp(finiteNumber(savedCamera?.fov, 45), 1, 179);
    const savedProjectionName = projectionName(OV, savedProjection);
    const failures = [];
    const frames = [];
    let totalBytes = 0;
    let restorationFailure = null;
    try {
      for (let viewIndex = 0; viewIndex < views.length; viewIndex += 1) {
        const view = views[viewIndex] || {};
        try {
          const projection = requestedProjection || savedProjectionName;
          const mode = projectionValue(OV, projection);
          if (mode === null) throw new Error('unsupported projection');
          if (viewer.GetProjectionMode() !== mode) viewer.SetProjectionMode(mode);
          const azimuth = finiteNumber(view.azimuthDegrees, 0);
          const elevation = clamp(finiteNumber(view.elevationDegrees, 0), -89, 89);
          const distanceScale = clamp(finiteNumber(view.distanceScale, 1), 0.1, 5);
          const azimuthRadians = azimuth * Math.PI / 180;
          const elevationRadians = elevation * Math.PI / 180;
          const direction = {
            x: Math.cos(elevationRadians) * Math.sin(azimuthRadians),
            y: Math.sin(elevationRadians),
            z: Math.cos(elevationRadians) * Math.cos(azimuthRadians),
          };
          const distance = radius / Math.sin((savedFov * Math.PI / 180) / 2) * 1.35 * distanceScale;
          const eye = {
            x: target.x + direction.x * distance,
            y: target.y + direction.y * distance,
            z: target.z + direction.z * distance,
          };
          const up = Math.abs(direction.y) > 0.995
            ? {x: 0, y: 0, z: 1} : {x: 0, y: 1, z: 0};
          viewer.SetCamera(new OV.Camera(
            new OV.Coord3D(eye.x, eye.y, eye.z),
            new OV.Coord3D(target.x, target.y, target.z),
            new OV.Coord3D(up.x, up.y, up.z),
            savedFov));
          viewer.Render();
          const dataURL = viewer.GetImageAsDataUrl(width, height, false);
          const dimensions = pngDimensions(dataURL);
          if (!dimensions) throw new Error('the renderer did not return a PNG frame');
          if (dimensions.width < 64 || dimensions.width > 2048
              || dimensions.height < 64 || dimensions.height > 2048) {
            throw new Error('captured PNG dimensions are outside the 64...2048 bound');
          }
          const byteEstimate = Math.ceil(dataURL.length * 3 / 4);
          if (byteEstimate > maximumPNGBytes) throw new Error('png exceeds frame limit');
          if (totalBytes + byteEstimate > maximumTotalBytes) {
            throw new Error('capture exceeds total limit');
          }
          totalBytes += byteEstimate;
          frames.push({
            dataURL,
            width: dimensions.width,
            height: dimensions.height,
            viewIndex,
            azimuthDegrees: azimuth,
            elevationDegrees: elevation,
            projection,
            renderer: 'online3DViewer',
            backend: backendName,
            timeSeconds: 0,
            clipIndex: null,
            sourceSHA256,
            state: stateObject(),
          });
        } catch (error) {
          failures.push({viewIndex, reason: String(error?.message ?? error)});
        }
      }
    } finally {
      // Restore the exact pre-capture projection/camera even after a failure.
      try {
        if (viewer.GetProjectionMode() !== savedProjection) {
          viewer.SetProjectionMode(savedProjection);
        }
        viewer.SetCamera(savedCamera);
        viewer.Render();
      } catch (error) {
        restorationFailure = String(error?.message ?? error);
      }
      publishState();
    }
    if (restorationFailure !== null) {
      frames.length = 0;
      failures.push({viewIndex: 0,
        reason: `The previous view could not be restored; capture discarded: ${restorationFailure}`});
    }
    return JSON.stringify({frames, failures, sourceSHA256});
  }

  function reviewContext() {
    const snapshot = stateObject();
    return {
      type: backendName === 'occt' ? 'CAD surface display' : 'mesh',
      source: documentName,
      sourceSHA256,
      backend: backendName,
      nodeCount: snapshot.nodeCount,
      meshCount: snapshot.meshCount,
      instancedMeshCount: snapshot.instancedMeshCount,
      materialCount: snapshot.materialCount,
      bounds: snapshot.bounds,
      hierarchy: nodes.slice(0, 60),
      missingResources,
      unsupportedExtensions,
      warnings,
      conversion: conversion || null,
      limitations: 'Rendered display geometry only. Dimensions, tolerances, feature history, B-Rep topology and manufacturing validity are not verified.',
    };
  }

  function dispose() {
    disposed = true;
  }

  return {
    state,
    stateObject,
    command,
    capture,
    fit,
    reviewContext,
    cameraSnapshot,
    dispose,
  };
}
