# Build191 qualification

Candidate1.7.0(191), tag `v1.7.0-beta.48`, immutable source
`715cbc42e9402cf5ca691291fed5c201e61cf222`.
[Cloud run35337960392](https://github.com/JiangNanGenius/floe-agent/actions/runs/35337960392)
started once by tag push and finished with three UI test failures. See the final result below; early progress notes are historical.

This candidate includes CI policy commit `a7b6dce0`: the complete
NetworkDiagnosticToolsTests suite runs separately from unrelated Swift suites,
using the existing diagnostics wrapper. It remains mandatory. The original
eight-way concurrent race,1.5s deadline, production implementation and all
assertions are unchanged. A coverage check verifies every excluded latency
suite has exactly one separate invocation without a failure bypass.

Build190's original failed SDK27 test remains recorded in
[its evidence](../build190-release/README.md). Its accepted-SDK App204/204,
full-App iPad/iPhone Notes4 passed plus1 existing device-only skip each, and
NativeNotes101/101 each passed. These results do not replace this candidate's
cloud qualification or constitute physical-device acceptance.

No shipping implementation changes beyond all four target build numbers.
No old release tag moves, skipped release gate, or retry of the failed unchanged
workflow. Heavy builds remain cloud-only. TestFlight, prerelease, Feather and
main merge remain separate pending deliverables. Public Beta is not submitted.

Preflight on2026-09-18: script suite444 tests,443 passed and1 existing platform
skip. All four project.yml targets and eight generated build configurations
use191. Generated-project consistency passed after the candidate commit.
No production Swift or UI code changed, so no duplicate local App build ran.

## Initial cloud results — 2026-09-18

The isolated network suite passed13/13; its unchanged eight-way deadline race
completed in0.250s against1.5s. The other five recorded Swift invocations also
exited successfully. This confirms the new invocation passed, without changing
the original build190 failure or proving its scheduler-contention hypothesis.
NativeNotes xcresults independently confirm101/101 passed,0 skipped on each
simulator family. [Structured evidence](early-results.json). Both full-App SDK
qualification jobs remain in progress; no upload or installability is claimed.

## SDK27 iPad search-result failure

The SDK27 App regression passed204/204. The iPad full-App Notes UI subsequently
failed at `testDocumentTabsAndBodySearch` line228: XCTest timed out resolving
the result card for `tap()`. The body-match snippet, result existence and
hittability checks had passed. This path still used a global descendant-text
`firstMatch`, unlike the library-scoped cover helper. The cover test, including
cold relaunch, passed in93.502s. Original job output is retained; recordings
and the other device/SDK results are still pending. No App deadlock or harmless
test failure is inferred from this log alone.

The pending test correction selects that same named notebook card through the
existing library-scoped helper and scrolls the same results grid. All body-match,
existence, hittability, tap and opened-editor assertions and deadlines remain.
It changes no shipping code and does not alter the immutable191 tag.

## Explicit expedited internal distribution

The user selected “upload Build191 first; I will test on device” after being
informed of both SDK27 UI failures. The iPhone failure is the New-button
enabled check in `testPencilToolsAndFocusedLayout`, before writing begins.
The two failures remain recorded; signing and Apple validation remain required.
[Distribution run35343019320](https://github.com/JiangNanGenius/floe-agent/actions/runs/35343019320)
reuses the accepted-SDK artifact from35337960392 without rebuilding. The App
source remains715cbc42e9402cf5ca691291fed5c201e61cf222; dispatch controller
b18b3b1d is separate. No upload success or installability is claimed yet.

The subsequent test-only toolbar query correction scopes New-button lookup to
NotesRootView's navigation bars, retaining the same enabled check and10s limit.
All six focused Swift semantic/object checks pass. It is not part of191.

## Final result and stopped distribution — 2026-09-18

[Final structured results](final-results.json): both SDK App regression bundles
passed204/204, NativeNotes101/101 each device, and accepted-SDK iPad Notes UI
passed4 with1 existing native-Office device-only skip. SDK27 iPad/iPhone and
accepted-SDK iPhone each passed3, failed1, with that same existing skip.

The newly completed accepted-SDK iPhone case
`testWorkspaceImportAndDocumentAssistant` failed its initial10-second
`notes.assistant.restart` enabled check, **before tapping restart**. Its recording
shows the assistant sheet and blue restart control, but that visual observation
does not prove the control was responsive or make the failed assertion pass.
Original logs, xcresults and recordings are retained.

Distribution35343019320 stopped before signing because the accepted-SDK job
failed and no qualified distribution-input artifact was staged. Nothing was
uploaded. The existing unsigned device recovery remains intact. A narrow
recovery controller is prepared with pinned source/run/artifact digests and
unchanged normalization, App regression, signing and Apple validation. It is
disabled by default and has not been dispatched: the user has so far waived
only the two SDK27 failures, and a question about the third failure is pending.
No192 build, retagging, public Beta or production submission occurred.

## Additional waiver and recovery dispatch — 12:49UTC

The user explicitly answered “skip” to the additional accepted-SDK iPhone
failure. All three recorded UI failures are now waived for this internal
device-testing delivery only. [Recovery upload35346684753](https://github.com/JiangNanGenius/floe-agent/actions/runs/35346684753)
uses controller0b97fa4e and the original715cbc42 App, with no compilation.
The recovery policy and related gates passed108 local Python checks and
actionlint; those controller checks are not application UI acceptance.
Signing, Apple processing and group availability remain pending.
