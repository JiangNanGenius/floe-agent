// SPDX-License-Identifier: MPL-2.0
import GeoJSON from 'ol/format/GeoJSON.js';
import GPX from 'ol/format/GPX.js';
import KML from 'ol/format/KML.js';
import WKT from 'ol/format/WKT.js';
import * as shp from 'shpjs';
import { unzipSync, zipSync, strFromU8, strToU8, zlibSync } from 'fflate';
import { fromArrayBuffer, writeArrayBuffer } from 'geotiff';
import { sql } from './sqlite.js';
export { sql } from './sqlite.js';
import { artifact, bytes64, from64, text, clone, uid, t, required } from '../../FloeHeavyEditorSupport/Web/runtime.js';
import { vectorLayer, rasterLayer, getLayer, layerField, field, featureCollection, transformGeometry, inGeographic, defineCRS, gridSample, transformPosition, WEB_HALF, normalizeGIS, inferFields, validateGeometry } from './model.js';

import { rasterPixel, rasterRange } from './symbology.js';

const geojson = new GeoJSON();
function safeStem(name) { return String(name||'map').replace(/[\\/:\u0000-\u001f]/g,'_').replace(/\.[^.]+$/,'').slice(0,160)||'map'; }
export function parseCSV(source) {
  const rows=[];let row=[],value='',quoted=false;
  for(let i=0;i<source.length;i++) {
    const c=source[i];if(c==='"'){if(quoted&&source[i+1]==='"'){value+='"';i++;}else quoted=!quoted;}
    else if(c===','&&!quoted){row.push(value);value='';}
    else if((c==='\n'||c==='\r')&&!quoted){if(c==='\r'&&source[i+1]==='\n')i++;row.push(value);if(row.some(v=>v!==''))rows.push(row);row=[];value='';}
    else value+=c;
  }
  if(quoted)throw new Error('Unclosed CSV quote');if(value||row.length){row.push(value);rows.push(row);}return rows;
}
const csvCell=value=>'"'+String(value??'').replace(/"/g,'""')+'"';
function csvFeatures(source) {
  const [columns,...rows]=parseCSV(source.replace(/^\uFEFF/,'')),names=required(columns,'CSV header is missing').map(n=>n.trim()),lower=names.map(n=>n.toLowerCase());
  if(names.some(n=>!n)||new Set(names).size!==names.length)throw new Error('CSV headers must be nonempty and unique');
  const x=lower.findIndex(n=>['x','lon','lng','longitude','easting'].includes(n)),y=lower.findIndex(n=>['y','lat','latitude','northing'].includes(n)),w=lower.findIndex(n=>['wkt','geometry'].includes(n));
  if(w<0&&(x<0||y<0))throw new Error(t('CSV 需包含 WKT 或经纬度列。','CSV requires WKT or coordinate columns.'));
  const wkt=new WKT();return rows.map(values=>{
    if(values.length>names.length)throw new Error('CSV row has too many columns');
    if(w<0&&(!values[x]?.trim()||!values[y]?.trim()))throw new Error('CSV coordinate is empty');
    const geometry=w>=0?(values[w]?.trim()?geojson.writeGeometryObject(wkt.readGeometry(values[w])):null):{type:'Point',coordinates:[Number(values[x]),Number(values[y])]};
    const properties={};names.forEach((key,i)=>{if(i!==w&&i!==x&&i!==y)properties[key]=values[i]!==''&&Number.isFinite(Number(values[i]))?Number(values[i]):values[i]??'';});
    return {type:'Feature',id:uid(),geometry,properties};
  });
}

export function writeWKB(geometry) {
  validateGeometry(geometry);
  const chunks=[],u8=v=>chunks.push(Uint8Array.of(v)),u32=v=>{const b=new Uint8Array(4);new DataView(b.buffer).setUint32(0,v,true);chunks.push(b);},f64=v=>{const b=new Uint8Array(8);new DataView(b.buffer).setFloat64(0,v,true);chunks.push(b);};
  const write=g=>{
    const type={Point:1,LineString:2,Polygon:3,MultiPoint:4,MultiLineString:5,MultiPolygon:6,GeometryCollection:7}[g.type];
    let first=g.coordinates;while(Array.isArray(first?.[0]))first=first[0];const dimensions=first?.length??2,offset=g.layout==='XYM'?2000:dimensions===4?3000:dimensions===3?1000:0;
    u8(1);u32(type+offset);const point=c=>{if(c.length!==dimensions)throw new Error('WKB vertices must have consistent dimensions');for(const v of c)f64(v);};
    if(type===1)point(g.coordinates);
    else if(type===2){u32(g.coordinates.length);g.coordinates.forEach(point);}
    else if(type===3){u32(g.coordinates.length);for(const ring of g.coordinates){u32(ring.length);ring.forEach(point);}}
    else {const parts=type===7?g.geometries:g.coordinates.map(c=>({type:{4:'Point',5:'LineString',6:'Polygon'}[type],coordinates:c,layout:g.layout}));u32(parts.length);parts.forEach(write);}
  };write(geometry);const result=new Uint8Array(chunks.reduce((sum,c)=>sum+c.length,0));let offset=0;for(const chunk of chunks){result.set(chunk,offset);offset+=chunk.length;}return result;
}
export function readWKB(bytes,start=0) {
  const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);let offset=start;
  const guard=n=>{if(offset+n>view.byteLength)throw new Error('Truncated WKB geometry');};
  const parse=(depth=0)=>{
    if(depth>32)throw new Error('WKB geometry is nested too deeply');guard(5);const order=view.getUint8(offset++);if(order!==0&&order!==1)throw new Error('Invalid WKB byte order');const little=order===1;
    let raw=view.getUint32(offset,little);offset+=4;const ewkbZ=Boolean(raw&0x80000000),ewkbM=Boolean(raw&0x40000000),hasSRID=Boolean(raw&0x20000000);raw&=0x0fffffff;
    const iso=Math.floor(raw/1000),z=ewkbZ||iso===1||iso===3,m=ewkbM||iso===2||iso===3,dimensions=2+Number(z)+Number(m),type=raw%1000;if(hasSRID){guard(4);offset+=4;}
    const count=()=>{guard(4);const v=view.getUint32(offset,little);offset+=4;if(v>1e7||v>view.byteLength/4)throw new Error('WKB geometry is too large');return v;};
    const point=()=>{guard(dimensions*8);return Array.from({length:dimensions},()=>{const v=view.getFloat64(offset,little);offset+=8;return v;});};
    let geometry;if(type===1)geometry={type:'Point',coordinates:point()};
    else if(type===2)geometry={type:'LineString',coordinates:Array.from({length:count()},point)};
    else if(type===3)geometry={type:'Polygon',coordinates:Array.from({length:count()},()=>Array.from({length:count()},point))};
    else {if(![4,5,6,7].includes(type))throw new Error('Unsupported WKB geometry type');const geometries=Array.from({length:count()},()=>parse(depth+1));geometry=type===7?{type:'GeometryCollection',geometries}:{type:{4:'MultiPoint',5:'MultiLineString',6:'MultiPolygon'}[type],coordinates:geometries.map(g=>g.coordinates)};}
    if(m&&!z)geometry.layout='XYM';return geometry;
  };const result=parse();validateGeometry(result);return result;
}
const quote=value=>'"'+String(value).replace(/"/g,'""')+'"';
const wgs84='GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433],AUTHORITY["EPSG","4326"]]';
export function crsWKT(crs,definitions={}){
  const code=Number(crs.replace('EPSG:',''));
  if(code===4326)return wgs84;
  if(code===3857)return `PROJCS["WGS 84 / Pseudo-Mercator",${wgs84},PROJECTION["Mercator_1SP"],PARAMETER["central_meridian",0],PARAMETER["scale_factor",1],PARAMETER["false_easting",0],PARAMETER["false_northing",0],UNIT["metre",1],AUTHORITY["EPSG","3857"]]`;
  if((code>=32601&&code<=32660)||(code>=32701&&code<=32760)){const zone=code%100,south=code>=32700;return `PROJCS["WGS 84 / UTM zone ${zone}${south?'S':'N'}",${wgs84},PROJECTION["Transverse_Mercator"],PARAMETER["latitude_of_origin",0],PARAMETER["central_meridian",${zone*6-183}],PARAMETER["scale_factor",0.9996],PARAMETER["false_easting",500000],PARAMETER["false_northing",${south?10000000:0}],UNIT["metre",1],AUTHORITY["EPSG","${code}"]]`;}
  const definition=definitions[crs];if(typeof definition==='string'&&/^(?:PROJCS|GEOGCS|PROJCRS|GEOGCRS)\s*\[/i.test(definition))return definition;
  throw new Error(t('这个格式需要 WKT 坐标定义；请提供定义或导出为 EPSG:4326。','This format requires a WKT CRS definition. Provide one or export as EPSG:4326.'));
}
function exportCollection(layer,crs){return featureCollection(layer.data.features.map(f=>({...clone(f),geometry:transformGeometry(f.geometry,layer.crs,crs)})));}
export async function writeGeoPackage(layers,{crs,definitions={}}={}) {
  if(!layers.some(l=>l.kind==='vector'))throw new Error('Choose a vector layer for GeoPackage export');
  const SQL=await sql(),db=new SQL.Database();
  try {
    db.run('PRAGMA application_id=1196444487;PRAGMA user_version=10300;');
    db.run('CREATE TABLE gpkg_spatial_ref_sys (srs_name TEXT NOT NULL,srs_id INTEGER NOT NULL PRIMARY KEY,organization TEXT NOT NULL,organization_coordsys_id INTEGER NOT NULL,definition TEXT NOT NULL,description TEXT);');
    db.run('CREATE TABLE gpkg_contents (table_name TEXT NOT NULL PRIMARY KEY,data_type TEXT NOT NULL,identifier TEXT UNIQUE,description TEXT DEFAULT \'\',last_change DATETIME NOT NULL DEFAULT (strftime(\'%Y-%m-%dT%H:%M:%fZ\',\'now\')),min_x DOUBLE,min_y DOUBLE,max_x DOUBLE,max_y DOUBLE,srs_id INTEGER);');
    db.run('CREATE TABLE gpkg_geometry_columns (table_name TEXT NOT NULL,column_name TEXT NOT NULL,geometry_type_name TEXT NOT NULL,srs_id INTEGER NOT NULL,z TINYINT NOT NULL,m TINYINT NOT NULL,PRIMARY KEY(table_name,column_name));');
    db.run('CREATE TABLE floe_gis_metadata (table_name TEXT PRIMARY KEY,metadata TEXT NOT NULL)');
    for(const [name,id,definition] of [['Undefined Cartesian',-1,'undefined'],['Undefined geographic',0,'undefined'],['WGS 84',4326,wgs84]])db.run('INSERT INTO gpkg_spatial_ref_sys VALUES(?,?,?,?,?,?)',[name,id,id>0?'EPSG':'NONE',id>0?id:0,definition,'']);
    let index=0;const srsIDs=new Map([['EPSG:4326',4326]]);
    for(const layer of layers.filter(l=>l.kind==='vector')) {
      const outputCRS=defineCRS(crs||layer.crs),collection=exportCollection(layer,outputCRS),table='features_'+index++,fields=inferFields(collection.features,layer.fields);
      let srs=srsIDs.get(outputCRS);if(srs===undefined){const epsg=Number(outputCRS.replace('EPSG:',''));srs=Number.isInteger(epsg)&&epsg>0?epsg:100000+index;srsIDs.set(outputCRS,srs);db.run('INSERT INTO gpkg_spatial_ref_sys VALUES(?,?,?,?,?,?)',[outputCRS,srs,outputCRS.startsWith('EPSG:')?'EPSG':'NONE',outputCRS.startsWith('EPSG:')?srs:0,crsWKT(outputCRS,definitions),'']);}
      const names=new Set(fields.map(f=>f.name)),unique=base=>{while(names.has(base))base+='_';names.add(base);return base;},pk=unique('_floe_fid'),geom=unique('_floe_geom'),idColumn=unique('_floe_feature_id');
      const sqlType=type=>({number:'REAL',boolean:'BOOLEAN',string:'TEXT',json:'TEXT'})[type]??'TEXT';
      db.run(`CREATE TABLE ${quote(table)} (${quote(pk)} INTEGER PRIMARY KEY AUTOINCREMENT,${quote(geom)} BLOB,${quote(idColumn)} TEXT${fields.map(f=>','+quote(f.name)+' '+sqlType(f.type)).join('')});`);
      const located=collection.features.filter(f=>f.geometry),box=located.length?geometryBounds(featureCollection(located)):Array(4).fill(null),types=new Set(located.map(f=>f.geometry.type.toUpperCase()));
      db.run('INSERT INTO gpkg_contents(table_name,data_type,identifier,min_x,min_y,max_x,max_y,srs_id) VALUES(?,?,?,?,?,?,?,?)',[table,'features',layer.name+' ['+index+']',...box,srs]);
      db.run('INSERT INTO gpkg_geometry_columns VALUES(?,?,?,?,?,?)',[table,geom,types.size===1?[...types][0]:'GEOMETRY',srs,2,2]);
      db.run('INSERT INTO floe_gis_metadata VALUES(?,?)',[table,JSON.stringify({name:layer.name,crs:outputCRS,idColumn,fields})]);
      const insert=db.prepare(`INSERT INTO ${quote(table)}(${quote(geom)},${quote(idColumn)}${fields.map(f=>','+quote(f.name)).join('')}) VALUES(${Array(fields.length+2).fill('?').join(',')})`);
      try{for(const f of collection.features) {
        let bytes=null;if(f.geometry){const wkb=writeWKB(f.geometry);bytes=new Uint8Array(8+wkb.length);bytes.set([0x47,0x50,0,1]);new DataView(bytes.buffer).setInt32(4,srs,true);bytes.set(wkb,8);}
        insert.run([bytes,JSON.stringify(f.id),...fields.map(field=>{const v=f.properties[field.name];return v===undefined||v===null?null:field.type==='json'?JSON.stringify(v):typeof v==='boolean'?Number(v):typeof v==='object'?JSON.stringify(v):v;})]);
      }}finally{insert.free();}
    }return db.export();
  }finally{db.close();}
}
export function geometryBounds(collection){let minX=Infinity,minY=Infinity,maxX=-Infinity,maxY=-Infinity;const visit=g=>{if(!g)return;if(g.type==='GeometryCollection'){g.geometries.forEach(visit);return;}const walk=c=>{if(typeof c[0]==='number'){minX=Math.min(minX,c[0]);minY=Math.min(minY,c[1]);maxX=Math.max(maxX,c[0]);maxY=Math.max(maxY,c[1]);}else c.forEach(walk);};walk(g.coordinates);};collection.features.forEach(f=>visit(f.geometry));return [minX,minY,maxX,maxY];}
export async function readGeoPackage(bytes) {
  const SQL=await sql(),db=new SQL.Database(bytes),layers=[];
  try {
    const contents=db.exec("SELECT c.table_name,c.identifier,g.column_name,g.srs_id FROM gpkg_contents c JOIN gpkg_geometry_columns g ON c.table_name=g.table_name WHERE c.data_type='features'")[0];
    if(!contents)throw new Error('No feature tables in GeoPackage');
    const hasMetadata=Boolean(db.exec("SELECT name FROM sqlite_master WHERE type='table' AND name='floe_gis_metadata'").length);
    for(const [table,name,geometryColumn,srs] of contents.values) {
      const srsStatement=db.prepare('SELECT definition FROM gpkg_spatial_ref_sys WHERE srs_id=?');srsStatement.bind([srs]);const definition=srsStatement.step()?srsStatement.get()[0]:null;srsStatement.free();
      let crs=Number(srs)>0?`EPSG:${srs}`:'EPSG:4326',metadata={};
      if(hasMetadata){const statement=db.prepare('SELECT metadata FROM floe_gis_metadata WHERE table_name=?');statement.bind([table]);try{if(statement.step())metadata=JSON.parse(statement.get()[0]);}finally{statement.free();}}
      if(metadata.crs)crs=metadata.crs;
      defineCRS(crs,definition&&definition!=='undefined'&&!['EPSG:4326','EPSG:3857'].includes(crs)?definition:undefined);
      const tableInfo=db.exec(`PRAGMA table_info(${quote(table)})`)[0],primary=tableInfo?.values.find(row=>row[5])?.[1],query=db.exec(`SELECT * FROM ${quote(table)}`)[0],fields=metadata.fields??tableInfo?.values.filter(row=>row[1]!==geometryColumn&&row[1]!==primary).map(row=>({name:row[1],type:/BOOL/i.test(row[2])?'boolean':/INT|REAL|FLOAT|DOUBLE|NUMERIC/i.test(row[2])?'number':'string',nullable:!row[3]}))??[];
      const features=(query?.values??[]).map(row=>{const properties={};let geometry=null,id;for(let i=0;i<query.columns.length;i++){const key=query.columns[i],value=row[i];if(key===geometryColumn&&value){if(value[0]!==0x47||value[1]!==0x50||value[2]!==0)throw new Error('Invalid GeoPackage geometry');if(value[3]&0x20)throw new Error('Extended GeoPackage geometry is not supported');const indicator=(value[3]>>1)&7,envelopeBytes={0:0,1:32,2:48,3:48,4:64}[indicator];if(envelopeBytes===undefined)throw new Error('Invalid GeoPackage envelope');if(!(value[3]&0x10))geometry=readWKB(value,8+envelopeBytes);}else if(key===metadata.idColumn){try{id=JSON.parse(value);}catch{id=value;}}else if(key===primary){id??=value;}else if(key!==geometryColumn){const field=fields.find(f=>f.name===key);properties[key]=value===null?null:field?.type==='json'?JSON.parse(value):field?.type==='boolean'?Boolean(value):value;}}return {type:'Feature',id:id??uid(),geometry,properties};});
      const layer=vectorLayer(metadata.name||name||table,features,crs);layer.fields=fields;layer.source={format:'GeoPackage',table,definition};layers.push(layer);
    }return layers;
  }finally{db.close();}
}
export async function readGeoTIFF(bytes,name) {
  const tiff=await fromArrayBuffer(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)),image=await tiff.getImage(),width=image.getWidth(),height=image.getHeight(),keys=image.getGeoKeys()??{},directory=image.getFileDirectory();
  if(width*height>16_777_216)throw new Error('GeoTIFF exceeds 16.7 million pixels');
  const matrix=directory.getValue('ModelTransformation'),orientation=directory.getValue('Orientation')??1;if(orientation!==1||matrix&&(Math.abs(matrix[1])>1e-12||Math.abs(matrix[4])>1e-12))throw new Error(t('请先将旋转 GeoTIFF 转换为北向上的栅格。','Warp rotated GeoTIFF data to a north-up grid first.'));
  let bounds,georeferenced=true;try{const resolution=image.getResolution();if(resolution[0]<=0||resolution[1]>=0)throw new Error('GeoTIFF must have eastward columns and southward rows');bounds=image.getBoundingBox();if(keys.GTRasterTypeGeoKey===2)bounds=[bounds[0]-Math.abs(resolution[0])/2,bounds[1]+Math.abs(resolution[1])/2,bounds[2]-Math.abs(resolution[0])/2,bounds[3]+Math.abs(resolution[1])/2];}
  catch(error){if(matrix||directory.getValue('ModelPixelScale'))throw error;bounds=[0,0,width,height];georeferenced=false;}
  const rasters=await image.readRasters();let nodata=image.getGDALNoData()??-9999;if(!Number.isFinite(nodata)){nodata=[-3.4028234663852886e38,-1.7014117331926443e38,-8.5070586659632215e37].find(v=>!Array.from(rasters).some(b=>b.includes(v)));if(nodata===undefined)throw new Error('Unable to choose a finite nodata marker');}
  const code=keys.ProjectedCSTypeGeoKey??keys.GeographicTypeGeoKey??(georeferenced?4326:3857),layer=rasterLayer(safeStem(name),Array.from(rasters[0],v=>Number.isFinite(v)?v:nodata),width,height,bounds,`EPSG:${code}`,nodata);
  layer.bands=Array.from(rasters,band=>Array.from(band,v=>Number.isFinite(v)?v:nodata));layer.source={name,format:'GeoTIFF',geoKeys:keys,georeferenced};return layer;
}
export async function writeGeoTIFF(layer) {
  const code=Number(layer.crs.replace('EPSG:',''));if(!Number.isInteger(code)||code<=0||code===32767)throw new Error('GeoTIFF export requires an EPSG coordinate system');const metadata={width:layer.width,height:layer.height,BitsPerSample:Array(layer.bands.length).fill(32),SampleFormat:Array(layer.bands.length).fill(3),SamplesPerPixel:layer.bands.length,ExtraSamples:Array(Math.max(0,layer.bands.length-1)).fill(0),PhotometricInterpretation:1,GDAL_NODATA:String(Math.fround(layer.nodata)),ModelPixelScale:[(layer.bounds[2]-layer.bounds[0])/layer.width,(layer.bounds[3]-layer.bounds[1])/layer.height,0],ModelTiepoint:[0,0,0,layer.bounds[0],layer.bounds[3],0],GTModelTypeGeoKey:code===4326?2:1,[code===4326?'GeographicTypeGeoKey':'ProjectedCSTypeGeoKey']:code};
  // The writer preserves a typed buffer's IEEE representation. Plain nested
  // arrays would otherwise be encoded as byte values despite Float32 tags.
  const data=new Float32Array(layer.width*layer.height*layer.bands.length);
  for(let i=0;i<layer.width*layer.height;i++)for(let b=0;b<layer.bands.length;b++){const value=Math.fround(layer.bands[b][i]);if(!Number.isFinite(value))throw new Error('Sample exceeds Float32 range');data[i*layer.bands.length+b]=value;}
  return new Uint8Array(await writeArrayBuffer(data,metadata));
}
export function readASCIIGrid(source,name) {
  const lines=source.trim().split(/\r?\n/),header={};let start=0;
  while(start<lines.length){const parts=lines[start].trim().split(/\s+/);if(!/^(ncols|nrows|xllcorner|yllcorner|xllcenter|yllcenter|cellsize|nodata_value)$/i.test(parts[0]))break;header[parts[0].toLowerCase()]=Number(parts[1]);start++;}
  const w=header.ncols,h=header.nrows,s=header.cellsize;if(!(Number.isInteger(w)&&Number.isInteger(h)&&w>0&&h>0&&s>0))throw new Error('Invalid ASCII grid header');
  const x=header.xllcorner??header.xllcenter-s/2,y=header.yllcorner??header.yllcenter-s/2,grid=lines.slice(start).join(' ').trim().split(/\s+/).map(Number);if(!grid.every(Number.isFinite))throw new Error('Invalid ASCII grid sample');
  return rasterLayer(safeStem(name),grid,w,h,[x,y,x+w*s,y+h*s],'EPSG:4326',header.nodata_value??-9999);
}
export function writeASCIIGrid(layer) {
  const dx=(layer.bounds[2]-layer.bounds[0])/layer.width,dy=(layer.bounds[3]-layer.bounds[1])/layer.height;if(Math.abs(dx-dy)>1e-8*Math.max(Math.abs(dx),Math.abs(dy)))throw new Error('ASCII grid requires square cells; resample first');
  return `ncols ${layer.width}\nnrows ${layer.height}\nxllcorner ${layer.bounds[0]}\nyllcorner ${layer.bounds[1]}\ncellsize ${dx}\nNODATA_value ${layer.nodata}\n`+Array.from({length:layer.height},(_,r)=>layer.bands[0].slice(r*layer.width,(r+1)*layer.width).join(' ')).join('\n')+'\n';
}
export async function readMBTiles(bytes,name) {
  const SQL=await sql(),db=new SQL.Database(bytes);
  try {
    const rows=db.exec('SELECT name,value FROM metadata')[0]?.values??[],metadata=Object.fromEntries(rows),count=db.exec('SELECT count(*) FROM tiles')[0]?.values?.[0]?.[0]??0;
    if(!count)throw new Error('MBTiles contains no tiles');
    if(!['png','jpg','jpeg','webp','image/png','image/jpeg','image/webp'].includes(String(metadata.format).toLowerCase()))throw new Error(t('请导入影像瓦片；矢量瓦片可先转换为矢量图层。','Import image tiles; convert vector tiles into a vector layer first.'));
    const bounds=String(metadata.bounds??'-180,-85.05112878,180,85.05112878').split(',').map(Number);if(bounds.length!==4||!bounds.every(Number.isFinite))throw new Error('Invalid MBTiles bounds');
    return {id:uid(),kind:'tiles',name:safeStem(name),bounds,crs:'EPSG:3857',visible:true,opacity:1,locked:true,group:'',base64:bytes64(bytes),metadata,tileCount:count};
  }finally{db.close();}
}
export function readWorldFile(source,width,height){
  const values=source.trim().split(/\s+/).map(Number);if(values.length!==6||!values.every(Number.isFinite))throw new Error('Invalid world file');
  const [dx,rotationY,rotationX,dy,x,y]=values;if(Math.abs(rotationX)>1e-12||Math.abs(rotationY)>1e-12||dx<=0||dy>=0)throw new Error('Only north-up world files are supported; warp rotated images first');
  return [x-dx/2,y+dy*(height-.5),x+dx*(width-.5),y-dy/2];
}
export function writeWorldFile(layer){const dx=(layer.bounds[2]-layer.bounds[0])/layer.width,dy=-(layer.bounds[3]-layer.bounds[1])/layer.height;return [dx,0,0,dy,layer.bounds[0]+dx/2,layer.bounds[3]+dy/2].join('\n')+'\n';}
export async function readImage(bytes,name,{bounds,crs='EPSG:3857'}={}){
  const url=URL.createObjectURL(new Blob([bytes])),image=new Image();
  try{await new Promise((resolve,reject)=>{image.onload=resolve;image.onerror=()=>reject(new Error('Unable to decode this image'));image.src=url;});
    const width=image.naturalWidth,height=image.naturalHeight;if(width*height>16_777_216)throw new Error('Image exceeds 16.7 million pixels');
    const canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;const context=canvas.getContext('2d');context.drawImage(image,0,0);const rgba=context.getImageData(0,0,width,height).data;
    const layer=rasterLayer(safeStem(name),Array.from({length:width*height},(_,i)=>rgba[i*4]),width,height,bounds??[0,0,width,height],crs);layer.bands=Array.from({length:4},(_,b)=>Array.from({length:width*height},(_,i)=>rgba[i*4+b]));layer.style={palette:'rgb',band:0};layer.source={name,image:true,format:name.split('.').at(-1),georeferenced:Boolean(bounds)};return layer;
  }finally{URL.revokeObjectURL(url);}
}
const crcTable=Array.from({length:256},(_,i)=>{for(let j=0;j<8;j++)i=i&1?0xedb88320^(i>>>1):i>>>1;return i>>>0;});
function pngChunk(type,data){const name=strToU8(type),result=new Uint8Array(data.length+12),view=new DataView(result.buffer);view.setUint32(0,data.length);result.set(name,4);result.set(data,8);let crc=0xffffffff;for(const b of result.subarray(4,-4))crc=crcTable[(crc^b)&255]^(crc>>>8);view.setUint32(result.length-4,(crc^0xffffffff)>>>0);return result;}
export function encodePNG(rgba,width,height){
  if(rgba.length!==width*height*4)throw new Error('Invalid RGBA pixels');const ihdr=new Uint8Array(13),view=new DataView(ihdr.buffer);view.setUint32(0,width);view.setUint32(4,height);ihdr[8]=8;ihdr[9]=6;
  const rows=new Uint8Array((width*4+1)*height);for(let r=0;r<height;r++)rows.set(rgba.subarray(r*width*4,(r+1)*width*4),r*(width*4+1)+1);
  const chunks=[Uint8Array.of(137,80,78,71,13,10,26,10),pngChunk('IHDR',ihdr),pngChunk('IDAT',zlibSync(rows)),pngChunk('IEND',new Uint8Array())],result=new Uint8Array(chunks.reduce((n,c)=>n+c.length,0));let offset=0;for(const chunk of chunks){result.set(chunk,offset);offset+=chunk.length;}return result;
}
export async function writeMBTiles(layer,{minZoom=0,maxZoom=12,tileSize=256}={},signal){
  if(layer.kind!=='raster')throw new Error('Choose a raster layer');minZoom=Math.trunc(minZoom);maxZoom=Math.trunc(maxZoom);if(minZoom<0||maxZoom<minZoom||maxZoom>22||tileSize!==256)throw new Error('Choose a zoom range from 0 to 22');
  const edge=[];for(let i=0;i<=16;i++){const s=i/16;edge.push([layer.bounds[0]+s*(layer.bounds[2]-layer.bounds[0]),layer.bounds[1]],[layer.bounds[0]+s*(layer.bounds[2]-layer.bounds[0]),layer.bounds[3]],[layer.bounds[0],layer.bounds[1]+s*(layer.bounds[3]-layer.bounds[1])],[layer.bounds[2],layer.bounds[1]+s*(layer.bounds[3]-layer.bounds[1])]);}
  const points=edge.map(p=>transformPosition(p,layer.crs,'EPSG:3857')),bounds=[Math.max(-WEB_HALF,Math.min(...points.map(p=>p[0]))),Math.max(-WEB_HALF,Math.min(...points.map(p=>p[1]))),Math.min(WEB_HALF,Math.max(...points.map(p=>p[0]))),Math.min(WEB_HALF,Math.max(...points.map(p=>p[1])))];
  if(!bounds.every(Number.isFinite)||bounds[0]>=bounds[2]||bounds[1]>=bounds[3])throw new Error('Raster lies outside the Web Mercator tile domain');
  const ranges=[];let count=0;for(let z=minZoom;z<=maxZoom;z++){const n=2**z,x0=Math.max(0,Math.floor((bounds[0]+WEB_HALF)/(2*WEB_HALF)*n)),x1=Math.min(n-1,Math.ceil((bounds[2]+WEB_HALF)/(2*WEB_HALF)*n)-1),y0=Math.max(0,Math.floor((WEB_HALF-bounds[3])/(2*WEB_HALF)*n)),y1=Math.min(n-1,Math.ceil((WEB_HALF-bounds[1])/(2*WEB_HALF)*n)-1);ranges.push({z,n,x0,x1,y0,y1});count+=(x1-x0+1)*(y1-y0+1);}
  if(count>4096)throw new Error(t('结果超过 4096 个瓦片，请降低最大缩放级别。','The result exceeds 4096 tiles. Lower the maximum zoom.'));
  const SQL=await sql(),db=new SQL.Database(),range=rasterRange(layer,layer.style?.band??0);
  try{
    db.run('PRAGMA application_id=1297105496;CREATE TABLE metadata(name TEXT,value TEXT);CREATE TABLE tiles(zoom_level INTEGER,tile_column INTEGER,tile_row INTEGER,tile_data BLOB);CREATE UNIQUE INDEX tile_index ON tiles(zoom_level,tile_column,tile_row)');
    const sw=transformPosition(bounds.slice(0,2),'EPSG:3857','EPSG:4326'),ne=transformPosition(bounds.slice(2),'EPSG:3857','EPSG:4326'),metadata={name:layer.name,format:'png',type:'overlay',version:'1.3',bounds:[...sw,...ne].join(','),center:[(sw[0]+ne[0])/2,(sw[1]+ne[1])/2,maxZoom].join(','),minzoom:String(minZoom),maxzoom:String(maxZoom)};
    for(const [k,v]of Object.entries(metadata))db.run('INSERT INTO metadata VALUES(?,?)',[k,v]);
    const insert=db.prepare('INSERT INTO tiles VALUES(?,?,?,?)');try{for(const {z,n,x0,x1,y0,y1}of ranges)for(let y=y0;y<=y1;y++)for(let x=x0;x<=x1;x++){
      if(signal?.aborted)throw new Error('Cancelled');await new Promise(resolve=>setTimeout(resolve,0));const pixels=new Uint8Array(tileSize*tileSize*4),span=2*WEB_HALF/n;
      for(let row=0;row<tileSize;row++)for(let col=0;col<tileSize;col++){const p=transformPosition([-WEB_HALF+(x+(col+.5)/tileSize)*span,WEB_HALF-(y+(row+.5)/tileSize)*span],'EPSG:3857',layer.crs),values=layer.bands.map((_,band)=>gridSample(layer,p[0],p[1],band,'nearest'));pixels.set(rasterPixel(layer,values,range),(row*tileSize+col)*4);}
      insert.run([z,x,n-y-1,encodePNG(pixels,tileSize,tileSize)]);
    }}finally{insert.free();}return db.export();
  }finally{db.close();}
}
// Independent XY Shapefile producer. Each geometry family gets a complete SHP/SHX/DBF/PRJ/CPG set.
export function writeShapefile(collection,stem,prj=wgs84){
  const groups=new Map();const add=(type,coordinates,properties,id)=>{if(!groups.has(type))groups.set(type,[]);groups.get(type).push({type,coordinates,properties,id});};
  for(const f of collection.features){const visit=g=>{if(!g)return;if(g.type==='GeometryCollection')return g.geometries.forEach(visit);const types={Point:1,MultiPoint:8,LineString:3,MultiLineString:3,Polygon:5,MultiPolygon:5};if(!types[g.type])throw new Error('Unsupported Shapefile geometry');let c=g.coordinates;if(g.type==='LineString')c=[c];const orient=rings=>rings.map((ring,i)=>{let area=0;for(let n=0;n<ring.length-1;n++)area+=ring[n][0]*ring[n+1][1]-ring[n+1][0]*ring[n][1];return (i===0?area>0:area<0)?[...ring].reverse():ring;});if(g.type==='Polygon')c=orient(c);if(g.type==='MultiPolygon')c=c.flatMap(orient);add(types[g.type],c,f.properties,f.id);};visit(f.geometry);}
  if(!groups.size)throw new Error('Shapefile requires at least one located feature');const files={};
  for(const [type,features]of groups){
    const name=`${stem}/${stem}-${{1:'points',3:'lines',5:'polygons',8:'multipoints'}[type]}`;
    const coords=features.flatMap(f=>type===1?[f.coordinates]:type===8?f.coordinates:f.coordinates.flat()),box=[Math.min(...coords.map(p=>p[0])),Math.min(...coords.map(p=>p[1])),Math.max(...coords.map(p=>p[0])),Math.max(...coords.map(p=>p[1]))];
    const records=features.map(f=>{let parts=type===1?[f.coordinates]:type===8?f.coordinates:f.coordinates;
      if((type===1?[f.coordinates]:type===8?parts:parts.flat()).some(c=>c.length>2))throw new Error('Shapefile output is XY; use GeoPackage to preserve Z/M coordinates');
      const points=type===1?[f.coordinates]:type===8?parts:parts.flat(),partCount=[3,5].includes(type)?parts.length:0,length=type===1?20:type===8?40+points.length*16:44+partCount*4+points.length*16,result=new Uint8Array(length),v=new DataView(result.buffer);v.setInt32(0,type,true);
      if(type===1){v.setFloat64(4,points[0][0],true);v.setFloat64(12,points[0][1],true);}else{const b=[Math.min(...points.map(p=>p[0])),Math.min(...points.map(p=>p[1])),Math.max(...points.map(p=>p[0])),Math.max(...points.map(p=>p[1]))];b.forEach((n,i)=>v.setFloat64(4+i*8,n,true));let offset;if(type===8){v.setInt32(36,points.length,true);offset=40;}else{v.setInt32(36,partCount,true);v.setInt32(40,points.length,true);let start=0;parts.forEach((part,i)=>{v.setInt32(44+i*4,start,true);start+=part.length;});offset=44+partCount*4;}points.forEach((p,i)=>{v.setFloat64(offset+i*16,p[0],true);v.setFloat64(offset+i*16+8,p[1],true);});}return result;});
    const header=length=>{const bytes=new Uint8Array(100),v=new DataView(bytes.buffer);v.setInt32(0,9994);v.setInt32(24,length/2);v.setInt32(28,1000,true);v.setInt32(32,type,true);box.forEach((n,i)=>v.setFloat64(36+i*8,n,true));return bytes;};
    const shpBytes=new Uint8Array(100+records.reduce((n,r)=>n+8+r.length,0)),shxBytes=new Uint8Array(100+records.length*8);shpBytes.set(header(shpBytes.length));shxBytes.set(header(shxBytes.length));let offset=100;records.forEach((record,i)=>{const view=new DataView(shpBytes.buffer),index=new DataView(shxBytes.buffer);view.setInt32(offset,i+1);view.setInt32(offset+4,record.length/2);index.setInt32(100+i*8,offset/2);index.setInt32(104+i*8,record.length/2);shpBytes.set(record,offset+8);offset+=8+record.length;});
    const properties=features.map(f=>f.properties);for(const feature of features)for(const value of Object.values(feature.properties)){if(typeof value==='number'&&Number(value.toFixed(8))!==value)throw new Error('DBF output supports eight decimal places; use GeoPackage to preserve this numeric value');if(strToU8(typeof value==='object'?JSON.stringify(value):String(value??'')).length>254)throw new Error('DBF text exceeds 254 UTF-8 bytes; shorten it or use GeoPackage');}const schema=inferFields(features.map(f=>({properties:f.properties}))),used=new Set(),fields=schema.map((f,i)=>{let n=f.name.replace(/[^A-Za-z0-9_]/g,'_').slice(0,10)||'field';if(used.has(n)||/^_+$/.test(n))n='field'+i;while(used.has(n))n=(n.slice(0,7)+'_'+i).slice(0,10);used.add(n);const values=properties.map(p=>p[f.name]),kind=f.type==='number'?'N':f.type==='boolean'?'L':'C';return {...f,short:n,kind,length:kind==='N'?24:kind==='L'?1:Math.min(254,Math.max(1,...values.map(v=>strToU8(typeof v==='object'?JSON.stringify(v):String(v??'')).length)))};});
    const headerSize=33+fields.length*32,rowSize=1+fields.reduce((n,f)=>n+f.length,0),dbf=new Uint8Array(headerSize+features.length*rowSize+1).fill(32),dv=new DataView(dbf.buffer),now=new Date();dbf[0]=3;dbf[1]=now.getUTCFullYear()-1900;dbf[2]=now.getUTCMonth()+1;dbf[3]=now.getUTCDate();dv.setUint32(4,features.length,true);dv.setUint16(8,headerSize,true);dv.setUint16(10,rowSize,true);dbf.fill(0,12,32);
    fields.forEach((f,i)=>{const start=32+i*32;dbf.fill(0,start,start+32);dbf.set(strToU8(f.short),start);dbf[start+11]=f.kind.charCodeAt(0);dbf[start+16]=f.length;dbf[start+17]=f.kind==='N'?8:0;});dbf[headerSize-1]=13;
    properties.forEach((p,i)=>{let off=headerSize+i*rowSize;dbf[off++]=32;for(const f of fields){const value=p[f.name],string=value==null?'':f.kind==='L'?(value?'T':'F'):f.kind==='N'?Number(value).toFixed(8):typeof value==='object'?JSON.stringify(value):String(value),encoded=strToU8(string);if(f.kind==='N'&&encoded.length>f.length)throw new Error('Numeric value exceeds DBF field width');let take=Math.min(encoded.length,f.length);while(take>0&&take<encoded.length&&(encoded[take]&0xc0)===0x80)take--;dbf.set(encoded.subarray(0,take),off+(f.kind==='N'?f.length-take:0));off+=f.length;}});dbf[dbf.length-1]=26;
    files[name+'.shp']=shpBytes;files[name+'.shx']=shxBytes;files[name+'.dbf']=dbf;files[name+'.prj']=strToU8(prj);files[name+'.cpg']=strToU8('UTF-8');files[name+'.floe-fields.json']=strToU8(JSON.stringify({fields,ids:features.map(f=>f.id),nulls:features.map(f=>Object.keys(f.properties).filter(k=>f.properties[k]===null)),missing:features.map(f=>fields.map(field=>field.name).filter(k=>!(k in f.properties)))}));
  }return zipSync(files);
}
export async function importGIS(e,args) {
  const name=String(args.name??'import'),extension=name.split('.').at(-1).toLowerCase(),bytes=from64(args.base64),source=()=>text(bytes);let layers=[];
  if(['floegis','json','geojson'].includes(extension)) {
    const value=JSON.parse(source());
    if(extension==='floegis'||value.kind==='gis'||value.data?.layers||value.layers){const state=value.content?.data??value.content??value.data??value;normalizeGIS(state);e.state=e.payload.data=clone(state);const history=value.content?.history??value.history;if(history&&Array.isArray(history.past)&&Array.isArray(history.future))e.payload.history=clone(history);e.liveView=null;e.selection={layer:e.state.layers[0]?.id??null,features:[]};return {project:true};}
    const features=value.type==='FeatureCollection'?value.features:value.type==='Feature'?[value]:[{type:'Feature',geometry:value,properties:{}}],crs=args.crs??value.crs?.properties?.name??'EPSG:4326';layers=[vectorLayer(safeStem(name),features,crs.replace('urn:ogc:def:crs:EPSG::','EPSG:'))];
  }else if(extension==='csv')layers=[vectorLayer(safeStem(name),csvFeatures(source()),args.crs??'EPSG:4326')];
  else if(extension==='gpx'||extension==='kml') {
    if(/<!DOCTYPE|<!ENTITY/i.test(source()))throw new Error('External XML definitions are not supported');
    const reader=extension==='gpx'?new GPX():new KML({extractStyles:false});layers=[vectorLayer(safeStem(name),reader.readFeatures(source(),{dataProjection:'EPSG:4326',featureProjection:'EPSG:4326'}).map(f=>geojson.writeFeatureObject(f)))];
  }else if(extension==='kmz'){const files=unzipSync(bytes),key=Object.keys(files).find(k=>/\.kml$/i.test(k));if(!key)throw new Error('KMZ has no KML');return importGIS(e,{name:key,base64:bytes64(files[key])});}
  else if(extension==='gpkg')layers=await readGeoPackage(bytes);
  else if(extension==='tif'||extension==='tiff')layers=[await readGeoTIFF(bytes,name)];
  else if(['png','jpg','jpeg','webp'].includes(extension))layers=[await readImage(bytes,name,args)];
  else if(extension==='asc'){const layer=readASCIIGrid(source(),name);if(args.crs)layer.crs=defineCRS(args.crs);layers=[layer];}
  else if(extension==='mbtiles')layers=[await readMBTiles(bytes,name)];
  else if(extension==='zip') {
    const files=unzipSync(bytes),shapefiles=Object.keys(files).filter(k=>/\.shp$/i.test(k));if(!shapefiles.length)throw new Error('ZIP has no Shapefile; import image and world file separately');
    const result=await shp.default(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength));
    layers=(Array.isArray(result)?result:[result]).map((fc,i)=>{const prefix=fc.fileName??shapefiles[i].replace(/\.shp$/i,''),metaKey=Object.keys(files).find(k=>k.toLowerCase()===(prefix+'.floe-fields.json').toLowerCase()),metadata=metaKey?JSON.parse(strFromU8(files[metaKey])):null;
      if(metadata)fc.features.forEach((feature,n)=>{const properties={};for(const field of metadata.fields){let v=feature.properties[field.short];if(v!=null&&field.type==='json')try{v=JSON.parse(v);}catch{}properties[field.name]=metadata.nulls?.[n]?.includes(field.name)?null:v;}for(const key of metadata.missing?.[n]??[])delete properties[key];feature.properties=properties;feature.id=metadata.ids[n]??uid();});
      const layer=vectorLayer(prefix.split('/').at(-1),fc.features);if(metadata)layer.fields=metadata.fields.map(({name,type})=>({name,type,nullable:true}));return layer;});
  }else if(extension==='shp')layers=[vectorLayer(safeStem(name),shp.parseShp(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)).map(geometry=>({type:'Feature',geometry,properties:{}})),args.crs??'EPSG:4326')];
  else if(extension==='dbf') {
    const attrs=shp.parseDbf(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength),args.encoding??'UTF-8'),layer=required(e.state.layers.find(l=>l.name===safeStem(name)&&l.kind==='vector'),'Import matching SHP first');if(attrs.length!==layer.data.features.length)throw new Error('DBF and SHP record counts differ');attrs.forEach((p,i)=>layer.data.features[i].properties=p);layer.fields=inferFields(layer.data.features);return {attributes:attrs.length};
  }else if(extension==='prj'){const layer=required(e.state.layers.find(l=>l.name===safeStem(name)||safeStem(l.source?.name)===safeStem(name)),'Import matching layer first'),code='CUSTOM:'+layer.id.toUpperCase();defineCRS(code,source());e.state.definitions[code]=source();layer.crs=code;return {crs:code};}
  else if(['pgw','jgw','tfw','wld','pngw','jpgw'].includes(extension)){
    const layer=required(e.state.layers.find(l=>l.kind==='raster'&&(l.name===safeStem(name)||safeStem(l.source?.name)===safeStem(name))),'Import matching image first');layer.bounds=readWorldFile(source(),layer.width,layer.height);layer.source={...layer.source,georeferenced:true};return {bounds:layer.bounds};
  }else if(extension==='shx'||extension==='cpg'){
    const layer=required(e.state.layers.find(l=>l.name===safeStem(name)),'Import matching SHP first');layer.source={...layer.source,[extension]:extension==='cpg'?source():{bytes:bytes.length}};return {sidecar:extension};
  }else throw new Error(t('不支持这个文件格式。','Unsupported file format.'));
  for(const layer of layers){layer.source={...layer.source,name,format:layer.source?.format??extension};if(layer.source.definition&&!['EPSG:4326','EPSG:3857'].includes(layer.crs))e.state.definitions[layer.crs]=layer.source.definition;}
  e.state.layers.push(...layers);if(layers[0])e.selection={layer:layers[0].id,features:[]};return {layers:layers.map(l=>({id:l.id,name:l.name,kind:l.kind}))};
}
export async function exportGIS(e,args,signal) {
  const format=args.format??'geojson';
  if(format==='floegis'){const state=clone(e.state);state.view=clone(e.liveView??state.view);return {artifacts:[artifact(safeStem(args.name??state.title)+'.floegis','application/json',JSON.stringify({kind:'gis',schemaVersion:1,data:state,history:e.payload.history}))]};}
  const layer=getLayer(e,args.layer),stem=safeStem(args.name??layer.name);let data,media='application/octet-stream',suffix=format;
  const requestedCRS=args.crs?defineCRS(args.crs):undefined;
  if(format==='gpkg')data=await writeGeoPackage(args.all?e.state.layers:[layer],{crs:requestedCRS,definitions:e.state.definitions});
  else if(format==='tif'){if(layer.kind!=='raster')throw new Error('Choose a raster layer');data=await writeGeoTIFF(layer);media='image/tiff';}
  else if(format==='asc'){if(layer.kind!=='raster')throw new Error('Choose a raster layer');data=writeASCIIGrid(layer);media='text/plain';return {artifacts:[artifact(stem+'.asc',media,data),artifact(stem+'.prj','text/plain',crsWKT(layer.crs,e.state.definitions))]};}
  else if(format==='png'){if(layer.kind!=='raster')throw new Error('Choose a raster layer');const range=rasterRange(layer,layer.style?.band??0),rgba=new Uint8Array(layer.width*layer.height*4);for(let i=0;i<layer.width*layer.height;i++)rgba.set(rasterPixel(layer,layer.bands.map(b=>b[i]),range),i*4);return {artifacts:[artifact(stem+'.png','image/png',encodePNG(rgba,layer.width,layer.height)),artifact(stem+'.pgw','text/plain',writeWorldFile(layer)),artifact(stem+'.prj','text/plain',crsWKT(layer.crs,e.state.definitions))]};}
  else if(format==='mbtiles'){data=layer.kind==='tiles'?from64(layer.base64):await writeMBTiles(layer,{minZoom:args.minZoom??0,maxZoom:args.maxZoom??12},signal);}
  else {
    if(layer.kind!=='vector')throw new Error(t('请选择矢量图层。','Choose a vector layer.'));
    const crs=requestedCRS??'EPSG:4326';if(['geojson','gpx','kml'].includes(format)&&crs!=='EPSG:4326')throw new Error('GeoJSON, GPX and KML use EPSG:4326; choose GeoPackage, Shapefile or CSV for projected coordinates');
    const collection=exportCollection(layer,crs),features=geojson.readFeatures(collection);
    if(format==='geojson'){data=JSON.stringify(collection);media='application/geo+json';}
    else if(format==='csv'){const fields=inferFields(collection.features,layer.fields).map(f=>f.name),wkt=new WKT();data=[['wkt',...fields],...collection.features.map((f,i)=>[f.geometry?wkt.writeGeometry(features[i].getGeometry()):'',...fields.map(k=>typeof f.properties[k]==='object'?JSON.stringify(f.properties[k]):f.properties[k])])].map(row=>row.map(csvCell).join(',')).join('\r\n');media='text/csv';}
    else if(format==='gpx'){if(collection.features.some(f=>f.geometry&&!['Point','LineString','MultiLineString'].includes(f.geometry.type)))throw new Error('GPX supports points and tracks. Use KML or GeoPackage for other geometry types');data=new GPX().writeFeatures(features);media='application/gpx+xml';}
    else if(format==='kml'){data=new KML({extractStyles:false}).writeFeatures(features);media='application/vnd.google-earth.kml+xml';}
    else if(format==='shp'){data=writeShapefile(collection,stem,crsWKT(crs,e.state.definitions));suffix='zip';media='application/zip';}
    else throw new Error('Unsupported export format');
  }return {artifacts:[artifact(stem+'.'+suffix,media,data)]};
}
export async function querySQL(e,args){
  const layer=getLayer(e,args.layer,'vector'),SQL=await sql(),db=new SQL.Database(),fields=inferFields(layer.data.features,layer.fields).map(f=>f.name);
  if(fields.includes('_id')||fields.includes('_geometry'))throw new Error('Rename the reserved SQL fields _id and _geometry first');
  try{
    db.run(`CREATE TABLE features (_id TEXT,_geometry TEXT${fields.map(f=>','+quote(f)).join('')})`);const insert=db.prepare(`INSERT INTO features VALUES(${Array(fields.length+2).fill('?').join(',')})`),wkt=new WKT();
    try{for(const f of layer.data.features)insert.run([String(f.id),f.geometry?wkt.writeGeometry(geojson.readGeometry(f.geometry)):null,...fields.map(k=>{const v=f.properties[k];return v==null?null:typeof v==='object'?JSON.stringify(v):typeof v==='boolean'?Number(v):v;})]);}finally{insert.free();}
    db.run('PRAGMA query_only=ON');const query=String(args.sql??'SELECT * FROM features LIMIT 100');if(!/^\s*(SELECT|WITH)\b/i.test(query))throw new Error('Use a SELECT query');
    let statementCount=0;for(const statement of db.iterateStatements(query)){void statement;statementCount++;}if(statementCount!==1)throw new Error('Use a single SELECT query');const result=db.exec(query);if(result.length>1)throw new Error('Use a single SELECT query');if(!result.length)return [];const rows=result[0].values.map(values=>Object.fromEntries(result[0].columns.map((c,i)=>[c,values[i]])));
    if(result[0].columns.includes('_id'))e.selection={layer:layer.id,features:rows.map(r=>r._id)};return rows;
  }finally{db.close();}
}
export function registerFormats(e) {
  e.register({id:'file.import',title:t('导入文件','Import file'),group:t('文件','Files'),access:'importFile',fields:[],hidden:true},a=>importGIS(e,a));
  e.register({id:'file.export',title:t('导出数据／工程','Export data / project'),group:t('文件','Files'),access:'exportFile',fields:[layerField(),field('format',t('格式','Format'),'select',{options:['floegis','geojson','gpkg','shp','csv','gpx','kml','tif','asc','png','mbtiles'],default:'geojson'}),field('name',t('文件名','File name')),field('crs',t('导出坐标系（可留空）','Output CRS (optional)')),field('all',t('包含所有矢量图层','Include all vector layers'),'checkbox'),field('minZoom',t('瓦片最低级别','Minimum tile zoom'),'number',{default:0,min:0,max:22}),field('maxZoom',t('瓦片最高级别','Maximum tile zoom'),'number',{default:12,min:0,max:22})]},(a,signal)=>exportGIS(e,a,signal));
  e.register({id:'query.sql',title:t('SQL 属性查询','SQL attribute query'),group:t('查询','Query'),access:'read',fields:[layerField(),field('sql',t('查询 features 表','Query the features table'),'textarea',{default:'SELECT * FROM features LIMIT 100'})]},a=>querySQL(e,a));
}
