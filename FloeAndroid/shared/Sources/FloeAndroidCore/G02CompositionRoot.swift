// SPDX-License-Identifier: MPL-2.0
//
// G02 production composition — process orchestrator retained by the ONE
// accepted `AndroidRuntimeBootstrap.Generation`, ordinary base first.
//
// Lifecycle contract with RB1 (narrow reviewed delta, see
// `app-deltas/RuntimeFacadeBootstrap.g02-composition-hook.patch`):
//   * `install(gen:catalogBytes:)` runs at the end of the bootstrap job's
//     committed success path, BEFORE its terminal settles. Domain handlers
//     become visible only after each domain's real constructors ran AND the
//     full-owner claim succeeded.
//   * `beginRetirement(epoch:)` runs in every close path immediately after
//     `RuntimeFacadeBridge.uninstall()`: it fences new domain admissions,
//     cancels owned services (live run services, staging ingress, P8 feed
//     leases), unregisters the domain binder keys and retires any bound
//     optional-domain extension with the EXACT epoch. The database and root
//     stay owned: RB1's drain waits on the real owned-work registry and
//     only then closes the DB.
//   * Singleflight: the reservation is taken BEFORE the first `await` and
//     carries the ACTUAL full-owner identity (normalized root path + full
//     token + epoch); a conflicting in-flight ownership is refused, never
//     overwritten. Exactly one install and one retirement per epoch; a
//     rebind/reopen of the same epoch is idempotent, never duplicate pumps
//     or handler callbacks.
//   * Partial-build rollback: a constructor refusal after a self-installing
//     lane (attachment staging / run domain) already installed retires that
//     lane guarded by the EXACT owned domain instance (never a tokenless
//     global uninstall) — no half graph is ever advertised or left live.
//   * Handler registration happens AFTER the full-owner claim; if the claim
//     is lost mid-registration, exactly the keys this registration bound
//     are unregistered (late cleanup can never unregister a newer owner's
//     handlers — RB1 admits no newer generation inside this window).
//   * Stale-owner safety: a retirement for an epoch the process no longer
//     owns cancels that epoch's extension services (epoch-guarded) but can
//     NEVER uninstall the process-lane facades or clear the newer graph's
//     state — only the owning epoch retires process-lane state.
//
// No timeout-based fake detach exists anywhere here: unfinished owned work
// keeps the root open through RB1's real drain predicate.
import Foundation
import FloePersistence

public final class G02RuntimeComposition: @unchecked Sendable {

    public static let shared = G02RuntimeComposition()

    // MARK: - Process-level ports (one per process; epoch-validated inside)

    public let transportGate = G02QualifiedTransportGate()
    public let routeContext = G02HostRouteContextProvider()

    // MARK: - Installed state (one per accepted full owner)

    private let lock = NSLock()
    private var installed: G02InstalledComposition?
    /// The ACTUAL full-owner reservation (root+token+epoch), taken before
    /// the first await. A conflicting ownership is refused, not overwritten.
    private var reservation: (identity: RuntimeOwnerIdentity, epoch: UInt64)?
    private var retiredEpochs: [UInt64] = []
    /// Generation-scoped destructive-operation fences. The ordinary base
    /// never sets these (its privacy extension successor does, around the
    /// real clear/delete mutations); the P8 personalization fence reads
    /// them so feeds stop BEFORE those mutations. Owning-epoch only.
    private var deletionOrHistoryClearPending: Set<UUID> = []
    private var historyClearInFlight = false
    /// Optional-domain extensions (temporary/privacy successors). Accepted
    /// ONLY in the idle pre-bootstrap window — explicit refusal while a
    /// generation is installing or live keeps the seam minimal and owned.
    private var registeredExtensions: [G02DomainExtensionID: any G02DomainExtension] = [:]

    /// Composition admission mode. `.ordinaryProduct` (the DEFAULT and the
    /// only production mode) builds and installs the real ordinary graph at
    /// bootstrap. `.coreOnly` is an INTERNAL trusted test-fixture mode for
    /// isolated component lanes (e.g. the attachment bridge v3 fixture that
    /// installs its own real staging service): install() becomes a no-op so
    /// the component's own seven-command fail-closed-before-install and
    /// real store/rollback assertions execute against a genuinely unbound
    /// root. Never the production default; never a permit-all.
    enum CompositionMode: Sendable {
        case ordinaryProduct
        case coreOnly
    }
    private var mode: CompositionMode = .ordinaryProduct

    private init() {}

    /// Trusted fixture boundary (same module only): isolated component
    /// fixtures run with the core-only composition so their own real
    /// service installation is the system under test. Production code never
    /// calls this.
    func setCompositionModeForTesting(_ mode: CompositionMode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

    // MARK: - Swift-6-safe scoped synchronous state helpers (never across await)

    private func withState<T>(_ body: (inout G02InstalledComposition?,
                                       inout (identity: RuntimeOwnerIdentity, epoch: UInt64)?,
                                       inout [UInt64],
                                       inout [G02DomainExtensionID: any G02DomainExtension]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&installed, &reservation, &retiredEpochs,
                    &registeredExtensions)
    }

    // MARK: - Destructive-operation fences (privacy-extension producer)

    /// A history clear fences every conversation; modelConfiguration clears
    /// do not touch conversations and are not flagged here.
    func isDeletionOrHistoryClearPending(_ conversationID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return historyClearInFlight
            || deletionOrHistoryClearPending.contains(conversationID)
    }

    /// Set around an in-flight `privacy.history.clear` so P8 feeds stop for
    /// all conversations BEFORE the mutation starts. Consumed by the privacy
    /// extension when it integrates; the ordinary base never manufactures it.
    func noteHistoryClearInFlight(_ pending: Bool) {
        lock.lock()
        historyClearInFlight = pending
        lock.unlock()
    }

    /// The privacy extension records a pending destructive clear so P8 feeds
    /// for those conversations stop BEFORE the mutations begin.
    func noteDeletionOrHistoryClearPending(_ conversationID: UUID, pending: Bool) {
        lock.lock()
        if pending {
            deletionOrHistoryClearPending.insert(conversationID)
        } else {
            deletionOrHistoryClearPending.remove(conversationID)
        }
        lock.unlock()
    }

    /// Takes the per-full-owner install reservation BEFORE the first
    /// `await`. Returns false when the epoch is already installed, this
    /// owner is already reserved, a DIFFERENT ownership is in flight
    /// (conflicting ownership is serialized by refusal — RB1 serializes
    /// generations, so this is a fail-closed invariant, not a spin), or the
    /// epoch is retired. Idempotent singleflight per full owner.
    private func reserveInstall(identity: RuntimeOwnerIdentity) -> Bool {
        withState { installed, reservation, retired, _ in
            if installed?.epoch == identity.epoch { return false }
            if retired.contains(identity.epoch) { return false }
            if let active = reservation {
                // Same full owner retrying its own in-flight install is
                // refused (idempotent); a different owner is never
                // overwritten — conflicting in-flight ownership settles
                // through the owner's real rollback before any new admit.
                return false
            }
            reservation = (identity, identity.epoch)
            return true
        }
    }

    private func cancelReservation(identity: RuntimeOwnerIdentity) {
        withState { _, reservation, _, _ in
            if reservation?.identity.matchesOwnership(of: identity) == true {
                reservation = nil
            }
        }
    }

    /// Publishes the built composition ONLY while the full-owner
    /// reservation is still current; a racing retirement clears the
    /// reservation and the install discards its result (fail-closed, never
    /// a stale publish).
    private func claimInstalled(_ composition: G02InstalledComposition,
                                identity: RuntimeOwnerIdentity) -> Bool {
        withState { installed, reservation, _, _ in
            guard reservation?.identity.matchesOwnership(of: identity) == true else {
                return false
            }
            installed = composition
            reservation = nil
            return true
        }
    }

    /// True while the full-owner claim for this identity is still held
    /// (post-claim registration/attach steps re-check this after every
    /// await; a lost claim triggers exact cleanup).
    private func claimAlive(_ identity: RuntimeOwnerIdentity) -> Bool {
        withState { installed, _, _, _ in
            installed?.epoch == identity.epoch
        }
    }

    // MARK: - Optional-domain extension seam (pre-bootstrap registration only)

    /// Registers an optional-domain extension (temporary/privacy successor
    /// package). Accepted ONLY while no generation is installing or live —
    /// an explicit refusal otherwise (no dynamic plugin system, no unowned
    /// attach tasks). The extension is awaited within the OWNED install
    /// flow; a failed attach is honest, non-gating and self-rolled-back.
    @discardableResult
    func registerExtension(_ extension: any G02DomainExtension) -> Bool {
        withState { installed, reservation, _, registry in
            guard installed == nil, reservation == nil else { return false }
            registry[`extension`.id] = `extension`
            return true
        }
    }

    // MARK: - G04 pre-drain retirement preservation hook (Main 2026-10-24)

    /// SYNCHRONOUS adoption-time gate: called by `AndroidRuntimeBootstrap`
    /// BEFORE the shutdown state-lock flips (never inside it — the registry
    /// re-enters the bootstrap lock through `ownedWorkAttachAllowed`). When a
    /// registered extension owes durable preservation for this epoch it
    /// attaches ONE REAL `.conversation` owned-work token, which makes the
    /// ORIGINAL `waitForLifecycleDrain` predicate honestly unable to report a
    /// clean drain until `runRetirementPreservationIO` settles verified
    /// bytes and exact-releases the token. If the adoption later refuses,
    /// the caller MUST `release` what it attached. Attach refusal leaves no
    /// state and must refuse shutdown when preservation is required.
    func preparesRetirementPreservation(epoch: UInt64) -> G04WorkspaceRetirementGate.Outcome {
        let owed = withState { _, _, _, registry in
            registry.values.contains { $0.requiresRetirementPreservation(epoch: epoch) }
        }
        guard owed else { return .notRequired }
        return G04WorkspaceRetirementGate.shared.prepare(epoch: epoch)
    }

    /// ASYNC pre-drain driver: runs BEFORE the first drain wait. Defaults do
    /// nothing; only the workspace extension performs real preservation IO
    /// under the gate lease (verified -> release; unproven -> the token stays
    /// and the ORIGINAL drain timeout / failedDrainPending / watch-retry
    /// machinery keeps the root owned — no fake lease, no silent drop).
    func runRetirementPreservationIO(epoch: UInt64) async {
        let extensions: [any G02DomainExtension] =
            withState { _, _, _, registry in Array(registry.values) }
        for ext in extensions where ext.requiresRetirementPreservation(epoch: epoch) {
            await ext.runRetirementPreservationIO(epoch: epoch)
        }
    }

    /// Attempts ONE extension attach inside the owned install. A failure is
    /// honest and non-fatal: the ordinary base stays installed and the
    /// extension's domains stay blocked (the extension self-rolled back any
    /// partial state per the seam contract).
    private func attachExtension(_ extension: any G02DomainExtension,
                                 to composition: G02InstalledComposition,
                                 identity: RuntimeOwnerIdentity,
                                 gen: AndroidRuntimeBootstrap.Generation) async {
        guard claimAlive(identity) else { return }
        guard AndroidRuntimeBootstrap.bootstrapStillCurrent(epoch: identity.epoch,
                                                           owner: gen.owner) else {
            return
        }
        guard await `extension`.attach(to: composition, gen: gen) else {
            return
        }
        withState { installed, _, _, _ in
            if installed === composition {
                composition.attachedExtensions[`extension`.id] = `extension`
            }
        }
    }

    // MARK: - Install (called from the RB1 bootstrap committed path)

    /// Constructs the ordinary base over the live generation's owned
    /// cluster, claims the full owner, registers every ordinary handler,
    /// then attaches any registered optional-domain extension. Returns
    /// whether the ordinary base actually installed (the RB1 bootstrap
    /// detail reports this honestly; per-domain readiness stays the
    /// authoritative source).
    @discardableResult
    func install(gen: AndroidRuntimeBootstrap.Generation,
                 catalogBytes: Data? = nil) async -> Bool {
        // Core-only fixture mode: the ordinary product graph stays
        // uninstalled by design (isolated component fixtures own their own
        // real service installs). Production default never takes this path.
        if mode == .coreOnly {
            return false
        }
        // 1. Reserve BEFORE the first await, keyed by the ACTUAL full owner.
        guard reserveInstall(identity: gen.identity) else {
            return false
        }
        do {
            guard AndroidRuntimeBootstrap.bootstrapStillCurrent(epoch: gen.epoch, owner: gen.owner) else {
                cancelReservation(identity: gen.identity)
                return false
            }
            guard let cluster = await gen.owner.g02OwnedCluster(expected: gen.identity) else {
                // Owner proof failed: the ordinary runtime stays honestly
                // uninstalled; RB1's status already reports owned-store facts.
                cancelReservation(identity: gen.identity)
                return false
            }
            guard AndroidRuntimeBootstrap.bootstrapStillCurrent(epoch: gen.epoch, owner: gen.owner) else {
                cancelReservation(identity: gen.identity)
                return false
            }

            // 1b. REAL transport/default-system-TLS startup admission —
            //     evaluated ONLY for the captured CURRENT full owner under
            //     its held reservation and proven currency, and BEFORE this
            //     owner's immutable RunContext snapshot is constructed. A
            //     rejected/stale install can therefore never mutate the
            //     process gate or its listener. Facts only: the platform
            //     default-trust store, the trust-environment guard and the
            //     ORIGINAL production session factory — never a private
            //     receipt, a manual flip, a hardcoded true or source/port
            //     presence. A refusal keeps typed transportUnavailable.
            let admission = G02TransportStartupAdmission.evaluate()
            transportGate.applyStartupAdmission(admission)
            guard AndroidRuntimeBootstrap.bootstrapStillCurrent(epoch: gen.epoch, owner: gen.owner) else {
                cancelReservation(identity: gen.identity)
                return false
            }

            guard let composition = await G02InstalledComposition.build(
                gen: gen, cluster: cluster,
                transportGate: transportGate,
                routeContext: routeContext,
                catalogBytes: catalogBytes) else {
                // A real constructor refused (vault join / skills init):
                // roll back the self-installed lanes for THIS owner (exact
                // owned instance guarded) and install nothing.
                await rollbackPartialBuild(epoch: gen.epoch, identity: gen.identity)
                cancelReservation(identity: gen.identity)
                return false
            }
            guard AndroidRuntimeBootstrap.bootstrapStillCurrent(epoch: gen.epoch, owner: gen.owner) else {
                await rollbackPartialBuild(epoch: gen.epoch, identity: gen.identity)
                cancelReservation(identity: gen.identity)
                return false
            }

            // 2. Claim the full owner BEFORE any handler becomes visible:
            //    advertisement and ownership arrive together.
            guard claimInstalled(composition, identity: gen.identity) else {
                await rollbackPartialBuild(epoch: gen.epoch, identity: gen.identity)
                return false
            }

            // 3. Register handlers with exact-owner cleanup: bind one key at
            //    a time; if the claim is lost mid-registration, unregister
            //    exactly the keys this registration bound (RB1 admits no
            //    newer generation inside this window, so the keys are still
            //    this owner's).
            let boundKeys = composition.registerAllDomainHandlers(gen: gen)
            if !claimAlive(gen.identity) {
                let binder = RuntimeCommandBinder.shared
                for key in boundKeys {
                    binder.unregister(key)
                }
                await rollbackPartialBuild(epoch: gen.epoch, identity: gen.identity)
                return false
            }

            // Truthful transport admission: the REAL gate state was
            // snapshotted into the immutable RunContext at build (BEFORE
            // the snapshot); any later Main flip propagates truthfully into
            // the live snapshot — never forever-false, never fake-true.
            transportGate.setAdmissionListener { [weak self] admitted in
                guard let self else { return }
                self.lock.lock()
                let target = self.installed
                self.lock.unlock()
                target?.runComponents.context.isTransportQualified = admitted
            }

            // 4. Attach registered optional-domain extensions inside the
            //    owned install; each failure is honest and non-gating.
            let extensions: [any G02DomainExtension] =
                withState { _, _, _, registry in Array(registry.values) }
            for ext in extensions {
                await attachExtension(ext, to: composition,
                                      identity: gen.identity, gen: gen)
            }

            // 5. G02-R7: ONE durable V36 private-workspace cleanup retry,
            //    owned by THIS generation and drained like any other domain
            //    work (see `runPrivateWorkspaceCleanupSweepOnce`). It runs
            //    inside the admitted startup window, after the conversation
            //    domain exists, and never gates or fails the bootstrap.
            await runPrivateWorkspaceCleanupSweepOnce(composition: composition,
                                                      gen: gen)
            return true
        }
    }

    /// G03-R3 (job-3d39b56695c44bd2): a REAL cleared runtime-cleanup receipt
    /// for a retained V36 row re-drives the SAME owned sweep once (event,
    /// not poll). The trigger is generation-bound (lane rebind drops it) and
    /// the re-drive re-attaches its owned token exactly like the launch
    /// sweep, so retirement still waits for the real work.
    ///
    /// The ONE real bootstrap/root-lifecycle retry of the durable
    /// `local_workspace_cleanup` queue (G02-R7 gap 3).
    ///
    /// * Owned: a `.conversation` owned-work token (the frozen registry
    ///   vocabulary — no new kind) is attached before the sweep, so every
    ///   Root shutdown/retirement drain waits for the real work, and the
    ///   EXACT token is detached afterwards. If the attach is refused (a
    ///   stop was already requested, the store is not ready or the epoch is
    ///   not admitting), the sweep is skipped and every row stays durably
    ///   queued for the next launch.
    /// * Fenced to the actual root/epoch: the same `bootstrapStillCurrent`
    ///   predicate that gates the rest of the install is re-checked after
    ///   the attach and before every item; when the generation stops
    ///   starting, the sweep stops after the current item instead of
    ///   touching a newer generation's root.
    /// * One-shot: called exactly once from the owned install. No UI
    ///   action, no polling, no detached/unowned task, no duplicate call.
    ///   The only later re-drive is the lane's REAL cleared-receipt event
    ///   (G03-R3), which runs the SAME owned token/ fence path once.
    private func runPrivateWorkspaceCleanupSweepOnce(
        composition: G02InstalledComposition,
        gen: AndroidRuntimeBootstrap.Generation
    ) async {
        // Capture only Sendable values for the shared owned sweep; the
        // `Generation` struct itself is never captured.
        let epoch = gen.epoch
        let owner = gen.owner
        let domain = composition.conversationDomain
        await Self.runOwnedPrivateWorkspaceCleanupSweep(domain: domain, epoch: epoch, owner: owner)
        // Event-driven finalization for retained R3 rows (see doc above).
        LinuxRuntimeCleanupLane.shared.installSettlementTrigger(epoch: epoch) {
            Task {
                await Self.runOwnedPrivateWorkspaceCleanupSweep(
                    domain: domain, epoch: epoch, owner: owner)
            }
        }
    }

    /// The owned sweep body shared by the launch one-shot and the
    /// settlement re-drive: REAL owned-work token, exact root/epoch fence,
    /// rows that cannot finish stay durably queued.
    private static func runOwnedPrivateWorkspaceCleanupSweep(
        domain: FacadeConversationDomain,
        epoch: UInt64,
        owner: AndroidRuntimeStoreOwner
    ) async {
        guard AndroidRuntimeBootstrap.bootstrapStillCurrent(epoch: epoch, owner: owner) else {
            return
        }
        let registry = RuntimeOwnedWorkRegistry.shared
        let ownerID = "cleanup-sweep:\(epoch):\(UUID().uuidString)"
        guard case .attached(let token) = registry.attach(
            epoch: epoch, kind: .conversation, ownerID: ownerID) else {
            return
        }
        defer { registry.detach(token) }
        guard AndroidRuntimeBootstrap.bootstrapStillCurrent(epoch: epoch, owner: owner) else {
            return
        }
        _ = await domain.retryPendingLocalWorkspaceCleanup(shouldContinue: {
            AndroidRuntimeBootstrap.bootstrapStillCurrent(
                epoch: epoch, owner: owner)
        })
    }

    /// Rolls back the self-installing lanes of a FAILED build for the exact
    /// owner. The run-domain uninstall is guarded by the EXACT owned domain
    /// INSTANCE at mutation time (captured before the awaiting cancel
    /// cascade): a late rollback can never tokenlessly clear a newer or
    /// replacement domain. Attachment staging retires by exact epoch+owner
    /// (its facade revalidates identity internally).
    private func rollbackPartialBuild(epoch: UInt64,
                                      identity: RuntimeOwnerIdentity) async {
        // Capture the exact owned instance before any await.
        let ownedRunDomain: FacadeRunDomain? =
            RunDomainFacade.current(epoch: epoch)?.0
        guard let ownedRunDomain else {
            // No run domain installed for this epoch: nothing of ours to
            // retire (staging retire is still exact-epoch safe below).
            G073TaskScheduleBindings.uninstall(epoch: epoch)
            G073TaskScheduleFacade.uninstall(epoch: epoch)
            AttachmentStagingFacade.retire(epoch: epoch)
            return
        }
        await RunDomainFacade.beginGenerationRetirement(epoch: epoch)
        // Guard at mutation time: only the identical owned instance may be
        // uninstalled; a replacement/newer domain is untouched.
        let stillOurs = RunDomainFacade.current(epoch: epoch)
        if stillOurs?.0 === ownedRunDomain {
            RunDomainFacade.uninstall()
        }
        G073TaskScheduleBindings.uninstall(epoch: epoch)
        G073TaskScheduleFacade.uninstall(epoch: epoch)
        AttachmentStagingFacade.retire(epoch: epoch)
    }

    // MARK: - Retirement (called from every RB1 close path)

    /// RootStop: cancels owned services, unregisters domain handlers and
    /// retires bound extensions with the EXACT epoch. The database/root
    /// stay locked and open until RB1's real drain completes; no early
    /// close here. A stale epoch's retirement can never uninstall the
    /// process-lane facades or clear the newer graph's state.
    public func beginRetirement(epoch: UInt64) async {
        let alreadyRetired: Bool = withState { installed, reservation, retired, _ in
            if retired.contains(epoch) { return true }
            retired.append(epoch)
            while retired.count > 8 { retired.removeFirst() }
            if reservation?.epoch == epoch { reservation = nil }
            return false
        }
        guard !alreadyRetired else { return }
        let target: G02InstalledComposition? = withState { installed, _, _, _ in
            installed?.epoch == epoch ? installed : nil
        }
        let ownsEpoch = target != nil

        // 0. Root-retirement fence for the trusted host secure-ingress route:
        //    clears ONLY a binding this exact epoch minted. A newer epoch's
        //    binding is never touched, and a live-epoch re-check inside the
        //    registry independently fails a retired binding closed.
        routeContext.retireBoundRoute(epoch: epoch)

        // 0b. G06 Notes authority retirement: exact-epoch close of the one
        //     service-owned NotesStore. A stale epoch is a no-op and never
        //     closes a newer generation's store. This runs on every normal or
        //     failed generation retirement, before the runtime DB close.
        await NotesOCRComposition.detach(epoch: epoch)
        await NotesDomainService.shared.retire(epoch: epoch)
        await NotesAssistantDomain.shared.unbind(epoch: epoch)

        // 1. Fence domain admissions: unregister the synchronous binder keys
        //    FIRST so no new domain command can be admitted. The async
        //    processors lived on the generation's registry and become
        //    unreachable with it; the mailbox retires their streams.
        if let target {
            let binder = RuntimeCommandBinder.shared
            for key in target.registeredHandlerKeys {
                binder.unregister(key)
            }
        }

        // 2. Retire bound optional-domain extensions for the exact epoch
        //    BEFORE the run domain retires (cross-domain fences stay live).
        let extensions: [any G02DomainExtension] =
            withState { _, _, _, registry in Array(registry.values) }
        for ext in extensions {
            await ext.beginRetirement(epoch: epoch)
        }

        // 3. Cancel owned services. The run facade's retirement cascade is
        //    epoch-guarded; the process-lane uninstall runs ONLY for the
        //    owning epoch — a stale epoch cancels its own epoch-guarded
        //    domain work and stops there, never clearing a newer graph.
        await RunDomainFacade.beginGenerationRetirement(epoch: epoch)
        if ownsEpoch {
            RunDomainFacade.uninstall()
            G073TaskScheduleBindings.uninstall(epoch: epoch)
            G073TaskScheduleFacade.uninstall(epoch: epoch)
        }
        AttachmentStagingFacade.retire(epoch: epoch)
        UserQuestionHostAPI.shared.retire(epoch: epoch)

        // 4. Drop the installed pointer and generation-scoped fences last,
        //    owning epoch only.
        if ownsEpoch {
            withState { installed, _, _, _ in
                if installed?.epoch == epoch { installed = nil }
            }
            clearFences()
        }
    }

    // MARK: - Adapter accessors

    var personalizationEvents: FacadePersonalizationEvents? {
        withState { installed, _, _, _ in installed?.personalizationEvents }
    }

    public var installedComposition: G02InstalledComposition? {
        withState { installed, _, _, _ in installed }
    }

    func installedConversationDomain(epoch: UInt64) async -> FacadeConversationDomain? {
        withState { installed, _, _, _ in
            guard let installed, installed.epoch == epoch else { return nil }
            return installed.conversationDomain
        }
    }

    /// True when the given extension is attached to the LIVE composition.
    func isExtensionAttached(_ id: G02DomainExtensionID) -> Bool {
        withState { installed, _, _, _ in
            installed?.attachedExtensions[id] != nil
        }
    }

    // MARK: - Test-only

    /// Test-only full reset. The composition is the OWNER of the two
    /// self-installing process lanes (attachment staging + run domain), so
    /// its reset releases exactly what it installed — this is producer
    /// ownership cleanup, not a force reset hiding a leak: a stranded lane
    /// would otherwise refuse every later generation's real install.
    func resetForTesting() {
        transportGate.setAdmissionListener(nil)
        // Owner cleanup of THIS composition instance's synchronous binder
        // ingress: a test-only full reset must not leave the process-global
        // binder answering with stale captured pumps (the exact cross-class
        // leak that made a later core-only fixture see bound domains).
        let lingeringKeys: [String] = withState { installed, reservation, retired, registry in
            let keys = installed?.registeredHandlerKeys ?? []
            installed = nil
            reservation = nil
            retired.removeAll()
            registry.removeAll()
            return keys
        }
        if !lingeringKeys.isEmpty {
            let binder = RuntimeCommandBinder.shared
            for key in lingeringKeys {
                binder.unregister(key)
            }
        }
        clearFences()
        AttachmentStagingFacade.uninstallAllForTesting()
        RunDomainFacade.uninstall()
        // G03-R3 lanes owned by THIS composition's G02DomainServices build:
        // the workspace authority install slot and the live readiness
        // ingress. Same producer-ownership reset discipline; production
        // never reaches this path.
        LinuxWorkspaceAuthority.resetInstallationForTesting()
        LinuxReadinessIngress.shared.resetForTesting()
        // G04 retirement gate: same test-only ownership cleanup (production
        // releases flow only through verified preservation settle).
        G04WorkspaceRetirementGate.shared.resetForTesting()
        lock.lock()
        mode = .ordinaryProduct
        lock.unlock()
    }

    /// Synchronous fence reset (Swift-6: never `lock()` from async code).
    private func clearFences() {
        lock.lock()
        deletionOrHistoryClearPending.removeAll()
        historyClearInFlight = false
        lock.unlock()
    }
}
