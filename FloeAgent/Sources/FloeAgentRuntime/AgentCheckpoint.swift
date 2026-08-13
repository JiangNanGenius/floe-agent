// FloeAgentRuntime — Checkpoint payload.
// See blazing-aurora-darwin.md §5.12. Checkpoints persist the exact
// resumable state of a run; `formatVersion` gates migrations of the
// checkpoint file itself while `schemaVersion` tracks the GRDB schema the
// embedded records were written against.

import Foundation
import FloeCore
import FloeModels
import FloeSecurity

/// Serializable snapshot of an agent run, written on cancellation, app
/// suspension, or explicit user pause timeout.
public struct AgentCheckpoint: Sendable, Codable, Hashable {
    /// Checkpoint file format version. Current: 1.
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

    /// Current checkpoint file format.
    public static let currentFormatVersion = 1
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
        schemaVersion: Int = AgentCheckpoint.currentSchemaVersion
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

    public init(id: UUID = UUID(), role: String, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}
