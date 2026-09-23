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
//
// RELEASE CAPABILITY (B4): engine capacity, image-manifest claims and device
// quota are all DISTINCT from what this release is qualified to ship. Real
// cloud qualification (GitHub Actions run 35851127603) proved the fresh SMP
// kernel boots and serves parallel 9P on one hart while two harts stall at
// the first fork/exec, with no measurable dual speedup.
// The authoritative per-release gate is therefore `GuestReleaseShapePolicy`
// (single hart only) and is enforced at EVERY production boundary — pool
// admission, reshape planning/confirmation, the registry and direct runtime
// construction — independent of the image manifest (`smp=true` is never
// authority), environment variables or loose integer inputs. Synthetic SMP
// engine/admission experiments stay possible ONLY through an explicit internal
// test policy value passed by code (never env vars, never a manifest).

import Foundation

/// Error raised when a request asks for a vCPU shape THIS release cannot
/// deliver (an unsupported explicit count or a malformed/loose integer).
/// Distinct from `LinuxGuestError` (which lives in the Linux layer): the
/// release gate is a ResourcePolicy decision applied by every boundary.
public enum GuestReleaseShapeError: Error, LocalizedError, Sendable, Equatable {
    /// The requested vCPU count is supported by the engine ladder but is not
    /// qualified for this release (e.g. two harts while dual stays unproven).
    case unsupportedReleaseVCPUCount(requested: Int, releaseMaximum: Int)
    /// The loose input is not any expressible guest count (0, negative, or
    /// above the engine ceiling) — it must be rejected, never clamped.
    case invalidVCPUCount(requested: Int, supportedRange: ClosedRange<Int>)

    public var errorDescription: String? {
        switch self {
        case .unsupportedReleaseVCPUCount(let requested, let releaseMaximum):
            return "This release supports at most \(releaseMaximum) guest core; \(requested) cores are not qualified (dual-core boot stalls at fork/exec in cloud run 35851127603); choose a single-core guest."
        case .invalidVCPUCount(let requested, let range):
            return "Invalid guest core count \(requested); supported values are \(range.lowerBound)…\(range.upperBound)."
        }
    }
}

/// The AUTHORITATIVE per-release guest-shape qualification gate.
///
/// Engine capacity (`FLOE_VM_MAX_VCPU`), the image manifest's `smp` flag and
/// the device quota can never widen this: it states only what THIS release is
/// qualified to ship. The frozen `production` policy allows exactly one hart;
/// dual/six-hart support stays opt-in ONLY through `internalSyntheticTesting`,
/// an explicit code-supplied value for synthetic engine/admission tests, which
/// is unreachable from manifests, environment variables or user input and is
/// never assembled by the app.
public struct GuestReleaseShapePolicy: Sendable, Equatable {
    /// Maximum vCPU count one guest may be granted in THIS release.
    public let maximumSupportedVCPUs: Int
    /// True only for the explicit internal synthetic-test configuration.
    public let isInternalSyntheticTesting: Bool
    /// Free-form provenance for test policies (test/host id); production is nil.
    public let syntheticProvenance: String?

    private init(maximumSupportedVCPUs: Int, synthetic: Bool, provenance: String?) {
        self.maximumSupportedVCPUs = max(1, min(GuestVCPUCount.allCases.map(\.rawValue).max() ?? 1, maximumSupportedVCPUs))
        self.isInternalSyntheticTesting = synthetic
        self.syntheticProvenance = provenance
    }

    /// The release policy. Frozen: exactly one hart until a real release
    /// changes this type with fresh dual-boot/performance qualification.
    public static let production = GuestReleaseShapePolicy(maximumSupportedVCPUs: 1, synthetic: false, provenance: nil)

    /// Explicit internal test configuration: unlocks the engine ladder for
    /// SYNTHETIC SMP engine/admission experiments. There is intentionally no
    /// environment-variable or manifest path to this value; the `provenance`
    /// string names the test host so misuse is visible in logs/evidence.
    public static func internalSyntheticTesting(
        maximumSupportedVCPUs: Int = 2,
        provenance: String
    ) -> GuestReleaseShapePolicy {
        GuestReleaseShapePolicy(
            maximumSupportedVCPUs: maximumSupportedVCPUs,
            synthetic: true,
            provenance: provenance
        )
    }

    /// Applies the release gate to an already typed ladder value.
    public func requireReleased(_ vcpus: GuestVCPUCount) throws -> GuestVCPUCount {
        guard vcpus.rawValue <= maximumSupportedVCPUs else {
            throw GuestReleaseShapeError.unsupportedReleaseVCPUCount(
                requested: vcpus.rawValue, releaseMaximum: maximumSupportedVCPUs
            )
        }
        return vcpus
    }

    /// True when the typed value is releasable under this policy.
    public func supports(_ vcpus: GuestVCPUCount) -> Bool {
        vcpus.rawValue <= maximumSupportedVCPUs
    }

    /// Parses a loose integer into the typed ladder UNDER THE RELEASE GATE:
    /// malformed/out-of-engine-range input (0, negative, six, …) throws
    /// `invalidVCPUCount`, and an engine-supported but release-unqualified
    /// count throws `unsupportedReleaseVCPUCount` — it is never clamped onto
    /// another count. nil means "no explicit request" and answers the single
    /// safe default, which every auto path must still re-check.
    public func resolve(requestedVCPUs: Int?) throws -> GuestVCPUCount {
        guard let requested = requestedVCPUs else { return .one }
        guard let value = GuestVCPUCount(rawValue: requested) else {
            let supported = GuestVCPUCount.allCases.map(\.rawValue).min()!...GuestVCPUCount.allCases.map(\.rawValue).max()!
            throw GuestReleaseShapeError.invalidVCPUCount(requested: requested, supportedRange: supported)
        }
        return try requireReleased(value)
    }
}

/// vCPU count requested for ONE guest VM.
public enum GuestVCPUCount: Int, Sendable, CaseIterable, Codable, Comparable {
    case one = 1
    case two = 2

    public static func < (lhs: GuestVCPUCount, rhs: GuestVCPUCount) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var count: Int { rawValue }
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

    /// Builds a request from loose MB/CPU inputs under the release gate.
    /// Memory above the ceiling clamps to 2048, below the floor to 256; the
    /// vCPU count is NEVER clamped — malformed/out-of-range or
    /// release-unqualified counts throw through the policy so an explicit
    /// request for two/six cores can never become a silent one/two-core boot.
    public static func resolved(
        requestedVCPUs: Int?,
        requestedMB: Int?,
        origin: GuestRequestOrigin = .workerDefault,
        releasePolicy: GuestReleaseShapePolicy = .production
    ) throws -> GuestResourceRequest {
        let memory: GuestMemoryMiB
        if let requestedMB {
            memory = GuestMemoryMiB.smallestHolding(max(0, requestedMB)) ?? .m2048
        } else {
            memory = .m512
        }
        return GuestResourceRequest(
            vcpus: try releasePolicy.resolve(requestedVCPUs: requestedVCPUs),
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
