// SPDX-License-Identifier: MPL-2.0
// FloeApp — T6 production `DesignResultPublicationPort`.
//
// Returns an ADOPTED design result through the app's EXISTING stores only:
//   * `.chatAttachment`: a NEW attachment plus a durable message in the
//     ORIGINATING task (`target.ownerID`). The original attachment is never
//     modified or deleted.
//   * `.creativeDocument`: a NEW content-addressed asset in the existing
//     `CreativeAssetStore` (no parallel media library, no hidden Canvas).
//
// Idempotence is structural, not best-effort:
//   * every created identity (attachment/message/creative asset) is derived
//     from a binding key that combines the FULL frozen target (`stableKey`),
//     the publication destination and `publication.publicationKey`
//     (operationID|revisionID|contentSHA256). The same operation bytes used
//     for a DIFFERENT owner can never alias another task's attachment;
//   * a replay after a crash or a duplicate call RE-VERIFIES the real staged
//     bytes (bounded streaming digest), the destination row AND the durable
//     transcript notice before returning the receipt. An attachment written
//     without its message, a message without its attachment part, or a
//     corrupt/partial staged file is repaired through the same deterministic
//     identity instead of being mistaken for "published";
//   * the durable receipt index is written only after that verification and a
//     failed write THROWS (never a silent no-op), so a publication is never
//     claimed without a durable receipt.
//
// Honesty: a failed write throws and leaves at most one deterministic
// partial object; the next call completes it and returns the same receipt.
// Nothing here claims a publication that did not persist.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import CryptoKit
import UniformTypeIdentifiers
import FloeCore
import FloeModels
import FloePersistence
import FloeTools

@MainActor
struct AppDesignResultPublicationPort: DesignResultPublicationPort {
    let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func publish(
        _ publication: DesignResultPublication
    ) async throws -> DesignResultPublicationReceipt {
        switch publication.target.kind {
        case .chatAttachment:
            return try await publishToChat(publication)
        case .creativeDocument:
            return try await publishToCreative(publication)
        case .canvasNode, .fileDocument:
            throw FloeError.validationFailed(
                "\(publication.target.kind.rawValue) results have no separate publication destination; they are committed in place or exported as a verified revision")
        }
    }

    // MARK: - Binding identity (target + destination + payload)

    /// The port-local publication binding. `publicationKey` alone is
    /// model-influenced operation identity; the destination and the frozen
    /// target must be part of every derived id so an identical operation and
    /// payload for a DIFFERENT owner can never reuse another owner's
    /// attachment/asset/receipt.
    static func chatBindingKey(for publication: DesignResultPublication) throws -> String {
        guard let destination = chatDestination(for: publication) else {
            throw FloeError.validationFailed("Chat publication target is not a conversation identity")
        }
        return try bindingKey(for: publication, destination: destination)
    }

    static func creativeBindingKey(for publication: DesignResultPublication) -> String {
        return (try? bindingKey(
            for: publication,
            destination: "creative:\(publication.target.ownerID)"))
            ?? "\(publication.target.stableKey)|creative:\(publication.target.ownerID)|\(publication.publicationKey)"
    }

    static func bindingKey(
        for publication: DesignResultPublication,
        destination: String
    ) throws -> String {
        let targetKey = publication.target.stableKey
        // The frozen key recorded at commit time is audit data; when present
        // it must agree with the live target, otherwise the publication is
        // bound to a different owner than it claims.
        let frozen = publication.targetStableKey
        guard frozen.isEmpty || frozen == targetKey else {
            throw FloeError.validationFailed(
                "The publication's frozen target does not match its live owner identity")
        }
        return "\(targetKey)|\(destination)|\(publication.publicationKey)"
    }

    static func chatDestination(for publication: DesignResultPublication) -> String? {
        guard UUID(uuidString: publication.target.ownerID) != nil else { return nil }
        return "chat:\(publication.target.ownerID)"
    }

    static func chatAttachmentID(bindingKey: String) -> UUID {
        deterministicUUID("floe.design.publication.attachment|\(bindingKey)")
    }

    static func chatMessageID(bindingKey: String) -> UUID {
        deterministicUUID("floe.design.publication.message|\(bindingKey)")
    }

    static func creativeAssetID(bindingKey: String) -> UUID {
        deterministicUUID("floe.design.publication.asset|\(bindingKey)")
    }

    /// Canonical on-disk file name for a creative-library asset. Always
    /// derived from the CANONICAL asset id so a content-hash merge can never
    /// leave the file under a losing candidate id. The display name is
    /// sanitized again here: a canonical row may have been created by another
    /// producer and must never contribute a path separator.
    static func creativeRelativePath(assetID: UUID, displayName: String) -> String {
        let safe = displayName
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "Materials/\(assetID.uuidString)-design-\(safe.isEmpty ? "asset" : safe)"
    }

    // MARK: - Chat (originating task only)

    private func publishToChat(
        _ publication: DesignResultPublication
    ) async throws -> DesignResultPublicationReceipt {
        guard let conversationID = UUID(uuidString: publication.target.ownerID) else {
            throw FloeError.validationFailed("Chat publication target is not a conversation identity")
        }
        // Attribution guard: when an originating task is recorded it MUST be
        // the destination conversation — a result can never land in another
        // task's transcript.
        if let origin = publication.originConversationID,
           origin.caseInsensitiveCompare(publication.target.ownerID) != .orderedSame {
            throw FloeError.validationFailed(
                "The adopted result's originating task does not match the publication destination")
        }
        guard try await environment.conversationStore.conversation(id: conversationID) != nil else {
            throw FloeError.validationFailed("The originating task no longer exists; the result is retained pending")
        }
        let digest = publication.contentSHA256.lowercased()
        guard FloeDigest.sha256Hex(publication.bytes) == digest else {
            throw FloeError.validationFailed("The publication payload does not match its verified digest")
        }
        let bindingKey = try Self.chatBindingKey(for: publication)
        let destination = "chat:\(publication.target.ownerID)"
        let attachmentID = Self.chatAttachmentID(bindingKey: bindingKey)
        let messageID = Self.chatMessageID(bindingKey: bindingKey)
        let displayName = Self.sanitizedDisplayName(
            publication.displayName, format: publication.format, seed: digest)
        let relativePath = "\(attachmentID.uuidString)-\(displayName)"
        let kind = Self.attachmentKind(forFormat: publication.format)
        let stagedURL = try Self.attachmentStagingDirectory()
            .appendingPathComponent(relativePath)

        // (1) Real staged bytes exist and match the verified digest. A partial
        // or corrupt write is repaired through the SAME deterministic path and
        // re-verified by reading the file back (bounded streaming digest).
        try Self.ensureStagedBytes(publication.bytes, at: stagedURL, digest: digest)

        // (2) The destination attachment row must describe THIS payload and
        // THIS task/message. An existing row is never trusted by id alone.
        // The message row may not exist yet on the FIRST publication (the
        // attachment is written first so an interruption stays repairable),
        // and `attachments.message_id` has a FK to `messages`. The row is
        // therefore persisted without the link and linked in (4) once the
        // message is durable.
        let existingMessages = try await environment.conversationStore.messages(
            conversationID: conversationID)
        let existingNotice = existingMessages.first { $0.id == messageID }
        var attachment: AttachmentRef
        var attachmentNeedsLink = false
        if let existing = try await environment.conversationStore.attachment(id: attachmentID) {
            guard existing.conversationID == conversationID,
                  existing.messageID == messageID || existing.messageID == nil,
                  existing.sha256.caseInsensitiveCompare(digest) == .orderedSame,
                  existing.byteCount == publication.bytes.count,
                  existing.relativePath == relativePath,
                  existing.kind == kind else {
                throw FloeError.validationFailed(
                    "A different attachment already occupies this publication identity; nothing was overwritten")
            }
            attachment = existing
            attachmentNeedsLink = existing.messageID == nil
        } else {
            attachment = AttachmentRef(
                id: attachmentID,
                conversationID: conversationID,
                messageID: nil,
                kind: kind,
                displayName: displayName,
                uti: Self.utiIdentifier(forFormat: publication.format),
                byteCount: publication.bytes.count,
                sha256: digest,
                storage: .applicationSupport,
                urlBookmark: nil,
                relativePath: relativePath)
            try await environment.conversationStore.saveAttachment(attachment)
            attachmentNeedsLink = true
        }

        // (3) The durable visible notice must exist AND carry the attachment
        // part. A crash between the attachment row and the message (or a
        // damaged part) is repaired by the same insert-or-update message id.
        let metadata: [String: String] = [
            "name": displayName,
            "design.publicationKey": bindingKey,
            "design.candidateID": publication.candidateID,
            "design.revisionID": publication.revisionID,
            "design.contentSHA256": digest,
            "design.mode": publication.mode.rawValue,
        ]
        let notice = FloeL10n.isChinese
            ? "已采纳的设计结果已返回到此任务：\(displayName)（候选 \(publication.candidateID)，摘要 \(digest.prefix(12))），原附件与来源保持不变。"
            : "The adopted design result was returned to this task: \(displayName) (candidate \(publication.candidateID), digest \(digest.prefix(12))); the original source and attachment are unchanged."
        let partKind: MessagePart.Kind = kind == .image ? .image : .file
        let part = MessagePart(
            messageID: messageID, partIndex: 0, kind: partKind,
            text: displayName, attachmentID: attachmentID,
            metadata: metadata)
        let message = PersistedMessage(
            id: messageID, conversationID: conversationID,
            role: "assistant", content: notice, createdAt: Date(),
            parts: [part])
        if let existingNotice {
            guard existingNotice.conversationID == conversationID else {
                throw FloeError.validationFailed(
                    "A different message already occupies this publication identity")
            }
            let partIsIntact = existingNotice.parts.contains {
                $0.attachmentID == attachmentID
                    && $0.kind == partKind
                    && $0.metadata["design.publicationKey"] == bindingKey
            }
            if !partIsIntact {
                try await environment.conversationStore.appendMessage(message)
            }
        } else {
            try await environment.conversationStore.appendMessage(message)
        }

        // (4) Link the attachment to its durable message now that the FK
        // target exists. Idempotent: only done when the link was missing.
        if attachmentNeedsLink {
            attachment.messageID = messageID
            try await environment.conversationStore.saveAttachment(attachment)
        }

        // (5) Receipt only after the real attachment bytes, the destination
        // row and the visible notice were all verified/committed. A failed
        // receipt write THROWS instead of silently claiming publication.
        let receipt = DesignResultPublicationReceipt(
            identifier: attachmentID.uuidString,
            destination: destination,
            contentSHA256: digest)
        try DesignPublicationReceiptStore().record(receipt, for: bindingKey)
        return receipt
    }

    // MARK: - Creative (existing asset library)

    private func publishToCreative(
        _ publication: DesignResultPublication
    ) async throws -> DesignResultPublicationReceipt {
        let digest = publication.contentSHA256.lowercased()
        guard FloeDigest.sha256Hex(publication.bytes) == digest else {
            throw FloeError.validationFailed("The publication payload does not match its verified digest")
        }
        let bindingKey = Self.creativeBindingKey(for: publication)
        let destination = "creative:\(publication.target.ownerID)"
        let displayName = Self.sanitizedDisplayName(
            publication.displayName, format: publication.format, seed: digest)
        let kind = Self.mediaKind(forFormat: publication.format)
        let expectedAssetID = Self.creativeAssetID(bindingKey: bindingKey)
        let assetStore = environment.creativeAssetStore

        // The existing library is content-addressed: identical bytes are ONE
        // canonical row. Resolve/prepare the canonical record first and never
        // trust an id-only lookup.
        let canonical: CreativeAssetRecord
        if let byDigest = try await assetStore.asset(contentHash: digest) {
            canonical = byDigest
        } else {
            canonical = try await assetStore.saveResolvingCanonical(CreativeAssetRecord(
                id: expectedAssetID,
                contentHash: digest,
                kind: kind,
                displayName: displayName,
                mimeType: Self.utiIdentifier(forFormat: publication.format),
                localRelativePath: Self.creativeRelativePath(
                    assetID: expectedAssetID, displayName: displayName),
                byteCount: Int64(publication.bytes.count),
                tags: ["design", "adopted"],
                referenceCount: 0,
                createdAt: Date(),
                updatedAt: Date()))
        }
        guard canonical.contentHash.caseInsensitiveCompare(digest) == .orderedSame else {
            throw FloeError.validationFailed(
                "A different creative asset already occupies this publication identity; nothing was overwritten")
        }

        // Durable file lives at the CANONICAL id path (a losing candidate id
        // must never own the bytes). Missing/corrupt bytes are rewritten from
        // the verified payload and re-read back.
        let storedRelative = canonical.localRelativePath.flatMap { $0.isEmpty ? nil : $0 }
        let relativePath = storedRelative
            ?? Self.creativeRelativePath(assetID: canonical.id, displayName: canonical.displayName)
        let target = try Self.artifactRoot().appendingPathComponent(relativePath)
        try Self.ensureStagedBytes(publication.bytes, at: target, digest: digest)
        if storedRelative != relativePath {
            var repaired = canonical
            repaired.localRelativePath = relativePath
            repaired.updatedAt = Date()
            try await assetStore.save(repaired)
        }

        // Read the row back: the receipt is only issued for the canonical row
        // that actually carries this digest.
        guard let readback = try await assetStore.asset(id: canonical.id),
              readback.contentHash.caseInsensitiveCompare(digest) == .orderedSame else {
            throw FloeError.storageCorrupted(
                "The published creative asset row could not be read back after the write")
        }

        let receipt = DesignResultPublicationReceipt(
            identifier: readback.id.uuidString,
            destination: destination,
            contentSHA256: digest)
        try DesignPublicationReceiptStore().record(receipt, for: bindingKey)
        return receipt
    }

    // MARK: - Real staged bytes (bounded readback)

    /// Writes `bytes` atomically when the destination file is missing or does
    /// not already contain EXACTLY those bytes, then verifies by reading the
    /// file back with a bounded streaming digest.
    static func ensureStagedBytes(_ bytes: Data, at url: URL, digest: String) throws {
        if (try? verifiedFileDigest(of: url, expectedByteCount: bytes.count)) == digest {
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: [.atomic])
        guard (try? verifiedFileDigest(of: url, expectedByteCount: bytes.count)) == digest else {
            throw FloeError.storageCorrupted(
                "Published bytes did not match their verified digest after the write")
        }
    }

    /// Streaming SHA-256 with a hard upper bound: never loads the whole file
    /// into memory and refuses a file whose size changed under us.
    static func verifiedFileDigest(of url: URL, expectedByteCount: Int) throws -> String {
        guard expectedByteCount >= 0 else {
            throw FloeError.validationFailed("Expected byte count cannot be negative")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            total += chunk.count
            guard total <= expectedByteCount else {
                throw FloeError.storageCorrupted("The staged file is larger than its verified payload")
            }
            hasher.update(data: chunk)
        }
        guard total == expectedByteCount else {
            throw FloeError.storageCorrupted("The staged file is incomplete")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Deterministic identities + storage conventions

    /// RFC 4122 v5-style UUID over a SHA-256 digest: stable across launches
    /// and devices (same seed → same id), so replays cannot duplicate.
    static func deterministicUUID(_ seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Same directory convention as `FilesCenter` staging, so the existing
    /// `resolveURL(for:)` reads these attachments without a second store.
    static func attachmentStagingDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let directory = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func artifactRoot() throws -> URL {
        try FloeArtifactStore.root()
    }

    /// Deterministic safe file name. `seed` (the verified content digest) is
    /// used for the fallback so a retry of the SAME publication can never
    /// write a second random-named staging file (an orphaned partial).
    static func sanitizedDisplayName(_ raw: String, format: String, seed: String) -> String {
        let base = (raw as NSString).lastPathComponent
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            return "Design-\(String(seed.prefix(12))).\(format)"
        }
        if (base as NSString).pathExtension.isEmpty {
            return "\(base).\(format)"
        }
        return base
    }

    static func attachmentKind(forFormat format: String) -> AttachmentRef.Kind {
        switch format.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg":
            return .image
        case "mp3", "wav", "m4a", "aac", "flac":
            return .audio
        case "md", "txt", "html", "json", "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx":
            return .document
        default:
            return .other
        }
    }

    static func utiIdentifier(forFormat format: String) -> String {
        UTType(filenameExtension: format.lowercased())?.identifier ?? "public.data"
    }

    static func mediaKind(forFormat format: String) -> MediaKind {
        switch format.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg":
            return .image
        case "mp4", "mov", "m4v", "webm":
            return .video
        case "mp3", "wav", "m4a", "aac", "flac":
            return .audio
        default:
            return .document
        }
    }
}

/// Durable receipt index for design-result publications, kept under the
/// existing artifact authority. It is an audit/idempotency index only: the
/// attachment/asset record itself remains authoritative, and this store
/// never holds payload bytes. A missing root is an ERROR (the receipt is
/// part of the durability promise); it is never a silent no-op.
struct DesignPublicationReceiptStore {
    private var fileURL: URL? {
        (try? FloeArtifactStore.root())
            .map { $0.appendingPathComponent("DesignPublications/receipts.json") }
    }

    func receipt(for key: String) -> DesignResultPublicationReceipt? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return nil
        }
        return entries[key]?.receipt
    }

    func record(_ receipt: DesignResultPublicationReceipt, for key: String) throws {
        guard let fileURL else {
            throw FloeError.internalError(
                "The artifact root is unavailable; the publication receipt cannot be recorded")
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var entries: [String: Entry] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
        entries[key] = Entry(
            identifier: receipt.identifier,
            destination: receipt.destination,
            contentSHA256: receipt.contentSHA256,
            recordedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(entries).write(to: fileURL, options: [.atomic])
    }

    struct Entry: Codable {
        var identifier: String
        var destination: String
        var contentSHA256: String
        var recordedAt: Date

        var receipt: DesignResultPublicationReceipt {
            DesignResultPublicationReceipt(
                identifier: identifier,
                destination: destination,
                contentSHA256: contentSHA256)
        }
    }
}
#endif
