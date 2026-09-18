# Build189 preflight: Notes card accessibility ownership

Candidate1.7.0(189), immutable tag `v1.7.0-beta.46`, source
`ba0271b247fd233ebfed9df3bd2353a9242d0cc7`.
[Cloud run35322816608](https://github.com/JiangNanGenius/floe-agent/actions/runs/35322816608)
was started by the tag push with the normal release gates.

Build188's SDK27 full-App Notes UI failed on both device families while finding
the Word library card. The iPad query timed out; iPhone could not reach the card.
The retained iPad recording shows actual Word/Excel/PPT content summaries, so
the failed query alone is not evidence that the cover images were missing.
The same run's body-search trace exposes the actionable document button as
`notes.thumbnail.notebook.预览验收`, rather than its enclosing `notes.card`
identity. This provides evidence of nested accessibility metadata propagation.

The correction lets embedded thumbnails omit their standalone accessibility
element altogether. The library retains the native Button and visible text
semantics, including the body-search excerpt. Its identifier and actual cover
state remain on the Button. Standalone thumbnail hosts retain their existing
accessibility representation. Image generation, cache lifecycle and all cover
source/revision/rename/reopen/cold-launch assertions are unchanged.

Six focused Swift6 typecheck/object checks passed; NotesRootView parses. No
local full-App build or simulator was used. Cloud full-App UI validation is
still required and is not implied by these checks. Neither this candidate nor
the retained188 unsigned recovery package has been uploaded to TestFlight.

Original188 evidence: [recorded library frame](../build188-release/ipad-cover-query-failure.png).
Cloud raw logs, xcresult bundles and recordings remain in the private evidence
store. The frame predates completion of CAD covers and is not CAD acceptance.

## Cloud checkpoint — 2026-09-18

- NativeNotes component: iPad101/101 and iPhone101/101, zero skips
  ([structured result](notes-component.json)).
- SDK27 App regression:204/204, zero skips
  ([structured result](sdk27-app-regression.json)).
- Exact-source accepted-SDK unsigned device recovery retained; source SHA,
  SHA-256, app/extension IDs and versions verified
  ([recovery record](device-recovery.json)).

- Accepted-SDK App regression:204/204, zero skips
  ([structured result](accepted-app-regression.json)).

The SDK27 iPad full-App UI gate failed after the cover test relaunched the
App. Its live job log confirms all seven initial content-cover checks passed,
including DXF and DWG, followed by a successful Word rename with revision
1 → 2 and open/return cycle. The first card query after cold relaunch then
timed out at `NotesWorkspaceImportUITests.swift:390`. This narrows the remaining
failure; it does not establish cold-launch acceptance or its root cause.
SDK27 iPhone has completed the cover/relaunch case successfully in the live
log. Remaining tests and the completed diagnostic bundles are still pending.
The accepted-SDK iPad UI step passed; its structured results will be retained
when the parallel job publishes them. No retry or assertion change was made.

These results do not establish TestFlight upload or availability.

## Final result and retained failure diagnosis

Run35322816608 ended **failure**. The accepted-SDK job passed: both iPad and
iPhone UI results are4 passed,0 failed,1 existing device-only Office skip.
SDK27 has3 passed,1 failed,1 Office skip on each family. Its iPad failed the
cold-relaunch card query; iPhone failed the first App launch in the body-search
case, before that case could interact with Floe. Its subsequent cover test,
including cold relaunch, passed. All four Pencil flows passed this time;
this does not prove the older188 intermittent panel-close failure is fixed.
See [structured final results](final-ui-results.json).

The SDK27 iPad recording at120s and170s shows the library rendering covers and
updating relative time while the XCTest query is stalled. The process sample
at08:54:48Z shows the main thread inside
`XCTElementQuery._firstMatchingSnapshotForInput` /
`XCTFilteringTransformerIterator.nextMatch`, interleaved with Quick Look and
SwiftUI work. It does not establish an application deadlock. A later blank
watchdog screenshot alone would give an incomplete account; both originals
remain in the private artifact store.

- [SDK27 iPad during the failed query](sdk27-ipad-during-query-timeout.png)
- [Accepted-SDK iPad covers after successful relaunch](accepted-ipad-covers-after-relaunch.png)

The next candidate scopes the card query to the Notes library and uses indexed
matching rather than a global lazy first match. Simulator boot completes in a
bounded recorded preparation step before XCTest's App-launch deadline starts.
It does not pre-launch the App or retry executed failures. All cover sources,
revision, rename, open/return, cold-relaunch and dual-device assertions remain
required. This is a proposed harness correction, not a retrospective pass.
No189 signed upload, GitHub prerelease or Feather release occurred.
