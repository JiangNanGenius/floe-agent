# Build190 preflight — bounded Notes UI queries and simulator readiness

Candidate1.7.0(190), tag `v1.7.0-beta.47` (immutable source recorded after commit).
This changes test infrastructure and the build number; the shipping Notes
implementation remains that of189.

Build189 passed accepted-SDK App204/204 and both full-App Notes device legs
(4 passed,0 failed,1 existing native-Office/device-only skip each). SDK27
App204/204 and NativeNotes components101/101 each passed. Its SDK27 iPad
cold-relaunch query and iPhone initial App launch failed. Both failures,
recordings, process samples and unique device recovery packages are retained:
[189 final evidence](../build189-release/README.md).

The iPad failure used a global `app.buttons…firstMatch`; the recording shows
rendered covers and updating times while the sample is in XCTest's snapshot
filtering. The new query starts at the Notes library ScrollView and uses an
indexed match. It still requires the same named card to be reachable, a real
allowed content source, an incremented saved revision, open/return, and
regeneration after cold relaunch. No test timeout, assertion, skip policy or
executed-failure retry rule changed.

Each normal release UI leg now waits for the selected simulator to finish
booting before XCTest begins its App-launch deadline. Preparation is bounded
to180s, keeps original boot output, fails closed and never pre-launches the App.
It does not delete data or operate on other simulators.

Local verification: all6 Swift semantic/object checks passed, including the
actual full-App UI test source. Python script suite443 tests:442 passed and
1 existing platform skip. The first script-suite run failed because its shell
fixture did not implement the new boot-preparation command; that evidence is
retained. The fixture now models both boot success and failure, and a new
executed-shell case proves a preparation failure cannot start XCTest.
Project generation updates all four target build numbers and their generated
configurations. No local full-App build, simulator or paid worker was used.

Cloud results remain required. No190 upload or installability is claimed.
