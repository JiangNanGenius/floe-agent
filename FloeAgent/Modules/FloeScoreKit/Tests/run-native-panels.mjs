// SPDX-License-Identifier: MPL-2.0
import fs from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const cache=process.env.FLOE_EDITOR_WEB_TOOLCHAIN??path.join(process.env.HOME,'Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/web-toolchain');
const require=createRequire(path.join(cache,'package.json'));
const {JSDOM}=require('jsdom'),dom=new JSDOM('<!doctype html><html><body></body></html>');
for(const name of ['DOMParser','XMLSerializer','Node','Element','HTMLElement'])globalThis[name]=dom.window[name];globalThis.document=dom.window.document;
const scratch=path.join(process.env.HOME,'Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/score-native-panels');await fs.mkdir(scratch,{recursive:true});
const output=path.join(scratch,'native-panels.cjs');await require('esbuild').build({entryPoints:[path.join(root,'Tests/native-panels.js')],outfile:output,bundle:true,platform:'node',format:'cjs',nodePaths:[path.join(cache,'node_modules')]});
const result=await require(output).run();const {snapshot,...summary}=result;console.log(JSON.stringify(summary,null,2));
if(process.argv[2]){await fs.mkdir(process.argv[2],{recursive:true});await fs.writeFile(path.join(process.argv[2],'native-panels-results.json'),JSON.stringify(summary,null,2)+'\n');await fs.writeFile(path.join(process.argv[2],'native-panels-snapshot.json'),JSON.stringify(snapshot,null,2)+'\n');}
