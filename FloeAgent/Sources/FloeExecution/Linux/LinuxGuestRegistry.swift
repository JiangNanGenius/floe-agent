// FloeExecution — Linux guest registry and command service.
//
// One registry owns one guest per environment and any number of environments,
// bounded by an explicit admission budget (guest count and reserved guest
// RAM, because every environment's interpreter VM costs memory). The shell,
// localPython and localService paths for an environment share the same
// interpreter and the same 9p views. Sessions are keyed by environment id and
// record the task that started them for ownership teardown. An existing
// environment disk is a mutable clone of a verified base image: a catalog
// image update never rewrites it, and the runner inside it is upgraded in
// place (in-guest, from verified standalone bytes) instead of resetting the
// disk.

import Foundation
import FloeCore
import FloeTools

/// One guest session's lifecycle closures. The registry only needs these
/// seams, which keeps the TinyEMU C bridge out of the scheduling logic.
public struct LinuxGuestSessionHandle: Sendable {
    public var transport: any LinuxGuestConsoleTransport
    public var start: @Sendable () async throws -> Void
    public var stop: @Sendable () async -> Void
    public var close: @Sendable () async -> Void
    public var isRunning: @Sendable () async -> Bool
    public var addForward: @Sendable (LinuxGuestServiceForward) throws -> Void
    public var removeForward: @Sendable (LinuxGuestServiceForward) throws -> Void
    /// Latest cumulative emulator-thread CPU sample; nil on scripted/test
    /// sessions that do not model it.
    public var emulatorCPUSample: @Sendable () -> LinuxGuestEmulatorCPUSample?
    /// Sets the RAM the machine will use on its NEXT start (the engine
    /// allocates guest RAM at create time and cannot balloon online, so a
    /// tier change is always a stop → flush → restart). nil on scripted/test
    /// sessions that do not model memory tiers.
    public var setRAMMB: (@Sendable (Int) -> Void)?
    /// Sets the vCPU count the machine will use on its NEXT start, same
    /// stop → flush → restart boundary as `setRAMMB` (the pinned engine has
    /// no online hotplug). Wired by the TinyEMU session factory; nil on
    /// sessions that do not model shape changes. Throwing: the machine's
    /// own release gate (B4) is the last boundary, so an unqualified count
    /// that reached it despite the pool refusal surfaces as an error and
    /// the restart rolls back instead of booting a silently different shape.
    public var setVCPUs: (@Sendable (Int) throws -> Void)?

    public init(
        transport: any LinuxGuestConsoleTransport,
        start: @escaping @Sendable () async throws -> Void,
        stop: @escaping @Sendable () async -> Void,
        close: @escaping @Sendable () async -> Void,
        isRunning: @escaping @Sendable () async -> Bool,
        addForward: @escaping @Sendable (LinuxGuestServiceForward) throws -> Void,
        removeForward: @escaping @Sendable (LinuxGuestServiceForward) throws -> Void,
        emulatorCPUSample: @escaping @Sendable () -> LinuxGuestEmulatorCPUSample? = { nil },
        setRAMMB: (@Sendable (Int) -> Void)? = nil,
        setVCPUs: (@Sendable (Int) throws -> Void)? = nil
    ) {
        self.transport = transport
        self.start = start
        self.stop = stop
        self.close = close
        self.isRunning = isRunning
        self.addForward = addForward
        self.removeForward = removeForward
        self.emulatorCPUSample = emulatorCPUSample
        self.setRAMMB = setRAMMB
        self.setVCPUs = setVCPUs
    }
}

/// Session creation seam: production = TinyEMU, tests = scripted transports.
public protocol LinuxGuestSessionCreating: Sendable {
    func makeSession(
        descriptor: LinuxGuestEnvironmentDescriptor,
        image: LinuxGuestImage,
        limits: LinuxGuestLimits
    ) throws -> LinuxGuestSessionHandle
}

extension TinyEMUGuestSessionFactory: LinuxGuestSessionCreating {}

/// App-registered builder for the optional guest → host control bridge
/// (`floe-host`). The app closes over its own bridge implementation and
/// returns the handler, including the HELLO advertisement, for one
/// environment's declared 9p share table. Returning nil leaves the
/// capability unadvertised for that environment; the registry never invents
/// a handler of its own.
public typealias LinuxGuestHostRequestHandlerFactory = @Sendable (
    _ environmentID: String,
    _ pathMap: LinuxGuestPathMap
) -> LinuxGuestHostRequestHandler?

/// Registration cell shared by the command service (writer) and the registry
/// actor (reader at each session start). A lock, not actor state, so the app
/// can install the factory during its synchronous assembly and every existing
/// service copy sees the same value.
final class LinuxGuestHostRequestHandlerRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var factory: LinuxGuestHostRequestHandlerFactory?

    func install(_ factory: LinuxGuestHostRequestHandlerFactory?) {
        lock.lock()
        defer { lock.unlock() }
        self.factory = factory
    }

    func current() -> LinuxGuestHostRequestHandlerFactory? {
        lock.lock()
        defer { lock.unlock() }
        return factory
    }
}

/// Shape admission result for one guest start: the granted RAM tier and vCPU
/// count plus honest downgrade reporting. This is the B2-side seam consumed by
/// `TinyEMULinuxGuestRegistry.start`; the Runtime v2 integrator overrides
/// `acquireShape(...)` to reach the pool's three-axis (vCPU/RAM/VM) admission.
public struct LinuxGuestShapeAdmission: Sendable, Equatable {
    public var runtimeID: String
    public var ramMB: Int
    public var vcpus: Int
    public var downgraded: Bool
    public var vcpusDowngraded: Bool
    public var downgradeReason: String?

    public init(
        runtimeID: String,
        ramMB: Int,
        vcpus: Int,
        downgraded: Bool,
        vcpusDowngraded: Bool = false,
        downgradeReason: String? = nil
    ) {
        self.runtimeID = runtimeID
        self.ramMB = ramMB
        self.vcpus = vcpus
        self.downgraded = downgraded
        self.vcpusDowngraded = vcpusDowngraded
        self.downgradeReason = downgradeReason
    }
}

/// Authoritative per-session runtime truth for UI/metrics surfaces (H):
/// pairs the environment with the identity type H's sampler consumes
/// (`LinuxGuestRuntimeIdentity`, runtimeID + launchGeneration) plus the
/// granted shape and liveness. `runtimeID` is the Runtime v2 slot identity
/// (nil on the legacy admission path, preserved as unknown); the
/// `launchGeneration` is the registry's own per-session generation, minted
/// for every owned session, so a restart rotates the identity and no
/// consumer has to invent one.
public struct LinuxGuestRuntimeState: Sendable, Equatable {
    public var environmentID: String
    public var identity: LinuxGuestRuntimeIdentity
    public var running: Bool
    public var ramMB: Int
    public var vcpus: Int
    public var startedAt: Date

    public init(
        environmentID: String,
        identity: LinuxGuestRuntimeIdentity,
        running: Bool,
        ramMB: Int,
        vcpus: Int,
        startedAt: Date
    ) {
        self.environmentID = environmentID
        self.identity = identity
        self.running = running
        self.ramMB = ramMB
        self.vcpus = vcpus
        self.startedAt = startedAt
    }
}

public extension LinuxGuestRuntimeV2Integrating {
    /// Three-axis admission seam. The production Runtime v2 integrator
    /// overrides this with the resource pool's shape-aware `acquire` (real
    /// granted vCPU/RAM, release + image SMP gates, strict/authorized
    /// downgrade policy). The default bridges to the legacy MB-only slot:
    /// one vCPU, memory downgrades only — fail closed for any shape THIS
    /// release does not qualify (B4: one hart, independent of the image
    /// manifest), never silently granting a second hart the legacy path
    /// cannot account for.
    func acquireShape(
        environmentID: String,
        runtimeID: String,
        request: GuestResourceRequest,
        imageSMPCapable: Bool,
        downgrade: GuestShapeDowngradePolicy
    ) async throws -> LinuxGuestShapeAdmission {
        // The release gate is independent of the caller's SMP claim.
        let vcpuDowngraded: Bool
        switch (request.vcpus, downgrade) {
        case (.one, _):
            vcpuDowngraded = false
        case (_, .strict):
            throw LinuxGuestError.releaseShapeUnsupported(requested: request.vcpus.count, maximum: 1)
        case (_, .authorized(let vcpuFloor, _)):
            guard vcpuFloor == .one else {
                throw LinuxGuestError.releaseShapeUnsupported(requested: request.vcpus.count, maximum: 1)
            }
            vcpuDowngraded = true
        }
        let admission = try await acquireSlot(
            environmentID: environmentID, runtimeID: runtimeID, requestedMB: request.memory.mb
        )
        return LinuxGuestShapeAdmission(
            runtimeID: admission.runtimeID,
            ramMB: admission.ramMB,
            vcpus: 1,
            downgraded: admission.downgraded || vcpuDowngraded,
            vcpusDowngraded: vcpuDowngraded,
            downgradeReason: vcpuDowngraded
                ? "this release qualifies one guest core; the caller authorized a single-hart boot"
                : (admission.downgraded
                    ? "memory tier lowered by the legacy MB-only admission path" : nil)
        )
    }

    /// Validates a requested shape change BEFORE any disruption. Default
    /// bridges to the RAM-only retier plan; a vCPU change requires the
    /// integrator's CPU-aware override (the pool must validate the vCPU
    /// quota), so it throws an actionable error instead of skipping that
    /// validation and drifting the pool accounting. The loose integer goes
    /// through the production release gate, never a clamp: a request for
    /// two/six cores in a single-core release fails before any stop runs.
    func planReshape(
        environmentID: String,
        ramMB: Int,
        vcpus: Int,
        currentVCPUs: Int
    ) async throws {
        let policy = GuestReleaseShapePolicy.production
        let requested: GuestVCPUCount
        do {
            requested = try policy.resolve(requestedVCPUs: vcpus)
        } catch GuestReleaseShapeError.invalidVCPUCount {
            throw LinuxGuestError.invalidConfiguration(
                "invalid guest core count \(vcpus); this release supports exactly one"
            )
        } catch {
            throw LinuxGuestError.releaseShapeUnsupported(
                requested: vcpus, maximum: policy.maximumSupportedVCPUs
            )
        }
        let current = (try? policy.resolve(requestedVCPUs: currentVCPUs)) ?? .one
        guard requested == current else {
            throw LinuxGuestError.invalidConfiguration(
                "changing guest vCPUs to \(vcpus) requires the Runtime v2 shape planner, which is not connected yet"
            )
        }
        try await planRetier(environmentID: environmentID, ramMB: ramMB)
    }

    /// Confirms a completed shape change. Default records the RAM tier; the
    /// integrator override records the full shape.
    func confirmReshape(environmentID: String, ramMB: Int, vcpus: Int) async {
        _ = vcpus
        await confirmTier(environmentID: environmentID, ramMB: ramMB)
    }
}

public actor TinyEMULinuxGuestRegistry {
    /// Logical capacity of each environment raw disk. Test registries can
    /// override via `init(targetDiskCapacityBytes:)`; production grows to
    /// the 8 GiB `LinuxGuestDiskLayout` target.
    private let targetDiskCapacityBytes: Int64
    /// Release gate enforced at the registry's own start/reshape boundaries
    /// (B4), independent of the image manifest and the v2 substrate.
    /// Production assemblies use `.production`; focused lifecycle tests that
    /// exercise the stop → dual-hart restart path pass an explicit
    /// `.internalSyntheticTesting(provenance:)` policy — never an env var or
    /// manifest claim, and never assembled by the app.
    private let releasePolicy: GuestReleaseShapePolicy
    private struct Session {
        var descriptor: LinuxGuestEnvironmentDescriptor
        var image: LinuxGuestImage
        var handle: LinuxGuestSessionHandle
        var channel: LinuxGuestCommandChannel
        var startedAt: Date
        var taskID: String?
        var forwards: [LinuxGuestServiceForward]
        /// Runtime v2 slot identity (runtime/vm/<runtimeID>); nil on the
        /// legacy admission path.
        var runtimeID: String?
        /// First-boot network result reported by the runner during this
        /// session's capability handshake. nil when the boot path did not
        /// negotiate (unknown, never assumed ready).
        var networkStatus: LinuxGuestNetworkStatus?
        /// Identity of this owned session, minted every time a handle becomes
        /// the environment's owned guest (registration, replacement, confirmed
        /// removal, quarantine). A lifecycle operation suspended across an
        /// await revalidates this value before it writes, restarts or rebooks
        /// anything, so a stale operation can never resurrect the old handle or
        /// mutate a replacement session.
        var generation: UInt64
    }

    private let environments: any LinuxGuestEnvironmentProviding
    private let images: any LinuxGuestImageResolving
    private let limits: LinuxGuestLimits
    private let factory: any LinuxGuestSessionCreating
    /// Runtime v2 substrate: pool admission (4 running + queue), durable
    /// leases, working-disk/delta lifecycle. nil keeps the legacy bounded
    /// admission (capacityReached) and per-layer disk preparation — the seam
    /// used by focused registry tests.
    private let runtimeV2: (any LinuxGuestRuntimeV2Integrating)?
    private var sessions: [String: Session] = [:]
    private var lastErrors: [String: String] = [:]
    private var lastImpacts: [String: String] = [:]
    /// Per-environment failure of the in-guest ext4 resize after the host
    /// grew the raw container. The guest still runs at its previous
    /// capacity; the UI surfaces this as a repair state.
    private var diskResizeFailures: [String: String] = [:]
    private var terminalSessions: [String: TerminalSession] = [:]
    /// Environments whose start is in flight. The actor is reentrant across
    /// awaits, so without this a concurrent start of the same environment
    /// would prepare a second disk copy and create a second VM.
    private var startingEnvironments: Set<String> = []
    /// Environments asked to stop while their start was in flight; the start
    /// tears its own handle down instead of registering a session.
    private var pendingStops: Set<String> = []
    /// Environments whose teardown is in flight. The actor is reentrant across
    /// the close awaits, so a concurrent start must not see a removed session
    /// and boot a second VM on the same environment disk.
    private var teardownsInFlight: Set<String> = []
    /// In-flight guest commands per environment (one-shot runs and service
    /// SPAWN/OPEN exchanges). A guest with an active command is never a
    /// transient-release candidate: the release waits for the run's own
    /// command to finish (bounded) instead of interrupting it.
    private var activeCommands: [String: Int] = [:]
    /// Guest pids spawned as managed background services and not yet killed.
    /// A guest with a live managed service is persistent work, not a
    /// disposable tool guest.
    private var spawnedServices: [String: Set<Int32>] = [:]
    /// Environments whose VM survived a stop (the engine run loop did not exit
    /// inside its budget). The session and its admission reservation are kept,
    /// no new guest may boot on that environment's disk, and a later stop can
    /// still recover it.
    private var quarantinedEnvironments: Set<String> = []
    /// Admission reservations: environment id → reserved guest RAM (MB).
    /// Covers starts in flight and running sessions alike, so concurrent
    /// starts cannot oversubscribe the device's guest budget.
    private var guestReservations: [String: Int] = [:]
    /// Per-environment lifecycle linearization. A shape/RAM change holds this
    /// lock for its whole stop → apply → restart → confirm critical section; a
    /// teardown takes it before its destructive phase (channel/handle close,
    /// delta capture, working-disk/lease/slot release). The engine stop/start
    /// paths await, so the actor is reentrant: without this lock a resuming
    /// reshape could restart a handle whose working disk, lease and pool slot a
    /// concurrent stop already released. `teardownsInFlight` remains the
    /// cancellation signal a reshape re-checks after every await; the lock
    /// additionally guarantees the teardown cannot release the disk/lease
    /// while the reshape is still inside its restart, and a reshape waiting
    /// behind a teardown revalidates session identity before touching anything.
    private struct LifecycleWaiter {
        var token: UInt64
        var isShapeChange: Bool
        var continuation: CheckedContinuation<Void, Never>
    }

    private struct LifecycleLock {
        var ownerToken: UInt64
        var ownerIsShapeChange: Bool
        var waiters: [LifecycleWaiter]
    }

    private var lifecycleLocks: [String: LifecycleLock] = [:]
    private var lifecycleOperationTokenCounter: UInt64 = 0
    private var sessionGenerationCounter: UInt64 = 0
    /// App-installed factory for the optional guest → host control bridge.
    /// Read once per session start; see `LinuxGuestHostRequestHandlerRegistry`.
    private let hostRequestHandlerRegistry = LinuxGuestHostRequestHandlerRegistry()

    /// One interactive guest terminal plus its buffered output.
    private struct TerminalSession {
        var environmentID: String
        var handle: LinuxGuestInteractiveSession
    }

    public init(
        environments: any LinuxGuestEnvironmentProviding,
        images: any LinuxGuestImageResolving,
        limits: LinuxGuestLimits = .standard,
        factory: any LinuxGuestSessionCreating = TinyEMUGuestSessionFactory(),
        targetDiskCapacityBytes: Int64 = LinuxGuestDiskLayout.targetLogicalCapacityBytes,
        runtimeV2: (any LinuxGuestRuntimeV2Integrating)? = nil,
        releasePolicy: GuestReleaseShapePolicy = .production
    ) {
        self.environments = environments
        self.images = images
        self.limits = limits
        self.factory = factory
        self.targetDiskCapacityBytes = targetDiskCapacityBytes
        self.runtimeV2 = runtimeV2
        self.releasePolicy = releasePolicy
    }

    /// True when this service owns the environment as a Linux guest, running
    /// or not. Native environments (and unknown ids) answer false.
    public func owns(environmentID: String) async -> Bool {
        await environments.linuxGuestEnvironment(id: environmentID) != nil
    }

    /// Installs (or clears, with nil) the app's builder for the optional
    /// guest → host control bridge. Nonisolated and synchronous by design:
    /// the app assembles its services before any guest can start, and the
    /// builder is only invoked at session start — so nothing is advertised
    /// to a guest before a handler for its own shares exists.
    public nonisolated func installHostRequestHandlerFactory(
        _ factory: LinuxGuestHostRequestHandlerFactory?
    ) {
        hostRequestHandlerRegistry.install(factory)
    }

    /// True only when the owned guest is actually running.
    public func supports(environmentID: String) async -> Bool {
        guard await environments.linuxGuestEnvironment(id: environmentID) != nil else {
            await stop(environmentID: environmentID)
            return false
        }
        guard let session = sessions[environmentID] else { return false }
        return await session.handle.isRunning()
    }

    public func status(environmentID: String) async -> LinuxGuestStatus {
        let descriptor = await environments.linuxGuestEnvironment(id: environmentID)
        var imageInstalled: Bool?
        var imageFailure: String?
        var distributable: Bool?
        if let imageID = descriptor?.imageID {
            imageInstalled = await images.linuxGuestImage(id: imageID) != nil
            imageFailure = await images.linuxGuestImageVerificationFailure(id: imageID)
            distributable = LinuxGuestImageDistributionCatalog.entry(id: imageID) != nil
            if let runtimeV2, await runtimeV2.isImageVerified(imageID: imageID) {
                // Runtime v2 verified truth: an image whose legacy directory
                // was moved aside by migration is still installed — a
                // verified (even running) guest can never report uninstalled.
                let resolverSawInstalled = imageInstalled == true
                imageInstalled = true
                if !resolverSawInstalled { imageFailure = nil }
            }
        }
        let admitted = guestReservations.count
        let reservedRAM = reservedGuestRAMMB
        let queued = await runtimeV2?.queuedStarts()
        if let session = sessions[environmentID] {
            return LinuxGuestStatus(
                environmentID: environmentID,
                running: await session.handle.isRunning(),
                imageID: session.image.id,
                ramMB: limits.clampedRAMMB(session.descriptor.ramMB),
                startedAt: session.startedAt,
                lastError: lastErrors[environmentID],
                imageInstalled: imageInstalled,
                imageVerificationFailure: imageFailure,
                imageDistributable: distributable,
                lastResetSharedImpact: lastImpacts[environmentID],
                activeGuestCount: admitted,
                reservedGuestRAMMB: reservedRAM,
                networkStatus: session.networkStatus,
                diskResizeFailure: diskResizeFailures[environmentID],
                queuedGuestCount: queued
            )
        }
        return LinuxGuestStatus(
            environmentID: environmentID,
            running: false,
            imageID: descriptor?.imageID,
            ramMB: descriptor?.ramMB,
            lastError: lastErrors[environmentID],
            imageInstalled: imageInstalled,
            imageVerificationFailure: imageFailure,
            imageDistributable: distributable,
            lastResetSharedImpact: lastImpacts[environmentID],
            activeGuestCount: admitted,
            reservedGuestRAMMB: reservedRAM,
            diskResizeFailure: diskResizeFailures[environmentID],
            queuedGuestCount: queued
        )
    }

    /// Latest cumulative emulator-thread CPU sample for one environment; nil
    /// when no session exists or the session factory did not supply a sampler.
    public func emulatorThreadCPUSample(environmentID: String) -> LinuxGuestEmulatorCPUSample? {
        sessions[environmentID]?.handle.emulatorCPUSample()
    }

    /// Guests currently holding an admission slot. Running sessions and starts
    /// in flight both count.
    public var activeGuestCount: Int { guestReservations.count }

    /// Environment ids that currently hold guest capacity: running sessions,
    /// starts in flight (the reservation is published before the VM boots)
    /// and quarantined survivors of a failed stop (their slot stays owned so
    /// no new guest ever boots on that disk). This — not `guestIsRunning` —
    /// is the arbiter's activity truth: a starting or stop-quarantined VM
    /// has no running vCPU yet still owns real memory and its disk.
    public var environmentsWithGuestActivity: [String] {
        guestReservations.keys.sorted()
    }

    /// Authoritative runtime identity of one environment's session, for the
    /// metrics sampler's `runtimeIdentityProvider` seam. A fresh `runtimeID`
    /// is minted per Runtime v2 start, and `launchGeneration` is this
    /// session's own minted generation (bumped on every registration,
    /// replacement, confirmed removal or quarantine), so both distinguish a
    /// restart from the previous launch even for the same environment. The
    /// generation is the registry's real per-start identity — never a
    /// locally incremented UI guess and never an invented value; a missing
    /// session answers an all-nil identity.
    public func runtimeIdentity(environmentID: String) async -> LinuxGuestRuntimeIdentity {
        guard let session = sessions[environmentID] else {
            return LinuxGuestRuntimeIdentity()
        }
        return LinuxGuestRuntimeIdentity(
            runtimeID: session.runtimeID,
            launchGeneration: session.generation
        )
    }

    /// Authoritative state of every session this service owns (running, and
    /// quarantined survivors of a failed stop): identity, liveness and the
    /// granted shape. Stopped is not deleted: callers must pair this with
    /// `owns(environmentID:)` (environment existence) rather than treating a
    /// missing entry as a deleted environment.
    public func runtimeStates() async -> [LinuxGuestRuntimeState] {
        var states: [LinuxGuestRuntimeState] = []
        for (environmentID, session) in sessions {
            states.append(
                LinuxGuestRuntimeState(
                    environmentID: environmentID,
                    identity: LinuxGuestRuntimeIdentity(
                        runtimeID: session.runtimeID,
                        launchGeneration: session.generation
                    ),
                    running: await session.handle.isRunning(),
                    ramMB: limits.clampedRAMMB(session.descriptor.ramMB),
                    vcpus: (try? releasePolicy.resolve(
                        requestedVCPUs: session.descriptor.vcpus
                    ))?.count ?? 1,
                    startedAt: session.startedAt
                )
            )
        }
        return states.sorted { $0.environmentID < $1.environmentID }
    }

    /// Interactive PTY sessions currently open inside one environment's
    /// guest. The registry owns the session table, so a number is a real
    /// measurement (zero included); an environment this service does not own
    /// answers nil, never a fabricated zero.
    public func activeSessionCount(environmentID: String) async -> Int? {
        guard await environments.linuxGuestEnvironment(id: environmentID) != nil else {
            return nil
        }
        return terminalSessions.values.lazy.filter { $0.environmentID == environmentID }.count
    }

    /// Guest RAM (MB) reserved by the guests above.
    public var reservedGuestRAMMB: Int { guestReservations.values.reduce(0, +) }

    /// Bounded admission: refuses a new guest (before any VM or disk copy is
    /// created) when the per-device guest count or RAM budget is used up.
    /// Running guests are never killed to make room and this never waits for
    /// a slot to free up; the caller gets an actionable error instead.
    private func reserveGuestCapacity(environmentID: String, ramMB: Int) throws {
        if guestReservations[environmentID] != nil { return }
        if guestReservations.count >= limits.maxActiveGuests {
            throw LinuxGuestError.capacityReached(
                detail: "this device already runs \(guestReservations.count) Linux guests (limit \(limits.maxActiveGuests), \(reservedGuestRAMMB) MB of \(limits.maxGuestRAMMB) MB reserved); stop a guest before starting another"
            )
        }
        let total = reservedGuestRAMMB + ramMB
        guard total <= limits.maxGuestRAMMB else {
            throw LinuxGuestError.capacityReached(
                detail: "starting a \(ramMB) MB guest would reserve \(total) MB of the \(limits.maxGuestRAMMB) MB device guest RAM budget; \(reservedGuestRAMMB) MB is already reserved by \(guestReservations.count) guest(s). Stop a guest or lower the requested RAM"
            )
        }
        guestReservations[environmentID] = ramMB
        publishReservation(environmentID: environmentID, ramMB: ramMB)
    }

    /// Publishes the admitted guest RAM to the process-wide reservation
    /// registry so the local-model memory preflight subtracts a running
    /// guest's budget instead of admitting a model on top of pages the OS has
    /// not charged yet. FloeExecution owns the reservation; FloeCore only
    /// carries the number.
    private func publishReservation(environmentID: String, ramMB: Int?) {
        let bytes = Int64(max(0, ramMB ?? 0)) * 1_048_576
        ResidentMemoryReservations.set(id: "linux-guest:" + environmentID, bytes: bytes)
    }

    /// Releases the published reservation for one environment.
    private func clearReservation(environmentID: String) {
        ResidentMemoryReservations.clear(id: "linux-guest:" + environmentID)
    }

    /// Mints the identity of the next owned session.
    private func nextSessionGeneration() -> UInt64 {
        sessionGenerationCounter &+= 1
        return sessionGenerationCounter
    }

    /// Mints the owner token for the next lifecycle operation.
    private func nextLifecycleOperationToken() -> UInt64 {
        lifecycleOperationTokenCounter &+= 1
        return lifecycleOperationTokenCounter
    }

    /// True while a shape/RAM change owns the environment's lifecycle lock.
    private func isShapeChangeInFlight(environmentID: String) -> Bool {
        lifecycleLocks[environmentID]?.ownerIsShapeChange == true
    }

    /// FIFO acquire of the environment's lifecycle lock. The token identifies
    /// the owner, so a late release can never free another operation's lock.
    private func acquireLifecycle(
        environmentID: String,
        token: UInt64,
        isShapeChange: Bool
    ) async {
        if var lock = lifecycleLocks[environmentID] {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.waiters.append(
                    LifecycleWaiter(
                        token: token, isShapeChange: isShapeChange, continuation: continuation
                    )
                )
                lifecycleLocks[environmentID] = lock
            }
            return
        }
        lifecycleLocks[environmentID] = LifecycleLock(
            ownerToken: token, ownerIsShapeChange: isShapeChange, waiters: []
        )
    }

    /// Releases the lifecycle lock, handing it to the next waiter in arrival
    /// order. A stale token is ignored: it cannot free another owner's lock.
    private func releaseLifecycle(environmentID: String, token: UInt64) {
        guard var lock = lifecycleLocks[environmentID], lock.ownerToken == token else { return }
        guard !lock.waiters.isEmpty else {
            lifecycleLocks[environmentID] = nil
            return
        }
        let next = lock.waiters.removeFirst()
        lock.ownerToken = next.token
        lock.ownerIsShapeChange = next.isShapeChange
        lifecycleLocks[environmentID] = lock
        next.continuation.resume()
    }

    /// True when the environment's owned session is still the generation a
    /// suspended operation captured: it is false after a stop removed or
    /// re-quarantined that handle and after a replacement start registered a
    /// new one.
    private func isCurrentSession(environmentID: String, generation: UInt64) -> Bool {
        sessions[environmentID]?.generation == generation
    }

    /// Internal lifecycle diagnostics (not public API). The deterministic
    /// interleaving tests use this predicate to drive a stop into a parked
    /// shape change instead of sleeping.
    struct LifecycleDiagnostics: Sendable, Equatable {
        var startInFlight: Bool
        var teardownInFlight: Bool
        var shapeChangeInFlight: Bool
    }

    func lifecycleDiagnostics(environmentID: String) -> LifecycleDiagnostics {
        LifecycleDiagnostics(
            startInFlight: startingEnvironments.contains(environmentID),
            teardownInFlight: teardownsInFlight.contains(environmentID),
            shapeChangeInFlight: isShapeChangeInFlight(environmentID: environmentID)
        )
    }

    /// Runs the result-carrying stop through the existential. Since C3,
    /// `completeStopResult` is a REQUIREMENT of
    /// `LinuxGuestRuntimeV2Integrating` (with a compatible default for legacy
    /// conformers), so the concrete integrator's real outcome — including
    /// `retainedForRepair` — is always reached here; the former
    /// `LinuxGuestRuntimeV2StopOutcomeReporting` adapter is folded into the
    /// protocol and deleted. Conformers that only implement the legacy void
    /// `completeStop` keep the truth-conservative `.unknown` default.
    private func runtimeV2StopOutcome(
        _ runtimeV2: any LinuxGuestRuntimeV2Integrating,
        environmentID: String,
        runtimeID: String,
        imageID: String,
        clean: Bool
    ) async -> RuntimeV2StopOutcome {
        await runtimeV2.completeStopResult(
            environmentID: environmentID, runtimeID: runtimeID, imageID: imageID, clean: clean
        )
    }

    /// Consumes Runtime v2's result-carrying stop (C2 `completeStopResult`). A
    /// stop whose delta capture failed is NEVER reported as a clean save: the
    /// environment surfaces repair-required (the store already refuses a fresh
    /// boot over the retained disk) and the caller must not claim "saved",
    /// "destroyed" or a normal restart. Returns true only when the stop may be
    /// reported as a clean, persisted shutdown.
    @discardableResult
    private func recordStopOutcome(
        _ outcome: RuntimeV2StopOutcome,
        environmentID: String,
        action: String,
        runtimeID: String
    ) -> Bool {
        switch outcome {
        case .captured, .noWorkingDisk, .unknown:
            return true
        case .retainedForRepair(let reason):
            lastErrors[environmentID] = "the guest stopped but its state could NOT be saved: \(reason)"
            lastImpacts[environmentID] =
                "\(action): \(environmentID) stopped, but its state was NOT saved cleanly; the working disk is retained for repair and a normal restart is refused until the repair completes"
            FloeLogger(category: .tools).error(
                "Linux guest stop persistence failed environment=\(environmentID) runtime=\(runtimeID): \(reason)"
            )
            return false
        case .notStopped:
            // The VM/threads were not confirmed stopped: the disk, lease and
            // slot stay owned and the existing quarantine message (set by the
            // caller) stays authoritative. Never claimed saved.
            if lastErrors[environmentID] == nil {
                lastErrors[environmentID] =
                    "the guest stop did not confirm; the working disk and lease are retained for recovery"
            }
            return false
        }
    }

    /// Starts the environment's guest. Returns false when the environment is
    /// not a Linux guest this service owns.
    @discardableResult
    public func start(environmentID: String, taskID: String?) async throws -> Bool {
        guard let descriptor = await environments.linuxGuestEnvironment(id: environmentID) else {
            return false
        }
        if teardownsInFlight.contains(environmentID) {
            throw LinuxGuestError.stopFailed(
                environmentID: environmentID,
                detail: "a stop is still in progress; this environment's disk is not reused until it finishes"
            )
        }
        if quarantinedEnvironments.contains(environmentID) {
            // The previous VM never confirmed its stop: booting another VM on
            // the same writable disk would corrupt it. Retry stopGuest.
            throw LinuxGuestError.stopFailed(
                environmentID: environmentID,
                detail: "the previous guest is still running after a failed stop; retry stopGuest and wait for it to succeed, nothing was started"
            )
        }
        if isShapeChangeInFlight(environmentID: environmentID) {
            // A shape/RAM change is between its stop and its restart on this
            // environment: the VM is intentionally down and its handle is
            // owned by that operation. Starting here would either fight the
            // restart or register a handle the reshape would then overwrite;
            // the caller waits for the shape change to finish.
            throw LinuxGuestError.guestBusy(environmentID: environmentID)
        }
        if let existing = sessions[environmentID], await existing.handle.isRunning() {
            return true
        }
        if sessions[environmentID] != nil {
            // A dead handle from an earlier run: release its channel and
            // admission slot before this start replaces it, so a stale VM is
            // never double-counted.
            await teardown(environmentID: environmentID, action: "restart")
        }
        // Own the environment's start from BEFORE the heavy-runtime wait so a
        // stop that lands while this start is queued for inference idle (or
        // for an unverified resident model) reaches it: teardown sees the
        // in-flight start, records the stop and cancels the queued admission
        // instead of mistaking it for "nothing to stop" and letting the
        // guest boot later.
        guard startingEnvironments.insert(environmentID).inserted else {
            throw LinuxGuestError.guestBusy(environmentID: environmentID)
        }
        pendingStops.remove(environmentID)
        var sessionRegistered = false
        var quarantinedByFailure = false
        var admissionOwned = false
        defer {
            startingEnvironments.remove(environmentID)
            pendingStops.remove(environmentID)
            // Only a start that actually published an admission reservation
            // releases one — later failures release exactly this start's
            // slot, while an early refusal (or a quarantined environment
            // checked above) never clears another owner's reservation. A
            // failed start whose VM refused to stop keeps its reservation:
            // the quarantined session still owns the environment's disk.
            if !sessionRegistered, !quarantinedByFailure, admissionOwned {
                guestReservations[environmentID] = nil
                clearReservation(environmentID: environmentID)
            }
        }
        // Linux and the on-device MLX runtime share one heavy-memory budget:
        // the arbiter admits this start atomically with its idle check (a
        // racing local-model probe sees the pending start, never an empty
        // snapshot), queues it behind an active session or an unverified
        // resident model, and verifies the model's physical release before
        // the queue is released. The registration release is installed
        // before the await, so even a cancelled wait cannot leak a
        // pending-start registration.
        defer { HeavyRuntimeArbiter.shared.releaseLinuxStart(environmentID: environmentID) }
        try await HeavyRuntimeArbiter.shared.waitForLocalInferenceIdle(registeringStart: environmentID)
        if pendingStops.remove(environmentID) != nil {
            // The stop landed while this start was queued; nothing was
            // booted and the defer above releases the admission.
            throw LinuxGuestError.startFailed("the guest start was stopped before it completed")
        }

        // Admission. Runtime v2 (when configured) admits through the pool on
        // all three axes (vCPU/RAM/VM): at most four VMs run and further
        // starts queue — cancellable, with a bounded wait — instead of
        // failing immediately. The B4 release gate is applied while the
        // loose descriptor values become a typed request: an explicit
        // request for an unqualified shape (two/six cores in this
        // single-core release) fails with an actionable error BEFORE any
        // disk work, regardless of the image manifest's `smp` flag, while
        // an auto plan that explicitly authorized a single-core floor is
        // admitted at one hart with an honest recorded downgrade. The
        // legacy path keeps the bounded refusal. Either way the budget is
        // bound here, before the image is verified and before any disk
        // work, so a refusal never touches the environment's persistent
        // disk.
        //
        // SMP engine capability and image-manifest claims are never the
        // release authority: only the pool's frozen GuestReleaseShapePolicy
        // is, and this release ships one hart (cloud run 35851127603).
        var admission: RuntimeV2Admission?
        var grantedVCPUs: Int?
        do {
            if let runtimeV2 {
                let runtimeID = Self.makeRuntimeID(environmentID: environmentID)
                let requestedShape = try Self.typedStartShape(
                    descriptor: descriptor,
                    clampedRAMMB: limits.clampedRAMMB(descriptor.ramMB),
                    releasePolicy: releasePolicy
                )
                // A descriptor start is either an explicit persisted choice
                // (strict: an unqualified second core must fail, never boot
                // one silently) or the nil worker default, which already
                // resolves to one hart. A genuine advisory plan that asked
                // for two harts reaches acquireShape as a typed
                // `.recommendation` request with the caller's OWN
                // `.authorized(vcpuFloor: .one)` policy; the pool records
                // that downgrade. It is never invented here from a loose int.
                let downgrade: GuestShapeDowngradePolicy
                switch requestedShape.origin {
                case .recommendation:
                    downgrade = .authorized(vcpuFloor: .one, memoryFloor: .m256)
                case .environmentPolicy, .userSpecified, .workerDefault:
                    downgrade = .strict
                }
                let imageSMPCapable = await runtimeV2.imageSMPCapable(imageID: descriptor.imageID)
                let granted = try await runtimeV2.acquireShape(
                    environmentID: environmentID,
                    runtimeID: runtimeID,
                    request: requestedShape,
                    imageSMPCapable: imageSMPCapable,
                    downgrade: downgrade
                )
                admission = RuntimeV2Admission(
                    runtimeID: granted.runtimeID,
                    ramMB: granted.ramMB,
                    downgraded: granted.downgraded
                )
                grantedVCPUs = granted.vcpus
                guestReservations[environmentID] = granted.ramMB
                admissionOwned = true
                publishReservation(environmentID: environmentID, ramMB: granted.ramMB)
            } else {
                try reserveGuestCapacity(
                    environmentID: environmentID,
                    ramMB: limits.clampedRAMMB(descriptor.ramMB)
                )
                admissionOwned = true
            }
            try await performStart(
                environmentID: environmentID,
                descriptor: descriptor,
                taskID: taskID,
                admission: admission,
                grantedVCPUs: grantedVCPUs,
                sessionRegistered: &sessionRegistered,
                quarantinedByFailure: &quarantinedByFailure
            )
        } catch {
            if let runtimeV2, let admission {
                if quarantinedByFailure {
                    // The VM survived a failed start/stop: the working disk,
                    // the lease and the pool slot stay owned, exactly like
                    // the legacy quarantine reservation.
                    let outcome = await runtimeV2StopOutcome(
                        runtimeV2, environmentID: environmentID, runtimeID: admission.runtimeID,
                        imageID: descriptor.imageID, clean: false
                    )
                    recordStopOutcome(
                        outcome, environmentID: environmentID, action: "start cleanup",
                        runtimeID: admission.runtimeID
                    )
                } else if !sessionRegistered {
                    let outcome = await runtimeV2StopOutcome(
                        runtimeV2, environmentID: environmentID, runtimeID: admission.runtimeID,
                        imageID: descriptor.imageID, clean: true
                    )
                    recordStopOutcome(
                        outcome, environmentID: environmentID, action: "start cleanup",
                        runtimeID: admission.runtimeID
                    )
                    await runtimeV2.releaseSlot(
                        environmentID: environmentID, runtimeID: admission.runtimeID
                    )
                }
            }
            throw error
        }
        return true
    }

    /// Runtime v2 working-directory identifier (runtime/vm/<runtimeID>).
    private static func makeRuntimeID(environmentID: String) -> String {
        "rt-\(environmentID)-\(UUID().uuidString.lowercased().prefix(8))"
    }

    /// Converts a descriptor's loose shape into the typed request under the
    /// AUTHORITATIVE release gate (B4). The descriptor carries no trustworthy
    /// auto/explicit provenance, so the distinction is structural:
    ///  * `vcpus == nil` is the worker/auto default — one hart (origin
    ///    `.workerDefault`); no downgrade is implied or recorded because no
    ///    larger shape was ever requested.
    ///  * `vcpus != nil` is an EXPLICIT persisted choice (environment policy,
    ///    manifest or user) and is admitted strictly: an unqualified count
    ///    (two in this release) throws `releaseShapeUnsupported`, and a
    ///    malformed count (0, six, …) throws an invalid-configuration error —
    ///    never clamped onto another shape, regardless of the image
    ///    manifest's `smp` claim.
    /// A genuine automatic recommendation (GuestResourceAdvisory) that
    /// planned two harts reaches `acquireShape` as a TYPED
    /// `GuestResourceRequest(origin: .recommendation)` whose caller chooses
    /// the authorized single-core floor; that recorded downgrade is granted
    /// by the pool/integrator, never invented here from a loose integer.
    private static func typedStartShape(
        descriptor: LinuxGuestEnvironmentDescriptor,
        clampedRAMMB: Int,
        releasePolicy: GuestReleaseShapePolicy
    ) throws -> GuestResourceRequest {
        let memory = GuestMemoryMiB.smallestHolding(max(0, clampedRAMMB)) ?? .m2048
        guard let requestedVCPUs = descriptor.vcpus else {
            return GuestResourceRequest(vcpus: .one, memory: memory, origin: .workerDefault)
        }
        let vcpus: GuestVCPUCount
        do {
            vcpus = try releasePolicy.resolve(requestedVCPUs: requestedVCPUs)
        } catch GuestReleaseShapeError.invalidVCPUCount {
            throw LinuxGuestError.invalidConfiguration(
                "the guest descriptor for \(descriptor.id) carries an invalid core count \(requestedVCPUs); no guest was started"
            )
        } catch GuestReleaseShapeError.unsupportedReleaseVCPUCount {
            throw LinuxGuestError.releaseShapeUnsupported(
                requested: requestedVCPUs,
                maximum: releasePolicy.maximumSupportedVCPUs
            )
        }
        return GuestResourceRequest(vcpus: vcpus, memory: memory, origin: .environmentPolicy)
    }

    /// The body of `start` once admission is granted. Split out so every
    /// failure path funnels through the admission cleanup in `start`.
    private func performStart(
        environmentID: String,
        descriptor: LinuxGuestEnvironmentDescriptor,
        taskID: String?,
        admission: RuntimeV2Admission?,
        grantedVCPUs: Int?,
        sessionRegistered: inout Bool,
        quarantinedByFailure: inout Bool
    ) async throws {
        guard let image = await images.linuxGuestImage(id: descriptor.imageID) else {
            let reason = "no guest image manifest for id '\(descriptor.imageID)'"
            lastErrors[environmentID] = reason
            throw LinuxGuestError.imageNotQualified(environmentID: environmentID, reason: reason)
        }
        // Digest verification is the gate that makes a manifest's `qualified`
        // flag meaningful: a hand-written flag with no matching artifact bytes
        // is rejected here, before any VM is created.
        if let failure = await images.linuxGuestImageVerificationFailure(id: descriptor.imageID) {
            lastErrors[environmentID] = failure
            throw LinuxGuestError.imageNotQualified(environmentID: environmentID, reason: failure)
        }

        // Boot artifacts resolve against the Runtime v2 expanded (verified,
        // rebuildable) image directory when the substrate is configured,
        // else against the legacy images root.
        let imageDirectory: URL?
        if let runtimeV2 {
            imageDirectory = try await runtimeV2.expandedImageDirectory(imageID: descriptor.imageID)
        } else {
            imageDirectory = images.imageRoot?.appendingPathComponent(descriptor.imageID, isDirectory: true)
        }
        if let failure = image.qualificationFailure(imageDirectory: imageDirectory) {
            lastErrors[environmentID] = failure
            throw LinuxGuestError.imageNotQualified(environmentID: environmentID, reason: failure)
        }

        // The verified manifest is not what the C engine can boot: its paths
        // are relative to the image directory (the app has no usable cwd) and
        // its disk is the shared, immutable base. Runtime v2 boots from a
        // working disk materialized under the temporary runtime/vm/<runtimeID>
        // (verified base clone + system delta); the legacy path prepares (or
        // reuses) the environment's own writable disk copy under its layer. A
        // resolver without an image root is the in-memory test seam and
        // cannot verify digests; the app never assembles one.
        var bootDescriptor = descriptor
        if let admission { bootDescriptor.ramMB = admission.ramMB }
        // The granted shape is what the machine is created with (the engine
        // reads vcpus/ramMB at create time): an authorized or image-gated
        // downgrade is reflected in the boot descriptor, never silently.
        if let grantedVCPUs { bootDescriptor.vcpus = grantedVCPUs }
        let runtimeImage: LinuxGuestImage
        var workingDiskCapacity: Int64?
        if let runtimeV2, let admission, let imageDirectory {
            do {
                let work = try await runtimeV2.prepareWorkingDisk(
                    environmentID: environmentID,
                    runtimeID: admission.runtimeID,
                    imageID: descriptor.imageID,
                    legacyWritableDirectory: descriptor.writableDirectory,
                    targetCapacityBytes: targetDiskCapacityBytes
                )
                workingDiskCapacity = work.capacityBytes
                let dataDirectory = try await runtimeV2.environmentDataDirectory(
                    environmentID: environmentID
                )
                bootDescriptor.shares.removeAll { $0.tag == LinuxGuestShare.environmentTag }
                bootDescriptor.shares.insert(
                    LinuxGuestShare(tag: LinuxGuestShare.environmentTag, hostDirectory: dataDirectory),
                    at: 0
                )
                runtimeImage = try Self.v2BootImage(
                    image: image, imageDirectory: imageDirectory, workingDisk: work.diskURL
                )
            } catch {
                lastErrors[environmentID] = error.localizedDescription
                throw error
            }
        } else if let imageDirectory {
            do {
                runtimeImage = try LinuxGuestRuntimeImagePreparer().prepare(
                    image: image,
                    imageDirectory: imageDirectory,
                    environmentID: environmentID,
                    writableDirectory: descriptor.writableDirectory,
                    targetCapacityBytes: targetDiskCapacityBytes
                )
            } catch {
                lastErrors[environmentID] = error.localizedDescription
                throw error
            }
        } else {
            runtimeImage = image
        }

        // Every 9P export must exist before the TinyEMU configuration is
        // validated. This also repairs Build 221 installs whose retained
        // workspace reference points at an app-owned directory not yet made.
        for share in bootDescriptor.shares {
            try FileManager.default.createDirectory(
                at: share.hostDirectory, withIntermediateDirectories: true
            )
        }
        let handle = try factory.makeSession(descriptor: bootDescriptor, image: runtimeImage, limits: limits)
        do {
            try await handle.start()
        } catch {
            lastErrors[environmentID] = error.localizedDescription
            quarantinedByFailure = await abandonFailedStart(
                environmentID: environmentID,
                descriptor: bootDescriptor,
                image: runtimeImage,
                handle: handle,
                channel: nil,
                taskID: taskID,
                error: error,
                runtimeID: admission?.runtimeID
            )
            throw error
        }

        let channel = LinuxGuestCommandChannel(transport: handle.transport, limits: limits)
        // Optional guest → host control bridge: install the app's handler for
        // this environment's final share table BEFORE the first HELLO. The
        // channel only advertises the capability while a handler is
        // installed, so the handshake truthfully tells the guest what the
        // host will serve (and an environment without shares upgrades or
        // starts with the capability unadvertised).
        if let factory = hostRequestHandlerRegistry.current() {
            let pathMap = LinuxGuestPathMap(shares: bootDescriptor.shares)
            if !pathMap.isEmpty, let handler = factory(environmentID, pathMap) {
                await channel.installHostRequestHandler(handler)
            }
        }
        // The channel the session will use. A runner upgrade reboots the guest
        // and returns a fresh channel over the renewed console stream; without
        // an upgrade the probed channel itself is the live one.
        var sessionChannel = channel
        var negotiatedCapabilities: String?
        if descriptor.writableDirectory != nil || admission != nil {
            do {
                // Persistent-disk runner upgrade: the disk is a mutable clone,
                // so a new catalog image does not change the runner inside it.
                // Probe the booted runner; when it predates protocol 3 and the
                // image ships a verified runner artifact, replace
                // /usr/local/bin/floe-exec in the guest from those bytes
                // (preserving every installed package and file) and reboot
                // into the new runner. Without an artifact the start fails with
                // an actionable upgrade error — a stale runner is never used
                // silently.
                let current = try await ensureGuestRunnerCurrent(
                    descriptor: bootDescriptor,
                    image: image,
                    imageDirectory: imageDirectory,
                    handle: handle,
                    channel: channel
                )
                sessionChannel = current.channel
                negotiatedCapabilities = current.capabilities
                // Extend the ext4 filesystem to the host-grown container
                // capacity (grow-only). Idempotent; a failure is recorded as
                // a repair state, not a start failure — the guest remains
                // usable at its previous capacity.
                switch await ensureGuestFilesystemCapacity(
                    descriptor: bootDescriptor,
                    channel: sessionChannel,
                    capacityOverride: workingDiskCapacity
                ) {
                case .none:
                    break
                case .ok:
                    diskResizeFailures[environmentID] = nil
                case .failed(let detail):
                    diskResizeFailures[environmentID] = detail
                    lastErrors[environmentID] = detail
                }
            } catch {
                lastErrors[environmentID] = error.localizedDescription
                quarantinedByFailure = await abandonFailedStart(
                    environmentID: environmentID,
                    descriptor: bootDescriptor,
                    image: runtimeImage,
                    handle: handle,
                    channel: channel,
                    taskID: taskID,
                    error: error,
                    runtimeID: admission?.runtimeID
                )
                throw error
            }
        }
        if pendingStops.remove(environmentID) != nil {
            let stopError = LinuxGuestError.startFailed("the guest start was stopped before it completed")
            lastErrors[environmentID] = stopError.localizedDescription
            quarantinedByFailure = await abandonFailedStart(
                environmentID: environmentID,
                descriptor: bootDescriptor,
                image: runtimeImage,
                handle: handle,
                channel: sessionChannel,
                taskID: taskID,
                error: stopError,
                runtimeID: admission?.runtimeID
            )
            throw stopError
        }

        var session = Session(
            descriptor: bootDescriptor,
            image: runtimeImage,
            handle: handle,
            channel: sessionChannel,
            startedAt: Date(),
            taskID: taskID,
            forwards: [],
            runtimeID: admission?.runtimeID,
            networkStatus: LinuxGuestNetworkStatus.from(capabilities: negotiatedCapabilities),
            generation: nextSessionGeneration()
        )
        do {
            // Requested forwards are part of the start contract: if the
            // engine cannot honor them, the caller must hear it now.
            guard descriptor.serviceForwards.count <= limits.maxServiceForwards else {
                throw LinuxGuestError.invalidConfiguration(
                    "at most \(limits.maxServiceForwards) host forwards are supported per guest"
                )
            }
            for forward in descriptor.serviceForwards {
                try handle.addForward(forward)
                session.forwards.append(forward)
            }
        } catch {
            lastErrors[environmentID] = error.localizedDescription
            quarantinedByFailure = await abandonFailedStart(
                environmentID: environmentID,
                descriptor: bootDescriptor,
                image: runtimeImage,
                handle: handle,
                channel: channel,
                taskID: taskID,
                error: error,
                runtimeID: admission?.runtimeID
            )
            throw error
        }
        sessions[environmentID] = session
        sessionRegistered = true
        lastErrors[environmentID] = nil
        FloeLogger(category: .tools).info(
            "Linux guest started environment=\(environmentID) image=\(image.id) ramMB=\(limits.clampedRAMMB(bootDescriptor.ramMB)) activeGuests=\(guestReservations.count) reservedRAMMB=\(reservedGuestRAMMB) network=\(session.networkStatus?.rawValue ?? "unknown")"
        )
        if let network = session.networkStatus, !network.isReady, let diagnostic = network.diagnostic {
            // The guest still starts: local shell/file work is valid. The
            // degraded network is recorded and surfaced, never smoothed over.
            lastErrors[environmentID] = "Linux guest network \(network.rawValue): \(diagnostic)"
        }
    }

    /// Builds the bootable image for a Runtime v2 start: boot artifacts
    /// resolve to absolute files inside the verified expanded image
    /// directory; the disk is this run's working disk (temporary
    /// runtime/vm/<runtimeID>/disk.img), never the shared immutable base.
    private static func v2BootImage(
        image: LinuxGuestImage,
        imageDirectory: URL,
        workingDisk: URL
    ) throws -> LinuxGuestImage {
        var runtime = image
        runtime.biosPath = try LinuxGuestRuntimeImagePreparer.resolveArtifact(
            path: image.biosPath, role: "bios", imageDirectory: imageDirectory
        ).path
        if let kernelPath = image.kernelPath {
            runtime.kernelPath = try LinuxGuestRuntimeImagePreparer.resolveArtifact(
                path: kernelPath, role: "kernel", imageDirectory: imageDirectory
            ).path
        }
        if let initrdPath = image.initrdPath {
            runtime.initrdPath = try LinuxGuestRuntimeImagePreparer.resolveArtifact(
                path: initrdPath, role: "initrd", imageDirectory: imageDirectory
            ).path
        }
        if image.diskPath != nil {
            runtime.diskPath = workingDisk.path
            runtime.diskReadWrite = true
        }
        return runtime
    }

    // MARK: persistent-disk runner upgrade

    /// Ensures the runner booted inside this environment's persistent disk
    /// matches the protocol this build speaks, and returns the channel the
    /// session must use. The disk is a mutable clone of the verified base, so
    /// a catalog image update alone never changes the runner inside it; this
    /// path upgrades the runner in-guest from the image's verified standalone
    /// runner artifact, preserving every installed package and file, or fails
    /// with an actionable error.
    ///
    /// Console ownership: a TinyEMU VM has exactly ONE immutable console
    /// stream and the channel has exactly one router reading it. Cancelling
    /// that reader finishes the stream for good (a replacement iterator then
    /// sees nil), so the upgrade runs on the very channel the session will
    /// use — never a second reader, never a released-then-reused stream:
    ///
    ///  1. Probe the *live* runner with FLOE-HELLO on the production channel.
    ///     The runner-upgrade ledger is a record, never a substitute for this
    ///     probe: a disk upgraded elsewhere still has to answer.
    ///  2. A protocol-3 answer means the disk is current; the session keeps
    ///     this channel.
    ///  3. Otherwise (legacy runner): require the image's verified
    ///     `runnerArtifact` + `runnerCapabilities`, switch the one channel
    ///     into legacy serial mode (`enterLegacySerialMode`: no HELLO, one
    ///     exchange at a time, same reader) and run the upgrade. Every step
    ///     is awaited one at a time and no other caller can reach the channel
    ///     while the start is in flight.
    ///  4. Stage the runner bytes in-guest (through the environment's real 9p
    ///     share when it is mapped, chunked console upload otherwise), verify
    ///     the digest inside the guest, replace /usr/local/bin/floe-exec with
    ///     a same-directory rename, then reboot with a host-side stop + start.
    ///     `stop()` does not finish the console stream and the single router
    ///     keeps reading, so the rebooted output reaches the same reader.
    ///  5. At the reboot boundary `resetRouterState()` drops the old boot's
    ///     routing state and `leaveLegacySerialMode()` restores negotiation;
    ///     only after the rebooted runner answers CAPS equal to the manifest's
    ///     expectation is the channel handed to the session. Any failure
    ///     leaves the persistent disk in place with an honest error and the
    ///     caller closes the VM.
    private func ensureGuestRunnerCurrent(
        descriptor: LinuxGuestEnvironmentDescriptor,
        image: LinuxGuestImage,
        imageDirectory: URL?,
        handle: LinuxGuestSessionHandle,
        channel: LinuxGuestCommandChannel
    ) async throws -> (channel: LinuxGuestCommandChannel, capabilities: String) {
        let environmentID = descriptor.id
        let expected = image.runnerCapabilities?.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Live probe. A legacy runner never answers, so the probe is
        // bounded and returns nil rather than hanging.
        if let capabilities = try await channel.probeCapabilities(
            timeout: limits.runnerProbeTimeout, requireCurrentProtocol: false
        ), isCurrentProtocol(capabilities) {
            try await channel.acceptExternalNegotiation(capabilities: capabilities)
            // Keep the ledger truthful for diagnostics, but it is written
            // only because the live runner answered; it is never read as
            // proof that the runner is current. The host-advertised echo is
            // excluded from the identity comparison (see runnerIdentity).
            if let expected, runnerIdentity(of: expected) == runnerIdentity(of: capabilities) {
                await recordRunnerLedger(
                    capabilities,
                    descriptor: descriptor
                )
            }
            return (channel, capabilities)
        }

        // 2. Legacy runner. Without a verified artifact there is no safe
        // upgrade; fail with an actionable error rather than booting a runner
        // that cannot route concurrent tokens.
        guard let artifact = image.runnerArtifact else {
            throw LinuxGuestError.runnerUpgradeRequired(
                required: "protocol 3 runner (image '\(image.id)' ships no verified runner upgrade artifact)",
                found: "legacy pre-protocol-3 runner inside the environment disk"
            )
        }
        guard artifact.role == .runner else {
            throw LinuxGuestError.runnerUpgradeRequired(
                required: "protocol 3 runner (image '\(image.id)' declares its runner artifact with the 'runner' role, not '\(artifact.role.rawValue)')",
                found: "legacy pre-protocol-3 runner inside the environment disk"
            )
        }
        guard let expected, !expected.isEmpty else {
            throw LinuxGuestError.runnerUpgradeRequired(
                required: "protocol 3 runner (image '\(image.id)' records no runnerCapabilities payload)",
                found: "legacy pre-protocol-3 runner inside the environment disk"
            )
        }
        guard let imageDirectory else {
            throw LinuxGuestError.runnerUpgradeRequired(
                required: "protocol 3 runner",
                found: "legacy runner, and this resolver cannot verify the upgrade artifact bytes"
            )
        }
        // Same containment/symlink/size/digest checks as the boot artifacts;
        // nothing is loaded from an unverified path.
        let runnerData = try LinuxGuestRuntimeImagePreparer.loadVerifiedArtifact(
            artifact,
            imageDirectory: imageDirectory,
            role: "runner upgrade artifact"
        )

        // 3. Switch the one channel into legacy serial mode (no HELLO, one
        // exchange at a time) while keeping its console reader: cancelling a
        // for-await reader would finish the transport's AsyncStream for good,
        // so this is a policy change, not a reader handoff.
        do {
            try await channel.enterLegacySerialMode()
        } catch {
            throw LinuxGuestError.runnerUpgradeRequired(
                required: expected,
                found: "the guest channel is not idle for the runner upgrade"
            )
        }
        try await installRunnerInGuest(
            channel: channel,
            descriptor: descriptor,
            runnerData: runnerData,
            digest: artifact.sha512.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )

        // 4. Reboot on the same stream: the host stops and starts the VM, and
        // because stop() does not finish the console stream the single router
        // keeps reading the new boot. Router protocol state from the old boot
        // (buffered partial frames, section owner, dead token streams) is
        // dropped at the boundary before the new runner may answer.
        await handle.stop()
        try await handle.start()
        await channel.resetRouterState()
        await channel.leaveLegacySerialMode()

        // 5. The rebooted runner must answer on the same reader with exactly
        // the contract the manifest declared.
        let rebootProbeTimeout = max(15, limits.runnerProbeTimeout)
        guard let capabilities = try await channel.probeCapabilities(
            timeout: rebootProbeTimeout, requireCurrentProtocol: false
        ), isCurrentProtocol(capabilities) else {
            throw LinuxGuestError.runnerUpgradeRequired(
                required: expected,
                found: "the guest rebooted but the runner still does not answer protocol 3"
            )
        }
        guard runnerIdentity(of: capabilities) == runnerIdentity(of: expected) else {
            throw LinuxGuestError.startFailed(
                "runner upgraded but reports '\(capabilities)', manifest expects '\(expected)'"
            )
        }
        try await channel.acceptExternalNegotiation(capabilities: capabilities)
        await recordRunnerLedger(capabilities, descriptor: descriptor, required: true)
        FloeLogger(category: .tools).info(
            "Linux guest runner upgraded in place environment=\(environmentID) caps=\(capabilities)"
        )
        return (channel, capabilities)
    }

    // MARK: persistent-disk ext4 resize

    private enum GuestFilesystemResizeResult: Sendable {
        /// No persistent disk was prepared by this build: nothing to do.
        case none
        /// Resize ran (no-op or successful extension).
        case ok
        /// Resize could not run or failed; the guest keeps its old capacity.
        case failed(String)
    }

    /// Extends the ext4 filesystem to the host-grown raw-container capacity
    /// right after the runner is current. Only runs when the host sidecar
    /// records a prepared logical capacity. A failure is non-fatal: the guest
    /// remains usable at its prior capacity and the UI shows a repair state.
    private func ensureGuestFilesystemCapacity(
        descriptor: LinuxGuestEnvironmentDescriptor,
        channel: LinuxGuestCommandChannel,
        capacityOverride: Int64? = nil
    ) async -> GuestFilesystemResizeResult {
        // The host-grown capacity comes from the Runtime v2 working disk
        // when configured, else from the legacy origin sidecar under the
        // environment layer. No capacity recorded → no resize attempt.
        let capacityBytes: Int64
        if let capacityOverride {
            capacityBytes = capacityOverride
        } else {
            guard let writable = descriptor.writableDirectory,
                  let origin = LinuxGuestRuntimeImagePreparer.diskOrigin(
                      writableDirectory: writable,
                      environmentID: descriptor.id
                  ) else {
                return .none
            }
            capacityBytes = origin.logicalCapacityBytes ?? 0
        }
        guard capacityBytes > 0 else { return .none }
        let result: LinuxCommandResult
        do {
            result = try await channel.run(
                argv: ["/bin/sh", "-c", LinuxGuestFilesystemResize.ensureScript()],
                timeout: 180,
                cancellation: nil
            )
        } catch {
            return .failed("the ext4 filesystem could not be resized to the 8 GiB disk capacity: \(error.localizedDescription)")
        }
        if result.exitCode == 0 { return .ok }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = detail.count > 300 ? String(detail.suffix(300)) : detail
        return .failed("the ext4 filesystem could not be resized to the 8 GiB disk capacity (exit \(result.exitCode)): \(tail)")
    }

    private func recordRunnerLedger(
        _ capabilities: String,
        descriptor: LinuxGuestEnvironmentDescriptor,
        required: Bool = false
    ) async {
        if let runtimeV2 {
            guard await runtimeV2.recordedRunnerCapabilities(environmentID: descriptor.id) != capabilities else {
                return
            }
            await runtimeV2.recordRunnerCapabilities(capabilities, environmentID: descriptor.id)
            return
        }
        guard let writable = descriptor.writableDirectory else { return }
        do {
            guard LinuxGuestRuntimeImagePreparer.recordedRunnerCapabilities(
                writableDirectory: writable, environmentID: descriptor.id
            ) != capabilities else { return }
            try LinuxGuestRuntimeImagePreparer.recordRunnerCapabilities(
                capabilities,
                writableDirectory: writable,
                environmentID: descriptor.id
            )
        } catch {
            if required {
                FloeLogger(category: .tools).error(
                    "Linux guest runner upgraded but the ledger could not be written environment=\(descriptor.id): \(error.localizedDescription)"
                )
            }
        }
    }

    /// Uploads/installs the verified runner inside the guest and returns only
    /// after the guest confirmed the replacement. Bounded by one overall
    /// deadline; the staging bytes are removed from the host share on every
    /// path.
    private func installRunnerInGuest(
        channel: LinuxGuestCommandChannel,
        descriptor: LinuxGuestEnvironmentDescriptor,
        runnerData: Data,
        digest: String
    ) async throws {
        // A guest runner is a small static executable; anything larger is a
        // manifest mistake, not a runner. The bound also caps the number of
        // console round trips the upgrade can make.
        let byteLimit = 8 * 1024 * 1024
        guard runnerData.count <= byteLimit else {
            throw LinuxGuestError.startFailed(
                "runner upgrade artifact is \(runnerData.count) bytes; refusing an upgrade larger than \(byteLimit) bytes"
            )
        }
        let deadline = Date().addingTimeInterval(300)
        let stagingDirectory = "/tmp/.floe-runner-upgrade"
        let stagedBinary = stagingDirectory + "/floe-exec.bin"

        _ = try await serialStep(
            channel,
            argv: ["/bin/sh", "-c", "rm -rf \(stagingDirectory) && mkdir -m 0700 -p \(stagingDirectory)"],
            deadline: deadline,
            stepTimeout: 30
        )

        var hostStaging: URL?
        var staged = false
        var shareFailure: String?
        if let writeRoot = descriptor.writableDirectory,
           let guestPath = stagedSharePath(writableDirectory: writeRoot, descriptor: descriptor) {
            do {
                let file = try stageRunnerOnShare(runnerData, writableDirectory: writeRoot)
                hostStaging = file
                let copy = try await serialStep(
                    channel,
                    argv: ["/bin/sh", "-c", "cp \(guestPath) \(stagedBinary) && chmod 0600 \(stagedBinary)"],
                    deadline: deadline,
                    stepTimeout: 60
                )
                staged = copy.exitCode == 0
                if !staged {
                    shareFailure = boundedDetail(copy.stderr)
                }
            } catch {
                staged = false
                shareFailure = error.localizedDescription
            }
            if let hostStaging {
                // The guest copy is complete (or failed): never leave the
                // staged bytes in the user's environment share.
                try? FileManager.default.removeItem(at: hostStaging)
                try? FileManager.default.removeItem(at: hostStaging.deletingLastPathComponent())
            }
        }
        if !staged {
            // Fallback: the environment share may not be mounted in this
            // guest (or there is no share at all). Upload the bytes through
            // the console in bounded chunks, then decode in the guest.
            let base64 = runnerData.base64EncodedString()
            let encodedPath = stagingDirectory + "/floe-exec.b64"
            _ = try await serialStep(
                channel,
                argv: ["/bin/sh", "-c", "rm -f \(encodedPath) && : > \(encodedPath)"],
                deadline: deadline,
                stepTimeout: 30
            )
            var offset = base64.startIndex
            var chunkIndex = 0
            while offset < base64.endIndex {
                let end = base64.index(offset, offsetBy: 30000, limitedBy: base64.endIndex) ?? base64.endIndex
                let chunk = String(base64[offset..<end])
                offset = end
                chunkIndex += 1
                let result = try await serialStep(
                    channel,
                    argv: ["/bin/sh", "-c", "printf '%s' '\(chunk)' >> \(encodedPath)"],
                    deadline: deadline,
                    stepTimeout: 60
                )
                guard result.exitCode == 0 else {
                    throw LinuxGuestError.startFailed(
                        "runner upload failed in guest at chunk \(chunkIndex): \(boundedDetail(result.stderr))"
                    )
                }
            }
            let decoded = try await serialStep(
                channel,
                argv: ["/bin/sh", "-c", "base64 -d \(encodedPath) > \(stagedBinary) && rm -f \(encodedPath) && chmod 0600 \(stagedBinary)"],
                deadline: deadline,
                stepTimeout: 60
            )
            guard decoded.exitCode == 0 else {
                throw LinuxGuestError.startFailed(
                    "runner upload could not be decoded inside the guest: \(boundedDetail(decoded.stderr))"
                )
            }
            staged = true
        }
        guard staged else {
            let shareDetail = shareFailure.map { " (share copy failed: \($0))" } ?? ""
            throw LinuxGuestError.startFailed("the runner artifact could not be staged inside the guest\(shareDetail)")
        }

        // Verify the staged bytes against the manifest digest *inside* the
        // guest, keep the replaced runner for recovery, and promote the new
        // binary with a same-directory rename so a crash can never leave a
        // half-written init binary at the live path.
        let install = """
        set -e
        actual=$(sha512sum \(stagedBinary) | cut -d' ' -f1)
        [ "$actual" = "\(digest)" ]
        chmod 0755 \(stagedBinary)
        cp -f \(LinuxGuestImage.runnerGuestPath) \(LinuxGuestImage.runnerGuestPath).prev
        sync
        cp -f \(stagedBinary) \(LinuxGuestImage.runnerGuestPath).new
        chmod 0755 \(LinuxGuestImage.runnerGuestPath).new
        sync
        mv -f \(LinuxGuestImage.runnerGuestPath).new \(LinuxGuestImage.runnerGuestPath)
        sync
        rm -rf \(stagingDirectory)
        echo floe-runner-installed
        """
        let result = try await serialStep(
            channel,
            argv: ["/bin/sh", "-c", install],
            deadline: deadline,
            stepTimeout: 120
        )
        guard result.exitCode == 0 else {
            throw LinuxGuestError.startFailed(
                "in-guest runner replacement failed (exit \(result.exitCode)): \(boundedDetail(result.stderr))"
            )
        }
    }

    /// Runs one bounded exchange on the channel's single reader, refusing to
    /// start work after the
    /// upgrade deadline. `stepTimeout` is additionally clamped to the time
    /// left, so the whole sequence finishes inside one finite budget.
    private func serialStep(
        _ channel: LinuxGuestCommandChannel,
        argv: [String],
        deadline: Date,
        stepTimeout: TimeInterval
    ) async throws -> LinuxCommandResult {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 1 else {
            throw LinuxGuestError.startFailed("the runner upgrade did not finish inside its 300 second budget; the persistent disk is unchanged")
        }
        do {
            return try await channel.run(
                argv: argv,
                timeout: min(stepTimeout, remaining),
                cancellation: nil
            )
        } catch let error as LinuxGuestError {
            if case .timedOut = error {
                throw LinuxGuestError.startFailed("a runner upgrade step timed out; the persistent disk is unchanged")
            }
            throw error
        }
    }

    private func boundedDetail(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
    }

    /// Host-side staging next to the environment's persistent layer: the
    /// layer is the guest's `floe-env` share (`/floe/env`), so the guest can
    /// copy the bytes directly instead of receiving them over the console.
    /// Returns the host URL to remove afterwards, or nil when the descriptor
    /// has no share that maps this directory.
    private func stageRunnerOnShare(
        _ runnerData: Data,
        writableDirectory: URL
    ) throws -> URL {
        let directory = writableDirectory
            .appendingPathComponent(".floe-runner-upgrade", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("floe-exec-riscv64")
        try runnerData.write(to: file, options: .atomic)
        // The guest's 9p mount must be able to read it; the host file mode is
        // irrelevant to the guest root, but the digest is re-checked in-guest
        // anyway.
        return file
    }

    /// Guest path of the staged runner when the environment's writable
    /// directory is exported as a 9p share, nil otherwise. Only a path inside
    /// the share maps (the path map rejects escapes), and only characters
    /// that cannot break the shell script are accepted.
    private func stagedSharePath(
        writableDirectory: URL,
        descriptor: LinuxGuestEnvironmentDescriptor
    ) -> String? {
        guard let guestRoot = LinuxGuestPathMap(shares: descriptor.shares).environmentGuestRoot else { return nil }
        let hostPath = writableDirectory
            .appendingPathComponent(".floe-runner-upgrade", isDirectory: true)
            .appendingPathComponent("floe-exec-riscv64")
            .path
        guard let guestPath = LinuxGuestPathMap(shares: descriptor.shares).guestPath(forHostPath: hostPath),
              guestPath.hasPrefix(guestRoot + "/") else { return nil }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-")
        guard guestPath.allSatisfy({ allowed.contains($0) }) else { return nil }
        return guestPath
    }

    private func isCurrentProtocol(_ capabilities: String) -> Bool {
        for field in capabilities.split(separator: " ") where field.hasPrefix("protocol=") {
            if let value = Int(field.dropFirst("protocol=".count)) {
                return value >= 3
            }
        }
        return false
    }

    /// Runner-owned fields of a CAPS payload, for identity comparison. The
    /// `hostArchive=` field is the runner echoing whatever the host
    /// advertised in HELLO: it changes when this host starts or stops
    /// advertising the optional guest bridge, so comparing it verbatim would
    /// reject a manifest recorded against a different host advertisement even
    /// though the runner is exactly the expected one.
    private func runnerIdentity(of capabilities: String) -> String {
        capabilities.split(separator: " ")
            .filter { !$0.hasPrefix("hostArchive=") }
            .joined(separator: " ")
    }

    public func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        guard let session = sessions[environmentID], await session.handle.isRunning() else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        // The command is real activity on this guest: a scoped transient
        // release must wait for it instead of tearing the guest down under it.
        beginActiveCommand(environmentID: environmentID)
        defer { endActiveCommand(environmentID: environmentID) }
        do {
            return try await session.channel.run(
                argv: argv,
                workingDirectory: workingDirectory,
                standardInput: standardInput,
                timeout: timeout,
                maxOutputBytes: maxOutputBytes,
                cancellation: cancellation
            )
        } catch {
            lastErrors[environmentID] = error.localizedDescription
            if await session.channel.isPoisoned {
                // The guest may still be executing an interrupted command;
                // its state is unknown, so the session is torn down rather
                // than reused for the next caller.
                await stop(environmentID: environmentID)
            }
            throw error
        }
    }

    /// Marks one in-flight command on an environment (synchronous, actor
    /// isolated, so a release that checks inside the actor observes it).
    private func beginActiveCommand(environmentID: String) {
        activeCommands[environmentID, default: 0] += 1
    }

    private func endActiveCommand(environmentID: String) {
        guard let count = activeCommands[environmentID] else { return }
        if count <= 1 {
            activeCommands[environmentID] = nil
        } else {
            activeCommands[environmentID] = count - 1
        }
    }

    public func stop(environmentID: String) async {
        await teardown(environmentID: environmentID, action: "stop")
    }

    /// Stops the guest and discards only runtime state. The environment's
    /// persistent disk image, 9p shares and image manifest are preserved, so
    /// the next start boots the same disk fresh. Other environments — guests,
    /// disks, forwards — are never touched by one environment's reset.
    public func reset(environmentID: String) async {
        await teardown(environmentID: environmentID, action: "reset")
    }

    /// Cleans up a start that failed after its VM was created. Closing the
    /// handle *is* a stop attempt, so the same contract as stopGuest applies:
    /// if the engine's stop budget elapses while the run loop is still alive,
    /// the handle is not orphaned — it is retained as a quarantined session
    /// with its admission reservation, so a later stop can recover it and no
    /// new guest can boot on the same writable disk. Returns true when the
    /// guest is quarantined.
    private func abandonFailedStart(
        environmentID: String,
        descriptor: LinuxGuestEnvironmentDescriptor,
        image: LinuxGuestImage,
        handle: LinuxGuestSessionHandle,
        channel: LinuxGuestCommandChannel?,
        taskID: String?,
        error: Error,
        runtimeID: String? = nil
    ) async -> Bool {
        if let channel { await channel.close() }
        await handle.close()
        guard await handle.isRunning() else { return false }
        // The VM survived the close: own it instead of leaking it. The
        // retained channel (never used if there was none) only exists so a
        // later teardown can close the transport again.
        let retainedChannel = channel ?? LinuxGuestCommandChannel(transport: handle.transport, limits: limits)
        sessions[environmentID] = Session(
            descriptor: descriptor,
            image: image,
            handle: handle,
            channel: retainedChannel,
            startedAt: Date(),
            taskID: taskID,
            forwards: [],
            runtimeID: runtimeID,
            generation: nextSessionGeneration()
        )
        quarantinedEnvironments.insert(environmentID)
        lastErrors[environmentID] =
            "the guest failed to start (\(error.localizedDescription)) and is still running; retry stopGuest (the persistent disk is preserved and no new guest will start on it)"
        lastImpacts[environmentID] =
            "start failed: \(environmentID) is STILL RUNNING (the VM refused to stop); the persistent disk and shares are preserved, the guest is quarantined and no new guest may start on this disk"
        FloeLogger(category: .tools).error(
            "Linux guest start failed and could not be destroyed environment=\(environmentID): \(error.localizedDescription); quarantined"
        )
        return true
    }

    private func teardown(environmentID: String, action: String) async {
        // A stop request that lands while this environment's start is in
        // flight cannot tear down a session that does not exist yet: the
        // start observes the flag and destroys its own handle instead of
        // registering a guest the caller already asked to stop. A start that
        // is still queued for heavy-runtime admission is cancelled right here
        // — it must not hold the stop until the model happens to finish —
        // and its own defer releases the arbiter registration.
        if startingEnvironments.contains(environmentID) {
            pendingStops.insert(environmentID)
            HeavyRuntimeArbiter.shared.cancelLinuxStart(environmentID: environmentID)
        }
        // One teardown per environment: a second stop call while the first is
        // awaiting close must not race it, and a start must not slip past the
        // removed session (see start's teardownsInFlight guard).
        guard teardownsInFlight.insert(environmentID).inserted else {
            lastImpacts[environmentID] = "\(action): a stop is already in progress for \(environmentID); no second teardown was started"
            return
        }
        // Serialize with an in-flight shape/RAM change: it holds the lifecycle
        // lock across its stop → apply → restart critical section, so the
        // destructive teardown below can never close the handle or release the
        // working disk, lease and pool slot while that operation is still
        // restarting the same guest. The reshape re-checks this registered
        // teardown after every await and aborts instead of resurrecting the VM.
        let lifecycleToken = nextLifecycleOperationToken()
        await acquireLifecycle(
            environmentID: environmentID, token: lifecycleToken, isShapeChange: false
        )
        defer {
            // Finish the teardown (including the in-flight marker a reshape
            // revalidates against) before the next lifecycle operation starts.
            teardownsInFlight.remove(environmentID)
            releaseLifecycle(environmentID: environmentID, token: lifecycleToken)
        }
        for (sessionID, terminal) in terminalSessions where terminal.environmentID == environmentID {
            terminalSessions.removeValue(forKey: sessionID)
            await terminal.handle.close()
        }
        guard let session = sessions.removeValue(forKey: environmentID) else {
            // No session: still release a reservation left by an in-flight
            // start that will not register one.
            if !startingEnvironments.contains(environmentID) {
                guestReservations[environmentID] = nil
                clearReservation(environmentID: environmentID)
                quarantinedEnvironments.remove(environmentID)
            }
            return
        }
        await performTeardownBody(environmentID: environmentID, action: action, session: session)
    }

    /// The destructive teardown body shared by `teardown` (user stop/reset)
    /// and `releaseTransientGuest` (scoped own-transient release). The caller
    /// owns the lifecycle lock and the `teardownsInFlight` marker and has
    /// already removed the session from `sessions`. Returns true when the VM
    /// survived the stop and is now quarantined.
    @discardableResult
    private func performTeardownBody(
        environmentID: String,
        action: String,
        session: Session
    ) async -> Bool {
        var session = session
        await session.channel.close()
        await session.handle.close()
        // Truthful stop: the engine may have refused to destroy a VM whose
        // run loop did not leave its last slice inside the stop budget. The
        // guest is then NOT stopped, so the session, its admission slot and
        // the disk stay owned by this environment until a later stop really
        // succeeds; a start on the same disk would otherwise corrupt it.
        if await session.handle.isRunning() {
            // The retained handle gets a fresh identity: any shape change that
            // captured this session before the failed stop can no longer match
            // it and can never restart a quarantined guest.
            session.generation = nextSessionGeneration()
            sessions[environmentID] = session
            quarantinedEnvironments.insert(environmentID)
            if let runtimeV2, let runtimeID = session.runtimeID {
                // Keep the working disk, the lease and the pool slot owned by
                // this quarantined environment; record the interruption. The
                // result is consumed so a refused capture is never smoothed
                // into a clean save.
                let outcome = await runtimeV2StopOutcome(
                    runtimeV2, environmentID: environmentID, runtimeID: runtimeID,
                    imageID: session.descriptor.imageID, clean: false
                )
                recordStopOutcome(
                    outcome, environmentID: environmentID, action: action, runtimeID: runtimeID
                )
            }
            lastErrors[environmentID] =
                "the Linux guest did not stop within the engine's budget and is still running; retry stopGuest (the persistent disk is preserved and no new guest will start on it)"
            lastImpacts[environmentID] =
                "\(action): \(environmentID) is STILL RUNNING (the VM refused to stop); the persistent disk and shares are preserved, the guest is quarantined and no new guest may start on it"
            FloeLogger(category: .tools).error(
                "Linux guest \(action) environment=\(environmentID) still running after the stop budget; quarantined"
            )
            return true
        }
        quarantinedEnvironments.remove(environmentID)
        guestReservations[environmentID] = nil
        clearReservation(environmentID: environmentID)
        // The guest is gone: its managed services died with it and can no
        // longer make a later scoped release refuse. In-flight command
        // counters are deliberately left to their balanced increment/decrement
        // pairs, so a stale defer can never hide a future command.
        spawnedServices[environmentID] = nil
        var stopSavedCleanly = true
        if let runtimeV2, let runtimeID = session.runtimeID {
            // Confirmed stop: flush + capture the delta, record the shutdown,
            // sweep the runtime dir and release the lease. The result is
            // consumed: a refused capture (retained for repair) is reported
            // truthfully instead of as a clean save. The arbiter/pool slot is
            // released by the actual stop — the VM's threads are gone and the
            // handle is closed — separately from whether the persistence
            // succeeded (the store refuses a fresh boot over the retained
            // disk until the repair completes).
            let outcome = await runtimeV2StopOutcome(
                runtimeV2, environmentID: environmentID, runtimeID: runtimeID,
                imageID: session.descriptor.imageID, clean: true
            )
            stopSavedCleanly = recordStopOutcome(
                outcome, environmentID: environmentID, action: action, runtimeID: runtimeID
            )
            await runtimeV2.releaseSlot(environmentID: environmentID, runtimeID: runtimeID)
        }
        if stopSavedCleanly {
            // The disk and shares are untouched; only runtime state was dropped.
            lastImpacts[environmentID] =
                "\(action): guest runtime for \(environmentID) stopped and destroyed; persistent disk and shares preserved; other environments untouched"
        }
        FloeLogger(category: .tools).info(
            "Linux guest \(action) environment=\(environmentID) activeGuests=\(guestReservations.count) reservedRAMMB=\(reservedGuestRAMMB) stopSavedCleanly=\(stopSavedCleanly)"
        )
        return false
    }

    /// Stops guests started by this task id (task ownership teardown).
    public func stop(taskID: String) async {
        let owned = sessions.filter { $0.value.taskID == taskID }.map(\.key)
        for id in owned {
            await stop(environmentID: id)
        }
    }

    /// Environment ids whose guest was started by this task.
    public func environments(taskID: String) async -> [String] {
        sessions.filter { $0.value.taskID == taskID }.map(\.key)
    }

    public func stopAll() async {
        for id in Array(sessions.keys) {
            await stop(environmentID: id)
        }
    }

    // MARK: logical-run ownership / scoped transient release

    /// Verified activity and ownership facts for every environment holding
    /// guest capacity (running, starting, stopping or stop-quarantined). The
    /// heavy-runtime arbiter consumes these to tell a logical run's own
    /// disposable tool guest from work that needs an explicit user decision;
    /// every field is a real registry measurement, never an inference.
    public func guestActivityDetails() async -> [LinuxGuestActivityDetail] {
        var details: [LinuxGuestActivityDetail] = []
        for environmentID in guestReservations.keys.sorted() {
            let terminalCount = terminalSessions.values.lazy
                .filter { $0.environmentID == environmentID }.count
            let serviceCount = spawnedServices[environmentID]?.count ?? 0
            let commandCount = activeCommands[environmentID] ?? 0
            if let session = sessions[environmentID] {
                details.append(LinuxGuestActivityDetail(
                    environmentID: environmentID,
                    ownerRunID: session.taskID,
                    running: await session.handle.isRunning(),
                    starting: startingEnvironments.contains(environmentID),
                    quarantined: quarantinedEnvironments.contains(environmentID),
                    activeCommandCount: commandCount,
                    activeTerminalCount: terminalCount,
                    activeServiceCount: serviceCount,
                    requestedForwardCount: session.forwards.count
                ))
            } else {
                // A reservation without a session is a start in flight or a
                // quarantined placeholder: never transient, never auto-released.
                details.append(LinuxGuestActivityDetail(
                    environmentID: environmentID,
                    ownerRunID: nil,
                    running: false,
                    starting: startingEnvironments.contains(environmentID),
                    quarantined: quarantinedEnvironments.contains(environmentID),
                    activeCommandCount: commandCount,
                    activeTerminalCount: terminalCount,
                    activeServiceCount: serviceCount,
                    requestedForwardCount: 0
                ))
            }
        }
        return details
    }

    /// Scoped release of a logical run's OWN transient tool guest, used by the
    /// heavy-runtime arbiter for that run's continuation. Deliberately
    /// narrower than `stop`:
    ///
    ///  * The guest must still be owned by `expectedOwnerRunID` — the run
    ///    whose tool started it on demand — and must still be verified
    ///    transient: no in-flight command (the run's own commands are waited
    ///    for, bounded), no interactive terminal, no managed service, no
    ///    requested forward and no quarantined stop.
    ///  * A guest that stopped being transient is REFUSED, never destroyed:
    ///    the caller falls back to the explicit conflict decision.
    ///  * A successful release runs the same teardown body as a user stop, so
    ///    Runtime v2 flushes/captures the working disk and releases the lease
    ///    and pool slot before the caller may map model weights.
    ///
    /// Never touches another environment and never clears a quarantine.
    public func releaseTransientGuest(
        environmentID: String,
        expectedOwnerRunID: String,
        commandDrainTimeout: Duration = .seconds(2)
    ) async -> LinuxGuestTransientReleaseOutcome {
        guard let snapshot = sessions[environmentID] else {
            return .refused(reason: "no guest session is owned for this environment")
        }
        guard LinuxGuestActivityDetail.runIDsMatch(snapshot.taskID, expectedOwnerRunID) else {
            return .refused(reason: "the guest is not owned by this logical run")
        }
        // The run's own in-flight commands finish first (bounded): a release
        // must never interrupt the command whose result the run is about to
        // use.
        let clock = ContinuousClock()
        let deadline = clock.now + commandDrainTimeout
        while (activeCommands[environmentID] ?? 0) > 0 {
            if clock.now >= deadline {
                return .refused(reason: "a command started by this run is still running in the guest")
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if startingEnvironments.contains(environmentID) {
            return .refused(reason: "the guest is still starting")
        }
        if isShapeChangeInFlight(environmentID: environmentID) {
            return .refused(reason: "a shape change owns this environment's lifecycle")
        }
        guard teardownsInFlight.insert(environmentID).inserted else {
            return .refused(reason: "a stop is already in progress for this environment")
        }
        let lifecycleToken = nextLifecycleOperationToken()
        await acquireLifecycle(
            environmentID: environmentID, token: lifecycleToken, isShapeChange: false
        )
        defer {
            teardownsInFlight.remove(environmentID)
            releaseLifecycle(environmentID: environmentID, token: lifecycleToken)
        }
        guard let current = sessions[environmentID],
              current.generation == snapshot.generation else {
            return .refused(reason: "the guest session was replaced while this release waited")
        }
        guard await current.handle.isRunning() else {
            return .refused(reason: "the guest is no longer running")
        }
        // Revalidate after the last await. From here through the session
        // removal the actor runs synchronously, so nothing can start a
        // command or service in between and then find its console closed.
        guard LinuxGuestActivityDetail.runIDsMatch(current.taskID, expectedOwnerRunID) else {
            return .refused(reason: "the guest is not owned by this logical run")
        }
        guard (activeCommands[environmentID] ?? 0) == 0 else {
            return .refused(reason: "a command started by this run is still running in the guest")
        }
        if terminalSessions.values.contains(where: { $0.environmentID == environmentID }) {
            return .refused(reason: "an interactive terminal session is open in this guest")
        }
        if let services = spawnedServices[environmentID], !services.isEmpty {
            return .refused(reason: "a managed service is running in this guest")
        }
        guard current.forwards.isEmpty else {
            return .refused(reason: "the guest has requested host port forwards")
        }
        guard !quarantinedEnvironments.contains(environmentID) else {
            return .refused(reason: "the guest is quarantined after a failed stop")
        }
        sessions[environmentID] = nil
        FloeLogger(category: .tools).info(
            "Linux guest transientRelease environment=\(environmentID) owner=\(expectedOwnerRunID)"
        )
        let stillRunning = await performTeardownBody(
            environmentID: environmentID, action: "transientRelease", session: current
        )
        if stillRunning {
            return .stopFailedQuarantined(
                detail: "the guest did not stop within the engine's budget; it is quarantined and a later stop can recover it"
            )
        }
        return .released
    }

    /// Changes the running guest's memory tier through the safe
    /// stop → flush → restart path. Kept for call-site compatibility;
    /// forwards to `setShape` without changing the vCPU count.
    public func setMemoryTier(environmentID: String, ramMB: Int) async throws {
        try await setShape(
            environmentID: environmentID,
            ramMB: ramMB,
            vcpus: sessions[environmentID]?.descriptor.vcpus ?? 1
        )
    }

    /// Changes the running guest's full shape (RAM tier + vCPU count) through
    /// the safe stop → flush → restart path. Documented boundary: the pinned
    /// TinyEMU engine allocates guest RAM and its harts once at create time
    /// and exposes no balloon/resize or hotplug API, so an online shape
    /// change is impossible by construction — the machine is stopped (its
    /// working disk stays exactly where it is), recreated with the new shape,
    /// and the console stream and command channel survive the reboot (the
    /// same boundary the in-guest runner upgrade already uses). The budget
    /// is validated BEFORE anything is disrupted, a failed restart restores
    /// the previous shape, and the whole sequence is serialized against
    /// teardown/start by the per-environment lifecycle lock: the session
    /// captured here is revalidated after every suspension, so a stale shape
    /// change can never restart the old handle, rebook a released reservation
    /// or overwrite a replacement session.
    public func setShape(environmentID: String, ramMB: Int, vcpus: Int) async throws {
        // Fast fail without a session, then capture the identity this request
        // is about. The capture is only a candidate; it is revalidated under
        // the lifecycle lock before anything is touched.
        guard let snapshot = sessions[environmentID], await snapshot.handle.isRunning() else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        let lifecycleToken = nextLifecycleOperationToken()
        await acquireLifecycle(
            environmentID: environmentID, token: lifecycleToken, isShapeChange: true
        )
        defer { releaseLifecycle(environmentID: environmentID, token: lifecycleToken) }
        guard isCurrentSession(environmentID: environmentID, generation: snapshot.generation),
              let session = sessions[environmentID] else {
            // A stop removed the session — or a replacement start registered a
            // new handle — while this request waited: the request belongs to
            // the old guest and must not touch the new one.
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        guard !teardownsInFlight.contains(environmentID) else {
            throw LinuxGuestError.guestBusy(environmentID: environmentID)
        }
        guard !startingEnvironments.contains(environmentID) else {
            throw LinuxGuestError.guestBusy(environmentID: environmentID)
        }
        guard let setRAMMB = session.handle.setRAMMB else {
            throw LinuxGuestError.invalidConfiguration("this guest session does not support memory tiers")
        }
        let tier = RuntimeMemoryTier.tier(forRequestedMB: ramMB, minimumMB: limits.minRAMMB)
        let clamped = limits.clampedRAMMB(tier.mb)
        let previous = limits.clampedRAMMB(session.descriptor.ramMB)
        let previousVCPUs: Int = {
            (try? releasePolicy.resolve(requestedVCPUs: session.descriptor.vcpus))?.count ?? 1
        }()
        let requestedVCPUs: GuestVCPUCount
        do {
            requestedVCPUs = try releasePolicy.resolve(requestedVCPUs: vcpus)
        } catch GuestReleaseShapeError.invalidVCPUCount {
            throw LinuxGuestError.invalidConfiguration(
                "invalid guest core count \(vcpus); this release supports exactly one"
            )
        } catch GuestReleaseShapeError.unsupportedReleaseVCPUCount {
            throw LinuxGuestError.releaseShapeUnsupported(
                requested: vcpus, maximum: releasePolicy.maximumSupportedVCPUs
            )
        }
        if requestedVCPUs.count == previousVCPUs {
            // RAM-only path: pure retier, planned through the RAM-only seam.
            guard clamped != previous else { return }
            try await applyShapeChange(
                environmentID: environmentID,
                session: session,
                ramMB: clamped,
                vcpus: nil,
                previousRAMMB: previous,
                previousVCPUs: previousVCPUs,
                setRAMMB: setRAMMB,
                setVCPUs: nil
            )
            return
        }
        guard let setVCPUs = session.handle.setVCPUs else {
            throw LinuxGuestError.invalidConfiguration(
                "this guest session does not support vCPU changes"
            )
        }
        try await applyShapeChange(
            environmentID: environmentID,
            session: session,
            ramMB: clamped,
            vcpus: requestedVCPUs.count,
            previousRAMMB: previous,
            previousVCPUs: previousVCPUs,
            setRAMMB: setRAMMB,
            setVCPUs: setVCPUs
        )
    }

    /// The disruptive half of a shape change, run while `setShape` holds the
    /// environment's lifecycle lock. The lock keeps a teardown's destructive
    /// phase (delta capture, working-disk/lease/slot release) from overlapping
    /// a reshape restart; `teardownsInFlight` is re-checked after every await
    /// so a stop that lands meanwhile always wins — this method then leaves the
    /// stopped handle to that stop instead of restarting, rebooking or
    /// confirming anything.
    private func applyShapeChange(
        environmentID: String,
        session: Session,
        ramMB: Int,
        vcpus: Int?,
        previousRAMMB: Int,
        previousVCPUs: Int,
        setRAMMB: @Sendable (Int) -> Void,
        setVCPUs: (@Sendable (Int) throws -> Void)?
    ) async throws {
        // Budget validation BEFORE any disruption: the requested shape must fit
        // next to the other running guests, or the VM stays untouched. Nothing
        // is stopped if this throws.
        if let runtimeV2 {
            if let vcpus {
                try await runtimeV2.planReshape(
                    environmentID: environmentID,
                    ramMB: ramMB,
                    vcpus: vcpus,
                    currentVCPUs: previousVCPUs
                )
            } else {
                try await runtimeV2.planRetier(environmentID: environmentID, ramMB: ramMB)
            }
        } else {
            let others = reservedGuestRAMMB - previousRAMMB
            guard others + ramMB <= limits.maxGuestRAMMB else {
                throw LinuxGuestError.capacityReached(
                    detail: "moving to the \(ramMB) MB tier would reserve \(others + ramMB) MB of the \(limits.maxGuestRAMMB) MB device guest RAM budget; \(others) MB is reserved by other guests"
                )
            }
        }
        // From here on the guest is disrupted; the caller's task is only
        // honoured before the stop, and a registered teardown always wins.
        try Task.checkCancellation()
        try requireShapeChangeOwnership(environmentID: environmentID)
        await session.handle.stop()
        try requireShapeChangeOwnership(environmentID: environmentID)
        let changeLabel = vcpus == nil ? "memory-tier change" : "shape change"
        let shapeLabel = vcpus == nil
            ? "the previous \(previousRAMMB) MB tier stays in effect"
            : "the previous \(previousRAMMB) MB / \(previousVCPUs) vCPU shape stays in effect"
        guard await session.handle.isRunning() == false else {
            throw LinuxGuestError.stopFailed(
                environmentID: environmentID,
                detail: "the guest did not stop for the \(changeLabel); \(shapeLabel)"
            )
        }
        try requireShapeChangeOwnership(environmentID: environmentID)
        setRAMMB(ramMB)
        // Last-boundary release gate (B4): setShape and planReshape already
        // validated this count; a throw here means the machine itself still
        // refuses the unqualified shape, so roll the previous shape back in
        // before restarting instead of booting a silently different one.
        do {
            try setVCPUs?(vcpus ?? previousVCPUs)
        } catch {
            setRAMMB(previousRAMMB)
            try? setVCPUs?(previousVCPUs)
            if !teardownsInFlight.contains(environmentID) {
                try? await session.handle.start()
            }
            throw error
        }
        do {
            try await session.handle.start()
        } catch {
            // Rollback: restore the previous shape and, unless a stop is
            // already registered (it owns the handle and will close it), try
            // to bring the guest back exactly as it was. The session stays
            // registered either way, so a later start/stop can heal a failed
            // rollback.
            setRAMMB(previousRAMMB)
            try? setVCPUs?(previousVCPUs)
            if !teardownsInFlight.contains(environmentID) {
                try? await session.handle.start()
            }
            throw error
        }
        guard !teardownsInFlight.contains(environmentID) else {
            // A stop landed while the restart was in flight. The VM is running
            // again at the requested shape; the teardown waiting on this lock
            // owns the handle from here and will stop it. Do not rebook the new
            // shape, re-register the session or confirm anything.
            throw LinuxGuestError.guestBusy(environmentID: environmentID)
        }
        guard isCurrentSession(environmentID: environmentID, generation: session.generation) else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        var updated = session
        updated.descriptor.ramMB = ramMB
        if let vcpus { updated.descriptor.vcpus = vcpus }
        sessions[environmentID] = updated
        guestReservations[environmentID] = ramMB
        publishReservation(environmentID: environmentID, ramMB: ramMB)
        if let runtimeV2 {
            if let vcpus {
                await runtimeV2.confirmReshape(
                    environmentID: environmentID, ramMB: ramMB, vcpus: vcpus
                )
            } else {
                await runtimeV2.confirmTier(environmentID: environmentID, ramMB: ramMB)
            }
        }
    }

    /// Re-checks, after every await in the disruptive path, that this shape
    /// change still owns the environment: no stop was registered and no start
    /// slipped in. The operation aborts without touching the guest otherwise.
    private func requireShapeChangeOwnership(environmentID: String) throws {
        if teardownsInFlight.contains(environmentID) {
            throw LinuxGuestError.guestBusy(environmentID: environmentID)
        }
        if startingEnvironments.contains(environmentID) {
            throw LinuxGuestError.guestBusy(environmentID: environmentID)
        }
    }

    // MARK: interactive sessions

    public func openSession(
        environmentID: String,
        sessionID: String,
        argv: [String],
        workingDirectory: String?,
        columns: Int,
        rows: Int
    ) async throws {
        guard let session = sessions[environmentID], await session.handle.isRunning() else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        guard terminalSessions[sessionID] == nil else {
            throw LinuxGuestError.invalidConfiguration("session \(sessionID) already exists")
        }
        let handle = try await session.channel.openSession(
            sessionID: sessionID,
            argv: argv,
            workingDirectory: workingDirectory,
            columns: columns,
            rows: rows
        )
        terminalSessions[sessionID] = TerminalSession(environmentID: environmentID, handle: handle)
    }

    /// Reads buffered terminal output. Returns nil when the session is
    /// unknown; the tuple's info carries aliveness/exit state.
    public func readSession(
        sessionID: String,
        maxBytes: Int,
        waitMs: Int
    ) async -> (output: Data, info: LinuxGuestSessionInfo)? {
        guard let terminal = terminalSessions[sessionID] else { return nil }
        var collected = Data()
        let deadline = Date().addingTimeInterval(Double(max(0, waitMs)) / 1000)
        var sawData = false
        while collected.count < maxBytes {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 || !sawData else { break }
            let wait = sawData ? min(20, max(0, Int(remaining * 1000))) : max(0, Int(remaining * 1000))
            guard let chunk = await terminal.handle.nextOutput(timeoutMs: wait) else {
                if await terminal.handle.isFinished { break }
                if sawData { break }
                break
            }
            sawData = true
            collected.append(chunk)
        }
        let info = LinuxGuestSessionInfo(
            sessionID: sessionID,
            alive: await !terminal.handle.isFinished,
            exitCode: await terminal.handle.terminalExitCode
        )
        if await terminal.handle.isFinished {
            terminalSessions[sessionID] = nil
        }
        return (collected, info)
    }

    public func writeSession(sessionID: String, text: String) async throws {
        guard let terminal = terminalSessions[sessionID] else {
            throw LinuxGuestError.notRunning(environmentID: "session \(sessionID)")
        }
        try await terminal.handle.write(text)
    }

    public func signalSession(sessionID: String, signal: LinuxGuestSessionSignal) async {
        guard let terminal = terminalSessions[sessionID] else { return }
        await terminal.handle.signal(signal)
    }

    public func resizeSession(sessionID: String, columns: Int, rows: Int) async {
        guard let terminal = terminalSessions[sessionID] else { return }
        await terminal.handle.signal(.window, rows: rows, columns: columns)
    }

    public func closeSession(sessionID: String) async {
        guard let terminal = terminalSessions.removeValue(forKey: sessionID) else { return }
        await terminal.handle.close()
    }

    public func sessionInfo(sessionID: String) async -> LinuxGuestSessionInfo? {
        guard let terminal = terminalSessions[sessionID] else { return nil }
        return LinuxGuestSessionInfo(
            sessionID: sessionID,
            alive: await !terminal.handle.isFinished,
            exitCode: await terminal.handle.terminalExitCode
        )
    }

    public func addForward(environmentID: String, forward: LinuxGuestServiceForward) async throws {
        guard let session = sessions[environmentID], await session.handle.isRunning() else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        guard session.forwards.count < limits.maxServiceForwards else {
            throw LinuxGuestError.invalidConfiguration(
                "at most \(limits.maxServiceForwards) host forwards are supported per guest"
            )
        }
        // Revalidate the captured session identity after the await: a stop or
        // shape change may have replaced it, and writing the stale copy back
        // would resurrect its descriptor over the replacement.
        guard var current = sessions[environmentID],
              current.generation == session.generation else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        try current.handle.addForward(forward)
        current.forwards.append(forward)
        sessions[environmentID] = current
    }

    public func removeForward(environmentID: String, forward: LinuxGuestServiceForward) async {
        guard var session = sessions[environmentID] else { return }
        try? session.handle.removeForward(forward)
        session.forwards.removeAll { $0 == forward }
        sessions[environmentID] = session
    }

    // MARK: background services (exec.localService)

    /// Guest-side operations for the local-service supervisor. These keep the
    /// same single-session rule as commands and sessions: a SPAWN/KILL/ALIVE
    /// exchange owns the console only while it is in flight.
    public func guestDescriptor(environmentID: String) async -> LinuxGuestEnvironmentDescriptor? {
        await environments.linuxGuestEnvironment(id: environmentID)
    }

    /// Host↔guest path mapping for this environment's 9p shares.
    public func linuxGuestPathMap(environmentID: String) async -> LinuxGuestPathMap? {
        guard let descriptor = await environments.linuxGuestEnvironment(id: environmentID) else { return nil }
        return LinuxGuestPathMap(shares: descriptor.shares)
    }

    public func guestSpawn(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        logPath: String,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> Int32 {
        guard let session = sessions[environmentID], await session.handle.isRunning() else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        // An in-flight spawn is activity: a scoped transient release must wait
        // for it instead of closing the console under the SPAWN exchange.
        beginActiveCommand(environmentID: environmentID)
        defer { endActiveCommand(environmentID: environmentID) }
        do {
            let pid = try await session.channel.spawnService(
                argv: argv,
                workingDirectory: workingDirectory,
                logPath: logPath,
                timeout: timeout,
                cancellation: cancellation
            )
            // The spawned service is persistent guest work: owning it keeps
            // the guest non-transient until the service is explicitly killed.
            spawnedServices[environmentID, default: []].insert(pid)
            return pid
        } catch {
            lastErrors[environmentID] = error.localizedDescription
            if await session.channel.isPoisoned {
                await stop(environmentID: environmentID)
            }
            throw error
        }
    }

    public func guestServiceAlive(environmentID: String, pid: Int32, timeout: TimeInterval) async throws -> Bool {
        guard let session = sessions[environmentID], await session.handle.isRunning() else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        return try await session.channel.serviceAlive(pid: pid, timeout: timeout)
    }

    public func guestKillService(environmentID: String, pid: Int32, timeout: TimeInterval) async throws -> Bool {
        guard let session = sessions[environmentID], await session.handle.isRunning() else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        let killed = try await session.channel.killService(pid: pid, timeout: timeout)
        if killed {
            spawnedServices[environmentID]?.remove(pid)
            if spawnedServices[environmentID]?.isEmpty == true {
                spawnedServices[environmentID] = nil
            }
        }
        return killed
    }

    public func guestEnsureForward(environmentID: String, forward: LinuxGuestServiceForward) async throws {
        try await addForward(environmentID: environmentID, forward: forward)
    }

    public func guestRemoveForward(environmentID: String, forward: LinuxGuestServiceForward) async {
        await removeForward(environmentID: environmentID, forward: forward)
    }
}

extension TinyEMULinuxGuestRegistry: LinuxGuestLocalServiceHosting {}

extension TinyEMULinuxGuestRegistry {
    /// The service supervisor's acknowledged pending-terminal store lives in
    /// the app's own support directory, following the same convention as the
    /// other FloeExecution stores. The store is a bounded hand-off: events
    /// stay there only until the app's durable notification pipeline accepts
    /// and acknowledges them. `nonisolated`: the path is a pure function of
    /// the process's support directory, no actor state involved.
    public nonisolated var localServiceTerminalStoreDirectory: URL? {
        let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base?.appendingPathComponent("FloeAgent/LinuxServiceTerminal", isDirectory: true)
    }
}

extension TinyEMULinuxCommandService {
    /// Installs (or clears, with nil) the app's builder for the optional
    /// guest → host control bridge. Forwarded to the one registry every copy
    /// of this service shares; a guest started after this call advertises the
    /// capability in its HELLO handshake, and one started before it does not.
    public func installHostRequestHandlerFactory(
        _ factory: LinuxGuestHostRequestHandlerFactory?
    ) {
        registry.installHostRequestHandlerFactory(factory)
    }
}

extension TinyEMULinuxCommandService: LinuxGuestPathMapping {
    public func linuxGuestPathMap(environmentID: String) async -> LinuxGuestPathMap? {
        await registry.linuxGuestPathMap(environmentID: environmentID)
    }
}

/// The injected `LinuxCommandRunning` implementation: one service per app,
/// one guest per environment, shared by shell, localPython and localService.
public struct TinyEMULinuxCommandService: LinuxCommandRunning, LinuxGuestControlling, LinuxGuestLocalServiceControlling, LinuxGuestLocalServiceLifecycleReporting {
    private let registry: TinyEMULinuxGuestRegistry
    private let localServices: LinuxGuestLocalServiceSupervisor

    public init(registry: TinyEMULinuxGuestRegistry, limits: LinuxGuestLimits = .standard) {
        self.registry = registry
        self.localServices = LinuxGuestLocalServiceSupervisor(host: registry, limits: limits)
    }

    // MARK: LinuxCommandRunning

    public func supports(environmentID: String) async -> Bool {
        await registry.supports(environmentID: environmentID)
    }

    public func ownsLinuxEnvironment(environmentID: String) async -> Bool {
        await registry.owns(environmentID: environmentID)
    }

    public func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        try await registry.run(
            environmentID: environmentID,
            argv: argv,
            workingDirectory: workingDirectory,
            standardInput: standardInput,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            cancellation: cancellation
        )
    }

    // MARK: LinuxGuestControlling

    public func startGuest(environmentID: String, taskID: String?) async throws -> Bool {
        try await registry.start(environmentID: environmentID, taskID: taskID)
    }

    public func stopGuest(environmentID: String) async {
        // Services die with their guest: kill them explicitly first so the
        // host forwarding table and the job log are closed out, not just
        // discarded with the VM. The shared interpreter caches are dropped as
        // well; a restart re-probes the (persistent) venv/Node environment
        // instead of trusting paths resolved before the layer was remounted.
        await localServices.stopLocalServices(environmentID: environmentID)
        await registry.stop(environmentID: environmentID)
        // The stop owns the environment: a service start that still crossed it
        // is released as an explicit host stop, never kept as a live handle.
        await localServices.environmentDidStop(environmentID: environmentID)
        await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID)
        await LinuxGuestNodeProvisioner.shared.forget(environmentID: environmentID)
    }

    public func resetGuest(environmentID: String) async {
        // Same teardown as stopGuest (services first, then the guest), but
        // explicitly scoped: the persistent disk image and shares survive;
        // other environments are untouched. The impact text is surfaced
        // through guestStatus.lastResetSharedImpact.
        await localServices.stopLocalServices(environmentID: environmentID)
        await registry.reset(environmentID: environmentID)
        await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID)
        await LinuxGuestNodeProvisioner.shared.forget(environmentID: environmentID)
    }

    public func deleteGuest(environmentID: String) async {
        await localServices.stopLocalServices(environmentID: environmentID)
        await registry.stop(environmentID: environmentID)
        await localServices.environmentDidStop(environmentID: environmentID)
        await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID)
        await LinuxGuestNodeProvisioner.shared.forget(environmentID: environmentID)
    }

    public func guestIsRunning(environmentID: String) async -> Bool {
        await registry.status(environmentID: environmentID).running
    }

    /// Lease-based activity truth for the heavy-runtime arbiter's probe:
    /// every environment holding guest capacity (running, starting,
    /// stopping, or stop-quarantined). See
    /// `TinyEMULinuxGuestRegistry.environmentsWithGuestActivity`.
    public func environmentsWithGuestActivity() async -> [String] {
        await registry.environmentsWithGuestActivity
    }

    /// Verified ownership/activity facts feeding the arbiter's own-transient
    /// auto-release decision. See `TinyEMULinuxGuestRegistry.guestActivityDetails`.
    public func guestActivityDetails() async -> [LinuxGuestActivityDetail] {
        await registry.guestActivityDetails()
    }

    /// Scoped release of a logical run's OWN transient tool guest, used by the
    /// arbiter for that run's continuation. The supervisor's service table is
    /// checked first: a guest with a live managed service is persistent work
    /// and is refused here, never stopped silently. The registry then
    /// revalidates ownership/transience itself (including services it spawned)
    /// before running the same teardown body as a user stop.
    public func releaseTransientGuest(
        environmentID: String,
        expectedOwnerRunID: String
    ) async -> LinuxGuestTransientReleaseOutcome {
        if await localServices.activeLocalServiceCount(environmentID: environmentID) > 0 {
            return .refused(reason: "a managed service is running in this guest")
        }
        let outcome = await registry.releaseTransientGuest(
            environmentID: environmentID,
            expectedOwnerRunID: expectedOwnerRunID
        )
        if outcome.isReleased {
            // Same cache hygiene as stopGuest: a later start re-probes the
            // (persistent) venv/Node environment instead of trusting paths
            // resolved before the guest was released.
            await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID)
            await LinuxGuestNodeProvisioner.shared.forget(environmentID: environmentID)
        }
        return outcome
    }

    /// Authoritative runtime identity for one environment (metrics sampler
    /// provider seam). See `TinyEMULinuxGuestRegistry.runtimeIdentity`.
    public func runtimeIdentity(environmentID: String) async -> LinuxGuestRuntimeIdentity {
        await registry.runtimeIdentity(environmentID: environmentID)
    }

    /// Authoritative per-launch states (identity, liveness, granted shape)
    /// for metrics/notification surfaces. See
    /// `TinyEMULinuxGuestRegistry.runtimeStates`.
    public func runtimeStates() async -> [LinuxGuestRuntimeState] {
        await registry.runtimeStates()
    }

    public func guestStatus(environmentID: String) async -> LinuxGuestStatus {
        await registry.status(environmentID: environmentID)
    }

    public func stopGuests(taskID: String) async {
        let environmentIDs = await registry.environments(taskID: taskID)
        for environmentID in environmentIDs {
            await localServices.stopLocalServices(environmentID: environmentID)
        }
        await registry.stop(taskID: taskID)
        // Nothing above can restart these guests; release any start that still
        // crossed the stop as an explicit host stop instead of a dead handle.
        for environmentID in environmentIDs {
            await localServices.environmentDidStop(environmentID: environmentID)
        }
    }

    public func forwardService(environmentID: String, forward: LinuxGuestServiceForward) async throws {
        try await registry.addForward(environmentID: environmentID, forward: forward)
    }

    public func removeServiceForward(environmentID: String, forward: LinuxGuestServiceForward) async {
        await registry.removeForward(environmentID: environmentID, forward: forward)
    }

    // MARK: interactive sessions

    public func openSession(
        environmentID: String,
        sessionID: String,
        argv: [String],
        workingDirectory: String?,
        columns: Int,
        rows: Int
    ) async throws {
        try await registry.openSession(
            environmentID: environmentID,
            sessionID: sessionID,
            argv: argv,
            workingDirectory: workingDirectory,
            columns: columns,
            rows: rows
        )
    }

    public func readSession(
        sessionID: String,
        maxBytes: Int,
        waitMs: Int
    ) async -> (output: Data, info: LinuxGuestSessionInfo)? {
        await registry.readSession(sessionID: sessionID, maxBytes: maxBytes, waitMs: waitMs)
    }

    public func writeSession(sessionID: String, text: String) async throws {
        try await registry.writeSession(sessionID: sessionID, text: text)
    }

    public func signalSession(sessionID: String, signal: LinuxGuestSessionSignal) async {
        await registry.signalSession(sessionID: sessionID, signal: signal)
    }

    public func resizeSession(sessionID: String, columns: Int, rows: Int) async {
        await registry.resizeSession(sessionID: sessionID, columns: columns, rows: rows)
    }

    public func closeSession(sessionID: String) async {
        await registry.closeSession(sessionID: sessionID)
    }

    public func sessionInfo(sessionID: String) async -> LinuxGuestSessionInfo? {
        await registry.sessionInfo(sessionID: sessionID)
    }

    public func shutdown() async {
        await localServices.stopAllLocalServices()
        await registry.stopAll()
    }

    // MARK: LinuxGuestLocalServiceControlling

    public func startLocalService(
        environmentID: String,
        request: LinuxGuestLocalServiceRequest,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestLocalServiceHandle {
        try await localServices.startLocalService(
            environmentID: environmentID,
            request: request,
            cancellation: cancellation
        )
    }

    public func localServiceSnapshot(_ handle: LinuxGuestLocalServiceHandle) async -> LinuxGuestLocalServiceSnapshot {
        await localServices.localServiceSnapshot(handle)
    }

    public func stopLocalService(_ handle: LinuxGuestLocalServiceHandle) async {
        await localServices.stopLocalService(handle)
    }

    public func stopLocalServices(environmentID: String) async {
        await localServices.stopLocalServices(environmentID: environmentID)
    }

    public func activeLocalServiceCount(environmentID: String) async -> Int {
        await localServices.activeLocalServiceCount(environmentID: environmentID)
    }

    /// Bounded lifecycle stream of the owned local-service supervisor: the
    /// app's durable terminal pipeline consumes it and acknowledges every
    /// accepted observed end, so a slow or restarted consumer can never lose
    /// one (explicit stops are transient notices and must not be alerted).
    /// See `LinuxGuestLocalServiceLifecycleReporting`.
    public func localServiceLifecycleEvents() async -> AsyncStream<LinuxGuestLocalServiceLifecycleEvent> {
        await localServices.localServiceLifecycleEvents()
    }

    public func acknowledgeLocalServiceLifecycleEvent(
        _ event: LinuxGuestLocalServiceLifecycleEvent
    ) async {
        await localServices.acknowledgeLocalServiceLifecycleEvent(event)
    }

    /// Interactive sessions currently open inside one environment's guest;
    /// nil when this service does not own the environment (unknown, never a
    /// fabricated zero).
    public func activeSessionCount(environmentID: String) async -> Int? {
        await registry.activeSessionCount(environmentID: environmentID)
    }

    /// Latest cumulative emulator-thread CPU sample for one environment. The
    /// metrics sampler derives a host-side emulator CPU fraction from two
    /// samples; nil means "not measured", never zero.
    public func emulatorThreadCPUSample(environmentID: String) async -> LinuxGuestEmulatorCPUSample? {
        await registry.emulatorThreadCPUSample(environmentID: environmentID)
    }
}
