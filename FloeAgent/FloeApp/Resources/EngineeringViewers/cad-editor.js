// SPDX-License-Identifier: MPL-2.0
// Only these typed operations reach the Rust engine. No arbitrary JS/file API.
import {
 ACI_COLORS, LINE_WEIGHT_PRESETS, DEFAULT_LINE_WEIGHT, DEFAULT_TOLERANCE_PX,
 MIN_SAMPLE_DISTANCE_PX, aciCssColor, buildStrokeRequest, clientToCanvas,
 createStrokeCapture, cssToleranceToWorld, inkReadiness, isDrawPointer,
 screenToWorld, validateStrokeRequest, worldToScreen,
} from './cad-ink.js';

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
 const panel=document.createElement('aside');panel.id='cadPanel';panel.hidden=true;
 const message=document.createElement('p');message.id='cadMessage';message.setAttribute('role','status');
 const controls=document.createElement('div');controls.className='cadActions';
 const fields=document.createElement('div');fields.className='cadFields';
 const entities=document.createElement('select');entities.id='cadEntities';entities.setAttribute('aria-label',say('选择图元','Select entity'));
 const tools=document.createElement('div');tools.className='cadActions';
 const title=document.createElement('strong');title.textContent=say('二维图纸编辑','2D drawing editor');
 const close=document.createElement('button');close.textContent=say('收起','Close');
 panel.append(title,close,message,controls,entities,fields,tools);document.body.append(panel);
 const toggle=document.createElement('button');toggle.id='cadEdit';toggle.textContent=say('编辑','Edit');toggle.onclick=()=>{panel.hidden=!panel.hidden;if(!panel.hidden){const layers=document.getElementById('layers');if(layers)layers.hidden=true;}};
 document.querySelector('header').append(toggle);
 const undo=button(controls,say('撤销','Undo'),()=>mutate('undo'));
 const redo=button(controls,say('重做','Redo'),()=>mutate('redo'));
 const save=button(controls,say('保存','Save'),saveDocument);save.id='cadSave';
 function button(parent,label,action){const b=document.createElement('button');b.textContent=label;b.onclick=action;parent.append(b);return b;}
 function note(text,error=false){message.textContent=text;message.classList.toggle('failure',error);}

 // ------------------------------------------------------------------ ink UI
 const ink=document.createElement('div');ink.className='cadInk';
 const inkTitle=document.createElement('strong');inkTitle.textContent=say('Pencil 批注','Pencil ink');
 const inkMessage=document.createElement('p');inkMessage.className='cadInkMessage';inkMessage.setAttribute('role','status');
 const colorLabel=document.createElement('span');colorLabel.className='cadFieldLabel';colorLabel.textContent=say('笔色','Ink color');
 const colorGroup=document.createElement('div');colorGroup.className='cadSwatches';colorGroup.setAttribute('role','radiogroup');colorGroup.setAttribute('aria-label',say('笔色','Ink color'));
 const widthLabel=document.createElement('span');widthLabel.className='cadFieldLabel';widthLabel.textContent=say('线宽（毫米）','Width (mm)');
 const widthGroup=document.createElement('div');widthGroup.className='cadWidths';widthGroup.setAttribute('role','radiogroup');widthGroup.setAttribute('aria-label',say('线宽','Ink width'));
 const fingerRow=document.createElement('label');fingerRow.className='cadFinger';
 const finger=document.createElement('input');finger.type='checkbox';finger.checked=false;
 fingerRow.append(finger,document.createTextNode(say('用手指绘制','Draw with finger')));
 ink.append(inkTitle,inkMessage,colorLabel,colorGroup,widthLabel,widthGroup,fingerRow);
 panel.insertBefore(ink,entities);

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
 function update(){
  entities.replaceChildren();const placeholder=new Option(say('选择图元以修改','Select an entity'), '');entities.append(placeholder);
  for(const row of info.entities){const kind=Object.keys(row.entity)[0],body=row.entity[kind];
   const option=new Option(`${kind} · ${body.common?.layer??''} · ${row.handle}`,row.handle);option.disabled=!row.editable;entities.append(option);
  }
  entities.value=selected;undo.disabled=busy||!info.canUndo;redo.disabled=busy||!info.canRedo;save.disabled=busy||!dirty;
  if(info.entities.length<info.entityCount)note(say('显示前 500 个图元，其他内容保留在原图纸中。','Showing the first 500 entities; other content remains in the drawing.'));
  updateInk();
 }
 async function mutate(operation,edit){if(busy)return;busy=true;update();
  try{const next=await engine.call(operation,{edit});info=next.info;dirty=true;onDirty(true);await render(next.dxf);note(say('有未保存的修改','Unsaved changes'));}
  catch(e){note(e.message,true);}finally{busy=false;update();}
 }
 async function saveDocument(){if(busy)return;busy=true;update();note(say('正在校验并保存…','Validating and saving…'));
  try{const bytes=await engine.call('save');let binary='';for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.subarray(i,i+8192));
   await window.webkit.messageHandlers.floeEngineering.postMessage({operation:'save',base64:btoa(binary)});
   dirty=false;onDirty(false);note(say('已保存，原版已保留','Saved; previous version retained'));
  }catch(e){note(e.message,true);}finally{busy=false;update();}
 }
 function number(label,value=0){const row=document.createElement('label'),input=document.createElement('input');input.type='number';input.step='any';input.value=String(value);row.append(document.createTextNode(label),input);fields.append(row);return ()=>{const v=Number(input.value);if(!input.value||!Number.isFinite(v))throw Error(say('请输入有效数字','Enter a valid number'));return v;};}
 function text(label,value=''){const row=document.createElement('label'),input=document.createElement('input');input.type='text';input.value=value;row.append(document.createTextNode(label),input);fields.append(row);return ()=>input.value;}
 function reset(){fields.replaceChildren();tools.replaceChildren();}
 function action(label,build){button(tools,label,()=>{try{void mutate('edit',build());}catch(e){note(e.message,true);}});}
 entities.onchange=()=>{
  selected=entities.value;reset();const row=info.entities.find(e=>e.handle===selected);if(!row)return;
  const kind=Object.keys(row.entity)[0],body=row.entity[kind];
  const dx=number('ΔX'),dy=number('ΔY');
  action(say('移动','Move'),()=>({operation:'move',handle:selected,delta:[dx(),dy(),0]}));
  if(kind==='Circle'){const radius=number(say('半径','Radius'),body.radius);action(say('修改半径','Set radius'),()=>({operation:'setRadius',handle:selected,radius:radius()}));}
  if(kind==='Text'){const value=text(say('文字','Text'),body.value);action(say('修改文字','Set text'),()=>({operation:'setText',handle:selected,text:value()}));}
  action(say('删除选中图元','Delete selected entity'),()=>({operation:'delete',handle:selected}));
  const position=body.center??body.insertion_point??body.start;
  if(position){const origin=viewer.GetOrigin(),bounds=viewer.GetBounds();viewer.SetView({x:position.x-origin.x,y:position.y-origin.y},Math.max(10,(bounds.maxX-bounds.minX)*.5));viewer.Render();}
 };
 const down=e=>{pointerStart={x:e.detail.domEvent.clientX,y:e.detail.domEvent.clientY};};
 const up=e=>{
  const event=e.detail.domEvent;if(busy||!pointerStart||Math.hypot(event.clientX-pointerStart.x,event.clientY-pointerStart.y)>8)return;
  pointerStart=null;const origin=viewer.GetOrigin(),p={x:e.detail.position.x+origin.x,y:e.detail.position.y+origin.y};
  const camera=viewer.GetCamera(),threshold=Math.abs(camera.right-camera.left)/camera.zoom/viewer.GetCanvas().clientWidth*20;
  let best=null,distance=threshold;
  for(const row of info.entities.filter(e=>e.editable)){
   const kind=Object.keys(row.entity)[0],v=row.entity[kind];let d=Infinity;
   if(kind==='Line'){
    const dx=v.end.x-v.start.x,dy=v.end.y-v.start.y,length=dx*dx+dy*dy;
    const t=length?Math.max(0,Math.min(1,((p.x-v.start.x)*dx+(p.y-v.start.y)*dy)/length)):0;
    d=Math.hypot(p.x-v.start.x-t*dx,p.y-v.start.y-t*dy);
   }else if(kind==='Circle')d=Math.abs(Math.hypot(p.x-v.center.x,p.y-v.center.y)-v.radius);
   else if(kind==='Text')d=Math.hypot(p.x-v.insertion_point.x,p.y-v.insertion_point.y);
   if(d<distance){best=row;distance=d;}
  }
  if(best){panel.hidden=false;entities.value=best.handle;entities.onchange();}
 };
 viewer.Subscribe('pointerdown',down);viewer.Subscribe('pointerup',up);
 const add=document.createElement('div');add.className='cadActions';panel.append(add);
 for(const kind of ['line','circle','text'])button(add,say({line:'直线',circle:'圆',text:'文字'}[kind],`Add ${kind}`),()=>{
  selected='';entities.value='';reset();const x=number('X'),y=number('Y');
  const layer=text(say('图层','Layer'),'0');
  if(kind==='line'){const ex=number(say('终点 X','End X'),10),ey=number(say('终点 Y','End Y'),10);action(say('添加直线','Add line'),()=>({operation:'addLine',start:[x(),y(),0],end:[ex(),ey(),0],layer:layer()}));}
  if(kind==='circle'){const r=number(say('半径','Radius'),5);action(say('添加圆','Add circle'),()=>({operation:'addCircle',center:[x(),y(),0],radius:r(),layer:layer()}));}
  if(kind==='text'){const t=text(say('文字','Text')),h=number(say('字高','Text height'),2.5);action(say('添加文字','Add text'),()=>({operation:'addText',position:[x(),y(),0],text:t(),height:h(),layer:layer()}));}
 });
 note(say('支持线、圆、文字，以及 Apple Pencil 批注。复杂图元保留，暂不编辑。','Edit lines, circles and text, plus Apple Pencil ink. Other entities are retained and read only.'));update();
 return {inspect:()=>({...info,selectedHandle:selected,ink:{active:inkState.active,ready:inkState.ready,reason:inkState.reason,color:inkState.color,lineWeight:inkState.lineWeight,drawWithFinger:inkState.drawWithFinger,capabilities:inkState.capabilities?{pointCount:inkState.capabilities.pointCount,lineWeights:inkState.capabilities.lineWeights.length}:null}}),destroy(){
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
  viewer.Unsubscribe('pointerdown',down);viewer.Unsubscribe('pointerup',up);
  panel.remove();toggle.remove();pen.remove();
 }};
}
