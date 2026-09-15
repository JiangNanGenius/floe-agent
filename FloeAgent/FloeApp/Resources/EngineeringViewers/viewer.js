// SPDX-License-Identifier: MPL-2.0
const config=window.floeEngineeringConfiguration??{};
const zh=(config.language??navigator.language).startsWith('zh');
const say=(cn,en)=>zh?cn:en;
const $=id=>document.getElementById(id),view=$('view');
document.body.classList.toggle('dark',!!config.dark);
$('fit').textContent=say('复位','Fit');$('layersButton').textContent=say('图层','Layers');
$('layersButton').onclick=()=>{$('layers').hidden=!$('layers').hidden;};
let destroy=()=>{},fit=()=>{},timer,finished=false,reviewContext=()=>({});
$('review').textContent=say('AI 审图','Ask AI');
$('review').onclick=async()=>{
 $('review').disabled=true;
 try{const context=JSON.stringify(reviewContext());if(context.length>60000)throw Error(say('审图信息过大','Review context too large'));
  await window.webkit.messageHandlers.floeEngineering.postMessage({operation:'review',context});
 }catch(error){$('status').textContent=String(error?.message??error);}
 finally{$('review').disabled=false;}
};
const urls=[];
function localURL(blob){const url=URL.createObjectURL(blob);urls.push(url);return url;}
function fail(error){if(finished)return;finished=true;clearTimeout(timer);destroy();view.replaceChildren();$('error').hidden=false;$('error').textContent=say('无法显示此文件。\n','Unable to display this file.\n')+String(error?.message??error);$('status').textContent=say('加载失败','Failed');window.floeEngineeringResult={ok:false,error:String(error)};}
function ready(details){if(finished)return;finished=true;clearTimeout(timer);window.webkit?.messageHandlers?.floeEngineering?.postMessage({operation:'complete'}).catch(()=>{});$('status').textContent=details;window.floeEngineeringResult={ok:true,details};$('review').hidden=!config.canReview;}
$('fit').onclick=()=>fit();
window.addEventListener('pagehide',()=>{destroy();urls.forEach(URL.revokeObjectURL);});
window.addEventListener('unhandledrejection',event=>{fail(event.reason);});
function bytes(file){return Uint8Array.from(atob(file.base64),c=>c.charCodeAt(0));}
async function load(pkg){
 $('format').textContent=pkg.name.split('.').pop().toUpperCase();
 $('status').textContent=say('正在解析','Loading');
 timer=setTimeout(()=>fail(say('处理时间过长，请关闭后使用较小文件重试。','Processing took too long. Close this preview and retry with a smaller file.')),60000);
 const main=pkg.files[0];if(!main)throw Error(say('文件为空','No file'));
 const missing=pkg.missingReferences?.length??0;
 if(pkg.kind==='dxf'||pkg.kind==='dwg'){
  let cad=null,cadState=null,cadEditor=null,source=bytes(main);
  if(pkg.kind==='dwg'||config.canEdit){
   const {createCadEngine}=await import('./cad-editor.js');cad=createCadEngine();destroy=()=>cad.close();
   cadState=await cad.call('open',{bytes:source,format:pkg.kind});source=cadState.dxf;
  }
  const {DxfViewer,Color}=await import('./dxf.js');
  // Upstream changes its container to position:relative. Keep the app's
  // absolutely positioned viewport intact or it collapses to zero height.
  const surface=document.createElement('div');surface.style.cssText='width:100%;height:100%';view.append(surface);
  const viewer=new DxfViewer(surface,{autoResize:true,retainParsedDxf:true,clearColor:new Color(config.dark?'#181e28':'#f5f6f8'),colorCorrection:true});
  destroy=()=>{cadEditor?.destroy();cad?.close();viewer.Destroy();};
  const render=async data=>{
   const url=URL.createObjectURL(new Blob([data]));
   try{await viewer.Load({url,fonts:[new URL('MiSans-Regular.ttf',location.href).href],workerFactory:()=>new Worker(new URL('dxf-worker.js',location.href),{type:'module'})});}
   finally{URL.revokeObjectURL(url);}
  };
  await render(source);
  if(!viewer.bounds)throw Error(say('未找到可显示的二维几何。','No supported 2D geometry.'));
  fit=()=>{const b=viewer.bounds,o=viewer.GetOrigin();viewer.FitView(b.minX-o.x,b.maxX-o.x,b.minY-o.y,b.maxY-o.y);viewer.Render();};
  for(const layer of viewer.GetLayers(true)){
   const label=document.createElement('label'),input=document.createElement('input');input.type='checkbox';input.checked=true;
   input.onchange=()=>viewer.ShowLayer(layer.name,input.checked);label.append(input,document.createTextNode(layer.displayName??layer.name));$('layers').append(label);
  }
  $('layersButton').hidden=$('layers').children.length===0;
  if(cad&&config.canEdit){
   const {installCadEditor}=await import('./cad-editor.js');
   cadEditor=installCadEditor({engine:cad,initial:cadState.info,render,viewer,zh,onDirty:dirty=>{
    window.webkit?.messageHandlers?.floeEngineering?.postMessage({operation:'dirty',dirty}).catch(()=>{});
   }});
  }
  reviewContext=()=>{
   const parsed=viewer.GetDxf(),camera=viewer.GetCamera(),origin=viewer.GetOrigin();
   const all=parsed?.entities??[],sample=[];let size=0;
   for(const entity of all.slice(0,100)){
    const value=boundedValue(entity),length=JSON.stringify(value).length;
    if(size+length>40000)break;sample.push(value);size+=length;
   }
   return {type:pkg.kind.toUpperCase(),bounds:viewer.GetBounds(),origin,viewport:{x:camera.position.x,y:camera.position.y,zoom:camera.zoom},
    layers:[...$('layers').querySelectorAll('label')].slice(0,100).map(e=>({name:e.textContent,visible:e.querySelector('input').checked})),
    version:parsed?.header?.$ACADVER,units:parsed?.header?.$INSUNITS,entityCount:all.length,entities:sample,
    truncated:sample.length<all.length,missingGlyphs:viewer.hasMissingChars,
    nativeDiagnostics:(cadEditor?.inspect()??cadState?.info)?.diagnostics,
    selectedHandle:cadEditor?.inspect().selectedHandle,
    limitations:'Viewport may simplify dimensions, line styles and layouts. Sampled entities are not a complete engineering review.'};
  };
  $('hint').textContent=say('双指缩放 · 拖动平移 · 部分标注、线型和布局可能简化','Pinch to zoom · Drag to pan · Some dimensions, line styles and layouts may be simplified');
  ready(viewer.hasMissingChars?say('部分字符缺少字体','Some glyphs are unavailable'):say('二维图纸','2D drawing'));
  }else if(pkg.kind==='mesh'||pkg.kind==='cadSurface'){
  let modelFiles=pkg.files.map(f=>new File([bytes(f)],f.name)),surfaceInfo;
  if(pkg.kind==='cadSurface'){
   const worker=new Worker(new URL('occt-worker.js',location.href));destroy=()=>worker.terminate();
   const converted=await new Promise((resolve,reject)=>{
    const timeout=setTimeout(()=>{worker.terminate();reject(Error(say('图纸处理超时','CAD processing timed out')));},45000);
    worker.onerror=()=>{clearTimeout(timeout);worker.terminate();reject(Error(say('图纸处理失败','CAD processing failed')));};
    worker.onmessage=({data})=>{clearTimeout(timeout);worker.terminate();data.error?reject(Error(data.error)):resolve(data);};
    worker.postMessage({bytes:bytes(main),extension:pkg.name.split('.').pop().toLowerCase()});
   });
   modelFiles=[new File([converted.buffer],'display.stl')];surfaceInfo=converted.info;
  }
  const OV=await import('./mesh.js');
  const embedded=new OV.EmbeddedViewer(view,{
   backgroundColor:new OV.RGBAColor(...(config.dark?[24,30,40,255]:[245,246,248,255])),
   defaultColor:new OV.RGBColor(120,165,190),
   onModelLoaded:()=>{
    const model=embedded.GetModel();if(!model||model.MeshCount()===0){fail(say('文件没有可显示的网格。','No renderable meshes.'));return;}
    reviewContext=()=>({type:'mesh',sourceCAD:surfaceInfo,meshCount:model.MeshCount(),vertexCount:model.VertexCount?.(),triangleCount:model.TriangleCount?.(),
     bounds:embedded.GetViewer().GetBoundingSphere(()=>true),missingReferences:pkg.missingReferences,
     limitations:'Rendered meshes only. Dimensions, material properties, tolerances and manufacturing validity are not verified.'});
    ready(missing?say('部分外部资源缺失','Some referenced resources are missing'):say('三维模型','3D model'));
   },onModelLoadFailed:()=>fail(say('格式、压缩方式不受支持，或文件已损坏。','Unsupported format/compression, or a damaged file.'))
  });
  const observer=new ResizeObserver(()=>embedded.Resize());observer.observe(view);
  destroy=()=>{observer.disconnect();embedded.Destroy();};
  fit=()=>{const v=embedded.GetViewer();const sphere=v.GetBoundingSphere(()=>true);if(sphere)v.FitSphereToWindow(sphere,false);};
  embedded.LoadModelFromFileList(modelFiles);
  $('hint').textContent=say('单指旋转 · 双指缩放和平移 · 只读预览','Drag to rotate · Two fingers to zoom and pan · Read only');
 }else if(pkg.kind==='gerber'){
  const worker=new Worker(new URL('gerber-worker.js',location.href));destroy=()=>worker.terminate();
  worker.onerror=event=>fail(event.message);
  worker.onmessage=({data})=>{
   worker.terminate();if(data.error){fail(data.error);return;}
   // Render SVG in an image context: no scripts, embedded navigation or HTML.
   const xml=new DOMParser().parseFromString(data.svg,'image/svg+xml');
   const bounds=(xml.documentElement.getAttribute('viewBox')??'').split(/\s+/).map(Number);
   if(bounds.length!==4||!bounds.every(Number.isFinite)||bounds[2]<=0||bounds[3]<=0){fail(say('未找到可显示的板层几何。','No board layer geometry.'));return;}
   xml.documentElement.setAttribute('color',config.dark?'#83e0bb':'#146a50');
   reviewContext=()=>({type:'Gerber or drill',name:pkg.name,renderedViewBox:bounds,units:xml.documentElement.getAttribute('width'),
    limitations:'One file/layer only. No netlist, electrical connectivity, complete layer stack or design-rule verification is available.'});
   const img=new Image();img.onload=()=>{view.append(img);installPanZoom(img);ready(say('板层预览','Board layer'));};img.onerror=()=>fail(say('板层渲染失败','Layer rendering failed'));
   img.src=localURL(new Blob([new XMLSerializer().serializeToString(xml)],{type:'image/svg+xml'}));
  };
  worker.postMessage(new TextDecoder().decode(bytes(main)));
  $('hint').textContent=say('单层 Gerber／钻孔 · 双指缩放 · 拖动平移','Single Gerber / drill layer · Pinch to zoom · Drag to pan');
 }else throw Error(say('此格式的本地解析器尚未接入。二维图纸可先导出为 DXF／PDF；三维模型可导出为 GLB／STL。','A local decoder for this format is not bundled yet. Export 2D drawings to DXF/PDF, or 3D models to GLB/STL.'));
}
function installPanZoom(img){
 let scale=1,x=0,y=0,points=new Map();
 const apply=()=>img.style.transform=`translate(${x}px,${y}px) scale(${scale})`;
 fit=()=>{scale=1;x=0;y=0;apply();};
 const center=()=>{const p=[...points.values()];return {x:p.reduce((s,a)=>s+a.x,0)/p.length,y:p.reduce((s,a)=>s+a.y,0)/p.length,d:p.length>1?Math.hypot(p[0].x-p[1].x,p[0].y-p[1].y):0};};
 view.onpointerdown=e=>{view.setPointerCapture(e.pointerId);points.set(e.pointerId,{x:e.offsetX,y:e.offsetY});};
 view.onpointerup=view.onpointercancel=e=>points.delete(e.pointerId);
 view.onpointermove=e=>{if(!points.has(e.pointerId))return;const before=center();points.set(e.pointerId,{x:e.offsetX,y:e.offsetY});const after=center();const next=before.d>0?Math.max(.25,Math.min(24,scale*after.d/before.d)):scale;const ratio=next/scale;x=after.x-(before.x-x)*ratio;y=after.y-(before.y-y)*ratio;scale=next;apply();};
 view.onwheel=e=>{e.preventDefault();const next=Math.max(.25,Math.min(24,scale*Math.exp(-e.deltaY*.002))),r=next/scale;x=e.offsetX-(e.offsetX-x)*r;y=e.offsetY-(e.offsetY-y)*r;scale=next;apply();};
}
window.floeEngineeringLoad=load;
function boundedValue(value,depth=0){
 if(depth>5)return '[depth limit]';
 if(typeof value==='string')return value.slice(0,2000);
 if(Array.isArray(value))return value.slice(0,100).map(v=>boundedValue(v,depth+1));
 if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).slice(0,50).map(([k,v])=>[k,boundedValue(v,depth+1)]));
 return value;
}
if(window.webkit?.messageHandlers?.floeEngineering){
 window.webkit.messageHandlers.floeEngineering.postMessage({operation:'load'}).then(load).catch(fail);
}
