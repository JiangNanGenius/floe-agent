# PPT selected-object first save — admission-race hardening

Date: 2026-10-09 · Branch: `codex/content-upgrade-20261009` · No device claim: local
evidence is state/JS-level; the real-engine save/reopen verification belongs to
the cloud real-engine qualification (fixture and exact steps below).

## Observed symptom (previous qualification)

Editing a PPTX in the native Office host (Impress via the pinned Collabora
engine), the FIRST save intermittently failed while an object/shape was
selected; deselecting allowed the save to succeed. Save/reopen of the actual
PPTX bytes is the only accepted verification — no screenshot or PDF
substitution.

## Mechanism (verified against the pinned sources)

The engine admits one save at a time. `DocumentBroker::manualSave` refuses an
explicit save while a save activity (the autosave that follows an edit, e.g.
inserting/selecting a shape) is in flight, and the embedding overlay
(`FloeAgent/ThirdParty/Collabora/patches/ios-embedding-boundaries.patch`)
converts that refusal into `floeSaveRequestRejected` →
`saveReceipts reject:` → completion `NO` → native error
**8** "Office could not complete this save." (`FloeOfficeNative.mm` ~2014-2045).
A retry after the activity settles — exactly what deselect-then-save does —
succeeds.

Error 8 is **generic**: it also covers kit sequence-save failures and JS
dispatch rejection. It is therefore not safe to blanket-retry, and this
change does not: a first-save defect keeps surfacing as `save.failed` with
domain/code evidence.

## Change (app side, existing channels only)

- `OfficeSaveAdmissionRetry` (`FloeAgent/FloeApp/Workspace/OfficeSaveAdmissionRetry.swift`):
  retries a save **exactly once**, only for the proven pre-dispatch busy
  signal — native **code 9** ("a save is already in progress"), which
  `saveReceipts begin:` raises while another tracked save receipt is open and
  which the overlay guarantees for every frontend Save route. The settle delay
  throws, so cancellation prevents the second attempt. Generic failures
  (code 8, conflicts, timeouts) propagate unchanged.
- `OfficeDocumentEditorView.save(returnToPreview:)` runs the working-copy
  flush through that policy and records `save.busyRetry` /
  `save.busyRetry.ok` stages for qualification.
- A reason-preserving bridge change (distinguishing admission rejection from
  sequence-save failure at the receipt) requires rebuilding the pinned native
  host and is **not** part of this patch; the `save.failed` stage domain/code
  is the deciding evidence if the observed failure proves to be code 8.

## Local evidence

- `OfficeBridgeStateTests` → `FloeApp.OfficeSaveAdmissionRetry` (5 tests):
  classification (only code 9 retryable; code 7/8/30/foreign domains refused),
  clean single attempt, busy-retry-then-succeed, generic code 8 propagates
  without retry, persistent busy stops at two attempts, **cancellation during
  the settle delay prevents the second attempt**.
- Headless bridge regression (`FloeAgent/scripts/test_office_explicit_save.py`,
  Node `vm` against the shipped script): after a failed save the bridge stays
  armed, a repeated UI_Save posts a new native save, rapid taps coalesce, and
  the watchdog bounds a lost handoff — the "save remains admissible after
  failure" contract the retry relies on.
- Full app test-bundle run (iPad Air 13-inch M4 simulator): suite passes
  except four environment-dependent tests that fail identically before and
  after this diff (see the delivery report).

## Real-engine verification (cloud workflow — required before claiming a fix)

Fixture: `floe-sim-qual.pptx` via `OfficeRealEngineUITests` save phases.

1. Open the deck in the Notes Office editor → Edit. Insert a shape and leave
   it selected.
2. Tap Save. Accept: `save.ok`, or `save.busyRetry` + `save.busyRetry.ok`.
   If `save.failed` appears, record domain/code — code 9 retried-and-failed or
   code 8 decides the follow-up (receipt-reason bridge vs kit investigation).
3. Reopen the deck from a cold preview and byte-compare against the working
   copy (the existing save/reopen phase does this): the inserted shape and
   title edit must survive.
4. Control run: repeat with the shape deselected; both runs must reach
   `save.ok` and reopen equal.

## Historical attribution note

The stalled-run logs from 2026-10-08 (`promo-shell-stall-20261008.jsonl`) prove
an approval that never executed after the user approved; they do **not** prove
the exact interleaving. The deterministically reproduced race (decision or
cancellation arriving between the `.waitingApproval` state publish and the
continuation install) is fixed and regression-tested; the historical root
cause remains **unproven** and is tracked in the approval-stall evidence.
