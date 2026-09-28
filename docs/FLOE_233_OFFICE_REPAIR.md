# Floe 233 — Office PPT-resilience and font repair (source handoff)

Date: 2026-09-28. Status: **source candidate implemented; native host rebuild and
device acceptance outstanding.** Nothing in this document claims an iPad or
engine result. The signed-delivery state remains Build 232.

The diagnosis that motivates this repair is retained (task-private): it is not
duplicated here. This file records what changed in the checkout, the exact
checks that were run, the cloud handoff, and what is still unproven.

## What changed

| Item | Files | Behaviour |
| --- | --- | --- |
| R1 durable native stage breadcrumbs | `ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.{h,mm}`, `FloeApp/Workspace/OfficeStageDiagnostics.swift`, `FloeApp/Workspace/OfficeDocumentEditorView.swift` | The pinned host emits one content-free `floeStage:` breadcrumb at open settle, permission probe, render probe, first paint, visible render (ready/failed/unobserved), the whole edit-entry chain, close bye/ack and web-content termination, each carrying `memAvailableMB`/`memPhysicalMB`. The App records them as `host.<stage>` under its own session identity, guarded by controller identity + open generation + `runtimeFailed`, so a late callback from a replaced controller can never settle a newer session. App-side stages (`controller.mounted`, `engine.runtime.prepare.started/ready`, `engine.open`, `edit.attempt`, `engine.visibleRender`, `edit.acknowledged`, memory warnings) also carry a memory sample. `OfficeMemorySample` preserves a real `os_proc_available_memory()` 0. Font discovery facts (`staged`, `resolved`, catalog fingerprint) are exposed as `FloeOfficeNativeRuntime.fontDiscoveryFacts` and recorded at `engine.runtime.ready`. |
| R2 idle-model shed for Office | `Sources/FloeLocalModels/LocalProviderAdapter.swift` (`shedIdleResidentEngineForOffice`), `FloeApp/App/AppEnvironment.swift`, `FloeApp/Workspace/OfficeDocumentEditorView.swift` | Before engine runtime preparation and on `UIApplication.didReceiveMemoryWarningNotification` while an Office controller is mounted, the App asks the runtime to release an **idle** resident MLX mapping. The runtime refuses immediately (returns nil, never waits on the FIFO inference slot) when `inferenceBusy`, any transient load/benchmark/chat lease, or any retained durable task claim exists. No task, guest, request or tool continuation is cancelled; only the physical mapping is released and the next local turn reloads the pinned snapshot. Both outcomes are recorded in the stage trace. |
| R3 web-content termination recovery | `FloeOfficeNative.{h,mm}`, `OfficeDocumentEditorView.swift` | A category on the **upstream** `DocumentViewController` (which already owns `navigationDelegate`) implements `webViewWebContentProcessDidTerminate:` and reports through a notification only for its own editor. No delegate is replaced or proxied and no working copy is touched. The App records `host.webContent.terminated` and settles the bounded recoverable failure `org.floeagent.office.render` code 2 (retry/recovery, copies retained) instead of waiting for the 25 s probe deadline. |
| R4 font substitution configuration | `ThirdParty/Collabora/FloeOfficeFontSubstitutions.xcu` (new), `scripts/office_font_config.py` (new), `scripts/build_office_native_host.py`, `scripts/embed_office_host.py`, `scripts/verify_office_app_embedding.py`, `scripts/tests/test_office_font_config.py`, `.github/workflows/office-native-host.yml` | An additive `user:` layer merged into the packaged `coolkitconfig.xcu` at native-host packaging time (so the pin covers the merged bytes; the vendor file is never edited in place). It uses the pinned VCL registry hierarchy exactly: `FontSubstitutions` is a set of locale members (`org.openoffice.VCL:LocalizedFontSubstitutions['en']`), each locale member a set of `LFonts` alias records. An alias the pinned `main.xcd` already declares (`simsun`/`nsimsun`/`simhei`/`kai`/`hei`/`fangsong`/`song`/…, the vendor CJK and Office Latin keys) is addressed as `/org.openoffice.VCL/FontSubstitutions/org.openoffice.VCL:LocalizedFontSubstitutions['en']/org.openoffice.VCL:LFonts['<alias>']` and only its `SubstFonts` value is replaced, keeping the vendor `SubstFontsMS`/`FontWeight`/`FontWidth`/`FontType`. An alias the shipped table lacks (`fzfangsong`, `microsoftyahei`, `microsoftjhenghei`, `dengxian`, `kaiti`, `yahei`, `msyh`, `pingfang*`, `stheiti`, `stsong`, `songtisc`, `heitisc`) is added as an `oor:op="fuse"` node child of the `en` locale member, which the pinned configmgr `XcupParser::handleSetNode` creates or merges without touching sibling aliases or locales. Every alias key is stored in the exact normalized form the pinned engine looks up, and every target is a real font **family** of a bundled OFL-licensed font (`Source Han Sans/Serif SC/TC`, `LXGW WenKai`, `Sarasa Mono SC`, `MiSans`, `HarmonyOS Sans SC`) or of the pinned LibreOffice bundle (`Carlito`, `Caladea`, `Liberation *`). |
| R5 zh UI language resources | `scripts/office_font_config.py` (`language_resource_report`), `scripts/build_office_native_host.py`, `scripts/embed_office_host.py`, `scripts/verify_office_app_embedding.py`, `scripts/tests/test_office_language_resources.py` | The host build records which configured-language (`en-US zh-CN zh-TW`) registry/langpack files the upstream engine output actually produced; the app payload must contain every produced file, and a language the upstream build never emitted is a recorded gap (`languageResourceGap`), never fabricated. The release gate refuses an artifact missing a produced language file and refuses an artifact predating the R4 overlay. |
| Gates and workflow | `scripts/verify_office_app_embedding.py`, `.github/workflows/office-native-host.yml` | `--require-release` now fails when the embedded host predates the font-substitution overlay; the native-host workflow validates the overlay/merge language audit before and after packaging. |

### Corrections to the earlier diagnosis (artifact-backed)

1. `share/registry/main.xcd` in the shipped Build 232 IPA (streamed SHA-256
   `1563bff4…c066`, identical to the vendor copy) **does** contain
   `org.openoffice.VCL` component-data with `FontSubstitutions` and
   `DefaultFonts`. The real gap is that its substitution targets
   (`fzsongti`, `msunglightsc`, `nsimsun`, …) are not installed, so documents
   naming those Windows/Chinese families fall through the whole list.
2. The same file's `zh-cn`/`zh-tw` `DefaultFonts` `CJK_*` lists already start
   with `Source Han Sans/Serif SC/TC`, which are the bundled families. No
   override is needed there; the gate only verifies the merged config's Floe
   aliases resolve.
3. `zh-CN`/`zh-TW` UI registry/langpack files genuinely do not exist in the
   pinned upstream output (the IPA ships `Langpack-en-US.xcd`,
   `res/registry_en-US.xcd`, `res/fcfg_langpack_en-US.xcd` only). Closing that
   needs upstream engine resource outputs (or an engine rebuild with the
   translation target); this change makes the gap explicit and gated rather
   than fabricating files.
4. **Font overlay path hierarchy (primary audit, corrected).** The first R4
   candidate addressed aliases as
   `/org.openoffice.VCL/org.openoffice.VCL:FontSubstitutions['simsun']` and
   added missing aliases as nodes of the root set. That hierarchy is wrong:
   the pinned schema (`engine/officecfg/registry/schema/org/openoffice/VCL.xcs`,
   commit `27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc`, lines 75/92 and
   compiled into the shipped `share/registry/main.xcd`) declares
   `FontSubstitutions` as a **set of `LocalizedFontSubstitutions`**, that
   template as a **set of `LFonts`**, and `LFonts` as the group carrying
   `SubstFonts`/`SubstFontsMS`/`FontWeight`/`FontWidth`/`FontType`. The pinned
   reader confirms it: `fontcfg.cxx readLocaleSubst` reads the locale member
   first and then its alias records, and `getSubstInfo` falls back to `en`
   for every UI language; the pinned table's only locale with data is `en`.
   A path that omits the locale addresses the root set's member position
   (a locale), and a node added directly on the root set would be read as a
   locale, never as a font. The corrected overlay instead uses
   `/org.openoffice.VCL/FontSubstitutions/org.openoffice.VCL:LocalizedFontSubstitutions['en']/org.openoffice.VCL:LFonts['<alias>']`
   for the 31 vendor aliases it overrides, and one `en` locale-set item whose
   15 new aliases are `oor:op="fuse"` node children
   (`XcuParser::handleSetNode` creates a missing member and merges into an
   existing one; `handleGroupProp` replaces only the named property).
   `DefaultFonts` is already correct in the vendor `coolkitconfig.xcu`
   (`/org.openoffice.VCL/DefaultFonts/org.openoffice.VCL:LocalizedDefaultFonts['en']`,
   the extensible `LocalizedDefaultFonts` group); the validator and tests
   now parse and reject wrong forms for both node kinds. A merge simulation
   over the real `main.xcd` (SHA-256 `1563bff4…c066`) retains every locale and
   all 289 unrelated vendor aliases byte-equal, overrides only `SubstFonts`
   on the 31 targeted aliases, and adds exactly the 15 declared aliases.

### Font coverage decision (R6)

No document is modified by any of this: the overlay changes render-time font
fallback only, so original font names and metadata inside DOCX/PPTX/XLSX files
are preserved byte-for-byte (the existing save/receipt paths are untouched).

`FloeAgent/scripts/fonts/manifest.json` declares `zhuque-fangsong` as an
optional OFL-1.1 family, but the entry has no pinned archive hash (upstream is
a prerelease) and the staged set is deliberately the curated core tier. No
ornamental/optional family is added here. Documents naming 仿宋/FangSong
resolve to `Source Han Serif SC` (substitution, not an installed 仿宋 face);
true 仿宋 glyph shapes remain a documented coverage limitation until a
validated, hash-pinned fangsong source is staged.

## Local checks actually run

All of these ran in this checkout; none is an App, engine or device build.

| Check | Command | Result |
| --- | --- | --- |
| Font config | `python3 -m unittest discover -s FloeAgent/scripts/tests -p 'test_office_font_config.py'` | 21/21 pass (locale/alias path hierarchy incl. regressions rejecting the previous locale-less form, DefaultFonts locale hierarchy, normalization, localized-name lookup, real sfnt family/PostScript facts of the 23 staged font files, required alias coverage, embed-time merge, idempotent merge preserving vendor items). The three `PinnedVendorTableTests` additionally parse the downloaded vendor `share/registry/main.xcd` (schema node types, 320 vendor aliases, fuse-merge retention) and skip when that artifact is not present. |
| Language resources | `python3 -m unittest ... test_office_language_resources.py` | 4/4 pass (reporting, honest gap, packaging-regression failure) |
| Stage/R2/R3 contract | `python3 FloeAgent/scripts/test_office_stage_diagnostics.py` | 12/12 pass, including an Objective-C++ syntax compile of the new native stage/recovery block against the macOS SDK |
| Office host suites | `python3 FloeAgent/scripts/test_office_native_host.py` and the other `test_office_*.py` suites | 30/30 pass (2 pre-existing skips); `test_office_engine_bundle.py` needs Python 3.12 (`zipfile.extractall(filter=…)`), the CI workflow uses 3.12 |
| Pin state | `python3 FloeAgent/scripts/pin_office_host_artifact.py --check` | exit 1, `SOURCE AHEAD OF ARTIFACT (FloeOfficeNative.h, FloeOfficeNative.mm)` — the intended candidate state; the old artifact is not misrepresented |
| Pin path tests | `python3 -m unittest FloeAgent.scripts.tests.test_office_host_pin_path` | 11/11 pass (fail-closed behaviour preserved) |

The sfnt name-table parser was cross-checked against the earlier CoreText
facts: 23/23 staged font files match on resolved family and PostScript name.

Not yet run (blocked or handed off): the FloeLocalModels Swift tests added in
`Tests/FloeLocalModelsTests/LocalModelOfficeShedTests.swift` and the two tests
added to `Tests/FloeAppTests/OfficeEditEntryAckTests.swift` require the shared
`FloeAgent/.build` scratch (owned by a concurrent qualification) — run them as
soon as it is free. The App target, native framework, engine and any device run
are cloud/user-side.

## Cloud host rebuild and re-pin handoff

The host sources changed, so `bootstrap_office_host.py`/`checked_lock` fail
closed until a rebuilt artifact is pinned. The sequence (no release authority
is implied):

```bash
# 1. Dispatch the native host workflow on the candidate branch (repo root).
gh workflow run office-native-host.yml --ref <candidate-branch>
gh run list --workflow=office-native-host.yml --limit 3   # find the run id
# 2. Download the rebuilt unsigned host artifact.
gh run download <run-id> -n office-native-host-unsigned -D ./host
# 3. Record the rebuilt artifact (refuses mismatched sources/overlay/qualification).
python3 FloeAgent/scripts/pin_office_host_artifact.py \
    --artifact-zip ./host/OfficeNativeHost.zip --apply
# 4. App-side payload verification after the next App build:
python3 FloeAgent/scripts/verify_office_app_embedding.py \
    "<built .app>" --output "$RUNNER_TEMP/office-embedding.json" --require-release
```

`--require-release` intentionally still fails on the four capability flags
(embedded editor, PPTX visible render, device roundtrip, original-file
writeback) until real device evidence exists. The rebuilt host must show
`fontSubstitutionConfig.aliases > 0` with `locales: ["en"]` and non-empty
`aliasOverrides`/`aliasAdditions` (validated against the packaged
`share/registry/main.xcd`), the merged markers in
`OfficeRuntimeResources/coolkitconfig.xcu`, and the language audit block.

## Remaining Apple/iPad acceptance (unproven — no fake claims)

The device path is the existing isolated-probe + receiver flow; the R7 idle
receipt is the new bounded piece:

```bash
python3 FloeAgent/scripts/qualify_office_device_capabilities.py \
    --receipts ./device --device-model 'iPad14,3' --os-version '26.0' --run-id <run> \
    --original-writeback ./device/original-writeback.json \
    --embedded ./app-embedding.json --require-idle [--apply]
```

`--require-idle` consumes `./device/idle-stability.json`: one presentation
session, `stageTracePresent: true` (the R1 durable trace), `idleSeconds >= 600`,
at least two `memoryAvailableMB` samples, `processAliveAfterIdle`,
`interactiveAfterIdle`, `saveCompletedAfterIdle`, `reopenedAfterIdle` all true,
and the last recorded stage. A simulator run, a synthetic receipt without the
device facts, or a shorter window fails the qualification; none of it changes
the four release capability flags by itself.

1. Reproduce the Build 232 PPT idle path (editable Impress open from Notes)
   with the R1 breadcrumbs + memory samples and capture the last native stage,
   `availableMB` series and any `JetsamEvent`/crash `.ips` whose App/framework
   UUIDs match the installed build. The 232 crash attribution (jetsam vs
   native abort vs teardown race) is still unproven; nothing here asserts it.
2. PPTX edit → idle ≥ 10 min → save → close → reopen with a resident local
   model and with it shed, checking that the editor stays interactive.
3. A fixed CJK/Latin font probe deck rendered on device (SimSun, SimHei,
   Microsoft YaHei, KaiTi, FangSong, 宋体/黑体 alias input, Calibri, Cambria,
   Arial, Times New Roman) with the engine's own font-resolution facts in the
   diagnostics — file presence and config parsing are not glyph proof.
4. Device memory/arrival telemetry around MLX + Office concurrency, and the
   imported-`DeviceFontStore` question below.

## Known limit: imported device fonts vs the engine font list

The engine caches its available-font list when the runtime starts and the
profile identity fingerprints the bundled catalog only. A font imported into
`DeviceFontStore` **after** the engine started is not guaranteed to be visible
to that engine process; the App records `engine.fontDiscovery` and the device
font count so this can be verified from a trace, but no claim is made that all
user-imported fonts are engine-visible. A supported refresh (engine restart or
an upstream font-list refresh hook) remains open.
