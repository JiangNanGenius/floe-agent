// SPDX-License-Identifier: MPL-2.0
import assert from 'node:assert/strict';
import {EditorEngine} from '../../FloeHeavyEditorSupport/Web/runtime.js';
import {createScore,normalizeScore,scoreDocument,partList,noteTimeline,child,string,pitchMIDI} from '../Web/model.js';
import {registerParts} from '../Web/parts.js';
import {registerEditing} from '../Web/edit.js';
import {registerNotation} from '../Web/notation.js';
import {registerPlayback,compileScore} from '../Web/playback.js';
import {registerAnalysisAndLayout} from '../Web/analysis.js';
import {registerFormats,readMXL} from '../Web/formats.js';
import {registerScoreNative,scoreNativeSnapshot} from '../Web/native.js';
import {registerProfessionalScore} from '../Web/professional.js';
import {readMIDI} from '../Web/midi.js';
export async function run(){
 const details=[];const e=new EditorEngine({kind:'score',create:createScore,normalize:normalizeScore,nativeSnapshot:scoreNativeSnapshot});
 for(const register of [registerParts,registerEditing,registerNotation,registerPlayback,registerAnalysisAndLayout,registerFormats,registerScoreNative])register(e);
 const originalIDs=e.commandIndex().filter(x=>!x.id.startsWith('score.ui.')).map(x=>x.id);assert.equal(originalIDs.length,57);registerProfessionalScore(e);
 assert(originalIDs.every(id=>e.commandIndex().some(x=>x.id===id)));assert.equal(e.commandIndex().filter(x=>!x.id.startsWith('score.ui.')).length,60);details.push('All 57 original commands remain discoverable alongside tuning, atomic TAB entry and atomic drum entry');
 e.render=async()=>{};await e.load({kind:'score',revision:0,content:createScore()});
 const exec=async(command,args={})=>{const result=await e.execute({command,arguments:args,revision:e.revision});if(['edit','importFile'].includes(e.command(command).access))e.acknowledge(e.revision+1);e.nativeSnapshot();return result;};
 await exec('score.project.template',{template:'quartet',bars:4});let parts=partList(scoreDocument(e.state));
 await exec('score.edit.insert',{part:parts[0].id,pitch:'C4',type:'half',voice:1,staff:1});
 await exec('score.edit.insert',{part:parts[0].id,pitch:'G3',type:'half',voice:2,staff:1});
 let timeline=noteTimeline(partList(scoreDocument(e.state))[0],0);assert.equal(timeline.notes.filter(n=>!n.rest).length,2);assert.deepEqual(timeline.notes.filter(n=>!n.rest).map(n=>n.voice).sort(),['1','2']);
 const reopenPayload=structuredClone(e.payload),reopenRevision=e.revision;await e.load({kind:'score',revision:reopenRevision,content:reopenPayload});assert.deepEqual(e.payload,reopenPayload);details.push('Independent voices on the same staff survive actual original/history payload save and reopen');
 await exec('score.parts.view',{part:parts[0].id,concert:false});const source=e.state.xml;
 await exec('score.layout.settings',{scope:'part',part:parts[0].id,paper:'A4_L',margin:12,measuresPerSystem:2,staffSpacing:8,zoom:1});assert.equal(e.state.xml,source);assert.equal(e.state.layout.paper,'A4_P');assert.equal(e.nativeSnapshot().layout.paper,'A4_L');await exec('score.layout.settings',{scope:'part',part:parts[0].id,zoom:0.8});assert.equal(e.nativeSnapshot().layout.paper,'A4_L');assert.equal(e.nativeSnapshot().layout.margin,12);details.push('Linked-part layout is persisted separately without changing full-score MusicXML or other part settings');
 const rendered=[];let disposed=0;
 // Controlled source-dispatch contract ONLY; actual OSMD/PDF is separately
 // exercised by the real WKWebView qualification, never inferred from this stub.
 e.createScoreExportSurface=async(doc,layout)=>{rendered.push({parts:partList(doc).map(p=>p.id),paper:layout.paper});const surface=document.createElement('div');surface.innerHTML='<svg xmlns="http://www.w3.org/2000/svg" width="800" height="1131"><path d="M0 0 L10 10"/></svg>';return {surface,dispose:()=>disposed++};};
 const revision=e.revision,history=structuredClone(e.payload.history),view=e.viewPart,selection=structuredClone(e.selection);
 await exec('score.export',{format:'svg',linkedPart:false});assert.equal(rendered.at(-1).parts.length,4);assert.equal(rendered.at(-1).paper,'A4_P');
 await exec('score.export',{format:'svg',linkedPart:true});assert.deepEqual(rendered.at(-1).parts,[parts[0].id]);assert.equal(rendered.at(-1).paper,'A4_L');
 const allParts=await exec('score.parts.export',{format:'svg'});assert.equal(allParts.artifacts.length,4);assert.equal(new Set(allParts.artifacts.map(a=>a.name)).size,4);assert(rendered.slice(-4).every(x=>x.parts.length===1));assert.equal(disposed,6);assert.equal(e.state.xml,source);assert.equal(e.revision,revision);assert.equal(e.viewPart,view);assert.deepEqual(e.selection,selection);assert.deepEqual(e.payload.history,history);details.push('Full score and linked/all-part graphics use the requested source and layout without changing selection, view, revision or history');
 const xml=(await exec('score.export',{format:'musicxml',linkedPart:false})).artifacts[0];const xmlText=new TextDecoder().decode(Uint8Array.from(atob(xml.base64),c=>c.charCodeAt(0)));assert.equal(partList(scoreDocument({xml:xmlText})).length,4);
 const mxl=(await exec('score.parts.export',{format:'mxl'})).artifacts;assert.equal(mxl.length,4);for(const artifact of mxl){const archive=readMXL(Uint8Array.from(atob(artifact.base64),c=>c.charCodeAt(0)));assert.equal(partList(archive.doc).length,1);}
 const midi=(await exec('score.parts.export',{format:'midi'})).artifacts;assert.equal(midi.length,4);for(const artifact of midi)readMIDI(Uint8Array.from(atob(artifact.base64),c=>c.charCodeAt(0)));details.push('All linked parts produce independently parseable real MXL and SMF files; full-score XML retains all parts');
 await assert.rejects(exec('score.layout.settings',{scope:'other'}));assert.equal(e.state.xml,source);details.push('Invalid layout scope rolls back the original');
 await exec('score.project.template',{template:'tab',bars:2});let snapshot=e.nativeSnapshot();
 await exec('score.parts.tuning',{part:snapshot.selection.part,measure:snapshot.selection.measure,staff:1,tuning:'D4 A3 G3 D3 A2 D2',capo:3});
 snapshot=e.nativeSnapshot();assert.deepEqual(snapshot.current.staffDetails.tuning,[62,57,55,50,45,38]);assert.equal(snapshot.current.staffDetails.capo,3);
 await exec('score.edit.tabInsert',{part:snapshot.selection.part,measure:snapshot.selection.measure,staff:1,voice:1,type:'quarter',string:6,fret:0,mode:'replace'});
 let selected=e.nativeSnapshot().current.note;assert.equal(selected.pitch,41);let doc=scoreDocument(e.state),note=doc.querySelector('note[id="'+selected.id+'"]');assert.equal(string(child(child(note,'notations'),'technical'),'string'),'6');assert.equal(string(child(child(note,'notations'),'technical'),'fret'),'0');
 await exec('score.edit.technical',{string:6,fret:3});assert.equal(e.nativeSnapshot().current.note.pitch,44);details.push('TAB entry and selected-note editing honor actual bottom-to-top MusicXML tuning, string-one-highest convention and capo');
 const beforeInvalid=e.state.xml;await assert.rejects(exec('score.edit.tabInsert',{staff:1,string:7,fret:0}));await assert.rejects(exec('score.parts.tuning',{staff:1,tuning:'E99',capo:3}));assert.equal(e.state.xml,beforeInvalid);details.push('Invalid fretboard input leaves the original unchanged');await exec('score.edit.transpose',{semitones:1});doc=scoreDocument(e.state);selected=e.nativeSnapshot().current.note;note=doc.querySelector('note[id=\"'+selected.id+'\"]');assert.equal(selected.pitch,45);assert.equal(string(child(child(note,'notations'),'technical'),'fret'),'4');
 await exec('score.edit.tabInsert',{pitch:'C4',staff:1,voice:2,type:'quarter',mode:'append'});assert.equal(e.nativeSnapshot().current.note.pitch,60);assert.equal(e.nativeSnapshot().current.note.voice,'2');
 const tabState=structuredClone(e.payload);await e.load({kind:'score',revision:e.revision,content:tabState});assert.equal(e.nativeSnapshot().current.staffDetails.capo,3);details.push('Keyboard pitch entry chooses a playable string/fret and preserves polyphony and tuning on reopen');
 await exec('score.project.template',{template:'guitar',bars:1});snapshot=e.nativeSnapshot();await exec('score.edit.insert',{part:snapshot.parts[0].id,staff:1,voice:1,pitch:'C4',type:'quarter'});await exec('score.edit.technical',{string:6,fret:3});assert.equal(compileScore(e.state,{respectMix:false,includeMetronome:false}).events[0].pitch,43);details.push('Ordinary octave-transposing guitar fingering compiles the intended sounding pitch and generic TAB transposition updates frets');
 await exec('score.project.template',{template:'drums',bars:1});snapshot=e.nativeSnapshot();
 const hits=[36,38,42,46,45,48,49,51];for(const drum of hits)await exec('score.edit.percussionInsert',{part:snapshot.selection.part,measure:snapshot.selection.measure,staff:1,voice:2,type:'eighth',mode:'append',drum});
 const performance=compileScore(e.state,{respectMix:false,includeMetronome:false});assert.deepEqual(performance.events.map(n=>n.pitch),hits);assert(performance.events.every(n=>n.channel===9));
 const drumDoc=scoreDocument(e.state),part=partList(drumDoc)[0];assert.equal(noteTimeline(part,0).notes.filter(n=>!n.rest&&n.voice==='2').length,8);const toms=[...drumDoc.querySelectorAll('note')].filter(n=>{const id=child(n,'instrument')?.getAttribute('id');return id?.endsWith('D45')||id?.endsWith('D48');});assert(toms.every(n=>!child(n,'notehead')));details.push('Native drum-pad commands create real unpitched channel-10 performance with independent voice and correct normal tom noteheads');
 await globalThis.captureProfessionalArtifact('professional-drums.musicxml',new TextEncoder().encode((await exec('score.export',{format:'musicxml'})).artifacts[0]?new TextDecoder().decode(Uint8Array.from(atob((await exec('score.export',{format:'musicxml'})).artifacts[0].base64),c=>c.charCodeAt(0))):''));
 await exec('score.project.template',{template:'quartet',bars:2});await exec('score.parts.view',{part:null});const beforeCancel=e.state.xml;const oldDispose=disposed;
 e.createScoreExportSurface=async()=>{e.abortController.abort();const surface=document.createElement('div');surface.innerHTML='<svg><path d="M0 0L1 1"/></svg>';return {surface,dispose:()=>disposed++};};
 await assert.rejects(exec('score.parts.export',{format:'svg'}));assert.equal(e.state.xml,beforeCancel);assert.equal(disposed,oldDispose+1);details.push('Cancelled all-part export disposes its surface and returns no success or partial original change');
 return {passed:true,checks:details.length,details,publicCommands:60,scope:'Actual dispatcher/MusicXML/part export/model contracts; mocked engraving source dispatch only; real graphics checked in WKWebView separately'};
}
