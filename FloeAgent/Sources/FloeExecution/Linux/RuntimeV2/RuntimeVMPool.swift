// FloeExecution — Runtime v2 VM pool: bounded concurrency, FIFO queue, tiers.
//
// At most `maxRunning` VMs (production: four) hold pool slots at any time. A
// request that cannot be admitted does NOT fail immediately: it enters a
// bounded FIFO queue and waits, cancellable, up to `queueTimeout`; the entry
// is recorded in the registry's queue table so an app restart can mark
// interrupted starts explicitly instead of losing them. Admission speaks in
// memory tiers against the device-class budget (1.5 / 2 GiB): a request is
// granted at its requested tier when it fits, otherwise at the highest tier
// that still fits (never below the floor), otherwise it queues.
//
// The pinned TinyEMU engine has no balloon/resize API — guest RAM is fixed at
// create time — so a tier change for a running VM is impossible online. The
// pool therefore only PLANS tier changes (`downgradePlan(forQueuedMB:)`); the
// guest registry executes them through the safe stop → flush → restart path
// and confirms with `confirmRetier`. Nothing here ever claims online
// ballooning happened.

import Foundation
import FloeCore

public actor RuntimeVMPool {
    public struct Configuration: Sendable, Equatable {
        public var maxRunning: Int
        public var budget: RuntimeMemoryBudget
        public var queueLimit: Int
        public var queueTimeout: TimeInterval
        public var floorTier: RuntimeMemoryTier

        public init(
            maxRunning: Int = 4,
            budget: RuntimeMemoryBudget = .current(),
            queueLimit: Int = 32,
            queueTimeout: TimeInterval = 600,
            floorTier: RuntimeMemoryTier = .constrained
        ) {
            self.maxRunning = max(1, min(16, maxRunning))
            self.budget = budget
            self.queueLimit = max(1, min(128, queueLimit))
            self.queueTimeout = max(1, queueTimeout)
            self.floorTier = floorTier
        }
    }

    public struct Slot: Sendable, Equatable {
        public var runtimeID: String
        public var environmentID: String
        public var tier: RuntimeMemoryTier
        public var grantedAt: Date
        /// True when admission granted a tier below the request: the caller
        /// boots the VM with `tier` MB and reports the downgrade honestly.
        public var downgradedAtAdmission: Bool
    }

    public struct PoolStatus: Sendable, Equatable {
        public var running: Int
        public var queued: Int
        public var reservedMB: Int
        public var budgetMB: Int
        public var maxRunning: Int
    }

    private struct Waiter {
        var id: String
        var environmentID: String
        var requestedTier: RuntimeMemoryTier
        var enqueuedAt: Date
        var continuation: CheckedContinuation<Slot, Error>
    }

    private let configuration: Configuration
    private let registry: RuntimeV2Registry?
    private var slots: [String: Slot] = [:] // runtimeID → slot
    private var runtimeByEnvironment: [String: String] = [:]
    private var waiters: [Waiter] = []

    public init(configuration: Configuration, registry: RuntimeV2Registry? = nil) {
        self.configuration = configuration
        self.registry = registry
    }

    public var status: PoolStatus {
        PoolStatus(
            running: slots.count,
            queued: waiters.count,
            reservedMB: slots.values.reduce(0) { $0 + $1.tier.mb },
            budgetMB: configuration.budget.totalMB,
            maxRunning: configuration.maxRunning
        )
    }

    public func slot(environmentID: String) -> Slot? {
        runtimeByEnvironment[environmentID].flatMap { slots[$0] }
    }

    // MARK: acquire (immediate or queued)

    /// Admits a start request. Returns the granted slot immediately when
    /// capacity allows; otherwise the request queues (recorded durably) until
    /// a release makes room, the task is cancelled, or the queue timeout
    /// elapses. Re-entrant for an environment that already holds a slot.
    public func acquire(
        environmentID: String,
        runtimeID: String,
        requestedTier: RuntimeMemoryTier
    ) async throws -> Slot {
        try RuntimeV2Identifier.validate(environmentID, kind: .environment)
        try RuntimeV2Identifier.validate(runtimeID, kind: .runtime)
        if let existing = slot(environmentID: environmentID) {
            return existing
        }
        let reserved = slots.values.reduce(0) { $0 + $1.tier.mb }
        if slots.count < configuration.maxRunning,
           let tier = configuration.budget.admissionTier(
               requested: requestedTier, reservedMB: reserved, floor: configuration.floorTier
           ) {
            return await grant(
                environmentID: environmentID, runtimeID: runtimeID,
                tier: tier, downgraded: tier < requestedTier
            )
        }
        guard waiters.count < configuration.queueLimit else {
            throw RuntimeV2Error.queueFull(limit: configuration.queueLimit)
        }
        let entryID = runtimeID
        let queuedAt = Date()
        try await registry?.recordQueueEntry(
            RuntimeV2Registry.QueueRow(
                id: entryID, environmentID: environmentID, requestedMB: requestedTier.mb,
                state: "queued", enqueuedAt: queuedAt, startedAt: nil, finishedAt: nil
            )
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Slot, Error>) in
                let waiter = Waiter(
                    id: entryID, environmentID: environmentID,
                    requestedTier: requestedTier, enqueuedAt: queuedAt,
                    continuation: continuation
                )
                waiters.append(waiter)
                scheduleTimeout(for: entryID)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: entryID, reason: "cancelled") }
        }
    }

    private func scheduleTimeout(for entryID: String) {
        let timeout = configuration.queueTimeout
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.cancelWaiter(id: entryID, reason: "timed out")
        }
    }

    private func cancelWaiter(id: String, reason: String) async {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        try? await registry?.setQueueEntryState(id: id, state: reason == "cancelled" ? "cancelled" : "interrupted", finished: true)
        if reason == "cancelled" {
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            waiter.continuation.resume(throwing: RuntimeV2Error.queueTimedOut(
                environmentID: waiter.environmentID, seconds: Int(configuration.queueTimeout)
            ))
        }
    }

    private func grant(
        environmentID: String, runtimeID: String, tier: RuntimeMemoryTier, downgraded: Bool
    ) async -> Slot {
        let slot = Slot(
            runtimeID: runtimeID, environmentID: environmentID,
            tier: tier, grantedAt: Date(), downgradedAtAdmission: downgraded
        )
        slots[runtimeID] = slot
        runtimeByEnvironment[environmentID] = runtimeID
        return slot
    }

    // MARK: release + waiter promotion

    /// Releases a slot and promotes queued waiters in FIFO order. A waiter
    /// whose request cannot fit even at the floor tier stays queued; later
    /// waiters that do fit are not blocked behind it forever.
    public func release(runtimeID: String) async {
        guard let slot = slots.removeValue(forKey: runtimeID) else { return }
        runtimeByEnvironment.removeValue(forKey: slot.environmentID)
        if registry != nil {
            try? await registry?.setQueueEntryState(id: runtimeID, state: "done", finished: true)
        }
        await promoteWaiters()
    }

    private func promoteWaiters() async {
        var index = 0
        while index < waiters.count {
            guard slots.count < configuration.maxRunning else { return }
            let waiter = waiters[index]
            let reserved = slots.values.reduce(0) { $0 + $1.tier.mb }
            guard let tier = configuration.budget.admissionTier(
                requested: waiter.requestedTier, reservedMB: reserved, floor: configuration.floorTier
            ) else {
                index += 1
                continue
            }
            waiters.remove(at: index)
            let slot = await grant(
                environmentID: waiter.environmentID, runtimeID: waiter.id,
                tier: tier, downgraded: tier < waiter.requestedTier
            )
            try? await registry?.setQueueEntryState(id: waiter.id, state: "running", started: true)
            waiter.continuation.resume(returning: slot)
        }
    }

    // MARK: tier changes (planned here, executed by the registry)

    /// Plans which running VMs must step down so a queued request fits, using
    /// the device budget's minimal-restart plan. Empty dictionary = no
    /// downgrade needed; nil = even every VM at the floor cannot make room.
    public func downgradePlan(forQueuedMB neededMB: Int) -> [String: RuntimeMemoryTier]? {
        configuration.budget.downgradePlan(
            running: slots.map { ($0.key, $0.value.tier) },
            neededMB: neededMB,
            floor: configuration.floorTier
        )
    }

    /// Validates a requested tier change for a running VM: the new tier must
    /// fit the device budget alongside every OTHER running VM. Throws
    /// `capacityReached` with the honest numbers when it cannot fit — the
    /// caller leaves the running VM untouched.
    public func validateRetier(environmentID: String, tier: RuntimeMemoryTier) throws {
        guard let current = slot(environmentID: environmentID) else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        let othersReserved = slots.values
            .filter { $0.runtimeID != current.runtimeID }
            .reduce(0) { $0 + $1.tier.mb }
        guard configuration.budget.fits(reservedMB: othersReserved, addingMB: tier.mb) else {
            throw LinuxGuestError.capacityReached(
                detail: "moving \(environmentID) to the \(tier.mb) MB tier would reserve \(othersReserved + tier.mb) MB of the \(configuration.budget.totalMB) MB device guest RAM budget; \(othersReserved) MB is reserved by other guests"
            )
        }
    }

    /// Confirms a tier change after the caller executed the safe
    /// stop → flush → restart path. The engine cannot balloon online; this
    /// only records what the restart already made true.
    public func confirmRetier(runtimeID: String, tier: RuntimeMemoryTier) {
        guard var slot = slots[runtimeID] else { return }
        slot.tier = tier
        slots[runtimeID] = slot
    }

    /// Number of currently queued waiters (for honest status reporting).
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
}
