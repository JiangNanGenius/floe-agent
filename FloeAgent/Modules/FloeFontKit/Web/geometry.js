// SPDX-License-Identifier: MPL-2.0
import paper from 'paper';
import { t,clone,required,parseXML } from '../../FloeHeavyEditorSupport/Web/runtime.js';
import { getGlyph,glyphList,glyphField,glyphPath,point,field } from './model.js';
import { cubicToQuadratics } from './contours.js';
let scope;
function paperScope(){if(!scope){scope=new paper.PaperScope();scope.setup(new scope.Size(1000,1000));}scope.activate();return scope;}
export function contoursFromPaper(item){
  const contours=[];const paths=item.className==='CompoundPath'?item.children:[item];
  for(const path of paths){const segments=path.segments;if(!segments?.length)continue;const contour=[];
    segments.forEach((segment,index)=>{const previous=segments[(index+segments.length-1)%segments.length],curved=!previous.handleOut.isZero()||!segment.handleIn.isZero();
      if(curved&&(index>0||path.closed)){contour.push(point(previous.point.x+previous.handleOut.x,previous.point.y+previous.handleOut.y,'offcurve'),point(segment.point.x+segment.handleIn.x,segment.point.y+segment.handleIn.y,'offcurve'));}
      contour.push(point(segment.point.x,segment.point.y,index===0&&!path.closed?'move':curved?'curve':'line',segment.isSmooth()));
    });
    // Move closing-segment controls behind the last on-curve point, matching UFO's cyclic order.
    if(path.closed&&contour[0]?.type==='offcurve')contour.push(...contour.splice(0,2));contours.push(contour);
  }return contours;
}
function shapePath(e,name){const s=paperScope(),font={...e.state,glyphs:glyphList(e)};return new s.CompoundPath({pathData:glyphPath(font,getGlyph(e,name)),insert:false});}
const multiply=(a,b)=>[a[0]*b[0]+a[2]*b[1],a[1]*b[0]+a[3]*b[1],a[0]*b[2]+a[2]*b[3],a[1]*b[2]+a[3]*b[3],a[0]*b[4]+a[2]*b[5]+a[4],a[1]*b[4]+a[3]*b[5]+a[5]];
export function svgTransform(source=''){
  let matrix=[1,0,0,1,0,0];const pattern=/([A-Za-z]+)\s*\(([^)]*)\)/g;let match,consumed='';
  while((match=pattern.exec(source))){consumed+=match[0];const values=match[2].trim().split(/[\s,]+/).filter(Boolean).map(Number);if(!values.every(Number.isFinite))throw new Error('Invalid SVG transform');const [a=0,b=0,c=0]=values;let next;
    switch(match[1]){case'matrix':if(values.length!==6)throw new Error('Invalid SVG matrix');next=values;break;case'translate':next=[1,0,0,1,a,b];break;case'scale':next=[a,0,0,values[1]??a,0,0];break;case'rotate':{const r=a*Math.PI/180,rotation=[Math.cos(r),Math.sin(r),-Math.sin(r),Math.cos(r),0,0];next=multiply(multiply([1,0,0,1,b,c],rotation),[1,0,0,1,-b,-c]);break;}case'skewX':next=[1,0,Math.tan(a*Math.PI/180),1,0,0];break;case'skewY':next=[1,Math.tan(a*Math.PI/180),0,1,0,0];break;default:throw new Error('Unsupported SVG transform');}matrix=multiply(matrix,next);
  }
  if(source.replace(pattern,'').trim())throw new Error('Invalid SVG transform');return matrix;
}
// SVG glyph import handles filled vector shapes and local reuse. It does not
// fetch resources, execute SVG, or guess outlines for text or raster images.
export function readSVGOutlines(source,{flipY=true}={}){
  const doc=parseXML(source),root=doc.documentElement,s=paperScope(),result=[];
  const visit=(node,parent=[1,0,0,1,0,0],seen=new Set(),referenced=false)=>{
    const tag=node.localName,matrix=multiply(parent,svgTransform(node.getAttribute('transform')??'')),number=(key,fallback=0)=>Number(node.getAttribute(key)??fallback);let item;
    if(['script','image','foreignObject','text','style','filter'].includes(tag))throw new Error(t('请将文字与图像先转换为矢量轮廓。','Convert text and images to vector outlines before importing.'));
    if(tag==='defs'&&!referenced)return;
    if(tag==='use'){
      const href=node.getAttribute('href')??node.getAttribute('xlink:href');if(!href?.startsWith('#')||seen.has(href))throw new Error('SVG reuse must refer to a non-circular local shape');const target=required(doc.getElementById(href.slice(1)),'Missing SVG shape');visit(target,multiply(matrix,[1,0,0,1,number('x'),number('y')]),new Set([...seen,href]),true);return;
    }
    if(tag==='path')item=new s.CompoundPath({pathData:node.getAttribute('d')??'',insert:false});
    else if(tag==='rect')item=new s.Path.Rectangle({rectangle:new s.Rectangle(number('x'),number('y'),number('width'),number('height')),radius:new s.Size(number('rx'),number('ry',number('rx'))),insert:false});
    else if(tag==='circle'||tag==='ellipse')item=new s.Path.Ellipse({center:[number('cx'),number('cy')],radius:tag==='circle'?[number('r'),number('r')]:[number('rx'),number('ry')],insert:false});
    else if(tag==='polygon'||tag==='polyline'){const values=(node.getAttribute('points')??'').trim().split(/[\s,]+/).map(Number);if(values.length%2||!values.every(Number.isFinite))throw new Error('Invalid SVG polygon');item=new s.Path({segments:Array.from({length:values.length/2},(_,i)=>[values[i*2],values[i*2+1]]),closed:tag==='polygon',insert:false});}
    else if(tag==='line')item=new s.Path({segments:[[number('x1'),number('y1')],[number('x2'),number('y2')]],insert:false});
    else if(!['svg','g','defs','symbol','title','desc','metadata','clipPath'].includes(tag))throw new Error('Unsupported SVG outline element '+tag);
    if(item){item.transform(new s.Matrix(...matrix));const rule=node.getAttribute('fill-rule')??node.parentElement?.getAttribute('fill-rule');if(rule==='evenodd')item.reorient(false);result.push(...contoursFromPaper(item));item.remove();}
    else if(!['title','desc','metadata','clipPath'].includes(tag))for(const child of node.children)visit(child,matrix,seen,referenced);
  };visit(root);
  if(!result.length)throw new Error('SVG contains no vector outlines');
  if(flipY){const view=(root.getAttribute('viewBox')??'').trim().split(/[\s,]+/).map(Number),points=result.flat(),height=view.length===4&&view.every(Number.isFinite)?view[1]*2+view[3]:parseFloat(root.getAttribute('height'))||Math.min(...points.map(p=>p.y))+Math.max(...points.map(p=>p.y));for(const p of points)p.y=height-p.y;}
  return result;
}
export function registerGeometry(e){
  const add=(id,title,fields,handler,access='edit')=>e.register({id,title,fields,group:t('轮廓几何','Outline geometry'),access},handler);
  add('outline.shape',t('添加矩形／椭圆','Add rectangle / ellipse'),[glyphField(),field('shape',t('形状','Shape'),'select',{options:['rectangle','ellipse'],default:'rectangle'}),field('x',t('横坐标','X'),'number',{default:50}),field('y',t('纵坐标','Y'),'number',{default:0}),field('width',t('宽度','Width'),'number',{default:500}),field('height',t('高度','Height'),'number',{default:700})],a=>{const s=paperScope(),bounds=new s.Rectangle(a.x,a.y,a.width,a.height),path=a.shape==='ellipse'?new s.Path.Ellipse({rectangle:bounds,insert:false}):new s.Path.Rectangle({rectangle:bounds,insert:false});getGlyph(e,a.glyph).contours.push(...contoursFromPaper(path));path.remove();});
  for(const operation of ['unite','intersect','subtract','exclude'])add('outline.'+operation,{unite:t('布尔合并','Boolean union'),intersect:t('布尔相交','Boolean intersection'),subtract:t('布尔差集','Boolean difference'),exclude:t('布尔异或','Boolean exclude')}[operation],[glyphField(),glyphField('other',t('另一个字形','Other glyph'))],a=>{const first=shapePath(e,a.glyph),second=shapePath(e,a.other),result=first[operation](second,{insert:false}),g=getGlyph(e,a.glyph);g.contours=contoursFromPaper(result);g.components=[];first.remove();second.remove();result.remove();});
  add('outline.removeOverlap',t('去除重叠','Remove overlap'),[glyphField()],a=>{const path=shapePath(e,a.glyph),resolved=path.resolveCrossings(),united=resolved.unite(resolved,{insert:false}),g=getGlyph(e,a.glyph);g.contours=contoursFromPaper(united);g.components=[];path.remove();if(resolved!==path)resolved.remove();united.remove();});
  add('outline.simplify',t('简化轮廓','Simplify outline'),[glyphField(),field('tolerance',t('容差','Tolerance'),'number',{default:1,min:0})],a=>{const path=shapePath(e,a.glyph);for(const child of path.children??[path]){child.simplify(Math.max(.01,a.tolerance));}getGlyph(e,a.glyph).contours=contoursFromPaper(path);getGlyph(e,a.glyph).components=[];path.remove();});
  add('outline.extrema',t('在极值处加点','Add extrema points'),[glyphField()],a=>{const path=shapePath(e,a.glyph);for(const child of path.children??[path]){const locations=[];for(const curve of child.curves){const values=curve.values;for(const axis of [0,1]){const p0=values[axis],p1=values[2+axis],p2=values[4+axis],p3=values[6+axis],qa=-p0+3*p1-3*p2+p3,qb=2*(p0-2*p1+p2),qc=p1-p0,discriminant=qb*qb-4*qa*qc,roots=Math.abs(qa)<1e-10?Math.abs(qb)>1e-10?[-qc/qb]:[]:discriminant>=0?[(-qb+Math.sqrt(discriminant))/(2*qa),(-qb-Math.sqrt(discriminant))/(2*qa)]:[];for(const time of roots)if(time>1e-6&&time<1-1e-6)locations.push(curve.getLocationAtTime(time));}}
      for(const location of locations.sort((a,b)=>b.offset-a.offset))child.divideAt(location);
    }getGlyph(e,a.glyph).contours=contoursFromPaper(path);getGlyph(e,a.glyph).components=[];path.remove();});
  add('outline.convert',t('转换曲线类型','Convert curve type'),[glyphField(),field('type',t('曲线','Curve'),'select',{options:['cubic','quadratic','lines'],default:'cubic'}),field('tolerance',t('容差','Tolerance'),'number',{default:1,min:.01})],a=>{const path=shapePath(e,a.glyph);if(a.type==='lines'){for(const child of path.children??[path])child.flatten(Math.max(.01,a.tolerance));getGlyph(e,a.glyph).contours=contoursFromPaper(path);}else if(a.type==='cubic')getGlyph(e,a.glyph).contours=contoursFromPaper(path);else {const g=getGlyph(e,a.glyph),converted=[];for(const child of path.children??[path]){const contour=[];for(const curve of child.curves){if(!contour.length)contour.push(point(curve.point1.x,curve.point1.y,child.closed?'line':'move'));const values=curve.values,chain=[0,2,4,6].map(index=>({x:values[index],y:values[index+1]}));for(const segment of cubicToQuadratics(chain,Math.max(.01,a.tolerance)))contour.push(point(segment.control.x,segment.control.y,'offcurve'),point(segment.end.x,segment.end.y,'qcurve'));}if(child.closed&&contour.length>1){const last=contour.pop();contour[0].type=last.type;}converted.push(contour);}g.contours=converted;}getGlyph(e,a.glyph).components=[];path.remove();});
  add('outline.align',t('对齐选中节点','Align selected points'),[glyphField(),field('axis',t('对齐方式','Alignment'),'select',{options:['left','centerX','right','bottom','centerY','top'],default:'left'})],a=>{const g=getGlyph(e,a.glyph),ids=new Set(e.selection?.points??[]),points=g.contours.flat().filter(p=>ids.has(p.id));if(!points.length)throw new Error('Select points first');const x=a.axis.includes('X')||['left','right'].includes(a.axis),values=points.map(p=>x?p.x:p.y),target=['left','bottom'].includes(a.axis)?Math.min(...values):['right','top'].includes(a.axis)?Math.max(...values):values.reduce((s,v)=>s+v,0)/values.length;for(const p of points)p[x?'x':'y']=target;});
  add('outline.winding',t('修正方向与洞','Correct winding & holes'),[glyphField(),field('clockwise',t('外轮廓顺时针','Clockwise outer contours'),'checkbox',{default:true})],a=>{const path=shapePath(e,a.glyph);path.reorient(false,Boolean(a.clockwise));const g=getGlyph(e,a.glyph);g.contours=contoursFromPaper(path);g.components=[];path.remove();});
  add('outline.inspect',t('检查轮廓交点／方向／洞','Inspect intersections / winding / holes'),[glyphField()],a=>{const path=shapePath(e,a.glyph),children=path.children??[path],parents=children.map(child=>children.map((candidate,index)=>({candidate,index})).filter(({candidate})=>candidate!==child&&Math.abs(candidate.area)>Math.abs(child.area)+1e-6&&candidate.bounds.contains(child.bounds)&&candidate.contains(child.getInteriorPoint())&&!candidate.getIntersections(child).length).sort((a,b)=>Math.abs(a.candidate.area)-Math.abs(b.candidate.area))[0]?.index??-1),depth=index=>parents[index]<0?0:1+depth(parents[index]);
    const result={area:path.area,selfIntersections:path.getIntersections().length,contours:children.map((c,index)=>({index,clockwise:c.clockwise,closed:c.closed,length:c.length,segments:c.segments.length,parent:parents[index],depth:depth(index),hole:depth(index)%2===1,windingConflict:parents[index]>=0&&c.clockwise===children[parents[index]].clockwise}))};path.remove();return result;},'read');
}
