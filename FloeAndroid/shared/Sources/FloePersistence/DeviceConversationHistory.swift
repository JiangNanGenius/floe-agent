// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The portable portion of an ordinary conversation. Message and text-part
/// identifiers match the native conversation store on both Apple platforms.
///
/// Android mirror of the FIXED iOS donor
/// `FloeAgent/Sources/FloePersistence/DeviceConversationHistory.swift`
/// (0d2c31722). The wire shape is intentionally unchanged: version 1, the
/// same field names, the same date coding (JSONEncoder/Decoder default
/// reference-date numbers) and the same sorted-keys encoding, so history
/// exported on iOS/Mac decodes here and vice versa. The portable v1 shape
/// is text-only: native runtime state, secrets, attachments, tool calls,
/// permissions and hidden/temporary/editor conversations never enter it.
public struct DeviceConversationHistory: Codable, Sendable {
    public static let maximumMessages = 12_000
    public static let maximumBytes = 32 * 1_024 * 1_024

    public struct TextPart: Codable, Equatable, Sendable {
        public let id: UUID
        public let index: Int
        public let text: String
        public let createdAt: Date

        public init(id: UUID, index: Int, text: String, createdAt: Date) {
            self.id = id
            self.index = index
            self.text = text
            self.createdAt = createdAt
        }
    }

    public struct Message: Codable, Equatable, Sendable {
        public let id: UUID
        public let role: String
        public let content: String
        public let createdAt: Date
        public let parts: [TextPart]

        public init(id: UUID, role: String, content: String, createdAt: Date, parts: [TextPart]) {
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

    public init(id: UUID, title: String, createdAt: Date, updatedAt: Date, messages: [Message]) {
        version = 1
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
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

    public func validate() throws {
        guard version == 1 else { throw DeviceConversationHistoryError.unsupportedVersion }
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
    }
}

public enum DeviceConversationHistoryError: Error, Equatable, Sendable {
    case unsupportedVersion
    case sizeLimit
    case invalidHistory
    case conversationUnavailable
    case messageConflict(UUID)
    case cursorExpired
    /// The conversation has an active durable run (the existing
    /// `FacadeRunDomain.activeRunStates` vocabulary), proven INSIDE the
    /// import writer transaction. Android additive case: the fixed iOS
    /// donor refuses this on the Mac host's in-memory `liveRuns` instead;
    /// the wire shape is unaffected.
    case busy
}

/// One independently importable text archive and its sender position.
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

    public init(conversationID: UUID, addedMessages: Int, createdConversation: Bool) {
        self.conversationID = conversationID
        self.addedMessages = addedMessages
        self.createdConversation = createdConversation
    }
}
