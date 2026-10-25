import Foundation

public enum SkillAuthoringKind: String, Codable, Sendable, Hashable {
    case creation, importing
}

/// Execution phase and presentation ownership are independent: conversion
/// does not finish/restart the underlying work or erase its real phase.
public enum SkillAuthoringPhase: String, Codable, Sendable, Hashable {
    case draft, preparing, running, needsUser, paused, cancelling
    case ready, installed, failed, interrupted, stopped

    public var isSettled: Bool {
        switch self {
        case .ready, .installed, .failed, .interrupted, .stopped: true
        default: false
        }
    }
}

public enum SkillAuthoringAdvisoryDecision: String, Codable, Sendable, Hashable {
    case unanswered, keepWaiting, convertRequested, converted
}

public enum SkillAuthoringAdvisoryChoice: Sendable, Equatable {
    case keepWaiting, convertToTask
}

/// Frozen resolved IDs only. The existing environment/model services retain
/// authority over routing, credentials, actual files and execution grants.
public struct SkillAuthoringBinding: Codable, Sendable, Hashable {
    public var runID: UUID?
    public var providerID: UUID?
    public var modelID: UUID?
    public var workspaceID: UUID?
    public var environmentID: String?
    public var workspaceWriteLayer: String?
    public var requiresExecution: Bool

    public init(runID: UUID? = nil, providerID: UUID? = nil, modelID: UUID? = nil,
                workspaceID: UUID? = nil, environmentID: String? = nil,
                workspaceWriteLayer: String? = nil, requiresExecution: Bool = false) {
        self.runID = runID; self.providerID = providerID; self.modelID = modelID
        self.workspaceID = workspaceID; self.environmentID = environmentID
        self.workspaceWriteLayer = workspaceWriteLayer; self.requiresExecution = requiresExecution
    }
}

/// Callback fence minted by startProcessing, not inferred from visible text.
public struct SkillAuthoringAttemptToken: Codable, Sendable, Hashable {
    public let conversationID: UUID
    public let inputRevision: Int
    public let attemptID: UUID
    /// Monotonic storage generation also fences a mistakenly reused UUID.
    public let generation: Int64
    public let runID: UUID?
}

public struct SkillAuthoringAttempt: Codable, Sendable, Hashable {
    public let token: SkillAuthoringAttemptToken
    public let binding: SkillAuthoringBinding
    public let startedAt: Date
    public internal(set) var activeProcessingMilliseconds: UInt64
}

/// Identifies the exact generated/imported package the user can add. It is
/// not an installation receipt or a publisher review/permission grant.
public struct SkillAuthoringPreparedSkill: Codable, Sendable, Hashable {
    public let skillID: String
    public let version: String
    public let digest: String
    public init(skillID: String, version: String, digest: String) {
        self.skillID = skillID; self.version = version; self.digest = digest
    }
}

public struct SkillAuthoringInstallationReceipt: Codable, Sendable, Hashable {
    public let skill: SkillAuthoringPreparedSkill
    public let verifiedAt: Date
}

/// Feature metadata only. Text/attachments remain in ComposerDraftStore,
/// messages in ConversationStore, jobs/runs and files in their existing stores.
/// The operation ID IS the durable conversation ID, including after conversion.
public struct SkillAuthoringRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let kind: SkillAuthoringKind
    public internal(set) var revision: Int64
    public internal(set) var inputRevision: Int
    public internal(set) var phase: SkillAuthoringPhase
    public internal(set) var sourceAttachmentIDs: [UUID]
    public internal(set) var sourceSnapshotIDs: [UUID]
    public internal(set) var generatedArtifactIDs: [UUID]
    public internal(set) var jobIDs: [UUID]
    public internal(set) var attempt: SkillAuthoringAttempt?
    public internal(set) var activeProcessingMilliseconds: UInt64
    public internal(set) var advisoryDecision: SkillAuthoringAdvisoryDecision
    public internal(set) var promotedAt: Date?
    public internal(set) var preparedSkill: SkillAuthoringPreparedSkill?
    public internal(set) var installationReceipt: SkillAuthoringInstallationReceipt?
    public internal(set) var failureMessage: String?
    public internal(set) var acknowledged: Bool
    public let createdAt: Date
    public internal(set) var updatedAt: Date

    public var conversationID: UUID { id }
    public var isPromoted: Bool { promotedAt != nil }
    public var occupiesForegroundSlot: Bool { !isPromoted && !phase.isSettled }
    /// The coordinator still decides whether the actual processing panel is
    /// visible. Reading this property never presents a modal or converts work.
    public var isAdvisoryEligible: Bool {
        phase == .running && !isPromoted && activeProcessingMilliseconds >= 90_000
            && advisoryDecision == .unanswered
    }

    init(id: UUID, kind: SkillAuthoringKind, now: Date) {
        self.id = id; self.kind = kind; revision = 0; inputRevision = 0; phase = .draft
        sourceAttachmentIDs = []; sourceSnapshotIDs = []; generatedArtifactIDs = []; jobIDs = []
        attempt = nil; activeProcessingMilliseconds = 0; advisoryDecision = .unanswered
        promotedAt = nil; preparedSkill = nil; installationReceipt = nil
        failureMessage = nil; acknowledged = false; createdAt = now; updatedAt = now
    }
}

public struct SkillAuthoringBeginResult: Sendable, Equatable {
    public let record: SkillAuthoringRecord
    public let created: Bool
}

/// Storage errors are typed for the App to map to concise localized actions;
/// no model output may turn one of these failures into a success receipt.
public enum SkillAuthoringStoreError: Error, Sendable, Equatable {
    case missing
    case ownerMissing
    case ownerMismatch
    case staleRevision
    case staleAttempt
    case invalidTransition
    case foregroundOccupied(UUID)
    case invalidBinding
    case invalidMetadata
    case installationMismatch
    case corruptState
}
