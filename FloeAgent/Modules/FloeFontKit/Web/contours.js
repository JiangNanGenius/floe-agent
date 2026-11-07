// SPDX-License-Identifier: MPL-2.0
import { clone,uid } from '../../FloeHeavyEditorSupport/Web/runtime.js';
const p=(x,y,type='line')=>({id:uid(),x,y,type,smooth:false});
const mix=(a,b,t)=>p(a.x+(b.x-a.x)*t,a.y+(b.y-a.y)*t);

// Expand implied quadratic points without changing the represented curve.
export function contourSegments(contour) {
  if(!contour.length)return {start:null,segments:[],closed:true};
  let points=clone(contour),start=points.findIndex(v=>v.type!=='offcurve'),closed=!points.some(v=>v.type==='move');
  if(start<0){const first=mix(points.at(-1),points[0],.5);first.type='qcurve';points.unshift(first);start=0;}
  if(!closed&&start!==0)throw new Error('An open contour must begin with a move point');
  points=[...points.slice(start),...points.slice(0,start)];
  const initial=points[0],segments=[];let current=initial,controls=[];
  for(const end of closed?[...points.slice(1),initial]:points.slice(1)){
    if(end.type==='offcurve'){controls.push(end);continue;}
    if(end.type==='curve'){
      if(controls.length!==2)throw new Error('A cubic segment needs two control handles');
      segments.push({start:current,end,controls,type:'curve'});
    }else if(end.type==='qcurve'){
      if(!controls.length)segments.push({start:current,end,controls:[],type:'line'});
      for(let i=0;i<controls.length;i++){const target=i===controls.length-1?end:mix(controls[i],controls[i+1],.5);target.type='qcurve';segments.push({start:current,end:target,controls:[controls[i]],type:'qcurve'});current=target;}
    }else {
      if(controls.length||end.type==='move')throw new Error('Invalid line segment or move point');
      segments.push({start:current,end,controls:[],type:'line'});
    }
    current=end;controls=[];
  }
  if(controls.length)throw new Error('An open contour cannot end in control handles');
  return {start:initial,segments,closed};
}
export function segmentsContour({start,segments,closed}) {
  if(!start)return [];
  const first={...start,type:closed?(segments.at(-1)?.type??'line'):'move'},result=[first];
  for(let i=0;i<segments.length;i++){
    const segment=segments[i];result.push(...segment.controls.map(v=>({...v,type:'offcurve'})));
    if(!closed||i<segments.length-1)result.push({...segment.end,type:segment.type});
  }
  return result;
}
export function reverseContour(contour) {
  const path=contourSegments(contour);if(!path.start)return [];
  const segments=[...path.segments].reverse().map(s=>({start:s.end,end:s.start,type:s.type,controls:[...s.controls].reverse()}));
  return segmentsContour({start:segments[0]?.start??path.start,segments,closed:path.closed});
}
export function splitSegment(contour,index,time=.5) {
  const path=contourSegments(contour),segment=path.segments[index];
  if(!segment||!(time>0&&time<1))throw new Error('Choose a segment and a split position between 0 and 1');
  const chain=[segment.start,...segment.controls,segment.end],left=[chain[0]],right=[chain.at(-1)];let row=chain;
  while(row.length>1){row=row.slice(0,-1).map((value,i)=>mix(value,row[i+1],time));left.push(row[0]);right.unshift(row.at(-1));}
  const middle=left.at(-1);middle.type=segment.type;middle.smooth=segment.type!=='line';right[0]=middle;
  path.segments.splice(index,1,{start:left[0],end:middle,controls:left.slice(1,-1),type:segment.type},{start:middle,end:segment.end,controls:right.slice(1,-1),type:segment.type});
  return segmentsContour(path);
}
export function openContour(contour,pointID) {
  const path=contourSegments(contour);if(!path.closed)return clone(contour);
  const index=path.segments.findIndex(s=>s.start.id===(pointID??path.start.id));if(index<0)throw new Error('Choose an on-curve start point');
  path.segments=[...path.segments.slice(index),...path.segments.slice(0,index)];path.start=path.segments[0].start;
  // Duplicate the end node so opening preserves the former closing curve.
  path.segments.at(-1).end={...path.start,id:uid()};path.closed=false;return segmentsContour(path);
}
export function closeContour(contour) {
  const path=contourSegments(contour);if(path.closed||!path.segments.length)return clone(contour);
  const last=path.segments.at(-1),end=last.end;
  if(Math.hypot(end.x-path.start.x,end.y-path.start.y)<1e-8)last.end=path.start;
  else path.segments.push({start:end,end:path.start,controls:[],type:'line'});
  path.closed=true;return segmentsContour(path);
}
export function deleteContourPoints(contour,ids) {
  const path=contourSegments(contour),selected=new Set(ids);
  if(!path.segments.length)return [];
  const nodes=[path.start,...path.segments.map(s=>s.end)];if(path.closed)nodes.pop();
  const keep=nodes.filter(p=>!selected.has(p.id));if(keep.length<2)return [];
  const segments=[];
  for(let i=0;i<(path.closed?keep.length:keep.length-1);i++){
    const start=keep[i],end=keep[(i+1)%keep.length],original=path.segments.find(s=>s.start.id===start.id&&s.end.id===end.id);
    segments.push(original&&!original.controls.some(p=>selected.has(p.id))?original:{start,end,type:'line',controls:[]});
  }
  return segmentsContour({start:keep[0],segments,closed:path.closed});
}
export function smoothContour(contour,ids,mode='smooth') {
  const path=contourSegments(contour),selected=new Set(ids);
  const cubic=segment=>{
    if(segment.type==='curve')return;
    const [a,b]=segment.controls.length?[mix(segment.start,segment.controls[0],2/3),mix(segment.end,segment.controls[0],2/3)]:[mix(segment.start,segment.end,1/3),mix(segment.start,segment.end,2/3)];
    segment.type='curve';segment.controls=[a,b];
  };
  for(let i=0;i<path.segments.length;i++){
    const outgoing=path.segments[i],anchor=outgoing.start;if(!selected.has(anchor.id))continue;
    anchor.smooth=mode!=='corner';if(mode==='corner')continue;
    const incoming=i?path.segments[i-1]:path.closed?path.segments.at(-1):null;
    if(!incoming)continue;
    let direction;
    if(mode==='tangent'&&(incoming.type==='line'||outgoing.type==='line')){
      const line=incoming.type==='line'?incoming:outgoing;direction={x:line.end.x-line.start.x,y:line.end.y-line.start.y};
      if(incoming.type!=='line')cubic(incoming);if(outgoing.type!=='line')cubic(outgoing);
    }else {
      cubic(incoming);cubic(outgoing);
      const before=incoming.controls.at(-1),after=outgoing.controls[0];
      const a=Math.hypot(anchor.x-before.x,anchor.y-before.y)||1,b=Math.hypot(after.x-anchor.x,after.y-anchor.y)||1;
      direction={x:(anchor.x-before.x)/a+(after.x-anchor.x)/b,y:(anchor.y-before.y)/a+(after.y-anchor.y)/b};
    }
    const length=Math.hypot(direction.x,direction.y);if(!length)continue;direction.x/=length;direction.y/=length;
    const before=incoming.controls.at(-1),after=outgoing.controls[0],a=before?Math.hypot(anchor.x-before.x,anchor.y-before.y):0,b=after?Math.hypot(after.x-anchor.x,after.y-anchor.y):0;
    if(before){const size=mode==='symmetric'?(a+b)/2:a;before.x=anchor.x-direction.x*size;before.y=anchor.y-direction.y*size;}
    if(after){const size=mode==='symmetric'?(a+b)/2:b;after.x=anchor.x+direction.x*size;after.y=anchor.y+direction.y*size;}
  }
  // The final endpoint of an open contour can still be marked as corner/smooth.
  if(!path.closed&&path.segments.length&&selected.has(path.segments.at(-1).end.id))path.segments.at(-1).end.smooth=mode!=='corner';
  return segmentsContour(path);
}
export function moveGlyphPoints(glyph,changes,{follow=true}={}) {
  const targets=new Map(changes.map(v=>[v.id,v])),selected=new Set(targets.keys()),original=clone(glyph.contours);
  for(const contour of glyph.contours)for(let i=0;i<contour.length;i++){
    const point=contour[i],change=targets.get(point.id);
    if(change){point.x=Number(change.x);point.y=Number(change.y);continue;}
    if(!follow||point.type!=='offcurve')continue;
    const neighbors=[contour[(i+contour.length-1)%contour.length],contour[(i+1)%contour.length]],anchor=neighbors.find(v=>v.type!=='offcurve'&&selected.has(v.id));
    if(anchor){const before=original.flat().find(v=>v.id===anchor.id),target=targets.get(anchor.id);point.x+=target.x-before.x;point.y+=target.y-before.y;}
  }
  for(const contour of glyph.contours)for(let i=0;i<contour.length;i++){
    const handle=contour[i];if(handle.type!=='offcurve'||!selected.has(handle.id))continue;
    for(const offset of [-1,1]){
      const anchor=contour[(i+offset+contour.length)%contour.length],opposite=contour[(i+2*offset+contour.length)%contour.length];
      if(anchor.type==='offcurve'||!anchor.smooth||opposite.type!=='offcurve'||selected.has(opposite.id)||selected.has(anchor.id))continue;
      const length=Math.hypot(opposite.x-anchor.x,opposite.y-anchor.y),direction=Math.hypot(handle.x-anchor.x,handle.y-anchor.y);if(!direction)continue;
      opposite.x=anchor.x-(handle.x-anchor.x)*length/direction;opposite.y=anchor.y-(handle.y-anchor.y)*length/direction;
    }
  }
}
export function contourBounds(contour) {
  const path=contourSegments(contour),points=path.start?[path.start]:[];
  for(const segment of path.segments){
    points.push(segment.end);const chain=[segment.start,...segment.controls,segment.end];
    const evaluate=time=>{let row=chain;while(row.length>1)row=row.slice(0,-1).map((v,i)=>mix(v,row[i+1],time));return row[0];};
    for(const axis of ['x','y']){
      let roots=[];
      if(chain.length===3){const [a,b,c]=chain.map(p=>p[axis]),denominator=a-2*b+c;if(Math.abs(denominator)>1e-12)roots=[(a-b)/denominator];}
      if(chain.length===4){const [a,b,c,d]=chain.map(p=>p[axis]),A=-a+3*b-3*c+d,B=2*(a-2*b+c),C=b-a,D=B*B-4*A*C;
        roots=Math.abs(A)<1e-12?Math.abs(B)>1e-12?[-C/B]:[]:D>=0?[(-B+Math.sqrt(D))/(2*A),(-B-Math.sqrt(D))/(2*A)]:[];}
      for(const time of roots)if(time>0&&time<1)points.push(evaluate(time));
    }
  }
  return points;
}
export function cubicToQuadratics(chain,tolerance=1,depth=0) {
  const [a,b,c,d]=chain,q=p((3*b.x+3*c.x-a.x-d.x)/4,(3*b.y+3*c.y-a.y-d.y)/4,'offcurve');
  const first=mix(a,q,2/3),last=mix(d,q,2/3),error=Math.max(Math.hypot(first.x-b.x,first.y-b.y),Math.hypot(last.x-c.x,last.y-c.y));
  if(error<=tolerance)return [{control:q,end:{...d,type:'qcurve'}}];
  if(depth>=18)throw new Error('Curve tolerance is too small');
  const ab=mix(a,b,.5),bc=mix(b,c,.5),cd=mix(c,d,.5),abc=mix(ab,bc,.5),bcd=mix(bc,cd,.5),middle=mix(abc,bcd,.5);
  return [...cubicToQuadratics([a,ab,abc,middle],tolerance,depth+1),...cubicToQuadratics([middle,bcd,cd,d],tolerance,depth+1)];
}
