# PPT selected-object first save — admission-race hardening

Date: 2026-10-09 · Branch: `codex/content-upgrade-20261009` · No release performed.

## Observed symptom (previous qualification, historical)

Editing a PPTX in the native Office host, the FIRST save intermittently
failed while an object/shape was selected; deselecting allowed the save to
succeed. Save/reopen of the actual PPTX bytes is the only accepted
verification — no screenshot or PDF substitution.

**Attribution status:** the historical logs do not identify the failure
code, and the failure was not reproduced locally (see below). What is
verified from the pinned sources is a *mechanism class* — not proof that it
caused the observed failure.

## Known source mechanism (verified against pinned sources)

The pinned engine admits one save at a time. `DocumentBroker::manualSave`
(source-pinned, `wsd/DocumentBroker.cpp`) refuses an explicit save while a
save activity is in flight, and the embedding overlay
(`ThirdParty/Collabora/patches/ios-embedding-boundaries.patch`) converts that
refusal into `floeSaveRequestRejected` → `saveReceipts reject:` → completion
`NO` → native **error 8** "Office could not complete this save."
(`FloeOfficeNative.mm` ~2014-2045). Error 8 is **generic** — it also covers
kit sequence-save failures and JS dispatch rejection — and native **error 9**
is the distinct "a save is already in progress" pre-dispatch signal. The
historical cause (admission race vs sequence-save failure vs JS rejection)
stays **unproven** until a failing run records the `save.failed` domain/code.

## Change (app side, existing channels only)

- `OfficeSaveAdmissionRetry` (`FloeApp/Workspace/OfficeSaveAdmissionRetry.swift`):
  retries a save **exactly once**, only for the proven pre-dispatch busy
  signal (native code 9). The settle delay throws, so cancellation prevents
  the second attempt. Generic failures (code 8, conflicts, timeouts) propagate
  unchanged — a real first-save defect still surfaces as `save.failed` with
  its code, and the busy-retry stage evidence (`save.busyRetry` /
  `save.busyRetry.ok`) records which path ran.
- `OfficeDocumentEditorView.save(returnToPreview:)` runs the working-copy
  flush through that policy.
- This is hardening of the observed *contract* (retry-after-settle succeeds),
  not a claim that the historical selected-object failure is repaired.

## Local verification (2026-10-09, measured outcome — corrected)

A dedicated app-hosted qualification test exists:
`Tests/FloeAppTests/OfficeSelectedObjectSaveTests.swift`. It mounts the **real
production `OfficeDocumentSurface`** in a visible foreground `UIWindow`, drives
the production preview → edit session against the pinned synthetic
`floe-sim-qual.pptx`, waits for the host's genuine painted-surface signal
(editable `ViewLayoutImpress`, `editSurfacePainted=1`), inserts an image
attachment (the engine leaves the inserted object selected — the reported
precondition), saves in place, byte-verifies the embedded `ppt/media/` part and
a changed hash, and reopens to a rendered preview. The session itself refuses
to flush any unrendered document (`renderGate.permitsSave`), so a green run
proves a visible edit → selected object → save → reopen; it never passes on the
engine-unavailable branch or a relaxed gate.

**The earlier "engine aborts during `prepare` with native error 4 and an empty
profile" diagnosis was inaccurate and is superseded.** On this checkout the
pinned simulator kit (`overlaySHA256 4ac3cc3b…` matching `engine.lock.json`)
**starts locally**: the stage trace reaches `engine.runtime.ready` (fonts
resolved=23/staged=23) and mounts editable controllers that really paint. The
native error 4 seen previously came from the *headless* test host: the old
test only called `OfficeFileSession.open` without presenting a window, so the
presentation `visibleRenderRequired` gate never observed a tile and the open
ended at the 30 s `open.watchdog`; the (then) unavailable branch was wrongly
reported as a pass. Mounting the production surface visibly (as the cloud
runner and the real App do) removes that false failure — no render-gate
relaxation was needed.

Measured local results, Xcode 27 / iPad Air 13-inch (M4) iOS 27 simulator
`37D8E931`, pinned kit `simulator-36792170654-kit`:

- `FloeApp.OfficeSelectedObjectSave.selectedObjectFirstSaveAndReopen`
  (real visible editor): **passes** — editable generation paints
  (`permission=edit`, `ViewLayoutImpress`, new tile decodes), selected-image
  insert, `save.ok`, one `ppt/media/` part, post-save hash differs, reopen
  renders. Log marker `FLOE_OFFICE_SELECTED_SAVE_OK`.
- Genuine full-app scenario `OfficeRealEngineUITests` (import → preview →
  edit → insert slide → real slideshow of all 3 pages → idle 120 s → save →
  remembered reopen ×2 → persist): **22/22 phases pass locally** (≈190 s). On
  a freshly reinstalled container the cloud gate
  `verify_real_engine_trace.py` reports `tracePassed=true` (155 events, no
  failures), and the committed Notes resources independently unzip to 2
  (fixture) → 3 → 4 slides. Evidence under
  `Local/Private/evidence/content-upgrade-20261009/office-realengine-local/`.

Distinct, non-blocking observation (preserved, not conflated with save): when
the old **headless** host exited, the pinned process-lifetime Office server is
destroyed by a static destructor (`__cxa_finalize` → `COOLWSDServer::stop()`)
while a `SocketPoll` worker thread is still live, and a `std::mutex::lock`
throws `system_error: mutex lock failed: Invalid argument` → `SIGABRT`
(`ggml_uncaught_exception` frames are llama.cpp's generic backtrace handler,
not a model failure). It is a unit-host process-teardown race only; the
process-lifetime server is deliberately never restarted inside one app
(`FloeOfficeNative.mm` keeps upstream shutdown destructors out of the in-app
restart path), and neither the real App lifecycle nor the visible XCUITest
scenario hits it. Raw excerpt retained as
`office-realengine-local/unit-host-exit-mutex-exception.txt`.

The cloud workflow (`.github/workflows/office-floe-simulator.yml`) remains the
canonical qualified runner; run 36843561563 (`office-floe-simulator-host`,
both jobs `success`) is the byte-identical overlay pin. Its newer framework
binary was downloaded for diagnosis but is **not** embedded: its receipt omits
the `engineRepair` provenance block this checkout's
`bootstrap_office_host.verify_simulator_host` gate requires, so swapping it in
would violate the tracked pin. The already-pinned committed kit is what
actually started and passed locally.

## Fixture for the native verification step (primary / cloud runner)

1. Run `FloeAppTests` → `FloeApp.OfficeSelectedObjectSave` /
   `selectedObjectFirstSaveAndReopen` (now a real visible-editor host). Accept:
   test passes with `engine.visibleRender` (editable), `save.ok`/`save.busyRetry.ok`,
   a `ppt/media/` part and differing post-save bytes. It now passes locally.
2. If `saveInPlace()` returns false, the issue carries `session.error` and
   the durable stage trace records the `save.failed` domain/code — code 9
   (busy, retried-and-failed) or code 8 (generic: admission vs
   sequence-save vs JS rejection) decides the follow-up. A code-8 admission
   refusal reproduced here would justify the reason-preserving receipt
   bridge (requires rebuilding the pinned native host; deferred, not waived).
3. Manual UI equivalent: Notes → import `floe-sim-qual.pptx` → Edit → insert
   an image (stays selected) → Save → expect success without deselecting →
   force-quit and reopen → image persists.

## Related

- Approval-stall evidence (same handoff era): see
  `Local/Private/evidence/content-upgrade-20261009/approval-stall-evidence.md`.
