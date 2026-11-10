// SPDX-License-Identifier: MPL-2.0
import {attributesAt,child,children,string,ensure,node,set,pitchMIDI} from './model.js';
const semitones={C:0,D:2,E:4,F:5,G:7,A:9,B:11};
export function staffDetails(part,index,staff=1){
 const attrs=attributesAt(part,index),clef=attrs.clefs[staff]?.sign??'G';let lines=clef==='TAB'?6:5,capo=0;const byLine=new Map();
 for(let i=0;i<=index;i++)for(const entry of part.measures[i]?.children??[]){
  if(i===index&&['note','backup','forward'].includes(entry.tagName))break;if(entry.tagName!=='attributes')continue;
  for(const details of children(entry,'staff-details'))if(Number(details.getAttribute('number')??1)===staff){
   if(child(details,'staff-lines'))lines=Number(string(details,'staff-lines'));if(child(details,'capo'))capo=Number(string(details,'capo'));
   for(const tuning of children(details,'staff-tuning')){const line=Number(tuning.getAttribute('line')),step=string(tuning,'tuning-step'),octave=Number(string(tuning,'tuning-octave')),alter=Number(string(tuning,'tuning-alter',0));const pitch=(octave+1)*12+semitones[step]+alter;if(!Number.isInteger(line)||line<1||!Number.isFinite(pitch)||pitch<0||pitch>127)throw new Error('Invalid staff tuning');byLine.set(line,pitch);}
  }
 }
 if(!Number.isInteger(lines)||lines<1||lines>12||!Number.isInteger(capo)||capo<0||capo>36)throw new Error('Invalid fretted staff details');
 const count=clef==='TAB'?lines:(byLine.size?Math.max(...byLine.keys()):6),fallback=[40,45,50,55,59,64],assumed=byLine.size===0&&count===6;
 const tuning=Array.from({length:count},(_,i)=>byLine.get(count-i)??(assumed?fallback[count-i-1]:null));
 return {staff,clef,lines,capo,tuning,assumedStandardTuning:assumed,percussion:clef==='percussion',transpose:attrs.transpose.chromatic+(attrs.transpose.octave??0)*12};
}
export function frettedPitch(details,stringNo,fret){
 if(!Number.isInteger(stringNo)||stringNo<1||stringNo>details.tuning.length||!Number.isInteger(fret)||fret<0||fret>36)throw new Error('Invalid string or fret');
 const open=details.tuning[stringNo-1];if(open===null)throw new Error('Configure this staff tuning first');const pitch=open+details.capo+fret-details.transpose;
 if(!Number.isInteger(pitch)||pitch<0||pitch>127)throw new Error('Fretted note is outside the MIDI range');return pitch;
}
export function setTuning(doc,part,index,staff,pitches,capo){
 if(!Array.isArray(pitches)||pitches.length<1||pitches.length>12||pitches.some(p=>!Number.isInteger(p)||p<0||p>127)||!Number.isInteger(capo)||capo<0||capo>24)throw new Error('Invalid tuning or capo');
 const measure=part.measures[index],attrs=ensure(measure,'attributes');measure.insertBefore(attrs,measure.firstElementChild);
 let clef=children(attrs,'clef').find(n=>Number(n.getAttribute('number')??1)===staff);if(!clef){clef=node(doc,'clef',null,{number:staff});attrs.append(clef);}set(clef,'sign','TAB');child(clef,'line')?.remove();
 let details=children(attrs,'staff-details').find(n=>Number(n.getAttribute('number')??1)===staff);if(!details){details=node(doc,'staff-details',null,{number:staff});attrs.append(details);}
 set(details,'staff-lines',pitches.length);for(const old of children(details,'staff-tuning'))old.remove();child(details,'capo')?.remove();
 const names=['C','C#','D','D#','E','F','F#','G','G#','A','A#','B'];
 for(let i=pitches.length-1;i>=0;i--){const pitch=pitches[i],name=names[pitch%12],tuning=node(doc,'staff-tuning',null,{line:pitches.length-i});tuning.append(node(doc,'tuning-step',name[0]));if(name.length>1)tuning.append(node(doc,'tuning-alter',1));tuning.append(node(doc,'tuning-octave',Math.floor(pitch/12)-1));details.append(tuning);}details.append(node(doc,'capo',capo));
}

export function alignFrettedNote(note,details,usedStrings=null){
 const technical=child(child(note,'notations'),'technical'),oldString=Number(string(technical,'string',0)),pitch=pitchMIDI(note);
 if(details.clef!=='TAB'&&!oldString)return;if(pitch===null){child(technical,'string')?.remove();child(technical,'fret')?.remove();return;}
 const options=details.tuning.map((open,i)=>({string:i+1,fret:open===null?NaN:pitch+details.transpose-open-details.capo})).filter(x=>Number.isInteger(x.fret)&&x.fret>=0&&x.fret<=36&&!usedStrings?.has(x.string)).sort((a,b)=>(a.string===oldString?-1:0)-(b.string===oldString?-1:0)||a.fret-b.fret||a.string-b.string);
 if(!options.length)throw new Error('No playable string for this note or chord');const chosen=options[0],target=ensure(ensure(note,'notations'),'technical');set(target,'string',chosen.string);set(target,'fret',chosen.fret);usedStrings?.add(chosen.string);
}
