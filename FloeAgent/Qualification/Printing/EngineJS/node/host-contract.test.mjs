// SPDX-License-Identifier: MPL-2.0
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createSettings,validateSettings,validateMesh,createPrintHost,sliceFDM,sliceSLA,hostDiagnostics} from '../floe-print-host.js';
import {MESH_FIXTURES} from '../fixtures/mesh-fixtures.js';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../../../ThirdParty/KiriMoto/src');
const host=await createPrintHost({engineRoot:pathToFileURL(root+'/').href,wasmResolver:async name=>{const b=fs.readFileSync(path.join(root,'wasm',name));return b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength)}});
const mesh={positions:MESH_FIXTURES.cube20.build()};
test('owned settings reject scripts, unknown formats and mutation',()=>{
 assert.throws(()=>createSettings('photon'),{code:'E_KIND'});
 for(const key of ['gcodePre','gcodeProc','slaFormat','extruders','__proto__'])assert.throws(()=>createSettings('fdm',{[key]:1}));
 assert.throws(()=>createSettings('fdm',{sliceHeight:NaN}));
 const s=createSettings('fdm');assert.throws(()=>validateSettings('fdm',structuredClone(s)),{code:'E_SETTINGS'});
 assert.throws(()=>{s.device.gcodePre[0]='BAD'});assert.throws(()=>validateSettings('sla',s));
});
test('malformed and degenerate meshes fail before slicing',async()=>{
 assert.throws(()=>validateMesh({positions:[NaN,0,0,0,0,0,0,0,0]}));
 await assert.rejects(sliceFDM(host,{requestId:'bad',mesh:{positions:new Float32Array(9)},settings:createSettings('fdm')}));
 await assert.rejects(sliceFDM(host,{requestId:'far',mesh:{positions:[300,0,0,301,0,0,300,1,1]},settings:createSettings('fdm')}),{code:'E_BOUNDS'});
});
test('shared mutable realm rejects a second job; output retains request identity',async()=>{
 const running=sliceFDM(host,{requestId:'owner-A',mesh,settings:createSettings('fdm')});
 await assert.rejects(sliceSLA(host,{requestId:'owner-B',mesh,settings:createSettings('sla')}),{code:'E_BUSY'});
 const out=await running;assert.equal(out.requestId,'owner-A');assert.match(out.text,/G1.*E/);assert.deepEqual(hostDiagnostics(host),{busy:false,ownedWidgets:0});
});
test('cancelled stage cannot return an artifact and releases its slot only on unwind',async()=>{
 const controller=new AbortController();
 await assert.rejects(sliceFDM(host,{requestId:'cancelled',mesh,settings:createSettings('fdm'),signal:controller.signal,onProgress:()=>controller.abort()}),{code:'E_CANCELLED'});
 assert.deepEqual(hostDiagnostics(host),{busy:false,ownedWidgets:0});
 const cancelled=new AbortController();cancelled.abort();
 await assert.rejects(sliceFDM(host,{requestId:'already-cancelled',mesh,settings:createSettings('fdm'),signal:cancelled.signal}),{code:'E_CANCELLED'});
});
test('editing the caller mesh during slicing cannot alter the accepted snapshot',async()=>{
 const source=MESH_FIXTURES.cube20.build(),stable=new Float32Array(source);
 const reference=await sliceFDM(host,{requestId:'fidelity-reference',mesh:{positions:stable},settings:createSettings('fdm')});
 let changed=false;
 const result=await sliceFDM(host,{requestId:'fidelity-edit',mesh:{positions:source},settings:createSettings('fdm'),onProgress:()=>{
  if(!changed){source.fill(0);changed=true;}
 }});
 const motions=text=>text.split(/\r?\n/).map(s=>s.split(';')[0].trim()).filter(s=>/^G(?:0|1|2|3)\s/.test(s));
 assert.equal(changed,true);
 assert.deepEqual(motions(result.text),motions(reference.text));
});
