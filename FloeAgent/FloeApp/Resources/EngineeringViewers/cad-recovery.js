// SPDX-License-Identifier: MPL-2.0
// A recovery file contains the exact original bytes and a bounded replay log.
// It is never a CAD-format replacement or a substitute for strict save checks.
export const MAX_RECOVERY_BYTES = 16 * 1024 * 1024;
const byteLength=value=>new TextEncoder().encode(value).length;
const MAX_LOG_BYTES = 2 * 1024 * 1024, MAX_EVENTS = 4096, MAX_SOURCE_BYTES = 10 * 1024 * 1024;
function encode(bytes) {
 let binary='';for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.subarray(i,i+8192));
 return btoa(binary);
}
function decode(value) {
 if(typeof value!=='string'||value.length>14*1024*1024)throw Error('Invalid recovery source');
 const binary=atob(value);if(!binary.length||binary.length>MAX_SOURCE_BYTES)throw Error('Invalid recovery source size');
 return Uint8Array.from(binary,c=>c.charCodeAt(0));
}
async function sha256(bytes) {
 const digest=new Uint8Array(await crypto.subtle.digest('SHA-256',bytes));
 return Array.from(digest,v=>v.toString(16).padStart(2,'0')).join('');
}
function eventValue(event) {
 if(!event||typeof event!=='object'||!['edit','undo','redo'].includes(event.operation))throw Error('Invalid recovery operation');
 const keys=Object.keys(event).sort().join(',');
 if(event.operation==='edit') {
  if(keys!=='operation,request'||typeof event.request!=='string'||new TextEncoder().encode(event.request).length>32768)throw Error('Invalid recovery edit');
  const request=JSON.parse(event.request);if(!request||typeof request!=='object'||Array.isArray(request))throw Error('Invalid recovery edit');
 }else if(keys!=='operation')throw Error('Invalid recovery history');
 return structuredClone(event);
}
export class CadRecoveryJournal {
 constructor(bytes,format,events=[]) {
  if(!['dwg','dxf'].includes(format)||!bytes.length||bytes.length>MAX_SOURCE_BYTES)throw Error('Invalid recovery drawing');
  this.bytes=new Uint8Array(bytes);this.format=format;this.events=events.map(eventValue);
  this.logBytes=0;for(const event of this.events)this.logBytes+=byteLength(JSON.stringify(event));
  if(this.events.length>MAX_EVENTS||this.logBytes>MAX_LOG_BYTES)throw Error('Recovery log limit');
 }
 prepare(event) {
  event=eventValue(event);const size=byteLength(JSON.stringify(event));
  if(this.events.length>=MAX_EVENTS||this.logBytes+size>MAX_LOG_BYTES)throw Error('Export the recovery draft and reopen the drawing before continuing');
  return ()=>{this.events.push(event);this.logBytes+=size;};
 }
 async serialize() {
  const text=JSON.stringify({schema:'floe-cad-recovery',version:1,format:this.format,
   sourceBase64:encode(this.bytes),sourceSHA256:await sha256(this.bytes),events:this.events});
  if(new TextEncoder().encode(text).length>MAX_RECOVERY_BYTES)throw Error('Recovery file limit');return text;
 }
}
export async function readCadRecovery(text) {
 if(typeof text!=='string'||new TextEncoder().encode(text).length>MAX_RECOVERY_BYTES)throw Error('Recovery file limit');
 const v=JSON.parse(text);
 if(v?.schema!=='floe-cad-recovery'||v.version!==1||!Array.isArray(v.events)||v.events.length>MAX_EVENTS
  ||Object.keys(v).sort().join(',')!=='events,format,schema,sourceBase64,sourceSHA256,version')throw Error('Invalid CAD recovery file');
 const bytes=decode(v.sourceBase64);
 if(await sha256(bytes)!==v.sourceSHA256)throw Error('Recovery source checksum mismatch');
 return new CadRecoveryJournal(bytes,v.format,v.events);
}
export function replayCadRecovery(journal,CadSession) {
 const candidate=new CadSession(journal.bytes,journal.format);
 try {
  for(const event of journal.events) {
   if(event.operation==='edit')candidate.edit(event.request);
   else if(event.operation==='undo')candidate.undo();else candidate.redo();
  }
  return candidate;
 }catch(error){candidate.free();throw error;}
}
