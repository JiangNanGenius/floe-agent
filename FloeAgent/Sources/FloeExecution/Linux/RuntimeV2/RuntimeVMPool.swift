// FloeExecution — Runtime v2 VM pool: simultaneous CPU/RAM/VM admission.
//
// At most `quota.maxVMs` VMs (default policy: four on modern iPads) hold
// pool leases at any time. A request that cannot be admitted does NOT fail
// immediately: it enters a bounded FIFO queue and waits, cancellable, up to
// `queueTimeout`; the entry is recorded in the registry's queue table so an
// app restart can mark interrupted starts explicitly instead of losing them.
//
// Admission is SIMULTANEOUS on three dimensions against one GuestResourceQuota
// (see ResourcePolicy/GuestResourceQuota): VM count AND total vCPUs AND total
// guest RAM, so no dimension is ever deducted twice. Two additional real
// bounds apply (the quota is a policy ceiling, not a promise the OS can pay):
//   - process headroom: os_proc_available_memory() must still cover the new
//     guest's RAM + a fixed per-VM host overhead + a future reserve margin,
//     which distinguishes resident memory from not-yet-touched reservations;
//   - pressure/thermal: serious thermal pressure admits only floor-shaped
//     guests, critical pressure admits no NEW guest. Pressure and idle
//     reclaim never terminate an active lease — only the registry stops a
//     VM, through the safe path.
//
// Dual-hart requests additionally require an image-capability gate
// (`imageSMPCapable`, supplied by the registry from the image manifest):
// engine capability is not guest compatibility. A strict dual request that
// cannot be granted two harts QUEUES — it is never silently booted single.
// lease records it honestly.
//
// The pinned TinyEMU engine has no balloon/resize or online vCPU hotplug:
// guest RAM/harts are fixed at create time. Shape changes therefore go
// through the safe stop → flush → restart path (`validateShapeChange` +
// `confirmShape`). Nothing here claims an online change happened.

import Foundation
import FloeCore

public actor RuntimeVMPool {
    /// Host pressure severity used to gate new admissions.
    public enum ResourcePressure: Int, Sendable, Equatable, Codable, Comparable {
        case nominal
        case fair
        case serious
        case critical

        public static func < (lhs: ResourcePressure, rhs: ResourcePressure) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public struct Configuration: Sendable, Equatable {
        /// CPU/RAM/VM quota for the whole pool.
        public var quota: GuestResourceQuota
        public var queueLimit: Int
        public var queueTimeout: TimeInterval
        /// Per-VM host overhead (emulator threads, slirp, 9p buffers) in MiB,
        /// reserved once per lease in the headroom check.
        public var hostOverheadMiB: Int
        /// Free headroom kept in reserve after an admission (future margin).
        public var futureReserveMiB: Int
        // Legacy tier vocabulary retained so existing callers/tests compile.
        public var floorTier: RuntimeMemoryTier

        public init(
            quota: GuestResourceQuota,
            queueLimit: Int = 32,
            queueTimeout: TimeInterval = 600,
            hostOverheadMiB: Int = 64,
            futureReserveMiB: Int = 256,
            floorTier: RuntimeMemoryTier = .constrained
        ) {
            self.quota = quota
            self.queueLimit = max(1, min(128, queueLimit))
            self.queueTimeout = max(1, queueTimeout)
            self.hostOverheadMiB = max(0, min(512, hostOverheadMiB))
            self.futureReserveMiB = max(0, min(2048, futureReserveMiB))
            self.floorTier = floorTier
        }

        /// Legacy initializer: maps the old device-class budget into a quota.
        public init(
            maxRunning: Int = 4,
            budget: RuntimeMemoryBudget = .current(),
            queueLimit: Int = 32,
            queueTimeout: TimeInterval = 600,
            floorTier: RuntimeMemoryTier = .constrained
        ) {
            let running = max(1, min(16, maxRunning))
            self.init(
                quota: GuestResourceQuota(
                    totalVCPUs: running,
                    totalMemoryMiB: budget.totalMB,
                    maxVMs: running
                ),
                queueLimit: queueLimit,
                queueTimeout: queueTimeout,
                floorTier: floorTier
            )
        }

        /// Production default: quota from the real host observation.
        public init() {
            self.init(quota: GuestResourceQuota.defaultQuota(for: .current))
        }
    }

    /// Injectable host seams (headroom + pressure probes).
    public struct Seams: Sendable {
        public var availableHeadroomBytes: @Sendable () -> Int?
        public var pressure: @Sendable () -> ResourcePressure?

        public init(
            availableHeadroomBytes: @escaping @Sendable () -> Int?,
            pressure: @escaping @Sendable () -> ResourcePressure?
        ) {
            self.availableHeadroomBytes = availableHeadroomBytes
            self.pressure = pressure
        }

        /// Production seams: os_proc_available_memory + ProcessInfo thermal.
        public static let production = Seams(
            availableHeadroomBytes: { RuntimeProcessHeadroom.availableBytes() },
            pressure: {
                switch ProcessInfo.processInfo.thermalState {
                case .nominal: return .nominal
                case .fair: return .fair
                case .serious: return .serious
                case .critical: return .critical
                @unknown default: return nil
                }
            }
        )

        /// Test seam: unbounded headroom, always nominal pressure.
        public static let unrestricted = Seams(
            availableHeadroomBytes: { nil },
            pressure: { .nominal }
        )
    }

    /// Legacy slot projection (kept for existing integrator/tests).
    public struct Slot: Sendable, Equatable {
        public var runtimeID: String
        public var environmentID: String
        public var tier: RuntimeMemoryTier
        public var grantedAt: Date
        /// True when admission granted a shape below the request.
        public var downgradedAtAdmission: Bool
    }

    public struct PoolStatus: Sendable, Equatable {
        public var running: Int
        public var queued: Int
        public var reservedMB: Int
        public var budgetMB: Int
        public var maxRunning: Int
        public var usedVCPUs: Int
        public var pressure: ResourcePressure
        public var headroomBytes: Int?

        public init(
            running: Int, queued: Int, reservedMB: Int, budgetMB: Int,
            maxRunning: Int, usedVCPUs: Int, pressure: ResourcePressure,
            headroomBytes: Int?
        ) {
            self.running = running
            self.queued = queued
            self.reservedMB = reservedMB
            self.budgetMB = budgetMB
            self.maxRunning = maxRunning
            self.usedVCPUs = usedVCPUs
            self.pressure = pressure
            self.headroomBytes = headroomBytes
        }
    }

    private struct Waiter {
        var id: String
        var environmentID: String
        var request: GuestResourceRequest
        var imageSMPCapable: Bool
        var downgrade: GuestShapeDowngradePolicy
        var enqueuedAt: Date
        var continuation: CheckedContinuation<GuestResourceLease, Error>
    }

    private let configuration: Configuration
    private let seams: Seams
    private let registry: RuntimeV2Registry?
    private var leases: [String: GuestResourceLease] = [:] // runtimeID → lease
    private var runtimeByEnvironment: [String: String] = [:]
    private var waiters: [Waiter] = []
    /// Last externally reported pressure; nil to rely on the seam probe.
    private var reportedPressure: ResourcePressure?

    public init(
        configuration: Configuration = .init(),
        registry: RuntimeV2Registry? = nil,
        seams: Seams = .production
    ) {
        self.configuration = configuration
        self.registry = registry
        self.seams = seams
    }

    /// Current effective pressure (external report merged with host probe,
    /// most severe wins).
    private func currentPressure() -> ResourcePressure {
        let probed = seams.pressure() ?? .nominal
        if let reported = reportedPressure { return max(probed, reported) }
        return probed
    }

    public var status: PoolStatus {
        let leases = Array(leases.values)
        return PoolStatus(
            running: leases.count,
            queued: waiters.count,
            reservedMB: leases.reduce(0) { $0 + $1.shape.memory.mb },
            budgetMB: configuration.quota.totalMemoryMiB,
            maxRunning: configuration.quota.maxVMs,
            usedVCPUs: leases.reduce(0) { $0 + $1.shape.vcpus.count },
            pressure: currentPressure(),
            headroomBytes: seams.availableHeadroomBytes()
        )
    }

    public func lease(runtimeID: String) -> GuestResourceLease? { leases[runtimeID] }

    public func slot(environmentID: String) -> Slot? {
        runtimeByEnvironment[environmentID].flatMap { leases[$0] }.map(Self.projection)
    }

    static func projection(_ lease: GuestResourceLease) -> Slot {
        Slot(
            runtimeID: lease.runtimeID,
            environmentID: lease.environmentID,
            tier: RuntimeMemoryTier.tier(forRequestedMB: lease.shape.memory.mb),
            grantedAt: lease.grantedAt,
            downgradedAtAdmission: lease.wasDowngraded
        )
    }

    // MARK: acquire (shape-based)

    /// Admits a start request against the full request (vCPUs + RAM).
    /// Returns the granted lease immediately when capacity, headroom and
    /// pressure allow; otherwise the request queues (recorded durably) until
    /// a release makes room, the task is cancelled, or the queue timeout
    /// elapses. Re-entrant for an environment that already holds a lease.
    ///
    /// - Parameters:
    ///   - imageSMPCapable: whether THIS image's kernel/firmware support SMP.
    ///     Strict dual requests with a false gate throw an actionable error;
    ///     authorized callers may accept a single-hart downgrade.
    ///   - downgrade: `.strict` queues on temporary shortage and throws on a
    ///     permanent image mismatch; `.authorized` may reduce within floors.
    public func acquire(
        environmentID: String,
        runtimeID: String,
        request: GuestResourceRequest,
        imageSMPCapable: Bool,
        downgrade: GuestShapeDowngradePolicy = .strict
    ) async throws -> GuestResourceLease {
        try RuntimeV2Identifier.validate(environmentID, kind: .environment)
        try RuntimeV2Identifier.validate(runtimeID, kind: .runtime)
        if let existing = runtimeByEnvironment[environmentID] {
            if let lease = leases[existing] { return lease }
        }
        let usage = currentUsage()
        if let granted = try admit(
            environmentID: environmentID,
            request: request, imageSMPCapable: imageSMPCapable,
            downgrade: downgrade, usage: usage
        ) {
            return grant(environmentID: environmentID, runtimeID: runtimeID, decision: granted)
        }
        guard waiters.count < configuration.queueLimit else {
            throw RuntimeV2Error.queueFull(limit: configuration.queueLimit)
        }
        let queuedAt = Date()
        try await registry?.recordQueueEntry(
            RuntimeV2Registry.QueueRow(
                id: runtimeID, environmentID: environmentID,
                requestedMB: request.memory.mb, state: "queued",
                enqueuedAt: queuedAt, startedAt: nil, finishedAt: nil
            )
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<GuestResourceLease, Error>) in
                waiters.append(
                    Waiter(
                        id: runtimeID, environmentID: environmentID,
                        request: request, imageSMPCapable: imageSMPCapable,
                        downgrade: downgrade, enqueuedAt: queuedAt,
                        continuation: continuation
                    )
                )
                scheduleTimeout(for: runtimeID)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: runtimeID, reason: "cancelled") }
        }
    }

    /// Legacy admission used by the current integrator: MB-only request,
    /// single hart, no image SMP evidence ⇒ dual is never granted through
    /// this seam (fail closed; B2 wires the shape-based overload). Memory
    /// downgrades through this seam are explicitly authorized (the old
    /// integrator behavior), bounded by the 256 MiB floor and reported
    /// honestly via the slot's `downgradedAtAdmission` flag.
    public func acquire(
        environmentID: String,
        runtimeID: String,
        requestedTier: RuntimeMemoryTier
    ) async throws -> Slot {
        let request = GuestResourceRequest(
            vcpus: .one,
            memory: GuestMemoryMiB.smallestHolding(requestedTier.mb) ?? .m2048
        )
        let lease = try await acquire(
            environmentID: environmentID,
            runtimeID: runtimeID,
            request: request,
            imageSMPCapable: false,
            downgrade: .authorized(memoryFloor: .m256)
        )
        return Self.projection(lease)
    }

    private struct Usage {
        var runningVMs: Int
        var usedVCPUs: Int
        var usedMemoryMiB: Int
    }

    private func currentUsage() -> Usage {
        let leases = Array(leases.values)
        return Usage(
            runningVMs: leases.count,
            usedVCPUs: leases.reduce(0) { $0 + $1.shape.vcpus.count },
            usedMemoryMiB: leases.reduce(0) { $0 + $1.shape.memory.mb }
        )
    }

    /// Pure decision plus the image gate and real headroom/pressure gates.
    /// Returns the admission payload (granted shape + downgrade flags) or nil
    /// to QUEUE (temporary shortage). Throws when the image/shape mismatch is
    /// permanent (dual request against an image with no SMP evidence under
    /// strict admission), so the caller hears an actionable error instead of
    /// waiting forever.
    private func admit(
        environmentID: String,
        request: GuestResourceRequest,
        imageSMPCapable: Bool,
        downgrade: GuestShapeDowngradePolicy,
        usage: Usage
    ) throws -> GuestResourceAdmissionDecision? {
        // Image capability gate: engine SMP support is not guest
        // compatibility. A dual request with no image evidence either gets
        // an actionable error (strict) or, when the caller explicitly
        // authorized it, a single-hart downgrade with an honest reason.
        var effectiveRequest = request
        var imageGateDowngrade = false
        if request.vcpus == .two, !imageSMPCapable {
            switch downgrade {
            case .strict:
                throw LinuxGuestError.smpUnsupportedByImage(environmentID: environmentID)
            case .authorized(let vcpuFloor, _):
                guard vcpuFloor == .one else {
                    throw LinuxGuestError.smpUnsupportedByImage(environmentID: environmentID)
                }
                effectiveRequest = GuestResourceRequest(
                    vcpus: .one, memory: request.memory, origin: request.origin
                )
                imageGateDowngrade = true
            }
        }

        // Permanently impossible shapes fail fast with an actionable error:
        // no amount of waiting can satisfy a request whose minimum exceeds
        // the device's immutable pool total. Temporary shortages (pool
        // currently occupied, headroom, thermal) still queue below.
        if GuestResourceAdmission.isPermanentlyUnsatisfiable(
            request: effectiveRequest,
            quota: configuration.quota,
            downgrade: downgrade
        ) {
            throw LinuxGuestError.shapeExceedsPoolCapacity(
                detail: "the \(configuration.quota.totalVCPUs) vCPU / \(configuration.quota.totalMemoryMiB) MiB pool cannot ever hold \(effectiveRequest.vcpus.count) vCPU(s) / \(effectiveRequest.memory.mb) MiB (environment \(environmentID)); choose a smaller shape or a larger device"
            )
        }

        let decision = GuestResourceAdmission.evaluate(
            request: effectiveRequest,
            runningVMs: usage.runningVMs,
            usedVCPUs: usage.usedVCPUs,
            usedMemoryMiB: usage.usedMemoryMiB,
            quota: configuration.quota,
            downgrade: downgrade
        )
        guard case .admitted(let shape, let vcpusDowngraded, let memoryDowngraded,
                             let vcpuReason, let memoryReason) = decision else {
            return nil
        }

        // Pressure gate on NEW admissions; running leases are never touched.
        switch currentPressure() {
        case .nominal, .fair:
            break
        case .serious:
            // Only floor-shaped guests may start under serious pressure.
            guard shape.vcpus == .one, shape.memory.mb <= 512 else { return nil }
        case .critical:
            return nil
        }

        // Process headroom: resident reality on top of the quota's allowance
        // for not-yet-touched leases. A nil probe leaves the quota as the
        // sole bound (the API was unavailable), recorded honestly.
        if let available = seams.availableHeadroomBytes() {
            let required = (shape.memory.mb + configuration.hostOverheadMiB + configuration.futureReserveMiB) * 1_048_576
            guard available >= required else { return nil }
        }

        let imageGateReason = imageGateDowngrade
            ? "the image has no SMP capability evidence; the caller authorized a single-hart boot" : nil
        let combinedVCPUReason = [vcpuReason, imageGateReason]
            .compactMap { $0 }.joined(separator: "; ")
        return .admitted(
            shape: shape,
            vcpusDowngraded: vcpusDowngraded || imageGateDowngrade,
            memoryDowngraded: memoryDowngraded,
            vcpusDowngradeReason: combinedVCPUReason.isEmpty ? nil : combinedVCPUReason,
            memoryDowngradeReason: memoryReason
        )
    }

    private func grant(
        environmentID: String, runtimeID: String,
        decision: GuestResourceAdmissionDecision
    ) -> GuestResourceLease {
        guard case .admitted(let shape, let vcpusDowngraded, let memoryDowngraded,
                             let vcpuReason, let memoryReason) = decision else {
            preconditionFailure("grant requires an admitted decision")
        }
        let lease = GuestResourceLease(
            runtimeID: runtimeID,
            environmentID: environmentID,
            shape: shape,
            grantedAt: Date(),
            vcpusDowngraded: vcpusDowngraded,
            memoryDowngraded: memoryDowngraded,
            vcpusDowngradeReason: vcpuReason,
            memoryDowngradeReason: memoryReason
        )
        leases[runtimeID] = lease
        runtimeByEnvironment[environmentID] = runtimeID
        return lease
    }

    private func scheduleTimeout(for runtimeID: String) {
        let timeout = configuration.queueTimeout
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.cancelWaiter(id: runtimeID, reason: "timed out")
        }
    }

    private func cancelWaiter(id runtimeID: String, reason: String) async {
        guard let index = waiters.firstIndex(where: { $0.id == runtimeID }) else { return }
        let waiter = waiters.remove(at: index)
        // No lease was granted to a queued waiter, so nothing is returned.
        try? await registry?.setQueueEntryState(
            id: runtimeID,
            state: reason == "cancelled" ? "cancelled" : "interrupted",
            finished: true
        )
        if reason == "cancelled" {
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            waiter.continuation.resume(throwing: RuntimeV2Error.queueTimedOut(
                environmentID: waiter.environmentID, seconds: Int(configuration.queueTimeout)
            ))
        }
    }

    // MARK: release + waiter promotion

    /// Releases a lease and promotes queued waiters in FIFO order. A waiter
    /// that still cannot fit stays queued; later waiters that do fit are not
    /// blocked behind it forever.
    public func release(runtimeID: String) async {
        guard let lease = leases.removeValue(forKey: runtimeID) else { return }
        runtimeByEnvironment.removeValue(forKey: lease.environmentID)
        if registry != nil {
            try? await registry?.setQueueEntryState(id: runtimeID, state: "done", finished: true)
        }
        await promoteWaiters()
    }

    private func promoteWaiters() async {
        var index = 0
        while index < waiters.count {
            let waiter = waiters[index]
            let usage = currentUsage()
            let decision: GuestResourceAdmissionDecision?
            do {
                decision = try admit(
                    environmentID: waiter.environmentID,
                    request: waiter.request,
                    imageSMPCapable: waiter.imageSMPCapable,
                    downgrade: waiter.downgrade,
                    usage: usage
                )
            } catch {
                // Permanent image/shape mismatch surfaced now that room
                // exists: remove the waiter and deliver the actionable error.
                waiters.remove(at: index)
                try? await registry?.setQueueEntryState(
                    id: waiter.id, state: "interrupted", finished: true
                )
                waiter.continuation.resume(throwing: error)
                continue
            }
            guard configuration.quota.hasRoomForVM(runningVMs: usage.runningVMs),
                  let decision else {
                index += 1
                continue
            }
            waiters.remove(at: index)
            let lease = grant(
                environmentID: waiter.environmentID, runtimeID: waiter.id,
                decision: decision
            )
            try? await registry?.setQueueEntryState(id: waiter.id, state: "running", started: true)
            waiter.continuation.resume(returning: lease)
        }
    }

    // MARK: pressure + idle reclaim

    /// Reports host-side pressure (thermal/memory) from app observers. The
    /// report only gates NEW admissions; it never terminates a running lease.
    /// When pressure clears, queued waiters are re-evaluated immediately.
    public func reportPressure(_ pressure: ResourcePressure?) async {
        reportedPressure = pressure
        await promoteWaiters()
    }

    /// Re-evaluates queued waiters when host headroom changed without a
    /// release (pressure clear is handled by `reportPressure`).
    public func refreshQueuedAdmissions() async {
        await promoteWaiters()
    }

    /// Idle-reclaim planner: returns leases the registry MAY stop (oldest
    /// first) to recover `targetMiB`, EXCLUDING callers listed as active and
    /// never selecting a lease below 256 MiB of recoverable RAM. The pool
    /// itself stops nothing — the registry executes its own safe stop path.
    public func idleReclaimCandidates(
        activeRuntimeIDs: Set<String>,
        targetMiB: Int
    ) -> [String] {
        guard targetMiB > 0 else { return [] }
        let candidates = leases.values
            .filter { !activeRuntimeIDs.contains($0.runtimeID) }
            .sorted { $0.grantedAt < $1.grantedAt }
        var recovered = 0
        var result: [String] = []
        for lease in candidates {
            result.append(lease.runtimeID)
            recovered += lease.shape.memory.mb + configuration.hostOverheadMiB
            if recovered >= targetMiB { break }
        }
        return result
    }

    // MARK: shape changes (planned here, executed by the registry)

    /// Validates a shape change for a running lease BEFORE the stop/flush/
    /// restart path: VM slot is already held, but vCPUs, RAM, headroom and
    /// the image SMP gate must all accept the new shape alongside every
    /// OTHER lease. Throws the honest error; the running VM stays untouched.
    public func validateShapeChange(
        environmentID: String,
        request: GuestResourceRequest,
        imageSMPCapable: Bool
    ) throws {
        guard let current = runtimeByEnvironment[environmentID].flatMap({ leases[$0] }) else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        if request.vcpus == .two, !imageSMPCapable {
            throw LinuxGuestError.invalidConfiguration(
                "the image for \(environmentID) has no SMP capability evidence; a dual-hart restart is refused"
            )
        }
        let others = leases.values.filter { $0.runtimeID != current.runtimeID }
        let usedVCPUs = others.reduce(0) { $0 + $1.shape.vcpus.count }
        let usedMemory = others.reduce(0) { $0 + $1.shape.memory.mb }
        guard configuration.quota.vcpusFit(usedVCPUs: usedVCPUs, adding: request.vcpus.count) else {
            throw LinuxGuestError.capacityReached(
                detail: "moving \(environmentID) to \(request.vcpus.count) vCPU(s) would use \(usedVCPUs + request.vcpus.count) of the \(configuration.quota.totalVCPUs) vCPU quota"
            )
        }
        guard configuration.quota.memoryFits(usedMemoryMiB: usedMemory, adding: request.memory.mb) else {
            throw LinuxGuestError.capacityReached(
                detail: "moving \(environmentID) to \(request.memory.mb) MiB would reserve \(usedMemory + request.memory.mb) MiB of the \(configuration.quota.totalMemoryMiB) MiB quota; \(usedMemory) MiB is reserved by other guests"
            )
        }
        if let available = seams.availableHeadroomBytes() {
            let required = (request.memory.mb + configuration.hostOverheadMiB + configuration.futureReserveMiB) * 1_048_576
            guard available >= required else {
                throw LinuxGuestError.capacityReached(
                    detail: "the process currently has \(available) bytes of headroom; the new shape requires \(required); the running guest is left untouched"
                )
            }
        }
    }

    /// Legacy RAM-only validation used by the current integrator.
    public func validateRetier(environmentID: String, tier: RuntimeMemoryTier) throws {
        try validateShapeChange(
            environmentID: environmentID,
            request: GuestResourceRequest(
                vcpus: .one,
                memory: GuestMemoryMiB.smallestHolding(tier.mb) ?? .m2048
            ),
            imageSMPCapable: false
        )
    }

    /// Confirms a shape change after the registry executed the safe
    /// stop → flush → restart path. Records only what the restart made true.
    public func confirmShape(runtimeID: String, shape: GuestResourceRequest) {
        guard var lease = leases[runtimeID] else { return }
        lease.shape = shape
        leases[runtimeID] = lease
    }

    /// Legacy confirmation used by the current integrator (RAM only).
    public func confirmRetier(runtimeID: String, tier: RuntimeMemoryTier) {
        guard var lease = leases[runtimeID] else { return }
        let memory = GuestMemoryMiB.smallestHolding(tier.mb) ?? .m2048
        lease.shape = GuestResourceRequest(vcpus: lease.shape.vcpus, memory: memory)
        leases[runtimeID] = lease
    }

    /// Number of currently queued waiters (honest status reporting).
    public var queuedCount: Int { waiters.count }

    /// Marks every waiter interrupted (app shutdown path): continuations are
    /// resumed with an honest error and the durable entries are closed.
    public func interruptAll(reason: String) async {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            try? await registry?.setQueueEntryState(id: waiter.id, state: "interrupted", finished: true)
            waiter.continuation.resume(throwing: RuntimeV2Error.queueTimedOut(
                environmentID: waiter.environmentID, seconds: 0
            ))
        }
    }

    /// Legacy downgrade planner: which running leases must lower RAM (through
    /// stop/restart) so a queued request of `neededMB` fits. Empty = nothing
    /// needed; nil = even a full floor reduction cannot make room.
    public func downgradePlan(forQueuedMB neededMB: Int) -> [String: RuntimeMemoryTier]? {
        var tiers: [String: GuestMemoryMiB] = Dictionary(
            uniqueKeysWithValues: leases.values.map { ($0.runtimeID, $0.shape.memory) }
        )
        var reserved = tiers.values.reduce(0) { $0 + $1.mb }
        if reserved + neededMB <= configuration.quota.totalMemoryMiB { return [:] }
        let order = tiers.sorted { $0.value > $1.value }.map(\.key)
        var plan: [String: RuntimeMemoryTier] = [:]
        while reserved + neededMB > configuration.quota.totalMemoryMiB {
            guard let candidate = order.first(where: { (tiers[$0]?.mb ?? 0) > 256 }) else { return nil }
            guard let next = tiers[candidate]?.lowered() else { return nil }
            reserved -= (tiers[candidate]?.mb ?? 0) - next.mb
            tiers[candidate] = next
            plan[candidate] = RuntimeMemoryTier.tier(forRequestedMB: next.mb)
        }
        return plan
    }
}

/// Process-headroom probe wrapping `os_proc_available_memory()`.
enum RuntimeProcessHeadroom {
    /// Bytes the OS estimates the app may still allocate; nil when the API
    /// is unavailable (including macOS). This reflects RESIDENT charges
    /// (guest pages only once touched), which is why the pool combines it
    /// with the quota's not-yet-fulfilled lease accounting instead of using
    /// either alone.
    static func availableBytes() -> Int? {
        #if os(iOS) || os(tvOS) || os(watchOS)
        if #available(iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let bytes = os_proc_available_memory()
            return bytes == 0 ? nil : Int(bytes)
        }
        #endif
        return nil
    }
}
