# Storage diagnostics and safe cleanup / 储存空间诊断与安全清理

<!-- docs-updated: 2026-10-16 -->

Status: implemented in source, **not yet device-accepted**. This document describes the current behavior. The Data management page covers Floe's own data only; iOS Storage remains the authority for the app's system-accounted size, and no guessed cap is shown. Last updated: 2026-10-16 (measured physical extent union through public `fcntl(F_LOG2PHYS_EXT)` with a fail-closed fallback, one shared snapshot cache, a Floe-app-only numeric overview whose details reconcile with the total, and a separate Shared files section).

## Why this exists / 背景

An upgraded device reported Floe's figures far above what iOS Storage showed. The previous inspector already read host-allocated size keys (`totalFileAllocatedSize`), so logical lengths alone do not explain the difference. Local probes then proved one concrete over-counting mechanism: APFS clone families report their full allocated size on every member, so adding the members up counts the same shared blocks several times. The census now measures this instead of guessing, and the page presents only what it can honestly support. The affected device is not reachable from the development host, so device-specific numbers remain unconfirmed; the measurement is privacy-preserving and never deletes user data to produce it.

## The engine / 计量引擎

`FloeAgent/Sources/FloeCore/StorageAccounting.swift`, `StorageCloneAccounting.swift` and `StorageReportBuilder.swift`:

- **Single mutually-exclusive pass.** Overlapping/nested roots attribute each file to the deepest matching root; the walker visits each physical tree once.
- **Exact identity dedup.** Device + inode deduplicate hard links and root overlaps; deduped bytes are reported separately (`sharedSize`) and never added twice.
- **Logical vs allocated.** `logicalBytes` is the file's apparent length as the filesystem reports it (`stat` size). It is **not** the configured or used guest capacity of a VM disk: qcow2/container metadata makes the apparent length deviate from the guest's real virtual size, and the space actually used *inside* the guest can only be measured while the guest runs. `allocatedBytes` uses host-allocated, sparse-aware size. Both are kept and displayed separately.
- **Measured physical extents (active basis).** A narrow C shim calls the SDK's public `fcntl(fd, F_LOG2PHYS_EXT)` and maps each measured file to its backing device runs; the sorted union of those runs is the measured block footprint of the set, so full clones, partially CoW-split families and hard links all resolve to one physical copy, and unallocated holes contribute nothing. Each file is cross-checked against `st_blocks`, and raw device offsets are opaque comparison keys that are never persisted, logged or displayed — only aggregated bytes leave the engine. The union is **all or nothing**: any per-file failure, unsupported filesystem, anomalous mapping or budget overflow withholds the whole union and the report keeps the accepted allocated basis; a partial union is never subtracted. The union counts the data blocks referenced by the measured file set: filesystem metadata and checksums, blocks retained only by APFS snapshots and extra forks are outside it, while blocks shared with files outside the set are still included. It is therefore not the size iOS Storage accounts for, not device usage and not a reclaimable number.
- **Clone accounting (fallback basis).** When the extent union is withheld, the census keeps the previously accepted basis: `getattrlist` with `FSOPT_ATTR_CMN_EXTENDED` exposes APFS private size, clone id, extended flags and clone reference count using public headers only. Pure full-clone families (same clone id and `EF_SHARES_ALL_BLOCKS` on every member) are deduplicated exactly once; measured private bytes are reported as an exclusive lower bound only when every measured file answered the extended query, and a partial-COW union is never fabricated as a subtractive total. Where the query is unsupported, the census falls back to declared clone-root flags and says which figure is measured and which is an estimate.
- **One basis per report.** Totals, per-category figures and the bundle share are slices of the same active basis (measured extents when collected, otherwise the accepted allocated basis); the two are never mixed or added together.
- **Hidden files** are included by default so staging/`.trash`/`.downloads` directories are not silently dropped.
- **Races and errors.** Files that vanish mid-scan are counted as `changedOrVanishedCount`; unreadable entries as `errorCount`; an allocation that cannot be measured is reported as partial. Nothing is deleted or silently ignored.
- **Progress and cancellation.** The census reports measured file counts and polls an `isCancelled` closure; the UI offers Stop Scan and keeps the last valid snapshot on cancellation.
- **No guessed cap.** The engine never caps, subtracts a heuristic or relabels the measured sum to make the page look like a different number; unmeasurable sharing stays visible as a limitation.

## Snapshot cache / 快照缓存

One shared `StorageSnapshotCenter` (`StorageDiagnosticService.shared`) renders the last valid totals immediately:

- 600 s freshness for automatic appearance refreshes; an explicit pull-to-refresh always scans.
- A real mutation (cleanup completion, canvas cloud release, font or model changes, environment changes) invalidates the snapshot so the next pass scans once.
- Failure keeps the last good snapshot with a short retry cooldown; cancellation keeps the last snapshot; a dismissed page does not kill a cache-filling scan.
- The snapshot persists atomically (counts and categories only — never paths, names or contents) and is discarded when the schema, accounting version, exact roots or app build no longer match. The accounting version is `2026-10-16.extent-union.v4`: a build upgrade discards the older allocated-only snapshot once instead of continuing to serve its inflated total.

## App wiring / App 接线

- The census covers `Library`, `Documents` and `tmp` plus the Floe roots (Environments/container layers and per-environment sparse disks, the sibling `Floe/Runtime/v2` store, Materials, Canvases, MediaProjects, CanvasCAD, LocalModels, PrivateTasks, Fonts, Attachments, GeneratedImages, BrowserArtifacts, Checkpoints). `Caches`/`tmp` are surfaced as reclaimable file capacity, not as user-data categories.
- **Overview (Floe data only).** No device-wide total, free-space row or iOS Storage placeholder is shown. The top figure is the same snapshot's mutually-exclusive total (installed bundle plus Floe data categories, with shared/clone-capable data already counted once), followed by the installed bundle, the user-data figure and the cleanup-candidate estimate; the expanded details reconcile with these numbers. No “at least / approximately” labels are used.
- **Shared files.** Floe's shared data (VM/runtime images and shared resources) appears in its own section as the measured file capacity of what the census identified as sharing-capable. It is already part of the total above exactly once and is never added again; the figure is file capacity, so it is not additional physical usage and not free space that can be reclaimed.
- **File capacity details.** Per-category figures on the same basis (they sum to the total shown above), item counts, the measured exclusive lower bound when available and scan diagnostics stay one tap away; the ordinary screen keeps technical notes out of view. VM-disk categories show apparent size with a note that it is not configured guest capacity.
- Totals are labelled partial when races, unreadable entries or unmeasurable allocations occurred.

## Safe cleanup / 安全清理

`FloeAgent/Sources/FloeCore/StorageCleanup.swift` (engine) + `FloeApp/Settings/StorageDiagnosticService.swift` (registered plan):

- **Explicit registered candidates only.** Each candidate carries an owner, title, purpose, retention reason and an age cutoff. The current plan has one candidate: the task-owned scratch root `tmp/FloeAgent/scratch` (purpose-prefix filter, a 24-hour quiescence cutoff, per-path leases and atomic deletion claims). A whole-`tmp` sweep and a whole-`Caches` sweep are never candidates.
- **Retained registrations.** Floe's `Caches/FloeAgent` holds user data and recovery state — the prompt library (user-authored), the diagnostics log and the PDF operation journal. They are registered as *retained* with reasons and can never be candidates.
- **Fail closed.** Every deletion requires an owner probe that positively proves idle (no running environment, no model download, no unfinished media job), re-probed per candidate and per item immediately before removal. Unknown, busy or erroring probes delete nothing.
- **Skip accounting.** Recent items, protected names, symlinks and directories containing actively written children are counted as skipped; a sweep-safety guard rejects any misregistered cache-parent root.
- **Honest results.** Reports deleted / skipped-owner-busy / skipped-protected / skipped-recent / failed counts, the **observed allocated-bytes change** across cleaned roots (explicitly *not* an exact physical reclaim on a clone/sparse volume) and, when measurable, the volume available-space change. Summed file sizes are never presented as freed volume bytes.
- **Eligible estimate.** The “Files available to clean” figure is computed with the same owner/age/retention rules at estimate time, in file-capacity terms; it is not whole-directory math and not a promise of reclaimed bytes.
- **Cancellation** is honoured between items.

## Tests / 测试

The engine's behavior is covered by focused checks executed against the patched sources during development: ordinary files, sparse disks (logical vs allocated), hard links counted once, nested roots, parent/unattributed files, symlinks not followed, hidden and vanishing files, cancellation, report arithmetic; pure-clone family dedup, measured private bytes, unsupported-volume fallback; snapshot cache reentry, invalidation, failure cooldown, persistence and store privacy/corruption handling. The App-hosted storage suites, full-App build and device acceptance remain with the integration owner. FloeApp compilation is part of the full App build.

## Honesty / 诚实边界

- File capacity may include blocks shared with clone siblings more than once; it is an **upper estimate**, not additional physical usage and not an exact freeable figure.
- iOS Storage uses an unpublished methodology; Floe does not claim the two numbers must match, and the page never caps or guesses a number to make them line up.
- The Shared files section and the data-management notes state this explicitly in English and Chinese.
- Cleanup never equates summed candidate sizes with actual reclaimed volume bytes.
