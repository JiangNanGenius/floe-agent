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
| `MusicLiveInstrument` | Host-authorized live generated synth with 8 voices, sine/saw presets, note lifecycle, pedal, bend and modulation; no session-category writes |
| `MusicRenderLease` | Snapshot lifecycle fence and synchronous staged-output commit; host must invalidate it after edits/navigation/cancellation |

All destinations must be new local files. Services never resolve a model-authored file locator, replace original media, or use a host command-line encoder. Decoder/encoder work is service-owned and checks cancellation. No Swift timers drive musical time and no module-owned realtime callback performs file I/O or waits on a lock.

The offline renderer supports the subset in [CORE_CONTRACT.md](../CORE_CONTRACT.md). Only the built-in synth, one parametric EQ and medium-room reverb are currently executable. Unsupported active plugin/state/preset, automation or pre-fader routing throws; stored opaque state remains intact. WAV export uses floating-point PCM and does not apply a hidden loudness target/limiter.

DSP reuse is concrete: Soundpipe DynamicOscillator/AmplitudeEnvelope for voices, AudioKitEX Fader for actual left/right gain, and Apple's EQ/Reverb units. `MusicAudioNodeReference` bridges nodes in the existing AVAudioEngine; it does not create a second AudioKit engine or modify global audio settings.

## Qualification

The [separate host](../../../Qualification/Music/README.md) mixes actual MP3/WAV and SMF-derived synth notes, writes an injected recording, saves/reopens the relocated project, applies EQ/automation, renders WAV and actual MP3, tests pan endpoints and dual-deck output, and rejects stale render/encode/recording results. Its exported executable runs after build-cache removal. Independent FFmpeg decoding verifies 20 PCM properties, including an exact five-second/240000-frame MP3 result, expected pitches and note-release silence.

Native source and its dependencies pass arm64 iOS 26 object compilation. The combined keyboard/native Simulator App links. No full-App, physical iPad, microphone, hardware cue, realtime multitrack, professional scratch/keylock, AUv3 or AI-service claim follows from these checks.

The MIDI importer is explicitly `notes-and-tempo`. No sampled piano or licensed soundbank is bundled. The live synth's modulation maps to 0...3 Hz detuning and bend maps to ±2 semitones; these are basic patch semantics, not a full synthesizer editor. Host-specific playback/interruption quality still needs device acceptance.
