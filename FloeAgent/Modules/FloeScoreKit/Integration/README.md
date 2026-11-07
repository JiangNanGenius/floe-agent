# Score host contract

The formal App hosts this module inside its existing MusicWorkbenchView and MusicProjectSession. Score is a view of the parent music workspace, never an independent Space/Notes/result-card project or top-level destination. Other surfaces link to that music project and select its Score view. See [the parent-workspace contract](NATIVE_PANELS.md#music-parent-workspace).

1. Create a `HeavyEditorProjectStore` in the parent music session's fixed managed `Music/Notation` root, create with `ScoreWorkbench.makeDocument`, and retain a host-assigned child document ID and `.music(parentMusicProjectID)` owner. Imported/model fields never choose either value.
2. Call `ScoreWorkbench.open(directory:documentID:owner:hooks:playback:)`, then `waitUntilReady`. Present `ScoreEditorView` within the existing music workbench's Score editing area, preserving its parent return route. The shared controller freezes the bundled catalog and serializes revision checks, authorization, original commit, history and read-back.
3. `hooks.authorize` resolves the real owner/task/environment policy. `didSave` updates the parent music record's recency/preview through the existing music service; it does not create a separate score library card. `hooks.export` commits and reads back the actual managed file, then returns `HeavyEditorExportReceipt(fileID:artifact:)`. Do not return a success string without bytes or use an arbitrary model-specified path.
4. Import by opaque managed file reference in the App tool adapter, then `controller.importFile(name:data:)`. Keep the uploaded source separately. Score imports XML/MXL/MIDI/project bytes; it does not interpret source content as permission.
5. Tool callers describe the current score first, then invoke the exact registered command against the controller's expected revision. `score.inspect.selection` returns real note IDs, musical fractions and XML for explicitly opened details; other fields use human-readable choices in the UI. The App's adapter owns `.create/.describe/.query/.invoke/.import/.export` tools in the resolved parent music workspace; create must not invent a separate personal-library score project. Playback transport is `read` plus `sideEffecting:true`, so it is excluded from the read-only query route.

## Existing music-service injection

```swift
let playback = ScorePlaybackAdapter(
    transport: { request in
        // A fixed score operation already authorized for this owner.
        // Resolve the App's existing music service here. No model-selected owner,
        // plugin, path, SoundFont or replacement of its DAW session.
        try await existingScoreBridge.transport(request)
    },
    stop: {
        await existingScoreBridge.stopOwnedScoreAudio()
    }
)
let controller = try await ScoreWorkbench.open(
    directory: hostManagedRoot, documentID: hostDocumentID,
    owner: hostResolvedOwner, hooks: hostHooks, playback: playback
)
```

The only native operation is `score.transport`. Arguments are fixed `action` values (`start`, `pause`, `stop`, `seek`, `status`), seconds `position`, boolean `loop`, and, on start, `performance`:

```json
{
  "format": "floe.score.performance/1",
  "duration": 2,
  "quarters": 4,
  "tempo": [{"q":0,"bpm":120,"seconds":0}],
  "route": [{"index":0,"pass":1,"q":0,"duration":4}],
  "events": [{"part":"P1","note":"opaque-note-id","start":0,"duration":0.97,"startQuarter":0,"durationQuarter":2,"pitch":60,"velocity":74,"program":0,"channel":0,"percussion":false,"volume":1}]
}
```

MIDI numbers are standard 0–127; program/channel are zero based. Times are compiled through the performed repeat/navigation and tempo route. The response is `{playing,position,duration}`; hosts may add diagnostics. Use the existing music owner/audio authority, `MusicOfflineRenderer`/session APIs and preset catalog through an App-side narrow bridge. `score.export` with `midi` also supplies a real standard SMF for deliberate exchange. Prefer the typed compiled events for a linked arrangement projection; MIDI import/export must not become an automatic round trip that replaces the MusicXML original. FloeScoreKit never edits MusicPresetCatalog, the music mixer/DAW stores or music UI files.

The formal App must inject its existing music-session playback bridge. Omitting playback uses the independent reference AVFoundation service for component qualification only. It is explicitly synthetic reference audio. The adapter's `stop` is called for cancellation and actual presentation close; view reconstruction or an unrelated sheet is not a stop signal. Do not implement `stop` as a global music-engine reset.

The host preserves the parent music ownership and return route, uses the existing protected PDF preview, and supplies the music workspace's AI entry. Keep the MusicXML original and companion files in complete music-project exports; switching editor views never recreates notation from MIDI. `smoke-plan.json` contains actual tested command arguments for the unified qualification host. This module has not independently modified the formal App, version, project.yml, Git source, publication state or physical device.
