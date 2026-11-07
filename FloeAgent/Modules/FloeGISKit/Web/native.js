// SPDX-License-Identifier: MPL-2.0
// A small presentation projection of the same GIS document and typed registry.
// Geometry, raster samples and offline tile bytes never cross this UI boundary.
import { clone, finite, t } from '../../FloeHeavyEditorSupport/Web/runtime.js';
import { getLayer, inferFields, field, layerField } from './model.js';
import { legendEntries } from './symbology.js';
export const GIS_TABLE_PAGE_SIZE=25;
export function gisUI(e){return e.gisUI??={mode:'map',tool:'select',multiselect:false,snapping:true,page:0,filter:'',sort:'',sortDescending:false,onlySelected:false,columns:null,terrainFactor:1,vertexAction:null,drawing:false};}
const textValue=(value,type)=>type==='json'||typeof value==='object'?JSON.stringify(value??null):String(value??'');
function cell(name,type,value,limit){const complete=textValue(value,type);let text=complete.slice(0,limit);if(text.length<complete.length&&/[\uD800-\uDBFF]$/.test(text))text=text.slice(0,-1);return {name,type,text,truncated:text.length<complete.length,isNull:value===null};}
const pick=(source,keys)=>Object.fromEntries(keys.filter(key=>Object.hasOwn(source??{},key)).map(key=>[key,clone(source[key])]));
function styleSnapshot(style={}){const result={};for(const key of ['color','fill','mode','field','label','palette'])if(typeof style[key]==='string')result[key]=style[key];for(const key of ['width','radius','classes','fillOpacity','band','min','max'])if(typeof style[key]==='number'&&Number.isFinite(style[key])||['min','max'].includes(key)&&style[key]===null)result[key]=style[key];return result;}
export function gisTable(e){
  const ui=gisUI(e),layer=e.state.layers.find(l=>l.id===e.selection?.layer&&l.kind==='vector');
  if(!layer)return {layerID:null,fields:[],columns:[],rows:[],total:0,filteredCount:0,page:0,pageSize:GIS_TABLE_PAGE_SIZE,pageCount:0,filter:ui.filter,sort:ui.sort,sortDescending:ui.sortDescending,onlySelected:ui.onlySelected};
  const fields=inferFields(layer.data.features,layer.fields),ids=new Set((e.selection?.features??[]).map(String));
  const selected=Array.isArray(ui.columns)?ui.columns.filter(name=>fields.some(f=>f.name===name)):fields.slice(0,8).map(f=>f.name),columns=selected.slice(0,12).map(name=>fields.find(f=>f.name===name));
  let features=layer.data.features.filter(f=>(!ui.onlySelected||ids.has(String(f.id)))&&(!ui.filter||JSON.stringify(f.properties).toLocaleLowerCase().includes(ui.filter.toLocaleLowerCase())));
  if(ui.sort)features=[...features].sort((a,b)=>String(a.properties[ui.sort]??'').localeCompare(String(b.properties[ui.sort]??''),undefined,{numeric:true})*(ui.sortDescending?-1:1));
  const pageCount=Math.ceil(features.length/GIS_TABLE_PAGE_SIZE),page=Math.max(0,Math.min(Math.trunc(finite(ui.page)),pageCount-1)),start=page*GIS_TABLE_PAGE_SIZE;
  return {layerID:layer.id,fields,columns,rows:features.slice(start,start+GIS_TABLE_PAGE_SIZE).map(f=>({id:String(f.id),rawID:f.id,selected:ids.has(String(f.id)),cells:columns.map(field=>cell(field.name,field.type,f.properties[field.name],256))})),total:layer.data.features.length,filteredCount:features.length,page,pageSize:GIS_TABLE_PAGE_SIZE,pageCount,filter:ui.filter,sort:ui.sort,sortDescending:ui.sortDescending,onlySelected:ui.onlySelected};
}
export function gisNativeSnapshot(e){
  const ui=gisUI(e),layers=e.state.layers.map((l,index)=>({id:l.id,name:l.name,kind:l.kind,group:l.group??'',index,visible:l.visible!==false,locked:Boolean(l.locked),opacity:l.opacity??1,crs:l.crs,count:l.kind==='vector'?l.data.features.length:l.kind==='tiles'?l.tileCount:undefined,width:l.width,height:l.height,bandCount:l.bands?.length}));
  const source=e.state.layers.find(l=>l.id===e.selection?.layer),summary=layers.find(l=>l.id===source?.id),selectedIDs=new Set((e.selection?.features??[]).map(String)),selected=source?.kind==='vector'?source.data.features.filter(f=>selectedIDs.has(String(f.id))):[],fields=source?.kind==='vector'?inferFields(source.data.features,source.fields):[];
  const groups=[...new Set(layers.map(l=>l.group))].map(name=>{const members=layers.filter(l=>l.group===name);return {id:name,name,visible:members.some(l=>l.visible),locked:members.every(l=>l.locked),layerIDs:members.map(l=>l.id)};});
  const table=gisTable(e),legend=source?legendEntries(source):[];
  const terrain=e.state.layers.find(l=>l.id===source?.id&&l.kind==='raster')??e.state.layers.find(l=>l.kind==='raster');
  return {kind:'gis',crs:e.state.crs,ui:{...clone(ui),page:table.page},layers,groups,selectedLayer:source?{...summary,style:styleSnapshot(source.style),fields,legend:legend.slice(0,20),legendCount:legend.length}:null,
    selection:{layerID:source?.id??null,featureIDs:selected.map(f=>String(f.id)),count:selected.length,features:selected.slice(0,4).map(f=>({id:String(f.id),rawID:f.id,name:String(f.properties.name??f.id),geometryType:f.geometry?.type??null,attributes:fields.slice(0,24).map(field=>cell(field.name,field.type,f.properties[field.name],512)),attributeCount:fields.length})),hasClipboard:Boolean(e.gisClipboard?.features?.length)},
    table,bookmarks:e.state.bookmarks.map(b=>({id:b.id,name:b.name})),layout:{...pick(e.state.layout,['title','paper','orientation','legend','north','scale','scaleDenominator']),annotationCount:e.state.layout.annotations?.length??0},view:pick(e.liveView??e.state.view,['center','zoom','extent','extentCRS','fit']),terrain:{layerID:terrain?.id??null,name:terrain?.name??'',factor:ui.terrainFactor}};
}
export function registerGISUI(e,currentView=()=>null){
  const add=(id,title,fields,handler)=>e.register({id:'gis.ui.'+id,title,group:t('地图界面','Map interface'),access:'read',sideEffecting:true,hidden:true,fields},handler);
  const redraw=kind=>{e.gisRenderHint=kind;e.notifyPresentation?.();};
  add('mode',t('切换地图视图','Change map view'),[field('mode',t('视图','View'),'select',{options:['map','table','terrain','layout']})],a=>{if(!['map','table','terrain','layout'].includes(a.mode))throw new Error('Unknown map view');gisUI(e).mode=a.mode;gisUI(e).drawing=false;gisUI(e).vertexAction=null;redraw('full');return {mode:a.mode};});
  add('tool',t('选择地图工具','Choose map tool'),[field('tool',t('工具','Tool'),'select',{options:['select','Point','LineString','Polygon','modify','translate']})],a=>{if(!['select','Point','LineString','Polygon','modify','translate'].includes(a.tool))throw new Error('Unknown map tool');gisUI(e).tool=a.tool;gisUI(e).vertexAction=null;gisUI(e).drawing=false;redraw('full');return {tool:a.tool};});
  add('options',t('地图选择与捕捉','Map selection & snapping'),[field('multiselect',t('多选','Multi-select'),'checkbox'),field('snapping',t('捕捉','Snap'),'checkbox')],a=>{const ui=gisUI(e);for(const key of ['multiselect','snapping'])if(key in a){if(typeof a[key]!=='boolean')throw new Error('Invalid map option');ui[key]=a[key];}redraw('full');return {multiselect:ui.multiselect,snapping:ui.snapping};});
  add('selectLayer',t('选择图层','Select layer'),[layerField()],a=>{const layer=getLayer(e,a.layer);e.selection={layer:layer.id,features:[]};gisUI(e).page=0;gisUI(e).columns=null;gisUI(e).filter='';gisUI(e).sort='';redraw('full');return {layerID:layer.id};});
  add('selection',t('选择地图要素','Select map features'),[layerField(),field('features',t('要素编号','Feature IDs'),'json')],a=>{if(!Array.isArray(a.features))throw new Error('Feature IDs must be an array');const previous=e.selection?.layer,layer=getLayer(e,a.layer,'vector'),wanted=new Set(a.features.map(String));e.selection={layer:layer.id,features:layer.data.features.filter(f=>wanted.has(String(f.id))).map(f=>f.id)};redraw(previous===layer.id&&gisUI(e).tool!=='modify'?'selection':'full');return {count:e.selection.features.length};});
  add('table',t('属性表视图','Attribute table view'),[field('filter',t('筛选属性','Filter attributes')),field('sort',t('排序字段','Sort field')),field('sortDescending',t('倒序','Descending'),'checkbox'),field('onlySelected',t('只看选区','Selection only'),'checkbox'),field('columns',t('显示列','Columns'),'json'),field('page',t('页码（从0起）','Page (from 0)'),'number')],a=>{const ui=gisUI(e);for(const key of ['filter','sort'])if(key in a)ui[key]=String(a[key]).slice(0,1024);for(const key of ['sortDescending','onlySelected'])if(key in a){if(typeof a[key]!=='boolean')throw new Error('Invalid table option');ui[key]=a[key];}if('columns'in a){if(!Array.isArray(a.columns))throw new Error('Columns must be an array');ui.columns=[...new Set(a.columns.map(String))].slice(0,12);}ui.page='page'in a?Math.max(0,Math.trunc(finite(a.page))):0;ui.page=gisTable(e).page;redraw('table');return {page:ui.page};});
  add('terrain',t('地形显示','Terrain display'),[field('factor',t('高程夸大','Elevation exaggeration'),'number',{min:.1,max:20})],a=>{gisUI(e).terrainFactor=Math.max(.1,Math.min(20,finite(a.factor,1)));redraw('full');return {factor:gisUI(e).terrainFactor};});
  add('drawing',t('绘图状态','Drawing state'),[field('active',t('正在绘图','Drawing'),'checkbox')],a=>{if(typeof a.active!=='boolean')throw new Error('Invalid drawing state');gisUI(e).drawing=a.active;redraw('canvas');return {drawing:gisUI(e).drawing};});
  add('canvas',t('地图画布操作','Map canvas action'),[field('action',t('操作','Action'),'select',{options:['fitLayer','zoomIn','zoomOut','finishDrawing','abortDrawing','insertVertex','deleteVertex','clearSelection']})],a=>{
    const actions=['fitLayer','zoomIn','zoomOut','finishDrawing','abortDrawing','insertVertex','deleteVertex','clearSelection'];if(!actions.includes(a.action))throw new Error('Unknown map canvas action');const ui=gisUI(e);
    if(a.action==='clearSelection'){e.selection={layer:e.selection?.layer,features:[]};redraw(['modify','translate'].includes(ui.tool)?'full':'selection');return {cleared:true};}
    if(a.action==='insertVertex'||a.action==='deleteVertex'){ui.vertexAction=a.action==='insertVertex'?'insert':'delete';redraw('canvas');return {vertexAction:ui.vertexAction};}
    const view=currentView();if(!view)throw new Error(t('地图尚未打开。','The map is not open.'));view.nativeCanvasAction(a.action);redraw('canvas');return {action:a.action};
  });
}
