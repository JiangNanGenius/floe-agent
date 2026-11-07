// SPDX-License-Identifier: MPL-2.0
// Produce standard SQLite files for independent Python/SQLite verification.
import fs from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath,pathToFileURL} from 'node:url';
const here=path.dirname(fileURLToPath(import.meta.url));
const cache=process.env.FLOE_EDITOR_WEB_TOOLCHAIN??path.join(process.env.HOME,'Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/web-toolchain');
const require=createRequire(path.join(cache,'package.json'));
const scratch=process.env.FLOE_GIS_TEST_SCRATCH??path.join(process.env.HOME,'Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/gis-tests');
const output=process.argv[2];
if(!output)throw new Error('Pass a task-owned fixture output directory');
await fs.mkdir(scratch,{recursive:true});
const script=path.join(scratch,'sqlite-fixtures.cjs');
await require('esbuild').build({entryPoints:[path.join(here,'sqlite-fixture-entry.js')],outfile:script,bundle:true,platform:'node',format:'cjs',target:'node22',nodePaths:[path.join(cache,'node_modules')],logLevel:'warning',define:{'__FLOE_GIS_SQLITE_TESTING__':'true'}});
const info=await require(script).writeFixtures({output,moduleURL:pathToFileURL(path.join(cache,'node_modules/@sqlite.org/sqlite-wasm/dist/node.mjs')).href,wasmPath:path.join(cache,'node_modules/@sqlite.org/sqlite-wasm/dist/sqlite3.wasm')});
console.log(JSON.stringify(info,null,2));
