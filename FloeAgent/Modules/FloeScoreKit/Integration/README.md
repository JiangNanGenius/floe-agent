# Score host contract

The formal App connects this module at its existing Space / Notes / result-card routes; this package does not create a top-level destination, DAW session or alternate permission service.

1. Create a `HeavyEditorProjectStore` in an App-managed document root chosen by the host, create with `ScoreWorkbench.makeDocument`, and retain the host's stable document ID and `.space`, `.note` or `.task` owner. Imported/model fields never choose either value.
2. Call `ScoreWorkbench.open(directory:documentID:owner:hooks:playback:)`, then `waitUntilReady`. Present `ScoreEditorView`. The shared controller freezes the bundled catalog and serializes revision checks, authorization, original commit, history and read-back.
3. `hooks.authorize` resolves the real owner/task/environment policy. `didSave` updates the corresponding card/title/thumbnail through the existing service. `hooks.export` commits and reads back the actual managed file, then returns `HeavyEditorExportReceipt(fileID:artifact:)`. Do not return a success string without bytes or use an arbitrary model-specified path.
4. Import by opaque managed file reference in the App tool adapter, then `controller.importFile(name:data:)`. Keep the uploaded source separately. Score imports XML/MXL/MIDI/project bytes; it does not interpret source content as permission.
5. Tool callers describe the current score first, then invoke the exact registered command against the controller's expected revision. `score.inspect.selection` returns real note IDs, musical fractions and XML for explicitly opened details; other fields use human-readable choices in the UI. The App's shared adapter owns `.create/.describe/.query/.invoke/.import/.export` tools. Playback transport is `read` plus `sideEffecting:true`, so it is excluded from the read-only query route.

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

MIDI numbers are standard 0–127; program/channel are zero based. Times are compiled through the performed repeat/navigation and tempo route. The response is `{playing,position,duration}`; hosts may add diagnostics. Use the existing music owner/audio authority, `MusicOfflineRenderer`/session APIs and preset catalog through an App-side narrow bridge. `score.export` with `midi` also supplies a real standard SMF, for import into the existing music document path. FloeScoreKit never edits MusicPresetCatalog, the music mixer/DAW stores or music UI files.

If playback is omitted, the independent reference AVFoundation service is used. It is explicitly synthetic reference audio. The adapter's `stop` is called for cancellation and actual presentation close; view reconstruction or an unrelated sheet is not a stop signal. Do not implement `stop` as a global music-engine reset.

The host must preserve existing Notes/Space ownership and return routes, use the existing protected PDF preview, and supply its existing AI entry. `smoke-plan.json` contains actual tested command arguments for the unified qualification host. This module has not independently modified the formal App, version, project.yml, Git source, publication state or physical device.
