import Foundation
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

    /// Keep enough headroom for SwiftUI, the database, Metal scratch buffers,
    /// KV cache and decoded images. Disk size is an imperfect estimate of
    /// resident memory, but it provides a deterministic preflight that turns
    /// an otherwise uncatchable iOS jetsam into a useful error.
    public static func canLoad(
        mappedBytes: UInt64,
        physicalMemoryBytes: UInt64
    ) -> Bool {
        guard physicalMemoryBytes > 0 else { return true }
        // Callers pass os_proc_available_memory on iOS. Comparing a
        // safetensors file byte-for-byte with that instantaneous allowance is
        // incorrect for MLX: weights are memory-mapped and iPadOS can reclaim
        // other background processes as pages become resident. Permit a Q4
        // snapshot up to 110% of the current allowance, while still rejecting
        // clearly impossible loads before they reach an uncatchable Jetsam.
        return mappedBytes <= physicalMemoryBytes * 110 / 100
    }

    public static func profile(
        mappedBytes: UInt64,
        physicalMemoryBytes: UInt64
    ) -> LocalInferenceResourceProfile {
        guard physicalMemoryBytes > 0 else {
            return .init(
                tier: .constrained,
                contextSize: 4_096,
                batchSize: 128,
                gpuLayers: 20,
                maximumOutputTokens: 768
            )
        }
        let pressure = Double(mappedBytes) / Double(physicalMemoryBytes)
        // A large memory-mapped model can be loadable while leaving almost
        // no instantaneous process allowance for prompt evaluation and KV
        // growth. Keep that load permitted (iPadOS may reclaim background
        // apps), but enter a minimum-scratch profile so the first decode does
        // not immediately consume another large allocation. Build 17 device
        // diagnostics showed Gemma at ~97.7% of the current allowance dying
        // during generation, after its container loaded successfully.
        if pressure >= 0.90 {
            return .init(
                tier: .constrained,
                contextSize: 2_048,
                batchSize: 32,
                gpuLayers: 12,
                maximumOutputTokens: 256
            )
        }
        if pressure >= 0.58 {
            return .init(
                tier: .constrained,
                contextSize: 4_096,
                batchSize: 96,
                gpuLayers: 16,
                maximumOutputTokens: 768
            )
        }
        if pressure >= 0.34 {
            return .init(
                tier: .balanced,
                contextSize: 8_192,
                batchSize: 128,
                gpuLayers: 24,
                maximumOutputTokens: 1_024
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
