// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The portable portion of an ordinary conversation. Message and text-part
/// identifiers match the native conversation store on both Apple platforms.
public struct DeviceConversationHistory: Codable, Sendable {
    public static let maximumMessages = 12_000
    public static let maximumBytes = 32 * 1_024 * 1_024

    public struct TextPart: Codable, Equatable, Sendable {
        public let id: UUID
        public let index: Int
        public let text: String
        public let createdAt: Date
    }

    public struct Message: Codable, Equatable, Sendable {
        public let id: UUID
        public let role: String
        public let content: String
        public let createdAt: Date
        public let parts: [TextPart]
    }

    public let version: Int
    public let id: UUID
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
    public let messages: [Message]

    init(id: UUID, title: String, createdAt: Date, updatedAt: Date, messages: [Message]) {
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

    func validate() throws {
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
}

public struct DeviceConversationImport: Sendable, Equatable {
    public let conversationID: UUID
    public let addedMessages: Int
    public let createdConversation: Bool
}
