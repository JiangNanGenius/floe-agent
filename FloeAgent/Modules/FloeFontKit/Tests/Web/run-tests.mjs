// SPDX-License-Identifier: MPL-2.0
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const cache=process.env.FLOE_EDITOR_WEB_TOOLCHAIN??path.join(process.env.HOME,'Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/web-toolchain');
const require=createRequire(path.join(cache,'package.json')),esbuild=require('esbuild');
const output=path.join(process.env.HOME,'Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/font-web-tests');
await fs.mkdir(output,{recursive:true});
const bundle=path.join(output,'font-behavior.cjs');
await esbuild.build({entryPoints:[path.join(root,'Tests/Web/font-behavior.test.js')],bundle:true,packages:'external',platform:'node',format:'cjs',outfile:bundle,nodePaths:[path.join(cache,'node_modules')],define:{'process.env.NODE_ENV':'"test"'}});
const result=spawnSync(process.execPath,[bundle],{stdio:'inherit',env:{...process.env,FLOE_EDITOR_WEB_TOOLCHAIN:cache,NODE_PATH:path.join(cache,'node_modules')}});process.exitCode=result.status??1;
