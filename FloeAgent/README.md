# Floe Agent Engineering Guide

**Current internal TestFlight: 1.7.0 (218).** Apple VALID, unexpired status, the existing private Floe QA group and IN_BETA_TESTING were verified on September 21 at 15:08 UTC. This includes the explicit Linux install path, Office CJK/Pencil and routing repairs, IDE source control and archive browsing, and stable multi-turn local-model tools. Only focused checks and the cloud accepted-SDK build/upload validation were required; device acceptance belongs to the tester. [Delivery evidence](../docs/TESTFLIGHT_1.7.0_BETA.md).

[Website](https://www.floe-agent.com/) · [Product README](../README.md) · [中文 README](../README.zh-CN.md) · [Architecture](../docs/ARCHITECTURE_OVERVIEW.md) · [User guide](../docs/USER_GUIDE.md) · [中文使用指南](../docs/USER_GUIDE.zh-CN.md)

This directory contains the Swift package, generated Xcode project, native app, tests, and release scripts for Floe 1.7. Minimum deployment is iOS/iPadOS 26.0; database schema is v43. Heavy App builds and archives run in cloud CI. Build 201 (`be06cece`, `v1.7.0-beta.58`) was a prior internal TestFlight delivery; Apple VALID, unexpired status, the single private Floe QA group, `IN_BETA_TESTING` and both test-note languages were verified at 2026-09-19 17:44 UTC. GitHub beta.58 and its matching Feather entry are also published; both were recovered from the retained build 201 artifact after the lean publish job stopped on a missing release-notes file, without rebuilding or re-uploading.

Build 186 (`d421fea2`, `v1.7.0-beta.43`, [run 35306551280](https://github.com/JiangNanGenius/floe-agent/actions/runs/35306551280)) failed qualification and was not uploaded. The accepted-SDK App regression passed 204/204 including all 23 IDE cases. Both Notes UI legs failed the Office back-control identifier check; the Notes component had one iPad Excel Quick Look timeout, while the actual content-summary fallback worked. SDK 27 module tests rejected one non-namespaced localization key. Original evidence and the source-verified unsigned device recovery archive are retained.

[Build191](../docs/qualification/build191-release/README.md), immutable `715cbc42` / `v1.7.0-beta.48`, was uploaded successfully by recovery run35347141494 after the user explicitly waived all three recorded UI failures; Apple VALID/unexpired, Floe QA and IN_BETA_TESTING were verified at13:43UTC. Both SDK App suites passed204/204 and both NativeNotes components101/101. The two SDK27 UI failures and a newly completed accepted-SDK iPhone assistant-readiness failure remain recorded; all three are explicitly waived for internal device testing. Upload reuses the exact-source accepted-SDK artifact; signing passed and internal Floe QA installation is available. No public Beta or production submission is authorized. Physical local-model and native Office/Pencil acceptance, full package/model delivery and RDP App integration remain open.

Build 196 delivers the build 191 feedback repair to internal TestFlight: tag `v1.7.0-beta.53` at `0771aee5`, Apple buildID `27355e88-2f37-4c60-8b6e-713db546773b` verified `VALID`, unexpired, private Floe QA and `IN_BETA_TESTING` at 2026-09-19 02:24 UTC with both test-note languages read back. It was built once with the accepted upload SDK; the unsigned device IPA and its matching private symbols were retained before signing. Builds 192/193 never compiled (Swift 6 region isolation, then seven App-target errors), and builds 194/195 were accepted by Apple but never published (release-workflow defect, then a transient artifact-service failure); tags `v1.7.0-beta.49` through `v1.7.0-beta.52` are retained as evidence and the App source is identical across 194-196. The candidate includes truthful Office editability with the chart-workbook save gate (cloud component run `35373122891` at `b494897c` compiled and linked the overlay/host; runtime roundtrip is device-pending), typed IDE routing with native Office/document tabs, file-preview sharing, real Git fast-forward/conflict/staged-discard recovery (71/71 libgit2 checks), interactive-terminal descriptor/readiness fixes, explicit npm/pnpm authority, model-default fallback, durable video-from-chat jobs with one inline reference image, and real GIF frame handling. The signed capability catalog bundled with this build adds `floe/ruby` 3.4.1 and `floe/php` 8.2.33 to `floe/lua` 5.4.8 (signing run 35399070312 at `96be231e`); device install and runtime acceptance remain the tester's. Validation recorded before the run is host-level and fixture-level: it is not a substitute for the accepted-SDK App compile or device evidence.

Build 197 (version 1.7.0, build 197, tag `v1.7.0-beta.54` fixed at `f05b02ac`) failed the accepted-upload-SDK cloud App compile in [run 35426497884](https://github.com/JiangNanGenius/floe-agent/actions/runs/35426497884) with five diagnostics and two distinct errors and was never uploaded: `ExecutionEnvironmentView.swift:82/105/124/147` could not find `RuntimeInventoryEntry` because the defining `FloeExecution` module was not imported, and `FileInspectorView.swift:132:24` conditionally bound the already-unwrapped `previewPath` ("initializer for conditional binding must have Optional type, not 'String'"). Every step after the compile was skipped, so there is no App artifact, no signing and no TestFlight upload; the tag stays at `f05b02ac` and is not moved. Its implementation range `1cff5665..11681a0f` (eight implementation commits) carries touch-driven mind-map node creation, public video-model candidate selection plus the Ark credential-namespace fix, cross-run tool-context recovery with secret-redacted persisted tool summaries, real runtime versions with reviewed shell/APT tool routes, Magic Keyboard Return-to-send with Shift+Return newline, Office first-entry preview and second-entry (or new-document) direct editing, in-IDE Office embedding with Source control/Share/file-inspector direct entry, stable Pencil ink identity, read-only cloud/network snapshots, and the removal of the ineffective Add to Canvas action.

Build 198 (version 1.7.0, build 198, reserved tag `v1.7.0-beta.55` not yet created) is the replacement candidate for build 197: the same feature set with the two compile errors fixed minimally (add `import FloeExecution`; drop the redundant second optional binding, no behavior change) and all four targets on `CURRENT_PROJECT_VERSION` 198. Only light checks were run for this preparation round (swiftc parse of the two touched sources, xcodegen, exact version/build consistency, JSON validation, `git diff --check`); no App cloud build, TestFlight upload or device acceptance has happened, and the build 191 local Qwen GatedDeltaNet first-message abort remains unconfirmed and is not claimed fixed.

Build 199 (`v1.7.0-beta.56`) only prepared the version and notes and was never uploaded. Build 200 (`v1.7.0-beta.57`, `45553423`) stopped inside the accepted-SDK App build in [run 35451531085](https://github.com/JiangNanGenius/floe-agent/actions/runs/35451531085): no App artifact, no signing, no TestFlight upload, and the two recorded Swift 6 diagnostics are fixed by `3744103f` (media model resolution awaiting its main-actor route; compact/regular Office toolbar label-style branches). Build 201 (`be06cece`, `v1.7.0-beta.58`) was built once in [run 35453588806](https://github.com/JiangNanGenius/floe-agent/actions/runs/35453588806); TestFlight accepted the upload and the unsigned IPA with matching private symbols was retained before signing. That run's publish job failed on the missing release-notes file in the frozen tag checkout, so the attested unsigned GitHub prerelease and Feather source were recovered from the retained artifact without a rebuild or a second upload ([record](../docs/RELEASE_NOTES_1.7.0_BUILD_201.md)). The rebuild-free retry also exposed a latent bare metadata-only verifier call in `testflight-direct.yml`'s reuse step, now repaired with a regression test.

## Build prerequisites

- macOS with a full Xcode installation containing the iOS 26 SDK or newer; use Xcode 27 to compile and validate the iOS 27 Foundation Models implementation;
- Swift 6.2 or newer;
- XcodeGen for regenerating `FloeAgent.xcodeproj`;
- optional release tools: `gitleaks`, `syft`, and GitHub CLI.

The scripts use `DEVELOPER_DIR` where practical and do not require changing the machine-wide `xcode-select` setting.

## Build and test

Prefer focused local tests and cloud App builds for the 1.7 integration. From the repository root, with a full Xcode selected through `DEVELOPER_DIR`:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift test --package-path FloeAgent/Qualification --scratch-path FloeAgent/.build --force-resolved-versions --jobs 2
bash FloeAgent/scripts/bootstrap_native_components.sh
python3 FloeAgent/scripts/audit_native_runtime_free.py --project
```

Since the Phase 2 TinyEMU migration there is no bundled CPython/NodeMobile
build input: local Python/Node execute inside each environment's TinyEMU
Linux guest, and `audit_native_runtime_free.py` fails the build if a native
Python/Node marker returns to the project or the packaged app. The retired
recipes (pinned runtime bootstrap, ios-wheelhouse builders, Node tools) are
archived, not wired into the build, under
`FloeAgent/ThirdParty/NativeRuntimeArchive/`.

Check mode does not install resources or modify locks. Qualification covers environment, package, media, persistence and signed catalog paths; it does not replace App or device tests. Run commands sharing the SwiftPM scratch directory sequentially.

For a full local App build when needed, use `bash scripts/local_build.sh` from this directory after installing XcodeGen and checking free space. Cloud CI owns the normal development-SDK and release-SDK App checks and heavy archives. See [complete build and acceptance instructions](../docs/FLOE_1_7_BUILD_AND_ACCEPTANCE.md).

A Command Line Tools-only selection cannot provide iOS Simulator builds or all Swift Testing macro plugins reliably. Adjust the Xcode path to the installed full developer directory.

## Generated project rule

`project.yml` is the source of truth and the `.xcodeproj` is committed so contributors and release automation see the same graph. After changing targets, resources, build settings, versions, or schemes:

```bash
xcodegen generate
git diff -- FloeAgent.xcodeproj/project.pbxproj project.yml
```

CI regenerates the project and fails if the committed project differs.

## Package map

| Target | Responsibility |
| --- | --- |
| `FloeCore`, `FloeModels` | Shared provider, task, workspace, policy, event, and error models. |
| `FloeProviders` | Streaming wire adapters and multimodal/image provider translation. |
| `FloeLocalModels` | Apple Foundation Models availability/runtime, curated MLX downloads, resource policy, dynamic local context, and bounded local tool-call translation. |
| `FloeAgentRuntime` | Continuous run state machine, context assembly, Plan/Goal/Memory, harness, checkpoints, and tool loop. |
| `FloeTools`, `FloeSecurity` | Compile-time tool catalog, scoped execution, approvals, audit chain, Keychain, and catastrophic-action gate. |
| `FloePersistence` | GRDB stores, atomic run launch, credential metadata, archive state, and append-only migrations through v43, including media-job owner/idempotency columns and durable private-workspace cleanup intents. |
| `FloeWorkspace`, `FloeDocuments`, `FloeImages` | File scopes, change evidence, document working copies, and image operations. |
| `FloeGit` | Non-destructive libgit2 repository operations, GitHub API/Keychain integration, and model-facing local/cloud source-control tools. |
| `FloeSSH`, `FloeExecution`, `FloeVNC` | SSH/jump/PTY/forwarding, remote execution, and Metal-backed VNC. |
| `FloeSkills` | Declarative Skill validation, compatibility, provenance, install staging, and tool ceilings. |
| `FloeApp` | SwiftUI workbench, visible browser, voice coordinator, task inspector, settings, notifications, and background recovery. |

## Runtime invariants

1. One user-visible Task/Conversation owns many Runs.
2. Every Task owns exactly one project or private workspace.
3. First-message persistence is atomic and completes before provider I/O.
4. Provider tool schemas are filtered by task authority; executor checks remain authoritative.
5. Plan mode denies side-effecting tools at both selection and execution boundaries.
6. Browser element references are document-scoped and fail as stale after invalidation.
7. Uncertain side effects are never silently replayed during recovery.
8. Skills are declarative packages and never dynamically expand the compiled tool catalog.
9. Completed tool executions are checkpointed with the run ledger; recovery clears unfinished stream fields and never replays a successful identical tool/argument pair.
10. Local-model context/tool selection is independent from cloud-provider context, compression, and capability ceilings.
11. Stateful tool chains preserve verified identifiers and artifact bindings before bounded output; missing IDs route to a read-only discovery predecessor instead of a guessed value or repeated mutation.

## Release checks

Version and build number live in `project.yml`. A SemVer tag must match `MARKETING_VERSION`, and the integer build must increase from the previous tag.

```bash
scripts/release_preflight.sh v1.3.2
scripts/pin_check.sh
scripts/secret_scan.sh
scripts/license_inventory.sh
scripts/sbom.sh
```

The release workflow freezes a validated tag, then runs SDK 27 qualification and the App Store-accepted Xcode 26.6 (17F113, SDK 26.5) build/qualification in parallel. Successful push or manually dispatched full CI for the exact source SHA can supply SDK 27 App and both Notes UI result bundles; each bundle is revalidated before reuse. Otherwise SDK 27 builds its simulator test hosts once. Each SDK retains its own compiled simulator host before tests. Notes runs in separate iPad/iPhone steps with strict gates; executed failures are not automatically retried. A source-, digest- and toolchain-bound recovery can reuse an accepted-SDK host instead of rebuilding it. Cloud simulator builds select arm64, matching their actual devices, and omit unused Intel compilation. Both independent Release device builds remain required. Signing starts only after both jobs succeed and restores the already-qualified accepted-SDK application from an artifact whose SHA-256, source commit, bundle ID and version/build are checked. No application compilation occurs in the upload job. Version 27-only compiler-gated interfaces use compatibility paths in that upload. Reviewed bundle normalization removes pinned non-iOS pnpm resources and preserves libssh2 generic arm64 code while correcting its minimum-OS metadata. It also compares all embedded bundle deployment commands, aligns dash framework metadata with the actual binary and removes stale template build provenance. Distribution recovery records application-source and packaging-policy commits separately and verifies any reused test evidence. Beta tags skip automatic GitHub publication by default. For the current feedback release, publish the matching GitHub prerelease with reviewed assets after TestFlight availability has been verified; a tag alone is not a release. Production release remains a separate action. See [the root README](../README.md#unsigned-ipa) for the user-facing distinction between these packages.

## Documentation discipline

- Update both English and Simplified Chinese user guidance when behavior, navigation, permissions, installation, or recovery changes.
- Keep public product architecture in [`docs/ARCHITECTURE_OVERVIEW.md`](../docs/ARCHITECTURE_OVERVIEW.md).
- Keep internal plans, audits, validation evidence, App Review research and release handoffs outside the public repository.
- Never copy credentials, personal paths, hostnames, device identifiers, or unredacted diagnostics into fixtures or documentation.

## Workflow-upgrade verification

The [current upgrade record](../docs/WORKFLOW_UPGRADE.md) distinguishes implemented behavior from pending engine/device verification. Focused app suites cover canvas contracts, workspace cleanup, plugin lifecycle and PDF refresh. `HomeChatVoiceIPhoneUITests.testCanvasCreationRemainsVisibleInPortraitAndLandscape` drives real compact navigation and both creation menus, retaining screenshot attachments. iPad navigation tests retain plugin, selection and workspace-manager screenshots.

Run `scripts/qualify_office_engine.sh --check` for the isolated pinned Collabora prerequisite check; the separate cloud workflow can perform the native build. Qualification does not enable advanced editing or certify app embedding, licensing, or file fidelity. Heavy engine builds belong on an adequately provisioned build host.
