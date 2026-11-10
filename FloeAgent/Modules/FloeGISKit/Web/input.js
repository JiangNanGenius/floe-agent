// SPDX-License-Identifier: MPL-2.0
import MapBrowserEvent from 'ol/MapBrowserEvent.js';
import DragPan from 'ol/interaction/DragPan.js';
import { defaults } from 'ol/interaction/defaults.js';
import { noModifierKeys, primaryAction, shiftKeyOnly, altKeyOnly, singleClick } from 'ol/events/condition.js';
import Graticule from 'ol/layer/Graticule.js';
import { Text, Fill, Stroke } from 'ol/style.js';
import { apply } from 'ol/transform.js';

const pointerEvents=new Set(['pointerdown','pointermove','pointerdrag','pointerup']);
const clickEvents=new Set(['click','singleclick','dblclick']);
export const gis2DViewOptions={enableRotation:false,rotation:0};

export { gisEditTools, gisEditNotice } from './readiness.js';

export function gisInputPolicy({fingerDrawing=()=>false,editing=()=>false}={}){
  let activeCount=0,multiple=false,suppressClick=false;
  const events=new WeakMap();
  const observe=event=>{
    if(events.has(event))return events.get(event);
    const original=event.originalEvent??{},pointer=pointerEvents.has(event.type),click=clickEvents.has(event.type);
    const count=pointer&&Array.isArray(event.activePointers)?event.activePointers.length:activeCount;
    if(event.type==='pointerdown'&&activeCount===0&&count<=1)suppressClick=false;
    if(count>1){multiple=true;suppressClick=true;}
    const navigationGesture=multiple||click&&suppressClick;
    const device=original.pointerType,primary=original.isPrimary!==false&&(original.button===0||['pointermove','pointerdrag'].includes(event.type)&&original.button===-1);
    const hardware=device==='mouse'||device==='pen'||device==='touch'&&fingerDrawing();
    const result={edit:Boolean(editing()&&hardware&&primary&&!navigationGesture),navigationGesture,click:!navigationGesture};
    events.set(event,result);
    if(pointer){activeCount=count;if(event.type==='pointerup'&&count===0)multiple=false;}
    return result;
  };
  return {
    observe,
    cancelEvent:event=>events.set(event,{edit:false,navigationGesture:true,click:false}),
    edit:event=>observe(event).edit,
    click:event=>observe(event).click,
    navigate:event=>{const state=observe(event);return noModifierKeys(event)&&(state.navigationGesture||!state.edit)&&(event.originalEvent?.button===0||event.activePointers?.length>1);},
  };
}

export function gisNavigationInteractions(input){
  const interactions=defaults({dragPan:false,altShiftDragRotate:false,pinchRotate:false});
  const pan=new DragPan({condition:input.navigate}),handle=pan.handleEvent.bind(pan);
  pan.handleEvent=event=>{input.observe(event);return handle(event);};
  interactions.push(pan);
  return interactions;
}

export function gisDrawConditions(input){
  return {condition:event=>input.edit(event)&&noModifierKeys(event),freehandCondition:event=>input.edit(event)&&shiftKeyOnly(event),finishCondition:input.edit};
}
export function gisModifyConditions(input){
  return {condition:event=>input.edit(event)&&primaryAction(event),deleteCondition:event=>input.edit(event)&&singleClick(event)&&altKeyOnly(event)};
}
export function gisTranslateConditions(input){return {condition:event=>input.edit(event)&&primaryAction(event)};}

// A second pointer can arrive after OL's down-only condition accepted an edit.
// Finish that pointer sequence without committing, then restore the OL features.
// The document is changed only by the existing typed draw/modify/translate end handlers.
export function guardGISEditInteraction(interaction,input,{start,end,draw=false}={}){
  let pointerGesture=false,cancelling=false;
  const originals=new Map(),handle=interaction.handleEvent.bind(interaction);
  if(start)interaction.on(start,event=>{for(const feature of event.features.getArray())if(!originals.has(feature))originals.set(feature,feature.getGeometry()?.clone());});
  if(end)interaction.on(end,()=>{if(!cancelling)originals.clear();});
  interaction.handleEvent=event=>{
    if(!pointerEvents.has(event.type)&&!clickEvents.has(event.type))return handle(event);
    if(input.edit(event)){
      const result=handle(event);
      if(event.type==='pointerdown')pointerGesture=true;
      if(event.type==='pointerup'&&event.activePointers?.length===0)pointerGesture=false;
      return result;
    }
    if(pointerGesture){
      cancelling=true;
      try{
        const up=new MapBrowserEvent('pointerup',event.map,event.originalEvent,false,event.frameState??undefined,[]);
        up.pixel=event.pixel.slice();up.coordinate=event.coordinate.slice();
        input.cancelEvent(up);handle(up);
        if(draw)interaction.abortDrawing();
        for(const [feature,geometry]of originals)if(geometry)feature.setGeometry(geometry);
      }finally{originals.clear();pointerGesture=false;cancelling=false;}
    }
    return true;
  };
  return {interaction,canCommit:()=>!cancelling};
}

// Native vertex buttons arm this same map click path; they cannot bypass input policy.
export function gisVertexClick(modify,input,event,action,onInsert){
  if(!input.edit(event)||!['insert','delete'].includes(action))return false;
  if(action==='delete')modify.removePoint(event.coordinate);else if(modify.insertPoint(event.coordinate))onInsert?.();
  return true;
}

// OL 10.11.0 exposes static label Text options but no per-label style callback.
// Bind only its two label callbacks; public frame events, Text and transforms
// keep the real graticule lines/anchors untouched. Upgrade with this contract test.
function insetGraticuleLabels(grid,styles){
  let render;
  grid.on('prerender',event=>{render=event;});
  for(const [key,base]of [['lonLabelStyle_',styles[0]],['latLabelStyle_',styles[1]]]){
    const original=grid[key],offset=[base.getOffsetX(),base.getOffsetY()];
    if(typeof original!=='function')throw new Error('GIS graticule label adapter requires OL 10.11.0 label callbacks');
    grid[key]=feature=>{
      const style=original(feature),text=style.getText();
      if(!text)throw new Error('GIS graticule label adapter requires the pinned Text style');
      text.setOffsetX(offset[0]);text.setOffsetY(offset[1]);
      const state=render?.frameState;
      if(!state)return style;
      const size=state.size;
      if(!Array.isArray(size)||size.length!==2||!size.every(Number.isFinite))throw new Error('GIS graticule label adapter received an invalid frame size');
      if(size[0]<=0||size[1]<=0)return style;
      const transform=state.coordinateToPixelTransform,context=render.context,point=feature.getGeometry();
      if(!Array.isArray(transform)||transform.length!==6||!transform.every(Number.isFinite)||point?.getType()!=='Point'||!point.getCoordinates().every(Number.isFinite))throw new Error('GIS graticule label adapter requires the frame transform and OL Point');
      if(typeof context?.measureText!=='function'||typeof context.save!=='function'||typeof context.restore!=='function'||text.getRotation())throw new Error('GIS graticule label adapter requires Canvas font metrics and unrotated Text');
      let measured;
      context.save();
      try{
        context.font=text.getFont();context.textAlign=text.getTextAlign()??'center';context.textBaseline=text.getTextBaseline()??'middle';
        measured=context.measureText(text.getText());
      }finally{context.restore();}
      const bounds=[measured.actualBoundingBoxLeft,measured.actualBoundingBoxAscent,measured.actualBoundingBoxRight,measured.actualBoundingBoxDescent];
      if(!bounds.every(Number.isFinite))throw new Error('GIS graticule label adapter requires actual Canvas bounding-box metrics');
      const scale=text.getScaleArray(),halo=(text.getStroke()?.getWidth()??0)/2,pixel=apply(transform,point.getCoordinates().slice());
      const clamp=(value,min,max)=>min<=max?Math.max(min,Math.min(max,value)):(min+max)/2;
      for(const axis of [0,1]){
        const before=(bounds[axis]+halo)*scale[axis],after=(bounds[axis+2]+halo)*scale[axis];
        const inset=Math.min(8,Math.max(0,(size[axis]-before-after)/2));
        const value=clamp(pixel[axis]+offset[axis],inset+before,size[axis]-inset-after)-pixel[axis];
        if(axis===0)text.setOffsetX(value);else text.setOffsetY(value);
      }
      return style;
    };
  }
  return grid;
}

export function gisGraticule(){
  const ink=()=>({font:'12px Calibri,sans-serif',fill:new Fill({color:'rgba(0,0,0,1)'}),stroke:new Stroke({color:'rgba(255,255,255,1)',width:3})});
  const lon=new Text({...ink(),textBaseline:'bottom',offsetY:-8}),lat=new Text({...ink(),textAlign:'right',offsetX:-8});
  return insetGraticuleLabels(new Graticule({strokeStyle:new Stroke({color:'#8192a433',width:1}),showLabels:true,wrapX:false,
    lonLabelPosition:0,latLabelPosition:1,lonLabelStyle:lon,latLabelStyle:lat}),[lon,lat]);
}
