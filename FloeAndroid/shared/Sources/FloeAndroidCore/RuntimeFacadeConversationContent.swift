// SPDX-License-Identifier: MPL-2.0
//
// RB-3 content authority — bounded conversation content backend
// (private source candidate; NOT compiled, NOT executed, NOT registered).
//
// WHY THIS FILE EXISTS AS A SEPARATE SEAM (and why it is NOT another
// FacadeContentReader):
// * `FacadeContentReader.swift` is owned by RB-1. The MAIN-REVIEWED frozen
//   copy lives at runtime-bootstrap-main-reviewed-source/candidate (archive
//   sha256 e975c8a0089a4807d1ed9bcbd22325a52013ba84cf69bbce5f5f1e6da6ae5529,
//   file sha256 466f2231a190a68cd3c671f528104e4e5e1fabf60a87e82960d72f4a3763e1c7,
//   :23-229: NSLock-guarded opaque-handle blob store, `chunk:v1:`+32hex
//   handles, 32 live handles / 4 MiB aggregate / 49_152 max chunk,
//   scalar-safe read with backward scan, typed notFound on foreign
//   generations, `init(generation:)` and a per-generation instance inside
//   `AndroidRuntimeBootstrap.Generation.content`). THIS lane must not fork,
//   copy or parallel-cache that reader: the admission rule is
//   "Producer/reader API may delegate shared RB1 FacadeContentReader with
//   trusted owner binding; no new unbounded content cache/parallelreader."
// * The reviewed RB1 is frozen for its ACTUAL API but still NOT published
//   and NOT compiled (admission: publicationAdmittedNow false; Main
//   serialized publication pending). So the byte-holding responsibility
//   stays behind the `ConversationContentPublishing` port whose three
//   methods map 1:1 onto the ACTUAL reviewed signatures (documented below
//   per method — names come from the reviewed file, not from guesses), and
//   this file adds only what RB-1 deliberately does NOT own: the TRUSTED
//   OWNER BINDING INDEX (handle → real conversation/message/host
//   generation), the dual-scope content.read authority rules, and the
//   P0-budget page assembly.
//
// Exact target binding (Main serial integration, at the published RB1):
//   stage(bytes:)                  -> FacadeContentReader.stage(_ content: Data) (:95)
//                                      .staged -> staged(handle:)
//                                      .rejected(contentSaturated:) -> .saturated
//                                      .rejected(emptyContent:) -> .rejectedEmpty
//   read(handle:offset:maxBytes:)  -> FacadeContentReader.read(handle:offset:maxBytes:) (:117)
//                                      .slice(bytes:nextOffset:complete:) /
//                                      .notFound / .invalidOffset map 1:1
//   release(handle:)               -> FacadeContentReader.release(handle:) (:194)
// Generation retirement additionally calls `retireAll()` (:203) through the
// bootstrap owner; the per-generation instance (init(generation:) :86) is
// what makes the binding epoch's honest handle-expiry work.
//
// Wire budget authority: `SettingsDomainV1.ContentBudget` +
// `SettingsDomainV1.ContentChunk` from the accepted P0 final source
// (settings-domain-p0-final-alignment). All size decisions measure the
// COMPLETE ENCODED response (actual UTF-8 bytes plus JSON escaping through
// the same JSONSerialization rules the wire uses), never a raw character
// count and never a duplicated encoder. The named P0 qualifier (a8) may
// repair the chunk-budget body (P0-BUDGET-1/2); integration must consume
// the qualified helpers AS PUBLISHED — this file keeps referencing them by
// name and must never be "re-pinned" to an older hash (dependencyHash
// evolution per settings-defaults-usage-source acceptance).

import Foundation
import GRDB
import FloePersistence

// MARK: - Publishing port (RB-1 FacadeContentReader binding target)

public enum ConversationContentStageResult: Sendable, Equatable {
    case staged(handle: String)
    /// The shared reader is at its live-handle or aggregate-byte bound.
    /// There is NO silent eviction and NO fallback cache: the page fails
    /// closed with a typed error so nothing is ever truncated with a
    /// completeness label.
    case saturated
    case rejectedEmpty
}

public enum ConversationContentSliceOutcome: Sendable, Equatable {
    case slice(bytes: Data, nextOffset: Int, complete: Bool)
    case notFound
    case invalidOffset
}

/// Narrow typed port for the SHARED bounded reader. Implementations hold
/// bytes; this lane's authority index holds metadata only.
public protocol ConversationContentPublishing: Sendable {
    func stage(_ bytes: Data) async -> ConversationContentStageResult
    func read(handle: String, offset: Int, maxBytes: Int) async -> ConversationContentSliceOutcome
    func release(handle: String) async
}

// MARK: - Owner binding

/// A staged oversize item is bound to the REAL row that produced it and to
/// the CURRENT host generation. Every content.read must re-derive authority
/// from the durable row; a handle is never a file path and never names
/// arbitrary host storage.
public struct ConversationContentBinding: Sendable, Equatable {
    public let handle: String
    public let conversationID: UUID
    public let messageID: UUID
    public let hostEpoch: UInt64
    public let totalBytes: Int
    /// Canonical digest of the staged UTF-8 bytes (actual value computed at
    /// staging by the accepted P0 encoder). A local domain literal — the
    /// digest encoder is domain-parameterized precisely for lane-owned
    /// domains; no P0 source was edited.
    public let contentDigest: String
    /// NON-nil ONLY for a LIVE temporary session row: the exact session
    /// incarnation that owns the RAM message. Every read re-proves that
    /// incarnation (and message existence in the session's own store)
    /// before bytes are returned. Ordinary bindings keep nil.
    public let temporaryIncarnation: UUID?

    /// Domain literal for the content-handle digest.
    public static let digestDomain = "floe.conversation-content-handle.v1"

    init(handle: String, conversationID: UUID, messageID: UUID,
         hostEpoch: UInt64, totalBytes: Int, contentDigest: String,
         temporaryIncarnation: UUID? = nil) {
        self.handle = handle
        self.conversationID = conversationID
        self.messageID = messageID
        self.hostEpoch = hostEpoch
        self.totalBytes = totalBytes
        self.contentDigest = contentDigest
        self.temporaryIncarnation = temporaryIncarnation
    }

    static func digest(of text: String) -> String {
        SettingsDomainV1.CanonicalDigest.rowToken(domain: digestDomain,
                                                  fields: [.text(text)])
    }
}

// MARK: - content.read request / reply

public struct ConversationContentReadRequest: Sendable, Equatable {
    public let handle: String
    public let offset: Int
    public let maxBytes: Int

    /// The frozen P0 chunk clamp (SettingsDomainV1.maximumChunkBytes =
    /// 32_768) is enforced here. It is SMALLER than the RB1 draft reader
    /// bound (49_152), so a request accepted here can never be rejected by
    /// the bound reader for size. The hard wire bound stays the frozen
    /// `BridgeV3.maximumBytes` (65_536) at the binder; the NORMAL page
    /// budget is `SettingsDomainV1.pageBudgetBytes` (48 KiB) and the slice
    /// reply is measured with the P0 helper that includes JSON escaping.
    public static let maximumOffsetSpan = 4_194_304 // RB1 aggregate bound sanity

    public init(handle: String, offset: Int, maxBytes: Int) {
        self.handle = handle
        self.offset = offset
        self.maxBytes = maxBytes
    }

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> ConversationContentReadRequest
    {
        guard let payload else {
            throw ConversationDomainError.invalidEnvelope("missingPayload")
        }
        guard case .object(let root) = payload else {
            throw ConversationDomainError.invalidEnvelope("invalidPayload")
        }
        for key in root.keys where ["handle", "offset", "maxBytes"].contains(key) == false {
            throw ConversationDomainError.invalidEnvelope("unknownContentReadField")
        }
        guard let handleValue = root["handle"] else {
            throw ConversationDomainError.invalidEnvelope("missingPayloadField:handle")
        }
        guard case .string(let handle) = handleValue,
              !handle.isEmpty, handle.count <= 64,
              // Qualifier repair (2026-10-19): `Unicode.Scalar.isNewline`
              // is stdlib-internal; spell the scalar newline set explicitly
              // (LF/VT/FF/CR are already excluded by the `>= 0x20` bound, so
              // the remaining newline scalars are NEL U+0085, U+2028, U+2029).
              handle.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20
                      && scalar.value != 0x85
                      && scalar.value != 0x2028
                      && scalar.value != 0x2029
              }) else {
            throw ConversationDomainError.invalidEnvelope("invalidPayloadField:handle")
        }
        guard let offsetValue = root["offset"] else {
            throw ConversationDomainError.invalidEnvelope("missingPayloadField:offset")
        }
        guard case .integer(let rawOffset) = offsetValue,
              rawOffset >= 0, rawOffset < Int64(maximumOffsetSpan) else {
            throw ConversationDomainError.invalidEnvelope("contentOffsetInvalid")
        }
        let offset = Int(rawOffset)
        guard let maxBytesValue = root["maxBytes"] else {
            throw ConversationDomainError.invalidEnvelope("missingPayloadField:maxBytes")
        }
        guard case .integer(let rawMax) = maxBytesValue,
              rawMax >= 1, rawMax <= Int64(SettingsDomainV1.maximumChunkBytes) else {
            throw ConversationDomainError.invalidEnvelope("invalidPayloadField:maxBytes")
        }
        let maxBytes = Int(rawMax)
        return ConversationContentReadRequest(handle: handle,
                                              offset: offset,
                                              maxBytes: maxBytes)
    }
}

/// The slice reply REUSES the accepted P0 chunk DTO verbatim
/// (`SettingsDomainV1.ContentChunk`: chunk text, nextOffset, totalBytes,
/// done) so the chunk-budget/JSON-escaping measurement runs through the
/// SAME qualified P0 helper as every other chunked response. The handle is
/// the binding's opaque `chunk:v1:` token; the remaining fields are additive
/// and real (never invented): the bound row identity and the staged-bytes
/// digest computed at publish time.
public struct ConversationContentSliceReply: Sendable, Equatable {
    public let handle: String
    public let chunk: SettingsDomainV1.ContentChunk
    public let conversationID: UUID
    public let messageID: UUID
    public let contentDigest: String

    public init(handle: String, chunk: SettingsDomainV1.ContentChunk,
                conversationID: UUID, messageID: UUID, contentDigest: String) {
        self.handle = handle
        self.chunk = chunk
        self.conversationID = conversationID
        self.messageID = messageID
        self.contentDigest = contentDigest
    }

    public var wireObject: [String: Any] {
        var object: [String: Any] = [
            "handle": handle,
            "chunk": chunk.chunk,
            "totalBytes": chunk.totalBytes,
            "done": chunk.done,
            "conversationID": conversationID.uuidString,
            "messageID": messageID.uuidString,
            "contentDigest": contentDigest,
        ]
        object["nextOffset"] = chunk.nextOffset ?? NSNull()
        return object
    }
}

// MARK: - The content authority

/// Metadata-only index over the SHARED bounded reader. It NEVER stores
/// content bytes itself; it answers "which real row and which host
/// generation produced this handle, and is that row still readable here?".
public actor FacadeConversationContentAuthority {

    /// Mirrors the RB1 reader's own live-handle bound so the index cannot
    /// outlive the bytes it names. (Not a new arbitrary cap.)
    public static let maximumBindings = 32

    private let publisher: any ConversationContentPublishing
    private let conversationStore: SQLiteConversationStore
    private let database: DatabaseManager
    private let context: ConversationFacadeContext

    private struct Entry {
        let binding: ConversationContentBinding
    }
    private var bindings: [String: Entry] = [:]
    private var order: [String] = []

    public init(publisher: any ConversationContentPublishing,
                database: DatabaseManager,
                conversationStore: SQLiteConversationStore,
                context: ConversationFacadeContext) {
        self.publisher = publisher
        self.database = database
        self.conversationStore = conversationStore
        self.context = context
    }

    // MARK: Stage (producer side)

    /// Publishes one oversize durable row. `text` MUST be the content of
    /// the ORIGINAL store row the caller just read in the same request (the
    /// messagePage/snapshot projection), so the handle always names the
    /// stored bytes, never a rendered variant. Returns nil ONLY for the
    /// honest saturated/empty/row-vanished outcomes; the page assembly
    /// turns nil into a typed refusal — a failed publish NEVER degrades to
    /// an inline truncation.
    public func publish(conversationID: UUID, messageID: UUID, text: String) async
        -> (handle: String, totalBytes: Int)?
    {
        guard let record = try? await conversationStore.conversation(id: conversationID),
              record.purpose == .ordinary else { return nil }
        let bytes = Data(text.utf8)
        guard !bytes.isEmpty else {
            // An empty message content needs no handle at all: it is inline
            // ("") by definition. The caller must not have asked.
            return nil
        }
        guard await messageBelongsToConversation(messageID: messageID,
                                                  conversationID: conversationID) else {
            return nil
        }
        guard bindings.count < Self.maximumBindings else { return nil }
        switch await publisher.stage(bytes) {
        case .staged(let handle):
            let binding = ConversationContentBinding(
                handle: handle,
                conversationID: conversationID,
                messageID: messageID,
                hostEpoch: context.hostEpoch,
                totalBytes: bytes.count,
                contentDigest: ConversationContentBinding.digest(of: text))
            bindings[handle] = Entry(binding: binding)
            order.append(handle)
            while bindings.count > Self.maximumBindings, let oldest = order.first {
                order.removeFirst()
                bindings.removeValue(forKey: oldest)
                await publisher.release(handle: oldest)
            }
            return (handle, bytes.count)
        case .saturated, .rejectedEmpty:
            return nil
        }
    }

    /// Publishes one oversize row of the LIVE temporary session. The bytes
    /// stay in the SAME generation-owned bounded reader; the binding carries
    /// the session incarnation and is re-authorized against the session's
    /// OWN RAM store on every read. No durable row, no second cache and no
    /// truncation: a saturated/absent message is a typed nil the page
    /// assembly turns into a refusal.
    public func publishTemporary(conversationID: UUID, messageID: UUID,
                                 incarnation: UUID, text: String) async
        -> (handle: String, totalBytes: Int)?
    {
        guard let route = await TemporaryLiveRouting.route(
            epoch: context.hostEpoch, conversationID: conversationID),
              route.incarnation == incarnation else { return nil }
        let bytes = Data(text.utf8)
        guard !bytes.isEmpty else { return nil }
        guard let messages = try? await route.stores.conversations.messages(
            conversationID: conversationID),
              messages.contains(where: { $0.id == messageID }) else { return nil }
        guard bindings.count < Self.maximumBindings else { return nil }
        switch await publisher.stage(bytes) {
        case .staged(let handle):
            let binding = ConversationContentBinding(
                handle: handle,
                conversationID: conversationID,
                messageID: messageID,
                hostEpoch: context.hostEpoch,
                totalBytes: bytes.count,
                contentDigest: ConversationContentBinding.digest(of: text),
                temporaryIncarnation: incarnation)
            bindings[handle] = Entry(binding: binding)
            order.append(handle)
            while bindings.count > Self.maximumBindings, let oldest = order.first {
                order.removeFirst()
                bindings.removeValue(forKey: oldest)
                await publisher.release(handle: oldest)
            }
            return (handle, bytes.count)
        case .saturated, .rejectedEmpty:
            return nil
        }
    }

    /// `conversationLifecycle content.read` for the LIVE temporary session.
    /// The handle must be bound to THIS conversation AND this exact live
    /// incarnation, and the message must still exist in the session's RAM
    /// conversation. A discarded/promoted session or a different incarnation
    /// is the SAME typed notFound as an unknown handle.
    public func readTemporary(conversationID: UUID,
                              incarnation: UUID,
                              request: ConversationContentReadRequest) async throws
        -> ConversationContentSliceReply
    {
        guard let binding = bindings[request.handle],
              binding.binding.conversationID == conversationID,
              binding.binding.temporaryIncarnation == incarnation,
              binding.binding.hostEpoch == context.hostEpoch else {
            throw ConversationDomainError.notFound
        }
        try await requireLiveTemporaryBinding(binding.binding)
        return try await performRead(binding: binding.binding, request: request)
    }

    private func requireLiveTemporaryBinding(_ binding: ConversationContentBinding) async throws {
        guard let incarnation = binding.temporaryIncarnation,
              let route = await TemporaryLiveRouting.route(
                epoch: context.hostEpoch,
                conversationID: binding.conversationID),
              route.incarnation == incarnation,
              let messages = try? await route.stores.conversations.messages(
                conversationID: binding.conversationID),
              messages.contains(where: { $0.id == binding.messageID }) else {
            throw ConversationDomainError.notFound
        }
    }

    /// Bounded one-row existence probe on the ORIGINAL messages table
    /// (exact `(id, conversation_id)` pairing; mirrors the pairing the
    /// store's own messagePage guarantees).
    private func messageBelongsToConversation(messageID: UUID, conversationID: UUID) async -> Bool {
        let database = self.database
        let id = messageID.uuidString
        let conversation = conversationID.uuidString
        return (try? await database.reader { db in
            try Int.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM messages WHERE id = ? AND conversation_id = ?
                )
                """, arguments: [id, conversation]) ?? 0
        }) == 1
    }

    // MARK: Read — conversationLifecycle authority

    /// Owner-bound read. The request's conversation is the OWNER: a handle
    /// bound to a different conversation is refused with the SAME typed
    /// notFound as an unknown handle (foreign vs unknown stays
    /// indistinguishable — no probing oracle). The bound row must still
    /// exist, still be ordinary, and still belong to this conversation;
    /// the generation must be the current one.
    public func read(conversationID: UUID, request: ConversationContentReadRequest) async throws
        -> ConversationContentSliceReply
    {
        guard let binding = bindings[request.handle],
              binding.binding.conversationID == conversationID,
              binding.binding.temporaryIncarnation == nil,
              binding.binding.hostEpoch == context.hostEpoch else {
            throw ConversationDomainError.notFound
        }
        try await requireLiveBoundRow(binding: binding.binding)
        return try await performRead(binding: binding.binding, request: request)
    }

    // MARK: Read — applicationConfiguration/conversations authority

    /// The configuration scope has no owner field, so authority is derived
    /// ENTIRELY from the durable row the handle was bound to: the bound
    /// conversation must still exist as an ordinary row and the bound
    /// message must still belong to it. Expired generations and unknown
    /// handles are typed notFound; this never opens a caller-named path.
    public func readWithinOrdinaryConversation(request: ConversationContentReadRequest) async throws
        -> ConversationContentSliceReply
    {
        guard let binding = bindings[request.handle],
              binding.binding.temporaryIncarnation == nil,
              binding.binding.hostEpoch == context.hostEpoch else {
            throw ConversationDomainError.notFound
        }
        try await requireLiveBoundRow(binding: binding.binding)
        return try await performRead(binding: binding.binding, request: request)
    }

    /// Authority is the DURABLE ROW, re-checked on every read: the bound
    /// conversation must still exist as an ordinary row and the bound
    /// message must still belong to it (bounded EXISTS probe). Deleted or
    /// re-parented content is typed notFound — an expired/foreign handle
    /// can never read surviving bytes of another row.
    private func requireLiveBoundRow(binding: ConversationContentBinding) async throws {
        guard let record = try? await conversationStore.conversation(id: binding.conversationID),
              record.purpose == .ordinary else {
            throw ConversationDomainError.notFound
        }
        guard await messageBelongsToConversation(messageID: binding.messageID,
                                                  conversationID: binding.conversationID) else {
            throw ConversationDomainError.notFound
        }
    }

    private func performRead(binding: ConversationContentBinding,
                             request: ConversationContentReadRequest) async throws
        -> ConversationContentSliceReply
    {
        switch await publisher.read(handle: request.handle,
                                    offset: request.offset,
                                    maxBytes: request.maxBytes) {
        case .notFound:
            throw ConversationDomainError.notFound
        case .invalidOffset:
            throw ConversationDomainError.invalidEnvelope("contentOffsetInvalid")
        case .slice(let bytes, let nextOffset, let complete):
            // UTF-8 validity is the shared reader's scalar-boundary
            // guarantee; a hard decode failure fails closed and is never
            // laundered into a replacement character.
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw ConversationDomainError.persistenceUnavailable("contentSliceDecode")
            }
            let chunk = SettingsDomainV1.ContentChunk(
                chunk: text,
                nextOffset: complete ? nil : nextOffset,
                totalBytes: binding.totalBytes,
                done: complete)
            guard ConversationContentBudget.encodedSliceFits(chunk) else {
                // Defensive: the P0 chunk bound (32 KiB) plus metadata must
                // keep the reply inside the 48 KiB normal page. If the
                // qualified P0 helper ever disagrees, fail closed rather
                // than emit an oversized frame.
                throw ConversationDomainError.payloadTooLarge(maxBytes: SettingsDomainV1.pageBudgetBytes)
            }
            return ConversationContentSliceReply(handle: request.handle,
                                                 chunk: chunk,
                                                 conversationID: binding.conversationID,
                                                 messageID: binding.messageID,
                                                 contentDigest: binding.contentDigest)
        }
    }

    // MARK: Release

    public func release(handle: String) async {
        guard let entry = bindings.removeValue(forKey: handle) else { return }
        order.removeAll { $0 == handle }
        await publisher.release(handle: entry.binding.handle)
    }

    /// Releases every handle bound to ONE conversation. Called by the
    /// delete path AFTER the durable commit; bindings for other
    /// conversations are never touched, so a late delete echo cannot clear
    /// another conversation's staged content (the owner-id equality is the
    /// guard).
    public func release(forConversationID conversationID: UUID) async -> Int {
        let handles = bindings.values
            .map(\.binding)
            .filter { $0.conversationID == conversationID }
            .map(\.handle)
        for handle in handles {
            await release(handle: handle)
        }
        return handles.count
    }

    public func bindingCount() -> Int { bindings.count }
}

// MARK: - Budget helpers (delegation, never duplication)

/// All encoded-size questions route to the accepted P0 helpers. This enum
/// contains NO re-implementation of JSON escaping or chunk math: the only
/// local logic is the whole-object measurement using the same
/// JSONSerialization rules P0's own `encodedChunkResponseBytes` uses
/// (SettingsDomainV1.swift:1013-1023).
public enum ConversationContentBudget {
    /// Complete encoded P0 chunk response fits the normal page budget.
    public static func encodedSliceFits(_ chunk: SettingsDomainV1.ContentChunk) -> Bool {
        SettingsDomainV1.ContentBudget.fitsPageBudget(chunk)
    }

    /// The inline-vs-handle decision for one wire row: build the row's
    /// object with the content field set to `""`, measure it, and use the
    /// P0 exact complete-response formula
    /// (`metadataEncodedBytesWithEmptyContent - 2 + encodedJSONStringBytes(content)`).
    /// No arbitrary constant, no second cap, no 16 KiB inline rule.
    public static func shouldInline(content: String,
                                    rowObjectWithEmptyContent: [String: Any]) -> Bool {
        let metadataBytes = ConversationWireBudget.encodedObjectBytes(rowObjectWithEmptyContent)
        return SettingsDomainV1.ContentBudget.shouldInline(
            content: content,
            metadataEncodedBytesWithEmptyContent: metadataBytes)
    }
}

public enum ConversationWireBudget {
    /// Exact encoded bytes of a complete JSON object using the same sorted-
    /// key JSONSerialization rules as the P0 response measurers.
    public static func encodedObjectBytes(_ object: [String: Any]) -> Int {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]) else {
            // Fail closed: an unmeasurable object is treated as far too
            // large rather than "probably fine".
            return Int.max
        }
        return data.count
    }

    /// Delegates to the accepted P0 helper (actual UTF-8 length including
    /// surrounding quotes and JSON escaping).
    public static func encodedJSONStringBytes(_ value: String) -> Int {
        SettingsDomainV1.ContentBudget.encodedJSONStringBytes(value)
    }

    /// The complete encoded page must fit the NORMAL 48 KiB page budget;
    /// the 64 KiB hard bound belongs to the frozen binder envelope
    /// (`BridgeV3.maximumBytes`) and is re-checked there.
    public static let pageBudgetBytes = SettingsDomainV1.pageBudgetBytes
}

// MARK: - Page row builder

/// Turns the ORIGINAL store rows into the wire reply: roles pass through
/// exactly as stored; each oversized content field is decided by the P0
/// `shouldInline` helper against the row's real encoded shape; `staged`
/// maps messageID → the shared reader's binding for rows that do not fit.
/// A row WITHOUT a `staged` entry is ALWAYS the complete inline content —
/// a partially inline row cannot be constructed here by design. The
/// cursor/canary start from the store page and are recomputed by the
/// caller's trim loop (atomic row/cursor progress).
enum ConversationMessageReplyBuilder {
    /// `earliestKeptCursorOverride` / `forceHasEarlier` let the trim loop
    /// publish an honest continued cursor without mutating the store page.
    static func build(messages: [PersistedMessage],
                      staged: [UUID: (handle: String, totalBytes: Int)],
                      originalPage: ConversationMessagePage,
                      reencodedEarlierCursor: String?,
                      forceHasEarlier: Bool) -> ConversationMessagePageReply {
        let rows = messages.map { message -> ConversationMessageRowWire in
            let entry = staged[message.id]
            return ConversationMessageRowWire(
                messageID: message.id,
                role: message.role,
                createdAtRaw: ConversationWireDate.encode(message.createdAt),
                runID: message.runID,
                content: entry == nil ? message.content : nil,
                contentHandle: entry?.handle,
                totalBytes: entry?.totalBytes ?? message.content.utf8.count,
                contentInlineComplete: entry == nil,
                partCount: message.parts.count
            )
        }
        return ConversationMessagePageReply(
            rows: rows,
            earlierCursor: reencodedEarlierCursor
                ?? originalPage.earlierCursor.flatMap {
                    try? FacadeConversationDomain.encodeMessageCursor($0)
                },
            hasEarlier: forceHasEarlier || originalPage.hasEarlier,
            usesContentHandles: rows.contains { $0.contentHandle != nil }
        )
    }

    /// The row's own encoded shape with the content field set to the
    /// empty string — the exact input shape the P0 helper
    /// `encodedInlineResponseBytes(metadataEncodedBytesWithEmptyContent:content:)`
    /// is defined for (no arbitrary constant, no 16 KiB rule).
    static func rowObjectWithEmptyContent(message: PersistedMessage) -> [String: Any] {
        var object: [String: Any] = [
            "id": message.id.uuidString,
            "role": message.role,
            "createdAt": ConversationWireDate.encode(message.createdAt),
            "totalBytes": message.content.utf8.count,
            "partCount": message.parts.count,
            "content": "",
            "contentHandle": NSNull(),
            "contentInlineComplete": true,
        ]
        object["runID"] = message.runID?.uuidString as Any
        return object
    }

    /// True exactly when the FULL inline content of this single row would
    /// not fit one 48 KiB normal page by itself (P0 complete-response
    /// measurement). Only such rows cost an owned handle.
    static func requiresHandle(message: PersistedMessage) -> Bool {
        !ConversationContentBudget.shouldInline(
            content: message.content,
            rowObjectWithEmptyContent: rowObjectWithEmptyContent(message: message))
    }
}


