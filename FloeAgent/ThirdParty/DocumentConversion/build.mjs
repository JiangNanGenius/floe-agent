import { build } from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
const dir=path.resolve('../../FloeApp/Resources/DocumentConversion');
fs.mkdirSync(dir,{recursive:true});
const result=await build({entryPoints:['converter.js'],bundle:true,platform:'browser',conditions:['browser'],format:'iife',target:'safari18',minify:true,legalComments:'eof',define:{global:'globalThis'},outfile:path.join(dir,'converter.js'),metafile:true});
const packages=new Map();
for(const file of Object.keys(result.metafile.inputs)) {
 if(!file.includes('node_modules/')) continue;
 let p=path.dirname(path.resolve(file));
 while(!fs.existsSync(path.join(p,'package.json'))) {const parent=path.dirname(p);if(parent===p)break;p=parent;}
 const manifest=JSON.parse(fs.readFileSync(path.join(p,'package.json'),'utf8'));
 packages.set(manifest.name,{name:manifest.name,version:manifest.version,license:manifest.license,path:p});
}
// Upstream browser distributions include their own dependencies. Preserve
// notices for the locked production dependency closure as well.
const lock=JSON.parse(fs.readFileSync('package-lock.json','utf8'));
for(const [location,entry] of Object.entries(lock.packages)) {
 if(!location || entry.dev || !fs.existsSync(path.join(location,'package.json'))) continue;
 const manifest=JSON.parse(fs.readFileSync(path.join(location,'package.json'),'utf8'));
 const license=manifest.license?.includes('MIT OR GPL') ? 'MIT' : manifest.license;
 packages.set(manifest.name,{name:manifest.name,version:manifest.version,license,path:path.resolve(location)});
}
let notice='Floe offline document conversion dependencies\n\n';
const inventory=[];
for(const pkg of [...packages.values()].sort((a,b)=>a.name.localeCompare(b.name))) {
 if(/GPL|AGPL/.test(pkg.license) && !/OR/.test(pkg.license))throw Error('Unexpected copyleft dependency '+pkg.name);
 notice+=`\n=== ${pkg.name} ${pkg.version} (${pkg.license}) ===\n`;
 for(const file of fs.readdirSync(pkg.path).filter(n=>/^(license|copying|notice)/i.test(n))) {
  if(fs.statSync(path.join(pkg.path,file)).isFile())notice+=fs.readFileSync(path.join(pkg.path,file),'utf8')+'\n';
 }
 inventory.push({name:pkg.name,version:pkg.version,license:pkg.license});
}
fs.writeFileSync(path.join(dir,'THIRD-PARTY-NOTICES.txt'),notice);
const digest=crypto.createHash('sha256').update(fs.readFileSync(path.join(dir,'converter.js'))).digest('hex');
fs.writeFileSync('inventory.json',JSON.stringify({sha256:digest,packages:inventory},null,2)+'\n');
console.log('Bundled offline conversion engine',digest);
