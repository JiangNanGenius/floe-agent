// SPDX-License-Identifier: MPL-2.0
// Small presentation DTO and transient UI commands for the native Score panels.
// Document edits remain the existing, revision-authorized score commands.
import {t,clone} from '../../FloeHeavyEditorSupport/Web/runtime.js';
import {scoreDocument,partList,currentPart,attributesAt,noteTimeline,child,children,string,durationTypes} from './model.js';
import {chooseSpelling} from './edit.js';

export const scoreInputDefaults=()=>({type:'quarter',dots:0,voice:1,staff:1,octave:4,mode:'replace',rest:false});
const fractionText=f=>f.d===1?String(f.n):f.n+'/'+f.d;
function context(e,doc=scoreDocument(e.state)){
  const part=currentPart(e,doc),index=Math.max(0,part.measures.findIndex(m=>m.getAttribute('id')===e.selection?.measure));
  return {doc,part,index,measure:part.measures[index]};
}
export function synchronizeScoreNativeContext(e){
  e.input??=scoreInputDefaults();
  if(!e.state?.xml)return;
  const doc=scoreDocument(e.state),parts=partList(doc);if(!parts.length)return;
  if(e.viewPart&&!parts.some(part=>part.id===e.viewPart)){e.viewPart=null;e.renderKey=null;}
  const current=context(e,doc),staves=attributesAt(current.part,current.index).staves;
  e.input.staff=Math.max(1,Math.min(staves,Number(e.input.staff)||1));
}
export function scoreTransportSnapshot(e){
  const transport=e.transport??{},duration=Math.max(0,Number(transport.duration??e.performance?.duration??0));
  let position=Math.max(0,Number(transport.position??0)),playing=Boolean(transport.playing);
  if(playing){const now=globalThis.performance?.now?.()??Date.now();position+=Math.max(0,(now-(transport.received??now))/1000);if(duration>0&&position>=duration){if(e.state?.playback?.loop)position%=duration;else{position=duration;playing=false;}}}
  return {playing,position:Math.min(duration||position,position),duration,sampledAt:Date.now(),referenceTimbres:Boolean(transport.referenceTimbres)};
}
function markLabel(mark){
  if(mark.tagName==='harmony'){const root=mark.querySelector('root-step')?.textContent??'',alter=Number(mark.querySelector('root-alter')?.textContent??0),kind=string(mark,'kind','');return root+(alter>0?'♯'.repeat(alter):'♭'.repeat(-alter))+' '+kind;}
  const type=child(mark,'direction-type'),first=type?.firstElementChild;if(!first)return t('演奏记号','Performance mark');
  if(['words','rehearsal'].includes(first.tagName))return first.textContent||t('文字','Text');
  if(first.tagName==='dynamics')return first.firstElementChild?.tagName??t('力度','Dynamic');
  if(first.tagName==='metronome')return t('速度 ','Tempo ')+(first.querySelector('per-minute')?.textContent??'');
  const names={wedge:t('渐变力度','Hairpin'),pedal:t('踏板','Pedal'),'octave-shift':t('八度线','Octave line'),segno:'Segno',coda:'Coda'};
  return (names[first.tagName]??t('演奏记号','Performance mark'))+(first.getAttribute('type')?' · '+first.getAttribute('type'):'');
}
export function scoreNativeSnapshot(e){
  synchronizeScoreNativeContext(e);
  const empty=()=>({schemaVersion:1,kind:'score',title:e.state?.title??'',revision:e.revision??0,selection:{part:'',measure:'',note:null,notes:[],count:0},parts:[],measures:[],current:{notes:[],marks:[],staves:1},input:clone(e.input),layout:clone(e.state?.layout??{}),view:{part:'',concert:false,keyboardVisible:e.nativeUI?.keyboardVisible!==false},playback:{tempoScale:1,loop:false,loopFrom:0,loopTo:0,metronome:false,...clone(e.state?.playback??{})},transport:scoreTransportSnapshot(e),diagnostics:[]});
  if(!e.state?.xml)return empty();
  const parsed=scoreDocument(e.state);if(!partList(parsed).length)return empty();
  const {doc,part,index,measure}=context(e,parsed),parts=partList(doc),timeline=noteTimeline(part,index),selected=new Set(e.selection?.notes??(e.selection?.note?[e.selection.note]:[]));
  const notes=timeline.notes.map(n=>({id:n.id,pitch:n.pitch,pitchName:n.rest?t('休止符','Rest'):n.pitch===null?t('鼓音','Drum'):chooseSpelling(n.pitch),onset:n.onset,duration:n.duration,onsetText:fractionText(n.onset),durationText:fractionText(n.duration),type:string(n.node,'type','quarter'),dots:children(n.node,'dot').length,voice:n.voice,staff:n.staff,rest:n.rest,grace:n.grace,selected:selected.has(n.id),actual:Number(string(child(n.node,'time-modification')??n.node,'actual-notes',1)),normal:Number(string(child(n.node,'time-modification')??n.node,'normal-notes',1))}));
  const current=notes.find(n=>n.id===e.selection?.note)??notes.find(n=>n.selected)??null;
  const allNoteIDs=new Set([...doc.querySelectorAll('note')].map(note=>note.getAttribute('id'))),selectedIDs=[...selected].filter(id=>allNoteIDs.has(id));
  return {
    schemaVersion:1,kind:'score',title:e.state.title,revision:e.revision,
    selection:{part:part.id,measure:measure.getAttribute('id'),note:current?.id??null,notes:selectedIDs.slice(0,512),count:selectedIDs.length},
    parts:parts.map(p=>({id:p.id,name:p.name,staves:attributesAt(p,0).staves,measureCount:p.measures.length,mix:{solo:false,mute:false,volume:1,...e.state.playback?.parts?.[p.id]}})),
    measures:part.measures.map((m,i)=>{const attrs=attributesAt(part,i);return {id:m.getAttribute('id'),number:m.getAttribute('number')??String(i+1),index:i+1,beats:attrs.beats,beatType:attrs.beatType,notesCount:children(m,'note').length};}),
    current:{part:part.id,partName:part.name,measure:measure.getAttribute('id'),index:index+1,beats:timeline.attrs.beats,beatType:timeline.attrs.beatType,fifths:timeline.attrs.fifths,staves:timeline.attrs.staves,clefs:Object.entries(timeline.attrs.clefs).map(([staff,clef])=>({staff:Number(staff),...clef})),notes,note:current,marks:[...measure.children].filter(n=>['direction','harmony'].includes(n.tagName)).map(n=>({id:n.getAttribute('id'),kind:n.tagName,label:markLabel(n)}))},
    input:clone(e.input),layout:clone(e.state.layout??{}),view:{part:e.viewPart??'',concert:Boolean(e.concertPitch),keyboardVisible:e.nativeUI?.keyboardVisible!==false},
    playback:{tempoScale:1,loop:false,loopFrom:0,loopTo:0,metronome:false,...clone(e.state.playback??{})},transport:scoreTransportSnapshot(e),
    diagnostics:(e.diagnostics??[]).slice(0,100).map((issue,index)=>({index:index+1,...issue}))
  };
}
export function selectScoreContext(e,args={}){
  const doc=scoreDocument(e.state),parts=partList(doc);let part,measure,note;
  if(args.note){
    for(const p of parts){if(args.part&&p.id!==args.part)continue;for(const m of p.measures){const n=children(m,'note').find(n=>n.getAttribute('id')===args.note);if(n){part=p;measure=m;note=n;break;}}if(note)break;}
    if(!note)throw new Error(t('音符已不存在。','The note no longer exists.'));
  }else{
    part=currentPart(e,doc,args.part);
    measure=args.measure?part.measures.find(m=>m.getAttribute('id')===args.measure):part.measures.find(m=>m.getAttribute('id')===e.selection?.measure)??part.measures[0];
    if(!measure)throw new Error(t('小节已不存在。','The measure no longer exists.'));
  }
  const staves=attributesAt(part,part.measures.indexOf(measure)).staves;
  if(args.staff!==undefined&&(!Number.isInteger(args.staff)||args.staff<1||args.staff>staves))throw new Error('Invalid score selection staff');
  const id=note?.getAttribute('id'),notes=id?(args.extend&&e.selection?.part===part.id?[...new Set([...(e.selection?.notes??[]),id])]:[id]):[];
  e.selection={part:part.id,measure:measure.getAttribute('id'),...(id?{note:id}:{}),notes};
  e.input??=scoreInputDefaults();if(note){e.input.staff=Number(string(note,'staff',1));const voice=Number(string(note,'voice',1));if(Number.isFinite(voice))e.input.voice=voice;}else e.input.staff=args.staff??Math.max(1,Math.min(staves,e.input.staff));
  if(e.viewPart&&e.viewPart!==part.id){e.viewPart=part.id;e.renderKey=null;}
  return {part:part.id,measure:measure.getAttribute('id'),note:id??null,selected:notes.length};
}
export function registerScoreNative(e){
  e.input??=scoreInputDefaults();
  const ui=(id,title,handler)=>e.register({id,title,access:'read',sideEffecting:true,hidden:true,fields:[]},handler);
  ui('score.ui.input',t('谱面输入状态','Score input state'),args=>{
    const next={...e.input},integer=(key,min,max)=>{if(args[key]===undefined)return;const v=Number(args[key]);if(!Number.isInteger(v)||v<min||v>max)throw new Error('Invalid score input '+key);next[key]=v;};
    if(args.type!==undefined){if(!Object.hasOwn(durationTypes,args.type))throw new Error('Unknown score duration');next.type=args.type;}
    if(args.mode!==undefined){if(!['replace','append','insert'].includes(args.mode))throw new Error('Invalid score entry mode');next.mode=args.mode;}
    integer('dots',0,3);integer('voice',1,64);if(args.staff!==undefined){const current=context(e);integer('staff',1,attributesAt(current.part,current.index).staves);}integer('octave',0,8);
    if(args.rest!==undefined){if(typeof args.rest!=='boolean')throw new Error('Invalid rest input');next.rest=args.rest;}
    e.input=next;return clone(next);
  });
  ui('score.ui.select',t('谱面选择','Score selection'),args=>selectScoreContext(e,args));
  ui('score.ui.view',t('谱面显示状态','Score view state'),args=>{
    if(args.part!==undefined&&args.part!==''&&!partList(scoreDocument(e.state)).some(p=>p.id===args.part))throw new Error('Unknown score part');
    if(args.part!==undefined)e.viewPart=args.part||null;
    if(args.concert!==undefined)e.concertPitch=Boolean(args.concert);
    if(args.keyboardVisible!==undefined)e.nativeUI={...e.nativeUI,keyboardVisible:Boolean(args.keyboardVisible)};
    e.renderKey=null;return {part:e.viewPart??'',concert:Boolean(e.concertPitch),keyboardVisible:e.nativeUI?.keyboardVisible!==false};
  });
  ui('score.ui.transport',t('谱面播放状态','Score transport state'),()=>scoreTransportSnapshot(e));
}
