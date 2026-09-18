# Build189 preflight: Notes card accessibility ownership

Candidate1.7.0(189), intended tag `v1.7.0-beta.46`.

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
