// FloeAgentRuntime — Checkpoint payload.
// See blazing-aurora-darwin.md §5.12. Checkpoints persist the exact
// resumable state of a run; `formatVersion` gates migrations of the
// checkpoint file itself while `schemaVersion` tracks the GRDB schema the
// embedded records were written against.

import Foundation
import FloeCore
import FloeModels
import FloeSecurity

/// Codable, provider-neutral form of the bounded execution ledger. Keeping it
/// in the checkpoint prevents a resumed run from re-running observations that
/// already succeeded before suspension.
public struct AgentExecutionLedgerEntry: Sendable, Codable, Hashable {
    public var toolName: String
    public var callFingerprint: String
    public var status: ToolResult.Status
    public var resultFingerprint: String
    public var excerpt: String
    public var occurrenceCount: Int

    public init(
        toolName: String,
        callFingerprint: String,
        status: ToolResult.Status,
        resultFingerprint: String,
        excerpt: String,
        occurrenceCount: Int
    ) {
        self.toolName = toolName
        self.callFingerprint = callFingerprint
        self.status = status
        self.resultFingerprint = resultFingerprint
        self.excerpt = excerpt
        self.occurrenceCount = occurrenceCount
    }
}

/// Durable execution boundary for one structured tool call. `recorded` and
/// `approved` prove that no external action started; `dispatched` means a
/// crash may have happened after the request crossed the executor boundary;
/// `resultCommitted` proves the paired result reached a recovery checkpoint.
public enum AgentToolLifecyclePhase: String, Sendable, Codable, Hashable {
    case recorded
    case approved
    case dispatched
    case resultCommitted
}

public struct AgentToolLifecycleEntry: Sendable, Codable, Hashable {
    public var callID: String
    public var toolName: String
    public var authorizationIdentity: String?
    public var phase: AgentToolLifecyclePhase
    public var updatedAt: Date

    public init(
        callID: String,
        toolName: String,
        authorizationIdentity: String? = nil,
        phase: AgentToolLifecyclePhase,
        updatedAt: Date = Date()
    ) {
        self.callID = callID
        self.toolName = toolName
        self.authorizationIdentity = authorizationIdentity
        self.phase = phase
        self.updatedAt = updatedAt
    }
}

/// Serializable snapshot of an agent run, written on cancellation, app
/// suspension, or explicit user pause timeout.
public struct AgentCheckpoint: Sendable, Codable, Hashable {
    /// Checkpoint file format version. Current: 2.
    public var formatVersion: Int
    public var runID: UUID
    public var conversationID: UUID
    /// State at checkpoint time. `streamingModel`/`executingTool` are
    /// always persisted downgraded to `preparing` (replay resumes from the
    /// last tool-result boundary).
    public var state: AgentState
    /// Conversation messages in wire-neutral form.
    public var messages: [ConversationMessage]
    /// Tool calls requested but not yet executed.
    public var pendingToolCalls: [ToolCall]
    /// Tool results produced since the last model turn, not yet sent.
    public var pendingToolResults: [ToolResult]
    /// Active approval grants at checkpoint time.
    public var approvals: [ApprovalGrant]
    /// Idempotency keys already executed in this run (dedup on replay).
    public var idempotencyKeys: Set<String>
    public var createdAt: Date
    /// GRDB schema version the embedded records were written against.
    public var schemaVersion: Int
    /// V2 orchestration metadata. Optional fields keep V1 files decodable.
    public var parentRunID: UUID?
    public var conversationMode: ConversationMode?
    public var planID: UUID?
    public var goalID: UUID?
    public var contextCompaction: ContextCompactionRecord?
    public var activeChildRunIDs: [UUID]?
    public var parentIterationCount: Int?
    public var totalIterationCount: Int?
    /// Bounded evidence of tool attempts already completed in this run.
    /// Optional so V1/V2 checkpoints written before Build 53 remain readable.
    public var executionLedgerEntries: [AgentExecutionLedgerEntry]?
    /// Exact dispatch boundary for pending calls. Optional so older
    /// checkpoints remain decodable and are repaired conservatively.
    public var toolLifecycleEntries: [AgentToolLifecycleEntry]?

    /// Current checkpoint file format.
    public static let currentFormatVersion = 3
    /// Current GRDB schema version.
    public static let currentSchemaVersion = 1

    public init(
        formatVersion: Int = AgentCheckpoint.currentFormatVersion,
        runID: UUID,
        conversationID: UUID,
        state: AgentState,
        messages: [ConversationMessage],
        pendingToolCalls: [ToolCall] = [],
        pendingToolResults: [ToolResult] = [],
        approvals: [ApprovalGrant] = [],
        idempotencyKeys: Set<String> = [],
        createdAt: Date = Date(),
        schemaVersion: Int = AgentCheckpoint.currentSchemaVersion,
        parentRunID: UUID? = nil,
        conversationMode: ConversationMode? = nil,
        planID: UUID? = nil,
        goalID: UUID? = nil,
        contextCompaction: ContextCompactionRecord? = nil,
        activeChildRunIDs: [UUID]? = nil,
        parentIterationCount: Int? = nil,
        totalIterationCount: Int? = nil,
        executionLedgerEntries: [AgentExecutionLedgerEntry]? = nil,
        toolLifecycleEntries: [AgentToolLifecycleEntry]? = nil
    ) {
        self.formatVersion = formatVersion
        self.runID = runID
        self.conversationID = conversationID
        self.state = state
        self.messages = messages
        self.pendingToolCalls = pendingToolCalls
        self.pendingToolResults = pendingToolResults
        self.approvals = approvals
        self.idempotencyKeys = idempotencyKeys
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
        self.parentRunID = parentRunID
        self.conversationMode = conversationMode
        self.planID = planID
        self.goalID = goalID
        self.contextCompaction = contextCompaction
        self.activeChildRunIDs = activeChildRunIDs
        self.parentIterationCount = parentIterationCount
        self.totalIterationCount = totalIterationCount
        self.executionLedgerEntries = executionLedgerEntries
        self.toolLifecycleEntries = toolLifecycleEntries
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> AgentCheckpoint {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let checkpoint = try decoder.decode(AgentCheckpoint.self, from: data)
        guard checkpoint.formatVersion <= currentFormatVersion else {
            throw FloeError.validationFailed(
                "Checkpoint format v\(checkpoint.formatVersion) is newer than supported v\(currentFormatVersion)"
            )
        }
        return checkpoint
    }
}

/// Wire-neutral conversation message persisted in checkpoints and GRDB.
public struct ConversationMessage: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var role: String
    public var content: String
    public var createdAt: Date
    /// Bounded inline visual evidence belonging to this message. It is only
    /// sent when the selected model actually declares vision support.
    public var images: [ConversationImagePart]

    public init(
        id: UUID = UUID(),
        role: String,
        content: String,
        createdAt: Date = Date(),
        images: [ConversationImagePart] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.images = images
    }

    private enum CodingKeys: String, CodingKey { case id, role, content, createdAt, images }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(String.self, forKey: .role)
        content = try values.decode(String.self, forKey: .content)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        images = try values.decodeIfPresent([ConversationImagePart].self, forKey: .images) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(role, forKey: .role)
        try values.encode(content, forKey: .content)
        try values.encode(createdAt, forKey: .createdAt)
        if !images.isEmpty { try values.encode(images, forKey: .images) }
    }
}

public struct ConversationImagePart: Sendable, Codable, Hashable {
    public var mimeType: String
    public var base64: String

    public init(mimeType: String, base64: String) {
        self.mimeType = mimeType
        self.base64 = base64
    }
}
