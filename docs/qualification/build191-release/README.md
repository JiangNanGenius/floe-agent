# Build191 qualification

Candidate1.7.0(191), tag `v1.7.0-beta.48`.

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
use191. Generated-project consistency is checked after the candidate commit.
No production Swift or UI code changed, so no duplicate local App build ran.
