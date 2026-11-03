// SPDX-License-Identifier: MPL-2.0
import init, {CadSession} from './floe_cad_engine.js';
import {normalizeEngineRequest} from './cad-request.js';
import {CadRecoveryJournal,readCadRecovery,replayCadRecovery} from './cad-recovery.js';
let session, initialized, recovery;
let queue=Promise.resolve();
self.onmessage=({data})=>{queue=queue.then(()=>handle(data));};
async function handle({id,operation,...args}) {
 try {
  initialized ??= init(); await initialized;
  let result;
  switch(operation) {
   case 'open': {const candidate=new CadSession(args.bytes,args.format);const journal=new CadRecoveryJournal(args.bytes,args.format);session?.free();session=candidate;recovery=journal;result=state();break;}
   case 'edit': {
    // The engine returns {"created":[handle,...]} or throws without changing
    // the document or the undo history. normalizeEngineRequest keeps a JSON
    // string from native callers single-encoded.
    const request=normalizeEngineRequest(args.edit,'edit');
    const commit=recovery.prepare({operation:'edit',request});
    const summary=JSON.parse(session.edit(request));commit();
    result={...state(),created:summary.created??[]};
    break;
   }
   case 'undo': {const commit=recovery.prepare({operation:'undo'});session.undo();commit();result=state();break;}
   case 'redo': {const commit=recovery.prepare({operation:'redo'});session.redo();commit();result=state();break;}
   case 'inspect': result=JSON.parse(session.inspect(args.offset??0,args.limit??100));break;
   case 'query': result=JSON.parse(session.query(normalizeEngineRequest(args.request,'query')));break;
   case 'setActiveLayer': session.set_active_layer(args.name);result=state();break;
   case 'save': result=session.save();break;
   case 'recovery': result=await recovery.serialize();break;
   case 'restoreRecovery': {
    const journal=await readCadRecovery(args.text);
    if(journal.format!==recovery.format||journal.bytes.length!==recovery.bytes.length||!journal.bytes.every((v,i)=>v===recovery.bytes[i]))throw Error('Open the original drawing for this recovery draft first');
    const candidate=replayCadRecovery(journal,CadSession);
    let next;try{next={info:JSON.parse(candidate.inspect(0,500)),dxf:candidate.display_dxf()};}catch(error){candidate.free();throw error;}
    session?.free();session=candidate;recovery=journal;result=next;break;
   }
   case 'display_dxf': result=session.display_dxf();break;
   default: throw Error('Unknown CAD operation');
  }
  self.postMessage({id,result});
 } catch(error) { self.postMessage({id,error:String(error?.message??error)}); }
}
function state(){return {info:JSON.parse(session.inspect(0,500)),dxf:session.display_dxf()};}
