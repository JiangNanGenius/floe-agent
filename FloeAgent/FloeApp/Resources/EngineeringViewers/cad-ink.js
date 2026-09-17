// SPDX-License-Identifier: MPL-2.0
// Pure geometry, capability and stroke-capture helpers for the world-coordinate
// CAD Pencil annotation layer. This module contains NO DOM code, NO engine
// mutation and NO persistence fallback.
//
// The durable write path is the native engine's single typed operation
// `addStroke` (FloeAgent/ThirdParty/CADEngine/src/lib.rs):
//   { operation: "addStroke", points: [[x,y,z], ...], color?: ACI 1..255,
//     lineWeight?: canonical 1/100 mm }
// The engine validates the whole stroke, creates FLOE_ANNOTATION on demand and
// commits exactly one undo snapshot. This module only prepares that request and
// reads the engine's own `capabilities.addStroke` metadata; it never fakes a
// save, never writes a parallel annotation store, and never assumes the
// operation exists when the bundled engine does not advertise it.

/** Dedicated layer the engine creates on demand for persisted annotations. */
export const ANNOTATION_LAYER = 'FLOE_ANNOTATION';

/** Hard upper bound the engine documents for one stroke. */
export const DEFAULT_MAX_POINTS = 256;

/** Simplify tolerance expressed in CSS pixels when none is supplied. */
export const DEFAULT_TOLERANCE_PX = 2.5;

/** Ignore pointer samples closer than this many CSS pixels to the previous one. */
export const MIN_SAMPLE_DISTANCE_PX = 1.5;

/** Hard cap on raw captured samples before simplification (bounded memory). */
export const MAX_CAPTURED_POINTS = 4096;

/** Largest absolute world coordinate the engine accepts. */
export const MAX_COORDINATE = 1e12;

/**
 * Five clearly labelled ACI colors. ACI 7 is the adaptive black/white index:
 * it renders black on a light drawing and white on a dark one, so it stays
 * visible on both themes. ACI 255 is explicit white for dark backgrounds.
 * ACI 250 is a near-black for light backgrounds.
 */
export const ACI_COLORS = Object.freeze([
  { aci: 1, zh: '红', en: 'Red', hex: '#e53935' },
  { aci: 3, zh: '绿', en: 'Green', hex: '#2e9e5b' },
  { aci: 5, zh: '蓝', en: 'Blue', hex: '#1e6fd9' },
  { aci: 7, zh: '黑白', en: 'Black/White', adaptive: true },
  { aci: 255, zh: '白', en: 'White', hex: '#ffffff' },
]);

/**
 * Canonical line weights (1/100 mm) that the engine round-trips. Chosen from
 * `INDEXED_LINE_WEIGHTS` in lib.rs; every value here is accepted by `addStroke`.
 */
export const LINE_WEIGHT_PRESETS = Object.freeze([
  { value: 0, zh: '细', en: 'Thin' },
  { value: 25, zh: '0.25', en: '0.25' },
  { value: 50, zh: '0.50', en: '0.50' },
  { value: 100, zh: '1.00', en: '1.00' },
  { value: 200, zh: '2.00', en: '2.00' },
]);

/** Default selected width (0.25 mm). */
export const DEFAULT_LINE_WEIGHT = 25;

/** The four informational AC18/DWG read notices that are not blocking. */
const INFORMATIONAL_WARNING_PREFIXES = Object.freeze([
  'Reading DWG file version: AC',
  'AC18 inner header: page_map_address=',
]);

function informationalAc18Read(message) {
  return message.startsWith('AC18: Read ') && (
    message.endsWith(' page records from page map')
    || message.endsWith(' section descriptors from section map'));
}

/** Convert a DOMRect-relative client point to canvas-local coordinates. */
export function clientToCanvas(point, rect) {
  if (!rect) throw new Error('clientToCanvas: rect required');
  return { x: point.x - rect.left, y: point.y - rect.top };
}

/**
 * Canvas-local point -> viewer scene coordinates.
 *
 * Mirrors the bundled dxf.js (read-only, not modified):
 *   SetView sets an orthographic camera with left=-w/2, right=w/2, top=h/2,
 *   bottom=-h/2, position=(center.x, center.y, 1), rotation 0; zoom starts at 1
 *   and changes with pinch/scroll. `_CanvasToSceneCoord(x,y)` is
 *   `new Vector3(x*2/W-1, -y*2/H+1, 1).unproject(camera)`, which for that
 *   symmetric, unrotated orthographic camera is
 *   scene.x = position.x + ndcX*(right-left)/(2*zoom)
 *   scene.y = position.y + ndcY*(top-bottom)/(2*zoom).
 * `W`/`H` are the viewer's CSS canvas dimensions (`canvasWidth`/`canvasHeight`),
 * so the math is identical at any device pixel ratio.
 */
export function screenToScene(point, view) {
  const { camera, canvasWidth, canvasHeight } = view ?? {};
  if (!camera || !camera.position) throw new Error('screenToScene: camera required');
  if (!(canvasWidth > 0) || !(canvasHeight > 0)) throw new Error('screenToScene: canvas size required');
  const zoom = camera.zoom ?? 1;
  if (!(zoom > 0)) throw new Error('screenToScene: zoom must be positive');
  const ndcX = (point.x * 2) / canvasWidth - 1;
  const ndcY = (-point.y * 2) / canvasHeight + 1;
  const halfWidth = (camera.right - camera.left) / 2 / zoom;
  const halfHeight = (camera.top - camera.bottom) / 2 / zoom;
  return { x: camera.position.x + ndcX * halfWidth, y: camera.position.y + ndcY * halfHeight };
}

/** Scene coordinates -> absolute world coordinates (viewer.GetOrigin compensation). */
export function sceneToWorld(scene, origin = { x: 0, y: 0 }) {
  return { x: scene.x + (origin?.x ?? 0), y: scene.y + (origin?.y ?? 0) };
}

/** Absolute world coordinates -> scene coordinates. */
export function worldToScene(world, origin = { x: 0, y: 0 }) {
  return { x: world.x - (origin?.x ?? 0), y: world.y - (origin?.y ?? 0) };
}

/** Canvas-local point -> absolute world coordinates. */
export function screenToWorld(point, view) {
  return sceneToWorld(screenToScene(point, view), view?.origin);
}

/** Absolute world coordinates -> canvas-local point (inverse of screenToWorld). */
export function worldToScreen(world, view) {
  const { camera, canvasWidth, canvasHeight } = view ?? {};
  if (!camera || !camera.position) throw new Error('worldToScreen: camera required');
  if (!(canvasWidth > 0) || !(canvasHeight > 0)) throw new Error('worldToScreen: canvas size required');
  const zoom = camera.zoom ?? 1;
  if (!(zoom > 0)) throw new Error('worldToScreen: zoom must be positive');
  const scene = worldToScene(world, view?.origin);
  const halfWidth = (camera.right - camera.left) / 2 / zoom;
  const halfHeight = (camera.top - camera.bottom) / 2 / zoom;
  const ndcX = (scene.x - camera.position.x) / halfWidth;
  const ndcY = (scene.y - camera.position.y) / halfHeight;
  return { x: ((ndcX + 1) * canvasWidth) / 2, y: ((1 - ndcY) * canvasHeight) / 2 };
}

/** World units spanned by one CSS pixel at the current camera. */
export function worldPerCssPixel(view) {
  const { camera, canvasWidth } = view ?? {};
  if (!camera || !(canvasWidth > 0)) throw new Error('worldPerCssPixel: camera and canvas required');
  const zoom = camera.zoom ?? 1;
  if (!(zoom > 0)) throw new Error('worldPerCssPixel: zoom must be positive');
  const worldWidth = (camera.right - camera.left) / zoom;
  const perPixel = worldWidth / canvasWidth;
  return Number.isFinite(perPixel) && perPixel > 0 ? perPixel : 0;
}

/** Convert a simplify tolerance in CSS pixels to world units. */
export function cssToleranceToWorld(px, view) {
  const perPixel = worldPerCssPixel(view);
  if (!(px > 0) || !perPixel) return 0;
  return px * perPixel;
}

/** Euclidean distance between two world points. */
export function worldDistance(a, b) {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

/** Resolve the CSS color for an ACI swatch (adaptive for ACI 7). */
export function aciCssColor(aci, dark = false) {
  const entry = ACI_COLORS.find(color => color.aci === aci);
  if (!entry) return dark ? '#ffffff' : '#111111';
  if (entry.adaptive) return dark ? '#ffffff' : '#111111';
  return entry.hex;
}

function perpendicularDistance(point, start, end) {
  const dx = end.x - start.x, dy = end.y - start.y;
  const lengthSq = dx * dx + dy * dy;
  if (lengthSq === 0) return Math.hypot(point.x - start.x, point.y - start.y);
  const t = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSq;
  const clamped = Math.max(0, Math.min(1, t));
  return Math.hypot(point.x - (start.x + clamped * dx), point.y - (start.y + clamped * dy));
}

function rdp(points, tolerance) {
  if (points.length < 3) return points.slice();
  let worst = 0, index = 0;
  const start = points[0], end = points[points.length - 1];
  for (let i = 1; i < points.length - 1; i += 1) {
    const distance = perpendicularDistance(points[i], start, end);
    if (distance > worst) { worst = distance; index = i; }
  }
  if (worst <= tolerance) return [start, end];
  const left = rdp(points.slice(0, index + 1), tolerance);
  const right = rdp(points.slice(index), tolerance);
  return left.slice(0, -1).concat(right);
}

/**
 * Reduce a stroke while keeping both endpoints. RDP first, then a uniform
 * stride if the tolerance still leaves more than `maxPoints`. Geometry is
 * preserved within `tolerance`; endpoints are never dropped.
 */
export function reduceStroke(points, { maxPoints = DEFAULT_MAX_POINTS, tolerance = 0 } = {}) {
  const finite = (points ?? []).filter(p => Number.isFinite(p?.x) && Number.isFinite(p?.y));
  if (finite.length < 2) return finite.slice();
  if (!(maxPoints >= 2)) throw new Error('reduceStroke: maxPoints must be at least 2');
  let reduced = rdp(finite, tolerance > 0 ? tolerance : 0);
  if (reduced.length > maxPoints) {
    const stride = (reduced.length - 1) / (maxPoints - 1);
    const sampled = [];
    for (let i = 0; i < maxPoints; i += 1) sampled.push(reduced[Math.round(i * stride)]);
    reduced = sampled;
  }
  return reduced;
}

/**
 * Bounded raw-sample capture with explicit cancellation. DOM-free so the
 * cancel/commit contract can be tested directly. `add` returns whether the
 * sample was retained; `cancel` clears without producing a request; `take`
 * hands the captured samples to the caller and resets.
 */
export function createStrokeCapture({
  maxCaptured = MAX_CAPTURED_POINTS,
  minWorldDistance = 0,
} = {}) {
  let points = [];
  let active = false;
  return {
    begin() { points = []; active = true; },
    add(point) {
      if (!active) return false;
      if (!Number.isFinite(point?.x) || !Number.isFinite(point?.y)) return false;
      if (points.length >= maxCaptured) return false;
      if (minWorldDistance > 0 && points.length > 0
        && worldDistance(point, points[points.length - 1]) < minWorldDistance) return false;
      points.push({ x: point.x, y: point.y, z: Number.isFinite(point.z) ? point.z : 0 });
      return true;
    },
    cancel() { points = []; active = false; },
    take() { const out = points; points = []; active = false; return out; },
    /** Read-only view of the captured samples for a live preview. */
    peek() { return points; },
    get active() { return active; },
    get size() { return points.length; },
  };
}

/**
 * Build the engine's atomic `addStroke` request from world points. Returns
 * null when the stroke cannot form at least one segment; throws only for an
 * invalid bound, so the caller can cancel without committing.
 */
export function buildStrokeRequest(points, {
  maxPoints = DEFAULT_MAX_POINTS,
  tolerance = 0,
  color = null,
  lineWeight = null,
} = {}) {
  const reduced = reduceStroke(points, { maxPoints, tolerance });
  if (reduced.length < 2) return null;
  const request = {
    operation: 'addStroke',
    points: reduced.map(p => [p.x, p.y, Number.isFinite(p.z) ? p.z : 0]),
  };
  if (Number.isInteger(color)) request.color = color;
  if (Number.isInteger(lineWeight)) request.lineWeight = lineWeight;
  return request;
}

/**
 * Read the engine's own `capabilities.addStroke` metadata from an `inspect`
 * payload. Absent/malformed metadata is reported as unsupported, never assumed.
 */
export function readStrokeCapabilities(info) {
  const capability = info?.capabilities;
  const stroke = capability?.addStroke;
  if (!stroke || typeof stroke !== 'object') {
    return { supported: false, reason: 'capabilities-missing' };
  }
  const min = Number(stroke.pointCount?.min);
  const max = Number(stroke.pointCount?.max);
  if (!Number.isInteger(min) || !Number.isInteger(max) || min < 2 || max < min || max > DEFAULT_MAX_POINTS) {
    return { supported: false, reason: 'pointCount-invalid' };
  }
  const color = stroke.color && typeof stroke.color === 'object'
    ? { min: Number(stroke.color.min), max: Number(stroke.color.max) }
    : null;
  const lineWeights = Array.isArray(stroke.lineWeight?.allowed)
    ? stroke.lineWeight.allowed.filter(value => Number.isInteger(value))
    : [];
  return {
    supported: true,
    reason: null,
    version: capability.version ?? null,
    pointCount: { min, max },
    color,
    lineWeights,
    defaultColor: stroke.color?.default ?? null,
    defaultLineWeight: stroke.lineWeight?.default ?? null,
    layer: typeof stroke.layer === 'string' ? stroke.layer : ANNOTATION_LAYER,
    atomicity: stroke.atomicity ?? null,
    history: stroke.history ?? null,
  };
}

/** True for informational DWG/AC18 read warnings that do not block editing. */
export function isInformationalDiagnostic(text) {
  const match = /^\[([^\]]+)\]\s*([\s\S]*)$/.exec(String(text ?? ''));
  if (!match) return false;
  const [, type, message] = match;
  if (type !== 'Warning') return false;
  return INFORMATIONAL_WARNING_PREFIXES.some(prefix => message.startsWith(prefix))
    || informationalAc18Read(message);
}

/**
 * Mirror of the engine's `blocking_diagnostics` gate: omitted diagnostics or a
 * non-informational notice means editing (and therefore ink) is disabled.
 */
export function hasBlockingDiagnostics(info) {
  if (!info) return false;
  if ((Number(info.omittedDiagnostics) || 0) > 0) return true;
  const diagnostics = Array.isArray(info.diagnostics) ? info.diagnostics : [];
  return diagnostics.some(text => !isInformationalDiagnostic(text));
}

/**
 * Combined readiness for ink: engine advertises a valid addStroke capability and
 * the drawing has no blocking diagnostics. `reason` is 'capabilities-missing',
 * 'pointCount-invalid' or 'diagnostics' when not ready.
 */
export function inkReadiness(info) {
  const capabilities = readStrokeCapabilities(info);
  if (!capabilities.supported) {
    return { ready: false, capabilities, reason: capabilities.reason };
  }
  if (hasBlockingDiagnostics(info)) {
    return { ready: false, capabilities, reason: 'diagnostics' };
  }
  return { ready: true, capabilities, reason: null };
}

/** Validate a built request against the engine's advertised limits. */
export function validateStrokeRequest(request, capabilities) {
  const caps = capabilities?.supported ? capabilities : null;
  if (!caps) return { ok: false, reason: 'capabilities-missing' };
  const points = request?.points;
  if (!Array.isArray(points) || points.length < caps.pointCount.min || points.length > caps.pointCount.max) {
    return { ok: false, reason: 'pointCount-out-of-range' };
  }
  for (const point of points) {
    if (!Array.isArray(point) || point.length !== 3
      || !point.every(value => Number.isFinite(value) && Math.abs(value) <= MAX_COORDINATE)) {
      return { ok: false, reason: 'coordinate-out-of-range' };
    }
  }
  if (request.color !== undefined) {
    const range = caps.color ?? { min: 1, max: 255 };
    if (!Number.isInteger(request.color) || request.color < range.min || request.color > range.max) {
      return { ok: false, reason: 'color-out-of-range' };
    }
  }
  if (request.lineWeight !== undefined) {
    if (!Number.isInteger(request.lineWeight)) return { ok: false, reason: 'lineWeight-invalid' };
    if (caps.lineWeights.length > 0 && !caps.lineWeights.includes(request.lineWeight)) {
      return { ok: false, reason: 'lineWeight-not-canonical' };
    }
  }
  return { ok: true, reason: null };
}

/**
 * Which pointer types draw in the current mode. Pen always draws; touch only
 * when the user explicitly enabled "draw with finger"; mouse never does.
 */
export function isDrawPointer(pointerType, { drawWithFinger = false } = {}) {
  if (pointerType === 'pen') return true;
  if (pointerType === 'touch') return drawWithFinger === true;
  return false;
}
