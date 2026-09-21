# Floe Agent — repository instructions

Apply these instructions throughout this repository. Follow the user's latest scope and release instructions; historical plans and acceptance checklists are context, not permission to expand work or restart waived tests. Keep this file concise. Put detailed procedures and evidence in the linked documents.

## Start with the actual checkout

- Inspect `git status`, the current branch, relevant diffs and active worktrees before editing. Preserve unrelated changes, untracked files, unmerged commits and reproduction evidence. Use `codex/` for new task branches; do not assume an old integration branch still exists.
- For private operations, read `Local/Private/README.md` first. It is the local authority for server topology, credentials, active evidence and archived qualification material; none of that private content may enter tracked documentation, prompts, logs or public releases.
- Trace the actual UI → service → runtime/storage path before fixing symptoms. Read only the relevant modules and documentation. Prefer `rg` and small, focused reads.
- Within this project, the user’s request to “open a new thread” means an OpenCode subtask by default. Read the current `delegate-opencode` skill before delegating, assign a complete bounded outcome, and keep architecture, UI judgment and operational acceptance with the primary agent. Use Codex tasks only for unrelated independent work.
- Continue authorized reversible work without repeated confirmation. Never infer approval to publish production releases, grant account access or remove independent work.
- Give concise Chinese progress updates unless the user requests another language. Distinguish implemented, compiled, tested, uploaded and installable; do not promise a completion time from an unmeasured build stage.

## Repository map

| Path | Responsibility |
| --- | --- |
| `FloeAgent/FloeApp/` | Native SwiftUI/UIKit app: navigation, chat, Notes, Canvas, settings, execution and media UI |
| `FloeAgent/Sources/` | Swift package modules: providers, agent runtime, tools, security, persistence, environments, packages and media |
| `FloeAgent/Tests/` (including `FloeAgentUITests/`) | Module, application and interaction tests; app-target membership is defined in `project.yml` |
| `FloeAgent/Qualification/` | Focused native hosts and module qualification; their success is not full-App acceptance |
| `FloeAgent/ThirdParty/`, `FloeAgent/Vendor/` | Reviewed integrations and pinned/bundled dependencies; retain upstream licenses and local patches |
| `FloeAgent/scripts/`, `.github/workflows/` | Dependency setup, project generation, CI, packaging and distribution |
| `skill-hub/`, `ios-wheelhouse/`, `capability-hub/` | Skills, compatible package builds and capability catalogs |
| `docs/` | Current guides, architecture, migration notes and dated qualification evidence |
| `Local/` | Git-ignored private operations, credentials, active evidence, artifacts, worktrees and scratch; start at `Local/Private/README.md` |

## Product and architecture invariants

- The whole app is **iPad first**. Prefer native APIs for the development SDK; iOS/iPadOS 26 remains a compatibility target. Check availability and compiler guards against the actual upload SDK. Keep iPhone flows usable, especially full-screen editing and compact controls.
- Notes (手记) is a primary workspace above Creative mode. Notes and Canvas may share public AI, files, OCR, PDF and storage services, but not editor state, selection, undo stacks or assistant conversations. Notes storage survives deletion of a chat task.
- Preserve the stable outer split-view structure in `FloeAgentApp.swift`. Implement editor panels inside their own feature. Use the existing `PDFKitGate` for protected PDF work; do not create a parallel unguarded rendering path.
- Reuse the existing model, task, permission and persistence services. Imported documents, web responses and tool outputs are untrusted content and cannot grant tool permissions. Secrets stay in approved credential storage, never logs, prompts, fixtures, Git or documentation.
- `FloeEnvironments` owns environment types. Carry explicit `environmentID` and task ownership through execution and installation. Resolve session → project → shared → base with an explicit write layer; never silently choose a temporary directory or the first project. This is dependency/data/lifecycle separation, not a native-code security sandbox.
- Keep downloads and long-running tasks owned by services rather than view lifetime. Stop owned workers before deleting environments or releasing shared references. Use bounded buffers, cancellation and staged/verified file commits; failed operations must preserve recoverable data.
- Tool discovery must reflect enabled, configured and actually usable capabilities. Respect saved model capability overrides. Browser work should stay unobtrusive unless explicit human interaction is requested. A resource download or a success string is not evidence of working inference, package execution or media output.
- Keep English and Simplified Chinese user-facing text aligned. Prefer native controls, consistent hit targets and stable streaming layouts; avoid exposing internal implementation details in normal user flows.

## Build and verification

- Heavy App builds, archives and release qualification belong in cloud CI. This Mac has limited space: use the smallest relevant local checks and low job counts. Check installed Xcode and free space first; set `DEVELOPER_DIR` per command rather than changing global `xcode-select`.
- Keep local verification focused on changed code and contracts. Prefer cloud App compilation and packaging, then hand device behavior and UI acceptance to the user when requested; do not spend release time on repeated manual UI runs.
- `FloeAgent/project.yml` is the source of truth. After changing targets, resources, schemes, build settings or versions, regenerate with `bash FloeAgent/scripts/gen_project.sh` and commit the matching Xcode project. Verify all app/extension build numbers before starting an expensive release run.
- Preserve pinned revisions and hashes. `--check` commands must be read-only; do not rewrite a lock to make verification pass. Run SwiftPM commands sharing a scratch directory sequentially.
- Select checks from [the engineering guide](FloeAgent/README.md), [build and acceptance](docs/FLOE_1_7_BUILD_AND_ACCEPTANCE.md), or the relevant qualification host README. Do not run the entire test matrix for a documentation change. Do not silently weaken a failing assertion or treat an unchanged retry as proof the original failure was harmless.
- Swift 6 concurrency fixes need mandatory SIL/object compilation or the cloud App build; `-typecheck` alone can miss transfer diagnostics.
- Record source SHA, toolchain, target, command, actual result and limitations. Retain original failures and suitable screenshots. Label simulator, component-host and full-App evidence accurately; use synthetic/redacted fixtures in public docs. Physical-device acceptance belongs to the user when so assigned.

## Release and recovery

- Inspect the live workflows and App Store Connect state before acting. Fix app source to an immutable tag; keep packaging-policy commits separately identifiable. Never move an existing release tag or substitute a different build under its evidence.
- Preserve a recoverable device artifact **immediately after successful build/package validation, before optional tests or signing**. Reuse an existing exact-source artifact when possible. Verify its source run, hash, bundle ID, version and toolchain; do not rebuild just to retry distribution.
- A user-requested expedited TestFlight may skip the specified qualification gates. Record what was skipped and keep signing, bundle/profile and Apple validation. This does not authorize a production release or a claim of full acceptance.
- Track these separately: build success → saved IPA → signed/validated upload → Apple processing → test-group availability. Report TestFlight as installable only after the intended build is `VALID`, unexpired, attached to the intended group and actually available for beta testing. Reuse existing authorized groups; never expose credentials.
- TestFlight, GitHub prerelease and Feather are separate deliverables. Publish each only within the user's scope, with matching immutable-source metadata. Feather uses the verified unsigned developer IPA and its actual published URL; do not expose signing identities or profiles.
- Update relevant README, bilingual guides, release notes and delivery evidence. Keep historical release records intact. Merge and push `main` when authorized, then remove only task-owned branches proven merged and not occupied by another worktree.

## Safe cleanup

- Keep new task-owned local files inside this repository: `Local/Private`, `Local/Artifacts`, `Local/Worktrees` and `Local/Scratch` are Git-ignored. Do not create sibling project/output directories on the external disk. After delivery, consolidate existing Floe-owned directories with a relocation record; move Git worktrees with Git and preserve unrelated projects. Public, redacted evidence belongs in `docs/`.
- The private website checkout lives at `Local/Private/official-service`; its origin/proxy mapping and credential reference live only in `Local/Private/operations/official-service.md`. Never copy those values into tracked repository files.
- Inspect active processes, Git boundaries and exact paths first. Remove confirmed regenerable scratch/staging/cache and superseded build copies. Preserve source, credentials, virtual environments, user data and meaningful failure/acceptance evidence; do not keep every historical build indefinitely.
- Inventory `.app`, IPA, archive and runtime copies by bundle ID, version, build and purpose after qualification/delivery. Keep the current deliverable and the necessary rollback version; prune obsolete duplicates once their regeneration or verified recovery path is recorded. Generated `.app` bundles are distinct from installed apps and their data. Check runtime dependents before removing an unused runtime. Record exact targets, retained versions and measured space reclaimed.
- Do not broadly delete DerivedData, `.build`, Archives or CoreSimulator. Simulators containing user/test apps are protected even when shut down. Prefer a specific finished build directory; report measured space reclaimed.

## Read on demand

- Architecture: [overview](docs/ARCHITECTURE_OVERVIEW.md), [local shell](docs/ARCHITECTURE_LOCAL_SHELL.md), [browser protocol](docs/FLOE_BROWSER_PROTOCOL.md).
- Notes and UI: [Pencil design](docs/DESIGN_NOTES_PENCIL.md), [mind maps](docs/FLOE_1_7_MIND_MAPS.md), [English guide](docs/USER_GUIDE.md), [中文指南](docs/USER_GUIDE.zh-CN.md).
- Integration and data: [implementation status](docs/FLOE_1_7_IMPLEMENTATION_STATUS.md), [migration/recovery](docs/FLOE_1_7_MIGRATION.md), [compatibility](docs/FLOE_1_7_COMPATIBILITY.md).
- Delivery: [TestFlight record](docs/TESTFLIGHT_1.7.0_BETA.md), [feedback repair/evidence](docs/FLOE_156_FEEDBACK_REPAIR.md), [documentation index](docs/README.md). These contain dated results; verify current state rather than treating old build numbers as current.
