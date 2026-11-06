// SPDX-License-Identifier: MPL-2.0
// Read-only source/hash check. Parses actual ESM dependencies without executing vendor code.
import fs from 'node:fs';import path from 'node:path';import vm from 'node:vm';import crypto from 'node:crypto';
const root=path.resolve(process.argv[2]);const manifest=JSON.parse(fs.readFileSync(path.join(root,'PROVENANCE.json')));
const digest=b=>crypto.createHash('sha256').update(b).digest('hex');
const seen=new Set();const entries=['add/class.js','add/three.js','kiri/core/codec.js','kiri/mode/fdm/work/init-work.js','kiri/mode/sla/work/init-work.js','kiri/mode/sla/core/formats.js'];
function visit(rel){if(seen.has(rel))return;seen.add(rel);const file=path.join(root,'src',rel);const text=fs.readFileSync(file,'utf8');const m=new vm.SourceTextModule(text,{identifier:rel});for(const spec of m.dependencySpecifiers){if(!spec.startsWith('.'))throw Error('external runtime import '+spec);const child=path.posix.normalize(path.posix.join(path.posix.dirname(rel),spec));if(child.startsWith('../'))throw Error('escaped vendor root');visit(child)}}
for(const e of entries)visit(e);
for(const f of manifest.sourceFiles){const b=fs.readFileSync(path.join(root,f.path));if(b.length!==f.bytes||digest(b)!==f.sha256)throw Error('source mismatch '+f.path)}
const sources=manifest.sourceFiles.filter(f=>f.path.endsWith('.js'));
if(sources.length!==seen.size || sources.some(f=>!seen.has(f.path.slice(4))))throw Error('unexpected or unreachable source');
for(const f of manifest.sourceFiles)if(/GPL|AGPL|LGPL/.test(f.license))throw Error('unapproved copyleft source '+f.path);
console.log(JSON.stringify({passed:true,staticModules:seen.size,sourceFiles:manifest.sourceFiles.length,unknownRuntimeImports:0,pinnedSourceHashesVerified:true}));
