# Floe Agent 1.7.8 (Build 249) — qualification failed

Immutable tag `v1.7.8` fixes source `fbd0634221256325e0ccbda9cfff5fbbb9202752`. The [normal release run](https://github.com/JiangNanGenius/floe-agent/actions/runs/37187480974) passed the development-SDK Swift package checks and NativeNotes component qualification, but failed five `FloeApp.LocalShell` tests in the development-SDK App regression gate. The accepted-SDK job passed its iPad Notes leg; its final status remains in the linked run. The normal release gate prevents signing and TestFlight upload.

The cold `pkg update` command exceeded the test's five-second execution budget, and the partial-output timeout began before its first output on a loaded simulator. An interactive session then produced no visible output within the test's five-second poll and held the process-wide shell gate while closing, causing two following commands to report busy. Build 250 increases only these bounded cold-start test windows and makes interactive `closeSession` wait for the native worker to release the gate, up to ten seconds. The focused local `FloeApp.LocalShell` suite passed 11/11 after this change. Physical device shell behavior remains unverified.

The accepted-SDK device build is retained in the failed workflow as a recoverable input only; it was not signed or uploaded as this candidate.
