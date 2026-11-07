// SPDX-License-Identifier: MPL-2.0
import { clone,uid,t,required,finite,parseXML,escapeXML } from '../../FloeHeavyEditorSupport/Web/runtime.js';
export const field=(key,label,type='text',extra={})=>({key,label,type,...extra});
export const gcd=(a,b)=>b?gcd(b,a%b):Math.abs(a);
export const fraction=(n,d=1)=>{if(!Number.isFinite(n)||!Number.isFinite(d)||d===0)throw new Error('Invalid musical duration');if(!Number.isInteger(n)||!Number.isInteger(d)){n=Math.round(n*1000000);d=Math.round(d*1000000);}const g=gcd(n,d)||1;return {n:n/g,d:d/g};};
export const value=f=>typeof f==='number'?f:f.n/f.d;
export const add=(a,b)=>fraction(a.n*b.d+b.n*a.d,a.d*b.d);
export const subtract=(a,b)=>fraction(a.n*b.d-b.n*a.d,a.d*b.d);
export function parseFraction(input){if(typeof input==='object'&&input!==null)return fraction(input.n,input.d);const [n,d='1']=String(input??0).split('/');return fraction(Number(n),Number(d));}
export const durationTypes={maxima:32,long:16,breve:8,whole:4,half:2,quarter:1,eighth:.5,'16th':.25,'32nd':.125,'64th':.0625,'128th':.03125,'256th':.015625};
export function notatedDuration(type,dots=0,actual=1,normal=1){const base=required(durationTypes[type],'Unknown note duration'),multiplier=2-1/2**Math.max(0,Math.trunc(dots));return fraction(base*1024*multiplier*Math.max(1,normal),1024*Math.max(1,actual));}
export function serialize(doc){return typeof XMLSerializer!=='undefined'?new XMLSerializer().serializeToString(doc):doc.toString();}
export const children=(node,tag)=>[...(node?.children??[])].filter(n=>n.tagName===tag);
export const child=(node,tag)=>children(node,tag)[0];
export const string=(node,tag,fallback='')=>child(node,tag)?.textContent??fallback;
export function node(doc,name,content,attrs={}){const element=doc.createElement(name);if(content!==undefined&&content!==null)element.textContent=String(content);for(const[k,v]of Object.entries(attrs))if(v!==undefined)element.setAttribute(k,String(v));return element;}
export function set(node_,name,content){let element=child(node_,name);if(content===undefined||content===null){element?.remove();return;}if(!element){element=node(node_.ownerDocument,name);node_.append(element);}element.textContent=String(content);return element;}
export function ensure(node_,name){return child(node_,name)??node_.appendChild(node(node_.ownerDocument,name));}
export function scoreDocument(state){const doc=parseXML(state.xml);if(doc.documentElement.tagName!=='score-partwise')throw new Error(t('需要 MusicXML 分部乐谱。','A partwise MusicXML score is required.'));return doc;}
export function ensureIDs(doc){for(const n of doc.querySelectorAll('measure,note,direction,harmony'))if(!n.getAttribute('id'))n.setAttribute('id','floe-'+n.tagName+'-'+uid());return doc;}
export function normalizeScore(state){state.layout??={paper:'A4_P',zoom:1,continuous:false};state.playback??={tempoScale:1,loop:false,metronome:false,parts:{}};state.playback.parts??={};const doc=ensureIDs(scoreDocument(state));state.title??=doc.querySelector('work-title')?.textContent??'Score';state.xml=serialize(doc);}
export function partList(doc){const definitions=[...doc.querySelectorAll('part-list > score-part')];return [...doc.documentElement.children].filter(n=>n.tagName==='part').map(part=>{const definition=definitions.find(n=>n.getAttribute('id')===part.getAttribute('id'));return {id:part.getAttribute('id'),name:definition?string(definition,'part-name'):part.getAttribute('id'),node:part,definition,measures:children(part,'measure')};});}
export function currentPart(e,doc,id){const parts=partList(doc);if(id)return required(parts.find(p=>p.id===id),t('乐器已不存在。','The instrument no longer exists.'));return required(parts.find(p=>p.id===e.selection?.part)??parts[0],t('请选择一个乐器。','Choose an instrument.'));}
export function currentMeasure(e,doc,args={}){const part=currentPart(e,doc,args.part),measure=args.measure?part.measures.find(m=>m.getAttribute('id')===args.measure):(part.measures.find(m=>m.getAttribute('id')===e.selection?.measure)??part.measures[Math.max(0,Math.trunc(args.index??0))]);return {part,measure:required(measure,t('请选择一个小节。','Choose a measure.'))};}
export function currentNote(e,doc,args={}){const context=currentMeasure(e,doc,args),id=args.note??e.selection?.note;return {...context,note:required(children(context.measure,'note').find(n=>n.getAttribute('id')===id),t('请选择一个音符。','Choose a note.'))};}
export function commit(e,doc){ensureIDs(doc);e.state.xml=serialize(doc);e.previewVersion=(e.previewVersion??0)+1;}
export function attributesAt(part,index){let divisions=960,beats=4,beatType=4,fifths=0,staves=1;const clefs={1:{sign:'G',line:2}},transpose={diatonic:0,chromatic:0,octave:0};for(let i=0;i<=index&&i<part.measures.length;i++)for(const entry of part.measures[i].children){if(i===index&&['note','backup','forward'].includes(entry.tagName))break;if(entry.tagName!=='attributes')continue;const attrs=entry;if(child(attrs,'divisions')){divisions=Number(string(attrs,'divisions'));if(!Number.isFinite(divisions)||divisions<=0)throw new Error('MusicXML divisions must be positive');}const time=child(attrs,'time');if(time){const numbers=children(time,'beats'),types=children(time,'beat-type');if(numbers.length){let quarters=fraction(0),denominator=1;for(let j=0;j<numbers.length;j++){const n=numbers[j].textContent.split('+').reduce((sum,b)=>sum+Number(b),0),d=Number(types[j]?.textContent??types[0]?.textContent??4);if(!Number.isFinite(n)||n<=0||!Number.isFinite(d)||d<=0)throw new Error('Invalid MusicXML meter');quarters=add(quarters,fraction(n*4,d));denominator=denominator/gcd(denominator,d)*d;}beatType=denominator;beats=value(quarters)*denominator/4;}}if(child(attrs,'key'))fifths=Number(string(child(attrs,'key'),'fifths',0));if(child(attrs,'staves'))staves=Number(string(attrs,'staves',1));for(const clef of children(attrs,'clef'))clefs[Number(clef.getAttribute('number')??1)]={sign:string(clef,'sign','G'),line:Number(string(clef,'line',2)),octave:Number(string(clef,'clef-octave-change',0))};if(child(attrs,'transpose')){transpose.diatonic=Number(string(child(attrs,'transpose'),'diatonic',0));transpose.chromatic=Number(string(child(attrs,'transpose'),'chromatic',0));transpose.octave=Number(string(child(attrs,'transpose'),'octave-change',0));}}
 return {divisions,beats,beatType,fifths,staves,clefs,transpose,quarters:fraction(beats*4,beatType)};
}
export function pitchMIDI(note){const pitch=child(note,'pitch');if(!pitch)return null;const steps={C:0,D:2,E:4,F:5,G:7,A:9,B:11};return (Number(string(pitch,'octave',4))+1)*12+(steps[string(pitch,'step','C')]??0)+Number(string(pitch,'alter',0));}
export function pitchParts(input){if(typeof input==='number'){const midi=Math.max(0,Math.min(127,Math.round(input))),names=['C','C#','D','D#','E','F','F#','G','G#','A','A#','B'];return pitchParts(names[midi%12]+(Math.floor(midi/12)-1));}const match=/^([A-Ga-g])([#bx♯♭]*)(-?\d+)$/.exec(String(input).trim());if(!match)throw new Error('Use a pitch such as C4 or F#5');const alter=[...match[2]].reduce((s,c)=>s+(c==='#'||c==='♯'?1:c==='x'?2:-1),0);return {step:match[1].toUpperCase(),alter,octave:Number(match[3])};}
export function noteTimeline(part,index){
 const measure=part.measures[index],attrs=attributesAt(part,index),notes=[];let divisions=attributesAt(part,index-1).divisions,cursor=fraction(0),lastOnset=fraction(0),max=fraction(0);
 for(const entry of measure.children){if(entry.tagName==='attributes'&&child(entry,'divisions'))divisions=Number(string(entry,'divisions'));else if(entry.tagName==='backup')cursor=subtract(cursor,fraction(Number(string(entry,'duration',0)),divisions));else if(entry.tagName==='forward')cursor=add(cursor,fraction(Number(string(entry,'duration',0)),divisions));else if(entry.tagName==='note'){
  const grace=Boolean(child(entry,'grace')),duration=grace?fraction(0):fraction(Number(string(entry,'duration',0)),divisions),chord=Boolean(child(entry,'chord')),onset=chord?lastOnset:cursor;if(!chord)lastOnset=onset;
  notes.push({id:entry.getAttribute('id'),node:entry,onset,duration,voice:string(entry,'voice','1'),staff:Number(string(entry,'staff',1)),pitch:pitchMIDI(entry),rest:Boolean(child(entry,'rest')),grace});
  if(!chord)cursor=add(cursor,duration);if(value(add(onset,duration))>value(max))max=add(onset,duration);
 }}return {notes,attrs,actualDuration:max,duration:value(max)>value(attrs.quarters)?max:attrs.quarters};
}
export function rewriteMeasure(part,index,notes){
 const measure=part.measures[index],attrs=attributesAt(part,index),doc=measure.ownerDocument;let divisions=attrs.divisions;
 for(const note of notes){divisions=divisions/gcd(divisions,note.duration.d)*note.duration.d;divisions=divisions/gcd(divisions,note.onset.d)*note.onset.d;if(divisions>1e8)throw new Error('Musical subdivisions are too complex');}
 // Capture the original stream before moving notes. Mid-bar attributes retain
 // their exact temporal anchor; direction offsets become absolute from bar 0.
 const attributes=children(measure,'attributes')[0]??node(doc,'attributes'),extra=[];let oldDivisions=attributesAt(part,index-1).divisions,oldCursor=fraction(0),seenTimed=false;
 for(const entry of [...measure.children]){
  if(entry.tagName==='attributes'){if(child(entry,'divisions'))oldDivisions=Number(string(entry,'divisions'));if(entry!==attributes){extra.push({node:entry,onset:oldCursor});entry.remove();}else if(seenTimed){extra.push({node:entry.cloneNode(true),onset:oldCursor});for(const n of [...entry.children])n.remove();}}
  else if(entry.tagName==='backup'){oldCursor=subtract(oldCursor,fraction(Number(string(entry,'duration',0)),oldDivisions));seenTimed=true;}
  else if(entry.tagName==='forward'){oldCursor=add(oldCursor,fraction(Number(string(entry,'duration',0)),oldDivisions));seenTimed=true;}
  else if(entry.tagName==='note'&&!child(entry,'chord')&&!child(entry,'grace')){oldCursor=add(oldCursor,fraction(Number(string(entry,'duration',0)),oldDivisions));seenTimed=true;}
  else if(['direction','harmony','figured-bass','sound'].includes(entry.tagName)){
   const offset=add(oldCursor,fraction(Number(string(entry,'offset',0)),oldDivisions));if(entry.tagName!=='sound')set(entry,'offset',Math.round(value(offset)*divisions));else if(value(offset)!==0){const direction=node(doc,'direction'),type=node(doc,'direction-type');type.append(node(doc,'words',''));direction.append(type,node(doc,'offset',Math.round(value(offset)*divisions)));measure.replaceChild(direction,entry);direction.append(entry);}for(const duration of children(entry,'duration'))duration.textContent=String(Math.round(Number(duration.textContent)*divisions/oldDivisions));
  }
 }
 // Fence inherited divisions even when imported source changed divisions inside
 // this bar. The following untouched bar must keep its original tick unit.
 if(oldDivisions!==divisions&&part.measures[index+1]){const next=ensure(part.measures[index+1],'attributes');if(!child(next,'divisions'))set(next,'divisions',oldDivisions);part.measures[index+1].insertBefore(next,part.measures[index+1].firstElementChild);}
 set(attributes,'divisions',divisions);if(!attributes.parentNode)measure.insertBefore(attributes,measure.firstElementChild);else if(attributes!==measure.firstElementChild)measure.insertBefore(attributes,measure.firstElementChild);for(const entry of extra)child(entry.node,'divisions')?.remove();
 for(const entry of [...measure.children])if(['note','backup','forward'].includes(entry.tagName))entry.remove();
 const right=children(measure,'barline').find(b=>(b.getAttribute('location')??'right')==='right'),append=n=>right?measure.insertBefore(n,right):measure.append(n),groups=new Map();for(const note of notes){const key=note.staff+':'+note.voice;if(!groups.has(key))groups.set(key,[]);groups.get(key).push(note);}if(!groups.size)groups.set('1:1',[]);
 let previousEnd=0,firstGroup=true;
 for(const group of groups.values()){
  if(previousEnd){const backup=node(doc,'backup');backup.append(node(doc,'duration',previousEnd));append(backup);}let cursor=0,lastOnset=-1;
  const stream=[...group,...(firstGroup?extra:[])].sort((a,b)=>value(a.onset)-value(b.onset)||Number(Boolean(a.duration))-Number(Boolean(b.duration))||Number(b.grace)-Number(a.grace)||(a.duration&&b.duration?value(b.duration)-value(a.duration):0));firstGroup=false;
  const move=onset=>{if(onset>cursor){const forward=node(doc,'forward');forward.append(node(doc,'duration',onset-cursor));append(forward);}else if(onset<cursor){const backup=node(doc,'backup');backup.append(node(doc,'duration',cursor-onset));append(backup);}cursor=onset;};
  for(const event of stream){const onset=Math.round(value(event.onset)*divisions),entry=event.node;if(!event.duration){move(onset);append(entry);lastOnset=-1;continue;}const duration=Math.round(value(event.duration)*divisions);if(onset!==lastOnset)move(onset);child(entry,'chord')?.remove();if(onset===lastOnset&&!event.rest&&!event.grace)entry.insertBefore(node(doc,'chord'),entry.firstElementChild);if(!event.grace)set(entry,'duration',duration);set(entry,'voice',event.voice);if(attrs.staves>1||event.staff>1)set(entry,'staff',event.staff);else child(entry,'staff')?.remove();append(entry);if(onset!==lastOnset||event.grace)cursor=onset+duration;lastOnset=event.grace?-1:onset;
  }previousEnd=cursor;
 }
 return divisions;
}
export function makeNote(doc,args){
  const entry=node(doc,'note',null,{id:'floe-note-'+uid()});if(args.grace)entry.append(node(doc,'grace',null,{slash:args.slash?'yes':'no'}));
  if(args.rest)entry.append(node(doc,'rest'));else{const pitch=pitchParts(args.pitch??'C4'),p=node(doc,'pitch');p.append(node(doc,'step',pitch.step));if(pitch.alter)p.append(node(doc,'alter',pitch.alter));p.append(node(doc,'octave',pitch.octave));entry.append(p);}
  const type=args.type??'quarter',duration=notatedDuration(type,args.dots??0,args.actual??1,args.normal??1);if(!args.grace)entry.append(node(doc,'duration',Math.round(value(duration)*960)));entry.append(node(doc,'voice',args.voice??'1'),node(doc,'type',type));
  for(let i=0;i<Math.max(0,args.dots??0);i++)entry.append(node(doc,'dot'));
  if(args.actual>1){const modification=node(doc,'time-modification');modification.append(node(doc,'actual-notes',args.actual),node(doc,'normal-notes',args.normal??2));entry.append(modification);const tuple=node(doc,'tuplet',null,{type:args.tupletStop?'stop':'start',number:1});ensure(entry,'notations').append(tuple);}
  if(args.staff>1)entry.append(node(doc,'staff',args.staff));return {id:entry.getAttribute('id'),node:entry,duration,voice:String(args.voice??1),staff:Number(args.staff??1),rest:Boolean(args.rest),grace:Boolean(args.grace)};
}
export function createScore(){
  const xml=`<?xml version="1.0" encoding="UTF-8"?><score-partwise version="4.0"><work><work-title>New score</work-title></work><identification><creator type="composer"></creator></identification><part-list><score-part id="P1"><part-name>Piano</part-name><part-abbreviation>Pno.</part-abbreviation><score-instrument id="I1"><instrument-name>Piano</instrument-name></score-instrument><midi-instrument id="I1"><midi-channel>1</midi-channel><midi-program>1</midi-program></midi-instrument></score-part></part-list><part id="P1"><measure number="1"><attributes><divisions>960</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes><direction><direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>120</per-minute></metronome></direction-type><sound tempo="120"/></direction><note><rest measure="yes"/><duration>3840</duration><voice>1</voice><type>whole</type></note><barline location="right"><bar-style>light-heavy</bar-style></barline></measure></part></score-partwise>`;
  return {title:t('新乐谱','New score'),xml,layout:{paper:'A4_P',zoom:1,continuous:false,measuresPerSystem:4},playback:{tempoScale:1,loop:false,metronome:false,parts:{}}};
}
export const partOptions=e=>partList(scoreDocument(e.state)).map(p=>({value:p.id,label:p.name}));
export const partField=(key='part',label=t('乐器','Instrument'))=>field(key,label,'select',{options:partOptions,default:e=>e.selection?.part??partOptions(e)[0]?.value??''});
export const measureField=()=>field('measure',t('小节','Measure'),'select',{options:(e,args={})=>{const doc=scoreDocument(e.state),part=currentPart(e,doc,args.part);return part.measures.map(m=>({value:m.getAttribute('id'),label:m.getAttribute('number')}));},default:e=>e.selection?.measure??currentPart(e,scoreDocument(e.state)).measures[0]?.getAttribute('id')});
export function canonicalXML(doc,{stripInternal=true}={}){
  const copy=doc.cloneNode(true),orders={
    'score-partwise':['work','movement-number','movement-title','identification','defaults','credit','part-list','part'],
    'score-part':['identification','part-name','part-name-display','part-abbreviation','part-abbreviation-display','group','score-instrument','player','midi-device','midi-instrument'],
    'midi-instrument':['midi-channel','midi-name','midi-bank','midi-program','midi-unpitched','volume','pan','elevation'],
    note:['grace','cue','chord','pitch','unpitched','rest','duration','tie','instrument','footnote','level','voice','type','dot','accidental','time-modification','stem','notehead','notehead-text','staff','beam','notations','lyric','play','listen'],
    attributes:['footnote','level','divisions','key','time','staves','part-symbol','instruments','clef','staff-details','transpose','directive','measure-style'],
    direction:['direction-type','offset','footnote','level','voice','staff','sound','listening'],
    harmony:['root','numeral','function','kind','inversion','bass','degree','frame','offset','footnote','level','staff'],
    'page-layout':['page-height','page-width','page-margins'],
    defaults:['scaling','concert-score','page-layout','system-layout','staff-layout','appearance','music-font','word-font','lyric-font','lyric-language'],
    'staff-details':['staff-type','staff-lines','line-detail','staff-tuning','capo','staff-size'],
    transpose:['diatonic','chromatic','octave-change','double']
  };
  for(const parent of [copy.documentElement??copy,...copy.querySelectorAll('*')]){const order=orders[parent.tagName];if(order){const list=[...parent.children].map((node,index)=>({node,index}));list.sort((a,b)=>{const x=order.indexOf(a.node.tagName),y=order.indexOf(b.node.tagName);return (x<0?999:x)-(y<0?999:y)||a.index-b.index;});for(const entry of list)parent.append(entry.node);}}
  if(stripInternal)for(const n of copy.querySelectorAll('*'))for(const a of [...n.attributes])if(a.name.startsWith('data-floe-')||(a.name==='id'&&a.value.startsWith('floe-')))n.removeAttribute(a.name);
  return serialize(copy);
}
