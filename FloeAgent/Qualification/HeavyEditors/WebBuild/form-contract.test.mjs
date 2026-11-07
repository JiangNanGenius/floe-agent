// SPDX-License-Identifier: MPL-2.0
import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import {createRequire} from 'node:module';
import {EditorEngine} from '../../../Modules/FloeHeavyEditorSupport/Web/runtime.js';
const cache=process.env.FLOE_EDITOR_WEB_TOOLCHAIN??path.join(process.env.HOME,'Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/web-toolchain');
const {JSDOM}=createRequire(path.join(cache,'package.json'))('jsdom');
test('form refreshes measure choices for the selected part and submits current values',async()=>{
  const dom=new JSDOM('<!doctype html><body></body>');
  globalThis.document=dom.window.document;globalThis.Node=dom.window.Node;
  dom.window.HTMLDialogElement.prototype.showModal=function(){this.open=true;};
  dom.window.HTMLDialogElement.prototype.close=function(){this.open=false;this.dispatchEvent(new dom.window.Event('close'));};
  try{
    const e=new EditorEngine({kind:'test',create:()=>({title:'Fixture'})});let received;
    e.perform=async(_command,args)=>{received=args;return {result:null};};
    const action={id:'move',title:'Move',access:'edit',fields:[
      {key:'part',type:'select',label:'Part',default:'p1',options:['p1','p2']},
      {key:'measure',type:'select',label:'Measure',default:(_e,args)=>args.part==='p2'?'b1':'a1',options:(_e,args)=>args.part==='p2'?['b1','b2','b3']:['a1','a2']}
    ]};
    e.register(action,()=>{});assert.deepEqual(e.catalog().find(v=>v.id==='move').fields[1].options,['a1','a2']);
    e.showAction(action);const [part,measure]=document.querySelectorAll('select');
    assert.equal(measure.value,'a1');part.value='p2';part.dispatchEvent(new dom.window.Event('change'));
    assert.deepEqual([...measure.options].map(v=>v.value),['b1','b2','b3']);assert.equal(measure.value,'b1');
    measure.value='b3';document.querySelector('form').dispatchEvent(new dom.window.Event('submit',{cancelable:true}));
    await new Promise(resolve=>setTimeout(resolve,0));assert.deepEqual(received,{part:'p2',measure:'b3'});
  }finally{delete globalThis.document;delete globalThis.Node;dom.window.close();}
});
