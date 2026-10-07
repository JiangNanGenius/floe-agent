// SPDX-License-Identifier: MPL-2.0
// Behavioral tests for the extended CAD command surface: pure request builders
// plus the bundled Rust engine driven through the real WASM bindings.
//
//   node FloeAgent/scripts/test_cad_commands.mjs
//
// Exit 0 means every assertion passed. No GUI, no filesystem writes.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const viewers = path.resolve(scriptDir, '../FloeApp/Resources/EngineeringViewers');
const load = name => pathToFileURL(path.join(viewers, name)).href;

const commands = await import(load('cad-commands.js'));
const request = await import(load('cad-request.js'));
const { default: init, CadSession } = await import(load('floe_cad_engine.js'));
await init({ module_or_path: fs.readFileSync(path.join(viewers, 'floe_cad_engine_bg.wasm')) });

const failures = [];
let passes = 0;
function check(name, condition, detail = '') {
  if (condition) passes += 1;
  else failures.push(detail ? `${name} — ${detail}` : name);
}
const session = new CadSession(fs.readFileSync(path.join(viewers, 'sample-editable.dwg')), 'dwg');
const inspect = () => JSON.parse(session.inspect(0, 500));
const query = request => JSON.parse(session.query(JSON.stringify(request)));
const edit = request => {
  try { return { summary: JSON.parse(session.edit(JSON.stringify(request))), error: null }; }
  catch (error) { return { summary: null, error: String(error?.message ?? error) }; }
};

// ---------------------------------------------------------------------------
// 1. Pure request builders
// ---------------------------------------------------------------------------
{
  const line = commands.buildCreate('line', { start: [0, 0], end: [10, 5], layer: 'Walls' });
  check('build line', line.operation === 'addLine' && line.start[2] === 0 && line.layer === 'Walls');
  const rect = commands.buildCreate('rectangle', { start: [0, 0], end: [4, 3] });
  check('build rectangle', rect.operation === 'addLwPolyline' && rect.closed === true && rect.points.length === 4);
  check('rectangle rejects coincident corners', (() => { try { commands.buildCreate('rectangle', { start: [1, 1], end: [1, 1] }); return false; } catch { return true; } })());
  const poly = commands.buildCreate('polyline', { points: '0,0; 5,0 ; 5,5', closed: false });
  check('build polyline', poly.operation === 'addLwPolyline' && poly.points.length === 3);
  check('polyline rejects bad points', (() => { try { commands.buildCreate('polyline', { points: '0,0;x,5' }); return false; } catch { return true; } })());
  const move = commands.buildTransform('move', 'AB', { dx: 1, dy: 2 });
  check('build move', move.operation === 'move' && move.delta[1] === 2);
  const batch = commands.buildBatch([move, { operation: 'delete', handle: 'CD' }]);
  check('build batch', batch.operation === 'batch' && batch.operations.length === 2);
  check('single batch collapses', commands.buildBatch([move]).operation === 'move');
  const trim = commands.buildTrimExtend('trim', 'A', 'B', { x: 5, y: 5 });
  check('build trim', trim.operation === 'trim' && trim.pick[0] === 5);
  check('trim requires pick', (() => { try { commands.buildTrimExtend('trim', 'A', 'B', null); return false; } catch { return true; } })());
  const offset = commands.buildOffset('A', 2, { x: 0, y: 1 });
  check('build offset', offset.operation === 'offset' && offset.distance === 2);
  check('offset rejects negative distance', (() => { try { commands.buildOffset('A', -1, { x: 0, y: 1 }); return false; } catch { return true; } })());
  const layer = commands.buildLayerRequest('update', { name: 'Walls', locked: true });
  check('build layer update', layer.operation === 'updateLayer' && layer.locked === true);
  const snap = commands.buildQuery('snap', { point: { x: 1, y: 2 }, tolerance: 0.5 });
  check('build snap query', snap.operation === 'snap' && snap.tolerance === 0.5);
  const candidate = commands.selectSnapCandidate([
    { kind: 'midpoint', point: [0, 0], distance: 0.1000005 },
    { kind: 'endpoint', point: [1, 1], distance: 0.1 },
  ]);
  check('snap prefers endpoint on a near tie', candidate.kind === 'endpoint', JSON.stringify(candidate));
  check('snap kinds filter', commands.selectSnapCandidate([{ kind: 'center', point: [0, 0], distance: 0.1 }], { kinds: ['endpoint'] }) === null);
  check('format measure', commands.formatMeasure({ kind: 'distance', value: 5, unit: 'mm' }, true).includes('5.0000'));
  const window = commands.boundsInWindow({ bounds: { min: [0, 0], max: [2, 2] } }, { x: -1, y: -1 }, { x: 1, y: 1 });
  check('window selection', window === true && commands.boundsInWindow({ bounds: { min: [5, 5], max: [6, 6] } }, { x: -1, y: -1 }, { x: 1, y: 1 }) === false);
}

// ---------------------------------------------------------------------------
// 1b. Worker-boundary request normalization (string stays single-encoded)
// ---------------------------------------------------------------------------
{
  const json = '{"operation":"addLine","start":[0,0,0],"end":[1,0,0],"layer":"0"}';
  check('string request stays single-encoded', request.normalizeEngineRequest(json) === json);
  check('object request encoded exactly once', request.normalizeEngineRequest({ operation: 'addLine' }) === '{"operation":"addLine"}');
  check('empty request rejected', (() => { try { request.normalizeEngineRequest(''); return false; } catch { return true; } })());
  check('non-object request rejected', (() => { try { request.normalizeEngineRequest(42); return false; } catch { return true; } })());
  check('invalid JSON string rejected before wasm', (() => { try { request.normalizeEngineRequest('{oops'); return false; } catch { return true; } })());
  // Regression: native passes a string; the worker must hand the engine that
  // exact string, never JSON.stringify(string) (which corrupts the command).
  const normalized = request.normalizeEngineRequest(json);
  check('normalized string is not double-quoted', !normalized.startsWith('"') && normalized.includes('"operation"'));
}

// ---------------------------------------------------------------------------
// 2. Bundled engine capabilities
// ---------------------------------------------------------------------------
{
  const info = inspect();
  const capabilities = info.capabilities;
  check('engine advertises capabilities v2', capabilities.version === 2, JSON.stringify(capabilities.version));
  check('engine advertises trim/extend/offset', ['trim', 'extend', 'offset'].every(op => capabilities.operations.includes(op)));
  check('engine advertises dimensions', capabilities.entityCreation.dimensions.length === 5);
  check('engine advertises snap and measure kinds', capabilities.snap.kinds.includes('intersection') && capabilities.measure.kinds.includes('area'));
  check('engine reports drawing header', (() => { const drawing = query({ operation: 'drawing' }); return typeof drawing.unit === 'string' && drawing.editable === true; })());
}

// ---------------------------------------------------------------------------
// 3. Create / modify / trim / offset / layers / measure through the real engine
// ---------------------------------------------------------------------------
{
  const base = inspect().entityCount;
  const line = edit({ operation: 'addLine', start: [0, 0, 0], end: [100, 0, 0], layer: '0' });
  check('create line', line.error === null && line.summary.created.length === 1, String(line.error));
  const crossing = edit({ operation: 'addLine', start: [50, -10, 0], end: [50, 10, 0], layer: '0' });
  check('create crossing line', crossing.error === null);
  const horizontal = line.summary.created[0];
  const vertical = crossing.summary.created[0];

  const created = [];
  created.push(edit({ operation: 'addCircle', center: [20, 20, 0], radius: 5, layer: '0' }).summary?.created?.[0]);
  created.push(edit({ operation: 'addArc', center: [0, 0, 0], radius: 10, startAngle: 0, endAngle: 1.5707963267948966, layer: '0' }).summary?.created?.[0]);
  created.push(edit({ operation: 'addLwPolyline', points: [[60, 60], [80, 60], [80, 80]], closed: true, layer: '0' }).summary?.created?.[0]);
  check('create circle/arc/polyline', created.every(Boolean), JSON.stringify(created));
  check('creation at non-zero Z is rejected', edit({ operation: 'addLine', start: [0, 0, 5], end: [1, 0, 5], layer: '0' }).error !== null);

  const copy = edit({ operation: 'copy', handle: horizontal, delta: [0, 40, 0] });
  check('copy creates a new handle', copy.error === null && copy.summary.created.length === 1 && copy.summary.created[0] !== horizontal);
  const rotate = edit({ operation: 'rotate', handle: copy.summary.created[0], center: [0, 0, 0], angle: 1.5707963267948966 });
  check('rotate', rotate.error === null);
  const scale = edit({ operation: 'scale', handle: created[0], center: [20, 20, 0], factor: 3 });
  check('scale', scale.error === null);
  const mirror = edit({ operation: 'mirror', handle: copy.summary.created[0], axis: [[0, 0, 0], [0, 10, 0]] });
  check('mirror', mirror.error === null);

  const trim = edit({ operation: 'trim', handle: horizontal, boundary: vertical, pick: [10, 0, 0] });
  check('trim removes the picked segment', trim.error === null, String(trim.error));
  const rows = query({ operation: 'entities', type: 'Line' }).entities;
  const trimmed = rows.find(row => row.handle === horizontal);
  check('trim kept the right half', trimmed && Math.abs(trimmed.image.Line.start.x - 50) < 1e-9, JSON.stringify(trimmed?.image?.Line?.start));

  const farBoundary = edit({ operation: 'addLine', start: [40, -20, 0], end: [60, -20, 0], layer: '0' });
  const extend = edit({ operation: 'extend', handle: vertical, boundary: farBoundary.summary.created[0], pick: [50, -9, 0] });
  check('extend to a boundary', extend.error === null, String(extend.error));

  const offset = edit({ operation: 'offset', handle: horizontal, distance: 2, side: [60, 5, 0] });
  check('offset creates a new entity', offset.error === null && offset.summary.created.length === 1, String(offset.error));

  const addLayer = edit({ operation: 'addLayer', name: 'QA-Layer', color: 3, lineType: 'Continuous', lineWeight: 25 });
  check('add layer', addLayer.error === null, String(addLayer.error));
  const setLayer = edit({ operation: 'setLayer', handle: horizontal, layer: 'QA-Layer' });
  check('move entity to layer', setLayer.error === null);
  check('deleting a referenced layer is rejected', edit({ operation: 'deleteLayer', name: 'QA-Layer' }).error !== null);

  const missing = edit({ operation: 'addLayer', name: 'QA-Missing', color: 3, lineType: 'DoesNotExist' });
  check('unknown linetype rejected', missing.error !== null);

  const snap = query({ operation: 'snap', point: [50, 0], tolerance: 0.5 });
  check('snap returns candidates', snap.candidates.some(candidate => candidate.kind === 'intersection'), JSON.stringify(snap.candidates));
  const radius = query({ operation: 'measure', kind: 'radius', handles: [created[0]] });
  check('measure radius after scale', Math.abs(radius.value - 15) < 1e-9, String(radius.value));
  const area = query({ operation: 'measure', kind: 'area', handles: [created[2]] });
  check('measure area', Math.abs(area.value - 200) < 1e-9, String(area.value));
  const checkReply = query({ operation: 'check', tolerance: 0.001 });
  check('check reply is structured', Array.isArray(checkReply.zeroLength) && checkReply.layerUsage['0'] >= 1);

  const batch = edit({ operation: 'batch', operations: [
    { operation: 'addLine', start: [0, 100, 0], end: [5, 100, 0], layer: '0' },
    { operation: 'addCircle', center: [0, 100, 0], radius: 2, layer: '0' },
  ] });
  check('atomic batch creates both entities', batch.error === null && batch.summary.created.length === 2, String(batch.error));
  const countAfterBatch = inspect().entityCount;
  const rejected = edit({ operation: 'batch', operations: [
    { operation: 'addLine', start: [0, 200, 0], end: [5, 200, 0], layer: '0' },
    { operation: 'addCircle', center: [0, 200, 0], radius: -1, layer: '0' },
  ] });
  check('rejected batch leaves nothing behind', rejected.error !== null && inspect().entityCount === countAfterBatch);

  // Save runs the engine's own round-trip gate before returning bytes.
  const bytes = session.save();
  check('save returns DWG bytes', bytes.length > 0 && String.fromCharCode(bytes[0], bytes[1]) === 'AC', String(bytes.length));
  check('total created entities accounted for', inspect().entityCount >= base + 7);
}

// ---------------------------------------------------------------------------
// Verdict
// ---------------------------------------------------------------------------
console.log(`cad-commands: ${passes} passed, ${failures.length} failed`);
for (const failure of failures) console.log(`  FAIL ${failure}`);
process.exit(failures.length ? 1 : 0);
