// SPDX-License-Identifier: MPL-2.0
import init, {CadSession} from './floe_cad_engine.js';
let session, initialized;
self.onmessage = async ({data: {id, operation, ...args}}) => {
 try {
  initialized ??= init(); await initialized;
  let result;
  switch(operation) {
   case 'open': session?.free();session=new CadSession(args.bytes,args.format);result=state();break;
   case 'edit': session.edit(JSON.stringify(args.edit));result=state();break;
   case 'undo': session.undo();result=state();break;
   case 'redo': session.redo();result=state();break;
   case 'inspect': result=JSON.parse(session.inspect(args.offset??0,args.limit??100));break;
   case 'save': result=session.save();break;
   default: throw Error('Unknown CAD operation');
  }
  self.postMessage({id,result});
 } catch(error) { self.postMessage({id,error:String(error?.message??error)}); }
};
function state(){return {info:JSON.parse(session.inspect(0,500)),dxf:session.display_dxf()};}
