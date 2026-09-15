# Concurrent human and Agent editing

Implementation checkpoint: 2026-09-15. Full-App and device qualification are still required before claiming release acceptance.

## Interaction contract

Both parties may continue editing. A short managed-file transaction protects comparison and commit; no editor is locked for the duration of an Agent run. Editors retain their opened version and draft. A save checks the current file, preserves recoverable edits and acknowledges success only after committing.

- **Text / IDE:** three-way line merge with the opened, human and current disk versions. Independent changes are combined. Overlapping regions require a choice, with an editable combined result before saving. Reviewing does not reserve the file: another write causes a fresh conflict. IDE also checks that the open draft still matches the reviewed draft. Failed saves keep the editor dirty.
- **Deleted / unreadable text:** save the recovery draft first. Report its path, retain the editor content and leave the original absent/unchanged. Never recreate a deleted original without an explicit user action. Recovery copies are content addressed and never overwritten unless the existing digest proves they are identical.
- **Office:** settle the native working copy, retain recovery, and compare the original hash during coordinated replacement. On conflict, compare immutable copies of the current original and editor draft, preview or export either. Export does not advance the original baseline or count as resolving its save. Do not concatenate ZIP/XML packages or infer formatting compatibility from equal visible text.
- **Notes:** compare the actual affected object against the editor baseline. Independent text elements, ink and metadata can retain unrelated changes. Replacing a page/map, deleting branches or changing structure requires a broader unchanged baseline. Agent tools still require `notes.read` and the exact expected revision. A conflicting UI edit creates a durable Notes copy, retaining its resource references and discoverability. Review lets the user keep both versions or apply the original requested edits to the reviewed original version. A later original edit requires another review; a later edit to the recovery copy prevents application of an obsolete batch.

Handwriting captures the baseline loaded into the Pencil canvas at gesture start. Autosave coalesces strokes against that baseline and advances it only after its own successful commit. A single atomic `.inkdraft` envelope retains ink and baseline together for restart recovery. Older `.drawing` recovery files have no trustworthy baseline and therefore create a separate reviewable copy rather than overwriting the original.

Notes persists pending conflict reviews in the versioned SQLite store (`notes.v5.edit-conflicts`) and reloads them after restart. Applying a review checks both original and recovery revisions and removes the pending record in the same document transaction; keeping both removes only the review record. Recovery documents remain in the library. Recent baseline lookup is limited to 32 history rows. An unavailable baseline fails without guessing; the originating editor keeps its draft. Full historical cross-document merging is not claimed.

## Resource and lifecycle bounds

IDE files are limited to 4 MiB of UTF-8 text. Original-text retention is bounded to 16 MiB across reads. Diff work is bounded to two million LCS cells; absent or oversized baselines use an explicit whole-file decision. Conflict previews are shortened, while the original text and saved recovery stay complete.

Notes copies are ordinary long-lived documents, independent of chat deletion. Office comparison exports are disposable immutable snapshots; closing comparison removes only those snapshots, not working/recovery/original files. Space or I/O failures remain errors; never report a preserved copy or successful save unless its write succeeded.

The managed transaction lock coordinates Floe's managed writers. Arbitrary native scripts, external apps and cloud file providers must cooperate with file coordination/version checks; it is not a kernel-wide lock or security sandbox. Atomically replacing a file does not by itself protect an uncooperative writer's intent.

## Evidence

- Real Swift merge smoke: 114,310 non-overlapping edit combinations, overlap choices, insertion/deletion and CRLF passed locally.
- Four BrowserFS/native bridge tests passed locally.
- Native workspace suite: 7/7 passed on CI 34960853663, source `0fd21a32c3e06c75bc58a84f15b31ea92ffafc0e`; artifact 10393446450. Includes 20 concurrent guarded writers with exactly one winner, late edits, repeated recovery and deleted original.
- Real pinned CodeBlitz browser prototype accepted a reviewed draft, rejected a stale draft, saved the combined text and became clean. This used synthetic browser storage, not the app's native disk bridge.
- Added Office current-version snapshot and Notes independent/overlapping/deleted-page/baseline-history/review-restart tests await the next cloud source. Native conflict sheets, iPad/iPhone interactions, Office rendering and restart recovery require full-App verification.
