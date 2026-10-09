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

## Local verification attempt (2026-10-09, measured outcome)

A dedicated app-hosted qualification test now exists:
`Tests/FloeAppTests/OfficeSelectedObjectSaveTests.swift` — opens the pinned
`synthetic floe-sim-qual.pptx` editable through the production
session/intent path, inserts an image attachment (the engine leaves the
inserted object selected — the reported precondition), saves in place,
reopens and byte-verifies persistence. When the engine runtime is available
it performs the full save/reopen check; when unavailable it skips with the
recorded reason (it never passes or fails for the wrong cause).

Local result in this checkout: the pinned simulator host **links** and its
resources embed (`cool.html`, `rc`, `fundamentalrc`, `program/`, `share/`,
`ICU.dat` verified in the built app), but the engine runtime aborts during
`prepare` with native error 4 and leaves an empty profile — the local
`simulator-36792170654-kit` predates the current overlay pin, and the kit
thread swallows the startup exception. The qualified real-engine runner is
the cloud workflow (`.github/workflows/office-floe-simulator.yml`), which
verifies/installs the pinned host before running. This boundary is recorded
honestly; the test is the exact fixture for the native step wherever the
qualified engine runs.

## Fixture for the native verification step (primary / cloud runner)

1. Run `FloeAppTests` → `FloeApp.OfficeSelectedObjectSave` /
   `selectedObjectFirstSaveAndReopen` on a build whose engine runtime starts
   (the cloud real-engine workflow's simulator). Accept: test passes with
   `save.ok` or `save.busyRetry.ok` stages and differing post-save bytes.
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
