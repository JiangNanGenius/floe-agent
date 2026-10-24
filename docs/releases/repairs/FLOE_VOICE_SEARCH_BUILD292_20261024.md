# Voice and search repair — 1.7.51 (292)

## Scope and source

The repair covers continuous-voice startup and playback, enhanced recognition model residency, speech controls and table reading, Volcengine search decoding, and configuration-sync status. The immutable annotated tag `v1.7.51` binds App source `ba5e075be1f6ae3f30ec76dbceec3b8aca760744`. Subsequent feed and delivery-document commits do not change that source or its binaries.

- Continuous voice uses the configured recognition service, waits for real microphone buffers, and fences cancelled sessions and late callbacks. Audio ownership and recognition recovery are bounded.
- After the first foreground request, the enhanced recognition model can stay loaded for reuse. Stopping recognition releases the microphone and session; backgrounding or resource pressure can retire the model. A retired cold load cannot silently remount itself.
- Speech speed and pitch apply to actual playback. Pause, interruption, playback progress and completion use playback state; queued progress from an old playback epoch cannot enter a new turn.
- Online voices have a picker, and saved keys require authentication before reveal. Table reading preserves header/row relationships and reads the final response rather than tool activity.
- Volcengine decoding accepts its `Result.WebResults` response shape and distinguishes an empty successful result from a provider error. Sync status refreshes when a previously unavailable key becomes available.

## Verification

| Boundary | Actual result |
| --- | --- |
| Swift 6 full App and AppTests compilation | Passed on Xcode 27.1, build 27A9275 |
| Canonical reused iPad Simulator, App-host behavior tests | 175 passed; zero failures and skips |
| iPhoneOS Release build and archive | Passed; arm64 device executable, SDK 27.1; App and four extensions report 1.7.51 (292) |
| Native settings UI | Speed/pitch controls and nine Volcengine voice choices inspected; final-source UI hashes rechecked |
| Downloaded public unsigned IPA | Publication verifier passed: exact source/tag, sidecar, remote digest, arm64 iOS device binary and latest release |

The original failed test run and build diagnostics were retained. The first App-host run exposed a retired-model reload defect; the implementation and regression coverage were corrected before the final successful run.

Physical devices were returned to the user and were not reused for patched acceptance. Real-device microphone behavior, audible playback, latency and actual model memory are **not measured by this qualification**. The user's approximate 1 GB estimate is not an admission threshold or a measured footprint. Simulator tests and UI checks do not establish those physical results.

## Delivery readback — 2026-10-24 UTC

| Deliverable | Verified state |
| --- | --- |
| TestFlight internal | Apple `VALID`, unexpired, `IN_BETA_TESTING`, existing Floe QA group; bilingual notes verified |
| TestFlight external | Submitted once to existing publictest1; App Store Connect independently shows **Waiting for Review** for 1.7.51 (292), with Floe QA and publictest1 attached |
| GitHub App Release | Stable, published, latest; unsigned IPA, checksum and minimal provenance only |
| Feather | Awaited reusable publication job passed; live feed URL, version, build, source and checksum match the published IPA |

External TestFlight approval and availability are pending Apple review. This delivery does not publish a production App Store version.

- [Stable Release and unsigned installation package](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.51)
- [Feather source](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json)
- [Signing and internal TestFlight run](https://github.com/JiangNanGenius/floe-agent/actions/runs/40080073612)
- [Unsigned publication and awaited Feather run](https://github.com/JiangNanGenius/floe-agent/actions/runs/40081344090)

Unsigned IPA: `Floe-Agent-1.7.51-build292-unsigned.ipa`, 812,094,430 bytes.

SHA-256: `2f5b4bf3d1f14a48699aba036dbb99db87849de31c5dce21fd38b11b12696789`.

## Integration and cleanup

All repair commits were merged and pushed to `main`; the task-owned local and remote branch was removed after proving it merged and unoccupied. The release tag remains unchanged. The subsequent Feather commit was fast-forwarded into the checkout.

Removed only this round's finished Simulator/device compiler outputs, duplicate archive and prequalification copies, redundant unpacked App/raw ZIP, and the private transfer draft. Measured free-space increases total 17,617,305,600 bytes (about 17.6 GB) across the two volumes. APFS sharing means apparent file sizes differ from reclaimed space.

Retained the downloaded unsigned IPA/checksum, verified recovery transport, matching symbols, success/failure logs, test results, source bindings and UI evidence. The prior rollback build, user recordings, credentials, other worktrees and Simulator app data were preserved. No Simulator remains booted by this task.
