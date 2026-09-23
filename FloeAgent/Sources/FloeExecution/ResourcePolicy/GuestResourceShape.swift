// FloeExecution — ResourcePolicy: vCPU/RAM request shapes and leases.
//
// SPDX-License-Identifier: MPL-2.0
//
// Resource admission speaks in these types instead of arbitrary megabyte
// counts: a guest requests exactly one `GuestResourceRequest` (1 or 2 vCPUs,
// one step of the 256…2048 MiB ladder) and, once admitted, holds one
// `GuestResourceLease`. Every dimension is expressible, countable and
// testable, so the pool can admit on CPU/RAM/VM simultaneously without
// double-deducting any budget.
//
// The pinned TinyEMU engine allocates guest RAM once at create time with no
// balloon/resize API and exposes at most two harts (`FLOE_VM_MAX_VCPU`).
// Nothing here claims an online shape change is possible: changes go through
// the safe stop → flush → restart path (see RuntimeVMPool).

import Foundation

/// vCPU count requested for ONE guest VM.
public enum GuestVCPUCount: Int, Sendable, CaseIterable, Codable, Comparable {
    case one = 1
    case two = 2

    public static func < (lhs: GuestVCPUCount, rhs: GuestVCPUCount) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var count: Int { rawValue }

    /// Maps an arbitrary requested count onto the ladder. Values above the
    /// ceiling clamp to `.two`; below the floor to `.one`.
    public static func clamping(_ requested: Int) -> GuestVCPUCount {
        requested >= 2 ? .two : .one
    }
}

/// One step of the guest RAM ladder. Raw values are MiB.
public enum GuestMemoryMiB: Int, Sendable, CaseIterable, Codable, Comparable {
    case m256 = 256
    case m512 = 512
    case m768 = 768
    case m1024 = 1024
    case m1536 = 1536
    case m2048 = 2048

    public static func < (lhs: GuestMemoryMiB, rhs: GuestMemoryMiB) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var mb: Int { rawValue }

    public init?(exactMB mb: Int) { self.init(rawValue: mb) }

    /// Smallest ladder step that can hold `mb`; nil above the 2 GiB ceiling.
    public static func smallestHolding(_ mb: Int) -> GuestMemoryMiB? {
        allCases.sorted().first { mb <= $0.rawValue }
    }

    /// Largest ladder step at or below `mb`; nil below the 256 MiB floor.
    public static func largestAtOrBelow(_ mb: Int) -> GuestMemoryMiB? {
        allCases.sorted().last { $0.rawValue <= mb }
    }

    /// The next smaller ladder step, or nil at the floor.
    public func lowered() -> GuestMemoryMiB? {
        GuestMemoryMiB.largestAtOrBelow(rawValue - 1)
    }

    /// The next LARGER declared ladder step, or nil at the 2 GiB ceiling.
    /// Deliberately steps by declaration order, never by rawValue + 256: the
    /// gaps above 1 GiB are 512 MiB, so arithmetic would miss 1536/2048.
    public func raised() -> GuestMemoryMiB? {
        GuestMemoryMiB.allCases.sorted().first { $0.rawValue > rawValue }
    }
}

/// Where a resource request came from (honest accounting, never authority:
/// admission still depends on quota, headroom and image capability).
public enum GuestRequestOrigin: String, Sendable, Equatable, Codable {
    /// Environment policy / manifest value.
    case environmentPolicy
    /// The GuestResourceAdvisory recommendation service.
    case recommendation
    /// The user explicitly chose this shape.
    case userSpecified
    /// No evidence: a worker default.
    case workerDefault
}

/// Explicit rule for whether admission may grant a shape below the request.
///
/// Aligned for CPU and RAM:
///  * `.strict` — the requested shape is the minimum; temporary shortage
///    QUEUES. Nothing is silently reduced.
///  * `.authorized` — the caller (e.g. an auto plan) explicitly accepts a
///    smaller shape within the floors supplied; the lease records the
///    downgrade and the reason.
public enum GuestShapeDowngradePolicy: Sendable, Equatable {
    case strict
    case authorized(
        vcpuFloor: GuestVCPUCount = .one,
        memoryFloor: GuestMemoryMiB = .m256
    )
}

/// What a guest asks the pool for.
public struct GuestResourceRequest: Sendable, Equatable, Codable {
    public var vcpus: GuestVCPUCount
    public var memory: GuestMemoryMiB
    public var origin: GuestRequestOrigin

    public init(
        vcpus: GuestVCPUCount = .one,
        memory: GuestMemoryMiB = .m512,
        origin: GuestRequestOrigin = .workerDefault
    ) {
        self.vcpus = vcpus
        self.memory = memory
        self.origin = origin
    }

    /// Builds a request from loose MB/CPU inputs; memory above the ceiling
    /// clamps to 2048, below the floor to 256.
    public static func from(
        requestedVCPUs: Int?,
        requestedMB: Int?,
        origin: GuestRequestOrigin = .workerDefault
    ) -> GuestResourceRequest {
        let memory: GuestMemoryMiB
        if let requestedMB {
            memory = GuestMemoryMiB.smallestHolding(max(0, requestedMB)) ?? .m2048
        } else {
            memory = .m512
        }
        return GuestResourceRequest(
            vcpus: GuestVCPUCount.clamping(requestedVCPUs ?? 1),
            memory: memory,
            origin: origin
        )
    }
}

/// What the pool granted. One lease covers one running VM (or a start in
/// flight) and is the unit that cancellation/failure/stop must return.
public struct GuestResourceLease: Sendable, Equatable, Codable {
    public var runtimeID: String
    public var environmentID: String
    public var shape: GuestResourceRequest
    public var grantedAt: Date
    /// Granted fewer vCPUs than requested. Only possible when the caller
    /// authorized downgrades; strict dual requests queue instead.
    public var vcpusDowngraded: Bool
    /// Granted a smaller RAM step than requested (never below the floor the
    /// caller authorized; strict requests queue instead).
    public var memoryDowngraded: Bool
    /// Why vCPUs were reduced (nil unless `vcpusDowngraded`).
    public var vcpusDowngradeReason: String?
    /// Why RAM was reduced (nil unless `memoryDowngraded`).
    public var memoryDowngradeReason: String?

    public init(
        runtimeID: String,
        environmentID: String,
        shape: GuestResourceRequest,
        grantedAt: Date,
        vcpusDowngraded: Bool = false,
        memoryDowngraded: Bool = false,
        vcpusDowngradeReason: String? = nil,
        memoryDowngradeReason: String? = nil
    ) {
        self.runtimeID = runtimeID
        self.environmentID = environmentID
        self.shape = shape
        self.grantedAt = grantedAt
        self.vcpusDowngraded = vcpusDowngraded
        self.memoryDowngraded = memoryDowngraded
        self.vcpusDowngradeReason = vcpusDowngradeReason
        self.memoryDowngradeReason = memoryDowngradeReason
    }

    public var wasDowngraded: Bool { vcpusDowngraded || memoryDowngraded }
}
