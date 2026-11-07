// SPDX-License-Identifier: MPL-2.0
import * as opentype from 'opentype.js';
import fonteditor from 'fonteditor-core';
import { zipSync,strToU8,unzipSync,strFromU8 } from 'fflate';
import { clone,uid,t,required,from64,bytes64,artifact,parseXML,escapeXML } from '../../FloeHeavyEditorSupport/Web/runtime.js';
import { createFont,normalizeFont,glyph,point,glyphPath,glyphBounds,field,glyphField,interpolateFont,glyphList,activeSource } from './model.js';
import { readSVGOutlines } from './geometry.js';
import { parseLocation } from './variation.js';
import { makeDesignspaceArchive,makeUFOFiles,readFontArchive } from './ufo.js';
let woffPromise;
export const sourceSignature=font=>{const {original,...data}=font,text=JSON.stringify(data);let a=2166136261,b=5381;for(let i=0;i<text.length;i++){a=Math.imul(a^text.charCodeAt(i),16777619);b=Math.imul(b,33)^text.charCodeAt(i);}return text.length+':'+(a>>>0).toString(16)+':'+(b>>>0).toString(16);};
export const originalIsCurrent=font=>Boolean(font.original?.signature&&font.original.signature===sourceSignature(font));
const arrayBuffer=bytes=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength);
export function woff2AssetLocation(){
  // WKWebView's custom scheme cannot be fetched by this Emscripten loader.
  // The host injects only fixed, bundled binary assets before document start.
  const assets=globalThis.FloeBundledBinaryAssets;
  if(assets&&Object.prototype.hasOwnProperty.call(assets,'woff2.wasm')){
    const base64=assets['woff2.wasm'];if(typeof base64!=='string'||!base64.length||!/^[A-Za-z0-9+/]*={0,2}$/.test(base64))throw new Error('Invalid bundled WOFF2 data');
    return 'data:application/octet-stream;base64,'+base64;
  }
  // The pinned package's explicit Node fixture resolves its own wasm path.
  return typeof window==='undefined'?undefined:new URL('woff2.wasm',location.href).href;
}
export const initWOFF2=()=>fonteditor.woff2.isInited()?Promise.resolve(fonteditor.woff2):(woffPromise??=fonteditor.woff2.init(woff2AssetLocation()));
export async function codecWOFF2(bytes,encode){
  await initWOFF2();const data=bytes instanceof Uint8Array?bytes:new Uint8Array(bytes),module=fonteditor.woff2.woff2Module,vector=module[encode?'woff2Enc':'woff2Dec'](data,data.byteLength);
  try{const length=vector.size();if(!length||length>256*1024*1024)throw new Error('Invalid WOFF2 result');return Uint8Array.from({length},(_,i)=>vector.get(i));}finally{vector.delete();}
}
export function pathContours(commands){
  const contours=[];let contour=[];
  const end=closed=>{if(!contour.length)return;if(closed){if(contour.length>1&&contour[0].x===contour.at(-1).x&&contour[0].y===contour.at(-1).y){const last=contour.pop();contour[0].type=last.type;}else contour[0].type='line';}else contour[0].type='move';contours.push(contour);contour=[];};
  for(const command of commands){if(command.type==='M'){end(false);contour.push(point(command.x,command.y));}else if(command.type==='L')contour.push(point(command.x,command.y));else if(command.type==='Q')contour.push(point(command.x1,command.y1,'offcurve'),point(command.x,command.y,'qcurve'));else if(command.type==='C')contour.push(point(command.x1,command.y1,'offcurve'),point(command.x2,command.y2,'offcurve'),point(command.x,command.y,'curve'));else if(command.type==='Z')end(true);}end(false);return contours;
}
function namesValue(value,fallback=''){return typeof value==='string'?value:value?.en??Object.values(value??{})[0]??fallback;}
function readDefaultKerning(parsed,font){
  // Editable horizontal PairPos kerning for the parser's default script. Other
  // script/context/device programs remain in the original, not invented as FEA.
  const lookups=parsed.position?.defaultKerningTables??[];let serial=0;
  const name=index=>font.glyphs[index]?.name,set=(left,right,value)=>{if(left&&right&&Number.isFinite(value)){font.kerning[left]??={};font.kerning[left][right]=value;}};
  for(const lookup of lookups){
    for(const subtable of lookup.subtables??[]){
      if(subtable.posFormat===1){for(let left=0;left<font.glyphs.length;left++){const index=parsed.position.getCoverageIndex(subtable.coverage,left);if(index<0)continue;for(const pair of subtable.pairSets[index]??[])if(pair.value1?.xAdvance!==undefined)set(name(left),name(pair.secondGlyph),pair.value1.xAdvance);}}
      else if(subtable.posFormat===2){
        const lefts=new Map(),rights=new Map();for(let i=0;i<font.glyphs.length;i++){const l=parsed.position.getGlyphClass(subtable.classDef1,i),r=parsed.position.getGlyphClass(subtable.classDef2,i);if(parsed.position.getCoverageIndex(subtable.coverage,i)>=0){if(!lefts.has(l))lefts.set(l,[]);lefts.get(l).push(name(i));}if(!rights.has(r))rights.set(r,[]);rights.get(r).push(name(i));}
        const groups=new Map(),group=(side,index,members)=>{const key=side+':'+index;if(!groups.has(key)){const existing=Object.entries(font.groups).find(([n,values])=>n.startsWith('public.kern'+side+'.')&&values.length===members.length&&values.every((n,i)=>n===members[i]));if(existing){groups.set(key,existing[0]);return existing[0];}if(Object.entries(font.groups).some(([n,values])=>n.startsWith('public.kern'+side+'.')&&values.some(v=>members.includes(v))))return null;const keyName='public.kern'+side+'.imported'+serial+'_'+index;font.groups[keyName]=members;groups.set(key,keyName);}return groups.get(key);};
        for(const [left,members]of lefts)for(const [right,rightMembers]of rights){const value=subtable.classRecords[left]?.[right]?.value1?.xAdvance;if(!value)continue;const l=group(1,left,members),r=group(2,right,rightMembers);if(l&&r)set(l,r,value);}
        serial++;
      }
    }
    // Multiple positioning lookups can be additive. A source-level rebuild
    // cannot safely collapse arbitrary lookup order into one UFO kerning map.
    break;
  }
}
export function attachVerticalMetrics(parsed,bytes){
  const tables=sfntTables(bytes),vhea=tables.get('vhea'),vmtx=tables.get('vmtx');if(!vhea||!vmtx)return parsed;
  const view=data=>new DataView(data.buffer,data.byteOffset,data.byteLength),header=view(vhea),metrics=view(vmtx),count=header.getUint16(34);if(!count||count>parsed.glyphs.length)throw new Error('Invalid vertical metric count');
  const origins=new Map(),vorg=tables.get('VORG');let defaultOrigin;
  if(vorg){const data=view(vorg);defaultOrigin=data.getInt16(4);for(let i=0;i<data.getUint16(6);i++)origins.set(data.getUint16(8+i*4),data.getInt16(10+i*4));}
  parsed.floeVertical={info:{openTypeVheaVertTypoAscender:header.getInt16(4),openTypeVheaVertTypoDescender:header.getInt16(6),openTypeVheaVertTypoLineGap:header.getInt16(8)},metrics:Array.from({length:parsed.glyphs.length},(_,i)=>({advanceHeight:metrics.getUint16(Math.min(i,count-1)*4),topBearing:metrics.getInt16(i<count?i*4+2:count*4+(i-count)*2),origin:origins.get(i)??defaultOrigin}))};
  const vvar=tables.get('VVAR');if(vvar){const p=new opentype._parse.Parser(view(vvar),0),major=p.parseUShort();p.parseUShort();if(major!==1)throw new Error('Unsupported VVAR version');const store=p.parsePointer32(function(){return this.parseItemVariationStore();}),readMap=()=>p.parsePointer32(function(){return this.parseDeltaSetIndexMap();});parsed.tables.vvar={itemVariationStore:store,advanceHeight:readMap(),topBearing:readMap(),bottomBearing:readMap(),verticalOrigin:readMap()};}
  return parsed;
}
export function fromOpenType(parsed,name='Typeface',location){
  const result=createFont();result.info={...result.info,familyName:namesValue(parsed.names.fontFamily,name),styleName:namesValue(parsed.names.fontSubfamily,'Regular'),unitsPerEm:parsed.unitsPerEm,ascender:parsed.ascender,descender:parsed.descender,xHeight:parsed.tables.os2?.sxHeight??500,capHeight:parsed.tables.os2?.sCapHeight??700,copyright:namesValue(parsed.names.copyright),license:namesValue(parsed.names.license),openTypeNameLicenseURL:namesValue(parsed.names.licenseURL),versionMajor:1,versionMinor:0};result.title=result.info.familyName;result.glyphs=[];
  for(let i=0;i<parsed.glyphs.length;i++){
    const original=parsed.glyphs.get(i),source=location&&parsed.variation?parsed.variation.getTransform(original,location):original;let name=/^[A-Za-z_.][A-Za-z0-9_.]*$/.test(original.name??'')?original.name:i===0?'.notdef':'glyph'+i;while(result.glyphs.some(g=>g.name===name))name+='_';
    const g=glyph(name,[...new Set(original.unicodes??[])],pathContours(source.path.commands),source.advanceWidth??600);g.leftBearing=source.leftSideBearing??0;g.sourceGlyphID=i;
    const vertical=parsed.floeVertical?.metrics[i];if(vertical){const adjustment=key=>parsed.tables.vvar&&parsed.variation&&(key==='advanceHeight'||parsed.tables.vvar[key])?parsed.variation.process.getVariableAdjustment(i,'vvar',key,location):0;g.advanceHeight=vertical.advanceHeight+adjustment('advanceHeight');g.verticalOrigin=vertical.origin!==undefined?vertical.origin+adjustment('verticalOrigin'):glyphBounds({...result,glyphs:[g]},g).yMax+vertical.topBearing+adjustment('topBearing');}
    result.glyphs.push(g);
  }
  for(const [pair,value]of Object.entries(parsed.kerningPairs??{})){const [left,right]=pair.split(',').map(Number),l=result.glyphs[left]?.name,r=result.glyphs[right]?.name;if(l&&r){result.kerning[l]??={};result.kerning[l][r]=value;}}
  readDefaultKerning(parsed,result);
  Object.assign(result.info,parsed.floeVertical?.info??{});result.axes=(parsed.tables.fvar?.axes??[]).map(a=>({tag:a.tag,name:namesValue(a.name,a.tag),min:a.minValue,default:a.defaultValue,max:a.maxValue}));
  result.instances=(parsed.tables.fvar?.instances??[]).map(instance=>({id:uid(),name:namesValue(instance.name,'Instance'),location:clone(instance.coordinates)}));normalizeFont(result);return result;
}
export function sfntTables(bytes){
  const data=bytes instanceof Uint8Array?bytes:new Uint8Array(bytes),view=new DataView(data.buffer,data.byteOffset,data.byteLength);if(data.length<12)throw new Error('Invalid sfnt header');const count=view.getUint16(4),tables=new Map();
  if(12+count*16>data.length)throw new Error('Invalid sfnt directory');for(let i=0;i<count;i++){const entry=12+i*16,tag=String.fromCharCode(...data.subarray(entry,entry+4)),offset=view.getUint32(entry+8),length=view.getUint32(entry+12);if(offset+length>data.length)throw new Error('Invalid font table bounds');tables.set(tag,data.slice(offset,offset+length));}return tables;
}
export function assembleSFNT(tables,version=0x00010000){
  const entries=[...tables.entries()].sort(([a],[b])=>a.localeCompare(b)),count=entries.length,header=12+count*16,total=header+entries.reduce((sum,[,bytes])=>sum+Math.ceil(bytes.length/4)*4,0),result=new Uint8Array(total),view=new DataView(result.buffer);view.setUint32(0,version);view.setUint16(4,count);const power=2**Math.floor(Math.log2(count));view.setUint16(6,power*16);view.setUint16(8,Math.log2(power));view.setUint16(10,count*16-power*16);
  let offset=header,headOffset;
  const checksum=(data,start=0,length=data.length)=>{let sum=0;for(let i=start;i<start+length;i+=4){let word=0;for(let b=0;b<4;b++)word=(word<<8)|(data[i+b]??0);sum=(sum+(word>>>0))>>>0;}return sum;};
  entries.forEach(([tag,original],index)=>{const bytes=original.slice();if(tag==='head'){bytes.fill(0,8,12);headOffset=offset;}const entry=12+index*16;result.set([...tag].map(c=>c.charCodeAt(0)),entry);view.setUint32(entry+4,checksum(bytes));view.setUint32(entry+8,offset);view.setUint32(entry+12,bytes.length);result.set(bytes,offset);offset+=Math.ceil(bytes.length/4)*4;});
  if(headOffset!==undefined)view.setUint32(headOffset+8,(0xb1b0afba-checksum(result))>>>0);return result;
}
export function toCFF(ttf,info){
  const source=opentype.parse(arrayBuffer(ttf)),glyphs=[];if(source.tables.fvar)throw new Error('Generate a static instance before CFF export');for(let i=0;i<source.glyphs.length;i++){const original=source.glyphs.get(i);glyphs.push(new opentype.Glyph({name:original.name??'glyph'+i,unicode:original.unicode,unicodes:original.unicodes,advanceWidth:original.advanceWidth,path:original.path}));}
  const cff=new opentype.Font({familyName:info.familyName,styleName:info.styleName,unitsPerEm:source.unitsPerEm,ascender:source.ascender,descender:source.descender,glyphs}),minimal=sfntTables(new Uint8Array(cff.toArrayBuffer())),tables=sfntTables(ttf);
  for(const key of ['glyf','loca','gvar','cvar','fvar','avar','HVAR','VVAR','MVAR'])tables.delete(key);tables.set('CFF ',required(minimal.get('CFF '),'CFF encoder did not produce CFF'));tables.set('maxp',minimal.get('maxp'));const head=tables.get('head');new DataView(head.buffer,head.byteOffset,head.byteLength).setInt16(50,0);return assembleSFNT(tables,0x4f54544f);
}
export async function compileFont(e,font=e.state){
  const archive=makeDesignspaceArchive(font),result=await e.native('font.compile',{archive:bytes64(archive),static:font.axes.length===0});return from64(result.base64);
}
export async function instantiate(e,input){
  const location=parseLocation(e.state.axes,input);
  if(originalIsCurrent(e.state)&&e.state.original.sfnt&&e.state.axes.length){
    const sfnt=from64(e.state.original.sfnt),parsed=attachVerticalMetrics(opentype.parse(arrayBuffer(sfnt)),sfnt),result=fromOpenType(parsed,e.state.title,location);
    result.info={...e.state.info,styleName:'Instance'};result.features=e.state.features;result.groups=clone(e.state.groups);result.kerning=clone(e.state.kerning);result.axes=[];result.masters=[];result.instances=[];return result;
  }
  // Native compilation validates the source model. Source interpolation retains
  // anchors, component transforms, per-master kerning and vertical metrics.
  await compileFont(e);const result=interpolateFont(e.state,location);result.info.styleName='Instance';return result;
}
export async function importFont(e,args){
  const name=String(args.name??'font'),extension=name.split('.').at(-1).toLowerCase(),bytes=from64(args.base64);let result;
  if(extension==='floefont'){const value=JSON.parse(strFromU8(bytes));result=value.content?.data??value.content??value.data??value;}
  else if(extension==='designspace')throw new Error(t('请将 Designspace 与所有 UFO 母版放在同一个 ZIP 中导入。','Import a ZIP containing the Designspace and all UFO sources.'));
  else if(extension==='zip'||extension==='ufo')result=readFontArchive(bytes);
  else if(extension==='svg'){
    const doc=parseXML(strFromU8(bytes)),fontNode=doc.querySelector('font');if(fontNode){result=createFont();const face=fontNode.querySelector('font-face');result.info.familyName=face?.getAttribute('font-family')??'SVG Font';result.info.unitsPerEm=Number(face?.getAttribute('units-per-em')??1000);result.info.ascender=Number(face?.getAttribute('ascent')??800);result.info.descender=Number(face?.getAttribute('descent')??-200);result.glyphs=[];
      for(const node of fontNode.querySelectorAll('glyph,missing-glyph')){const p=new opentype.Path();p.fromSVG(node.getAttribute('d')??'');const unicode=node.getAttribute('unicode');result.glyphs.push(glyph(node.tagName==='missing-glyph'?'.notdef':node.getAttribute('glyph-name')??'glyph'+result.glyphs.length,unicode?[...unicode].map(c=>c.codePointAt(0)):[],pathContours(p.commands),Number(node.getAttribute('horiz-adv-x')??fontNode.getAttribute('horiz-adv-x')??600)));}result.title=result.info.familyName;
    }else{const contours=readSVGOutlines(strFromU8(bytes),{flipY:args.flipY!==false});const current=glyphList(e).find(g=>g.name===e.selection?.glyph);if(current)current.contours.push(...contours);else glyphList(e).push(glyph('imported'+glyphList(e).length,[],contours));return {glyphs:1};}
  }else if(['ttf','otf','woff','woff2'].includes(extension)){
    let sfnt=bytes;if(extension==='woff2')sfnt=await codecWOFF2(bytes,false);else if(extension==='woff')sfnt=new Uint8Array(fonteditor.woff2ttf(arrayBuffer(bytes)));
    const parsed=attachVerticalMetrics(opentype.parse(arrayBuffer(sfnt)),sfnt);result=fromOpenType(parsed,name);result.original={name,format:extension,base64:bytes64(bytes),sfnt:bytes64(sfnt),glyphOrder:result.glyphs.map(g=>g.name)};
    // Sample each real variation tuple's peak through the font's own gvar/CFF2
    // interpreter. Imported bytes also remain available for original export.
    if(parsed.variation&&result.axes.length){const positions=new Map();for(const axis of result.axes){if(axis.min!==axis.default)positions.set(axis.tag+':min',{[axis.tag]:axis.min});if(axis.max!==axis.default)positions.set(axis.tag+':max',{[axis.tag]:axis.max});}
      for(const [label,partial]of positions){const location=Object.fromEntries(result.axes.map(a=>[a.tag,partial[a.tag]??a.default])),master=fromOpenType(parsed,name,location);result.masters.push({id:uid(),name:label,location,glyphs:master.glyphs,info:master.info,kerning:clone(result.kerning)});}
    }
  }else throw new Error(t('不支持这个字体格式。','Unsupported font format.'));
  normalizeFont(result);if(extension!=='floefont'){result.original??={name,format:extension,base64:bytes64(bytes)};result.original.policy='Original bytes are retained. Rebuilt fonts use editable outlines, metrics, kerning and feature source; unparsed layout, hinting and unknown tables are not copied.';result.original.signature=sourceSignature(result);}
  if(args.mode==='merge'){mergeFont(e,result,args);return {glyphs:result.glyphs.length,merged:true};}
  e.state=e.payload.data=result;e.activeMaster='default';e.selection={glyph:result.glyphs.find(g=>g.name!=='.notdef')?.name??'.notdef',points:[]};e.previewBytes=null;return {glyphs:result.glyphs.length,axes:result.axes.length,rebuiltTablePolicy:result.original?.policy??null,importedVariableMasters:result.original&&result.axes.length?'Editable axis-end samples; original variable preview remains exact until edited.':null};
}
export function mergeFont(e,imported,{prefix='imported.'}={}) {
  if(imported.axes.length||e.state.axes.length)throw new Error(t('请先将变量字体生成为静态实例，再合并字形。','Generate static instances before merging glyphs from variable fonts.'));
  if(!/^[A-Za-z_.][A-Za-z0-9_.]*$/.test(prefix))throw new Error('Use a valid glyph prefix');
  const names=new Map();for(const g of imported.glyphs){let name=prefix+g.name;while(e.state.glyphs.some(v=>v.name===name)||[...names.values()].includes(name))name+='_';names.set(g.name,name);}
  const scale=e.state.info.unitsPerEm/imported.info.unitsPerEm;
  for(const g of imported.glyphs){if(!names.has(g.name))continue;const copy=clone(g);copy.id=uid();copy.name=names.get(g.name);copy.unicodes=copy.unicodes.filter(code=>!e.state.glyphs.some(v=>v.unicodes.includes(code)));copy.advance*=scale;if(copy.advanceHeight!==undefined)copy.advanceHeight*=scale;if(copy.verticalOrigin!==undefined)copy.verticalOrigin*=scale;
    for(const c of copy.contours)for(const p of c){p.id=uid();p.x*=scale;p.y*=scale;}for(const a of copy.anchors){a.x*=scale;a.y*=scale;}for(const c of copy.components){c.base=names.get(c.base)??c.base;c.matrix[4]*=scale;c.matrix[5]*=scale;}e.state.glyphs.push(copy);
  }
  const groups=new Map();for(const [name,members]of Object.entries(imported.groups)){const match=/^(public\.kern[12]\.)(.*)$/.exec(name);let target=match?match[1]+prefix+match[2]:prefix+name;while(e.state.groups[target])target+='_';groups.set(name,target);e.state.groups[target]=members.map(n=>names.get(n)).filter(Boolean);}
  for(const [left,rights]of Object.entries(imported.kerning)){const l=names.get(left)??groups.get(left);if(!l)continue;e.state.kerning[l]??={};for(const [right,value]of Object.entries(rights)){const r=names.get(right)??groups.get(right);if(r)e.state.kerning[l][r]=value*scale;}}
  // Renaming arbitrary FEA programs requires a parser (class and lookup symbols
  // have independent namespaces). Keep the source as an artifact for deliberate integration.
  e.state.mergedSources??=[];e.state.mergedSources.push({family:imported.info.familyName,glyphMap:Object.fromEntries(names),features:imported.features,license:imported.info.license??''});
}
export function svgFont(font){
  const info=font.info;return `<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg"><defs><font id="FloeTypeface" horiz-adv-x="600"><font-face font-family="${escapeXML(info.familyName)}" units-per-em="${info.unitsPerEm}" ascent="${info.ascender}" descent="${info.descender}"/>${font.glyphs.map(g=>`<${g.name==='.notdef'?'missing-glyph':'glyph'} glyph-name="${escapeXML(g.name)}"${g.unicodes.length?` unicode="${escapeXML(String.fromCodePoint(...g.unicodes))}"`:''} horiz-adv-x="${g.advance}" d="${glyphPath(font,g)}"/>`).join('')}</font></defs></svg>`;
}
export async function exportFont(e,args){
  const format=args.format??'ttf',stem=(e.state.info.familyName||e.state.title||'Typeface').replace(/[\\/:\u0000-\u001f]/g,'_');let data,suffix=format,media='application/octet-stream';
  if(format==='floefont'){data=JSON.stringify({kind:'font',schemaVersion:1,data:e.state});media='application/json';}
  else if(format==='package'){const data=await compileFont(e);const files={[stem+'.ttf']:data,'LICENSE.txt':strToU8([e.state.info.license||e.state.info.openTypeNameLicense||'',...(e.state.mergedSources??[]).map(s=>s.family+'\n'+s.license)].join('\n\n')),'FONT-INFO.json':strToU8(JSON.stringify(e.state.info,null,2)),'SOURCE.floefont':strToU8(JSON.stringify({kind:'font',schemaVersion:1,data:e.state}))};return {artifacts:[artifact(stem+'-font-package.zip','application/zip',zipSync(files,{level:6}))]};}
  else if(format==='original'){if(!e.state.original)throw new Error('This project has no imported original');return {artifacts:[artifact(e.state.original.name,'application/octet-stream',from64(e.state.original.base64))]};}
  else if(format==='ufo'){const root=stem+'.ufo/',files=Object.fromEntries(Object.entries(makeUFOFiles(e.state,glyphList(e),activeSource(e).name??e.state.info.styleName,activeSource(e))).map(([name,data])=>[root+name,data]));data=zipSync(files,{level:6});suffix='ufo.zip';media='application/zip';}
  else if(format==='designspace'){data=makeDesignspaceArchive(e.state);suffix='designspace.zip';media='application/zip';}
  else if(format==='svg'){data=svgFont(e.state);media='image/svg+xml';}
  else {
    let font=e.state;if(args.instance){const location=parseLocation(e.state.axes,args.location??'');font=await instantiate(e,location);}
    if(format==='otf'&&font.axes.length)throw new Error(t('OTF 导出请选择静态实例；变量字体请使用 TTF 或 WOFF2。','Choose a static instance for OTF; use TTF or WOFF2 for variable fonts.'));
    data=await compileFont(e,font);
    if(format==='otf'){data=toCFF(data,font.info);media='font/otf';}
    else if(format==='woff'){data=new Uint8Array(fonteditor.ttf2woff(arrayBuffer(data)));media='font/woff';}
    else if(format==='woff2'){data=await codecWOFF2(data,true);media='font/woff2';}
    else if(format==='ttf')media='font/ttf';else throw new Error('Unsupported export format');
  }
  return {artifacts:[artifact(stem+'.'+suffix,media,data)]};
}
export function registerFontFormats(e){
  e.register({id:'file.import',title:t('导入字体／工程','Import font / project'),group:t('文件','Files'),access:'importFile',fields:[],hidden:true},a=>importFont(e,a));
  e.register({id:'file.merge',title:t('合并字体／工程','Merge font / project'),group:t('文件','Files'),access:'importFile',fields:[],hidden:true},a=>importFont(e,{...a,mode:'merge'}));
  e.register({id:'file.export',title:t('编译并导出字体','Compile & export font'),group:t('文件','Files'),access:'exportFile',fields:[field('format',t('格式','Format'),'select',{options:['ttf','otf','woff','woff2','ufo','designspace','svg','floefont','package','original'],default:'ttf'}),field('instance',t('生成静态实例','Generate static instance'),'checkbox'),field('location',t('轴位置（wght=550）','Axis location (wght=550)'),'text',{default:'wght=550'})]},a=>exportFont(e,a));
  e.register({id:'glyph.exportSVG',title:t('导出当前字形 SVG','Export glyph SVG'),group:t('文件','Files'),access:'exportFile',fields:[glyphField(),field('points',t('显示节点','Show points'),'checkbox')]},a=>{const font={...e.state,glyphs:glyphList(e)},g=required(font.glyphs.find(g=>g.name===a.glyph),'Unknown glyph'),bounds=glyphBounds(font,g),margin=40,width=Math.max(1,bounds.xMax-bounds.xMin)+2*margin,height=Math.max(1,bounds.yMax-bounds.yMin)+2*margin;const svg=`<svg xmlns="http://www.w3.org/2000/svg" viewBox="${bounds.xMin-margin} ${-bounds.yMax-margin} ${width} ${height}"><g transform="scale(1,-1)"><path d="${escapeXML(glyphPath(font,g))}" fill="black"/>${a.points?g.contours.flat().map(p=>`<circle cx="${p.x}" cy="${p.y}" r="4" fill="red"/>`).join(''):''}</g></svg>`;return {artifacts:[artifact(g.name+'.svg','image/svg+xml',svg)]};});
  e.register({id:'features.merged',title:t('查看合并字体的特性程序','Inspect merged feature sources'),group:t('字距与排版','Spacing & layout'),access:'read',fields:[]},()=>e.state.mergedSources??[]);
  e.register({id:'font.preview',title:t('编译并预览排版','Compile & preview shaping'),group:t('字距与排版','Spacing & layout'),access:'read',fields:[]},async()=>{const bytes=originalIsCurrent(e.state)&&e.state.original.sfnt?from64(e.state.original.sfnt):await compileFont(e);if(e.previewFace)document.fonts.delete(e.previewFace);e.previewBytes=bytes;e.previewSignature=sourceSignature(e.state);const face=new FontFace('FloePreview'+uid().replaceAll('-',''),arrayBuffer(bytes));await face.load();document.fonts.add(face);e.previewFace=face;e.previewFamily=face.family;return {bytes:bytes.length,glyphs:e.state.glyphs.length,axes:e.state.axes.length};});
  e.register({id:'variation.generate',title:t('将实例保存为新工程数据','Generate instance project data'),group:t('变量字体','Variations'),access:'exportFile',fields:[field('location',t('轴位置（wght=550）','Axis location (wght=550)'),'text',{default:'wght=550'})]},async a=>{const location=parseLocation(e.state.axes,a.location),font=await instantiate(e,location);return {artifacts:[artifact((font.info.familyName||'Instance')+'-instance.floefont','application/json',JSON.stringify({kind:'font',data:font}))]};});
}
