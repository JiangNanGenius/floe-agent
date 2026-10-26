// FloeApp — trusted lazy deployment of allowlisted runtime components.
//
// The app-side half of the frozen "runtime component" channel (today exactly
// the allowlisted `impeccable-engine` static RISC-V Linux binary). The chain
// has four strictly separated states, and none of them is implied by another:
//
//   source install — an installed + ENABLED official curated skill whose typed
//       receipt digest matches the row and the pinned snapshot. Revalidated
//       live on every use; nothing here trusts a serialized plan or marker.
//   cache — the artifact bytes fetched ONCE from the trusted Hub GitHub
//       repository at the SAME publication commit Y recorded in the receipt,
//       through the existing GitHub-only `skillRepositoryData` transport
//       (16 MiB cap for exactly this component, budget owned by
//       SkillHubTransportBudget). Verified exact integer size + SHA256 +
//       static-ELF gate, committed atomically into app-owned storage. GitHub
//       unavailable + verified cache => offline reuse; no website fallback
//       exists anywhere on this path.
//   staged — the verified bytes copied into the RESOLVED environment's write
//       layer (`registry.layerURL`, shared with the guest as /floe/env) under
//       a reserved `runtime-components` root, chunked, cancellation-fenced,
//       hash-verified, atomically renamed. A foreign/damaged/oversized entry
//       at the staged path is preserved exactly as found and fails closed.
//   probed — FIXED native-owned guest commands only (`chmod 0755`,
//       `engine-probe`, `contract`): exit 0, the exact handshake line, and the
//       contract bytes hashing to the descriptor's capture-contract sha256
//       with a natively supported version. No command text ever comes from
//       JSON. Download/staging is NOT readiness; a missing environment stays
//       deferred, never fake-ready.
//
// Authority flow: a verified exact `skill.read` of an installed official
// curated package that carries `references/engine-dependency.json` records an
// IMMUTABLE plan bound to (environmentID, runID) — the read itself stages
// nothing new, downloads nothing and executes nothing (the resource footer
// keeps its "Nothing was executed" line). At the approved `exec.shell`
// boundary, `RoutingLocalShellBackend` calls the injected preparation closure
// AFTER real guest activation and BEFORE the already-authorized command; on
// success the two verified guest paths are exported for THIS RUN ONLY
// (FLOE_IMPECCABLE_ENGINE / IMPECCABLE_SKILL_DIR), with the native binding
// winning over any caller-supplied value. No global environment mutation, no
// blanket allow, no model-forgeable grant, no recursive shell-tool dispatch.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Darwin
import FloeCore
import FloeExecution
import FloeSkills
import FloeTools

// MARK: - Authority (constructed only by SkillsCenter from verified facts)

/// Live authority facts for one component-bearing skill. Built ONLY by
/// `SkillsCenter` from the actual installed row + typed curated receipt +
/// digest-verified pinned snapshot. The center re-checks the formal shape on
/// its side and re-fetches this on every fresh use — a serialized copy of
/// this struct is never a ready token.
struct SkillRuntimeComponentAuthority: Sendable, Equatable {
    let skillID: String
    let entryVersion: String
    /// Canonical package digest; equals the row digest and the snapshot digest.
    let contentDigest: String
    let packageSHA256: String
    let catalogSHA256: String
    let reviewSHA256: String
    /// Audited source X — provenance only, never a retrieval pin.
    let auditedSourceCommit: String?
    /// Immutable publication Y — the ONLY retrieval pin.
    let publicationCommit: String
    let feedStatus: CuratedSkillFeedStatus
    let reviewDecision: CuratedSkillReviewDecision
    let feedSignatureKeyID: String
    let reviewKeyID: String
    let hubRepository: String
    /// Exact bytes of references/engine-dependency.json in the pinned snapshot.
    let descriptorBytes: Data
    let descriptorSHA256: String
    /// Pinned package manifest + bytes (used to re-verify the staged bundle
    /// byte-for-byte at use time through the existing stager verifier).
    let declaredFiles: [SkillFile]
    let packageFiles: [String: Data]
}

// MARK: - Environment facts

struct SkillRuntimeComponentEnvironment: Sendable, Equatable {
    let layerURL: URL?
    let isLinuxVM: Bool
    let isActive: Bool
}

// MARK: - Plan / readiness / state

/// Immutable plan recorded at a verified exact read; bound to one
/// (environmentID, runID). Replaced only by a newer verified read of the same
/// binding.
struct SkillRuntimeComponentPlan: Sendable {
    let skillID: String
    let environmentID: String
    let runID: UUID
    let workspaceRootURL: URL?
    /// Guest root of the staged pinned skill bundle (IMPECCABLE_SKILL_DIR).
    let stagedSkillGuestRoot: String
    let descriptor: SkillRuntimeDependencyDescriptor
    let descriptorSHA256: String
    let authority: SkillRuntimeComponentAuthority
    let recordedAt: Date
}

/// Probe receipt. Reusable only while the guest `launchGeneration` that
/// observed the probe is still current (the registry rotates it every boot),
/// the staged bytes still hash identically and the installed authorization
/// still revalidates — never by marker alone.
struct SkillRuntimeComponentReadiness: Sendable, Equatable {
    let environmentID: String
    let componentID: String
    let componentVersion: String
    let artifactSHA256: String
    let engineGuestPath: String
    let skillDirGuestPath: String
    let probeStdout: String
    let contractSHA256: String
    let launchGeneration: UInt64?
    let publicationCommit: String
    let catalogSHA256: String
    let verifiedAt: Date
}

/// Diagnostic state; the four phases stay distinct by design.
struct SkillRuntimeComponentState: Sendable, Equatable {
    var componentID: String?
    var componentVersion: String?
    var planRecorded = false
    var sourceAuthorized = false
    var cacheVerified = false
    var stagedVerified = false
    var probed = false
    var deferredReason: String?
}

enum SkillRuntimeComponentPlanOutcome: Sendable, Equatable {
    case recorded(environmentID: String, runID: UUID)
    case rejected(reason: String)
}

/// Stable, model-safe unavailable reasons. None carries a host path.
enum SkillRuntimeComponentReason {
    static let cancelled = "runtime component preparation was cancelled"
    static let noEnvironment = "no task Linux environment is bound to this run"
    static let noRun = "no run identity is bound to this read"
    static let notStaged = "the pinned skill bundle is not staged into the task workspace"
    static let transportUnavailable = "the trusted runtime-component transport is not configured"
    static let authorizationUnavailable = "the installed runtime-component authorization could not be revalidated"
    static let authorityRevoked = "the installed skill authorization no longer verifies for this component"
    static let descriptorRejected = "the packaged runtime-component descriptor failed strict validation"
    static let incompatibleAppVersion = "this app version is below the component's minimum app version"
    static let unsupportedContract = "the component's capture-contract version is not supported by this build"
    static let environmentUnavailable = "the resolved execution environment is unavailable"
    static let notLinuxEnvironment = "the resolved environment is not a local Linux guest environment"
    static let environmentDeleting = "the resolved environment is being deleted"
    static let noLayer = "the resolved environment has no write layer"
    static let noShareMap = "the resolved environment's host/guest share map is unavailable"
    static let layerMismatch = "the environment write layer does not match the guest's environment share"
    static let noWorkspaceShare = "the resolved environment exports no workspace share for the staged skill bundle"
    static let stagedBundleInvalid = "the staged skill bundle no longer matches the pinned snapshot bytes"
    static let cacheUnavailable = "durable runtime-component storage is unavailable"
    static let hubUnavailable = "the trusted Hub artifact could not be downloaded and no verified cache exists"
    static let artifactSizeMismatch = "the downloaded artifact size does not match the descriptor"
    static let artifactDigestMismatch = "the downloaded artifact bytes do not match the descriptor sha256"
    static let artifactRejected = "the downloaded artifact is not a static RISC-V Linux executable"
    static let existingRootConflict = "the reserved runtime-component root conflicts with existing entries"
    static let stagedPathBlocked = "an existing entry occupies the staged component path and does not match the pinned artifact"
    static let writeFailed = "staging the component into the environment write layer failed"
    static let probeUnavailable = "the Linux guest runner is unavailable for the component probe"
    static func probeFailed(_ verb: String, exitCode: Int32) -> String {
        "the fixed \(verb) command failed with exit code \(exitCode)"
    }
    static func probeError(_ verb: String) -> String {
        "the fixed \(verb) command could not run in the Linux guest"
    }
    static let probeStdoutMismatch = "the engine-probe output does not equal the exact expected handshake line"
    static let contractDigestMismatch = "the engine contract bytes do not match the descriptor capture-contract sha256"
    static let contractVersionUnsupported = "the engine contract version is not supported by the native producer"
}

// MARK: - Late bindings (phase-1-safe publication)

/// Lock-protected publication of the two seams that need the fully initialized
/// `AppEnvironment` (GitHub-only transport + skills-center authorization).
/// The center is created during `AppEnvironment.init` (the routing backend
/// closure needs it before phase-1 completes); these seams publish right
/// after, mirroring the `PinnedImageSource` reconnect pattern.
final class SkillRuntimeComponentLateBindings: @unchecked Sendable {
    typealias Transport = @Sendable (_ owner: String, _ repository: String, _ ref: String, _ path: String) async throws -> Data
    typealias Authorization = @Sendable (_ skillID: String) async -> SkillRuntimeComponentAuthority?

    private let lock = NSLock()
    private var transportBox: Transport?
    private var authorizationBox: Authorization?

    init(transport: Transport? = nil, authorization: Authorization? = nil) {
        transportBox = transport
        authorizationBox = authorization
    }

    func publish(transport: @escaping Transport, authorization: @escaping Authorization) {
        lock.lock()
        transportBox = transport
        authorizationBox = authorization
        lock.unlock()
    }

    var transport: Transport? { lock.lock(); defer { lock.unlock() }; return transportBox }
    var authorization: Authorization? { lock.lock(); defer { lock.unlock() }; return authorizationBox }
}

// MARK: - Center

/// Service-owned deployment of allowlisted runtime components. Downloads are
/// coalesced and owned here (never by a view); per-environment preparation is
/// coalesced per (environment, component identity) with explicit subscriber
/// accounting. Every wait on shared service work is cancellable from the
/// WAITER side only (both the waiting Swift task's cancellation and the
/// waiter's `CancellationToken`): a cancelled waiter returns promptly and
/// never receives bindings or a late ready, but it never cancels the shared
/// work it merely awaited. The shared preparation continues for the
/// remaining valid subscribers; when the LAST subscriber cancels, the owned
/// preparation is cancelled + joined before that caller returns, stopping
/// further environment staging and fixed probes. The global content-keyed
/// download outlives individual waiters and even `releaseEnvironment`: its
/// slot is removed only when the actual shared task settles, so remaining
/// and late consumers always coalesce instead of starting a duplicate
/// transfer.
///
/// Preparation correctness never depends on the waiter-side 10 ms watcher's
/// wake latency: every subscribed caller registers its SYNCHRONOUS
/// cancellation references (the caller `CancellationToken` plus a Swift
/// waiter-cancel mirror flipped inside the wait's own cancellation handler),
/// and the owned preparation re-reads ALL live references at each critical
/// phase boundary (start, post-download/pre-staging, staging entry, every
/// probe verb, receipt reuse, readiness publication) in the same
/// actor-synchronous region as that phase's first effect. A cancellation
/// published before a boundary read is necessarily observed at that
/// boundary: with zero live demand the phase fences to `cancelled()` before
/// any staging byte, probe verb or readiness fact, while any remaining valid
/// subscriber keeps the shared preparation running.
actor SkillRuntimeComponentCenter {
    typealias EnvironmentResolver = @Sendable (_ environmentID: String) async -> SkillRuntimeComponentEnvironment?
    typealias PathMapProvider = @Sendable (_ environmentID: String) async -> LinuxGuestPathMap?
    typealias LaunchGenerationProvider = @Sendable (_ environmentID: String) async -> UInt64?

    /// Reserved root inside the environment write layer.
    static let reservedLayerComponents = ["runtime-components"]
    static let stagingPrefix = ".staging-component-"
    static let downloadPrefix = ".download-component-"
    /// In-flight staging renames within seconds; an older UUID-proven
    /// temporary is provably abandoned.
    static let staleTemporaryAge: TimeInterval = 24 * 60 * 60
    static let copyChunkBytes = 256 * 1_024
    // Fixed, native-owned probe budgets (never JSON-configurable).
    static let chmodTimeout: TimeInterval = 30
    static let probeTimeout: TimeInterval = 60
    static let contractTimeout: TimeInterval = 120
    static let smallOutputCap = 4 * 1_024
    static let contractOutputCap = 256 * 1_024
    static let engineEnvironmentVariable = "FLOE_IMPECCABLE_ENGINE"
    static let skillDirEnvironmentVariable = "IMPECCABLE_SKILL_DIR"

    private struct PlanKey: Hashable { let environmentID: String; let runID: UUID }
    private struct PrepKey: Hashable, Sendable {
        let environmentID: String
        let componentVersion: String
        let artifactSHA256: String
    }
    private struct ReadinessKey: Hashable { let environmentID: String; let componentID: String }
    private struct StateKey: Hashable { let environmentID: String; let componentID: String }

    private let environmentResolver: EnvironmentResolver
    private let runner: (any LinuxCommandRunning)?
    private let cacheRoot: URL?
    private let pathMapping: PathMapProvider
    private let launchGenerationProvider: LaunchGenerationProvider
    private let appVersion: @Sendable () -> String
    let lateBindings: SkillRuntimeComponentLateBindings

    private var plans: [PlanKey: SkillRuntimeComponentPlan] = [:]
    private var states: [StateKey: SkillRuntimeComponentState] = [:]
    private var readiness: [ReadinessKey: SkillRuntimeComponentReadiness] = [:]
    /// Synchronous cancellation mirror for ONE waiting subscriber. The
    /// caller-side `cancellableWait` flips it inside its cancellation
    /// handlers the instant the waiter's Swift task is cancelled — before the
    /// waiter resumes. `CancellationToken.isCancelled` covers the token-only
    /// path with the same synchronous visibility; this mirror extends that to
    /// Swift-task cancellation, which offers no cross-task synchronous read.
    /// Preparation phase boundaries read both references, so a departing
    /// waiter is observed at the next boundary without depending on the
    /// caller-side watcher's wake latency.
    private final class WaiterCancelMirror: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    /// One subscribed caller's live cancellation references. `isCancelled` is
    /// a synchronous read; it becomes true the instant EITHER the caller's
    /// CancellationToken or the caller's Swift-waiter cancellation is
    /// published — never delayed by a poll.
    private struct SubscriberDemand: Sendable {
        let token: CancellationToken?
        let mirror: WaiterCancelMirror
        var isCancelled: Bool { token?.isCancelled == true || mirror.isCancelled }
    }

    /// Per (environment, component identity) in-flight preparation with live
    /// subscriber accounting. The internal token is cancelled ONLY by
    /// `releaseEnvironment` or by the last-subscriber rule in
    /// `prepareBindings`; the entry is generation-guarded, so a departed
    /// waiter can never retire or cancel a newer preparation for the same key.
    /// `subscribers` maps each subscription identity to that caller's
    /// synchronous cancellation references; the owned preparation fences its
    /// critical phases while no record stays live, and the last departing
    /// subscriber triggers the cancel + JOIN rule in `prepareBindings`.
    private struct PreparationEntry: Sendable {
        let generation: UUID
        let task: Task<SkillRuntimeComponentReadiness?, Never>
        let token: CancellationToken
        var subscribers: [UUID: SubscriberDemand]
    }
    private var preparations: [PrepKey: PreparationEntry] = [:]
    /// Global content-keyed downloads. Service-owned lifetime: the entry's
    /// token is internal and is NEVER handed to any environment's preparation
    /// or cancelled by a consumer — one environment's cancellation/deletion
    /// must not abort a transfer another environment is awaiting. `Task` is a
    /// value type, so the slot is generation-guarded: an old completion can
    /// never clear a newly created slot for the same content key. The slot is
    /// retired by the task itself when the ACTUAL shared work settles; a
    /// waiter that abandons its wait early can never remove it.
    private struct DownloadEntry: Sendable {
        let generation: UUID
        let task: Task<URL, Error>
        let token: CancellationToken
    }
    private var downloads: [String: DownloadEntry] = [:]

    init(
        environmentResolver: @escaping EnvironmentResolver,
        runner: (any LinuxCommandRunning)?,
        cacheRoot: URL?,
        pathMapping: @escaping PathMapProvider,
        launchGeneration: @escaping LaunchGenerationProvider,
        appVersion: @escaping @Sendable () -> String,
        bindings: SkillRuntimeComponentLateBindings = SkillRuntimeComponentLateBindings()
    ) {
        self.environmentResolver = environmentResolver
        self.runner = runner
        self.cacheRoot = cacheRoot
        self.pathMapping = pathMapping
        self.launchGenerationProvider = launchGeneration
        self.appVersion = appVersion
        self.lateBindings = bindings
    }

    /// Publishes the two `AppEnvironment`-dependent seams once phase-1 has
    /// completed. Callable from synchronous init contexts (nonisolated).
    nonisolated func setLateBindings(
        transport: @escaping SkillRuntimeComponentLateBindings.Transport,
        authorization: @escaping SkillRuntimeComponentLateBindings.Authorization
    ) {
        lateBindings.publish(transport: transport, authorization: authorization)
    }

    // MARK: - Plan recording (verified exact read; never executes)

    /// Record an immutable plan from a verified exact `skill.read`. Refusals
    /// are honest and never throw into the read path. This method downloads
    /// nothing, stages nothing and executes nothing.
    func recordPlan(
        skillID: String,
        environmentID: String?,
        workspaceRootURL: URL?,
        runID: UUID?,
        stagedGuestRoot: String?,
        authority: SkillRuntimeComponentAuthority?
    ) async -> SkillRuntimeComponentPlanOutcome {
        let trimmedEnvironmentID = environmentID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let environmentID = trimmedEnvironmentID, !environmentID.isEmpty else {
            return .rejected(reason: SkillRuntimeComponentReason.noEnvironment)
        }
        guard let runID else { return .rejected(reason: SkillRuntimeComponentReason.noRun) }
        guard let stagedGuestRoot = stagedGuestRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stagedGuestRoot.isEmpty else {
            return .rejected(reason: SkillRuntimeComponentReason.notStaged)
        }
        guard let authority else {
            return .rejected(reason: SkillRuntimeComponentReason.authorizationUnavailable)
        }
        guard authority.skillID == skillID else {
            return .rejected(reason: SkillRuntimeComponentReason.authorityRevoked)
        }

        // Decode + validate the descriptor HERE (center-side), not in the
        // caller: a descriptor byte string alone is never authority.
        let descriptor: SkillRuntimeDependencyDescriptor
        do {
            descriptor = try SkillRuntimeDependency.decode(authority.descriptorBytes)
        } catch {
            setState(environmentID, SkillRuntimeDependency.knownComponentID) {
                $0.deferredReason = SkillRuntimeComponentReason.descriptorRejected
            }
            return .rejected(reason: SkillRuntimeComponentReason.descriptorRejected)
        }
        let componentID = descriptor.componentID
        guard authority.descriptorSHA256 == FloeDigest.sha256Hex(authority.descriptorBytes) else {
            return .rejected(reason: SkillRuntimeComponentReason.authorityRevoked)
        }
        guard Self.isFormallyValid(authority) else {
            return .rejected(reason: SkillRuntimeComponentReason.authorityRevoked)
        }
        guard SkillRuntimeDependency.isCompatible(
            minimumAppVersion: descriptor.minimumAppVersion, appVersion: appVersion()
        ) else {
            setState(environmentID, componentID) {
                $0.componentID = componentID
                $0.componentVersion = descriptor.componentVersion
                $0.deferredReason = SkillRuntimeComponentReason.incompatibleAppVersion
            }
            return .rejected(reason: SkillRuntimeComponentReason.incompatibleAppVersion)
        }
        guard SkillRuntimeDependency.isCaptureContractVersionSupported(descriptor.captureContract.version) else {
            setState(environmentID, componentID) {
                $0.componentID = componentID
                $0.componentVersion = descriptor.componentVersion
                $0.deferredReason = SkillRuntimeComponentReason.unsupportedContract
            }
            return .rejected(reason: SkillRuntimeComponentReason.unsupportedContract)
        }

        let plan = SkillRuntimeComponentPlan(
            skillID: skillID,
            environmentID: environmentID,
            runID: runID,
            workspaceRootURL: workspaceRootURL,
            stagedSkillGuestRoot: stagedGuestRoot,
            descriptor: descriptor,
            descriptorSHA256: authority.descriptorSHA256,
            authority: authority,
            recordedAt: Date()
        )
        // The newest verified read for the same (environment, run) binding
        // replaces the previous plan wholesale — plans are immutable values.
        plans[PlanKey(environmentID: environmentID, runID: runID)] = plan
        setState(environmentID, componentID) {
            $0.componentID = componentID
            $0.componentVersion = descriptor.componentVersion
            $0.planRecorded = true
            $0.sourceAuthorized = true
            $0.deferredReason = nil
        }
        return .recorded(environmentID: environmentID, runID: runID)
    }

    // MARK: - exec.shell boundary hook

    /// Called by `RoutingLocalShellBackend` after real guest activation and
    /// before the already-authorized command. Returns the two verified guest
    /// path bindings for THIS RUN, or nil on any deferral (state records the
    /// honest reason; the shell command itself is never blocked by a
    /// component failure).
    func prepareBindings(
        environmentID: String,
        runID: UUID?,
        cancellation: CancellationToken?
    ) async -> [String: String]? {
        guard !Self.isFenced(cancellation) else { return nil }
        guard let runID, let plan = plans[PlanKey(environmentID: environmentID, runID: runID)] else {
            return nil
        }
        let componentID = plan.descriptor.componentID

        let key = PrepKey(
            environmentID: environmentID,
            componentVersion: plan.descriptor.componentVersion,
            artifactSHA256: plan.descriptor.artifact.sha256
        )
        // Subscribe to (or create) the shared per-environment preparation.
        // There is no suspension point between the plan lookup above and the
        // subscription below, so it is atomic with respect to
        // `releaseEnvironment` on this actor: a caller either subscribes
        // before the release fences the plans, or finds no plan afterwards.
        // Every subscriber registers its SYNCHRONOUS cancellation references
        // (caller token + Swift waiter-cancel mirror), which the owned
        // preparation re-reads at its critical phase boundaries — the demand
        // fence never waits for the caller-side 10 ms watcher.
        let subscriptionID = UUID()
        let waiterMirror = WaiterCancelMirror()
        let demand = SubscriberDemand(token: cancellation, mirror: waiterMirror)
        let entry: PreparationEntry
        if var existing = preparations[key] {
            // Coalesced caller: one consumer's cancellation never corrupts
            // the shared work; it fences only its own delivery, and only the
            // LAST departing subscriber also cancels + joins the owned
            // preparation (below).
            existing.subscribers[subscriptionID] = demand
            preparations[key] = existing
            entry = existing
        } else {
            let token = CancellationToken()
            let generation = UUID()
            let task = Task {
                await self.performReadiness(
                    plan: plan, token: token, prepKey: key, prepGeneration: generation
                )
            }
            entry = PreparationEntry(
                generation: generation, task: task, token: token,
                subscribers: [subscriptionID: demand]
            )
            preparations[key] = entry
        }

        // Waiter-side cancellable join of the shared preparation: this
        // caller's Swift task cancellation or CancellationToken returns
        // from the wait promptly WITHOUT cancelling the preparation itself.
        // `onWaiterCancel` flips this subscriber's mirror synchronously in
        // the wait's cancellation producers, so the preparation's next phase
        // boundary observes the departure even before this caller resumes.
        let receipt: SkillRuntimeComponentReadiness?
        let waiterCancelled: Bool
        do {
            receipt = try await Self.cancellableWait(
                token: cancellation,
                onWaiterCancel: { waiterMirror.cancel() }
            ) { await entry.task.value }
            waiterCancelled = false
        } catch {
            // The preparation task never fails; the only error source here
            // is this waiter's own cancellation.
            receipt = nil
            waiterCancelled = true
        }

        if waiterCancelled {
            var cancelOwnedPreparation = false
            if var current = preparations[key], current.generation == entry.generation {
                current.subscribers[subscriptionID] = nil
                if current.subscribers.isEmpty {
                    // Last subscriber cancelled: retire the entry, then
                    // cancel + JOIN the owned preparation BEFORE this caller
                    // returns, stopping any further environment staging or
                    // fixed probes. The join is prompt: every long wait
                    // inside the preparation is waiter-cancellable, every
                    // synchronous region fences the token, and every phase
                    // boundary re-reads live demand. The service-owned
                    // global download is NOT cancelled and its slot is NOT
                    // touched — remaining or late consumers of the same bytes
                    // coalesce on the running transfer.
                    preparations[key] = nil
                    cancelOwnedPreparation = true
                } else {
                    // Remaining valid subscribers keep the shared
                    // preparation alive; only THIS delivery is fenced.
                    preparations[key] = current
                }
            }
            if cancelOwnedPreparation {
                entry.token.cancel()
                entry.task.cancel()
                _ = await entry.task.value
            }
        } else if let current = preparations[key], current.generation == entry.generation {
            // The preparation settled for every subscriber: retire the slot
            // so the next use revalidates from scratch.
            preparations[key] = nil
        }

        guard let receipt else { return nil }
        guard !Self.isFenced(cancellation) else { return nil }

        // Plan-specific tail: the CURRENT installed authorization (full
        // revalidation, after the long shared awaits) and the staged skill
        // bundle's byte identity against the pinned snapshot.
        guard let authorization = await lateBindings.authorization?(plan.skillID),
              Self.matchesPlan(authorization, plan) else {
            plans[PlanKey(environmentID: environmentID, runID: plan.runID)] = nil
            setState(environmentID, componentID) {
                $0.deferredReason = SkillRuntimeComponentReason.authorityRevoked
                $0.sourceAuthorized = false
            }
            return nil
        }
        guard await verifyStagedSkillBundle(plan: plan, authorization: authorization) else {
            setState(environmentID, componentID) {
                $0.deferredReason = SkillRuntimeComponentReason.stagedBundleInvalid
            }
            return nil
        }
        guard !Self.isFenced(cancellation) else { return nil }
        setState(environmentID, componentID) { $0.deferredReason = nil }
        return [
            Self.engineEnvironmentVariable: receipt.engineGuestPath,
            Self.skillDirEnvironmentVariable: plan.stagedSkillGuestRoot
        ]
    }

    // MARK: - Environment deletion lifecycle

    /// Fences and removes everything this environment owns — plans,
    /// preparation subscriptions, readiness receipts and state — and
    /// cancels + JOINS its in-flight preparations BEFORE returning. Called
    /// by the container lifecycle BEFORE the environment (and its write
    /// layer) disappears. The join is prompt and never waits on the
    /// independent global download: a preparation's wait on the shared
    /// transfer is cancellable from the waiter side, so the cancelled
    /// preparation returns while the service-owned download keeps running
    /// for other environments — its slot is removed only when the actual
    /// shared task settles and its result is a verified cache fact.
    func releaseEnvironment(_ environmentID: String) async {
        // Fence first: with the plans gone, no NEW preparation can start for
        // this environment while the owned ones are cancelled + joined
        // (prepareBindings requires a recorded plan, and subscription is
        // atomic with the plan lookup on this actor).
        plans = plans.filter { $0.key.environmentID != environmentID }
        let owned = preparations.filter { $0.key.environmentID == environmentID }
        // Retire the owned entries (subscriptions die with them) BEFORE the
        // joins; already-waiting callers hold value copies of task +
        // generation, so their generation-guarded cleanups become no-ops.
        for (key, entry) in owned {
            if preparations[key]?.generation == entry.generation {
                preparations[key] = nil
            }
        }
        for (_, entry) in owned {
            entry.token.cancel()
            entry.task.cancel()
        }
        for (_, entry) in owned {
            // Prompt: the preparation's shared-download wait exits on its own
            // cancellation without touching the independent global transfer.
            _ = await entry.task.value
        }
        // Purge the observed facts only AFTER the joins, so no joined
        // preparation can write state for this environment post-purge.
        readiness = readiness.filter { $0.key.environmentID != environmentID }
        states = states.filter { $0.key.environmentID != environmentID }
    }

    /// Current diagnostic state for one (environment, component).
    func state(environmentID: String, componentID: String) -> SkillRuntimeComponentState {
        states[StateKey(environmentID: environmentID, componentID: componentID)]
            ?? SkillRuntimeComponentState(componentID: componentID)
    }

    // MARK: - Readiness pipeline

    /// Synchronous live-demand read for preparation phase boundaries. True
    /// only while THIS exact preparation generation is still registered and
    /// at least one subscriber's cancellation references (caller token or
    /// Swift waiter mirror) stay uncancelled. A retired generation has no
    /// demand by definition — both retirement paths (`releaseEnvironment`,
    /// last-subscriber rule) also cancel the preparation token, so this check
    /// and `isFenced(token)` fail together there. This read is the explicit
    /// cancellation/phase linearization: a caller cancellation published
    /// BEFORE a boundary read is NECESSARILY observed at that boundary — no
    /// sleep or watcher poll is in the causal chain — and the guarded phase
    /// (staging, one probe verb, a readiness publication) never starts for a
    /// fully departed demand. A cancellation racing an already-running
    /// bounded synchronous phase lets that phase finish (no hard-realtime
    /// promise between two instructions); the next boundary stops the
    /// sequence.
    private func hasLiveDemand(prepKey: PrepKey, generation: UUID) -> Bool {
        guard let entry = preparations[prepKey], entry.generation == generation else { return false }
        return entry.subscribers.contains { _, demand in !demand.isCancelled }
    }

    private func performReadiness(
        plan: SkillRuntimeComponentPlan,
        token: CancellationToken,
        prepKey: PrepKey,
        prepGeneration: UUID
    ) async -> SkillRuntimeComponentReadiness? {
        let environmentID = plan.environmentID
        let descriptor = plan.descriptor
        let componentID = descriptor.componentID

        func deferral(_ reason: String) -> SkillRuntimeComponentReadiness? {
            setState(environmentID, componentID) {
                $0.componentID = componentID
                $0.componentVersion = descriptor.componentVersion
                $0.deferredReason = reason
            }
            return nil
        }
        func cancelled() -> SkillRuntimeComponentReadiness? {
            setState(environmentID, componentID) {
                $0.componentID = componentID
                $0.componentVersion = descriptor.componentVersion
                $0.deferredReason = SkillRuntimeComponentReason.cancelled
            }
            return nil
        }
        func reauthorize() async -> Bool {
            guard let current = await lateBindings.authorization?(plan.skillID),
                  Self.matchesPlan(current, plan) else { return false }
            setState(environmentID, componentID) { $0.sourceAuthorized = true }
            return true
        }

        guard !Self.isFenced(token) else { return cancelled() }
        // Demand fence at preparation start: a caller that cancelled between
        // subscribing and this first boundary stops the pipeline before any
        // phase runs.
        guard hasLiveDemand(prepKey: prepKey, generation: prepGeneration) else { return cancelled() }
        guard await reauthorize() else {
            plans[PlanKey(environmentID: environmentID, runID: plan.runID)] = nil
            return deferral(SkillRuntimeComponentReason.authorityRevoked)
        }
        guard SkillRuntimeDependency.isCompatible(
            minimumAppVersion: descriptor.minimumAppVersion, appVersion: appVersion()
        ) else { return deferral(SkillRuntimeComponentReason.incompatibleAppVersion) }
        guard SkillRuntimeDependency.isCaptureContractVersionSupported(descriptor.captureContract.version)
        else { return deferral(SkillRuntimeComponentReason.unsupportedContract) }

        guard let environment = await environmentResolver(environmentID) else {
            return deferral(SkillRuntimeComponentReason.environmentUnavailable)
        }
        guard environment.isActive else { return deferral(SkillRuntimeComponentReason.environmentDeleting) }
        guard environment.isLinuxVM else { return deferral(SkillRuntimeComponentReason.notLinuxEnvironment) }
        guard let layerURL = environment.layerURL else { return deferral(SkillRuntimeComponentReason.noLayer) }
        guard let pathMap = await pathMapping(environmentID) else {
            return deferral(SkillRuntimeComponentReason.noShareMap)
        }
        // The environment write layer must be exactly what the guest mounts at
        // /floe/env; anything else means the resolved environment changed
        // under the plan.
        guard let exportedLayer = pathMap.hostPath(forGuestPath: LinuxGuestMountPoint.environment)?
            .resolvingSymlinksInPath().standardizedFileURL,
              exportedLayer == layerURL.resolvingSymlinksInPath().standardizedFileURL else {
            return deferral(SkillRuntimeComponentReason.layerMismatch)
        }

        // 1. Cache (long await): the ONLY fetch is the trusted Hub repository
        //    at Y through the GitHub-only transport.
        let cachedURL: URL
        do {
            cachedURL = try await ensureCachedArtifact(plan: plan, token: token)
        } catch let error as SkillRuntimeComponentFailure {
            return deferral(error.reason)
        } catch is CancellationError {
            return cancelled()
        } catch {
            return deferral(SkillRuntimeComponentReason.writeFailed)
        }
        setState(environmentID, componentID) { $0.cacheVerified = true }

        // Re-authorize after the long download await: a disable/uninstall
        // that landed mid-download must not issue a late ready.
        guard !Self.isFenced(token) else { return cancelled() }
        // Demand fence BEFORE any environment-visible phase: the shared
        // download is a service-global cache fact that completes for
        // remaining and late consumers, but staging/probes/publication may
        // only START for live demand. This read is synchronous with respect
        // to every subscriber's cancellation references, so a caller token
        // cancelled before the download settled is NECESSARILY observed
        // here — independently of the caller-side watcher's wake latency.
        guard hasLiveDemand(prepKey: prepKey, generation: prepGeneration) else { return cancelled() }
        guard await reauthorize() else {
            plans[PlanKey(environmentID: environmentID, runID: plan.runID)] = nil
            return deferral(SkillRuntimeComponentReason.authorityRevoked)
        }

        // 2. Stage into the resolved environment write layer.
        let staged: (url: URL, guestPath: String)
        do {
            staged = try await ensureStagedArtifact(
                plan: plan, layerURL: layerURL, pathMap: pathMap, token: token,
                prepKey: prepKey, prepGeneration: prepGeneration
            )
        } catch let error as SkillRuntimeComponentFailure {
            return deferral(error.reason)
        } catch is CancellationError {
            return cancelled()
        } catch {
            return deferral(SkillRuntimeComponentReason.writeFailed)
        }
        setState(environmentID, componentID) { $0.stagedVerified = true }

        // Re-authorize after staging, before the probe and before any ready
        // delivery.
        guard !Self.isFenced(token) else { return cancelled() }
        // Demand fence before the probe phase and before receipt reuse (a
        // readiness publication in its own right).
        guard hasLiveDemand(prepKey: prepKey, generation: prepGeneration) else { return cancelled() }
        guard await reauthorize() else {
            plans[PlanKey(environmentID: environmentID, runID: plan.runID)] = nil
            return deferral(SkillRuntimeComponentReason.authorityRevoked)
        }

        // 3. Receipt reuse: same env, same component identity, same staged
        //    bytes (hash reverified during staging), bound to the CURRENT
        //    non-nil guest launch generation.
        let key = ReadinessKey(environmentID: environmentID, componentID: componentID)
        let generation = await launchGenerationProvider(environmentID)
        // Demand fence in the SAME actor-synchronous region as the reuse
        // publication below (no suspension between this read and the `probed`
        // state write): receipt reuse publishes readiness.
        guard hasLiveDemand(prepKey: prepKey, generation: prepGeneration) else { return cancelled() }
        if let receipt = readiness[key],
           receipt.componentVersion == descriptor.componentVersion,
           receipt.artifactSHA256 == descriptor.artifact.sha256,
           let receiptGeneration = receipt.launchGeneration,
           let generation, receiptGeneration == generation {
            setState(environmentID, componentID) { $0.probed = true }
            return receipt
        }

        // 4. Fixed native probe verbs.
        guard let runner else { return deferral(SkillRuntimeComponentReason.probeUnavailable) }
        let enginePath = staged.guestPath
        do {
            try await runProbeVerb(
                runner: runner, environmentID: environmentID,
                argv: ["/bin/chmod", "0755", enginePath],
                timeout: Self.chmodTimeout, maxOutputBytes: Self.smallOutputCap,
                verb: "chmod", token: token,
                prepKey: prepKey, prepGeneration: prepGeneration
            )
            let probe = try await runProbeVerb(
                runner: runner, environmentID: environmentID,
                argv: [enginePath, "engine-probe"],
                timeout: Self.probeTimeout, maxOutputBytes: Self.smallOutputCap,
                verb: "engine-probe", token: token,
                prepKey: prepKey, prepGeneration: prepGeneration
            )
            let expected = SkillRuntimeDependency.expectedProbeStdout(
                componentVersion: descriptor.componentVersion
            )
            guard probe.stdout == expected else {
                return deferral(SkillRuntimeComponentReason.probeStdoutMismatch)
            }
            let contract = try await runProbeVerb(
                runner: runner, environmentID: environmentID,
                argv: [enginePath, "contract"],
                timeout: Self.contractTimeout, maxOutputBytes: Self.contractOutputCap,
                verb: "contract", token: token,
                prepKey: prepKey, prepGeneration: prepGeneration
            )
            let contractBytes = Data(contract.stdout.utf8)
            guard FloeDigest.sha256Hex(contractBytes) == descriptor.captureContract.sha256 else {
                return deferral(SkillRuntimeComponentReason.contractDigestMismatch)
            }
            guard Self.contractVersion(contractBytes) == descriptor.captureContract.version,
                  SkillRuntimeDependency.isCaptureContractVersionSupported(descriptor.captureContract.version) else {
                return deferral(SkillRuntimeComponentReason.contractVersionUnsupported)
            }
        } catch let failure as SkillRuntimeComponentFailure {
            return deferral(failure.reason)
        } catch is CancellationError {
            return cancelled()
        } catch {
            return deferral(SkillRuntimeComponentReason.probeError("probe"))
        }

        // Final fence + authorization before recording readiness facts.
        guard !Self.isFenced(token) else { return cancelled() }
        guard hasLiveDemand(prepKey: prepKey, generation: prepGeneration) else { return cancelled() }
        guard await reauthorize() else {
            plans[PlanKey(environmentID: environmentID, runID: plan.runID)] = nil
            return deferral(SkillRuntimeComponentReason.authorityRevoked)
        }
        // Demand fence in the SAME actor-synchronous region as the
        // publication below (no suspension between this read and the
        // readiness/state writes): a readiness receipt is never recorded for
        // a fully departed demand.
        guard hasLiveDemand(prepKey: prepKey, generation: prepGeneration) else { return cancelled() }
        let receipt = SkillRuntimeComponentReadiness(
            environmentID: environmentID,
            componentID: componentID,
            componentVersion: descriptor.componentVersion,
            artifactSHA256: descriptor.artifact.sha256,
            engineGuestPath: enginePath,
            skillDirGuestPath: plan.stagedSkillGuestRoot,
            probeStdout: SkillRuntimeDependency.expectedProbeStdout(componentVersion: descriptor.componentVersion),
            contractSHA256: descriptor.captureContract.sha256,
            launchGeneration: generation,
            publicationCommit: plan.authority.publicationCommit,
            catalogSHA256: plan.authority.catalogSHA256,
            verifiedAt: Date()
        )
        readiness[key] = receipt
        setState(environmentID, componentID) {
            $0.probed = true
            $0.deferredReason = nil
        }
        return receipt
    }

    private func runProbeVerb(
        runner: any LinuxCommandRunning,
        environmentID: String,
        argv: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int,
        verb: String,
        token: CancellationToken,
        prepKey: PrepKey,
        prepGeneration: UUID
    ) async throws -> LinuxCommandResult {
        guard !Self.isFenced(token) else { throw CancellationError() }
        // Demand fence BEFORE each fixed verb is dispatched into the guest:
        // no verb starts for a fully departed demand. A cancellation landing
        // while an already-dispatched verb runs cannot un-run it — that
        // bounded phase completes; the post-run token fence, the next verb's
        // boundary and the fenced publication stop the sequence.
        guard hasLiveDemand(prepKey: prepKey, generation: prepGeneration) else { throw CancellationError() }
        let result: LinuxCommandResult
        do {
            result = try await runner.run(
                environmentID: environmentID,
                argv: argv,
                workingDirectory: nil,
                standardInput: nil,
                timeout: timeout,
                maxOutputBytes: maxOutputBytes,
                cancellation: token
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.probeError(verb))
        }
        guard !Self.isFenced(token) else { throw CancellationError() }
        guard result.exitCode == 0 else {
            throw SkillRuntimeComponentFailure(
                reason: SkillRuntimeComponentReason.probeFailed(verb, exitCode: result.exitCode)
            )
        }
        return result
    }

    // MARK: - Cache

    private struct SkillRuntimeComponentFailure: Error {
        let reason: String
    }

    private func cacheFileURL(for descriptor: SkillRuntimeDependencyDescriptor) -> URL? {
        guard let cacheRoot else { return nil }
        return cacheRoot
            .appendingPathComponent(descriptor.componentID, isDirectory: true)
            .appendingPathComponent(descriptor.componentVersion, isDirectory: true)
            .appendingPathComponent(descriptor.target.triple, isDirectory: true)
            .appendingPathComponent(SkillRuntimeDependency.frozenEngineFileName, isDirectory: false)
    }

    /// Coalesced, service-owned download into the app-owned cache namespace.
    /// Existing verified bytes are reused (hash reverified every time, so a
    /// marker is never trusted); damaged cache bytes inside OUR namespace are
    /// replaced by a fresh verified download; foreign bytes in the environment
    /// staging area are always preserved (see ensureStagedArtifact).
    private func ensureCachedArtifact(
        plan: SkillRuntimeComponentPlan,
        token: CancellationToken
    ) async throws -> URL {
        let descriptor = plan.descriptor
        guard let cacheFile = cacheFileURL(for: descriptor) else {
            throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.cacheUnavailable)
        }
        let cacheDirectory = cacheFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: cacheFile.path) {
            if try verified(file: cacheFile, size: descriptor.artifact.size, sha256: descriptor.artifact.sha256, token: token) {
                return cacheFile
            }
            // App-owned cache namespace: damaged/planted bytes are replaced,
            // never preserved (unlike the guest-visible staging area).
            try? FileManager.default.removeItem(at: cacheFile)
        }

        let downloadKey = "\(descriptor.componentID)\n\(descriptor.componentVersion)\n\(descriptor.artifact.sha256)"
        let entry: DownloadEntry
        if let existing = downloads[downloadKey] {
            entry = existing
        } else {
            // Service-owned token: the shared download is not bound to the
            // first caller's preparation token; `releaseEnvironment` and
            // per-caller cancellation fence only their own preparation and
            // delivery, never this shared transfer. The slot is retired by
            // the task itself when the ACTUAL shared work settles
            // (generation-guarded): a waiter that abandons its wait early
            // never removes it, so remaining and late consumers coalesce on
            // the running transfer instead of starting a duplicate.
            let serviceToken = CancellationToken()
            let generation = UUID()
            let task = Task { () -> URL in
                defer {
                    if self.downloads[downloadKey]?.generation == generation {
                        self.downloads[downloadKey] = nil
                    }
                }
                return try await self.downloadAndCommitToCache(
                    plan: plan, cacheDirectory: cacheDirectory, cacheFile: cacheFile, token: serviceToken
                )
            }
            entry = DownloadEntry(generation: generation, task: task, token: serviceToken)
            downloads[downloadKey] = entry
        }
        // Waiter-side cancellable wait: this preparation's own Swift task
        // cancellation or token returns from the wait promptly — this is
        // what makes `releaseEnvironment`'s cancel + JOIN prompt — WITHOUT
        // cancelling the service-owned transfer.
        do {
            return try await Self.cancellableWait(token: token) { try await entry.task.value }
        } catch is WaiterCancelledError {
            // This waiter's wait ended early; the shared transfer is still
            // in flight (or settles alone and retires its own slot). The
            // slot deliberately stays exactly as it is.
            throw CancellationError()
        }
    }

    private func downloadAndCommitToCache(
        plan: SkillRuntimeComponentPlan,
        cacheDirectory: URL,
        cacheFile: URL,
        token: CancellationToken
    ) async throws -> URL {
        let descriptor = plan.descriptor
        guard !Self.isFenced(token) else { throw CancellationError() }
        // Y must be an immutable 40-hex commit BEFORE any network use.
        guard Self.isCanonicalHexSHA1(plan.authority.publicationCommit) else {
            throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.authorityRevoked)
        }
        guard let transport = lateBindings.transport else {
            throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.transportUnavailable)
        }
        let bytes: Data
        do {
            bytes = try await transport(
                CuratedSkillHub.owner, CuratedSkillHub.repository,
                plan.authority.publicationCommit, descriptor.artifact.path
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // GitHub-only transport; there is deliberately no fallback source.
            throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.hubUnavailable)
        }
        guard !Self.isFenced(token) else { throw CancellationError() }
        // Exact integer size + sha256 + static ELF gate, in that order.
        guard bytes.count == descriptor.artifact.size else {
            throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.artifactSizeMismatch)
        }
        guard bytes.count <= SkillRuntimeDependency.maximumArtifactBytes,
              FloeDigest.sha256Hex(bytes) == descriptor.artifact.sha256 else {
            throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.artifactDigestMismatch)
        }
        do {
            try SkillRuntimeDependency.verifyStaticRISCVExecELF(bytes)
        } catch {
            throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.artifactRejected)
        }

        // Atomic commit: temp file -> same-volume rename; a concurrent winner
        // is adopted only on full verification.
        let temporary = cacheDirectory.appendingPathComponent(
            Self.downloadPrefix + UUID().uuidString, isDirectory: false
        )
        let output = try Self.createExclusiveTemporaryFile(at: temporary)
        defer { try? output.close() }
        do {
            try writeVerified(bytes: bytes, to: output, token: token)
            if FileManager.default.fileExists(atPath: cacheFile.path) {
                if try verified(file: cacheFile, size: descriptor.artifact.size,
                                sha256: descriptor.artifact.sha256, token: token) {
                    try? FileManager.default.removeItem(at: temporary)
                } else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.writeFailed)
                }
            } else {
                try FileManager.default.moveItem(at: temporary, to: cacheFile)
            }
        } catch let failure as SkillRuntimeComponentFailure {
            try? FileManager.default.removeItem(at: temporary)
            throw failure
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: temporary)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.writeFailed)
        }

        // Advisory provenance sidecar (never a trust source; bytes are
        // reverified on every use).
        let provenance: [String: Any] = [
            "componentID": descriptor.componentID,
            "componentVersion": descriptor.componentVersion,
            "artifactSHA256": descriptor.artifact.sha256,
            "artifactSize": descriptor.artifact.size,
            "publicationCommit": plan.authority.publicationCommit,
            "auditedSourceCommit": plan.authority.auditedSourceCommit ?? NSNull(),
            "catalogSHA256": plan.authority.catalogSHA256,
            "fetchedAt": String(Int(Date().timeIntervalSince1970))
        ]
        if let data = try? JSONSerialization.data(withJSONObject: provenance, options: [.sortedKeys]) {
            try? data.write(to: cacheDirectory.appendingPathComponent("provenance.json"), options: .atomic)
        }
        Self.pruneStaleComponentTemps(in: cacheDirectory)
        return cacheFile
    }

    // MARK: - Environment staging

    /// Reserved-root walk mirroring the workspace stager: every component
    /// must be a real non-symlink directory; anything else is preserved as
    /// found and fails closed.
    private static func preparedLayerRoot(under layerURL: URL) -> URL? {
        var current = layerURL
        for component in reservedLayerComponents {
            current = current.appendingPathComponent(component, isDirectory: true)
            if !FileManager.default.fileExists(atPath: current.path) {
                try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  SkillWorkspaceResourceStager.isSymbolicLink(current) == false else { return nil }
        }
        return current
    }

    private func ensureStagedArtifact(
        plan: SkillRuntimeComponentPlan,
        layerURL: URL,
        pathMap: LinuxGuestPathMap,
        token: CancellationToken,
        prepKey: PrepKey,
        prepGeneration: UUID
    ) async throws -> (url: URL, guestPath: String) {
        // Token + demand fences as the FIRST synchronous statements: this
        // body has no suspension points, so the checks and every filesystem
        // effect below run as ONE actor region — the staging phase's
        // linearization point. No staging byte moves and no directory is
        // created for a cancelled preparation or a fully departed demand.
        guard !Self.isFenced(token) else { throw CancellationError() }
        guard hasLiveDemand(prepKey: prepKey, generation: prepGeneration) else { throw CancellationError() }
        let descriptor = plan.descriptor
        guard let reservedRoot = Self.preparedLayerRoot(under: layerURL) else {
            throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.existingRootConflict)
        }
        let directory = reservedRoot
            .appendingPathComponent(descriptor.componentID, isDirectory: true)
            .appendingPathComponent(descriptor.componentVersion, isDirectory: true)
            .appendingPathComponent(descriptor.target.triple, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Re-walk: intermediate directories must not be symlinks either.
        var cursor = reservedRoot
        for component in [descriptor.componentID, descriptor.componentVersion, descriptor.target.triple] {
            cursor = cursor.appendingPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cursor.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  SkillWorkspaceResourceStager.isSymbolicLink(cursor) == false else {
                throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.existingRootConflict)
            }
        }
        guard let cached = cacheFileURL(for: descriptor),
              FileManager.default.fileExists(atPath: cached.path) else {
            throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.cacheUnavailable)
        }

        let target = directory.appendingPathComponent(SkillRuntimeDependency.frozenEngineFileName, isDirectory: false)
        guard let guestPath = pathMap.guestPath(forHostPath: target.path),
              guestPath.hasPrefix(LinuxGuestMountPoint.environment + "/"),
              !guestPath.split(separator: "/").contains("..") else {
            throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.noShareMap)
        }

        if FileManager.default.fileExists(atPath: target.path) {
            // Reuse is granted ONLY by full byte verification; a foreign,
            // damaged or oversized entry stays exactly as found.
            if try verified(file: target, size: descriptor.artifact.size,
                            sha256: descriptor.artifact.sha256, token: token) {
                Self.pruneStaleComponentTemps(in: directory)
                return (target, guestPath)
            }
            throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.stagedPathBlocked)
        }

        // Chunked, cancellation-fenced copy from the verified cache file,
        // then full verification BEFORE the atomic rename.
        let temporary = directory.appendingPathComponent(
            Self.stagingPrefix + UUID().uuidString, isDirectory: false
        )
        let output = try Self.createExclusiveTemporaryFile(at: temporary)
        defer { try? output.close() }
        do {
            try copyVerified(from: cached, to: output, token: token)
            guard try verified(file: temporary, size: descriptor.artifact.size,
                               sha256: descriptor.artifact.sha256, token: token) else {
                throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.artifactDigestMismatch)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            guard !Self.isFenced(token) else { throw CancellationError() }
            if FileManager.default.fileExists(atPath: target.path) {
                // A concurrent publisher committed meanwhile: adopt only a
                // fully verifying tree, never overwrite.
                if try verified(file: target, size: descriptor.artifact.size,
                                sha256: descriptor.artifact.sha256, token: token) {
                    try? FileManager.default.removeItem(at: temporary)
                } else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.stagedPathBlocked)
                }
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        } catch let failure as SkillRuntimeComponentFailure {
            try? FileManager.default.removeItem(at: temporary)
            throw failure
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: temporary)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if FileManager.default.fileExists(atPath: target.path),
               try verified(file: target, size: descriptor.artifact.size,
                            sha256: descriptor.artifact.sha256, token: token) {
                // A concurrent publisher won; the verified tree stands.
            } else {
                throw SkillRuntimeComponentFailure(reason: SkillRuntimeComponentReason.writeFailed)
            }
        }
        Self.pruneStaleComponentTemps(in: directory)
        return (target, guestPath)
    }

    // MARK: - Staged skill bundle re-verification (existing stager gate)

    private func verifyStagedSkillBundle(
        plan: SkillRuntimeComponentPlan,
        authorization: SkillRuntimeComponentAuthority
    ) async -> Bool {
        guard let pathMap = await pathMapping(plan.environmentID),
              let hostRoot = pathMap.hostPath(forGuestPath: plan.stagedSkillGuestRoot) else { return false }
        guard let bundle = SkillWorkspaceResourceStager.stagingBundle(
            manifestID: plan.skillID,
            digest: authorization.contentDigest,
            declaredFiles: authorization.declaredFiles,
            bytes: authorization.packageFiles,
            limits: SkillValidationLimits()
        ) else { return false }
        return SkillWorkspaceResourceStager.verify(
            stagedRoot: hostRoot, bundle: bundle
        )
    }

    // MARK: - Cancellable waits on service-owned work

    /// Waiter-side early exit from `cancellableWait`. Distinct from the
    /// watched task's OWN settled errors so a caller can tell "the shared
    /// task finished with this result" from "my wait ended early; the shared
    /// task is still running and its slot must stay untouched".
    private struct WaiterCancelledError: Error, Sendable {}

    /// Lock-protected one-shot continuation box: exactly one resume, by
    /// whichever producer arrives first (watched-task completion, Swift task
    /// cancellation, token watcher). Mirrors the single-resume discipline of
    /// `WhisperModelStore`'s pending transfers.
    private final class WaitOnceBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var pending: Result<T, Error>?
        private var fulfilled = false

        /// True once any producer has produced the result, even before the
        /// continuation is installed.
        var isFulfilled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return fulfilled
        }

        /// Producer side. Only the FIRST producer resumes the continuation;
        /// later producers are no-ops. A result that arrives before the
        /// continuation is installed is stored for `install` to resume once.
        func fulfill(with result: Result<T, Error>) {
            lock.lock()
            guard !fulfilled else {
                lock.unlock()
                return
            }
            fulfilled = true
            let waiting = continuation
            continuation = nil
            if waiting == nil { pending = result }
            lock.unlock()
            waiting?.resume(with: result)
        }

        /// Consumer side; called exactly once from the continuation body. A
        /// producer that already fired (for example the cancellation handler
        /// ran before installation) resumes immediately with its stored
        /// result — no lost cancellation.
        func install(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                continuation.resume(with: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    /// Cancellation poll interval of the bounded token watcher; polled ONLY
    /// while a wait is active (the watcher exits as soon as the wait settles
    /// or the token fires — never an idle permanent poll).
    static let cancellationPollNanoseconds: UInt64 = 10_000_000 // 10 ms

    /// Awaits `operation` (typically the value of a service-owned
    /// unstructured task) while remaining cancellable FROM THE WAITER SIDE:
    /// throws `WaiterCancelledError` early when the waiting Swift task is
    /// cancelled or when `token` is cancelled. It NEVER cancels the watched
    /// work itself — the shared download/preparation may legitimately
    /// outlive this waiter and keep serving other consumers.
    /// `CancellationToken` has no callback API, so the token side uses a
    /// bounded watcher whose lifetime equals this active wait. Swift 6:
    /// one-shot box, exactly one continuation resume, detached watchers
    /// capture only Sendable values.
    /// `onWaiterCancel` (when provided) runs synchronously in EVERY
    /// waiter-side cancellation producer — the Swift-task `onCancel` handler
    /// and the token watcher — BEFORE the box is fulfilled, so the caller can
    /// publish a synchronous departure mirror that service-side phase
    /// boundaries read without waiting on this wait's wake latency. It is
    /// never invoked when the watched operation itself settles the wait.
    private static func cancellableWait<T: Sendable>(
        token: CancellationToken?,
        onWaiterCancel: (@Sendable () -> Void)? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = WaitOnceBox<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                box.install(continuation)
                // A producer that already fired (for example the waiting task
                // was cancelled before this wait began) resumed the
                // continuation inside `install`; no watcher is needed then.
                guard !box.isFulfilled else { return }
                Task.detached {
                    do {
                        box.fulfill(with: .success(try await operation()))
                    } catch {
                        box.fulfill(with: .failure(error))
                    }
                }
                if let token {
                    Task.detached {
                        // Bounded monitor: exists only while the wait is
                        // active; exits on token fire, on settlement, or
                        // when its own sleep is interrupted.
                        while !token.isCancelled {
                            if box.isFulfilled { return }
                            do {
                                try await Task.sleep(nanoseconds: cancellationPollNanoseconds)
                            } catch {
                                return
                            }
                        }
                        // Departure mirror first, box second: the flip is
                        // visible to service-side demand reads before this
                        // waiter's resume is even enqueued.
                        onWaiterCancel?()
                        box.fulfill(with: .failure(WaiterCancelledError()))
                    }
                }
            }
        } onCancel: {
            onWaiterCancel?()
            box.fulfill(with: .failure(WaiterCancelledError()))
        }
    }

    // MARK: - File helpers

    /// Static: `verified`'s synchronous hash closure is nonisolated, so it
    /// cannot call actor-isolated helpers. `Task.isCancelled` inside a sync
    /// closure reads the enclosing task's cancellation, which is exactly the
    /// preparation task this code runs on.
    private static func isFenced(_ token: CancellationToken?) -> Bool {
        token?.isCancelled == true || Task.isCancelled
    }

    private func verified(
        file url: URL,
        size: Int,
        sha256: String,
        token: CancellationToken
    ) throws -> Bool {
        guard !Self.isFenced(token) else { throw CancellationError() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              SkillWorkspaceResourceStager.isSymbolicLink(url) == false else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let actualSize = attributes?[.size] as? Int, actualSize == size else { return false }
        let actualSHA = try FloeDigest.sha256Hex(
            ofFileAt: url,
            isCancelled: { Self.isFenced(token) }
        )
        return actualSHA == sha256
    }

    /// Claim the new temporary atomically before any cleanup scope owns it.
    /// FileHandle(forWritingTo:) opens an existing file; it never creates one.
    /// Exclusive, no-follow creation also preserves a conflicting entry.
    private static func createExclusiveTemporaryFile(at url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func writeVerified(bytes: Data, to handle: FileHandle, token: CancellationToken) throws {
        guard !Self.isFenced(token) else { throw CancellationError() }
        do {
            var offset = 0
            while offset < bytes.count {
                if Self.isFenced(token) { throw CancellationError() }
                let end = min(offset + Self.copyChunkBytes, bytes.count)
                try handle.write(contentsOf: bytes.subdata(in: offset..<end))
                offset = end
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func copyVerified(from source: URL, to output: FileHandle, token: CancellationToken) throws {
        guard !Self.isFenced(token) else { throw CancellationError() }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        do {
            while true {
                if Self.isFenced(token) { throw CancellationError() }
                guard let chunk = try handle.read(upToCount: Self.copyChunkBytes), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
            }
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
    }

    /// Removes ONLY this helper's abandoned temporaries: exact prefix +
    /// canonical-UUID round-trip + plain regular file + older than the stale
    /// bound. Content entries are never touched.
    static func pruneStaleComponentTemps(in directory: URL, now: Date = Date()) {
        let prefixes = [stagingPrefix, downloadPrefix]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: []
        ) else { return }
        for url in entries {
            let name = url.lastPathComponent
            // Use the ACTUAL matched prefix: staging and download prefixes
            // differ in length, so a fixed offset would never match one of them.
            guard let matched = prefixes.first(where: { name.hasPrefix($0) }) else { continue }
            let suffix = String(name.dropFirst(matched.count))
            guard let uuid = UUID(uuidString: suffix), uuid.uuidString == suffix else { continue }
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey
            ])
            guard values?.isSymbolicLink != true,
                  values?.isRegularFile == true,
                  let modified = values?.contentModificationDate,
                  now.timeIntervalSince(modified) > staleTemporaryAge else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Contract / authority shape checks

    private static func contractVersion(_ bytes: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              (object["contract"] as? String) == SkillRuntimeDependency.captureContractName,
              let number = object["contractVersion"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    /// Formal validity of authority facts: production trust + approve review
    /// + fixed repository + immutable 40-hex Y + canonical digests. Checked
    /// at plan recording and on every live revalidation.
    static func isFormallyValid(_ authority: SkillRuntimeComponentAuthority) -> Bool {
        guard authority.feedStatus == .production,
              authority.reviewDecision == .approve,
              authority.feedSignatureKeyID == CuratedSkillHub.productionKeyID,
              authority.reviewKeyID == CuratedSkillHub.productionKeyID,
              authority.hubRepository == CuratedSkillHub.hubRepository,
              isCanonicalHexSHA1(authority.publicationCommit),
              SkillRuntimeDependency.isCanonicalLowercaseHexSHA256(authority.contentDigest),
              SkillRuntimeDependency.isCanonicalLowercaseHexSHA256(authority.packageSHA256),
              SkillRuntimeDependency.isCanonicalLowercaseHexSHA256(authority.catalogSHA256),
              SkillRuntimeDependency.isCanonicalLowercaseHexSHA256(authority.reviewSHA256),
              SkillRuntimeDependency.isCanonicalLowercaseHexSHA256(authority.descriptorSHA256) else { return false }
        return true
    }

    static func matchesPlan(
        _ authority: SkillRuntimeComponentAuthority,
        _ plan: SkillRuntimeComponentPlan
    ) -> Bool {
        guard isFormallyValid(authority),
              authority.skillID == plan.skillID,
              authority.contentDigest == plan.authority.contentDigest,
              authority.descriptorSHA256 == plan.descriptorSHA256,
              authority.publicationCommit == plan.authority.publicationCommit,
              authority.catalogSHA256 == plan.authority.catalogSHA256,
              authority.packageSHA256 == plan.authority.packageSHA256,
              authority.reviewSHA256 == plan.authority.reviewSHA256 else { return false }
        return true
    }

    static func isCanonicalHexSHA1(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }

    private func setState(
        _ environmentID: String,
        _ componentID: String,
        mutate: (inout SkillRuntimeComponentState) -> Void
    ) {
        let key = StateKey(environmentID: environmentID, componentID: componentID)
        var state = states[key] ?? SkillRuntimeComponentState()
        mutate(&state)
        states[key] = state
    }
}
#endif
