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
/// coalesced per (environment, component identity); a caller's cancellation
/// fences only that caller's delivery — the shared service work it merely
/// awaited is never corrupted by one consumer's reference cancellation, and
/// `releaseEnvironment` is the only path that cancels + joins in-flight work.
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
    private struct PrepKey: Hashable {
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
    /// Per (environment, component identity) in-flight preparation. The
    /// internal token is cancelled ONLY by `releaseEnvironment`.
    private var preparations: [PrepKey: (task: Task<SkillRuntimeComponentReadiness?, Never>, token: CancellationToken)] = [:]
    /// Global content-keyed downloads. Service-owned lifetime: the entry's
    /// token is internal and is NEVER handed to any environment's preparation
    /// or cancelled by a consumer — one environment's cancellation/deletion
    /// must not abort a transfer another environment is awaiting. `Task` is a
    /// value type, so the slot is generation-guarded: an old completion can
    /// never clear a newly created slot for the same content key.
    private struct DownloadEntry {
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

        let receipt: SkillRuntimeComponentReadiness?
        let key = PrepKey(
            environmentID: environmentID,
            componentVersion: plan.descriptor.componentVersion,
            artifactSHA256: plan.descriptor.artifact.sha256
        )
        if let inflight = preparations[key] {
            // Coalesced caller: one consumer's reference cancellation never
            // corrupts the shared work; it fences only its own delivery.
            receipt = await inflight.task.value
        } else {
            let token = CancellationToken()
            let task = Task { await self.performReadiness(plan: plan, token: token) }
            preparations[key] = (task, token)
            receipt = await task.value
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

    /// Cancels + joins every in-flight preparation owned by this environment,
    /// then drops its plans, readiness receipts and state. Called by the
    /// container lifecycle BEFORE the environment (and its write layer)
    /// disappears. The global content-keyed download is deliberately left
    /// running: other consumers may be awaiting it, it is service-owned and
    /// bounded, and its result is a verified cache fact.
    func releaseEnvironment(_ environmentID: String) async {
        let owned = preparations.filter { $0.key.environmentID == environmentID }
        for (_, entry) in owned {
            entry.token.cancel()
            entry.task.cancel()
        }
        for (_, entry) in owned {
            _ = await entry.task.value
        }
        preparations = preparations.filter { $0.key.environmentID != environmentID }
        plans = plans.filter { $0.key.environmentID != environmentID }
        readiness = readiness.filter { $0.key.environmentID != environmentID }
        states = states.filter { $0.key.environmentID != environmentID }
    }

    /// Current diagnostic state for one (environment, component).
    func state(environmentID: String, componentID: String) -> SkillRuntimeComponentState {
        states[StateKey(environmentID: environmentID, componentID: componentID)]
            ?? SkillRuntimeComponentState(componentID: componentID)
    }

    // MARK: - Readiness pipeline

    private func performReadiness(
        plan: SkillRuntimeComponentPlan,
        token: CancellationToken
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
        guard await reauthorize() else {
            plans[PlanKey(environmentID: environmentID, runID: plan.runID)] = nil
            return deferral(SkillRuntimeComponentReason.authorityRevoked)
        }

        // 2. Stage into the resolved environment write layer.
        let staged: (url: URL, guestPath: String)
        do {
            staged = try await ensureStagedArtifact(
                plan: plan, layerURL: layerURL, pathMap: pathMap, token: token
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
        guard await reauthorize() else {
            plans[PlanKey(environmentID: environmentID, runID: plan.runID)] = nil
            return deferral(SkillRuntimeComponentReason.authorityRevoked)
        }

        // 3. Receipt reuse: same env, same component identity, same staged
        //    bytes (hash reverified during staging), bound to the CURRENT
        //    non-nil guest launch generation.
        let key = ReadinessKey(environmentID: environmentID, componentID: componentID)
        let generation = await launchGenerationProvider(environmentID)
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
                verb: "chmod", token: token
            )
            let probe = try await runProbeVerb(
                runner: runner, environmentID: environmentID,
                argv: [enginePath, "engine-probe"],
                timeout: Self.probeTimeout, maxOutputBytes: Self.smallOutputCap,
                verb: "engine-probe", token: token
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
                verb: "contract", token: token
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
        guard await reauthorize() else {
            plans[PlanKey(environmentID: environmentID, runID: plan.runID)] = nil
            return deferral(SkillRuntimeComponentReason.authorityRevoked)
        }
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
        token: CancellationToken
    ) async throws -> LinuxCommandResult {
        guard !Self.isFenced(token) else { throw CancellationError() }
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
            // delivery, never this shared transfer.
            let serviceToken = CancellationToken()
            let task = Task { try await self.downloadAndCommitToCache(
                plan: plan, cacheDirectory: cacheDirectory, cacheFile: cacheFile, token: serviceToken
            ) }
            entry = DownloadEntry(generation: UUID(), task: task, token: serviceToken)
            downloads[downloadKey] = entry
        }
        do {
            let url = try await entry.task.value
            if downloads[downloadKey]?.generation == entry.generation {
                downloads[downloadKey] = nil
            }
            return url
        } catch {
            if downloads[downloadKey]?.generation == entry.generation {
                downloads[downloadKey] = nil
            }
            throw error
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
        do {
            try writeVerified(bytes: bytes, to: temporary, token: token)
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
        token: CancellationToken
    ) async throws -> (url: URL, guestPath: String) {
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
        do {
            try copyVerified(from: cached, to: temporary, token: token)
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
            stagedRoot: URL(fileURLWithPath: hostRoot), bundle: bundle
        )
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

    private func writeVerified(bytes: Data, to url: URL, token: CancellationToken) throws {
        guard !Self.isFenced(token) else { throw CancellationError() }
        let handle = try FileHandle(forWritingTo: url)
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

    private func copyVerified(from source: URL, to destination: URL, token: CancellationToken) throws {
        guard !Self.isFenced(token) else { throw CancellationError() }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let output = try FileHandle(forWritingTo: destination)
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
