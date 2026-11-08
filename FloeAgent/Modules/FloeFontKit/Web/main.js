// SPDX-License-Identifier: MPL-2.0
import { jsPDF } from 'jspdf';
import { EditorEngine,expose,t,artifact,uid,clone,escapeXML,required } from '../../FloeHeavyEditorSupport/Web/runtime.js';
import { createFont,normalizeFont,registerFontModel,getGlyph,glyphPath,glyphList,field } from './model.js';
import { registerGeometry } from './geometry.js';
import { registerFontFormats } from './formats.js';
import { FontView } from './view.js';
import { registerFontReads } from './read.js';
import { contourSegments } from './contours.js';
import { fontNativeSnapshot,registerFontNative } from './native.js';
let view;
export const engine=new EditorEngine({kind:'font',title:t('字体设计','Font design'),create:createFont,normalize:normalizeFont,nativeSnapshot:e=>fontNativeSnapshot(e,view),nativeChromeChanged:async()=>{if(view)await view.render();},render:async e=>{
  normalizeFont(e.state);if(e.activeMaster&&e.activeMaster!=='default'&&!e.state.masters.some(m=>m.id===e.activeMaster))e.activeMaster='default';
  const glyphs=glyphList(e);if(!glyphs.some(g=>g.name===e.selection?.glyph))e.selection={glyph:glyphs.find(g=>g.name!=='.notdef')?.name??'.notdef',points:[]};
  else e.selection.points=(e.selection.points??[]).filter(id=>getGlyph(e).contours.some(c=>c.some(p=>p.id===id)));
  view??=new FontView(e);await view.render();
}});
registerFontModel(engine);registerGeometry(engine);registerFontFormats(engine);
registerFontNative(engine,()=>view);registerFontReads(engine);
engine.register({id:'outline.addContour',title:t('添加轮廓','Add contour'),group:t('轮廓几何','Outline geometry'),hidden:true,access:'edit',fields:[]},a=>{
  const g=getGlyph(engine,a.glyph);if(!Array.isArray(a.points)||a.points.length<2||a.points.some(p=>!Number.isFinite(p.x)||!Number.isFinite(p.y)||!['line','qcurve','curve','offcurve','move'].includes(p.type)))throw new Error('Invalid contour');
  const contour=clone(a.points);for(const p of contour)p.id=uid();
  if(a.closed===false)contour[0].type='move';else{let controls=0;for(let i=contour.length-1;i>=0&&contour[i].type==='offcurve';i--)controls++;contour[0].type=controls===2?'curve':controls===1?'qcurve':'line';}
  contourSegments(contour);g.contours.push(contour);
});
engine.register({id:'specimen.export',title:t('导出示字页／字形表','Export specimen / glyph sheet'),group:t('文件','Files'),access:'exportFile',fields:[field('format',t('格式','Format'),'select',{options:['pdf','svg','png'],default:'pdf'}),field('columns',t('每行字形数','Glyphs per row'),'number',{default:6,min:1,max:16}),field('rows',t('每页行数','Rows per page'),'number',{default:8,min:1,max:20}),field('points',t('显示节点','Show points'),'checkbox')]},async a=>{
  const columns=Math.max(1,Math.min(16,Math.trunc(a.columns))),rows=Math.max(1,Math.min(20,Math.trunc(a.rows))),perPage=columns*rows,width=1200,height=1600,cellWidth=(width-100)/columns,cellHeight=(height-150)/rows,info=engine.state.info,pages=[];
  for(let offset=0;offset<engine.state.glyphs.length;offset+=perPage){let content=`<rect width="${width}" height="${height}" fill="white"/><text x="50" y="50" font-size="28" font-family="sans-serif">${escapeXML(info.familyName)} · ${Math.floor(offset/perPage)+1}</text>`;
    for(const [index,g]of engine.state.glyphs.slice(offset,offset+perPage).entries()){const x=50+(index%columns)*cellWidth,y=90+Math.floor(index/columns)*cellHeight,scale=Math.min((cellWidth-20)/(info.unitsPerEm||1000),(cellHeight-45)/(info.ascender-info.descender));content+=`<g transform="translate(${x+10},${y+info.ascender*scale}) scale(${scale},${-scale})"><path d="${glyphPath(engine.state,g)}" fill="#171a20"/>${a.points?g.contours.flat().map(p=>`<circle cx="${p.x}" cy="${p.y}" r="4" fill="#2879c7"/>`).join(''):''}</g><text x="${x+10}" y="${y+cellHeight-10}" font-family="sans-serif" font-size="13">${escapeXML(g.name)}</text>`;}
    pages.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">${content}</svg>`);
  }
  const stem=(info.familyName||'Typeface').replace(/[\\/:]/g,'_'),artifacts=[];if(a.format==='svg')return {artifacts:pages.map((source,index)=>artifact(`${stem}-${index+1}.svg`,'image/svg+xml',source))};
  const pdf=a.format==='pdf'?new jsPDF({unit:'pt',format:[600,800]}):null;
  for(const [index,source]of pages.entries()){const url=URL.createObjectURL(new Blob([source],{type:'image/svg+xml'}));try{const image=new Image();await new Promise((resolve,reject)=>{image.onload=resolve;image.onerror=()=>reject(new Error('Unable to render specimen'));image.src=url;});const canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;canvas.getContext('2d').drawImage(image,0,0);if(pdf){if(index)pdf.addPage([600,800]);pdf.addImage(canvas,'PNG',0,0,600,800);}else{const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/png'));artifacts.push(artifact(`${stem}-${index+1}.png`,'image/png',await blob.arrayBuffer()));}}finally{URL.revokeObjectURL(url);}}
  if(pdf)artifacts.push(artifact(stem+'-specimen.pdf','application/pdf',pdf.output('arraybuffer')));return {artifacts};
});
expose(engine);
