import Foundation

/// Host physical allocation accounting. Logical resources and mapped aliases
/// describe the same allocations from other views and must not be added.
public struct ARM64GPUBudget: Sendable, Equatable {
    public var present: Bool
    public var requestedBytes: UInt64
    public var effectiveBytes: UInt64
    public var targetBytes: UInt64
    public var hostBlobBytes: UInt64
    public var hostInternalBytes: UInt64
    public var logicalResourceBytes: UInt64
    public var mappedAliasBytes: UInt64
    public var pending: Bool
    public var clamped: Bool
    public var needsReset: Bool

    public var physicalBytes: UInt64 { hostBlobBytes + hostInternalBytes }
}
