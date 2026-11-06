// SPDX-License-Identifier: MPL-2.0
// Source-only R10 additions. Mainline owns execution/acceptance.
import test from 'node:test';
import assert from 'node:assert/strict';
import {snapshotMesh,createSettings,ADAPTER_VERSION,SUPPORTED_CAPABILITIES} from '../floe-print-host.js';

test('right-angle triangle coordinates are copied without smoothing or normalization',()=>{
    const input=new Float32Array([12,3,0, 17,3,0, 12,8,0]);
    const snapshot=snapshotMesh({positions:input});
    assert.notEqual(snapshot.positions.buffer,input.buffer);
    assert.deepEqual(Array.from(snapshot.positions),Array.from(input));
    input[0]=99;input[4]=99;
    assert.deepEqual(Array.from(snapshot.positions),[12,3,0, 17,3,0, 12,8,0]);
});
test('representable fractional straight edges remain unchanged',()=>{
    const input=new Float64Array([0.125,0.25,0, 1.125,0.25,0, 0.125,1.25,0]);
    assert.deepEqual(Array.from(snapshotMesh({positions:input}).positions),Array.from(input));
});
test('engine conversion cannot silently collapse a thin real edge',()=>{
    const positions=new Float64Array([100,0,0, 100.0000002,0,0, 100,1,0]);
    assert.throws(()=>snapshotMesh({positions}),{code:'E_MESH_PRECISION'});
});
test('a concurrently mutable shared buffer is not accepted as a geometry snapshot',()=>{
    if(typeof SharedArrayBuffer==='undefined')return;
    const positions=new Float32Array(new SharedArrayBuffer(9*4));
    positions.set([0,0,0,1,0,0,0,1,0]);
    assert.throws(()=>snapshotMesh({positions}),{code:'E_MESH_OWNERSHIP'});
});
test('owned geometry policy disables shape-changing options and identifies the new adapter',()=>{
    const {process}=createSettings('fdm');
    assert.equal(process.fdmArcEnabled,false);assert.equal(process.sliceSolidify,false);
    assert.equal(process.sliceCompInner,0);assert.equal(process.sliceCompOuter,0);
    assert.equal(SUPPORTED_CAPABILITIES.adapterVersion,ADAPTER_VERSION);
    assert.throws(()=>createSettings('fdm',{sliceSolidify:1}));
});
