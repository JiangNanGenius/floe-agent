// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBiologyCore

public protocol BiologyBackend: Sendable {
    var environmentID: String { get }
    var engineVersion: String { get }
    var methods: Set<String> { get }
    func evaluate(projectID: UUID, asset: BiologyAsset, method: String, options: JSONValue, runID: UUID, owner: BiologyExecutionOwner?) async throws -> BiologyAnalysisResult
    /// Return only after the corresponding owned worker has really stopped.
    func cancel(runID: UUID) async throws
}
public struct NativeBiologyBackend: BiologyBackend {
    public let environmentID = "native.local"
    public let engineVersion = "FloeBiologyNative/1"
    public let methods = Set(BiologyNativeAnalysis.methods.values.flatMap{$0})
    public init() {}
    public func evaluate(projectID: UUID, asset: BiologyAsset, method: String, options: JSONValue, runID: UUID, owner: BiologyExecutionOwner?) async throws -> BiologyAnalysisResult {
        try BiologyNativeAnalysis.run(asset:asset,method:method,options:options)
    }
    public func cancel(runID: UUID) async throws { /* The service cancels and awaits its native Task. */ }
}
