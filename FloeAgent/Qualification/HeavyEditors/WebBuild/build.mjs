// SPDX-License-Identifier: MPL-2.0
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import {writeNotices} from './notices.mjs';
import {woff2CSPPlugin} from './woff2-csp.mjs';
const here=path.dirname(fileURLToPath(import.meta.url));
const cache=process.env.FLOE_EDITOR_WEB_TOOLCHAIN ?? path.join(process.env.HOME,'Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/web-toolchain');
const require=createRequire(path.join(cache,'package.json'));
const esbuild=require('esbuild');
const modules=path.resolve(here,'../../../Modules');
const css=await fs.readFile(path.join(modules,'FloeHeavyEditorSupport/Web/editor.css'));
for(const [name,kind] of [['FloeGISKit','gis'],['FloeScoreKit','score'],['FloeFontKit','font']]) {
  if(process.argv.length>2&&!process.argv.slice(2).includes(kind))continue;
  const root=path.join(modules,name), target=path.join(root,'Sources',name,'Resources','Web');
  await fs.mkdir(target,{recursive:true});
  let woff2Patch;
  const result=await esbuild.build({entryPoints:[path.join(root,'Web/main.js')],bundle:true,format:'iife',globalName:'FloeBundledEditor',platform:'browser',target:'safari18',outfile:path.join(target,'editor.js'),nodePaths:[path.join(cache,'node_modules')],legalComments:'eof',metafile:true,write:true,minifySyntax:kind==='gis',plugins:kind==='font'?[woff2CSPPlugin(value=>woff2Patch=value)]:[],define:{'process.env.NODE_ENV':'"production"','__FLOE_GIS_SQLITE_TESTING__':'false'}});
  if(kind==='font'){if(!woff2Patch)throw new Error('Expected fixed WOFF2 glue CSP adaptation');await fs.writeFile(path.join(root,'Web/woff2-csp-patch.json'),JSON.stringify(woff2Patch,null,2)+'\n');}
  if(kind==='gis'){const production=await fs.readFile(path.join(target,'editor.js'),'utf8');for(const fixture of ['FloeEditorTestSQLiteModule','FloeEditorTestSQLWasm'])if(production.includes(fixture))throw new Error('Node SQLite fixture leaked into production: '+fixture);}
  const inputs=Object.entries(result.metafile.inputs).map(([input,metadata])=>({source:input.includes('/node_modules/')?'npm/'+input.slice(input.indexOf('/node_modules/')+'/node_modules/'.length):path.relative(modules,input),bytes:metadata.bytes}));
  if(kind==='gis')for(const file of ['index.mjs','sqlite3.wasm']){const source='@sqlite.org/sqlite-wasm/dist/'+file;inputs.push({source:'npm/'+source,bytes:(await fs.stat(path.join(cache,'node_modules',source))).size});}
  await fs.writeFile(path.join(root,'Web/bundle-inputs.json'),JSON.stringify(inputs,null,2)+'\n');
  let generatedCSS='';if(Object.keys(result.metafile.outputs).some(file=>file.endsWith('.css')))generatedCSS=await fs.readFile(path.join(target,'editor.css'),'utf8');
  await fs.writeFile(path.join(target,'editor.css'),generatedCSS+'\n'+css);
  await fs.writeFile(path.join(target,'index.html'),`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5, viewport-fit=cover"><meta http-equiv="Content-Security-Policy" content="default-src 'self' blob: data:; script-src 'self' blob: 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data: blob:; connect-src 'self' blob: data:; object-src 'none'; base-uri 'none'"><title>Floe ${kind}</title><link rel="stylesheet" href="editor.css"></head><body>${kind==='gis'?'<script src="sqlite3.js"></script>':''}<script src="editor.js"></script></body></html>`);
  if(kind==='gis'){
    await esbuild.build({entryPoints:[path.join(cache,'node_modules/@sqlite.org/sqlite-wasm/dist/index.mjs')],bundle:true,format:'iife',globalName:'FloeSQLiteOfficial',platform:'browser',target:'safari18',outfile:path.join(target,'sqlite3.js'),legalComments:'eof',banner:{js:'// Official SQLite module; upstream license notices are retained below.\nvar __floeSQLiteModuleURL = document.currentScript.src;'},define:{'import.meta.url':'__floeSQLiteModuleURL'}});
    await fs.copyFile(path.join(cache,'node_modules/@sqlite.org/sqlite-wasm/dist/sqlite3.wasm'),path.join(target,'sqlite3.wasm'));
    await fs.rm(path.join(target,'sql-wasm.wasm'),{force:true});
  }
  if(kind==='font') {
    const wasm=path.join(cache,'node_modules/fonteditor-core/woff2/woff2.wasm');
    try { await fs.copyFile(wasm,path.join(target,'woff2.wasm')); } catch { /* Source path checked by font-engine integration. */ }
  }
  await writeNotices({inputs,cache,kind,target,qualificationRoot:path.dirname(here)});
  console.log(`${name}: bundled offline resources`);
}
