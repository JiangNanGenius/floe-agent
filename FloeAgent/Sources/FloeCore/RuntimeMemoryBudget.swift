// FloeCore — device-class guest memory budgets and per-VM memory tiers.
//
// SPDX-License-Identifier: MPL-2.0
//
// Runtime v2 admission is bounded by a device-class budget, not a compile-time
// constant: devices with little physical RAM admit up to 1.5 GiB of guest RAM,
// larger devices up to 2 GiB. Each admitted VM holds exactly one memory tier.
// The pinned TinyEMU engine allocates guest RAM once at `floe_vm_create` and
// has no balloon/resize API, so a tier change is only possible through the
// safe stop → flush → restart path (see RuntimeVMPool and the Linux guest
// registry); nothing here pretends online ballooning exists.

import Foundation

/// Device memory class used to pick the process-wide guest RAM budget.
public enum RuntimeDeviceMemoryClass: String, Sendable, CaseIterable {
    /// Devices with less than 12 GiB of physical RAM: 1.5 GiB guest budget.
    case compact
    /// Devices with at least 12 GiB of physical RAM: 2 GiB guest budget.
    case standard
}

/// One VM's memory tier. Raw values are MiB. Tiers are deliberately coarse:
/// admission, reporting and the stop/flush/restart tier-change path all speak
/// in tiers instead of arbitrary megabyte counts, so a budget plan is always
/// expressible and testable.
public enum RuntimeMemoryTier: Int, Sendable, CaseIterable, Comparable, Codable {
    /// Minimum practical tier and default for ordinary shell work.
    case constrained = 256
    /// Package installs and ordinary Node/Python services.
    case standard = 512
    /// Larger builds and services.
    case expanded = 768
    /// Per-VM ceiling for an explicitly heavy environment.
    case maximum = 1024

    public static func < (lhs: RuntimeMemoryTier, rhs: RuntimeMemoryTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var mb: Int { rawValue }

    /// The smallest tier that can hold `requestedMB`, clamped into the tier
    /// ladder. nil selects the default tier. Requests above the ceiling clamp
    /// down to `.maximum`, below the floor up to `.constrained`.
    public static func tier(forRequestedMB requested: Int?, minimumMB: Int = 96) -> RuntimeMemoryTier {
        guard let requested else { return .constrained }
        let floor = max(minimumMB, RuntimeMemoryTier.constrained.mb)
        let clamped = max(floor, min(RuntimeMemoryTier.maximum.mb, requested))
        for tier in RuntimeMemoryTier.allCases.sorted() where clamped <= tier.mb {
            return tier
        }
        return .maximum
    }
}

/// Process-wide guest RAM budget derived from the device's memory class.
public struct RuntimeMemoryBudget: Sendable, Equatable {
    public static let compactBudgetMB = 1536
    public static let standardBudgetMB = 2048
    /// Physical RAM boundary between the compact and standard classes.
    public static let standardFloorBytes: UInt64 = 12 * 1024 * 1024 * 1024

    public let deviceClass: RuntimeDeviceMemoryClass
    /// Total guest RAM all running VMs may reserve together, in MiB.
    public let totalMB: Int

    public init(deviceClass: RuntimeDeviceMemoryClass) {
        self.deviceClass = deviceClass
        self.totalMB = deviceClass == .compact
            ? RuntimeMemoryBudget.compactBudgetMB
            : RuntimeMemoryBudget.standardBudgetMB
    }

    /// Derives the class from physical memory (injectable for tests).
    public init(physicalMemoryBytes: UInt64) {
        self.init(deviceClass: physicalMemoryBytes >= RuntimeMemoryBudget.standardFloorBytes ? .standard : .compact)
    }

    /// Production default: classifies the current device.
    public static func current() -> RuntimeMemoryBudget {
        RuntimeMemoryBudget(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    /// True when `addingMB` still fits next to the already reserved tiers.
    public func fits(reservedMB: Int, addingMB: Int) -> Bool {
        reservedMB + addingMB <= totalMB
    }

    /// Admission plan for a new request: the requested tier when it fits,
    /// otherwise the highest tier that still fits (never below the floor the
    /// caller supplies), otherwise nil when nothing fits.
    public func admissionTier(
        requested: RuntimeMemoryTier,
        reservedMB: Int,
        floor: RuntimeMemoryTier = .constrained
    ) -> RuntimeMemoryTier? {
        if fits(reservedMB: reservedMB, addingMB: requested.mb) { return requested }
        for tier in RuntimeMemoryTier.allCases.sorted().reversed() where tier >= floor && tier < requested {
            if fits(reservedMB: reservedMB, addingMB: tier.mb) { return tier }
        }
        return nil
    }

    /// Computes which running VMs must step down one or more tiers so a queued
    /// request of `neededMB` can be admitted. Returns nil when even every
    /// running VM at `floor` cannot make room (the request then stays queued).
    /// Only tiers strictly above `floor` are lowered, and only as far as
    /// needed: the plan never over-shrinks the fleet.
    public func downgradePlan(
        running: [(id: String, tier: RuntimeMemoryTier)],
        neededMB: Int,
        floor: RuntimeMemoryTier = .constrained
    ) -> [String: RuntimeMemoryTier]? {
        var plan: [String: RuntimeMemoryTier] = [:]
        var reserved = running.reduce(0) { $0 + $1.tier.mb }
        if fits(reservedMB: reserved, addingMB: neededMB) { return [:] }
        // Largest consumers step down first, one tier at a time, until the
        // request fits; this keeps the number of restarts minimal.
        let order = running.sorted { $0.tier > $1.tier }
        var tiers = Dictionary(uniqueKeysWithValues: running.map { ($0.id, $0.tier) })
        func lowered(_ tier: RuntimeMemoryTier) -> RuntimeMemoryTier? {
            RuntimeMemoryTier.allCases.sorted().last { $0 >= floor && $0 < tier }
        }
        while !fits(reservedMB: reserved, addingMB: neededMB) {
            guard let candidate = order.first(where: { entry in
                let current = tiers[entry.id] ?? entry.tier
                return lowered(current) != nil
            }) else { return nil }
            let current = tiers[candidate.id] ?? candidate.tier
            guard let next = lowered(current) else { return nil }
            tiers[candidate.id] = next
            plan[candidate.id] = next
            reserved -= current.mb - next.mb
        }
        return plan
    }
}
