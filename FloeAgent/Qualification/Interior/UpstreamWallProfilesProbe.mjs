// SPDX-License-Identifier: MPL-2.0
// Runs the pinned MIT upstream algorithm; does not ship it in the App.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = resolve(process.argv[2] ?? '');
assert.ok(process.argv[2], 'Pass the task-owned upstream fixture directory');
const pinned = 'b0727b54da5f0f642722dcc88cc52d7236fadc9e';
const expected = {
  'wallProfiles.ts': 'bc61ab5650500066f0699e4c2548656b9074fbd3',
  'models-types.ts': '07edba8e16e92484e6050e5f6acb3c94bf1f96ad',
  'LICENSE': 'e19847719492831e7ba07f12a7929ed410b386a4',
};
const files = {};
for (const [name, sha] of Object.entries(expected)) {
  const data = await readFile(join(root, 'original', name));
  const actual = createHash('sha1').update(`blob ${data.length}\0`).update(data).digest('hex');
  assert.equal(actual, sha, `Upstream bytes changed: ${name}`);
  files[name] = { gitBlobSHA: sha, sha256: createHash('sha256').update(data).digest('hex') };
}
const original = await readFile(join(root, 'original', 'wallProfiles.ts'), 'utf8');
assert.equal(await readFile(join(root, 'runnable', 'wallProfiles.ts'), 'utf8'),
  original.replace("from '$lib/models/types'", "from './models-types.ts'"));
assert.deepEqual(await readFile(join(root, 'runnable', 'models-types.ts')),
  await readFile(join(root, 'original', 'models-types.ts')));
const api = await import(pathToFileURL(join(root, 'runnable', 'wallProfiles.ts')).href);
const cases = [];
function check(name, run) { run(); cases.push({ name, passed: true }); }
function near(a, b, epsilon = 1e-7) { assert.ok(Math.abs(a-b) < epsilon, `${a} != ${b}`); }
function area(segments) { return segments.reduce((a,s) => a+s.width*((s.topYLeft+s.topYRight)/2-s.bottomY),0); }
function wall(extra={}) {
  return { id:'w1', start:{x:0,y:0}, end:{x:400,y:0}, height:270, thickness:20, ...extra };
}
check('straight wall area minus door', () => {
  near(area(api.buildWallSegments(400,270,270,[{position:0.5,width:90}],[])),400*270-90*210);
});
check('overlapping door and window subtract their union', () => {
  near(area(api.buildWallSegments(400,270,270,[{position:0.5,width:100,height:210}],
    [{position:0.625,width:100,sillHeight:90,height:120}])),81000);
});
check('opening at wall end is clipped without changing stored width', () => {
  const door={position:0,width:90,height:210};
  near(area(api.buildWallSegments(400,270,270,[door],[])),400*270-45*210);
  assert.equal(door.width,90);
});
check('sloped opening fits below both endpoint heights', () => {
  assert.deepEqual(api.openingOnWall(400,240,300,0.25,100,0,280),
    {left:50,right:150,bottom:0,top:247.5});
});
check('full wall aperture leaves no blocking face', () => {
  assert.deepEqual(api.buildWallSegments(400,270,270,[{position:0.5,width:500,height:300}],[]),[]);
});
check('invalid and zero length profiles produce no geometry', () => {
  assert.deepEqual(api.buildWallSegments(0,270,270,[],[]),[]);
  assert.equal(api.openingOnWall(400,270,270,NaN,90,0,210),null);
});
check('curved wall uses 16 finite spans with original endpoints', () => {
  const spans=api.wallPathSpans(wall({curvePoint:{x:150,y:120}}));
  assert.equal(spans.length,16);
  assert.deepEqual(spans[0].start,{x:0,y:0});
  assert.deepEqual(spans.at(-1).end,{x:400,y:0});
  const path=api.wallPathProfile(wall({curvePoint:{x:150,y:120}}));
  assert.ok(path.length>400);
  near(path.distanceAt(1),path.length);
});
check('curved profile full aperture remains open across facet joins', () => {
  const w=wall({curvePoint:{x:150,y:120}});
  const spans=api.wallProfileSpans(w,[{position:0.5,width:1000,height:300}],[]);
  assert.equal(spans.length,16);
  assert.ok(spans.every(s=>s.segments.length===0));
});
check('ceiling height refuses missing or inconsistent boundaries', () => {
  assert.equal(api.roomCeilingHeight(['w1'],[wall()]),270);
  assert.equal(api.roomCeilingHeight(['missing'],[wall()]),undefined);
  assert.equal(api.roomCeilingHeight(['w1','w2'],[wall(),wall({id:'w2',height:280})]),undefined);
});
check('short baseboard segment cannot acquire negative width', () => {
  assert.equal(api.baseboardSegment({width:0.8,offsetX:100},{from:0,length:400},400).width,0);
});
const receipt={
  scope:'Selected upstream wall profile functions executed headlessly, not an iOS port',
  repository:'https://github.com/laanlabs/openPlan3D',revision:pinned,license:'MIT',
  runtime:process.version,files,adaptation:'Only the models import path was replaced for local Node loading',
  units:'Upstream inputs are centimeters; centimeter-squared areas. Native Floe CAD uses millimeters.',
  limitations:['No exact arc conversion','No room detection or RoomPlan import exercised','No native Swift port qualified'],
  cases,passed:cases.length,
};
await writeFile(join(root,'verification.json'),JSON.stringify(receipt,null,2)+'\n');
console.log(JSON.stringify({passed:cases.length,revision:pinned}));
