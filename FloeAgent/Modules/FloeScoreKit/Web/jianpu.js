// SPDX-License-Identifier: MPL-2.0
// A projection of the original MusicXML. Stable note IDs remain the existing
// selection/edit/playback identities; no editable second document is created.
import {partList,noteTimeline,child,children,string,value,field} from './model.js';
import {t} from '../../FloeHeavyEditorSupport/Web/runtime.js';

const NS='http://www.w3.org/2000/svg',STEPS=['C','D','E','F','G','A','B'];
const SHARPS=['F','C','G','D','A','E','B'],FLATS=['B','E','A','D','G','C','F'];
const mod=(n,d)=>(n%d+d)%d;
const svg=(name,attributes={},text)=>{const n=document.createElementNS(NS,name);for(const[k,v]of Object.entries(attributes)){if(k==='xmlns')n.setAttributeNS('http://www.w3.org/2000/xmlns/',k,String(v));else n.setAttribute(k,String(v));}if(text!==undefined)n.textContent=String(text);return n;};
function text(parent,x,y,label,size=18,attrs={}){const n=svg('text',{x,y,'font-size':size,'font-family':'Arial, "PingFang SC", sans-serif',fill:'#17243a',...attrs},label);parent.append(n);return n;}
function line(parent,x1,y1,x2,y2,width=1){parent.append(svg('line',{x1,y1,x2,y2,stroke:'#17243a','stroke-width':width}));}
function dot(parent,x,y,r=1.8){parent.append(svg('circle',{cx:x,cy:y,r,fill:'#17243a'}));}
export function notationMode(layout={},doc){
 if(['staff','jianpu'].includes(layout.notation))return layout.notation;
 return [...(doc?.querySelectorAll('clef > sign')??[])].some(n=>n.textContent==='jianpu')?'jianpu':'staff';
}
export function registerNumberedNotation(e){
 e.register({id:'score.view.notation',title:t('五线谱／简谱','Staff / numbered notation'),group:t('排版与视图','Layout & view'),access:'edit',
  fields:[field('notation',t('记谱方式','Notation'),'select',{options:[{value:'staff',label:t('五线谱','Staff')},{value:'jianpu',label:t('简谱','Numbered')}],default:e=>e.state.layout?.notation??'staff'})]},args=>{
   if(!['staff','jianpu'].includes(args.notation))throw new Error('Choose staff or jianpu');
   e.state.layout={...e.state.layout,notation:args.notation};return {notation:args.notation};
  });
}
function keyValue(key,previous={fifths:0,mode:'major',unsupported:false}){
 if(!key)return previous;
 const fifths=Number(string(key,'fifths',previous.fifths)),mode=string(key,'mode',previous.mode);
 return {fifths,mode,unsupported:!Number.isInteger(fifths)||Math.abs(fifths)>7||!['major','minor'].includes(mode)||children(key,'key-step').length>0};
}
export function keyAt(part,index){
 let key={fifths:0,mode:'major',unsupported:false};
 for(let i=0;i<=index&&i<part.measures.length;i++)for(const entry of part.measures[i].children){
  if(i===index&&['note','backup','forward'].includes(entry.tagName))break;
  if(entry.tagName==='attributes')key=keyValue(child(entry,'key'),key);
 }
 return key;
}
function alterations(fifths){const map=Object.fromEntries(STEPS.map(s=>[s,0]));const order=fifths<0?FLATS:SHARPS;for(let i=0;i<Math.abs(fifths);i++)map[order[i%7]]+=fifths<0?-1:1;return map;}
function tonic(key){const index=mod(key.fifths*4,7),step=STEPS[index],alter=alterations(key.fifths)[step];return {index,step,alter};}
function spelled(step,alter,octave){return step+(alter>0?'#'.repeat(alter):'b'.repeat(-alter))+octave;}
export function degreePitch(key,degree,octave=4,alter=0){
 if(key.unsupported||!Number.isInteger(degree)||degree<1||degree>7||!Number.isInteger(octave)||octave<0||octave>8||!Number.isInteger(alter)||Math.abs(alter)>2)throw new Error('Unsupported numbered-note input');
 const root=tonic(key),offset=root.index+degree-1,step=STEPS[offset%7],noteOctave=octave+Math.floor(offset/7);
 if(noteOctave>9)throw new Error('Numbered-note input is outside MusicXML octave range');
 return spelled(step,alterations(key.fifths)[step]+alter,noteOctave);
}
export function numberedInput(part,index,input={}){
 const key=keyAt(part,index),octave=Number(input.octave??4),alter=Number(input.numberAlter??0);
 return {supported:!key.unsupported,key:keyLabel(key),alter,octave,
  keys:key.unsupported?[]:Array.from({length:7},(_,i)=>({degree:i+1,pitch:degreePitch(key,i+1,octave,alter)}))};
}
export function numberForNote(note,key){
 if(note.rest)return {digit:'0',octave:0,alter:0,rest:true};
 const pitch=child(note.node,'pitch');if(!pitch)return {digit:'×',octave:0,alter:0,unpitched:true};
 const step=string(pitch,'step','C'),alter=Number(string(pitch,'alter',0)),octave=Number(string(pitch,'octave',4));
 if(key.unsupported||!STEPS.includes(step)||!Number.isInteger(alter)||!Number.isInteger(octave))return {digit:'?',octave:0,alter:0,unsupported:true};
 const root=tonic(key),distance=(octave-4)*7+STEPS.indexOf(step)-root.index;
 return {digit:String(mod(distance,7)+1),octave:Math.floor(distance/7),alter:alter-alterations(key.fifths)[step],spelled:spelled(step,alter,octave),natural:string(note.node,'accidental')==='natural'};
}
export function keyLabel(key){
 if(key.unsupported)return t('自定义调号','Custom key');
 const root=tonic(key),alter=alterations(key.fifths),minor=key.mode==='minor',step=minor?STEPS[(root.index+5)%7]:root.step;
 return (minor?'6=':'1=')+step+(alter[step]>0?'♯'.repeat(alter[step]):'♭'.repeat(-alter[step]));
}
function partData(part){
 let key={fifths:0,mode:'major',unsupported:false};const lanes=new Map(),bars=[];let noteCount=0;
 for(let index=0;index<part.measures.length;index++){
  const timeline=noteTimeline(part,index),keys=new Map(),measure=part.measures[index];let initial;
  for(const entry of measure.children){
   if(entry.tagName==='attributes')key=keyValue(child(entry,'key'),key);
   else if(entry.tagName==='note'){initial??=key;keys.set(entry.getAttribute('id'),key);}
  }
  const notes=timeline.notes.map(note=>({...note,key:keys.get(note.id)??key,number:numberForNote(note,keys.get(note.id)??key)}));
  for(const note of notes){const id=note.staff+':'+note.voice;if(!lanes.has(id))lanes.set(id,{id,staff:note.staff,voice:note.voice});noteCount++;}
  bars.push({index,measure,timeline,notes,key:initial??key});
 }
 if(!lanes.size)lanes.set('1:1',{id:'1:1',staff:1,voice:'1'});
 return {part,bars,lanes:[...lanes.values()].sort((a,b)=>a.staff-b.staff||a.voice.localeCompare(b.voice,undefined,{numeric:true})),noteCount};
}
function durationSpec(note){
 const types={maxima:32,long:16,breve:8,whole:4,half:2,quarter:1,eighth:.5,'16th':.25,'32nd':.125,'64th':.0625,'128th':.03125,'256th':.015625,'512th':.0078125,'1024th':.00390625};
 const type=string(note.node,'type',''),dots=children(note.node,'dot').length;
 if(types[type])return {base:types[type],dots};
 if(note.grace)return {base:.5,dots};
 const modification=child(note.node,'time-modification'),actual=Number(string(modification,'actual-notes',1)),normal=Number(string(modification,'normal-notes',1));
 for(const base of Object.values(types))for(let d=0;d<=3;d++)if(Math.abs(base*(2-1/2**d)*normal/actual-value(note.duration))<1e-8)return {base,dots:d};
 return {base:1,dots:0,unsupported:true};
}
function noteShape(parent,note,x,y,keyState){
 const n=note.number,group=svg('g',{'data-score-note':note.id,class:'jp-note',transform:`translate(${x},${y})`});
 const spec=durationSpec(note),{base,dots}=spec,beams=Math.max(0,Math.round(-Math.log2(Math.min(1,base))));
 group.append(svg('rect',{x:-16,y:-38,width:34,height:64,rx:5,fill:'transparent',class:'jp-hit'}));
 let accidental=n.alter===0?'':n.alter>0?'♯'.repeat(n.alter):'♭'.repeat(-n.alter);
 const stateID=n.digit+':'+n.octave;
 if(!n.rest&&!n.unpitched&&!n.unsupported){if(n.alter===0&&(n.natural||keyState.get(stateID)))accidental='♮';keyState.set(stateID,n.alter);}
 if(accidental)text(group,-18,-2,accidental,15,{'text-anchor':'end',class:'jp-accidental'});
 text(group,0,0,spec.unsupported?'?':n.digit,note.grace?17:24,{'text-anchor':'middle','font-weight':'600',class:'jp-number'});
 if(n.unsupported)group.setAttribute('data-jianpu-unsupported','pitch');
 for(let i=0;i<beams;i++)line(group,-8,7+i*4,8,7+i*4,1.4);
 for(let i=0;i<dots;i++)dot(group,13+i*6,-8,1.9);
 for(let i=0;i<Math.max(0,n.octave);i++)dot(group,0,-28-i*6);
 for(let i=0;i<Math.max(0,-n.octave);i++)dot(group,0,16+beams*4+i*6);
 const actual=Number(string(child(note.node,'time-modification'),'actual-notes',1));
 if(actual>1)text(group,0,-40-Math.max(0,n.octave-1)*6,actual,11,{'text-anchor':'middle',class:'jp-tuplet'});
 if(note.grace)line(group,10,-22,16,-33,1);
 parent.append(group);return {group,base,beams};
}
function measureWidth(data,index){
 const events=new Set();let quarters=1,caption=0;
 for(const p of data){const bar=p.bars[index];if(!bar)continue;quarters=Math.max(quarters,value(bar.timeline.duration));
  for(const n of bar.notes){events.add(Math.round(value(n.onset)*1e8));caption=Math.max(caption,...children(n.node,'lyric').map(x=>string(x,'text').length));}}
 return Math.max(176,events.size*Math.max(44,caption*12+12)+40,quarters*44+32);
}
function barline(parent,x,top,bottom,measure,final=false){
 const marks=measure?children(measure,'barline'):[],right=marks.find(n=>(n.getAttribute('location')??'right')==='right'),style=string(right,'bar-style',final?'light-heavy':'regular');
 line(parent,x,top,x,bottom,style==='heavy'||style==='heavy-light'?2.4:1);
 if(['light-light','light-heavy','heavy-light','heavy-heavy'].includes(style))line(parent,x+5,top,x+5,bottom,style.endsWith('heavy')?2.7:1);
 if(child(right,'repeat')?.getAttribute('direction')==='backward'){dot(parent,x-7,(top+bottom)/2-5);dot(parent,x-7,(top+bottom)/2+5);}
}

export function renderNumberedScore(doc,layout={},availableWidth=1000,{exporting=false}={}){
 const data=partList(doc).map(partData),noteCount=data.reduce((n,p)=>n+p.noteCount,0);
 if(noteCount>50000)throw new Error(t('简谱内容过多，请缩小分谱范围或切回五线谱。','This numbered score is too large; choose a linked part or use staff notation.'));
 const lanes=data.flatMap(p=>p.lanes.map(lane=>({...lane,data:p})));if(lanes.length>64)throw new Error(t('声部过多，请先选择分谱。','Too many voices; choose a linked part.'));
 const warnings=new Set();for(const p of data)for(const bar of p.bars){if(bar.key.unsupported)warnings.add('key');for(const n of bar.notes){if(n.number.unsupported)warnings.add('pitch');if(n.number.unpitched)warnings.add('percussion');if(durationSpec(n).unsupported)warnings.add('duration');}}
 if(doc.querySelector('direction,harmony,ornaments,glissando,slide,bend,slur,articulations,technical,ending'))warnings.add('marks');
 const zoom=exporting?1:Math.max(.3,Math.min(3,Number(layout.zoom??1))),margin=Math.max(20,Math.min(100,Number(layout.margin??15)*3));
 const baseWidth=Math.max(640,Math.min(1600,Number(availableWidth)||1000)),left=margin+120,measureCount=Math.max(0,...data.map(p=>p.bars.length));
 const widths=Array.from({length:measureCount},(_,i)=>measureWidth(data,i)),continuous=Boolean(layout.continuous)&&!exporting;
 const width=continuous?Math.max(baseWidth,left+widths.reduce((s,n)=>s+n,0)+margin):baseWidth;
 const systems=[];let current=[],used=0;const cap=Math.max(1,Math.min(32,Number(layout.measuresPerSystem)||32));
 for(let i=0;i<measureCount;i++){
  const forced=data.some(p=>{const pr=child(p.bars[i]?.measure,'print');return pr?.getAttribute('new-system')==='yes'||pr?.getAttribute('new-page')==='yes';});
  if(!continuous&&current.length&&(used+widths[i]>width-left-margin||current.length>=cap||forced)){systems.push(current);current=[];used=0;}
  current.push(i);used+=widths[i];
 }if(current.length)systems.push(current);
 const rowMetrics=lanes.map(lane=>{
  let chord=1,high=0,low=0,lyrics=0;const groups=new Map();
  for(const bar of lane.data.bars)for(const n of bar.notes)if(n.staff===lane.staff&&n.voice===lane.voice){
   const key=bar.index+':'+value(n.onset)+':'+n.grace;groups.set(key,(groups.get(key)??0)+1);
   chord=Math.max(chord,groups.get(key));high=Math.max(high,n.number.octave);low=Math.max(low,-n.number.octave);lyrics=Math.max(lyrics,children(n.node,'lyric').length);
  }
  const up=(chord-1)*42+high*6+56,down=Math.max(42,low*6+38)+lyrics*22;
  return {up,height:up+down};
 });
 const systemHeight=rowMetrics.reduce((s,n)=>s+n.height,0)+38,paperRatio=({A4_P:297/210,A4_L:210/297,A3_P:420/297,Letter_P:279.4/215.9})[layout.paper]??297/210;
 const pageHeight=continuous?margin*2+systemHeight+96:Math.max(width*paperRatio,systemHeight+margin*2+96),pages=[],noteVisuals=new Map(),positions=[];
 let page,y;
 const newPage=()=>{page=svg('svg',{xmlns:NS,width:width*zoom,height:pageHeight*zoom,viewBox:`0 0 ${width} ${pageHeight}`,class:'jianpu-page','data-score-notation':'jianpu',role:'group','aria-label':t('可编辑简谱','Editable numbered score')});page.append(svg('rect',{width,height:pageHeight,fill:'white'}));pages.push(page);y=margin;
  const title=doc.querySelector('work-title')?.textContent??doc.querySelector('movement-title')?.textContent??'';text(page,width/2,y+24,title,24,{'text-anchor':'middle','font-weight':'600'});
  const composer=doc.querySelector('creator[type="composer"]')?.textContent??'';if(composer)text(page,width-margin,y+46,composer,13,{'text-anchor':'end'});
  if(warnings.size)text(page,margin,y+66,t('完整记号请查看五线谱。','View the staff score for all marks.'),11,{'data-jianpu-warning':[...warnings].join(','),class:'jp-warning'});y+=76;};
 for(let systemIndex=0;systemIndex<systems.length;systemIndex++){
  const bars=systems[systemIndex],newPageRequested=data.some(p=>child(p.bars[bars[0]]?.measure,'print')?.getAttribute('new-page')==='yes');
  if(!page||!continuous&&(y+systemHeight>pageHeight-margin||newPageRequested&&systemIndex>0))newPage();
  const top=y+14,system=svg('g',{'data-jianpu-system':systemIndex});page.append(system);let rowY=top;
  const total=bars.reduce((n,i)=>n+widths[i],0),factor=!continuous&&bars.length>1?Math.max(1,(width-left-margin)/total):1;
  for(let laneIndex=0;laneIndex<lanes.length;laneIndex++){
   const lane=lanes[laneIndex],baseline=rowY+rowMetrics[laneIndex].up,label=lane.data.part.name+(lane.data.lanes.length>1?' · '+lane.staff+'/'+lane.voice:'');
   const abbreviated=[...label].slice(0,/[\u2e80-\uffff]/.test(label)?8:17).join(''),labelNode=text(system,margin,baseline-4,abbreviated===label?label:abbreviated+'…',13,{'data-jianpu-part':lane.data.part.id});
   labelNode.append(svg('title',{},label));
   let x=left;
   for(const index of bars){
    const bar=lane.data.bars[index],barWidth=widths[index]*factor;if(!bar){x+=barWidth;continue;}
    const local=svg('g',{'data-jianpu-measure':bar.measure.getAttribute('id'),'data-jianpu-voice':lane.id});system.append(local);
    if(laneIndex===0)text(local,x+8,top-8,bar.measure.getAttribute('number')??index+1,12,{'data-jianpu-measure-number':index+1});
    text(local,x+8,rowY+4,keyLabel(bar.key)+'  '+bar.timeline.attrs.beats+'/'+bar.timeline.attrs.beatType,11,{'data-jianpu-meter':'yes'});
    const forwardRepeat=children(bar.measure,'barline').find(n=>n.getAttribute('location')==='left'&&child(n,'repeat')?.getAttribute('direction')==='forward');
    if(forwardRepeat){line(local,x,rowY-12,x,rowY+rowMetrics[laneIndex].height-12,2.7);line(local,x+5,rowY-12,x+5,rowY+rowMetrics[laneIndex].height-12);dot(local,x+12,baseline-15);dot(local,x+12,baseline-5);}
    const notes=bar.notes.filter(n=>n.staff===lane.staff&&n.voice===lane.voice),groups=new Map(),keyState=new Map(),duration=Math.max(.125,value(bar.timeline.duration));
    for(const note of notes){const onset=value(note.onset),key=String(onset)+(note.grace?':grace':'');if(!groups.has(key))groups.set(key,[]);groups.get(key).push(note);}
    const quarter=(barWidth-40)/duration;
    for(const groupNotes of groups.values()){
     groupNotes.sort((a,b)=>(b.pitch??-1)-(a.pitch??-1));const group=svg('g',{'data-score-notes':groupNotes.map(n=>n.id).join(','),role:'button',tabindex:0,
      'aria-label':groupNotes.map(n=>n.rest?t('休止','Rest'):n.number.digit+' ('+(n.number.spelled??t('鼓音','Drum'))+')').join(', ')+', '+t('小节','measure')+' '+(index+1)});local.append(group);
     const noteX=x+20+value(groupNotes[0].onset)*quarter;
     for(let k=0;k<groupNotes.length;k++){
      const note=groupNotes[k],noteY=baseline-(groupNotes.length-1-k)*42,drawn=noteShape(group,note,noteX,noteY,keyState);noteVisuals.set(note.id,drawn.group);
      for(let beat=1;beat<Math.floor(drawn.base);beat++)line(drawn.group,beat*quarter-6,-7,beat*quarter+6,-7,1.5);
      for(const[verse,lyric]of children(note.node,'lyric').entries())text(local,noteX,baseline+34+verse*20,string(lyric,'text'),14,{'text-anchor':'middle','data-jianpu-lyric':note.id});
      if(child(child(note.node,'notations'),'fermata'))text(group,noteX,noteY-45,'𝄐',18,{'text-anchor':'middle'});
      positions.push({note,x:noteX,y:noteY,parent:system,page:pages.length-1,system:systemIndex,lane:lane.data.part.id+':'+lane.id,left,right:left+total*factor});
     }
    }
    if(index===bars[0])line(local,x,rowY-12,x,rowY+rowMetrics[laneIndex].height-12,1);
    barline(local,x+barWidth,rowY-12,rowY+rowMetrics[laneIndex].height-12,bar.measure,index===measureCount-1);x+=barWidth;
   }
   rowY+=rowMetrics[laneIndex].height;
  }
  y+=systemHeight;
 }
 for(let i=0;i<positions.length;i++){
  const current=positions[i];if(!children(current.note.node,'tie').some(n=>n.getAttribute('type')==='start'))continue;
  const next=positions.slice(i+1).find(n=>n.lane===current.lane&&n.note.pitch===current.note.pitch&&!n.note.rest);
  if(next){
   const curve=(parent,x1,y1,x2,y2)=>{if(x2-x1>3)parent.append(svg('path',{d:`M ${x1} ${y1} Q ${(x1+x2)/2} ${Math.min(y1,y2)-18} ${x2} ${y2}`,fill:'none',stroke:'#17243a','stroke-width':1.2,'data-jianpu-tie':'yes'}));};
   if(next.page===current.page&&next.system===current.system)curve(current.parent,current.x+8,current.y-18,next.x-8,next.y-18);
   else {curve(current.parent,current.x+8,current.y-18,current.right-8,current.y-18);curve(next.parent,next.left+4,next.y-18,next.x-8,next.y-18);}
  }
 }
 return {pages,noteVisuals,warnings:[...warnings],noteCount,systemCount:systems.length};
}
