// SPDX-License-Identifier: MPL-2.0
import * as esbuild from 'esbuild';
import {execFileSync} from 'node:child_process';
import {mkdir,copyFile,readFile,writeFile,readdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const root=path.dirname(fileURLToPath(import.meta.url));
// Maintainer-only override so a private qualification build can be staged
// without touching the checked-in resource directory. Normal builds keep the
// existing default output.
const configuredOut=process.env.FLOE_ENGINEERING_VIEWERS_OUT;
const out=configuredOut?path.resolve(configuredOut):path.resolve(root,'../../FloeApp/Resources/EngineeringViewers');
await mkdir(out,{recursive:true});
// dxf-viewer 1.0.48 was built against three 0.161. Keep its entry pinned to
// that exact nested package even though the scene viewer needs r176; otherwise
// npm's hoisting would silently pair the viewer with a newer Color class.
const dxfThree=path.join(root,'node_modules/dxf-viewer/node_modules/three');
for(const [entry,name,options] of [
 ['dxf-entry.js','dxf.js',{alias:{three:dxfThree}}],
 ['mesh-entry.js','mesh.js',{}],
 ['scene-entry.js','scene.js',{}],
 // Static Online3DViewer adapter. It receives the already bundled OV
 // namespace from viewer.js, so this bundle never embeds a second three.js or
 // a remote dependency.
 ['static-scene-entry.js','static-scene.js',{}]
]){
 await esbuild.build({absWorkingDir:root,entryPoints:[entry],outfile:path.join(out,name),bundle:true,format:'esm',target:'es2022',minify:true,legalComments:'linked',...options});
}
for(const name of ['occt-import-js.js','license.occt-import-js.txt','license.occt.txt'])
 await copyFile(path.join(root,'node_modules/occt-import-js/dist',name),path.join(out,name));
execFileSync('python3',[path.join(root,'bound_occt_memory.py'),path.join(root,'node_modules/occt-import-js/dist/occt-import-js.wasm'),path.join(out,'occt-import-js.wasm')]);
await copyFile(path.join(root,'dxf-worker.js'),path.join(out,'dxf-worker.js'));
for(const name of ['gerber-to-svg.min.js','gerber-to-svg.min.js.LICENSE.txt'])
 await copyFile(path.join(root,'node_modules/gerber-to-svg/dist',name),path.join(out,name));
await copyFile(path.resolve(root,'../../FloeApp/Resources/Fonts/Bundled/misans/MiSans-Regular.ttf'),path.join(out,'MiSans-Regular.ttf'));

// Locally bundled three.js r176 scene decoders. Every file is copied from the
// exact pinned npm tarball and hashed below; no runtime CDN/remote fetch is
// permitted by index.html's CSP or the native preview server.
const threeRoot=path.join(root,'node_modules/three');
const decoderFiles=[
 ['draco_decoder.js',path.join(threeRoot,'examples/jsm/libs/draco/gltf/draco_decoder.js')],
 ['draco_decoder.wasm',path.join(threeRoot,'examples/jsm/libs/draco/gltf/draco_decoder.wasm')],
 ['draco_wasm_wrapper.js',path.join(threeRoot,'examples/jsm/libs/draco/gltf/draco_wasm_wrapper.js')],
 ['basis_transcoder.js',path.join(threeRoot,'examples/jsm/libs/basis/basis_transcoder.js')],
 ['basis_transcoder.wasm',path.join(threeRoot,'examples/jsm/libs/basis/basis_transcoder.wasm')]
];
for(const [name,source] of decoderFiles)
 await copyFile(source,path.join(out,name));
const licenseFiles=[
 ['license.three.txt','LICENSE.three.txt'],
 ['license.draco.txt','LICENSE.draco.txt'],
 ['license.basis-transcoder.txt','LICENSE.basis-transcoder.txt'],
 ['license.meshopt.txt','LICENSE.meshopt.txt'],
 ['license.ktx-parse.txt','LICENSE.ktx-parse.txt'],
 ['license.zstddec.txt','LICENSE.zstddec.txt']
];
for(const [target,source] of licenseFiles)
 await copyFile(path.join(root,'licenses',source),path.join(out,target));
const hashFile=async file=>createHash('sha256').update(await readFile(file)).digest('hex');
const sha256={};
for(const [name] of decoderFiles)sha256[name]=await hashFile(path.join(out,name));
const bom={
  generatedBy:'FloeAgent/ThirdParty/EngineeringViewers/build.mjs',
  networkPolicy:'local-only; no remote decoder URLs',
  three:{package:'three',version:'0.176.0',license:'MIT',source:'https://registry.npmjs.org/three/-/three-0.176.0.tgz'},
  decoders:{
    draco:{license:'Apache-2.0',source:'three@0.176.0/examples/jsm/libs/draco/gltf',files:['draco_decoder.js','draco_decoder.wasm','draco_wasm_wrapper.js']},
    meshopt:{license:'MIT',source:'three@0.176.0/examples/jsm/libs/meshopt_decoder.module.js',bundledInto:'scene.js'},
    ktx2Basis:{license:'Apache-2.0',source:'three@0.176.0/examples/jsm/libs/basis',files:['basis_transcoder.js','basis_transcoder.wasm']},
    ktxParse:{license:'MIT',source:'three@0.176.0/examples/jsm/libs/ktx-parse.module.js',bundledInto:'scene.js'},
    zstddec:{license:'MIT AND BSD-3-Clause',source:'three@0.176.0/examples/jsm/libs/zstddec.module.js',bundledInto:'scene.js'}
  },
  sha256,
  ktx2WorkerGuard:{
    source:'FloeAgent/ThirdParty/EngineeringViewers/ktx2-worker-guard.js',
    sourceSHA256:await hashFile(path.join(root,'ktx2-worker-guard.js')),
    adaptation:'CSP-safe embind closures and bounded owned-worker lifecycle; upstream decoder files unchanged'
  },
  sceneBundleSHA256:await hashFile(path.join(out,'scene.js'))
};
await writeFile(path.join(out,'DECODER_BOM.json'),JSON.stringify(bom,null,2)+'\n');

let notices='# Engineering viewer third-party notices\n\n';
const lock=JSON.parse(await readFile(path.join(root,'package-lock.json'),'utf8'));
for(const [folder,meta] of Object.entries(lock.packages)){
 if(!folder||meta.dev||folder.includes('@types/'))continue;
 const dir=path.join(root,folder);
 const pkg=JSON.parse(await readFile(path.join(dir,'package.json'),'utf8'));
 notices+=`## ${pkg.name} ${pkg.version} — ${pkg.license}\n\n`;
 for(const name of await readdir(dir))if(/^(license|licence|copying)(\.|$)/i.test(name))notices+=(await readFile(path.join(dir,name),'utf8'))+'\n\n';
}
for(const [heading,source] of [
 ['Draco glTF decoder (three@0.176.0 examples/jsm/libs/draco/gltf) — Apache-2.0','LICENSE.draco.txt'],
 ['Basis Universal transcoder (three@0.176.0 examples/jsm/libs/basis) — Apache-2.0','LICENSE.basis-transcoder.txt'],
 ['meshopt decoder (meshoptimizer) — MIT','LICENSE.meshopt.txt'],
 ['ktx-parse (bundled in three@0.176.0) — MIT','LICENSE.ktx-parse.txt'],
 ['zstddec + embedded Zstandard (bundled in three@0.176.0) — MIT AND BSD-3-Clause','LICENSE.zstddec.txt']
])notices+=`## ${heading}\n\n`+(await readFile(path.join(root,'licenses',source),'utf8'))+'\n\n';
notices+='## MiSans\n\n'+await readFile(path.resolve(root,'../../FloeApp/Resources/Fonts/Bundled/misans/LICENSE.txt'),'utf8');
await writeFile(path.join(out,'THIRD_PARTY_NOTICES.txt'),notices.replace(/\r\n/g,'\n'));
const hashes={};
for(const name of (await readdir(out)).sort())if(name!=='asset-hashes.json')hashes[name]=createHash('sha256').update(await readFile(path.join(out,name))).digest('hex');
await writeFile(path.join(out,'asset-hashes.json'),JSON.stringify(hashes,null,2)+'\n');
