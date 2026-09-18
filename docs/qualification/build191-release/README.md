# Build191 qualification

Candidate1.7.0(191), tag `v1.7.0-beta.48`, immutable source
`715cbc42e9402cf5ca691291fed5c201e61cf222`.
[Cloud run35337960392](https://github.com/JiangNanGenius/floe-agent/actions/runs/35337960392)
started once by tag push; all three normal qualification jobs are running.

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
