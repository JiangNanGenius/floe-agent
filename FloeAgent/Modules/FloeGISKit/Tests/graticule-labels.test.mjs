// SPDX-License-Identifier: MPL-2.0
import test from 'node:test';
import assert from 'node:assert/strict';
import View from 'ol/View.js';
import Feature from 'ol/Feature.js';
import Point from 'ol/geom/Point.js';
import {create,compose,apply} from 'ol/transform.js';
import {gis2DViewOptions,gisGraticule} from '../Web/input.js';

// Only Canvas font metrics are a deterministic fixture. View/projection,
// graticule generation, label geometries and Text styles are pinned real OL.
function metrics(label,align,baseline){
  const width=String(label).length*7.25+1;
  const left=align==='right'?width+.75:align==='left'?.75:width/2+.75;
  const right=align==='right'?-.25:align==='left'?width-.25:width/2-.25;
  return {actualBoundingBoxLeft:left,actualBoundingBoxRight:right,
    actualBoundingBoxAscent:baseline==='bottom'?11.25:5.5,
    actualBoundingBoxDescent:baseline==='bottom'?-1.25:4.5};
}
function fontContext(){
  const stack=[],calls=[];
  return {font:'10px sans-serif',textAlign:'left',textBaseline:'alphabetic',calls,
    save(){stack.push([this.font,this.textAlign,this.textBaseline]);},
    restore(){[this.font,this.textAlign,this.textBaseline]=stack.pop();},
    measureText(label){calls.push({font:this.font,align:this.textAlign,baseline:this.textBaseline,label});return metrics(label,this.textAlign,this.textBaseline);}};
}
function frame({size=[640,720],center=[0,0],resolution=.25,pixelRatio=1}={}){
  const view=new View({...gis2DViewOptions,projection:'EPSG:4326',center,resolution,constrainResolution:false});
  view.setViewportSize(size);
  const state=view.getState(),transform=compose(create(),size[0]/2,size[1]/2,1/state.resolution,-1/state.resolution,-state.rotation,-state.center[0],-state.center[1]);
  return {size,pixelRatio,viewState:state,extent:view.calculateExtent(size),coordinateToPixelTransform:transform};
}
function labelBounds(text,pixel){
  const box=metrics(text.getText(),text.getTextAlign()??'center',text.getTextBaseline()??'middle'),halo=(text.getStroke()?.getWidth()??0)/2;
  return [pixel[0]+text.getOffsetX()-box.actualBoundingBoxLeft-halo,
    pixel[1]+text.getOffsetY()-box.actualBoundingBoxAscent-halo,
    pixel[0]+text.getOffsetX()+box.actualBoundingBoxRight+halo,
    pixel[1]+text.getOffsetY()+box.actualBoundingBoxDescent+halo];
}
function labels(grid,state,context=fontContext()){
  grid.loaderFunction(state.extent,state.viewState.resolution,state.viewState.projection);
  grid.dispatchEvent({type:'prerender',frameState:state,context});
  const result=[];
  for(const [kind,lines,data,pointMethod] of [
    ['lon',grid.getMeridians(),grid.meridiansLabels_,'getMeridianPoint_'],
    ['lat',grid.getParallels(),grid.parallelsLabels_,'getParallelPoint_']]){
    for(let index=0;index<lines.length;index++){
      const line=lines[index],coordinates=line.getCoordinates(),point=grid[pointMethod](line,state.extent,index),original=point.getCoordinates().slice();
      const feature=new Feature({geometry:point,graticule_label:data[index].text});
      const text=grid[`${kind}LabelStyle_`](feature).getText();
      assert.deepEqual(line.getCoordinates(),coordinates,'label placement must preserve the real graticule line');
      assert.deepEqual(point.getCoordinates(),original,'label placement must preserve OL geographic anchor');
      assert.equal(text.getText(),data[index].text,'label value must preserve true longitude/latitude');
      const pixel=apply(state.coordinateToPixelTransform,original.slice());
      result.push({kind,text:text.getText(),anchor:original,pixel,offset:[text.getOffsetX(),text.getOffsetY()],bounds:labelBounds(text,pixel)});
    }
  }
  assert.ok(result.length>0,'the real OL loader must generate labels');
  return result;
}
function inside(all,size){
  for(const label of all){
    const [left,top,right,bottom]=label.bounds;
    assert.ok(left>=-1e-8&&top>=-1e-8&&right<=size[0]+1e-8&&bottom<=size[1]+1e-8,
      `${label.kind} ${label.text} bounds=${JSON.stringify(label.bounds)} viewport=${JSON.stringify(size)}`);
  }
}

test('world EPSG4326 preserves both 90-degree parallels and contains labels at all four viewport edges',t=>{
  const grid=gisGraticule(),state=frame(),context=fontContext();
  try{
    const all=labels(grid,state,context);
    for(const pole of all.filter(label=>label.kind==='lat'&&Math.abs(label.anchor[1])===90))t.diagnostic(`pole ${pole.text} bounds=${JSON.stringify(pole.bounds)} viewport=${JSON.stringify(state.size)}`);
    inside(all,state.size);
    for(const latitude of [-90,90]){
      const pole=all.find(label=>label.kind==='lat'&&Math.abs(label.anchor[1]-latitude)<1e-8);
      assert.ok(pole,`real ${latitude} degree parallel is retained`);
      assert.match(pole.text,/90°/);
    }
    assert.ok(all.some(label=>label.kind==='lon'&&label.pixel[0]<1));
    assert.ok(all.some(label=>label.kind==='lon'&&label.pixel[0]>state.size[0]-1));
    assert.ok(context.calls.some(call=>call.align==='right'&&call.baseline==='middle'));
    assert.ok(context.calls.some(call=>call.align==='center'&&call.baseline==='bottom'));
    assert.ok(context.calls.every(call=>call.font==='12px Calibri,sans-serif'));
    assert.equal(context.font,'10px sans-serif','measurement restores the render context');
  }finally{grid.dispose();}
});

test('pan, zoom and viewport resize recalculate label offsets without cumulative drift',()=>{
  const grid=gisGraticule(),initial=frame();
  try{
    const original=labels(grid,initial);inside(original,initial.size);
    for(let cycle=0;cycle<3;cycle++){
      for(const options of [
        {center:[20,10],resolution:.1},
        {size:[320,400],center:[0,0],resolution:.45},
        {size:[960,360],center:[-120,20],resolution:.5},
        {size:[160,240],center:[40,-30],resolution:.25}
      ]){const next=frame(options);inside(labels(grid,next),next.size);}
      assert.deepEqual(labels(grid,initial),original,'returning to the same view must restore identical labels and offsets');
    }
  }finally{grid.dispose();}
});

test('DPR changes preserve CSS label bounds and zero-size first/reconstructed frames are safe',()=>{
  const grid=gisGraticule(),feature=new Feature({geometry:new Point([0,90]),graticule_label:'90° N'});
  try{
    grid.dispatchEvent({type:'prerender',frameState:frame({size:[0,0]}),context:fontContext()});
    let text=grid.latLabelStyle_(feature).getText();assert.deepEqual([text.getOffsetX(),text.getOffsetY()],[-8,0]);
    const first=labels(grid,frame());inside(first,[640,720]);
    for(const pixelRatio of [2,3])assert.deepEqual(labels(grid,frame({pixelRatio})),first);
    grid.dispatchEvent({type:'prerender',frameState:frame({size:[0,720]}),context:fontContext()});
    text=grid.latLabelStyle_(feature).getText();assert.deepEqual([text.getOffsetX(),text.getOffsetY()],[-8,0]);
    assert.deepEqual(labels(grid,frame()),first);
  }finally{grid.dispose();}
});

test('active frame transform or font-metrics contract mismatch fails explicitly',()=>{
  const grid=gisGraticule(),feature=new Feature({geometry:new Point([0,90]),graticule_label:'90° N'});
  try{
    const missing=frame();delete missing.coordinateToPixelTransform;
    grid.dispatchEvent({type:'prerender',frameState:missing,context:fontContext()});
    assert.throws(()=>grid.latLabelStyle_(feature),/graticule.*(transform|frame)/i);
    const context=fontContext();context.measureText=()=>({width:42});
    grid.dispatchEvent({type:'prerender',frameState:frame(),context});
    assert.throws(()=>grid.latLabelStyle_(feature),/graticule.*(metric|measure)/i);
  }finally{grid.dispose();}
});
