// SPDX-License-Identifier: MPL-2.0
// Pure request builders for the extended 2D CAD editing surface. This module
// contains NO DOM code and NO engine mutation: it only turns UI values into the
// typed operations the Rust engine accepts, and interprets engine replies.
//
// Supported engine operations (see CADEngine/src/lib.rs capabilities v2):
// addLine/addCircle/addArc/addLwPolyline/addText/addDimension, move/copy/
// rotate/scale/mirror, trim/extend/offset, layer management, a batch wrapper
// and read-only queries.

const KIND_BY_IMAGE_KEY = {
  Line: 'line',
  Circle: 'circle',
  Arc: 'arc',
  LwPolyline: 'lwpolyline',
  Text: 'text',
  Leader: 'leader',
  Dimension: 'dimension',
};

/** Engine image key -> UI kind. */
export function entityKind(row) {
  const key = row?.type ?? Object.keys(row?.image ?? {})[0] ?? '';
  return KIND_BY_IMAGE_KEY[key] ?? key.toLowerCase();
}

/** The engine image body of a query row (e.g. row.image.Line). */
export function entityBody(row) {
  const image = row?.image ?? {};
  const key = Object.keys(image)[0];
  return key ? image[key] : null;
}

/** Representative anchor point for centering the view on a row. */
export function entityAnchor(row) {
  const body = entityBody(row);
  if (!body) return null;
  const kind = entityKind(row);
  if (kind === 'line') return body.start ?? null;
  if (kind === 'circle' || kind === 'arc') return body.center ?? null;
  if (kind === 'text' || kind === 'leader') return body.insertion_point ?? body.vertices?.[0] ?? null;
  if (kind === 'lwpolyline') {
    const vertex = body.vertices?.[0]?.location ?? body.vertices?.[0];
    return vertex ? { x: vertex.x, y: vertex.y } : null;
  }
  return row?.bounds?.min ? { x: row.bounds.min[0], y: row.bounds.min[1] } : null;
}

/** Whether a query row's bounds intersect the window rectangle. */
export function boundsInWindow(row, min, max) {
  const bounds = row?.bounds;
  if (!bounds || !Array.isArray(bounds.min) || !Array.isArray(bounds.max)) return false;
  const [x1, y1] = [Math.min(min.x, max.x), Math.min(min.y, max.y)];
  const [x2, y2] = [Math.max(min.x, max.x), Math.max(min.y, max.y)];
  return bounds.min[0] <= x2 && bounds.max[0] >= x1 && bounds.min[1] <= y2 && bounds.max[1] >= y1;
}

function finite(value, what) {
  if (!Number.isFinite(value)) throw new Error(`Invalid ${what}`);
  return value;
}

function point(values, what = 'point') {
  if (!Array.isArray(values) || values.length < 2) throw new Error(`Invalid ${what}`);
  return [finite(Number(values[0]), what), finite(Number(values[1]), what), 0];
}

/**
 * Build a create request. `values` are UI strings/numbers; throws a
 * user-facing message when a value is missing or invalid.
 */
export function buildCreate(kind, values) {
  const layer = String(values.layer ?? '').trim() || '0';
  switch (kind) {
    case 'line':
      return { operation: 'addLine', start: point(values.start, 'start point'), end: point(values.end, 'end point'), layer };
    case 'circle': {
      const radius = finite(Number(values.radius), 'radius');
      if (radius <= 0) throw new Error('Radius must be positive');
      return { operation: 'addCircle', center: point(values.center, 'center'), radius, layer };
    }
    case 'arc': {
      const radius = finite(Number(values.radius), 'radius');
      if (radius <= 0) throw new Error('Radius must be positive');
      return {
        operation: 'addArc',
        center: point(values.center, 'center'),
        radius,
        startAngle: finite(Number(values.startAngle), 'start angle'),
        endAngle: finite(Number(values.endAngle), 'end angle'),
        layer,
      };
    }
    case 'rectangle': {
      const a = point(values.start, 'first corner');
      const b = point(values.end, 'second corner');
      if (a[0] === b[0] && a[1] === b[1]) throw new Error('Rectangle needs two distinct corners');
      const points = [[a[0], a[1]], [b[0], a[1]], [b[0], b[1]], [a[0], b[1]]];
      return { operation: 'addLwPolyline', points, closed: true, layer };
    }
    case 'polyline': {
      const points = String(values.points ?? '')
        .split(';')
        .map(pair => pair.trim())
        .filter(Boolean)
        .map(pair => {
          const [x, y] = pair.split(',').map(value => Number(value.trim()));
          if (!Number.isFinite(x) || !Number.isFinite(y)) throw new Error(`Invalid polyline point '${pair}'`);
          return [x, y];
        });
      if (points.length < 2) throw new Error('Polyline needs at least two points');
      return { operation: 'addLwPolyline', points, closed: values.closed === true, layer };
    }
    case 'text': {
      const height = finite(Number(values.height), 'text height');
      if (height <= 0) throw new Error('Text height must be positive');
      return { operation: 'addText', position: point(values.position, 'position'), text: String(values.text ?? ''), height, layer };
    }
    case 'leader': {
      const vertices = String(values.points ?? '')
        .split(';')
        .map(pair => pair.trim())
        .filter(Boolean)
        .map(pair => {
          const [x, y] = pair.split(',').map(value => Number(value.trim()));
          if (!Number.isFinite(x) || !Number.isFinite(y)) throw new Error(`Invalid leader point '${pair}'`);
          return [x, y, 0];
        });
      if (vertices.length < 2) throw new Error('Leader needs at least two vertices');
      return { operation: 'addLeader', points: vertices, layer };
    }
    case 'dimension': {
      const dimensionKind = String(values.dimensionKind ?? 'linear');
      const points = String(values.points ?? '')
        .split(';')
        .map(pair => pair.trim())
        .filter(Boolean)
        .map(pair => {
          const [x, y] = pair.split(',').map(value => Number(value.trim()));
          if (!Number.isFinite(x) || !Number.isFinite(y)) throw new Error(`Invalid dimension point '${pair}'`);
          return [x, y, 0];
        });
      const required = dimensionKind === 'angular' ? 3 : 2;
      if (points.length !== required) throw new Error(`${dimensionKind} dimension needs ${required} points`);
      const request = { operation: 'addDimension', kind: dimensionKind, points, layer };
      if (values.offset !== undefined && values.offset !== '' && Number.isFinite(Number(values.offset))) {
        request.offset = Number(values.offset);
      }
      if (dimensionKind === 'linear' && values.rotation !== undefined && values.rotation !== '' && Number.isFinite(Number(values.rotation))) {
        request.rotation = Number(values.rotation);
      }
      return request;
    }
    default:
      throw new Error(`Unknown create kind '${kind}'`);
  }
}

/** One transform operation for a handle. `op` is move/copy/rotate/scale/mirror. */
export function buildTransform(op, handle, values) {
  if (!handle) throw new Error('Select an entity first');
  switch (op) {
    case 'move':
    case 'copy':
      return { operation: op, handle, delta: [finite(Number(values.dx), 'ΔX'), finite(Number(values.dy), 'ΔY'), 0] };
    case 'rotate':
      return {
        operation: 'rotate',
        handle,
        center: point(values.center, 'rotation center'),
        angle: finite(Number(values.angle), 'angle'),
      };
    case 'scale':
      return {
        operation: 'scale',
        handle,
        center: point(values.center, 'scale center'),
        factor: finite(Number(values.factor), 'scale factor'),
      };
    case 'mirror':
      return { operation: 'mirror', handle, axis: [point(values.axisStart, 'axis start'), point(values.axisEnd, 'axis end')] };
    default:
      throw new Error(`Unknown transform '${op}'`);
  }
}

/** Batch wrapper for multi-selection transform/delete. */
export function buildBatch(operations) {
  if (!Array.isArray(operations) || operations.length === 0) throw new Error('Nothing to apply');
  if (operations.length === 1) return operations[0];
  return { operation: 'batch', operations };
}

export function buildDelete(handles) {
  return buildBatch(handles.map(handle => ({ operation: 'delete', handle })));
}

export function buildTrimExtend(op, target, boundary, pick) {
  if (!target || !boundary) throw new Error('Trim/extend needs a target and a boundary entity');
  if (!pick || !Number.isFinite(pick.x) || !Number.isFinite(pick.y)) throw new Error('Pick a point on the part to remove or extend');
  if (op === 'trim') return { operation: 'trim', handle: target, boundary, pick: [pick.x, pick.y, 0] };
  if (op === 'extend') return { operation: 'extend', handle: target, boundary, pick: [pick.x, pick.y, 0] };
  throw new Error(`Unknown trim/extend operation '${op}'`);
}

export function buildOffset(handle, distance, side) {
  if (!handle) throw new Error('Select an entity first');
  const value = finite(Number(distance), 'offset distance');
  if (value <= 0) throw new Error('Offset distance must be positive');
  if (!side || !Number.isFinite(side.x) || !Number.isFinite(side.y)) throw new Error('Pick the offset side');
  return { operation: 'offset', handle, distance: value, side: [side.x, side.y, 0] };
}

export function buildSetLayer(handles, layer) {
  const name = String(layer ?? '').trim();
  if (!name) throw new Error('Choose a layer');
  return buildBatch(handles.map(handle => ({ operation: 'setLayer', handle, layer: name })));
}

export function buildLayerRequest(action, values) {
  const name = String(values.name ?? '').trim();
  if (!name) throw new Error('Layer name is required');
  switch (action) {
    case 'add': {
      const request = { operation: 'addLayer', name };
      if (Number.isInteger(Number(values.color)) && values.color !== '' && values.color !== undefined) request.color = Number(values.color);
      if (values.lineType) request.lineType = String(values.lineType);
      if (Number.isInteger(Number(values.lineWeight)) && values.lineWeight !== '' && values.lineWeight !== undefined) {
        request.lineWeight = Number(values.lineWeight);
      }
      return request;
    }
    case 'update': {
      const request = { operation: 'updateLayer', name };
      if (typeof values.locked === 'boolean') request.locked = values.locked;
      if (typeof values.visible === 'boolean') request.visible = values.visible;
      if (values.color !== undefined && values.color !== '') request.color = Number(values.color);
      if (values.lineType) request.lineType = String(values.lineType);
      if (values.lineWeight !== undefined && values.lineWeight !== '') request.lineWeight = Number(values.lineWeight);
      if (!['locked', 'visible', 'color', 'lineType', 'lineWeight'].some(key => request[key] !== undefined)) {
        throw new Error('Nothing to update on this layer');
      }
      return request;
    }
    case 'rename': {
      const to = String(values.to ?? '').trim();
      if (!to) throw new Error('New layer name is required');
      return { operation: 'renameLayer', from: name, to };
    }
    case 'delete':
      return { operation: 'deleteLayer', name };
    default:
      throw new Error(`Unknown layer action '${action}'`);
  }
}

/** Build a read-only query request. */
export function buildQuery(kind, values = {}) {
  switch (kind) {
    case 'drawing':
      return { operation: 'drawing' };
    case 'layers':
      return { operation: 'layers' };
    case 'entities': {
      const request = { operation: 'entities', offset: values.offset ?? 0, limit: values.limit ?? 500 };
      if (values.type) request.type = values.type;
      if (values.layer) request.layer = values.layer;
      if (values.text) request.text = values.text;
      if (Array.isArray(values.handles) && values.handles.length) request.handles = values.handles;
      return request;
    }
    case 'snap': {
      const source = values.point ?? {};
      const coords = Array.isArray(source) ? source : [source.x, source.y];
      return { operation: 'snap', point: point(coords, 'snap point'), tolerance: finite(Number(values.tolerance), 'tolerance') };
    }
    case 'measure': {
      const request = { operation: 'measure', kind: values.measureKind };
      if (Array.isArray(values.points) && values.points.length) request.points = values.points.map(value => point(value, 'measure point'));
      if (Array.isArray(values.handles) && values.handles.length) request.handles = values.handles;
      return request;
    }
    case 'check':
      return { operation: 'check', tolerance: Number.isFinite(Number(values.tolerance)) ? Number(values.tolerance) : 0.001 };
    case 'locate': {
      if (!values.handle) throw new Error('Select an entity to locate');
      return { operation: 'locate', handle: values.handle };
    }
    default:
      throw new Error(`Unknown query '${kind}'`);
  }
}

/**
 * Pick the best snap candidate near `point`. Preference order is endpoint,
 * intersection, center, midpoint; the engine already sorted by distance, so a
 * closer candidate of a lower-priority kind wins only when much closer.
 */
export function selectSnapCandidate(candidates, { kinds } = {}) {
  const allowed = Array.isArray(kinds) && kinds.length ? kinds : ['endpoint', 'midpoint', 'center', 'intersection'];
  const priority = { endpoint: 0, intersection: 1, center: 2, midpoint: 3 };
  let best = null;
  for (const candidate of candidates ?? []) {
    if (!allowed.includes(candidate.kind)) continue;
    if (!Number.isFinite(candidate.point?.[0]) || !Number.isFinite(candidate.point?.[1])) continue;
    const score = candidate.distance + (priority[candidate.kind] ?? 4) * 1e-9;
    if (!best || score < best.score) best = { ...candidate, score };
  }
  if (best) delete best.score;
  return best;
}

/** A short human summary of a measure reply. */
export function formatMeasure(result, zh) {
  if (!result) return '';
  const value = Number(result.value);
  if (!Number.isFinite(value)) return '';
  const number = Math.abs(value) >= 1000 ? value.toFixed(2) : value.toFixed(4);
  const labels = {
    distance: zh ? '距离' : 'Distance',
    angle: zh ? '角度' : 'Angle',
    radius: zh ? '半径' : 'Radius',
    perimeter: zh ? '周长' : 'Perimeter',
    area: zh ? '面积' : 'Area',
  };
  return `${labels[result.kind] ?? result.kind}: ${number} ${result.unit ?? ''}`.trim();
}

/** Check summary counts for the assistant/status line. */
export function formatCheck(result, zh) {
  if (!result) return '';
  const zero = result.zeroLength?.length ?? 0;
  const duplicates = result.duplicates?.length ?? 0;
  const open = result.openContours?.length ?? 0;
  const dangling = result.danglingEndpoints?.length ?? 0;
  return (zh ? '零长度 %d · 重复 %d · 开放轮廓 %d · 悬挂端点 %d' : 'zero-length %d · duplicates %d · open contours %d · dangling %d')
    .replace('%d', zero).replace('%d', duplicates).replace('%d', open).replace('%d', dangling);
}
