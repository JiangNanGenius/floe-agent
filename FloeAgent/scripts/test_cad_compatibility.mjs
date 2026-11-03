// SPDX-License-Identifier: MPL-2.0
// External-corpus probe. Exit 0 proves same-format save and exact-source
// recovery; exit 2 records a correctly refused compatibility case. It never
// writes the input file. Use --input <drawing> --output <evidence-directory>.
import fs from 'node:fs';import path from 'node:path';import assert from 'node:assert/strict';import {createHash,webcrypto} from 'node:crypto';
if(!globalThis.crypto)globalThis.crypto=webcrypto;
const args=process.argv.slice(2);const arg=name=>args[args.indexOf(name)+1];
if(!args.includes('--input')||!args.includes('--output'))throw Error('--input and --output are required');
const source=path.resolve(arg('--input')),out=path.resolve(arg('--output'));if(source.startsWith(out+path.sep))throw Error('Keep source outside the output directory');
const format=path.extname(source).slice(1).toLowerCase();if(!['dwg','dxf'].includes(format))throw Error('Expected DWG or DXF');
fs.mkdirSync(out,{recursive:true});const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const {default:init,CadSession}=await import('../FloeApp/Resources/EngineeringViewers/floe_cad_engine.js');
const {CadRecoveryJournal,readCadRecovery,replayCadRecovery}=await import('../FloeApp/Resources/EngineeringViewers/cad-recovery.js');
await init({module_or_path:fs.readFileSync(new URL('../FloeApp/Resources/EngineeringViewers/floe_cad_engine_bg.wasm',import.meta.url))});
const bytes=fs.readFileSync(source),report={sourceName:path.basename(source),sourceSHA256:sha(bytes),format};let session;
try{
 session=new CadSession(bytes,format);const info=JSON.parse(session.inspect(0,500));report.entityCount=info.entityCount;report.diagnostics=info.diagnostics;
 report.readOnlyTypes={};for(const row of info.entities)if(!row.editable){const type=Object.keys(row.entity)[0];report.readOnlyTypes[type]=(report.readOnlyTypes[type]??0)+1;}
 const journal=new CadRecoveryJournal(bytes,format);
 const line=info.entities.find(row=>row.editable&&row.operations.includes('move')&&row.entity.Line);
 const text=info.entities.find(row=>row.editable&&row.operations.includes('setText')&&row.entity.Text);
 const edit=line?{operation:'move',handle:line.handle,delta:[.1,0,0]}:text?{operation:'setText',handle:text.handle,text:text.entity.Text.value+' [Floe]'}:{operation:'addStroke',points:[[0,0,0],[5,2,0],[10,0,0]]};
 try{const request=JSON.stringify(edit),commit=journal.prepare({operation:'edit',request});session.edit(request);commit();report.edit=edit.operation;report.editedHandle=edit.handle??null;}catch(error){report.editError=String(error);}
 try{const saved=session.save();report.saved=true;report.outputSHA256=sha(saved);fs.writeFileSync(path.join(out,'edited.'+format),saved);const reopened=new CadSession(saved,format);report.reopenedEntityCount=JSON.parse(reopened.inspect(0,1)).entityCount;reopened.free();}catch(error){report.saved=false;report.saveError=String(error);}
 const recovery=await journal.serialize();fs.writeFileSync(path.join(out,'Drawing.floe-cad-draft.json'),recovery);
 const restoredJournal=await readCadRecovery(recovery);assert.deepEqual(Buffer.from(restoredJournal.bytes),bytes);
 const restored=replayCadRecovery(restoredJournal,CadSession);report.recoveryExact=restored.inspect(0,500)===session.inspect(0,500);assert.equal(report.recoveryExact,true);restored.free();
}catch(error){report.openError=String(error);report.saved=false;}finally{session?.free();}
report.originalUnchanged=sha(fs.readFileSync(source))===report.sourceSHA256;assert.equal(report.originalUnchanged,true);
fs.writeFileSync(path.join(out,'RESULT.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
process.exitCode=report.saved&&report.edit&&!report.editError?0:2;
