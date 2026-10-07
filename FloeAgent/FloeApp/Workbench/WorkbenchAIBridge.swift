// FloeApp — AI bridge for the media workbench.
//
// The workbench AI drawer reuses the EXISTING configured image providers and
// the durable video model/job infrastructure. It never introduces a new
// provider integration and never invents prices: cost notes come only from
// provider-reported metadata, otherwise they state that the provider account
// is authoritative.

import Foundation
import FloeCore
import FloeWorkbench

struct WorkbenchAIModelInfo: Identifiable, Hashable, Sendable {
    var id: UUID
    var displayName: String
    var remoteModelID: String
    var providerName: String
}

struct WorkbenchAIJobInfo: Identifiable, Hashable, Sendable {
    var id: UUID
    var state: String
    var progress: Double?
    var message: String?
    var isActive: Bool
    var isWaitStopped: Bool
    var modelName: String
}

struct WorkbenchVideoAIOptions: Sendable, Hashable {
    var durationSeconds: Double?
    var aspectRatio: String?
    var resolution: String?
}

struct WorkbenchAIBridge: Sendable {
    var isAvailable: @Sendable () async -> Bool
    var imageModels: @MainActor @Sendable () -> [WorkbenchAIModelInfo]
    var videoModels: @MainActor @Sendable () -> [WorkbenchAIModelInfo]
    var generateImages: @MainActor @Sendable (_ prompt: String, _ modelID: UUID, _ size: String?,
                                              _ count: Int, _ sourceURL: URL?) async throws -> [URL]
    var submitVideo: @MainActor @Sendable (_ prompt: String, _ modelID: UUID,
                                           _ options: WorkbenchVideoAIOptions, _ projectID: UUID,
                                           _ referenceURL: URL?) async throws -> UUID
    var refreshJob: @MainActor @Sendable (_ jobID: UUID) async throws -> WorkbenchAIJobInfo
    var cancelJob: @MainActor @Sendable (_ jobID: UUID) async throws -> Void
    var jobs: @MainActor @Sendable (_ projectID: UUID) async -> [WorkbenchAIJobInfo]
    var deliverResult: @MainActor @Sendable (_ jobID: UUID) async throws -> URL
    /// Provider-reported price text only; nil means the provider does not
    /// report pricing and the UI states that honestly.
    var costNote: @MainActor @Sendable (_ modelID: UUID) -> String
}
