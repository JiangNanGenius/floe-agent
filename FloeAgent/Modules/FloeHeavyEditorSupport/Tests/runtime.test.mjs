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
test('native command index stays small and native form dependencies resolve from current arguments',()=>{
  const e=engine();e.register({id:'choice',access:'read',fields:[{key:'part',default:'one'},{key:'bar',options:(_e,args)=>args.part==='two'?['b1','b2']:['a1'],default:'a1'}]},()=>{});
  assert.deepEqual(e.commandIndex().find(row=>row.id==='choice').fields,[{key:'part',label:undefined,type:undefined},{key:'bar',label:undefined,type:undefined}]);
  assert.deepEqual(e.formDescription('choice',{part:'two'}).fields[1].options,['b1','b2']);
});
test('native read/UI commands do not return the whole project or duplicate export bytes',async()=>{
  const e=engine();e.register({id:'select',access:'read',sideEffecting:true,hidden:true},()=>({selected:2}));
  e.register({id:'output',access:'exportFile'},()=>({artifacts:[{name:'fixture.txt',base64:'aGk='}]}));
  const selection=await e.execute({command:'select',revision:0,arguments:{}});assert.equal(selection.state,null);assert.deepEqual(selection.result,{selected:2});
  const output=await e.execute({command:'output',revision:0,arguments:{}});assert.equal(output.state,null);assert.equal(output.result,null);assert.equal(output.artifacts.length,1);
});
