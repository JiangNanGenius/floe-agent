# Floe Music modules

Independent predevelopment for the approved music workbench. The main Floe App has not been modified or integrated. See [Chinese handoff](../../../docs/FLOE_MUSIC_WORKBENCH_PREDEVELOPMENT_HANDOFF.zh-CN.md) and [Chinese module guide](README.zh-CN.md).

| Package / product | Responsibility |
| --- | --- |
| This package / `FloeMusicCore` | Validated audio/MIDI project, tempo map, routing, atomic edit batches, revision/session fences, bounded in-memory undo/redo, repository seam and DJ state/math |
| [KeyboardUI](KeyboardUI/README.md) / `FloeMusicKeyboard` | SwiftUI multitouch keyboard using pinned AudioKit/Keyboard; owner-tagged note, pedal and wheel events; host-injected presets and controls |
| [Native](Native/README.md) / `FloeMusicNative` | Actual AVAudioEngine offline mixing, AudioKitEX faders, EQ/send reverb, Soundpipe synth, note/tempo SMF import, injected-PCM recording, LAME MP3 export and offline dual-deck audio |
| [Qualification host](../../Qualification/Music/README.md) | Separate macOS audio scenario and iOS component App; no main-App entry point |

Requires Swift 6.2+, iOS 26 or macOS 15. Current qualification used Xcode 27.1 / Swift 6.4 on arm64 macOS and arm64 iOS object compilation. The isolated iOS Simulator App and its UI tests compile; the UI run was prevented by the occupied canonical Simulator lock. This is not physical-device or full-App acceptance.

## Results

The frozen source passed 56 core tests, 26 keyboard-controller tests and 2 native lease tests. The exported macOS executable also passed a real-file scenario and 20 independent FFmpeg PCM checks: save/reopen after directory relocation, audio trimming/fades, MIDI synth notes/release, EQ, gain automation, channel pan, dual-deck fader/loop/rate/reverse and actual five-second MP3 output. Interrupted render/encode cannot commit stale output. Original synthetic inputs remain unchanged.

Commands, exact source digests and public-safe results: [evidence](../../../docs/evidence/music-predev-20261103/qualification.json). Original failure logs and executable/App/audio artifacts remain in the repository's ignored `Local` directories, as listed in the handoff.

## Integration contract

Use [CORE_CONTRACT.md](CORE_CONTRACT.md). Implement `MusicRepository` through the existing Floe transaction/asset services; pass its `MusicCommitFence` into the atomic commit boundary. Inject host-resolved file URLs and a `MusicAudioAuthority` adapter. The package never opens model-authored source locators, changes AVAudioSession categories, creates a provider/permission flow, or writes into the main App's storage.

Reopening uses `MusicProjectStore.open`; its initializer creates a new project only. Sessions are revision-bound. Manual and future AI edits use the same `MusicEditBatch` path. Undo/redo is currently RAM-only and must be connected to the existing durable journal at mainline intake.

The native renderer supports a declared subset and throws for unsupported active plugin/state/automation routes. Opaque plugin state remains preserved in the document. The current synth has two generated waveforms, not a sampled piano library. Recording qualification injects PCM; microphone acquisition, hardware monitoring and process-death recovery remain host/device work.

Realtime multitrack transport, professional scratch/keylock, hardware cue, full MIDI interchange, drum/piano-roll editing, AUv3 and AI/provider integration remain later stages in the accepted plan. No version, merge, distribution or publication is part of this predevelopment handoff.
