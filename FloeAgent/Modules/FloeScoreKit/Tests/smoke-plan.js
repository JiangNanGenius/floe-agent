// SPDX-License-Identifier: MPL-2.0
// Targeted regression for the real Integration/smoke-plan.json command sequence.
import assert from 'node:assert/strict';
import {EditorEngine,from64} from '../../FloeHeavyEditorSupport/Web/runtime.js';
import {createScore,normalizeScore} from '../Web/model.js';
import {registerParts} from '../Web/parts.js';
import {registerEditing} from '../Web/edit.js';
import {registerNotation} from '../Web/notation.js';
import {registerAnalysisAndLayout} from '../Web/analysis.js';
import {registerPlayback} from '../Web/playback.js';
import {registerFormats} from '../Web/formats.js';
import {readMIDI} from '../Web/midi.js';
export async function run(plan){
  const engine=new EditorEngine({kind:'score',create:createScore,normalize:normalizeScore});
  for(const register of [registerParts,registerEditing,registerNotation,registerAnalysisAndLayout,registerPlayback,registerFormats])register(engine);
  engine.render=async()=>{};
  await engine.load({kind:'score',revision:0,content:createScore()});
  let compiled,exportedMIDI,selection,transposition;
  const commands=[];
  for(const step of plan.steps){
    const response=await engine.execute({command:step.command,arguments:step.arguments,revision:engine.revision});
    if(['edit','importFile'].includes(engine.command(step.command).access))engine.acknowledge(engine.revision+1);
    commands.push(step.command);
    if(step.command==='score.edit.select')selection=response.result;
    if(step.command==='score.edit.transpose')transposition=response.result;
    if(step.command==='score.playback.compile')compiled=response.result;
    if(step.command==='score.export'&&step.arguments.format==='midi'){
      exportedMIDI=from64(response.artifacts[0].base64);
      break; // This regression targets score semantics/MIDI, not the rendered PDF host.
    }
  }
  assert.equal(selection.selected,3,'Select all three newly created voice-1 chord tones');
  assert.equal(transposition.changed,3,'Transpose the entire selected chord');
  assert.equal(compiled.format,'floe.score.performance/1');
  const partID=compiled.parts[0].id;
  const chord=compiled.events.filter(event=>event.part===partID&&event.measure===1&&event.pass===1&&event.staff===1&&event.voice==='1'&&event.startQuarter===0);
  const pitches=chord.map(event=>event.pitch).sort((a,b)=>a-b);
  assert.deepEqual(pitches,plan.expected.initialChordPitchesAfterTranspose);
  assert.deepEqual(pitches,[62,66,69]);
  assert.equal(chord.length,3);
  for(const event of chord){
    assert.equal(event.startQuarter,0);assert.equal(event.durationQuarter,1);assert.equal(event.start,0);
    assert.ok(Math.abs(event.duration-(60/108*.97))<1e-9);
  }
  assert.equal(compiled.quarters,16);
  assert.ok(Math.abs(compiled.duration-16*60/108)<1e-9);
  assert.equal(compiled.tempo[0].bpm,108);
  const midi=readMIDI(exportedMIDI);
  const midiChord=midi.tracks[0].notes.filter(note=>note.q===0);
  assert.deepEqual(midiChord.map(note=>note.pitch).sort((a,b)=>a-b),[62,66,69]);
  assert.ok(midiChord.every(note=>note.tick===0&&note.durationQuarter===1&&note.duration===midi.division));
  assert.ok(midi.tempos.some(tempo=>Math.abs(tempo.bpm-108)<.001));
  return {
    report:{passed:true,scope:'Only the smoke plan through its MIDI export; no full semantic suite, UI, native or DAW run',commands,selected:selection.selected,transposed:transposition.changed,
      performanceResultPath:'response.result',partIDPath:'response.result.parts[0].id',eventsPath:'response.result.events',
      chordFilter:{part:'parts[0].id',measure:1,pass:1,staff:1,voice:'1',startQuarter:0},
      firstChord:chord.map(({pitch,startQuarter,durationQuarter,start,duration})=>({pitch,startQuarter,durationQuarter,start,duration})),
      expectedPitches:[62,66,69],totalQuarters:compiled.quarters,totalSeconds:compiled.duration,bpm:compiled.tempo[0].bpm,
      midi:{bytes:exportedMIDI.length,division:midi.division,pitches:midiChord.map(note=>note.pitch).sort((a,b)=>a-b),startTick:0,durationTicks:midi.division}},
    midi:exportedMIDI
  };
}
