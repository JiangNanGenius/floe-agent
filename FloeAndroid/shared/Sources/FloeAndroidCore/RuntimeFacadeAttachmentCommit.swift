// SPDX-License-Identifier: MPL-2.0
//
// RB-7 attachment staging — conversation commit CAS, ownership reads and the
// launch consumption adapter.
//
// Durable authority (unchanged, deliberately):
// * The ORIGINAL schema-46 `attachments` table + the original
//   `SQLiteConversationStore` remain the ownership truth. This file adds NO
//   schema and NO parallel store; the launch path keeps the ORIGINAL atomic
//   `RunLaunchStore.prepare` as the ONLY message-attachment insertion point.
//   `attachment.commit` (conversationLifecycle, pre-run) persists a
//   conversation-LEVEL row (message_id NULL) through two narrow ADDITIVE
//   store seams whose verification closures run INSIDE the original writer
//   transaction — the same reviewed seam style as the RB3 deletion hook.
//   A row later bound to a message by prepare can never be inserted or
//   deleted here (`message_id IS NULL` is part of every destructive guard).
// * Revision CAS uses the settled opaque full raw-row digest grammar:
//   conversations through RB3's reviewed `ConversationRowRevision`
//   (floe.conversation-row.v1, consumed by name), attachment rows through
//   the identical algorithm under the new literal domain
//   `floe.attachment-row.v1` (CanonicalDigest is domain-parameterized by
//   design — the exact convention RB3 recorded for its own admission).
//
// The trusted bounded image loader lives on the service itself
// (RuntimeFacadeAttachmentStaging.swift): host-native equivalent of the
// original `ConversationHistoryAssembler.inlineImage`, streaming through the
// same file seam with size + digest + magic re-verification, outputting the
// ORIGINAL `ConversationImagePart` for provider memory paths only. base64
// never crosses the bridge, never enters JSON settlement or logs; formats
// ImageIO would rasterize on Apple hosts honestly omit on Android.
//
// This source is NOT compiled/executed by the authoring package.
import Foundation
import Crypto
import FloeCore
import GRDB
import FloeModels
import FloePersistence
import FloeAgentRuntime

// MARK: - Attachment row revision (settled digest grammar, new domain literal)

public enum AttachmentRowRevision {
    /// Admission-pinned domain literal defined HERE (no upstream/P0 edit);
    /// CanonicalDigest is domain-parameterized by design — the same note
    /// RB3 recorded for `floe.conversation-row.v1`.
    public static let domain = "floe.attachment-row.v1"
    public static let resourcePrefix = "attachment."

    public static func resourceID(attachmentID: UUID) -> String {
        resourcePrefix + attachmentID.uuidString
    }

    /// Compares PARSED UUIDs, not raw spelling (the frozen v3 cursor rule
    /// precedent, BridgeEnvelopeV3.swift:721-726).
    public static func matches(revisionResourceID: String, attachmentID: UUID) -> Bool {
        guard revisionResourceID.hasPrefix(resourcePrefix) else { return false }
        let raw = String(revisionResourceID.dropFirst(resourcePrefix.count))
        guard let parsed = UUID(uuidString: raw) else { return false }
        return parsed == attachmentID
    }

    /// Deterministic sorted column-name + type-tagged pairs over the REAL
    /// attachment row (every column it actually has — future-proof),
    /// mirroring `ConversationRowRevision.digest(of:)` exactly.
    public static func digest(of row: Row) -> String {
        let pairs = row
            .map { (name: $0.0, value: $0.1) }
            .sorted { $0.name < $1.name }
        var fields: [SettingsDomainV1.CanonicalDigest.Field] = []
        fields.reserveCapacity(pairs.count * 2)
        for pair in pairs {
            fields.append(.text(pair.name))
            fields.append(field(pair.value))
        }
        return SettingsDomainV1.CanonicalDigest.rowToken(domain: domain, fields: fields)
    }

    static func field(_ value: DatabaseValue) -> SettingsDomainV1.CanonicalDigest.Field {
        switch value.storage {
        case .null: return .null
        case .int64(let value): return .integer(value)
        case .double(let value): return .real(value)
        case .string(let value): return .text(value)
        case .blob(let value): return .blob(value)
        }
    }
}

// MARK: - Narrow additive store port

/// The additive seams this lane REQUIRES on the ORIGINAL store (exact delta
/// in patches/RB7_ATTACHMENT_STAGING_LIVE_APPLY.patch, with the symlink
/// preimage and upstream pin recorded in provenance/). Verification closures
/// run INSIDE the store's own writer transaction immediately before the
/// effect, so admission and the durable write can never interleave with
/// another writer.
public protocol AttachmentCommittingStore: ConversationStore {
    /// Insert the EXACT staged conversation-level attachment row (original
    /// column set) only if `verification` passes in the same transaction.
    func insertAttachmentRowGuarded(
        _ attachment: AttachmentRef,
        verification: @escaping @Sendable (Database) throws -> Void
    ) async throws

    /// Delete the EXACT attachment row only if `verification` passes in the
    /// same transaction. Returns true only when the guarded DELETE actually
    /// removed the row.
    func deleteAttachmentRowGuarded(
        id: UUID,
        verification: @escaping @Sendable (Database) throws -> Void
    ) async throws -> Bool

    /// Bounded single-row raw read for digest/CAS tokens. The projection
    /// closure runs inside the store's reader transaction; nil row means
    /// absent. (The store never learns digest grammars — the core computes
    /// them from the Row.)
    func readAttachmentRow<T: Sendable>(
        id: UUID,
        projection: @escaping @Sendable (Row?) throws -> T
    ) async throws -> T
}

/// Conformance is asserted by the published additive store diff (same
/// module boundary Main controls). Until that lands these requirements do
/// not exist and the lane fails closed at Main's binding step — never a
/// silent alternate path.
extension SQLiteConversationStore: AttachmentCommittingStore {}

// MARK: - Commit / cancel / read flows on the staging service
//
// Lock discipline: every flow validates through the service's locked
// helpers, takes an explicit mark (or none for reads), and performs the
// ORIGINAL store await OUTSIDE any lock; the RAM transition is applied only
// after the durable truth settles. Nothing here deletes bytes before the DB
// effect is known, and nothing ever removes a message-bound row.

public extension AttachmentStagingService {

    /// One staged handle → conversation-level row through the original
    /// writer with in-transaction CAS. Truths stay distinct and are never
    /// downgraded:
    ///   * handle not staged / marked / leased  → typed refusal
    ///   * conversation missing or not ordinary → `.wrongOwner`
    ///   * conversation row digest moved        → `.rowChanged`
    ///   * existing durable row differing in any owned/size/digest/storage
    ///     field                               → `.digestMismatch` (never an
    ///     overwrite); identical values are a verified replay.
    /// On DB failure the staged bytes stay owned and reusable: the mark is
    /// cleared and the handle keeps working — exactly the failed-prepare
    /// recovery rule.
    func commitStagedHandle(_ handle: String, conversationID: UUID,
                            expectedConversationDigest: String) async
        -> Result<StagedRecordView, AttachmentStagingError>
    {
        let correlation = "commit:" + UUID().uuidString
        guard let info = routeInfo(handle: handle), info.state == .staged else {
            return .failure(AttachmentStagingError(.handleUnknown))
        }
        if let refusal = markLaunchReference(handle: handle, correlation: correlation) {
            return .failure(AttachmentStagingError(refusal))
        }
        guard let view = snapshot(handle: handle),
              let id = UUID(uuidString: view.stagingID),
              let record = stagedRecord(id: id) else {
            _ = clearLaunchMark(handle: handle, correlation: correlation)
            return .failure(AttachmentStagingError(.handleUnknown))
        }
        let attachment = attachmentRef(for: record)
        var bound = attachment
        bound.conversationID = conversationID
        // message_id stays NULL. The ORIGINAL atomic prepare is the only
        // message-binding path (contract; never a second manual insert).
        do {
            try await components.store.insertAttachmentRowGuarded(bound) { db in
                guard let conversation = try Row.fetchOne(
                        db,
                        sql: "SELECT * FROM conversations WHERE id = ?",
                        arguments: [conversationID.uuidString]),
                      (conversation["purpose"] as String?) == "ordinary" else {
                    throw FloeError.validationFailed("attachmentCommit.wrongOwner")
                }
                guard ConversationRowRevision.digest(of: conversation)
                        == expectedConversationDigest else {
                    throw FloeError.validationFailed("attachmentCommit.rowChanged")
                }
                if let existing = try Row.fetchOne(
                        db,
                        sql: "SELECT * FROM attachments WHERE id = ?",
                        arguments: [attachment.id.uuidString]) {
                    let sameConversation: String? = existing["conversation_id"]
                    let existingMessage: String? = existing["message_id"]
                    let existingBytes: Int64 = existing["byte_count"]
                    let existingSHA: String = existing["sha256"]
                    let existingStorage: String = existing["storage"]
                    guard sameConversation == conversationID.uuidString,
                          existingMessage == nil,
                          Int(existingBytes) == attachment.byteCount,
                          existingSHA == attachment.sha256,
                          existingStorage == AttachmentRef.Storage.applicationSupport.rawValue
                    else {
                        throw FloeError.validationFailed("attachmentCommit.digestMismatch")
                    }
                    // Verified replay: identical values; the guarded INSERT
                    // below writes the same row again inside the same
                    // transaction. Ownership never moves.
                }
            }
        } catch let error as FloeError {
            _ = clearLaunchMark(handle: handle, correlation: correlation)
            return .failure(AttachmentStagingError(Self.mapStoreError(error)))
        } catch {
            _ = clearLaunchMark(handle: handle, correlation: correlation)
            return .failure(AttachmentStagingError(.storeUnavailable))
        }
        markRowCommitted(stagingID: id)
        guard let finalView = snapshot(stagingID: id.uuidString) else {
            return .success(view)
        }
        return .success(finalView)
    }

    static func mapStoreError(_ error: FloeError) -> AttachmentStagingCode {
        switch error {
        case .validationFailed(let detail):
            if detail.contains("rowChanged") { return .rowChanged }
            if detail.contains("wrongOwner") { return .wrongOwner }
            if detail.contains("digestMismatch") { return .digestMismatch }
            return .payloadInvalid
        case .notFound: return .wrongOwner
        default: return .storeUnavailable
        }
    }

    /// `attachment.cancel` (conversationLifecycle): cancel a
    /// COMMITTED-BUT-PRE-RUN conversation-level attachment row (message_id
    /// NULL) with a same-transaction row digest CAS; the bytes are removed
    /// ONLY after the guarded DELETE settled. A row already bound to a
    /// message is refused `.rowBoundToMessage` (conversation/message
    /// history deletion belongs to the RB3 lifecycle, never here), and a
    /// cancellation attempted after a durable commit already happened is
    /// reported truthfully — never as a "rollback".
    func cancelCommittedRow(attachmentID: String, conversationID: UUID,
                            expectedRowDigest: String) async
        -> Result<StagedRecordView?, AttachmentStagingError>
    {
        guard let id = UUID(uuidString: attachmentID) else {
            return .failure(AttachmentStagingError(.payloadInvalid))
        }
        let before = snapshot(stagingID: attachmentID)
        do {
            let deleted = try await components.store.deleteAttachmentRowGuarded(id: id) { db in
                guard let row = try Row.fetchOne(
                        db,
                        sql: "SELECT * FROM attachments WHERE id = ?",
                        arguments: [id.uuidString]) else {
                    throw FloeError.validationFailed("attachmentCancel.notFound")
                }
                let owner: String? = row["conversation_id"]
                let message: String? = row["message_id"]
                guard owner == conversationID.uuidString else {
                    throw FloeError.validationFailed("attachmentCancel.wrongOwner")
                }
                guard message == nil else {
                    throw FloeError.validationFailed("attachmentCancel.rowBoundToMessage")
                }
                guard AttachmentRowRevision.digest(of: row) == expectedRowDigest else {
                    throw FloeError.validationFailed("attachmentCancel.rowChanged")
                }
            }
            guard deleted else {
                return .failure(AttachmentStagingError(.wrongOwner))
            }
        } catch let error as FloeError {
            switch error {
            case .validationFailed(let detail):
                if detail.contains("rowBoundToMessage") {
                    return .failure(AttachmentStagingError(.rowBoundToMessage))
                }
                if detail.contains("rowChanged") {
                    return .failure(AttachmentStagingError(.rowChanged))
                }
                if detail.contains("wrongOwner") {
                    return .failure(AttachmentStagingError(.wrongOwner))
                }
                if detail.contains("notFound") {
                    return .failure(AttachmentStagingError(.handleUnknown))
                }
                return .failure(AttachmentStagingError(.storeUnavailable))
            default:
                return .failure(AttachmentStagingError(.storeUnavailable))
            }
        } catch {
            return .failure(AttachmentStagingError(.storeUnavailable))
        }
        // Row gone. Now (and only now) drop this lane's RAM record and the
        // exact derived file — never a scan, never another route's bytes.
        var removedView: StagedRecordView?
        if let view = before {
            removeStagedRecordAfterRowDeletion(id: id)
            removeStagedFile(stagingID: id, name: view.displayName)
            removedView = view
        } else {
            // No RAM projection (committed in an earlier generation): only
            // the strictly UUID-named per-attachment directory is inspected;
            // exactly-one-file directories are this row's own bytes.
            let directory = attachmentsDirectoryURL
                .appendingPathComponent(id.uuidString, isDirectory: true)
            let names = listFileNamesForCleanup(at: directory)
            if names.count == 1, let name = names.first {
                removeStagedFile(stagingID: id, name: name)
            }
        }
        removeManifestEntry(stagingID: attachmentID)
        return .success(removedView)
    }

    /// Bounded ownership verification for `attachment.read`, mirroring the
    /// original ChatAttachmentOpen.prepare sequence minus the iOS-only
    /// editor/workspace handoff (G02 read = preview/download channel):
    /// exact ordinary conversation row; exact attachment row ownership;
    /// bounded message-page + containing-part proof when the row carries a
    /// message id; digest CAS token returned for follow-up cancel.
    func verifyReadableAttachment(attachmentID: String,
                                  conversationID: UUID) async
        -> (row: AttachmentRef, rowDigest: String)? {
        guard let id = UUID(uuidString: attachmentID) else { return nil }
        guard let conversation = try? await components.store.conversation(id: conversationID),
              conversation.purpose == .ordinary else { return nil }
        guard let row = try? await components.store.attachment(id: id),
              row.conversationID == conversationID else { return nil }
        if let messageID = row.messageID {
            var cursor: ConversationMessageCursor?
            var messageOwned = false
            while true {
                guard let page = try? await components.store.messagePage(
                        conversationID: conversationID, before: cursor, limit: 100)
                else { return nil }
                if page.messages.contains(where: {
                    $0.id == messageID && $0.conversationID == conversationID
                }) {
                    messageOwned = true
                    break
                }
                guard page.hasEarlier, let next = page.earlierCursor, next != cursor else {
                    break
                }
                cursor = next
            }
            guard messageOwned else { return nil }
            guard let parts = try? await components.store.parts(messageID: messageID) else {
                return nil
            }
            guard parts.contains(where: {
                $0.attachmentID == id && ($0.kind == .file || $0.kind == .image)
            }) else { return nil }
        }
        let token: String? = try? await components.store.readAttachmentRow(id: id) { row in
            row.map { AttachmentRowRevision.digest(of: $0) }
        }
        guard let digest = token, !digest.isEmpty else { return nil }
        return (row, digest)
    }

    /// Read the exact bytes of an OWNED committed attachment through the
    /// bounded file seam under the validated attachments root. The durable
    /// row's recorded byteCount must equal the actual file size; a missing
    /// or mismatched file is nil (typed refusal at the bridge), never a
    /// partial page presented as complete.
    func readCommittedBytes(attachment: AttachmentRef, offset: Int64,
                            maxBytes: Int) -> Data? {
        guard attachment.storage == .applicationSupport,
              let relative = attachment.relativePath,
              let url = resolveStagedPath(relativePath: relative),
              maxBytes >= 0, maxBytes <= AttachmentStagingLimits.maximumChunkBytes,
              isRegularFile(atPath: url.path),
              let size = fileSize(atPath: url.path),
              size == attachment.byteCount,
              offset >= 0, offset <= Int64(size) else { return nil }
        let length = min(maxBytes, size - Int(offset))
        return readFile(offset: offset, length: length, at: url)
    }

    /// The RB3 deletion-lifecycle handoff: remove THIS lane's files for
    /// attachment ids whose rows were deleted inside the original
    /// conversation-deletion transaction. Exact derived paths only — no
    /// scanning, no following links, never other conversations' bytes.
    /// Returns the ids whose bytes settled gone.
    func cleanupDeletedConversation(attachmentIDs: [String]) -> [String] {
        var removed: [String] = []
        for raw in attachmentIDs {
            guard let id = UUID(uuidString: raw) else { continue }
            if let view = snapshot(stagingID: raw) {
                removeStagedRecordAfterRowDeletion(id: id)
                removeStagedFile(stagingID: id, name: view.displayName)
                removed.append(raw)
            } else {
                // File exists without any RAM record (launched/committed in
                // an earlier generation): only the strictly UUID-named
                // per-attachment directory is inspected; a directory with
                // exactly one file is ours.
                let directory = attachmentsDirectoryURL
                    .appendingPathComponent(id.uuidString, isDirectory: true)
                let names = listFileNamesForCleanup(at: directory)
                guard names.count == 1, let name = names.first else { continue }
                removeStagedFile(stagingID: id, name: name)
                removed.append(raw)
            }
            removeManifestEntry(stagingID: raw)
        }
        return removed
    }

    /// The attachments directory (derived from the accepted root, never
    /// caller-chosen).
    var attachmentsDirectoryURL: URL {
        URL(fileURLWithPath: components.identity.root.path, isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
    }
}

// MARK: - Launch consumption adapter (RB4 port, parent-compatible)

/// Conforms to RB4's reviewed `RunStagedAttachmentAuthority`
/// (RuntimeFacadeRunIngress.swift:98-102, consumed by name after Main
/// publishes that lane). This is the PARENT-compatible entry: resolve-only.
/// Because the current parent binding has no reservation/commit handshake,
/// every successful resolve takes a launch mark so the SAME handle cannot
/// be handed to a second launch's transaction while the first is unresolved;
/// the durable PK/transaction remains the final backstop, and
/// `reconcileLaunchMarked` clears stale marks from exact-row truth.
///
/// The RB4-repair lane consumes the richer typed API directly
/// (`reserveLaunchLease` + `commitLaunchLease` + `rollbackLaunchLease`) for
/// pre-DB rejection and exact rollback-before-commit; nothing here duplicates
/// any filesystem or ContentResolver work.
public final class AttachmentStagingLaunchAuthority: RunStagedAttachmentAuthority,
                                                     @unchecked Sendable {
    public let service: AttachmentStagingService

    /// Exact Run-port -> producer lease identity map. The ORIGINAL staging
    /// summary mints an opaque receipt STRING as its lease identity while the
    /// reviewed RB4 port carries a UUID per launch; the adapter must map the
    /// two so commit-acknowledge and rollback reach the SAME producer lease
    /// and per-run owner. Entries are transient: created by `reserve`, removed
    /// by `commitAcknowledged`/`releaseReservation`, and foreign-epoch entries
    /// are pruned on the next reservation.
    private typealias LeaseEntry = (producerLeaseID: String, runID: UUID,
                                    conversationID: UUID?, epoch: UInt64)
    private let leaseLock = NSLock()
    private var leaseByID: [UUID: LeaseEntry] = [:]
    /// Hard bound over LIVE reservations. A full table means the run domain
    /// leaked a reservation (never committed/released); refusing honestly is
    /// the only safe answer (an eviction would orphan a reserved handle).
    private static let maximumLiveLeases = 4_096

    public init(service: AttachmentStagingService) {
        self.service = service
    }

    /// Synchronous scoped-lock seam (NSLock is noasync in Swift 6; the
    /// async entry points below never call `lock()` directly).
    private func withLeaseTable<T>(_ body: (inout [UUID: LeaseEntry]) -> T) -> T {
        leaseLock.lock()
        defer { leaseLock.unlock() }
        return body(&leaseByID)
    }

    private func takeLease(_ leaseID: UUID) -> LeaseEntry? {
        withLeaseTable { $0.removeValue(forKey: leaseID) }
    }

    /// RUN-S4 real adapter: `reserve` maps to the producer's batch
    /// `reserveLaunchLease` (all-or-nothing) for the EXACT run owner and
    /// returns one RunAttachmentLease carrying the ORIGINAL AttachmentRef.
    public func reserve(handle: String, conversationID: UUID?, runID: UUID,
                        epoch: UInt64) async throws -> RunAttachmentLease {
        let currentEpoch = await service.epoch
        guard currentEpoch == epoch else { throw RunStagingError.generationFenced }
        let atCapacity = withLeaseTable { table -> Bool in
            table = table.filter { $0.value.epoch == epoch }
            return table.count >= Self.maximumLiveLeases
        }
        guard !atCapacity else { throw RunStagingError.unbound }
        let result = await service.reserveLaunchLease(
            handles: [handle],
            conversationID: conversationID,
            correlation: "launch:" + runID.uuidString)
        switch result {
        case .failure(let error):
            switch error.code {
            case .handleUnknown, .payloadInvalid, .wrongOwner: throw RunStagingError.handleUnknown
            case .stateConflict: throw RunStagingError.handleAlreadyReserved
            case .generationFenced, .notInstalled: throw RunStagingError.generationFenced
            default: throw RunStagingError.handleUnknown
            }
        case .success(let lease):
            let refs = await service.refs(forLease: lease)
            guard let ref = refs.first, refs.count == 1 else {
                // The producer reserved without a projectable ref: roll the
                // reservation back and answer the typed refusal (no leak).
                _ = await service.rollbackLaunchLease(lease.leaseID)
                throw RunStagingError.handleUnknown
            }
            let leaseID = UUID()
            withLeaseTable { $0[leaseID] = (lease.leaseID, runID, conversationID, epoch) }
            return RunAttachmentLease(leaseID: leaseID, handle: handle, runID: runID, ref: ref)
        }
    }

    /// The ORIGINAL atomic prepare committed this lease: acknowledge EXACTLY
    /// the producer lease that reserved the handle. Refusal here never deletes
    /// bytes (the producer's commit does not discard either); the mapping is
    /// dropped so a stale acknowledgement cannot touch a newer generation.
    public func commitAcknowledged(_ lease: RunAttachmentLease, conversationID: UUID,
                                   messageID: UUID, epoch: UInt64) async {
        guard let entry = takeLease(lease.leaseID) else { return }
        guard entry.epoch == epoch, entry.runID == lease.runID,
              entry.conversationID == nil || entry.conversationID == conversationID else {
            return
        }
        _ = await service.commitLaunchLease(entry.producerLeaseID)
        _ = messageID
    }

    /// Pre-commit failure: release the producer reservation. Staged BYTES stay
    /// on the compose surface (the user keeps the file).
    public func releaseReservation(_ lease: RunAttachmentLease, epoch: UInt64) async {
        guard let entry = takeLease(lease.leaseID) else { return }
        guard entry.epoch == epoch, entry.runID == lease.runID else { return }
        _ = await service.rollbackLaunchLease(entry.producerLeaseID)
    }

    public func resolve(handle: String, conversationID: UUID?, epoch: UInt64) async throws
        -> AttachmentRef {
        let currentEpoch = await service.epoch
        guard currentEpoch == epoch else { throw RunStagingError.generationFenced }
        guard let info = await service.routeInfo(handle: handle),
              info.state == .staged, !info.launchMarked else {
            throw RunStagingError.handleUnknown
        }
        // Cross-owner guard: a handle minted for an EXISTING conversation
        // may only launch into that conversation. New-composer handles
        // (nil route conversation) may resolve to any launch target the
        // host passes (the prepare transaction binds and owns them from
        // then on).
        if let routeConversation = info.conversationID,
           let conversationID, routeConversation != conversationID {
            throw RunStagingError.handleUnknown
        }
        // Storage class guard (Main addendum): Android staging is always
        // the portable applicationSupport case; a bookmark-bearing record
        // could not have been produced by this lane at all.
        guard let ref = await service.attachmentRef(handle: handle),
              ref.storage == .applicationSupport else {
            throw RunStagingError.handleUnknown
        }
        let refusal = await service.markLaunchReference(handle: handle,
                                                        correlation: "launch.resolve")
        if let refusal {
            switch refusal {
            case .generationFenced, .notInstalled: throw RunStagingError.generationFenced
            default: throw RunStagingError.handleUnknown
            }
        }
        return ref
    }
}

// MARK: - Payload vocabulary (closed; shared by the bridge handlers)

/// The closed payload grammar for the seven attachment commands. Unknown
/// keys, URI-shaped values, path-shaped values or oversized scalars are
/// typed refusals BEFORE any effect — this is the model-forgery surface, so
/// it accepts the MINIMUM each command needs and nothing else.
public enum AttachmentStagingPayload {
    public enum Stage: Sendable, Equatable {
        case publish(ingressReceipt: String)
    }
    public enum StagingRead: Sendable, Equatable {
        case snapshot(stagingID: String)
    }
    public enum StagingCancel: Sendable, Equatable {
        case ingress(stagingID: String)
    }
    public enum StagingDiscard: Sendable, Equatable {
        case handle(handle: String)
    }
    public enum Read: Sendable, Equatable {
        case committed(attachmentID: String)
    }

    public struct Decoding {
        public let object: [String: Any]
        init?(_ data: Data) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let object = parsed as? [String: Any] else { return nil }
            self.object = object
        }
        var payload: [String: Any]? { object["payload"] as? [String: Any] }
    }

    /// Exactly one key per command; rejects anything else (including the
    /// lure keys a forged envelope would carry).
    private static let lureKeys: Set<String> = [
        "uri", "contentUri", "path", "absolutePath", "fd", "fileDescriptor",
        "bookmark", "data", "base64", "root", "storageRoot", "token",
    ]

    static func onlyKeys(_ payload: [String: Any], _ allowed: Set<String>) -> Bool {
        let keys = Set(payload.keys)
        if !keys.isSubset(of: allowed) { return false }
        return keys.isDisjoint(with: lureKeys)
    }

    static func boundedString(_ payload: [String: Any], _ key: String,
                              validator: (String) -> Bool) -> String? {
        guard let value = payload[key] as? String, validator(value) else { return nil }
        return value
    }

    public static func decodeStage(_ payload: [String: Any]) -> Stage? {
        guard onlyKeys(payload, ["ingressReceipt"]),
              let receipt = boundedString(payload, "ingressReceipt",
                                          validator: {
                    AttachmentReceipt.isValid($0, prefix: AttachmentReceipt.ingressPrefix)
                }) else { return nil }
        return .publish(ingressReceipt: receipt)
    }

    public static func decodeStagingRead(_ payload: [String: Any]) -> StagingRead? {
        guard onlyKeys(payload, ["stagingID"]),
              let id = boundedString(payload, "stagingID",
                                     validator: { UUID(uuidString: $0) != nil })
        else { return nil }
        return .snapshot(stagingID: id)
    }

    public static func decodeStagingCancel(_ payload: [String: Any]) -> StagingCancel? {
        guard onlyKeys(payload, ["stagingID"]),
              let id = boundedString(payload, "stagingID",
                                     validator: { UUID(uuidString: $0) != nil })
        else { return nil }
        return .ingress(stagingID: id)
    }

    public static func decodeStagingDiscard(_ payload: [String: Any]) -> StagingDiscard? {
        guard onlyKeys(payload, ["stagingHandle"]),
              let handle = boundedString(payload, "stagingHandle",
                                         validator: {
                    AttachmentReceipt.isValid($0, prefix: AttachmentReceipt.stagingPrefix)
                }) else { return nil }
        return .handle(handle: handle)
    }

    /// Commit carries the conversation identity + row digest from the
    /// ENVELOPE (owner taskID + revision), not the payload — this payload
    /// check validates only the handle list; the bridge binds envelope
    /// fields. (The same rule as the frozen v3 revision grammar.)
    public static func decodeCommitHandles(_ payload: [String: Any]) -> [String]? {
        guard onlyKeys(payload, ["stagingHandles"]),
              let raw = payload["stagingHandles"] as? [String],
              !raw.isEmpty,
              raw.count <= AttachmentStagingLimits.maximumHandlesPerOperation,
              raw.allSatisfy({ AttachmentReceipt.isValid($0,
                                          prefix: AttachmentReceipt.stagingPrefix) })
        else { return nil }
        return raw
    }

    public static func decodeRead(_ payload: [String: Any]) -> Read? {
        guard onlyKeys(payload, ["attachmentID"]),
              let id = boundedString(payload, "attachmentID",
                                     validator: { UUID(uuidString: $0) != nil })
        else { return nil }
        return .committed(attachmentID: id)
    }

    public static func attachmentIDOnly(_ payload: [String: Any]) -> String? {
        guard onlyKeys(payload, ["attachmentID"]),
              let id = boundedString(payload, "attachmentID",
                                     validator: { UUID(uuidString: $0) != nil })
        else { return nil }
        return id
    }
}
