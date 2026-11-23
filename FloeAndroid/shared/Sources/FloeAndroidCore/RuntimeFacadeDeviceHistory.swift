// SPDX-License-Identifier: MPL-2.0
//
// Device-history sync — store-facing lane (Android port of the fixed iOS/Mac
// device-link history surface, 0d2c31722). The App offers ordinary
// conversations to a trusted peer, exports their portable v1 bytes and
// explicitly imports verified peer bytes through the SAME native
// conversation database the rest of the product uses.
//
// Composition contract (owned here, not in the JNI TU):
//  * offers list ONLY ordinary, normally visible, unowned, unarchived
//    conversations — the unchanged `isVisibleInOrdinaryList` contract;
//  * export reads through `ConversationStore.deviceHistory` (one consistent
//    reader transaction, user/assistant text-only, redacted);
//  * import writes through `ConversationStore.importDeviceHistory` (one
//    writer transaction, idempotent append-if-absent, conflict aborts the
//    WHOLE import before any mutation);
//  * the decoded history id MUST equal the task id the App supplied — a
//    mismatched archive is refused before the store ever sees it;
//  * a conversation with a live run answers typed `busy`, mirroring the Mac
//    host's `liveRuns[id] != nil` refusal.
//
// This file is the ONLY FloeAndroidCore owner of those rules; the C ABI in
// DeviceHistoryNative.swift only fences epochs/sessions and copies bytes.

import Crypto
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence

// MARK: - Offer / result vocabulary

/// One shareable ordinary conversation, mirroring the fixed
/// `FloeDeviceSync.DeviceHistoryOffer` (iOS/Mac unchanged).
public struct DeviceHistoryOffer: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

/// Displayable, data-free failure taxonomy for the App surface. Carries no
/// message bytes, titles, paths or identities beyond the typed case.
public enum DeviceHistoryLaneError: Error, Sendable, Equatable {
    /// No live trusted generation / store for the fenced epoch.
    case unavailable
    /// The epoch belongs to another (or retired) generation.
    case fenced
    /// The conversation is missing or not an ordinary visible-owned row.
    case conversationUnavailable
    /// A same-id message exists with different content; nothing imported.
    case conflict
    /// The conversation has a live run; retry later.
    case busy
    /// Decoded bytes failed version/size/shape validation.
    case invalidArchive
    /// The decoded archive id does not match the App-supplied task id.
    case identityMismatch
    /// Archive exceeds the 32 MiB portable ceiling.
    case tooLarge
    case cursorExpired
    /// A store read/write hop failed (never reported as empty/success).
    case storeUnavailable
}

/// Bounded offer page assembly for one ordinary conversation store. Titles
/// are redacted and capped exactly like the fixed Mac host offers.
enum DeviceHistoryStoreLane {

    static let maximumOffers = 200
    static let offerTitleBytes = 1_024

    /// The shareable ordinary conversations, in the store's pinned-first
    /// recency order. Only rows the export side would also accept are
    /// listed, so an accepted offer can never fail eligibility afterwards.
    static func offers(store: any ConversationStore) async throws -> [DeviceHistoryOffer] {
        let rows = try await store.conversations(includeArchived: false)
        var seen = Set<UUID>()
        var result: [DeviceHistoryOffer] = []
        for row in rows where row.isVisibleInOrdinaryList {
            var title = String(SecretRedactor.redact(row.title).prefix(256))
            while title.utf8.count > offerTitleBytes { title.removeLast() }
            guard !title.isEmpty, seen.insert(row.id).inserted else { continue }
            result.append(.init(id: row.id, title: title))
            if result.count >= maximumOffers { break }
        }
        return result
    }

    /// Portable bytes of one offered conversation, redacted + encoded by the
    /// store itself (the exact fixed iOS encoding contract).
    static func exportHistory(store: any ConversationStore, conversationID: UUID,
                              version: Int = 1, epoch: UInt64? = nil) async throws -> Data {
        do {
            if version == 2 {
                guard let durable = store as? SQLiteConversationStore, let epoch else {
                    throw DeviceHistoryLaneError.storeUnavailable
                }
                try await indexAttachmentDigests(durable, conversationID: conversationID, epoch: epoch)
                return try await durable.deviceHistory(conversationID: conversationID, version: version).encoded()
            }
            return try await store.deviceHistory(conversationID: conversationID).encoded()
        } catch DeviceConversationHistoryError.conversationUnavailable {
            throw DeviceHistoryLaneError.conversationUnavailable
        } catch DeviceConversationHistoryError.sizeLimit {
            throw DeviceHistoryLaneError.tooLarge
        } catch DeviceConversationHistoryError.invalidHistory {
            throw DeviceHistoryLaneError.invalidArchive
        } catch let error as DeviceHistoryLaneError {
            throw error
        } catch {
            throw DeviceHistoryLaneError.storeUnavailable
        }
    }

    static func exportPage(
        store: any ConversationStore, conversationID: UUID, after: String?, through: Int64?,
        version: Int = 1, epoch: UInt64? = nil
    ) async throws -> DeviceConversationHistoryPage {
        guard let durable = store as? SQLiteConversationStore else { throw DeviceHistoryLaneError.storeUnavailable }
        do {
            if version == 2, after == nil {
                guard let epoch else { throw DeviceHistoryLaneError.storeUnavailable }
                try await indexAttachmentDigests(durable, conversationID: conversationID, epoch: epoch)
            }
            return try await durable.deviceHistoryPage(conversationID: conversationID, after: after,
                                                       through: through, version: version)
        } catch DeviceConversationHistoryError.cursorExpired {
            throw DeviceHistoryLaneError.cursorExpired
        } catch DeviceConversationHistoryError.conversationUnavailable {
            throw DeviceHistoryLaneError.conversationUnavailable
        } catch DeviceConversationHistoryError.sizeLimit {
            throw DeviceHistoryLaneError.tooLarge
        } catch DeviceConversationHistoryError.invalidHistory {
            throw DeviceHistoryLaneError.invalidArchive
        } catch let error as DeviceHistoryLaneError {
            throw error
        } catch {
            throw DeviceHistoryLaneError.storeUnavailable
        }
    }

    static func receiveCursor(
        store: any ConversationStore, peerID: String, conversationID: UUID
    ) async throws -> String? {
        guard let durable = store as? SQLiteConversationStore else { throw DeviceHistoryLaneError.storeUnavailable }
        do {
            return try await durable.deviceHistoryCursor(from: peerID, conversationID: conversationID)
        } catch {
            throw DeviceHistoryLaneError.storeUnavailable
        }
    }

    /// Decodes + validates the archive BEFORE admission into the durable
    /// writer: version/size/shape and the App-supplied identity guard. This
    /// is the cheap, revocation-free half of the import; the store half is
    /// `importHistory(store:history:hasLiveRun:)`.
    static func decodeHistory(bytes: Data, expectedID: UUID, expectedVersion: Int = 1) throws -> DeviceConversationHistory {
        guard bytes.count <= DeviceConversationHistory.maximumBytes else {
            throw DeviceHistoryLaneError.tooLarge
        }
        let history: DeviceConversationHistory
        do {
            history = try DeviceConversationHistory(data: bytes)
        } catch DeviceConversationHistoryError.sizeLimit {
            throw DeviceHistoryLaneError.tooLarge
        } catch {
            throw DeviceHistoryLaneError.invalidArchive
        }
        guard history.id == expectedID else { throw DeviceHistoryLaneError.identityMismatch }
        guard history.version == expectedVersion else { throw DeviceHistoryLaneError.invalidArchive }
        return history
    }

    /// The active-run probe re-proven INSIDE the import writer transaction.
    /// Uses the existing `FacadeRunDomain.activeRunStates` durable
    /// vocabulary: a run that committed `preparing` (admitted/preparing
    /// ownership included) is visible because GRDB serialises writers, so
    /// import and fresh run admission commit serially. A probe failure
    /// throws and fails the WHOLE transaction closed (typed refusal, never
    /// a partial import).
    static func hasLiveRunForImport(conversationID: UUID) -> @Sendable (Database) throws -> Bool {
        let states = FacadeRunDomain.activeRunStates.sorted()
        let placeholders = states.map { _ in "?" }.joined(separator: ",")
        let conversation = conversationID.uuidString
        return { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM runs
                        WHERE conversation_id = ? AND state IN (\(placeholders))
                    )
                    """,
                arguments: StatementArguments([conversation] + states)
            ) == true
        }
    }

    /// Explicit import of one ALREADY-DECODED history. The WHOLE import
    /// aborts before any mutation when one same-id message differs; an
    /// active durable run refuses typed, proven in the same writer.
    static func importHistory(
        store: any ConversationStore,
        history: DeviceConversationHistory,
        sourcePeerID: String? = nil,
        nextCursor: String? = nil,
        hasLiveRun: @escaping @Sendable (Database) throws -> Bool
    ) async throws -> DeviceConversationImport {
        do {
            if let sourcePeerID {
                guard let durable = store as? SQLiteConversationStore else {
                    throw DeviceHistoryLaneError.storeUnavailable
                }
                return try await durable.importDeviceHistory(
                    history, sourcePeerID: sourcePeerID, nextCursor: nextCursor, hasLiveRun: hasLiveRun)
            }
            return try await store.importDeviceHistory(history, hasLiveRun: hasLiveRun)
        } catch DeviceConversationHistoryError.messageConflict {
            throw DeviceHistoryLaneError.conflict
        } catch DeviceConversationHistoryError.busy {
            throw DeviceHistoryLaneError.busy
        } catch DeviceConversationHistoryError.conversationUnavailable {
            throw DeviceHistoryLaneError.conversationUnavailable
        } catch DeviceConversationHistoryError.sizeLimit {
            throw DeviceHistoryLaneError.tooLarge
        } catch DeviceConversationHistoryError.invalidHistory {
            throw DeviceHistoryLaneError.invalidArchive
        } catch let error as DeviceHistoryLaneError {
            throw error
        } catch {
            throw DeviceHistoryLaneError.storeUnavailable
        }
    }
}

// MARK: - Original user attachments

extension DeviceHistoryStoreLane {
    private static func attachmentService(epoch: UInt64) throws -> AttachmentStagingService {
        guard G02NativeRootEpoch.readback() == epoch,
              let installed = AttachmentStagingFacade.currentInstalled,
              installed.epoch == epoch else { throw DeviceHistoryLaneError.fenced }
        return installed.service
    }

    private static func fileDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func readCommitted(_ item: AttachmentRef, using service: AttachmentStagingService) -> Data? {
        guard item.storage == .applicationSupport, let relative = item.relativePath,
              let target = service.resolveStagedPath(relativePath: relative),
              (0...DeviceConversationHistory.maximumRestorableAttachmentBytesPerItem).contains(item.byteCount),
              let data = service.readAllBounded(url: target), data.count == item.byteCount else { return nil }
        return data
    }

    private static func indexAttachmentDigests(_ store: SQLiteConversationStore,
                                               conversationID: UUID, epoch: UInt64) async throws {
        let service = try attachmentService(epoch: epoch)
        let attachments = try await store.deviceHistoryUserAttachments(conversationID: conversationID,
                                                                        storage: .applicationSupport)
        for attachment in attachments where attachment.sha256.isEmpty {
            guard G02NativeRootEpoch.readback() == epoch else { throw DeviceHistoryLaneError.fenced }
            if let bytes = readCommitted(attachment, using: service) {
                try await store.noteDeviceAttachmentDigest(fileDigest(bytes), for: attachment)
            }
        }
    }

    static func exportAttachment(store: any ConversationStore, conversationID: UUID, attachmentID: UUID,
                                 epoch: UInt64) async throws -> Data {
        guard let store = store as? SQLiteConversationStore,
              let conversation = try await store.conversation(id: conversationID),
              conversation.isVisibleInOrdinaryList,
              let row = try await store.deviceHistoryUserAttachment(conversationID: conversationID, id: attachmentID),
              row.storage == .applicationSupport else { throw DeviceHistoryLaneError.conversationUnavailable }
        let service = try attachmentService(epoch: epoch)
        guard let bytes = readCommitted(row, using: service),
              fileDigest(bytes) == row.sha256 else { throw DeviceHistoryLaneError.conflict }
        return bytes
    }

    static func pendingAttachmentJSON(store: any ConversationStore, conversationID: UUID,
                                      byteBudget: Int) async throws -> String {
        guard let store = store as? SQLiteConversationStore,
              let conversation = try await store.conversation(id: conversationID),
              conversation.isVisibleInOrdinaryList else { throw DeviceHistoryLaneError.conversationUnavailable }
        let records = try await store.deviceHistoryUserAttachments(conversationID: conversationID, storage: .none)
        var bytesRemaining = DeviceConversationHistory.maximumRestorableAttachmentBytes
        var items: [[String: Any]] = []
        var truncated = false
        var wireRemaining = byteBudget - 128
        for row in records {
            guard let message = row.messageID, row.sha256.utf8.count == 64 else { continue }
            let item: [String: Any] = [
                "attachmentID": row.id.uuidString, "messageID": message.uuidString,
                "kind": row.kind == .image ? "image" : "file",
                "displayName": row.displayName, "byteCount": row.byteCount, "digest": row.sha256,
            ]
            wireRemaining -= ConversationWireBudget.encodedObjectBytes(item) + 1
            bytesRemaining -= Int64(row.byteCount)
            if wireRemaining < 0 || bytesRemaining < 0 {
                truncated = true
                break
            }
            items.append(item)
        }
        let body: [String: Any] = ["ok": 1, "schema": "floe.device-history.attachments.v1",
            "items": items, "truncated": truncated ? 1 : 0]
        let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return String(decoding: encoded, as: UTF8.self)
    }

    static func restoreAttachment(
        store: any ConversationStore, epoch: UInt64, conversationID: UUID,
        attachmentID: UUID, messageID: UUID, digest: String, bytes: Data,
        beginAdmission: @Sendable () -> Bool
    ) async throws -> Bool {
        guard let store = store as? SQLiteConversationStore,
              let conversation = try await store.conversation(id: conversationID),
              conversation.isVisibleInOrdinaryList,
              let row = try await store.deviceHistoryUserAttachment(conversationID: conversationID, id: attachmentID),
              row.messageID == messageID, row.sha256 == digest,
              row.byteCount == bytes.count,
              bytes.count <= DeviceConversationHistory.maximumRestorableAttachmentBytesPerItem,
              fileDigest(bytes) == digest else { throw DeviceHistoryLaneError.conflict }
        let service = try attachmentService(epoch: epoch)
        if row.storage == .applicationSupport {
            return readCommitted(row, using: service).map { fileDigest($0) == digest } == true
        }
        guard row.storage == .none, beginAdmission(), G02NativeRootEpoch.readback() == epoch else {
            throw DeviceHistoryLaneError.fenced
        }
        let name = StagingNameSanitizer.sanitize(displayNameHint: row.displayName,
                                                  fallbackStagingID: attachmentID)
        let relative = attachmentID.uuidString + "/" + name
        guard let target = service.resolveStagedPath(relativePath: relative) else {
            throw DeviceHistoryLaneError.storeUnavailable
        }
        let filesystem = FileManagerStagingFileSystem.shared
        let folder = target.deletingLastPathComponent()
        try filesystem.createDirectory(at: folder)
        guard service.resolveStagedPath(relativePath: relative) == target else {
            throw DeviceHistoryLaneError.storeUnavailable
        }
        if !filesystem.isRegularFile(atPath: target.path) {
            let transfer = folder.appendingPathComponent(".device-\(UUID().uuidString).tmp")
            defer { try? filesystem.removeItem(at: transfer) }
            try bytes.write(to: transfer, options: .withoutOverwriting)
            try filesystem.sync(transfer)
            guard G02NativeRootEpoch.readback() == epoch,
                  service.resolveStagedPath(relativePath: relative) == target else {
                throw DeviceHistoryLaneError.fenced
            }
            do { try filesystem.rename(from: transfer, to: target) }
            catch {
                guard filesystem.isRegularFile(atPath: target.path) else { throw error }
            }
        }
        guard service.resolveStagedPath(relativePath: relative) == target,
              let readBack = service.readAllBounded(url: target), readBack.count == row.byteCount,
              fileDigest(readBack) == digest else { throw DeviceHistoryLaneError.conflict }
        let hasLiveRun = hasLiveRunForImport(conversationID: conversationID)
        return try await store.restoreDeviceHistoryAttachment(conversationID: conversationID,
            attachmentID: attachmentID, messageID: messageID, digest: digest, relativePath: relative,
            guardCurrent: { db in
                guard G02NativeRootEpoch.readback() == epoch else { return false }
                return try !hasLiveRun(db)
            })
    }
}

// MARK: - JSON reply assembly (byte-bounded, sorted keys)

extension DeviceHistoryStoreLane {

    /// {"ok":1,"schema":"floe.device-history.offers.v1","offers":[...],
    ///  "truncated":0|1} — whole-page prefix budgeting: the reply only ever
    /// crosses when the REAL JSON fits the caller capacity (minus NUL),
    /// dropping whole trailing offers with the honest `truncated` flag.
    static func offersJSON(_ offers: [DeviceHistoryOffer], byteBudget: Int) -> (ok: Bool, json: String) {
        var items: [[String: Any]] = []
        var truncated = false
        for offer in offers {
            let candidate = items + [["id": offer.id.uuidString, "title": offer.title]]
            let body: [String: Any] = [
                "ok": 1,
                "schema": "floe.device-history.offers.v1",
                "offers": candidate,
                "truncated": 0,
            ]
            if JSONSerialization.isValidJSONObject(body),
               let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
               data.count <= byteBudget {
                items = candidate
            } else {
                truncated = true
                break
            }
        }
        let body: [String: Any] = [
            "ok": 1,
            "schema": "floe.device-history.offers.v1",
            "offers": items,
            "truncated": truncated ? 1 : 0,
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return (false, DeviceHistoryNativeJSON.internalError)
        }
        return (true, text)
    }

    /// {"ok":1,"schema":"floe.device-history.import.v1","conversationID",
    /// "addedMessages","createdConversation"}.
    static func importJSON(_ receipt: DeviceConversationImport) -> String {
        let body: [String: Any] = [
            "ok": 1,
            "schema": "floe.device-history.import.v1",
            "conversationID": receipt.conversationID.uuidString,
            "addedMessages": receipt.addedMessages,
            "createdConversation": receipt.createdConversation ? 1 : 0,
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return DeviceHistoryNativeJSON.internalError
        }
        return text
    }
}

/// Tiny JSON constants shared with the C ABI (no data surfaces).
enum DeviceHistoryNativeJSON {
    static let internalError = "{\"ok\":0,\"errorCode\":\"internal\"}"
}
