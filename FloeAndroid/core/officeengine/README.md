# :core:officeengine — embedded Office engine (R1 preview + R2 manual editing)

Reusable embedded Android Office viewer/editor built on the pinned, signature-
verified Collabora Office Mobile 26.04.4.2/code937 ARM64 payload. See
[PROVENANCE.md](PROVENANCE.md) for identity, license obligations and the
honest unproven list. R1 = offline preview: DOCX/XLSX/PPTX, read-only routes,
no save/export/edit. R2 (this source batch) adds the explicit trusted-host
EDIT session over a separately owned mutable working copy, typed save/export
receipts from the real pinned producer callbacks, the generic host save-target
seam and bounded RAM-only diagnostics. Representative offline display was
observed for all three formats in R1; R2 editing/save is source-complete and
awaits Main's concentrated compile + device qualification.

## Process and host wiring (Main integration)

- Everything engine-side runs in the dedicated **`:floe_office`** process
  (`OfficePreviewActivity` + `OfficeEngineService` +
  `OfficeWebViewDirectoryProvider`, all `exported=false`, same UID =
  lifecycle/crash segregation, not a sandbox).
- `FloeApplication` returns before default-process bootstrap when
  `Application.getProcessName()` ends with `:floe_office` (Main-owned). The module sets no Application and requires none.
- WebView data-directory: the module's provider calls
  `WebView.setDataDirectorySuffix("floe_office")` first inside the engine
  process only; the browser's default-process WebView data is never shared,
  deleted or reset. `OfficeEngine.ensureOfficeWebViewDirectory()` is exposed
  for embedders and is idempotent.

## Build inputs

Packaging consumes Main's staged payload directory explicitly (never
Git-tracked, never rebuilt on the host):

```
./gradlew :app:assembleFullDebug \
  -Pfloe.office.payloadDir="/absolute/path/to/verified-office-payload"
```

(or `FLOE_OFFICE_PAYLOAD_DIR`). Missing/mismatched payload fails actionably at
the packaging merge (`verifyOfficeEnginePayload` → `stageOfficeEngineJniLibs`
→ `prepareOfficeEngineAssets`), with per-file SHA verification against the
source-controlled `producer-manifest.json` digest at the first/changed-input boundary.
Pure compile + JVM tests never require the payload. `-Pfloe.office.payloadVerify`
is not a thing: re-verification is Gradle-driven; use `--rerun-tasks` for an explicitly requested repeat.

## Caller API (trusted staged snapshots only)

```kotlin
val staged = // Main's stager output, e.g. WorkspaceOfficeSnapshotStager result:
//   <app-owned root>/<sessionUUID>/document.docx with verified sha/length.
val request = OfficePreviewRequest.of(
    sessionToken = snapshot.sessionUUID,          // opaque host-owned identity
    stagedFilePath = snapshot.localPath,         // absolute, app-data-scoped
    sha256 = snapshot.digest,                    // re-verified engine-side
    lengthBytes = snapshot.bytes,
    displayName = snapshot.logicalPath.substringAfterLast('/'),
    languageTag = null,                          // null -> device locale
    // Real optional context only; null for a direct SAF local preview:
    ownerTaskId = snapshot.ownerTaskIdOrNull,
    workspaceId = snapshot.workspaceIdOrNull,
    nativeEpoch = snapshot.nativeEpochOrNull,
    hostGeneration = snapshot.hostGenerationOrNull,
    sourceLogicalPath = snapshot.logicalPath,
    sourceId = snapshot.sourceIdOrNull,
    sourceRevision = snapshot.sourceRevisionOrNull,
).getOrThrow()                                   // fail-closed shape checks

context.startActivity(OfficeEngine.previewIntent(context, request))
// registerForActivityResult path:
val outcome = OfficeViewerOutcome.fromResultData(dataIntent)
// outcome.closedCleanly / failure code / document witness dimensions.
```

No content URI, no external intent path, no permission is ever derived from
the request: the engine process canonicalises the path inside the app's own
data roots, re-hashes it, extracts the profile skeleton (`assets/unpack` →
`$APP_DATA_DIR`, with the fontconfig cache directory rewritten to the running
package), then mounts it. The originals live under the host's authority and
are never written by R1.

## Lifetime and readiness (summary)

- `OfficeEngineService` owns native work: staging checks → payload unpack →
  `createCOOLWSD` (control thread) → page load → HULLO → message witnesses.
- READY_READ_ONLY requires document shape + a real tile delivery + a passed
  PixelCopy painted-frame probe; `invalidatetiles:` alone never marks ready.
- Close/cancel is BYE on a dedicated close worker, settling exactly once;
  reopen of a live mount is refused with `ENGINE_BUSY`; view reconstruction
  reopens the same session token after the previous mount settles.
- The mobile engine carries one active document per native lifetime — that
  limit is real and surfaced, not hidden.

## R2: manual editing, typed save outcomes and the host save seam

- **EDIT admission**: `OfficePreviewRequest.of(..., permission = OfficePermission.EDIT)`
  is the explicit trusted-host request. The open pipeline fail-closes unless the
  staged file is a WRITABLE working copy (canonical, digest-verified, inside app
  data) — an immutable R1 snapshot or provider original can never be mounted
  editable. Preview defaults and all R1 call sites are unchanged.
- **READY_EDITABLE** is an honest edited-ready variant: the R1 render witnesses
  PLUS the ordered `.uno:ReadOnly` barrier reply after the real kit command
  `setviewreadonly value=false`, PLUS unmasked server permission frames
  (`perm: edit` / `filemode:{readOnly:false}`), PLUS no modify-password
  protection. Protected/denied/unconfirmed EDIT mounts DEGRADE to
  READY_READ_ONLY with an explicit notice — never a fake editable claim. The
  host edit toggle drives the pinned page entry (`_proceedEditMode` /
  `_enterReadOnlyMode`) through a guarded injection; the page's own
  `EDITMODE on/off` message is the page-state witness.
- **Working-copy flush** (`WORKING_COPY_FLUSH`): the real protocol message
  `save dontTerminateEdit=1 dontSaveIfUnmodified=<0|1>` (official-app parity).
  Proof is the kit's `unocommandresult:` `.uno:Save` frame observed on the
  unforgeable native→page channel, with the pinned `SaveResult` semantics
  (success→FLUSHED only after a working-copy digest re-read; `unmodified`→
  UNMODIFIED; else FAILED; `error: cmd=save|storage kind=savefailed`→FAILED).
  No ack within the bounded window (or before mount end) is UNKNOWN — never
  success-by-sleep. After one lost ack, further flushes are refused
  (STALE_ACK_QUARANTINE) so a late old callback can never satisfy a new op.
- **Staged export** (`STAGED_EXPORT`, Save Copy): the pinned synchronous JNI
  `saveAs` writes a FRESH op-owned file under
  `noBackupFilesDir/floe-office-outputs/<generation>/`, then bounded real
  verification (regular, 1..256 MiB, whole read, format magic, SHA-256)
  produces `OUTPUT_READY{path,sha,bytes}`. Void return alone is never success;
  there is no async saveAs ack in the pinned producer (reported, not faked).
  No flush prerequisite — it exports the current in-memory document. Failed
  partials of THIS attempt are removed; the working copy and all previously
  verified outputs are retained on every non-success path.
- **Host save-target seam** (no SAF logic in the module): the App prepares the
  CREATE_DOCUMENT Intent (`OfficeHostSaveChannel.parentBinder.onPrepare`), the
  FOREGROUND viewer Activity launches it via StartActivityForResult (the
  background App must not assume BAL permission) and forwards the ACTUAL
  uri+flags+op identity back (`onPickResult`). Picker acceptance means
  "accepted for processing" only. The App settles the truth asynchronously via
  `settleHostSaveCopy(opId, token, generation, COPY_SAVED|COPY_FAILED|
  COPY_CANCELLED)` — accepted exactly once per known pending op; only
  COPY_SAVED may display a saved-to-destination outcome or close a dirty
  editor. Native FLUSHED/UNMODIFIED/ModifiedStatus describe the PRIVATE
  working copy and never authorize a close.
- **App-process command surface**: bind `OfficeEngineCommands.bindIntent`
  (distinct explicit action; extras never multiplex binders) →
  `submitSave/cancelSave/requestEdit/requestEditHistory/readState/
  readDiagnostics/settleHostSaveCopy/readGeneration/registerHostChannel`.
  Same-UID + descriptor + exact token/generation fences on every transaction.
  Receipts/edit-state also push to the App channel; OUTPUT_READY is delivered
  to the App channel BEFORE the in-process listener so a viewer-initiated
  prepare can never outrun the App's receipt storage (real happens-before).
- **Dirty-close guard**: once editing was entered or the kit reports the copy
  modified, Back opens an explicit sheet — "Save Copy and close" (closes only
  after the verified App settlement), "Discard changes" or "Keep editing".
  During a close-save the document input is frozen (IME hidden, focus cleared,
  owned busy cover) so no later edit is silently discarded.
- **Close facts**: `OfficeViewerOutcome` adds `dirtyAtClose`,
  `editPermissionEstablished`, `saveReceiptCount` and bounded
  `saveReceiptDescriptors` (parse via `OfficeSaveReceipt.fromDescriptorLine`).
  R1 close semantics (ack-before-BYE, owner binding, uncertain-close) are
  unchanged; a pending flush at mount end settles UNKNOWN and every staged
  artifact is retained.
- **Diagnostics**: `OfficeSessionDiagnostics` keeps a bounded (64 events /
  16 KiB / 240 chars) RAM-only per-session history — startup `onJsError`
  facts survive later generic notices (R1 C8 lesson). Readable only through
  the viewer's explicit local Technical details sheet or the fenced
  `readDiagnostics` transaction; never logged, persisted or put in results.

## Not proven here (device gates for Main)

native dlopen + libc++ ABI equivalence; three-format actual rendering;
engine-kernel macro auto-execution and external-reference auto-update
behaviour (see PROVENANCE.md); merged-manifest review with the App;
`--write-locks` generation for this module. R2 adds: EDIT admission on a real
mutable working copy; on-device observation of `perm: edit`/`filemode:`
frames for the mobile integration; the flush ack roundtrip and its timeout
path; export artifact verification for all three formats; the host-picker
handoff against Main's real SafGateway flow; close/cancel quiescence with a
save in flight; both bind orders (Activity-first and App-first) against the
cached-binder identity fix. Undo/redo state strings are chrome information
only; a forced full-recalc-before-save command is deliberately NOT shipped
(Calc live-recalculates dependents; no pinned producer command was proven —
reported instead of guessed).

## Parent owner and close results

Floe binds the visible viewer to an inert, non-exported owner service in the application process. This expresses the Android process dependency while the document is visible; it adds no foreground notification, PiP or permission and does not bypass ordinary background limits. The viewer keeps the exact-session close capability in its private launch Intent.

The fixed mobile producer terminates its process on the last document close, before Java can return a result. The parent therefore acknowledges only the current user close before native teardown. A missing result after that acknowledgement is an uncertain close: it does not invent native-clean acknowledgement, and the private preview input is retained. Unexpected death without an owned close stays a failure. Reliable editing/save commits are a separate next-stage contract.
