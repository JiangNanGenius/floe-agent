// FloeCore — User choices for onboarding and model routing.

import Foundation

public enum OnboardingStatus: String, Sendable, Codable, CaseIterable, Hashable {
    case unseen
    case skipped
    case completed
}

public enum AuxiliaryImageMode: String, Sendable, Codable, CaseIterable, Hashable {
    case shared
    case separate
}

/// Secret-free model routing preferences. Model references are cleared by
/// SQLite foreign keys when their target model is deleted.
public struct ModelSelectionPreferences: Sendable, Codable, Hashable {
    public var onboardingStatus: OnboardingStatus
    public var defaultAgentModelID: UUID?
    /// Optional Canvas-specific assistant route. Nil inherits the ordinary
    /// Agent default so a new user can open Canvas without extra setup.
    public var canvasAgentModelID: UUID?
    public var visionModelID: UUID?
    /// Optional Canvas-specific visual understanding route. Nil inherits the
    /// auxiliary vision model selected above.
    public var canvasVisionModelID: UUID?
    public var approvalModelID: UUID?
    /// Tool-free model used for managed Python package review. On-device
    /// format and sandbox checks remain authoritative.
    public var packageReviewModelID: UUID?
    public var auxiliaryImageMode: AuxiliaryImageMode
    public var sharedImageModelID: UUID?
    public var imageGenerationModelID: UUID?
    public var imageEditingModelID: UUID?
    /// Default video model used by Agent-initiated generation. Manual creative
    /// actions may still choose another enabled compatible model per request.
    public var defaultVideoModelID: UUID?
    public var updatedAt: Date
    public var syncRevision: Int64

    public init(
        onboardingStatus: OnboardingStatus = .unseen,
        defaultAgentModelID: UUID? = nil,
        canvasAgentModelID: UUID? = nil,
        visionModelID: UUID? = nil,
        canvasVisionModelID: UUID? = nil,
        approvalModelID: UUID? = nil,
        packageReviewModelID: UUID? = nil,
        auxiliaryImageMode: AuxiliaryImageMode = .shared,
        sharedImageModelID: UUID? = nil,
        imageGenerationModelID: UUID? = nil,
        imageEditingModelID: UUID? = nil,
        defaultVideoModelID: UUID? = nil,
        updatedAt: Date = Date(),
        syncRevision: Int64 = 0
    ) {
        self.onboardingStatus = onboardingStatus
        self.defaultAgentModelID = defaultAgentModelID
        self.canvasAgentModelID = canvasAgentModelID
        self.visionModelID = visionModelID
        self.canvasVisionModelID = canvasVisionModelID
        self.approvalModelID = approvalModelID
        self.packageReviewModelID = packageReviewModelID
        self.auxiliaryImageMode = auxiliaryImageMode
        self.sharedImageModelID = sharedImageModelID
        self.imageGenerationModelID = imageGenerationModelID
        self.imageEditingModelID = imageEditingModelID
        self.defaultVideoModelID = defaultVideoModelID
        self.updatedAt = updatedAt
        self.syncRevision = syncRevision
    }

    /// Applies the shared/separate image-routing transition without guessing
    /// unsupported roles. Callers provide the current capability lookup so
    /// stale or deleted model IDs naturally become unconfigured.
    public mutating func switchAuxiliaryMode(
        to newMode: AuxiliaryImageMode,
        capabilities: (UUID) -> ModelCapabilities?
    ) {
        guard newMode != auxiliaryImageMode else { return }
        switch newMode {
        case .separate:
            if let id = sharedImageModelID, let value = capabilities(id) {
                imageGenerationModelID = value.contains(.imageGeneration) ? id : nil
                imageEditingModelID = value.contains(.imageEditing) ? id : nil
            } else {
                imageGenerationModelID = nil
                imageEditingModelID = nil
            }
            sharedImageModelID = nil
        case .shared:
            if let generationID = imageGenerationModelID,
               generationID == imageEditingModelID,
               let value = capabilities(generationID),
               value.contains(.imageGeneration), value.contains(.imageEditing) {
                sharedImageModelID = generationID
            } else {
                sharedImageModelID = nil
            }
            imageGenerationModelID = nil
            imageEditingModelID = nil
        }
        auxiliaryImageMode = newMode
    }
}
