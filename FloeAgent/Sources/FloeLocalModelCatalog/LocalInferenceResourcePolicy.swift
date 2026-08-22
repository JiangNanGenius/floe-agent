import Foundation

/// Conservative device-side loading limits for GGUF models. The policy is
/// deliberately independent from llama.cpp so it can be tested without ever
/// mapping model weights on the development Mac.
public struct LocalInferenceResourceProfile: Sendable, Equatable {
    public let contextSize: UInt32
    public let batchSize: UInt32
    public let gpuLayers: Int32
    public let maximumOutputTokens: Int

    public init(
        contextSize: UInt32,
        batchSize: UInt32,
        gpuLayers: Int32,
        maximumOutputTokens: Int
    ) {
        self.contextSize = contextSize
        self.batchSize = batchSize
        self.gpuLayers = gpuLayers
        self.maximumOutputTokens = maximumOutputTokens
    }
}

public enum LocalInferenceResourcePolicy {
    /// Keep enough headroom for SwiftUI, the database, Metal scratch buffers,
    /// KV cache and decoded images. Disk size is an imperfect estimate of
    /// resident memory, but it provides a deterministic preflight that turns
    /// an otherwise uncatchable iOS jetsam into a useful error.
    public static func canLoad(
        mappedBytes: UInt64,
        physicalMemoryBytes: UInt64
    ) -> Bool {
        guard physicalMemoryBytes > 0 else { return true }
        return mappedBytes <= physicalMemoryBytes * 62 / 100
    }

    public static func profile(
        mappedBytes: UInt64,
        physicalMemoryBytes: UInt64
    ) -> LocalInferenceResourceProfile {
        guard physicalMemoryBytes > 0 else {
            return .init(contextSize: 3_072, batchSize: 128, gpuLayers: 20, maximumOutputTokens: 768)
        }
        let pressure = Double(mappedBytes) / Double(physicalMemoryBytes)
        if pressure >= 0.45 {
            return .init(contextSize: 3_072, batchSize: 96, gpuLayers: 16, maximumOutputTokens: 768)
        }
        if pressure >= 0.30 {
            return .init(contextSize: 4_096, batchSize: 128, gpuLayers: 24, maximumOutputTokens: 1_024)
        }
        return .init(contextSize: 4_096, batchSize: 128, gpuLayers: 99, maximumOutputTokens: 1_024)
    }
}
