# Floe 1.7 TestFlight delivery

## Current delivery: 1.7.0 (172)

**Available in the existing internal Floe QA group.** Apple `VALID`, unexpired, one private internal group and `IN_BETA_TESTING` were verified at 2026-09-14 17:52:18 UTC. English and Simplified Chinese notes were written and read back. [Availability evidence](evidence/floe-1.7/release-172/TESTFLIGHT_AVAILABLE.json).

Source: `fb86fef896d41871fa98c8871237606f56c5ff39` / `v1.7.0-beta.29`. Direct packaging policy: `9c741b0`; [successful build/upload](https://github.com/JiangNanGenius/floe-agent/actions/runs/34870170373), [group/notes preparation](https://github.com/JiangNanGenius/floe-agent/actions/runs/34877274179), [availability verification](https://github.com/JiangNanGenius/floe-agent/actions/runs/34877319188).

SDK 27 source qualification passed 1,270 Swift executions, 159 full-App regressions and the Notes UI case on iPad and iPhone. The direct Xcode 26.6 / SDK 26.5 uploader built, validated and signed the same app source; simulator qualification was explicitly waived for this expedited delivery. Original accepted-SDK selector failure and earlier attempts remain recorded. Physical-device checks belong to the user. Full package/model capability delivery remains incomplete. Public/external TestFlight review and production App Store release are not part of this delivery.

[GitHub Beta 29](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.29) supplies a separately qualified SDK 27 unsigned IPA; [Feather instructions](FEATHER_SOURCE.md) describe that developer-signed installation route.

Main was fast-forwarded to the delivered integration. Task-owned merged branches were removed; the independent Office and occupied shell branches remain. [Branch cleanup](evidence/floe-1.7/release-172/branch-cleanup.json). The public [Feather feed check](evidence/floe-1.7/release-172/feather-published.json) returned HTTP 200 for the source, icon and IPA.

## September 15 repair candidate — not yet delivered

Build 176 / `v1.7.0-beta.33` / `b8c1fc0494a08e49af1a092b14df11ee74580554`
started [initial CI qualification](https://github.com/JiangNanGenius/floe-agent/actions/runs/34949420611)
and [release qualification/build](https://github.com/JiangNanGenius/floe-agent/actions/runs/34949491542).
The initial test-host compile failed because a new test omitted a module import.
That test-only correction is in `1d86b285`; [follow-up CI](https://github.com/JiangNanGenius/floe-agent/actions/runs/34951710478) is running. The App files are unchanged and beta.33 remains immutable; final delivery waits for qualification.
It adds live document refresh, dedicated conversation restart and a full-height iPad assistant column.
Upload and Apple availability remain pending; the installable delivery above remains build 172.
[Build-specific notes](RELEASE_NOTES_1.7.0_BUILD_176.md) record remaining scope.

Build 175 / `v1.7.0-beta.32` / `8958d8f1482c3236f73172076b76adc83da86f5f`
passed 172/172 App regressions and its iPhone Notes case. The iPad case exceeded
its 180-second allowance. The release was cancelled before upload to include
the owner's additional document-assistant requirements. The accepted-SDK device
artifact `10388835194` remains in [run 34945701373](https://github.com/JiangNanGenius/floe-agent/actions/runs/34945701373).
[Original results](evidence/floe-1.7/build172-repair/app-build175.json).

Build 174 / `v1.7.0-beta.31` / `aa8e42708157a54aa9cbc083a484c00a882a10b3`
was deliberately stopped before upload after the real Agent demonstration exposed
empty continuation IDs overwriting a valid tool identity. Its accepted-SDK device
build was preserved as `accepted-sdk-device-recovery-1.7.0-build174`, artifact
`10386910401`, in [run 34941785251](https://github.com/JiangNanGenius/floe-agent/actions/runs/34941785251).
This is a recovery artifact, not a delivered TestFlight build. The tag remains immutable.

Build 173 / `v1.7.0-beta.30` / `316251adcba91c94bd96ab9accf9cba72da59f95`
was not uploaded. Its SDK 27 localization suite rejected the bare key
`Floe 助手与思维导图`; the accepted-SDK build was then cancelled to avoid
finishing an obsolete candidate. Build 174 gives the same bilingual label the
namespaced key `notes.office.assistantAndMindMaps`, with no weakened assertion.
The original [failed run](https://github.com/JiangNanGenius/floe-agent/actions/runs/34939310493)
and immutable tag remain available. Local checks passed all 903 bilingual keys
and six release version/test-host contracts; final cloud validation is separate.

## Earlier checkpoints (historical states)


## Build 172 direct-upload candidate

The user requested a new TestFlight build for personal device testing and waived iPad/iPhone simulator qualification as an upload gate. [Direct build and upload](https://github.com/JiangNanGenius/floe-agent/actions/runs/34870170373) uses immutable tag `v1.7.0-beta.29`, source `fb86fef896d41871fa98c8871237606f56c5ff39`. It retains the unsigned device artifact before signing and still requires bundle/profile validation and Apple's upload validation. Availability below stays at build 156 until actual Apple processing and Floe QA visibility are verified.

The same build 172 source separately passed 1,270 Swift test executions and 159 SDK 27 App regressions. Its original SDK 26 device and simulator builds passed, but a duplicate simulator-name selection error stopped tests before execution and prevented that workflow from retaining the device package. These outcomes remain distinct from the direct uploader.

Build 172 upload succeeded at 2026-09-14 17:25:50 UTC. Apple initially reported `PROCESSING`; [upload receipt](evidence/floe-1.7/release-172/testflight-upload.json). This is not yet an installability claim.

## Feedback repair — uploaded, processing pending

The `codex/floe-156-feedback-repair` branch contains the September 14 fixes and subsequent content-search/workspace-import additions. Build 156 below is still the last verified delivery. New source builds, component tests and screenshots do not establish a new TestFlight release. Current gates and evidence are tracked in [the feedback repair record](FLOE_156_FEEDBACK_REPAIR.md); physical-device checks remain with the user.

## Internal delivery — 2026-09-14 (Australia/Sydney)

**Available: 1.7.0 (156), internal Floe QA TestFlight.** Apple `VALID`, unexpired, exactly one existing private internal group, and `IN_BETA_TESTING` were confirmed at 2026-09-13 15:15:02 UTC. English and Simplified Chinese beta notes were written and read back. [Availability evidence](evidence/floe-1.7/release-156/TESTFLIGHT_AVAILABLE.json).

- App source: `65969b8f04e67269a92b899a55620ff469d96322`, immutable tag `v1.7.0-beta.13`.
- Distribution policy: `52312222565c7cec7b8036dc2bb4ed6da077b6a9`; actual Xcode 26.6 (17F113), SDK 26.5.
- [Upload 34762764702](https://github.com/JiangNanGenius/floe-agent/actions/runs/34762764702), [notes/group 34764956759](https://github.com/JiangNanGenius/floe-agent/actions/runs/34764956759), [availability 34765022410](https://github.com/JiangNanGenius/floe-agent/actions/runs/34765022410).
- Build ID: `a75a56dc-6e83-4616-9739-966b72dbccd3`; signed IPA SHA-256: `5cd7ed2a7d98347bed15d9c2b363faad9092d088253ef841fc1ba2e3338180ff`.

SDK 27 source qualification passed 1244 Swift executions and 135 App regressions. The same source also passed the accepted-SDK build and 135 App regressions. Distribution recovery retained those exact-source tests and binaries, verified their provenance and changed only reviewed bundle packaging before signing. All 148 executable files remained unchanged before resigning; 16 packaging/guard tests passed. The beta-group reader additionally passed four targeted tests and actual API readback. [Recovery history](evidence/floe-1.7/release-156/distribution-recovery.md) retains the initial pnpm/libssh2 validation failure and subsequent dash processing failure.

This is an internal beta, not completion of every item in the 1.7 plan. Physical iPad/iPhone checks belong to the user after installation. Full package/model delivery and long-media/device acceptance remain open. No production App Store or public GitHub release was published.

Build 155 was cancelled during dependency preparation after a local reproduction found its test expected data depended on the mutable working lock. Build 156 reads the committed test expectation. All eight tests, pin checking and license generation pass for the combined lock, actual cloud host lock and its legacy serialization (24 test executions, byte-identical inventories). No upload occurred for 155.

Build 156 now supersedes the earlier build 152 source qualification: both SDK paths passed their App gates. The latest Notes component screenshots and SDK 27/26 iPad/iPhone evidence are from [`4550b6d`](https://github.com/JiangNanGenius/floe-agent/actions/runs/34742130370); component qualification is distinct from full-App and physical-device acceptance. Final TestFlight text and checks are tracked in [the release description](RELEASE_NOTES_1.7.0.md).

Apple processing, beta notes, the existing internal Floe QA group and `IN_BETA_TESTING` have now been verified for build 156. Physical-device checks belong to the user after installation. After verified delivery, the integration was fast-forwarded into `main` and pushed. Four fully merged local/remote branches were removed; the two branches with independent work and the occupied shell qualification worktree were preserved. See [cleanup evidence](evidence/floe-1.7/release-156/branch-cleanup.json). No public App Store release is included.

## Build 154 — beta.11

Build 153 / `1ae0364` / run `34751318198` failed the early generated-project check because the checked-in Xcode project retained build 152. Build 154 regenerates the project to match all four version declarations. No application upload occurred for 153.

## Build 153 — beta.10

Candidate 153 fixes release tooling after build 152 passed 1244 Swift test executions, the SDK 27 simulator Release build and 135 App regressions. Run [34748849626](https://github.com/JiangNanGenius/floe-agent/actions/runs/34748849626) then failed in lock-file parsing during license inventory generation; no upload occurred. The new parser supports SwiftPM v1/v2/v3 and checks normalized pins against the committed lock. Five parser regressions pass. Existing candidate tags remain immutable.

## Earlier candidates

This is an internal beta candidate, not completion of the full 1.7 upgrade plan.

- Immutable source: `d587a0e7eef1f4bb831e42e7a28d452d41eba79b`.
- Tag: `v1.7.0-beta.1`; local tag/version/extension/build preflight passed.
- Cloud archive/upload workflow: [34707145277](https://github.com/JiangNanGenius/floe-agent/actions/runs/34707145277).
- Audience to verify after Apple processing: existing internal **Floe QA** group.
- Build 144 candidate was cancelled before upload: full-App CI 34706721636 found a missing `await` in the actor-isolated font import adapter. Build 145 / beta.2 includes the fix; cloud verification remains required. No uploaded build or TestFlight visibility is claimed yet.
- Beta tags do not automatically publish a public GitHub release. No production App Store release is requested.

## Included changes

- Workspace-owned environment creation, settings inventory and measured storage; session/project ownership, rebuild checks, CAS durability, template copies and journaled package promotion.
- Persistent Node worker host with cwd/environment/stdin routing, output bounds, timeout and cancellation; pinned runtime and npm/pnpm/yarn inputs.
- Real basic video/audio processing; workspace video workbench with trim, crop, rotation, speed and manual timed subtitles through pinned MIT VideoEditorKit. Edit parameters persist; exported files are reopened and checked.
- Lower-left sidebar contains the settings button without the account label/avatar.
- Bilingual introduction and user guides include retained, clearly labelled development screenshots.

## Recorded qualification

- 42 focused host tests: 15 environment, 16 package, 9 media, 1 job persistence and 1 signed Skill catalog.
- 9 native iOS Simulator Node bridge cases plus 4 Swift adapter checks; 4 host Node tests.
- Native editor model save/reopen and output smoke; Chinese caption export verified before/during/after its interval with pixel evidence.
- Repeat promotion of the same package tested separately after the 42-test checkpoint.

These do not replace the full application tests or physical-device checks.

## Still open

- All 15 model capability classes need actual runners/weights and per-device output, latency and memory qualification; 33 candidate reviews are not runnable-model evidence.
- Official package-pool production versions, complete dependency promotion/rollback/concurrent installation and recovery UI remain incomplete.
- Shared Agent/workbench task queue, chat-attachment handoff, full environment dependency migration/rebuild and complete long-media/background/device acceptance remain incomplete.
- Source qualification, signed distribution, Apple processing and internal availability have passed; physical-device acceptance remains with the user.

See [implementation status](FLOE_1_7_IMPLEMENTATION_STATUS.md), [compatibility matrix](FLOE_1_7_QUALIFICATION_MATRIX.md), [migration and recovery](FLOE_1_7_MIGRATION.md), and [screenshots](evidence/floe-1.7/SCREENSHOTS.md).

Build 145 / beta.2 was also cancelled before upload after expanded native shell
qualification reproduced unsafe cancellation of an infinite loop. Build 146 /
beta.3 uses cooperative interpreter-thread cancellation. Nine commands plus
interactive input/close pass in both Debug and Release minimal native Apps,
including worker termination, unknown command, three-stage pipe, timeout and
execution after cancel. Full application qualification remains separate.

Build 146 / beta.3 was cancelled before upload to complete the exposed audio
editing and frame-utility paths. The next candidate adds bounded audio editing,
real per-input mix gains, verified PNG/JPEG batches, aspect-preserving proxies,
source-preserving thumbnails and accepted-SDK directory-iteration compatibility.
No previous candidate has reached TestFlight upload.

## Build 147 / beta.4 candidate

Includes the audio/frame fixes plus General appearance selection, project/session
container and package management, refined reasoning/tool frames and persistent
batch folding. Forty-nine module tests and two native component UI tests pass;
[interface evidence](evidence/floe-1.7/interface/README.md) records the fixture
boundary. Final native component compilation also passes after adding conversation
titles to container rows. Full-App cloud builds and Apple processing remain pending.
Production apt provisioning, the complete model capability matrix and physical
device acceptance remain open; this is an internal beta, not full-plan acceptance.

- Fixed source: `2cd030c2121ef48214da312ad310c74ae1c72324`.
- Immutable tag: `v1.7.0-beta.4`; tag/version/build preflight passed.
- Cloud run: [34711460906](https://github.com/JiangNanGenius/floe-agent/actions/runs/34711460906).
- Cancelled before upload after the Swift regression stage stopped producing
  output for approximately 14 minutes. Complete logs reveal an SVG inspection
  approval regression and an execution-test stall; no App build or upload passed.
  The SVG inspection exemption is restored in the next source revision, while
  the execution stall requires reproduction and qualification before another tag.

## Build 148 / beta.5 candidate

Restores the existing read-only SVG inspection approval rule that was lost during
tool consolidation. Focused host tests pass: 83 security-policy tests and 147
execution tests, with the two JavaScript deadline suites kept separate as in the
release workflow. The temporary test harness links production sources and the
PDF fixtures; these results do not replace the complete cloud suite.

The cloud stall has not reproduced in this focused run. Release tests now retain
their complete output, sample owned Swift test processes after 90 seconds without
test output, and fail after 180 seconds without output or the overall deadline.
The wrapper preserves test exit codes and terminates its own process group on a
deadline. Three subprocess checks cover output/exit propagation, timeout and
child cleanup. No tests are skipped beyond the pre-existing isolated JavaScript
suites, which still run separately. Fresh cloud verification remains required.

## Build 149 / beta.6 preparation

Includes independent Notes, dynamic illustrated maps and PDF windows, Office and Whisper integration, and confirmed permanent deletion with shared-resource protection. SDK 27/26 iPad/iPhone native qualification passed at `4550b6d` in run `34742130370`; subsequent lifecycle code passed 15 host tests and native component compilation. The release workflow must verify the final tagged source before signed upload. Physical-device acceptance follows TestFlight installation and is performed by the user.

The package/model qualification matrix remains explicit; unbuilt resources are not offered as installed capabilities. Upload, Apple processing and tester availability are pending until verified.

## Build 150 / beta.7 preparation

Build 149 failed its automated Swift gate and was not uploaded. Cloud sampling confirmed cooperative workers blocked while draining WASM output; its network timeout also failed under contention. Build 150 separates blocking WASM/DNS work from Swift task scheduling, tests task cancellation, parallel commands and lookup deadlines, and updates the explicit Canvas tool-set assertion for the four scoped Notes tools.

All release gates remain required. The next fixed candidate is `v1.7.0-beta.7`; upload and Apple processing are still pending. Device testing follows internal TestFlight availability and belongs to the user.

## Build 151 / beta.8 preparation

Build 150 completed the full concurrent Swift run without the earlier WASM stall. Only `FloeCoreTests` failed, because 21 appearance/environment catalog keys lacked the required namespace. The next candidate renames those keys and their UI references, preserves English and Chinese translations, and explicitly localizes the dynamic hold/unhold label. The original completeness rules remain intact. No TestFlight upload occurred for 150.

## Build 152 / beta.9 preparation

151 passed 1,244 Swift test executions, the SDK 27 simulator Release build, and all 135 App regressions (zero failures/skips). It then stopped on a scanner false positive: the public OpenAI tokenizer commit identifier in the Whisper manifest. The exact historical fingerprint is documented; the unused metadata label is renamed `textAssetsRevision`, preserving all download URLs, hashes, model identity and runtime-decoded fields.

The source-history scan now runs before expensive tests/builds, and App regression bundles are retained even if a later release step fails. All verification requirements remain. No 151 upload took place; 152 is the next candidate.
