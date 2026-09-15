// SPDX-License-Identifier: MPL-2.0
// OCCT remains a separately replaceable LGPL library. Source files never leave
// this local worker; only a bounded display mesh and inspection metadata return.
importScripts('occt-import-js.js');
self.onmessage=async({data})=>{
 try{
  if(!(data.bytes instanceof Uint8Array)||data.bytes.length>10*1024*1024)throw Error('CAD input exceeds 10 MiB');
  const method={step:'ReadStepFile',stp:'ReadStepFile',iges:'ReadIgesFile',igs:'ReadIgesFile',brep:'ReadBrepFile'}[data.extension];
  if(!method)throw Error('Unsupported CAD format');
  const occt=await occtimportjs({locateFile:name=>new URL(name,location.href).href});
  const result=occt[method](data.bytes,{linearUnit:'millimeter',linearDeflectionType:'bounding_box_ratio',linearDeflection:0.002,angularDeflection:0.5});
  if(!result.success||!Array.isArray(result.meshes)||!result.meshes.length)throw Error('No readable CAD geometry');
  let triangles=0,vertices=0;
  if(result.meshes.length>1000)throw Error('CAD assembly exceeds 1000 meshes');
  for(const mesh of result.meshes){
   const p=mesh.attributes?.position?.array,idx=mesh.index?.array;
   if(!p||!idx||p.length%3||idx.length%3)throw Error('Invalid CAD tessellation');
   triangles+=idx.length/3;vertices+=p.length/3;
   if(triangles>200000||vertices>600000)throw Error('CAD display mesh exceeds preview limits');
   if(!p.every(v=>Number.isFinite(v)&&Math.abs(v)<1e12)||!idx.every(i=>Number.isInteger(i)&&i>=0&&i<p.length/3))throw Error('Invalid CAD vertex data');
  }
  const buffer=new ArrayBuffer(84+50*triangles),view=new DataView(buffer);view.setUint32(80,triangles,true);
  let offset=84;
  for(const mesh of result.meshes){const p=mesh.attributes.position.array,idx=mesh.index.array;
   for(let i=0;i<idx.length;i+=3){offset+=12;for(let j=0;j<3;j++)for(let k=0;k<3;k++){view.setFloat32(offset,p[idx[i+j]*3+k],true);offset+=4;}offset+=2;}
  }
  self.postMessage({buffer,info:{sourceFormat:data.extension,displayUnits:data.extension==='brep'?'source units':'millimeter',meshCount:result.meshes.length,triangles,vertices,
   parts:result.meshes.slice(0,100).map(m=>({name:String(m.name??'').slice(0,256),faceCount:m.brep_faces?.length})),
   limitations:'Tessellated read-only surface; materials/colors, exact analytic surfaces, tolerances and manufacturing approval are not represented.'}},[buffer]);
 }catch(e){self.postMessage({error:String(e.message??e)});}
};
