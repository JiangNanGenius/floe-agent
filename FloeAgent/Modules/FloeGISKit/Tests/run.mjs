// SPDX-License-Identifier: MPL-2.0
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
const here=path.dirname(fileURLToPath(import.meta.url));
const cache=process.env.FLOE_EDITOR_WEB_TOOLCHAIN??path.join(process.env.HOME,'Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/web-toolchain');
const require=createRequire(path.join(cache,'package.json')),esbuild=require('esbuild');
const output=process.env.FLOE_GIS_TEST_SCRATCH??path.join(process.env.HOME,'Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/gis-tests');
await fs.mkdir(output,{recursive:true});
const target=path.join(output,'gis.test.cjs');
await esbuild.build({entryPoints:[path.join(here,'gis.test.mjs')],outfile:target,bundle:true,platform:'node',format:'cjs',target:'node22',nodePaths:[path.join(cache,'node_modules')],logLevel:'warning',loader:{'.css':'empty'},define:{'__FLOE_GIS_SQLITE_TESTING__':'true'}});
const result=spawnSync(process.execPath,['--test',...process.argv.slice(2),target],{stdio:'inherit',env:{...process.env,FLOE_EDITOR_SQL_WASM:path.join(cache,'node_modules/@sqlite.org/sqlite-wasm/dist/sqlite3.wasm'),FLOE_EDITOR_SQLITE_MODULE:pathToFileURL(path.join(cache,'node_modules/@sqlite.org/sqlite-wasm/dist/node.mjs')).href}});
process.exitCode=result.status??1;
