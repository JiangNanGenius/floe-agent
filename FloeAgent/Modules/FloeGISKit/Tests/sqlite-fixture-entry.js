// SPDX-License-Identifier: MPL-2.0
// Node-only qualification fixture producer. Not bundled in the editor.
import fs from 'node:fs/promises';
import path from 'node:path';
import {vectorLayer,rasterLayer} from '../Web/model.js';
import {writeGeoPackage,readGeoPackage,writeMBTiles,readMBTiles,sql} from '../Web/formats.js';
export async function writeFixtures({output,moduleURL,wasmPath}) {
  globalThis.FloeEditorTestSQLiteModule=moduleURL;
  globalThis.FloeEditorTestSQLWasm=wasmPath;
  const layer=vectorLayer('SQLite许可替换检查',[
    {type:'Feature',id:'source-A',geometry:{type:'Point',coordinates:[2000,3000,40]},properties:{name:'中文河岸',value:42.5,bool:true,json:{a:[1,2]},nullable:null}},
    {type:'Feature',id:99,geometry:{type:'Polygon',coordinates:[[[0,0],[4,0],[4,4],[0,4],[0,0]],[[1,1],[1,2],[2,2],[2,1],[1,1]]]},properties:{name:'孔洞',value:12,bool:false,json:{source:'fixture'},nullable:null}}
  ],'EPSG:3857');
  const gpkg=await writeGeoPackage([layer]);
  const raster=rasterLayer('Real PNG tile',[0,100,50,75],2,2,[0,0,180,85.05112878]);
  raster.style={palette:'gray',band:0,min:0,max:100};
  const tiles=await writeMBTiles(raster,{minZoom:1,maxZoom:1});
  await fs.mkdir(output,{recursive:true});
  await fs.writeFile(path.join(output,'official-sqlite.gpkg'),gpkg);
  await fs.writeFile(path.join(output,'official-sqlite.mbtiles'),tiles);
  const reopened=await readGeoPackage(gpkg),mbtiles=await readMBTiles(tiles,'official-sqlite.mbtiles');
  const info={engine:(await sql()).engineInfo,geoPackage:{bytes:gpkg.length,layers:reopened.length,features:reopened[0].data.features.length,crs:reopened[0].crs},mbtiles:{bytes:tiles.length,tiles:mbtiles.tileCount,format:mbtiles.metadata.format}};
  await fs.writeFile(path.join(output,'node-binary-roundtrip.json'),JSON.stringify(info,null,2)+'\n');
  return info;
}
