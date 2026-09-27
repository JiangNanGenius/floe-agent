// FloeExecution — Model-facing Linux guest lifecycle tools' service layer.
//
// Explicit, truthful start/status/stop/soft-restart/hard-restart control for
// the TinyEMU Linux guest owned by one Floe environment. The agent tools in
// Tools/LinuxLifecycleTools.swift call `LinuxGuestLifecycleManager`; the
// manager owns the safe ordering around an injected `LinuxGuestControlling`
// backend and never lets a request claim a shape the runtime did not grant.
//
// Honesty invariants encoded here:
//
//  * A parameterless start asks for the worker default (one vCPU, 256 MiB).
//    Explicit vcpus/memory are resolved through the typed ladder UNDER THE
//    RELEASE GATE; an unsupported count (dual harts in this single-core
//    release) throws `capabilityUnsupported` with the real reason — it is
//    never clamped onto one hart and reported as what the caller chose.
//  * An already-running guest is REUSED. An explicit shape that contradicts
//    the running guest's granted core count is refused (or asks for a restart);
//    the running VM is never silently reset.
//  * Hard restart stops the ACTUAL guest instance and verifies it left before
//    a new guest is started; it never deletes the environment and never
//    pretends a guest-shell command rebooted the host. The whole stop → start
//    transaction holds the shared service's existing per-environment
//    lifecycle ownership, so a direct start/execute/terminal/shape change is
//    refused instead of slipping into the window between the old instance
//    leaving and the replacement booting.
//  * Soft restart exists only when the guest supplies a real ordered
//    flush+durable restart performer. Without one it answers an explicit
//    capability error, never a false success.
//  * Every receipt distinguishes requested vs actual vCPU/RAM and says whether
//    the guest was reused.
//
// This layer does not own approval policy: the tool's risk labels feed the
// existing approval/risk system. It does own the safe lifecycle ordering,
// including the refusal to disrupt an open interactive terminal.

import Foundation
import FloeCore
import FloeTools

/// Typed start/restart configuration. Absent fields mean "no explicit choice":
/// the worker default (one vCPU, 256 MiB).
public struct LinuxGuestLifecycleConfig: Sendable, Equatable, Codable {
    /// Explicit vCPU count (1 or 2). nil = default one core.
    public var vcpus: Int?
    /// Explicit guest RAM in MiB (the 256…2048 ladder). nil = default 256 (the engine worker default).
    public var memoryMB: Int?

    public init(vcpus: Int? = nil, memoryMB: Int? = nil) {
        self.vcpus = vcpus
        self.memoryMB = memoryMB
    }
}

public enum LinuxGuestLifecyclePhase: String, Sendable, Codable, Equatable {
    case running
    case stopped
}

/// Truthful result of one lifecycle operation. Requested fields echo the
/// caller's typed choice (nil when none); actual fields are read back from the
/// runtime's own session table after the operation, never assumed from the
/// request.
public struct LinuxGuestLifecycleReceipt: Sendable, Equatable, Codable {
    public var phase: LinuxGuestLifecyclePhase
    public var environmentID: String
    public var requestedVCPUs: Int?
    public var requestedMemoryMB: Int?
    /// Cores the runtime actually granted (0 when stopped).
    public var actualVCPUs: Int
    public var actualMemoryMB: Int
    /// True when an already-running guest was reused untouched.
    public var reused: Bool
    public var imageID: String?
    /// Per-launch generation of the instance that served the call, when the
    /// runtime reports one; a hard restart rotates it.
    public var launchGeneration: Int?
    /// Managed services stopped as part of this operation.
    public var servicesStopped: Int
    /// Image/kernel capability summary (single-core qualified; dual
    /// unqualified with the reason).
    public var capability: String
    public var detail: String

    public init(
        phase: LinuxGuestLifecyclePhase,
        environmentID: String,
        requestedVCPUs: Int? = nil,
        requestedMemoryMB: Int? = nil,
        actualVCPUs: Int,
        actualMemoryMB: Int,
        reused: Bool,
        imageID: String? = nil,
        launchGeneration: Int? = nil,
        servicesStopped: Int = 0,
        capability: String,
        detail: String
    ) {
        self.phase = phase
        self.environmentID = environmentID
        self.requestedVCPUs = requestedVCPUs
        self.requestedMemoryMB = requestedMemoryMB
        self.actualVCPUs = actualVCPUs
        self.actualMemoryMB = actualMemoryMB
        self.reused = reused
        self.imageID = imageID
        self.launchGeneration = launchGeneration
        self.servicesStopped = servicesStopped
        self.capability = capability
        self.detail = detail
    }
}

/// Typed failures for the lifecycle manager. Every case refuses the operation
/// WITHOUT deleting or resetting the environment.
public enum LinuxGuestLifecycleError: Error, LocalizedError, Sendable, Equatable {
    /// Another lifecycle operation on this environment is in flight. The
    /// manager serializes per environment; the late caller is refused.
    case busy(environmentID: String)
    /// The backend does not own this id as a Linux guest.
    case notOwned(environmentID: String)
    /// The requested shape cannot be delivered by THIS release/image with the
    /// real reason (e.g. dual harts stay unqualified), or the guest has no
    /// soft-restart agent. Nothing boots at another shape.
    case capabilityUnsupported(environmentID: String, requestedVCPUs: Int, reason: String)
    /// A lifecycle configuration value is not expressible on the guest ladder
    /// (e.g. vcpus 0/3, or a memory size between ladder steps). Rejected
    /// SERVER-SIDE — schema enums are convenience, not the authority — and
    /// never silently rounded onto another shape.
    case invalidConfiguration(environmentID: String, detail: String)
    /// A guest is already running at a different granted core count. A running
    /// VM is fixed at create time; stop it (or hard-restart it) to change it.
    case runningShapeMismatch(environmentID: String, requestedVCPUs: Int, runningVCPUs: Int)
    /// A guest is already running at a different granted RAM tier. Like the
    /// core count, guest RAM is allocated once at create time and is never
    /// silently reshaped; stop or hard-restart it to change the tier.
    case runningMemoryMismatch(environmentID: String, requestedMB: Int, runningMB: Int)
    /// A guest is known to be running but its granted count could not be read,
    /// so the explicit request cannot be compared. Fails closed.
    case runningShapeUnknown(environmentID: String, requestedVCPUs: Int)
    /// An interactive terminal is open on the guest, so a stop/restart that
    /// would kill a human session is refused; close the terminal first.
    case activeInteractiveTerminal(environmentID: String, terminalCount: Int)
    /// The actual guest instance did not stop inside the budget. The guest is
    /// treated as quarantined (its disk is not reused by a new start) until a
    /// later stop succeeds.
    case stopFailedQuarantined(environmentID: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .busy(let id):
            return "another Linux lifecycle operation is in progress for environment \(id); retry once it finishes"
        case .notOwned(let id):
            return "environment \(id) is not owned as a Linux guest by this backend"
        case .capabilityUnsupported(let id, let requested, let reason):
            return "environment \(id): the requested \(requested)-core shape is not available: \(reason)"
        case .invalidConfiguration(let id, let detail):
            return "environment \(id): invalid lifecycle configuration: \(detail)"
        case .runningShapeMismatch(let id, let requested, let running):
            return "environment \(id) already runs a \(running)-core guest; the requested \(requested) core(s) were refused and the guest was not reset (stop or hard-restart it to change shape)"
        case .runningMemoryMismatch(let id, let requested, let running):
            return "environment \(id) already runs a guest with \(running) MiB RAM; the requested \(requested) MiB were refused and the guest was not reshaped (guest RAM is fixed at create time; stop or hard-restart it to change the tier)"
        case .runningShapeUnknown(let id, let requested):
            return "environment \(id) has a running guest whose granted core count could not be read; the explicit \(requested)-core request was refused instead of assuming a match"
        case .activeInteractiveTerminal(let id, let count):
            return "environment \(id) has \(count) interactive terminal(s) open; close them before stopping or restarting the guest"
        case .stopFailedQuarantined(let id, let detail):
            return "the guest for environment \(id) did not stop: \(detail); the disk stays quarantined until a later stop succeeds"
        }
    }
}

/// Real guest soft-restart seam: an ordered in-guest flush + durable restart
/// that preserves running services where possible. Absent in the current guest
/// image; the manager then reports soft restart unsupported.
public typealias LinuxGuestSoftRestartPerformer = @Sendable (
    _ environmentID: String,
    _ config: LinuxGuestLifecycleConfig?
) async throws -> LinuxGuestLifecycleReceipt

/// The service consumed by the lifecycle tools.
public protocol LinuxGuestLifecycleControlling: Sendable {
    func status(environmentID: String) async throws -> LinuxGuestLifecycleReceipt
    func start(
        environmentID: String,
        config: LinuxGuestLifecycleConfig,
        ownerTaskID: String?,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestLifecycleReceipt
    func stop(
        environmentID: String,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestLifecycleReceipt
    func softRestart(
        environmentID: String,
        config: LinuxGuestLifecycleConfig?,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestLifecycleReceipt
    func hardRestart(
        environmentID: String,
        config: LinuxGuestLifecycleConfig?,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestLifecycleReceipt
}

/// Serializes safe lifecycle operations around one injected guest controller.
public actor LinuxGuestLifecycleManager: LinuxGuestLifecycleControlling {
    private struct Snapshot: Equatable {
        var running: Bool
        var vcpus: Int
        var ramMB: Int
        var launchGeneration: UInt64?
    }

    /// Capability summary carried by every receipt of this release.
    public static let capabilitySummary =
        "single-core qualified (this release grants at most 1 vCPU); dual-core is unqualified — SMP boot stalls at fork/exec (cloud run 35851127603) — and only a later qualified engine can deliver it"

    /// The engine's worker default for a start that requests no RAM
    /// (`LinuxGuestLimits.defaultRAMMB`, 256 MiB). Kept in parity so a
    /// parameterless lifecycle cold start boots exactly what a parameterless
    /// `exec.shell` boots.
    public static let defaultMemoryMB = GuestMemoryMiB.m256.mb

    private let controller: any LinuxGuestControlling
    private let releasePolicy: GuestReleaseShapePolicy
    private let softRestartPerformer: LinuxGuestSoftRestartPerformer?
    /// Optional image preparation, matching the shell's prepare-and-retry
    /// path: when a start hits an unqualified/missing image, this prepares
    /// (downloads/verifies) the pinned image once and the start is retried.
    /// nil leaves the engine's honest imageNotQualified failure surfaced.
    private let prepareImage: (@Sendable (String, CancellationToken?) async throws -> Void)?
    /// How long a stop/restart waits for the runtime to report the guest gone
    /// before treating it as quarantined. Tests shorten it; production keeps
    /// the default.
    private let stopVerificationTimeout: TimeInterval
    /// Environment ids with an operation in flight; guards even across actor
    /// reentrancy at awaited boundaries.
    private var busyEnvironments = Set<String>()
    /// Internal deterministic interleaving point (never set by the app): a
    /// hard restart awaits it after the old instance is confirmed stopped and
    /// before the replacement start, so cross-concurrency tests can land a
    /// direct start/execute/terminal exactly inside the exposed window.
    private var restartWindowBarrier: (@Sendable () async -> Void)?

    /// Installs (or clears, with nil) the internal restart-window barrier used
    /// by the cross-concurrency tests. Never called by app code.
    func setRestartWindowBarrier(_ barrier: (@Sendable () async -> Void)?) {
        restartWindowBarrier = barrier
    }

    public init(
        controller: any LinuxGuestControlling,
        releasePolicy: GuestReleaseShapePolicy = .production,
        softRestartPerformer: LinuxGuestSoftRestartPerformer? = nil,
        prepareImage: (@Sendable (String, CancellationToken?) async throws -> Void)? = nil,
        stopVerificationTimeout: TimeInterval = 10
    ) {
        self.controller = controller
        self.releasePolicy = releasePolicy
        self.softRestartPerformer = softRestartPerformer
        self.prepareImage = prepareImage
        self.stopVerificationTimeout = max(0.05, stopVerificationTimeout)
    }

    // MARK: serialization

    private func beginOperation(_ environmentID: String) throws {
        guard !busyEnvironments.contains(environmentID) else {
            throw LinuxGuestLifecycleError.busy(environmentID: environmentID)
        }
        busyEnvironments.insert(environmentID)
    }

    private func endOperation(_ environmentID: String) {
        busyEnvironments.remove(environmentID)
    }

    private static func throwIfCancelled(_ token: CancellationToken?) throws {
        if let token, token.isCancelled { throw FloeError.cancelled }
    }

    // MARK: probes

    /// The runtime's own session truth for one environment, or nil when no
    /// guest instance is registered (stopped or unknown).
    private func snapshot(_ environmentID: String) async -> Snapshot? {
        let states = await controller.runtimeStates()
        guard let state = states.first(where: { $0.environmentID == environmentID }) else {
            return nil
        }
        return Snapshot(
            running: state.running,
            vcpus: state.vcpus,
            ramMB: state.ramMB,
            launchGeneration: state.identity.launchGeneration
        )
    }

    /// Ownership/activity facts for one environment from the controller.
    private func activity(_ environmentID: String) async -> LinuxGuestActivityDetail? {
        await controller.guestActivityDetails()
            .first(where: { $0.environmentID == environmentID })
    }

    /// Bounded, state-driven wait for the runtime to drop the instance. The
    /// deadline is only a safety bound; the runtime truth decides.
    private func waitUntilStopped(_ environmentID: String) async -> Bool {
        let deadline = Date().addingTimeInterval(stopVerificationTimeout)
        while Date() < deadline {
            let state = await snapshot(environmentID)
            if state == nil || state?.running == false {
                let running = await controller.guestIsRunning(environmentID: environmentID)
                if !running { return true }
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await controller.guestIsRunning(environmentID: environmentID) == false
    }

    /// Validates a lifecycle config SERVER-SIDE against the expressible guest
    /// ladder. The tool schema's enums are convenience only: an out-of-ladder
    /// value is rejected here instead of being silently rounded onto another
    /// shape (e.g. 600 MiB must not become 768 MiB).
    private func validate(
        _ config: LinuxGuestLifecycleConfig,
        environmentID: String
    ) throws {
        if let vcpus = config.vcpus {
            let expressible = GuestVCPUCount.allCases.map(\.rawValue)
            guard expressible.contains(vcpus) else {
                throw LinuxGuestLifecycleError.invalidConfiguration(
                    environmentID: environmentID,
                    detail: "vcpus must be one of \(expressible.map(String.init).joined(separator: "/")); got \(vcpus), which is not a guest shape"
                )
            }
        }
        if let memoryMB = config.memoryMB {
            guard GuestMemoryMiB(exactMB: memoryMB) != nil else {
                throw LinuxGuestLifecycleError.invalidConfiguration(
                    environmentID: environmentID,
                    detail: "memoryMB must be exactly one of the guest RAM ladder steps \(GuestMemoryMiB.allCases.sorted().map { String($0.mb) }.joined(separator: "/")); got \(memoryMB) — sizes are never rounded"
                )
            }
        }
    }

    /// Resolves a lifecycle config into the typed request UNDER THE RELEASE
    /// GATE: never clamped, never silently downgraded.
    private func resolvedRequest(
        _ config: LinuxGuestLifecycleConfig,
        environmentID: String
    ) throws -> GuestResourceRequest {
        try validate(config, environmentID: environmentID)
        do {
            return try GuestResourceRequest.resolved(
                requestedVCPUs: config.vcpus,
                // Match the engine worker default rather than the ladder's
                // 512 MiB fallback, so a parameterless lifecycle cold start
                // and a parameterless exec.shell boot the same shape.
                requestedMB: config.memoryMB ?? Self.defaultMemoryMB,
                origin: .userSpecified,
                releasePolicy: releasePolicy
            )
        } catch let error as GuestReleaseShapeError {
            throw LinuxGuestLifecycleError.capabilityUnsupported(
                environmentID: environmentID,
                requestedVCPUs: config.vcpus ?? 1,
                reason: error.localizedDescription
            )
        }
    }

    /// Merges an optional restart config with the RUNNING guest's granted
    /// shape: an unspecified dimension is PRESERVED from the running guest
    /// (a restart must not silently reset an explicitly configured VM), and
    /// only a restart with nothing running falls back to the cold-start
    /// default. An explicit dimension is kept as the caller asked.
    static func mergedConfig(
        _ config: LinuxGuestLifecycleConfig?,
        current: (vcpus: Int, ramMB: Int)?
    ) -> LinuxGuestLifecycleConfig {
        guard let config else {
            guard let current else { return LinuxGuestLifecycleConfig() }
            return LinuxGuestLifecycleConfig(vcpus: current.vcpus, memoryMB: current.ramMB)
        }
        var merged = config
        if merged.vcpus == nil { merged.vcpus = current?.vcpus }
        if merged.memoryMB == nil { merged.memoryMB = current?.ramMB }
        return merged
    }

    /// Starts the guest, applying the same image preparation + single retry
    /// the shell path uses when the only failure is a missing/unqualified
    /// image. Every other error propagates unchanged. When a shared lifecycle
    /// transaction is supplied, the replacement start runs under it (the
    /// transaction owns the environment's lifecycle lock, so a direct start
    /// cannot slip in).
    private func startWithPreparation(
        environmentID: String,
        ownerTaskID: String?,
        shape: GuestResourceRequest,
        cancellation: CancellationToken?,
        transaction: LinuxGuestLifecycleTransaction? = nil
    ) async throws -> Bool {
        do {
            return try await startGuest(
                environmentID: environmentID,
                ownerTaskID: ownerTaskID,
                shape: shape,
                transaction: transaction
            )
        } catch let error as LinuxGuestError {
            guard case .imageNotQualified = error, let prepareImage else { throw error }
            try await prepareImage(environmentID, cancellation)
            return try await startGuest(
                environmentID: environmentID,
                ownerTaskID: ownerTaskID,
                shape: shape,
                transaction: transaction
            )
        }
    }

    /// One explicit-shape start through the transaction-aware controller seam.
    private func startGuest(
        environmentID: String,
        ownerTaskID: String?,
        shape: GuestResourceRequest,
        transaction: LinuxGuestLifecycleTransaction?
    ) async throws -> Bool {
        if let transaction {
            return try await controller.startForLifecycleTransaction(
                transaction, taskID: ownerTaskID, shape: shape
            )
        }
        return try await controller.startGuest(
            environmentID: environmentID, taskID: ownerTaskID, shape: shape
        )
    }

    /// Refuses to call a start/restart successful when the runtime granted a
    /// different vCPU/RAM than the resolved request: an external request that
    /// preempted the restart (or a downgrade the manager did not authorize)
    /// must surface as an honest failure instead of a receipt whose requested
    /// and actual fields disagree.
    private func verifyGrantedShape(
        _ actual: Snapshot,
        request: GuestResourceRequest,
        environmentID: String
    ) throws {
        let requestedVCPUs = request.vcpus.count
        if actual.vcpus != requestedVCPUs {
            throw LinuxGuestLifecycleError.capabilityUnsupported(
                environmentID: environmentID,
                requestedVCPUs: requestedVCPUs,
                reason: "the guest runs with \(actual.vcpus) vCPU(s), not the requested \(requestedVCPUs); the replacement was not granted the requested shape"
            )
        }
        let requestedMB = request.memory.mb
        if actual.ramMB != requestedMB {
            throw LinuxGuestLifecycleError.capabilityUnsupported(
                environmentID: environmentID,
                requestedVCPUs: requestedVCPUs,
                reason: "the guest has \(actual.ramMB) MiB RAM, not the requested \(requestedMB) MiB; the replacement was not granted the requested shape"
            )
        }
    }

    /// Begins the shared service's exclusive stop → start transaction for a
    /// hard restart. nil means the controller cannot hold the environment
    /// across the window (focused in-memory controllers): the manager then
    /// keeps its per-call ordering and still verifies the granted shape.
    private func beginSharedTransaction(
        _ environmentID: String
    ) async throws -> LinuxGuestLifecycleTransaction? {
        do {
            return try await controller.beginLifecycleTransaction(environmentID: environmentID)
        } catch let error as LinuxGuestError {
            switch error {
            case .notOwned:
                throw LinuxGuestLifecycleError.notOwned(environmentID: environmentID)
            case .guestBusy:
                throw LinuxGuestLifecycleError.busy(environmentID: environmentID)
            default:
                throw LinuxGuestLifecycleError.capabilityUnsupported(
                    environmentID: environmentID,
                    requestedVCPUs: 1,
                    reason: error.localizedDescription
                )
            }
        }
    }

    private func receipt(
        phase: LinuxGuestLifecyclePhase,
        environmentID: String,
        config: LinuxGuestLifecycleConfig?,
        snapshot: Snapshot?,
        reused: Bool,
        imageID: String?,
        servicesStopped: Int = 0,
        detail: String
    ) -> LinuxGuestLifecycleReceipt {
        LinuxGuestLifecycleReceipt(
            phase: phase,
            environmentID: environmentID,
            requestedVCPUs: config?.vcpus,
            requestedMemoryMB: config?.memoryMB,
            actualVCPUs: phase == .running ? (snapshot?.vcpus ?? 0) : 0,
            actualMemoryMB: snapshot?.ramMB ?? 0,
            reused: reused,
            imageID: imageID,
            launchGeneration: snapshot?.launchGeneration.flatMap { Int(exactly: $0) },
            servicesStopped: servicesStopped,
            capability: Self.capabilitySummary,
            detail: detail
        )
    }

    // MARK: status

    public func status(environmentID: String) async throws -> LinuxGuestLifecycleReceipt {
        let current = await snapshot(environmentID)
        let status = await controller.guestStatus(environmentID: environmentID)
        if current?.running == true {
            return receipt(
                phase: .running,
                environmentID: environmentID,
                config: nil,
                snapshot: current,
                reused: true,
                imageID: status.imageID,
                detail: "guest is running"
            )
        }
        // A controller without a runtime-state snapshot can still prove the
        // guest is up through its liveness probe; report running honestly and
        // say the granted shape is unavailable instead of claiming "stopped".
        if await controller.guestIsRunning(environmentID: environmentID) {
            return LinuxGuestLifecycleReceipt(
                phase: .running,
                environmentID: environmentID,
                actualVCPUs: 0,
                actualMemoryMB: status.ramMB ?? 0,
                reused: true,
                imageID: status.imageID,
                capability: Self.capabilitySummary,
                detail: "guest is running, but the runtime did not report a granted-shape snapshot"
            )
        }
        return LinuxGuestLifecycleReceipt(
            phase: .stopped,
            environmentID: environmentID,
            actualVCPUs: 0,
            actualMemoryMB: status.ramMB ?? 0,
            reused: false,
            imageID: status.imageID,
            capability: Self.capabilitySummary,
            detail: status.lastError.map { "guest is stopped; last error: \($0)" } ?? "guest is stopped"
        )
    }

    // MARK: start

    public func start(
        environmentID: String,
        config: LinuxGuestLifecycleConfig = .init(),
        ownerTaskID: String? = nil,
        cancellation: CancellationToken? = nil
    ) async throws -> LinuxGuestLifecycleReceipt {
        try beginOperation(environmentID)
        defer { endOperation(environmentID) }
        try Self.throwIfCancelled(cancellation)
        // Server-side authority: an out-of-ladder configuration is refused
        // before anything is read or started, never silently rounded.
        try validate(config, environmentID: environmentID)

        let running = await snapshot(environmentID)
        let engineRunning = await controller.guestIsRunning(environmentID: environmentID)
        if running?.running == true || engineRunning {
            // An already-running guest is reused, never reset. Any explicit
            // dimension must match what the runtime actually granted — both
            // cores and RAM are fixed at create time — or the call is refused.
            if config.vcpus != nil || config.memoryMB != nil {
                guard let current = running else {
                    throw LinuxGuestLifecycleError.runningShapeUnknown(
                        environmentID: environmentID, requestedVCPUs: config.vcpus ?? 1
                    )
                }
                if let requestedVCPUs = config.vcpus, current.vcpus != requestedVCPUs {
                    throw LinuxGuestLifecycleError.runningShapeMismatch(
                        environmentID: environmentID,
                        requestedVCPUs: requestedVCPUs,
                        runningVCPUs: current.vcpus
                    )
                }
                if let requestedMB = config.memoryMB, current.ramMB != requestedMB {
                    throw LinuxGuestLifecycleError.runningMemoryMismatch(
                        environmentID: environmentID,
                        requestedMB: requestedMB,
                        runningMB: current.ramMB
                    )
                }
            }
            return receipt(
                phase: .running,
                environmentID: environmentID,
                config: config,
                snapshot: running,
                reused: true,
                imageID: await controller.guestStatus(environmentID: environmentID).imageID,
                detail: "reused the already-running guest without resetting it"
            )
        }

        let request = try resolvedRequest(config, environmentID: environmentID)
        let started: Bool
        do {
            started = try await startWithPreparation(
                environmentID: environmentID,
                ownerTaskID: ownerTaskID,
                shape: request,
                cancellation: cancellation
            )
        } catch let error as LinuxGuestError {
            // Surface the engine's honest reason as a capability/start failure.
            throw LinuxGuestLifecycleError.capabilityUnsupported(
                environmentID: environmentID,
                requestedVCPUs: config.vcpus ?? 1,
                reason: error.localizedDescription
            )
        }
        guard started else {
            throw LinuxGuestLifecycleError.notOwned(environmentID: environmentID)
        }
        guard let actual = await snapshot(environmentID), actual.running else {
            throw LinuxGuestLifecycleError.capabilityUnsupported(
                environmentID: environmentID,
                requestedVCPUs: config.vcpus ?? 1,
                reason: "start returned but no running guest was observed"
            )
        }
        // The receipt must describe the guest that really booted: a start that
        // was preempted by another request must fail honestly instead of
        // reporting requested and actual values that disagree.
        try verifyGrantedShape(actual, request: request, environmentID: environmentID)
        return receipt(
            phase: .running,
            environmentID: environmentID,
            config: config,
            snapshot: actual,
            reused: false,
            imageID: await controller.guestStatus(environmentID: environmentID).imageID,
            detail: "cold-started the guest at the requested shape"
        )
    }

    // MARK: stop

    public func stop(
        environmentID: String,
        cancellation: CancellationToken? = nil
    ) async throws -> LinuxGuestLifecycleReceipt {
        try beginOperation(environmentID)
        defer { endOperation(environmentID) }
        try Self.throwIfCancelled(cancellation)

        // Nothing to stop when no instance is registered. Ownership still has
        // to exist: a guest the backend never owns is an honest notOwned.
        let before = await snapshot(environmentID)
        if before == nil,
           await controller.guestIsRunning(environmentID: environmentID) == false {
            let owns = await controller.guestStatus(environmentID: environmentID)
            if owns.imageID == nil {
                throw LinuxGuestLifecycleError.notOwned(environmentID: environmentID)
            }
            return receipt(
                phase: .stopped,
                environmentID: environmentID,
                config: nil,
                snapshot: nil,
                reused: false,
                imageID: owns.imageID,
                detail: "guest was already stopped"
            )
        }

        // An open interactive terminal is a human session: refuse instead of
        // killing it silently.
        if let detail = await activity(environmentID), detail.activeTerminalCount > 0 {
            throw LinuxGuestLifecycleError.activeInteractiveTerminal(
                environmentID: environmentID,
                terminalCount: detail.activeTerminalCount
            )
        }
        let serviceCount = (await activity(environmentID))?.activeServiceCount ?? 0

        await controller.stopGuest(environmentID: environmentID)
        guard await waitUntilStopped(environmentID) else {
            throw LinuxGuestLifecycleError.stopFailedQuarantined(
                environmentID: environmentID,
                detail: "the runtime still reports the guest running after stop; its disk is not reused"
            )
        }
        let status = await controller.guestStatus(environmentID: environmentID)
        return receipt(
            phase: .stopped,
            environmentID: environmentID,
            config: nil,
            snapshot: nil,
            reused: false,
            imageID: status.imageID,
            servicesStopped: serviceCount,
            detail: "stopped the actual guest instance; services terminated: \(serviceCount)"
        )
    }

    // MARK: soft restart

    public func softRestart(
        environmentID: String,
        config: LinuxGuestLifecycleConfig? = nil,
        cancellation: CancellationToken? = nil
    ) async throws -> LinuxGuestLifecycleReceipt {
        try beginOperation(environmentID)
        defer { endOperation(environmentID) }
        try Self.throwIfCancelled(cancellation)
        guard let performer = softRestartPerformer else {
            throw LinuxGuestLifecycleError.capabilityUnsupported(
                environmentID: environmentID,
                requestedVCPUs: config?.vcpus ?? 1,
                reason: """
                soft restart is not implemented in the guest image (no ordered flush + durable \
                restart agent), so a false success was refused; use environment.hardRestartLinux \
                (which stops the actual TinyEMU instance) when the disruption is acceptable
                """
            )
        }
        return try await performer(environmentID, config)
    }

    // MARK: hard restart

    public func hardRestart(
        environmentID: String,
        config: LinuxGuestLifecycleConfig? = nil,
        cancellation: CancellationToken? = nil
    ) async throws -> LinuxGuestLifecycleReceipt {
        try beginOperation(environmentID)
        defer { endOperation(environmentID) }
        try Self.throwIfCancelled(cancellation)
        // Server-side authority: reject an out-of-ladder configuration before
        // any disruption (never rounded onto another shape).
        if let config { try validate(config, environmentID: environmentID) }

        if let detail = await activity(environmentID), detail.activeTerminalCount > 0 {
            throw LinuxGuestLifecycleError.activeInteractiveTerminal(
                environmentID: environmentID,
                terminalCount: detail.activeTerminalCount
            )
        }
        let serviceCount = (await activity(environmentID))?.activeServiceCount ?? 0

        // Hold the shared service's exclusive transaction across the WHOLE
        // stop → verify → start sequence: a direct start (exec.shell), guest
        // command, terminal or shape change must not slip into the window
        // between the old instance leaving and the replacement booting. The
        // transaction reuses the registry's existing per-environment
        // lifecycle lock; the transaction's own stop/start run under that
        // ownership instead of re-acquiring it. Backends without the seam
        // answer nil and keep the per-call ordering.
        let transaction = try await beginSharedTransaction(environmentID)
        do {
            // The transaction may have waited behind another operation: a
            // token cancelled meanwhile must abort before any disruption, and
            // the catch below still releases the shared ownership.
            try Self.throwIfCancelled(cancellation)
            let receipt = try await performHardRestart(
                environmentID: environmentID,
                transaction: transaction,
                config: config,
                serviceCount: serviceCount,
                cancellation: cancellation
            )
            if let transaction { await controller.endLifecycleTransaction(transaction) }
            return receipt
        } catch {
            // Release the shared ownership on EVERY failure path (cancellation,
            // unconfirmed stop, start refusal) so the environment is not left
            // locked; a quarantine stays registered in the registry.
            if let transaction { await controller.endLifecycleTransaction(transaction) }
            throw error
        }
    }

    /// The stop → verify → start body of a hard restart, run under the
    /// transaction when the backend supports one. The running guest's shape is
    /// read HERE, under the transaction: a direct start that completed
    /// between the manager's activity probes and the transaction acquisition
    /// is still seen and restarted, never mistaken for the replacement.
    private func performHardRestart(
        environmentID: String,
        transaction: LinuxGuestLifecycleTransaction?,
        config: LinuxGuestLifecycleConfig?,
        serviceCount: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestLifecycleReceipt {
        // Preserve the RUNNING guest's configured shape for every dimension the
        // caller left unspecified: a restart must not silently reset an
        // explicitly configured VM to the cold-start default. Only a restart
        // with no running guest falls back to defaults.
        let before = await snapshot(environmentID)
        let runningShape: (vcpus: Int, ramMB: Int)? = {
            guard let before, before.running else { return nil }
            return (before.vcpus, before.ramMB)
        }()
        let lifecycleConfig = Self.mergedConfig(config, current: runningShape)
        // Resolve the requested shape BEFORE any disruption: an unqualified
        // request (dual harts in this release) refuses here without first
        // killing the running guest.
        let request = try resolvedRequest(lifecycleConfig, environmentID: environmentID)

        // Stop the ACTUAL instance and verify it left before restarting.
        let oldEngineRunning = await controller.guestIsRunning(environmentID: environmentID)
        if before != nil || oldEngineRunning {
            if let transaction {
                await controller.stopForLifecycleTransaction(transaction)
            } else {
                await controller.stopGuest(environmentID: environmentID)
            }
            guard await waitUntilStopped(environmentID) else {
                throw LinuxGuestLifecycleError.stopFailedQuarantined(
                    environmentID: environmentID,
                    detail: "hard restart aborted after stop: the old guest did not leave; no new guest was started"
                )
            }
        }
        // Deterministic test interleaving: the old instance is fully gone and
        // the replacement has not started. The shared transaction (when
        // supported) is held across this point.
        if let barrier = restartWindowBarrier { await barrier() }

        let started: Bool
        do {
            started = try await startWithPreparation(
                environmentID: environmentID,
                ownerTaskID: nil,
                shape: request,
                cancellation: cancellation,
                transaction: transaction
            )
        } catch let error as LinuxGuestError {
            throw LinuxGuestLifecycleError.capabilityUnsupported(
                environmentID: environmentID,
                requestedVCPUs: lifecycleConfig.vcpus ?? 1,
                reason: error.localizedDescription
            )
        }
        guard started else {
            throw LinuxGuestLifecycleError.notOwned(environmentID: environmentID)
        }
        guard let actual = await snapshot(environmentID), actual.running else {
            throw LinuxGuestLifecycleError.capabilityUnsupported(
                environmentID: environmentID,
                requestedVCPUs: lifecycleConfig.vcpus ?? 1,
                reason: "restart returned but no running guest was observed"
            )
        }
        // The replacement must run at the resolved request: if anything else
        // (an external request that preempted, or a silent downgrade) booted
        // a different shape, the restart fails instead of reporting success.
        try verifyGrantedShape(actual, request: request, environmentID: environmentID)
        if let oldGeneration = before?.launchGeneration,
           let newGeneration = actual.launchGeneration,
           oldGeneration == newGeneration {
            throw LinuxGuestLifecycleError.capabilityUnsupported(
                environmentID: environmentID,
                requestedVCPUs: lifecycleConfig.vcpus ?? 1,
                reason: "hard restart did not rotate the launch generation; the old instance may still be running"
            )
        }
        let status = await controller.guestStatus(environmentID: environmentID)
        return receipt(
            phase: .running,
            environmentID: environmentID,
            config: lifecycleConfig,
            snapshot: actual,
            reused: false,
            imageID: status.imageID,
            servicesStopped: serviceCount,
            detail: "hard-restarted: the old TinyEMU instance was stopped and verified, then a fresh instance booted"
        )
    }
}
