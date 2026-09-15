// SPDX-License-Identifier: MPL-2.0
import * as esbuild from 'esbuild';
import {mkdir,copyFile,readFile,writeFile,readdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const root=path.dirname(fileURLToPath(import.meta.url));
const out=path.resolve(root,'../../FloeApp/Resources/EngineeringViewers');
await mkdir(out,{recursive:true});
for(const [entry,name] of [['dxf-entry.js','dxf.js'],['mesh-entry.js','mesh.js']]){
 await esbuild.build({absWorkingDir:root,entryPoints:[entry],outfile:path.join(out,name),bundle:true,format:'esm',target:'es2022',minify:true,legalComments:'linked'});
}
await copyFile(path.join(root,'dxf-worker.js'),path.join(out,'dxf-worker.js'));
for(const name of ['gerber-to-svg.min.js','gerber-to-svg.min.js.LICENSE.txt'])
 await copyFile(path.join(root,'node_modules/gerber-to-svg/dist',name),path.join(out,name));
await copyFile(path.resolve(root,'../../FloeApp/Resources/Fonts/Bundled/misans/MiSans-Regular.ttf'),path.join(out,'MiSans-Regular.ttf'));
let notices='# Engineering viewer third-party notices\n\n';
const lock=JSON.parse(await readFile(path.join(root,'package-lock.json'),'utf8'));
for(const [folder,meta] of Object.entries(lock.packages)){
 if(!folder||meta.dev||folder.includes('@types/'))continue;
 const dir=path.join(root,folder);
 const pkg=JSON.parse(await readFile(path.join(dir,'package.json'),'utf8'));
 notices+=`## ${pkg.name} ${pkg.version} — ${pkg.license}\n\n`;
 for(const name of await readdir(dir))if(/^(license|licence|copying)(\.|$)/i.test(name))notices+=(await readFile(path.join(dir,name),'utf8'))+'\n\n';
}
notices+='## MiSans\n\n'+await readFile(path.resolve(root,'../../FloeApp/Resources/Fonts/Bundled/misans/LICENSE.txt'),'utf8');
await writeFile(path.join(out,'THIRD_PARTY_NOTICES.txt'),notices);
const hashes={};
for(const name of (await readdir(out)).sort())if(name!=='asset-hashes.json')hashes[name]=createHash('sha256').update(await readFile(path.join(out,name))).digest('hex');
await writeFile(path.join(out,'asset-hashes.json'),JSON.stringify(hashes,null,2)+'\n');
