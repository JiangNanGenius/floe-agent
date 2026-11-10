// SPDX-License-Identifier: MPL-2.0
import fs from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const cache=process.env.FLOE_EDITOR_WEB_TOOLCHAIN??path.join(process.env.HOME,'Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/web-toolchain');
const scratch=process.env.FLOE_SCORE_PROFESSIONAL_SCRATCH,output=process.argv[2];
if(!scratch||!output)throw new Error('Provide FLOE_SCORE_PROFESSIONAL_SCRATCH and a task-owned evidence output directory');
const require=createRequire(path.join(cache,'package.json')),{JSDOM}=require('jsdom');
const dom=new JSDOM('<!doctype html><html><body></body></html>');
for(const key of ['DOMParser','XMLSerializer','Node','Element','HTMLElement'])globalThis[key]=dom.window[key];globalThis.document=dom.window.document;
await fs.mkdir(scratch,{recursive:true});await fs.mkdir(output,{recursive:true});
globalThis.captureProfessionalArtifact=async(name,bytes)=>{if(name.includes('/')||name.includes('\\'))throw new Error('Unsafe fixture name');await fs.writeFile(path.join(output,name),bytes);};
const results={};
for(const name of ['native-panels','professional']){
 const target=path.join(scratch,name+'.cjs');
 await require('esbuild').build({entryPoints:[path.join(root,'Tests',name+'.js')],bundle:true,platform:'node',format:'cjs',outfile:target,nodePaths:[path.join(cache,'node_modules')]});
 const {snapshot,...result}=await require(target).run();results[name]=result;
 if(snapshot)await fs.writeFile(path.join(output,'native-panels-snapshot.json'),JSON.stringify(snapshot,null,2)+'\n');
}
await fs.writeFile(path.join(output,'RESULT.json'),JSON.stringify(results,null,2)+'\n');console.log(JSON.stringify(results,null,2));
