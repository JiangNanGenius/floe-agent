# Floe 231 — Office PPT/Excel open and Word CJK font repair

Status: source repair in the shared branch `codex/build231-device-regressions`;
lightweight host/script harnesses pass. The native host source changed, so the
pinned framework is now fail-closed (`SOURCE AHEAD OF ARTIFACT`) until a cloud
host rebuild is pinned, and no App build/device behaviour is claimed here.
Every table/statement below is sanitized engineering evidence; there is no
device or engine run in this document except where explicitly marked as
*not run*.

## Symptoms

* PPT/PPTX and XLSX failed to open/enter their editor (spinner then bounded
  failure or a dead surface).
* Chinese text in Word documents rendered as tofu boxes again (CJK families
  present in the bundle but not discovered).

## Root causes (verified against the pinned sources)

### 1. Two competing edit-intent owners (PPT/Excel)

`FloeOfficeNative.mm` had two independent edit entries:

* the injected page wrapper (`FloeFullScreenEditScript`) called
  `map._switchToEditMode()` synchronously from the first
  `setPermission('edit')`;
* the native host deferred/ran its own guarded entry
  (`deferEditEntryUntilFirstPaint`).

The pinned upstream ordering makes the page-owned entry unsafe:

* `browser/src/app/Socket.ts` assigns `_docLayer` and then calls
  `addLayer`, i.e. `CanvasTileLayer.onAdd`;
* `CanvasTileLayer.onAdd` (pinned `browser/src/layer/tile/CanvasTileLayer.js`)
  calls `map.setPermission(app.file.permission)` and only **afterwards** runs
  `map.fire('statusindicator', {statusType: 'coolloaded'})`,
  `sendInitUNOCommands()` and `setInitialZoom()` (which ends in
  `_requestNewTiles()`); the first status message is processed after that;
* `Permission.js`'s real `_enterEditMode` dereferences `this._docLayer`
  (`_docType`; Calc also calls `showCalcInputBar()`), and it first sets
  `_permission = 'edit'`, sends `setviewreadonly`, and fires
  `updatepermission` — so an entry that throws leaves partial edit state;
* `Map.js` sets `_docLoaded` on the `docloaded` event, which `Socket.ts` fires
  only after `addLayer`/`onAdd` returned.

An entry driven from inside `setPermission` is therefore re-entrant with the
layer's own initialisation, and the file-based Impress/Draw startup additionally
needs its preview to decode its first document tile before switching to the
part-based edit layout.

### 2. Readiness was format-blind for Word/Excel

No entry may run before the document layer exists and its first status was
processed. `docTypeKnown` alone is not that fact.

### 3. Font registration "success" was descriptors-only

`BundledFontRegistrar` / `DeviceFontStore` treated
`CTFontManagerCreateFontDescriptorsFromURL` returning descriptors as proof that
a font was registered. Descriptors parse from a file even when nothing was
registered for the process, so a failed CJK registration was silently counted
as success.

### 4. The engine never scans the app-level `Fonts/` directory

The pinned engine (`engine/vcl/quartz/salgdi.cxx`, `AddLocalTempFontDirs`)
registers fonts from exactly two directories before it caches the CoreText font
list (`GetCoretextFontList`):

* `$BRAND_BASE_DIR/program/resource/common/fonts/`
* `$BRAND_BASE_DIR/share/fonts/truetype/`

The shipped iOS engine binary (`Vendor/Office/35668651442`, engine built from
the same pinned tree) contains the literals `$BRAND_BASE_DIR`,
`/program/resource/common/fonts/` and `/share/fonts/truetype/`, confirming the
same two paths on device. `scripts/embed_office_host.py` used to copy the
bundled CJK families into the app-level `Fonts/` directory, which is on neither
path and is not scanned by any other engine code — the engine only saw them
through the App's process-wide registration, i.e. exactly through the
registration check that was broken.

## Changes

* `FloeAgent/ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm`
  * the page wrapper is now a handoff: it never drives the edit entry, records
    the initial grant content-free for diagnostics, hides the in-page mobile
    edit button (a second, human-owned intent path), and leaves the engine's
    viewing-first startup untouched;
  * one readiness gate per format: presentations need a decoded document tile
    (existing evidence, unchanged) with the bounded extent-bootstrap fallback
    for the file-based startup; Word/Excel need `docTypeKnown && docLoaded &&
    canvasSized` (the layer completed its first status);
  * every editable format funnels through that single deferral; the permission
    report is settled by the entry (or the bounded fallback) exactly once, and
    a still-parked entry settles without an entry at the probe deadline instead
    of hanging the report;
  * the font-catalog fingerprint now covers `Bundled`, `Fonts`,
    `program/resource/common/fonts` and `share/fonts`, and records whether the
    process really resolves each App-staged font (`registered`/`unresolved`
    via `CTFontCreateWithNameAndOptions`), logging
    `FloeOffice font discovery staged=… resolved=…`.
* `FloeAgent/FloeApp/Fonts/DeviceFontStore.swift`
  * new `CoreTextFontRegistration`: registration is verified by resolving the
    font's declared PostScript name in-process; the duplicate-registration
    error (105) is classified, never silently accepted; `activateManagedFonts`
    and `persist` only accept genuinely resolvable fonts.
* `FloeAgent/FloeApp/Fonts/BundledFontRegistrar.swift`
  * registration uses the same verification, returns only truly unresolvable
    files as failures, and exposes `discoveryReport(in:)` for diagnostics/tests
    (`stagedFiles`/`parsedFiles`/`resolvedFiles`/`unresolvedFiles`).
* `FloeAgent/scripts/embed_office_host.py`
  * bundled families are staged into the engine-scanned
    `program/resource/common/fonts` (with the symlink guard) instead of the
    unscanned app-level `Fonts/`; bundle size is unchanged (the app-level copy
    is replaced, not added).
* `FloeAgent/FloeApp/Workspace/OfficeStageDiagnostics.swift`
  * bounded, content-free `exportText()` (newest events, line and byte caps);
    each line now carries an absolute UTC timestamp and the header's
    `events_exported` is the number of lines actually rendered, never the
    events merely selected before the byte bound;
  * restart recovery: a new instance reads back the bounded tail of the
    previous process's JSONL before any new record can rewrite it (at most
    `fileLimit` bytes, decoded line by line, malformed or torn tail lines
    skipped) and re-sanitizes every recovered identity/detail field, so a
    crash, watchdog kill or relaunch no longer erases the stages that led to
    it and the first new record appends to the old tail instead of replacing
    the file; the recovered + new ring still obeys `eventLimit`/`fileLimit`.
* `FloeAgent/FloeApp/Settings/DiagnosticsExporter.swift`
  * the redacted diagnostics bundle now includes the Office stage trace.
* `FloeAgent/FloeApp/Workspace/OfficeDocumentEditorView.swift`
  * records the runtime-death error stage and the host's own
    `renderDiagnostics` snapshot at the open report, so PPT/Excel stages
    (host / working copy / import / permission / first paint / errors /
    session + generation) are all attributable from an export.
* Tests/assets: `FloeAgent/scripts/test_office_native_host.py`,
  `FloeAgent/scripts/test_office_fullscreen_edit.py`,
  `FloeAgent/scripts/tests/test_office_fonts_and_pencil.py`,
  `FloeAgent/Tests/FloeAppTests/OfficePresentationOpeningTests.swift`.

## Verification executed (local, sanitized)

| Check | Result |
| --- | --- |
| `python3 -m pytest FloeAgent/scripts/test_office_native_host.py FloeAgent/scripts/tests/test_office_fonts_and_pencil.py -q` | 35 passed, 2 skipped |
| `python3 FloeAgent/scripts/test_office_fullscreen_edit.py` | pass (wrapper never drives the entry; viewing-first startup preserved; button hidden; idempotent) |
| `python3 FloeAgent/scripts/test_office_edit_entry_chain.py` | pass |
| `python3 FloeAgent/scripts/test_office_readonly.py`, `test_office_app_load_chain.py`, `test_office_embedded_controls.py` | pass |
| Office script suites (native host/open/lifecycle/explicit save/language/filter overlay/host bootstrap/mobile qualification/save receipts) | 71 passed, 2 skipped; the only failures are `test_office_engine_bundle.py` (`tarfile.extractall(filter=…)` needs Python 3.12) and pre-existing release/license tests unrelated to these files |
| Compiled gate harness (`test_office_native_host.py`) | Word/Excel trigger requires type+docloaded+canvas; presentations require the decoded tile; fallback bounds hold |
| `node` harness of the shipped fullscreen wrapper | zero page-owned entries at every grant timing, no `_switchToEditMode` in the script |
| Compiled run of the shipped font-catalog fragment (fake app tree) | discovery log `staged=… resolved=…`; a garbage `.ttf` changes the identity and is marked unresolved; file-size change and removal change the identity; a registered font reports `alreadyRegistered` |
| Compiled run of the shipped registrar helper | before registration 0/23 resolved; after activation 23/23 resolved, 0 failures; an unresolvable staged file is reported; already-registered font is `alreadyRegistered` |
| macOS swift-testing run of the shipped recorder (`DEVELOPER_DIR=Xcode-beta swift test` over the working-tree `OfficeStageDiagnostics.swift` plus the extracted new `OfficeStageDiagnosticsTests` and the pre-existing `OfficeStageRecorderTests`) | 13 passed, 0 failed: relaunch tail recovery and export, first-record tail preservation, `fileLimit` tail read of a 200-line file, `eventLimit` ring across a relaunch, malformed and torn-line tolerance, re-sanitizing of crafted path and path-in-identity fields, rendered-count header under the byte bound, absolute timestamps, plus the 4 pre-existing export tests and the 3 pre-existing recorder tests |
| Hostile-input probe (extreme `at` values) | no crash, no unbounded output: 4 hostile events rendered 304 bytes; the ISO8601 renderer clamps absurd dates to a compact year |
| `xcrun swiftc -parse` of the modified `OfficePresentationOpeningTests.swift` (file guard bypassed) | exit 0 (full FloeApp test bundle remains a CI/cloud run) |
| Real CoreText pass over the staged families | 23/23 parse, register, resolve by PostScript name and cover CJK (`"中"`,`"文"`) in 0.13 s |
| `python3 FloeAgent/scripts/pin_office_host_artifact.py --check` | exit 1, `SOURCE AHEAD OF ARTIFACT … FloeOfficeNative.mm` (expected: host source changed) |

Not run / not proven here: no App build, no simulator App run (the simulator has
no native engine slice), no engine open, no real first paint, no device font
rendering, no original-file writeback. The first three local harnesses are
mocks/synthetic and are labelled as such in their tests.

## Required next steps (cloud, main thread)

1. Commit and push the branch (`codex/build231-device-regressions`).
2. Rebuild and re-pin the native host:
   ```
   gh workflow run office-native-host.yml --ref codex/build231-device-regressions
   gh run watch <run-id>
   gh run download <run-id> -n office-native-host-unsigned -D ./host
   python3 FloeAgent/scripts/pin_office_host_artifact.py \
     --artifact-zip ./host/OfficeNativeHost.zip --apply --artifact-id <id> \
     --note "Build 231 repair: single readiness-gated edit entry (Word/Excel need type+docloaded+sized canvas; presentations keep the decoded-tile gate), page wrapper is handoff-only, engine-scanned font staging, resolved-font catalog fingerprint. Framework evidence only; App build/device acceptance separate."
   ```
   Expected artifacts: `office-native-host-unsigned` (framework +
   `OfficeRuntimeResources`) and `office-native-host-evidence`. The App embed
   step separately adds the curated families to `program/resource/common/fonts`;
   the host artifact alone does not prove those App fonts were packaged.
   Then `--apply` updates
   `engine.lock.json.qualifiedHostArtifact` (`runID`, artifact id, archive /
   executable / manifest hashes, `hostSourceSHA256`).
3. Run the App build with the new pin, then device acceptance (below).

## Diagnostics export shape

The redacted diagnostics bundle carries a bounded, content-free Office stage
trace. Every line now starts with its absolute UTC time (`at=…`), so stages
recorded before a crash or relaunch still correlate with the current process,
and the header's `events_exported` is the number of lines actually rendered —
never the events merely selected before the byte bound. The shape below was
regenerated by the local harness from the shipped recorder for the same
13-stage PPTX edit open (1447 bytes; the timestamps come from that synthetic
run, not from a device):

```
== Office stage trace (content-free, bounded) ==
events_retained=13 events_exported=13
at=2026-09-27T03:09:29.482Z session=0A1B2C3D generation=1 stage=intent.edit format=pptx
at=2026-09-27T03:09:29.483Z session=0A1B2C3D generation=1 stage=workingCopy.open format=pptx
at=2026-09-27T03:09:29.484Z session=0A1B2C3D generation=1 stage=workingCopy.ready
at=2026-09-27T03:09:29.484Z session=0A1B2C3D generation=1 stage=engine.runtime.prepare.started readOnly=false
at=2026-09-27T03:09:29.485Z session=0A1B2C3D generation=1 stage=engine.runtime.ready
at=2026-09-27T03:09:29.485Z session=0A1B2C3D generation=1 stage=controller.mounted hostRenderContract=true readOnly=false
at=2026-09-27T03:09:29.486Z session=0A1B2C3D generation=1 stage=render.gate requirement=visibleRenderRequired
at=2026-09-27T03:09:29.486Z session=0A1B2C3D generation=1 stage=engine.open engineReadOnly=false success=true
at=2026-09-27T03:09:29.487Z session=0A1B2C3D generation=1 stage=host.renderDiagnostics deadline=25.0 docType=presentation elapsed=3.2 requiresVisibleRender=true stage=ready tiles=4
at=2026-09-27T03:09:29.487Z session=0A1B2C3D generation=1 stage=edit.attempt
at=2026-09-27T03:09:29.487Z session=0A1B2C3D generation=1 stage=edit.entry readOnly=false
at=2026-09-27T03:09:29.488Z session=0A1B2C3D generation=1 stage=edit.acknowledged readOnly=false
at=2026-09-27T03:09:29.489Z session=0A1B2C3D generation=1 stage=engine.visibleRender docType=presentation editSurfaceArmed=true editSurfacePainted=true newDecodes=1
```

A process that launched after this trace may export these previous-session lines
plus its own; the times and the session/generation identity tell the two
launches apart. Recovery reads at most `fileLimit` bytes of the file tail, skips
malformed or torn lines, drops non-content-free identity/detail values, and
keeps at most `eventLimit` newest events, so a corrupted or replaced file can
neither enlarge memory nor leak document content into the bundle.

## Still requires device acceptance

* PPT/PPTX and XLSX open to a painted, editable surface on a physical iPad;
  re-open, edit and save round-trip.
* The edit entry actually runs once at the recorded readiness (host log:
  `edit-entry-deferred` → `first-paint` → `edit-entry` → `edit-entry-result`)
  with no partial-state surface.
* Word CJK text renders with the bundled families; `FloeOffice font discovery
  staged=… resolved=…` shows the staged families resolved on device.
* A diagnostics export from the device contains the bounded Office stage trace.
* No regression for preview, permission, exit/save, ink and attachments.
