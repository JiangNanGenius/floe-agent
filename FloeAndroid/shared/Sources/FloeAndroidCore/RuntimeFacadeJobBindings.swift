// SPDX-License-Identifier: MPL-2.0
//
// G03-R2 — Runtime facade durable-JOB bindings (job-a16c9976985f40b2).
//
// The trusted composition seam between the ORIGINAL durable background-job
// closure (FloeAndroidJobTools: the byte-identical BackgroundJobService /
// NativeJobHandlers originals + the narrow BackgroundJobTools mirror + the
// exec.shell lease-reconcile wait runner) and the Main-owned App/host layer,
// composed OVER the already delivered ORIGINAL LocalShellService path
// (FloeAndroidShellTools + the Core mailbox). NOTHING in this file is
// reachable from model dispatch: no V3 handler key, no tool name, no
// privileged completion surface. Main calls these APIs from its composition
// root and JNI host code only.
//
// Ownership discipline (honest, reused authorities — no parallel systems):
// * The ONLY durable job/env authority remains the ORIGINAL
//   BackgroundJobStore (SQLite, G02 database, migrations V39/V40/V46 already
//   registered in the Android DatabaseManager) and the ORIGINAL
//   BackgroundJobService. This file adds no schema, no shadow job table and
//   no second runner. Call provenance, approval consumption, the effective
//   ceiling, run dependency edges and cancellation reconciliation all ride
//   the original submit() path unchanged (the mirrored JobsSubmitTool still
//   forwards context.callOrigin/childExecution/runtimeAuthority with
//   submissionSource: .runtime; nothing here synthesizes provenance).
// * The live-work view is a RAM-only processor index (JobLiveWorkIndex):
//   ONLY real processor ownership counts. A stored "running" row after a
//   process death is NOT live work — the index starts empty each launch and
//   the original durable recovery path marks unfinished rows interrupted-
//   UNKNOWN. This is the honest on-work-start/settled projection surface for
//   the Core FGS lane (job-4701c875b6dc4737, owned elsewhere; this file
//   deliberately touches NOTHING in core/runlifecycle, RunForegroundBinding.kt
//   or RunForegroundProjection.swift).
// * Cancellation and timeout never terminalize a shell job before the real
//   engine acknowledgment. The job-scoped exec.shell runner (ExecShellJob-
//   Runner) consumes the SAME backend ownedSessions truth Main fixed in the
//   shell ledger (active + reconciliation leases counted; unsettled while
//   claimed dispatch is unresolved) and, for the uncertain-START window
//   (shell.start CLAIMED, waiter expired/disconnected, preparation/process
//   may still exist), it requires the settlement gate below. The gate has
//   NO default and NO stub-true answer here: compose() refuses to register
//   jobs without Main's injected gate, and the adapter treats every
//   non-proven answer as "keep the job nonterminal" until either the engine
//   poll proves leaseReleased, the gate proves quiescence, or the bounded
//   reconciliation ceiling throws NativeJobSafetyFailure (the original
//   "unsafe resource state, not a clean cancellation" honest failure).
// * Root shutdown ordering is Main's: fence local admission → drainJobWork
//   (bounded, honest leftovers) → the existing LinuxShell drain /
//   reconcileLedger → native Root close. Original stores are preserved
//   throughout; nothing here replays or force-settles work.
//
// Admissions (actual-capability-based, per the current Android round):
// * exec.shell — the delivered ORIGINAL shell closure over the mailbox
//   backend (jobs run with the frozen call provenance, environment lease and
//   workspace confinement of the submitting call; the service's
//   "jobs." call-id prefix automatically selects the original 600s
//   background timeout ceiling).
// * web.fetch — admitted ONLY when the app actually registered it in the
//   shared registry at compose time (the factory intersects policy with
//   live runners and JobsSubmitTool validates against that exact set).
// * NOT admitted, never revived here: exec.localService, legacy installers,
//   exec.localPython/exec.javascript/exec.wasm aliases, network.download
//   background URLSession ownership, media/document/video adapters (the
//   ORIGINAL adapter seam stays injectable for later rounds).

import Foundation
import FloeCore
import FloeTools
import FloePersistence
import FloeAgentRuntime
import FloeAndroidShellTools
import FloeAndroidJobTools

public final class RuntimeFacadeJobBindings: @unchecked Sendable {
    public static let shared = RuntimeFacadeJobBindings()

    private struct Plan {
        let database: DatabaseManager
        let shell: LinuxShellComponents
        let transport: any LinuxShellTransport
        let settlementGate: JobShellSettlementGate
        let outputRootURL: URL
        let policy: NativeJobActionPolicy
        let adapters: [String: NativeJobServiceAdapter]
        let onTerminal: (@Sendable (BackgroundJob) async -> Void)?
        let shellConfiguration: ExecShellJobRunnerConfiguration
        let processorOwnership: JobProcessorOwnershipDelegate?
    }

    private let stateLock = NSLock()
    private var planStorage: Plan?
    private var serviceStorage: BackgroundJobService?
    private var jobRegistryStorage: ToolRunnerRegistry?
    private var admittedStorage: Set<String> = []
    /// Synchronous host-delegate storage (set at compose, before register:
    /// no task-scheduling race for the first dispatch).
    private let jobOwnershipBox = JobProcessorOwnershipBox()
    /// RAM-only live processor index (NOT a job store; identities/counts only).
    private let liveIndex: JobLiveWorkIndex

    /// Internal for tests; production uses `.shared` (one per process).
    init() {
        liveIndex = JobLiveWorkIndex(ownership: jobOwnershipBox)
    }

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return body()
    }

    // MARK: - Android job policy (narrow, original handler types)

    /// The Android admitted TARGET set: the ORIGINAL action-policy types,
    /// narrowed to what this platform actually runs. `exec.shell` and
    /// `web.fetch` are single-purpose tools without an `action` field, so
    /// the ORIGINAL `"*"` (any payload) admission is exactly the iOS entry
    /// for them; nothing else is claimed. A target without a registered
    /// runner never reaches execution (the service's own
    /// "not available in this build" refusal and the injected admitted set
    /// fail closed).
    /// `document.office.edit` carries NO directly admitted actions: the
    /// ORIGINAL service admits a deferred payload only when the registered
    /// `NativeJobServiceAdapter` owns its action (`adapter != nil` in
    /// submit), and the Office AI adapter owns exactly `apply`. Reads,
    /// preparatory selection/navigation and `collect` therefore can never be
    /// submitted as jobs (collect must seal into a REAL current call, and a
    /// raw background executor context could never satisfy that — the tool
    /// additionally refuses any `jobs.*` call context by itself).
    public static let androidJobPolicy: NativeJobActionPolicy = NativeJobActionPolicy(handlers: [
        "exec.shell": NativeJobHandler(allowedActions: [NativeJobActionPolicy.anyAction]),
        "web.fetch": NativeJobHandler(allowedActions: [NativeJobActionPolicy.anyAction]),
        "document.office.edit": NativeJobHandler(allowedActions: []),
    ])

    // MARK: - Composition (trusted host only)

    /// Validate the composition inputs and store the plan. Does NOT touch
    /// the shared registry: `register()` performs the actual registration
    /// after Main has ordered the target tools (shell + web) in.
    ///
    /// `settlementGate` is REQUIRED (no default parameter): it is Main's
    /// pump-side proof channel for the uncertain-start window (the Kotlin
    /// LinuxShellPump retains the exact claimed `shell.start` receipt, never
    /// replays, requests the real startup stop and defers FAILURE
    /// completion until UID recovery/quiescence proves idle or
    /// `session.leaseReleased`). Answers must be honest: `.unconfirmed`
    /// keeps jobs nonterminal; there is no stub-true.
    ///
    /// `outputRootURL` is REQUIRED and explicit (mirror delta J2): the
    /// globalApplicationSupport fallback is removed in the job module, so
    /// Main must inject the one trusted, retention-managed root. The root
    /// must be a file URL inside the app's private storage; the bindings
    /// create it fail-closed.
    ///
    /// `processorOwnership` (optional) receives REAL job-processor
    /// start/settle events (identities only) synchronously at composition:
    /// the Core FGS lane attaches its foreground-service ownership around
    /// exactly these transitions (a durable "running" row alone NEVER
    /// counts; only a processor this process actually owns does).
    @discardableResult
    public func compose(
        database: DatabaseManager,
        shell: LinuxShellComponents,
        transport: any LinuxShellTransport,
        settlementGate: @escaping JobShellSettlementGate,
        outputRootURL: URL,
        policy: NativeJobActionPolicy? = nil,
        adapters: [String: NativeJobServiceAdapter] = [:],
        onTerminal: (@Sendable (BackgroundJob) async -> Void)? = nil,
        shellConfiguration: ExecShellJobRunnerConfiguration = ExecShellJobRunnerConfiguration(),
        processorOwnership: JobProcessorOwnershipDelegate? = nil
    ) -> Bool {
        guard outputRootURL.isFileURL, outputRootURL.path != "/" else { return false }
        do {
            try FileManager.default.createDirectory(at: outputRootURL, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let resolvedPolicy = policy ?? Self.androidJobPolicy
        var resolvedAdapters = adapters
        if resolvedPolicy.supportedTargetNames.contains(OfficeDocumentEditTool.name),
           resolvedAdapters[OfficeDocumentEditTool.name] == nil {
            // Idempotent production injection of the ORIGINAL adapter seam:
            // the Office AI deferred apply runs through the SAME Core bridge
            // (ONE capture/model-think/apply invariant for inline + job), and
            // a caller-provided adapter for the target always wins.
            resolvedAdapters[OfficeDocumentEditTool.name] =
                OfficeEditJobAdapter.make(port: OfficeAIHostBridge.shared)
        }
        guard resolvedAdapters.keys.allSatisfy({ resolvedPolicy.supportedTargetNames.contains($0) }) else {
            // An adapter for a target the policy does not admit would be
            // silently unreachable; refuse the plan instead of shipping a
            // dead seam.
            return false
        }
        let resolvedRoot = outputRootURL.standardizedFileURL
        stateLock.lock()
        guard serviceStorage == nil else { stateLock.unlock(); return false }
        planStorage = Plan(
            database: database,
            shell: shell,
            transport: transport,
            settlementGate: settlementGate,
            outputRootURL: resolvedRoot,
            policy: resolvedPolicy,
            adapters: resolvedAdapters,
            onTerminal: onTerminal,
            shellConfiguration: shellConfiguration,
            processorOwnership: processorOwnership
        )
        serviceStorage = nil // re-compose invalidates the previous registration
        admittedStorage = []
        stateLock.unlock()
        // Installed BEFORE register()/any dispatch: synchronous, so the
        // first real processor start can never miss the delegate.
        jobOwnershipBox.set(processorOwnership)
        return true
    }

    public var isComposed: Bool { withState { planStorage != nil } }

    // MARK: - Registration (trusted host only, after target tools exist)

    /// Build the ORIGINAL service over the ORIGINAL G02 stores and register
    /// jobs.submit/status/result/cancel into the EXISTING shared
    /// ToolRunnerRegistry/ToolCatalog via the ORIGINAL factory seam
    /// (mirrored with deltas J1–J3). The BACKGROUND EXECUTION resolves its
    /// target runners from the job-scoped registry: exec.shell wrapped by
    /// the lease-reconcile wait runner, every other admitted target wrapped
    /// only by the live-work tracker. Idempotent: the second call returns
    /// the already-registered service.
    @discardableResult
    public func register() -> BackgroundJobService? {
        // Fast path when already registered: the ORIGINAL factory is not
        // re-run (no duplicate runners, no second service over the store).
        if let existing = withState({ serviceStorage }) {
            publishToolsIfQualified()
            return existing
        }
        guard let plan = withState({ planStorage }) else { return nil }

        let shared = ToolRunnerRegistry.shared
        if plan.policy.supportedTargetNames.contains(OfficeDocumentEditTool.name) {
            // Register the Office AI tool runner BEFORE resolving job targets
            // so the ORIGINAL J1 admitted-set intersection reflects the ACTUAL
            // executable surface (isAvailable = live host lane), never a
            // hoped-for later registration.
            OfficeAIComposition.shared.installToolIfNeeded()
        }
        let jobRegistry = ToolRunnerRegistry()
        var admitted: Set<String> = []
        for target in plan.policy.supportedTargetNames {
            let resolved = shared.runner(named: target) ?? (target == ExecShellJobRunner.toolName
                ? AnyAgentTool(LocalShellTool(shell: plan.shell.service)) : nil)
            guard let inner = resolved else { continue }
            if target == ExecShellJobRunner.toolName {
                let runner = ExecShellJobRunner(
                    inner: inner,
                    backend: plan.shell.backend,
                    transport: plan.transport,
                    gate: plan.settlementGate,
                    index: liveIndex,
                    configuration: plan.shellConfiguration
                )
                jobRegistry.register(runner.makeRunner())
            } else {
                jobRegistry.register(makeJobTrackedRunner(inner: inner, index: liveIndex))
            }
            admitted.insert(target)
        }
        guard !admitted.isEmpty else {
            // No admitted target is actually registered: jobs.submit would
            // advertise an empty set. Fail closed honestly — Main registers
            // the target tools first.
            return nil
        }
        let mainTerminal = plan.onTerminal
        let index = liveIndex
        let service = registerBackgroundJobTools(
            database: plan.database,
            registry: shared,
            policy: plan.policy,
            adapters: plan.adapters,
            onTerminal: { job in
                // Defensive idempotent settle (the wrappers settle the real
                // span; a late terminal callback can never resurrect or
                // double-count work).
                await index.settle(jobID: job.id)
                await mainTerminal?(job)
            },
            outputRootURL: plan.outputRootURL,
            runnerLookup: jobRegistry,
            advertise: false
        )
        stateLock.lock()
        serviceStorage = service
        jobRegistryStorage = jobRegistry
        admittedStorage = admitted
        stateLock.unlock()
        publishToolsIfQualified()
        return service
    }

    /// Service recovery/cancellation exists before device execution is
    /// qualified. Advertisement uses the same real Linux capability gate.
    public func publishToolsIfQualified() {
        guard RuntimeFacadeLinuxBindings.shared.isCapabilityQualified else { return }
        let (service, plan, admitted) = withState { (serviceStorage, planStorage, admittedStorage) }
        guard let service, let plan else { return }
        let registry = ToolRunnerRegistry.shared
        ToolCatalog.register(JobsSubmitTool.self)
        ToolCatalog.register(JobsStatusTool.self)
        ToolCatalog.register(JobsResultTool.self)
        ToolCatalog.register(JobsCancelTool.self)
        registry.register(JobsSubmitTool(service: service, admittedTargets: admitted))
        registry.register(JobsStatusTool(service: service))
        registry.register(JobsResultTool(service: service, outputRoot: plan.outputRootURL))
        registry.register(JobsCancelTool(service: service))
    }

    /// Exact-root retirement after original store/work cleanup. No live
    /// processor/service is replaced by a new generation's composition.
    public func retire(epoch: UInt64) async -> Bool {
        guard let owner = G03JobLifecycle.current, owner.epoch == epoch else { return true }
        guard await owner.stopAndDrain(timeoutMillis: 0), await liveIndex.isIdle() else { return false }
        if let service = withState({ serviceStorage }), !(await service.ownedProcessorIDs()).isEmpty { return false }
        guard await owner.disconnectAfterDrain() else { return false }
        withState {
            serviceStorage = nil; jobRegistryStorage = nil; planStorage = nil; admittedStorage = []
        }
        jobOwnershipBox.set(nil)
        ToolRunnerRegistry.shared.unregister {
            ["jobs.submit", "jobs.status", "jobs.result", "jobs.cancel"].contains($0)
                || $0 == OfficeDocumentEditTool.name
        }
        G03JobLifecycle.uninstall(epoch: epoch)
        return true
    }

    public var service: BackgroundJobService? { withState { serviceStorage } }

    /// The targets jobs.submit actually admits in THIS build right now:
    /// the policy set intersected with registered runners at registration
    /// time. Empty before registration.
    public var admittedJobTargets: Set<String> { withState { admittedStorage } }

    /// The explicit trusted spool root the service was composed with (nil
    /// before compose). Persistence retention and this root MUST be the
    /// same directory — Main owns that wiring.
    public var outputRootURL: URL? { withState { planStorage?.outputRootURL } }

    // MARK: - Live processor projection (Core FGS lane inputs)

    public func liveJobWork() async -> [JobLiveWorkEntry] { await liveIndex.live() }
    public func liveJobWorkCount() async -> Int { await liveIndex.count }
    public func hasLiveJobWork() async -> Bool {
        let idle = await liveIndex.isIdle()
        return !idle
    }

    /// Install the trusted host's start/settled projection observer (the FGS
    /// lane re-reads `liveJobWork()` from the callback). Setting nil removes
    /// it; no synthetic notification is emitted.
    public func setLiveWorkObserver(_ observer: (@Sendable (Int) async -> Void)?) async {
        await liveIndex.setObserver(observer)
    }

    /// Bounded honest drain for the Root-shutdown ordering: true only when
    /// NO real processor is executing in this process at all (including
    /// shell processors waiting for lease release). On timeout it returns
    /// false and the caller must treat `liveJobWork()` as the leftover
    /// truth — never a drained claim without proof.
    public func drainJobWork(timeoutMillis: Int) async -> Bool {
        await liveIndex.waitForIdle(timeoutMillis: timeoutMillis)
    }

    // MARK: - Durable run-dependency projection (Main wires per run)

    /// The ORIGINAL durable edge projection for AgentRuntime's
    /// `outstandingDependencies` configuration: reads ONLY the shared
    /// `run_dependencies` + `background_jobs` rows (never an in-memory job
    /// shadow) and self-heals edges whose terminal callback was lost, in
    /// exactly the iOS ConversationCenter shape. A required job keeps its
    /// submitting run nonterminal across relaunch because the edges live in
    /// the same G02 database.
    public func outstandingRunDependencies(runID: UUID) async -> [RunDependencyLabel] {
        let (service, database): (BackgroundJobService?, DatabaseManager?) = withState {
            (serviceStorage, planStorage?.database)
        }
        guard let database else { return [] }
        let dependencies = SQLiteRunDependencyStore(database: database)
        guard let pending = try? await dependencies.pending(runID: runID), !pending.isEmpty else {
            return []
        }
        var labels: [RunDependencyLabel] = []
        for dependency in pending {
            guard let service, let job = try? await service.job(id: dependency.jobID) else {
                _ = try? await dependencies.resolve(
                    jobID: dependency.jobID, state: .interrupted,
                    note: "The owning job record is gone; its outcome is unknown.")
                continue
            }
            if job.state.isTerminal {
                _ = try? await dependencies.resolve(
                    jobID: dependency.jobID,
                    state: BackgroundJobService.dependencyState(for: job.state),
                    note: job.lastError ?? "job \(job.state.rawValue)")
                continue
            }
            // Android admits no long-lived service targets this round, so a
            // "service" kind edge (only ever written for exec.localService
            // by the ORIGINAL service) is held as outstanding until its
            // real job row reaches a terminal state — never a guessed
            // readiness.
            labels.append(RunDependencyLabel(
                identifier: job.id.uuidString,
                kind: dependency.kind,
                label: job.targetTool))
        }
        return labels
    }

    // MARK: - Launch reconciliation + cancellation (original semantics)

    /// Marks every durable non-terminal job whose processor is NOT live in
    /// this process interrupted/UNKNOWN (the ORIGINAL durable recovery
    /// path; retired-target and dependency resolution included). Call once
    /// after the G02 composition registers jobs, before admission of new
    /// runs. Process death never restores fake "running" state.
    @discardableResult
    public func reconcileInterruptedOnLaunch() async throws -> Int {
        guard let service = withState({ serviceStorage }) else { return 0 }
        return try await service.reconcileInterruptedOnLaunch()
    }

    /// The ORIGINAL cancellation entry: REQUESTS a stop, keeps the job
    /// non-terminal until the processor acknowledges (for shell jobs the
    /// wait runner routes the REAL `shell.cancel` to the exact engine
    /// session / startup receipt and holds until release/quiescence), and
    /// returns the current durable row.
    public func cancelOwnedJob(id: UUID) async throws -> BackgroundJob? {
        guard let service = withState({ serviceStorage }) else {
            throw FloeError.invalidConfiguration("background jobs are not composed in this build")
        }
        return try await service.cancel(id: id)
    }

    /// Ownership-resolved read (durable run ownership, not a caller-supplied
    /// task id), for Main's UI/notification projections.
    public func ownedJob(id: UUID, runID: UUID) async throws -> BackgroundJob {
        guard let service = withState({ serviceStorage }) else {
            throw FloeError.invalidConfiguration("background jobs are not composed in this build")
        }
        return try await service.ownedJob(id: id, runID: runID)
    }

    // MARK: - Diagnostics (typed counts only; never payloads/commands/output)

    public func statsJSON() -> String {
        let (composed, registered, admitted, epochShellBound): (Bool, Bool, [String], Bool) = withState {
            (planStorage != nil, serviceStorage != nil, admittedStorage.sorted(),
             RuntimeFacadeLinuxBindings.shared.components != nil)
        }
        let object: [String: Any] = [
            "composed": composed,
            "registered": registered,
            "admittedTargets": admitted,
            "shellComponentsPresent": epochShellBound,
            "spoolRootConfigured": withState { planStorage?.outputRootURL != nil },
            "liveWorkCount": "async://liveJobWorkCount",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"stats_encoding\"}"
        }
        return string
    }
}

// MARK: - Trusted-host C ABI (JNI; no model route)

/// Sync composition/registration diagnostics (typed counts; never payloads).
@_cdecl("floe_jobs_stats")
public func floeJobsStats(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    let text = RuntimeFacadeJobBindings.shared.statsJSON()
    guard let buffer, capacity > 0 else { return -105 }
    let bytes = Array(text.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return -106 }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}

/// Bounded honest drain for the Root-shutdown path (trusted host thread
/// only; blocks the calling host thread up to the given window).
/// Returns 1 drained, 0 leftovers remain at timeout, -105 not composed.
private final class JobDrainBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32 = 0
    func set(_ newValue: Int32) { lock.lock(); value = newValue; lock.unlock() }
    var current: Int32 { lock.lock(); defer { lock.unlock() }; return value }
}

@_cdecl("floe_jobs_drain")
public func floeJobsDrain(_ timeoutMillis: Int32) -> Int32 {
    guard timeoutMillis >= 0, timeoutMillis <= 60_000 else { return -105 }
    let semaphore = DispatchSemaphore(value: 0)
    let box = JobDrainBox()
    Task {
        let owned = await G03JobLifecycle.current?.stopAndDrain(timeoutMillis: Int(timeoutMillis)) ?? true
        let processors = await RuntimeFacadeJobBindings.shared.drainJobWork(timeoutMillis: 0)
        let drained = processors && owned
        box.set(drained ? 1 : 0)
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + .milliseconds(Int(max(0, timeoutMillis)) + 500)) == .timedOut {
        return 0 // never claim drained without proof
    }
    return box.current
}

// MARK: - EXACT Main wiring points (NOT performed by this package)
//
// 1. Package.swift (Main-serialized):
//    .target(name: "FloeAndroidJobTools", dependencies: [
//        "FloeCore", "FloeModels", "FloeTools", "FloePersistence",
//        "FloeAndroidShellTools",
//        .product(name: "Crypto", package: "swift-crypto")], swiftSettings: strictSettings)
//    FloeAndroidCore dependencies gain "FloeAndroidJobTools".
//    .testTarget(name: "FloeAndroidJobToolsTests", dependencies: [
//        "FloeAndroidJobTools", "FloeAndroidShellTools", "FloeCore", "FloeTools",
//        "FloeModels", "FloePersistence",
//        .product(name: "Crypto", package: "swift-crypto")], swiftSettings: strictSettings)
// 2. Composition order (after RuntimeFacadeLinuxBindings.shared.compose +
//    bindMailboxEpoch + registerIntoCurrentGeneration, and after the Web
//    tools registration if web.fetch should be admitted):
//    RuntimeFacadeJobBindings.shared.compose(
//        database: <G02 owned DatabaseManager>,
//        shell: RuntimeFacadeLinuxBindings.shared.components!,
//        transport: MailboxLinuxShellTransport(),
//        settlementGate: <Kotlin pump-backed proof — REQUIRED, honest
//            .unconfirmed until quiescence/leaseReleased>,
//        outputRootURL: <trusted app-private job-output root, the SAME root
//            FloePersistence run-lifecycle retention prunes>,
//        onTerminal: <FGS terminal projection / run steer>)
//    then register() ONCE.
// 3. Per-run AgentRuntime configuration must wire
//    outstandingDependencies: { await RuntimeFacadeJobBindings.shared
//    .outstandingRunDependencies(runID: runID) } (same closure shape as
//    iOS ConversationCenter). Without it a required job cannot hold its run
//    nonterminal — the durable edges still exist, the projection is the
//    consumer.
// 4. Launch: after register(), call reconcileInterruptedOnLaunch() once
//    before admitting runs (marks store-only "running" rows UNKNOWN per the
//    original durable recovery semantics).
// 5. Root shutdown ordering: fence local admission →
//    drainJobWork/reconcile (bounded) → RuntimeFacadeLinuxBindings
//    .drainLinuxShell + reconcileLedger → native Root close. Live shell-job
//    processors surface through the shared shell ledger (their dispatch
//    hook attaches before the backend call and ends only on real
//    settlement; owner ids are linux-shell:<runID>:jobs.<jobID>).
// 6. FGS lane: consume liveJobWork()/setLiveWorkObserver ONLY for REAL
//    processors; a durable "running" row after process death must never
//    hold a foreground service (launch reconcile turns it interrupted).
// 7. Core credentials/history boundary: unchanged and NOT weakened here —
//    jobs dispatch through the same facade tool path; the mailbox still
//    never carries Core credentials or history into the runtime.
