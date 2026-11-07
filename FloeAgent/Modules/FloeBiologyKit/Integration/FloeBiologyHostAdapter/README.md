# Floe biology host adapter

This separate package connects `FloeBiologyKit` to real `FloeTools`, `FloeModels`, `FloeExecution`, `FloePersistence` and `FloeEnvironments` products. It does not modify the main App or make the standalone component depend on the App. Linking it alone does not change navigation or AI discovery.

## Composition

Use the existing App-owned service instances, not a second job queue, interpreter or environment registry:

```swift
let contexts = BiologyExecutionContexts()
let scientific = BiologyScientificJobs(
    jobs: backgroundJobService,
    registry: toolRegistry,
    environments: environmentRegistry,
    contexts: contexts,
    files: biologyFiles)
let service = try BiologyService(
    store: BiologyProjectStore(root: biologyProjectRoot),
    fileAccess: biologyFiles,
    authorize: authorizeBiologyOperation)
let bridge = BiologyToolBridge(
    service: service,
    contexts: contexts,
    scientificJobs: scientific,
    grant: resolveTaskBiologyGrant,
    registerCreatedProject: recordProjectOwnership)
try await bridge.register(in: toolRegistry)
```

The names ending in `Service`, `Registry`, `Root` and the callbacks above are the host's existing dependencies. `grant` resolves project IDs, creation and read-only authority from the real `ToolContext`; `registerCreatedProject` persists new ownership in that same host system. Neither callback executes analysis or grants authority from JSON. Keep the bridge/service/contexts alive for the workspace, not a view lifetime.

For each ordinary task's effective tool catalog, include `try await bridge.descriptors(for: context)`. The adapter registers all 22 executable tools once, but exposes only current authorized tools. Temporary/public-web-only chat receives none. Dispatch rechecks project grants, allowed/frozen tool ceilings, current task/run/call, cancellation and any exact runtime-authority binding. Provider wire-name encoding/reverse lookup remains the ordinary Floe provider path; do not invent a second alias/executor.

`biology.describe` returns exact optional method schemas and pinned requirements. `biology.methods` lists usable methods plus the selected environment setup hint. A scientific `biology.analyze` against the task's resolved environment runs an actual engine probe, configures the backend from that result, then starts the owned job. A replayed accepted call uses its durable receipt rather than relaunching/probing. Missing packages return engine diagnostics; the AI can use the existing `exec.shell` environment/package workflow. No additional package tool is registered.

## Native scientific launches

The workbench's `executionOwner(projectID, assetID)` callback must resolve/create an ordinary durable task/run with the correct project grant and Linux environment. Probe and configure the actual environment, then bind one native launch:

```swift
let qualified = try await scientific.probe(context: resolvedContext)
let backend = try await scientific.backend(qualified: qualified)
try await service.configureBackend(backend)
let owner = try await contexts.authorizeNative(
    resolvedContext, binding: existingRuntimeAuthorityBinding)
// Return owner from the workbench executionOwner callback.
```

`resolvedContext` and `existingRuntimeAuthorityBinding` come from the host's normal task/approval route. A native binding is consumed once; a model cannot submit a `ToolContext` through arguments. `onAI` also stays on the ordinary App agent/model route. The optional component `BiologyAssistant` supports a real injected provider for another host, not a canned answer.

## Scientific execution and files

`BiologyScientificJobs` accepts Linux VM or Linux SSH environments actually present in `EnvironmentRegistry`. It rejects deleted/rebuilding/foreign-session environments and mismatched context/environment/workspace. Verified worker scripts and exact input are staged through existing scoped `exec.shell`; calculate/staging jobs are recorded in `BackgroundJobService` with exact task/run/tool/call/payload provenance and the original approval binding. No `Process`, native-host Python fallback, generic command from a dataset or installer alias exists.

A completed calculation first commits an output file/length/SHA receipt. Bounded read-back uses the same scoped runner, validates final SHA, then validates the complete worker envelope and exact input/attempt identity before saving a result. File-backed data is streamed in 1 MiB chunks via the host's `BiologyFileAccessing` service and checked again by the worker. File references must match project and selected environment. This initial transport emphasizes bounded correctness; very large upload throughput has not been qualified.

Cancellation stops and joins the actual durable job, and fences later submissions. An unsafe/interrupted job without a real processor-exit acknowledgement remains unresolved and prevents destructive project lifecycle operations. After process restart, the host reconciles its real job records before calling `reconcileStoppedWorker` with the exact project/run/owner/environment. Do not call it merely because a connection disappeared or a status label says interrupted.

`BiologyWorkspaceFiles` is an available concrete importer/exporter. A main-App implementation can bind opaque IDs to its existing granted files. `biology.importProject` can read a saved project through `fileID` + authorized `sourceProjectID` instead of a large base64 argument. Native large-original export additionally needs `prepareNativeExport` / `finishNativeExport`; these URL handoffs are deliberately non-Codable and never tool output. Complete project JSON carries large-file references, not a portable file archive, so import requires fresh explicit file grants or host packaging.

## Focused verification

`Tests/FloeBiologyHostAdapterTests/BridgeContractTests.swift` exercises the real `ToolRunnerRegistry`, real in-memory migrated database, `BackgroundJobService` and `EnvironmentRegistry`: scope/temporary ceilings, native analysis, scientific envelope roundtrip and cancellation. Its `ScientificShellFixture` is explicitly a protocol fixture, not Linux/Python execution. Tests do not weaken ordinary ownership or permission checks.

The current task builds/links adapter sources against the App owner's genuine compiled modules in a separate private qualification target and runs on the single canonical reused iPad. The normal package target is available for App integration; it is not automatically added to main `project.yml`. Actual pinned-CPython scientific numerical tests are recorded separately. Full-App catalog/model calls, real selected Linux execution and physical iPad acceptance still require the integration owner's runtime evidence.

See [component closure evidence](../../../../../docs/FLOE_BIOLOGY_COMPONENT_CLOSURE_20261107.zh-CN.md). This delivery changes no App version, release tag, TestFlight or formal App Store submission.
