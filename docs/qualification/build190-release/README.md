# Build190 preflight — bounded Notes UI queries and simulator readiness

Candidate1.7.0(190), tag `v1.7.0-beta.47` source
`5183112af7388b2a0c8742057176e584e76cc733`.
[Cloud run35329733708](https://github.com/JiangNanGenius/floe-agent/actions/runs/35329733708)
was started once by the immutable tag push.
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

## SDK27 Swift gate failure — 2026-09-18

Run35329733708 SDK27 job105551136529 failed before building its full-App UI
host. `NetworkDiagnosticToolsTests.concurrentDeadlines` measured1.947162125s
against the unchanged1.5s requirement. The177-test run reported
1 issue; the original diagnostics and job log are retained privately.
The other SDK and component jobs are allowed to finish for evidence.

The failed log has many unrelated suites finishing around2s. A small local
probe copied the original deadline helper and first four tests verbatim,
substituting only the `FloeError` enum to avoid rebuilding the full dependency
graph. All four passed; the eight-way race completed in0.106s. This probe is
not full-module or cloud acceptance and does not prove the original failure
harmless. Scheduler contention remains a hypothesis.

The proposed CI correction runs the complete network-diagnostics suite in a
separate mandatory invocation, like the existing JavaScript deadline suites.
The eight-operation concurrency,1.5s assertion and all other assertions remain
unchanged. A workflow-coverage test requires every excluded latency suite to
appear exactly once as a separate invocation with retained diagnostics and no
failure bypass. Do not rerun the original unchanged workflow or relabel this
failed run as a pass; wait for the remaining UI evidence before fixing the
next immutable candidate.
