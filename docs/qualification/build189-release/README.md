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
