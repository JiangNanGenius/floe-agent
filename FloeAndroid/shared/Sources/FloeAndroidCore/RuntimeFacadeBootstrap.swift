// SPDX-License-Identifier: MPL-2.0
//
// RB-1 runtime bootstrap — process-lifecycle owner of the generation state
// machine (Application-owned, Activity-independent).
//
// Ownership (RB1 handoff, Main draft review RB1-M1..M5, and the 2026-10-19
// wire/lifecycle repair RB1-R1..R4/R7):
// * One MainActor-free generation owns ONE `AndroidRuntimeStoreOwner` (the
//   single original `DatabaseManager` + approved store cluster), ONE bounded
//   mailbox, ONE effect pump, ONE run-event pump and ONE content reader.
// * The trusted root/owner token/epoch arrive ONLY through the internal JNI
//   seam from the Android Application/service host. A command envelope cannot
//   select, widen or learn a storage root; the model-visible lifecycle
//   surface only echoes typed fingerprints.
// * M1: ownership equality is the EXACT normalized root path + full token,
//   never the short diagnostic fingerprint.
// * M2: an exact replay of the current generation's accepted
//   root/token/epoch is idempotent BEFORE any stale-epoch guard; a newer
//   epoch under the SAME owner while owned work lives is a typed
//   `rebindWhileOwned` refusal; a fresh generation after real retirement
//   requires a strictly newer epoch.
// * M3: shutdown fences new admissions atomically at the accepted boundary.
//   The control waits until every OTHER queued/active entry has really
//   settled, then unbinds command ingress, retires the mailbox WITHOUT
//   settling itself, closes the owner (DB last) and only then does its single
//   terminal effect settle and become readable.
// * M4: ownership (generation + mailbox slots + database) is retained until
//   the actual drain and real `DatabaseManager.close()` complete — on the
//   success path, and on the failed-bootstrap path too. A failed drain
//   timeout is NOT permission to dispose: the generation enters a typed
//   `failedDrainPending` state and retires only after the real work finishes
//   (a controlled retirement control is minted then).
// * R1: closed/failed generation terminals stay readable through the ACTUAL
//   v3 `effect.poll` entry after the binder uninstall and the real DB close,
//   including across a new generation. A separate bounded registry retains
//   ONLY terminal effect streams (no owner/mailbox/database/generation).
// * R2: retry controls carry their ACTUAL correlationID through the
//   processor/wait/retire path; a retry never waits for itself and the old
//   receipt keeps exactly one unchanged terminal.
// * R4: the public `system.shutdown` command's own receipt IS the control
//   receipt and settles only after the real drain + DB close (or a typed
//   failed outcome). No outer job waits on an inner stop job.
// * R5: trusted stop requires the accepted owner epoch + token; a stale
//   coordinator cannot stop a newer generation. Late bootstrap readiness
//   cannot publish after shutdown was requested.
// * R7: every access to the lifecycle lock goes through a synchronous
//   `withStateLock` helper; no lock is ever held across an `await`.
//
// All synchronous entry points (JNI/binder + status reads) are lock-only and
// never await the owner actor, network or SQLite. Heavy async steps run as
// mailbox jobs on the cooperative pool. This source is NOT compiled/executed
// by the authoring package.
import Foundation
import Crypto
import FloePersistence

public enum AndroidRuntimeBootstrap {

    // MARK: - Public outcomes

    public enum StartOutcome: Sendable, Equatable {
        case accepted(receipt: String)
        case idempotent(receipt: String)
        case rejected(RuntimeFacadeCode)
    }

    public enum ShutdownOutcome: Sendable, Equatable {
        case accepted(receipt: String)
        case idempotent(receipt: String)
        case rejected(RuntimeFacadeCode)
    }

    public enum Phase: String, Sendable, Codable {
        case stopped              // no live generation
        case starting             // bootstrap live (stores ready or failing)
        case draining             // shutdown accepted; real drain in progress
        case failedDrainPending   // bootstrap failed; ownership retained until
                                  // outstanding work really settles
        case failed               // bootstrap failed AND really retired
    }

    /// The closed list of REAL dependencies the ordinary runtime still lacks
    /// after RB1. This enum is the typed admission barrier: it shrinks only
    /// when the owning package installs the actual binding (Main review).
    public enum MissingBinding: String, Sendable, CaseIterable {
        case providerConfigurationDomain          // RB2
        case credentialVaultAdapter               // RB2b (job-de5991705fcb4477)
        case credentialArgumentNormalizer         // RB2b mirror overlay
        case conversationDomain                   // RB3
        case runDomain                            // RB4
        case temporaryDomain                      // RB5
        case skillsMcpDiscovery                   // RB6
        case hostAttachmentStaging                // pre-run staging owner
        case transportDeviceQualification         // StreamingTransport lane
    }

    // MARK: - Internal generation state (one live generation)

    struct Generation {
        let identity: RuntimeOwnerIdentity
        let epoch: UInt64
        let owner: AndroidRuntimeStoreOwner
        let registry: RuntimeDomainRegistry
        let effects: FacadeEffectPump
        let events: FacadeEventPump
        let content: FacadeContentReader
        let mailbox: FacadeCommandMailbox
        var bootstrapReceipt: String
        var shutdownReceipt: String?
        /// The ACTUAL correlationID of the currently outstanding control job.
        var shutdownCorrelation: String?
        /// `.stopped` for a clean drain, `.failed` for failed-retirement retry.
        var shutdownFinalPhase: Phase = .stopped
        var ownedStorePhase: AndroidRuntimeStoreOwner.Phase = .created
        var recovery = RuntimeRecoverySummary()
        var lastFailure: RuntimeFacadeCode?
        /// Failure that prevented immediate retirement (currently shutdownTimeout).
        var retirementPending: RuntimeFacadeCode?
        /// M4: true from the moment bootstrap fails typed until the real
        /// database close completes; no replacement is admitted inside that
        /// window.
        var retiring = false
        var retirementRetryCount = 0
        var retirementWatchTask: Task<Void, Never>?
    }

    private struct RetiredAnchor {
        let epoch: UInt64
        let receipt: String
        /// Generation identity: a stale job/observer from a RESET (or any
        /// same-epoch reuse in a test process) can never address the newer
        /// generation even though the epoch value matches.
        let effectsID: ObjectIdentifier
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var generation: Generation?
    nonisolated(unsafe) private static var lastEpoch: UInt64 = 0
    nonisolated(unsafe) private static var phase: Phase = .stopped
    nonisolated(unsafe) private static var lastFailureCode: RuntimeFacadeCode?
    /// Bounded anchors whose single control/bootstrap terminal may still be
    /// settling AFTER the real database close. The observer copies the
    /// generation's terminal streams into `RuntimeRetiredEffectRegistry`.
    nonisolated(unsafe) private static var retiredAnchors: [RetiredAnchor] = []
    /// Test hook only (monotonic bound of the drain wait). Production uses
    /// the constant below; resetForTesting restores it.
    nonisolated(unsafe) internal static var shutdownDrainTimeoutMillisOverride: Int?
    /// Test-only rendezvous used by the failed-bootstrap drain test to queue
    /// REAL outstanding work before the bounded drain starts. Nil in
    /// production; it never changes a lifecycle decision by itself.
    nonisolated(unsafe) internal static var failedBootstrapDrainGateForTesting:
        (@Sendable () async -> Void)?

    private static var shutdownDrainTimeoutMillis: Int {
        shutdownDrainTimeoutMillisOverride ?? 10_000
    }

    /// Every lifecycle-lock access goes through this SYNCHRONOUS helper.
    /// Async methods call it for snapshots/mutations and never hold the lock
    /// across an await (Swift 6 noasync-locking discipline).
    private static func withStateLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Full-owner currency proof for GLOBAL generation-scoped mutations,
    /// re-checked AFTER every await in a retirement path. Epoch equality
    /// alone is not ownership: the captured owner INSTANCE and the exact
    /// normalized root + full token must still be the global current
    /// generation. A stale old cleanup therefore can never erase a newer
    /// generation's globals or remove its process-wide binder ingress.
    private static func stillOwnsGlobalGenerationLocked(_ gen: Generation) -> Bool {
        guard let live = generation else { return false }
        return live.epoch == gen.epoch
            && live.owner === gen.owner
            && live.identity.matchesOwnership(of: gen.identity)
    }

    /// Retirement tail: stage this generation's retired-receipt anchor (R1
    /// readability of the old receipts survives in BOTH cases and is keyed
    /// by the OLD epoch/receipt/effects identity), then release the GLOBAL
    /// generation/phase ONLY when this generation still owns them (M4).
    /// Returns false for a stale cleanup — the old generation's own
    /// DB/mailbox/receipt settlement already happened and must not touch
    /// the newer globals.
    private static func releaseRetiredGeneration(gen: Generation,
                                                 receipt: String,
                                                 finalPhase: Phase) -> Bool {
        withStateLock {
            addRetiredAnchorLocked(epoch: gen.epoch, receipt: receipt,
                                   effectsID: ObjectIdentifier(gen.effects))
            guard stillOwnsGlobalGenerationLocked(gen) else { return false }
            if var live = generation {
                live.ownedStorePhase = .closed
                live.retiring = false
                live.retirementPending = nil
                live.retirementWatchTask?.cancel()
                generation = live
            }
            // Only now release the generation (M4): the supported new start
            // requires a strictly newer epoch.
            generation = nil
            phase = finalPhase
            return true
        }
    }

    /// The process-global binder ingress belongs to the CURRENT generation:
    /// a stale cleanup must never remove a newer generation's bridge keys
    /// (observed carrier hazard: an old late cleanup crossing a new start
    /// left the new generation without command ingress).
    private static func uninstallBridgeIfOwned(gen: Generation) {
        let owned = withStateLock { stillOwnsGlobalGenerationLocked(gen) }
        guard owned else { return }
        RuntimeFacadeBridge.uninstall()
    }

    private static func addRetiredAnchorLocked(epoch: UInt64, receipt: String,
                                               effectsID: ObjectIdentifier) {
        retiredAnchors.removeAll { $0.epoch == epoch && $0.effectsID == effectsID }
        retiredAnchors.append(RetiredAnchor(epoch: epoch, receipt: receipt,
                                            effectsID: effectsID))
        while retiredAnchors.count > RuntimeRetiredEffectRegistry.Limits.maximumGenerations {
            retiredAnchors.removeFirst()
        }
    }

    private static func isRetiredGeneration(_ epoch: UInt64,
                                            effectsID: ObjectIdentifier) -> Bool {
        withStateLock {
            retiredAnchors.contains { $0.epoch == epoch && $0.effectsID == effectsID }
        }
    }

    // MARK: - Start / shutdown (synchronous, JNI-safe)

    /// Trusted host start.
    public static func start(rootPath: String, ownerToken: String, epoch: UInt64)
        -> StartOutcome {
        guard let root = RuntimeStorageRoot(validatingAbsoluteDirectory: rootPath) else {
            return .rejected(.invalidStorageRoot)
        }
        guard let identity = RuntimeOwnerIdentity(root: root, token: ownerToken,
                                                  epoch: epoch) else {
            return .rejected(.invalidOwnerToken)
        }
        return withStateLock {
            if let live = generation {
                // M2/M4: the live generation (starting, draining, or retiring
                // in a failed close window) owns work; only retirement admits a
                // new generation, and then only with a strictly newer epoch.
                if phase == .draining || phase == .failedDrainPending || live.retiring {
                    return .rejected(.alreadyDraining)
                }
                // M1: EXACT normalized root + full token equality.
                if live.identity.matchesOwnership(of: identity) {
                    if epoch == live.epoch {
                        // M2: exact replay of the accepted start is idempotent;
                        // no second DB open, no second job, no second effect.
                        return .idempotent(receipt: live.bootstrapReceipt)
                    }
                    // A STALE epoch (older than the live accepted generation)
                    // is always `epochNotNewer`; only a NEWER epoch under the
                    // same owner while work lives is `rebindWhileOwned`.
                    if epoch < live.epoch { return .rejected(.epochNotNewer) }
                    return .rejected(.rebindWhileOwned)
                }
                return .rejected(.ownerMismatch)
            }
            guard epoch > lastEpoch else {
                return .rejected(.epochNotNewer)
            }
            // Fresh generation. Every bounded component is constructed before
            // the bootstrap job is enqueued so a poll for the receipt is
            // immediately meaningful (unknown-receipt honesty applies only
            // after retire).
            let owner = AndroidRuntimeStoreOwner()
            let registry = RuntimeDomainRegistry()
            let effects = FacadeEffectPump(generation: epoch)
            let events = FacadeEventPump()
            let content = FacadeContentReader(generation: epoch)
            let mailbox = FacadeCommandMailbox(effects: effects, registry: registry)
            let correlation = "host:bootstrap:\(epoch)"
            guard let receipt = effects.register(correlationID: correlation) else {
                return .rejected(.receiptSaturated)
            }
            var gen = Generation(identity: identity, epoch: epoch, owner: owner,
                                 registry: registry, effects: effects, events: events,
                                 content: content, mailbox: mailbox,
                                 bootstrapReceipt: receipt)
            gen.ownedStorePhase = .opening
            // RB1-R1: observe the single anchor terminal AFTER the real close
            // so the terminal is routable through the actual v3 entry. The
            // observer never captures the mailbox strongly (no retain cycle)
            // and copies only terminal effect streams.
            mailbox.setTerminalObserver { [weak mailbox, effects] _, settledReceipt, _ in
                Self.handleTerminalSettled(epoch: epoch, effects: effects,
                                           receipt: settledReceipt, mailbox: mailbox)
            }
            // Publish BEFORE install/submit; the drain is not started yet, so
            // no job can run against a half-built generation.
            generation = gen
            let job = RuntimeCommandEnvelopeJob(
                correlationID: correlation,
                handlerKey: RuntimeFacadeBridge.internalBootstrapHandlerKey,
                command: "internal.bootstrap.start",
                scope: nil, configurationScope: nil,
                receipt: receipt, envelope: Data())
            switch mailbox.submit(job) {
            case .queued:
                break
            case .duplicate, .rejected:
                // A brand-new mailbox cannot duplicate; a rejection here is a bug.
                mailbox.close(reason: .replaced)
                effects.retire()
                content.retireAll()
                generation = nil
                phase = .stopped
                return .rejected(.internal)
            }
            RuntimeFacadeBridge.install(for: gen)
            mailbox.startDrain()
            lastEpoch = epoch
            phase = .starting
            return .accepted(receipt: receipt)
        }
    }

    /// Trusted host shutdown. RB1-R5: the caller MUST present the exact
    /// accepted owner epoch + token. A stale coordinator cannot stop a newer
    /// generation and a caller without accepted-start proof cannot address
    /// another instance's owner.
    public static func shutdown(expectedEpoch: UInt64,
                                ownerToken: String) -> ShutdownOutcome {
        return withStateLock { () -> ShutdownOutcome in
            guard var live = generation else {
                return .rejected(.notInstalled)
            }
            guard live.epoch == expectedEpoch,
                  live.identity.token == ownerToken else {
                return .rejected(.ownerMismatch)
            }
            if phase == .failedDrainPending || live.retiring {
                // A failed bootstrap owns real outstanding work. Allow a
                // controlled retirement retry ONLY after the first retirement
                // attempt reached its typed deferred state; while the
                // bootstrap job itself is still draining/closing, a second
                // controller would wait on that job and deadlock the close.
                if let existing = live.shutdownReceipt,
                   !live.effects.isTerminal(receipt: existing) {
                    return .idempotent(receipt: existing)
                }
                guard live.retirementPending == .shutdownTimeout else {
                    return .rejected(.alreadyDraining)
                }
                return enqueueRetryControlLocked(&live, finalPhase: .failed)
            }
            if phase == .draining {
                // A control already owns the drain. A terminal typed failure
                // (shutdownTimeout) permits exactly one fresh control attempt
                // on a NEW receipt; the old receipt keeps its single terminal.
                if let existing = live.shutdownReceipt,
                   !live.effects.isTerminal(receipt: existing) {
                    return .idempotent(receipt: existing)
                }
                return enqueueRetryControlLocked(&live, finalPhase: .stopped)
            }
            guard phase == .starting else { return .rejected(.notInstalled) }
            if let existing = live.shutdownReceipt {
                return .idempotent(receipt: existing)
            }
            let correlation = "host:shutdown:\(live.epoch)"
            guard let receipt = live.effects.register(correlationID: correlation) else {
                return .rejected(.receiptSaturated)
            }
            let job = RuntimeCommandEnvelopeJob(
                correlationID: correlation,
                handlerKey: RuntimeFacadeBridge.internalShutdownHandlerKey,
                command: "internal.bootstrap.shutdown",
                scope: nil, configurationScope: nil,
                receipt: receipt, envelope: Data())
            switch live.mailbox.submit(job) {
            case .queued:
                // M3: atomic admission fence at the accepted boundary — the
                // very same lifecycle-lock hold that queued the control job.
                live.mailbox.beginDraining()
                live.shutdownReceipt = receipt
                live.shutdownCorrelation = correlation
                live.shutdownFinalPhase = .stopped
                if var current = generation, current.epoch == live.epoch {
                    current = live
                    generation = current
                }
                phase = .draining
                return .accepted(receipt: receipt)
            case .duplicate(let existing):
                return .idempotent(receipt: existing)
            case .rejected(let code):
                live.effects.append(receipt: receipt, kind: .rejected, code: code)
                return .rejected(code)
            }
        }
    }

    /// Retry control for a draining/failed generation. Called while holding
    /// the state lock. The control's ACTUAL correlationID is stored on the
    /// generation and carried into `runShutdownJob` (RB1-R2).
    private static func enqueueRetryControlLocked(_ live: inout Generation,
                                                  finalPhase: Phase)
        -> ShutdownOutcome {
        if let existing = live.shutdownReceipt,
           !live.effects.isTerminal(receipt: existing) {
            // Exactly one live controller per generation, regardless of the
            // final phase an earlier admission intended.
            return .idempotent(receipt: existing)
        }
        let retryIndex = live.retirementRetryCount + 1
        let correlation = "host:shutdown:\(live.epoch):retry:\(retryIndex)"
        guard let receipt = live.effects.register(correlationID: correlation) else {
            return .rejected(.receiptSaturated)
        }
        let job = RuntimeCommandEnvelopeJob(
            correlationID: correlation,
            handlerKey: RuntimeFacadeBridge.internalShutdownHandlerKey,
            command: "internal.bootstrap.shutdown",
            scope: nil, configurationScope: nil,
            receipt: receipt, envelope: Data())
        switch live.mailbox.submitControl(job) {
        case .queued:
            live.retirementRetryCount = retryIndex
            live.shutdownReceipt = receipt
            live.shutdownCorrelation = correlation
            live.shutdownFinalPhase = finalPhase
            live.retirementWatchTask = nil
            if var current = generation, current.epoch == live.epoch {
                current = live
                generation = current
            }
            return .accepted(receipt: receipt)
        case .duplicate(let existing):
            return .idempotent(receipt: existing)
        case .rejected(let code):
            live.effects.append(receipt: receipt, kind: .rejected, code: code)
            return .rejected(code)
        }
    }

    // MARK: - Bootstrap job bodies (async; run as mailbox jobs)

    /// Runs the ORIGINAL open/migrate/recover sequence and publishes honest
    /// lifecycle facts. Never touches a host interpreter, RAM store or
    /// fallback path: any failure is terminal-for-this-generation.
    static func runBootstrapJob(epoch: UInt64, correlation: String,
                                owner expectedOwner: AndroidRuntimeStoreOwner) async
        -> RuntimeCommandResult {
        let resolved: Generation? = withStateLock {
            guard let live = generation, live.epoch == epoch,
                  live.owner === expectedOwner,
                  !live.retiring, phase == .starting else { return nil }
            return live
        }
        guard let gen = resolved else { return .rejected(.notInstalled) }
        let owner = gen.owner
        await owner.openAndMigrate(with: gen.identity)
        let afterOpen = await owner.currentPhase
        let openFailure = await owner.lastFailureCode()
        if afterOpen != .migrated {
            let code = openFailure ?? .storeOpenFailed
            recordBootstrapFailure(epoch: epoch, owner: owner, code: code)
            // RB1-R5: a shutdown request fences late bootstrap failure/ready
            // publication too; the shutdown control owns the close.
            guard bootstrapStillCurrent(epoch: epoch, owner: owner) else {
                return .rejected(.alreadyDraining)
            }
            withStateLock {
                if var live = generation, live.epoch == epoch,
                   live.owner === owner, !live.retiring,
                   phase == .starting {
                    live.ownedStorePhase = afterOpen
                    generation = live
                }
            }
            return await retireFailed(gen: gen, correlation: correlation, code: code)
        }
        // RB1-R5: a shutdown request fences late bootstrap readiness. Never
        // publish a ready phase after the accepted stop boundary.
        guard bootstrapStillCurrent(epoch: epoch, owner: owner) else {
            return .rejected(.alreadyDraining)
        }
        withStateLock {
            if var live = generation, live.epoch == epoch,
               live.owner === owner, !live.retiring,
               phase == .starting {
                live.ownedStorePhase = afterOpen
                generation = live
            }
        }
        await owner.recover(token: epoch)
        let afterRecover = await owner.currentPhase
        let recoverFailure = await owner.lastFailureCode()
        guard afterRecover == .ready else {
            let code = recoverFailure ?? .recoveryFailed
            recordBootstrapFailure(epoch: epoch, owner: owner, code: code)
            guard bootstrapStillCurrent(epoch: epoch, owner: owner) else {
                return .rejected(.alreadyDraining)
            }
            withStateLock {
                if var live = generation, live.epoch == epoch,
                   live.owner === owner, !live.retiring,
                   phase == .starting {
                    live.ownedStorePhase = afterRecover
                    generation = live
                }
            }
            return await retireFailed(gen: gen, correlation: correlation, code: code)
        }
        guard bootstrapStillCurrent(epoch: epoch, owner: owner) else {
            return .rejected(.alreadyDraining)
        }
        let summary = await owner.currentRecoverySummary()
        let committed = withStateLock { () -> Bool in
            guard var live = generation, live.epoch == epoch,
                  live.owner === owner, !live.retiring,
                  phase == .starting else { return false }
            live.ownedStorePhase = .ready
            live.recovery = summary
            generation = live
            return true
        }
        guard committed else { return .rejected(.alreadyDraining) }
        // G02 temporary package (RB5 successor) pre-bootstrap registration:
        // the REAL optional-domain extension is registered in the idle
        // window and attaches INSIDE the owned install below. The ordinary
        // base installs INDEPENDENTLY of it: an attach failure is honest
        // and non-gating, and `registerExtension` naturally refuses once a
        // generation is installing or live (idempotent per process).
        G02TemporaryDomainRegistration.registerIfNeeded()
        // G02: construct the real domain service graph over THIS
        // generation's owned cluster and bind every G02 command handler
        // before the bootstrap terminal settles. Failure leaves the
        // ordinary runtime honestly uninstalled (no partial advertisement).
        //
        // Trusted official-catalog resource (Main's
        // MAIN_BUNDLED_PROVIDER_CATALOG_GAP_20261020): the trusted host read
        // the packaged, reviewed `provider/ProviderCatalog.json` asset and
        // froze those exact bytes through the pre-start host seam
        // (`floe_host_catalog_freeze`). Passing them here is the ONLY
        // production injection point; when the host did not freeze a valid
        // document this is nil and the facade keeps its honest typed
        // `needsConfiguration(catalogNotInjected)` refusal (the Custom
        // compatible-endpoint path stays available). Never a fixture.
        let domainRuntimeReady = await G02RuntimeComposition.shared.install(
            gen: gen,
            catalogBytes: G02HostCatalog.frozenBytes())

        // Honest detail: bootstrap committed; ordinary runtime admission
        // remains gated per-domain (separate typed facts in status).
        return .accepted(detail: ["ownedStoreReady": "true",
                                  "domainRuntimeReady": domainRuntimeReady ? "true" : "false"])
    }

    private static func recordBootstrapFailure(epoch: UInt64,
                                              owner: AndroidRuntimeStoreOwner,
                                              code: RuntimeFacadeCode) {
        withStateLock {
            if var live = generation, live.epoch == epoch,
               live.owner === owner, !live.retiring {
                live.lastFailure = code
                if live.shutdownCorrelation != nil {
                    live.shutdownFinalPhase = .failed
                }
                generation = live
            }
            if let live = generation, live.epoch == epoch, live.owner === owner {
                lastFailureCode = code
            }
        }
    }

    // Internal for the G02 composition's pre/post-await currency checks
    // (same module; the composition hook delta is the only caller).
    static func bootstrapStillCurrent(epoch: UInt64,
                                      owner: AndroidRuntimeStoreOwner) -> Bool {
        withStateLock {
            guard let live = generation, live.epoch == epoch,
                  live.owner === owner else { return false }
            return !live.retiring && phase == .starting
        }
    }

    /// Combined real drain predicate: mailbox operation slots AND the
    /// registered domain-owned work port. This is the ONLY gate before a
    /// retirement close; a mailbox that looks idle while a real run/tool/
    /// vault operation is still attached is NOT drained.
    private static func waitForLifecycleDrain(mailbox: FacadeCommandMailbox,
                                              epoch: UInt64,
                                              correlation: String,
                                              timeoutMillis: Int) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(max(0, timeoutMillis)) &* 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let mailboxIdle = mailbox.isIdleIgnoringSelf(correlation: correlation)
            let ownedWork = RuntimeOwnedWorkRegistry.shared.count(for: epoch)
            if mailboxIdle, ownedWork == 0 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
            if Task.isCancelled { break }
        }
        return mailbox.isIdleIgnoringSelf(correlation: correlation)
            && RuntimeOwnedWorkRegistry.shared.count(for: epoch) == 0
    }

    /// M4 + R3: a failed bootstrap keeps ownership until the REAL database
    /// close completes. If the bounded drain times out, nothing is closed or
    /// released: the generation enters `failedDrainPending`, keeps the live
    /// database and every active/queued slot, and a controlled retirement
    /// control is minted once the real work completes.
    private static func retireFailed(gen: Generation, correlation: String,
                                     code: RuntimeFacadeCode) async
        -> RuntimeCommandResult {
        var delegatedToShutdownControl = false
        var ownsGeneration = false
        var alreadyRetiring = false
        withStateLock {
            guard var live = generation, live.epoch == gen.epoch,
                  live.owner === gen.owner else { return }
            ownsGeneration = true
            if live.shutdownCorrelation != nil, live.shutdownReceipt != nil {
                // A shutdown control is already the single owner of the
                // close. Do not wait for it (it is waiting for this very
                // bootstrap job): record the failure, remain retiring, and
                // let the control drain/close with final phase failed.
                delegatedToShutdownControl = true
                live.lastFailure = code
                live.retiring = true
                live.retirementPending = nil
                live.shutdownFinalPhase = .failed
                generation = live
                lastFailureCode = code
                phase = .failedDrainPending
                return
            }
            guard !live.retiring else {
                alreadyRetiring = true
                return
            }
            live.lastFailure = code
            live.retiring = true
            live.retirementPending = nil
            generation = live
            lastFailureCode = code
            phase = .failedDrainPending
        }
        if delegatedToShutdownControl {
            return .failed(code, detail: ["drain": "delegatedToShutdownControl"])
        }
        guard ownsGeneration else {
            return .failed(code, detail: ["drain": "notOwner"])
        }
        if alreadyRetiring {
            return .failed(code, detail: ["drain": "alreadyPending"])
        }
        // Test-only rendezvous BEFORE the fence so a test can queue real
        // outstanding command work; production leaves this nil.
        if let gate = failedBootstrapDrainGateForTesting {
            await gate()
        }
        gen.mailbox.beginDraining()
        // Commands fail closed immediately; bootstrap-scope effects that were
        // already queued settle during the drain before retirement below.
        uninstallBridgeIfOwned(gen: gen)
        let drained = await waitForLifecycleDrain(
            mailbox: gen.mailbox, epoch: gen.epoch, correlation: correlation,
            timeoutMillis: shutdownDrainTimeoutMillis)
        guard drained else {
            withStateLock {
                if var live = generation, live.epoch == gen.epoch,
                   live.owner === gen.owner {
                    live.retirementPending = .shutdownTimeout
                    generation = live
                }
                if let live = generation, live.epoch == gen.epoch,
                   live.owner === gen.owner {
                    lastFailureCode = .shutdownTimeout
                }
            }
            scheduleRetirementWatch(epoch: gen.epoch)
            // The original failure remains the bootstrap's typed outcome; the
            // deferred retirement is a separate typed status fact.
            return .failed(code, detail: ["drain": "pending",
                                          "retirementPending": "shutdownTimeout"])
        }
        gen.mailbox.retireAfterDrain(excludingCorrelation: correlation)
        await G02RuntimeComposition.shared.beginRetirement(epoch: gen.epoch)
        await gen.owner.close()
        gen.content.retireAll()
        RuntimeOwnedWorkRegistry.shared.finishGeneration(epoch: gen.epoch)
        RuntimeRetiredEffectRegistry.shared.stagePending(generation: gen.epoch,
                                                         effects: gen.effects)
        // Full-owner guarded GLOBAL release; the old generation's retired
        // anchor is staged even when a newer generation already owns the
        // globals (readability preserved, newer state untouched).
        _ = releaseRetiredGeneration(gen: gen, receipt: gen.bootstrapReceipt,
                                     finalPhase: .failed)
        // NOTE: the bootstrap job's single terminal settles via the mailbox
        // AFTER this return; the observer then snapshots the terminal streams
        // into the bounded retired-receipt registry (DB is already closed).
        return .failed(code, detail: ["drain": "complete", "dbClosed": "true"])
    }

    /// Controlled failed-retirement retry. A watcher polls only the mailbox's
    /// REAL drain predicate (no time disposal) and, once everything settled,
    /// enqueues the single retirement control. The control runs the same close
    /// path as a normal shutdown and leaves the final phase `.failed`.
    private static func scheduleRetirementWatch(epoch: UInt64) {
        let shouldStart: Bool = withStateLock {
            guard var live = generation, live.epoch == epoch,
                  live.retiring, phase == .failedDrainPending else { return false }
            if let existing = live.retirementWatchTask, !existing.isCancelled {
                return false
            }
            return true
        }
        guard shouldStart else { return }
        let task = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let state: (live: Bool, mailboxDrained: Bool) = withStateLock {
                    guard let live = generation, live.epoch == epoch,
                          live.retiring, phase == .failedDrainPending else {
                        return (false, false)
                    }
                    return (true, live.mailbox.isFullyDrained())
                }
                if !state.live { return }
                // Registry read OUTSIDE the lifecycle lock (registry may take
                // the lifecycle lock during attach; no inverse nesting).
                let ownedWork = RuntimeOwnedWorkRegistry.shared.count(for: epoch)
                if state.mailboxDrained, ownedWork == 0 {
                    _ = enqueueFailedRetirementControl(epoch: epoch)
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        withStateLock {
            if var live = generation, live.epoch == epoch {
                live.retirementWatchTask = task
                generation = live
            }
        }
    }

    private static func enqueueFailedRetirementControl(epoch: UInt64) -> ShutdownOutcome {
        withStateLock {
            guard var live = generation, live.epoch == epoch,
                  live.retiring, phase == .failedDrainPending else {
                return .rejected(.notInstalled)
            }
            return enqueueRetryControlLocked(&live, finalPhase: .failed)
        }
    }

    /// Resolves the single anchor terminal after the real close. Called by the
    /// mailbox settlement observer outside the mailbox lock. Never mutates a
    /// pump and never touches a new generation: it copies terminal streams
    /// from THIS retired generation only.
    private static func handleTerminalSettled(epoch: UInt64,
                                              effects: FacadeEffectPump,
                                              receipt: String,
                                              mailbox: FacadeCommandMailbox?) {
        let hasAnchor = isRetiredGeneration(epoch,
                                            effectsID: ObjectIdentifier(effects))
        if hasAnchor {
            let streams = effects.exportTerminalStreams()
            RuntimeRetiredEffectRegistry.shared.retire(generation: epoch,
                                                       streams: streams)
            let isFinalAnchor: Bool = withStateLock {
                guard let anchor = retiredAnchors.first(where: { $0.epoch == epoch }),
                      anchor.receipt == receipt else { return false }
                retiredAnchors.removeAll { $0.epoch == epoch }
                return true
            }
            if isFinalAnchor {
                RuntimeRetiredEffectRegistry.shared.completePending(generation: epoch)
                mailbox?.setTerminalObserver(nil)
            }
            return
        }
        // A failed bootstrap whose real work just finished: schedule the
        // controlled retirement (single controller; no time disposal).
        let pending = withStateLock {
            guard let live = generation, live.epoch == epoch,
                  live.effects === effects,
                  live.retiring, phase == .failedDrainPending else { return false }
            return true
        }
        if pending { scheduleRetirementWatch(epoch: epoch) }
    }

    /// Attachment policy used by `RuntimeOwnedWorkRegistry`. It is the SAME
    /// accepted-generation fence as the command surface: no attach before the
    /// real owned store committed, and no attach after a stop/retirement was
    /// requested. `domainNotBound` keeps the ordinary-runtime barrier honest.
    static func ownedWorkAttachAllowed(epoch: UInt64) -> RuntimeFacadeCode? {
        withStateLock {
            guard let live = generation, live.epoch == epoch else {
                return .notInstalled
            }
            if phase == .draining || phase == .failedDrainPending || live.retiring {
                return .alreadyDraining
            }
            guard phase == .starting else { return .notInstalled }
            guard live.ownedStorePhase == .ready else { return .domainNotBound }
            return nil
        }
    }

    private static func finalLifecyclePhase(epoch: UInt64,
                                            fallback: Phase) -> Phase {
        withStateLock {
            guard let live = generation, live.epoch == epoch else {
                return fallback
            }
            if phase == .failedDrainPending { return .failed }
            if let failure = live.lastFailure, failure != .shutdownTimeout {
                return .failed
            }
            return fallback
        }
    }

    /// The shutdown/retirement job. `correlation` is the ACTUAL correlationID
    /// of the job that is executing (RB1-R2) — never a reconstructed name.
    static func runShutdownJob(epoch: UInt64, receipt: String,
                               correlation: String) async -> RuntimeCommandResult {
        let resolved: (gen: Generation, finalPhase: Phase)? = withStateLock {
            guard let live = generation, live.epoch == epoch,
                  live.shutdownReceipt == receipt,
                  live.shutdownCorrelation == correlation else { return nil }
            return (live, phase == .failedDrainPending ? .failed : .stopped)
        }
        guard let resolvedValue = resolved else {
            return .rejected(.notInstalled)
        }
        let gen = resolvedValue.gen
        let finalPhase = resolvedValue.finalPhase
        // Redundant safety only: the fence was applied at the accepted
        // boundary (M3/R4).
        gen.mailbox.beginDraining()
        let drained = await waitForLifecycleDrain(
            mailbox: gen.mailbox, epoch: gen.epoch, correlation: correlation,
            timeoutMillis: shutdownDrainTimeoutMillis)
        guard drained else {
            withStateLock {
                if var live = generation, live.epoch == epoch,
                   live.owner === gen.owner,
                   live.shutdownReceipt == receipt {
                    live.lastFailure = .shutdownTimeout
                    live.retirementPending = .shutdownTimeout
                    // No live controller remains; a caller may retry.
                    live.shutdownCorrelation = nil
                    generation = live
                }
                if let live = generation, live.epoch == epoch,
                   live.owner === gen.owner {
                    lastFailureCode = .shutdownTimeout
                }
                if phase != .failedDrainPending { phase = .draining }
            }
            if finalPhase == .failed || withStateLock({ phase == .failedDrainPending }) {
                scheduleRetirementWatch(epoch: epoch)
            }
            // Ownership retained: mailbox stays fenced, effect polling stays
            // available, database and every real slot stay open.
            return .failed(.shutdownTimeout)
        }
        // Binder command ingress first: validated commands now receive the
        // unchanged runtimeUnavailable refusal exactly as before RB1 existed.
        // The read-only effect route stays bound for the terminal (R1).
        // Full-owner guarded: a stale cleanup never removes a newer
        // generation's process-wide ingress.
        uninstallBridgeIfOwned(gen: gen)
        // Retire WITHOUT settling the control itself (M3).
        gen.mailbox.retireAfterDrain(excludingCorrelation: correlation)
        // G02 RootStop: cancel owned domain services + unregister domain
        // handlers BEFORE the real database close.
        await G02RuntimeComposition.shared.beginRetirement(epoch: gen.epoch)
        // The real database close happens BEFORE this job's single terminal.
        await gen.owner.close()
        gen.content.retireAll()
        RuntimeOwnedWorkRegistry.shared.finishGeneration(epoch: epoch)
        RuntimeRetiredEffectRegistry.shared.stagePending(generation: epoch,
                                                         effects: gen.effects)
        let effectiveFinalPhase = finalLifecyclePhase(epoch: epoch,
                                                      fallback: finalPhase)
        // GLOBAL release is full-owner guarded AFTER every await above: a
        // late old cleanup stages only its own retired-receipt anchor and
        // never erases a newer generation's globals.
        _ = releaseRetiredGeneration(gen: gen, receipt: receipt,
                                     finalPhase: effectiveFinalPhase)
        // NOTE: NO effects.retire() here. The shutdown terminal settles via
        // the mailbox after this return and must remain readable through the
        // bounded retired-receipt route (R1).
        return .accepted(detail: ["drained": "true", "dbClosed": "true",
                                  "ownedStoreReady": "false"])
    }

    /// R4: the public `system.shutdown` command's OWN receipt is the control
    /// receipt. It settles through the normal mailbox settlement only AFTER
    /// the real drain + `DatabaseManager.close()`. No outer job is created.
    static func runPublicShutdown(job: RuntimeCommandEnvelopeJob,
                                  expectedEpoch: UInt64) async
        -> RuntimeCommandResult {
        var adoptionFailure: RuntimeFacadeCode? = nil
        let adopted: Generation? = withStateLock {
            guard var live = generation, live.epoch == expectedEpoch,
                  !live.retiring, phase == .starting else {
                adoptionFailure = .alreadyDraining
                return nil
            }
            guard live.shutdownReceipt == nil else {
                adoptionFailure = .alreadyDraining
                return nil
            }
            live.shutdownReceipt = job.receipt
            live.shutdownCorrelation = job.correlationID
            live.shutdownFinalPhase = .stopped
            // R4: fence admission atomically with adopting this job as THE
            // control (the same lock hold), so no second public stop can be
            // admitted in the gap before the drain wait.
            live.mailbox.beginDraining()
            generation = live
            phase = .draining
            return live
        }
        guard let gen = adopted else {
            return .rejected(adoptionFailure ?? .notInstalled)
        }
        let drained = await waitForLifecycleDrain(
            mailbox: gen.mailbox, epoch: gen.epoch,
            correlation: job.correlationID,
            timeoutMillis: shutdownDrainTimeoutMillis)
        guard drained else {
            withStateLock {
                if var live = generation, live.epoch == gen.epoch,
                   live.owner === gen.owner,
                   live.shutdownReceipt == job.receipt {
                    live.lastFailure = .shutdownTimeout
                    live.retirementPending = .shutdownTimeout
                    live.shutdownCorrelation = nil
                    generation = live
                }
                if let live = generation, live.epoch == gen.epoch,
                   live.owner === gen.owner {
                    lastFailureCode = .shutdownTimeout
                }
                if phase != .failedDrainPending { phase = .draining }
            }
            if withStateLock({ phase == .failedDrainPending }) {
                // A failed bootstrap delegated its close to this public
                // control; once the real work drains, the watcher mints the
                // single retirement control instead of orphaning the owner.
                scheduleRetirementWatch(epoch: gen.epoch)
            }
            // The public receipt itself settles typed `failed` here; the
            // database and all real work stay owned for a trusted retry.
            return .failed(.shutdownTimeout)
        }
        uninstallBridgeIfOwned(gen: gen)
        gen.mailbox.retireAfterDrain(excludingCorrelation: job.correlationID)
        await G02RuntimeComposition.shared.beginRetirement(epoch: gen.epoch)
        await gen.owner.close()
        gen.content.retireAll()
        RuntimeOwnedWorkRegistry.shared.finishGeneration(epoch: gen.epoch)
        RuntimeRetiredEffectRegistry.shared.stagePending(generation: gen.epoch,
                                                         effects: gen.effects)
        let effectiveFinalPhase = finalLifecyclePhase(epoch: gen.epoch,
                                                      fallback: .stopped)
        // Full-owner guarded GLOBAL release (same rule as the control job).
        _ = releaseRetiredGeneration(gen: gen, receipt: job.receipt,
                                     finalPhase: effectiveFinalPhase)
        return .accepted(detail: ["drained": "true", "dbClosed": "true",
                                  "ownedStoreReady": "false"])
    }

    /// R4: `system.bootstrap` is a CONFIRMATION only. It returns accepted
    /// only when the CURRENT live generation is still starting, not retiring,
    /// has no failure, and its owned store actually reached `.ready`.
    static func confirmCommitted(expectedEpoch: UInt64) -> Bool {
        withStateLock {
            guard let live = generation, live.epoch == expectedEpoch,
                  !live.retiring, phase == .starting,
                  live.ownedStorePhase == .ready,
                  live.lastFailure == nil else { return false }
            return true
        }
    }

    // MARK: - Synchronous status / stats (lock-only; no raw path, no bytes)

    public static func statusSnapshotJSON() -> String {
        let snapshot: (live: Generation?, phase: Phase, lastFailure: RuntimeFacadeCode?)
            = withStateLock { (generation, phase, lastFailureCode) }
        let live = snapshot.live
        var object: [String: Any] = [
            "version": 1,
            "phase": snapshot.phase.rawValue,
            "gatewayRegistered": SecretGatewayRegistry.shared.isRegistered,
            "ownedStoreReady": live?.ownedStorePhase == .ready,
            "ownedStorePhase": live?.ownedStorePhase.rawValue
                ?? AndroidRuntimeStoreOwner.Phase.closed.rawValue,
            "domainRuntimeReady": false,
            "businessCapabilities": [String](),
            "localLLM": false,
            "supportedSchemas": [
                BridgeV3.commandSchema, BridgeV3.runEventSchema, BridgeV3.effectSchema,
            ],
            // Read-only receipt polling is a SEPARATE fact from owned-store or
            // domain readiness: it may stay available after the database closed.
            "effectPollAvailable": live != nil
                || !RuntimeRetiredEffectRegistry.shared.isEmpty,
            "retiredReceiptGenerations":
                RuntimeRetiredEffectRegistry.shared.retainedGenerationCount,
        ]
        if let live {
            object["generation"] = live.epoch
            object["rootFingerprint"] = live.identity.root.fingerprint
            object["retiring"] = live.retiring
            object["schemaVersion"] = DatabaseManager.currentSchemaVersion
            object["recovery"] = [
                "transientInputsRecovered": live.recovery.transientInputsRecovered,
                "interruptedChildren": live.recovery.interruptedChildrenMarked,
                "interruptedRuns": live.recovery.interruptedRunsMarked,
                "credentialDeletionsPending": live.recovery.credentialDeletionsPending,
                "credentialDeletionsDrained": live.recovery.credentialDeletionsDrained,
                "credentialDeletionsDeferred": live.recovery.credentialDeletionsDeferred,
            ]
            object["boundHandlerKeys"] = live.registry.boundHandlerKeys
            object["mailbox"] = safeJSONObject(live.mailbox.statsJSON())
            object["effects"] = live.effects.statsSnapshot()
            object["events"] = live.events.statsSnapshot()
            object["content"] = live.content.statsSnapshot()
            if let failure = live.lastFailure {
                object["lastFailure"] = failure.rawValue
            }
            if let pending = live.retirementPending {
                object["retirementPending"] = pending.rawValue
            }
            if live.shutdownReceipt != nil {
                object["shutdownFinalPhase"] = live.shutdownFinalPhase.rawValue
            }
        }
        object["domainOwnedWork"] = live.map {
            RuntimeOwnedWorkRegistry.shared.count(for: $0.epoch)
        } ?? 0
        object["domainOwnedWorkByKind"] = live.map {
            RuntimeOwnedWorkRegistry.shared.countsByKind(for: $0.epoch)
        } ?? [String: Int]()
        if snapshot.live == nil, let lastFailure = snapshot.lastFailure {
            object["lastFailure"] = lastFailure.rawValue
        }
        // The typed admission barrier — the truth list, never empty while
        // ordinary runtime is unavailable.
        object["missingBindings"] = MissingBinding.allCases.map { $0.rawValue }
        object["ordinaryRuntimeAdmission"] = "blocked"
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"status_encoding\"}"
        }
        return string
    }

    private static func safeJSONObject(_ json: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [:]
    }

    // MARK: - Test-only control (never used by production hosts)

    internal static func resetForTesting() {
        let live = withStateLock { () -> Generation? in
            let value = generation
            generation = nil
            lastEpoch = 0
            phase = .stopped
            lastFailureCode = nil
            retiredAnchors.removeAll()
            shutdownDrainTimeoutMillisOverride = nil
            failedBootstrapDrainGateForTesting = nil
            return value
        }
        RuntimeFacadeBridge.uninstallAllForTesting()
        RuntimeRetiredEffectRegistry.shared.removeAllForTesting()
        RuntimeOwnedWorkRegistry.shared.removeAllForTesting()
        if let live {
            live.retirementWatchTask?.cancel()
            live.mailbox.setTerminalObserver(nil)
            live.mailbox.close(reason: .closed)
            live.effects.retire()
            live.content.retireAll()
        }
    }

    /// Test-only: the ACTUAL captured generation handle, so a regression can
    /// run the REAL retirement tail for an OLD handle while a NEWER
    /// generation is live (deterministic stale-cleanup proof).
    internal static func generationHandleForTesting() -> Generation? {
        withStateLock { generation }
    }

    /// Test-only: whether the retired-receipt anchor for one exact old
    /// generation identity is staged (a stale cleanup must still preserve
    /// retired-receipt readability while never touching newer globals).
    internal static func hasRetiredAnchorForTesting(
        epoch: UInt64, effectsID: ObjectIdentifier
    ) -> Bool {
        isRetiredGeneration(epoch, effectsID: effectsID)
    }

    /// Test-only: runs the REAL guarded retirement-tail global release for a
    /// captured handle and reports whether the globals were actually released
    /// (false == a stale cleanup correctly refused to touch them).
    @discardableResult
    internal static func runRetirementTailForTesting(
        gen: Generation, receipt: String, finalPhase: Phase
    ) -> Bool {
        releaseRetiredGeneration(gen: gen, receipt: receipt, finalPhase: finalPhase)
    }

    internal static func currentGenerationForTesting() -> (
        epoch: UInt64, effects: FacadeEffectPump, events: FacadeEventPump,
        content: FacadeContentReader, mailbox: FacadeCommandMailbox,
        registry: RuntimeDomainRegistry, owner: AndroidRuntimeStoreOwner,
        bootstrapReceipt: String)? {
        withStateLock {
            guard let live = generation else { return nil }
            return (live.epoch, live.effects, live.events, live.content,
                    live.mailbox, live.registry, live.owner, live.bootstrapReceipt)
        }
    }

    /// Live generation lookup for COMMAND handlers (receipt routing needs the
    /// CURRENT pumps, not a captured stale copy). A retiring generation is
    /// not allowed to admit commands.
    static func currentPumps() -> (effects: FacadeEffectPump, events: FacadeEventPump,
                                   content: FacadeContentReader,
                                   mailbox: FacadeCommandMailbox,
                                   epoch: UInt64, storeReady: Bool)? {
        withStateLock {
            guard let live = generation, !live.retiring else { return nil }
            return (live.effects, live.events, live.content, live.mailbox,
                    live.epoch, live.ownedStorePhase == .ready)
        }
    }

    /// Read-only effect-poll lookup. Unlike `currentPumps`, a retiring but
    /// still-owned generation remains pollable — its real terminal may not
    /// have settled yet; this never admits a command.
    static func currentEffectPumps() -> (effects: FacadeEffectPump,
                                         epoch: UInt64)? {
        withStateLock {
            guard let live = generation else { return nil }
            return (live.effects, live.epoch)
        }
    }
    // MARK: G02 trusted owner proof (job-7cd349b4cd6d4b55 narrow additive
    // delta). Synchronous, lock-only validation of the FULL owner token +
    // epoch against the live generation. Consumed ONLY by the privileged
    // native privacy-confirmation ingress; never exposed to the v3 binder.
    static func g02OwnerProofValid(epoch: UInt64, token: String) -> Bool {
        withStateLock {
            guard let live = generation, live.epoch == epoch,
                  phase == .starting, !live.retiring else { return false }
            return live.identity.token == token
        }
    }
}

// Owner-actor accessors the lifecycle needs without exposing mutable stores.
extension AndroidRuntimeStoreOwner {
    func lastFailureCode() async -> RuntimeFacadeCode? { lastFailure }
    func currentRecoverySummary() async -> RuntimeRecoverySummary { recoverySummary }
}

// MARK: - Domain-owned work attachment port (RB1-R3 / RB4 / vault-07)

/// Closed actual-work kinds that later domain owners (RB4 runs/children/tools/
/// conversations and the vault-owned operation package) MUST attach while the
/// real awaited work is live. This is a lifecycle port, not a readiness flag:
/// an attached item keeps the owned root/database open until `detach`.
public enum RuntimeOwnedWorkKind: String, Sendable, CaseIterable {
    case run
    case childRun
    case tool
    case conversation
    case vaultMaintenance
}

/// Opaque process-local work receipt returned by `attach`. Carries no path,
/// secret or model-controlled authority.
public struct RuntimeOwnedWorkToken: Sendable, Hashable {
    public let receipt: String
    public let epoch: UInt64
    public let kind: RuntimeOwnedWorkKind
    public let ownerID: String

    public init(receipt: String, epoch: UInt64, kind: RuntimeOwnedWorkKind,
                ownerID: String) {
        self.receipt = receipt
        self.epoch = epoch
        self.kind = kind
        self.ownerID = ownerID
    }
}

public enum RuntimeOwnedWorkAttachOutcome: Sendable, Equatable {
    case attached(RuntimeOwnedWorkToken)
    case rejected(RuntimeFacadeCode)
    case invalidIdentity
}

public enum RuntimeOwnedWorkReceipt {
    public static let prefix = "work:v1:"
    public static let hexLength = 32
    public static let logicalBytes = 40   // "work:v1:" (8) + 32 hex
    public static let capacity = 41       // + NUL

    public static func isValid(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == logicalBytes, value.hasPrefix(prefix) else {
            return false
        }
        let hex = value[value.index(value.startIndex, offsetBy: prefix.count)...]
        guard hex.count == hexLength else { return false }
        return hex.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

/// Bounded process-local registry of ACTUAL owned work. This is the concrete
/// integration port for RB4 (`run`, `childRun`, `tool`, `conversation`) and
/// the vault-owned-operation source (`vaultMaintenance`):
///
/// * attach is accepted only for the CURRENT accepted epoch while the owned
///   store is ready and the generation is not draining/retiring;
/// * detach is exact-token and idempotent; an old token can never affect a
///   new generation;
/// * the registry is real: `count(for:)` gates every retirement close path
///   and the retirement watcher. A zero count is meaningful only after the
///   real owner has detached every awaited operation (or when RB1's closed
///   ordinary runtime genuinely has none).
public final class RuntimeOwnedWorkRegistry: @unchecked Sendable {
    public static let shared = RuntimeOwnedWorkRegistry()

    public enum Limits {
        public static let maximumLiveWork = 256
        /// Owner identity bound (no path/secret; ASCII identity characters).
        public static let maximumOwnerIDBytes = 128
    }

    private let lock = NSLock()
    private var entries: [String: RuntimeOwnedWorkToken] = [:]
    private var order: [String] = []
    private var mintCounter: UInt64 = 0
    private let salt: Data

    public init() {
        var random = Data(count: 16)
        for index in random.indices { random[index] = UInt8.random(in: 0...255) }
        self.salt = random
    }

    /// Exact-token attach. `ownerID` is an opaque domain identity (UUID or
    /// similar), never a path, token, secret or model-supplied root.
    public func attach(epoch: UInt64, kind: RuntimeOwnedWorkKind,
                       ownerID: String) -> RuntimeOwnedWorkAttachOutcome {
        guard Self.isValidOwnerID(ownerID) else {
            return .invalidIdentity
        }
        lock.lock()
        defer { lock.unlock() }
        guard entries.count < Limits.maximumLiveWork else {
            return .rejected(.receiptSaturated)
        }
        // Registry -> lifecycle lock is the only nesting; the lifecycle never
        // takes the registry lock while holding its own lock.
        if let rejection = AndroidRuntimeBootstrap
            .ownedWorkAttachAllowed(epoch: epoch) {
            return .rejected(rejection)
        }
        var token: RuntimeOwnedWorkToken?
        for _ in 0..<8 {
            mintCounter &+= 1
            let input = salt + Data(
                "epoch:\(epoch);kind:\(kind.rawValue);owner:\(ownerID);mint:\(mintCounter)".utf8)
            let hex = SHA256.hash(data: input).prefix(16)
                .map { String(format: "%02x", $0) }.joined()
            let receipt = RuntimeOwnedWorkReceipt.prefix + hex
            if entries[receipt] == nil {
                token = RuntimeOwnedWorkToken(receipt: receipt, epoch: epoch,
                                              kind: kind, ownerID: ownerID)
                break
            }
        }
        guard let token else { return .rejected(.internal) }
        entries[token.receipt] = token
        order.append(token.receipt)
        return .attached(token)
    }

    /// Exact-token detach. Late/foreign/duplicate detach returns false and
    /// never mutates a newer generation.
    @discardableResult
    public func detach(_ token: RuntimeOwnedWorkToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard entries[token.receipt] == token else { return false }
        entries.removeValue(forKey: token.receipt)
        order.removeAll { $0 == token.receipt }
        return true
    }

    public func isAttached(_ token: RuntimeOwnedWorkToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[token.receipt] == token
    }

    public func count(for epoch: UInt64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter { $0.epoch == epoch }.count
    }

    public func countsByKind(for epoch: UInt64) -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        var counts: [String: Int] = [:]
        for token in entries.values where token.epoch == epoch {
            counts[token.kind.rawValue, default: 0] += 1
        }
        return counts
    }

    public var totalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Monotonic bounded wait used by the retirement paths. Zero is truthful
    /// only when every registered owner has really detached.
    public func waitForDrain(epoch: UInt64, timeoutMillis: Int) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(max(0, timeoutMillis)) &* 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if count(for: epoch) == 0 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
            if Task.isCancelled { return count(for: epoch) == 0 }
        }
        return count(for: epoch) == 0
    }

    /// Called only after the lifecycle has observed zero and closed the DB.
    /// Removes any impossible leftover so a new generation cannot inherit it.
    @discardableResult
    public func finishGeneration(epoch: UInt64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let receipts = entries.values.filter { $0.epoch == epoch }.map(\.receipt)
        for receipt in receipts { entries.removeValue(forKey: receipt) }
        order.removeAll { receipt in receipts.contains(receipt) }
        return receipts.count
    }

    public func removeAllForTesting() {
        lock.lock()
        entries.removeAll()
        order.removeAll()
        lock.unlock()
    }

    private static func isValidOwnerID(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= Limits.maximumOwnerIDBytes else {
            return false
        }
        return bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 46 || byte == 95 || byte == 58 || byte == 45
        }
    }
}
