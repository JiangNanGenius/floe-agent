# Floe Agent Engineering Guide

[Product README](../README.md) · [中文 README](../README.zh-CN.md) · [Architecture](../docs/ARCHITECTURE_OVERVIEW.md) · [User guide](../docs/USER_GUIDE.md)

This directory contains the Swift package, generated Xcode project, native app, tests, and release scripts for Floe Agent 1.2.x. The minimum deployment target is iOS/iPadOS 26.0 and the current database schema is v9.

## Build prerequisites

- macOS with a full Xcode installation containing the iOS 26 SDK or newer;
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
| `FloeAgentRuntime` | Continuous run state machine, context assembly, Plan/Goal/Memory, harness, checkpoints, and tool loop. |
| `FloeTools`, `FloeSecurity` | Compile-time tool catalog, scoped execution, approvals, audit chain, Keychain, and catastrophic-action gate. |
| `FloePersistence` | GRDB stores, atomic run launch, and append-only migrations through v9. |
| `FloeWorkspace`, `FloeDocuments`, `FloeImages` | File scopes, change evidence, document working copies, and image operations. |
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

## Release checks

Version and build number live in `project.yml`. A SemVer tag must match `MARKETING_VERSION`, and the integer build must increase from the previous tag.

```bash
scripts/release_preflight.sh v1.2.1
scripts/pin_check.sh
scripts/secret_scan.sh
scripts/license_inventory.sh
scripts/sbom.sh
```

The release workflow builds an unsigned device IPA and a signed App Store archive from the same commit. GitHub assets are published only after TestFlight transport accepts the archive. See [the root README](../README.md#unsigned-ipa) for the user-facing distinction between these packages.

## Documentation discipline

- Update both English and Simplified Chinese user guidance when behavior, navigation, permissions, installation, or recovery changes.
- Put current architecture in [`docs/ARCHITECTURE_OVERVIEW.md`](../docs/ARCHITECTURE_OVERVIEW.md) or the detailed architecture documents.
- Label audit, delivery, validation, and handoff documents as historical evidence with their date or commit.
- Never copy credentials, personal paths, hostnames, device identifiers, or unredacted diagnostics into fixtures or documentation.
