// SPDX-License-Identifier: MPL-2.0
// Source-space interpolation uses OpenType support tents and delta subtraction.
// The same model is used by fontc/fontdrasil; no distance-weighted approximation.
import { clone } from '../../FloeHeavyEditorSupport/Web/runtime.js';

export function mapCoordinate(axis, value, inverse=false) {
  const mapping=(axis.mapping??[]).map(pair=>inverse?[pair[1],pair[0]]:pair).sort((a,b)=>a[0]-b[0]);
  if(!mapping.length)return value;
  if(value<=mapping[0][0])return value+mapping[0][1]-mapping[0][0];
  if(value>=mapping.at(-1)[0])return value+mapping.at(-1)[1]-mapping.at(-1)[0];
  const index=mapping.findIndex(pair=>pair[0]>=value),[x0,y0]=mapping[index-1],[x1,y1]=mapping[index];
  return y0+(y1-y0)*(value-x0)/(x1-x0);
}
export function parseLocation(axes, input={}) {
  const location=typeof input==='string'?Object.fromEntries(input.split(',').filter(s=>s.trim()).map(part=>{
    const pieces=part.split('=');if(pieces.length!==2||!pieces[0].trim()||!pieces[1].trim())throw new Error('Use axis=value, separated by commas');
    return [pieces[0].trim(),Number(pieces[1])];
  })):clone(input);
  for(const tag of Object.keys(location))if(!axes.some(a=>a.tag===tag))throw new Error('Unknown variation axis '+tag);
  for(const axis of axes){const value=Number(location[axis.tag]??axis.default);if(!Number.isFinite(value)||value<axis.min||value>axis.max)throw new Error('Location outside '+axis.tag+' axis range');location[axis.tag]=value;}
  return location;
}
export function normalizedLocation(axes, location) {
  location=parseLocation(axes,location);
  return axes.map(axis=>{
    const value=mapCoordinate(axis,location[axis.tag]),middle=mapCoordinate(axis,axis.default);
    const span=value<middle?middle-mapCoordinate(axis,axis.min):mapCoordinate(axis,axis.max)-middle;
    return Math.abs(value-middle)<1e-10?0:(value-middle)/(span||1);
  });
}
const compare=(a,b)=>{for(let i=0;i<Math.min(a.length,b.length);i++){const diff=Array.isArray(a[i])?compare(a[i],b[i]):a[i]-b[i];if(diff)return diff;}return a.length-b.length;};
function scalar(location, support) {
  let value=1;
  for(let axis=0;axis<support.length;axis++){
    const [low,peak,high]=support[axis],position=location[axis];
    if(peak===0||position===peak)continue;
    if(position<=low||position>=high)return 0;
    value*=position<peak?(position-low)/(peak-low):(position-high)/(peak-high);
  }
  return value;
}
export function variationWeights(font, input) {
  const axes=font.axes??[],location=normalizedLocation(axes,input);
  const sources=[{glyphs:font.glyphs,kerning:font.kerning,info:font.info,location:Object.fromEntries(axes.map(a=>[a.tag,a.default]))},...(font.masters??[])];
  const records=sources.map((source,index)=>({source,index,location:normalizedLocation(axes,source.location??{})}));
  const keys=new Set();for(const record of records){const key=record.location.join(',');if(keys.has(key))throw new Error('Multiple masters share a variation location');keys.add(key);}
  const onAxis=axes.map(()=>new Set());
  for(const record of records){const nonzero=record.location.flatMap((v,i)=>v?[i]:[]);if(nonzero.length===1)onAxis[nonzero[0]].add(record.location[nonzero[0]]);}
  const key=record=>{const active=record.location.flatMap((v,i)=>v?[i]:[]);return [active.length,-active.filter(i=>onAxis[i].has(record.location[i])).length,active,active.map(i=>Math.sign(record.location[i])),active.map(i=>Math.abs(record.location[i]))];};
  records.sort((a,b)=>compare(key(a),key(b)));
  const supports=[];
  for(const record of records){
    const region=record.location.map(value=>value<0?[-1,value,0]:value>0?[0,value,1]:[0,0,0]);
    const active=record.location.map(v=>Boolean(v));
    for(const previous of supports){
      if(previous.some((tent,i)=>Boolean(tent[1])!==active[i]))continue;
      if(!region.every(([low,peak,high],i)=>previous[i][1]===peak||low<previous[i][1]&&previous[i][1]<high))continue;
      let best=-1,cuts=[];
      for(let i=0;i<region.length;i++){
        const [low,peak,high]=region[i],prior=previous[i][1];if(!active[i]||prior===peak)continue;
        const ratio=(prior-peak)/((prior<peak?low:high)-peak),cut=prior<peak?[prior,peak,high]:[low,peak,prior];
        if(ratio>best+1e-10){best=ratio;cuts=[];}if(Math.abs(ratio-best)<1e-10)cuts.push([i,cut]);
      }
      for(const [i,cut]of cuts)region[i]=cut;
    }
    supports.push(region);
  }
  // Convert delta scalars back to weights on original source values. This also
  // handles intermediate and multi-axis correction masters, including negatives.
  const deltas=[];
  for(let i=0;i<records.length;i++){
    const coefficients=Array(records.length).fill(0);coefficients[records[i].index]=1;
    for(let j=0;j<i;j++){const influence=scalar(records[i].location,supports[j]);for(let k=0;k<coefficients.length;k++)coefficients[k]-=influence*deltas[j][k];}
    deltas.push(coefficients);
  }
  const weights=Array(records.length).fill(0);
  for(let i=0;i<records.length;i++){const influence=scalar(location,supports[i]);for(let j=0;j<weights.length;j++)weights[j]+=influence*deltas[i][j];}
  return {sources,weights};
}
export const blendNumber=(sources,weights,read)=>sources.reduce((sum,source,i)=>sum+Number(read(source,i)??0)*weights[i],0);
export function interpolatedKerning(sources,weights) {
  const result={},pairs=new Map();
  for(const source of sources)for(const [left,rights]of Object.entries(source.kerning??{}))for(const right of Object.keys(rights)){if(!pairs.has(left))pairs.set(left,new Set());pairs.get(left).add(right);}
  for(const [left,rights]of pairs){result[left]={};for(const right of rights)result[left][right]=blendNumber(sources,weights,s=>s.kerning?.[left]?.[right]??0);}
  return result;
}
