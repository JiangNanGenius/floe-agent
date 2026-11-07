// SPDX-License-Identifier: MPL-2.0
import path from 'node:path';
import fs from 'node:fs/promises';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const cache=process.env.FLOE_EDITOR_WEB_TOOLCHAIN??path.join(process.env.HOME,'Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/web-toolchain');
const require=createRequire(path.join(cache,'package.json'));
const {JSDOM}=require('jsdom');const dom=new JSDOM('<!DOCTYPE html><html><body></body></html>',{url:'https://score-test.invalid/'});
for(const name of ['DOMParser','XMLSerializer','Node','Element','HTMLElement'])globalThis[name]=dom.window[name];
globalThis.document=dom.window.document;
globalThis.scoreTestFixture=await fs.readFile(path.join(root,'Tests/Fixtures/ensemble.musicxml'),'utf8');
const scratch=path.join(process.env.HOME,'Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/xcode-27B52/score/web-tests');await fs.mkdir(scratch,{recursive:true});
const output=path.join(scratch,'regression.cjs');
await require('esbuild').build({entryPoints:[path.join(root,'Tests/regression.js')],bundle:true,platform:'node',format:'cjs',outfile:output,nodePaths:[path.join(cache,'node_modules')],external:['node:*']});
globalThis.captureScoreArtifact=async(name,bytes)=>{await fs.writeFile(path.join(scratch,name),bytes);};
const report=await require(output).run();console.log(JSON.stringify(report,null,2));
if(process.env.FLOE_SCORE_TEST_OUTPUT)await fs.writeFile(process.env.FLOE_SCORE_TEST_OUTPUT,JSON.stringify(report,null,2)+'\n');
