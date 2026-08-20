// FloeModels — Durable user input submitted while an agent run is active.

import Foundation
import FloeCore

/// Durable lifecycle. Transient states are intentionally persisted so a
/// process crash can recover a message instead of silently losing it.
public enum PendingUserInputStatus: String, Sendable, Codable, Hashable {
    case queued
    case promoting
    case steerPending
    case consumed
    case cancelled

    public var isPending: Bool {
        switch self {
        case .queued, .promoting, .steerPending: true
        case .consumed, .cancelled: false
        }
    }
}

/// One exactly-identifiable user message waiting to be queued or steered.
public struct PendingUserInput: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    /// The run that was active when the user submitted/promoted this input.
    public var targetRunID: UUID?
    public var content: String
    public var mode: RunningInputMode
    public var status: PendingUserInputStatus
    public var position: Int64
    public var attachments: [AttachmentRef]
    public var selectedModelID: UUID?
    public var workspaceID: UUID?
    /// App-layer execution-mode raw value, kept storage-neutral here.
    public var executionMode: String
    /// The active run that consumed a steer, or the new run launched for a
    /// queued message. It is the durable exactly-once receipt.
    public var consumedRunID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var consumedAt: Date?

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        targetRunID: UUID? = nil,
        content: String,
        mode: RunningInputMode = .queue,
        status: PendingUserInputStatus = .queued,
        position: Int64 = 0,
        attachments: [AttachmentRef] = [],
        selectedModelID: UUID? = nil,
        workspaceID: UUID? = nil,
        executionMode: String = "agent",
        consumedRunID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        consumedAt: Date? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.targetRunID = targetRunID
        self.content = content
        self.mode = mode
        self.status = status
        self.position = position
        self.attachments = attachments
        self.selectedModelID = selectedModelID
        self.workspaceID = workspaceID
        self.executionMode = executionMode
        self.consumedRunID = consumedRunID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.consumedAt = consumedAt
    }
}

/// Receipt emitted when the runtime has inserted a steer into model context.
public struct SteerConsumptionReceipt: Sendable, Codable, Hashable {
    public var inputID: UUID
    public var runID: UUID
    public var consumedAt: Date

    public init(inputID: UUID, runID: UUID, consumedAt: Date = Date()) {
        self.inputID = inputID
        self.runID = runID
        self.consumedAt = consumedAt
    }
}
