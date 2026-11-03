// SPDX-License-Identifier: MPL-2.0
// Test oracle only: external three.js GLTFLoader + AnimationMixer + SkinnedMesh.
// No Floe evaluator, JSON joint-only success, GUI, network or package install.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
const [threeRoot, glbPath, expectedPath] = process.argv.slice(2);
assert(threeRoot && glbPath && expectedPath, 'usage: node independent-rig-readback.mjs <existing three root> <actual.glb> <expected.json>');
const pkg = JSON.parse(fs.readFileSync(path.join(threeRoot,'package.json'),'utf8'));
assert.equal(pkg.version,'0.176.0');
const THREE = await import(pathToFileURL(path.join(threeRoot,'build/three.module.js')));
const {GLTFLoader} = await import(pathToFileURL(path.join(threeRoot,'examples/jsm/loaders/GLTFLoader.js')));
const bytes = fs.readFileSync(glbPath);
assert(bytes.length < 16*1024*1024);
assert.equal(bytes.readUInt32LE(0),0x46546c67);assert.equal(bytes.readUInt32LE(8),bytes.length);
const json = JSON.parse(bytes.subarray(20,20+bytes.readUInt32LE(12)).toString());
assert(json.buffers.every(buffer => !buffer.uri), 'Only the owned embedded fixture is admitted');
assert((json.images ?? []).every(image => !image.uri),'No external assets/network');
assert.equal(json.skins.length,1);assert.equal(json.animations.length,1);
const gltf = await new GLTFLoader().parseAsync(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength),'');
const meshes=[];gltf.scene.traverse(node => { if (node.isSkinnedMesh) meshes.push(node); });
assert(meshes.length > 0,'Actual independent parser must instantiate skinning');
const expected=JSON.parse(fs.readFileSync(expectedPath,'utf8'));assert.equal(expected.units,'metres');
assert(expected.tolerance > 0 && expected.tolerance <= 2e-7);
const mixer=new THREE.AnimationMixer(gltf.scene),action=mixer.clipAction(gltf.animations[0]);
action.setLoop(THREE.LoopOnce,1);action.clampWhenFinished=true;action.play();
const records=[];let maxError=0;
for (const sample of expected.samples) {
  action.reset().setLoop(THREE.LoopOnce,1);action.clampWhenFinished=true;action.play();mixer.setTime(sample.time);
  gltf.scene.updateMatrixWorld(true);
  for (const mesh of meshes) {
    mesh.skeleton.update();const attribute=mesh.geometry.getAttribute('position');
    assert.equal(attribute.count,sample.worldPositionsM.length);
    const joints=mesh.geometry.getAttribute('skinIndex'),weights=mesh.geometry.getAttribute('skinWeight');
    assert(joints && weights && mesh.skeleton.bones.length === json.skins[0].joints.length);
    for (let index=0;index<attribute.count;index++) {
      const point=new THREE.Vector3().fromBufferAttribute(attribute,index);
      const targets=mesh.geometry.morphAttributes.position ?? [];
      assert(targets.length > 0 && mesh.morphTargetInfluences.length === targets.length,'Actual morph targets must be loaded');
      for (let m=0;m<targets.length;m++) point.addScaledVector(new THREE.Vector3().fromBufferAttribute(targets[m],index),mesh.morphTargetInfluences[m]);
      mesh.applyBoneTransform(index,point);mesh.localToWorld(point);
      const wanted=new THREE.Vector3(...sample.worldPositionsM[index]),error=point.distanceTo(wanted);maxError=Math.max(maxError,error);
      assert(error<=expected.tolerance,`t=${sample.time} vertex=${index} error=${error}`);
      const sum=weights.getX(index)+weights.getY(index)+weights.getZ(index)+weights.getW(index);
      assert(Math.abs(sum-1)<1e-6,'Target format weights stay normalized');
      records.push({time:sample.time,mesh:mesh.name,vertex:index,worldM:point.toArray(),expectedM:wanted.toArray(),error});
    }
  }
}
assert(records.length>0);
console.log(JSON.stringify({parser:'three.js GLTFLoader/AnimationMixer/SkinnedMesh',version:pkg.version,glbSHA256:createHash('sha256').update(bytes).digest('hex'),maxError,records},null,2));
