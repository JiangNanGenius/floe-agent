# :core:officeengine — G05-R1 embedded Office engine (preview)

Reusable embedded Android Office viewer built on the pinned, signature-
verified Collabora Office Mobile 26.04.4.2/code937 ARM64 payload. See
[PROVENANCE.md](PROVENANCE.md) for identity, license obligations and the
honest unproven list. R1 = offline preview only: DOCX/XLSX/PPTX, read-only routes, no save/export/edit. Representative offline display was observed for all three formats; editing, saving and complete device coverage remain separate qualifications.

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

## Not proven here (device gates for Main)

native dlopen + libc++ ABI equivalence; three-format actual rendering;
engine-kernel macro auto-execution and external-reference auto-update
behaviour (see PROVENANCE.md); merged-manifest review with the App;
`--write-locks` generation for this module.

## Parent owner and close results

Floe binds the visible viewer to an inert, non-exported owner service in the application process. This expresses the Android process dependency while the document is visible; it adds no foreground notification, PiP or permission and does not bypass ordinary background limits. The viewer keeps the exact-session close capability in its private launch Intent.

The fixed mobile producer terminates its process on the last document close, before Java can return a result. The parent therefore acknowledges only the current user close before native teardown. A missing result after that acknowledgement is an uncertain close: it does not invent native-clean acknowledgement, and the private preview input is retained. Unexpected death without an owned close stays a failure. Reliable editing/save commits are a separate next-stage contract.
