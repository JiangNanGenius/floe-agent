// SPDX-License-Identifier: MPL-2.0
// Shared map, print and offline-tile appearance. No browser globals are needed.
export const palette=['#2379b5','#de7d2e','#3b9b70','#b25aa1','#b3a52e','#4b4eb3','#bf5353','#55a5a3'];
const numeric=value=>value!==null&&value!==undefined&&value!==''&&Number.isFinite(Number(value));
export function vectorColor(layer,properties={}) {
  const style=layer.style??{},value=properties[style.field];
  if(style.mode==='categorical'){let hash=0;for(const c of String(value??''))hash=(hash*31+c.charCodeAt(0))>>>0;return palette[hash%palette.length];}
  if(style.mode==='graduated'){
    const values=layer.data.features.map(f=>f.properties[style.field]).filter(numeric).map(Number);
    if(!values.length||!numeric(value))return '#89939d';
    const min=Math.min(...values),max=Math.max(...values),classes=Math.max(2,Math.min(16,Number(style.classes)||5)),index=Math.min(classes-1,Math.max(0,Math.floor((Number(value)-min)/(max-min||1)*classes)));
    return palette[Math.round(index/(classes-1)*(palette.length-1))];
  }return /^#[0-9a-f]{6}$/i.test(style.color)?style.color:'#2879c7';
}
export function vectorFill(layer,color){const style=layer.style??{};if(style.mode==='single'&&/^#[0-9a-f]{8}$/i.test(style.fill))return style.fill;const base=style.mode==='single'&&/^#[0-9a-f]{6}$/i.test(style.fill)?style.fill:color,opacity=Math.max(0,Math.min(1,Number(style.fillOpacity??.24)));return base+Math.round(opacity*255).toString(16).padStart(2,'0');}
export function legendEntries(layer){
  if(layer.kind!=='vector')return [{label:layer.name,color:layer.kind==='tiles'?'#80949a':'#769e74'}];
  const style=layer.style??{};
  if(style.mode==='categorical')return [...new Set(layer.data.features.map(f=>String(f.properties[style.field]??'')))].map(value=>({label:value||'∅',color:vectorColor(layer,{[style.field]:value})}));
  if(style.mode==='graduated'){
    const values=layer.data.features.map(f=>f.properties[style.field]).filter(numeric).map(Number);if(!values.length)return [];
    const min=Math.min(...values),max=Math.max(...values),classes=Math.max(2,Math.min(16,Number(style.classes)||5));
    return Array.from({length:classes},(_,i)=>{const low=min+(max-min)*i/classes,high=min+(max-min)*(i+1)/classes;return {label:`${Number(low.toPrecision(5))} – ${Number(high.toPrecision(5))}`,color:vectorColor(layer,{[style.field]:(low+high)/2})};});
  }return [{label:layer.name,color:vectorColor(layer)}];
}
export function rasterRange(layer,band=0){let min=Infinity,max=-Infinity;for(const v of layer.bands[band]??[])if(v!==layer.nodata&&Number.isFinite(v)){min=Math.min(min,v);max=Math.max(max,v);}return {min:layer.style?.min??(min===Infinity?0:min),max:layer.style?.max??(max===-Infinity?1:max)};}
export function rasterPixel(layer,values,range=rasterRange(layer,layer.style?.band??0)){
  const band=Math.max(0,Math.min(layer.bands.length-1,layer.style?.band??0)),v=values[band];if(v===layer.nodata||!Number.isFinite(v))return [0,0,0,0];
  const scale=Math.min(1,Math.max(0,(v-range.min)/(range.max-range.min||1)));let rgb;
  if(layer.style?.palette==='rgb'&&values.length>=3)rgb=values.slice(0,3);
  else if(layer.style?.palette==='gray')rgb=[scale*255,scale*255,scale*255];
  else if(layer.style?.palette==='classes'){const c=palette[((Math.round(v)-1)%palette.length+palette.length)%palette.length];rgb=[parseInt(c.slice(1,3),16),parseInt(c.slice(3,5),16),parseInt(c.slice(5,7),16)];}
  else rgb=[Math.min(255,40+scale*260),Math.max(30,145+Math.sin(scale*Math.PI)*75-scale*65),Math.max(25,170-scale*145)];
  return [...rgb.map(x=>Math.max(0,Math.min(255,Math.round(x)))),layer.source?.image&&values.length>3?Math.max(0,Math.min(255,values[3])):255];
}
export function rasterRGBA(layer){const result=new Uint8ClampedArray(layer.width*layer.height*4),range=rasterRange(layer,layer.style?.band??0);for(let i=0;i<layer.width*layer.height;i++)result.set(rasterPixel(layer,layer.bands.map(b=>b[i]),range),i*4);return result;}
