// SPDX-License-Identifier: MPL-2.0
// Component qualification against the actual bundled WASM, not App acceptance.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {fileURLToPath} from 'node:url';
import {webcrypto} from 'node:crypto';
if(!globalThis.crypto)globalThis.crypto=webcrypto;
const assets=new URL('../FloeApp/Resources/EngineeringViewers/',import.meta.url);
const {default:init,CadSession}=await import(new URL('floe_cad_engine.js',assets));
const commands=await import(new URL('cad-commands.js',assets));
const {CadRecoveryJournal,readCadRecovery,replayCadRecovery}=await import(new URL('cad-recovery.js',assets));
await init({module_or_path:fs.readFileSync(new URL('floe_cad_engine_bg.wasm',assets))});
const input=fs.readFileSync(new URL('../ThirdParty/CADEngine/src/fixtures/e22-native-dimassoc.dxf',import.meta.url));
const s=new CadSession(input,'dxf');const inspect=s=>JSON.parse(s.inspect(0,500));
let rows=inspect(s).entities;
const line=rows.find(v=>v.entity.Line);const dim=rows.find(v=>v.entity.Dimension);
assert.deepEqual(dim.operations,['updateDimension']);
assert.equal(commands.supportsOperation(dim,'move'),false);
assert.equal(commands.supportsOperation(dim,'updateDimension'),true);
assert.equal(commands.dimensionDetails(dim).kind,'Linear');
const request={operation:'batch',operations:[{operation:'setLineEndpoints',handle:line.handle,start:[0,0,0],end:[42,0,0]},
 commands.buildDimensionUpdate(dim.handle,{text:'Length <>',textPosition:[20,8],linePosition:[0,6],textRotationDegrees:10})]};
const journal=new CadRecoveryJournal(input,'dxf');
let commit=journal.prepare({operation:'edit',request:JSON.stringify(request)});s.edit(JSON.stringify(request));commit();
assert.equal(commands.dimensionDetails(inspect(s).entities.find(v=>v.handle===dim.handle)).base.actual_measurement,42);
commit=journal.prepare({operation:'undo'});s.undo();commit();
commit=journal.prepare({operation:'redo'});s.redo();commit();
const bytes=s.save();const reopened=new CadSession(bytes,'dxf');
assert.equal(commands.dimensionDetails(inspect(reopened).entities.find(v=>v.handle===dim.handle)).base.text,'Length <>');
const recovery=await journal.serialize();const parsed=await readCadRecovery(recovery);
assert.deepEqual(Buffer.from(parsed.bytes),input);
const restored=replayCadRecovery(parsed,CadSession);
assert.deepEqual(inspect(restored),inspect(s));
assert.deepEqual(restored.save(),s.save());
const tampered=JSON.parse(recovery);tampered.sourceSHA256='0'.repeat(64);
await assert.rejects(readCadRecovery(JSON.stringify(tampered)),/checksum/);
const bad=JSON.parse(recovery);bad.events.push({operation:'edit',request:'{"operation":"delete","handle":"FFFF"}'});
const before=inspect(s);assert.throws(()=>replayCadRecovery(new CadRecoveryJournal(input,'dxf',bad.events),CadSession));assert.deepEqual(before,inspect(s));
// Real-worker recovery: failures do not append events, and import is bound to
// the original drawing currently open (never a different native save target).
let replies=[];globalThis.self={postMessage:value=>replies.push(value)};
await import(new URL('cad-worker.js',assets));
async function call(operation,args={}){
 const id=Math.random();self.onmessage({data:{id,operation,...args}});
 for(let n=0;n<100;n++){await new Promise(r=>setTimeout(r,5));const reply=replies.find(v=>v.id===id);if(reply){if(reply.error)throw Error(reply.error);return reply.result;}}
 throw Error('Worker response timeout');
}
await call('open',{bytes:input,format:'dxf'});
await call('edit',{edit:request});const workerDraft=await call('recovery');
await assert.rejects(call('edit',{edit:{operation:'move',handle:'FFFF',delta:[1,0,0]}}));
assert.equal((await readCadRecovery(await call('recovery'))).events.length,1);
await call('undo');await call('restoreRecovery',{text:workerDraft});
assert.deepEqual((await call('inspect',{offset:0,limit:500})).entities,inspect(s).entities);
const another=new CadRecoveryJournal(fs.readFileSync(new URL('sample-editable.dwg',assets)),'dwg');
await assert.rejects(call('restoreRecovery',{text:await another.serialize()}),/original drawing/);
assert.equal((await call('inspect',{offset:0,limit:500})).entities.length,2);
// Mixed drawing: unsupported content remains selectable as read only, while
// a supported model-space line can change and save in the original format.
const mixed=new CadSession(fs.readFileSync(new URL('../ThirdParty/CADEngine/src/fixtures/e20-mixed-reference.dxf',import.meta.url)),'dxf');
const mixedRows=inspect(mixed).entities;
for(const type of ['Spline','Hatch','Insert']){
 const row=mixedRows.find(v=>v.entity[type]);assert.ok(row);assert.equal(row.editable,false);assert.deepEqual(row.operations,[]);assert.ok(row.readOnlyReason);
}
const modelLine=mixedRows.find(v=>v.entity.Line&&v.editable);
mixed.edit(JSON.stringify({operation:'move',handle:modelLine.handle,delta:[1,2,0]}));
const mixedReopened=new CadSession(mixed.save(),'dxf');
for(const row of mixedRows.filter(v=>!v.editable))assert.deepEqual(inspect(mixedReopened).entities.find(v=>v.handle===row.handle).entity,row.entity);
mixed.free();mixedReopened.free();
for(const instance of [s,reopened,restored])instance.free();
console.log('CAD annotations: native DIMASSOC edit/reopen, per-operation UI metadata, exact-source replay, failed-edit atomicity and cross-document recovery fencing passed');
