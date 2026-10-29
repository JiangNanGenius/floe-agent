// SPDX-License-Identifier: MPL-2.0
//
// G03-R2 — Runtime facade Linux shell bindings (job-1bd4fcce5eca4856).
//
// The trusted composition seam between the ORIGINAL shell closure
// (FloeAndroidShellTools: LocalShellService + ShellSessionCenter +
// AndroidLinuxShellBackend over the typed `LinuxShellTransport`) and the
// Main-owned App/host layer. NOTHING in this file is reachable from model
// dispatch: there is no V3 handler key, no tool name and no privileged
// completion surface here. Main calls these APIs from its composition root
// and JNI host code only.
//
// Ownership discipline (honest, reused authorities — no parallel systems):
// * The ONLY durable task authority remains the ORIGINAL
//   BackgroundJobStore/BackgroundJobService. The mailbox tickets are
//   transient transport receipts; this file starts no job DB, writes no
//   durable record and must not be used to build one. (The full
//   background-service port is the separate follow-up integration after
//   this handoff; until then jobs.submit's durable replay stays with the
//   original service, unchanged, and nothing here duplicates it.)
// * Owned-worker bookkeeping REUSES the existing
//   `FacadeToolWorkCoordinator` (RB6) instance Main passes in: begin
//   BEFORE the awaited dispatch, end only on a SETTLED dispatch,
//   epoch-fenced cancellation through the SAME ledger, and the RB4
//   `RunOwnedToolCancellation` port shape for run/task/call cancel.
//   No second registry, no approval system, no per-call semaphore.
// * Core root/epoch authority comes from the existing native Root epoch
//   admission (`AndroidRuntimeBootstrap.currentPumps()` /
//   `G02NativeRootEpoch.readback()`); this file never mints an epoch and
//   never accepts 0-as-epoch.
// * Cancellation is NONTERMINAL until the engine proves the real stop:
//   cancelling a Core-side wait still requests `shell.cancel` remotely
//   (the backend issues it on its cancellation channel) and the ledger
//   worker stays attached until `leaseReleased` is observed. EOF != exit.
//
// Readiness truthfulness (G03-R3: trusted live ingress, fail-closed):
// * Until the trusted host INGESTS every real fact for the live generation
//   through `LinuxReadinessIngress` (dedicated runtime UID distinct from
//   Core's own + package cert digest + version + binder identity, engine
//   connected identity, the LIVE mailbox epoch cross-checked against the
//   original mailbox bind, rootfs install receipt, workspace mapping proven
//   ONLY by a terminal-index digest Core reads back from the ORIGINAL
//   engine tree, lease authority, and the acknowledged single-workload
//   contract), `isCapabilityQualified` is FALSE and every exec.shell
//   dispatch fails closed inside the backend with preparation guidance —
//   never a host-interpreter fallback. The old wholesale-override setter
//   and the allTrue initializer are GONE (R3 review).
// * "installed" or "connected" alone NEVER qualifies; the engine workspace
//   is physically distinct from the Core workspace and file exchange is
//   Main integration work, so workspaceMappingSynced stays false until the
//   real mapping receipt exists on the engine tree.
// * Stale epoch, invalidation, failed map or stop fence dispatch AND
//   discovery coherently (one live predicate); the cleanup lane and the
//   mailbox poller stay usable until real settlement.
// * Temporary chat NEVER forces this true (the existing tool ceiling and
//   capability overrides stay authoritative).
// * `runtimeConfiguration` is NOT altered here: the exact wiring points are
//   listed at the bottom of this file for Main's serialized integration.
import Foundation
import FloeCore
import FloeTools
import FloeAndroidShellTools

// MARK: - Readiness (trusted live ingress; default fail closed)

/// Closed capability fields for running Linux shell work. Every field
/// defaults FALSE and the members are NOT settable from outside this
/// module's ingress authority: since G03-R3 the ONLY way a field turns
/// true is a real per-generation ingestion through
/// `LinuxReadinessIngress.shared.ingest(_:rootEpoch:)` (trusted host JNI
/// over the actual package distinct-UID/certificate/version/binder
/// identity, the live mailbox epoch, rootfs installation, engine-receipt
/// read back workspace mapping/lease authority, and the acknowledged
/// single-workload contract). The compiled default stays FALSE until
/// those real host facts exist. These fields are DIAGNOSTICS — the
/// single authority is `isCapabilityQualified` below, which ANDs them
/// with the injected predicate (in production that predicate is the SAME
/// live ingress authority; see `LinuxShellLiveReadiness`).
public struct LinuxShellQualificationFields: Sendable, Equatable {
    public internal(set) var runtimeUidBoundaryVerified: Bool
    public internal(set) var engineConnected: Bool
    public internal(set) var mailboxEpochBound: Bool
    public internal(set) var rootfsQualified: Bool
    /// The honest gate for workspace visibility: the engine workspace and
    /// the ORIGINAL Core workspace are physically different trees; file
    /// import/export mapping/sync is Main-owned integration. FALSE keeps
    /// shell work unqualified regardless of install/connect state. The
    /// ingress ONLY accepts this fact from a terminal-index receipt Core
    /// reads back from the ORIGINAL engine tree — never from a flag.
    public internal(set) var workspaceMappingSynced: Bool
    public internal(set) var leaseAuthorityQualified: Bool
    /// One active local workload globally is the engine's CURRENT contract
    /// (RuntimeKernel/LinuxRuntimeOperations); a multi-workload engine would
    /// be an engine change first, and this field must not be flipped by the
    /// App alone.
    public internal(set) var singleWorkloadContractAcknowledged: Bool

    /// Compiled default: every field FALSE. There is deliberately NO
    /// allTrue initializer (the R3 review removed the bulk override).
    public init() {
        self.runtimeUidBoundaryVerified = false
        self.engineConnected = false
        self.mailboxEpochBound = false
        self.rootfsQualified = false
        self.workspaceMappingSynced = false
        self.leaseAuthorityQualified = false
        self.singleWorkloadContractAcknowledged = false
    }

    public var allFieldsTrue: Bool {
        runtimeUidBoundaryVerified && engineConnected && mailboxEpochBound
            && rootfsQualified && workspaceMappingSynced && leaseAuthorityQualified
            && singleWorkloadContractAcknowledged
    }
}

/// The injected readiness answer used by the backend and the ledger.
/// Production installs one that reads the LIVE qualification state; the
/// compiled default is permanently unqualified (fail closed).
public struct LinuxShellInjectedReadiness: LinuxShellReadiness {
    public let predicate: @Sendable () -> Bool
    public init(predicate: @escaping @Sendable () -> Bool) {
        self.predicate = predicate
    }
    /// The default: nothing configured => nothing qualified.
    public static let unconfigured = LinuxShellInjectedReadiness { false }
    public var isQualifiedForLinuxShell: Bool { predicate() }
    public var refusalGuidance: String {
        "status=engineUnqualified reason=linuxShellNotQualified\nThe Linux engine runtime UID/rootfs/workspace/lease capability is not fully qualified on this device. Nothing was executed and no host fallback was used. Open the runtime setup, complete installation, and wait until the App reports the workspace mapping as synced, then retry."
    }
}

// MARK: - Composed components

public struct LinuxShellComponents: Sendable {
    public let backend: AndroidLinuxShellBackend
    public let service: LocalShellService
    public let sessions: ShellSessionCenter
    /// Engine session identities stay owned by the backend; the facade keeps
    /// the ledger bridge (`reconcileLedger`) to settle owned workers only on
    /// REAL lease releases.
}

// MARK: - Facade bindings

public final class RuntimeFacadeLinuxBindings: @unchecked Sendable {
    public static let shared = RuntimeFacadeLinuxBindings()

    /// Owner prefix for shell ledger workers. Exact identity:
    /// `linux-shell:<runID>:<callID|client-token>` — run/call scoped, never
    /// derived from session text.
    private static let ownerPrefix = "linux-shell:"

    private let stateLock = NSLock()
    private var componentsStorage: LinuxShellComponents?
    private var coordinatorStorage: FacadeToolWorkCoordinator?
    private var readinessStorage: LinuxShellReadiness = LinuxShellInjectedReadiness.unconfigured
    private var boundEpoch: UInt64 = 0
    /// RAM-only shell-scoped view over the reused coordinator ledger:
    /// worker.id -> (runID, callID?, recordedAt). This is NOT a job store;
    /// it exists so the shell cancellation adapter refuses non-shell
    /// (runID, callID) pairs exactly and so unsettled workers can be
    /// reconciled after real lease release. Bounded by the coordinator's
    /// own 128-live-worker ceiling.
    ///
    /// G03-R2 deletion-lifetime contract (coordinator steer 20261022): the
    /// entry ALSO carries the EXACT conversation identity taken from the
    /// ORIGINAL ToolContext and the REAL RuntimeOwnedWorkRegistry receipt
    /// attached for the dispatch. A detached exec.shell whose parent run is
    /// already terminal stays addressable per conversation, so the
    /// ORIGINAL deletion fence cannot erase a workspace while a retained
    /// shell/Core export callback is still running. Dispatch without the
    /// original conversation binding fails closed at admission (nil hook
    /// receipt ⇒ LocalShellService refuses).
    private struct LedgerEntry: Sendable {
        let runID: UUID
        let callID: String?
        let epoch: UInt64
        var dispatchSettled: Bool
        let conversationID: UUID
        let workToken: RuntimeOwnedWorkToken
        // Recomposition may replace current components before an old
        // dispatch settles. Only its original actors can prove release.
        let backend: AndroidLinuxShellBackend
        let coordinator: FacadeToolWorkCoordinator
    }
    private var ledgerIndex: [String: LedgerEntry] = [:]
    /// Workers for which the conversation-deletion fence has already issued
    /// ONE cooperative stop request (re-requesting is harmless but the
    /// insert guard keeps the tick honest and side-effect-free after the
    /// first). Cleared when the worker really ends.
    private var conversationStopRequested: Set<String> = []
    /// One service-owned proof recheck for each settled dispatch; an
    /// unproven lease retains its exact ledger entry and registry token.
    private var releaseReconcileScheduled: Set<String> = []
    /// G05-R3 exact operation IDs whose run-less terminal first-use receipt is
    /// still owned. Registration happens BEFORE any binding/preflight await,
    /// so an uncertain reply cannot create a mailbox-empty drain race. These
    /// are lifecycle guards only: no global drain or readiness decision reads
    /// them, and each ID clears only after its REAL conversation receipt ends.
    private var firstEntryOwnershipIDs: Set<UUID> = []

    /// Internal for tests; production uses `.shared` (one per process).
    init() {}

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return body()
    }

    // MARK: Composition (trusted host only)

    /// Build the ORIGINAL service path over the typed engine transport and
    /// the reused owned-worker coordinator. Calling this does NOT register
    /// any tool (Main's serialized composition decides registration); it
    /// only makes the components available. Idempotent replacement retires
    /// the previous generation's LOCAL objects; engine leases of the old
    /// generation stay owned for reconciliation (never replayed).
    ///
    /// `environmentDefaults` stays EMPTY by contract: the engine now
    /// carries the EXPLICIT per-request caller env (bounds-checked against
    /// the engine rules in the backend), but composition-time defaults are
    /// precisely the injection channel for the Main process environment or
    /// stored credentials, which is forbidden here. Non-empty defaults are
    /// refused at wiring time (fail closed).
    @discardableResult
    public func compose(
        transport: LinuxShellTransport = MailboxLinuxShellTransport(),
        coordinator: FacadeToolWorkCoordinator,
        rootProvider: @escaping @Sendable () async -> URL?,
        readiness: LinuxShellReadiness = LinuxShellInjectedReadiness.unconfigured,
        journal: ShellOperationJournal = ShellOperationJournal(),
        environmentDefaults: [String: String] = [:]
    ) -> LinuxShellComponents? {
        guard environmentDefaults.isEmpty else {
            // Fail closed at composition: defaults are the Main-process /
            // credential injection channel the typed seam forbids. Only
            // explicit per-request caller env rides the engine wire.
            return nil
        }
        let hook = LinuxShellCallTrackingHook(onDispatch: { [weak self] context in
            guard let self else { return nil }
            return await self.beginLedgerWorker(for: context)
        })
        let backend = AndroidLinuxShellBackend(transport: transport, readiness: readiness)
        let service = LocalShellService(
            backend: backend,
            journal: journal,
            environmentDefaults: environmentDefaults,
            trackingHook: hook,
            rootProvider: rootProvider
        )
        let sessions = ShellSessionCenter(backend: backend)
        stateLock.lock()
        componentsStorage = LinuxShellComponents(backend: backend, service: service, sessions: sessions)
        coordinatorStorage = coordinator
        readinessStorage = readiness
        stateLock.unlock()
        return LinuxShellComponents(backend: backend, service: service, sessions: sessions)
    }

    public var components: LinuxShellComponents? {
        stateLock.lock(); defer { stateLock.unlock() }
        return componentsStorage
    }

    /// The live derived qualification fields (diagnostics + the single
    /// authority every gate reads). There is NO setter: values come only
    /// from trusted per-generation ingestion through
    /// `LinuxReadinessIngress` (see the struct docs above).
    public var qualificationFields: LinuxShellQualificationFields {
        LinuxReadinessIngress.shared.derivedFields()
    }

    /// Stop new execution while keeping the receipt/proof channel alive
    /// for actual cleanup. Closing the mailbox first would strand jobs.
    /// REAL admission fence (Main review 2026-10-22): the generation is
    /// MARKED suspended inside the readiness authority — late callbacks
    /// cannot re-ingest facts while the old Root/mailbox stays bound only
    /// for cleanup/proof drain. Positive readiness returns ONLY via an
    /// explicit `resumeAdmissions` for the same live epoch or a strictly
    /// newer accepted generation, and always needs full re-ingestion.
    public func suspendAdmissions(epoch: UInt64) -> Bool {
        withState {
            guard epoch != 0, boundEpoch == epoch else { return false }
            return LinuxReadinessIngress.shared.suspendAdmissions(epoch: epoch)
        }
    }

    /// The legitimate same-generation re-admission (trusted host lifecycle;
    /// mirrored by `floe_linux_readiness_resume_admissions`). Never restores
    /// facts by itself: the host must re-ingest real evidence afterwards.
    @discardableResult
    public func resumeAdmissions(epoch: UInt64) -> Bool {
        withState {
            guard epoch != 0, boundEpoch == epoch else { return false }
            return LinuxReadinessIngress.shared.resumeAdmissions(epoch: epoch)
        }
    }

    public var boundNativeEpoch: UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return boundEpoch
    }

    /// The ONLY truthful capability answer for `localLinuxGuestEnvironment`
    /// style gating: composed + mailbox epoch bound + every TRUSTED
    /// INGESTED field + the injected live predicate. Defaults false.
    /// Temporary chat, "installed" or "connected" alone NEVER satisfy it.
    /// Production's injected predicate IS the same live ingress authority
    /// (`LinuxShellLiveReadiness.makeInjected()` in the G02 composition),
    /// so qualification, dispatch and ordinary route discovery read ONE
    /// live predicate.
    public var isCapabilityQualified: Bool {
        stateLock.lock()
        let composed = componentsStorage != nil
        let epoch = boundEpoch
        let readiness = readinessStorage
        stateLock.unlock()
        return composed && epoch != 0
            && LinuxReadinessIngress.shared.derivedFields().allFieldsTrue
            && readiness.isQualifiedForLinuxShell
    }

    // MARK: Mailbox generation (trusted host lifecycle)

    /// Bind the transport mailbox to the ACTUAL accepted native Root epoch.
    /// The host must pass the same authoritative value it received from the
    /// native Root epoch readback; when the bootstrap's live pumps are
    /// readable, the value is cross-checked and a mismatch is refused
    /// (never a guessed 0, never a UI counter).
    @discardableResult
    public func bindMailboxEpoch(_ epoch: UInt64) -> Bool {
        guard epoch != 0 else { return false }
        if let pumps = AndroidRuntimeBootstrap.currentPumps(), pumps.epoch != epoch {
            return false
        }
        guard LinuxShellMailbox.shared.bind(epoch: epoch) else { return false }
        stateLock.lock()
        boundEpoch = epoch
        stateLock.unlock()
        return true
    }

    /// Generation fence entry (trusted host): marks the mailbox closed so
    /// every waiter receives the typed `hostFenced` result, INVALIDATES
    /// every readiness fact (the next generation must re-ingest real
    /// evidence; nothing stays qualified across a fence), and signals the
    /// shell ledger workers for `epoch` to accelerate cooperative
    /// cancellation. Owned workers are NOT ended here: their remote leases
    /// stay owned until `reconcileLedger()` proves the real release. The
    /// runtime-cleanup lane and the mailbox poller are deliberately NOT
    /// closed: the cleanup/proof channel stays available until real
    /// settlement.
    public func fenceGeneration(epoch: UInt64) {
        let coordinators: [FacadeToolWorkCoordinator] = withState {
            guard epoch != 0, boundEpoch == epoch else { return [] }
            boundEpoch = 0
            LinuxShellMailbox.shared.close()
            LinuxReadinessIngress.shared.invalidate(nil, reason: "generationFenced")
            var seen: Set<ObjectIdentifier> = []
            var owners = ledgerIndex.values.filter { $0.epoch == epoch }.map { $0.coordinator }
            if let current = coordinatorStorage { owners.append(current) }
            return owners.filter { seen.insert(ObjectIdentifier($0)).inserted }
        }
        Task { for coordinator in coordinators { await coordinator.fenceEpoch(epoch: epoch) } }
    }

    /// Marks one exact first-use operation receipt as physically owned BEFORE
    /// its SQLite/host work starts. Idempotent by operation identity; internal
    /// to the Core terminal domain, never a host/model API.
    func retainFirstEntryOwnership(_ operationID: UUID) {
        withState { _ = firstEntryOwnershipIDs.insert(operationID) }
    }

    /// Clears that guard only after the original operation mapping and real
    /// conversation receipt ended. Idempotent, but never called on a waiter
    /// timeout, generation fence, unknown ticket or premature table absence.
    func releaseFirstEntryOwnership(_ operationID: UUID) {
        withState { _ = firstEntryOwnershipIDs.remove(operationID) }
    }

    /// Honest drain checkpoint for lifecycle gates (shutdown / generation
    /// handover): true only when no transport receipt is live, no run-less
    /// first-use conversation receipt is retained, AND the backend has no
    /// lease awaiting release proof. Keeping the pure observation mailbox
    /// bound until these guards clear is what lets stop() cancel real IO,
    /// observe its settlement, and only then fence the original channel.
    public func isDrained() async -> Bool {
        await isDrained(mailbox: .shared)
    }

    /// Internal injectable mailbox for focused regressions; production uses
    /// the ORIGINAL shared mailbox through the public overload above.
    func isDrained(mailbox: LinuxShellMailbox) async -> Bool {
        let (components, hasWorkers, hasFirstEntryOwnership) = withState {
            (componentsStorage, !ledgerIndex.isEmpty, !firstEntryOwnershipIDs.isEmpty)
        }
        guard !hasWorkers, !hasFirstEntryOwnership, !mailbox.hasLiveTickets else { return false }
        guard let components else { return true }
        let owned = await components.backend.ownedSessions()
        let slotBusy = await components.backend.isEngineSlotBusy()
        return owned.isEmpty && !slotBusy
    }

    public func drainLinuxShell(timeoutMillis: Int) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(max(0, timeoutMillis)) &* 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await isDrained() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
            if Task.isCancelled { return await isDrained() }
        }
        return await isDrained()
    }

    // MARK: Owned-work ledger (reuses FacadeToolWorkCoordinator)

    /// Bridge called by the ORIGINAL service path (via the trusted
    /// `LinuxShellCallTrackingHook` injected at compose time) immediately
    /// before a real backend dispatch. Returns the settlement closure the
    /// service invokes after the backend returned AND the journal recorded.
    /// A configured hook refusal blocks dispatch in LocalShellService;
    /// no new process may run without its actual Root work ownership.
    private func beginLedgerWorker(for context: ToolContext) async -> (@Sendable () -> Void)? {
        let (coordinator, epoch, components) = withState { (coordinatorStorage, boundEpoch, componentsStorage) }
        guard let coordinator, epoch != 0, let components else { return nil }
        // G03-R2 deletion-lifetime contract (coordinator steer 20261022):
        // fail closed at admission WITHOUT the ORIGINAL conversation
        // binding. The deletion fence's target-only drain and the workspace
        // authority both key on this exact identity; nothing is guessed
        // (no first-workspace, no orphan-run inference).
        guard let conversationID = context.conversationID else { return nil }
        let callIdentity = context.toolCallID ?? context.clientScopedSessionToken
        let ownerID = Self.ownerPrefix + context.runID.uuidString + ":" + callIdentity
        let runID = context.runID
        let callID = context.toolCallID
        // Attach the REAL RuntimeOwnedWorkRegistry receipt BEFORE dispatch
        // (durable-job lane precedent, kind `.tool`): retained shell work
        // then participates in owned root/DB quiescence and produces
        // genuine per-conversation fence evidence. A refused/invalid attach
        // means the dispatch could not be tracked — it is refused, never
        // run untracked.
        let registryOwner = "linux-shell:" + conversationID.uuidString + ":" + runID.uuidString
        guard case let .attached(workToken) =
                RuntimeOwnedWorkRegistry.shared.attach(epoch: epoch, kind: .tool,
                                                       ownerID: registryOwner) else {
            return nil
        }
        guard case let .success(worker) = await coordinator.begin(ownerID: ownerID, runID: runID,
                                                                   callID: callID, epoch: epoch) else {
            RuntimeOwnedWorkRegistry.shared.detach(workToken)
            return nil
        }
        let workerID = worker.id
        // Cooperative cancel path: cancelling the ledger worker cancels the
        // run's OWN per-call CancellationToken object (the token the backend
        // polls), which makes the backend request the remote stop. The
        // backend still refuses to treat the request as a stop until the
        // engine proves `leaseReleased`. Cancellation NEVER detaches the
        // registry token and NEVER ends the ledger entry here.
        await coordinator.attachTaskCancel(workerID) {
            context.cancellation.cancel()
        }
        let backend = components.backend
        withState { ledgerIndex[workerID] = LedgerEntry(
            runID: runID, callID: callID, epoch: epoch, dispatchSettled: false,
            conversationID: conversationID, workToken: workToken,
            backend: backend, coordinator: coordinator) }
        return { [coordinator, backend, workerID, runID, workToken] in
            Task { [weak self] in
                guard let self else { return }
                self.withState { self.ledgerIndex[workerID]?.dispatchSettled = true }
                // Target-scoped release predicate: THIS run's engine leases
                // and THIS run's claimed shell.start tickets. Unrelated
                // conversations' tickets no longer hold a settled target
                // worker open (the global `hasLiveTickets` stays in
                // `isDrained()`, which legitimately waits for everything at
                // process retirement).
                let pendingLease = !(await backend.ownedSessions(runID: runID).isEmpty)
                    || LinuxShellMailbox.shared.hasLiveTickets(runID: runID)
                if pendingLease {
                    // Keep ownership until this dispatch's real release
                    // proof arrives, including while its root is paused.
                    self.scheduleReleaseReconcile(workerID: workerID)
                    return
                }
                await coordinator.end(workerID)
                let ended = self.withState { () -> Bool in
                    guard self.ledgerIndex[workerID]?.workToken == workToken else { return false }
                    self.ledgerIndex.removeValue(forKey: workerID)
                    self.conversationStopRequested.remove(workerID)
                    return true
                }
                if ended { RuntimeOwnedWorkRegistry.shared.detach(workToken) }
            }
        }
    }

    /// Reconcile the ledger: end workers whose run's leases are all
    /// proven-released. Trusted host pump (Main may call it from its
    /// lifecycle drain); idempotent and bounded by the ledger itself.
    @discardableResult
    public func reconcileLedger() async -> Int {
        let snapshot = withState { ledgerIndex }
        var ended = 0
        for (workerID, entry) in snapshot {
            guard entry.dispatchSettled,
                  !LinuxShellMailbox.shared.hasLiveTickets(runID: entry.runID) else { continue }
            let pendingLease = !(await entry.backend.ownedSessions(runID: entry.runID).isEmpty)
            if pendingLease { continue }
            await entry.coordinator.end(workerID)
            let removed = withState { () -> Bool in
                guard ledgerIndex[workerID]?.workToken == entry.workToken else { return false }
                ledgerIndex.removeValue(forKey: workerID)
                conversationStopRequested.remove(workerID)
                return true
            }
            if removed {
                RuntimeOwnedWorkRegistry.shared.detach(entry.workToken)
                ended += 1
            }
        }
        return ended
    }

    /// A paused root has no external drain pump. Recheck only the original
    /// dispatch's actors; a new empty backend is not proof about old work.
    private func scheduleReleaseReconcile(workerID: String) {
        let first = withState { () -> Bool in
            guard ledgerIndex[workerID] != nil else { return false }
            return releaseReconcileScheduled.insert(workerID).inserted
        }
        guard first else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.withState { _ = self.releaseReconcileScheduled.remove(workerID) } }
            while true {
                let owned = self.withState { () -> LedgerEntry? in
                    guard let entry = self.ledgerIndex[workerID], entry.dispatchSettled else { return nil }
                    return entry
                }
                guard let owned else { return }
                let leaseFree = await owned.backend.ownedSessions(runID: owned.runID).isEmpty
                let ticketFree = !LinuxShellMailbox.shared.hasLiveTickets(runID: owned.runID)
                if leaseFree && ticketFree {
                    await owned.coordinator.end(workerID)
                    let removed = self.withState { () -> Bool in
                        guard self.ledgerIndex[workerID]?.workToken == owned.workToken else { return false }
                        self.ledgerIndex.removeValue(forKey: workerID)
                        self.conversationStopRequested.remove(workerID)
                        return true
                    }
                    if removed { RuntimeOwnedWorkRegistry.shared.detach(owned.workToken) }
                    return
                }
                // No time budget can convert an unproven lease to release.
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return } // ownership remains for the existing drain/fence
            }
        }
    }

    // MARK: Conversation-deletion surface (ORIGINAL fence, target-only)

    /// REAL registry receipts currently held by retained shell work for
    /// EXACTLY this conversation+generation. Other conversations and global
    /// counts never appear (per-conversation drain rule). Empty when the
    /// lane never dispatched for the target.
    public func tokensForConversation(_ conversationID: UUID, epoch: UInt64)
        -> [RuntimeOwnedWorkToken]
    {
        withState {
            ledgerIndex.values
                .filter { $0.conversationID == conversationID && $0.epoch == epoch }
                .map { $0.workToken }
        }
    }

    /// One bounded tick under the ORIGINAL conversation deletion fence,
    /// alongside the durable-job lane tick. For EXACTLY (conversationID,
    /// epoch) ledger entries: unsettled dispatches receive ONE cooperative
    /// stop request through the existing real worker-token chain; settled
    /// entries end (coordinator + registry detach) only when THIS run's
    /// engine leases AND shell.start claims are proven released. Returns
    /// true only when NO target entry remains. Cancellation/timeout/EOF
    /// never counts as quiescence, and an unrelated conversation can never
    /// block (or be blocked by) this tick.
    public func drainConversationTick(conversationID: UUID, epoch: UInt64) async -> Bool {
        let snapshot = withState {
            ledgerIndex.filter { _, entry in entry.conversationID == conversationID && entry.epoch == epoch }
        }
        for (workerID, entry) in snapshot {
            if !entry.dispatchSettled {
                let first = withState { conversationStopRequested.insert(workerID).inserted }
                if first {
                    _ = await entry.coordinator.cancelOwnedToolMatches(
                        runID: entry.runID, callID: entry.callID, epoch: epoch)
                }
                continue
            }
            let pendingLease = !(await entry.backend.ownedSessions(runID: entry.runID).isEmpty)
                || LinuxShellMailbox.shared.hasLiveTickets(runID: entry.runID)
            if pendingLease { continue }
            await entry.coordinator.end(workerID)
            let removed = withState { () -> Bool in
                guard ledgerIndex[workerID]?.workToken == entry.workToken else { return false }
                ledgerIndex.removeValue(forKey: workerID)
                conversationStopRequested.remove(workerID)
                return true
            }
            if removed { RuntimeOwnedWorkRegistry.shared.detach(entry.workToken) }
        }
        return withState {
            !ledgerIndex.values.contains { $0.conversationID == conversationID && $0.epoch == epoch }
        }
    }

    // MARK: Cancellation adapter (RB4 RunOwnedToolCancellation shape)

    /// The run/task/call cancellation entry Main binds from the existing
    /// `run.skillcancel`-style owned-tool port wiring for the Linux shell
    /// domain. Matches ONLY shell-owned ledger workers for the exact
    /// (runID, optional callID, epoch) triple; a pair without shell workers
    /// answers false honestly (never a fake success, never another domain's
    /// worker). Cancellation requests the remote stop through the reused
    /// worker token chain and the worker stays attached until the real
    /// lease release (`reconcileLedger`).
    public func cancelOwnedShellTool(runID: UUID, callID: String?, epoch: UInt64) async -> Bool {
        let matching = withState {
            ledgerIndex.filter { _, entry in
                entry.epoch == epoch && entry.runID == runID
                    && (callID == nil || entry.callID == callID)
            }
        }
        var accepted = false
        for (workerID, entry) in matching {
            let match = await entry.coordinator.cancelOwnedToolMatches(runID: runID, callID: callID, epoch: epoch)
            if case .cancelled(let ids) = match, ids.contains(workerID) { accepted = true }
        }
        return accepted
    }

    // MARK: Diagnostics (typed counts only; never payloads/commands/output)

    public func statsJSON() -> String {
        stateLock.lock()
        let composed = componentsStorage != nil
        let epoch = boundEpoch
        stateLock.unlock()
        let fields = LinuxReadinessIngress.shared.derivedFields()
        let object: [String: Any] = [
            "composed": composed,
            "epochBound": epoch != 0,
            "ledgerWorkers": withState { ledgerIndex.count },
            "qualified": isCapabilityQualified,
            "fields": [
                "runtimeUidBoundaryVerified": fields.runtimeUidBoundaryVerified,
                "engineConnected": fields.engineConnected,
                "mailboxEpochBound": fields.mailboxEpochBound,
                "rootfsQualified": fields.rootfsQualified,
                "workspaceMappingSynced": fields.workspaceMappingSynced,
                "leaseAuthorityQualified": fields.leaseAuthorityQualified,
                "singleWorkloadContractAcknowledged": fields.singleWorkloadContractAcknowledged,
            ],
            "transport": LinuxShellMailbox.shared.statsJSON(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"stats_encoding\"}"
        }
        return string
    }

    /// Trusted host registration entry (Main composition only — model
    /// dispatch cannot reach it). Registers exec.shell + shell.* into the
    /// EXISTING shared ToolRunnerRegistry/ToolCatalog. Product discovery
    /// waits for actual qualification. Interactive sessions remain withheld
    /// until their original IDE/session ownership is integrated.
    @discardableResult
    public func registerIntoCurrentGeneration(registry: ToolRunnerRegistry = .shared) -> Bool {
        stateLock.lock()
        let components = componentsStorage
        stateLock.unlock()
        guard let components, isCapabilityQualified else { return false }
        // Interactive session lifetime/IDE ownership is a later goal. Keep
        // its source reusable without advertising an unowned model session.
        return registerShellTools(registry: registry, shell: components.service, sessions: components.sessions,
                                  includeInteractiveSessions: false)
    }
}

// MARK: - Trusted-host C ABI (JNI; no model route)

/// Bind the Linux shell mailbox to the ACTUAL accepted native Root epoch
/// (the same authoritative value `floe_runtime_status` reports as
/// `generation`). 0 => refused. Returns 0 on success, -105 on refusal.
@_cdecl("floe_linux_shell_bind_epoch")
public func floeLinuxShellBindEpoch(_ epoch: UInt64) -> Int32 {
    RuntimeFacadeLinuxBindings.shared.bindMailboxEpoch(epoch) ? 0 : -105
}

/// Generation fence for the shell transport + ledger (trusted host
/// lifecycle: runtime stop / generation replacement).
@_cdecl("floe_linux_shell_fence_generation")
public func floeLinuxShellFenceGeneration(_ epoch: UInt64) -> Int32 {
    RuntimeFacadeLinuxBindings.shared.fenceGeneration(epoch: epoch)
    return 0
}

@_cdecl("floe_linux_shell_suspend_admission")
public func floeLinuxShellSuspendAdmission(_ epoch: UInt64) -> Int32 {
    RuntimeFacadeLinuxBindings.shared.suspendAdmissions(epoch: epoch) ? 0 : -105
}

/// Explicit legitimate re-admission for the SAME still-live generation
/// (trusted host only). Clears the suspend mark; readiness then requires
/// full re-ingestion of real facts — this call alone never re-qualifies.
@_cdecl("floe_linux_shell_resume_admission")
public func floeLinuxShellResumeAdmission(_ epoch: UInt64) -> Int32 {
    RuntimeFacadeLinuxBindings.shared.resumeAdmissions(epoch: epoch) ? 0 : -105
}

private final class LinuxShellDrainResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32 = 0
    func set(_ value: Int32) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Int32 { lock.lock(); defer { lock.unlock() }; return value }
}

@_cdecl("floe_linux_shell_drain")
public func floeLinuxShellDrain(_ timeoutMillis: Int32) -> Int32 {
    guard timeoutMillis >= 0, timeoutMillis <= 60_000 else { return -105 }
    let result = LinuxShellDrainResult()
    let completion = DispatchSemaphore(value: 0)
    Task.detached {
        let bindings = RuntimeFacadeLinuxBindings.shared
        _ = await bindings.reconcileLedger()
        result.set(await bindings.drainLinuxShell(timeoutMillis: Int(timeoutMillis)) ? 1 : 0)
        completion.signal()
    }
    guard completion.wait(timeout: .now() + .milliseconds(Int(timeoutMillis) + 100)) == .success else { return 0 }
    return result.get()
}

/// Facade + transport stats (typed counts only; never payloads).
@_cdecl("floe_linux_shell_stats")
public func floeLinuxShellStats(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    let text = RuntimeFacadeLinuxBindings.shared.statsJSON()
    guard let buffer, capacity > 0 else { return -105 }
    let bytes = Array(text.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return -106 }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}

// MARK: - EXACT Main wiring points (NOT performed by this package)
//
// 1. Package.swift (Main-serialized): add target `FloeAndroidShellTools`
//    (dependencies: FloeCore, FloeTools, FloeSecurity) and test target
//    `FloeAndroidShellToolsTests`; add `FloeAndroidShellTools` to
//    `FloeAndroidCore`'s dependencies so LinuxShellMailbox +
//    RuntimeFacadeLinuxBindings link into the product .so.
// 2. G02 composition root: after the accepted native Root epoch exists,
//    call `RuntimeFacadeLinuxBindings.shared.compose(transport:
//    MailboxLinuxShellTransport(), coordinator:
//    <G02DomainServices.toolWorkCoordinator>, rootProvider: <trusted Core
//    workspace root resolver>, readiness: <live qualification predicate>)`
//    then `bindMailboxEpoch(<accepted native root epoch>)`.
// 3. Qualification: feed `LinuxShellQualificationFields` ONLY from real
//    Main-proven evidence. `workspaceMappingSynced` stays false until the
//    Core<->engine workspace import/export/sync integration exists; until
//    then `isCapabilityQualified` is false and exec.shell fails closed with
//    guidance (never a host interpreter).
// 4. Capability reporting: where the facade answers
//    `localLinuxGuestEnvironment`, it must consult
//    `RuntimeFacadeLinuxBindings.shared.isCapabilityQualified` — do NOT
//    derive it from runtimeConfiguration/install status or temporary-chat
//    state, and do NOT edit runtimeConfiguration in this round.
// 5. JNI host pump (Kotlin, Main-owned): one dedicated poller using
//    `floe_linux_shell_mailbox_next/describe/payload_length/take_payload/
//    is_live/complete/close/stats` (+ `floe_linux_shell_bind_epoch/
//    fence_generation/stats`): claim ticket -> RuntimeWire exchange on the
//    IO executor -> for shell.start/input/resize poll request.status until
//    completed/failed before `complete`; settle shell.poll/installation
//    snapshots and shell.cancel directly; NEVER replay a request after a
//    disconnect (`RuntimeConnection.disconnected` already refuses).
// 6. Runtime lifecycle drain: call `drainLinuxShell(timeoutMillis:)` /
//    `reconcileLedger()` from the existing owned-work quiescence path; the
//    ORIGINAL BackgroundJobStore/BackgroundJobService remain the durable
//    authority and are untouched here.
// 7. Registration: `registerIntoCurrentGeneration()` once, from the
//    serialized composition, after steps 2-3 (registering earlier is also
//    honest — the backend then simply reports the engine unqualified).
