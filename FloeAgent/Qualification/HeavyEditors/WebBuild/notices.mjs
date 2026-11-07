// SPDX-License-Identifier: MPL-2.0
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';

const safeLicenses=new Set(['MIT','Apache-2.0','BSD-2-Clause','BSD-3-Clause','BSD-1-Clause','ISC','EDL-1.0','Zlib','Unlicense','0BSD','CC0-1.0','BSL-1.0','Unicode-3.0','Unicode-DFS-2016','OFL-1.1','MPL-2.0','BlueOak-1.0.0']);
const hash=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
function licenseChoice(expression){
  const source=expression.replace(/^MIT\/Apache-2\.0$/,'(MIT OR Apache-2.0)').replace(/SEE LICEN[CS]E IN [A-Za-z0-9_.-]+/gi,'LicenseRef-SeeFile'),tokens=source.match(/[A-Za-z0-9.+-]+|[()]/g)??[];let cursor=0;
  const term=()=>{if(tokens[cursor]==='('){cursor++;const result=or();if(tokens[cursor++]!==')')throw new Error('Invalid SPDX expression');return result;}const id=tokens[cursor++];if(!id||['AND','OR'].includes(id))throw new Error('Invalid SPDX identifier');if(tokens[cursor]==='WITH')throw new Error('License exception requires explicit review: '+source);return {text:id,allowed:safeLicenses.has(id),rank:id==='MIT'?0:id==='EDL-1.0'?0:1};};
  const and=()=>{let result=term();while(tokens[cursor]==='AND'){cursor++;const other=term();result={text:result.text+' AND '+other.text,allowed:result.allowed&&other.allowed,rank:result.rank+other.rank};}return result;};
  const or=()=>{const options=[and()];while(tokens[cursor]==='OR'){cursor++;options.push(and());}return options.filter(v=>v.allowed).sort((a,b)=>a.rank-b.rank)[0]??options[0];};
  const result=or();if(cursor!==tokens.length||!result.allowed)throw new Error('License needs review: '+source);return result.text;
}
async function licenseFiles(root){
  const results=[];
  for(const entry of await fs.readdir(root,{withFileTypes:true})){
    if(entry.isFile()&&/licen[cs]e|copying|notice|copyright|authors|unlicense/i.test(entry.name)){const data=await fs.readFile(path.join(root,entry.name));results.push({name:entry.name,data});}
    else if(entry.isDirectory()&&/^licen[cs]es?$/i.test(entry.name)){for(const child of await fs.readdir(path.join(root,entry.name),{withFileTypes:true}))if(child.isFile()){const data=await fs.readFile(path.join(root,entry.name,child.name));results.push({name:entry.name+'/'+child.name,data});}}
  }return results;
}

async function installedPackage(from,name,nodeRoot){
  for(let current=from;current.startsWith(nodeRoot);current=path.dirname(current)){
    const root=path.join(current,'node_modules',name);
    try{const metadata=JSON.parse(await fs.readFile(path.join(root,'package.json'),'utf8'));if(metadata.name===name)return {root,metadata};}catch(error){if(error.code!=='ENOENT')throw error;}
    if(current===nodeRoot)break;
  }
  const root=path.join(nodeRoot,name),metadata=JSON.parse(await fs.readFile(path.join(root,'package.json'),'utf8'));
  if(metadata.name!==name)throw new Error('Wrong prebundled dependency: '+name);return {root,metadata};
}

// A prebundled npm entry is one esbuild input. Bind its reviewed inner runtime
// graph to exact bytes instead of treating all package dependencies as shipped.
async function collectPrebundled({packages,nodeRoot,qualificationRoot,cache,lock}){
  const directory=path.join(qualificationRoot,'Notices/score/embedded'),review=JSON.parse(await fs.readFile(path.join(directory,'prebundled-runtime.json'),'utf8'));
  const provenance=new Map(),audits=[],components=[],packageOriginals=new Map();
  for(const bundle of review.bundles){
    const found=[...packages].find(([,metadata])=>metadata.name===bundle.name);if(!found)continue;
    const [root,metadata]=found;if(metadata.version!==bundle.version)throw new Error('Prebundled runtime review needs update: '+bundle.name);
    const actual=hash(await fs.readFile(path.join(root,bundle.entry)));if(actual!==bundle.sha256)throw new Error('Reviewed prebundled entry bytes changed: '+bundle.name);
    const relative=path.relative(cache,root).replaceAll(path.sep,'/'),pinned=lock.packages[relative];if(!pinned||pinned.version!==metadata.version||!pinned.integrity)throw new Error('Prebundled parent does not match the lock: '+metadata.name);
    const parent={name:metadata.name,version:metadata.version,packagePath:relative,integrity:pinned.integrity,source:pinned.resolved,entry:bundle.entry,sha256:actual},roots=new Map([[metadata.name,root]]);
    for(const dependency of bundle.runtimeDependencies){
      const owner=roots.get(dependency.parent);if(!owner)throw new Error('Unknown prebundled dependency owner: '+dependency.parent);
      const installed=await installedPackage(owner,dependency.name,nodeRoot);if(installed.metadata.version!==dependency.version)throw new Error('Prebundled companion version changed: '+dependency.name);
      packages.set(installed.root,installed.metadata);roots.set(dependency.name,installed.root);
      const evidence={mode:'prebundled-runtime',via:parent,chain:dependency.chain,evidence:dependency.evidence};
      if(!provenance.has(installed.root))provenance.set(installed.root,[]);provenance.get(installed.root).push(evidence);
    }
    for(const check of bundle.companionChecks??[]){const owner=roots.get(check.package);if(!owner||hash(await fs.readFile(path.join(owner,check.file)))!==check.sha256)throw new Error('Reviewed prebundled companion bytes changed: '+check.package+'/'+check.file);}
    if(bundle.packageNoticeFiles?.length)packageOriginals.set(root,bundle.packageNoticeFiles.map(file=>({...file,directory})));
    for(const component of bundle.components??[])components.push({...component,via:parent,directory});
    audits.push({...parent,excluded:bundle.excluded??[],runtimeDependencies:bundle.runtimeDependencies.map(({name,version,chain,evidence})=>({name,version,chain,evidence}))});
  }
  return {provenance,audits,components,packageOriginals};
}

export async function writeNotices({inputs,cache,kind,target,qualificationRoot}){
  const nodeRoot=path.join(cache,'node_modules'),lock=JSON.parse(await fs.readFile(path.join(qualificationRoot,'WebBuild/package-lock.json'),'utf8')),packages=new Map(),missing=[];
  for(const input of inputs){
    if(!input.source.startsWith('npm/')||input.bytes===0)continue;
    const inputFile=path.join(nodeRoot,input.source.slice(4));await fs.access(inputFile);
    let current=path.dirname(inputFile),found=false;
    while(current.startsWith(nodeRoot+path.sep)){
      try{
        const metadata=JSON.parse(await fs.readFile(path.join(current,'package.json'),'utf8'));
        if(metadata.name&&metadata.version){packages.set(current,metadata);found=true;break;}
      }catch{}
      current=path.dirname(current);
    }
    if(!found)throw new Error('No installed package identity for actual input: '+input.source);
  }
  const prebundled=await collectPrebundled({packages,nodeRoot,qualificationRoot,cache,lock});
  const notices=[],records=[],seenSupplemental=new Set();
  for(const [root,metadata]of [...packages].sort((a,b)=>a[1].name.localeCompare(b[1].name)||a[1].version.localeCompare(b[1].version))){
    const declared=typeof metadata.license==='string'?metadata.license:Array.isArray(metadata.licenses)?metadata.licenses.map(v=>typeof v==='string'?v:v.type).join(' OR '):'';
    let selected;
    if(metadata.name==='arc'&&metadata.version==='0.2.0'&&declared==='BSD'){
      const bsd=await fs.readFile(path.join(root,'LICENSE.md')),gdal=await fs.readFile(path.join(root,'GDAL-LICENSE.md'));
      if(hash(bsd)!=='39b4ded6119e58a1cc899504aa4bd5df15c326073e11af20d2a51bd6a22be90b'||hash(gdal)!=='c860e7bde403ae4f12f023af91a1b7a26650a0b496dbc0ef48917f4ea259489b')throw new Error('arc license originals changed');
      selected='BSD-2-Clause AND MIT';
    }else if(metadata.name==='splaytree-ts'&&metadata.version==='1.0.2'&&declared==='BDS-3-Clause'){
      if(hash(await fs.readFile(path.join(root,'LICENSE')))!=='0e5bef767f87a35b0bcdebcda94aef2e03242d2ac221dd9a6081b6c2ab775d4c')throw new Error('splaytree-ts license original changed');
      selected='BSD-3-Clause';
    }else if(metadata.name==='zstddec'&&metadata.version==='0.2.0'&&declared==='MIT'){
      if(hash(await fs.readFile(path.join(root,'LICENSE')))!=='8d078b49fc02bd63c1beaf4ddc629a8b48e4ba6a435415408c8209e2a5c3aacf')throw new Error('Zstandard original notices changed');
      selected='MIT AND BSD-3-Clause';
    }else{try{selected=licenseChoice(declared);}catch(error){throw new Error(metadata.name+'@'+metadata.version+': '+error.message);}}
    const relative=path.relative(cache,root).replaceAll(path.sep,'/'),pinned=lock.packages[relative];
    if(!pinned||pinned.version!==metadata.version)throw new Error('Installed dependency does not match lock: '+metadata.name);
    const files=await licenseFiles(root);for(const original of prebundled.packageOriginals.get(root)??[]){const data=await fs.readFile(path.join(original.directory,original.name));if(hash(data)!==original.sha256)throw new Error('Reviewed package notice changed: '+original.name);files.push({name:original.name,data,source:original.source});}
    if(!files.length)missing.push(metadata.name+'@'+metadata.version);
    const record={name:metadata.name,version:metadata.version,packagePath:relative,declaredLicense:declared,selectedLicense:selected,integrity:pinned.integrity,source:pinned.resolved,notices:files.map(file=>({name:file.name,sha256:hash(file.data),...(file.source?{source:file.source}:{})}))};
    if(prebundled.provenance.has(root))record.inclusion=prebundled.provenance.get(root);
    if(metadata.name==='zstddec'&&metadata.version==='0.2.0'){
      const source=await fs.readFile(path.join(root,'dist/zstddec.esm.js'),'utf8'),encoded=source.match(/['"](AGFzbQE[A-Za-z0-9+/=]+)['"]/);if(!encoded)throw new Error('Expected embedded Zstandard WASM');
      const bytes=Buffer.from(encoded[1],'base64');if(hash(bytes)!=='8b093c4c144273776d511f3baaa0fec32c111500c2798cb4569a71479020e72a')throw new Error('Reviewed Zstandard WASM changed');
      record.embeddedComponents=[{name:'Zstandard decoder',version:'upstream version not reported by this WASM',selectedLicense:'BSD-3-Clause',sourceFile:'dist/zstddec.esm.js',format:'embedded-base64-wasm',byteCount:bytes.length,sha256:hash(bytes),notice:'LICENSE (Zstandard section)'}];
    }
    records.push(record);
    notices.push(`\n${'='.repeat(72)}\n${metadata.name} ${metadata.version}\nSelected license: ${selected}\nDeclared license: ${declared}\n`);
    for(const file of files)notices.push(`\n--- ${file.name} ---\n${file.data.toString('utf8')}\n`);
  }
  for(const component of prebundled.components){
    const originals=[];for(const file of component.noticeFiles){
      const resolved=path.resolve(component.directory,file.name),scope=path.resolve(qualificationRoot,'Notices/score')+path.sep;if(!resolved.startsWith(scope))throw new Error('Original notice is outside the reviewed notice directory');
      const data=await fs.readFile(resolved);if(hash(data)!==file.sha256)throw new Error('Reviewed embedded original notice changed: '+file.name);
      originals.push({name:path.relative(qualificationRoot,resolved).replaceAll(path.sep,'/'),source:file.source,sha256:file.sha256});
      if(!seenSupplemental.has(resolved)){seenSupplemental.add(resolved);notices.push(`\n--- Embedded ${component.name}: ${file.name} ---\n${data.toString('utf8')}\n`);}
    }
    records.push({name:component.name,version:component.version,component:true,selectedLicense:component.selectedLicense,source:component.source,inclusion:[{mode:'prebundled-component',via:component.via,evidence:component.evidence}],notices:originals});
  }
  const supplemental=path.join(qualificationRoot,'Notices',kind);
  try{for(const entry of await fs.readdir(supplemental,{withFileTypes:true}))if(entry.isFile()&&/\.txt$/i.test(entry.name)){const file=path.resolve(supplemental,entry.name);if(seenSupplemental.has(file))continue;const data=await fs.readFile(file);seenSupplemental.add(file);notices.push(`\n--- Additional component: ${entry.name} ---\n${data}\n`);records.push({supplemental:entry.name,sha256:hash(data)});}}catch(error){if(error.code!=='ENOENT')throw error;}
  if(kind==='gis'){
    const reviewed=path.resolve(qualificationRoot,'../../Modules/FloeGISKit/THIRD_PARTY');
    for(const component of ['JSTS','LERC']){
      const directory=path.join(reviewed,component);
      try{for(const entry of await fs.readdir(directory,{withFileTypes:true}))if(entry.isFile()&&/license|notice|copyright/i.test(entry.name)){const data=await fs.readFile(path.join(directory,entry.name));notices.push(`\n--- ${component} original ${entry.name} ---\n${data}`);records.push({supplemental:component+'/'+entry.name,sha256:hash(data)});}}
      catch{throw new Error(component+' original notices are required');}
    }
    if(hash(await fs.readFile(path.join(nodeRoot,'lerc/LercDecode.js')))!=='20a115a2ff426372eac84e062c520d1abdc650618ce4dcca402868c36241f99c')throw new Error('Reviewed LERC decoder bytes changed');
    const lercIndex=missing.indexOf('lerc@3.0.0');if(lercIndex>=0)missing.splice(lercIndex,1);
    const i=missing.indexOf('@turf/jsts@2.7.2');if(i>=0)missing.splice(i,1);
  }
  if(missing.length)throw new Error('Original dependency notices missing: '+missing.join(', '));
  await fs.writeFile(path.join(target,'THIRD-PARTY-NOTICES.txt'),'Floe bundled editor dependency notices\nFloe-authored files retain MPL-2.0. Third-party files retain the terms below.\n'+notices.join(''));
  await fs.writeFile(path.join(target,'dependency-inventory.json'),JSON.stringify({kind,packages:records,prebundledAudits:prebundled.audits},null,2)+'\n');
  return records;
}
