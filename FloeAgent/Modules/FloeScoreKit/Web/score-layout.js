// SPDX-License-Identifier: MPL-2.0
import {ensure,child,set,partList} from './model.js';
export function effectiveScoreLayout(e,part=e.viewPart){
 const base=e.state.layout??{},layout={...base,...(part?base.partLayouts?.[part]:{})};delete layout.partLayouts;return layout;
}
export function applyXMLLayout(doc,layout){
 const defaults=ensure(doc.documentElement,'defaults'),scaling=ensure(defaults,'scaling');set(scaling,'millimeters',7);set(scaling,'tenths',40);
 const page=ensure(defaults,'page-layout'),sizes={A4_P:[210,297],A4_L:[297,210],A3_P:[297,420],Letter_P:[215.9,279.4]},size=sizes[layout.paper]??sizes.A4_P,factor=40/7,margin=Math.max(5,Math.min(50,Number(layout.margin??15)));
 set(page,'page-height',size[1]*factor);set(page,'page-width',size[0]*factor);const margins=ensure(page,'page-margins');margins.setAttribute('type','both');for(const name of ['left-margin','right-margin','top-margin','bottom-margin'])set(margins,name,margin*factor);
 const per=Math.max(0,Math.min(32,Math.trunc(layout.measuresPerSystem??4)));
 for(const p of partList(doc))for(let i=0;i<p.measures.length;i++){
  const m=p.measures[i],print=child(m,'print');
  if(print?.getAttribute('data-floe-system')==='yes'){print.removeAttribute('new-system');print.removeAttribute('data-floe-system');}
  if(per&&i>0&&i%per===0){const pr=ensure(m,'print');pr.setAttribute('new-system','yes');pr.setAttribute('data-floe-system','yes');m.insertBefore(pr,m.firstElementChild);}
 }
 return doc;
}
