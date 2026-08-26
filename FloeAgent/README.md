# Floe Agent Engineering Guide

[Website](https://www.floe-agent.com/) · [Product README](../README.md) · [中文 README](../README.zh-CN.md) · [Architecture](../docs/ARCHITECTURE_OVERVIEW.md) · [User guide](../docs/USER_GUIDE.md) · [中文使用指南](../docs/USER_GUIDE.zh-CN.md)

This directory contains the Swift package, generated Xcode project, native app, tests, and release scripts for the Floe Agent 1.4.36 source target (build 67). The minimum deployment target is iOS/iPadOS 26.0 and the current database schema is v21.

## Build prerequisites

- macOS with a full Xcode installation containing the iOS 26 SDK or newer; use Xcode 27 to compile and validate the iOS 27 Foundation Models implementation;
- Swift 6.2 or newer;
- XcodeGen for regenerating `FloeAgent.xcodeproj`;
- optional release tools: `gitleaks`, `syft`, and GitHub CLI.

The scripts use `DEVELOPER_DIR` where practical and do not require changing the machine-wide `xcode-select` setting.

## Build and test

```bash
cd FloeAgent
brew install xcodegen
xcodegen generate
scripts/local_build.sh
```

Focused commands:

```bash
swift build
swift test
swift test --filter FloeSkillsTests
swift test --filter V8TaskOwnershipTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project FloeAgent.xcodeproj -scheme FloeAgent \
  -destination 'generic/platform=iOS Simulator' build
```

If the active full Xcode is named `Xcode-beta.app`, adjust `DEVELOPER_DIR`. A Command Line Tools-only `xcode-select` can compile some package targets but cannot provide iOS Simulator builds or Swift Testing macro plugins reliably.

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
| `FloePersistence` | GRDB stores, atomic run launch, credential metadata, archive state, and append-only migrations through v14. |
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

## Release checks

Version and build number live in `project.yml`. A SemVer tag must match `MARKETING_VERSION`, and the integer build must increase from the previous tag.

```bash
scripts/release_preflight.sh v1.3.2
scripts/pin_check.sh
scripts/secret_scan.sh
scripts/license_inventory.sh
scripts/sbom.sh
```

The release workflow builds an unsigned device IPA and signs the exact verified Xcode 27 application from the same tagged source. It rejects an Xcode build that Apple no longer accepts before starting expensive work. GitHub assets are published only after TestFlight transport accepts the upload. See [the root README](../README.md#unsigned-ipa) for the user-facing distinction between these packages.

## Documentation discipline

- Update both English and Simplified Chinese user guidance when behavior, navigation, permissions, installation, or recovery changes.
- Keep public product architecture in [`docs/ARCHITECTURE_OVERVIEW.md`](../docs/ARCHITECTURE_OVERVIEW.md).
- Keep internal plans, audits, validation evidence, App Review research and release handoffs outside the public repository.
- Never copy credentials, personal paths, hostnames, device identifiers, or unredacted diagnostics into fixtures or documentation.
