// SPDX-License-Identifier: MPL-2.0
// Small, value-only presentation DTO. UI commands never mutate the font document.
import { clone,t } from '../../FloeHeavyEditorSupport/Web/runtime.js';
import { glyphList,getGlyph,glyphContours,glyphBounds,activeSource,activeKerning,compatible } from './model.js';
import { contourSegments } from './contours.js';
import { parseLocation } from './variation.js';

const modes=['overview','outline','metrics','features','variations','proof'];
const tools=['select','marquee','pan','pen','rectangle','ellipse'];
const infoKeys=['familyName','styleName','unitsPerEm','ascender','descender','xHeight','capHeight','italicAngle','versionMajor','versionMinor','copyright','license','openTypeNameDesigner','openTypeNameDesignerURL','openTypeNameManufacturer','openTypeNameDescription','openTypeNameLicenseURL','openTypeOS2WeightClass','openTypeVheaVertTypoAscender','openTypeVheaVertTypoDescender','openTypeVheaVertTypoLineGap'];
const nativeInfo=info=>Object.fromEntries(infoKeys.filter(key=>['string','number','boolean'].includes(typeof info[key])).map(key=>[key,info[key]]));
const nativeNode=p=>({id:p.id,x:p.x,y:p.y,type:p.type,smooth:p.smooth});
export const nativeDefaults=()=>({mode:'overview',search:'',page:0,tool:'select',fingerDrawing:false,curveType:'line',snap:5,text:'AVOVA AVA',size:72,direction:'auto',language:'',vertical:false,multisize:false,previewLocation:{},previewFeatures:{kern:true,liga:true,mark:true,locl:true}});
export function pathCommands(contours) {
  const commands=[];
  for(const contour of contours){const {start,segments,closed}=contourSegments(contour);if(!start)continue;commands.push({op:'M',x:start.x,y:start.y});
    for(const s of segments){const end={x:s.end.x,y:s.end.y};if(s.type==='curve')commands.push({op:'C',x1:s.controls[0].x,y1:s.controls[0].y,x2:s.controls[1].x,y2:s.controls[1].y,...end});else if(s.type==='qcurve')commands.push({op:'Q',x1:s.controls[0].x,y1:s.controls[0].y,...end});else commands.push({op:'L',...end});}
    if(closed)commands.push({op:'Z'});
  }return commands;
}
function ui(e,view){return view??(e.fontNativeUI??=nativeDefaults());}
function filtered(e,view){const query=String(view.search??'').toLowerCase();return glyphList(e).filter(g=>!query||g.name.toLowerCase().includes(query)||g.unicodes.some(code=>String.fromCodePoint(code).toLowerCase().includes(query)||('u+'+code.toString(16)).includes(query)));}
const locationText=value=>Object.entries(value??{}).map(([tag,v])=>tag+'='+v).join(',');
export function fontNativeSnapshot(e,view) {
  const v=ui(e,view),source=activeSource(e),info=source.info??e.state.info,font={...e.state,glyphs:glyphList(e)},g=glyphList(e).find(g=>g.name===e.selection?.glyph)??glyphList(e)[0],all=filtered(e,v),pageSize=48,page=Math.max(0,Math.min(Math.trunc(v.page??0),Math.max(0,Math.ceil(all.length/pageSize)-1)));
  const shape=glyph=>{const contours=glyphContours(font,glyph);return {commands:pathCommands(contours),bounds:glyphBounds(font,glyph)};};
  let thumbnailBudget=14000;
  const glyphs=all.slice(page*pageSize,(page+1)*pageSize).map(glyph=>{const result={id:glyph.id,name:glyph.name,unicodes:clone(glyph.unicodes),advance:glyph.advance};const contours=glyphContours(font,glyph),count=contours.reduce((n,c)=>n+c.length,0);if(count<=2000&&count<=thumbnailBudget){Object.assign(result,shape(glyph));thumbnailBudget-=count;}else result.previewOmitted=true;return result;});
  const contours=g?glyphContours(font,g):[],pairs=[];let pairCount=0;
  for(const [left,rights]of Object.entries(activeKerning(e)))for(const [right,value]of Object.entries(rights)){pairCount++;if(pairs.length<240)pairs.push({left,right,value});}
  const groups=Object.entries(e.state.groups).slice(0,100).map(([name,glyphs])=>({name,glyphs:glyphs.join(' '),count:glyphs.length}));
  const masters=[{id:'default',name:String(e.state.info.styleName||'Regular'),location:locationText(Object.fromEntries(e.state.axes.map(a=>[a.tag,a.default])))},...e.state.masters.slice(0,127).map(m=>({id:m.id,name:String(m.name??'Master'),location:locationText(m.location)}))];
  const active=e.state.masters.find(m=>m.id===e.activeMaster);if(active&&!masters.some(m=>m.id===active.id))masters[masters.length-1]={id:active.id,name:String(active.name??'Master'),location:locationText(active.location)};
  if(!e.fontCompatibility||e.fontCompatibility.state!==e.state||e.fontCompatibility.revision!==e.revision)e.fontCompatibility={state:e.state,revision:e.revision,issues:compatible(e.state)};
  const issues=e.fontCompatibility.issues;
  const kern=(left,right)=>{const leftClass=Object.keys(e.state.groups).find(n=>n.startsWith('public.kern1.')&&e.state.groups[n].includes(left)),rightClass=Object.keys(e.state.groups).find(n=>n.startsWith('public.kern2.')&&e.state.groups[n].includes(right)),k=activeKerning(e);return k[left]?.[right]??k[left]?.[rightClass]??k[leftClass]?.[right]??k[leftClass]?.[rightClass]??0;};
  let cursor=0,previous;
  const spacing=v.mode==='metrics'&&font.glyphs.length?[...v.text].slice(0,40).map(character=>{const glyph=font.glyphs.find(g=>g.unicodes.includes(character.codePointAt(0)))??font.glyphs.find(g=>g.name==='.notdef')??font.glyphs[0],value=previous?kern(previous.name,glyph.name):0;cursor+=value;const item={name:glyph.name,previous:previous?.name??'',x:cursor,kern:value,advance:glyph.advance,...shape(glyph)};cursor+=glyph.advance;previous=glyph;return item;}):[];
  return {kind:'font',revision:e.revision??0,ui:{...Object.fromEntries(Object.keys(nativeDefaults()).map(key=>[key,clone(v[key]??nativeDefaults()[key])])),page},info:nativeInfo(info),masterID:e.activeMaster??'default',masters,masterTotal:e.state.masters.length+1,axes:e.state.axes.slice(0,32).map(a=>({tag:a.tag,name:String(a.name??a.tag),min:a.min,default:a.default,max:a.max,mapping:clone(a.mapping??[])})),axisTotal:e.state.axes.length,instances:e.state.instances.slice(0,128).map(i=>({id:String(i.id??i.name??''),name:String(i.name??''),location:locationText(i.location)})),instanceTotal:e.state.instances.length,features:e.state.features,
    glyphList:{items:glyphs,total:glyphList(e).length,filtered:all.length,page,pageSize},
    glyph:g?{id:g.id,name:g.name,unicodes:clone(g.unicodes),advance:g.advance,advanceHeight:g.advanceHeight??info.unitsPerEm,verticalOrigin:g.verticalOrigin??info.ascender,bounds:glyphBounds(font,g),commands:pathCommands(contours),componentCommands:pathCommands(contours.slice(g.contours.length)),contours:g.contours.map(c=>c.map(nativeNode)),anchors:g.anchors.map(a=>({name:a.name,x:a.x,y:a.y})),components:g.components.map(c=>({id:String(c.id??''),base:c.base,matrix:clone(c.matrix)})),guidelines:[...e.state.guidelines,...g.guidelines].map(g=>({id:String(g.id??''),name:String(g.name??''),x:g.x,y:g.y,angle:g.angle}))}:null,
    selectedPoints:clone(e.selection?.points??[]),spacing,kerning:{pairs,total:pairCount,groups,groupTotal:Object.keys(e.state.groups).length},compatibility:{count:issues.length,issues:issues.slice(0,100)},
    preview:{ready:Boolean(e.previewFamily),hasOriginal:Boolean(e.state.original)},
  };
}
export function registerFontNative(e,getView) {
  const add=(id,handler)=>e.register({id:'font.ui.'+id,title:t('字体视图','Font view'),group:t('视图','View'),access:'read',sideEffecting:true,hidden:true,fields:[]},handler);
  add('mode',a=>{if(!modes.includes(a.mode))throw new Error('Invalid font view mode');ui(e,getView()).mode=a.mode;});
  add('search',a=>{if(typeof a.query!=='string'||a.query.length>256)throw new Error('Invalid glyph search');const v=ui(e,getView());v.search=a.query;v.page=0;});
  add('page',a=>{if(!Number.isInteger(a.page)||a.page<0)throw new Error('Invalid glyph page');ui(e,getView()).page=a.page;});
  add('glyph',a=>{const g=getGlyph(e,a.glyph);e.selection={glyph:g.name,points:[]};if(a.outline!==false)ui(e,getView()).mode='outline';});
  add('points',a=>{const g=getGlyph(e,a.glyph),valid=new Set(g.contours.flat().map(p=>p.id));if(!Array.isArray(a.points)||a.points.some(id=>typeof id!=='string'||!valid.has(id)))throw new Error('Invalid point selection');e.selection={glyph:g.name,points:[...new Set(a.points)]};});
  add('master',a=>{if(a.master!=='default'&&!e.state.masters.some(m=>m.id===a.master))throw new Error('Unknown master');e.activeMaster=a.master;const glyph=glyphList(e).find(g=>g.name===e.selection?.glyph)??glyphList(e)[0];e.selection={glyph:glyph?.name??'.notdef',points:[]};});
  add('tool',a=>{const v=ui(e,getView());if(a.fingerDrawing!==undefined){if(typeof a.fingerDrawing!=='boolean')throw new Error('Invalid finger drawing mode');v.fingerDrawing=a.fingerDrawing;}if(a.tool!==undefined){if(!tools.includes(a.tool))throw new Error('Invalid outline tool');v.tool=a.tool;}if(a.curveType!==undefined){if(!['line','qcurve','curve'].includes(a.curveType))throw new Error('Invalid curve type');v.curveType=a.curveType;}if(a.snap!==undefined){if(!Number.isFinite(a.snap)||a.snap<0||a.snap>100)throw new Error('Invalid snap interval');v.snap=a.snap;}});
  add('proof',a=>{const v=ui(e,getView());for(const key of ['text','language'])if(a[key]!==undefined){if(typeof a[key]!=='string'||a[key].length>(key==='text'?20000:64))throw new Error('Invalid proof '+key);v[key]=a[key];}
    if(a.size!==undefined){if(!Number.isFinite(a.size)||a.size<12||a.size>200)throw new Error('Invalid proof size');v.size=a.size;}
    if(a.direction!==undefined){if(!['auto','ltr','rtl'].includes(a.direction))throw new Error('Invalid text direction');v.direction=a.direction;}
    for(const key of ['vertical','multisize'])if(a[key]!==undefined){if(typeof a[key]!=='boolean')throw new Error('Invalid proof toggle');v[key]=a[key];}
    if(a.location!==undefined)v.previewLocation=parseLocation(e.state.axes,a.location);
    if(a.features!==undefined){if(!a.features||Array.isArray(a.features)||typeof a.features!=='object'||Object.entries(a.features).some(([tag,on])=>!['kern','liga','calt','mark','locl','smcp'].includes(tag)||typeof on!=='boolean'))throw new Error('Invalid preview features');v.previewFeatures={...v.previewFeatures,...a.features};}
  });
}
