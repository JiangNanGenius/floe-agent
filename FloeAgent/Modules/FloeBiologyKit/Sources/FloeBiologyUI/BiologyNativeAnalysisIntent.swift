// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeBiologyCore

/// Created by the compiled native Run/Read-region controls. Not Codable:
/// imported project content and model arguments cannot mint native intent.
public struct BiologyNativeAnalysisIntent: Sendable {
    public enum Source: Sendable { case analysis, imageRegion }
    public let projectID: UUID
    public let assetID: UUID
    public let assetRevision: UInt64
    public let method: String
    public let options: JSONValue
    public let environmentID: String
    public let source: Source
    public init(projectID: UUID, assetID: UUID, assetRevision: UInt64, method: String,
                options: JSONValue, environmentID: String, source: Source = .analysis) {
        self.projectID = projectID; self.assetID = assetID; self.assetRevision = assetRevision
        self.method = method; self.options = options; self.environmentID = environmentID; self.source = source
    }
}
public typealias BiologyNativeAnalysisHandler = @MainActor @Sendable (BiologyNativeAnalysisIntent) async throws -> BiologyRun
public enum BiologyNativeImportedFile: Sendable {
    case asset(projectID: UUID, assetID: UUID)
    case project(UUID)
}
public typealias BiologyNativeFileImportHandler = @MainActor @Sendable (UUID, URL) async throws -> BiologyNativeImportedFile
public typealias BiologyNativeFileAuthorizationHandler = @MainActor @Sendable (UUID, UUID, UInt64) async throws -> BiologyAsset
#endif
