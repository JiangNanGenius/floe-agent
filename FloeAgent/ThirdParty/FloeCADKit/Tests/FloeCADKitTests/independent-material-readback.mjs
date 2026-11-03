// SPDX-License-Identifier: MPL-2.0
// Independent third-party material parse plus actual embedded PNG byte binding.
// No Floe material/evaluator functions, image stubs, network or package install.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
const [threeRoot,fieldsPath,bakedPath,expectedPath]=process.argv.slice(2);
assert(threeRoot && fieldsPath && bakedPath && expectedPath,'usage: node independent-material-readback.mjs <existing three root> <advanced-fields.glb> <baked-graph.glb> <material-expected.json>');
assert.equal(JSON.parse(fs.readFileSync(path.join(threeRoot,'package.json'))).version,'0.176.0');
const {GLTFLoader}=await import(pathToFileURL(path.join(threeRoot,'examples/jsm/loaders/GLTFLoader.js')));
const expected=JSON.parse(fs.readFileSync(expectedPath,'utf8'));
function glb(file) {
 const bytes=fs.readFileSync(file);assert(bytes.length<=16*1024*1024);assert.equal(bytes.readUInt32LE(0),0x46546c67);assert.equal(bytes.readUInt32LE(8),bytes.length);
 const n=bytes.readUInt32LE(12),json=JSON.parse(bytes.subarray(20,20+n).toString()),offset=20+n;
 assert(json.buffers.every(x=>!x.uri));assert((json.images ?? []).every(x=>!x.uri),'Only embedded owned fixtures');
 return {bytes,json,bin:bytes.subarray(offset+8,offset+8+bytes.readUInt32LE(offset))};
}
const a=glb(fieldsPath);assert.equal((a.json.images ?? []).length,0,'Numeric shader fields fixture uses actual loader with no image stand-ins');
const loaded=await new GLTFLoader().parseAsync(a.bytes.buffer.slice(a.bytes.byteOffset,a.bytes.byteOffset+a.bytes.byteLength),'');
const materials=[];loaded.scene.traverse(node=>{if(node.isMesh)materials.push(...(Array.isArray(node.material)?node.material:[node.material]));});
assert(materials.length>0);
function close(a,b,name){assert(Math.abs(a-b)<1e-6,`${name}: ${a} != ${b}`);}
for(const m of materials){
 assert(m.isMeshPhysicalMaterial);close(m.clearcoat,expected.clearcoat,'coat');close(m.clearcoatRoughness,expected.coatRoughness,'coat roughness');
 close(m.anisotropy,expected.anisotropy,'anisotropy');close(m.anisotropyRotation,expected.exportRotation,'declared native-angle loss');
 close(m.specularIntensity,expected.specular,'specular');close(m.sheenRoughness,expected.sheenRoughness,'fixed sheen roughness');
 for(let i=0;i<3;i++)close(m.sheenColor.toArray()[i],expected.sheen[i],'sheen RGB');
}
for(const m of a.json.materials){
 const e=m.extensions;assert(e.KHR_materials_clearcoat && e.KHR_materials_anisotropy && e.KHR_materials_specular && e.KHR_materials_sheen && e.KHR_materials_emissive_strength,'KHR additions cannot overwrite existing emission extension');
 close(m.extras.floe_advanced_source.anisotropyAngle,expected.nativeAngle,'source angle retained');
 assert(m.extras.floe_degradation.includes('anisotropy_angle_native_scale_not_converted_to_gltf_radians'));
}
for(const mesh of a.json.meshes)for(const p of mesh.primitives)assert(p.attributes.NORMAL!==undefined && p.attributes.TANGENT!==undefined,'Anisotropy has a real tangent basis');
const b=glb(bakedPath),digests=[];
for(const image of b.json.images){const v=b.json.bufferViews[image.bufferView];const png=b.bin.subarray(v.byteOffset ?? 0,(v.byteOffset ?? 0)+v.byteLength);digests.push(createHash('sha256').update(png).digest('hex'));}
assert(digests.includes(expected.bakedBaseColorSHA256),'GLB must embed the actual baked color PNG unchanged');
for(const material of b.json.materials){assert(material.pbrMetallicRoughness.baseColorTexture);assert.equal(material.extras.floe_node_graph.exchange,'baked_textures_only');assert.equal(material.extras.floe_node_graph.baked_sha256.baseColor,expected.bakedBaseColorSHA256);}
console.log(JSON.stringify({parser:'three.js 0.176.0 GLTFLoader + binary GLB image digest readback',materialCount:materials.length,fieldsSHA256:createHash('sha256').update(a.bytes).digest('hex'),bakedSHA256:createHash('sha256').update(b.bytes).digest('hex'),embeddedPNG:digests,expected},null,2));
