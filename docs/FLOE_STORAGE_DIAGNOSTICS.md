# Storage diagnostics and safe cleanup / 储存空间诊断与安全清理

Status: implemented in source, focused tests pass, **not yet device-accepted**. This document describes the current behavior. It does not claim the Settings figures match iOS Storage exactly — see “Honesty” below.

## Why this exists / 背景

Settings → Data Management used to sum Library + Documents + tmp and report the *apparent* size of sparse VM disks, which made Floe's number diverge from iPad Settings. The physical-device root cause is **not proven** to be a single factor; the old code already used allocated size keys. The rewrite replaces guesswork with a transparent, categorized, deduplicated measurement and an ownership-aware cleaner.

## The engine / 计量引擎

`FloeAgent/Sources/FloeCore/StorageAccounting.swift` (`StorageCensus`):

- **Single mutually-exclusive pass.** Overlapping/nested roots attribute each file to the deepest matching root; the walker visits each physical tree once.
- **Exact identity dedup.** Device + inode deduplicate hard links and root overlaps; deduped bytes are reported separately (`sharedSize`) and never added twice.
- **Logical vs allocated.** `logicalBytes` is the apparent length (for a sparse VM disk this is its *configured guest capacity*); `allocatedBytes` uses `totalFileAllocatedSize` (host-allocated, sparse-aware). Both are kept and displayed separately.
- **Hidden files** are included by default so staging/`.trash`/`.downloads` directories are not silently dropped.
- **Races and errors.** Files that vanish mid-scan are counted as `changedOrVanishedCount`; unreadable entries as `errorCount`. Nothing is deleted or silently ignored.
- **Progress and cancellation.** The census polls an `isCancelled` closure and throws `StorageCensusError.cancelled`; the UI exposes a Stop Scan button.
- **Clone uncertainty is explicit.** APFS copy-on-write clones share blocks across distinct inodes and cannot be split from `stat`. Clone-backed roots (the content-addressed runtime image store) are **still counted in full** — clones can hold unique blocks — and the report is flagged `isSharedAllocationEstimate`. No subtraction “for sharing”.

APFS behavior observed during testing: files up to ~16 MiB are reported fully allocated (small-file preallocation); real VM disks (16/32 GiB) report true sparse allocation. See the test comment in `Tests/FloeCoreTests/StorageAccountingTests.swift`.

## App wiring / App 接线

`FloeAgent/FloeApp/Settings/StorageDiagnosticService.swift` builds the real root list, including roots the old inspector never scanned:

- `FloeAgent/Environments` (container layers, per-environment sparse Linux disks `LinuxGuest/disks/<id>/disk.img`)
- the sibling `Floe/Runtime/v2` store (blobs/expanded images/VM disks, clone-backed)
- `Materials`, `Canvases`, `MediaProjects`, `CanvasCAD`, `LocalModels`, `PrivateTasks`, `Fonts`, `Attachments`, `GeneratedImages`, `BrowserArtifacts`, `Checkpoints`
- `Caches`/`tmp` are surfaced as the reclaimable estimate, not as user-data categories

Categories show item count plus host-allocated bytes; VM-disk categories additionally show configured capacity. Totals are labeled as estimates whenever clone-backed roots are present, and a partial-scan warning appears when errors/races occur.

## Safe cleanup / 安全清理

`FloeAgent/Sources/FloeCore/StorageCleanup.swift` (engine) + `FloeApp/Settings/StorageDiagnosticService.swift` (registered plan) replace the blanket “delete every child of Caches/ and tmp older than an hour”:

- **Explicit registered candidates only.** Each candidate carries an owner, title, purpose, retention reason and an age cutoff. The current plan has one candidate: stale app `tmp` scratch older than one hour. There is no whole-`Caches` sweep.
- **Retained registrations.** Floe's `Caches/FloeAgent` holds user data and recovery state — the prompt library (user-authored), the diagnostics log and the PDF operation journal. They are registered as *retained* with reasons and can never be candidates.
- **Fail closed.** Every deletion requires an owner probe that positively proves idle (no running environment, no model download, no unfinished media job, re-probed per candidate and per item immediately before removal). Unknown, busy or erroring probes delete nothing.
- **Skip accounting.** Recent items, protected names, symlinks and directories containing actively written children are counted as skipped; a sweep-safety guard rejects any misregistered cache-parent root.
- **Honest results.** Reports deleted / skipped-owner-busy / skipped-protected / skipped-recent / failed counts, the **observed allocated-bytes change** across cleaned roots (explicitly *not* an exact physical reclaim on a clone/sparse volume) and, when measurable, the volume available-space change. Summed file sizes are never presented as freed volume bytes.
- **Eligible estimate.** The “safe to clean” figure is computed with the same owner/age/retention rules at estimate time, so it is not whole-directory math.
- **Cancellation** is honoured between items.

## Tests / 测试

Focused FloeCore tests cover: ordinary files, sparse disks (logical vs allocated), hard links counted once, nested roots, parent/unattributed files, symlinks not followed, hidden files, vanishing files, cancellation; report arithmetic (each bucket counted exactly once, caches in total but not as categories, sparse capacity surfacing); cleanup safety (fail-closed busy owner, only-eligible deletion, skip counters, per-item owner revalidation, cache-parent rejection, retained registrations). FloeApp compilation is part of the full App build.

## Honesty / 诚实边界

- The allocated total may include blocks shared with clone siblings; it is an **upper estimate**, not an exact freeable figure.
- iOS Storage uses an unpublished methodology; Floe does not claim the two numbers must match.
- The `Shared allocation note` in the UI states this explicitly in English and Chinese.
- Cleanup never equates summed candidate sizes with actual reclaimed volume bytes.
