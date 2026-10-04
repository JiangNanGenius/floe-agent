# Floe Agent 1.7.5 (Build 246) — qualification failed

Immutable tag `v1.7.5` fixes source `242b481ad78c3185df4b8cc60c91f5902683183c`. The [normal release run](https://github.com/JiangNanGenius/floe-agent/actions/runs/37176842874) completed with failed SDK 27, accepted upload-SDK and independent NativeNotes jobs. It did not sign or upload Build 246, publish an App GitHub Release or distribute this build through Feather or TestFlight.

The accepted upload-SDK device build completed and was retained before simulator qualification as the `accepted-sdk-device-recovery-1.7.5-build246` Actions artifact (artifact ID `11293998719`, 735,050,516 bytes in GitHub storage). Both App jobs then failed to compile the test host: `IDELanguageRunPolicyTests.swift` did not handle the new `.tripleCore` case in an exhaustive switch. This is a test-source regression; the device-build result does not bypass that required gate.

The independent NativeNotes job compiled, but its linked-map assertion expected exact OCR for `Trade gains`, and its UI test looked for that native map topic under `webViews`. The cloud screenshot text included the visible branch as `<Triade gains`; the stale UI query failed on both device families. Strict Quick Look diagnostics separately reported Word cover timeouts as non-gating diagnostics. All original results and screenshots remain attached to the failed run.

Build 247 corrects those tests. Focused local iPad and iPhone linked-map unit and UI checks passed, and the Xcode 27 App test-host build passed. These checks do not convert Build 246 into a release; a new immutable tag and independent cloud qualification are required.
