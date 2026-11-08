// SPDX-License-Identifier: MPL-2.0
import test from 'node:test';
import assert from 'node:assert/strict';
import './graticule-labels.test.mjs';
import BaseObject from 'ol/Object.js';
import View from 'ol/View.js';
import Collection from 'ol/Collection.js';
import Feature from 'ol/Feature.js';
import LineString from 'ol/geom/LineString.js';
import GeoJSON from 'ol/format/GeoJSON.js';
import MapBrowserEvent from 'ol/MapBrowserEvent.js';
import Draw from 'ol/interaction/Draw.js';
import Modify from 'ol/interaction/Modify.js';
import Translate from 'ol/interaction/Translate.js';
import DragPan from 'ol/interaction/DragPan.js';
import PinchZoom from 'ol/interaction/PinchZoom.js';
import PinchRotate from 'ol/interaction/PinchRotate.js';
import DragRotate from 'ol/interaction/DragRotate.js';
import { EditorEngine } from '../../FloeHeavyEditorSupport/Web/runtime.js';
import { createGIS,normalizeGIS,vectorLayer,registerModelCommands } from '../Web/model.js';
import { gisUI,gisNativeSnapshot,registerGISUI } from '../Web/native.js';
import { gis2DViewOptions,gisInputPolicy,gisNavigationInteractions,gisDrawConditions,gisModifyConditions,gisTranslateConditions,guardGISEditInteraction,gisVertexClick,gisGraticule } from '../Web/input.js';

globalThis.requestAnimationFrame??=callback=>setTimeout(()=>callback(performance.now()),0);
globalThis.cancelAnimationFrame??=clearTimeout;
const format=new GeoJSON();
// Geometry-to-pixel adapter only. Editing, gesture sequences, navigation, geometry,
// the document registry and history below are real pinned OL / Floe implementations.
class GeometryMap extends BaseObject {
  constructor(features=[]){super();this.features=features;this.view=new View({...gis2DViewOptions,center:[0,0],resolution:1});this.view.setViewportSize([400,300]);this.viewport={classList:{add(){},remove(){}}};}
  getView(){return this.view;}
  getViewport(){return this.viewport;}
  getOverlayContainer(){return {appendChild(){},removeChild(){}};}
  getSize(){return [400,300];}
  getEventPixel(event){return [event.clientX,event.clientY];}
  getPixelFromCoordinate(coordinate){const center=this.view.getCenter(),resolution=this.view.getResolution();return [200+(coordinate[0]-center[0])/resolution,150-(coordinate[1]-center[1])/resolution];}
  getCoordinateFromPixel(pixel){const center=this.view.getCenter(),resolution=this.view.getResolution();return [center[0]+(pixel[0]-200)*resolution,center[1]-(pixel[1]-150)*resolution];}
  getCoordinateFromPixelInternal(pixel){return this.getCoordinateFromPixel(pixel);}
  getPixelFromCoordinateInternal(coordinate){return this.getPixelFromCoordinate(coordinate);}
  forEachFeatureAtPixel(pixel,callback){for(const feature of this.features){const result=callback(feature,null);if(result)return result;}}
  isRendered(){return true;}
  render(){}
}
function pointer(device,id,coordinate,map,extra={}){const [clientX,clientY]=map.getPixelFromCoordinate(coordinate);return {type:'pointermove',pointerType:device,pointerId:id,isPrimary:id===1,button:0,buttons:1,clientX,clientY,shiftKey:false,altKey:false,metaKey:false,ctrlKey:false,preventDefault(){},...extra};}
function event(type,map,original,activePointers){const e=new MapBrowserEvent(type,map,original,type==='pointerdrag',undefined,activePointers);e.pixel=[original.clientX,original.clientY];e.coordinate=map.getCoordinateFromPixel(e.pixel);return e;}
// Allocate OL's unchanged Shift-drag zoom rectangle without enabling DOM rendering in EditorEngine.
function navigationFor(input){const previous=globalThis.document;try{globalThis.document??={createElement:()=>({style:{}})};return gisNavigationInteractions(input);}finally{if(previous===undefined)delete globalThis.document;else globalThis.document=previous;}}
function fixture(tool,{fingerDrawing=false,rawDraw=false}={}){
  const e=new EditorEngine({kind:'gis',create:createGIS,normalize:normalizeGIS,nativeSnapshot:gisNativeSnapshot});registerModelCommands(e);registerGISUI(e);gisUI(e).tool=tool;gisUI(e).fingerDrawing=fingerDrawing;
  const layer=vectorLayer('Input',['Point','LineString','Polygon'].includes(tool)?[]:[{type:'Feature',id:'line',properties:{},geometry:{type:'LineString',coordinates:[[-40,0],[0,0],[40,0]]}}],'EPSG:3857');e.state.layers.push(layer);e.selection={layer:layer.id,features:layer.data.features.map(f=>f.id)};
  const features=format.readFeatures(layer.data),map=new GeometryMap(features),input=gisInputPolicy({fingerDrawing:()=>gisUI(e).fingerDrawing,editing:()=>!e.state.layers[0].locked&&tool!=='select'}),navigation=navigationFor(input),pending=[];let commits=0,interaction,guard;
  const run=(command,args)=>{commits++;pending.push(e.execute({command,arguments:args,revision:0}));};
  const commit=()=>run('feature.geometries',{changes:features.map(f=>({layer:layer.id,feature:f.getId(),geometry:format.writeGeometryObject(f.getGeometry())}))});
  if(['Point','LineString','Polygon'].includes(tool)){
    interaction=new Draw({type:tool,wrapX:false,...(rawDraw?{}:gisDrawConditions(input))});if(!rawDraw)guard=guardGISEditInteraction(interaction,input,{draw:true});
    interaction.on('drawend',value=>{if(!guard||guard.canCommit())run('feature.add',{layer:layer.id,geometry:value.feature.getGeometry().getType(),coordinates:value.feature.getGeometry().getCoordinates(),properties:{}});});
  }else if(tool==='modify'){
    interaction=new Modify({features:new Collection(features),pixelTolerance:14,...gisModifyConditions(input)});guard=guardGISEditInteraction(interaction,input,{start:'modifystart',end:'modifyend'});interaction.on('modifyend',()=>{if(guard.canCommit())commit();});
  }else if(tool==='translate'){
    interaction=new Translate({features:new Collection(features),hitTolerance:12,...gisTranslateConditions(input)});guard=guardGISEditInteraction(interaction,input,{start:'translatestart',end:'translateend'});interaction.on('translateend',()=>{if(guard.canCommit())commit();});
  }
  const interactions=[...navigation.getArray(),...(interaction?[interaction]:[])];for(const value of interactions)value.setMap(map);
  const send=(type,original,activePointers)=>{const ev=event(type,map,original,activePointers);for(const value of [...interactions].reverse())if(value.handleEvent(ev)===false)break;return ev;};
  const clickVertex=(device,action,coordinate=[20,0])=>{const p=pointer(device,1,coordinate,map,{buttons:0}),ev=event('singleclick',map,p,undefined);return gisVertexClick(interaction,input,ev,action,commit);};
  const flush=async()=>{await Promise.all(pending.splice(0));};
  const close=()=>{for(const value of interactions)value.setMap(null);map.view.cancelAnimations();};
  return {e,layer,features,map,input,interaction,navigation,send,clickVertex,flush,close,get commits(){return commits;}};
}
function tap(f,device,coordinate=[0,0]){const down=pointer(device,1,coordinate,f.map);f.send('pointerdown',down,[down]);f.send('pointerup',{...down,type:'pointerup',buttons:0},[]);}
function drag(f,device,start=[0,0],finish=[20,10]){let p=pointer(device,1,start,f.map);f.send('pointerdown',p,[p]);p=pointer(device,1,finish,f.map,{button:-1});f.send('pointerdrag',p,[p]);f.send('pointerup',{...p,type:'pointerup',button:0,buttons:0},[]);}
const coordinates=f=>f.e.state.layers[0].data.features[0]?.geometry.coordinates;

test('native typed finger toggle defaults off, validates Boolean and never changes payload/history',async()=>{
  const f=fixture('Point'),before=JSON.stringify(f.e.payload);assert.equal(f.e.nativeSnapshot().ui.fingerDrawing,false);
  const descriptor=f.e.command('gis.ui.options');assert.equal(descriptor.access,'read');assert.equal(descriptor.hidden,true);assert.equal(descriptor.fields.find(field=>field.key==='fingerDrawing').type,'checkbox');
  await f.e.execute({command:'gis.ui.options',arguments:{fingerDrawing:true},revision:0});assert.equal(f.e.nativeSnapshot().ui.fingerDrawing,true);assert.equal(JSON.stringify(f.e.payload),before);
  await assert.rejects(f.e.execute({command:'gis.ui.options',arguments:{fingerDrawing:'true'},revision:0}),/Invalid map option/);
  await f.e.execute({command:'gis.ui.options',arguments:{fingerDrawing:false},revision:0});assert.equal(f.e.nativeSnapshot().ui.fingerDrawing,false);f.close();
});
test('baseline OL Point without input policy accepts touch, matching the old map constructor',async()=>{
  const f=fixture('Point',{rawDraw:true});tap(f,'touch');await f.flush();assert.equal(f.e.state.layers[0].data.features.length,1);f.close();
});
test('default touch in Point mode pans the real View without creating a document feature',async()=>{
  const f=fixture('Point');let p=pointer('touch',1,[0,0],f.map);f.send('pointerdown',p,[p]);p={...p,button:-1,clientX:210};f.send('pointerdrag',p,[p]);p={...p,clientX:235};f.send('pointerdrag',p,[p]);f.send('pointerup',{...p,button:0,buttons:0},[]);await f.flush();
  assert.notDeepEqual(f.map.view.getCenter(),[0,0]);assert.equal(f.e.state.layers[0].data.features.length,0);assert.equal(f.commits,0);f.close();
});
for(const device of ['mouse','pen'])test(`${device} Point editing works while finger drawing remains off`,async()=>{
  const f=fixture('Point');tap(f,device,[12,8]);await f.flush();assert.deepEqual(coordinates(f),[12,8]);assert.equal(f.commits,1);assert.deepEqual(f.map.view.getCenter(),[0,0]);f.close();
});
test('enabled single touch creates a real feature; disabling the same typed option fences later touch',async()=>{
  const f=fixture('Point');await f.e.execute({command:'gis.ui.options',arguments:{fingerDrawing:true},revision:0});tap(f,'touch',[10,5]);await f.flush();assert.deepEqual(coordinates(f),[10,5]);
  await f.e.execute({command:'gis.ui.options',arguments:{fingerDrawing:false},revision:0});tap(f,'touch',[30,5]);await f.flush();assert.equal(f.e.state.layers[0].data.features.length,1);f.close();
});
for(const tool of ['modify','translate']){
  test(`${tool}: default touch cannot change OL geometry or canonical document`,async()=>{
    const f=fixture(tool),before=structuredClone(coordinates(f));drag(f,'touch');await f.flush();assert.deepEqual(coordinates(f),before);assert.deepEqual(f.features[0].getGeometry().getCoordinates(),before);assert.equal(f.commits,0);f.close();
  });
  for(const device of ['mouse','pen','touch'])test(`${tool}: ${device} edits commit through real feature.geometries`,async()=>{
    const f=fixture(tool,{fingerDrawing:device==='touch'}),before=structuredClone(coordinates(f));drag(f,device);await f.flush();assert.notDeepEqual(coordinates(f),before);assert.deepEqual(coordinates(f),f.features[0].getGeometry().getCoordinates());assert.equal(f.commits,1);assert.equal(f.e.payload.history.past.length,1);const edited=structuredClone(coordinates(f));await f.e.execute({command:'history.undo',arguments:{},revision:0});assert.deepEqual(coordinates(f),before);await f.e.execute({command:'history.redo',arguments:{},revision:0});assert.deepEqual(coordinates(f),edited);f.close();
  });
}
for(const tool of ['Point','modify','translate'])test(`${tool}: two fingers cancel pending edits, pan/zoom and suppress the late click`,async()=>{
  const f=fixture(tool,{fingerDrawing:true}),before=structuredClone(f.e.payload);let a=pointer('touch',1,[0,0],f.map),b=pointer('touch',2,[40,0],f.map);
  f.send('pointerdown',a,[a]);if(tool!=='Point'){a={...a,clientX:205,clientY:145,button:-1};f.send('pointerdrag',a,[a]);}
  f.send('pointerdown',b,[a,b]);a={...a,clientX:215,button:-1};b={...b,clientX:255,button:-1};f.send('pointerdrag',a,[a,b]);a={...a,clientX:225};b={...b,clientX:285};f.send('pointerdrag',b,[a,b]);
  f.send('pointerup',{...b,button:0,buttons:0},[a]);a={...a,clientX:230};const remaining=f.send('pointerdrag',a,[a]);assert.equal(f.input.edit(remaining),false);a={...a,clientX:245};f.send('pointerdrag',a,[a]);f.send('pointerup',{...a,button:0,buttons:0},[]);const late=f.send('singleclick',{...a,button:0,buttons:0},undefined);await f.flush();
  assert.equal(f.commits,0);assert.deepEqual(f.e.payload,before);if(tool!=='Point')assert.deepEqual(f.features[0].getGeometry().getCoordinates(),before.data.layers[0].data.features[0].geometry.coordinates);
  assert.ok(f.map.view.getResolution()!==1||f.map.view.getCenter().some(value=>value!==0));assert.equal(f.input.edit(late),false);assert.equal(f.input.click(late),false);assert.equal(f.map.view.getRotation(),0);
  if(tool==='Point'){tap(f,'touch',[4,3]);await f.flush();assert.equal(f.commits,1);}else{drag(f,'pen');await f.flush();assert.equal(f.commits,1);}f.close();
});
for(const action of ['insert','delete'])test(`explicit ${action} vertex click uses the same touch gate and commits permitted edits`,async()=>{
  const f=fixture('modify'),coordinate=action==='insert'?[20,0]:[0,0],before=structuredClone(coordinates(f));
  assert.equal(f.clickVertex('touch',action,coordinate),false);await f.flush();assert.deepEqual(coordinates(f),before);assert.deepEqual(f.features[0].getGeometry().getCoordinates(),before);assert.equal(f.commits,0);
  await f.e.execute({command:'gis.ui.options',arguments:{fingerDrawing:true},revision:0});assert.equal(f.clickVertex('touch',action,coordinate),true);await f.flush();assert.equal(coordinates(f).length,before.length+(action==='insert'?1:-1));assert.equal(f.commits,1);assert.equal(f.e.payload.history.past.length,1);await f.e.execute({command:'history.undo',arguments:{},revision:0});assert.deepEqual(coordinates(f),before);assert.equal(f.e.payload.history.past.length,0);f.close();
});
for(const device of ['mouse','pen'])test(`explicit insert/delete vertex clicks remain editable with ${device}`,async()=>{
  const f=fixture('modify'),before=structuredClone(coordinates(f));assert.equal(f.clickVertex(device,'insert',[20,0]),true);await f.flush();assert.equal(coordinates(f).length,4);const inserted=structuredClone(coordinates(f));assert.equal(f.clickVertex(device,'delete',[20,0]),true);await f.flush();assert.equal(coordinates(f).length,3);assert.equal(f.commits,2);assert.equal(f.e.payload.history.past.length,2);await f.e.execute({command:'history.undo',arguments:{},revision:0});assert.deepEqual(coordinates(f),inserted);await f.e.execute({command:'history.undo',arguments:{},revision:0});assert.deepEqual(coordinates(f),before);f.close();
});
test('two-finger late click cannot bypass explicit insert/delete even after fingers lift',async()=>{
  const f=fixture('modify',{fingerDrawing:true}),before=structuredClone(coordinates(f)),a=pointer('touch',1,[0,30],f.map),b=pointer('touch',2,[40,30],f.map);
  f.send('pointerdown',a,[a]);f.send('pointerdown',b,[a,b]);f.send('pointerup',{...b,buttons:0},[a]);f.send('pointerup',{...a,buttons:0},[]);
  assert.equal(f.clickVertex('touch','insert',[20,0]),false);assert.equal(f.clickVertex('touch','delete',[0,0]),false);await f.flush();assert.deepEqual(coordinates(f),before);assert.equal(f.commits,0);f.close();
});

for(const tool of ['LineString','Polygon']){
  test(`${tool}: default touch does not draw or finish a feature`,async()=>{const f=fixture(tool);for(const coordinate of [[0,0],[40,0],[40,40]])tap(f,'touch',coordinate);f.interaction.finishDrawing();await f.flush();assert.equal(f.e.state.layers[0].data.features.length,0);assert.equal(f.commits,0);f.close();});
  for(const device of ['mouse','pen','touch'])test(`${tool}: ${device} uses the real Draw sequence and native finish action`,async()=>{const f=fixture(tool,{fingerDrawing:device==='touch'});for(const coordinate of [[0,0],[40,0],[40,40]])tap(f,device,coordinate);f.interaction.finishDrawing();await f.flush();assert.equal(f.e.state.layers[0].data.features.length,1);assert.equal(f.e.state.layers[0].data.features[0].geometry.type,tool);assert.equal(f.commits,1);f.close();});
}
test('shift freehand cannot bypass disabled finger drawing',async()=>{
  const f=fixture('LineString');let p=pointer('touch',1,[0,0],f.map,{shiftKey:true});f.send('pointerdown',p,[p]);p={...p,clientX:230,button:-1};f.send('pointerdrag',p,[p]);f.send('pointerup',{...p,button:0,buttons:0},[]);f.interaction.finishDrawing();await f.flush();assert.equal(f.e.state.layers[0].data.features.length,0);assert.equal(f.commits,0);f.close();
});
test('a second finger rolls back a vertex inserted on down; the next Pencil stroke remains usable',async()=>{
  const f=fixture('modify',{fingerDrawing:true}),before=structuredClone(coordinates(f));let a=pointer('touch',1,[20,0],f.map),b=pointer('touch',2,[50,30],f.map);
  f.send('pointerdown',a,[a]);assert.equal(f.features[0].getGeometry().getCoordinates().length,4);assert.deepEqual(coordinates(f),before);f.send('pointerdown',b,[a,b]);assert.deepEqual(f.features[0].getGeometry().getCoordinates(),before);
  f.send('pointerup',{...b,buttons:0},[a]);const remaining=f.send('pointerdrag',{...a,clientX:230,button:-1},[a]);assert.equal(f.input.edit(remaining),false);f.send('pointerup',{...a,buttons:0},[]);await f.flush();assert.equal(f.commits,0);assert.deepEqual(coordinates(f),before);
  drag(f,'pen');await f.flush();assert.equal(f.commits,1);assert.notDeepEqual(coordinates(f),before);f.close();
});

test('2D View rejects rotation and its actual interaction collection omits both rotation gestures',()=>{
  const f=fixture('select'),interactions=f.navigation.getArray();assert.ok(interactions.some(value=>value instanceof DragPan));assert.ok(interactions.some(value=>value instanceof PinchZoom));assert.ok(!interactions.some(value=>value instanceof PinchRotate||value instanceof DragRotate));
  f.map.view.setRotation(Math.PI/3);assert.equal(f.map.view.getRotation(),0);f.map.view.adjustRotation(.6);assert.equal(f.map.view.getRotation(),0);f.close();
});
test('real Graticule label styles place longitude above the bottom and latitude inside the right edge',()=>{
  const grid=gisGraticule(),feature=new Feature({graticule_label:'151°30′E'}),lon=grid.lonLabelStyle_(feature).getText(),lat=grid.latLabelStyle_(feature).getText();
  const extent=[0,0,400,300],lonPoint=grid.getMeridianPoint_(new LineString([[200,-20],[200,320]]),extent,0),latPoint=grid.getParallelPoint_(new LineString([[-20,150],[420,150]]),extent,0);
  assert.equal(lon.getTextBaseline(),'bottom');assert.equal(lon.getOffsetY(),-8);assert.equal(300-lonPoint.getCoordinates()[1]+lon.getOffsetY(),292);
  assert.equal(lat.getTextAlign(),'right');assert.equal(lat.getOffsetX(),-8);assert.equal(latPoint.getCoordinates()[0]+lat.getOffsetX(),392);
  assert.equal(lon.getStroke().getWidth(),3);assert.equal(lat.getStroke().getWidth(),3);assert.equal(lon.getFont(),'12px Calibri,sans-serif');grid.dispose();
});
