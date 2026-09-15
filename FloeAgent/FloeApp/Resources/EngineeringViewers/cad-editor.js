// SPDX-License-Identifier: MPL-2.0
// Only these typed operations reach the Rust engine. No arbitrary JS/file API.
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

export function installCadEditor({engine,initial,render,viewer,zh,onDirty}){
 const say=(cn,en)=>zh?cn:en;
 let info=initial,selected='',busy=false,dirty=false,pointerStart=null;
 const panel=document.createElement('aside');panel.id='cadPanel';panel.hidden=true;
 const message=document.createElement('p');message.id='cadMessage';message.setAttribute('role','status');
 const controls=document.createElement('div');controls.className='cadActions';
 const fields=document.createElement('div');fields.className='cadFields';
 const entities=document.createElement('select');entities.id='cadEntities';entities.setAttribute('aria-label',say('选择图元','Select entity'));
 const tools=document.createElement('div');tools.className='cadActions';
 const title=document.createElement('strong');title.textContent=say('二维图纸编辑','2D drawing editor');
 const close=document.createElement('button');close.textContent=say('收起','Close');close.onclick=()=>panel.hidden=true;
 panel.append(title,close,message,controls,entities,fields,tools);document.body.append(panel);
 const toggle=document.createElement('button');toggle.id='cadEdit';toggle.textContent=say('编辑','Edit');toggle.onclick=()=>panel.hidden=!panel.hidden;
 document.querySelector('header').append(toggle);
 const undo=button(controls,say('撤销','Undo'),()=>mutate('undo'));
 const redo=button(controls,say('重做','Redo'),()=>mutate('redo'));
 const save=button(controls,say('保存','Save'),saveDocument);save.id='cadSave';
 function button(parent,label,action){const b=document.createElement('button');b.textContent=label;b.onclick=action;parent.append(b);return b;}
 function note(text,error=false){message.textContent=text;message.classList.toggle('failure',error);}
 function update(){
  entities.replaceChildren();const placeholder=new Option(say('选择图元以修改','Select an entity'), '');entities.append(placeholder);
  for(const row of info.entities){const kind=Object.keys(row.entity)[0],body=row.entity[kind];
   const option=new Option(`${kind} · ${body.common?.layer??''} · ${row.handle}`,row.handle);option.disabled=!row.editable;entities.append(option);
  }
  entities.value=selected;undo.disabled=busy||!info.canUndo;redo.disabled=busy||!info.canRedo;save.disabled=busy||!dirty;
  if(info.entities.length<info.entityCount)note(say('显示前 500 个图元，其他内容保留在原图纸中。','Showing the first 500 entities; other content remains in the drawing.'));
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
 note(say('支持线、圆、文字。复杂图元保留，暂不编辑。','Edit lines, circles and text. Other entities are retained and read only.'));update();
 return {inspect:()=>({...info,selectedHandle:selected}),destroy(){viewer.Unsubscribe('pointerdown',down);viewer.Unsubscribe('pointerup',up);panel.remove();toggle.remove();}};
}
