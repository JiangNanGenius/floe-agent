# Floe 1.7.0 — TestFlight candidate history

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
