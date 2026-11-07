// SPDX-License-Identifier: MPL-2.0
import assert from 'node:assert/strict';
import {installScoreInteractions} from '../Web/interaction.js';
import {scoreDocument,partList,children} from '../Web/model.js';
export async function checkScoreActivation(engine){
 const doc=scoreDocument(engine.state),part=partList(doc)[0],ids=part.measures.slice(0,2).map(m=>children(m,'note')[0].getAttribute('id')),surface=document.createElement('div'),calls=[],pending=[],transposes=[];
 const groups=ids.map(id=>{const g=document.createElementNS('http://www.w3.org/2000/svg','g');g.dataset.scoreNotes=id;g.setAttribute('role','button');g.setAttribute('tabindex','0');surface.append(g);return g;});document.body.append(surface);
 const e={scoreSurface:surface,state:engine.state},select=(note,extend)=>{calls.push({note,extend});const p=engine.perform('score.ui.select',{note,extend:Boolean(extend)});pending.push(p);return p;};
 installScoreInteractions(e,{select,transpose:async semitones=>{transposes.push(semitones);},edit:()=>{}});
 const Mouse=document.defaultView.MouseEvent,Key=document.defaultView.KeyboardEvent,emit=(index,type,options={})=>{const event=type.startsWith('key')?new Key(type,{bubbles:true,cancelable:true,...options}):new Mouse(type,{bubbles:true,cancelable:true,...options});groups[index].dispatchEvent(event);return event;},settle=async()=>{await Promise.all(pending.splice(0));await Promise.resolve();};
 const reset=async()=>{await engine.perform('score.ui.select',{note:ids[0]});calls.length=0;transposes.length=0;};
 try{
  await reset();emit(1,'click',{detail:0});await settle();assert.equal(engine.selection.measure,part.measures[1].getAttribute('id'),'AX click must select the activated rest in measure 2');assert.equal(calls.length,1);
  await reset();emit(1,'pointerdown',{clientY:100});emit(1,'pointerup',{clientY:100});emit(1,'click',{detail:1});await settle();assert.equal(calls.length,1,'A pointer gesture plus its click must activate once');
  await reset();emit(1,'pointerdown',{clientY:100,shiftKey:true});emit(1,'pointerup',{clientY:100,shiftKey:true});emit(1,'click',{detail:1});await settle();assert.deepEqual(new Set(engine.selection.notes),new Set(ids),'The following click must not reset pointer extension');assert.equal(calls.length,1);
  await reset();emit(1,'keydown',{key:'Enter'});emit(1,'keyup',{key:'Enter'});emit(1,'click',{detail:0});await settle();assert.equal(engine.selection.measure,part.measures[1].getAttribute('id'));assert.equal(calls.length,1,'Enter and an assistive synthetic click must activate once');
  await reset();let bubbled=0;const parentKey=()=>bubbled++;surface.parentElement.addEventListener('keydown',parentKey);const space=emit(1,'keydown',{key:' '});emit(1,'keydown',{key:' ',repeat:true});emit(1,'keyup',{key:' '});emit(1,'click',{detail:0});await settle();surface.parentElement.removeEventListener('keydown',parentKey);assert.equal(space.defaultPrevented,true);assert.equal(bubbled,0,'Space on a note must not reach the global play shortcut');assert.equal(calls.length,1);assert.equal(engine.selection.measure,part.measures[1].getAttribute('id'));
  await reset();emit(1,'pointerdown',{clientY:100});emit(1,'pointerup',{clientY:86});emit(1,'click',{detail:1});await settle();assert.equal(calls.length,1);assert.deepEqual(transposes,[2],'Drag still waits for selection and transposes once');
  await reset();emit(1,'pointerdown',{clientY:100});emit(1,'pointercancel',{clientY:100});await settle();calls.length=0;emit(1,'click',{detail:0});await settle();assert.equal(calls.length,1,'A cancelled gesture must not swallow a later AX activation');
  return 'Actual SVG activation handlers support AX click, pointer/click deduplication, preserved extension, Enter/Space, no Space playback bubbling, drag and pointer cancellation';
 }finally{surface.remove();await engine.perform('score.ui.select',{part:part.id,measure:part.measures[0].getAttribute('id')});}
}
