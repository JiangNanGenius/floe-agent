// FloeExecution — ResourcePolicy: process-wide vCPU/RAM/VM quota + defaults.
//
// SPDX-License-Identifier: MPL-2.0
//
// One `GuestResourceQuota` bounds the WHOLE guest pool on a device:
//   total vCPUs the pool may hand out / total guest RAM / maximum running VMs.
// Admission checks all three dimensions against the same quota, so nothing is
// deducted twice. The default policy (user-approved):
//
//   iPhone  ≤4GB → 1 vCPU /  512 MiB / 1 VM
//            6GB → 2 vCPU / 1024 MiB / 2 VM
//            8GB → 2 vCPU / 1536 MiB / 2 VM
//           ≥12GB → 3 vCPU / 2048 MiB / 3 VM
//   iPad    ≤4GB → 1 vCPU /  512 MiB / 1 VM      (same as iPhone)
//            6GB → 2 vCPU / 1024 MiB / 2 VM      (same as iPhone)
//            8GB → 4 vCPU / 2048 MiB / 4 VM
//           12GB → 4 vCPU / 3072 MiB / 4 VM
//           ≥16GB → 4 vCPU / 4096 MiB / 4 VM
//
// The table is driven only by the ACTUAL family / physical RAM / available
// cores — there is no speculative model-identifier matching. The user's
// M-class iPad Air with the 12 GB configuration therefore reaches the
// 4 vCPU / 3 GiB / 4 VM policy through the generic 12 GB iPad row.
// CPU totals are additionally clamped to the cores the process can use.

import Foundation
import FloeCore

public struct GuestResourceQuota: Sendable, Equatable, Codable {
    /// Total vCPUs every running guest may hold together.
    public var totalVCPUs: Int
    /// Total guest RAM (MiB) every running guest may reserve together.
    public var totalMemoryMiB: Int
    /// Maximum number of simultaneous VMs (running + starts in flight).
    public var maxVMs: Int
    /// Where this quota came from (honest reporting).
    public var source: Source

    public enum Source: String, Sendable, Equatable, Codable {
        case defaultPolicy
        case performanceTier
        case userOverride
        case custom
    }

    public init(
        totalVCPUs: Int,
        totalMemoryMiB: Int,
        maxVMs: Int,
        source: Source = .defaultPolicy
    ) {
        self.totalVCPUs = max(1, totalVCPUs)
        self.totalMemoryMiB = max(256, totalMemoryMiB)
        self.maxVMs = max(1, maxVMs)
        self.source = source
    }

    /// The user-approved default quota for a real host observation.
    public static func defaultQuota(for profile: HostResourceProfile) -> GuestResourceQuota {
        let bucket = profile.memoryBucket
        // The pool can never hand out more host execution capacity than the
        // OS gives this process. Interpreted guests are cooperative, but a
        // quota above the usable core count is fiction.
        func quota(vcpus: Int, memory: Int, vms: Int) -> GuestResourceQuota {
            GuestResourceQuota(
                totalVCPUs: min(vcpus, max(1, profile.activeProcessorCount)),
                totalMemoryMiB: memory,
                maxVMs: vms
            )
        }
        switch profile.family {
        case .phone:
            switch bucket {
            case .upTo4GB:
                return quota(vcpus: 1, memory: 512, vms: 1)
            case .around6GB:
                return quota(vcpus: 2, memory: 1024, vms: 2)
            case .around8GB:
                return quota(vcpus: 2, memory: 1536, vms: 2)
            case .around12GB, .atLeast16GB:
                return quota(vcpus: 3, memory: 2048, vms: 3)
            }
        case .pad:
            switch bucket {
            case .upTo4GB:
                return quota(vcpus: 1, memory: 512, vms: 1)
            case .around6GB:
                return quota(vcpus: 2, memory: 1024, vms: 2)
            case .around8GB:
                return quota(vcpus: 4, memory: 2048, vms: 4)
            case .around12GB:
                return quota(vcpus: 4, memory: 3072, vms: 4)
            case .atLeast16GB:
                return quota(vcpus: 4, memory: 4096, vms: 4)
            }
        case .mac, .unknown:
            // Developer/host default. Kept identical to the pre-policy
            // RuntimeVMPool defaults (4 slots, 2 GiB on a large-RAM host) so
            // host-side SwiftPM tests see no capacity change. Guest pools
            // are not a release target on these families.
            let budget = RuntimeMemoryBudget(physicalMemoryBytes: profile.physicalMemoryBytes)
            return quota(vcpus: 4, memory: budget.totalMB, vms: 4)
        }
    }

    // MARK: gated performance tier

    /// Immutable evidence that the six-quota performance tier was verified
    /// on a real device (SMP boot, thermal stability, sustained workload).
    /// It is a frozen per-instance value: there is no mutable global switch,
    /// so no code path can enable the tier without producing real evidence
    /// at the call site. The production app does not construct one until
    /// the verification record exists; B2 selects the quota at assembly.
    public struct PerformanceTierEvidence: Sendable, Equatable, Codable {
        /// Qualification run id (cloud/device evidence record).
        public let verificationRunID: String
        public let verifiedAt: Date
        /// Device the evidence applies to (uname identifier).
        public let hardwareIdentifier: String

        public init(verificationRunID: String, verifiedAt: Date, hardwareIdentifier: String) {
            let runID = verificationRunID.trimmingCharacters(in: .whitespacesAndNewlines)
            let hardware = hardwareIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            precondition(!runID.isEmpty, "performance tier evidence requires a real verification run id")
            precondition(!hardware.isEmpty, "performance tier evidence requires the device it was verified on")
            self.verificationRunID = runID
            self.verifiedAt = verifiedAt
            self.hardwareIdentifier = hardware
        }
    }

    /// Six-quota performance policy: iPad 12 GB class and up, only with
    /// concrete evidence that (a) names a real verification run and (b) was
    /// produced on the SAME hardware the profile observes — evidence for a
    /// different device fails closed.
    ///
    /// The six-CPU tier does NOT authorize raising the device's RAM ceiling:
    /// total guest memory stays at the default quota's RAM budget for this
    /// device (3072 MiB on a 12 GB iPad, 4096 from 16 GB up), never above it.
    public static func performanceQuota(
        for profile: HostResourceProfile,
        evidence: PerformanceTierEvidence
    ) -> GuestResourceQuota? {
        guard profile.family == .pad else { return nil }
        switch profile.memoryBucket {
        case .around12GB, .atLeast16GB:
            break
        case .upTo4GB, .around6GB, .around8GB:
            return nil
        }
        // Hardware binding: empty identifiers are not evidence, and a
        // mismatch cannot be used for this device.
        let actual = profile.hardwareIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let proven = evidence.hardwareIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actual.isEmpty, !proven.isEmpty, actual == proven else { return nil }

        let memoryCeiling = GuestResourceQuota.defaultQuota(for: profile).totalMemoryMiB
        return GuestResourceQuota(
            totalVCPUs: min(6, max(1, profile.activeProcessorCount)),
            totalMemoryMiB: min(4096, memoryCeiling),
            maxVMs: 4,
            source: .performanceTier
        )
    }

    // MARK: pure budget checks (no double deduction)

    public func hasRoomForVM(runningVMs: Int) -> Bool { runningVMs < maxVMs }

    public func vcpusFit(usedVCPUs: Int, adding count: Int) -> Bool {
        usedVCPUs + count <= totalVCPUs
    }

    public func memoryFits(usedMemoryMiB: Int, adding mb: Int) -> Bool {
        usedMemoryMiB + mb <= totalMemoryMiB
    }
}
