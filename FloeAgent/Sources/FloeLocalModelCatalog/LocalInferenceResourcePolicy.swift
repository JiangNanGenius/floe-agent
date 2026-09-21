import Foundation
import FloeCore
#if os(iOS)
import Darwin
#endif

/// Conservative device-side loading limits for local model weights. The policy
/// is deliberately independent from a concrete runtime so it can be tested without ever
/// mapping model weights on the development Mac.
public enum LocalInferenceResourceTier: String, Sendable, Codable, Equatable {
    case constrained
    case balanced
    case roomy
}

public struct LocalInferenceResourceProfile: Sendable, Equatable {
    public let tier: LocalInferenceResourceTier
    public let contextSize: UInt32
    public let batchSize: UInt32
    public let gpuLayers: Int32
    public let maximumOutputTokens: Int

    public init(
        tier: LocalInferenceResourceTier,
        contextSize: UInt32,
        batchSize: UInt32,
        gpuLayers: Int32,
        maximumOutputTokens: Int
    ) {
        self.tier = tier
        self.contextSize = contextSize
        self.batchSize = batchSize
        self.gpuLayers = gpuLayers
        self.maximumOutputTokens = maximumOutputTokens
    }
}

public enum LocalInferenceResourcePolicy {
    /// Apple recommends using the current process allowance on iOS rather
    /// than treating the device's installed physical RAM as the app limit.
    public static func availableMemoryBytes() -> UInt64 {
        #if os(iOS)
        UInt64(os_proc_available_memory())
        #else
        ProcessInfo.processInfo.physicalMemory
        #endif
    }

    /// Effective headroom for a local model: the live process allowance minus
    /// the memory other in-process runtimes have already been admitted to use
    /// (for example a running TinyEMU Linux guest with its fixed RAM budget).
    ///
    /// The subtraction is deliberately conservative: on iOS
    /// `os_proc_available_memory()` reflects the allowance at this instant and
    /// does not include memory a guest is still allowed to grow into, so a
    /// model must not be admitted on top of that budget. A model that cannot
    /// start must be refused here rather than crash the process later.
    public static func effectiveHeadroomBytes(
        physicalMemoryBytes: UInt64? = nil,
        reservedBytes: Int64? = nil
    ) -> UInt64 {
        let allowance = physicalMemoryBytes ?? availableMemoryBytes()
        let reserved = reservedBytes ?? ResidentMemoryReservations.totalBytes()
        guard reserved > 0 else { return allowance }
        let reservedBytes = UInt64(reserved)
        return reservedBytes >= allowance ? 0 : allowance - reservedBytes
    }

    /// Keep enough headroom for SwiftUI, the database, Metal scratch buffers,
    /// KV cache and decoded images. Disk size is an imperfect estimate of
    /// resident memory, but it provides a deterministic preflight that turns
    /// an otherwise uncatchable iOS jetsam into a useful error.
    public static func canLoad(
        mappedBytes: UInt64,
        physicalMemoryBytes: UInt64,
        reservedBytes: Int64? = nil
    ) -> Bool {
        let headroom = effectiveHeadroomBytes(
            physicalMemoryBytes: physicalMemoryBytes,
            reservedBytes: reservedBytes ?? ResidentMemoryReservations.totalBytes()
        )
        guard headroom > 0 else { return false }
        // Callers pass os_proc_available_memory on iOS. Comparing a
        // safetensors file byte-for-byte with that instantaneous allowance is
        // incorrect for MLX: weights are memory-mapped and iPadOS can reclaim
        // other background processes as pages become resident. Permit a Q4
        // snapshot up to 110% of the current headroom, while still rejecting
        // clearly impossible loads before they reach an uncatchable Jetsam.
        return mappedBytes <= headroom * 110 / 100
    }

    public static func profile(
        mappedBytes: UInt64,
        physicalMemoryBytes: UInt64,
        reservedBytes: Int64? = nil
    ) -> LocalInferenceResourceProfile {
        let headroom = effectiveHeadroomBytes(
            physicalMemoryBytes: physicalMemoryBytes,
            reservedBytes: reservedBytes ?? ResidentMemoryReservations.totalBytes()
        )
        guard headroom > 0 else {
            return .init(
                tier: .constrained,
                contextSize: 8_192,
                batchSize: 32,
                gpuLayers: 20,
                maximumOutputTokens: 1_024
            )
        }
        let pressure = Double(mappedBytes) / Double(headroom)
        // A large memory-mapped model can be loadable while leaving almost
        // no instantaneous process allowance for prompt evaluation and KV
        // growth. Keep that load permitted (iPadOS may reclaim background
        // apps), but keep prefill and KV precision conservative so the first
        // decode does not immediately consume another large allocation. A 2K
        // context made an otherwise healthy local agent unusable after one
        // tool result, so every supported 4B model now has an 8K floor.
        if pressure >= 0.90 {
            return .init(
                tier: .constrained,
                contextSize: 8_192,
                batchSize: 32,
                gpuLayers: 12,
                maximumOutputTokens: 1_024
            )
        }
        if pressure >= 0.58 {
            return .init(
                tier: .constrained,
                contextSize: 8_192,
                batchSize: 48,
                gpuLayers: 16,
                maximumOutputTokens: 1_024
            )
        }
        if pressure >= 0.34 {
            return .init(
                tier: .balanced,
                contextSize: 12_288,
                batchSize: 96,
                gpuLayers: 24,
                maximumOutputTokens: 1_536
            )
        }
        // Small Q4 models on 12-16 GB devices have enough headroom for a
        // materially useful agent context. Keep the batch modest: the larger
        // context is primarily KV-cache capacity, not a reason to increase the
        // transient prompt-evaluation allocation as well.
        return .init(
            tier: .roomy,
            contextSize: 16_384,
            batchSize: 128,
            gpuLayers: 99,
            maximumOutputTokens: 1_536
        )
    }
}
