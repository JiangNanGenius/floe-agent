// SPDX-License-Identifier: MPL-2.0
import {OpenSheetMusicDisplay} from 'opensheetmusicdisplay';
import {canonicalXML} from './model.js';
import {renderNumberedScore,notationMode} from './jianpu.js';
// Export owns an isolated engraving surface. It never changes the visible
// linked part, selection, playback, original, history or document revision.
export async function createScoreExportSurface(doc,layout,width=1000){
 const surface=document.createElement('div');surface.style.cssText=`position:fixed;left:-100000px;top:0;width:${Math.max(640,Math.min(2400,width||1000))}px;visibility:hidden;pointer-events:none`;
 document.body.append(surface);let engraver;
 const dispose=()=>{try{engraver?.clear();}finally{surface.remove();}};
 try{
  if(notationMode(layout,doc)==='jianpu'){const rendered=renderNumberedScore(doc,layout,width,{exporting:true});surface.append(...rendered.pages);return {surface,dispose};}
  for(const sign of doc.querySelectorAll('clef > sign'))if(sign.textContent==='jianpu')sign.textContent='G';
  engraver=new OpenSheetMusicDisplay(surface,{backend:'svg',autoResize:false,drawTitle:true,drawComposer:true,drawPartNames:true,drawPartAbbreviations:true,followCursor:false,disableCursor:true});
  engraver.setOptions({pageFormat:layout.paper??'A4_P',newSystemFromXML:true,newPageFromXML:true,renderSingleHorizontalStaffline:false,autoGenerateMultipleRestMeasuresFromRestMeasures:Boolean(layout.condenseRests)});
  engraver.zoom=1;
  if(layout.margin){const margin=layout.margin/1.75;for(const key of ['PageLeftMargin','PageRightMargin','PageTopMargin','PageBottomMargin'])engraver.EngravingRules[key]=margin;}
  if(layout.staffSpacing)engraver.EngravingRules.StaffDistance=layout.staffSpacing;
  await engraver.load(new DOMParser().parseFromString(canonicalXML(doc),'application/xml'));engraver.render();
  return {surface,dispose};
 }catch(error){dispose();throw error;}
}
