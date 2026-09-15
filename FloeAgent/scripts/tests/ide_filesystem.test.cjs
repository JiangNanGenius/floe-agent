// SPDX-License-Identifier: MPL-2.0
const test = require('node:test');
const assert = require('node:assert/strict');
const create = require('../../FloeApp/Resources/IDE/filesystem.js');
// Minimal upstream protocol shapes; UI integration separately exercises the
// pinned real BrowserFS implementation in CodeBlitz.
class Stats { constructor(type,size,mode,atime,mtime,ctime) { Object.assign(this,{type,size,mode,atime,mtime,ctime}); } }
class ApiError extends Error { constructor(errno,message,path) { super(message);Object.assign(this,{errno,path}); } }
class Base {}
class Editor extends Base {}
class InMemory { statSync(path) { if(path!=='/')throw new ApiError(2,'missing',path);return new Stats(0x4000,0); } }
const BrowserFS={FileSystem:{InMemory,Editor}};
const write=(fs,text)=>new Promise((resolve,reject)=>fs.writeFile('/main.py',text,'utf8',{getFlagString:()=> 'w'},420,(e,v)=>e?reject(e):resolve(v)));
test('write acknowledges only the completed native commit, preserving UTF8',async()=>{
 let finish,request,commits=0,acknowledged=false;
 const FS=create(BrowserFS,Buffer,r=>{request=r;return new Promise(resolve=>finish=resolve)},()=>commits++);
 const pending=write(new FS(),'print("中文")').then(()=>acknowledged=true);
 await new Promise(setImmediate);assert.equal(acknowledged,false);assert.equal(commits,0);
 assert.equal(Buffer.from(request.contentBase64,'base64').toString(),'print("中文")');
 finish({});await pending;assert.equal(commits,1);assert.equal(acknowledged,true);
});
test('conflict propagates to editor without successful commit notification',async()=>{
 let commits=0;
 const FS=create(BrowserFS,Buffer,async()=>({error:{code:'EBUSY',message:'Concurrent agent edit'}}),()=>commits++);
 await assert.rejects(write(new FS(),'stale'),e=>e.errno===16 && e.message==='Concurrent agent edit');assert.equal(commits,0);
});
test('stat uses stable numeric milliseconds instead of fresh wall clock',async()=>{
 const FS=create(BrowserFS,Buffer,async()=>({directory:false,size:17,modified:123456789}));
 const fs=new FS(),stat=()=>new Promise((resolve,reject)=>fs.stat('/main.py',false,(e,v)=>e?reject(e):resolve(v)));
 const first=await stat(),second=await stat();assert.equal(first.mtime,123456789);assert.equal(second.mtime,first.mtime);
});
test('oversized writes and unsupported append flags never reach native bridge',async()=>{
 let calls=0;const FS=create(BrowserFS,Buffer,async()=>{calls++;return {}}),fs=new FS();
 await assert.rejects(write(fs,'x'.repeat(4*1024*1024+1)),e=>e.errno===27);
 await assert.rejects(new Promise((resolve,reject)=>fs.writeFile('/main.py','a','utf8',{getFlagString:()=> 'a'},420,e=>e?reject(e):resolve())),e=>e.errno===95);
 assert.equal(calls,0);
});
