# Floe Agent Engineering Guide

> 用户操作：[中文手册](../docs/USER_GUIDE.zh-CN.md) · [English manual](../docs/USER_GUIDE.md) · [当前版本与验证状态](../docs/CURRENT_STATUS.md)。工程构建证据与 TestFlight 可安装状态分别记录。


Current source: **1.7.24 (265)**, iOS/iPadOS 26 minimum. See [current delivery status](../docs/CURRENT_STATUS.md), [creative tool contracts](../docs/FLOE_1_7_24_CREATIVE_TOOLS.md), and [architecture](../docs/ARCHITECTURE_OVERVIEW.md). Current code includes 2D CAD, Drawing Assistant, Office shared commands, Notes proposals and file-backed Canvas/media projects. Engine-level Office and physical-device acceptance remain separately qualified.

当前源码与安装渠道分别核对。优先本地定向测试及完整 App 验证，云端承担独立检查和发布流程。旧构建过程保留在[历史工程记录](../docs/history/ENGINEERING_RELEASE_CHRONOLOGY.pre-20261009.md)。

## Build prerequisites

- macOS with a full Xcode installation containing the iOS 26 SDK or newer; use Xcode 27 to compile and validate the iOS 27 Foundation Models implementation;
- Swift 6.2 or newer;
- XcodeGen for regenerating `FloeAgent.xcodeproj`;
- optional release tools: `gitleaks`, `syft`, and GitHub CLI.

The scripts use `DEVELOPER_DIR` where practical and do not require changing the machine-wide `xcode-select` setting.

## Build and test

Prefer focused local tests and relevant local App builds; use cloud CI for required independent checks and release workflows. From the repository root, with a full Xcode selected through `DEVELOPER_DIR`:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --package-path FloeAgent/Qualification --scratch-path "$HOME/Library/Caches/CodexBuild/Floe/main/xcode27/qualification" --force-resolved-versions --jobs 6
bash FloeAgent/scripts/bootstrap_native_components.sh
python3 FloeAgent/scripts/audit_native_runtime_free.py --project
make -C FloeAgent/LinuxGuest/runner check-net
python3 -m unittest discover -s FloeAgent/scripts/tests -p test_readme_source_links.py
```

`check-net` is the network-free native check for the guest's first-boot
resolver/interfaces/git-safe-directory files and the `net=up|partial|down`
status vocabulary; the ioctl and resolver-probe side is Linux-only and needs a
booted guest. `test_readme_source_links.py` keeps the README quick-add badges
linked to the official HTTPS quick-add endpoints (`/add/feather`,
`/add/altstore`), the badge assets present, the release download link separate
and GitHub-safe, and pins the shared Feather source URL. Cloud CI runs the
native IDE editor cases with
`-only-testing:FloeAgentUITests/WorkspaceIDEUITests` on iPad and iPhone
simulator legs (see `.github/workflows/ci.yml`); a passing simulator leg is not
device acceptance. The IDE module contracts run in the SwiftPM suite
(`IDENativeTextWorkspaceTests`, `ArchiveEngineTests`, `ArchiveBrowserServiceTests`).

Since the Phase 2 TinyEMU migration there is no bundled CPython/NodeMobile
build input: local Python/Node execute inside each environment's TinyEMU
Linux guest, and `audit_native_runtime_free.py` fails the build if a native
Python/Node marker, a precompiled wheel payload or a native Ruby/Rust runtime
returns to the project or the packaged app. The retired
recipes (pinned runtime bootstrap, ios-wheelhouse builders, Node tools) are
archived, not wired into the build, under
`FloeAgent/ThirdParty/NativeRuntimeArchive/`. WASM stays a separate
compatibility route (`ThirdParty/WasmKit`, `ThirdParty/PHPWASI`, signed
capability catalog) and is not an App-bundled language runtime.

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
| `FloePersistence` | GRDB stores, atomic run launch, credential metadata, archive state, and append-only migrations through v44, including media-job owner/idempotency columns, durable private-workspace cleanup intents, and the conversation search index repair. |
| `FloeWorkspace`, `FloeDocuments`, `FloeImages` | File scopes, change evidence, document working copies, and image operations. Also the native text/code editing workspace (`IDENativeTextWorkspace`, with the Web workbench retained as the advanced fallback) and the bounded native archive engine (zip/tar/tar.gz/tar.xz create, list and extract; bzip2 create-only; 7z read-only). |
| `FloeGit` | Non-destructive libgit2 repository operations, GitHub API/Keychain integration, and model-facing local/cloud source-control tools. |
| `FloeSSH`, `FloeExecution`, `FloeVNC` | SSH/jump/PTY/forwarding, remote execution, and Metal-backed VNC. `FloeExecution` owns Runtime v2: content-addressed images, immutable software templates with pinned per-environment deltas, the CPU/RAM/VM pool with fail-closed SMP admission, and the TinyEMU guest service. |
| `FloeSkills` | Declarative Skill validation, compatibility, provenance, install staging, and tool ceilings. |
| `FloeApp` | SwiftUI workbench, visible browser, voice coordinator, task inspector, settings, notifications, background recovery, and the status Picture-in-Picture surface behind its release gate. |

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
