// SPDX-License-Identifier: MPL-2.0
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { createFont,sampleFont,normalizeFont,glyph,point,interpolateFont,registerFontModel,compatible,glyphPath,glyphBounds,activeKerning } from '../../Web/model.js';
import { variationWeights,parseLocation,mapCoordinate } from '../../Web/variation.js';
import { contourSegments,reverseContour,splitSegment,openContour,closeContour,smoothContour,moveGlyphPoints,deleteContourPoints,cubicToQuadratics } from '../../Web/contours.js';
import { makeDesignspaceArchive,readFontArchive } from '../../Web/ufo.js';
import { toCFF,sfntTables,fromOpenType,pathContours,sourceSignature,importFont,exportFont,registerFontFormats,attachVerticalMetrics,codecWOFF2 } from '../../Web/formats.js';
import { registerGeometry,readSVGOutlines,svgTransform } from '../../Web/geometry.js';
import { FontView } from '../../Web/view.js';
import { EditorEngine } from '../../../FloeHeavyEditorSupport/Web/runtime.js';
import * as opentype from 'opentype.js';
import fonteditor from 'fonteditor-core';
const require=createRequire(process.env.FLOE_EDITOR_WEB_TOOLCHAIN+'/package.json'),{JSDOM}=require('jsdom'),dom=new JSDOM('<!doctype html><html><body></body></html>');
globalThis.document=dom.window.document;globalThis.Node=dom.window.Node;globalThis.DOMParser=dom.window.DOMParser;globalThis.XMLSerializer=dom.window.XMLSerializer;
const near=(actual,expected,tolerance=1e-6)=>assert.ok(Math.abs(actual-expected)<tolerance,`${actual} != ${expected}`);
let passed=0;
function test(name,run){run();passed++;console.log('PASS',name);}
const pending=[];
const asyncTest=(name,run)=>pending.push(async()=>{await run();passed++;console.log('PASS',name);});
function modelEngine(font=createFont()){
  normalizeFont(font);const commands=new Map(),e={state:font,payload:{data:font},commands,activeMaster:'default',selection:{glyph:'A',points:[]},register(descriptor,handler){commands.set(descriptor.id,{descriptor,handler});}};
  registerFontModel(e);e.call=(id,args={})=>commands.get(id).handler(args);return e;
}
function rectangle(width=300,height=600){return [point(0,0),point(width,0),point(width,height),point(0,height)];}
export function multiAxisFixture(){
  const font=createFont();font.info.familyName='Floe Two Axis';font.info.openTypeVheaVertTypoAscender=500;font.info.openTypeVheaVertTypoDescender=-500;font.info.openTypeVheaVertTypoLineGap=0;
  font.glyphs.push(glyph('A',[65],[rectangle()],600),glyph('V',[86],[rectangle(250)],600));
  for(const g of font.glyphs){g.advanceHeight=1000;g.verticalOrigin=800;}
  font.kerning={A:{V:-20}};
  font.axes=[{tag:'wght',name:'Weight',min:400,default:400,max:700},{tag:'wdth',name:'Width',min:100,default:100,max:150}];
  font.masters=[[700,100,800,-80,1200],[400,150,700,-40,1100],[700,150,1000,-160,1500],[550,125,900,-100,1300]].map(([wght,wdth,advance,kern,height],index)=>{
    const glyphs=structuredClone(font.glyphs);glyphs.find(g=>g.name==='A').advance=advance;
    for(const g of glyphs){g.advanceHeight=height;for(const c of g.contours)for(const p of c){p.x*=advance/600;p.y*=height/1000;}}
    return {id:'master'+index,name:'Master'+index,location:{wght,wdth},glyphs,kerning:{A:{V:kern}},info:structuredClone(font.info)};
  });normalizeFont(font);return font;
}
test('support tents reproduce multi-axis correction masters and interpolate kerning / vertical metrics',()=>{
  const font=multiAxisFixture();assert.deepEqual(compatible(font),[]);
  const middle=interpolateFont(font,{wght:550,wdth:125}),quarter=interpolateFont(font,{wght:475,wdth:112.5});
  near(middle.glyphs.find(g=>g.name==='A').advance,900);near(middle.kerning.A.V,-100);
  near(quarter.glyphs.find(g=>g.name==='A').advance,712.5);near(quarter.kerning.A.V,-50);near(quarter.glyphs[1].advanceHeight,1112.5);
  for(const master of font.masters){const result=interpolateFont(font,master.location);near(result.glyphs[1].advance,master.glyphs[1].advance);near(result.kerning.A.V,master.kerning.A.V);}
});
test('axis maps use design coordinates and reject unknown axes or duplicate master positions',()=>{
  const font=sampleFont();normalizeFont(font);font.axes[0].mapping=[[400,0],[550,200],[700,1000]];
  near(mapCoordinate(font.axes[0],625),600);near(mapCoordinate(font.axes[0],600,true),625);
  near(variationWeights(font,{wght:550}).weights[1],.2);
  assert.throws(()=>parseLocation(font.axes,'oops=10'));assert.throws(()=>parseLocation(font.axes,'wght=NaN'));assert.throws(()=>parseLocation(font.axes,'wght='));
  font.masters.push(structuredClone(font.masters[0]));assert.ok(compatible(font).some(i=>i.error==='duplicate master location'));
});
test('curve splitting preserves exact cubic geometry and true bounds exclude off-curve extremes',()=>{
  const contour=[point(0,0,'move'),point(0,200,'offcurve'),point(100,200,'offcurve'),point(100,0,'curve')],split=splitSegment(contour,0,.5),path=contourSegments(split);
  assert.equal(path.segments.length,2);near(path.segments[0].end.x,50);near(path.segments[0].end.y,150);
  const g=glyph('test',[],[contour]);near(glyphBounds({...createFont(),glyphs:[g]},g).yMax,150);
  const first=path.segments[0],second=path.segments[1];near(first.controls[0].y,100);near(first.controls[1].y,150);near(second.controls[0].y,150);
});
test('reverse / open / close preserve mixed UFO curves and all-off quadratic contours',()=>{
  const contour=[point(0,0,'line'),point(0,100,'offcurve'),point(100,100,'offcurve'),point(100,0,'curve'),point(50,-50,'line')];
  const reverse=reverseContour(contour),twice=reverseContour(reverse),shape=c=>contourSegments(c).segments.map(s=>[s.start.x,s.start.y,s.type,...s.controls.flatMap(p=>[p.x,p.y]),s.end.x,s.end.y]);
  assert.deepEqual(shape(twice),shape(contour));const open=openContour(contour,contour[3].id);assert.equal(contourSegments(open).closed,false);assert.equal(contourSegments(open).segments.length,3);assert.equal(contourSegments(closeContour(open)).segments.length,3);
  const allOff=[point(0,0,'offcurve'),point(100,0,'offcurve'),point(100,100,'offcurve'),point(0,100,'offcurve')];assert.equal(contourSegments(reverseContour(allOff)).segments.length,4);
});
test('smooth handles stay tangent during drag, and on-curve moves carry adjacent handles once',()=>{
  const contour=[point(0,0),point(80,0),point(100,40),point(20,80)],anchor=contour[1],smooth=smoothContour(contour,[anchor.id],'symmetric'),g=glyph('A',[],[smooth]);
  let index=g.contours[0].findIndex(p=>p.id===anchor.id),before=g.contours[0][index-1],after=g.contours[0][index+1];
  moveGlyphPoints(g,[{id:after.id,x:120,y:60}]);index=g.contours[0].findIndex(p=>p.id===anchor.id);const a=g.contours[0][index];before=g.contours[0][index-1];after=g.contours[0][index+1];near((before.x-a.x)*(after.y-a.y)-(before.y-a.y)*(after.x-a.x),0);
  const old=[before.x,before.y];moveGlyphPoints(g,[{id:a.id,x:a.x+10,y:a.y+20}]);near(before.x-old[0],10);near(before.y-old[1],20);
});
test('master CRUD, glyph naming / charset, components and kerning operate on real source data',()=>{
  const e=modelEngine(sampleFont());e.call('variation.masterEdit',{master:e.state.masters[0].id,name:'Heavy',location:'wght=700'});e.activeMaster=e.state.masters[0].id;
  e.call('kerning.pair',{left:'A',right:'V',value:-123});near(activeKerning(e).A.V,-123);near(e.state.kerning.A.V,-80);
  e.call('glyph.duplicate',{glyph:'A',name:'A.alt'});assert.ok(e.state.masters.every(m=>m.glyphs.some(g=>g.name==='A.alt')));
  e.call('glyph.rename',{glyph:'A.alt',name:'A.test'});assert.ok(e.state.glyphs.some(g=>g.name==='A.test'));
  e.call('glyph.charset',{characters:'ABé',advance:620});assert.equal(e.state.glyphs.filter(g=>g.unicodes.includes(233)).length,1);
  const master=e.state.masters[0];e.call('variation.masterEdit',{master:master.id,remove:true});assert.equal(e.activeMaster,'default');assert.equal(e.state.masters.length,0);
});
test('compatibility checks component identity, anchors, extra glyphs and point topology',()=>{
  const font=sampleFont();normalizeFont(font);font.masters[0].glyphs[1].components.push({base:'A',matrix:[1,0,0,1,0,0]});font.masters[0].glyphs[2].anchors.push({name:'top',x:0,y:0});
  assert.ok(compatible(font).some(i=>i.error==='incompatible components'));assert.ok(compatible(font).some(i=>i.error==='incompatible anchors'));
});
test('untrusted project coordinates, metrics and matrices cannot become SVG markup',()=>{
  for(const modify of [f=>f.glyphs[0].contours[0][0].x='0"/><image href="https://example.invalid"/>',f=>f.info.ascender='900" onload="alert(1)',f=>f.glyphs[0].advance=Infinity,f=>f.glyphs[0].components.push({base:'A',matrix:[1,0,0,1,'0" onload="',0]}),f=>f.glyphs[0].anchors.push({name:'test',x:NaN,y:0})]){const font=sampleFont();modify(font);assert.throws(()=>normalizeFont(font));}
});
test('UFO / Designspace round-trip master kerning, mapped coordinates and vertical origins',()=>{
  const font=multiAxisFixture();font.axes[0].mapping=[[400,0],[550,200],[700,1000]];
  const result=readFontArchive(makeDesignspaceArchive(font));assert.deepEqual(result.axes,font.axes);assert.equal(result.masters.length,4);assert.deepEqual(result.masters[0].location,font.masters[0].location);near(result.masters[3].kerning.A.V,-100);near(result.masters[0].glyphs[1].advanceHeight,1200);near(result.masters[0].glyphs[1].verticalOrigin,800);assert.deepEqual(compatible(result),[]);
});
test('boolean union / difference, extrema and bounded cubic-to-quadratic conversion execute',()=>{
  const e=modelEngine();e.state.glyphs.push(glyph('A',[65],[rectangle()],600),glyph('B',[66],[rectangle().map(p=>({...p,x:p.x+150}))],600));registerGeometry(e);
  e.call('outline.unite',{glyph:'A',other:'B'});const report=e.call('outline.inspect',{glyph:'A'});near(Math.abs(report.area),270000);near(glyphBounds(e.state,e.state.glyphs[1]).xMax,450);
  e.call('outline.subtract',{glyph:'A',other:'B'});near(Math.abs(e.call('outline.inspect',{glyph:'A'}).area),90000);
  e.call('outline.shape',{glyph:'A',shape:'ellipse',x:0,y:0,width:200,height:200});e.call('outline.extrema',{glyph:'A'});e.call('outline.convert',{glyph:'A',type:'quadratic',tolerance:.5});assert.ok(e.state.glyphs[1].contours.flat().some(p=>p.type==='qcurve'));for(const c of e.state.glyphs[1].contours)contourSegments(c);
  e.state.glyphs[1].contours=[[point(0,0),point(0,200,'offcurve'),point(100,200,'offcurve'),point(100,0,'curve')]];e.call('outline.extrema',{glyph:'A'});assert.ok(e.state.glyphs[1].contours.flat().some(p=>p.type!=='offcurve'&&Math.abs(p.y-150)<1e-6));
  const curves=cubicToQuadratics([{x:0,y:0},{x:40,y:300},{x:60,y:-100},{x:100,y:0}],.1);assert.ok(curves.length>2);near(curves.at(-1).end.x,100);
});
test('nested contours expose hole direction conflicts and can correct their winding',()=>{
  const outer=rectangle(500,500),inner=rectangle(200,200).map(p=>({...p,x:p.x+100,y:p.y+100})),e=modelEngine();e.state.glyphs.push(glyph('A',[65],[outer,inner]));registerGeometry(e);
  assert.ok(e.call('outline.inspect',{glyph:'A'}).contours.some(c=>c.hole&&c.windingConflict));e.call('outline.winding',{glyph:'A',clockwise:true});assert.ok(e.call('outline.inspect',{glyph:'A'}).contours.some(c=>c.hole&&!c.windingConflict));
});
test('deleting handles / endpoints, contour joining and rotation keep valid point-pen contours',()=>{
  const c=[point(0,0,'move'),point(0,100,'offcurve'),point(100,100,'offcurve'),point(100,0,'curve'),point(150,0)];
  for(const ids of [[c[1].id],[c[3].id],[c[0].id]])assert.doesNotThrow(()=>contourSegments(deleteContourPoints(c,ids)));
  const e=modelEngine();e.state.glyphs.push(glyph('A',[65],[[point(0,0,'move'),point(100,0)],[point(100,0,'move'),point(100,100)]]));
  e.call('contour.join',{glyph:'A',first:0,second:1});assert.equal(e.state.glyphs[1].contours.length,1);assert.equal(contourSegments(e.state.glyphs[1].contours[0]).segments.length,2);
});
test('SVG glyph import applies group transforms, arcs, shapes and local reuse without resource fetches',()=>{
  const svg='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400"><defs><rect id="r" x="0" y="0" width="100" height="50"/></defs><g transform="translate(20 30) scale(2)"><use href="#r"/></g><path d="M0 0 A50 50 0 0 1 100 0 Z"/></svg>';
  const contours=readSVGOutlines(svg,{flipY:false}),g=glyph('test',[],contours),bounds=glyphBounds({...createFont(),glyphs:[g]},g);near(bounds.xMax,220);near(bounds.yMax,130);assert.ok(contours.flat().some(p=>p.type==='curve'));
  assert.throws(()=>readSVGOutlines('<svg xmlns="http://www.w3.org/2000/svg"><use href="https://example.invalid/x"/></svg>'));
  assert.throws(()=>readSVGOutlines('<svg xmlns="http://www.w3.org/2000/svg"><text>A</text></svg>'));assert.deepEqual(svgTransform('translate(20 30) scale(2)'),[2,0,0,2,20,30]);
});
asyncTest('all six editor panes render and their inspector actions resolve to real commands',async()=>{
  const e=modelEngine(sampleFont());registerGeometry(e);registerFontFormats(e);e.command=id=>{const command=e.commands.get(id);assert.ok(command,'Missing UI command '+id);return command.descriptor;};e.showAction=descriptor=>{e.lastAction=descriptor.id;};e.sidebar=document.createElement('aside');e.canvas=document.createElement('main');e.inspector=document.createElement('aside');
  const view=new FontView(e);for(const mode of ['overview','outline','metrics','features','variations','proof']){view.mode=mode;await view.render();assert.ok(e.canvas.children.length>1);for(const button of e.inspector.querySelectorAll('button'))button.click();}
});
asyncTest('shared dispatcher history serializes / reopens and undoes / redoes master kerning edits',async()=>{
  const make=()=>{const e=new EditorEngine({kind:'font',title:'Font',create:sampleFont,normalize:normalizeFont,render:async()=>{}});registerFontModel(e);return e;};
  const e=make();await e.load({kind:'font',revision:0,content:{data:sampleFont(),history:{past:[],future:[]}}});e.activeMaster=e.state.masters[0].id;
  await e.perform('kerning.pair',{left:'A',right:'V',value:-135});near(e.state.masters[0].kerning.A.V,-135);near(e.state.kerning.A.V,-80);
  const saved=JSON.parse(JSON.stringify(e.payload)),reopened=make();await reopened.load({kind:'font',revision:1,content:saved});await reopened.perform('history.undo');near(reopened.state.masters[0].kerning.A.V,-80);await reopened.perform('history.redo');near(reopened.state.masters[0].kerning.A.V,-135);
});
const fixturePath=process.env.FLOE_FONT_WRITE_FIXTURE;
if(fixturePath){
  fs.writeFileSync(fixturePath,makeDesignspaceArchive(multiAxisFixture()));
  const font=createFont();font.info.familyName='Floe Layout';
  for(const [name,code,width]of [['A',65,600],['V',86,600],['f',102,350],['i',105,250],['fi',64257,500]])font.glyphs.push(glyph(name,[code],[rectangle(width-100)],width));
  font.glyphs.find(g=>g.name==='A').anchors.push({name:'top',x:300,y:700});
  const acute=glyph('acutecomb',[769],[[point(0,0),point(40,100),point(100,100),point(60,0)]],0);acute.anchors=[{name:'_top',x:50,y:0}];font.glyphs.push(acute);
  font.features='languagesystem DFLT dflt; feature liga { sub f i by fi; } liga;';font.kerning={A:{V:-80}};
  fs.writeFileSync(fixturePath.replace('multi-axis.zip','static-layout.zip'),makeDesignspaceArchive(font));console.log('WROTE',fixturePath);
}
if(process.env.FLOE_FONT_NATIVE_TTF){
  test('real native TTF converts to genuine CFF OTF with checksums and layout tables',()=>{
    const ttf=new Uint8Array(fs.readFileSync(process.env.FLOE_FONT_NATIVE_TTF)),cff=toCFF(ttf,{familyName:'Floe Test',styleName:'Regular'}),tables=sfntTables(cff);
    assert.ok(tables.has('CFF '));assert.ok(!tables.has('glyf'));assert.ok(tables.has('GSUB'));assert.ok(tables.has('GPOS'));
    let sum=0;const view=new DataView(cff.buffer);for(let i=0;i<cff.length;i+=4)sum=(sum+view.getUint32(i))>>>0;assert.equal(sum,0xb1b0afba);
    const parsed=opentype.parse(cff.buffer);assert.ok(parsed.glyphs.length>=5);assert.ok(parsed.charToGlyph('A').path.commands.length>0);fs.writeFileSync(process.env.FLOE_FONT_NATIVE_TTF.replace(/\.ttf$/,'.otf'),cff);
  });
  asyncTest('real WOFF and bundled WOFF2 WASM round-trip static and variable sfnt fonts',async()=>{
    await fonteditor.woff2.init();
    for(const path of [process.env.FLOE_FONT_NATIVE_TTF,process.env.FLOE_FONT_NATIVE_TTF.replace('static-layout.ttf','variable-ligature.ttf')]){
      const bytes=new Uint8Array(fs.readFileSync(path)),buffer=bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength),source=opentype.parse(buffer);
      for(const format of ['woff','woff2']){
        const compressed=format==='woff'?fonteditor.ttf2woff(buffer):await codecWOFF2(bytes,true),decoded=format==='woff'?fonteditor.woff2ttf(compressed):await codecWOFF2(compressed,false),font=opentype.parse(decoded.buffer??decoded);
        assert.equal(font.glyphs.length,source.glyphs.length);near(font.charToGlyph('A').advanceWidth,source.charToGlyph('A').advanceWidth);assert.equal(Boolean(font.tables.fvar),Boolean(source.tables.fvar));
        fs.writeFileSync(path.replace(/\.ttf$/,'.'+format),new Uint8Array(compressed));
      }
    }
  });
  asyncTest('TTF import preserves byte-exact original export and exposes rebuilt-table policy',async()=>{
    const bytes=new Uint8Array(fs.readFileSync(process.env.FLOE_FONT_NATIVE_TTF)),e=modelEngine();await importFont(e,{name:'fixture.ttf',base64:Buffer.from(bytes).toString('base64')});
    const gposKerning=e.state.kerning.A?.V??Object.entries(e.state.kerning).flatMap(([left,rights])=>Object.entries(rights).filter(([right])=>(left==='A'||e.state.groups[left]?.includes('A'))&&(right==='V'||e.state.groups[right]?.includes('V'))).map(([,value])=>value))[0];near(gposKerning,-80);
    const response=await exportFont(e,{format:'original'});assert.equal(response.artifacts[0].base64,Buffer.from(bytes).toString('base64'));assert.ok(e.state.original.policy.includes('not copied'));
    const merged=modelEngine();await importFont(merged,{name:'fixture.ttf',base64:Buffer.from(bytes).toString('base64'),mode:'merge',prefix:'added.'});assert.ok(merged.state.glyphs.some(g=>g.name==='added.A'));assert.ok(merged.state.mergedSources.length===1);
  });
  test('VVAR import exposes exact variable vertical advances in editable glyph metrics',()=>{
    const path=process.env.FLOE_FONT_NATIVE_TTF.replace('static-layout.ttf','multi-axis.ttf');
    if(!fs.existsSync(path))throw new Error('Native multi-axis fixture is required for vertical read-back');
    const bytes=new Uint8Array(fs.readFileSync(path)),parsed=attachVerticalMetrics(opentype.parse(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)),bytes),font=fromOpenType(parsed,'Vertical',{wght:475,wdth:112.5});
    near(font.glyphs.find(g=>g.name==='A').advanceHeight,1112.5,1);assert.ok(Number.isFinite(font.glyphs.find(g=>g.name==='A').verticalOrigin));
  });
}
(async()=>{for(const run of pending)await run();console.log(`Font web behavior: ${passed} passed`);})().catch(error=>{console.error(error);process.exitCode=1;});
