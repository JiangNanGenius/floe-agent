// SPDX-License-Identifier: MPL-2.0
// Only these typed operations reach the Rust engine. No arbitrary JS/file API.
import {
 ACI_COLORS, LINE_WEIGHT_PRESETS, DEFAULT_LINE_WEIGHT, DEFAULT_TOLERANCE_PX,
 MIN_SAMPLE_DISTANCE_PX, aciCssColor, buildStrokeRequest, clientToCanvas,
 createStrokeCapture, cssToleranceToWorld, inkReadiness, isDrawPointer,
 screenToWorld, validateStrokeRequest, worldToScreen,
} from './cad-ink.js';
import {
 boundsInWindow, buildBatch, buildCreate, buildDelete, buildLayerRequest,
 buildOffset, buildQuery, buildSetLayer, buildTransform, buildTrimExtend,
 entityAnchor, entityKind, formatCheck, formatMeasure, selectSnapCandidate,
} from './cad-commands.js';

export function createCadEngine(){
 const worker=new Worker(new URL('cad-worker.js',import.meta.url),{type:'module'});
 let sequence=0,closed=false,pending=new Map();
 const close=()=>{closed=true;worker.terminate();for(const p of pending.values()){clearTimeout(p.timer);p.reject(Error('CAD worker stopped'));}pending.clear();};
 worker.onmessage=({data})=>{const p=pending.get(data.id);if(!p)return;clearTimeout(p.timer);pending.delete(data.id);data.error?p.reject(Error(data.error)):p.resolve(data.result);};
 worker.onerror=close;
 return {close,call(operation,args={}){return new Promise((resolve,reject)=>{
  if(closed){reject(Error('CAD worker stopped'));return;}
  const id=++sequence,timer=setTimeout(()=>{close();},45000);
  pending.set(id,{resolve,reject,timer});worker.postMessage({id,operation,...args});
 });}};
}

export function installCadEditor({engine,initial,render,viewer,zh,dark=false,onDirty}){
 const say=(cn,en)=>zh?cn:en;
 let info=initial,selected='',busy=false,dirty=false,pointerStart=null;
 let selection=new Set(),lastSnap=null,snapEnabled=true,drawMode=null,clickAction=null,boundaryHandle='';
 let layers=[],units='';
 const panel=document.createElement('aside');panel.id='cadPanel';panel.hidden=true;
 const message=document.createElement('p');message.id='cadMessage';message.setAttribute('role','status');
 const controls=document.createElement('div');controls.className='cadActions cadPrimaryActions';
 const fields=document.createElement('div');fields.className='cadFields';
 const entities=document.createElement('select');entities.id='cadEntities';entities.setAttribute('aria-label',say('选择图元','Select entity'));
 const selectionInfo=document.createElement('p');selectionInfo.className='cadMessage';
 const tools=document.createElement('div');tools.className='cadActions';
 const title=document.createElement('strong');title.textContent=say('图纸助手 · 二维编辑','Drawing Assistant · 2D editor');
 const close=document.createElement('button');close.textContent=say('收起','Close');
 const properties=document.createElement('div');properties.className='cadSection';
 properties.append(entities,selectionInfo,fields,tools);
 panel.append(title,close,message,controls,properties);document.body.append(panel);
 let layersLoaded=false;
 const toggle=document.createElement('button');toggle.id='cadEdit';toggle.textContent=say('编辑','Edit');toggle.onclick=()=>{panel.hidden=!panel.hidden;if(!panel.hidden){const layersEl=document.getElementById('layers');if(layersEl)layersEl.hidden=true;if(!layersLoaded){layersLoaded=true;void refreshLayers();}}};
 document.querySelector('header').append(toggle);
 const undo=button(controls,say('撤销','Undo'),()=>mutate('undo'));
 const redo=button(controls,say('重做','Redo'),()=>mutate('redo'));
 const save=button(controls,say('保存','Save'),saveDocument);save.id='cadSave';
 function button(parent,label,action){const b=document.createElement('button');b.textContent=label;b.onclick=action;parent.append(b);return b;}
 function collapsible(section,label,open){
  const header=document.createElement('button');header.type='button';header.className='cadSectionToggle';
  header.textContent=label;header.setAttribute('aria-expanded',String(!!open));
  header.onclick=()=>{const collapsed=section.classList.toggle('collapsed');header.setAttribute('aria-expanded',String(!collapsed));};
  section.insertBefore(header,section.firstChild??null);
  if(!open)section.classList.add('collapsed');
  return header;
 }
 function note(text,error=false){message.textContent=text;message.classList.toggle('failure',error);}
 collapsible(properties,say('属性','Properties'),true);

 // ------------------------------------------------------------ snap indicator
 const snapDot=document.createElement('div');snapDot.className='cadSnapDot';snapDot.hidden=true;document.body.append(snapDot);
 function showSnap(candidate){
  lastSnap=candidate;
  if(!candidate||!candidate.point){snapDot.hidden=true;return;}
  const host=viewer.GetCanvas().parentElement??viewer.GetCanvas();
  if(getComputedStyle(host).position==='static')host.style.position='relative';
  const state=viewState();const screen=worldToScreen({x:candidate.point[0],y:candidate.point[1]},state);
  snapDot.hidden=false;snapDot.style.left=`${screen.x}px`;snapDot.style.top=`${screen.y}px`;
  snapDot.dataset.kind=candidate.kind;
 }
 function clearSnap(){lastSnap=null;snapDot.hidden=true;}
 function snapWorld(point){
  if(lastSnap?.point&&Math.hypot(lastSnap.point[0]-point.x,lastSnap.point[1]-point.y)<=cssToleranceToWorld(12,viewState()))return {x:lastSnap.point[0],y:lastSnap.point[1],snapped:true};
  return {x:point.x,y:point.y,snapped:false};
 }
 async function refreshSnap(point){
  if(!snapEnabled||busy||inkState.active){clearSnap();return;}
  try{
   const result=await engine.call('query',{request:buildQuery('snap',{point:{x:point.x,y:point.y},tolerance:cssToleranceToWorld(12,viewState())})});
   if(result?.candidates)showSnap(selectSnapCandidate(result.candidates));else clearSnap();
  }catch{clearSnap();}
 }

 // ------------------------------------------------------------------ ink UI
 const ink=document.createElement('div');ink.className='cadInk';
 const inkMessage=document.createElement('p');inkMessage.className='cadInkMessage';inkMessage.setAttribute('role','status');
 const colorLabel=document.createElement('span');colorLabel.className='cadFieldLabel';colorLabel.textContent=say('笔色','Ink color');
 const colorGroup=document.createElement('div');colorGroup.className='cadSwatches';colorGroup.setAttribute('role','radiogroup');colorGroup.setAttribute('aria-label',say('笔色','Ink color'));
 const widthLabel=document.createElement('span');widthLabel.className='cadFieldLabel';widthLabel.textContent=say('线宽（毫米）','Width (mm)');
 const widthGroup=document.createElement('div');widthGroup.className='cadWidths';widthGroup.setAttribute('role','radiogroup');widthGroup.setAttribute('aria-label',say('线宽','Ink width'));
 const fingerRow=document.createElement('label');fingerRow.className='cadFinger';
 const finger=document.createElement('input');finger.type='checkbox';finger.checked=false;
 fingerRow.append(finger,document.createTextNode(say('用手指绘制','Draw with finger')));
 ink.append(inkMessage,colorLabel,colorGroup,widthLabel,widthGroup,fingerRow);
 collapsible(ink,say('Pencil 批注','Pencil ink'),false);

 const pen=document.createElement('button');pen.id='cadPen';pen.type='button';pen.textContent=say('画笔','Pen');
 pen.setAttribute('aria-pressed','false');
 document.querySelector('header').append(pen);

 const colorButtons=[];
 for(const entry of ACI_COLORS){
  const b=document.createElement('button');b.type='button';b.className='cadSwatch';b.setAttribute('role','radio');
  b.setAttribute('aria-label',`${entry.zh} ${entry.en}`);b.title=`${entry.zh} · ${entry.en}`;
  b.dataset.aci=String(entry.aci);
  const dot=document.createElement('span');dot.className='cadSwatchDot';dot.style.background=aciCssColor(entry.aci,dark);
  const label=document.createElement('span');label.textContent=say(entry.zh,entry.en);
  b.append(dot,label);b.onclick=()=>{inkState.color=entry.aci;updateInk();};
  colorButtons.push(b);colorGroup.append(b);
 }
 const widthButtons=[];
 for(const entry of LINE_WEIGHT_PRESETS){
  const b=document.createElement('button');b.type='button';b.className='cadWidth';b.setAttribute('role','radio');
  b.setAttribute('aria-label',`${entry.value/100} mm`);b.title=say(`${entry.zh} 毫米`,`${entry.en} mm`);
  b.dataset.weight=String(entry.value);b.textContent=say(entry.zh,entry.en);
  b.onclick=()=>{inkState.lineWeight=entry.value;updateInk();};
  widthButtons.push(b);widthGroup.append(b);
 }
 const inkState={active:false,color:ACI_COLORS[0].aci,lineWeight:DEFAULT_LINE_WEIGHT,drawWithFinger:false,ready:false,capabilities:null,reason:null,capture:null,pointerId:null,overlay:null,context:null};
 finger.onchange=()=>{cancelStroke();inkState.drawWithFinger=finger.checked;updateInk();};
 pen.onclick=()=>setPen(!inkState.active);
 close.onclick=()=>{cancelStroke();panel.hidden=true;};

 function reasonText(reason){
  switch(reason){
   case 'capabilities-missing':return say('当前版本暂不支持此图纸的笔迹批注。','Ink annotations are unavailable for this drawing in the current version.');
   case 'pointCount-invalid':return say('引擎能力元数据无效，批注笔迹已禁用。','Engine capability metadata is invalid; ink is disabled.');
   case 'diagnostics':return say('此图纸存在未解决的读取诊断，编辑与批注已禁用。','This drawing has unresolved read diagnostics; editing and ink are disabled.');
   default:return say('批注笔迹当前不可用。','Ink is currently unavailable.');
  }
 }
 function setPen(active){
  if(active&&(!inkState.ready||busy)){note(reasonText(inkState.reason||'capabilities-missing'),true);return;}
  if(inkState.active===active)return;
  inkState.active=active;
  if(active){drawMode=null;clickAction=null;clearSnap();}
  if(!active)cancelStroke();
  updateInk();
 }
 function viewState(){
  const canvas=viewer.GetCanvas();
  return {camera:viewer.GetCamera(),canvasWidth:canvas.clientWidth,canvasHeight:canvas.clientHeight,origin:viewer.GetOrigin()};
 }
 function canvasPoint(event){return clientToCanvas({x:event.clientX,y:event.clientY},viewer.GetCanvas().getBoundingClientRect());}
 function worldPoint(event){return screenToWorld(canvasPoint(event),viewState());}
 function validWorld(point){return Number.isFinite(point?.x)&&Number.isFinite(point?.y)&&Math.abs(point.x)<=1e12&&Math.abs(point.y)<=1e12;}
 function ensureOverlay(){
  if(inkState.overlay&&inkState.overlay.isConnected)return;
  const canvas=viewer.GetCanvas(),host=canvas.parentElement??canvas;
  if(getComputedStyle(host).position==='static')host.style.position='relative';
  const overlay=document.createElement('canvas');overlay.className='cadInkOverlay';overlay.setAttribute('aria-hidden','true');
  host.append(overlay);inkState.overlay=overlay;inkState.context=overlay.getContext('2d');
  viewer.Subscribe('viewChanged',onViewChanged);viewer.Subscribe('resized',onViewChanged);
  syncOverlay();
 }
 function syncOverlay(){
  const canvas=viewer.GetCanvas();
  if(!inkState.overlay||!inkState.context||canvas.clientWidth<=0||canvas.clientHeight<=0)return;
  const ratio=window.devicePixelRatio||1,width=Math.round(canvas.clientWidth*ratio),height=Math.round(canvas.clientHeight*ratio);
  if(inkState.overlay.width!==width||inkState.overlay.height!==height){inkState.overlay.width=width;inkState.overlay.height=height;}
  inkState.context.setTransform(ratio,0,0,ratio,0,0);
 }
 function clearOverlay(){if(inkState.context&&inkState.overlay)inkState.context.clearRect(0,0,inkState.overlay.width,inkState.overlay.height);}
 function onViewChanged(){if(inkState.overlay&&inkState.capture?.active){syncOverlay();drawPreview();}else clearOverlay();}
 function drawPreview(){
  const capture=inkState.capture;
  if(!inkState.context||!capture)return;
  clearOverlay();
  const points=capture.peek();if(points.length<2)return;
  const state=viewState(),context=inkState.context;
  context.lineWidth=2.5;context.lineJoin='round';context.lineCap='round';
  context.strokeStyle=aciCssColor(inkState.color,dark);
  context.beginPath();
  points.forEach((point,index)=>{const screen=worldToScreen(point,state);if(index===0)context.moveTo(screen.x,screen.y);else context.lineTo(screen.x,screen.y);});
  context.stroke();
 }
 function cancelStroke(){
  if(inkState.capture)inkState.capture.cancel();
  inkState.capture=null;inkState.pointerId=null;clearOverlay();
 }
 function onPointerDown(event){
  if(!inkState.active||busy||!inkState.ready)return;
  if(!isDrawPointer(event.pointerType,{drawWithFinger:inkState.drawWithFinger}))return;
  if(event.target?.closest?.('aside,header,button,input,select,label,textarea'))return;
  if(inkState.pointerId!==null)return;
  if(event.pointerType==='pen'&&event.button>0)return;
  const point=worldPoint(event);
  if(!validWorld(point))return;
  event.preventDefault();event.stopPropagation();
  ensureOverlay();syncOverlay();
  inkState.pointerId=event.pointerId;
  inkState.capture=createStrokeCapture({minWorldDistance:cssToleranceToWorld(MIN_SAMPLE_DISTANCE_PX,viewState())});
  inkState.capture.begin();inkState.capture.add(point);drawPreview();
  try{viewer.GetCanvas().setPointerCapture(event.pointerId);}catch{}
 }
 function onPointerMove(event){
  if(inkState.pointerId===null||event.pointerId!==inkState.pointerId)return;
  event.preventDefault();event.stopPropagation();
  const point=worldPoint(event);if(!validWorld(point))return;
  if(inkState.capture.add(point))drawPreview();
 }
 function onPointerUp(event){
  if(inkState.pointerId===null||event.pointerId!==inkState.pointerId)return;
  event.preventDefault();event.stopPropagation();
  const finalPoint=worldPoint(event);
  if(validWorld(finalPoint))inkState.capture?.add(finalPoint);
  const points=inkState.capture?inkState.capture.take():[];
  inkState.capture=null;inkState.pointerId=null;clearOverlay();
  void commitStroke(points);
 }
 function onPointerCancel(event){
  if(inkState.pointerId===null||event.pointerId!==inkState.pointerId)return;
  event.stopPropagation();
  cancelStroke();
 }
 function onKeyDown(event){if(event.key==='Escape'&&inkState.pointerId!==null){cancelStroke();}}
 const captureOptions={capture:true,passive:false};
 document.addEventListener('pointerdown',onPointerDown,captureOptions);
 document.addEventListener('pointermove',onPointerMove,captureOptions);
 document.addEventListener('pointerup',onPointerUp,captureOptions);
 document.addEventListener('pointercancel',onPointerCancel,captureOptions);
 document.addEventListener('lostpointercapture',onPointerCancel,captureOptions);
 document.addEventListener('keydown',onKeyDown,captureOptions);
 window.addEventListener('blur',cancelStroke);
 async function commitStroke(points){
  if(!inkState.ready||busy)return;
  const capabilities=inkState.capabilities;
  const view=viewState();
  let request;
  try{request=buildStrokeRequest(points,{maxPoints:capabilities.pointCount.max,tolerance:cssToleranceToWorld(DEFAULT_TOLERANCE_PX,view),color:inkState.color,lineWeight:inkState.lineWeight});}
  catch(error){note(String(error?.message??error),true);return;}
  if(!request){note(say('笔迹太短，未写入图纸。','Stroke too short; nothing was written.'));return;}
  const check=validateStrokeRequest(request,capabilities);
  if(!check.ok){note(say('笔迹超出引擎限制，未写入。','Stroke exceeded engine limits; nothing was written.')+` (${check.reason})`,true);return;}
  await mutate('edit',request);
 }
 function updateInk(){
  const readiness=inkReadiness(info);
  inkState.capabilities=readiness.capabilities;inkState.ready=readiness.ready;inkState.reason=readiness.reason;
  if(!inkState.ready&&inkState.active){inkState.active=false;cancelStroke();}
  const blocked=busy||!inkState.ready;
  pen.disabled=blocked;pen.setAttribute('aria-pressed',String(inkState.active));pen.classList.toggle('active',inkState.active);
  pen.title=inkState.ready?'':reasonText(inkState.reason);
  ink.classList.toggle('unsupported',!inkState.ready);
  colorButtons.forEach(b=>{const on=Number(b.dataset.aci)===inkState.color;b.disabled=blocked;b.classList.toggle('selected',on);b.setAttribute('aria-checked',String(on));});
  widthButtons.forEach(b=>{const on=Number(b.dataset.weight)===inkState.lineWeight;b.disabled=blocked;b.classList.toggle('selected',on);b.setAttribute('aria-checked',String(on));});
  finger.disabled=blocked;
  inkMessage.textContent=inkState.ready
   ?(inkState.drawWithFinger?say('用手指或 Apple Pencil 绘制；关闭画笔可移动图纸。','Draw with a finger or Apple Pencil; turn off Pen to navigate.'):say('用 Apple Pencil 绘制，手指平移或双指缩放。','Draw with Apple Pencil; drag to pan or pinch to zoom.'))
   :reasonText(inkState.reason);
 }

 // -------------------------------------------------------------- draw tools
 const draw=document.createElement('div');draw.className='cadSection';
 const drawFields=document.createElement('div');drawFields.className='cadFields';
 const drawActions=document.createElement('div');drawActions.className='cadActions';
 draw.append(drawFields,drawActions);
 collapsible(draw,say('绘制','Draw'),true);
 function numberField(label,value=0,parent=drawFields){const row=document.createElement('label'),input=document.createElement('input');input.type='number';input.step='any';input.value=String(value);row.append(document.createTextNode(label),input);parent.append(row);return ()=>{const v=Number(input.value);if(!input.value||!Number.isFinite(v))throw Error(say('请输入有效数字','Enter a valid number'));return v;};}
 function textField(label,value='',parent=drawFields){const row=document.createElement('label'),input=document.createElement('input');input.type='text';input.value=value;row.append(document.createTextNode(label),input);parent.append(row);return ()=>input.value;}
 function pickField(label,parent=drawFields){const row=document.createElement('label'),value=document.createElement('span');value.className='cadPickValue';value.textContent=say('未取点','no point');const b=document.createElement('button');b.type='button';b.textContent=say('画布取点','Pick');b.onclick=()=>{clickAction=point=>{value.textContent=`${point.x.toFixed(3)}, ${point.y.toFixed(3)}`;pickValue=point;clickAction=null;};note(say('请在画布上取点','Pick a point on the drawing'));};row.append(document.createTextNode(label),value,b);parent.append(row);return ()=>pickValue;};
 let pickValue=null;
 const layerForCreate=textField(say('图层','Layer'),'0');
 const startX=numberField('X',0),startY=numberField('Y',0);
 const endX=numberField(say('终点 X','End X'),10),endY=numberField(say('终点 Y','End Y'),10);
 const radiusField=numberField(say('半径','Radius'),5);
 const startAngleField=numberField(say('起始角','Start angle'),0),endAngleField=numberField(say('结束角','End angle'),1.5707963267948966);
 const drawStatus=(text,error=false)=>note(text,error);
 function startDraw(kind){
  if(busy)return;
  drawMode={kind,points:[]};
  note(kind==='line'?say('依次点击起点和终点。','Click the start and end points.'):say('依次点击两个对角点。','Click two opposite corners.'));
 }
 button(drawActions,say('画线','Line'),()=>startDraw('line'));
 button(drawActions,say('画矩形','Rectangle'),()=>startDraw('rectangle'));
 button(drawActions,say('两点画圆','Circle by 2 clicks'),()=>startDraw('circle'));
 button(drawActions,say('输入画圆','Circle by numbers'),()=>{try{const request=buildCreate('circle',{center:[startX(),startY()],radius:radiusField(),layer:layerForCreate()});void mutate('edit',request);}catch(e){drawStatus(e.message,true);}});
 button(drawActions,say('输入画弧','Arc by numbers'),()=>{
  try{
   const request=buildCreate('arc',{center:[startX(),startY()],radius:radiusField(),startAngle:startAngleField(),endAngle:endAngleField(),layer:layerForCreate()});
   void mutate('edit',request);
  }catch(e){drawStatus(e.message,true);}
 });
 button(drawActions,say('输入多段线','Polyline by points'),()=>{try{const request=buildCreate('polyline',{points:'0,0;10,0;10,10',layer:layerForCreate()});void mutate('edit',request);}catch(e){drawStatus(e.message,true);}});
 button(drawActions,say('添加文字','Add text'),()=>{try{const request=buildCreate('text',{position:[startX(),startY()],text:'文字',height:2.5,layer:layerForCreate()});void mutate('edit',request);}catch(e){drawStatus(e.message,true);}});
 button(drawActions,say('添加标注','Add dimension'),()=>{try{const request=buildCreate('dimension',{dimensionKind:'linear',points:'0,0;10,0',offset:5,layer:layerForCreate()});void mutate('edit',request);}catch(e){drawStatus(e.message,true);}});

 // ------------------------------------------------------------ modify tools
 const modify=document.createElement('div');modify.className='cadSection';
 const modifyFields=document.createElement('div');modifyFields.className='cadFields';
 const modifyActions=document.createElement('div');modifyActions.className='cadActions';
 modify.append(modifyFields,modifyActions);
 collapsible(modify,say('修改','Modify'),false);
 const dx=numberField('ΔX',0,modifyFields),dy=numberField('ΔY',0,modifyFields),angle=numberField(say('角度','Angle'),0,modifyFields),factor=numberField(say('比例','Factor'),2,modifyFields);
 const mirrorX=numberField(say('镜像轴 X1','Axis X1'),0,modifyFields),mirrorY=numberField(say('镜像轴 Y1','Axis Y1'),0,modifyFields);
 const offsetDistance=numberField(say('偏移距离','Offset'),1,modifyFields);
 function targets(){return selected?[...new Set([...selection,selected])]:[...selection];}
 function applyTransform(op){
  try{
   const handles=targets();if(!handles.length)throw Error(say('请先选择图元','Select an entity first'));
   const center=selected&&entityAnchor(info.entities.find(e=>e.handle===selected))||{x:0,y:0};
   const operations=handles.map(handle=>buildTransform(op,handle,{dx:dx(),dy:dy(),angle:angle(),factor:factor(),center:[center.x,center.y],axisStart:[mirrorX(),mirrorY()],axisEnd:[mirrorX(),mirrorY()+1]}));
   void mutate('edit',buildBatch(operations));
  }catch(e){note(e.message,true);}
 }
 button(modifyActions,say('移动','Move'),()=>applyTransform('move'));
 button(modifyActions,say('复制','Copy'),()=>applyTransform('copy'));
 button(modifyActions,say('旋转','Rotate'),()=>applyTransform('rotate'));
 button(modifyActions,say('缩放','Scale'),()=>applyTransform('scale'));
 button(modifyActions,say('镜像','Mirror'),()=>applyTransform('mirror'));
 button(modifyActions,say('删除选中','Delete selected'),()=>{try{const handles=targets();if(!handles.length)throw Error(say('请先选择图元','Select an entity first'));void mutate('edit',buildDelete(handles));}catch(e){note(e.message,true);}});
 const boundaryLabel=document.createElement('span');boundaryLabel.className='cadFieldLabel';boundaryLabel.textContent=say('边界：无','Boundary: none');
 const setBoundary=button(modifyActions,say('把选中设为边界','Use selected as boundary'),()=>{if(!selected){note(say('请先选择边界图元','Select the boundary entity'),true);return;}boundaryHandle=selected;boundaryLabel.textContent=say(`边界：${boundaryHandle}`,'Boundary: '+boundaryHandle);note(say('点击要修剪/延伸的部分','Click the part to trim or extend'));clickAction=(point)=>{clickAction=null;try{void mutate('edit',buildTrimExtend(trimMode,selected,boundaryHandle,point));}catch(e){note(e.message,true);}};});
 let trimMode='trim';
 button(modifyActions,say('修剪','Trim'),()=>{trimMode='trim';setBoundary.onclick();});
 button(modifyActions,say('延伸','Extend'),()=>{trimMode='extend';setBoundary.onclick();});
 button(modifyActions,say('加选/取消多选','Toggle multi-select'),()=>{toggleSelection(selected);});
 button(modifyActions,say('偏移','Offset'),()=>{try{const handle=targets()[0];if(!handle)throw Error(say('请先选择图元','Select an entity first'));clickAction=point=>{clickAction=null;try{void mutate('edit',buildOffset(handle,offsetDistance(),point));}catch(e){note(e.message,true);}};note(say('点击偏移方向一侧','Click the side to offset toward'));}catch(e){note(e.message,true);}});
 modify.append(boundaryLabel);

 // -------------------------------------------------------------- layer tools
 const layerSection=document.createElement('div');layerSection.className='cadSection';
 const layerList=document.createElement('div');layerList.className='cadLayerList';
 const layerFields=document.createElement('div');layerFields.className='cadFields';
 const layerName=textField(say('名称','Name'),'',layerFields),layerColor=numberField(say('颜色 ACI','Color ACI'),7,layerFields),layerType=textField(say('线型','Linetype'),'Continuous',layerFields),layerWeight=numberField(say('线宽','LineWeight'),25,layerFields);
 const layerActions=document.createElement('div');layerActions.className='cadActions';
 layerSection.append(layerList,layerFields,layerActions);
 collapsible(layerSection,say('图层','Layers'),false);
 button(layerActions,say('新建图层','Add layer'),()=>{try{const request=buildLayerRequest('add',{name:layerName(),color:layerColor(),lineType:layerType(),lineWeight:layerWeight()});void mutate('edit',request);}catch(e){note(e.message,true);}});
 button(layerActions,say('重命名','Rename'),()=>{try{const to=String(layerName()).trim();if(!to)throw Error(say('请输入新名称','Enter the new name'));void mutate('edit',buildLayerRequest('rename',{name:activeLayer(),to}));}catch(e){note(e.message,true);}});
 button(layerActions,say('删除图层','Delete layer'),()=>{try{void mutate('edit',buildLayerRequest('delete',{name:activeLayer()}));}catch(e){note(e.message,true);}});
 button(layerActions,say('选中图元移到该层','Move selection to layer'),()=>{try{const handles=targets();if(!handles.length)throw Error(say('请先选择图元','Select an entity first'));void mutate('edit',buildSetLayer(handles,activeLayer()));}catch(e){note(e.message,true);}});
 function activeLayer(){return layers.find(l=>l.active)?.name??'0';}
 async function refreshLayers(){
  try{
   const [layerReply,drawingReply]=await Promise.all([engine.call('query',{request:buildQuery('layers')}),engine.call('query',{request:buildQuery('drawing')})]);
   layers=layerReply.layers??[];units=drawingReply.unit??'';
   layerList.replaceChildren();
   for(const layer of layers){
    const row=document.createElement('div');row.className='cadLayerRow';row.classList.toggle('active',!!layer.active);
    const pick=document.createElement('button');pick.type='button';pick.textContent=layer.name+(layer.active?` · ${say('当前','active')}`:'');
    pick.className='cadLayerPick';pick.title=layer.name;
    pick.onclick=async()=>{try{await engine.call('setActiveLayer',{name:layer.name});await refresh();}catch(e){note(e.message,true);}};
    const lock=document.createElement('button');lock.type='button';lock.textContent=layer.locked?say('解锁','Unlock'):say('锁定','Lock');
    lock.onclick=async()=>{try{await mutate('edit',{operation:'updateLayer',name:layer.name,locked:!layer.locked});}catch(e){note(e.message,true);}};
    const visibility=document.createElement('button');visibility.type='button';visibility.textContent=layer.visible===false?say('显示','Show'):say('隐藏','Hide');
    visibility.onclick=async()=>{try{await mutate('edit',{operation:'updateLayer',name:layer.name,visible:layer.visible===false});}catch(e){note(e.message,true);}};
    const count=document.createElement('span');count.textContent=String(layer.entityCount??0);
    row.append(pick,lock,visibility,count);layerList.append(row);
   }
  }catch(e){note(e.message,true);}
 }

 // ------------------------------------------------------------ measure tools
 const measure=document.createElement('div');measure.className='cadSection';
 const measureActions=document.createElement('div');measureActions.className='cadActions';
 const checkTolerance=numberField(say('容差','Tolerance'),0.001,modifyFields);
 let recentPoints=[];
 measure.append(measureActions);
 collapsible(measure,say('测量与检查','Measure & check'),false);
 async function runMeasure(kind){
  try{
   const handles=targets();
   const values={measureKind:kind};
   if(kind==='distance'){if(recentPoints.length<2)throw Error(say('请先取两个点','Pick two points first'));values.points=recentPoints.slice(-2);}
   else values.handles=handles;
   const result=await engine.call('query',{request:buildQuery('measure',values)});
   note(formatMeasure(result,zh));
  }catch(e){note(e.message,true);}
 }
 button(measureActions,say('距离','Distance'),()=>runMeasure('distance'));
 button(measureActions,say('角度','Angle'),()=>runMeasure('angle'));
 button(measureActions,say('半径','Radius'),()=>runMeasure('radius'));
 button(measureActions,say('周长','Perimeter'),()=>runMeasure('perimeter'));
 button(measureActions,say('面积','Area'),()=>runMeasure('area'));
 button(measureActions,say('检查','Check drawing'),async()=>{try{const result=await engine.call('query',{request:buildQuery('check',{tolerance:checkTolerance()})});note(formatCheck(result,zh));}catch(e){note(e.message,true);}});
 button(measureActions,say('定位选中','Locate selected'),async()=>{try{if(!selected)throw Error(say('请先选择图元','Select an entity first'));const result=await engine.call('query',{request:buildQuery('locate',{handle:selected})});const point=result.point;if(point){const origin=viewer.GetOrigin(),bounds=viewer.GetBounds();viewer.SetView({x:point[0]-origin.x,y:point[1]-origin.y},Math.max(10,(bounds.maxX-bounds.minX)*.5));viewer.Render();}note(`${result.type} · ${result.layer}`);}catch(e){note(e.message,true);}});
 const snapToggle=document.createElement('label');snapToggle.className='cadFinger';
 const snapCheck=document.createElement('input');snapCheck.type='checkbox';snapCheck.checked=true;
 snapCheck.onchange=()=>{snapEnabled=snapCheck.checked;if(!snapEnabled)clearSnap();};
 snapToggle.append(snapCheck,document.createTextNode(say('对象捕捉','Object snap')));
 measure.append(snapToggle);

 function update(){
  const previous=selected;
  entities.replaceChildren();const placeholder=new Option(say('选择图元以修改','Select an entity'), '');entities.append(placeholder);
  for(const row of info.entities){const kind=Object.keys(row.entity)[0],body=row.entity[kind];
   const option=new Option(`${kind} · ${body.common?.layer??''} · ${row.handle}`,row.handle);option.disabled=!row.editable;entities.append(option);
  }
  if(selected&&!info.entities.some(row=>row.handle===selected)){selected='';selection.delete(previous);}
  entities.value=selected;undo.disabled=busy||!info.canUndo;redo.disabled=busy||!info.canRedo;save.disabled=busy||!dirty;
  selectionInfo.textContent=selection.size?say(`已选 ${selection.size} 个图元`,`${selection.size} selected`):'';
  if(info.entities.length<info.entityCount)note(say('显示前 500 个图元，其他内容保留在原图纸中。','Showing the first 500 entities; other content remains in the drawing.'));
  updateInk();
 }
 function toggleSelection(handle){
  if(!handle)return;if(selection.has(handle))selection.delete(handle);else selection.add(handle);update();
 }
 async function mutate(operation,edit){if(busy)return;busy=true;update();
  try{
   let next;
   if(operation==='edit')next=await engine.call('edit',{edit});
   else next=await engine.call(operation,{});
   info=next.info;dirty=true;onDirty(true);await render(next.dxf);
   note(say('有未保存的修改','Unsaved changes'));
   if(operation==='edit'&&edit?.operation&&(edit.operation==='addLayer'||edit.operation==='updateLayer'||edit.operation==='renameLayer'||edit.operation==='deleteLayer'||edit.operation==='batch')){
    await refreshLayers();
   }
  }
  catch(e){note(e.message,true);}
  finally{busy=false;update();}
 }
 async function refresh(){const next=await engine.call('inspect',{offset:0,limit:500});info=next;update();}
 async function saveDocument(){if(busy)return;busy=true;update();note(say('正在校验并保存…','Validating and saving…'));
  try{const bytes=await engine.call('save');let binary='';for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.subarray(i,i+8192));
   await window.webkit.messageHandlers.floeEngineering.postMessage({operation:'save',base64:btoa(binary)});
   dirty=false;onDirty(false);note(say('已保存，原版已保留','Saved; previous version retained'));
  }catch(e){note(e.message,true);}finally{busy=false;update();}
 }
 // ------------------------------------------- drawing assistant locate/overlay
 const diffCanvas=document.createElement('canvas');diffCanvas.className='cadDiffOverlay';diffCanvas.setAttribute('aria-hidden','true');
 let diffEntries=[],diffHighlight=null,diffReady=false;
 function ensureDiffOverlay(){
  if(diffReady)return;
  const canvas=viewer.GetCanvas(),host=canvas.parentElement??canvas;
  if(getComputedStyle(host).position==='static')host.style.position='relative';
  host.append(diffCanvas);diffReady=true;
  viewer.Subscribe('viewChanged',drawDiff);viewer.Subscribe('resized',drawDiff);
  syncDiffOverlay();
 }
 function syncDiffOverlay(){
  const canvas=viewer.GetCanvas();
  if(!diffReady||canvas.clientWidth<=0||canvas.clientHeight<=0)return;
  const ratio=window.devicePixelRatio||1,width=Math.round(canvas.clientWidth*ratio),height=Math.round(canvas.clientHeight*ratio);
  if(diffCanvas.width!==width||diffCanvas.height!==height){diffCanvas.width=width;diffCanvas.height=height;}
  diffCanvas.getContext('2d').setTransform(ratio,0,0,ratio,0,0);
 }
 function drawDiff(){
  if(!diffReady)return;
  syncDiffOverlay();
  const context=diffCanvas.getContext('2d');
  context.clearRect(0,0,diffCanvas.width,diffCanvas.height);
  const state=viewState();
  const colors={added:'#2fbf71',changed:'#f5a623',deleted:'#e5484d'};
  for(const entry of diffEntries){
   if(!Array.isArray(entry.min)||!Array.isArray(entry.max))continue;
   const a=worldToScreen({x:entry.min[0],y:entry.min[1]},state),b=worldToScreen({x:entry.max[0],y:entry.max[1]},state);
   context.strokeStyle=colors[entry.kind]??'#7a8ba8';context.lineWidth=2;
   // Draw the actual entity geometry when the proposal carries a polyline;
   // fall back to the bounds rectangle otherwise.
   if(Array.isArray(entry.points)&&entry.points.length>=2){
    context.beginPath();
    entry.points.forEach((point,index)=>{
     if(!Array.isArray(point)||point.length<2)return;
     const p=worldToScreen({x:point[0],y:point[1]},state);
     if(index===0)context.moveTo(p.x,p.y);else context.lineTo(p.x,p.y);
    });
    context.stroke();
   }else{
    context.strokeRect(Math.min(a.x,b.x),Math.min(a.y,b.y),Math.max(2,Math.abs(b.x-a.x)),Math.max(2,Math.abs(b.y-a.y)));
   }
  }
  if(diffHighlight){
   const p=worldToScreen(diffHighlight,state);
   context.beginPath();context.arc(p.x,p.y,9,0,Math.PI*2);context.strokeStyle='#ffd60a';context.lineWidth=3;context.stroke();
   context.beginPath();context.arc(p.x,p.y,3,0,Math.PI*2);context.fillStyle='#ffd60a';context.fill();
  }
 }
 function showDiff(entries){diffEntries=Array.isArray(entries)?entries.slice(0,200):[];if(diffEntries.length||diffHighlight)ensureDiffOverlay();drawDiff();}
 function clearDiff(){diffEntries=[];diffHighlight=null;drawDiff();}
 async function locateHandle(handle){
  if(!handle)return false;
  try{
   const result=await engine.call('query',{request:buildQuery('locate',{handle})});
   const point=result?.point;
   if(point){
    const origin=viewer.GetOrigin(),bounds=viewer.GetBounds();
    viewer.SetView({x:point[0]-origin.x,y:point[1]-origin.y},Math.max(10,(bounds.maxX-bounds.minX)*.5));
    viewer.Render();
    diffHighlight={x:point[0],y:point[1]};ensureDiffOverlay();drawDiff();
   }
   return !!point;
  }catch{return false;}
 }
 function reset(){fields.replaceChildren();} function action(label,build){button(tools,label,()=>{try{void mutate('edit',build());}catch(e){note(e.message,true);}});}
 entities.onchange=()=>{
  selected=entities.value;reset();const row=info.entities.find(e=>e.handle===selected);if(!row)return;
  const kind=Object.keys(row.entity)[0],body=row.entity[kind];
  const dx=numberField('ΔX'),dy=numberField('ΔY');
  action(say('移动','Move'),()=>({operation:'move',handle:selected,delta:[dx(),dy(),0]}));
  if(kind==='Circle'){const radius=numberField(say('半径','Radius'),body.radius);action(say('修改半径','Set radius'),()=>({operation:'setRadius',handle:selected,radius:radius()}));}
  if(kind==='Arc'){const radius=numberField(say('半径','Radius'),body.radius);action(say('修改半径','Set radius'),()=>({operation:'setRadius',handle:selected,radius:radius()}));}
  if(kind==='Text'){const value=textField(say('文字','Text'),body.value);action(say('修改文字','Set text'),()=>({operation:'setText',handle:selected,text:value()}));}
  action(say('删除选中图元','Delete selected entity'),()=>({operation:'delete',handle:selected}));
  const anchor=entityAnchor(row);
  if(anchor){const origin=viewer.GetOrigin(),bounds=viewer.GetBounds();viewer.SetView({x:anchor.x-origin.x,y:anchor.y-origin.y},Math.max(10,(bounds.maxX-bounds.minX)*.5));viewer.Render();}
 };
 const down=e=>{
  pointerStart={x:e.detail.domEvent.clientX,y:e.detail.domEvent.clientY};
  if(inkState.active||busy)return;
  const point=screenToWorld(e.detail.position,viewState());
  if(drawMode||clickAction||snapEnabled)void refreshSnap(point);
 };
 const up=e=>{
  const event=e.detail.domEvent;if(busy)return;
  const moved=!pointerStart||Math.hypot(event.clientX-pointerStart.x,event.clientY-pointerStart.y)>8;
  pointerStart=null;
  const origin=viewer.GetOrigin(),raw={x:e.detail.position.x+origin.x,y:e.detail.position.y+origin.y};
  const point=snapWorld(raw);
  if(!moved){
   recentPoints=[...recentPoints,{x:point.x,y:point.y}].slice(-2);
   if(clickAction){const action=clickAction;clickAction=null;action(point);return;}
   if(drawMode){void advanceDraw(point);return;}
  } else if(drawMode){return;}
  if(moved)return;
  const camera=viewer.GetCamera(),threshold=Math.abs(camera.right-camera.left)/camera.zoom/viewer.GetCanvas().clientWidth*20;
  let best=null,distance=threshold;
  for(const row of info.entities.filter(e=>e.editable)){
   const kind=Object.keys(row.entity)[0],v=row.entity[kind];let d=Infinity;
   if(kind==='Line'){
    const dx=v.end.x-v.start.x,dy=v.end.y-v.start.y,length=dx*dx+dy*dy;
    const t=length?Math.max(0,Math.min(1,((point.x-v.start.x)*dx+(point.y-v.start.y)*dy)/length)):0;
    d=Math.hypot(point.x-v.start.x-t*dx,point.y-v.start.y-t*dy);
   }else if(kind==='Circle')d=Math.abs(Math.hypot(point.x-v.center.x,point.y-v.center.y)-v.radius);
   else if(kind==='Arc')d=Math.abs(Math.hypot(point.x-v.center.x,point.y-v.center.y)-v.radius);
   else if(kind==='Text')d=Math.hypot(point.x-v.insertion_point.x,point.y-v.insertion_point.y);
   else if(kind==='LwPolyline'&&Array.isArray(v.vertices)){for(const vertex of v.vertices){const location=vertex.location??vertex;d=Math.min(d,Math.hypot(point.x-location.x,point.y-location.y));}}
   if(d<distance){best=row;distance=d;}
  }
  if(best){panel.hidden=false;entities.value=best.handle;entities.onchange();}
 };
 function advanceDraw(point){
  drawMode.points.push([point.x,point.y]);
  const kind=drawMode.kind;
  if(kind==='line'&&drawMode.points.length===2){
   const [start,end]=drawMode.points;
   void mutate('edit',{operation:'addLine',start:[...start,0],end:[...end,0],layer:layerForCreate()}).then(()=>{drawMode=null;});
  }else if(kind==='rectangle'&&drawMode.points.length===2){
   const [a,b]=drawMode.points;const points=[[a[0],a[1]],[b[0],a[1]],[b[0],b[1]],[a[0],b[1]]];
   void mutate('edit',{operation:'addLwPolyline',points,closed:true,layer:layerForCreate()}).then(()=>{drawMode=null;});
  }else if(kind==='circle'&&drawMode.points.length===2){
   const [center,edge]=drawMode.points;const radius=Math.hypot(edge[0]-center[0],edge[1]-center[1]);
   if(radius<=0){note(say('半径必须大于零','Radius must be positive'),true);drawMode=null;return;}
   void mutate('edit',{operation:'addCircle',center:[...center,0],radius,layer:layerForCreate()}).then(()=>{drawMode=null;});
  }else if(kind==='line'||kind==='rectangle'||kind==='circle'){note(say('继续取下一个点','Pick the next point'));}
 }
 viewer.Subscribe('pointerdown',down);viewer.Subscribe('pointerup',up);
 const add=document.createElement('div');add.className='cadActions';panel.append(add);
 // Keep basic editing and save controls ahead of the optional pen settings.
 panel.append(draw,modify,layerSection,measure,ink);
 for(const kind of ['line','circle','text'])button(add,say({line:'直线',circle:'圆',text:'文字'}[kind],`Add ${kind}`),()=>{
  if(kind==='text'){
   const position=[startX(),startY()];
   try{void mutate('edit',buildCreate('text',{position,text:'文字',height:2.5,layer:layerForCreate()}));}catch(e){note(e.message,true);}
   return;
  }
  const anchor=[startX(),startY()];
  if(kind==='line'){try{void mutate('edit',buildCreate('line',{start:anchor,end:[endX(),endY()],layer:layerForCreate()}));}catch(e){note(e.message,true);}}
  if(kind==='circle'){try{void mutate('edit',buildCreate('circle',{center:anchor,radius:radiusField(),layer:layerForCreate()}));}catch(e){note(e.message,true);}}
 });
 note(say('支持线、圆、圆弧、多段线/矩形、文字、标注、移动/复制/旋转/缩放/镜像、修剪/延伸/偏移、图层与测量。复杂图元保留，暂不编辑。','Lines, circles, arcs, polylines/rectangles, text, dimensions, move/copy/rotate/scale/mirror, trim/extend/offset, layers and measures. Other entities are retained and read only.'));
 update();
 return {showDiff,clearDiff,locate:locateHandle,inspect:()=>({...info,selectedHandle:selected,selection:[...selection],activeLayer:activeLayer(),units,ink:{active:inkState.active,ready:inkState.ready,reason:inkState.reason,color:inkState.color,lineWeight:inkState.lineWeight,drawWithFinger:inkState.drawWithFinger,capabilities:inkState.capabilities?{pointCount:inkState.capabilities.pointCount,lineWeights:inkState.capabilities.lineWeights.length}:null}}),destroy(){
  document.removeEventListener('pointerdown',onPointerDown,captureOptions);
  document.removeEventListener('pointermove',onPointerMove,captureOptions);
  document.removeEventListener('pointerup',onPointerUp,captureOptions);
  document.removeEventListener('pointercancel',onPointerCancel,captureOptions);
  document.removeEventListener('lostpointercapture',onPointerCancel,captureOptions);
  document.removeEventListener('keydown',onKeyDown,captureOptions);
  window.removeEventListener('blur',cancelStroke);
  cancelStroke();
  viewer.Unsubscribe('viewChanged',onViewChanged);viewer.Unsubscribe('resized',onViewChanged);
  inkState.overlay?.remove();inkState.overlay=null;inkState.context=null;
  snapDot.remove();
  viewer.Unsubscribe('pointerdown',down);viewer.Unsubscribe('pointerup',up);
  if(diffReady){viewer.Unsubscribe('viewChanged',drawDiff);viewer.Unsubscribe('resized',drawDiff);}
  diffCanvas.remove();
  panel.remove();toggle.remove();pen.remove();
 }};
}
