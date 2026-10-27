// FloeAndroidCore — D04 run-output service: the trusted runtime owner of
// the sealed snapshot store, the configured `workspace.publishOutput`
// registration and the durable cleanup queue on Android.
//
// (job-3135f83ef97c4a21; ports iOS main 8f185ac D04:
// `RunOutputSnapshotStore` blob edb6b8dd, `RunOutputCleanupQueue` blob
// 881145e4, `WorkspacePublishOutputTool` blob c85a3b0c — see
// Sources/FloeTools/RunOutputSnapshotStore.swift,
// Sources/FloeTools/RunOutputCleanupQueue.swift and
// Sources/FloeWorkspace/Tools/WorkspacePublishOutputTool.swift headers for
// the recorded deltas. Lifetime hardening per the coordinator API review
// of 2026-10-27: generation-bound operation leases, retire highwater,
// instance-bound registration, and result-boundary generation rechecks.)
//
// Why this file exists:
// * On iOS the artifact store resolves through Application Support and the
//   App layer registers the tool + wires deletion/bootstrap (AppEnvironment
//   / ConversationCenter). Android has NO implicit application-support
//   authority: the Foundation default can resolve below `$HOME`, which is
//   not an app-owned persistent root. Like `EnvironmentRoots.makeTrusted`
//   (G03-R1) and `RuntimeFacadeLinuxBindings.registerIntoCurrentGeneration`,
//   production therefore requires an EXPLICIT trusted binding supplied by
//   the composition — here the owned persistent root carried by the REAL
//   `RuntimeStorageRoot` of the accepted generation. Absent the binding
//   every entry point below fails closed (`unavailable`), honestly: no
//   snapshot is written, no tool is executable, no tree is deleted.
// * Producer authority stays call-bound. `publish` takes the runtime-issued
//   `ToolContext` and forwards to the store, which requires the real tool-
//   call + task binding and refuses temporary (ephemeral) runs. A model,
//   document or tool output cannot mint an artifact root, a receipt, a
//   lease or a cleanup request through this surface — only trusted
//   in-process owners (the registered tool execution, the runtime seal in
//   `AgentRuntime.finalizeToolResult`, `FacadeConversationDomain`'s
//   deletion, `AndroidRuntimeStoreOwner`'s bootstrap readiness) call it.
// * Lifetime safety (the cascade-window gap): the DB `runs` row is removed
//   BY the conversation cascade itself, so a post-cascade row probe can
//   never see a publisher/download/native job that survived it. Ownership
//   therefore composes two REAL signals: (a) this facade's generation-bound
//   operation leases, acquired by every configured publication and by any
//   trusted consumer through the same seam, and (b) the deletion flow's
//   own exact RB1 owned-work tokens (`RuntimeOwnedWorkRegistry`
//   isAttached recheck). BOTH the immediate deletion path and the
//   readiness retry consult them; cleanup never races an active lease.
// * Stale completions: `install`/`retire` keep a monotonic epoch fence
//   (a retired generation can never be resurrected by an old install), and
//   every long operation captures its generation and REVALIDATES at its
//   result boundary. A publication whose generation was retired or rebound
//   mid-flight preserves its committed bytes (the store never rolls back
//   another receipt's durability) but the receipt is refused, never
//   advertised as usable ownership.
// * No public "purge everything" tool exists or is added: cleanup is exact,
//   conversation-owned and durable (queue semantics upstream), and the
//   live-ownership probes can retain requests until real owners release
//   the outputs. Notes/Canvas persistence lives in different stores and
//   namespaces — chat cleanup can never remove a Notes file through any
//   path here.

import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeWorkspace

/// The trusted artifact-store binding for the CURRENTLY accepted runtime
/// generation: the owned persistent root under which `RunOutputs/<runID>/`
/// snapshots and `RunOutputCleanupRequests/` tombstones live.
public struct RunOutputStoreBinding: Sendable, Equatable {
    public let artifactRoot: URL
    public let epoch: UInt64
}

/// One acquired generation-bound operation lease (publication in flight,
/// or a trusted consumer's owned operation). Opaque id + the minting
/// generation + the owning run; grants nothing by itself and is never
/// Codable: a model payload cannot mint, hold or release one.
public struct RunOutputLeaseToken: Sendable, Hashable {
    public let leaseID: UInt64
    public let epoch: UInt64
    public let runID: UUID
    /// Bounded trusted owner label (catalog tool name / service name),
    /// for diagnostics only — never payload text.
    public let owner: String
}

/// Outcome of a validated read resolution for one sealed receipt.
public enum RunOutputVerifiedRead: Sendable, Equatable {
    /// Binding present, ownership proven, snapshot canonical, size and
    /// SHA-256 re-verified at retrieval, AND the minting generation is
    /// still current at the result boundary: the URL is the validated
    /// local bytes (the consumer streams them; nothing is cached into RAM
    /// here).
    case resolved(url: URL)
    /// No trusted runtime binding is installed (Android fail-closed), or
    /// the generation was retired/rebound during resolution.
    case unavailable
    /// The requesting conversation does not own the sealed receipt
    /// (taskID mismatch or absent). Never surfaces another task's bytes.
    case notOwner
    case missing(displayName: String)
    case changed(displayName: String)
    case oversized(displayName: String)
    case rejected(reason: String)
}

/// Process-lifecycle owner of the D04 run-output surface. Mirrors the
/// established `RuntimeFacadeLinuxBindings` generation pattern: synchronous
/// thread-safe state under one lock, epoch-fenced installation by the
/// trusted composition only (no model route, no JNI export in this batch —
/// the App/bridge glue is the next consumer). Instances are injectable for
/// focused qualification; `shared` is the production composition point.
public final class RuntimeFacadeRunOutput: @unchecked Sendable {
    public static let shared = RuntimeFacadeRunOutput()

    private let stateLock = NSLock()
    private var binding: RunOutputStoreBinding?
    /// Monotonic retirement fence (coordinator review 2026-10-27): once an
    /// epoch is retired, `install` refuses that epoch AND every lower one,
    /// so a late/old call can never resurrect a retired generation.
    private var retiredHighWater: UInt64 = 0
    private var leases: [UInt64: RunOutputLeaseToken] = [:]
    private var leaseCounter: UInt64 = 0
    /// Runs currently under a narrow cleanup claim (2026-10-27 lifetime
    /// review): publications for a claimed run fail closed for the claim's
    /// duration, so cleanup removes bytes under real exclusion instead of
    /// racing a probe-then-delete boolean.
    private var cleaningRunIDs: Set<UUID> = []

    public init() {}

    // MARK: - Trusted composition binding

    /// Installs (or rebinds) the run-output storage for the accepted
    /// generation. `artifactRoot` must be the SAME owned persistent root
    /// validated by `RuntimeStorageRoot` (absolute, normalized, non-root,
    /// control-character-free); anything else is refused. A retired or
    /// stale epoch can never (re)install; a same-epoch rebind is allowed
    /// only for the identical owned root. Registers
    /// `workspace.publishOutput` into the configured registry bound to
    /// THIS instance so injected instances/registries read their own
    /// binding, never another object's.
    @discardableResult
    public func install(artifactRootPath: String, epoch: UInt64) -> Bool {
        guard epoch > 0,
              let storage = RuntimeStorageRoot(validatingAbsoluteDirectory: artifactRootPath)
        else { return false }
        stateLock.lock()
        guard epoch > retiredHighWater else {
            stateLock.unlock()
            return false
        }
        if let current = binding, current.epoch > epoch {
            stateLock.unlock()
            return false
        }
        if let current = binding, current.epoch == epoch,
           current.artifactRoot.path != storage.path {
            // Different owned root at the SAME accepted epoch is a real
            // conflict: refuse rather than re-pointing a live generation.
            stateLock.unlock()
            return false
        }
        binding = RunOutputStoreBinding(
            artifactRoot: URL(fileURLWithPath: storage.path, isDirectory: true),
            epoch: epoch
        )
        stateLock.unlock()
        registerOutputTool()
        return true
    }

    /// Retirement for the CURRENT binding only, advancing the monotonic
    /// fence: a late call from an older generation can never tear down a
    /// newer binding, and after retirement the SAME epoch can never be
    /// re-installed. In-flight leases are NOT force-released (their owners
    /// must finish and release; cleanup keeps retaining while any lease is
    /// active); durable trees and tombstones on disk are untouched.
    public func retire(epoch: UInt64) {
        stateLock.lock()
        if binding?.epoch == epoch {
            binding = nil
            retiredHighWater = max(retiredHighWater, epoch)
        }
        stateLock.unlock()
    }

    public func currentBinding() -> RunOutputStoreBinding? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return binding
    }

    /// Synchronous root read for the registered tool's
    /// `artifactRootProvider` (bound to THIS instance). Returns nil
    /// whenever no binding is current; the store then fails closed
    /// (Android) exactly as documented.
    public func currentArtifactRoot() -> URL? {
        capturedStoreBinding()?.artifactRoot
    }

    private func capturedStoreBinding() -> RunOutputStoreBinding? {
        stateLock.lock(); defer { stateLock.unlock() }
        return binding
    }

    // MARK: - Configured tool registration (instance-bound)

    /// Registers the D04 publisher into the EXISTING catalog/registry
    /// (called from `install` on the shared process registry, and directly
    /// with an injected registry by focused qualification). Every provider
    /// and gate closure is bound to THIS instance: an injected facade's
    /// runner can only ever read its own binding/leases, never the
    /// singleton's. The tool resolves its workspace root from
    /// `context.workspaceRootURL` (the per-run trusted binding assembled by
    /// `RuntimeFacadeRunAssembly`); with no context root it fails
    /// structured-closed, never a fallback.
    ///
    /// Discovery filtering is the REAL mechanism the existing contract
    /// already provides: `ToolRunnerRegistry.runner(named:)` and
    /// `allDescriptors` (the `CatalogToolExecutor` executable surface)
    /// evaluate `isAvailable`, so after `retire` the publisher stops being
    /// reachable/advertised at the next check without any removal dance.
    /// The compile-time `ToolCatalog` descriptor entry remains exactly what
    /// the existing architecture says it is — documentation, not an
    /// executable tool (`allDescriptors` comes from runners only); this
    /// makes no claim of catalog deletion.
    @discardableResult
    public func registerOutputTool(
        into registry: ToolRunnerRegistry = .shared
    ) -> Bool {
        guard currentArtifactRoot() != nil else {
            // Discovery must reflect an actually usable capability: an
            // unbound generation does not advertise the publisher.
            return false
        }
        registerWorkspacePublishOutputTool(
            artifactRootProvider: { [weak self] in self?.currentArtifactRoot() },
            operationGate: self,
            isAvailable: { [weak self] in self?.currentArtifactRoot() != nil },
            registry: registry
        )
        return true
    }

    // MARK: - Generation-bound operation leases (trusted seam)

    /// Acquires one live-operation lease for `runID` under the CURRENT
    /// binding ATOMICALLY: one lock section reads the binding, checks the
    /// cleaning claim and mints the lease, so no retire/install can split
    /// the capture (2026-10-27 lifetime review). Returns nil when no
    /// trusted generation is bound or a cleanup claim covers the run
    /// (callers must then fail closed). Trusted in-process owners use this
    /// seam for ANY operation whose completion must be visible to
    /// run-output cleanup: the publication paths below already do, and the
    /// later Office/App producers/consumers join through the same
    /// acquire/release pair — never a path/permission parallel system.
    public func acquireLease(runID: UUID, owner: String) -> RunOutputLeaseToken? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return acquireLeaseLocked(runID: runID, owner: owner)
    }

    private func acquireLeaseLocked(runID: UUID, owner: String) -> RunOutputLeaseToken? {
        let bounded = String(owner.prefix(128))
        guard !bounded.isEmpty,
              cleaningRunIDs.contains(runID) == false,
              let binding else { return nil }
        leaseCounter &+= 1
        let token = RunOutputLeaseToken(
            leaseID: leaseCounter, epoch: binding.epoch, runID: runID, owner: bounded)
        leases[token.leaseID] = token
        return token
    }

    /// Releases exactly one acquired lease. Unknown/foreign ids (old
    /// generation, double release) are idempotent no-ops and can never
    /// release another owner's lease.
    public func releaseLease(_ token: RunOutputLeaseToken) {
        stateLock.lock()
        if leases[token.leaseID] == token {
            leases.removeValue(forKey: token.leaseID)
        }
        stateLock.unlock()
    }

    /// True while ANY unreleased lease names `runID` — across generations
    /// on purpose: an owner that has not completed is live even if its
    /// minting epoch was retired (retirement never force-frees operations).
    public func hasActiveLease(forRunID runID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return leases.values.contains { $0.runID == runID }
    }

    public var activeLeaseCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return leases.count
    }

    // MARK: - Durable cleanup surface (trusted owners only)

    public func pendingCleanupRequests() throws -> [RunOutputCleanupRequest] {
        guard let root = currentArtifactRoot() else {
            throw FloeError.validationFailed(
                "run-output cleanup requires the trusted runtime artifact-root binding")
        }
        return try RunOutputCleanupQueue.pending(storeRoot: root)
    }

    /// The bootstrap/readiness retry pass: reattempts exactly the persisted
    /// tombstones, verifying through the caller-supplied TRUSTED closures
    /// that the conversation is truly gone and that no live durable service
    /// (lease/token probe) still owns the outputs. There is no global scan
    /// and no orphan guessing. The binding is CAPTURED up front and the
    /// generation is rechecked at the result boundary: if the epoch was
    /// retired/rebound mid-pass the pass result is reported honestly as
    /// partially stale (retained requests will simply retry on the next
    /// readiness; nothing already removed is re-created).
    public func resumePendingCleanup(
        liveOwnership: (any RunOutputLiveOwnership)? = nil,
        operationGate: (any RunOutputOperationGate)? = nil,
        conversationExists: @escaping (UUID) async throws -> Bool
    ) async -> RunOutputCleanupRetryOutcome {
        let capturedBinding = capturedStoreBinding()
        guard let root = capturedBinding?.artifactRoot else {
            var outcome = RunOutputCleanupRetryOutcome()
            outcome.failureDescriptions = ["run-output cleanup store is not bound"]
            return outcome
        }
        var outcome = await RunOutputCleanupQueue.retryPersistedTombstones(
            storeRoot: root,
            artifactRoot: root,
            liveOwnership: liveOwnership,
            operationGate: operationGate,
            conversationExists: conversationExists
        )
        if currentBinding() != capturedBinding {
            outcome.failureDescriptions.append(
                "run-output cleanup generation changed during the pass; retained requests retry on the next readiness pass")
        }
        return outcome
    }

    // MARK: - Call-bound producer / verifier surface

    /// Publishes through the core store with the artifact root captured
    /// INSIDE the minted ticket — the binding and the lease are taken in
    /// ONE atomic capture (2026-10-27 lifetime review: there is no window
    /// in which bytes published to rootA could later be validated by an
    /// epochB ticket). The lease is held for the whole store call (cleanup
    /// claims refuse while it is live — no publication/cleanup race) and
    /// the generation is revalidated at the completion boundary:
    /// committed bytes survive, but a receipt whose generation was retired
    /// or rebound during publication is refused, never advertised. The
    /// store requires the real tool-call + task binding in `context` and
    /// refuses temporary runs (the runtime seal finalizes ownership
    /// afterwards — see `AgentRuntime.finalizeToolResult`). Without a
    /// trusted binding: typed failure, never an implicit `$HOME`/temporary
    /// store.
    public func publish(
        _ request: RunOutputSnapshotRequest,
        using context: ToolContext,
        caps: RunOutputCaps = .standard
    ) throws -> RunOutputFile {
        guard let ticket = beginPublication(runID: context.runID) else {
            throw RunOutputSnapshotError.bindingMissing(
                "run-output publication requires a current trusted generation binding"
            )
        }
        guard let root = ticket.artifactRoot else {
            endPublication(ticket)
            throw RunOutputSnapshotError.bindingMissing(
                "run-output publication requires the trusted runtime artifact-root binding"
            )
        }
        defer { endPublication(ticket) }
        let receipt = try RunOutputSnapshotStore.publish(
            request, using: context, caps: caps, artifactRoot: root
        )
        guard isPublicationCurrent(ticket) else {
            // Bytes already committed under the old generation: PRESERVED
            // (never rolled back here; cleanup of that run still rides the
            // durable tombstone path). Only the advertisement is refused.
            throw RunOutputSnapshotError.ioFailure(
                "run output publication completed under a retired generation; the snapshot is preserved but its receipt is not advertised"
            )
        }
        return receipt
    }

    /// Re-validates a sealed receipt's snapshot at retrieval against the
    /// bound store (canonical shape, identity re-derivation, lexical
    /// containment, plain single-link regular file, exact size + streamed
    /// SHA-256).
    public func verify(
        _ receipt: RunOutputFile,
        caps: RunOutputCaps = .standard
    ) -> RunOutputSnapshotVerification {
        guard let root = currentArtifactRoot() else {
            return .rejected(reason: "run-output store is not bound")
        }
        return RunOutputSnapshotStore.verify(receipt, caps: caps, artifactRoot: root)
    }

    /// The runtime's authoritative seal over tool-proposed receipts
    /// (identity re-derivation, no laundering, mixed-slot rejection,
    /// per-run caps). Exposed so trusted finalization owners — and later
    /// native producer services — use the SAME authority the AgentRuntime
    /// already applies, never a parallel implementation.
    public func seal(
        drafts: [RunOutputFile],
        runID: UUID,
        taskID: UUID?,
        environmentID: String?,
        callID: String,
        toolName: String,
        caps: RunOutputCaps = .standard
    ) -> RunOutputSnapshotStore.SealOutcome {
        RunOutputSnapshotStore.seal(
            drafts: drafts, runID: runID, taskID: taskID,
            environmentID: environmentID, callID: callID, toolName: toolName,
            caps: caps
        )
    }

    /// Resolves a VALIDATED read of one SEALED receipt for a trusted
    /// in-process consumer, capturing the generation up front and
    /// rechecking it at the result boundary.
    ///
    /// IMPORTANT (coordinator review 2026-10-27): this is a TRUSTED-receipt
    /// helper, NOT an authorization boundary for model-supplied receipt
    /// JSON. `taskID` equality alone cannot authorize a fabricated
    /// receipt (a model can copy the conversation id), because the sealed
    /// run/call identity is proven against the RUNTIME's own context by
    /// the seal, not here. The next App bridge MUST first retrieve the
    /// exact OWNED persisted receipt through the persisted-run reader
    /// (durable event projection is still a pending next-consumer seam)
    /// and only then call this helper with that persisted value; bytes
    /// here are re-verified against the receipt's own digest either way,
    /// so a wrong receipt resolves to `.changed`/`.missing`/`.rejected`,
    /// never to another task's file. Notes/Canvas live in different stores
    /// and are unreachable through this surface.
    public func verifiedRead(
        _ receipt: RunOutputFile,
        requestingConversationID: UUID
    ) -> RunOutputVerifiedRead {
        let captured = currentBinding()
        guard let captured else { return .unavailable }
        guard receipt.taskID == requestingConversationID else {
            return .notOwner
        }
        // Bytes are re-verified against the CAPTURED generation root —
        // never a freshly re-read one that a mid-call rebind could swap
        // under the verification. The result boundary then requires the
        // same generation to still be current before anything resolves.
        switch RunOutputSnapshotStore.verify(receipt, artifactRoot: captured.artifactRoot) {
        case .verified(let url):
            guard currentBinding() == captured else { return .unavailable }
            return .resolved(url: url)
        case .missing(let name): return .missing(displayName: name)
        case .changed(let name): return .changed(displayName: name)
        case .oversized(let name): return .oversized(displayName: name)
        case .rejected(let reason): return .rejected(reason: reason)
        }
    }
}

// MARK: - RunOutputOperationGate conformance (publication leases + cleanup claims)

/// The configured publication path (tool and direct producer) consults
/// this SAME instance's lease set: begin mints the ticket atomically from
/// the current binding (the captured root travels INSIDE the ticket — no
/// split capture can make rootA bytes validate under epochB),
/// `isPublicationCurrent` is false for a ticket whose generation was
/// retired or rebound, and cleanup claims refuse new publications over
/// the claimed runs for the claim's duration.
extension RuntimeFacadeRunOutput: RunOutputOperationGate {
    public func beginPublication(runID: UUID) -> RunOutputPublicationTicket? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let lease = acquireLeaseLocked(runID: runID, owner: "run-output.publication") else {
            return nil
        }
        return RunOutputPublicationTicket(
            leaseID: lease.leaseID, epoch: lease.epoch, runID: runID,
            artifactRoot: binding?.artifactRoot)
    }

    public func endPublication(_ ticket: RunOutputPublicationTicket) {
        stateLock.lock()
        if leases[ticket.leaseID]?.epoch == ticket.epoch,
           leases[ticket.leaseID]?.runID == ticket.runID {
            leases.removeValue(forKey: ticket.leaseID)
        }
        stateLock.unlock()
    }

    public func isPublicationCurrent(_ ticket: RunOutputPublicationTicket) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard binding?.epoch == ticket.epoch,
              binding?.artifactRoot == ticket.artifactRoot else { return false }
        return leases[ticket.leaseID] != nil
    }

    /// Takes the narrow cleanup claim over EXACTLY these runs: refuses
    /// (false) while any is already claimed or carries an unreleased
    /// lease; on success no new publication can begin for them until the
    /// matching `endCleanup`.
    public func beginCleanup(runIDs: [UUID]) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !runIDs.isEmpty else { return true }
        for runID in runIDs where cleaningRunIDs.contains(runID)
            || leases.values.contains(where: { $0.runID == runID }) {
            return false
        }
        for runID in runIDs { cleaningRunIDs.insert(runID) }
        return true
    }

    public func endCleanup(runIDs: [UUID]) {
        stateLock.lock()
        for runID in runIDs { cleaningRunIDs.remove(runID) }
        stateLock.unlock()
    }
}

// MARK: - Trusted live-ownership probes (cleanup consults these)

/// Lease-only probe: live while any unreleased lease names the run.
public struct RunOutputLeaseLiveOwnership: RunOutputLiveOwnership {
    private let facade: RuntimeFacadeRunOutput
    public init(facade: RuntimeFacadeRunOutput = .shared) {
        self.facade = facade
    }
    public func ownsRunOutput(runID: UUID) async throws -> Bool {
        facade.hasActiveLease(forRunID: runID)
    }
}

/// The composite the conversation-deletion path uses: the run's outputs
/// are live while a publication/consumer lease is active OR any of the
/// target conversation's EXACT RB1 owned-work tokens (the ones the
/// deletion's own quiescence report captured) is STILL attached at the
/// live recheck (`RuntimeOwnedWorkRegistry.shared.isAttached`, the same
/// authoritative registry the drain/fence loop already uses). The runs
/// table is NOT consulted: the cascade itself deletes those rows before
/// cleanup runs, so a post-cascade row probe can never see a surviving
/// owner (coordinator review 2026-10-27). Tokens/observations are the
/// deletion flow's trusted runtime evidence — never model payload.
public struct OwnedRunOutputWorkProbe: RunOutputLiveOwnership {
    private let facade: RuntimeFacadeRunOutput
    private let ownedTokens: [RuntimeOwnedWorkToken]
    public init(
        facade: RuntimeFacadeRunOutput = .shared,
        conversationID: UUID,
        observations: [ConversationOwnedWorkObservation]
    ) {
        self.facade = facade
        // Only THIS conversation's observations authorize retention; a
        // foreign conversationID in the report is ignored, never trusted.
        // The LIVE recheck below supersedes the observation's drain-time
        // `stillAttached` snapshot, so a token that attached (or had not
        // yet detached) after the drain is still seen as live.
        self.ownedTokens = observations.filter { $0.conversationID == conversationID }
            .map(\.token)
    }
    public init(
        facade: RuntimeFacadeRunOutput = .shared,
        ownedTokens: [RuntimeOwnedWorkToken]
    ) {
        self.facade = facade
        self.ownedTokens = ownedTokens
    }
    public func ownsRunOutput(runID: UUID) async throws -> Bool {
        if facade.hasActiveLease(forRunID: runID) { return true }
        // Any still-attached target token means real owned work for THIS
        // conversation has not finished; every one of its runs is then
        // conservatively retained until the token releases.
        return ownedTokens.contains { RuntimeOwnedWorkRegistry.shared.isAttached($0) }
    }
}
