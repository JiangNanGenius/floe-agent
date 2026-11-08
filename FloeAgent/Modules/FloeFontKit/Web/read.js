// SPDX-License-Identifier: MPL-2.0
import {clone,t,required} from '../../FloeHeavyEditorSupport/Web/runtime.js';
import {field} from './model.js';

const pageFields=()=>[field('query',t('搜索','Search'),'text',{default:''}),field('offset',t('起始位置','Offset'),'number',{default:0,min:0}),field('limit',t('数量','Limit'),'number',{default:40,min:1,max:100})];
function page(values,a,match){
  const offset=a.offset??0,limit=a.limit??40,query=a.query??'';
  if(!Number.isSafeInteger(offset)||offset<0||!Number.isSafeInteger(limit)||limit<1||limit>100||typeof query!=='string'||query.length>200)throw new Error('Invalid font read page');
  const filtered=values.filter(value=>!query||match(value).toLocaleLowerCase().includes(query.toLocaleLowerCase()));
  return {items:clone(filtered.slice(offset,offset+limit)),total:values.length,matched:filtered.length,offset,limit,hasMore:offset+limit<filtered.length};
}
function source(e,a){return !a.master||a.master==='default'?e.state:required(e.state.masters.find(m=>m.id===a.master),'Unknown master');}

/// Pure command reads do not move UI selection, switch masters, mutate the
/// document, expand binary originals or copy every glyph into one response.
export function registerFontReads(e){
  const group=t('字体资料','Font information');
  e.register({id:'font.glyphs',title:t('搜索字形','Search glyphs'),group,access:'read',fields:[field('master',t('母版 ID','Master ID'),'text',{default:'default'}),...pageFields()]},a=>{
    const glyphs=source(e,a).glyphs;
    return page(glyphs.map(g=>({id:g.id,name:g.name,unicodes:g.unicodes,advance:g.advance,contourCount:g.contours.length,pointCount:g.contours.reduce((n,c)=>n+c.length,0)})),a,
      g=>g.name+' '+g.unicodes.map(c=>String.fromCodePoint(c)+' U+'+c.toString(16)).join(' '));
  });
  e.register({id:'font.glyph',title:t('读取字形节点','Read glyph points'),group,access:'read',fields:[field('master',t('母版 ID','Master ID'),'text',{default:'default'}),field('glyph',t('字形名','Glyph name'),'text'),...pageFields()]},a=>{
    const g=required(source(e,a).glyphs.find(g=>g.name===a.glyph),'Unknown glyph');
    const points=g.contours.flatMap((contour,c)=>contour.map((point,p)=>({contour:c,index:p,...point})));
    return {id:g.id,name:g.name,unicodes:clone(g.unicodes),advance:g.advance,advanceHeight:g.advanceHeight??null,verticalOrigin:g.verticalOrigin??null,
      contourCount:g.contours.length,points:page(points,a,p=>p.id+' '+p.type),anchors:page(g.anchors,a,p=>p.name),
      components:page(g.components,a,p=>p.base),guidelines:page(g.guidelines,a,p=>p.name??'')};
  });
  e.register({id:'font.records',title:t('读取字体记录','Read font records'),group,access:'read',fields:[field('section',t('类别','Section'),'select',{options:['info','masters','axes','instances','kerning','groups','groupMembers'],default:'info'}),field('master',t('母版 ID','Master ID'),'text',{default:'default'}),field('name',t('分组名','Group name'),'text',{default:''}),...pageFields()]},a=>{
    const current=source(e,a);let records;
    switch(a.section??'info'){
      case 'info':records=Object.entries(current.info??e.state.info).map(([name,value])=>({name,value}));break;
      case 'masters':records=[{id:'default',name:e.state.info.styleName,location:Object.fromEntries(e.state.axes.map(a=>[a.tag,a.default])),glyphCount:e.state.glyphs.length},...e.state.masters.map(m=>({id:m.id,name:m.name,location:m.location,glyphCount:m.glyphs.length}))];break;
      case 'axes':records=e.state.axes;break;
      case 'instances':records=e.state.instances;break;
      case 'kerning':records=Object.entries(current.kerning??e.state.kerning).flatMap(([left,rights])=>Object.entries(rights).map(([right,value])=>({left,right,value})));break;
      case 'groups':records=Object.entries(e.state.groups).map(([name,glyphs])=>({name,count:glyphs.length}));break;
      case 'groupMembers':records=required(e.state.groups[a.name],'Unknown group').map(name=>({name}));break;
      default:throw new Error('Unknown font record section');
    }
    return page(records,a,value=>JSON.stringify(value));
  });
  e.register({id:'font.featureSource',title:t('读取特性源码','Read feature source'),group,access:'read',fields:[field('offset',t('起始位置','Offset'),'number',{default:0,min:0}),field('limit',t('字符数','Characters'),'number',{default:12000,min:1,max:24000})]},a=>{
    const offset=a.offset??0,limit=a.limit??12000;
    if(!Number.isSafeInteger(offset)||offset<0||!Number.isSafeInteger(limit)||limit<1||limit>24000)throw new Error('Invalid feature source page');
    return {text:e.state.features.slice(offset,offset+limit),offset,limit,total:e.state.features.length,hasMore:offset+limit<e.state.features.length};
  });
}
