// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The portable portion of an ordinary conversation. Message and text-part
/// identifiers match the native conversation store on both Apple platforms.
///
/// Version 1 carries text parts only and stays the fallback for unupgraded
/// peers. Version 2 additionally carries restorable original user attachment
/// metadata and a display-only projection of tool results (redacted name,
/// status, and bounded summary). Approvals, credentials, run permissions,
/// replayable events, and internal reasoning are never exported.
public struct DeviceConversationHistory: Codable, Sendable {
    public static let maximumMessages = 12_000
    public static let maximumBytes = 32 * 1_024 * 1_024
    public static let currentVersion = 2
    public static let maximumRestorableAttachments = 512
    public static let maximumRestorableAttachmentBytesPerItem = 32 * 1_024 * 1_024
    public static let maximumRestorableAttachmentBytes: Int64 = 2 << 30
    public static let maximumToolResultsPerMessage = 32
    public static let maximumToolResultSummaryBytes = 4_096

    public struct Part: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable, Equatable {
            case text
            case attachment
            case tool
        }

        public let id: UUID
        public let index: Int
        public let kind: Kind
        /// Text body, or the bounded redacted tool-result summary.
        public let text: String?
        /// Present for `.attachment` parts; the attachment metadata lives in
        /// the top-level `attachments` list.
        public let attachmentID: UUID?
        /// Tool display name for `.tool` parts.
        public let toolName: String?
        /// Tool status for `.tool` parts ("ok" / "error" / ...).
        public let toolStatus: String?
        public let createdAt: Date

        public init(id: UUID, index: Int, kind: Kind = .text, text: String? = nil,
                    attachmentID: UUID? = nil, toolName: String? = nil, toolStatus: String? = nil,
                    createdAt: Date) {
            self.id = id
            self.index = index
            self.kind = kind
            self.text = text
            self.attachmentID = attachmentID
            self.toolName = toolName
            self.toolStatus = toolStatus
            self.createdAt = createdAt
        }

        private enum CodingKeys: String, CodingKey {
            case id, index, kind, text, attachmentID, toolName, toolStatus, createdAt
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            index = try container.decode(Int.self, forKey: .index)
            // Archives written before typed parts have no `kind` key; they
            // are text parts by definition.
            kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
            text = try container.decodeIfPresent(String.self, forKey: .text)
            attachmentID = try container.decodeIfPresent(UUID.self, forKey: .attachmentID)
            toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
            toolStatus = try container.decodeIfPresent(String.self, forKey: .toolStatus)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
        }
    }

    /// Source-compatibility alias: v1 archives used `TextPart` for the typed
    /// text entries; the unified `Part` decodes both shapes.
    public typealias TextPart = Part

    /// Restorable original user attachment metadata. Bytes travel separately
    /// through the authorized attachment transfer and are verified by this
    /// digest before a usable link is presented.
    public struct Attachment: Codable, Equatable, Sendable {
        public let id: UUID
        /// `AttachmentRef.Kind` raw value: image | document | audio | other.
        public let kind: String
        public let displayName: String
        public let uti: String
        public let byteCount: Int
        /// Lowercase 64-hex SHA-256 of the original bytes.
        public let sha256: String
        public let createdAt: Date

        public init(id: UUID, kind: String, displayName: String, uti: String,
                    byteCount: Int, sha256: String, createdAt: Date) {
            self.id = id
            self.kind = kind
            self.displayName = displayName
            self.uti = uti
            self.byteCount = byteCount
            self.sha256 = sha256
            self.createdAt = createdAt
        }
    }

    public struct Message: Codable, Equatable, Sendable {
        public let id: UUID
        public let role: String
        public let content: String
        public let createdAt: Date
        public let parts: [Part]

        public init(id: UUID, role: String, content: String, createdAt: Date, parts: [Part]) {
            self.id = id
            self.role = role
            self.content = content
            self.createdAt = createdAt
            self.parts = parts
        }
    }

    public let version: Int
    public let id: UUID
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
    public let messages: [Message]
    /// Restorable attachments referenced by the exported messages. Empty for
    /// v1 archives. Attachment *parts* referencing entries missing here are
    /// omitted: the receiver cannot present a usable link for them.
    public let attachments: [Attachment]

    init(id: UUID, title: String, createdAt: Date, updatedAt: Date, messages: [Message],
         attachments: [Attachment] = [], version: Int = 1) {
        self.version = version
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, title, createdAt, updatedAt, messages, attachments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        messages = try container.decode([Message].self, forKey: .messages)
        // Original v1 peers omit the attachment list.
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw DeviceConversationHistoryError.sizeLimit }
        return data
    }

    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw DeviceConversationHistoryError.sizeLimit }
        self = try JSONDecoder().decode(Self.self, from: data)
        try validate()
    }

    func validate() throws {
        guard version == 1 || version == 2 else { throw DeviceConversationHistoryError.unsupportedVersion }
        guard messages.count <= Self.maximumMessages else { throw DeviceConversationHistoryError.sizeLimit }
        guard !title.isEmpty, title.utf8.count <= 4_096,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              Set(messages.map(\.id)).count == messages.count else {
            throw DeviceConversationHistoryError.invalidHistory
        }
        var partIDs = Set<UUID>()
        for message in messages {
            guard message.role == "user" || message.role == "assistant",
                  message.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  Set(message.parts.map(\.index)).count == message.parts.count,
                  message.parts.allSatisfy({
                      $0.index >= 0 && $0.createdAt.timeIntervalSinceReferenceDate.isFinite
                          && partIDs.insert($0.id).inserted
                  }) else { throw DeviceConversationHistoryError.invalidHistory }
        }
        guard version == 2 else {
            // v1 shape: text parts only, no attachment metadata.
            guard attachments.isEmpty,
                  messages.allSatisfy({ message in
                      message.parts.allSatisfy { $0.kind == .text && $0.attachmentID == nil && $0.toolName == nil }
                  }) else { throw DeviceConversationHistoryError.invalidHistory }
            return
        }
        try validateAttachments()
        try validateTypedParts()
    }

    private func validateAttachments() throws {
        guard attachments.count <= Self.maximumRestorableAttachments else {
            throw DeviceConversationHistoryError.sizeLimit
        }
        var total: Int64 = 0
        var ids = Set<UUID>()
        let allowedKinds: Set<String> = ["image", "document", "audio", "other"]
        for attachment in attachments {
            guard ids.insert(attachment.id).inserted,
                  allowedKinds.contains(attachment.kind),
                  !attachment.displayName.isEmpty, attachment.displayName.utf8.count <= 256,
                  attachment.uti.utf8.count <= 128,
                  attachment.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  (0...Self.maximumRestorableAttachmentBytesPerItem).contains(attachment.byteCount),
                  Self.isValidDigest(attachment.sha256) else {
                throw DeviceConversationHistoryError.invalidHistory
            }
            total += Int64(attachment.byteCount)
            guard total <= Self.maximumRestorableAttachmentBytes else {
                throw DeviceConversationHistoryError.sizeLimit
            }
        }
    }

    private func validateTypedParts() throws {
        let attachmentIDs = Set(attachments.map(\.id))
        var attached = Set<UUID>()
        for message in messages {
            var toolCount = 0
            for part in message.parts {
                switch part.kind {
                case .text:
                    break
                case .attachment:
                    guard message.role == "user", let attachmentID = part.attachmentID,
                          attachmentIDs.contains(attachmentID), attached.insert(attachmentID).inserted else {
                        throw DeviceConversationHistoryError.invalidHistory
                    }
                case .tool:
                    toolCount += 1
                    guard toolCount <= Self.maximumToolResultsPerMessage,
                          let toolName = part.toolName, !toolName.isEmpty, toolName.utf8.count <= 256,
                          (part.toolStatus?.utf8.count ?? 0) <= 32,
                          let summary = part.text, !summary.isEmpty,
                          summary.utf8.count <= Self.maximumToolResultSummaryBytes else {
                        throw DeviceConversationHistoryError.invalidHistory
                    }
                }
            }
        }
        guard attached == attachmentIDs else { throw DeviceConversationHistoryError.invalidHistory }
    }

    static func isValidDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public enum DeviceConversationHistoryError: Error, Equatable, Sendable {
    case unsupportedVersion
    case sizeLimit
    case invalidHistory
    case conversationUnavailable
    case messageConflict(UUID)
    case cursorExpired
}

/// A bounded, independently importable text archive and its sender position.
public struct DeviceConversationHistoryPage: Sendable {
    public let archive: Data
    public let nextCursor: String?
    public let through: Int64
    public let hasMore: Bool
}

public struct DeviceConversationImport: Sendable, Equatable {
    public let conversationID: UUID
    public let addedMessages: Int
    public let createdConversation: Bool
}
