// SPDX-License-Identifier: MPL-2.0
import {t} from '../../FloeHeavyEditorSupport/Web/runtime.js';
import {field,partField,measureField,scoreDocument,currentMeasure,attributesAt,child,ensure,set,pitchParts,commit} from './model.js';
import {register,numberField,selectField} from './parts.js';
import {insert,changePitch,chooseSpelling} from './edit.js';
import {staffDetails,frettedPitch,setTuning} from './fretboard.js';
export function registerProfessionalScore(e){
 const group=t('鼓谱与六线谱','Drums & tablature');
 register(e,'score.parts.tuning',t('调弦与变调夹','Tuning & capo'),group,'edit',[partField(),measureField(),numberField('staff',t('谱表','Staff'),1,{min:1,max:16}),field('tuning',t('空弦（从第一弦到末弦）','Open strings (highest string first)'),'text',{default:'E4 B3 G3 D3 A2 E2'}),numberField('capo',t('变调夹品位','Capo fret'),0,{min:0,max:24})],a=>{
  const doc=scoreDocument(e.state),{part,measure}=currentMeasure(e,doc,a),index=part.measures.indexOf(measure),staff=Number(a.staff??e.input?.staff??1);
  if(!Number.isInteger(staff)||staff<1||staff>attributesAt(part,index).staves)throw new Error('Invalid tuning staff');
  const values=String(a.tuning??'').trim().split(/[\s,]+/).filter(Boolean).map(name=>{const p=pitchParts(name),steps={C:0,D:2,E:4,F:5,G:7,A:9,B:11};return (p.octave+1)*12+steps[p.step]+p.alter;});
  setTuning(doc,part,index,staff,values,Number(a.capo??0));commit(e,doc);return {part:part.id,staff,strings:values.length,capo:Number(a.capo??0)};
 });
 const fields=[partField(),measureField(),numberField('staff',t('谱表','Staff'),1,{min:1,max:16}),numberField('voice',t('声部','Voice'),1,{min:1,max:64}),selectField('type',t('时值','Duration'),['whole','half','quarter','eighth','16th','32nd'],'quarter'),numberField('dots',t('附点','Dots'),0,{min:0,max:3}),selectField('mode',t('输入方式','Entry mode'),['replace','append','insert'],'append')];
 register(e,'score.edit.tabInsert',t('输入六线谱音符','Enter TAB note'),group,'edit',[...fields,numberField('string',t('弦','String'),1,{min:1,max:12}),numberField('fret',t('品位','Fret'),0,{min:0,max:36})],a=>{
  const doc=scoreDocument(e.state),{part,measure}=currentMeasure(e,doc,a),index=part.measures.indexOf(measure),staff=Number(a.staff??e.input?.staff??1),details=staffDetails(part,index,staff);
  if(details.clef!=='TAB'||staff<1||staff>attributesAt(part,index).staves)throw new Error('Choose a tablature staff');
  let stringNo=Number(a.string??1),fret=Number(a.fret??0);
  if(a.pitch!==undefined){const p=pitchParts(a.pitch),steps={C:0,D:2,E:4,F:5,G:7,A:9,B:11},wanted=(p.octave+1)*12+steps[p.step]+p.alter;const options=details.tuning.map((open,i)=>({string:i+1,fret:open===null?NaN:wanted+details.transpose-open-details.capo})).filter(x=>Number.isInteger(x.fret)&&x.fret>=0&&x.fret<=36).sort((a,b)=>a.fret-b.fret||a.string-b.string);if(!options.length)throw new Error('The pitch is outside this fretboard');stringNo=options[0].string;fret=options[0].fret;}
  const pitch=frettedPitch(details,stringNo,fret),result=insert(e,{...a,staff,pitch:chooseSpelling(pitch),rest:false});
  const updated=scoreDocument(e.state),note=updated.querySelector('note[id="'+result.note+'"]');if(!note)throw new Error('Inserted TAB note was not found');
  const technical=ensure(ensure(note,'notations'),'technical');set(technical,'string',stringNo);set(technical,'fret',fret);commit(e,updated);return {...result,string:stringNo,fret,pitch};
 });
 register(e,'score.edit.percussionInsert',t('输入鼓件','Enter drum hit'),group,'edit',[...fields,numberField('drum',t('鼓件 MIDI 音高','Drum MIDI pitch'),38,{min:35,max:81})],a=>{
  const doc=scoreDocument(e.state),{part,measure}=currentMeasure(e,doc,a),index=part.measures.indexOf(measure),staff=Number(a.staff??e.input?.staff??1),drum=Number(a.drum??38);
  if(staffDetails(part,index,staff).clef!=='percussion'||staff<1||staff>attributesAt(part,index).staves||!Number.isInteger(drum)||drum<35||drum>81||!part.definition)throw new Error('Choose a percussion staff and a valid drum');
  const result=insert(e,{...a,staff,pitch:'C5',rest:false});
  e.commands.get('score.edit.percussion').handler({drum,part:part.id,measure:measure.getAttribute('id'),notes:result.note});return {...result,drum};
 });
}
