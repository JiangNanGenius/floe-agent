// Fixed upstream loader evaluation only. No renderer, package install or device.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const [sourceDirectory,outputDirectory]=process.argv.slice(2);
if(!sourceDirectory || !outputDirectory) throw Error('Provide source and a new output directory');
if(fs.existsSync(outputDirectory)) throw Error('Output directory already exists');
const source=fs.readFileSync(path.join(sourceDirectory,'IESLoader.js'),'utf8');
assert.equal(crypto.createHash('sha256').update(source).digest('hex'),'53238ccd54f20d4a3af09d1ee5d4a0fbb839d694e2bb4ac96715191f49d1908a');
const code=source.slice(source.indexOf('function IESLamp( text )'),source.lastIndexOf('export { IESLoader };'));
const context=vm.createContext({});
vm.runInContext(code,context,{timeout:1000});
function fixture(rows,angles,multiplier=1,ballast=1,factor=1){
 return `IESNA:LM-63-2002\n[TEST] SYNTHETIC\nTILT=NONE\n1 -1 ${multiplier} 3 ${angles.length} 1 2 0.1 0.2 0.05\n${ballast} ${factor} 12\n0 90 180\n${angles.join(' ')}\n${rows.map(r=>r.join(' ')).join('\n')}\n`;
}
const cases=[
 {id:'rotational',text:fixture([[100,50,0]],[0]),expected:[[1,0.5,0]]},
 {id:'multiplier-normalized',text:fixture([[100,50,0]],[0],2),expected:[[1,0.5,0]]},
 {id:'quarter',text:fixture([[100,50,0],[40,20,0]],[0,90]),expected:[[1,0.5,0],[0.4,0.2,0]]},
 {id:'half',text:fixture([[50,25,0],[100,50,0]],[0,180]),expected:[[0.5,0.25,0],[1,0.5,0]]},
 {id:'full-wrap',text:fixture([[10,10,10],[20,20,20],[30,30,30],[40,40,40]],[0,90,180,270]),expected:[[0.25,0.25,0.25],[0.5,0.5,0.5],[0.75,0.75,0.75],[1,1,1],[0.25,0.25,0.25]]},
 {id:'zero-output',text:fixture([[0,0,0]],[0]),expected:[[0,0,0]]},
 {id:'legacy-factors-normalized',text:fixture([[10,5,0]],[0],2,0.8,0.5),expected:[[1,0.5,0]]}
];
const results=[];
for(const item of cases){
 context.input=item.text;
 const parsed=vm.runInContext('JSON.parse(JSON.stringify(new IESLamp(input)))',context,{timeout:1000});
 const actual=JSON.parse(JSON.stringify(parsed.candelaValues));
 assert.deepEqual(actual,item.expected,item.id);
 results.push({id:item.id,passed:true,text:item.text,normalizedCandela:actual,horizontalAngles:parsed.horAngles});
}
fs.mkdirSync(outputDirectory,{recursive:false});
fs.writeFileSync(path.join(outputDirectory,'upstream-photometry.json'),JSON.stringify({
 sourceRevision:'00e83040432badf3e9b0dccf90ae57da65033d21',sourceSHA256:'53238ccd54f20d4a3af09d1ee5d4a0fbb839d694e2bb4ac96715191f49d1908a',
 cases:results,scope:'7 fixed upstream parser matrix checks; no Swift execution, absolute-candela engineering validation or lighting simulation',
 finding:'The upstream normalizes by peak. Absolute photometric calculations must retain original cd separately.'
},null,2)+'\n');
console.log(JSON.stringify({passed:results.length,scope:'upstream parser only',result:path.join(outputDirectory,'upstream-photometry.json')}));
