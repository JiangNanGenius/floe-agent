# Build188 preflight and scope

Candidate1.7.0(188), following failed immutable build187 (tagv1.7.0-beta.44).
No upload or installability is claimed by this preflight record.

- App cover cards now publish the thumbnail's actual source, revision and bounded
  diagnostics on the actionable card. UI qualification reads that existing card,
  rather than making a separate whole-App descendant query. The build187 query
  timed out on both SDK27 device families; its later AX dump contains the child.
  This is a query-scope repair, not proof of a missing image or App deadlock.
- The summary badge and content-source/revision assertions remain. Root inspected
  the retained Word/Excel/PPT component images separately from full-App UI evidence.
- The reviewed staged-copy fixture fix passed both devices in run35314763193.
  That run still failed: iPad mind-map test exceeded120s while WebKit's GPU process
  was unresponsive; it later returned at152.558s. iPhone passed101/101.
- Mind-map screenshot awaits now have a10s callback deadline, retain diagnostics,
  and fail rather than substituting an image or skipping a check. Other functional
  assertions and XCTest's overall timeout remain unchanged. This bounds an
  unbounded await; it does not claim to fix the simulator GPU process.
- Local focused Swift6 typecheck/object checks:6passed (thumbnail service,
  progressive/Office/gate tests, full-App Notes UI test file); the complete
  NativeNotesTests file also typechecks against retained component modules.
  NotesRootView parsing passed. No local App build or simulator was launched.
- Release/controller script suite:436executed,435passed,1existing platform skip.
  Original failure logs and unique recovery artifacts remain retained.

Cloud checks and actual App UI acceptance are required for this changed App source.
The narrow build187 artifact-only recovery controller was not dispatched, and its
source guards intentionally reject this source. Build187's saved device recovery
is not interchangeable with build188. CI lifecycle regression evidence is separate:
build187 SDK27 App regression204/204 includes23IDE GitHub task tests; live App
relaunch against a real remote run remains pending.

## Cloud update — 2026-09-18

Run35317532109 development NativeNotes component passed101/101 on both
iPad and iPhone simulators, with no skips. This includes the staging-resource
case and bounded mind-map snapshot cases. Structured evidence is in
[notes-component.json](notes-component.json). Full-App dual-SDK jobs are still
running; no TestFlight upload or installability is claimed.

Build187 has now ended in failure. Its accepted-SDK App regression passed204/204,
but iPad Notes UI failed while waiting for the imported PDF editor back button
to become hittable. The accepted-SDK iPhone UI passed4 tests with1 existing
skip. Details are retained in
[final accepted-SDK evidence](../build187-release/final-accepted-sdk.json).
This newly collected187 failure has not been declared fixed by188's component
pass;188 full-App UI must establish the outcome.
