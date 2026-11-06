# FloeMeetings

Independent meeting core for the Floe notes-embedded meetings workspace (预研组件, not wired into the main app).

## Scope

- Stable identities (`MeetingID`, `CaptureSessionID`, segment/speaker/note/marker/todo/decision ids).
- `SourceReference` anchors notes, markers, todos, decisions and corrections back to recording time ranges or transcript segments.
- Typed `MeetingProcessingCapabilities` — every engine capability is explicitly `available` / `degraded` / `unavailable`; nothing is fabricated.
- `MeetingCaptureController` recording lifecycle: idempotent stop/cancel, generation-fenced late callbacks, bounded stop wait, partial data kept on timeout.
- Ordered partial/final transcript with stable IDs across partial commit, session ownership checks, durable insertion ordinals, speaker rename/merge that keeps segment sources, and corrections that keep original text.
- Manual notes with revision-guarded edits, time markers, durable decisions, deduplicated todos with user-modification protection.
- `SummaryInputBuilder`: rolling "last 5 minutes" window + cumulative decisions (no LLM inside this package).
- GRDB (exact 7.8.0, same pin as the main package) persistence with versioned migrations and per-meeting cascading tables; committed records survive normal reopening. Audio-file crash recovery remains a separate qualification item.
- Pure-data export: TXT / Markdown / SRT / VTT following the app's existing caption formatting rules.
- `FloeMeetingsAV`: AVAudioRecorder backend + AVFoundation file probe (no permission requests, no hardware use in tests).

## Non-goals (by design)

- No recognition, diarization, translation, summarization or DSP algorithms. Engines are injected by the host; absent engines stay `unavailable`.
- No background/audio-session claims. Background continuity is a system property recorded, never asserted.
- No screen capture implementation. `ScreenCaptureRoute` only distinguishes the iOS 27 ScreenCaptureKit path from the iOS 26 ReplayKit broadcast route.
- No docx/PDF export, no main-app integration.

## Layout

| Target | Contents |
| --- | --- |
| `FloeMeetings` | Core models, capture lifecycle, persistence (GRDB), service facade, export |
| `FloeMeetingsAV` | AVAudioRecorder backend, `AudioFileProbe` |
| `FloeMeetingsTests` | Behavior tests (lifecycle fences, persistence, protections, export, AV probe) |

## Host contracts

- Create capture sessions through `startCapture` or `importFile` before injecting recognizer results. Arbitrary session IDs and cross-meeting session/speaker ownership are rejected.
- A stop outcome is bounded even if the backend's stop call suspends. `activeSession` stays occupied and `isCleaningUp` stays true until begin, stop and cleanup calls have all completed. A timeout does not prove that hardware has stopped. Hosts must keep the stopping indicator until physical ownership is released.
- `cancelCapture` is `async throws`; persistence failures are propagated. Automatic terminal-event persistence failures are also exposed as `capturePersistenceFailure`, and an explicit stop retries the retained outcome. Do not report successful save while that error exists.
- Cancellation fences recognizer results before awaiting cleanup. Partials remain in memory until durable commit succeeds; commit preserves their segment ID. Imported file sessions can still be transcribed after reopening.
- `AVAudioRecorderCaptureBackend` is a single-file recorder foundation. Final spans are measured from actual media frames. It is not a shared live PCM source for simultaneous ASR/diarization; that integration must use one audio owner in the existing voice runtime.

Build/test with an exclusive scratch/cache directory, explicit `DEVELOPER_DIR`,
and six jobs, following the repository resource policy:

```sh
DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer xcrun swift test \
  --package-path FloeAgent/Modules/FloeMeetings \
  --scratch-path "$MEETING_SCRATCH" --cache-path "$MEETING_CACHE" --jobs 6
```

The independent [engine probe](../../Qualification/Meetings/EngineProbe) contains
the actual pinned diarization experiment. Its current model configuration is not
qualified as a product default; this core does not fabricate engine capabilities.

License: MPL-2.0 (matches the repository). Dependency: GRDB.swift 7.8.0 (MIT).
