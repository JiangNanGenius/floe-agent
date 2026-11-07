# Floe Music modules

Music document, editing, keyboard and audio services used by the native Floe workbench. See the historical [predevelopment handoff](../../../docs/FLOE_MUSIC_WORKBENCH_PREDEVELOPMENT_HANDOFF.zh-CN.md) and [Chinese module guide](README.zh-CN.md).

## Current integration checkpoint — 2026-11-08

The main App uses its existing Space editor, personal original repository and
task-authorized `studio` tools. The workbench keeps one top assistant entry.
The same native live/offline bank supplies 41 synthesized presets in nine
categories, including a GM electronic drum kit; these are not acoustic samples.
The preset browser supports category/search, audition, saved application and
undo. Quantize, transpose, velocity edits and four additive clip templates use
the same validated edit batches.

`MusicEditJSONCodec` accepts documented plain MIDI clip/pattern commands or the
complete legacy native operation array, without mixing formats. `studio.read`
provides actual IDs, capabilities and complete update/insert examples. Note
updates explicitly choose append or replace; errors identify the field path.
No-op transforms retain the revision. Mix, monitoring and recording state are
preserved. Master strip edits are separate from auxiliary bus edits.

Xcode 27.2 (27B52) compiled and linked the actual arm64 Simulator App. Four
music App contracts cover legacy operations, 30-second append and insert,
save/reopen, precise validation and unchanged no-ops. At 100 BPM/960 PPQ,
48,000 ticks rendered to 1,440,000 frames at 48 kHz: the muted mix measured zero
peak and the audible fixture measured 0.24577063. Rendering can explicitly use
`tailFrames: 0`; omission preserves the existing 48,000-frame effect tail.
Fifteen codec, thirteen pattern and ten preset/audio component checks also
passed. Actual reused-iPad UI checks exercised preset application/undo and
template insertion/undo without replacing the existing phrase.

These are local candidate results, not physical-device, provider or release
acceptance. The already-published historical build 325 does not contain this
increment. The following predevelopment evidence remains a dated baseline.

| Package / product | Responsibility |
| --- | --- |
| This package / `FloeMusicCore` | Validated audio/MIDI project, tempo map, routing, atomic edit batches, revision/session fences, bounded in-memory undo/redo, repository seam and DJ state/math |
| [KeyboardUI](KeyboardUI/README.md) / `FloeMusicKeyboard` | SwiftUI multitouch keyboard using pinned AudioKit/Keyboard; owner-tagged note, pedal and wheel events; host-injected presets and controls |
| [Native](Native/README.md) / `FloeMusicNative` | Actual AVAudioEngine offline mixing, AudioKitEX faders, EQ/send reverb, Soundpipe synth, note/tempo SMF import, injected-PCM recording, LAME MP3 export and offline dual-deck audio |
| [Qualification host](../../Qualification/Music/README.md) | Separate macOS audio scenario and iOS component App; no main-App entry point |

Requires Swift 6.2+, iOS 26 or macOS 15. The original predevelopment qualification used Xcode 27.1 / Swift 6.4 on arm64 macOS and arm64 iOS object compilation. That isolated iOS Simulator App and its UI tests compiled, while its UI run was prevented by the occupied canonical Simulator lock. Those historical component results are separate from the newer App checks above.

## Historical predevelopment results

The frozen source passed 56 core tests, 26 keyboard-controller tests and 2 native lease tests. The exported macOS executable also passed a real-file scenario and 20 independent FFmpeg PCM checks: save/reopen after directory relocation, audio trimming/fades, MIDI synth notes/release, EQ, gain automation, channel pan, dual-deck fader/loop/rate/reverse and actual five-second MP3 output. Interrupted render/encode cannot commit stale output. Original synthetic inputs remain unchanged.

Commands, exact source digests and public-safe results: [evidence](../../../docs/evidence/music-predev-20261103/qualification.json). Original failure logs and executable/App/audio artifacts remain in the repository's ignored `Local` directories, as listed in the handoff.

## Integration contract

Use [CORE_CONTRACT.md](CORE_CONTRACT.md). Implement `MusicRepository` through the existing Floe transaction/asset services; pass its `MusicCommitFence` into the atomic commit boundary. Inject host-resolved file URLs and a `MusicAudioAuthority` adapter. The package never opens model-authored source locators, changes AVAudioSession categories, creates a provider/permission flow, or writes into the main App's storage.

Reopening uses `MusicProjectStore.open`; its initializer creates a new project only. Sessions are revision-bound. Manual and future AI edits use the same `MusicEditBatch` path. Undo/redo is currently RAM-only and must be connected to the existing durable journal at mainline intake.

The native renderer supports a declared subset and throws for unsupported active plugin/state/automation routes. Opaque plugin state remains preserved in the document. The original two generated presets remain compatible within the expanded bank. Recording qualification injects PCM; microphone acquisition, hardware monitoring and process-death recovery remain separate host/device checks.

Realtime multitrack transport, professional scratch/keylock, hardware cue, full MIDI interchange, AUv3 and advanced provider workflows remain separate stages in the accepted plan. The App already has native piano-roll/drum controls and registered editing/render tools; this does not imply those advanced stages are complete. No new distribution is part of this checkpoint.
