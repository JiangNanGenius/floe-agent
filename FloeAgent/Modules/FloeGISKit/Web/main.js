// SPDX-License-Identifier: MPL-2.0
import 'ol/ol.css';
import { jsPDF } from 'jspdf';
import { EditorEngine, expose, t, artifact, element } from '../../FloeHeavyEditorSupport/Web/runtime.js';
import { createGIS, normalizeGIS, registerModelCommands, field } from './model.js';
import { registerFormats } from './formats.js';
import { registerAnalysis } from './analysis.js';
import { GISView, registerViewCommands, makeMapSVG, paperSize } from './view.js';
let view;
export const engine=new EditorEngine({kind:'gis',title:t('地理信息','GIS'),create:createGIS,normalize:normalizeGIS,render:async e=>{view??=new GISView(e);await view.render();}});
registerModelCommands(engine);registerFormats(engine);registerAnalysis(engine);registerViewCommands(engine);
engine.commands.get('document.save').handler=()=>{engine.state.view={...(engine.liveView??engine.state.view)};return {saved:true};};
engine.register({id:'layout.export',title:t('导出地图','Export map'),group:t('制图','Layout'),access:'exportFile',fields:[field('format',t('格式','Format'),'select',{options:['svg','png','pdf'],default:'pdf'}),field('width',t('宽度（像素）','Width (pixels)'),'number',{default:e=>Math.round(paperSize(e.state.layout)[0]*96/25.4),min:200}),field('height',t('高度（像素）','Height (pixels)'),'number',{default:e=>Math.round(paperSize(e.state.layout)[1]*96/25.4),min:200})]},async a=>{
  const width=Math.max(200,Math.min(10000,a.width)),height=Math.max(200,Math.min(10000,a.height)),svg=await makeMapSVG(engine,{width,height}),name=engine.state.title.replace(/[\\/:]/g,'_');
  if(a.format==='svg')return {artifacts:[artifact(name+'.svg','image/svg+xml',svg)]};
  const blob=new Blob([svg],{type:'image/svg+xml'}),url=URL.createObjectURL(blob),image=new Image();try{
    await new Promise((resolve,reject)=>{image.onload=resolve;image.onerror=()=>reject(new Error('Unable to render map'));image.src=url;});
    const canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;canvas.getContext('2d').drawImage(image,0,0);
    if(a.format==='png'){const result=await new Promise(resolve=>canvas.toBlob(resolve,'image/png'));return {artifacts:[artifact(name+'.png','image/png',await result.arrayBuffer())]};}
    const page=paperSize(engine.state.layout),pdf=new jsPDF({orientation:page[0]>page[1]?'landscape':'portrait',unit:'mm',format:page}),scale=Math.min(page[0]/width,page[1]/height);pdf.addImage(canvas,'PNG',(page[0]-width*scale)/2,(page[1]-height*scale)/2,width*scale,height*scale);return {artifacts:[artifact(name+'.pdf','application/pdf',pdf.output('arraybuffer'))]};
  }finally{URL.revokeObjectURL(url);}
});
expose(engine);

if(typeof window!=='undefined')window.addEventListener('pagehide',()=>view?.dispose());
