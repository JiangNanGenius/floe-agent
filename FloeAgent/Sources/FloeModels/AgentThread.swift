// FloeModels — Daily-use Alpha thread domain types.
// See docs/ALPHA_DAILY_PLAN.md (Persistence v3) and DESIGN.md §"Information
// architecture": the execution thread is the canonical representation of
// assistant output, tool steps, terminal results, approvals, errors,
// checkpoints and evidence. These types are wire- and storage-neutral.

import Foundation

/// A typed multimodal part of a single message. The plain-text projection
/// still lives on the message row; structured parts let the thread render
/// evidence (images, files, reasoning) without parsing free text.
public struct MessagePart: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case text
        case reasoning
        case image
        case file
    }

    public var id: UUID
    public var messageID: UUID
    public var partIndex: Int
    public var kind: Kind
    public var text: String?
    public var attachmentID: UUID?
    /// Non-secret structured metadata (dimensions, mime, language, …).
    public var metadata: [String: String]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        messageID: UUID,
        partIndex: Int,
        kind: Kind,
        text: String? = nil,
        attachmentID: UUID? = nil,
        metadata: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.messageID = messageID
        self.partIndex = partIndex
        self.kind = kind
        self.text = text
        self.attachmentID = attachmentID
        self.metadata = metadata
        self.createdAt = createdAt
    }
}

/// A reference to a binary or large payload attached to a conversation.
/// Bytes live on disk or behind a security-scoped bookmark; only metadata
/// and a content digest are persisted. Never carries a secret.
public struct AttachmentRef: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case image
        case document
        case audio
        case other
    }

    public enum Storage: String, Sendable, Codable, Hashable {
        case none
        case applicationSupport
        case securityScopedBookmark
    }

    public var id: UUID
    public var conversationID: UUID?
    public var messageID: UUID?
    public var kind: Kind
    public var displayName: String
    public var uti: String
    public var byteCount: Int
    public var sha256: String
    public var storage: Storage
    /// Security-scoped bookmark data (iOS), when `storage == .securityScopedBookmark`.
    public var urlBookmark: Data?
    /// Path relative to the attachments directory, when `.applicationSupport`.
    public var relativePath: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        kind: Kind,
        displayName: String = "",
        uti: String = "",
        byteCount: Int = 0,
        sha256: String = "",
        storage: Storage = .none,
        urlBookmark: Data? = nil,
        relativePath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.messageID = messageID
        self.kind = kind
        self.displayName = displayName
        self.uti = uti
        self.byteCount = byteCount
        self.sha256 = sha256
        self.storage = storage
        self.urlBookmark = urlBookmark
        self.relativePath = relativePath
        self.createdAt = createdAt
    }
}

/// One entry in the canonical, append-only agent event thread. The payload
/// is a non-secret JSON projection of the underlying `AgentEvent` or a UI
/// status/checkpoint marker. Ordering is stable via `sequence`.
public struct RunEventRecord: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case assistantText
        case reasoning
        case toolRequest
        case toolResult
        case terminal
        case file
        case approval
        case error
        case usage
        case checkpoint
        case status
        /// A tool call that was automatically approved by policy (no human).
        case autoApproved
    }

    public var id: UUID
    public var runID: UUID
    public var sequence: Int
    public var kind: Kind
    /// Non-secret JSON payload (UTF-8). Shape depends on `kind`.
    public var payloadJSON: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        sequence: Int,
        kind: Kind,
        payloadJSON: String = "{}",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.sequence = sequence
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }
}

/// Per-run token/cost usage captured at one point in the run.
public struct RunUsageRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var runID: UUID
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var reasoningTokens: Int?
    public var isEstimated: Bool
    /// Decimal cost rendered as a string to avoid binary float drift.
    public var costEstimate: String?
    public var recordedAt: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        isEstimated: Bool = false,
        costEstimate: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.isEstimated = isEstimated
        self.costEstimate = costEstimate
        self.recordedAt = recordedAt
    }
}

/// A structured, provider-normalized error attached to a run.
public struct RunErrorRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var runID: UUID
    public var kind: String
    public var message: String
    public var httpStatus: Int?
    public var recoverable: Bool
    public var recordedAt: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        kind: String,
        message: String = "",
        httpStatus: Int? = nil,
        recoverable: Bool = false,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.kind = kind
        self.message = message
        self.httpStatus = httpStatus
        self.recoverable = recoverable
        self.recordedAt = recordedAt
    }
}

/// Live remote session (SSH terminal / VNC) registration. Lets the app
/// reconnect honestly after relaunch and report suspended/unknown state
/// rather than pretending a socket survived backgrounding.
public struct RemoteSessionRecord: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case sshTerminal
        case vnc
    }

    public enum State: String, Sendable, Codable, Hashable {
        case connecting
        case connected
        case suspended
        case disconnected
        case unknown
    }

    public var id: UUID
    public var hostID: UUID
    public var kind: Kind
    public var state: State
    public var remoteSessionRef: String?
    public var lastHeartbeatAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        hostID: UUID,
        kind: Kind,
        state: State,
        remoteSessionRef: String? = nil,
        lastHeartbeatAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.hostID = hostID
        self.kind = kind
        self.state = state
        self.remoteSessionRef = remoteSessionRef
        self.lastHeartbeatAt = lastHeartbeatAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
