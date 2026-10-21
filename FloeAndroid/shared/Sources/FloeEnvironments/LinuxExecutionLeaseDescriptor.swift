import Foundation
import FloeCore
import FloeTools

// G03-R1 Android-owned narrow lease descriptor (job-d15dbb99ae374286).
//
// This file is NOT a port of another iOS source and NOT a second registry:
// it is the Swift-side owned routing input that hands ONE resolved Linux
// execution lease to the backend launch transport (owned by the
// FloeAndroid/core/linuxruntime lane, job-32b3d5dded1d4e70). Every value in
// the descriptor comes from a live ToolEnvironmentLease obtained through the
// ORIGINAL EnvironmentExecutionCoordinator against the existing
// EnvironmentRegistry — the descriptor never creates records, never selects
// a backend itself, and never invents roots or identities.
//
// Lease ownership discipline (Main review 2026-10-22):
// - `acquireHolder` is the ONLY launchable path: it returns a holder that
//   owns the coordinator lease until the owned process quiesces.
// - `resolveMetadata` is metadata-only: it hands the lease back BEFORE
//   returning and its descriptor must NEVER be used as launch authority.
// - Exactly one code path is responsible for finishing any acquired lease:
//   the entry point that acquired it (holder on release, entry point on
//   failure). No nested helper ever finishes a lease.
//
// Truthful scope (per Local/Private/android-g03-20261022/r1/
// ARCHITECTURE_DECISIONS.json):
// - The ordered layer stack is LOOKUP ORDER for the future merged rootfs
//   view; it is not a kernel overlayfs, not a process sandbox, and the
//   merged apt rootfs is not implemented yet (mount mechanics belong to the
//   backend lane).
// - `linuxPRoot` is a compatibility candidate, NOT a security boundary;
//   same-UID PRoot is not an app sandbox. No isolation is claimed here.
// - Cancellation is not termination: the environment lease is retained
//   until the owned process actually quiesces.

/// One validated resolved Linux execution lease. Immutable snapshot built
/// only by `LinuxExecutionLeaseResolver`; carries the identities the backend
/// launch transport needs to route and account one owned process. A bare
/// descriptor is data, NOT launch authority: only
/// `LinuxExecutionLeaseHolder` (from `acquireHolder`) may authorize a
/// backend process launch.
public struct LinuxExecutionLeaseDescriptor: Sendable, Equatable {
    /// Container record the lease resolved to (FloeEnvironments authority id).
    public var environmentID: String
    /// Task run identity from the original ToolContext; survives unchanged.
    public var runID: UUID
    /// Owning conversation for session environments; nil only for
    /// project-scoped execution without a conversation. A session
    /// environment is never selected with a nil or foreign conversation.
    public var conversationID: UUID?
    /// SHA-256 (hex) of the canonical workspace root path: the workspace
    /// owner identity the registry validated against the record owner chain.
    public var workspaceID: String
    /// Canonical task workspace root (runtime-provided, hash-validated by
    /// the coordinator). Never a model-supplied path.
    public var workspaceRootURL: URL
    /// Project container backing this lease (a session's parent, or the
    /// project record itself). Resolving `first project` is never done.
    public var projectContainerID: String
    /// Explicitly selected execution backend, supplied by trusted
    /// composition and cross-checked against the persisted record.
    public var backend: EnvironmentExecutionBackend
    /// Writable layer the lease was pinned to (session/project layer).
    public var writableLayerURL: URL
    /// Ordered lookup stack (session > project > template > shared > base)
    /// exactly as resolved by the registry. Lookup order only.
    public var orderedLayerURLs: [URL]
    /// Per-lease home directory inside the writable layer.
    public var homeURL: URL
    /// Per-lease temporary directory inside the writable layer.
    public var temporaryURL: URL
    /// Validated ToolEnvironment variables (FLOE_ENVIRONMENT_ID, HOME,
    /// TMPDIR, PATH, PYTHONPATH, NODE_PATH).
    public var environmentVariables: [String: String]
    /// Base revision of the resolved record at lease time.
    public var baseRevision: String
}

public enum LinuxExecutionLeaseResolverError: Error, Sendable, CustomStringConvertible, Equatable {
    /// The trusted composition supplied an iOS-only backend selection.
    case backendNotSelectableOnAndroid(EnvironmentExecutionBackend)
    /// A session environment was addressed without its owning conversation.
    case sessionRequiresOwningConversation
    /// The addressed environment belongs to a different conversation.
    case foreignConversation(owner: String)
    /// The coordinator could not resolve an execution environment for the
    /// context (non-local scope or missing task workspace root).
    case noResolvedEnvironment
    /// The persisted record does not carry the composition-selected backend;
    /// silently retargeting the record is refused.
    case recordBackendMismatch(environmentID: String, recorded: String?, selected: EnvironmentExecutionBackend)

    public var description: String {
        switch self {
        case .backendNotSelectableOnAndroid(let backend):
            return "'\(backend.rawValue)' is an iOS-only execution selection; Android resolved execution requires the explicitly selected 'linuxPRoot' backend"
        case .sessionRequiresOwningConversation:
            return "a session environment requires the owning conversation; a nil conversation cannot select a session environment"
        case .foreignConversation(let owner):
            return "environment belongs to another conversation (owner \(owner))"
        case .noResolvedEnvironment:
            return "no resolved execution environment: the task needs local scope and a canonical task workspace root"
        case .recordBackendMismatch(let environmentID, let recorded, let selected):
            return "environment \(environmentID) records backend '\(recorded ?? "nil")' but the trusted composition selected '\(selected.rawValue)'; retargeting is refused"
        }
    }
}

/// Resolves `LinuxExecutionLeaseDescriptor`s through the original
/// FloeEnvironments authority. All authority decisions (workspace hash,
/// owner chain, liveness, stopping/rebuild, writable layer) stay in
/// `EnvironmentExecutionCoordinator.acquire`; this resolver only adds the
/// Android ownership gates the shared authority intentionally leaves to the
/// platform composition, and packages the validated result.
public enum LinuxExecutionLeaseResolver {

    /// LAUNCHABLE PATH. Resolves one execution environment and returns the
    /// holder the backend launch transport consumes. The holder keeps the
    /// coordinator lease until the transport confirms the owned process
    /// ACTUALLY quiesced (`markProcessQuiesced`); `release()` before that is
    /// a typed rejection, because a cancellation request is not proof of
    /// termination. Exactly one lease is acquired and exactly one owner
    /// finishes it.
    public static func acquireHolder(
        _ context: ToolContext,
        coordinator: EnvironmentExecutionCoordinator,
        registry: EnvironmentRegistry,
        selectedBackend: EnvironmentExecutionBackend
    ) async throws -> LinuxExecutionLeaseHolder {
        let lease = try await acquireValidatedLease(
            context, coordinator: coordinator, registry: registry, selectedBackend: selectedBackend
        )
        do {
            let descriptor = try await validatedDescriptor(
                from: lease, registry: registry, selectedBackend: selectedBackend
            )
            return LinuxExecutionLeaseHolder(descriptor: descriptor, lease: lease)
        } catch {
            // Sole failure-path finish for this entry point.
            await lease.finish()
            throw error
        }
    }

    /// METADATA-ONLY PATH. Resolves and validates one execution environment,
    /// then hands the lease back BEFORE returning. The returned descriptor is
    /// plain data for inspection/routing display and must NEVER be used as
    /// launch authority — a backend process may only launch from
    /// `acquireHolder`. Exactly one lease is acquired and finished.
    public static func resolveMetadata(
        _ context: ToolContext,
        coordinator: EnvironmentExecutionCoordinator,
        registry: EnvironmentRegistry,
        selectedBackend: EnvironmentExecutionBackend
    ) async throws -> LinuxExecutionLeaseDescriptor {
        let lease = try await acquireValidatedLease(
            context, coordinator: coordinator, registry: registry, selectedBackend: selectedBackend
        )
        do {
            let descriptor = try await validatedDescriptor(
                from: lease, registry: registry, selectedBackend: selectedBackend
            )
            await lease.finish()
            return descriptor
        } catch {
            await lease.finish()
            throw error
        }
    }

    /// Validates the Android ownership gates, then acquires exactly one lease
    /// through the original authority (workspace hash, owner chain, liveness,
    /// stopping/rebuild, writable layer). This helper never finishes the
    /// lease; its caller is the sole owner of the finish decision.
    private static func acquireValidatedLease(
        _ context: ToolContext,
        coordinator: EnvironmentExecutionCoordinator,
        registry: EnvironmentRegistry,
        selectedBackend: EnvironmentExecutionBackend
    ) async throws -> ToolEnvironmentLease {
        // 1. The composition's backend choice must be the Android candidate.
        //    This module never routes host execution or the iOS TinyEMU guest.
        guard selectedBackend == .linuxPRoot else {
            throw LinuxExecutionLeaseResolverError.backendNotSelectableOnAndroid(selectedBackend)
        }

        // 2. Early session ownership gate: the shared coordinator only
        //    cross-checks a session owner when a conversation id is present;
        //    a nil conversation must not be able to address another
        //    conversation's session environment. This pre-acquire check
        //    avoids pointless acquisition; the authoritative re-check runs
        //    against the RESOLVED record in `validatedDescriptor` (records
        //    can be reloaded/materialized between await points).
        if let environmentID = context.environmentID,
           let addressed = await registry.record(id: environmentID),
           addressed.kind == .session {
            try checkSessionOwnership(record: addressed, conversationID: context.conversationID)
        }

        // 3. Acquire through the original authority.
        return try await coordinator.acquire(context)
    }

    /// Pure validation + packaging of an already-acquired lease. NEVER
    /// finishes the lease: the entry point that acquired it owns the finish
    /// decision on every path.
    private static func validatedDescriptor(
        from lease: ToolEnvironmentLease,
        registry: EnvironmentRegistry,
        selectedBackend: EnvironmentExecutionBackend
    ) async throws -> LinuxExecutionLeaseDescriptor {
        // 4. The lease must carry a resolved writable layer: the
        //    coordinator's pass-through (non-local scope or nil workspace)
        //    leaves the context environment unset and is not executable.
        guard let environment = lease.context.environment else {
            throw LinuxExecutionLeaseResolverError.noResolvedEnvironment
        }
        guard let workspaceRoot = lease.context.workspaceRootURL else {
            throw LinuxExecutionLeaseResolverError.noResolvedEnvironment
        }
        guard let environmentID = lease.context.environmentID else {
            throw LinuxExecutionLeaseResolverError.noResolvedEnvironment
        }
        guard let record = await registry.record(id: environmentID) else {
            throw FloeError.notFound("Execution environment \(environmentID)")
        }

        // 5. Authoritative session ownership re-check on the RESOLVED record
        //    (post-prepare, post-acquire): the record behind this lease may
        //    have been reloaded or materialized at acquire time, so the
        //    resolved session must still belong to the resolved conversation.
        if record.kind == .session {
            try checkSessionOwnership(record: record, conversationID: lease.context.conversationID)
        }

        // 6. Backend cross-check: the record must carry the SAME explicit
        //    backend the composition selected. Records with a nil or
        //    different backend are refused rather than silently
        //    retargeted; creating or migrating a record never advertises
        //    an executable capability on its own.
        guard record.executionBackend == selectedBackend else {
            throw LinuxExecutionLeaseResolverError.recordBackendMismatch(
                environmentID: environmentID,
                recorded: record.executionBackend?.rawValue,
                selected: selectedBackend
            )
        }

        // 7. Identity survival: task/run, conversation, workspace and
        //    environment identities are carried into the descriptor
        //    exactly as the runtime issued them.
        let canonicalWorkspace = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        let workspaceID = FloeDigest.sha256Hex(Data(canonicalWorkspace.path.utf8))
        let projectContainerID: String
        switch record.kind {
        case .session:
            projectContainerID = record.parentID ?? record.id
        case .project:
            projectContainerID = record.id
        case .template, .shared:
            // The coordinator already refuses non-writable layers; this
            // is a defensive restatement, not a new authority.
            throw FloeError.validationFailed("Execution needs a writable environment")
        }
        guard let home = environment.variables["HOME"].map(URL.init(fileURLWithPath:)),
              let temporary = environment.variables["TMPDIR"].map(URL.init(fileURLWithPath:)) else {
            throw FloeError.validationFailed("Resolved environment is missing HOME/TMPDIR")
        }

        return LinuxExecutionLeaseDescriptor(
            environmentID: environmentID,
            runID: lease.context.runID,
            conversationID: lease.context.conversationID,
            workspaceID: workspaceID,
            workspaceRootURL: canonicalWorkspace,
            projectContainerID: projectContainerID,
            backend: selectedBackend,
            writableLayerURL: environment.writableLayerURL,
            orderedLayerURLs: environment.layerURLs,
            homeURL: home,
            temporaryURL: temporary,
            environmentVariables: environment.variables,
            baseRevision: record.baseRevision
        )
    }

    private static func checkSessionOwnership(record: ContainerRecord, conversationID: UUID?) throws {
        guard let conversationID else {
            throw LinuxExecutionLeaseResolverError.sessionRequiresOwningConversation
        }
        guard record.ownerID == conversationID.uuidString else {
            throw LinuxExecutionLeaseResolverError.foreignConversation(owner: record.ownerID ?? "(none)")
        }
    }
}

/// Owns one resolved execution lease until the backend process truly
/// quiesces. The environment lease is what keeps the record's liveness
/// guarantees alive for the running work; dropping it early would let
/// environment teardown reclaim layers still referenced by a live process.
public actor LinuxExecutionLeaseHolder {
    public let descriptor: LinuxExecutionLeaseDescriptor
    private let lease: ToolEnvironmentLease
    private var processQuiesced = false
    private var leaseFinished = false

    public init(descriptor: LinuxExecutionLeaseDescriptor, lease: ToolEnvironmentLease) {
        self.descriptor = descriptor
        self.lease = lease
    }

    /// Called by the backend launch transport once the owned process has
    /// ACTUALLY exited (creation identity reaped). A cancellation request
    /// alone never satisfies this gate.
    public func markProcessQuiesced() {
        processQuiesced = true
    }

    /// True once the transport confirmed real process exit.
    public var hasQuiesced: Bool { processQuiesced }

    /// True once the underlying environment lease was handed back.
    public var isReleased: Bool { leaseFinished }

    /// Releases the environment lease. Fails closed when the owned process
    /// has not quiesced yet: cancellation requested != terminated. Returns
    /// false when the lease was already released (idempotent). This is the
    /// ONLY finish call for the underlying lease on the success path.
    @discardableResult
    public func release() async throws -> Bool {
        guard processQuiesced else {
            throw FloeError.validationFailed("Environment lease cannot be released before the owned process quiesced; data was retained")
        }
        guard !leaseFinished else { return false }
        leaseFinished = true
        await lease.finish()
        return true
    }
}
