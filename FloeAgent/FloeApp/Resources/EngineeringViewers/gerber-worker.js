// SPDX-License-Identifier: MPL-2.0
importScripts('gerber-to-svg.min.js');
self.onmessage=({data})=>{
 try {
  gerberToSvg(data,{id:'floe-layer'},(error,svg)=>{
   if(error)self.postMessage({error:String(error)});
   else self.postMessage({svg});
  });
 }catch(error){self.postMessage({error:String(error)});}
};
