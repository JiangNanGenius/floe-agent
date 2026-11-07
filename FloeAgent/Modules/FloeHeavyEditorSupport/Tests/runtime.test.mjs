// SPDX-License-Identifier: MPL-2.0
import test from 'node:test';
import assert from 'node:assert/strict';
import { EditorEngine } from '../Web/runtime.js';
const engine=()=>new EditorEngine({kind:'test',create:()=>({title:'Fixture',values:[]}),normalize:state=>{if(!Array.isArray(state.values)||state.values.some(v=>typeof v!=='number'))throw new Error('Invalid values');}});
test('document and history survive reopen, schema validation fences invalid command results',async()=>{
  const e=engine();e.register({id:'append',access:'edit'},a=>e.state.values.push(a.value));
  await e.execute({command:'append',arguments:{value:4},revision:0});
  const copy=engine();await copy.load({kind:'test',revision:9,content:e.payload});
  await copy.execute({command:'history.undo',arguments:{},revision:9});assert.deepEqual(copy.state.values,[]);
  await copy.execute({command:'history.redo',arguments:{},revision:9});assert.deepEqual(copy.state.values,[4]);
  await assert.rejects(()=>e.execute({command:'append',arguments:{value:'bad'},revision:0}));assert.deepEqual(e.state.values,[4]);
});
test('imported history cannot traverse inherited constructor or prototype',async()=>{
  const e=engine();await e.load({kind:'test',revision:0,content:{data:{title:'Fixture',values:[]},history:{past:[{inverse:[{path:['constructor','prototype','floeInjected'],value:true}],forward:[]}],future:[]}}});
  await assert.rejects(()=>e.execute({command:'history.undo',revision:0,arguments:{}}));
  assert.equal(Object.prototype.floeInjected,undefined);
});
test('literal prototype-named data remains ordinary JSON data',async()=>{
  const e=engine();e.register({id:'data',access:'edit'},()=>Object.defineProperty(e.state,'__proto__',{value:{data:2},enumerable:true,writable:true,configurable:true}));
  await e.execute({command:'data',revision:0,arguments:{}});await e.execute({command:'history.undo',revision:0,arguments:{}});await e.execute({command:'history.redo',revision:0,arguments:{}});
  assert.equal(Object.getPrototypeOf(e.state),Object.prototype);assert.deepEqual(e.state.__proto__,{data:2});
});
