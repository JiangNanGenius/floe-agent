// SPDX-License-Identifier: MPL-2.0
//
// C04C bridge for a native `.floecad` DIRECTORY package.
//
// Kotlin validates the real package (manifest/document/OS3D blobs), writes one
// bounded derived GLB in glTF metres and serves the preserved B-Rep blobs to
// this local-only page. The pinned C04A viewer remains the renderer; this
// module:
//   * rewrites the rendered glb facts back to the package identity,
//   * converts the viewer's metre-space bounds to source millimetres,
//   * tessellates B-Rep-only bodies through the SAME pinned offline OCCT
//     ReadBrepFile worker used by the standalone .brep viewer, applies every
//     saved body/instance transform, and appends the resulting STL surfaces
//     to the one viewer model.
// It never reads a second source format, never edits the pinned viewer/mesh
// code or bytes, and never changes the original package.
const SESSION_PATTERN = /^[0-9a-f-]{36}$/i;
const BREP_MAX_BYTES = 10 * 1024 * 1024;
const BREP_MAX_TOTAL_TRIANGLES = 2_000_000;

let packageInfo = null;
let packageSession = '';
let brepGroups = [];
let brepFilesPromise = null;
let brepResult = null;
let meshPatched = false;

async function fetchVerifiedResource(entry) {
  if (!entry || typeof entry.token !== 'string' ||
      typeof entry.sha256 !== 'string' ||
      !Number.isInteger(entry.byteCount)) {
    throw new Error('invalidBrepResource');
  }
  const response = await fetch(
    '/resource/' + encodeURIComponent(packageSession) + '/' +
      encodeURIComponent(entry.token),
    { cache: 'no-store', credentials: 'omit' });
  if (!response.ok) throw new Error('brepFetch');
  const buffer = await response.arrayBuffer();
  if (buffer.byteLength !== entry.byteCount) throw new Error('brepLength');
  const digest = await crypto.subtle.digest('SHA-256', buffer);
  const hex = [...new Uint8Array(digest)]
    .map(value => value.toString(16).padStart(2, '0'))
    .join('');
  if (hex !== entry.sha256.toLowerCase()) throw new Error('brepDigest');
  return new Uint8Array(buffer);
}

function runBrepWorker(bytes) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL('occt-worker.js', location.href));
    const timer = setTimeout(() => {
      try { worker.terminate(); } catch (_) {}
      reject(new Error('brepTimeout'));
    }, 45_000);
    worker.onmessage = ({ data }) => {
      clearTimeout(timer);
      try { worker.terminate(); } catch (_) {}
      if (data && data.buffer) resolve(data);
      else reject(new Error(String(data?.error || 'brepWorker')));
    };
    worker.onerror = event => {
      clearTimeout(timer);
      try { worker.terminate(); } catch (_) {}
      reject(new Error(event?.message || 'brepWorker'));
    };
    worker.postMessage({ bytes, extension: 'brep' }, [bytes.buffer]);
  });
}

function matrixValues(raw) {
  if (!Array.isArray(raw) || raw.length !== 16) return null;
  const values = raw.map(value => Number(value));
  if (!values.every(value => Number.isFinite(value))) return null;
  if (Math.abs(values[3]) > 1e-9 || Math.abs(values[7]) > 1e-9 ||
      Math.abs(values[11]) > 1e-9 || Math.abs(values[15] - 1) > 1e-9) {
    return null;
  }
  return values;
}

function transformStl(source, matrices, budget) {
  if (!(source instanceof ArrayBuffer) || source.byteLength < 84) {
    throw new Error('brepStl');
  }
  const view = new DataView(source);
  const count = view.getUint32(80, true);
  if (count < 1 || 84 + count * 50 !== source.byteLength) {
    throw new Error('brepStlLength');
  }
  const accepted = [];
  let triangles = 0;
  for (const raw of matrices) {
    const matrix = matrixValues(raw);
    if (matrix == null) continue;
    if (triangles + count > budget) break;
    accepted.push(matrix);
    triangles += count;
  }
  if (accepted.length === 0) {
    return { bytes: null, triangles: 0, vertices: 0, placements: 0, dropped: matrices.length };
  }
  const output = new ArrayBuffer(84 + triangles * 50);
  const sourceBytes = new Uint8Array(source);
  const outputBytes = new Uint8Array(output);
  outputBytes.set(sourceBytes.subarray(0, 80), 0);
  const target = new DataView(output);
  target.setUint32(80, triangles, true);
  let offset = 84;
  const scale = 0.001; // source millimetres -> glTF metres
  for (const m of accepted) {
    for (let triangle = 0; triangle < count; triangle += 1) {
      const start = 84 + triangle * 50;
      const points = [];
      for (let vertex = 0; vertex < 3; vertex += 1) {
        const at = start + 12 + vertex * 12;
        const x = view.getFloat32(at, true);
        const y = view.getFloat32(at + 4, true);
        const z = view.getFloat32(at + 8, true);
        const wx = (m[0] * x + m[4] * y + m[8] * z + m[12]) * scale;
        const wy = (m[1] * x + m[5] * y + m[9] * z + m[13]) * scale;
        const wz = (m[2] * x + m[6] * y + m[10] * z + m[14]) * scale;
        if (![wx, wy, wz].every(Number.isFinite)) throw new Error('brepTransform');
        points.push([wx, wy, wz]);
      }
      const ux = points[1][0] - points[0][0];
      const uy = points[1][1] - points[0][1];
      const uz = points[1][2] - points[0][2];
      const vx = points[2][0] - points[0][0];
      const vy = points[2][1] - points[0][1];
      const vz = points[2][2] - points[0][2];
      let nx = uy * vz - uz * vy;
      let ny = uz * vx - ux * vz;
      let nz = ux * vy - uy * vx;
      const length = Math.hypot(nx, ny, nz);
      if (length > 1e-12) {
        nx /= length; ny /= length; nz /= length;
      } else {
        nx = 0; ny = 0; nz = 0;
      }
      target.setFloat32(offset, nx, true);
      target.setFloat32(offset + 4, ny, true);
      target.setFloat32(offset + 8, nz, true);
      for (let vertex = 0; vertex < 3; vertex += 1) {
        const at = offset + 12 + vertex * 12;
        target.setFloat32(at, points[vertex][0], true);
        target.setFloat32(at + 4, points[vertex][1], true);
        target.setFloat32(at + 8, points[vertex][2], true);
      }
      target.setUint16(offset + 48, 0, true);
      offset += 50;
    }
  }
  return {
    bytes: output,
    triangles,
    vertices: triangles * 3,
    placements: accepted.length,
    dropped: matrices.length - accepted.length,
  };
}

function safeStlName(name) {
  const base = String(name || 'brep')
    .replace(/[^A-Za-z0-9._-]/g, '_')
    .slice(0, 60);
  return (base || 'brep') + '.stl';
}

async function buildBrepFiles() {
  const files = [];
  let triangles = 0;
  let vertices = 0;
  let failed = 0;
  let overflow = 0;
  let budget = BREP_MAX_TOTAL_TRIANGLES;
  for (const group of brepGroups) {
    try {
      if (!group || typeof group.token !== 'string' ||
          !Array.isArray(group.matrices)) {
        failed += 1;
        continue;
      }
      if (Number(group.byteCount) > BREP_MAX_BYTES) {
        overflow += group.matrices.length;
        continue;
      }
      const bytes = await fetchVerifiedResource(group);
      const result = await runBrepWorker(bytes);
      const transformed = transformStl(result.buffer, group.matrices, budget);
      budget -= transformed.triangles;
      overflow += transformed.dropped;
      if (!transformed.bytes || transformed.triangles === 0) {
        failed += 1;
        continue;
      }
      const baseName = safeStlName(group.name);
      files.push(new File([transformed.bytes], baseName.replace(
        /\.stl$/, `-${files.length + 1}.stl`), {
        type: 'model/stl',
      }));
      triangles += transformed.triangles;
      vertices += transformed.vertices;
      if (budget <= 0) break;
    } catch (_) {
      failed += 1;
    }
  }
  return { files, triangles, vertices, failed, overflow };
}

function ensureBrepFiles() {
  if (brepFilesPromise == null) {
    brepFilesPromise = buildBrepFiles().then(result => {
      brepResult = result;
      return result;
    });
  }
  return brepFilesPromise;
}

async function installBrepSupport() {
  if (brepGroups.length === 0 || meshPatched) return;
  const module = await import('./mesh.js');
  const prototype = module.EmbeddedViewer?.prototype;
  if (!prototype || typeof prototype.LoadModelFromFileList !== 'function') {
    throw new Error('meshLoaderUnavailable');
  }
  const original = prototype.LoadModelFromFileList;
  prototype.LoadModelFromFileList = function (files) {
    const base = files ? Array.from(files) : [];
    // A B-Rep-only / image-free package has an intentionally empty derived
    // GLB. Load only the tessellated surfaces instead of asking the glTF
    // importer to accept an empty scene.
    const baseOnly = Number(packageInfo.meshCount) === 0 ? [] : base;
    ensureBrepFiles().then(
      result => {
        const combined = result.files.length > 0
          ? baseOnly.concat(result.files)
          : base;
        try {
          original.call(this, combined);
        } catch (_) {
          original.call(this, base);
        }
      },
      () => {
        original.call(this, base);
      },
    );
  };
  meshPatched = true;
}

function scaleBounds(bounds, factor) {
  if (!bounds || typeof bounds !== 'object') return;
  for (const key of ['min', 'max', 'center']) {
    if (Array.isArray(bounds[key])) {
      bounds[key] = bounds[key].map(value =>
        typeof value === 'number' ? value * factor : value);
    }
  }
  if (typeof bounds.radius === 'number') bounds.radius *= factor;
}

function brepLimitation() {
  if (brepGroups.length === 0) return '';
  const result = brepResult;
  if (!result) return 'B-Rep surfaces were not tessellated in this preview.';
  const parts = [];
  if (result.failed > 0) {
    parts.push(result.failed +
      (result.failed === 1 ? ' B-Rep group could not be tessellated' : ' B-Rep groups could not be tessellated') +
      '; those surfaces are not shown.');
  }
  if (result.overflow > 0) {
    parts.push(result.overflow +
      (result.overflow === 1 ? ' B-Rep placement was' : ' B-Rep placements were') +
      ' outside the bounded preview tessellation and are not shown.');
  }
  return parts.join(' ');
}

export async function installFloecadBridge() {
  const params = new URLSearchParams(location.search);
  if (params.get('package') !== '1') return false;
  const session = params.get('session') || '';
  const native = window.C04Bridge;
  if (!native || typeof native.postEvent !== 'function' ||
      !SESSION_PATTERN.test(session)) {
    return false;
  }
  try {
    const response = await fetch(
      '/session/' + encodeURIComponent(session) + '/manifest.json',
      { cache: 'no-store', credentials: 'omit' });
    if (response.ok) {
      const manifest = await response.json();
      if (manifest && manifest.session === session &&
          manifest.sourceFormat === 'floecad' && manifest.package) {
        packageInfo = manifest.package;
        packageSession = session;
        brepGroups = Array.isArray(packageInfo.brepBodies)
          ? packageInfo.brepBodies
          : [];
      }
    }
  } catch (_) {
    packageInfo = null;
  }
  if (!packageInfo) return false;
  try {
    await installBrepSupport();
  } catch (_) {
    // The GLB (mesh bodies/images) still renders; Kotlin reports the missing
    // B-Rep surfaces as a partial preview rather than a fake full result.
    brepResult = {
      files: [], triangles: 0, vertices: 0,
      failed: brepGroups.length, overflow: 0,
    };
  }
  const original = native.postEvent.bind(native);
  const wrapped = function (json) {
    let text = json;
    try {
      const event = JSON.parse(json);
      if (event && event.type === 'ready' && event.facts) {
        const facts = event.facts;
        facts.format = 'floecad';
        facts.sourceUnits = 'mm';
        facts.displayUnits = typeof packageInfo.displayUnits === 'string'
          ? packageInfo.displayUnits
          : 'mm';
        // The viewer reports a glTF metre-space scene. The package contract
        // and every visible bound are source millimetres.
        scaleBounds(facts.bounds, 1000);
        const packageLimitations = typeof packageInfo.limitations === 'string'
          ? packageInfo.limitations
          : '';
        const viewerLimitations = typeof facts.limitations === 'string'
          ? facts.limitations
          : '';
        facts.limitations = [packageLimitations, viewerLimitations, brepLimitation()]
          .filter(Boolean)
          .join(' ')
          .slice(0, 512);
        if (Number.isInteger(packageInfo.missingCount)) {
          const failed = brepResult ? brepResult.failed + brepResult.overflow : 0;
          facts.missingResourceCount = Math.max(0, packageInfo.missingCount + failed);
        }
        if (brepGroups.length > 0) {
          // The B-Rep STL surfaces are part of the actual rendered model, so
          // report the package mesh counts plus the tessellated placements.
          const extraTriangles = brepResult?.triangles ?? 0;
          const extraVertices = brepResult?.vertices ?? 0;
          const extraMeshes = brepResult?.files?.length ?? 0;
          if (Number.isInteger(packageInfo.meshCount)) {
            facts.meshCount = packageInfo.meshCount + extraMeshes;
          }
          if (Number.isInteger(packageInfo.triangleCount)) {
            facts.triangleCount = packageInfo.triangleCount + extraTriangles;
          }
          if (Number.isInteger(packageInfo.vertexCount)) {
            facts.vertexCount = packageInfo.vertexCount + extraVertices;
          }
        } else {
          if (Number.isInteger(packageInfo.meshCount)) facts.meshCount = packageInfo.meshCount;
          if (Number.isInteger(packageInfo.triangleCount)) facts.triangleCount = packageInfo.triangleCount;
          if (Number.isInteger(packageInfo.vertexCount)) facts.vertexCount = packageInfo.vertexCount;
        }
        event.facts = facts;
        text = JSON.stringify(event);
      }
    } catch (_) {
      text = json;
    }
    return original(text);
  };
  try {
    native.postEvent = wrapped;
    return true;
  } catch (_) {
    // Some WebView JS-interface objects expose read-only members. The Kotlin
    // host independently accepts the viewer's generic glb/m facts for a
    // native package and rewrites them from the validated package identity,
    // so a failed wrapper is a no-op rather than a failed preview.
    try {
      window.C04Bridge = { postEvent: wrapped };
      return true;
    } catch (_) {
      return false;
    }
  }
}
