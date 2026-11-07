# FloeMusicNative

Native audio services for the independent [Floe music predevelopment](../README.md). Swift 6, iOS 26 / macOS 15. Uses AVFoundation plus pinned AudioKit, AudioKitEX and SoundpipeAudioKit; LAME is the real MP3 encoder. See [NOTICE.md](NOTICE.md).

| API | Actual behavior |
| --- | --- |
| `MusicAudioPreparation.inspect/prepare` | Hash and inspect a host-resolved file; stream to project-rate stereo Float32 work copies without changing source bytes |
| `MusicOfflineRenderer.render` | Offline AVAudioEngine graph with streamed clips, sample-boundary MIDI events, real synth/EQ/send reverb, channel faders, gain automation and staged WAV commit |
| `MusicMP3Exporter.encode` | Stream PCM through libmp3lame, flush and write encoder delay/padding metadata, then commit a real MP3 |
| `MusicMIDINoteImport.read` | Import SMF notes and tempo with AudioKit's AppleSequencer; retain original SMF as an immutable asset |
| `MusicRecordingService` | Bounded off-realtime PCM chunks, WAV completion, controlled cancellation recovery and old-handle rejection; no microphone acquisition |
| `MusicDJBounce.render` | Actual offline dual-deck source reading, crossfader, beat loop and rate/reverse/jog gesture sequence using bounded page caches |
| `MusicLiveInstrument` | Host-authorized live generated synth with 8 voices and 41 stable presets, note lifecycle, pedal, bend and modulation; no session-category writes |
| `MusicRenderLease` | Snapshot lifecycle fence and synchronous staged-output commit; host must invalidate it after edits/navigation/cancellation |

All destinations must be new local files. Services never resolve a model-authored file locator, replace original media, or use a host command-line encoder. Decoder/encoder work is service-owned and checks cancellation. No Swift timers drive musical time and no module-owned realtime callback performs file I/O or waits on a lock.

The offline renderer supports the subset in [CORE_CONTRACT.md](../CORE_CONTRACT.md). Only the built-in synth, one parametric EQ and medium-room reverb are currently executable. Unsupported active plugin/state/preset, automation or pre-fader routing throws; stored opaque state remains intact. WAV export uses floating-point PCM and does not apply a hidden loudness target/limiter.

DSP reuse is concrete: Soundpipe DynamicOscillator, FMOscillator, WhiteNoise and AmplitudeEnvelope for voices, AudioKitEX Fader for actual left/right gain, and Apple's EQ/Reverb units. Additive and pulse wavetables are normalized before DSP; generator amplitude is set to 0.12 per voice before envelopes, filters and preset gain. Optional per-voice low/high-pass filters shape bass, strings and percussion. `MusicAudioNodeReference` bridges nodes in the existing AVAudioEngine; it does not create a second AudioKit engine or modify global audio settings.

## Qualification

The [separate host](../../../Qualification/Music/README.md) mixes actual MP3/WAV and SMF-derived synth notes, writes an injected recording, saves/reopens the relocated project, applies EQ/automation, renders WAV and actual MP3, tests pan endpoints and dual-deck output, and rejects stale render/encode/recording results. Its exported executable runs after build-cache removal. Independent FFmpeg decoding verifies 20 PCM properties, including an exact five-second/240000-frame MP3 result, expected pitches and note-release silence.

Native source and its dependencies pass arm64 iOS 26 object compilation. The combined keyboard/native Simulator App links. No full-App, physical iPad, microphone, hardware cue, realtime multitrack, professional scratch/keylock, AUv3 or AI-service claim follows from these checks.

The MIDI importer is explicitly `notes-and-tempo`. No sampled piano or licensed soundbank is bundled. The synth's modulation maps tonal oscillators to 0...3 Hz detuning and bend maps to ±2 semitones. Host-specific playback/interruption quality still needs device acceptance.

## Built-in preset contract

`FloeMusicCore.MusicPresetCatalog.all` exposes 41 stable, bilingual generated patches across keys, bass, strings, pads, leads, plucks, bells, percussion and organ. `MusicInstrumentPreset.index` (also its `id`) persists in `MusicPluginState.presetIndex`; defaults live in `parameters`. Empty saved parameters select the defaults, and explicit values override them. Indices 0 and 1 retain the original sine/saw waveform, 8 ms attack, 80 ms decay/release, 0.75 sustain and unity gain. Unknown indices or parameter keys and invalid ranges fail explicitly, preserving stored opaque state.

Live performance and `MusicOfflineRenderer` both instantiate the same `MusicSynthBank` and patch resolver. The new presets use different ADSR envelopes, oscillator shapes, normalized additive spectra, FM ratios/indices or filtered noise. Their names describe synthesis styles rather than sampled acoustic instruments. No external soundbank download or new library/license is required.

Preset 40 is an electronic drum kit: GM 35/36 select kick, 37–40 snare, 42/44 closed hat, 46 open hat and common cymbal pitches select the hat family; remaining pitches use a pitched tom. It reserves two voices per family, eight total, and a closed hat releases ringing hats. The other percussion presets are individual generated hits. Zero-sustain percussion follows its own bounded decay after key release; Stop/all-notes-off still stops every voice. For the kit, decay/release scale each family's own envelope. Sustain above zero restores ordinary note-off behavior.

The shared editable envelope parameters are `attack`, `decay`, `release` (0…99 seconds), `sustain` (0…1), and `gain` (0…1 linear). Additional tonal parameters are `waveform` (integer 0…8: sine, saw, triangle, square, pulse, additive, FM, noise, kit), `pulseWidth` (0.05…0.95), `harmonic2`…`harmonic8` (0…1), `fmRatio` (0.1…16), `fmIndex` (0…12), `transpose` (−48…48 semitones), `fixedNote` (integer −1 for keyboard pitch or 0…127), `detune` (−50…50 cents), `highpass` (0…20000 Hz; 0 bypasses) and `lowpass` (20…20000 Hz; 20000 bypasses). The kit accepts only the shared envelope/gain controls and its waveform code. Filters are clamped below the actual graph's Nyquist frequency.

`MusicPresetAudioTests` renders every catalog entry to finite audible PCM, checks actual PCM differences, verifies GM kick/snare/hat spectra, exercises pedal/polyphony/release/all-off through the live message path, compares live resolution to saved offline state, and invalidates a render during execution to verify cleanup. These are component audio checks, not full-App UI or physical listening acceptance.
