// SPDX-License-Identifier: MPL-2.0
// Bounded adaptation of the MIT-licensed fonteditor-core 2.6.3 Emscripten glue.
// Upstream original license texts remain in the shared third-party notices.
import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import assert from 'node:assert/strict';

export const WOFF2_GLUE_RAW_SHA256='405d77a48e3670c772f78fd8e42b64bea0d3df5744b998bad462cd83d69fe41d';
export const WOFF2_WASM_SHA256='afda7e08349046612a019713c8f3baae52ee9d064c712919af020cd2634dddd6';
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');

// These replace only three known generators. No Function/eval replacement is
// installed, and no source strings or model-authored programs are interpreted.
const namedFunction=String.raw`function createNamedFunction(name,body){
name=makeLegalFunctionName(name);
var wrapper=function(){return body.apply(this,arguments)};
Object.defineProperty(wrapper,"name",{value:name,configurable:true});
return wrapper;
}`;
const dynCaller=String.raw`function makeDynCaller(dynCall){
var count=signature.length-1;
var wrapper=function(){
var args=[rawFunction];
for(var i=0;i<count;++i){args.push(arguments[i])}
return dynCall.apply(undefined,args);
};
Object.defineProperty(wrapper,"name",{value:"dynCall_"+signature+"_"+rawFunction,configurable:true});
Object.defineProperty(wrapper,"length",{value:count,configurable:true});
return wrapper;
}`;
const invokerFunction=String.raw`function craftInvokerFunction(humanName,argTypes,classType,cppInvokerFunc,cppTargetFunc){
var argCount=argTypes.length;
if(argCount<2){throwBindingError("argTypes array size mismatch! Must at least get return value and 'this' types!")}
var isClassMethodFunc=argTypes[1]!==null&&classType!==null;
var needsDestructorStack=false;
for(var i=1;i<argTypes.length;++i){if(argTypes[i]!==null&&argTypes[i].destructorFunction===undefined){needsDestructorStack=true;break}}
var returns=argTypes[0].name!=="void";
var wrapper=function(){
if(arguments.length!==argCount-2){throwBindingError("function "+humanName+" called with "+arguments.length+" arguments, expected "+(argCount-2)+" args!")}
var destructors=needsDestructorStack?[]:null;
var wired=[],invocation=[cppTargetFunc],thisWired;
if(isClassMethodFunc){
// The old generated invoker was a non-strict function. Preserve its receiver
// boxing for class conversion, without constructing a non-strict function.
var receiver=this===null||this===undefined?globalThis:Object(this);
thisWired=argTypes[1].toWireType(destructors,receiver);invocation.push(thisWired);
}
for(var i=0;i<argCount-2;++i){wired[i]=argTypes[i+2].toWireType(destructors,arguments[i]);invocation.push(wired[i])}
var result=cppInvokerFunc.apply(undefined,invocation);
// Match the original success-path lifetime: conversion/invocation errors are
// propagated without inventing a new finally/destructor policy.
if(needsDestructorStack){runDestructors(destructors)}
else{for(var i=isClassMethodFunc?1:2;i<argTypes.length;++i){var destructor=argTypes[i].destructorFunction;if(destructor!==null){destructor(i===1?thisWired:wired[i-2])}}}
if(returns){return argTypes[0].fromWireType(result)}
};
Object.defineProperty(wrapper,"name",{value:makeLegalFunctionName(humanName),configurable:true});
Object.defineProperty(wrapper,"length",{value:argCount-2,configurable:true});
return wrapper;
}`;
const generators=[
  {name:'createNamedFunction',start:'function createNamedFunction(',end:'function extendError(',replacement:namedFunction},
  {name:'embind__requireFunction.makeDynCaller',start:'function makeDynCaller(dynCall)',end:'var fp;',replacement:dynCaller},
  {name:'craftInvokerFunction',start:'function craftInvokerFunction(',end:'function __embind_register_class_function(',replacement:invokerFunction}
];

export function patchWoff2Glue(raw){
  const bytes=Buffer.isBuffer(raw)?raw:Buffer.from(raw),rawSHA256=hash(bytes);
  if(rawSHA256!==WOFF2_GLUE_RAW_SHA256)throw new Error('WOFF2 glue changed; review the fixed CSP patch before updating the dependency');
  const original=bytes.toString('utf8');let source=original;
  const functions=[];
  for(const patch of generators){
    const start=original.indexOf(patch.start),end=original.indexOf(patch.end,start);
    if(start<0||end<=start||original.indexOf(patch.start,start+1)!==-1)throw new Error('Unknown WOFF2 generator layout: '+patch.name);
    const fragment=original.slice(start,end);if(!source.includes(fragment))throw new Error('Overlapping WOFF2 CSP patch');
    source=source.replace(fragment,patch.replacement);
    functions.push({name:patch.name,rawByteOffset:Buffer.byteLength(original.slice(0,start)),rawFunctionSHA256:hash(fragment),patchedFunctionSHA256:hash(patch.replacement)});
  }
  if(/new\s+Function\s*\(|new_\s*\(\s*Function\s*,|\beval\s*\(/.test(source))throw new Error('WOFF2 dynamic code construction remains');
  return {source,provenance:{package:'fonteditor-core',version:'2.6.3',sourceFile:'woff2/woff2.js',license:'MIT (original upstream text retained)',rawSHA256,patchedSHA256:hash(source),rawByteCount:bytes.length,patchedByteCount:Buffer.byteLength(source),functions,wasmSHA256:WOFF2_WASM_SHA256,wasmChanged:false}};
}

export function woff2CSPPlugin(onPatch){
  return {name:'floe-fixed-woff2-csp',setup(build){
    build.onLoad({filter:/[/\\]fonteditor-core[/\\]woff2[/\\]woff2\.js$/},async args=>{
      const result=patchWoff2Glue(await fs.readFile(args.path));onPatch?.(result.provenance);
      return {contents:result.source,loader:'js',resolveDir:path.dirname(args.path)};
    });
  }};
}

function testGenerators(){
  // Exercise arity, method receiver, converter/destructor ordering, errors and
  // return conversion using the exact replacement bodies in a restricted VM.
  const context=vm.createContext({events:[],makeLegalFunctionName:n=>n.replace(/[^\w$]/g,'_'),throwBindingError:message=>{throw new Error(message);},runDestructors:stack=>{while(stack.length){const value=stack.pop(),destructor=stack.pop();destructor(value);}}},{codeGeneration:{strings:false,wasm:true}});
  vm.runInContext(namedFunction+'\n'+invokerFunction,context);
  assert.throws(()=>vm.runInContext('Function("return 1")()',context),/Code generation from strings disallowed/);
  vm.runInContext(String.raw`
var convert=function(label,value){return {name:label,destructorFunction:null,toWireType:function(stack,x){events.push(label+":"+x);return x+value}}};
var ret={name:"int",fromWireType:function(x){events.push("return:"+x);return x*2}};
var a=convert("a",10),b=convert("b",20);
a.destructorFunction=function(x){events.push("destroy-a:"+x)};
b.destructorFunction=function(x){events.push("destroy-b:"+x)};
var call=craftInvokerFunction("pair",[ret,null,a,b],null,function(fn,x,y){events.push("invoke:"+fn);return x+y},7);
var actual=call(1,2);
`,context);
  assert.equal(context.actual,66);assert.equal(context.call.length,2);assert.equal(context.call.name,'pair');
  assert.deepEqual(Array.from(context.events),['a:1','b:2','invoke:7','destroy-a:11','destroy-b:22','return:33']);
  assert.throws(()=>context.call(1),/expected 2 args/);
  vm.runInContext(String.raw`
events.length=0;
var cls={name:"cls",destructorFunction:undefined,toWireType:function(stack,x){events.push("this:"+x.value);stack.push(function(v){events.push("destroy-this:"+v)},x.value);return x.value}};
var arg={name:"arg",destructorFunction:undefined,toWireType:function(stack,x){events.push("arg:"+x);stack.push(function(v){events.push("destroy-arg:"+v)},x);return x+1}};
var method=craftInvokerFunction("method",[{name:"void"},cls,arg],{},function(fn,receiver,x){events.push("invoke:"+receiver+":"+x);return 99},5);
var returned=method.call({value:8},3);
`,context);
  assert.equal(context.returned,undefined);assert.equal(context.method.length,1);
  assert.deepEqual(Array.from(context.events),['this:8','arg:3','invoke:8:4','destroy-arg:3','destroy-this:8']);
  vm.runInContext(String.raw`
events.length=0;
var bad=craftInvokerFunction("bad",[ret,null,a],null,function(){throw new Error("native failure")},1);
`,context);
  assert.throws(()=>context.bad(2),/native failure/);assert.deepEqual(Array.from(context.events),['a:2']);
  vm.runInContext('var signature="iiii",rawFunction=9;'+dynCaller+';var dyn=makeDynCaller(function(){return Array.prototype.slice.call(arguments)})',context);
  assert.equal(context.dyn.length,3);assert.equal(context.dyn.name,'dynCall_iiii_9');
  assert.deepEqual(Array.from(context.dyn(1,2,3,4)),[9,1,2,3]);
  assert.deepEqual(Array.from(context.dyn(1)),[9,1,undefined,undefined]);
}

export async function verifyWoff2CSP({cache,fontPath}){
  testGenerators();
  const packageRoot=path.join(cache,'node_modules/fonteditor-core/woff2'),raw=await fs.readFile(path.join(packageRoot,'woff2.js')),wasm=await fs.readFile(path.join(packageRoot,'woff2.wasm'));
  assert.equal(hash(wasm),WOFF2_WASM_SHA256);
  const patched=patchWoff2Glue(raw);
  let dataFetches=0;
  const dataOnlyFetch=async url=>{assert.ok(String(url).startsWith('data:application/octet-stream;base64,'));dataFetches++;return fetch(url);};
  const context=vm.createContext({module:{exports:{}},exports:{},window:{},document:{currentScript:{src:'https://font-fixture.invalid/woff2.js'}},console,WebAssembly,TextDecoder,TextEncoder,Uint8Array,ArrayBuffer,atob,fetch:dataOnlyFetch,setTimeout,clearTimeout},{codeGeneration:{strings:false,wasm:true}});
  assert.throws(()=>vm.runInContext('new Function("return 1")()',context),/Code generation from strings disallowed/);
  new vm.Script(patched.source,{filename:'fonteditor-core/woff2/woff2-csp.js'}).runInContext(context);
  let native;
  await new Promise((resolve,reject)=>{
    native=context.module.exports({locateFile:file=>file.endsWith('.wasm')?'data:application/octet-stream;base64,'+wasm.toString('base64'):file,onRuntimeInitialized:()=>resolve(),onAbort:reason=>reject(new Error(String(reason)))});
  });
  const input=await fs.readFile(fontPath);
  const copy=vector=>{try{return Uint8Array.from({length:vector.size()},(_,i)=>vector.get(i));}finally{vector.delete();}};
  const compressed=copy(native.woff2Enc(new Uint8Array(input),input.length));
  assert.equal(Buffer.from(compressed.subarray(0,4)).toString('ascii'),'wOF2');
  const decoded=copy(native.woff2Dec(compressed,compressed.length));
  const require=createRequire(path.join(cache,'package.json')),opentype=require('opentype.js');
  const arrayBuffer=data=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength),original=opentype.parse(arrayBuffer(input)),roundTrip=opentype.parse(arrayBuffer(decoded));
  assert.equal(roundTrip.glyphs.length,original.glyphs.length);assert.equal(roundTrip.charToGlyph('A').advanceWidth,original.charToGlyph('A').advanceWidth);
  const tables=data=>{const v=new DataView(data.buffer,data.byteOffset,data.byteLength),result=new Map();for(let i=0;i<v.getUint16(4);i++){const p=12+i*16,tag=String.fromCharCode(...data.subarray(p,p+4)),offset=v.getUint32(p+8),length=v.getUint32(p+12);result.set(tag,Buffer.from(data.subarray(offset,offset+length)));}return result;};
  const a=tables(input),b=tables(decoded);for(const tag of ['GSUB','GPOS'])if(a.has(tag))assert.deepEqual(b.get(tag),a.get(tag));
  assert.equal(hash(await fs.readFile(path.join(packageRoot,'woff2.js'))),WOFF2_GLUE_RAW_SHA256);
  assert.equal(dataFetches,1);
  return {stringsCodeGeneration:false,assetTransport:'Emscripten data URL through data-only fetch; no custom scheme / network / fs',generatorSemantics:'arity / receiver / conversion / destructor / exception / return checks passed',realWasmRoundTrip:true,ttfBytes:input.length,woff2Bytes:compressed.length,decodedBytes:decoded.length,glyphs:roundTrip.glyphs.length,layoutTablesPreserved:true,...patched.provenance};
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  const cache=process.env.FLOE_EDITOR_WEB_TOOLCHAIN??path.join(process.env.HOME,'Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/web-toolchain');
  if(!process.argv[2])throw new Error('An explicit real TTF fixture path is required');
  console.log(JSON.stringify(await verifyWoff2CSP({cache,fontPath:process.argv[2]}),null,2));
}
