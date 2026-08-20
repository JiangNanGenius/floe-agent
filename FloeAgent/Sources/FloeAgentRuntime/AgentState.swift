// FloeAgentRuntime — Agent state machine states.
// See blazing-aurora-darwin.md §7 mermaid state diagram. Every transition
// is driven by `FloeAgentRuntime`; these payloads carry the information the
// UI and checkpointing need at each state.

import Foundation
import FloeCore
import FloeModels
import FloeSecurity

/// Lifecycle states of one agent run. Terminal states: `.completed`,
/// `.failed`. `.checkpointed` resumes into `.preparing`.
public enum AgentState: Sendable, Codable, Hashable {
    case idle
    case preparing(PreparingInfo)
    case streamingModel(StreamingInfo)
    case waitingApproval(WaitingApproval)
    case executingTool(ExecutingInfo)
    case compacting
    case verifying
    case checkpointed(CheckpointRef)
    case paused(PausedInfo)
    case cancelling
    case completed(CompletionInfo)
    case failed(AgentFailure)

    /// Marker for checkpoint payloads; the checkpoint file carries the full
    /// `AgentCheckpoint`, so the state only references it.
    public struct CheckpointRef: Sendable, Codable, Hashable {
        public var checkpointURL: URL?
        public var createdAt: Date

        public init(checkpointURL: URL? = nil, createdAt: Date = Date()) {
            self.checkpointURL = checkpointURL
            self.createdAt = createdAt
        }
    }

    public struct PreparingInfo: Sendable, Codable, Hashable {
        public var goal: String
        public var resumedFromCheckpoint: Bool

        public init(goal: String, resumedFromCheckpoint: Bool = false) {
            self.goal = goal
            self.resumedFromCheckpoint = resumedFromCheckpoint
        }
    }

    public struct StreamingInfo: Sendable, Codable, Hashable {
        public var modelRemoteID: String
        public var startedAt: Date
        public var textSoFar: String

        public init(modelRemoteID: String, startedAt: Date = Date(), textSoFar: String = "") {
            self.modelRemoteID = modelRemoteID
            self.startedAt = startedAt
            self.textSoFar = textSoFar
        }
    }

    public struct WaitingApproval: Sendable, Codable, Hashable {
        public var toolCall: ToolCall
        public var reason: String
        public var requestedAt: Date

        public init(toolCall: ToolCall, reason: String, requestedAt: Date = Date()) {
            self.toolCall = toolCall
            self.reason = reason
            self.requestedAt = requestedAt
        }
    }

    public struct ExecutingInfo: Sendable, Codable, Hashable {
        public var toolCall: ToolCall
        public var startedAt: Date

        public init(toolCall: ToolCall, startedAt: Date = Date()) {
            self.toolCall = toolCall
            self.startedAt = startedAt
        }
    }

    public struct PausedInfo: Sendable, Codable, Hashable {
        public var pausedAt: Date
        /// Wall-clock budget after which a paused run checkpoints to disk.
        public var timeoutAt: Date

        public init(pausedAt: Date = Date(), timeoutAt: Date) {
            self.pausedAt = pausedAt
            self.timeoutAt = timeoutAt
        }
    }

    public struct CompletionInfo: Sendable, Codable, Hashable {
        public var stopReason: AgentEvent.StopReason
        public var completedAt: Date
        public var totalInputTokens: Int
        public var totalOutputTokens: Int

        public init(
            stopReason: AgentEvent.StopReason,
            completedAt: Date = Date(),
            totalInputTokens: Int = 0,
            totalOutputTokens: Int = 0
        ) {
            self.stopReason = stopReason
            self.completedAt = completedAt
            self.totalInputTokens = totalInputTokens
            self.totalOutputTokens = totalOutputTokens
        }
    }

    public struct AgentFailure: Sendable, Codable, Hashable {
        public var message: String
        public var isRecoverable: Bool
        public var failedAt: Date

        public init(message: String, isRecoverable: Bool = false, failedAt: Date = Date()) {
            self.message = message
            self.isRecoverable = isRecoverable
            self.failedAt = failedAt
        }
    }

    /// Human-readable stable name, used in persistence and tests.
    public var name: String {
        switch self {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .streamingModel: return "streamingModel"
        case .waitingApproval: return "waitingApproval"
        case .executingTool: return "executingTool"
        case .compacting: return "compacting"
        case .verifying: return "verifying"
        case .checkpointed: return "checkpointed"
        case .paused: return "paused"
        case .cancelling: return "cancelling"
        case .completed: return "completed"
        case .failed: return "failed"
        }
    }
}
