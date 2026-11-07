// SPDX-License-Identifier: MPL-2.0
import proj4 from 'proj4';
import { along } from '@turf/along';
import { area } from '@turf/area';
import { bbox } from '@turf/bbox';
import { booleanContains } from '@turf/boolean-contains';
import { booleanDisjoint } from '@turf/boolean-disjoint';
import { booleanIntersects } from '@turf/boolean-intersects';
import { booleanPointInPolygon } from '@turf/boolean-point-in-polygon';
import { booleanValid } from '@turf/boolean-valid';
import { booleanWithin } from '@turf/boolean-within';
import { buffer } from '@turf/buffer';
import { centroid } from '@turf/centroid';
import { cleanCoords } from '@turf/clean-coords';
import { convex } from '@turf/convex';
import { difference } from '@turf/difference';
import { dissolve } from '@turf/dissolve';
import { distance } from '@turf/distance';
import { intersect } from '@turf/intersect';
import { kinks } from '@turf/kinks';
import { length } from '@turf/length';
import { lineIntersect } from '@turf/line-intersect';
import { lineSplit } from '@turf/line-split';
import { nearestPointOnLine } from '@turf/nearest-point-on-line';
import { pointOnFeature } from '@turf/point-on-feature';
import { pointToLineDistance } from '@turf/point-to-line-distance';
import { polygonToLine } from '@turf/polygon-to-line';
import { simplify } from '@turf/simplify';
import { union } from '@turf/union';
import { unkinkPolygon } from '@turf/unkink-polygon';
import { coordEach, flattenEach, segmentEach } from '@turf/meta';
import { point, lineString, multiLineString, multiPoint, polygon } from '@turf/helpers';
import { clone, uid, t, finite, required } from '../../FloeHeavyEditorSupport/Web/runtime.js';
export { proj4 };
export const turf={along, area, bbox, booleanContains, booleanDisjoint, booleanIntersects, booleanPointInPolygon, booleanValid, booleanWithin, buffer, centroid, cleanCoords, convex, difference, dissolve, distance, intersect, kinks, length, lineIntersect, lineSplit, nearestPointOnLine, pointOnFeature, pointToLineDistance, polygonToLine, simplify, union, unkinkPolygon, coordEach, flattenEach, segmentEach, point, lineString, multiLineString, multiPoint, polygon};
export function createGIS() {
  return { title:t('新地图','New map'),crs:'EPSG:4326',layers:[],bookmarks:[],view:{center:[0,20],zoom:2},layout:{title:'',paper:'A4',legend:true,north:true,scale:true},definitions:{} };
}
export function normalizeGIS(state) {
  state.layers ??= []; state.bookmarks ??= []; state.view ??= {center:[0,20],zoom:2}; state.layout ??= {}; state.crs ??= 'EPSG:4326'; state.definitions ??= {};
  state.title=String(state.title??t('新地图','New map'));
  for(const [key,value] of Object.entries(state.definitions)) proj4.defs(key,value);
  defineCRS(state.crs);
  if(!Array.isArray(state.layers))throw new Error('Invalid project layers');
  const ids=new Set();
  for(const layer of state.layers) {
    layer.id ??= uid();if(ids.has(layer.id))layer.id=uid();ids.add(layer.id);
    layer.visible ??= true;layer.locked ??= false;layer.opacity=Math.max(0,Math.min(1,numeric(layer.opacity??1,'opacity')));layer.crs=defineCRS(layer.crs??state.crs);layer.group=String(layer.group??'');layer.name=String(layer.name??t('图层','Layer'));layer.style??={};
    for(const key of ['width','radius','classes','band','min','max','fillOpacity'])if(layer.style[key]!==undefined&&layer.style[key]!==null)layer.style[key]=numeric(layer.style[key],key);
    if(/^#[0-9a-f]{8}$/i.test(layer.style.fill)){layer.style.fillOpacity??=parseInt(layer.style.fill.slice(7,9),16)/255;layer.style.fill=layer.style.fill.slice(0,7);}
    if(layer.style.fillOpacity!==undefined)layer.style.fillOpacity=Math.max(0,Math.min(1,layer.style.fillOpacity));
    if(layer.style.width!==undefined)layer.style.width=Math.max(0,layer.style.width);
    if(layer.style.radius!==undefined)layer.style.radius=Math.max(1,layer.style.radius);
    for(const key of ['color','fill'])if(layer.style[key]!==undefined&&!/^#[0-9a-f]{6}(?:[0-9a-f]{2})?$/i.test(layer.style[key]))throw new Error('Invalid style color');
    if(layer.kind==='vector'){
      if(!Array.isArray(layer.data?.features))throw new Error('Invalid vector layer');
      layer.data=featureCollection(layer.data.features.map(normalizeFeature));deduplicateIDs(layer.data.features);layer.fields=inferFields(layer.data.features,layer.fields);
    }else if(layer.kind==='raster'){layer.nodata??=-9999;validateRaster(layer);}
    else if(layer.kind==='tiles'){if(typeof layer.base64!=='string'||!layer.metadata)throw new Error('Invalid offline tile layer');for(const key of ['minzoom','maxzoom'])if(layer.metadata[key]!==undefined&&(!Number.isInteger(Number(layer.metadata[key]))||Number(layer.metadata[key])<0||Number(layer.metadata[key])>22))throw new Error('Invalid tile zoom');}
    else throw new Error('Unknown layer type');
  }
  for(const view of [state.view,...state.bookmarks]){if(!Array.isArray(view.center)||view.center.length!==2||!view.center.every(Number.isFinite))throw new Error('Invalid map center');view.zoom=numeric(view.zoom??2,'zoom');if(view.extent&&(!Array.isArray(view.extent)||view.extent.length!==4||!view.extent.every(Number.isFinite)||view.extent[0]>=view.extent[2]||view.extent[1]>=view.extent[3]))throw new Error('Invalid map extent');}
  if(state.layout.scaleDenominator!==undefined)state.layout.scaleDenominator=Math.max(0,numeric(state.layout.scaleDenominator,'scale'));
  for(const annotation of state.layout.annotations??[]){annotation.x=numeric(annotation.x,'annotation X');annotation.y=numeric(annotation.y,'annotation Y');annotation.size=Math.max(8,Math.min(72,numeric(annotation.size??16,'font size')));annotation.text=String(annotation.text??'');}
}
function numeric(value,name){if(typeof value!=='number'||!Number.isFinite(value))throw new Error('Invalid numeric '+name);return value;}
export function defineCRS(code, definition) {
  code=String(code).trim().toUpperCase();
  if(definition) proj4.defs(code,definition);
  if(!proj4.defs(code) && /^EPSG:(326|327)\d{2}$/.test(code)) {
    const epsg=Number(code.slice(5)),zone=epsg%100;
    if(zone>=1&&zone<=60) proj4.defs(code,`+proj=utm +zone=${zone} ${epsg>=32700?'+south':''} +datum=WGS84 +units=m +no_defs`);
  }
  required(proj4.defs(code),t('请提供这个坐标系的定义。','Provide a definition for this coordinate system.'));
  return code;
}
export function transformGeometry(geometry,from,to) {
  if(!geometry||from===to)return clone(geometry);
  defineCRS(from);defineCRS(to);
  if(geometry.type==='GeometryCollection')return {...geometry,geometries:geometry.geometries.map(g=>transformGeometry(g,from,to))};
  const visit=coordinates=>typeof coordinates[0]==='number'? [...transformPosition(coordinates,from,to),...coordinates.slice(2)]:coordinates.map(visit);
  return {...geometry,coordinates:visit(geometry.coordinates)};
}
export const WEB_RADIUS=6378137,WEB_HALF=Math.PI*WEB_RADIUS;
export function transformPosition(position,from,to){
  if(from===to)return position.slice(0,2);
  if(from==='EPSG:4326'&&to==='EPSG:3857')return [position[0]*WEB_HALF/180,Math.log(Math.tan(Math.PI/4+Math.max(-85.05112878,Math.min(85.05112878,position[1]))*Math.PI/360))*WEB_RADIUS];
  if(from==='EPSG:3857'&&to==='EPSG:4326')return [position[0]/WEB_HALF*180,(2*Math.atan(Math.exp(position[1]/WEB_RADIUS))-Math.PI/2)*180/Math.PI];
  return proj4(from,to,position.slice(0,2));
}
export function projectedBounds(bounds,from,to,steps=24){
  const points=[];for(let i=0;i<=steps;i++){const s=i/steps;points.push([bounds[0]+s*(bounds[2]-bounds[0]),bounds[1]],[bounds[0]+s*(bounds[2]-bounds[0]),bounds[3]],[bounds[0],bounds[1]+s*(bounds[3]-bounds[1])],[bounds[2],bounds[1]+s*(bounds[3]-bounds[1])]);}
  const p=points.map(c=>transformPosition(c,from,to));if(p.some(c=>!c.every(Number.isFinite)))throw new Error('Projection is undefined over this extent');return [Math.min(...p.map(c=>c[0])),Math.min(...p.map(c=>c[1])),Math.max(...p.map(c=>c[0])),Math.max(...p.map(c=>c[1]))];
}
export function unwrapGeometry(geometry,anchor){
  if(!geometry)return null;
  if(geometry.type==='GeometryCollection')return {...geometry,geometries:geometry.geometries.map(g=>unwrapGeometry(g,anchor))};
  let first=geometry.coordinates;while(Array.isArray(first?.[0]))first=first[0];anchor??=first?.[0];
  const sequence=positions=>{let previous=anchor??positions[0]?.[0];return positions.map(c=>{let lon=c[0];while(lon-previous>180)lon-=360;while(lon-previous< -180)lon+=360;previous=lon;return [lon,...c.slice(1)];});};
  const depth={Point:0,MultiPoint:1,LineString:1,MultiLineString:2,Polygon:2,MultiPolygon:3}[geometry.type];
  const visit=(c,n)=>n===0?sequence([c])[0]:n===1?sequence(c):c.map(part=>visit(part,n-1));
  return {...geometry,coordinates:visit(geometry.coordinates,depth)};
}
export function inferFields(features,existing=[]){
  const fields=new Map((existing??[]).map(f=>[f.name,{...f}]));
  const types=new Map();for(const f of features)for(const [name,value]of Object.entries(f.properties??{})){propertyName(name);if(value!==null&&value!==undefined){if(!types.has(name))types.set(name,new Set());types.get(name).add(typeof value==='object'?'json':typeof value);}if(!fields.has(name))fields.set(name,{name,type:'string',nullable:true});}
  for(const [name,variants]of types){const field=fields.get(name);field.type=variants.size>1?'json':[...variants][0];}
  for(const field of fields.values()){propertyName(field.name);if(!['string','number','boolean','json'].includes(field.type))throw new Error('Invalid field type');}
  return [...fields.values()];
}
function deduplicateIDs(features){const ids=new Set();for(const f of features){if(ids.has(String(f.id)))f.id=uid();ids.add(String(f.id));}}
export function propertyName(name){name=String(name??'').trim();if(!name||['__proto__','constructor','prototype'].includes(name))throw new Error(t('请使用有效的字段名。','Use a valid field name.'));return name;}
export function attributeValue(value,type){
  if(value===null)return null;
  if(type==='number'){if(value===''||!Number.isFinite(Number(value)))throw new Error(t('请输入数字。','Enter a number.'));return Number(value);}
  if(type==='boolean'){if([true,'true','1',1].includes(value))return true;if([false,'false','0',0].includes(value))return false;throw new Error(t('请输入 true 或 false。','Enter true or false.'));}
  if(type==='json')return typeof value==='string'?JSON.parse(value):clone(value);
  return String(value??'');
}
export function featureCollection(features=[]) { return {type:'FeatureCollection',features}; }
export function vectorLayer(name,features=[],crs='EPSG:4326') {
  features=features.map(normalizeFeature);deduplicateIDs(features);
  return {id:uid(),name,kind:'vector',crs:defineCRS(crs),visible:true,locked:false,opacity:1,group:'',style:{color:'#2879c7',fill:'#2879c7',fillOpacity:.2,width:2,radius:5,label:'',mode:'single',field:'',classes:5},fields:inferFields(features),data:featureCollection(features)};
}
export function normalizeFeature(feature) {
  if(feature.type!=='Feature')feature={type:'Feature',properties:{},geometry:feature};
  const copy=clone(feature);copy.id??=uid();copy.properties??={};
  if(!['string','number'].includes(typeof copy.id)||typeof copy.id==='number'&&!Number.isFinite(copy.id))throw new Error('Invalid feature ID');
  if(typeof copy.properties!=='object'||Array.isArray(copy.properties))throw new Error('Feature properties must be an object');
  for(const name of Object.keys(copy.properties))propertyName(name);
  if(copy.geometry)validateGeometry(copy.geometry);
  return copy;
}
export function validateGeometry(geometry) {
  const allowed=['Point','MultiPoint','LineString','MultiLineString','Polygon','MultiPolygon','GeometryCollection'];
  if(!allowed.includes(geometry.type))throw new Error(t('不支持的几何类型。','Unsupported geometry type.'));
  if(geometry.type==='GeometryCollection') {if(!Array.isArray(geometry.geometries))throw new Error('Invalid geometry collection');geometry.geometries.forEach(validateGeometry);return;}
  const position=c=>{if(!Array.isArray(c)||c.length<2||c.length>4||!c.every(Number.isFinite))throw new Error('Invalid geometry coordinate');};
  const line=c=>{if(!Array.isArray(c)||c.length<2)throw new Error('A line requires at least two vertices');c.forEach(position);};
  const ring=c=>{line(c);if(c.length<4||c[0].length!==c.at(-1).length||c[0].some((v,i)=>v!==c.at(-1)[i]))throw new Error('A polygon ring requires three vertices and a matching closing vertex');};
  const polygon=c=>{if(!Array.isArray(c)||!c.length)throw new Error('A polygon requires an exterior ring');c.forEach(ring);};
  const many=(c,fn)=>{if(!Array.isArray(c))throw new Error('Invalid geometry coordinates');c.forEach(fn);};
  ({Point:position,MultiPoint:c=>many(c,position),LineString:line,MultiLineString:c=>many(c,line),Polygon:polygon,MultiPolygon:c=>many(c,polygon)})[geometry.type](geometry.coordinates);
}
export function selectedFeatures(e,layer,args={}){const ids=new Set((args.features??(e.selection?.layer===layer.id?e.selection.features:[])??[]).map(String));return layer.data.features.filter(f=>ids.has(String(f.id)));}
export const layerOptions=e=>e.state.layers.map(layer=>({value:layer.id,label:layer.name}));
export const selectedLayer=e=>e.selection?.layer??e.state.layers.find(l=>l.kind==='vector')?.id??e.state.layers[0]?.id??'';
export function getLayer(e,id,kind) { const layer=required(e.state.layers.find(l=>l.id===(id||selectedLayer(e))),t('请选择一个图层。','Choose a layer.'));if(kind&&layer.kind!==kind)throw new Error(t('图层类型不适合这项操作。','The layer type does not support this action.'));return layer; }
export function editable(layer) {if(layer.locked)throw new Error(t('请先解锁这个图层。','Unlock this layer first.'));return layer;}
export function getFeature(e,args) {const layer=editable(getLayer(e,args.layer,'vector'));const id=args.feature??e.selection?.features?.[0];return {layer,feature:required(layer.data.features.find(f=>String(f.id)===String(id)),t('请选择一个要素。','Choose a feature.'))};}
export function inGeographic(layer) {return featureCollection(layer.data.features.map(f=>({...clone(f),geometry:unwrapGeometry(transformGeometry(f.geometry,layer.crs,'EPSG:4326'))})));}
export function analysisLayer(e,name,collection,crs='EPSG:4326') {const layer=vectorLayer(name,collection.type==='FeatureCollection'?collection.features:[collection],crs);e.state.layers.push(layer);e.selection={layer:layer.id,features:[]};return {layerID:layer.id,count:layer.data.features.length};}
export function rasterLayer(name,grid,width,height,bounds,crs='EPSG:4326',nodata=-9999) {
  if(!Number.isFinite(nodata)){const values=new Set(grid);nodata=[-3.4028234663852886e38,-1.7014117331926443e38,-8.5070586659632215e37].find(n=>!values.has(n));if(nodata===undefined)throw new Error('Unable to choose a finite nodata marker');grid=Array.from(grid,v=>Number.isFinite(v)?v:nodata);}
  const layer={id:uid(),name,kind:'raster',width,height,bands:[Array.from(grid)],bounds,crs:defineCRS(crs),nodata,visible:true,locked:false,opacity:1,style:{palette:'terrain',band:0,min:null,max:null},group:''};validateRaster(layer);return layer;
}
export function validateRaster(layer){if(typeof layer.nodata!=='number'||!Number.isFinite(layer.nodata))throw new Error('Invalid raster nodata marker');if(!Number.isInteger(layer.width)||!Number.isInteger(layer.height)||layer.width<1||layer.height<1||layer.width*layer.height>16_777_216||!Array.isArray(layer.bands)||!layer.bands.length||layer.bands.some(b=>!Array.isArray(b)||b.length!==layer.width*layer.height||b.some(v=>typeof v!=='number'||!Number.isFinite(v))))throw new Error('Invalid raster dimensions');if(!Array.isArray(layer.bounds)||layer.bounds.length!==4||!layer.bounds.every(Number.isFinite)||layer.bounds[0]>=layer.bounds[2]||layer.bounds[1]>=layer.bounds[3])throw new Error('Invalid raster bounds');}
export function gridLocation(layer,column,row) {return [layer.bounds[0]+(column+.5)*(layer.bounds[2]-layer.bounds[0])/layer.width,layer.bounds[3]-(row+.5)*(layer.bounds[3]-layer.bounds[1])/layer.height];}
export function gridSample(layer,x,y,band=0,method='nearest') {
  const col=(x-layer.bounds[0])/(layer.bounds[2]-layer.bounds[0])*layer.width-.5,row=(layer.bounds[3]-y)/(layer.bounds[3]-layer.bounds[1])*layer.height-.5;
  if(!layer.bands[band]||col<-.5||row<-.5||col>layer.width-.5||row>layer.height-.5)return layer.nodata;
  const read=(c,r)=>layer.bands[band][Math.max(0,Math.min(layer.height-1,r))*layer.width+Math.max(0,Math.min(layer.width-1,c))];
  if(method==='nearest')return read(Math.round(col),Math.round(row));
  const c=Math.floor(col),r=Math.floor(row),a=col-c,b=row-r,values=[read(c,r),read(c+1,r),read(c,r+1),read(c+1,r+1)];
  if(values.some(v=>v===layer.nodata||!Number.isFinite(v)))return layer.nodata;
  return values[0]*(1-a)*(1-b)+values[1]*a*(1-b)+values[2]*(1-a)*b+values[3]*a*b;
}
export function sampleGIS() {
  const state=createGIS();state.title=t('地理信息样例','GIS sample');state.view={center:[151.18,-33.88],zoom:13};
  state.layers.push(vectorLayer(t('分区','Districts'),[
    turf.polygon([[[151.15,-33.9],[151.18,-33.9],[151.18,-33.87],[151.15,-33.87],[151.15,-33.9]]],{name:'West',population:1200}),
    turf.polygon([[[151.18,-33.9],[151.21,-33.9],[151.21,-33.87],[151.18,-33.87],[151.18,-33.9]]],{name:'East',population:1800})]));
  state.layers.push(vectorLayer(t('站点','Sites'),[turf.point([151.165,-33.885],{name:'A',value:12}),turf.point([151.19,-33.88],{name:'B',value:21}),turf.point([151.2,-33.895],{name:'C',value:31})]));
  state.layers.push(vectorLayer(t('道路','Roads'),[turf.lineString([[151.15,-33.885],[151.18,-33.885],[151.21,-33.885]],{name:'Main'}),turf.lineString([[151.18,-33.9],[151.18,-33.885],[151.18,-33.87]],{name:'Cross'})]));
  const width=48,height=48,grid=Array.from({length:width*height},(_,i)=>80+60*Math.sin((i%width)/9)*Math.cos(Math.floor(i/width)/11)+Math.floor(i/width));
  state.layers.push(rasterLayer(t('高程','Elevation'),grid,width,height,[151.145,-33.905,151.215,-33.865]));return state;
}
const optionText={single:['单色','Single symbol'],categorical:['分类','Categories'],graduated:['分级','Graduated'],set:['设置','Set'],insert:['插入','Insert'],delete:['删除','Delete'],add:['添加','Add'],rename:['重命名','Rename'],convert:['转换类型','Convert type'],string:['文本','Text'],number:['数字','Number'],boolean:['是／否','Boolean'],json:['JSON','JSON'],area:['面积','Area'],length:['长度','Length'],centroidX:['中心经度','Center longitude'],centroidY:['中心纬度','Center latitude'],subtract:['减去','Subtract'],multiply:['乘以','Multiply'],divide:['除以','Divide'],equals:['等于','Equals'],contains:['包含','Contains'],greater:['大于','Greater than'],less:['小于','Less than'],notEqual:['不等于','Does not equal'],isNull:['空值','Is null'],intersects:['相交','Intersects'],within:['在内部','Within'],disjoint:['不相交','Disjoint'],nearest:['最近邻','Nearest'],bilinear:['双线性','Bilinear'],equal:['等间隔','Equal interval'],quantile:['分位数','Quantile'],threshold:['阈值','Threshold'],bufferZero:['修复面边界','Repair polygon boundaries'],unkink:['拆分自交面','Split self-intersections'],clean:['清理重复节点','Clean duplicate vertices'],terrain:['地形','Terrain'],gray:['灰度','Grayscale'],classes:['分类','Classes'],rgb:['RGB','RGB'],landscape:['横向','Landscape'],portrait:['纵向','Portrait'],Point:['点','Point'],MultiPoint:['多点','MultiPoint'],LineString:['线','LineString'],MultiLineString:['多线','MultiLineString'],Polygon:['面','Polygon'],MultiPolygon:['多面','MultiPolygon']};
export const field=(key,label,type='text',extra={})=>({...{key,label,type,...extra},...(Array.isArray(extra.options)?{options:extra.options.map(o=>typeof o==='string'&&optionText[o]?{value:o,label:t(...optionText[o])}:o)}:{})});
export const layerField=(key='layer',label=t('图层','Layer'))=>field(key,label,'select',{options:layerOptions,default:selectedLayer});
function changeVertex(geometry,args){
  const copy=clone(geometry),parts=String(args.path??'').split('/');let target=copy;
  while(parts[0]?.startsWith('g')){const n=Number(parts.shift().slice(1));target=required(target.geometries?.[n],'Invalid collection path');}
  if(target.type==='Point'){if(args.action!=='set')throw new Error('A point has a single vertex');target.coordinates=[Number(args.x),Number(args.y),...target.coordinates.slice(2)];validateGeometry(copy);return copy;}
  const path=parts.join('/').split(',').map(Number);if(!path.length||path.some(v=>!Number.isInteger(v)||v<0))throw new Error('Invalid vertex path');
  let parent=target.coordinates;for(const n of path.slice(0,-1))parent=required(parent?.[n],'Invalid vertex path');
  let n=path.at(-1);if(!Array.isArray(parent)||!parent.length||!Array.isArray(parent[0])||!Number.isFinite(parent[0][0]))throw new Error('Choose a vertex in a line, ring or multipoint');
  const rings=[];const collect=g=>{if(g.type==='Polygon')rings.push(...g.coordinates);else if(g.type==='MultiPolygon')g.coordinates.forEach(p=>rings.push(...p));else if(g.type==='GeometryCollection')g.geometries.forEach(collect);};collect(copy);
  const closed=rings.includes(parent),limit=parent.length-(closed?1:0);if(n>=parent.length)throw new Error('Vertex index is outside the geometry');if(closed&&n===limit)n=0;
  if(args.action==='delete'){if(closed&&limit<=3)throw new Error('A ring needs at least three vertices');parent.splice(n,1);}
  else {if(!Number.isFinite(Number(args.x))||!Number.isFinite(Number(args.y)))throw new Error('Invalid vertex coordinate');const value=[Number(args.x),Number(args.y),...(parent[n]?.slice(2)??[])];if(args.action==='insert')parent.splice(n,0,value);else parent[n]=value;}
  if(closed)parent[parent.length-1]=clone(parent[0]);validateGeometry(copy);return copy;
}
function mapGeometry(geometry,fn){if(!geometry)return null;if(geometry.type==='GeometryCollection')return {...geometry,geometries:geometry.geometries.map(g=>mapGeometry(g,fn))};const visit=c=>typeof c[0]==='number'?fn(c):c.map(visit);return {...geometry,coordinates:visit(geometry.coordinates)};}
export function registerModelCommands(e) {
  const add=(id,title,fields,handler,group=t('图层与编辑','Layers & editing'),access='edit')=>e.register({id,title,fields,group,access},handler);
  const chosen=(a,allowEmpty=false)=>{const layer=getLayer(e,a.layer,'vector'),features=selectedFeatures(e,layer,a);if(!allowEmpty&&!features.length)throw new Error(t('请先选择要素。','Select features first.'));return {layer,features};};
  add('project.sample',t('载入完整样例','Load complete sample'),[],()=>{e.state=e.payload.data=sampleGIS();e.liveView=null;e.selection={layer:e.state.layers[0].id,features:[]};});
  add('project.crs',t('设置坐标系','Set coordinate system'),[field('crs',t('坐标系','CRS'),'text',{default:'EPSG:3857'}),field('definition',t('自定义定义','Custom definition'),'textarea')],a=>{const crs=defineCRS(a.crs,a.definition);if(a.definition)e.state.definitions[crs]=a.definition;e.state.crs=crs;return {crs};},t('工程','Project'));
  add('project.view',t('设置地图范围','Set map extent'),[field('bounds',t('西、南、东、北（经纬度）','West, south, east, north (degrees)'),'text',{default:'151.14,-33.91,151.22,-33.86'})],a=>{const bounds=Array.isArray(a.bounds)?a.bounds:String(a.bounds).split(/[,\s]+/).map(Number);if(bounds.length!==4||!bounds.every(Number.isFinite)||bounds[0]>=bounds[2]||bounds[1]>=bounds[3]||bounds[1]<-85||bounds[3]>85)throw new Error('Invalid geographic extent');const p=transformPosition(bounds.slice(0,2),'EPSG:4326','EPSG:3857'),q=transformPosition(bounds.slice(2),'EPSG:4326','EPSG:3857');e.state.view=e.liveView={center:[(bounds[0]+bounds[2])/2,(bounds[1]+bounds[3])/2],zoom:2,extent:[...p,...q],fit:true};return {bounds};},t('工程','Project'));
  add('project.bookmark',t('保存视图书签','Bookmark view'),[field('name',t('名称','Name'))],a=>{e.state.bookmarks.push({...clone(e.liveView??e.state.view),id:uid(),name:a.name||t('视图','View')});},t('工程','Project'));
  add('project.bookmarkOpen',t('打开视图书签','Open bookmark'),[field('bookmark',t('书签','Bookmark'),'select',{options:e=>e.state.bookmarks.map(b=>({value:b.id,label:b.name}))})],a=>{e.liveView={...clone(required(e.state.bookmarks.find(b=>b.id===a.bookmark),'Unknown bookmark')),fit:true};},t('工程','Project'),'read');
  add('project.bookmarkDelete',t('删除视图书签','Delete bookmark'),[field('bookmark',t('书签','Bookmark'),'select',{options:e=>e.state.bookmarks.map(b=>({value:b.id,label:b.name}))})],a=>{e.state.bookmarks=e.state.bookmarks.filter(b=>b.id!==a.bookmark);},t('工程','Project'));
  add('layer.create',t('新建矢量图层','New vector layer'),[field('name',t('名称','Name'),'text',{default:t('新图层','New layer')}),field('crs',t('坐标系','CRS'),'text',{default:e=>e.state.crs})],a=>{const layer=vectorLayer(a.name,[],defineCRS(a.crs||e.state.crs));e.state.layers.push(layer);e.selection={layer:layer.id,features:[]};return {layerID:layer.id};});
  add('layer.properties',t('图层属性与分组','Layer properties & group'),[layerField(),field('name',t('名称','Name')),field('group',t('分组','Group')),field('opacity',t('不透明度','Opacity'),'number',{default:1,min:0,max:1}),field('visible',t('显示','Visible'),'checkbox',{default:true}),field('locked',t('锁定','Locked'),'checkbox')],a=>{const l=getLayer(e,a.layer);if(a.name)l.name=String(a.name);if('group'in a)l.group=String(a.group);if('opacity'in a)l.opacity=Math.max(0,Math.min(1,finite(a.opacity,1)));if('visible'in a)l.visible=Boolean(a.visible);if('locked'in a)l.locked=Boolean(a.locked);});
  add('group.properties',t('修改图层组','Edit layer group'),[field('group',t('组名','Group name')),field('name',t('新组名','New group name')),field('visible',t('显示组','Show group'),'checkbox',{default:true}),field('locked',t('锁定组','Lock group'),'checkbox')],a=>{let count=0;for(const layer of e.state.layers.filter(l=>l.group===a.group)){if('name'in a)layer.group=a.name||a.group;if('visible'in a)layer.visible=Boolean(a.visible);if('locked'in a)layer.locked=Boolean(a.locked);count++;}return {count};});
  add('layer.move',t('调整图层顺序','Move layer'),[layerField(),field('index',t('位置（从0起）','Position (from 0)'),'number',{default:0})],a=>{const l=getLayer(e,a.layer),index=e.state.layers.indexOf(l);e.state.layers.splice(index,1);e.state.layers.splice(Math.max(0,Math.min(e.state.layers.length,Math.trunc(finite(a.index)))),0,l);});
  add('layer.delete',t('删除图层','Delete layer'),[layerField()],a=>{const layer=editable(getLayer(e,a.layer));e.state.layers=e.state.layers.filter(l=>l.id!==layer.id);e.selection={layer:null,features:[]};});
  add('layer.reproject',t('图层重投影','Reproject layer'),[layerField(),field('crs',t('目标坐标系','Target CRS'),'text',{default:'EPSG:3857'}),field('definition',t('自定义定义','Custom definition'),'textarea')],a=>{const layer=editable(getLayer(e,a.layer,'vector')),crs=defineCRS(a.crs,a.definition);if(a.definition)e.state.definitions[crs]=a.definition;for(const f of layer.data.features)f.geometry=transformGeometry(f.geometry,layer.crs,crs);layer.crs=crs;return {features:layer.data.features.length,crs};});
  add('layer.unwrap',t('展开跨日界线几何','Unwrap dateline geometry'),[layerField(),field('anchor',t('中心经度','Central longitude'),'number',{default:180})],a=>{const layer=getLayer(e,a.layer,'vector'),collection=inGeographic(layer);for(const f of collection.features)f.geometry=unwrapGeometry(f.geometry,finite(a.anchor,180));return analysisLayer(e,layer.name+' '+t('日界线','dateline'),collection);});
  add('feature.add',t('按坐标添加要素','Add feature by coordinates'),[layerField(),field('geometry',t('几何类型','Geometry type'),'select',{options:['Point','LineString','Polygon','MultiPoint','MultiLineString','MultiPolygon'],default:'Point'}),field('coordinates',t('坐标','Coordinates'),'textarea',{default:'[151.18,-33.88]'}),field('properties',t('属性','Attributes'),'textarea',{default:'{}'})],a=>{const layer=editable(getLayer(e,a.layer,'vector')),geometry={type:a.geometry,coordinates:typeof a.coordinates==='string'?JSON.parse(a.coordinates):a.coordinates};const feature=normalizeFeature({type:'Feature',geometry,properties:typeof a.properties==='string'?JSON.parse(a.properties||'{}'):a.properties??{}});layer.data.features.push(feature);layer.fields=inferFields(layer.data.features,layer.fields);e.selection={layer:layer.id,features:[feature.id]};return {featureID:feature.id};});
  add('feature.geometry',t('更新几何','Update geometry'),[],a=>{const {feature}=getFeature(e,a);if(a.geometry!==null)validateGeometry(a.geometry);feature.geometry=clone(a.geometry);});e.commands.get('feature.geometry').descriptor.hidden=true;
  add('feature.geometries',t('更新选中几何','Update selected geometries'),[],a=>{const changes=required(a.changes,'Geometry changes required').map(c=>{const {feature}=getFeature(e,c);if(c.geometry!==null)validateGeometry(c.geometry);return {feature,geometry:clone(c.geometry)};});for(const c of changes)c.feature.geometry=c.geometry;return {count:changes.length};});e.commands.get('feature.geometries').descriptor.hidden=true;
  add('feature.select',t('选择要素','Select features'),[layerField(),field('features',t('要素编号列表','Feature IDs'),'textarea',{default:'[]'})],a=>{const layer=getLayer(e,a.layer,'vector'),ids=typeof a.features==='string'?JSON.parse(a.features):a.features;if(!Array.isArray(ids))throw new Error('Feature IDs must be an array');const available=new Set(layer.data.features.map(f=>String(f.id)));e.selection={layer:layer.id,features:ids.filter(id=>available.has(String(id)))};return e.selection;},t('查询','Query'),'read');
  add('feature.delete',t('删除选中要素','Delete selected features'),[layerField()],a=>{const {layer,features}=chosen(a);editable(layer);const ids=new Set(features.map(f=>String(f.id)));layer.data.features=layer.data.features.filter(f=>!ids.has(String(f.id)));e.selection={layer:layer.id,features:[]};return {removed:features.length};});
  for(const action of ['copy','cut'])add('feature.'+action,action==='copy'?t('复制要素','Copy features'):t('剪切要素','Cut features'),[layerField()],a=>{const {layer,features}=chosen(a);if(action==='cut')editable(layer);e.gisClipboard={crs:layer.crs,features:clone(features),fields:clone(layer.fields)};if(action==='cut'){const ids=new Set(features.map(f=>String(f.id)));layer.data.features=layer.data.features.filter(f=>!ids.has(String(f.id)));e.selection={layer:layer.id,features:[]};}return {count:features.length};},t('图层与编辑','Layers & editing'),action==='copy'?'read':'edit');
  add('feature.paste',t('粘贴要素','Paste features'),[layerField(),field('dx',t('横向偏移（图层单位）','X offset (layer units)'),'number',{default:0}),field('dy',t('纵向偏移（图层单位）','Y offset (layer units)'),'number',{default:0})],a=>{const layer=editable(getLayer(e,a.layer,'vector')),clipboard=required(e.gisClipboard,t('请先复制要素。','Copy features first.')),copies=clipboard.features.map(f=>({...clone(f),id:uid(),geometry:mapGeometry(transformGeometry(f.geometry,clipboard.crs,layer.crs),c=>[c[0]+finite(a.dx),c[1]+finite(a.dy),...c.slice(2)])}));layer.data.features.push(...copies);layer.fields=inferFields(copies,[...layer.fields,...clipboard.fields.filter(f=>!layer.fields.some(g=>g.name===f.name))]);e.selection={layer:layer.id,features:copies.map(f=>f.id)};return {count:copies.length,featureIDs:e.selection.features};});
  add('feature.duplicate',t('创建选区副本','Duplicate selection'),[layerField()],a=>{const {layer,features}=chosen(a);editable(layer);const copies=features.map(f=>({...clone(f),id:uid()}));layer.data.features.push(...copies);e.selection={layer:layer.id,features:copies.map(f=>f.id)};return {count:copies.length};});
  add('feature.transform',t('移动／旋转／缩放','Move / rotate / scale'),[layerField(),field('dx',t('横向移动（图层单位）','Move X (layer units)'),'number',{default:0}),field('dy',t('纵向移动（图层单位）','Move Y (layer units)'),'number',{default:0}),field('rotation',t('角度','Angle'),'number',{default:0}),field('scale',t('比例','Scale'),'number',{default:1})],a=>{const {layer,features}=chosen(a);editable(layer);const located=features.filter(f=>f.geometry);if(!located.length)return {count:0};const box=turf.bbox(featureCollection(located)),center=[(box[0]+box[2])/2,(box[1]+box[3])/2],angle=finite(a.rotation)*Math.PI/180,s=finite(a.scale,1);if(s===0)throw new Error('Scale must not be zero');for(const f of located)f.geometry=mapGeometry(f.geometry,c=>[center[0]+s*((c[0]-center[0])*Math.cos(angle)-(c[1]-center[1])*Math.sin(angle))+finite(a.dx),center[1]+s*((c[0]-center[0])*Math.sin(angle)+(c[1]-center[1])*Math.cos(angle))+finite(a.dy),...c.slice(2)]);return {count:located.length};});
  add('feature.node',t('编辑几何节点','Edit geometry vertex'),[layerField(),field('feature',t('要素编号','Feature ID'),'text',{default:e=>e.selection?.features?.[0]??''}),field('path',t('节点位置','Vertex path'),'text',{default:'0,0'}),field('action',t('操作','Action'),'select',{options:['set','insert','delete'],default:'set'}),field('x',t('横坐标','X'),'number'),field('y',t('纵坐标','Y'),'number')],a=>{const {feature}=getFeature(e,a);feature.geometry=changeVertex(feature.geometry,a);});
  add('attribute.set',t('修改要素属性','Edit feature attribute'),[layerField(),field('feature',t('要素编号','Feature ID'),'text',{default:e=>e.selection?.features?.[0]??''}),field('field',t('字段','Field')),field('value',t('值','Value'),'textarea',{default:(e,a)=>{const layer=e.state.layers.find(l=>l.id===(a.layer||e.selection?.layer)),feature=layer?.data?.features.find(f=>String(f.id)===String(a.feature??e.selection?.features?.[0])),value=feature?.properties?.[a.field],type=a.type||layer?.fields?.find(f=>f.name===a.field)?.type;return type==='json'||typeof value==='object'?JSON.stringify(value??null):String(value??'');}}),field('type',t('类型（可留空）','Type (optional)'),'select',{options:['','string','number','boolean','json'],default:''})],a=>{const {layer,feature}=getFeature(e,a),name=propertyName(a.field),type=a.type||layer.fields.find(f=>f.name===name)?.type;feature.properties[name]=type?attributeValue(a.value,type):a.value;layer.fields=inferFields([feature],layer.fields);});
  add('field.edit',t('管理字段','Manage fields'),[layerField(),field('name',t('字段名','Field name')),field('action',t('操作','Action'),'select',{options:['add','delete','rename','convert'],default:'add'}),field('newName',t('新名称','New name')),field('type',t('类型','Type'),'select',{options:['string','number','boolean','json'],default:'string'}),field('value',t('默认值','Default value'))],a=>{const layer=editable(getLayer(e,a.layer,'vector')),name=propertyName(a.name),newName=a.action==='rename'?propertyName(a.newName):name;layer.fields=inferFields(layer.data.features,layer.fields);if(a.action==='rename'&&newName!==name&&layer.fields.some(f=>f.name===newName))throw new Error('The destination field already exists');for(const f of layer.data.features){if(a.action==='delete')delete f.properties[name];else if(a.action==='rename'){if(name in f.properties)f.properties[newName]=f.properties[name];delete f.properties[name];}else if(a.action==='convert')f.properties[name]=f.properties[name]===null?null:attributeValue(f.properties[name],a.type);else if(!(name in f.properties))f.properties[name]=attributeValue(a.value??(a.type==='number'?0:a.type==='boolean'?false:a.type==='json'?'null':''),a.type);}const old=layer.fields.find(f=>f.name===name);layer.fields=layer.fields.filter(f=>f.name!==name);if(a.action!=='delete')layer.fields.push({name:newName,type:a.action==='rename'?(old?.type??a.type):a.type,nullable:true});return {fields:layer.fields};});
  add('field.calculate',t('计算字段','Calculate field'),[layerField(),field('name',t('结果字段','Output field')),field('operation',t('计算','Calculation'),'select',{options:['area','length','centroidX','centroidY','add','subtract','multiply','divide'],default:'area'}),field('source',t('来源字段','Source field')),field('operand',t('数值','Operand'),'number',{default:1})],a=>{const layer=editable(getLayer(e,a.layer,'vector')),name=propertyName(a.name),operand=finite(a.operand,1);for(const f of layer.data.features){const geo={...f,geometry:transformGeometry(f.geometry,layer.crs,'EPSG:4326')},v=finite(f.properties[a.source]);const operations={area:()=>geo.geometry?turf.area(geo):null,length:()=>geo.geometry?turf.length(geo,{units:'meters'}):null,centroidX:()=>geo.geometry?turf.centroid(geo).geometry.coordinates[0]:null,centroidY:()=>geo.geometry?turf.centroid(geo).geometry.coordinates[1]:null,add:()=>v+operand,subtract:()=>v-operand,multiply:()=>v*operand,divide:()=>operand?v/operand:null};f.properties[name]=required(operations[a.operation],'Unknown calculation')();}layer.fields=inferFields(layer.data.features,layer.fields);return {count:layer.data.features.length};});
  add('layer.style',t('样式／分类／标签','Style / classes / labels'),[layerField(),field('color',t('颜色','Color'),'color',{default:'#2879c7'}),field('fill',t('填充颜色','Fill color'),'color',{default:'#2879c7'}),field('fillOpacity',t('填充不透明度','Fill opacity'),'number',{default:.2,min:0,max:1}),field('width',t('线宽','Line width'),'number',{default:2,min:0}),field('radius',t('点大小','Point size'),'number',{default:5,min:1}),field('mode',t('分类','Classification'),'select',{options:['single','categorical','graduated'],default:'single'}),field('field',t('分类字段','Class field')),field('label',t('标签字段','Label field')),field('classes',t('级数','Classes'),'number',{default:5,min:2,max:16})],a=>{const layer=editable(getLayer(e,a.layer,'vector'));layer.style={...layer.style,...a,width:Math.max(0,finite(a.width,2)),radius:Math.max(1,finite(a.radius,5)),classes:Math.max(2,Math.min(16,Math.trunc(finite(a.classes,5))))};delete layer.style.layer;});
  add('query.attributes',t('按属性查询','Query attributes'),[layerField(),field('field',t('字段','Field')),field('operator',t('关系','Operator'),'select',{options:['equals','contains','greater','less','notEqual','isNull'],default:'equals'}),field('value',t('值','Value')),field('sort',t('排序字段','Sort field'))],a=>{const layer=getLayer(e,a.layer,'vector'),compare=v=>({equals:()=>String(v)===String(a.value),contains:()=>String(v??'').includes(a.value),greater:()=>Number(v)>Number(a.value),less:()=>Number(v)<Number(a.value),notEqual:()=>String(v)!==String(a.value),isNull:()=>v==null})[a.operator]();const matches=layer.data.features.filter(f=>compare(f.properties[a.field]));if(a.sort)matches.sort((x,y)=>String(x.properties[a.sort]??'').localeCompare(String(y.properties[a.sort]??''),undefined,{numeric:true}));e.selection={layer:layer.id,features:matches.map(f=>f.id)};return matches.map(f=>({id:f.id,...f.properties}));},t('查询','Query'),'read');
  add('query.measure',t('测量选中要素','Measure selection'),[layerField()],a=>{const layer=getLayer(e,a.layer,'vector'),ids=new Set((e.selection?.layer===layer.id?e.selection.features:[]).map(String));return inGeographic(layer).features.filter(f=>f.geometry&&(!ids.size||ids.has(String(f.id)))).map(f=>({id:f.id,areaSquareMeters:turf.area(f),lengthMeters:['LineString','MultiLineString','Polygon','MultiPolygon'].includes(f.geometry.type)?turf.length(f,{units:'meters'}):0,centroid:turf.centroid(f).geometry.coordinates}));},t('查询','Query'),'read');
}
