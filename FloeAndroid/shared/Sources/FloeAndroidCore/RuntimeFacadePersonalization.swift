// SPDX-License-Identifier: MPL-2.0
//
// P3 — G02 personalization core adapter (private source candidate;
// UNCOMPILED). Job job-676ec714cb334606 (RB3b intelligence backend lane).
//
// Authority: settings-domain-main-acceptance-20261019/input-final/contract.json
// (sha256 f3ddecdca061ae17fbe4280b7bfb549d8a1673fd8d9ae6e1ba363332ef5db46c),
// commandTable entries label=personalization (personalization.get/
// revision.read/save/rollback/automatic.set), wireConventions
// .revisionTokenGrammar.activeSlotTokens + digestDomains,
// frameBudgets.contentInlineRule (Q10), adapters.components
// [FacadePersonalizationAdapter], behavioralTestDesign P3 vectors,
// IMPLEMENTATION_HANDOFF.md P3 checks.
//
// Original-source pins (byte-identical, NOT edited):
// * FloeAgent/Sources/FloeAgentRuntime/Personalization.swift:14-24 closed
//   kind/source enums, :26-58 document struct (trim+24k clamp is the
//   STORE-side clamp; user edits are rejected typed BEFORE mutation per
//   Main Q4 — documented deviation), :60-110 cursor + cadence, :304-316
//   active read via the partial unique active index, :350-379 saveDocument
//   (MAX+1 over ALL rows incl. drafts; deactivate-then-insert; trim +
//   non-empty guard), :381-394 cursor read (synthesized defaults, never
//   persisted), :396-415 saveCursor UPSERT, :470-494 row decodes, :543-549
//   workspaceKey/second-precision date, :663-686 saveManual/rollback
//   behavior (rollback = append active copy carrying the target's
//   evidenceDigest; non-destructive).
// * V13PersonalizationMemory.swift:52-74 personalization_documents schema +
//   the partial UNIQUE indexes relied upon (one active per
//   (kind, workspace); (kind[,workspace],revision) uniqueness), :76-92
//   cursor PK (kind, workspace_key) + CHECK.
// * FloeAgent/FloeApp/Memory/MemoryView.swift:891 — native "confirm and
//   enable" uses the rollback path for automatic drafts; this adapter keeps
//   rollback-to-a-draft-revision the ONLY activation path. Draft rows are
//   never touched or silently activated by any other path.
//
// Why an adapter: saveDocument/rollback have NO expected-revision CAS
// (last-writer-wins; the draft/active distinction never contends) and
// documentRevisions returns an UNBOUNDED full-content array. The contract
// adds the ACTIVE-SLOT CAS (the real is_active=1 row id+revision — NEVER
// MAX(revision), Main review issue 1), the complete-row cursor digest
// floe.personalization-cursor.v1 (never the second-precision updated_at),
// bounded metadata projections, and the Q10 inline-vs-owned-handle rule
// measured on the COMPLETE encoded response (no extra 16KiB cap). No
// shared-source edit.
//
// No handler registration, no capability claim. Bind through RB-1 after
// P0 lands; content handles bind to the RB1 bounded reader
// (FacadeContentReader) through the typed port below. Swift 6 strict
// concurrency; no MainActor assumption; no semaphore/runBlocking.

import Foundation
import GRDB
import Crypto
import FloeCore
import FloePersistence
import FloeAgentRuntime

// MARK: - Typed content-port (RB-1 bounded reader binding target)

/// Stage outcome of the shared bounded reader.
public enum PersonalizationContentStage: Sendable, Equatable {
    case staged(handle: String)
    /// Live-handle/aggregate-byte bound reached. There is NO silent eviction
    /// and NO fallback cache; the producer fails closed typed so nothing is
    /// ever truncated with a completeness label.
    case contentSaturated
    case emptyContent
}

/// Bounded scalar-aligned read from the shared reader.
public enum PersonalizationContentSlice: Sendable, Equatable {
    case slice(bytes: Data, nextOffset: Int, complete: Bool)
    case notFound
    case invalidOffset
}

/// Narrow typed port over the REAL RB1 `FacadeContentReader`
/// (runtime-bootstrap lane; stage/read/release/retireAll, handlePrefix
/// "chunk:v1:", maximumLiveHandles 32, maximumTotalBytes 4_194_304,
/// init(generation:)). The binder wires this port as a thin actor wrapper
/// around the per-generation reader instance; HANDOFF §dependency
/// documents the exact construction. Personalization owns NO byte storage of
/// its own — only the handle→real-row binding index below.
public protocol PersonalizationContentStoring: Sendable {
    func stage(_ bytes: Data) async -> PersonalizationContentStage
    func read(handle: String, offset: Int, maxBytes: Int) async -> PersonalizationContentSlice
    func release(handle: String) async
}

// MARK: - Errors

/// Typed failures of the personalization adapter. Wire codes reuse the
/// accepted vocabulary only; per-command reasons match the final contract.
public enum PersonalizationAdapterError: Error, Sendable, Equatable {
    case invalidEnvelope(String)
    case notFound(String)
    case staleRevision
    case payloadTooLarge(maxChars: Int)
    case persistenceUnavailable(String?)

    public var wireCode: String {
        switch self {
        case .invalidEnvelope: return "invalidEnvelope"
        case .notFound: return "notFound"
        case .staleRevision: return "staleRevision"
        case .payloadTooLarge: return "payloadTooLarge"
        case .persistenceUnavailable: return "persistenceUnavailable"
        }
    }

    public var wireReason: String? {
        switch self {
        case .invalidEnvelope(let reason), .notFound(let reason):
            return reason
        case .staleRevision:
            return nil
        case .payloadTooLarge(let maxChars):
            return "maxChars:\(maxChars)"
        case .persistenceUnavailable(let reason):
            return reason
        }
    }
}

// MARK: - Resource identity grammar

/// The frozen envelope resourceID grammar for the personalization resources
/// (commandTable entries 15/17/19 revision blocks). The binder validates the
/// resourceID and passes only `version` to the adapter; these helpers exist
/// so the binder/tests compose the SAME strings from real inputs — no
/// adapter-side invention.
public enum PersonalizationResourceIDs {
    public static func document(kind: SettingsDomainV1.PersonalizationKind,
                                workspaceID: UUID?) -> String {
        if let workspaceID {
            return "personalization.\(kind.rawValue).workspace.\(workspaceID.uuidString)"
        }
        return "personalization.\(kind.rawValue)"
    }

    public static func cursor(kind: SettingsDomainV1.PersonalizationKind,
                              workspaceID: UUID?) -> String {
        if let workspaceID {
            return "personalization.cursor.\(kind.rawValue).workspace.\(workspaceID.uuidString)"
        }
        return "personalization.cursor.\(kind.rawValue)"
    }

    /// ACTIVE-SLOT token grammar: '<activeDocumentID uuid>.<activeRevision
    /// int>' or the literal 'absent' — never MAX(revision), never the raw
    /// second-precision timestamp.
    public static func activeSlotToken(documentID: UUID, revision: Int) -> String {
        "\(documentID.uuidString).\(revision)"
    }

    public static let absentToken = "absent"
}

// MARK: - Cursor schema codec

internal struct FacadeCursorRawRow: Sendable {
    let fields: [SettingsDomainV1.CanonicalDigest.Field]
    let kindRaw: String
    let workspaceKey: String
    let workspaceID: String?
    let automaticUpdatesEnabled: Bool
    let lastGeneratedAt: String?
    let completedRunsSinceUpdate: Int64
    let userMessagesSinceUpdate: Int64
    let updatedAt: String?

    /// The 8 cursor columns in the order the contract's
    /// floe.personalization-cursor.v1 domain enumerates (matching the V13
    /// CREATE TABLE column order, V13PersonalizationMemory.swift:76-92).
    static let columns: [String] = [
        "kind", "workspace_key", "workspace_id", "automatic_updates_enabled",
        "last_generated_at", "completed_runs_since_update",
        "user_messages_since_update", "updated_at",
    ]

    init(_ row: Row) {
        self.fields = Self.columns.map { FacadeDigestCodec.field(row, $0) }
        self.kindRaw = row["kind"]
        self.workspaceKey = row["workspace_key"]
        self.workspaceID = row["workspace_id"]
        let enabledValue: DatabaseValue = row["automatic_updates_enabled"]
        if case .int64(let raw) = enabledValue.storage { self.automaticUpdatesEnabled = raw != 0 }
        else { self.automaticUpdatesEnabled = false }
        self.lastGeneratedAt = row["last_generated_at"]
        let runsValue: DatabaseValue = row["completed_runs_since_update"]
        if case .int64(let raw) = runsValue.storage { self.completedRunsSinceUpdate = raw }
        else { self.completedRunsSinceUpdate = 0 }
        let messagesValue: DatabaseValue = row["user_messages_since_update"]
        if case .int64(let raw) = messagesValue.storage { self.userMessagesSinceUpdate = raw }
        else { self.userMessagesSinceUpdate = 0 }
        self.updatedAt = row["updated_at"]
    }

    /// Complete-row digest token, or the literal 'absent' when no row exists
    /// (the caller constructs 'absent' directly — this function is only for
    /// a REAL stored row; never the second-precision updated_at string).
    var digest: String {
        SettingsDomainV1.CanonicalDigest.rowToken(
            domain: SettingsDomainV1.CanonicalDigest.domainPersonalizationCursor,
            fields: fields)
    }

    func cursorDTO(revisionToken: String) throws -> SettingsDomainV1.PersonalizationCursor {
        guard let wireKind = SettingsDomainV1.PersonalizationKind(rawValue: kindRaw) else {
            throw PersonalizationAdapterError.persistenceUnavailable("corruptCursorRow")
        }
        _ = wireKind
        return SettingsDomainV1.PersonalizationCursor(
            automaticUpdatesEnabled: automaticUpdatesEnabled,
            lastGeneratedAt: lastGeneratedAt,
            completedRunsSinceUpdate: Int(completedRunsSinceUpdate),
            userMessagesSinceUpdate: Int(userMessagesSinceUpdate),
            updatedAt: updatedAt ?? "",
            revision: revisionToken)
    }
}

// MARK: - Document row codec

internal struct FacadeDocumentRawRow: Sendable {
    let id: String
    let kindRaw: String
    let workspaceID: String?
    let revision: Int64
    let content: String
    let sourceKindRaw: String
    let evidenceDigest: String
    let isActive: Bool
    let createdAt: String?

    init(_ row: Row) {
        self.id = row["id"]
        self.kindRaw = row["kind"]
        self.workspaceID = row["workspace_id"]
        let revisionValue: DatabaseValue = row["revision"]
        if case .int64(let raw) = revisionValue.storage { self.revision = raw }
        else { self.revision = 0 }
        self.content = row["content"]
        self.sourceKindRaw = row["source_kind"]
        self.evidenceDigest = row["evidence_digest"]
        let activeValue: DatabaseValue = row["is_active"]
        if case .int64(let raw) = activeValue.storage { self.isActive = raw != 0 }
        else { self.isActive = false }
        self.createdAt = row["created_at"]
    }

    /// sha256 over the UTF-8 content (contract contentDigest rule).
    var contentDigest: String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    var contentBytes: Int { Data(content.utf8).count }

    func kind() throws -> SettingsDomainV1.PersonalizationKind {
        guard let kind = SettingsDomainV1.PersonalizationKind(rawValue: kindRaw) else {
            throw PersonalizationAdapterError.persistenceUnavailable("corruptDocumentRow")
        }
        return kind
    }

    func source() throws -> SettingsDomainV1.PersonalizationSource {
        guard let source = SettingsDomainV1.PersonalizationSource(rawValue: sourceKindRaw) else {
            throw PersonalizationAdapterError.persistenceUnavailable("corruptDocumentRow")
        }
        return source
    }

    func revisionMeta() throws -> SettingsDomainV1.PersonalizationRevisionMeta {
        // A corrupt id/source fails typed — never a substituted nil UUID and
        // never a defaulted source.
        guard let uuid = UUID(uuidString: id) else {
            throw PersonalizationAdapterError.persistenceUnavailable("corruptDocumentRow")
        }
        return SettingsDomainV1.PersonalizationRevisionMeta(
            id: uuid,
            revision: Int(revision),
            source: try source(),
            isActive: isActive,
            createdAt: createdAt ?? "",
            contentBytes: contentBytes,
            contentDigest: contentDigest)
    }
}

// MARK: - Request decoders (closed P0 grammar)

public struct PersonalizationGetRequest: Sendable, Equatable {
    public var kind: SettingsDomainV1.PersonalizationKind
    public var workspaceID: UUID?
    public var revisionsCursor: Int
    public var revisionsLimit: Int

    /// Contract: revisionsMeta default page 50 (limit 1..100).
    public static let defaultRevisionsLimit = 50

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> PersonalizationGetRequest
    {
        guard case .object(let root)? = payload,
              let kindValue = root["kind"] else {
            throw PersonalizationAdapterError.invalidEnvelope("missingPayloadField:kind")
        }
        for key in root.keys where !["kind", "workspaceID", "revisionsCursor",
                                     "revisionsLimit"].contains(key) {
            throw PersonalizationAdapterError.invalidEnvelope("unknownPersonalizationField")
        }
        guard case .string(let kindRaw) = kindValue,
              let kind = SettingsDomainV1.PersonalizationKind(rawValue: kindRaw) else {
            throw PersonalizationAdapterError.invalidEnvelope("invalidPayloadField:kind")
        }
        var request = PersonalizationGetRequest(kind: kind, workspaceID: nil,
                                                revisionsCursor: 0,
                                                revisionsLimit: defaultRevisionsLimit)
        if let value = root["workspaceID"], !WireMemorySupport.isJSONNull(value) {
            request.workspaceID = try WireMemorySupport.uuid(value, "workspaceID")
        }
        if let value = root["revisionsCursor"] {
            request.revisionsCursor = try WireMemorySupport.cursor(value)
        }
        if let value = root["revisionsLimit"] {
            let raw = try WireMemorySupport.integer(value, "revisionsLimit")
            guard raw >= 1, raw <= Int64(SettingsDomainV1.maximumCandidatePage) else {
                throw PersonalizationAdapterError.invalidEnvelope(
                    "payloadFieldOutOfRange:revisionsLimit")
            }
            request.revisionsLimit = Int(raw)
        }
        return request
    }
}

public struct PersonalizationRevisionReadRequest: Sendable, Equatable {
    public var kind: SettingsDomainV1.PersonalizationKind
    public var workspaceID: UUID?
    public var revision: Int

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> PersonalizationRevisionReadRequest
    {
        guard case .object(let root)? = payload,
              let kindValue = root["kind"], let revisionValue = root["revision"] else {
            throw PersonalizationAdapterError.invalidEnvelope("missingPayloadField:revision")
        }
        for key in root.keys where !["kind", "workspaceID", "revision"].contains(key) {
            throw PersonalizationAdapterError.invalidEnvelope("unknownPersonalizationField")
        }
        guard case .string(let kindRaw) = kindValue,
              let kind = SettingsDomainV1.PersonalizationKind(rawValue: kindRaw) else {
            throw PersonalizationAdapterError.invalidEnvelope("invalidPayloadField:kind")
        }
        let rawRevision = try WireMemorySupport.integer(revisionValue, "revision")
        guard rawRevision >= 1 else {
            throw PersonalizationAdapterError.invalidEnvelope("invalidPayloadField:revision")
        }
        var request = PersonalizationRevisionReadRequest(kind: kind, workspaceID: nil,
                                                         revision: Int(rawRevision))
        if let value = root["workspaceID"], !WireMemorySupport.isJSONNull(value) {
            request.workspaceID = try WireMemorySupport.uuid(value, "workspaceID")
        }
        return request
    }
}

public struct PersonalizationSaveRequest: Sendable, Equatable {
    public var kind: SettingsDomainV1.PersonalizationKind
    public var workspaceID: UUID?
    public var content: String

    /// Mirrors the P0 personalizationContentValue grammar: non-empty after
    /// trim (documentEmpty), no embedded NUL, ≤24000 chars rejected as
    /// payloadTooLarge BEFORE any mutation (Main Q4; the original silent
    /// prefix clamp :52 is a documented deviation for user edits).
    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> PersonalizationSaveRequest
    {
        guard case .object(let root)? = payload,
              let kindValue = root["kind"], let contentValue = root["content"] else {
            throw PersonalizationAdapterError.invalidEnvelope("missingPayloadField:content")
        }
        for key in root.keys where !["kind", "workspaceID", "content"].contains(key) {
            throw PersonalizationAdapterError.invalidEnvelope("unknownPersonalizationField")
        }
        guard case .string(let kindRaw) = kindValue,
              let kind = SettingsDomainV1.PersonalizationKind(rawValue: kindRaw) else {
            throw PersonalizationAdapterError.invalidEnvelope("invalidPayloadField:kind")
        }
        guard case .string(let content) = contentValue else {
            throw PersonalizationAdapterError.invalidEnvelope("invalidPayloadField:content")
        }
        guard !content.contains("\u{0}") else {
            throw PersonalizationAdapterError.invalidEnvelope("invalidPayloadField:content")
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PersonalizationAdapterError.invalidEnvelope("documentEmpty")
        }
        guard content.count <= SettingsDomainV1.maximumPersonalizationContentCharacters else {
            throw PersonalizationAdapterError.payloadTooLarge(
                maxChars: SettingsDomainV1.maximumPersonalizationContentCharacters)
        }
        var workspaceID: UUID?
        if let value = root["workspaceID"], !WireMemorySupport.isJSONNull(value) {
            workspaceID = try WireMemorySupport.uuid(value, "workspaceID")
        }
        return PersonalizationSaveRequest(kind: kind, workspaceID: workspaceID,
                                          content: content)
    }
}

public struct PersonalizationRollbackRequest: Sendable, Equatable {
    public var kind: SettingsDomainV1.PersonalizationKind
    public var workspaceID: UUID?
    public var targetRevision: Int

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> PersonalizationRollbackRequest
    {
        guard case .object(let root)? = payload,
              let kindValue = root["kind"], let revisionValue = root["targetRevision"] else {
            throw PersonalizationAdapterError.invalidEnvelope("missingPayloadField:targetRevision")
        }
        for key in root.keys where !["kind", "workspaceID", "targetRevision"].contains(key) {
            throw PersonalizationAdapterError.invalidEnvelope("unknownPersonalizationField")
        }
        guard case .string(let kindRaw) = kindValue,
              let kind = SettingsDomainV1.PersonalizationKind(rawValue: kindRaw) else {
            throw PersonalizationAdapterError.invalidEnvelope("invalidPayloadField:kind")
        }
        let raw = try WireMemorySupport.integer(revisionValue, "targetRevision")
        guard raw >= 1 else {
            throw PersonalizationAdapterError.invalidEnvelope("invalidPayloadField:targetRevision")
        }
        var workspaceID: UUID?
        if let value = root["workspaceID"], !WireMemorySupport.isJSONNull(value) {
            workspaceID = try WireMemorySupport.uuid(value, "workspaceID")
        }
        return PersonalizationRollbackRequest(kind: kind, workspaceID: workspaceID,
                                              targetRevision: Int(raw))
    }
}

public struct PersonalizationAutomaticRequest: Sendable, Equatable {
    public var kind: SettingsDomainV1.PersonalizationKind
    public var workspaceID: UUID?
    public var enabled: Bool

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> PersonalizationAutomaticRequest
    {
        guard case .object(let root)? = payload,
              let kindValue = root["kind"], let enabledValue = root["enabled"] else {
            throw PersonalizationAdapterError.invalidEnvelope("missingPayloadField:enabled")
        }
        for key in root.keys where !["kind", "workspaceID", "enabled"].contains(key) {
            throw PersonalizationAdapterError.invalidEnvelope("unknownPersonalizationField")
        }
        guard case .string(let kindRaw) = kindValue,
              let kind = SettingsDomainV1.PersonalizationKind(rawValue: kindRaw) else {
            throw PersonalizationAdapterError.invalidEnvelope("invalidPayloadField:kind")
        }
        let enabled = try WireMemorySupport.boolean(enabledValue, "enabled")
        var workspaceID: UUID?
        if let value = root["workspaceID"], !WireMemorySupport.isJSONNull(value) {
            workspaceID = try WireMemorySupport.uuid(value, "workspaceID")
        }
        return PersonalizationAutomaticRequest(kind: kind, workspaceID: workspaceID,
                                               enabled: enabled)
    }
}

// MARK: - Content-handle binding index

/// A staged oversize document snapshot: handle → the REAL stored row that
/// produced it (never a file path, never arbitrary storage). The bytes live
/// ONLY in the shared bounded reader behind the port; this index is
/// metadata. Bindings mirror the RB1 reader's own live-handle bound so the
/// index cannot outlive the bytes it names.
public struct PersonalizationContentBinding: Sendable, Equatable {
    public let handle: String
    public let kindRaw: String
    public let workspaceID: UUID?
    public let documentID: UUID
    public let revision: Int
    public let totalBytes: Int
    public let contentDigest: String
}

public actor FacadePersonalizationContentStore {
    public static let maximumBindings = 32
    static let maximumDetachedMemory = 64

    private let port: any PersonalizationContentStoring
    private var bindings: [String: PersonalizationContentBinding] = [:]
    private var order: [String] = []
    private var detached: [String] = []

    public init(port: any PersonalizationContentStoring) {
        self.port = port
    }

    /// Stage the COMPLETE stored content of one real document row and mint
    /// the owned handle. Called ONLY when the complete encoded response
    /// exceeds the actual 48 KiB page budget (Q10) — never unconditionally.
    func publish(content: String, kindRaw: String, workspaceID: UUID?,
                 documentID: UUID, revision: Int) async throws
        -> SettingsDomainV1.ContentHandle
    {
        let bytes = Data(content.utf8)
        let digestValue = SHA256.hash(data: bytes)
        let digest = "sha256:" + digestValue.map { String(format: "%02x", $0) }.joined()
        switch await port.stage(bytes) {
        case .staged(let handle):
            bindings[handle] = PersonalizationContentBinding(
                handle: handle, kindRaw: kindRaw, workspaceID: workspaceID,
                documentID: documentID, revision: revision,
                totalBytes: bytes.count, contentDigest: digest)
            order.append(handle)
            while order.count > Self.maximumBindings {
                let oldest = order.removeFirst()
                if let binding = bindings.removeValue(forKey: oldest) {
                    detached.append(oldest)
                    while detached.count > Self.maximumDetachedMemory {
                        detached.removeFirst()
                    }
                    await port.release(handle: binding.handle)
                }
            }
            return SettingsDomainV1.ContentHandle(handle: handle, bytes: bytes.count)
        case .contentSaturated:
            // Fail closed typed: never truncate a document with a
            // completeness label, never evict another owner's live handle.
            throw PersonalizationAdapterError
                .persistenceUnavailable("contentHandleSaturated")
        case .emptyContent:
            throw PersonalizationAdapterError.persistenceUnavailable("emptyDocumentContent")
        }
    }

    enum LookUp {
        case found(PersonalizationContentBinding)
        case expired
        case unknown
    }

    func lookup(handle: String) -> LookUp {
        if let binding = bindings[handle] { return .found(binding) }
        if detached.contains(handle) { return .expired }
        return .unknown
    }

    func read(handle: String, offset: Int, maxBytes: Int) async -> PersonalizationContentSlice {
        await port.read(handle: handle, offset: offset, maxBytes: maxBytes)
    }
}

// MARK: - Inline vs owned-handle projection (Q10 / frameBudgets.contentInlineRule)

internal enum FacadePersonalizationProjection {
    /// Decide inline vs owned handle for one document projection using the
    /// P0 helper over the COMPLETE ENCODED response (actual UTF-8 bytes
    /// including JSON escaping). `metadataEncodedBytesWithEmptyContent` is
    /// the actual encoded reply with the content string set to "". There is
    /// NO separate 16KiB inline cap (Main Q10); the 64KiB hard frame bound
    /// remains at the binder. Content is never emitted both inline and as a
    /// handle (the P0 DTO enforces the XOR on construction AND decode).
    static func document(from row: FacadeDocumentRawRow,
                         metadataEncodedBytesWithEmptyContent: Int,
                         pageBudget: Int = SettingsDomainV1.pageBudgetBytes) -> Bool {
        SettingsDomainV1.ContentBudget.shouldInline(
            content: row.content,
            metadataEncodedBytesWithEmptyContent: metadataEncodedBytesWithEmptyContent,
            pageBudget: pageBudget)
    }

    static func activeSlotToken(of row: FacadeDocumentRawRow?) -> String {
        guard let row, let uuid = UUID(uuidString: row.id) else {
            return PersonalizationResourceIDs.absentToken
        }
        return PersonalizationResourceIDs.activeSlotToken(documentID: uuid,
                                                          revision: Int(row.revision))
    }
}

// MARK: - FacadePersonalizationAdapter

/// Personalization backend over the ONE original schema-46 DatabaseManager
/// (commandTable entries 15-19). The document CAS resource is the ACTIVE
/// DOCUMENT SLOT — the real is_active=1 row's id+revision, or 'absent' —
/// NEVER MAX(revision) (drafts above the active row do not change the
/// token and are never silently activated). latestRevision is exposed
/// separately. The cursor CAS token is the complete 8-column
/// floe.personalization-cursor.v1 digest or the literal 'absent' — NEVER
/// the second-precision updated_at string.
public actor FacadePersonalizationAdapter {
    private let database: DatabaseManager
    private let workspaceStore: SQLiteWorkspaceStore
    private let contentStore: FacadePersonalizationContentStore
    /// Internal test-only fault seam; never reachable from a production
    /// initializer.
    private let faultInjection: (@Sendable (String) throws -> Void)?

    public init(database: DatabaseManager,
                workspaceStore: SQLiteWorkspaceStore,
                contentStore: FacadePersonalizationContentStore) {
        self.database = database
        self.workspaceStore = workspaceStore
        self.contentStore = contentStore
        self.faultInjection = nil
    }

    init(database: DatabaseManager,
         workspaceStore: SQLiteWorkspaceStore,
         contentStore: FacadePersonalizationContentStore,
         faultInjection: (@Sendable (String) throws -> Void)?) {
        self.database = database
        self.workspaceStore = workspaceStore
        self.contentStore = contentStore
        self.faultInjection = faultInjection
    }

    static func secondDate(_ date: Date) -> String { FacadeStoreTime.second(date) }

    static func workspaceKey(_ id: UUID?) -> String { id?.uuidString ?? "" }

    private func validateWorkspace(_ workspaceID: UUID?) async throws {
        if let workspaceID {
            guard try await workspaceStore.workspace(id: workspaceID) != nil else {
                throw PersonalizationAdapterError.notFound("workspaceMissing")
            }
        }
    }

    // MARK: - personalization.get

    /// ONE reader transaction: the active row via the partial-unique active
    /// index (mirrors Personalization.swift:304-316), MAX(revision) as
    /// latestRevision (:355-358 expression over ALL rows incl. drafts), one
    /// BOUNDED page of revision METADATA (id, revision, source, isActive,
    /// createdAt, UTF-8 byte length via length(CAST(content AS BLOB)) and
    /// the content digest — NOT full contents on the wire; the original
    /// documentRevisions unbounded full-array path is projected, never
    /// used), the cursor row (:381-394) with its complete-row digest, and
    /// the ACTIVE-SLOT revisionToken. Content is inlined only when the
    /// COMPLETE encoded response fits the actual 48KiB budget; otherwise
    /// the response carries an owned contentHandle.
    public func read(_ request: PersonalizationGetRequest) async throws
        -> SettingsDomainV1.PersonalizationGetReply
    {
        try await validateWorkspace(request.workspaceID)
        let database = self.database
        let kindRaw = request.kind.rawValue
        let workspaceKey = Self.workspaceKey(request.workspaceID)
        let revisionsLimit = min(SettingsDomainV1.maximumCandidatePage,
                                 max(1, request.revisionsLimit))
        let revisionsOffset = request.revisionsCursor
        struct Snapshot: Sendable {
            let active: FacadeDocumentRawRow?
            let latestRevision: Int
            let revisionRows: [FacadeDocumentRawRow]
            let revisionsProbeHasMore: Bool
            let cursor: FacadeCursorRawRow?
        }
        let snapshot: Snapshot = try await database.reader { db in
            let activeRow = try Row.fetchOne(db, sql: """
                SELECT * FROM personalization_documents
                WHERE kind = ? AND workspace_id IS ? AND is_active = 1
                LIMIT 1
                """, arguments: [kindRaw, request.workspaceID?.uuidString])
            let latest = try Int.fetchOne(db, sql: """
                SELECT MAX(revision) FROM personalization_documents
                WHERE kind = ? AND workspace_id IS ?
                """, arguments: [kindRaw, request.workspaceID?.uuidString]) ?? 0
            let revisionRows = try Row.fetchAll(db, sql: """
                SELECT * FROM personalization_documents
                WHERE kind = ? AND workspace_id IS ?
                ORDER BY revision DESC
                LIMIT ? OFFSET ?
                """, arguments: [kindRaw, request.workspaceID?.uuidString,
                                 revisionsLimit + 1, revisionsOffset])
                .map(FacadeDocumentRawRow.init)
            let cursorRow = try Row.fetchOne(db, sql: """
                SELECT * FROM personalization_update_cursors
                WHERE kind = ? AND workspace_key = ?
                """, arguments: [kindRaw, workspaceKey])
            return Snapshot(
                active: activeRow.map(FacadeDocumentRawRow.init),
                latestRevision: Int(latest),
                revisionRows: Array(revisionRows.prefix(revisionsLimit)),
                revisionsProbeHasMore: revisionRows.count > revisionsLimit,
                cursor: cursorRow.map(FacadeCursorRawRow.init))
        }
        // revision metadata page (bounded): the original projection order
        // revision DESC is preserved; nextCursor is the client-owned offset.
        var revisionsMeta: [SettingsDomainV1.PersonalizationRevisionMeta] = []
        for row in snapshot.revisionRows {
            revisionsMeta.append(try row.revisionMeta())
        }
        let revisionsNextCursor = snapshot.revisionsProbeHasMore
            ? String(revisionsOffset + revisionsMeta.count) : nil
        // Cursor: complete-row digest or the literal 'absent'; when no row
        // exists the ORIGINAL store synthesizes defaults WITHOUT persisting
        // (:386-391) — mirrored exactly; that synthesis is display state,
        // never a CAS token ('absent' is the token).
        let cursorDTO: SettingsDomainV1.PersonalizationCursor
        if let cursor = snapshot.cursor {
            cursorDTO = try cursor.cursorDTO(revisionToken: cursor.digest)
        } else {
            cursorDTO = SettingsDomainV1.PersonalizationCursor(
                automaticUpdatesEnabled: true,
                lastGeneratedAt: nil,
                completedRunsSinceUpdate: 0,
                userMessagesSinceUpdate: 0,
                updatedAt: Self.secondDate(Date()),
                revision: PersonalizationResourceIDs.absentToken)
        }
        let revisionToken = FacadePersonalizationProjection.activeSlotToken(of: snapshot.active)
        // Inline vs owned-handle decision on the COMPLETE encoded response.
        let activeProjection: SettingsDomainV1.PersonalizationDocument?
        if let active = snapshot.active {
            let emptyContentDoc = try Self.documentDTO(from: active, content: "",
                                                       handle: nil,
                                                       kind: request.kind)
            let emptyContentReply = SettingsDomainV1.PersonalizationGetReply(
                active: emptyContentDoc,
                latestRevision: snapshot.latestRevision,
                revisionsMeta: revisionsMeta,
                cursor: cursorDTO,
                revisionToken: revisionToken,
                revisionsNextCursor: revisionsNextCursor)
            let skeletonBytes = FacadeWireBytes.count(emptyContentReply)
            if FacadePersonalizationProjection.document(
                from: active,
                metadataEncodedBytesWithEmptyContent: skeletonBytes) {
                activeProjection = try Self.documentDTO(from: active, content: active.content,
                                                        handle: nil, kind: request.kind)
            } else {
                guard let documentID = UUID(uuidString: active.id) else {
                    throw PersonalizationAdapterError.persistenceUnavailable("corruptDocumentRow")
                }
                let handle = try await contentStore.publish(
                    content: active.content, kindRaw: request.kind.rawValue,
                    workspaceID: request.workspaceID, documentID: documentID,
                    revision: Int(active.revision))
                activeProjection = try Self.documentDTO(from: active, content: nil,
                                                        handle: handle,
                                                        kind: request.kind)
            }
        } else {
            activeProjection = nil
        }
        return SettingsDomainV1.PersonalizationGetReply(
            active: activeProjection,
            latestRevision: snapshot.latestRevision,
            revisionsMeta: revisionsMeta,
            cursor: cursorDTO,
            revisionToken: revisionToken,
            revisionsNextCursor: revisionsNextCursor)
    }

    // MARK: - personalization.revision.read

    /// Bounded single-row SELECT via the UNIQUE (kind, workspace, revision)
    /// indexes (V13:63-68) — never the original unbounded documentRevisions
    /// array. Drafts are readable exactly like active revisions (native
    /// DisclosureGroup parity).
    public func revisionRead(_ request: PersonalizationRevisionReadRequest) async throws
        -> SettingsDomainV1.PersonalizationRevisionReply
    {
        try await validateWorkspace(request.workspaceID)
        let database = self.database
        let row: FacadeDocumentRawRow? = try await database.reader { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM personalization_documents
                WHERE kind = ? AND workspace_id IS ? AND revision = ?
                LIMIT 1
                """, arguments: [request.kind.rawValue,
                                 request.workspaceID?.uuidString,
                                 request.revision])
                .map(FacadeDocumentRawRow.init)
        }
        guard let row else {
            throw PersonalizationAdapterError.notFound("revisionMissing")
        }
        // The same Q10 decision over the complete single-document reply.
        let skeletonDoc = try Self.documentDTO(from: row, content: "", handle: nil,
                                               kind: request.kind)
        let skeleton = SettingsDomainV1.PersonalizationRevisionReply(document: skeletonDoc)
        var outDoc: SettingsDomainV1.PersonalizationDocument
        if FacadePersonalizationProjection.document(
            from: row,
            metadataEncodedBytesWithEmptyContent: FacadeWireBytes.count(skeleton)) {
            outDoc = try Self.documentDTO(from: row, content: row.content, handle: nil,
                                          kind: request.kind)
        } else {
            guard let documentID = UUID(uuidString: row.id) else {
                throw PersonalizationAdapterError.persistenceUnavailable("corruptDocumentRow")
            }
            let handle = try await contentStore.publish(
                content: row.content, kindRaw: request.kind.rawValue,
                workspaceID: request.workspaceID, documentID: documentID,
                revision: Int(row.revision))
            outDoc = try Self.documentDTO(from: row, content: nil, handle: handle,
                                          kind: request.kind)
        }
        return SettingsDomainV1.PersonalizationRevisionReply(document: outDoc)
    }

    // MARK: - personalization.save

    /// ONE writer transaction mirroring saveDocument (:350-379) PLUS the
    /// missing CAS: (1) active-slot token compare ('absent' requires zero
    /// active rows; mismatch → staleRevision, NOTHING written);
    /// (2) nextRevision = MAX(revision)+1 over ALL rows incl. drafts — a
    /// new save always appends ABOVE existing drafts; (3) deactivate the
    /// previous active row; (4) INSERT the manual row (trim + non-empty per
    /// :352-353; evidence_digest ''); (5) read-after-write in-transaction.
    /// Draft rows are NEVER touched or activated by this path, so an
    /// inactive automatic draft never contends with an editing save and an
    /// editing save never clobbers a draft.
    public func save(expectedActiveToken: String, request: PersonalizationSaveRequest) async throws
        -> SettingsDomainV1.PersonalizationSaveReply
    {
        try await validateWorkspace(request.workspaceID)
        let trimmed = request.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PersonalizationAdapterError.invalidEnvelope("documentEmpty")
        }
        guard request.content.count <= SettingsDomainV1.maximumPersonalizationContentCharacters else {
            throw PersonalizationAdapterError.payloadTooLarge(
                maxChars: SettingsDomainV1.maximumPersonalizationContentCharacters)
        }
        let database = self.database
        let kindRaw = request.kind.rawValue
        let workspaceIDValue = request.workspaceID?.uuidString
        let documentID = UUID()
        let fault = self.faultInjection
        struct Outcome: Sendable {
            let row: FacadeDocumentRawRow
            let latestRevision: Int
        }
        let outcome: Outcome
        do {
            outcome = try await database.writer { db -> Outcome in
                let activeRow = try Row.fetchOne(db, sql: """
                    SELECT id, revision FROM personalization_documents
                    WHERE kind = ? AND workspace_id IS ? AND is_active = 1
                    LIMIT 1
                    """, arguments: [kindRaw, workspaceIDValue])
                let currentToken: String
                if let activeRow {
                    let id: String = activeRow["id"]
                    let revision: DatabaseValue = activeRow["revision"]
                    var revisionNumber = 0
                    if case .int64(let raw) = revision.storage { revisionNumber = Int(raw) }
                    currentToken = "\(id).\(revisionNumber)"
                } else {
                    currentToken = PersonalizationResourceIDs.absentToken
                }
                // A malformed expected token is not special-cased: it simply
                // compares unequal → staleRevision (defaults-lane precedent).
                guard currentToken == expectedActiveToken else {
                    throw PersonalizationAdapterError.staleRevision
                }
                let nextRevision = try Int.fetchOne(db, sql: """
                    SELECT MAX(revision) FROM personalization_documents
                    WHERE kind = ? AND workspace_id IS ?
                    """, arguments: [kindRaw, workspaceIDValue]) ?? 0
                try db.execute(sql: """
                    UPDATE personalization_documents SET is_active = 0
                    WHERE kind = ? AND workspace_id IS ? AND is_active = 1
                    """, arguments: [kindRaw, workspaceIDValue])
                try fault?("personalization.save.beforeInsert")
                try db.execute(sql: """
                    INSERT INTO personalization_documents (
                        id, kind, workspace_id, revision, content, source_kind,
                        evidence_digest, is_active, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [documentID.uuidString, kindRaw, workspaceIDValue,
                                     Int(nextRevision) + 1, trimmed, "manual", "",
                                     1, Self.secondDate(Date())])
                let latest = try Int.fetchOne(db, sql: """
                    SELECT MAX(revision) FROM personalization_documents
                    WHERE kind = ? AND workspace_id IS ?
                    """, arguments: [kindRaw, workspaceIDValue]) ?? 0
                guard let written = try Row.fetchOne(db, sql: """
                    SELECT * FROM personalization_documents WHERE id = ?
                    """, arguments: [documentID.uuidString]) else {
                    throw PersonalizationAdapterError.persistenceUnavailable("saveDidNotApply")
                }
                return Outcome(row: FacadeDocumentRawRow(written), latestRevision: Int(latest))
            }
        } catch let error as PersonalizationAdapterError {
            throw error
        } catch {
            throw PersonalizationAdapterError.persistenceUnavailable(nil)
        }
        let replyToken = FacadePersonalizationProjection
            .activeSlotToken(of: outcome.row)
        let document = try await Self.projectWithHandle(
            outcome.row, kind: request.kind,
            workspaceID: request.workspaceID,
            revisionToken: replyToken,
            latestRevision: outcome.latestRevision,
            contentStore: contentStore)
        return SettingsDomainV1.PersonalizationSaveReply(
            document: document, revisionToken: replyToken,
            latestRevision: outcome.latestRevision)
    }

    // MARK: - personalization.rollback

    /// ONE writer transaction: active-slot CAS → target revision existence
    /// via the UNIQUE index (typed notFound revisionMissing, original guard
    /// :680-682) → append the active copy (source 'rollback', content +
    /// evidence_digest copied from the target row, revision MAX+1,
    /// deactivate previous active) — PersonalizationService.rollback
    /// semantics (:673-686) plus CAS. Append-only and non-destructive: the
    /// target row is NEVER mutated, so this stays the ONLY activation path
    /// (native "confirm and enable" parity) and a rolled-back draft stays
    /// inactive forever.
    public func rollback(expectedActiveToken: String,
                         request: PersonalizationRollbackRequest) async throws
        -> SettingsDomainV1.PersonalizationRollbackReply
    {
        try await validateWorkspace(request.workspaceID)
        let database = self.database
        let kindRaw = request.kind.rawValue
        let workspaceIDValue = request.workspaceID?.uuidString
        let newDocumentID = UUID()
        struct Outcome: Sendable { let row: FacadeDocumentRawRow }
        let outcome: Outcome
        do {
            outcome = try await database.writer { db -> Outcome in
                let activeRow = try Row.fetchOne(db, sql: """
                    SELECT id, revision FROM personalization_documents
                    WHERE kind = ? AND workspace_id IS ? AND is_active = 1
                    LIMIT 1
                    """, arguments: [kindRaw, workspaceIDValue])
                let currentToken: String
                if let activeRow {
                    let id: String = activeRow["id"]
                    let revision: DatabaseValue = activeRow["revision"]
                    var revisionNumber = 0
                    if case .int64(let raw) = revision.storage { revisionNumber = Int(raw) }
                    currentToken = "\(id).\(revisionNumber)"
                } else {
                    currentToken = PersonalizationResourceIDs.absentToken
                }
                guard currentToken == expectedActiveToken else {
                    throw PersonalizationAdapterError.staleRevision
                }
                guard let target = try Row.fetchOne(db, sql: """
                    SELECT * FROM personalization_documents
                    WHERE kind = ? AND workspace_id IS ? AND revision = ?
                    LIMIT 1
                    """, arguments: [kindRaw, workspaceIDValue, request.targetRevision]) else {
                    throw PersonalizationAdapterError.notFound("revisionMissing")
                }
                let targetRow = FacadeDocumentRawRow(target)
                let nextRevision = try Int.fetchOne(db, sql: """
                    SELECT MAX(revision) FROM personalization_documents
                    WHERE kind = ? AND workspace_id IS ?
                    """, arguments: [kindRaw, workspaceIDValue]) ?? 0
                try db.execute(sql: """
                    UPDATE personalization_documents SET is_active = 0
                    WHERE kind = ? AND workspace_id IS ? AND is_active = 1
                    """, arguments: [kindRaw, workspaceIDValue])
                try db.execute(sql: """
                    INSERT INTO personalization_documents (
                        id, kind, workspace_id, revision, content, source_kind,
                        evidence_digest, is_active, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [newDocumentID.uuidString, kindRaw, workspaceIDValue,
                                     Int(nextRevision) + 1, targetRow.content, "rollback",
                                     targetRow.evidenceDigest, 1, Self.secondDate(Date())])
                guard let written = try Row.fetchOne(db, sql: """
                    SELECT * FROM personalization_documents WHERE id = ?
                    """, arguments: [newDocumentID.uuidString]) else {
                    throw PersonalizationAdapterError.persistenceUnavailable("rollbackDidNotApply")
                }
                return Outcome(row: FacadeDocumentRawRow(written))
            }
        } catch let error as PersonalizationAdapterError {
            throw error
        } catch {
            throw PersonalizationAdapterError.persistenceUnavailable(nil)
        }
        let replyToken = FacadePersonalizationProjection
            .activeSlotToken(of: outcome.row)
        let document = try await Self.projectWithHandle(
            outcome.row, kind: request.kind,
            workspaceID: request.workspaceID,
            revisionToken: replyToken,
            latestRevision: Int(outcome.row.revision),
            contentStore: contentStore)
        return SettingsDomainV1.PersonalizationRollbackReply(
            document: document, revisionToken: replyToken)
    }

    // MARK: - personalization.automatic.set

    /// ONE writer transaction closing the race against a concurrent
    /// recordActivity / generate resetCursor WITHOUT relying on the
    /// second-precision timestamp (commandTable entry 19): SELECT the
    /// complete 8-column cursor row → floe.personalization-cursor.v1 digest
    /// → compare ('absent' requires NO row, a digest requires the row and a
    /// match; mismatch → staleRevision, nothing written) → UPSERT mirroring
    /// saveCursor (:396-415) preserving lastGeneratedAt AND BOTH counters
    /// verbatim, flipping automatic_updates_enabled, updated_at=now
    /// (second-precision Self.date parity with the store :544 — a WRITE
    /// value, never a token) → read-after-write returning the NEW complete-
    /// row digest.
    public func setAutomatic(expectedCursorToken: String,
                             request: PersonalizationAutomaticRequest) async throws
        -> SettingsDomainV1.PersonalizationAutomaticReply
    {
        try await validateWorkspace(request.workspaceID)
        let database = self.database
        let kindRaw = request.kind.rawValue
        let workspaceKey = Self.workspaceKey(request.workspaceID)
        let workspaceIDValue = request.workspaceID?.uuidString
        let cursorRow: FacadeCursorRawRow? = try await database.writer { db -> FacadeCursorRawRow? in
            let stored = try Row.fetchOne(db, sql: """
                SELECT * FROM personalization_update_cursors
                WHERE kind = ? AND workspace_key = ?
                """, arguments: [kindRaw, workspaceKey])
                .map(FacadeCursorRawRow.init)
            let currentToken = stored?.digest ?? PersonalizationResourceIDs.absentToken
            guard currentToken == expectedCursorToken else {
                throw PersonalizationAdapterError.staleRevision
            }
            // Preserve lastGeneratedAt and BOTH counters verbatim; flip the
            // flag; updated_at=now. The 'absent' path creates the row from
            // the store's synthesized defaults (:386-391) with the flag set
            // to the requested value.
            let enabled = request.enabled
            let lastGeneratedAt = stored?.lastGeneratedAt
            let completed = stored?.completedRunsSinceUpdate ?? 0
            let messages = stored?.userMessagesSinceUpdate ?? 0
            try db.execute(sql: """
                INSERT INTO personalization_update_cursors (
                    kind, workspace_key, workspace_id, automatic_updates_enabled,
                    last_generated_at, completed_runs_since_update,
                    user_messages_since_update, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(kind, workspace_key) DO UPDATE SET
                    automatic_updates_enabled=excluded.automatic_updates_enabled,
                    last_generated_at=excluded.last_generated_at,
                    completed_runs_since_update=excluded.completed_runs_since_update,
                    user_messages_since_update=excluded.user_messages_since_update,
                    updated_at=excluded.updated_at
                """, arguments: [kindRaw, workspaceKey, workspaceIDValue, enabled,
                                 lastGeneratedAt, completed, messages,
                                 Self.secondDate(Date())])
            return try Row.fetchOne(db, sql: """
                SELECT * FROM personalization_update_cursors
                WHERE kind = ? AND workspace_key = ?
                """, arguments: [kindRaw, workspaceKey])
                .map(FacadeCursorRawRow.init)
        }
        guard let cursorRow else {
            throw PersonalizationAdapterError.persistenceUnavailable("cursorDidNotPersist")
        }
        return SettingsDomainV1.PersonalizationAutomaticReply(
            cursor: try cursorRow.cursorDTO(revisionToken: cursorRow.digest))
    }

    // MARK: - Shared projection

    static func documentDTO(from row: FacadeDocumentRawRow,
                            content: String?,
                            handle: SettingsDomainV1.ContentHandle?,
                            kind: SettingsDomainV1.PersonalizationKind) throws
        -> SettingsDomainV1.PersonalizationDocument
    {
        guard let documentID = UUID(uuidString: row.id) else {
            throw PersonalizationAdapterError.persistenceUnavailable("corruptDocumentRow")
        }
        return try SettingsDomainV1.PersonalizationDocument(
            id: documentID,
            kind: kind,
            workspaceID: row.workspaceID.flatMap(UUID.init(uuidString:)),
            revision: Int(row.revision),
            source: try row.source(),
            evidenceDigest: row.evidenceDigest,
            isActive: row.isActive,
            createdAt: row.createdAt ?? "",
            contentBytes: row.contentBytes,
            contentDigest: row.contentDigest,
            content: content,
            contentHandle: handle)
    }

    /// Project one committed row for a mutation reply using the same Q10
    /// inline-vs-owned-handle rule measured on the COMPLETE encoded reply.
    /// A committed mutation whose oversized reply cannot stage a handle
    /// (shared-reader saturation) reports the typed
    /// persistenceUnavailable("contentHandleSaturatedAfterCommit"): the
    /// DB state stays committed and durable (asyncAndLifetime.unknownOutcome
    /// — reconcile with personalization.get); the wire NEVER silently
    /// truncates or fabricates content.
    static func projectWithHandle(_ row: FacadeDocumentRawRow,
                                  kind: SettingsDomainV1.PersonalizationKind,
                                  workspaceID: UUID?,
                                  revisionToken: String,
                                  latestRevision: Int,
                                  contentStore: FacadePersonalizationContentStore) async throws
        -> SettingsDomainV1.PersonalizationDocument
    {
        let skeletonDoc = try documentDTO(from: row, content: "", handle: nil, kind: kind)
        let skeleton = SettingsDomainV1.PersonalizationSaveReply(
            document: skeletonDoc, revisionToken: revisionToken,
            latestRevision: latestRevision)
        if FacadePersonalizationProjection.document(
            from: row,
            metadataEncodedBytesWithEmptyContent: FacadeWireBytes.count(skeleton)) {
            return try documentDTO(from: row, content: row.content, handle: nil, kind: kind)
        }
        guard let documentID = UUID(uuidString: row.id) else {
            throw PersonalizationAdapterError.persistenceUnavailable("corruptDocumentRow")
        }
        let handle = try await contentStore.publish(
            content: row.content, kindRaw: kind.rawValue,
            workspaceID: workspaceID, documentID: documentID,
            revision: Int(row.revision))
        return try documentDTO(from: row, content: nil, handle: handle, kind: kind)
    }
}
