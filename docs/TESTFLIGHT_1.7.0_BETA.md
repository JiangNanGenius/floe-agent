# Floe 1.7.0 — TestFlight preparation and candidate history

## Current preparation — 2026-09-13

**Not uploaded.** The next build must include the independent Notes workspace, dynamic illustrated maps and document windows, Office integration, Whisper speech/captions, environment/package controls, media workbenches and appearance improvements. Candidate source will be fixed after remaining implementation and qualification; earlier tags below are historical and must not be reused as proof of delivery.

Latest full-App verification was started for `4550b6d` ([CI](https://github.com/JiangNanGenius/floe-agent/actions/runs/34742128610), [Notes SDK 27/26 on iPad and iPhone](https://github.com/JiangNanGenius/floe-agent/actions/runs/34742130370)); these runs do not yet qualify later lifecycle changes. Final TestFlight text and checks are tracked in [the 1.7 release description](RELEASE_NOTES_1.7.0.md). No public App Store release is included.

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
- Full application regression, accepted-SDK archive, Apple processing and group visibility must pass for this exact source.

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
