// SPDX-License-Identifier: MPL-2.0
import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { EditorEngine } from '../../FloeHeavyEditorSupport/Web/runtime.js';
import { createGIS,sampleGIS,normalizeGIS,registerModelCommands,proj4,defineCRS,vectorLayer,rasterLayer,featureCollection,turf,validateGeometry,transformGeometry,gridSample } from '../Web/model.js';
import { registerAnalysis,compileRasterExpression,terrainRaster,contours,shortestPath,rasterStatistics,geometryDistanceMeters } from '../Web/analysis.js';
import { writeWKB,readWKB,parseCSV,writeGeoPackage,readGeoPackage,writeGeoTIFF,readGeoTIFF,writeASCIIGrid,readASCIIGrid,exportGIS,importGIS,registerFormats,writeShapefile,writeMBTiles,readMBTiles,sql,readWorldFile,writeWorldFile,querySQL } from '../Web/formats.js';
import { registerViewCommands, makeMapSVG, layoutExtent, GISView } from '../Web/view.js';
import { vectorColor, legendEntries } from '../Web/symbology.js';
import { engine as bundledEngine } from '../Web/main.js';
import { unzipSync, unzlibSync } from 'fflate';
import { bytes64,from64 } from '../../FloeHeavyEditorSupport/Web/runtime.js';
globalThis.FloeEditorTestSQLWasm=process.env.FLOE_EDITOR_SQL_WASM;
globalThis.FloeEditorTestSQLiteModule=process.env.FLOE_EDITOR_SQLITE_MODULE;
const make=()=>{const e=new EditorEngine({kind:'gis',create:sampleGIS,normalize:normalizeGIS});registerModelCommands(e);registerAnalysis(e);registerFormats(e);registerViewCommands(e);return e;};
test('UTM southern hemisphere and Mercator round-trip actual coordinates',()=>{
  defineCRS('EPSG:32756');const projected=proj4('EPSG:4326','EPSG:32756',[151.2,-33.9]);assert.ok(Math.abs(projected[0]-333568.94)<1);assert.ok(Math.abs(projected[1]-6247473.34)<1);
  const geographic=proj4('EPSG:32756','EPSG:4326',projected);assert.ok(Math.abs(geographic[0]-151.2)<1e-8);assert.ok(Math.abs(geographic[1]+33.9)<1e-8);
});
test('real spatial join, buffer, routing and persisted undo payload',async()=>{
  const e=make(),zones=e.state.layers[0],sites=e.state.layers[1],roads=e.state.layers[2];
  let response=await e.execute({command:'vector.spatialJoin',revision:0,arguments:{layer:zones.id,target:sites.id,predicate:'intersects',field:'value'}});
  const joined=e.state.layers.at(-1);assert.deepEqual(joined.data.features.map(f=>f.properties.join_count),[1,2]);assert.deepEqual(joined.data.features.map(f=>f.properties.join_sum),[12,52]);
  await e.execute({command:'vector.buffer',revision:0,arguments:{layer:sites.id,meters:100,steps:32}});const area=turf.area(e.state.layers.at(-1).data);assert.ok(area>90000&&area<100000);
  const route=shortestPath(roads.data,[151.15,-33.885],[151.18,-33.87]);assert.ok(route.geometry.coordinates.length>=3);assert.ok(route.properties.lengthMeters>3500&&route.properties.lengthMeters<5000);
  const count=e.state.layers.length;await e.execute({command:'history.undo',revision:0,arguments:{}});assert.equal(e.state.layers.length,count-1);
  const fresh=make();await fresh.load({kind:'gis',revision:3,content:e.payload});await fresh.execute({command:'history.redo',revision:3,arguments:{}});assert.equal(fresh.state.layers.length,count);
});
test('raster band expression is parsed without JavaScript execution',()=>{
  const expression=compileRasterExpression('where(B1>0,(B2-B1)/(B2+B1),0)');assert.equal(expression([1,3]),.5);assert.equal(expression([-1,3]),0);
  assert.throws(()=>compileRasterExpression('globalThis.process.exit()'));assert.throws(()=>compileRasterExpression('B1 +'));
});
test('flat DEM slope and hillshade, contours and ASCII grid use actual grid values',async()=>{
  const flat=rasterLayer('Flat',Array(25).fill(100),5,5,[0,0,5,5],'EPSG:3857');const slope=await terrainRaster(flat,'slope');assert.equal(rasterStatistics(slope).max,0);
  const shade=await terrainRaster(flat,'hillshade',{altitude:45});assert.ok(Math.abs(shade.bands[0][12]-180.312229)<.001);
  const ramp=rasterLayer('Ramp',Array.from({length:25},(_,i)=>i%5),5,5,[0,0,5,5],'EPSG:3857');const lines=contours(ramp,1,.5);assert.ok(lines.features.length>=3);assert.ok(lines.features.every(f=>f.geometry.coordinates.flat().every(p=>p.every(Number.isFinite))));
  const ascii=writeASCIIGrid(ramp),read=readASCIIGrid(ascii,'ramp.asc');assert.deepEqual(read.bands,ramp.bands);assert.deepEqual(read.bounds,ramp.bounds);
});
test('WKB holes, multiple geometry variants and Unicode attributes round-trip through real GeoPackage',async()=>{
  const polygon={type:'Polygon',coordinates:[[[0,0],[4,0],[4,4],[0,4],[0,0]],[[1,1],[1,2],[2,2],[2,1],[1,1]]]};assert.deepEqual(readWKB(writeWKB(polygon)),polygon);
  const geometry={type:'MultiLineString',coordinates:[[[0,0],[1,1]],[[2,2],[3,3]]]};assert.deepEqual(readWKB(writeWKB(geometry)),geometry);
  const layer=vectorLayer('测试 map',[{type:'Feature',geometry:polygon,properties:{name:'中文',value:42.5}},{type:'Feature',geometry,properties:{name:'line',value:12}}]);
  const bytes=await writeGeoPackage([layer]);assert.equal(new TextDecoder().decode(bytes.slice(0,15)),'SQLite format 3');const read=await readGeoPackage(bytes);assert.equal(read[0].name,layer.name);assert.equal(read[0].data.features[0].properties.name,'中文');assert.deepEqual(read[0].data.features[0].geometry,polygon);assert.equal(read[0].data.features[1].properties.value,12);
});
test('GeoTIFF actual IEEE float samples and georeference round-trip',async()=>{
  const original=rasterLayer('Float grid',[1.5,2.5,-9999,4.5],2,2,[10,20,12,22],'EPSG:4326',-9999);
  const bytes=await writeGeoTIFF(original);assert.ok(bytes.length>100);const read=await readGeoTIFF(bytes,'test.tif');assert.equal(read.width,2);assert.equal(read.height,2);assert.deepEqual(read.bands[0],original.bands[0]);assert.deepEqual(read.bounds,original.bounds);assert.equal(read.crs,'EPSG:4326');
});
test('quoted CSV parser preserves embedded line breaks and escaped quotes',()=>{assert.deepEqual(parseCSV('x,y,name\r\n1,2,"a, b"\r\n3,4,"line\nwith ""quote"""'),[['x','y','name'],['1','2','a, b'],['3','4','line\nwith "quote"']]);});

const run=(e,command,args={})=>e.execute({command,revision:e.revision,arguments:args});
function pngPixels(bytes){
  const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),width=view.getUint32(16),height=view.getUint32(20),parts=[];let offset=8;
  while(offset<bytes.length){const n=view.getUint32(offset),type=new TextDecoder().decode(bytes.subarray(offset+4,offset+8));if(type==='IDAT')parts.push(bytes.subarray(offset+8,offset+8+n));offset+=n+12;}
  const compressed=new Uint8Array(parts.reduce((n,p)=>n+p.length,0));let start=0;for(const p of parts){compressed.set(p,start);start+=p.length;}const scan=unzlibSync(compressed),rgba=new Uint8Array(width*height*4);for(let row=0;row<height;row++){assert.equal(scan[row*(width*4+1)],0);rgba.set(scan.subarray(row*(width*4+1)+1,(row+1)*(width*4+1)),row*width*4);}return {width,height,rgba};
}
test('clipboard cuts and pastes across CRSs, keeps typed fields, and respects locks',async()=>{
  const e=make(),sites=e.state.layers[1],target=vectorLayer('Projected',[],'EPSG:3857');e.state.layers.push(target);e.selection={layer:sites.id,features:[sites.data.features[0].id]};
  await run(e,'feature.copy',{layer:sites.id});await run(e,'feature.paste',{layer:target.id,dx:10,dy:20});assert.equal(target.data.features.length,1);const expected=proj4('EPSG:4326','EPSG:3857',sites.data.features[0].geometry.coordinates),actual=target.data.features[0];assert.ok(Math.abs(actual.geometry.coordinates[0]-expected[0]-10)<1e-6);assert.equal(actual.properties.value,12);assert.ok(target.fields.some(f=>f.name==='value'&&f.type==='number'));
  e.selection={layer:sites.id,features:[sites.data.features[0].id]};await run(e,'feature.cut',{layer:sites.id});assert.equal(sites.data.features.length,2);await run(e,'history.undo');assert.equal(e.state.layers[1].data.features.length,3);
  const locked=e.state.layers.find(l=>l.id===target.id);locked.locked=true;await assert.rejects(run(e,'feature.paste',{layer:locked.id}),/Unlock/);
});
test('node editing preserves MultiPolygon holes, closure and Z, and rejects degenerate rings atomically',async()=>{
  const e=make(),geometry={type:'MultiPolygon',coordinates:[[[[0,0,10],[5,0,10],[5,5,10],[0,5,10],[0,0,10]],[[1,1,12],[1,2,12],[2,2,12],[2,1,12],[1,1,12]]]]},layer=vectorLayer('holes',[{type:'Feature',geometry,properties:{}}]);e.state.layers.push(layer);const id=layer.data.features[0].id;
  await run(e,'feature.node',{layer:layer.id,feature:id,path:'0,1,0',action:'set',x:1.2,y:1.1});const ring=layer.data.features[0].geometry.coordinates[0][1];assert.deepEqual(ring[0],[1.2,1.1,12]);assert.deepEqual(ring[0],ring.at(-1));
  await run(e,'feature.node',{layer:layer.id,feature:id,path:'0,1,1',action:'delete'});const current=e.state.layers.find(l=>l.id===layer.id),before=structuredClone(current.data);await assert.rejects(run(e,'feature.node',{layer:layer.id,feature:id,path:'0,1,1',action:'delete'}),/three/);assert.deepEqual(e.state.layers.find(l=>l.id===layer.id).data,before);
  const point=e.state.layers[1];await assert.rejects(run(e,'feature.geometries',{changes:[{layer:point.id,feature:point.data.features[0].id,geometry:{type:'Point',coordinates:[1,2]}},{layer:point.id,feature:point.data.features[1].id,geometry:{type:'LineString',coordinates:[[0,0]]}}]}));assert.equal(e.state.layers[1].data.features[0].geometry.coordinates[0],151.165);
  assert.throws(()=>validateGeometry({type:'Polygon',coordinates:[[[0,0],[1,0],[1,1],[0,1]]]}),/closing/);
});
test('empty-layer schema survives rename, conversion, save and reopen',async()=>{
  const e=make(),layer=vectorLayer('Empty');e.state.layers.push(layer);await run(e,'field.edit',{layer:layer.id,name:'population',action:'add',type:'number',value:'3'});await run(e,'field.edit',{layer:layer.id,name:'population',newName:'人数',action:'rename',type:'string'});assert.equal(layer.fields[0].name,'人数');assert.equal(layer.fields[0].type,'number');
  const saved=await exportGIS(e,{format:'floegis',name:'map'}),fresh=make();await importGIS(fresh,{name:'map.floegis',base64:saved.artifacts[0].base64});assert.deepEqual(fresh.state.layers.at(-1).fields,layer.fields);
});
test('WKB supports Z and M in lines, polygon holes and nested collections, including big endian input',()=>{
  const variants=[{type:'LineString',coordinates:[[0,0,3],[1,1,4]]},{type:'Polygon',coordinates:[[[0,0,1,2],[2,0,1,2],[2,2,1,2],[0,0,1,2]]]},{type:'MultiPoint',layout:'XYM',coordinates:[[1,2,5],[3,4,6]]},{type:'GeometryCollection',geometries:[{type:'Point',coordinates:[1,2,3]},{type:'LineString',coordinates:[[0,0],[1,1]]}]}];
  for(const geometry of variants)assert.deepEqual(readWKB(writeWKB(geometry)),geometry);const bytes=new Uint8Array(21),v=new DataView(bytes.buffer);v.setUint8(0,0);v.setUint32(1,1);v.setFloat64(5,2.5);v.setFloat64(13,3.5);assert.deepEqual(readWKB(bytes),{type:'Point',coordinates:[2.5,3.5]});assert.throws(()=>readWKB(bytes.subarray(0,10)),/Truncated/);
});
test('GeoPackage preserves projected CRS, string IDs, null geometry and conflicting attribute names',async()=>{
  const layer=vectorLayer('保留',[{type:'Feature',id:'original-A',geometry:{type:'Point',coordinates:[2000,3000,50]},properties:{fid:'user-fid',geom:'user-geom',_floe_fid:'custom',bool:true,json:{a:[1,2]},nullable:null}},{type:'Feature',id:99,geometry:null,properties:{bool:false}}],'EPSG:3857');
  const bytes=await writeGeoPackage([layer]),read=(await readGeoPackage(bytes))[0];assert.equal(read.crs,'EPSG:3857');assert.equal(read.data.features[0].id,'original-A');assert.deepEqual(read.data.features[0].geometry,layer.data.features[0].geometry);assert.deepEqual(read.data.features[0].properties,layer.data.features[0].properties);assert.equal(read.data.features[1].id,99);assert.equal(read.data.features[1].geometry,null);assert.equal(read.data.features[1].properties.bool,false);
});
test('real Shapefile archives preserve holes, multipart families, UTF-8 and long field mapping',async()=>{
  const geometry={type:'Polygon',coordinates:[[[0,0],[5,0],[5,5],[0,5],[0,0]],[[1,1],[1,2],[2,2],[2,1],[1,1]]]},collection=featureCollection([{type:'Feature',id:'poly',geometry,properties:{名称:'地块',long_field_one:1,long_field_two:2}},{type:'Feature',id:'multi',geometry:{type:'MultiPoint',coordinates:[[1,2],[3,4]]},properties:{名称:'点'}}]);
  const bytes=writeShapefile(collection,'fixture'),files=unzipSync(bytes);for(const extension of ['.shp','.shx','.dbf','.prj','.cpg'])assert.ok(Object.keys(files).filter(n=>n.endsWith(extension)).length===2);const shpBytes=files[Object.keys(files).find(n=>n.endsWith('polygons.shp'))];assert.equal(new DataView(shpBytes.buffer).getUint32(0),9994);
  const e=make();await importGIS(e,{name:'fixture.zip',base64:bytes64(bytes)});const imported=e.state.layers.slice(4),polygon=imported.flatMap(l=>l.data.features).find(f=>f.id==='poly');assert.equal(polygon.geometry.type,'Polygon');assert.equal(polygon.geometry.coordinates.length,2);assert.equal(polygon.properties.名称,'地块');assert.equal(polygon.properties.long_field_one,1);assert.equal(polygon.properties.long_field_two,2);const multi=imported.flatMap(l=>l.data.features).find(f=>f.id==='multi');assert.equal(multi.geometry.type,'MultiPoint');assert.equal(multi.geometry.coordinates.length,2);multi.geometry.coordinates.forEach((c,i)=>c.forEach((v,j)=>assert.ok(Math.abs(v-collection.features[1].geometry.coordinates[i][j])<1e-12)));
});
test('raster-to-MBTiles writes real PNG tiles with TMS rows and reloadable metadata',async()=>{
  const layer=rasterLayer('NE quadrant',Array(16).fill(50),4,4,[0,0,180,85.05112878]);layer.style={palette:'gray',band:0,min:0,max:100};const bytes=await writeMBTiles(layer,{minZoom:1,maxZoom:1}),SQL=await sql(),db=new SQL.Database(bytes);try{const rows=db.exec('SELECT zoom_level,tile_column,tile_row,tile_data FROM tiles')[0].values;assert.equal(rows.length,1);assert.deepEqual(rows[0].slice(0,3),[1,1,1]);const image=pngPixels(rows[0][3]);assert.equal(image.width,256);assert.equal(image.rgba[0],128);assert.equal(image.rgba[3],255);}finally{db.close();}const loaded=await readMBTiles(bytes,'offline.mbtiles');assert.equal(loaded.tileCount,1);assert.equal(loaded.metadata.format,'png');
});
test('north-up world-file pixel centers round-trip and rotated grids are rejected explicitly',()=>{const layer=rasterLayer('grid',Array(6).fill(1),3,2,[100,200,130,220],'EPSG:3857');assert.deepEqual(readWorldFile(writeWorldFile(layer),3,2),layer.bounds);assert.throws(()=>readWorldFile('10\n1\n0\n-10\n105\n215',3,2),/north-up/);});
test('read-only SQLite queries bind quoted field names, link selection and reject writes',async()=>{const e=make(),layer=e.state.layers[1];await run(e,'attribute.set',{layer:layer.id,feature:layer.data.features[0].id,field:'quote"name',value:'ok'});const rows=await querySQL(e,{layer:layer.id,sql:'SELECT _id, "quote""name" AS quoted FROM features WHERE value < 20'});assert.equal(rows.length,1);assert.equal(rows[0].quoted,'ok');assert.equal(e.selection.features[0],String(layer.data.features[0].id));assert.deepEqual(await querySQL(e,{layer:layer.id,sql:'SELECT * FROM features WHERE value > 1000'}),[]);await assert.rejects(querySQL(e,{layer:layer.id,sql:'SELECT 1; DELETE FROM features'}),/single SELECT|readonly|read-only/);assert.equal(e.state.layers[1].data.features.length,3);});
test('geometry distance uses nearest edges, disjoint excludes any intersection, and routing snaps within segments',async()=>{
  const polygon=turf.polygon([[[0,0],[1,0],[1,1],[0,1],[0,0]]]),point=turf.point([.5,1.001]);assert.ok(geometryDistanceMeters(point,polygon)<120);assert.equal(geometryDistanceMeters(turf.point([.5,.5]),polygon),0);
  const e=make(),source=vectorLayer('source',[turf.point([.5,.5]),turf.point([5,5])]),targets=vectorLayer('targets',[polygon,turf.polygon([[[2,2],[3,2],[3,3],[2,3],[2,2]]])]);e.state.layers.push(source,targets);const result=await run(e,'query.spatial',{layer:source.id,target:targets.id,predicate:'disjoint'});assert.equal(result.result.length,1);assert.equal(e.selection.features[0],source.data.features[1].id);
  const route=shortestPath(featureCollection([turf.lineString([[0,0],[1,0]])]),[.2,.1],[.8,-.1]);assert.ok(Math.abs(route.geometry.coordinates[0][0]-.2)<.01);assert.ok(Math.abs(route.geometry.coordinates.at(-1)[0]-.8)<.01);assert.ok(route.properties.lengthMeters>60000&&route.properties.lengthMeters<70000);
});
test('topology operations create editable output layers and retain holes and attributes',async()=>{
  const e=make(),outer=vectorLayer('outer',[turf.polygon([[[0,0],[4,0],[4,4],[0,4],[0,0]]],{name:'parcel'})]),hole=vectorLayer('hole',[turf.polygon([[[1,1],[2,1],[2,2],[1,2],[1,1]]])]);e.state.layers.push(outer,hole);await run(e,'vector.difference',{layer:outer.id,target:hole.id});const result=e.state.layers.at(-1);assert.equal(result.data.features[0].geometry.coordinates.length,2);assert.equal(result.locked,false);
  const lines=vectorLayer('lines',[turf.multiLineString([[[0,0],[4,0]],[[0,1],[4,1]]],{road:'main'})]),cuts=vectorLayer('cuts',[turf.lineString([[2,-1],[2,2]])]);e.state.layers.push(lines,cuts);await run(e,'vector.split',{layer:lines.id,target:cuts.id});assert.equal(e.state.layers.at(-1).data.features.length,4);assert.ok(e.state.layers.at(-1).data.features.every(f=>f.properties.road==='main'));
  const broken=vectorLayer('bowtie',[turf.polygon([[[0,0],[2,2],[0,2],[2,0],[0,0]]])]);e.state.layers.push(broken);await run(e,'vector.repair',{layer:broken.id,method:'unkink'});assert.equal(e.state.layers.at(-1).data.features.length,2);
});
test('raster operators, edge sampling, resampling, classification and nodata terrain use real samples',async()=>{
  assert.equal(compileRasterExpression('-2^2')([]),-4);assert.equal(compileRasterExpression('where(B1>=2 && B2!=0,B1/B2,0)')([4,2]),2);const source=rasterLayer('edge',[1,2,3,4],2,2,[0,0,2,2],'EPSG:3857');assert.equal(gridSample(source,0,2,0,'bilinear'),1);assert.equal(gridSample(source,-.01,2,0,'bilinear'),source.nodata);
  const e=make();e.state.layers.push(source);await run(e,'raster.resample',{layer:source.id,width:4,height:4,crs:'EPSG:3857',method:'nearest'});assert.deepEqual(e.state.layers.at(-1).bands[0],[1,1,2,2,1,1,2,2,3,3,4,4,3,3,4,4]);assert.equal(e.selection.layer,e.state.layers.at(-1).id);
  source.bands[0][0]=source.nodata;const slope=await terrainRaster(source,'slope');assert.equal(slope.bands[0][0],source.nodata);await run(e,'raster.classify',{layer:source.id,method:'threshold',classes:2,threshold:2});assert.deepEqual(e.state.layers.at(-1).bands[0],[-9999,1,2,2]);
});
test('layout restores saved extent and applies the same class colors, opacity, holes, labels and raster palette',async()=>{
  const e=make();e.state.layers=e.state.layers.slice(0,2);e.state.crs='EPSG:3857';e.state.layers[0].opacity=.4;e.state.layers[0].style={...e.state.layers[0].style,mode:'categorical',field:'name',label:'name'};e.state.view={center:[151.18,-33.885],zoom:13,extent:[16825000,-4015000,16835000,-4010000],extentCRS:'EPSG:3857'};
  const output=await makeMapSVG(e,{width:1000,height:600});assert.ok(output.includes('data-extent="16825000,-4015000,16835000,-4010000"'));assert.ok(output.includes('opacity="0.4"'));assert.ok(output.includes('fill-rule="evenodd"'));assert.ok(output.includes('Districts · West'));assert.ok(output.includes('>West</text>'));assert.ok(!output.includes('NaN'));
  const raster=rasterLayer('Gray',[0,100,0,100],2,2,[16825000,-4015000,16835000,-4010000],'EPSG:3857');raster.style={palette:'gray',band:0,min:0,max:100};e.state.layers=[raster];const image=await makeMapSVG(e,{width:300,height:250}),base64=/href="data:image\/png;base64,([^"]+)"/.exec(image)[1],pixels=pngPixels(from64(base64));assert.equal(pixels.width,200);for(let i=0;i<pixels.rgba.length;i+=4)assert.equal(pixels.rgba[i],pixels.rgba[i+1]);
  e.state.layout.scaleDenominator=10000;const fixed=layoutExtent(e,1000,650);assert.ok(fixed.extent[2]-fixed.extent[0]<10000);
});
test('map disposal releases each owned resource once, retaining a newly requested view',()=>{
  const e=make(),view=new GISView(e);let released=0,disposed=0;view.resources=[()=>released++,()=>released++];view.mapState=e.state;view.map={getSize:()=>[100,100],getView:()=>({getProjection:()=>({getCode:()=> 'EPSG:3857'}),getCenter:()=>[0,0],getZoom:()=>2,calculateExtent:()=>[0,0,1,1]}),setTarget:()=>{},dispose:()=>disposed++};e.liveView={center:[151,-33],zoom:10};view.dispose();view.dispose();assert.equal(released,2);assert.equal(disposed,1);assert.deepEqual(e.liveView.center,[151,-33]);
});

test('intersection, union, clipped multiline, dissolve and hull run through real geometry engines',async()=>{
  const e=make(),first=vectorLayer('A',[turf.polygon([[[0,0],[2,0],[2,2],[0,2],[0,0]]],{zone:'x'})]),second=vectorLayer('B',[turf.polygon([[[1,0],[3,0],[3,2],[1,2],[1,0]]],{zone:'x'})]);e.state.layers.push(first,second);
  await run(e,'vector.intersection',{layer:first.id,target:second.id});assert.deepEqual(turf.bbox(e.state.layers.at(-1).data),[1,0,2,2]);await run(e,'vector.union',{layer:first.id,target:second.id});assert.deepEqual(turf.bbox(e.state.layers.at(-1).data),[0,0,3,2]);
  const lines=vectorLayer('L',[turf.multiLineString([[[-1,.5],[4,.5]],[[-1,1.5],[4,1.5]]],{kind:'road'})]);e.state.layers.push(lines);await run(e,'vector.clip',{layer:lines.id,target:first.id});assert.equal(e.state.layers.at(-1).data.features.length,2);assert.deepEqual(turf.bbox(e.state.layers.at(-1).data),[0,.5,2,1.5]);
  const combined=vectorLayer('combined',[...first.data.features,...second.data.features]);e.state.layers.push(combined);await run(e,'vector.dissolve',{layer:combined.id,field:'zone'});assert.equal(e.state.layers.at(-1).data.features.length,1);await run(e,'vector.hull',{layer:combined.id});assert.deepEqual(turf.bbox(e.state.layers.at(-1).data),[0,0,3,2]);
});
test('raster crop, mosaic, IDW, profile and zonal outputs contain real editable values',async()=>{
  const e=make(),raster=rasterLayer('R',[10,20,30,40],2,2,[0,0,2,2]),mask=vectorLayer('Mask',[turf.polygon([[[0,0],[1,0],[1,2],[0,2],[0,0]]],{name:'west'})]);e.state.layers.push(raster,mask);
  await run(e,'raster.clip',{layer:raster.id,target:mask.id});assert.deepEqual(e.state.layers.at(-1).bands[0],[10,30]);await run(e,'raster.zonal',{layer:raster.id,target:mask.id,field:'name'});assert.equal(e.state.layers.at(-1).data.features[0].properties.zone_count,2);assert.equal(e.state.layers.at(-1).data.features[0].properties.zone_mean,20);assert.equal(e.selection.layer,e.state.layers.at(-1).id);
  const overlay=rasterLayer('overlay',[70,80,90,100],2,2,[2,0,4,2]);e.state.layers.push(overlay);await run(e,'raster.mosaic',{layer:raster.id,target:overlay.id,width:4,height:2});assert.deepEqual(e.state.layers.at(-1).bands[0],[10,20,70,80,30,40,90,100]);
  const points=vectorLayer('constant',[turf.point([0,0],{height:25}),turf.point([1,1],{height:25}),turf.point([0,1],{height:25})]);e.state.layers.push(points);await run(e,'raster.idw',{layer:points.id,field:'height',width:4,height:4,power:2});assert.ok(e.state.layers.at(-1).bands[0].every(v=>Math.abs(v-25)<1e-10));
  const line=vectorLayer('profile',[turf.lineString([[.5,.5],[.5,1.5]])]);e.state.layers.push(line);const result=await run(e,'terrain.profile',{layer:raster.id,target:line.id,samples:3});assert.equal(result.result.length,3);assert.equal(result.result[0].elevation,30);assert.ok(Math.abs(result.result[2].elevation-10)<1e-9);
});
test('multi-band UTM GeoTIFF preserves float samples and nodata at the declared Float32 precision',async()=>{
  const layer=rasterLayer('UTM',[1.23456789,2.5,3.5,-9999],2,2,[330000,6240000,330020,6240020],'EPSG:32756');layer.bands.push([5.5,6.5,7.5,-9999]);const bytes=await writeGeoTIFF(layer),read=await readGeoTIFF(bytes,'multiband.tif');assert.equal(read.crs,'EPSG:32756');assert.equal(read.bands.length,2);assert.deepEqual(read.bands,layer.bands.map(b=>b.map(Math.fround)));assert.deepEqual(read.bounds,layer.bounds);assert.equal(read.nodata,layer.nodata);
});
test('project and CSV imports reject malformed numeric/geometry data and keep null geometry',async()=>{
  const e=make();await assert.rejects(importGIS(e,{name:'bad.csv',base64:bytes64(new TextEncoder().encode('x,y\n,2'))}),/empty/);
  const result=await exportGIS(e,{layer:e.state.layers[1].id,format:'csv'});const fresh=make();await importGIS(fresh,{name:'sites.csv',base64:result.artifacts[0].base64});assert.equal(fresh.state.layers.at(-1).data.features.length,3);
  await importGIS(fresh,{name:'null.csv',base64:bytes64(new TextEncoder().encode('wkt,name\n,empty'))});assert.equal(fresh.state.layers.at(-1).data.features[0].geometry,null);
  const state=sampleGIS();state.layers[0].opacity='1" onload="bad';await assert.rejects(importGIS(e,{name:'bad.floegis',base64:bytes64(new TextEncoder().encode(JSON.stringify(state)))}),/numeric/);
});

test('public bundled dispatcher executes the native smoke plan and produces re-readable GeoPackage and SVG',async()=>{
  await run(bundledEngine,'project.sample');const calculation=await run(bundledEngine,'field.calculate',{name:'area_m2',operation:'area',source:'',operand:1});assert.equal(calculation.result.count,2);assert.ok(bundledEngine.state.layers[0].data.features.every(f=>f.properties.area_m2>1e6));
  const gpkg=await run(bundledEngine,'file.export',{format:'gpkg',name:'GIS-smoke',crs:'EPSG:3857',all:false});assert.equal(gpkg.artifacts.length,1);const reopened=await readGeoPackage(from64(gpkg.artifacts[0].base64));assert.equal(reopened[0].crs,'EPSG:3857');assert.equal(reopened[0].data.features.length,2);assert.ok(reopened[0].data.features.every(f=>f.properties.area_m2>1e6));
  const svg=await run(bundledEngine,'layout.export',{format:'svg',width:640,height:480});assert.equal(svg.artifacts[0].mediaType,'image/svg+xml');const source=new TextDecoder().decode(from64(svg.artifacts[0].base64));assert.ok(source.startsWith('<svg'));assert.ok(source.includes('data:image/png;base64,'));assert.ok(!source.replace(/href="data:image\/png;base64,[^"]*"/g,'').includes('NaN'));assert.ok(bundledEngine.catalog().some(c=>c.id==='query.sql'));
});

test('nullable graduated fields share actual class ranges with the legend and mixed values remain editable JSON',async()=>{
  const layer=vectorLayer('classes',[turf.point([0,0],{value:null,mixed:'a'}),turf.point([1,1],{value:10,mixed:2}),turf.point([2,2],{value:20,mixed:{nested:true}})]);layer.style={...layer.style,mode:'graduated',field:'value',classes:2};assert.equal(vectorColor(layer,{value:null}),'#89939d');const entries=legendEntries(layer);assert.equal(entries[0].label,'10 – 15');assert.equal(entries[1].label,'15 – 20');assert.equal(entries[0].color,vectorColor(layer,{value:12}));assert.equal(layer.fields.find(f=>f.name==='mixed').type,'json');
  const e=make();e.state.layers.push(layer);await run(e,'attribute.set',{layer:layer.id,feature:layer.data.features[0].id,field:'mixed',value:'"changed"'});assert.equal(e.state.layers.at(-1).data.features[0].properties.mixed,'changed');const reopened=(await readGeoPackage(await writeGeoPackage([e.state.layers.at(-1)])))[0];assert.deepEqual(reopened.data.features.map(f=>f.properties.mixed),['changed',2,{nested:true}]);
});

test('official SQLite bridge binds SQL values, copies blobs and reuses/reset/frees statements',async()=>{
  const SQL=await sql();assert.equal(SQL.engineInfo.package,'@sqlite.org/sqlite-wasm');assert.equal(SQL.engineInfo.sqliteVersion,'3.54.1');
  const db=new SQL.Database();try{
    db.run('CREATE TABLE binding(id INTEGER PRIMARY KEY, name TEXT, bytes BLOB, amount REAL, empty_value TEXT)');
    const insert=db.prepare('INSERT INTO binding VALUES(?,?,?,?,?)'),blob=Uint8Array.from([0,255,1,128]);
    assert.equal(insert.run([1,"中文'); DROP TABLE binding; --",blob,1.25,null]),insert);
    insert.run([2,'second',Uint8Array.from([9,8]),-2.5,null]);assert.equal(insert.free(),true);assert.equal(insert.free(),false);
    const statement=db.prepare('SELECT id,name,bytes,amount,empty_value FROM binding WHERE id=?');
    assert.equal(statement.bind([1]),true);assert.equal(statement.step(),true);assert.deepEqual(statement.getColumnNames(),['id','name','bytes','amount','empty_value']);
    const first=statement.getAsObject();assert.equal(first.name,"中文'); DROP TABLE binding; --");assert.deepEqual(first.bytes,blob);assert.equal(first.empty_value,null);
    assert.equal(statement.reset(),true);statement.bind([2]);assert.equal(statement.step(),true);assert.equal(statement.get()[1],'second');assert.deepEqual(first.bytes,blob);assert.equal(statement.step(),false);statement.free();
    assert.equal(db.exec('SELECT count(*) FROM binding')[0].values[0][0],2);
  }finally{db.close();db.close();}
});
test('official SQLite parser counts SQL statements without splitting quoted/comment semicolons',async()=>{
  const SQL=await sql(),db=new SQL.Database();try{
    const single=[...db.iterateStatements("SELECT 'one;two' AS value; -- semicolon ;\n /* ; */")];assert.equal(single.length,1);
    assert.equal([...db.iterateStatements("SELECT ';'; /* ; */ SELECT 2")].length,2);
    assert.deepEqual(db.exec("SELECT ';' AS marker;SELECT 2 AS second"),[{columns:['marker'],values:[[';']]},{columns:['second'],values:[[2]]}]);
    assert.deepEqual(db.exec('SELECT 1 WHERE 0'),[]);assert.throws(()=>db.exec('this is invalid SQL'));
  }finally{db.close();}
});
test('official SQLite binary import can grow, transact, export and reopen without borrowed heap aliases',async()=>{
  const SQL=await sql(),original=new SQL.Database();original.run('CREATE TABLE items(id INTEGER PRIMARY KEY, payload BLOB);INSERT INTO items VALUES(1,zeroblob(3));');const exported=original.export();original.close();
  assert.equal(new TextDecoder().decode(exported.subarray(0,16)),'SQLite format 3\0');
  const imported=new SQL.Database(exported);try{
    const payload=new Uint8Array(20000).fill(73);imported.run('INSERT INTO items VALUES(?,?)',[2,payload]);imported.run('BEGIN;DELETE FROM items;ROLLBACK;');
    assert.equal(imported.exec('SELECT count(*) FROM items')[0].values[0][0],2);const grown=imported.export();assert.ok(grown.length>exported.length);
    const reopened=new SQL.Database(grown);try{assert.equal(reopened.exec('PRAGMA integrity_check')[0].values[0][0],'ok');assert.equal(reopened.exec('SELECT length(payload) FROM items WHERE id=2')[0].values[0][0],20000);}finally{reopened.close();}
    const held=imported.prepare('SELECT * FROM items');imported.close();assert.throws(()=>held.step(),/closed|freed/);assert.equal(held.free(),false);
  }finally{imported.close();}
  assert.throws(()=>new SQL.Database(new TextEncoder().encode('not a SQLite database')));
});
test('official SQLite closes parser statements when iteration ends early and does not add contrib-only functions',async()=>{
  const SQL=await sql(),db=new SQL.Database();try{
    for(const statement of db.iterateStatements('SELECT 1;SELECT 2')){assert.equal(statement.step(),true);break;}
    assert.equal(db.statements.size,0);db.run('CREATE TABLE still_usable(value TEXT)');
    assert.throws(()=>db.exec('SELECT lower_quartile(1)'),/no such function/);
    assert.equal(db.exec('SELECT sqlite_version()')[0].values[0][0],'3.54.1');
  }finally{db.close();}
});
