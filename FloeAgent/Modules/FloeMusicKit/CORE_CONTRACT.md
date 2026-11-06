# Music core host contract

This package is an isolated predevelopment module. Mainline intake must reuse Floe's existing document, asset, job, undo, provider and permission services. The qualification file repository is a test host, not a replacement production store.

## Documents and edits

`MusicDocument` schema 1 owns tracks, clips, immutable source identities, tempo, buses, strips, effect/instrument state and automation. Audio positions/trim/fades use project sample frames. MIDI clip-relative ticks are converted at the clip's actual tempo-map position. The mainline native document/archive design and migration policy are not frozen by this prototype.

Constructors, decoding and `MusicProjectStore` revalidate mutable data. Unknown schema versions reject explicitly. Opaque plugin state remains encoded; a renderer must reject unsupported active state rather than silently discard it. Overlapping clips are valid.

Use `MusicEditBatch` through the store, not direct draft mutation. A whole batch is validated and committed once; an operation can reference a bus created later in the same batch. Sample/tick arithmetic and revision advancement reject overflow. `master` is a reserved virtual bus represented by `masterStrip`.

Store initialization is create-only. `MusicProjectStore.open` loads an existing document without overwriting it. A session carries its owner and observed base revision. A fresh batch number cannot refresh a stale handle; obtain a new session after reconciliation. Closed sessions are terminal. Undo/redo advances revisions and currently uses bounded RAM history only; durable undo/crash journaling is still an integration requirement.

## Repository requirements

Implement the following async methods:

```swift
stageAsset(_ payload: MusicAssetPayload)
save(document: MusicDocument, expectedRevision: Int64?, fence: MusicCommitFence?) -> MusicRevisionToken
load(projectID: MusicProjectID) -> MusicDocument
assetPayload(assetID: MusicAssetID) -> MusicAssetPayload?
```

`stageAsset` verifies the actual SHA-256 and preserves immutable asset ID/content/source-revision binding. Save verifies referenced staged versions and uses one atomic transaction. A nil expected revision creates only; otherwise the stored revision must equal the expected one and the incoming revision must advance exactly once. Encode/hash the exact stored bytes before swapping state. A crash must not expose a half-written document or a reference to an incomplete asset.

When a fence is supplied, perform the final synchronous state swap/rename inside:

```swift
try fence.withValidCommit(document: document) {
    // Existing atomic transaction's commit point; no await here.
}
```

Do not check the fence only before an asynchronous save, and do not provide a default implementation that ignores it. Closing or inactivating a session invalidates its pending fence. Reactivating permits new work but does not revive an old pending save. Commit and invalidation are ordered by the short fence lock: if the atomic commit already won, the saved state remains authoritative. The store serializes mutations across repository awaits and swaps its snapshot/history only after a successful repository commit.

The in-memory adapter verifies this behavior. The macOS qualification adapter adds per-project file locks, content-addressed blobs, synchronized staging and atomic rename, and demonstrates save/reopen after directory relocation. Power-loss durability, disk exhaustion, process-kill recovery, migration and the existing Floe durable journal remain separate production checks. Never garbage-collect a blob still referenced by a retained revision.

## Runtime ownership

The host supplies local file access and resolves assets. `sourceLocator` is data, never authority to open arbitrary paths. `MusicRenderLease` binds a snapshot to project/revision/owner; the host invalidates it on cancellation, navigation or intervening edits. Native render/encode checks it throughout processing and at atomic output commit. Destinations are new files; originals remain immutable.

The host owns microphone permissions, AVAudioSession category/route, live input adaptation and interruption handling. Pass `MusicAudioAuthority` to the live synth and call `stop()` when its owning service closes. Keyboard events are tagged with the original owner; route them only to a matching instrument. Audio I/O, conversion, file writes and locks stay outside realtime callbacks. Recording input is copied into bounded chunks on a service executor, not written synchronously from an input tap.

DJ state is separate from arrangement clips and references the same versioned assets. Persisted decks restore stopped. `channelGains().deckAMaster/deckBMaster` already include master gain; do not multiply them by `masterBusGain` again. Cue gains describe a logical cue bus and do not establish hardware output capability.

## Current executable subset

The offline engine handles audio clips, generated MIDI notes, track/bus/master gain and stereo pan, mute/track solo, supported EQ/reverb, post-fader sends and audio-track gain automation. Active unknown plugins, opaque effects, non-default effect presets, unsupported automation, pre-fader sends and bus solo reject explicitly. Stereo pan uses AudioKitEX's actual channel faders, verified by hard-left/right PCM output, rather than relying on an ineffective pre-connection mixer-pan property.

The DJ bounce uses bounded page caches and linear interpolation; it is an audio qualification foothold, not qualified low-latency scratch/keylock. SMF import currently means notes and tempo; controller/meter/meta fidelity and MIDI export are not qualified. The entire main-App, external-device and AI integration stage remains open.
