// SPDX-License-Identifier: MPL-2.0
// Real bundled WASM: exact OCS transfer, native sheet→DWG→edit→save/reopen.
// Does not claim WKWebView/App/independent CAD acceptance.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const assets=path.join(root,'FloeApp/Resources/EngineeringViewers');
const fixtures=path.join(root,'ThirdParty/CADEngine/src/fixtures');
const {default:init,CadSession}=await import(pathToFileURL(path.join(assets,'floe_cad_engine.js')));
await init({module_or_path:fs.readFileSync(path.join(assets,'floe_cad_engine_bg.wasm'))});
let checks=0;
const check=(name,body)=>{body();checks++;};
const inspect=s=>JSON.parse(s.inspect(0,500));
const transfer=(s,request={})=>JSON.parse(s.transfer_sketch(JSON.stringify(request)));
const input=fs.readFileSync(path.join(fixtures,'e23-native-engineering-sheet.dxf'));
const source=new CadSession(input,'dxf');
try {
 const baseline=source.inspect(0,500), selection=transfer(source);
 check('typed primitive and omission coverage',()=>{assert.equal(selection.schemaVersion,1);assert.equal(selection.unitScaleMM,1);assert.equal(selection.omissions.length,1);assert.equal(selection.omissions[0].entityType,'Text');assert(selection.curves.some(c=>c.kind==='circle'));assert(selection.curves.filter(c=>c.kind==='line').length>=4);});
 check('read-only source retained',()=>assert.equal(source.inspect(0,500),baseline));
 const line=inspect(source).entities.find(row=>row.entity.Line).handle;
 check('explicit handles and revision',()=>{const subset=transfer(source,{handles:[line],expectedRevision:0});assert.equal(subset.curves.length,1);assert.deepEqual(subset.curves[0].start,[0,0]);assert.throws(()=>transfer(source,{handles:['FFFFFFFF']}));assert.throws(()=>transfer(source,{expectedRevision:1}));});
 const converted=source.export_drawing_dwg();
 check('native DWG output and original retained',()=>{assert.equal(Buffer.from(converted).subarray(0,6).toString(),'AC1032');assert.equal(source.inspect(0,500),baseline);});
 const target=new CadSession(converted,'dwg');
 try {
  const original=inspect(target), row=original.entities.find(row=>row.entity.Line);
  check('layers and editable Chinese text',()=>{assert(original.entities.some(r=>r.entity.Text?.value==='Floe 工程'));assert.equal(transfer(target).insertionUnits,4);assert(original.entities.some(r=>r.layer==='HIDDEN'));});
  target.edit(JSON.stringify({operation:'move',handle:row.handle,delta:[3,4,0]}));
  check('stale snapshot refused',()=>assert.throws(()=>transfer(target,{handles:[row.handle],expectedRevision:0})));
  check('single undo and redo',()=>{assert.equal(target.undo(),true);assert.deepEqual(transfer(target,{handles:[row.handle]}).curves[0].start,[0,0]);assert.equal(target.redo(),true);assert.deepEqual(transfer(target,{handles:[row.handle]}).curves[0].start,[3,4]);});
  const saved=target.save(), reopened=new CadSession(saved,'dwg');
  try {check('actual DWG save/reopen',()=>{assert.deepEqual(transfer(reopened,{handles:[row.handle]}).curves[0].end,[103,4]);assert.equal(transfer(reopened).insertionUnits,4);assert(reopened.export_as('dwg').length>0);});}finally{reopened.free();}
 }finally{target.free();}
 const unitless=new CadSession(new TextEncoder().encode(input.toString().replace('$INSUNITS\n70\n4','$INSUNITS\n70\n0')),'dxf');
 try{check('unknown units are explicit',()=>assert.equal(transfer(unitless).unitScaleMM,null));}finally{unitless.free();}
 const oblique=new CadSession(fs.readFileSync(path.join(fixtures,'e21-oblique-closed-bulge.dxf')),'dxf');
 try {const row=inspect(oblique).entities.find(r=>r.entity.LwPolyline);const snapshot=transfer(oblique,{handles:[row.handle]});check('oblique OCS and exact bulges',()=>{assert(snapshot.curves.some(c=>c.kind==='arc'));assert(snapshot.curves.every(c=>c.ocs.normal.length===3));assert(snapshot.sourcePlane.xAxis.some((v,i)=>Math.abs(v-[1,0,0][i])>1e-6)||snapshot.sourcePlane.yAxis.some((v,i)=>Math.abs(v-[0,1,0][i])>1e-6));});}finally{oblique.free();}
}finally{source.free();}
console.log(`CAD sketch transfer: ${checks} checks passed (bundled WASM)`);
