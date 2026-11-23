// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Receiver-side hooks for restoring original user attachments referenced by
/// an imported v2 history archive. Attachments ride the same authorized
/// connection as workspace files, in digest-verified chunks; only after the
/// bytes are stored and re-read does the host bind the message part, so a
/// file/image part in the store always resolves to verified bytes.
public struct DeviceAttachmentRestore: Sendable {
    public struct Item: Sendable, Equatable {
        public let attachmentID: UUID
        /// Message the restored part belongs to.
        public let messageID: UUID
        public let kind: Kind
        public let displayName: String
        public let byteCount: Int
        /// Lowercase 64-hex SHA-256 of the original bytes.
        public let digest: String

        public init(attachmentID: UUID, messageID: UUID, kind: Kind, displayName: String,
                    byteCount: Int, digest: String) {
            self.attachmentID = attachmentID
            self.messageID = messageID
            self.kind = kind
            self.displayName = displayName
            self.byteCount = byteCount
            self.digest = digest
        }
    }

    public enum Kind: String, Sendable, Codable {
        case image
        case file
    }

    /// Attachments of the conversation whose bytes are still missing after a
    /// history import (storage `.none`). Called on the receiving device.
    public let pending: @Sendable (UUID) async throws -> [Item]

    /// Stores verified bytes for one item and binds its message part.
    /// Implementations must re-read the stored bytes, upsert the attachment
    /// record, and return true only when the part is resolvable. Retries and
    /// duplicate imports must be no-ops.
    public let restore: @Sendable (UUID, Item, Data) async throws -> Bool

    public init(pending: @escaping @Sendable (UUID) async throws -> [Item],
                restore: @escaping @Sendable (UUID, Item, Data) async throws -> Bool) {
        self.pending = pending
        self.restore = restore
    }
}

public enum DeviceAttachmentRestoreLimit {
    /// Per-conversation restore cap for one receive pass.
    public static let maximumItems = 512
    /// The in-memory attachment assembler is bounded independently of the
    /// workspace file path, which streams large files directly to disk.
    public static let maximumItemBytes = 32 * 1_024 * 1_024
    /// Total byte budget for one receive pass.
    public static let maximumTotalBytes: Int64 = 2 << 30
}
