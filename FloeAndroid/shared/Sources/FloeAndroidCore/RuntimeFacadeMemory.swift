// SPDX-License-Identifier: MPL-2.0
//
// P2 — G02 memory adapter + deterministic organizer (private source
// candidate; UNCOMPILED). Job job-676ec714cb334606 (RB3b intelligence
// backend lane).
//
// Authority: settings-domain-main-acceptance-20261019/input-final/contract.json
// (sha256 f3ddecdca061ae17fbe4280b7bfb549d8a1673fd8d9ae6e1ba363332ef5db46c),
// commandTable entries label=memory (memory.list/get/add/update/delete/
// delete.bulk/search/candidates.list/candidate.resolve/organize.start/
// organize.proposal.read/organize.apply/organize.cancel),
// wireConventions.digestDomains, adapters.components[FacadeMemoryAdapter],
// behavioralTestDesign P2 vectors, IMPLEMENTATION_HANDOFF.md P2 checks.
//
// Original-source pins (byte-identical, NOT edited here):
// * FloeAgent/Sources/FloeAgentRuntime/IntelligenceStore.swift:392-457
//   (saveMemory guards + UPSERT + evidence inserts), :459-464 memory(id:),
//   :466-521 listMemories SQL/ordering + n+1 probe, :539-588
//   organizationPreview derivation, :590-658 applyMaintenanceBatch ledger
//   semantics, :634-644 replace UPDATE column set, :684-725 preserve*
//   detach writers, :820-908 hybridRecall, :913-933 reinforceMemories,
//   :939-961 maintainMemoryLifecycle, :977-993 delete + tombstone helper,
//   :1345-1375 Self.memory(row) projection, :1377-1384 Self.scope,
//   :1585-1590 Self.date/parseDate, :1591-1596 looksLikeSecret markers,
//   :1597-1602 stableDigest (FNV-1a radix-16, reproduced verbatim below
//   because the original is `private` and the contract explicitly requires
//   the byte-exact double-digest reproduction for candidate activation).
// * FloeAgent/Sources/FloeAgentRuntime/Personalization.swift:417-468
//   (saveCandidate redaction, expiry sweep, candidates ordering), :496-516
//   Self.candidate row decode, :518-541 scope encode/decode, :834-856
//   resolvePending mapping ("approved by user"/"rejected by user").
// * MemoryMaintenance.swift:5-20 (MemoryFactIdentity normalization), :22-28
//   closed kinds, :65-75 the ORIGINAL 1024-char summary prefix, :106-116
//   batch struct (syncRevision is the original field), :143-172 list
//   request clamps; MemoryReview.swift:3-8/:16-21; MemoryEmbeddings.swift:
//   :48-102 hybrid request/item, :68 query clamp 8000, :75 limit clamp
//   1..20, :159-163 public MemoryContentDigest.make (called directly, never
//   re-implemented).
// * Migrations V7WorkbenchIntelligence.swift:149-161 (memory_entries base
//   columns incl. vestigial sync_revision), V8TaskOwnership.swift:17
//   (conversation_id), V21MemoryLifecycle.swift:10-16 + :21-36 (ownership
//   columns + UNIQUE content indexes), V30MemoryOrganization.swift:7-21
//   (fact-slot columns, memory_maintenance_batches ledger),
//   V13PersonalizationMemory.swift:25-50 (memory_candidates schema).
// * FloeAgent/FloeApp/Memory/MemoryView.swift:92-120 (add dedup +
//   constants), :164-240 quickOrganize orchestration + wall-clock-ms batch
//   ordering, :242-254 automaticDeleteIDs, :256-266 apply deleteIDs
//   derivation — behavior references only; NO SwiftUI import exists here.
//
// Why mirrored SQL: the public native MemoryEntry (IntelligenceStore.swift:
// 10-57) omits normalized_content, the vestigial sync_revision column and
// the seven V21 ownership columns, so the actor result cannot supply the
// 23-column floe.memory-entry.v3 digest. The final contract explicitly
// requires exact narrow SQL mirrors carrying full raw DatabaseValue rows
// with CAS inside the SAME reader/writer transaction (adapters.canonical
// Encoding, deadlockRule). hybridRecall, maintainMemoryLifecycle and
// saveMemory (fresh-id add) are DELEGATED UNMODIFIED as original actor
// calls OUTSIDE any open transaction.
//
// No handler registration, no mailbox code, no capability claim, no
// Package.swift edit. Bind through RB-1 after P0 lands and Main admits
// publication (HANDOFF.md). Swift 6 strict concurrency; NO MainActor
// assumption; NO semaphore/runBlocking anywhere in this file.

import Foundation
import GRDB
import FloeCore
import FloePersistence
import FloeAgentRuntime

// MARK: - Shared internal codecs (consumed by the P3/P4/P8 lane files)

/// DatabaseValue storage-class bridge feeding the accepted P0 encoder
/// (floe.canonical-digest.v1): NULL/int64/double/string/blob raw bytes, no
/// CAST/COALESCE, no date or number formatting.
internal enum FacadeDigestCodec {
    static func field(_ value: DatabaseValue) -> SettingsDomainV1.CanonicalDigest.Field {
        switch value.storage {
        case .null: return .null
        case .int64(let value): return .integer(value)
        case .double(let value): return .real(value)
        case .string(let value): return .text(value)
        case .blob(let value): return .blob(value)
        @unknown default: return .null
        }
    }

    static func field(_ row: Row, _ column: String) -> SettingsDomainV1.CanonicalDigest.Field {
        let value: DatabaseValue = row[column]
        return field(value)
    }
}

/// Wire byte measurement through the SAME JSONSerialization encoder the
/// bridge frame uses (Bridge.swift sortedKeys re-encode): JSONEncoder builds
/// the DTO object tree, JSONSerialization re-encodes it exactly as the wire
/// frame would, and the actual UTF-8 byte count (escape-aware) is returned.
/// Never uses String.count.
internal enum FacadeWireBytes {
    static func encoded<Value: Encodable>(_ value: Value) -> Data? {
        guard let dtoData = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: dtoData),
              JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: object,
                                           options: [.sortedKeys])
    }

    static func count<Value: Encodable>(_ value: Value) -> Int {
        encoded(value)?.count ?? Int.max
    }
}

/// Timestamp write formats matching the ORIGINAL stores exactly:
/// second-precision ISO-8601 (IntelligenceStore.swift:1585 /
/// Personalization.swift:544). These are WRITE values only — never CAS
/// tokens. Tombstone ordering uses wall-clock milliseconds like the original
/// quickOrganize path (MemoryView.swift:224).
internal enum FacadeStoreTime {
    static func second(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func wallClockMillis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }
}

/// Verbatim reproduction of the PRIVATE original stableDigest
/// (IntelligenceStore.swift:1597-1602, FNV-1a radix-16). The contract names
/// this reproduction as required for byte-exact candidate-evidence double
/// digests; the upstream function stays private and unedited.
internal enum FacadeStableDigest {
    static func fnvRadix16(_ value: String) -> String {
        String(value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }, radix: 16)
    }
}

/// Typed async-operation accounting shared by memory.organize.* and
/// personalization.generate.* (asyncAndLifetime.workLifetime): one owner per
/// operation receipt, bounded post-terminal history, honest phases, release
/// ONLY at the real terminal effect. No timers, no durable state; receipts
/// expire with the process (existing v3 rule).
internal final class FacadeAsyncOperationRegistry: @unchecked Sendable {
    enum TerminalOutcome: Sendable, Equatable {
        case canceled(phase: SettingsDomainV1.OperationCancelPhase)
        case completed(phase: SettingsDomainV1.OperationCancelPhase)
    }

    private final class Record: @unchecked Sendable {
        var phase: SettingsDomainV1.OperationCancelPhase
        var cancelRequested = false
        /// True once the final DB commit transaction has STARTED: the
        /// transaction is not interruptible mid-commit, so a late cancel
        /// must answer completed{phase} honestly instead of promising a
        /// cancellation that cannot happen (contract cancel semantics).
        var sealed = false
        var terminal: TerminalOutcome?
        init(phase: SettingsDomainV1.OperationCancelPhase) { self.phase = phase }
    }

    private let lock = NSLock()
    private var active: [String: Record] = [:]
    private var finishedOrder: [String] = []
    private var finished: [String: Record] = [:]
    /// Bound for post-terminal "completed honestly" answers inside the
    /// process. FIFO detach: an evicted receipt later answers
    /// operationReceiptUnknown at the binder — honest, never a fake state.
    static let maximumFinishedReceipts = 128

    func begin(_ receipt: String, phase: SettingsDomainV1.OperationCancelPhase) {
        lock.lock(); defer { lock.unlock() }
        active[receipt] = Record(phase: phase)
    }

    @discardableResult
    func advance(_ receipt: String,
                 phase: SettingsDomainV1.OperationCancelPhase) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let record = active[receipt] else { return false }
        record.phase = phase
        return true
    }

    /// Immediate cancel answer: nil for unknown receipts
    /// (operationReceiptUnknown at the binder), canceled while the operation
    /// still executes, completed with the REAL final phase afterwards.
    func requestCancel(_ receipt: String) -> SettingsDomainV1.OperationCancelReply? {
        lock.lock(); defer { lock.unlock() }
        if let record = active[receipt] {
            if record.sealed {
                // Commit transaction already started: no cancellation
                // window remains; the terminal effect will report the real
                // active-or-draft / applied outcome.
                return SettingsDomainV1.OperationCancelReply(status: .completed,
                                                             phase: record.phase)
            }
            record.cancelRequested = true
            return SettingsDomainV1.OperationCancelReply(status: .canceled,
                                                         phase: record.phase)
        }
        if let record = finished[receipt], let terminal = record.terminal {
            switch terminal {
            case .canceled(let phase):
                return SettingsDomainV1.OperationCancelReply(status: .canceled,
                                                             phase: phase)
            case .completed(let phase):
                return SettingsDomainV1.OperationCancelReply(status: .completed,
                                                             phase: phase)
            }
        }
        return nil
    }

    /// Seal the cooperative cancellation window (final commit beginning).
    func seal(_ receipt: String) {
        lock.lock(); defer { lock.unlock() }
        active[receipt]?.sealed = true
    }

    /// THE irreversible boundary of an async generation commit, in ONE lock
    /// acquisition, invoked as the FIRST statement of the ACTUAL Database
    /// writer closure (MEM-GEN-C1 / Main writer-admission review). Either a
    /// cancel that already won is refused here — the writer body must then
    /// throw BEFORE any mutation and the recorded phase stays `streaming` so
    /// `canceled{streaming}` remains inside the frozen reply grammar — or the
    /// window is sealed AND the phase advances to `committing` atomically,
    /// after which a late cancel answers `completed{committing}` and the real
    /// committed/draft outcome follows. Calling this BEFORE the writer handoff
    /// (or as a separate check-then-seal pair) would already refuse a cancel
    /// while the generation is merely QUEUED behind another writer.
    func beginCommit(_ receipt: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let record = active[receipt] else { return }
        if record.cancelRequested { throw OperationCanceled() }
        record.sealed = true
        record.phase = .committing
    }

    func cancelRequested(_ receipt: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active[receipt]?.cancelRequested ?? false
    }

    /// Caller-cancellation bridge for an OWNED operation task. Cancelling the
    /// Task that called the public entry does NOT propagate into an
    /// unstructured `Task`, so the entry forwards it through the SAME
    /// accepted/unsealed decision an explicit cancel uses: while the
    /// operation is still inside the cooperative window it marks the exact
    /// `cancelRequested` flag (making a queued `beginCommit` refuse with zero
    /// writes and `acceptedCancelPhase` normalize a handoff
    /// `CancellationError`) and returns true. Once the actual writer closure
    /// has sealed the boundary it returns false and changes nothing, so the
    /// child runs to its real committed/draft terminal. This is a bridge to
    /// existing state only; it creates no status, command or effect.
    func bridgeCallerCancellation(_ receipt: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let record = active[receipt], !record.sealed else { return false }
        record.cancelRequested = true
        return true
    }

    /// The phase to report for an ACCEPTED (not yet sealed) cancel, or nil
    /// when there is no live accepted cancel. Used to normalize an owned
    /// task's CancellationError (the real DB handoff may observe task
    /// cancellation before its closure body begins) into the SAME frozen
    /// `canceled{phase}` grammar as a check inside the stream/writer.
    func acceptedCancelPhase(_ receipt: String) -> SettingsDomainV1.OperationCancelPhase? {
        lock.lock(); defer { lock.unlock() }
        guard let record = active[receipt], record.cancelRequested,
              !record.sealed else { return nil }
        return record.phase
    }

    /// The CURRENT recorded phase (active or final) for honest terminal
    /// accounting and late-cancel answers.
    func phase(of receipt: String) -> SettingsDomainV1.OperationCancelPhase? {
        lock.lock(); defer { lock.unlock() }
        if let record = active[receipt] { return record.phase }
        if let record = finished[receipt] { return record.phase }
        return nil
    }

    func finish(_ receipt: String, outcome: TerminalOutcome) {
        lock.lock(); defer { lock.unlock() }
        let record: Record
        if let existing = active.removeValue(forKey: receipt) {
            record = existing
        } else {
            record = Record(phase: .committed)
        }
        record.terminal = outcome
        finished[receipt] = record
        finishedOrder.append(receipt)
        while finishedOrder.count > Self.maximumFinishedReceipts {
            let oldest = finishedOrder.removeFirst()
            finished.removeValue(forKey: oldest)
        }
    }

    /// Drops an active record WITHOUT a terminal outcome. Used ONLY when an
    /// operation really failed BEFORE its irreversible writer boundary: the
    /// closed cancel-reply grammar has no `failed` status, and answering
    /// `completed{streaming}` (or fabricating `committed`) would misstate
    /// the real outcome. A later cancel for this receipt answers
    /// `operationReceiptUnknown` — the honest "no live cancel window any
    /// more" answer, mapped by the binder; the failure effect itself already
    /// reported the real typed error.
    func discard(_ receipt: String) {
        lock.lock(); defer { lock.unlock() }
        active.removeValue(forKey: receipt)
        finished.removeValue(forKey: receipt)
        finishedOrder.removeAll { $0 == receipt }
    }

    struct OperationCanceled: Error {}

    /// Cooperative safe point between transactions / around stream
    /// boundaries. NEVER called inside a Database closure.
    func cancellationPoint(_ receipt: String) throws {
        lock.lock(); defer { lock.unlock() }
        if active[receipt]?.cancelRequested == true {
            throw OperationCanceled()
        }
    }
}

// MARK: - Error vocabulary

/// Typed failures of the memory adapter/organizer. Wire codes REUSE the
/// accepted vocabulary only (wireConventions.errorVocabulary); per-command
/// reason strings come from the final contract. Errors never carry secret
/// row content (contract: no secret content in errors).
public enum MemoryAdapterError: Error, Sendable, Equatable {
    case invalidEnvelope(String)
    case notFound(String)
    /// notFound{reason: memoryMissing, missingIDs:[…]} (bulk vector).
    case notFoundMissing(reason: String, ids: [UUID])
    case staleRevision(staleIDs: [UUID], missingIDs: [UUID])
    case payloadTooLarge(maxChars: Int)
    case persistenceUnavailable(String?)

    public var wireCode: String {
        switch self {
        case .invalidEnvelope: return "invalidEnvelope"
        case .notFound, .notFoundMissing: return "notFound"
        case .staleRevision: return "staleRevision"
        case .payloadTooLarge: return "payloadTooLarge"
        case .persistenceUnavailable: return "persistenceUnavailable"
        }
    }

    public var wireReason: String? {
        switch self {
        case .invalidEnvelope(let reason), .notFound(let reason),
             .notFoundMissing(let reason, _):
            return reason
        case .staleRevision:
            return nil
        case .payloadTooLarge(let maxChars):
            return "maxChars:\(maxChars)"
        case .persistenceUnavailable(let reason):
            return reason
        }
    }

    /// Real id lists for staleRevision{staleIDs|missingIDs} and
    /// notFound{missingIDs} vectors; ids only (uuid strings), never content.
    public var wireDetailArrays: [String: [String]] {
        switch self {
        case .staleRevision(let staleIDs, let missingIDs):
            var detail: [String: [String]] = [:]
            if !staleIDs.isEmpty { detail["staleIDs"] = staleIDs.map(\.uuidString) }
            if !missingIDs.isEmpty { detail["missingIDs"] = missingIDs.map(\.uuidString) }
            return detail
        case .notFoundMissing(_, let ids):
            return ids.isEmpty ? [:] : ["missingIDs": ids.map(\.uuidString)]
        default:
            return [:]
        }
    }
}

// MARK: - Closed-grammar primitives

/// Defensive typed parsing mirroring the P0 validator grammar exactly, so a
/// direct caller can never widen a payload past what
/// `SettingsDomainV1.validate` accepted (same pattern as the accepted P1
/// `SettingsDefaultsPatch.parse`).
public enum WireMemorySupport {
    static func string(_ value: SettingsDomainV1.JSONValue, _ field: String) throws -> String {
        guard case .string(let raw) = value else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:\(field)")
        }
        return raw
    }

    static func uuid(_ value: SettingsDomainV1.JSONValue, _ field: String) throws -> UUID {
        guard case .string(let raw) = value, let uuid = UUID(uuidString: raw),
              uuid != BridgeV3.nilUUID else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:\(field)")
        }
        return uuid
    }

    static func integer(_ value: SettingsDomainV1.JSONValue, _ field: String) throws -> Int64 {
        guard case .integer(let raw) = value else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:\(field)")
        }
        return raw
    }

    static func boolean(_ value: SettingsDomainV1.JSONValue, _ field: String) throws -> Bool {
        guard case .boolean(let raw) = value else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:\(field)")
        }
        return raw
    }

    static func unitInterval(_ value: SettingsDomainV1.JSONValue, _ field: String) throws -> Double {
        let number: Double
        switch value {
        case .integer(let raw): number = Double(raw)
        case .fractional(let raw): number = raw
        default:
            throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:\(field)")
        }
        guard number.isFinite, (0...1).contains(number) else {
            throw MemoryAdapterError.invalidEnvelope("payloadFieldOutOfRange:\(field)")
        }
        return number
    }

    static func enumValue<T: RawRepresentable & Equatable>(_ value: SettingsDomainV1.JSONValue,
                                                           _ field: String,
                                                           _ type: T.Type) throws -> T
        where T.RawValue == String {
        guard case .string(let raw) = value, let typed = T(rawValue: raw) else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:\(field)")
        }
        return typed
    }

    static func digest(_ value: SettingsDomainV1.JSONValue, _ field: String) throws -> String {
        guard case .string(let raw) = value, raw.hasPrefix("sha256:"),
              raw.count == 71, raw.dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:\(field)")
        }
        return raw
    }

    static func iso8601(_ value: SettingsDomainV1.JSONValue, _ field: String) throws -> String {
        let raw = try string(value, field)
        guard raw.count >= 20, raw.count <= 64 else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:\(field)")
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard fractional.date(from: raw) != nil || plain.date(from: raw) != nil else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:\(field)")
        }
        return raw
    }

    static func cursor(_ value: SettingsDomainV1.JSONValue) throws -> Int {
        guard case .string(let raw) = value, !raw.isEmpty, raw.count <= 18,
              raw.allSatisfy({ $0.isNumber }), let offset = Int(raw),
              offset >= 0 else {
            throw MemoryAdapterError.invalidEnvelope("invalidCursor")
        }
        return offset
    }

    static func factIdentity(_ value: SettingsDomainV1.JSONValue) throws
        -> SettingsDomainV1.FactIdentity
    {
        guard case .object(let object) = value else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:factIdentity")
        }
        for key in object.keys where key != "subjectKey" && key != "attributeKey" {
            throw MemoryAdapterError.invalidEnvelope("unknownMemoryField")
        }
        guard let subject = object["subjectKey"], let attribute = object["attributeKey"] else {
            throw MemoryAdapterError.invalidEnvelope("missingPayloadField:factIdentity")
        }
        let subjectKey = try string(subject, "subjectKey")
        let attributeKey = try string(attribute, "attributeKey")
        guard !subjectKey.isEmpty, !attributeKey.isEmpty,
              subjectKey.count <= SettingsDomainV1.maximumFactIdentityCharacters,
              attributeKey.count <= SettingsDomainV1.maximumFactIdentityCharacters else {
            throw MemoryAdapterError.invalidEnvelope("payloadFieldTooLong:factIdentity")
        }
        return SettingsDomainV1.FactIdentity(subjectKey: subjectKey,
                                             attributeKey: attributeKey)
    }

    static func scope(_ value: SettingsDomainV1.JSONValue) throws
        -> SettingsDomainV1.MemoryScope
    {
        guard case .object(let object) = value else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:scope")
        }
        for key in object.keys where !["kind", "workspaceID", "conversationID"]
            .contains(key) {
            throw MemoryAdapterError.invalidEnvelope("unknownMemoryField")
        }
        guard let kindValue = object["kind"] else {
            throw MemoryAdapterError.invalidEnvelope("missingPayloadField:scope.kind")
        }
        let kind = try enumValue(kindValue, "scope.kind",
                                 SettingsDomainV1.MemoryScopeKind.self)
        var workspaceID: UUID?
        if let raw = object["workspaceID"], !isJSONNull(raw) {
            workspaceID = try uuid(raw, "workspaceID")
        }
        var conversationID: UUID?
        if let raw = object["conversationID"], !isJSONNull(raw) {
            conversationID = try uuid(raw, "conversationID")
        }
        do {
            return try SettingsDomainV1.MemoryScope(kind: kind,
                                                    workspaceID: workspaceID,
                                                    conversationID: conversationID)
        } catch {
            throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:scope")
        }
    }

    static func isJSONNull(_ value: SettingsDomainV1.JSONValue) -> Bool {
        if case .null = value { return true }
        return false
    }

    /// The ORIGINAL secret markers (IntelligenceStore.swift:1591-1596) and
    /// the P0 validator list, byte-equal: lowercased containment. This guard
    /// protects memory CONTENT; it is never a tool-permission mechanism
    /// (task trust boundary; original secrecy guard semantics).
    public static func containsSecretLikeMarker(_ content: String) -> Bool {
        let lower = content.lowercased()
        return [
            "api_key=", "apikey=", "authorization: bearer", "-----begin private key",
            "password:", "password=", "access_token", "refresh_token",
        ].contains { lower.contains($0) }
    }
}

// MARK: - Typed request decoders

/// memory.list payload (P0 validateMemoryList grammar).
public struct MemoryListWireRequest: Sendable, Equatable {
    public var scope: SettingsDomainV1.MemoryScope?
    public var status: SettingsDomainV1.MemoryEntryStatus?
    public var originConversationID: UUID?
    public var originWorkspaceID: UUID?
    public var factIdentity: SettingsDomainV1.FactIdentity?
    public var isPinned: Bool?
    public var cursor: Int
    public var limit: Int

    /// Wire default 50 (original MemoryListRequest default 100 remains a
    /// documented wire choice; clamp 1..500 stays original).
    public static let defaultLimit = 50

    public init(scope: SettingsDomainV1.MemoryScope? = nil,
                status: SettingsDomainV1.MemoryEntryStatus? = nil,
                originConversationID: UUID? = nil, originWorkspaceID: UUID? = nil,
                factIdentity: SettingsDomainV1.FactIdentity? = nil,
                isPinned: Bool? = nil, cursor: Int = 0,
                limit: Int = defaultLimit) {
        self.scope = scope
        self.status = status
        self.originConversationID = originConversationID
        self.originWorkspaceID = originWorkspaceID
        self.factIdentity = factIdentity
        self.isPinned = isPinned
        self.cursor = cursor
        self.limit = limit
    }

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> MemoryListWireRequest
    {
        var request = MemoryListWireRequest()
        guard let payload else { return request }
        guard case .object(let root) = payload else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayload")
        }
        for key in root.keys where !["scope", "status", "originConversationID",
                                     "originWorkspaceID", "factIdentity",
                                     "isPinned", "cursor", "limit"].contains(key) {
            throw MemoryAdapterError.invalidEnvelope("unknownMemoryField")
        }
        if let value = root["scope"], !WireMemorySupport.isJSONNull(value) {
            request.scope = try WireMemorySupport.scope(value)
        }
        if let value = root["status"], !WireMemorySupport.isJSONNull(value) {
            request.status = try WireMemorySupport.enumValue(value, "status",
                                                             SettingsDomainV1.MemoryEntryStatus.self)
        }
        if let value = root["originConversationID"], !WireMemorySupport.isJSONNull(value) {
            request.originConversationID = try WireMemorySupport.uuid(value, "originConversationID")
        }
        if let value = root["originWorkspaceID"], !WireMemorySupport.isJSONNull(value) {
            request.originWorkspaceID = try WireMemorySupport.uuid(value, "originWorkspaceID")
        }
        if let value = root["factIdentity"], !WireMemorySupport.isJSONNull(value) {
            request.factIdentity = try WireMemorySupport.factIdentity(value)
        }
        if let value = root["isPinned"], !WireMemorySupport.isJSONNull(value) {
            request.isPinned = try WireMemorySupport.boolean(value, "isPinned")
        }
        if let value = root["cursor"] {
            request.cursor = try WireMemorySupport.cursor(value)
        }
        if let value = root["limit"] {
            let raw = try WireMemorySupport.integer(value, "limit")
            guard raw >= 1, raw <= Int64(SettingsDomainV1.maximumMemoryPage) else {
                throw MemoryAdapterError.invalidEnvelope("payloadFieldOutOfRange:limit")
            }
            request.limit = Int(raw)
        }
        return request
    }
}

/// memory.add payload.
public struct MemoryAddRequest: Sendable, Equatable {
    public var content: String
    public var scope: SettingsDomainV1.MemoryScope
    public var originConversationID: UUID?
    public var originWorkspaceID: UUID?

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> MemoryAddRequest
    {
        guard case .object(let root)? = payload else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayload")
        }
        for key in root.keys where !["content", "scope", "originConversationID",
                                     "originWorkspaceID"].contains(key) {
            throw MemoryAdapterError.invalidEnvelope("unknownMemoryField")
        }
        guard let contentValue = root["content"], let scopeValue = root["scope"] else {
            throw MemoryAdapterError.invalidEnvelope("missingPayloadField:content")
        }
        guard case .string(let content) = contentValue else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:content")
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryAdapterError.invalidEnvelope("memoryRejected:empty")
        }
        guard content.count <= SettingsDomainV1.maximumMemoryContentCharacters else {
            throw MemoryAdapterError.payloadTooLarge(
                maxChars: SettingsDomainV1.maximumMemoryContentCharacters)
        }
        guard !WireMemorySupport.containsSecretLikeMarker(content) else {
            throw MemoryAdapterError.invalidEnvelope("memoryRejected:secretLike")
        }
        var originConversationID: UUID?
        if let value = root["originConversationID"], !WireMemorySupport.isJSONNull(value) {
            originConversationID = try WireMemorySupport.uuid(value, "originConversationID")
        }
        var originWorkspaceID: UUID?
        if let value = root["originWorkspaceID"], !WireMemorySupport.isJSONNull(value) {
            originWorkspaceID = try WireMemorySupport.uuid(value, "originWorkspaceID")
        }
        return MemoryAddRequest(content: content,
                                scope: try WireMemorySupport.scope(scopeValue),
                                originConversationID: originConversationID,
                                originWorkspaceID: originWorkspaceID)
    }
}

/// memory.update closed changeset (status subset active|superseded per Q2).
public struct MemoryUpdateRequest: Sendable, Equatable {
    public enum ExpiresChange: Sendable, Equatable {
        case keepStored
        case clear
        case set(iso8601: String)
    }
    public enum FactChange: Sendable, Equatable {
        case keepStored
        case clear
        case set(SettingsDomainV1.FactIdentity)
    }
    public var id: UUID
    public var content: String?
    public var importance: Double?
    public var isPinned: Bool?
    public var status: SettingsDomainV1.MemoryUpdateStatus?
    public var expires: ExpiresChange
    public var fact: FactChange

    public init(id: UUID, content: String? = nil, importance: Double? = nil,
                isPinned: Bool? = nil,
                status: SettingsDomainV1.MemoryUpdateStatus? = nil,
                expires: ExpiresChange = .keepStored,
                fact: FactChange = .keepStored) {
        self.id = id
        self.content = content
        self.importance = importance
        self.isPinned = isPinned
        self.status = status
        self.expires = expires
        self.fact = fact
    }

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> MemoryUpdateRequest
    {
        guard case .object(let root)? = payload else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayload")
        }
        guard let idValue = root["id"], let changesValue = root["changes"] else {
            throw MemoryAdapterError.invalidEnvelope("missingPayloadField:changes")
        }
        let id = try WireMemorySupport.uuid(idValue, "id")
        guard case .object(let changes) = changesValue, !changes.isEmpty else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:changes")
        }
        for key in changes.keys where !["content", "importance", "isPinned",
                                       "status", "expiresAt", "factIdentity"]
            .contains(key) {
            throw MemoryAdapterError.invalidEnvelope("unknownMemoryField")
        }
        var request = MemoryUpdateRequest(id: id)
        if let value = changes["content"] {
            guard case .string(let raw) = value,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MemoryAdapterError.invalidEnvelope("memoryRejected:empty")
            }
            guard raw.count <= SettingsDomainV1.maximumMemoryContentCharacters else {
                throw MemoryAdapterError.payloadTooLarge(
                    maxChars: SettingsDomainV1.maximumMemoryContentCharacters)
            }
            guard !WireMemorySupport.containsSecretLikeMarker(raw) else {
                throw MemoryAdapterError.invalidEnvelope("memoryRejected:secretLike")
            }
            request.content = raw
        }
        if let value = changes["importance"] {
            request.importance = try WireMemorySupport.unitInterval(value, "importance")
        }
        if let value = changes["isPinned"] {
            request.isPinned = try WireMemorySupport.boolean(value, "isPinned")
        }
        if let value = changes["status"] {
            request.status = try WireMemorySupport.enumValue(value, "status",
                                                             SettingsDomainV1.MemoryUpdateStatus.self)
        }
        if let value = changes["expiresAt"] {
            if WireMemorySupport.isJSONNull(value) {
                request.expires = .clear
            } else {
                request.expires = .set(iso8601: try WireMemorySupport.iso8601(value, "expiresAt"))
            }
        }
        if let value = changes["factIdentity"] {
            if WireMemorySupport.isJSONNull(value) {
                request.fact = .clear
            } else {
                request.fact = .set(try WireMemorySupport.factIdentity(value))
            }
        }
        return request
    }
}

/// memory.delete.bulk payload (create-intent batch ledger identity is the
/// client-proposed batchID; syncRevision is the original ordering field).
public struct MemoryBulkDeleteRequest: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let id: UUID
        public let expectedDigest: String
    }
    public var batchID: UUID
    public var items: [Item]
    /// Original MemoryMaintenanceBatch.syncRevision (MemoryMaintenance.swift:
    /// 106-114): tombstone ordering value ONLY, NEVER a CAS precondition.
    public var syncRevision: Int64

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> MemoryBulkDeleteRequest
    {
        guard case .object(let root)? = payload else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayload")
        }
        guard let batchValue = root["batchID"], let entriesValue = root["entries"],
              let syncValue = root["syncRevision"] else {
            throw MemoryAdapterError.invalidEnvelope("missingPayloadField:entries")
        }
        let batchID = try WireMemorySupport.uuid(batchValue, "batchID")
        let sync = try WireMemorySupport.integer(syncValue, "syncRevision")
        guard case .array(let entries) = entriesValue, !entries.isEmpty else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:entries")
        }
        guard entries.count <= SettingsDomainV1.maximumBulkEntries else {
            throw MemoryAdapterError.invalidEnvelope("bulkLimitExceeded")
        }
        var items: [Item] = []
        var seen: Set<UUID> = []
        for entry in entries {
            guard case .object(let object) = entry,
                  let idValue = object["id"], let digestValue = object["expectedDigest"] else {
                throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:entries")
            }
            for key in object.keys where key != "id" && key != "expectedDigest" {
                throw MemoryAdapterError.invalidEnvelope("unknownMemoryField")
            }
            let id = try WireMemorySupport.uuid(idValue, "entries.id")
            guard seen.insert(id).inserted else {
                throw MemoryAdapterError.invalidEnvelope("duplicateBatchEntry")
            }
            let digest = try WireMemorySupport.digest(digestValue, "entries.expectedDigest")
            items.append(Item(id: id, expectedDigest: digest))
        }
        return MemoryBulkDeleteRequest(batchID: batchID, items: items,
                                       syncRevision: sync)
    }
}

/// memory.search payload.
public struct MemorySearchWireRequest: Sendable, Equatable {
    public var query: String
    public var workspaceID: UUID?
    public var conversationID: UUID?
    public var limit: Int
    public var handle: String?
    public var cursor: Int

    /// Native UI parity: MemoryView.search uses limit 20.
    public static let defaultLimit = SettingsDomainV1.maximumSearchItems

    /// Direct-construction defaults equal the wire parse defaults (fresh
    /// query: no handle, cursor 0, native limit); the adapter still rejects
    /// a cursor without a handle exactly like `parse`.
    public init(query: String, workspaceID: UUID? = nil,
                conversationID: UUID? = nil, limit: Int = defaultLimit,
                handle: String? = nil, cursor: Int = 0) {
        self.query = query
        self.workspaceID = workspaceID
        self.conversationID = conversationID
        self.limit = limit
        self.handle = handle
        self.cursor = cursor
    }

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> MemorySearchWireRequest
    {
        guard case .object(let root)? = payload,
              let queryValue = root["query"], case .string(let query) = queryValue else {
            throw MemoryAdapterError.invalidEnvelope("missingPayloadField:query")
        }
        guard query.count <= SettingsDomainV1.maximumSearchQueryCharacters else {
            throw MemoryAdapterError.invalidEnvelope("payloadFieldTooLong:query")
        }
        var request = MemorySearchWireRequest(query: query, workspaceID: nil,
                                              conversationID: nil,
                                              limit: defaultLimit, handle: nil,
                                              cursor: 0)
        if let value = root["workspaceID"], !WireMemorySupport.isJSONNull(value) {
            request.workspaceID = try WireMemorySupport.uuid(value, "workspaceID")
        }
        if let value = root["conversationID"], !WireMemorySupport.isJSONNull(value) {
            request.conversationID = try WireMemorySupport.uuid(value, "conversationID")
        }
        if let value = root["limit"] {
            let raw = try WireMemorySupport.integer(value, "limit")
            guard raw >= 1, raw <= Int64(SettingsDomainV1.maximumSearchItems) else {
                throw MemoryAdapterError.invalidEnvelope("payloadFieldOutOfRange:limit")
            }
            request.limit = Int(raw)
        }
        if let value = root["handle"] {
            guard case .string(let handle) = value, !handle.isEmpty,
                  handle.count <= SettingsDomainV1.maximumMemorySearchHandleCharacters else {
                throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:handle")
            }
            request.handle = handle
        }
        if let value = root["cursor"] {
            request.cursor = try WireMemorySupport.cursor(value)
            guard request.handle != nil else {
                throw MemoryAdapterError.invalidEnvelope("invalidCursor")
            }
        }
        return request
    }
}

/// memory.candidates.list payload.
public struct MemoryCandidatesListRequest: Sendable, Equatable {
    public var status: SettingsDomainV1.CandidateStatus?
    public var cursor: Int
    public var limit: Int

    public static let defaultLimit = 50

    /// Defaults equal `parse` (pending sweep when status nil, offset 0,
    /// bounded page 50).
    public init(status: SettingsDomainV1.CandidateStatus? = nil,
                cursor: Int = 0, limit: Int = defaultLimit) {
        self.status = status
        self.cursor = cursor
        self.limit = limit
    }

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> MemoryCandidatesListRequest
    {
        var request = MemoryCandidatesListRequest(status: nil, cursor: 0,
                                                  limit: defaultLimit)
        guard let payload else { return request }
        guard case .object(let root) = payload else {
            throw MemoryAdapterError.invalidEnvelope("invalidPayload")
        }
        for key in root.keys where !["status", "cursor", "limit"].contains(key) {
            throw MemoryAdapterError.invalidEnvelope("unknownMemoryField")
        }
        if let value = root["status"] {
            request.status = try WireMemorySupport.enumValue(value, "status",
                                                             SettingsDomainV1.CandidateStatus.self)
        }
        if let value = root["cursor"] {
            request.cursor = try WireMemorySupport.cursor(value)
        }
        if let value = root["limit"] {
            let raw = try WireMemorySupport.integer(value, "limit")
            guard raw >= 1, raw <= Int64(SettingsDomainV1.maximumCandidatePage) else {
                throw MemoryAdapterError.invalidEnvelope("payloadFieldOutOfRange:limit")
            }
            request.limit = Int(raw)
        }
        return request
    }
}

/// memory.organize.proposal.read payload.
public struct MemoryProposalReadRequest: Sendable, Equatable {
    public var handle: String
    public var cursor: Int
    public var limit: Int

    public static let defaultLimit = 50

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> MemoryProposalReadRequest
    {
        guard case .object(let root)? = payload,
              let handleValue = root["handle"], case .string(let handle) = handleValue,
              !handle.isEmpty,
              handle.count <= SettingsDomainV1.maximumHandleCharacters else {
            throw MemoryAdapterError.invalidEnvelope("missingPayloadField:handle")
        }
        var request = MemoryProposalReadRequest(handle: handle, cursor: 0,
                                                limit: defaultLimit)
        if let value = root["cursor"] {
            request.cursor = try WireMemorySupport.cursor(value)
        }
        if let value = root["limit"] {
            let raw = try WireMemorySupport.integer(value, "limit")
            guard raw >= 1,
                  raw <= Int64(SettingsDomainV1.maximumOrganizeProposalPage) else {
                throw MemoryAdapterError.invalidEnvelope("payloadFieldOutOfRange:limit")
            }
            request.limit = Int(raw)
        }
        return request
    }
}

/// memory.organize.apply payload.
public struct MemoryOrganizeApplyRequest: Sendable, Equatable {
    public var handle: String
    public var suggestionID: UUID
    public var batchID: UUID
    public var syncRevision: Int64

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> MemoryOrganizeApplyRequest
    {
        guard case .object(let root)? = payload,
              let handleValue = root["handle"], case .string(let handle) = handleValue,
              !handle.isEmpty,
              handle.count <= SettingsDomainV1.maximumHandleCharacters,
              let suggestionValue = root["suggestionID"],
              let batchValue = root["batchID"],
              let syncValue = root["syncRevision"] else {
            throw MemoryAdapterError.invalidEnvelope("missingPayloadField:handle")
        }
        return MemoryOrganizeApplyRequest(
            handle: handle,
            suggestionID: try WireMemorySupport.uuid(suggestionValue, "suggestionID"),
            batchID: try WireMemorySupport.uuid(batchValue, "batchID"),
            syncRevision: try WireMemorySupport.integer(syncValue, "syncRevision")
        )
    }
}

// MARK: - memory_entries schema codecs

/// One raw memory row captured INSIDE a transaction: the 23 non-id
/// DatabaseValue fields in declared schema order (V7 base order, then V8
/// conversation_id, V21 ownership block, V30 fact slots — the exact order
/// the contract's floe.memory-entry.v3 domain enumerates), plus the id and
/// the raw TEXT/BLOB storage values needed for projections.
internal struct FacadeMemoryRawRow: Sendable {
    let id: String
    let fields: [SettingsDomainV1.CanonicalDigest.Field]
    /// Raw stored text per non-id TEXT column (nil DatabaseValue for NULL;
    /// non-TEXT storage recorded separately below).
    let text: [String: String?]
    let scopeName: String
    let statusRaw: String
    let sourceKindRaw: String
    let isPinnedInteger: Int64
    let confidence: Double
    let importance: Double
    let recallCount: Int64

    static let nonIDColumns: [String] = [
        "scope", "workspace_id", "status", "content", "normalized_content",
        "confidence", "importance", "is_pinned", "source_kind", "expires_at",
        "sync_revision", "created_at", "updated_at", "conversation_id",
        "origin_workspace_id", "origin_conversation_id", "origin_owner_label",
        "owner_deleted_at", "last_recalled_at", "retained_until",
        "recall_count", "subject_key", "attribute_key",
    ]

    init(_ row: Row) {
        let idValue: String = row["id"]
        self.id = idValue
        self.fields = Self.nonIDColumns.map { FacadeDigestCodec.field(row, $0) }
        var text: [String: String?] = [:]
        for column in Self.nonIDColumns {
            let value: DatabaseValue = row[column]
            if case .string(let raw) = value.storage {
                text[column] = raw
            } else {
                text[column] = nil
            }
        }
        self.text = text
        self.scopeName = (text["scope"] ?? nil) ?? ""
        self.statusRaw = (text["status"] ?? nil) ?? ""
        self.sourceKindRaw = (text["source_kind"] ?? nil) ?? ""
        let pinned: DatabaseValue = row["is_pinned"]
        if case .int64(let raw) = pinned.storage { self.isPinnedInteger = raw }
        else { self.isPinnedInteger = 0 }
        let confidenceValue: Double = row["confidence"]
        self.confidence = confidenceValue
        let importanceValue: Double = row["importance"]
        self.importance = importanceValue
        let recall: DatabaseValue = row["recall_count"]
        if case .int64(let raw) = recall.storage { self.recallCount = raw }
        else { self.recallCount = 0 }
    }

    var digest: String {
        SettingsDomainV1.CanonicalDigest.rowToken(
            domain: SettingsDomainV1.CanonicalDigest.domainMemoryEntry,
            fields: fields)
    }

    func string(_ column: String) -> String? { text[column] ?? nil }
}

/// Raw row → wire MemoryEntry DTO. Timestamps pass through as the RAW
/// stored text (never re-formatted); closed enums fail typed on corruption;
/// the scope projection follows the original Self.memory(row) owner-fallback
/// semantics (IntelligenceStore.swift:1345-1375) so the wire never silently
/// re-writes ownership — the CAS digest always covers the true raw bytes.
internal enum FacadeMemoryRowCodec {
    static func entry(from row: FacadeMemoryRawRow, digest: String) throws
        -> SettingsDomainV1.MemoryEntry
    {
        guard let uuid = UUID(uuidString: row.id) else {
            throw MemoryAdapterError.persistenceUnavailable("corruptMemoryRow")
        }
        let corrupt = MemoryAdapterError
            .persistenceUnavailable("corruptMemoryRow:\(uuid.uuidString)")
        guard let wireStatus = SettingsDomainV1.MemoryEntryStatus(rawValue: row.statusRaw),
              let wireSource = SettingsDomainV1.MemorySourceKind(rawValue: row.sourceKindRaw),
              let content = row.string("content") else {
            throw corrupt
        }
        let workspace = row.string("workspace_id")
        let conversation = row.string("conversation_id")
        let originWorkspace = row.string("origin_workspace_id")
        let originConversation = row.string("origin_conversation_id")
        let scope: SettingsDomainV1.MemoryScope
        switch row.scopeName {
        case "user":
            scope = try SettingsDomainV1.MemoryScope(kind: .user)
        case "agent":
            scope = try SettingsDomainV1.MemoryScope(kind: .agent)
        case "workspace":
            if let owner = workspace ?? originWorkspace, let id = UUID(uuidString: owner) {
                guard let typed = try? SettingsDomainV1.MemoryScope(kind: .workspace,
                                                                    workspaceID: id) else {
                    throw corrupt
                }
                scope = typed
            } else {
                // ORIGINAL projection parity (:1360-1362): an ownerless
                // workspace row decodes as agentGlobal in the native DTO.
                scope = try SettingsDomainV1.MemoryScope(kind: .agent)
            }
        case "task":
            if let owner = conversation ?? originConversation, let id = UUID(uuidString: owner) {
                guard let typed = try? SettingsDomainV1.MemoryScope(kind: .task,
                                                                    conversationID: id) else {
                    throw corrupt
                }
                scope = typed
            } else {
                scope = try SettingsDomainV1.MemoryScope(kind: .agent)
            }
        default:
            throw corrupt
        }
        var factIdentity: SettingsDomainV1.FactIdentity?
        if let subject = row.string("subject_key"), let attribute = row.string("attribute_key") {
            factIdentity = SettingsDomainV1.FactIdentity(subjectKey: subject,
                                                         attributeKey: attribute)
        }
        let ownership = SettingsDomainV1.Ownership(
            ownerDeletedAt: row.string("owner_deleted_at"),
            retainedUntil: row.string("retained_until"),
            originOwnerLabel: row.string("origin_owner_label"),
            lastRecalledAt: row.string("last_recalled_at"),
            recallCount: Int(row.recallCount)
        )
        return SettingsDomainV1.MemoryEntry(
            id: uuid,
            scope: scope,
            status: wireStatus,
            content: content,
            confidence: row.confidence,
            importance: row.importance,
            isPinned: row.isPinnedInteger != 0,
            sourceKind: wireSource,
            originConversationID: originConversation.flatMap(UUID.init(uuidString:)),
            originWorkspaceID: originWorkspace.flatMap(UUID.init(uuidString:)),
            factIdentity: factIdentity,
            ownership: ownership,
            expiresAt: row.string("expires_at"),
            createdAt: row.string("created_at") ?? "",
            updatedAt: row.string("updated_at") ?? "",
            revision: digest
        )
    }

    /// Budget-stopped page assembly over raw rows. Entries are ATOMIC: the
    /// reply grows row by row and stops BEFORE the row whose inclusion would
    /// push the complete encoded reply (actual UTF-8 bytes, escaping
    /// included) past the 48 KiB page budget. The returned cursor advances
    /// by the rows ACCEPTED, so continuation never re-reads or silently
    /// drops a row (contract paging: cursorprogress/no silent truncation).
    /// `probeHasMore` is the original n+1 probe result.
    static func pagedReply(rows: [FacadeMemoryRawRow],
                           startCursor: Int,
                           probeHasMore: Bool) throws
        -> SettingsDomainV1.MemoryListReply
    {
        var entries: [SettingsDomainV1.MemoryEntry] = []
        var accepted = 0
        for raw in rows {
            let entry = try entry(from: raw, digest: raw.digest)
            let candidate = entries + [entry]
            let moreToCome = (accepted + 1 < rows.count) || probeHasMore
            let trial = SettingsDomainV1.MemoryListReply(
                entries: candidate,
                nextCursor: moreToCome ? String(startCursor + accepted + 1) : nil)
            guard FacadeWireBytes.count(trial) <= SettingsDomainV1.pageBudgetBytes else {
                break
            }
            entries = candidate
            accepted += 1
        }
        let remaining = rows.count - accepted
        let hasMore = remaining > 0 || probeHasMore
        let nextCursor: String?
        if hasMore, accepted > 0 {
            nextCursor = String(startCursor + accepted)
        } else if hasMore, accepted == 0 {
            // Not even the FIRST row fits: a single ≤4096-char entry larger
            // than the whole page budget is a pathological store state.
            // Fail typed — rows are atomic; nothing is truncated or skipped.
            throw MemoryAdapterError.persistenceUnavailable("pageItemOverBudget")
        } else {
            nextCursor = nil
        }
        return SettingsDomainV1.MemoryListReply(entries: entries,
                                                nextCursor: nextCursor)
    }
}

// MARK: - memory_candidates schema codec

/// One raw candidate row: the 18 non-id DatabaseValue fields in declared
/// schema order (V13PersonalizationMemory.swift:25-46 — the exact order the
/// contract's floe.memory-candidate.v1 domain enumerates).
internal struct FacadeCandidateRawRow: Sendable {
    let id: String
    let fields: [SettingsDomainV1.CanonicalDigest.Field]
    let text: [String: String?]

    static let nonIDColumns: [String] = [
        "scope", "workspace_id", "conversation_id", "content", "confidence",
        "stability", "importance", "sensitivity", "origin", "evidence_json",
        "conflicts_json", "source_attachment_id", "source_mime_type",
        "status", "review_reason", "expires_at", "created_at", "updated_at",
    ]

    init(_ row: Row) {
        let idValue: String = row["id"]
        self.id = idValue
        self.fields = Self.nonIDColumns.map { FacadeDigestCodec.field(row, $0) }
        var text: [String: String?] = [:]
        for column in Self.nonIDColumns {
            let value: DatabaseValue = row[column]
            if case .string(let raw) = value.storage { text[column] = raw }
            else { text[column] = nil }
        }
        self.text = text
    }

    var digest: String {
        SettingsDomainV1.CanonicalDigest.rowToken(
            domain: SettingsDomainV1.CanonicalDigest.domainMemoryCandidate,
            fields: fields)
    }

    func string(_ column: String) -> String? { text[column] ?? nil }

    /// REAL storage-class numeric extraction (no CAST assumptions): the
    /// columns are declared REAL; a STRICT table guarantees the storage
    /// class, but the codec reads the ACTUAL DatabaseValue either way.
    func number(at index: Int) -> Double {
        switch fields[index] {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return 0
        }
    }

    /// Projection mirroring the ORIGINAL Self.candidate decode
    /// (Personalization.swift:496-516 + decodeScope :527-541 + the
    /// MemoryCandidate init clamps) so a row the original rejects as
    /// corrupted is rejected identically; timestamps pass through as the
    /// RAW stored text.
    func candidateDTO(digest: String) throws -> SettingsDomainV1.MemoryCandidate {
        guard let uuid = UUID(uuidString: id) else {
            throw MemoryAdapterError.persistenceUnavailable("corruptCandidateRow")
        }
        let corrupt = MemoryAdapterError
            .persistenceUnavailable("corruptCandidateRow:\(uuid.uuidString)")
        guard let sensitivity = SettingsDomainV1.MemorySensitivity(rawValue: string("sensitivity") ?? ""),
              let origin = SettingsDomainV1.CandidateOrigin(rawValue: string("origin") ?? ""),
              let status = SettingsDomainV1.CandidateStatus(rawValue: string("status") ?? ""),
              let content = string("content") else {
            throw corrupt
        }
        let scopeName = string("scope") ?? ""
        let workspaceUUID = string("workspace_id").flatMap(UUID.init(uuidString:))
        let conversationUUID = string("conversation_id").flatMap(UUID.init(uuidString:))
        let scope: SettingsDomainV1.MemoryScope
        switch scopeName {
        case "user":
            scope = try SettingsDomainV1.MemoryScope(kind: .user)
        case "agent":
            scope = try SettingsDomainV1.MemoryScope(kind: .agent)
        case "workspace":
            // decodeScope (:527-541) throws storageCorrupted on a
            // workspace/task scope without its id — mirrored as typed.
            guard let workspaceUUID,
                  let typed = try? SettingsDomainV1.MemoryScope(kind: .workspace,
                                                                workspaceID: workspaceUUID) else {
                throw corrupt
            }
            scope = typed
        case "task":
            guard let conversationUUID,
                  let typed = try? SettingsDomainV1.MemoryScope(kind: .task,
                                                                conversationID: conversationUUID) else {
                throw corrupt
            }
            scope = typed
        default:
            throw corrupt
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let nativeEvidence: [MemoryEvidenceReference]
        do {
            nativeEvidence = try decoder.decode([MemoryEvidenceReference].self,
                                                from: Data((string("evidence_json") ?? "[]").utf8))
        } catch {
            throw corrupt
        }
        let conflicts: [UUID]
        do {
            conflicts = try decoder.decode([UUID].self,
                                           from: Data((string("conflicts_json") ?? "[]").utf8))
        } catch {
            throw corrupt
        }
        let evidence = nativeEvidence.map {
            SettingsDomainV1.MemoryEvidenceReference(id: $0.id,
                                                    messageID: $0.messageID,
                                                    excerpt: $0.excerpt)
        }
        return SettingsDomainV1.MemoryCandidate(
            id: uuid,
            scope: scope,
            content: content,
            confidence: number(at: 4),
            stability: number(at: 5),
            importance: number(at: 6),
            sensitivity: sensitivity,
            origin: origin,
            evidence: evidence,
            conflictsWithEntryIDs: conflicts,
            reviewReason: string("review_reason"),
            sourceAttachmentID: string("source_attachment_id").flatMap(UUID.init(uuidString:)),
            sourceMIMEType: string("source_mime_type"),
            status: status,
            expiresAt: string("expires_at"),
            createdAt: string("created_at") ?? "",
            updatedAt: string("updated_at") ?? "",
            revision: digest
        )
    }
}

// MARK: - Process-lifetime snapshot stores

/// Stores ONLY the recall ranking (≤20 id + ranking fields per the contract
/// searchHandle bound) — never row content, never digests, never durable.
/// Pages read fresh rows per page; recall is NEVER re-run by a continuation
/// (Q9: no double reinforcement per page).
internal final class FacadeSearchSnapshotStore: @unchecked Sendable {
    struct RankedItem: Sendable {
        let id: UUID
        let relevance: Double
        let lexicalRank: Int?
        let semanticRank: Int?
        let semanticSimilarity: Double?
    }

    struct Snapshot: Sendable {
        let items: [RankedItem]
    }

    enum LookUp: Sendable {
        case found(Snapshot)
        /// existed in this process and was detached by the FIFO bound —
        /// honest expiry (contract: re-issue the query for a fresh recall)
        case expired
        /// never existed in this process (or after process death)
        case unknown
    }

    private let lock = NSLock()
    private var snapshots: [String: Snapshot] = [:]
    private var order: [String] = []
    private var detached: [String] = []
    /// FIFO bound: detaching the oldest snapshot is an HONEST expiry — its
    /// handle then answers typed notFound{searchHandleExpired} and the
    /// client re-issues the query (contract paging safety valve;
    /// proposal/search handle expiry/count/bytes bounded).
    static let maximumLiveSnapshots = 32
    static let maximumDetachedMemory = 64

    func store(handle: String, items: [RankedItem]) {
        lock.lock(); defer { lock.unlock() }
        snapshots[handle] = Snapshot(items: Array(items.prefix(
            SettingsDomainV1.maximumSearchItems)))
        order.append(handle)
        while order.count > Self.maximumLiveSnapshots {
            let oldest = order.removeFirst()
            if snapshots.removeValue(forKey: oldest) != nil {
                detached.append(oldest)
                while detached.count > Self.maximumDetachedMemory {
                    detached.removeFirst()
                }
            }
        }
    }

    func lookup(_ handle: String) -> LookUp {
        lock.lock(); defer { lock.unlock() }
        if let snapshot = snapshots[handle] { return .found(snapshot) }
        if detached.contains(handle) { return .expired }
        return .unknown
    }

    static func mintHandle() -> String {
        var hex = ""
        hex.reserveCapacity(32)
        for _ in 0..<16 { hex += String(format: "%02x", UInt8.random(in: 0...255)) }
        return "msearch:v1:" + hex
    }
}

/// Proposal handles: process-lifetime, bounded by count (FIFO detach =
/// honest typed handleExpired; proposals are regenerable reads over real
/// data — no durable-cursor invention). Holds per-id expected digests from
/// the generation snapshot, provenance flags and the real auto-delete
/// outcome. Entry summaries keep the ORIGINAL 1024-char store-level prefix
/// (MemoryMaintenance.swift:69); full content remains store-side via
/// memory.get. The handle never holds raw full memory content.
internal final class FacadeProposalStore: @unchecked Sendable {
    struct Proposal: Sendable {
        let proposalID: UUID
        let generatedAt: String
        let scannedCount: Int
        let suggestions: [SettingsDomainV1.MemoryOrganizeSuggestion]
        let entries: [SettingsDomainV1.MemoryOrganizeEntrySummary]
        let expectedDigests: [UUID: String]
        let modelProvenance: Bool
        var stale: Bool
        var staleIDs: [UUID]
        var autoDelete: SettingsDomainV1.MemoryOrganizeAutoDelete
    }

    enum LookUp: Sendable {
        case found(Proposal)
        case expired
        case unknown
    }

    private let lock = NSLock()
    private var proposals: [String: Proposal] = [:]
    private var order: [String] = []
    private var detached: [String] = []
    static let maximumLiveProposals = 8
    static let maximumDetachedMemory = 64

    func store(handle: String, proposal: Proposal) {
        lock.lock(); defer { lock.unlock() }
        proposals[handle] = proposal
        order.append(handle)
        while order.count > Self.maximumLiveProposals {
            let oldest = order.removeFirst()
            if proposals.removeValue(forKey: oldest) != nil {
                detached.append(oldest)
                while detached.count > Self.maximumDetachedMemory {
                    detached.removeFirst()
                }
            }
        }
    }

    func lookup(_ handle: String) -> LookUp {
        lock.lock(); defer { lock.unlock() }
        if let proposal = proposals[handle] { return .found(proposal) }
        if detached.contains(handle) { return .expired }
        return .unknown
    }

    /// Snapshot-free proposal accessor for the async apply flow.
    func proposal(_ handle: String) -> Proposal? {
        if case .found(let proposal) = lookup(handle) { return proposal }
        return nil
    }

    static func mintHandle() -> String {
        var hex = ""
        hex.reserveCapacity(32)
        for _ in 0..<16 { hex += String(format: "%02x", UInt8.random(in: 0...255)) }
        return "morganize:v1:" + hex
    }
}

// MARK: - FacadeMemoryAdapter

/// Memory backend adapter over the ONE original schema-46 DatabaseManager.
/// Readers carry full raw rows + per-row digests in the same reader
/// snapshot; writer validations+mutations carry raw DatabaseValue CAS in
/// the same transaction. No actor awaits inside any DB closure
/// (contract deadlockRule).
public actor FacadeMemoryAdapter {
    private let database: DatabaseManager
    private let intelligenceStore: SQLiteIntelligenceStore
    private let workspaceStore: SQLiteWorkspaceStore
    private let conversationStore: SQLiteConversationStore
    private let searchSnapshots = FacadeSearchSnapshotStore()
    /// Internal test-only fault seam (P2 race vectors: a failure injected
    /// between the entry write and the candidate status write must roll the
    /// WHOLE transaction). Never reachable from a production initializer;
    /// never substitutes a store.
    private let faultInjection: (@Sendable (String) throws -> Void)?

    public init(database: DatabaseManager,
                intelligenceStore: SQLiteIntelligenceStore,
                workspaceStore: SQLiteWorkspaceStore,
                conversationStore: SQLiteConversationStore) {
        self.database = database
        self.intelligenceStore = intelligenceStore
        self.workspaceStore = workspaceStore
        self.conversationStore = conversationStore
        self.faultInjection = nil
    }

    init(database: DatabaseManager,
         intelligenceStore: SQLiteIntelligenceStore,
         workspaceStore: SQLiteWorkspaceStore,
         conversationStore: SQLiteConversationStore,
         faultInjection: (@Sendable (String) throws -> Void)?) {
        self.database = database
        self.intelligenceStore = intelligenceStore
        self.workspaceStore = workspaceStore
        self.conversationStore = conversationStore
        self.faultInjection = faultInjection
    }

    // MARK: - memory.list

    /// MIRRORED read-only SQL with the EXACT listMemories SQL/ordering and
    /// the same n+1 hasMore probe (IntelligenceStore.swift:466-521),
    /// computing each floe.memory-entry.v3 digest in the SAME reader
    /// transaction. The original listMemories stays the equivalence
    /// reference (bounded-fixture golden), not a runtime delegate.
    public func list(_ request: MemoryListWireRequest) async throws
        -> SettingsDomainV1.MemoryListReply
    {
        let nativeScope: MemoryScope?
        if let scope = request.scope {
            nativeScope = try Self.nativeScopeThrowing(scope)
        } else {
            nativeScope = nil
        }
        try await validateScopeIdentities(scope: nativeScope,
                                          originConversationID: request.originConversationID,
                                          originWorkspaceID: request.originWorkspaceID)
        let database = self.database
        let offset = request.cursor
        let limit = min(500, max(1, request.limit)) // ORIGINAL clamp parity
        let statusRaw = request.status?.rawValue
        let originConversationID = request.originConversationID
        let originWorkspaceID = request.originWorkspaceID
        let fact = request.factIdentity
        let isPinned = request.isPinned
        return try await database.reader { db in
            var filters: [String] = []
            var arguments = StatementArguments()
            if let nativeScope {
                let triple = Self.scopeTriple(nativeScope)
                filters.append("scope = ?")
                arguments += [triple.0]
                if let workspaceID = triple.1 {
                    filters.append("(workspace_id = ? OR origin_workspace_id = ?)")
                    arguments += [workspaceID.uuidString, workspaceID.uuidString]
                }
                if let conversationID = triple.2 {
                    filters.append("(conversation_id = ? OR origin_conversation_id = ?)")
                    arguments += [conversationID.uuidString, conversationID.uuidString]
                }
            }
            if let statusRaw {
                filters.append("status = ?")
                arguments += [statusRaw]
            }
            if let originConversationID {
                filters.append("origin_conversation_id = ?")
                arguments += [originConversationID.uuidString]
            }
            if let originWorkspaceID {
                filters.append("origin_workspace_id = ?")
                arguments += [originWorkspaceID.uuidString]
            }
            if let fact {
                filters.append("subject_key = ? AND attribute_key = ?")
                arguments += [fact.subjectKey, fact.attributeKey]
            }
            if let isPinned {
                filters.append("is_pinned = ?")
                arguments += [isPinned]
            }
            let whereClause = filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND ")
            arguments += [limit + 1, offset]
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM memory_entries
                \(whereClause)
                ORDER BY is_pinned DESC, importance DESC, updated_at DESC, id
                LIMIT ? OFFSET ?
                """, arguments: arguments)
            let hasMore = rows.count > limit
            let rawRows = rows.prefix(limit).map(FacadeMemoryRawRow.init)
            return try FacadeMemoryRowCodec.pagedReply(rows: Array(rawRows),
                                                      startCursor: offset,
                                                      probeHasMore: hasMore)
        }
    }

    // MARK: - memory.get

    /// MIRRORED single-row SELECT * FROM memory_entries WHERE id = ? (same
    /// mapping as memory(id:) :459-464) with the full-row digest computed in
    /// the SAME reader transaction.
    public func get(id: UUID) async throws -> SettingsDomainV1.MemoryEntry {
        let database = self.database
        return try await database.reader { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM memory_entries WHERE id = ?
                """, arguments: [id.uuidString]) else {
                throw MemoryAdapterError.notFound("memoryMissing")
            }
            let raw = FacadeMemoryRawRow(row)
            return try FacadeMemoryRowCodec.entry(from: raw, digest: raw.digest)
        }
    }

    // MARK: - memory.add

    /// Mirrors MemoryCenter.remember (MemoryView.swift:92-120): scope
    /// resolution → owner-existence validation → duplicate scan (the
    /// original memories(scope:status:) actor call) → ORIGINAL
    /// SQLiteIntelligenceStore.saveMemory (fresh minted id needs no CAS;
    /// evidence []) → UNIQUE-index convergence. The terminal effect's real
    /// minted id + digest come from the committed row read-back AFTER the
    /// delegate completes (manual created realID only after commit).
    public func add(_ request: MemoryAddRequest) async throws
        -> SettingsDomainV1.MemoryMutationReply
    {
        let nativeScope = try Self.nativeScopeThrowing(request.scope)
        try await validateScopeIdentities(scope: nativeScope,
                                          originConversationID: request.originConversationID,
                                          originWorkspaceID: request.originWorkspaceID)
        let normalized = request.content.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else {
            throw MemoryAdapterError.invalidEnvelope("memoryRejected:empty")
        }
        guard !WireMemorySupport.containsSecretLikeMarker(request.content) else {
            throw MemoryAdapterError.invalidEnvelope("memoryRejected:secretLike")
        }
        // Original store clamp parity (MemoryEntry.init content.prefix(4096))
        // applied as a PRE-MUTATION typed refusal: a user-edited oversize
        // add is never silently truncated and never stored.
        guard request.content.count <= SettingsDomainV1.maximumMemoryContentCharacters else {
            throw MemoryAdapterError.payloadTooLarge(
                maxChars: SettingsDomainV1.maximumMemoryContentCharacters)
        }
        // Original pre-check parity (:100-111): identical case-insensitive
        // ACTIVE content in the target scope.
        let existing = try await intelligenceStore.memories(scope: nativeScope,
                                                            status: .active)
        if let duplicate = existing.first(where: {
            $0.content.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == normalized
        }) {
            return SettingsDomainV1.MemoryMutationReply(status: .duplicate,
                                                        entry: nil,
                                                        existingID: duplicate.id)
        }
        // ORIGINAL actor method (IntelligenceStore.swift:392-457) — called
        // OUTSIDE any open transaction (deadlockRule).
        let entry = MemoryEntry(
            scope: nativeScope, status: .active, content: request.content,
            confidence: 1, importance: 0.8, isPinned: true,
            sourceKind: .explicitUserRequest,
            originConversationID: request.originConversationID,
            originWorkspaceID: request.originWorkspaceID
        )
        do {
            try await intelligenceStore.saveMemory(entry, evidence: [])
        } catch {
            // Concurrent UNIQUE convergence (V21:21-35 scope+
            // normalized_content indexes): re-query and return the REAL
            // existing id — typed duplicate, never a raw SQL error.
            if let databaseError = error as? DatabaseError,
               databaseError.resultCode == .SQLITE_CONSTRAINT,
               let winner = try await requeryUniqueWinner(normalized: normalized,
                                                          scope: nativeScope) {
                return SettingsDomainV1.MemoryMutationReply(status: .duplicate,
                                                            entry: nil,
                                                            existingID: winner)
            }
            throw Self.translateWriteError(error)
        }
        let stored = try await get(id: entry.id)
        return SettingsDomainV1.MemoryMutationReply(status: .added,
                                                    entry: stored,
                                                    existingID: nil)
    }

    private func requeryUniqueWinner(normalized: String,
                                     scope: MemoryScope) async throws
        -> UUID?
    {
        let database = self.database
        let triple = Self.scopeTriple(scope)
        return try await database.reader { db in
            guard let id = try String.fetchOne(db, sql: """
                SELECT id FROM memory_entries
                WHERE scope = ? AND normalized_content = ?
                  AND (workspace_id IS ? OR origin_workspace_id IS ?)
                  AND (conversation_id IS ? OR origin_conversation_id IS ?)
                ORDER BY updated_at DESC, created_at DESC LIMIT 1
                """, arguments: [triple.0, normalized,
                                 triple.1?.uuidString, triple.1?.uuidString,
                                 triple.2?.uuidString, triple.2?.uuidString]) else {
                return nil
            }
            return UUID(uuidString: id)
        }
    }

    // MARK: - memory.update

    /// ONE writer transaction (commandTable entry 5): SELECT ALL 23 non-id
    /// columns as DatabaseValue → recompute floe.memory-entry.v3 → compare
    /// (mismatch → staleRevision, nothing written; this same-transaction
    /// re-read is the owner/scope guard: detach, reinforce, tool upsert,
    /// candidate activation or any lifecycle column change flips the
    /// digest) → UPDATE with the EXACT original replace column set
    /// (IntelligenceStore.swift:634-641) → original guards (non-empty
    /// normalized + secret scan :630-632) → in-transaction read-after-write
    /// carrying the new digest. All 13 preserved columns keep their RAW
    /// stored values (sync_revision stays 0 — the adapter never writes it).
    public func update(expectedRevision: String, request: MemoryUpdateRequest) async throws
        -> SettingsDomainV1.MemoryUpdateReply
    {
        let database = self.database
        do {
            return try await database.writer { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT * FROM memory_entries WHERE id = ?
                    """, arguments: [request.id.uuidString]) else {
                    throw MemoryAdapterError.notFound("memoryMissing")
                }
                let raw = FacadeMemoryRawRow(row)
                guard raw.digest == expectedRevision else {
                    throw MemoryAdapterError.staleRevision(staleIDs: [request.id],
                                                           missingIDs: [])
                }
                // Untouched columns start from the RAW stored values.
                var content = raw.string("content") ?? ""
                var normalized = raw.string("normalized_content") ?? ""
                var status = raw.statusRaw
                var importance = raw.importance
                var isPinned: Int64 = raw.isPinnedInteger
                var expiresAt = raw.string("expires_at")
                var subjectKey = raw.string("subject_key")
                var attributeKey = raw.string("attribute_key")
                if let newContent = request.content {
                    content = newContent
                    normalized = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                }
                if let value = request.importance { importance = value }
                if let value = request.isPinned { isPinned = value ? 1 : 0 }
                if let value = request.status { status = value.rawValue }
                switch request.expires {
                case .keepStored: break
                case .clear: expiresAt = nil
                case .set(let iso): expiresAt = iso
                }
                switch request.fact {
                case .keepStored: break
                case .clear:
                    subjectKey = nil
                    attributeKey = nil
                case .set(let identity):
                    // ORIGINAL MemoryFactIdentity normalization
                    // (MemoryMaintenance.swift:5-20).
                    subjectKey = Self.normalizeFactKey(identity.subjectKey)
                    attributeKey = Self.normalizeFactKey(identity.attributeKey)
                }
                guard !normalized.isEmpty else {
                    throw MemoryAdapterError.invalidEnvelope("memoryRejected:empty")
                }
                guard !WireMemorySupport.containsSecretLikeMarker(content) else {
                    throw MemoryAdapterError.invalidEnvelope("memoryRejected:secretLike")
                }
                try db.execute(sql: """
                    UPDATE memory_entries SET content = ?, normalized_content = ?,
                        status = ?, confidence = ?, importance = ?, is_pinned = ?,
                        expires_at = ?, subject_key = ?, attribute_key = ?,
                        updated_at = ? WHERE id = ?
                    """, arguments: [content, normalized, status, raw.confidence,
                                     importance, isPinned, expiresAt,
                                     subjectKey, attributeKey,
                                     Self.secondDate(Date()),
                                     request.id.uuidString])
                guard db.changesCount == 1 else {
                    throw MemoryAdapterError.notFound("memoryMissing")
                }
                guard let written = try Row.fetchOne(db, sql: """
                    SELECT * FROM memory_entries WHERE id = ?
                    """, arguments: [request.id.uuidString]) else {
                    throw MemoryAdapterError.notFound("memoryMissing")
                }
                let resultRaw = FacadeMemoryRawRow(written)
                let entry = try FacadeMemoryRowCodec.entry(from: resultRaw,
                                                           digest: resultRaw.digest)
                return SettingsDomainV1.MemoryUpdateReply(entry: entry)
            }
        } catch let error as MemoryAdapterError {
            throw error
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            // Content/factIdentity change colliding with another row's
            // (scope, normalized_content) V21 UNIQUE index: typed domain
            // error, nothing written, never a raw SQL failure.
            throw MemoryAdapterError.invalidEnvelope("memoryDuplicateContent")
        } catch {
            throw MemoryAdapterError.persistenceUnavailable(nil)
        }
    }

    // MARK: - memory.delete

    /// ONE writer transaction: full raw row → floe.memory-entry.v3 digest
    /// CAS (same-transaction owner/scope guard) → the original
    /// delete+tombstone statements mirrored EXACTLY (IntelligenceStore.swift:
    /// 977-993) with the wall-clock-ms ordering value — the ordering value
    /// quickOrganize uses; native single-delete passes constant 1 (a
    /// documented wire choice; neither is ever a precondition).
    /// memory_embeddings cascade via the V7/V13 FK. A late retry hits the
    /// typed notFound{memoryMissing}, which doubles as the idempotent
    /// already-deleted signal (documented deviation from the unconditional
    /// original delete).
    public func delete(expectedRevision: String, id: UUID) async throws
        -> SettingsDomainV1.MemoryDeleteReply
    {
        let database = self.database
        let fault = self.faultInjection
        do {
            return try await database.writer { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT * FROM memory_entries WHERE id = ?
                    """, arguments: [id.uuidString]) else {
                    throw MemoryAdapterError.notFound("memoryMissing")
                }
                let raw = FacadeMemoryRawRow(row)
                guard raw.digest == expectedRevision else {
                    throw MemoryAdapterError.staleRevision(staleIDs: [id], missingIDs: [])
                }
                try Self.deleteWithTombstone(id: id.uuidString,
                                             revision: FacadeStoreTime.wallClockMillis(Date()),
                                             deletedAt: Self.secondDate(Date()),
                                             db: db)
                try fault?("memory.delete.beforeCommit")
                let remaining = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM memory_entries WHERE id = ?)
                    """, arguments: [id.uuidString]) ?? false
                guard !remaining else {
                    throw MemoryAdapterError.persistenceUnavailable("deleteDidNotApply")
                }
                return SettingsDomainV1.MemoryDeleteReply(deleted: true, tombstoned: true)
            }
        } catch let error as MemoryAdapterError {
            throw error
        } catch {
            throw MemoryAdapterError.persistenceUnavailable(nil)
        }
    }

    // MARK: - memory.delete.bulk

    /// ONE writer transaction mirroring applyMaintenanceBatch
    /// (IntelligenceStore.swift:590-658) PLUS per-id digest CAS:
    /// (1) batchID already in the DURABLE original ledger → alreadyApplied
    /// with the stored counts and ZERO re-application; (2) two-pass
    /// validation — existence first (typed notFound{missingIDs}), then
    /// per-id full-row digest CAS (staleRevision{staleIDs}) — nothing
    /// applied on any failure; no id twice (original guard :609-611);
    /// (3) delete+tombstone per id via the original static helper pattern
    /// with the REQUESTED syncRevision as ordering value; (4) ledger INSERT
    /// (:648-653). Same-batchID replay after process death reconciles from
    /// the original ledger — exactly-once without a second business store.
    public func deleteBulk(_ request: MemoryBulkDeleteRequest) async throws
        -> SettingsDomainV1.MemoryBulkDeleteReply
    {
        let database = self.database
        let items = request.items
        do {
            return try await database.writer { db in
                if let ledger = try Row.fetchOne(db, sql: """
                    SELECT operation_count, deleted_count, replaced_count
                    FROM memory_maintenance_batches WHERE id = ?
                    """, arguments: [request.batchID.uuidString]) {
                    let operationCount: Int64 = ledger["operation_count"]
                    let deletedCount: Int64 = ledger["deleted_count"]
                    let replacedCount: Int64 = ledger["replaced_count"]
                    return SettingsDomainV1.MemoryBulkDeleteReply(
                        batchID: request.batchID,
                        result: .alreadyApplied,
                        deletedCount: Int(deletedCount),
                        replacedCount: Int(replacedCount),
                        appliedCount: Int(operationCount)
                    )
                }
                var seen = Set<UUID>()
                for item in items {
                    guard seen.insert(item.id).inserted else {
                        throw MemoryAdapterError.invalidEnvelope("duplicateBatchEntry")
                    }
                }
                var missing: [UUID] = []
                var digests: [UUID: String] = [:]
                for item in items {
                    guard let row = try Row.fetchOne(db, sql: """
                        SELECT * FROM memory_entries WHERE id = ?
                        """, arguments: [item.id.uuidString]) else {
                        missing.append(item.id)
                        continue
                    }
                    let raw = FacadeMemoryRawRow(row)
                    digests[item.id] = raw.digest
                }
                guard missing.isEmpty else {
                    throw MemoryAdapterError.notFoundMissing(reason: "memoryMissing",
                                                             ids: missing.sorted {
                                                                 $0.uuidString < $1.uuidString
                                                             })
                }
                var stale: [UUID] = []
                for item in items {
                    if digests[item.id] != item.expectedDigest {
                        stale.append(item.id)
                    }
                }
                guard stale.isEmpty else {
                    throw MemoryAdapterError.staleRevision(staleIDs: stale,
                                                           missingIDs: [])
                }
                let deletedAt = Self.secondDate(Date())
                var deleted = 0
                for item in items {
                    try Self.deleteWithTombstone(id: item.id.uuidString,
                                                 revision: request.syncRevision,
                                                 deletedAt: deletedAt,
                                                 db: db)
                    deleted += 1
                }
                try db.execute(sql: """
                    INSERT INTO memory_maintenance_batches (
                        id, operation_count, deleted_count, replaced_count,
                        sync_revision, applied_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [request.batchID.uuidString, items.count,
                                     deleted, 0, request.syncRevision,
                                     Self.secondDate(Date())])
                return SettingsDomainV1.MemoryBulkDeleteReply(
                    batchID: request.batchID,
                    result: .applied,
                    deletedCount: deleted,
                    replacedCount: 0,
                    appliedCount: items.count
                )
            }
        } catch let error as MemoryAdapterError {
            throw error
        } catch {
            throw MemoryAdapterError.persistenceUnavailable(nil)
        }
    }

    // MARK: - memory.search

    /// Mutating read (commandTable entry 8, Q9 fix): the ORIGINAL
    /// hybridRecall is delegated UNMODIFIED exactly once per fresh query —
    /// including maintainMemoryLifecycle + reinforceMemories side effects —
    /// the bounded ranking goes into a process-lifetime searchHandle, and
    /// EVERY page (first or continuation) performs ONE batched fresh row
    /// read for that page's ids only, computing the current full-row digests
    /// in the same reader transaction. Ranking is preserved separately and
    /// never re-ranked; continuations never re-run recall (no double
    /// reinforcement). semantic=false: the Android overlay registers no
    /// embedding producer (queryEmbedding nil → lexical path + RRF over
    /// lexical only); semantic fields are absent, never faked.
    /// sideEffects are disclosed honestly; reinforcedCount stays null
    /// because the original API returns no per-item changesCount.
    public func search(_ request: MemorySearchWireRequest) async throws
        -> SettingsDomainV1.MemorySearchReply
    {
        if let handle = request.handle {
            switch searchSnapshots.lookup(handle) {
            case .found(let snapshot):
                return try await Self.page(snapshot: snapshot,
                                           offset: request.cursor,
                                           database: database,
                                           keepHandle: handle)
            case .expired:
                // Existed in THIS process and hit the bounded FIFO detach:
                // honest expiry; the client re-issues the query.
                throw MemoryAdapterError.notFound("searchHandleExpired")
            case .unknown:
                // Never existed here (or after process death).
                throw MemoryAdapterError.notFound("searchHandleUnknown")
            }
        }
        if let workspaceID = request.workspaceID {
            guard try await workspaceStore.workspace(id: workspaceID) != nil else {
                throw MemoryAdapterError.notFound("workspaceMissing")
            }
        }
        if let conversationID = request.conversationID {
            guard try await conversationStore.conversation(id: conversationID) != nil else {
                throw MemoryAdapterError.notFound("conversationMissing")
            }
        }
        let recallRequest = HybridMemoryRecallRequest(
            query: request.query,
            workspaceID: request.workspaceID,
            conversationID: request.conversationID,
            limit: min(20, max(1, request.limit))
        )
        // ORIGINAL actor call OUTSIDE any open transaction.
        let results = try await intelligenceStore.hybridRecall(recallRequest)
        let ranked = results.map {
            FacadeSearchSnapshotStore.RankedItem(id: $0.id,
                                                 relevance: $0.relevance,
                                                 lexicalRank: $0.lexicalRank,
                                                 semanticRank: $0.semanticRank,
                                                 semanticSimilarity: $0.semanticSimilarity)
        }
        let handle = FacadeSearchSnapshotStore.mintHandle()
        searchSnapshots.store(handle: handle, items: ranked)
        return try await Self.page(snapshot: FacadeSearchSnapshotStore.Snapshot(items: ranked),
                                   offset: 0,
                                   database: database,
                                   keepHandle: handle)
    }

    private static func page(snapshot: FacadeSearchSnapshotStore.Snapshot,
                             offset: Int,
                             database: DatabaseManager,
                             keepHandle: String) async throws
        -> SettingsDomainV1.MemorySearchReply
    {
        let items = snapshot.items
        guard offset < items.count else {
            return SettingsDomainV1.MemorySearchReply(
                items: [], semantic: false,
                sideEffects: SettingsDomainV1.MemorySearchSideEffects(),
                searchHandle: keepHandle, nextCursor: nil, hasMore: false)
        }
        let pageIDs = Array(items[offset...].map(\.id))
        let placeholders = pageIDs.map { _ in "?" }.joined(separator: ",")
        // ONE batched reader for ONLY this page's ids: current rows +
        // per-row digests in the same reader snapshot.
        let currentByID: [UUID: FacadeMemoryRawRow] = try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM memory_entries WHERE id IN (\(placeholders))
                """, arguments: StatementArguments(pageIDs.map(\.uuidString)))
            var mapping: [UUID: FacadeMemoryRawRow] = [:]
            for row in rows {
                let raw = FacadeMemoryRawRow(row)
                if let uuid = UUID(uuidString: raw.id) {
                    mapping[uuid] = raw
                }
            }
            return mapping
        }
        var pageItems: [SettingsDomainV1.MemorySearchItem] = []
        var index = offset
        while index < items.count {
            let ranked = items[index]
            let current: SettingsDomainV1.MemoryEntry?
            let deleted: Bool
            if let raw = currentByID[ranked.id] {
                current = try FacadeMemoryRowCodec.entry(from: raw, digest: raw.digest)
                deleted = false
            } else {
                // Row vanished between recall and the batched read: no
                // fabricated projection; edit/delete is not offered.
                current = nil
                deleted = true
            }
            let candidateItems = pageItems + [SettingsDomainV1.MemorySearchItem(
                id: ranked.id, relevance: ranked.relevance,
                lexicalRank: ranked.lexicalRank, semanticRank: ranked.semanticRank,
                semanticSimilarity: ranked.semanticSimilarity,
                current: current, deleted: deleted)]
            let more = index + 1 < items.count
            let trial = SettingsDomainV1.MemorySearchReply(
                items: candidateItems, semantic: false,
                sideEffects: SettingsDomainV1.MemorySearchSideEffects(),
                searchHandle: keepHandle,
                nextCursor: more ? String(index + 1) : nil,
                hasMore: more)
            if FacadeWireBytes.count(trial) <= SettingsDomainV1.pageBudgetBytes {
                pageItems = candidateItems
                index += 1
            } else if !pageItems.isEmpty {
                break
            } else {
                // Single atomic item larger than the page budget: fail
                // typed; nothing is truncated.
                throw MemoryAdapterError.persistenceUnavailable("pageItemOverBudget")
            }
        }
        let hasMore = index < items.count
        return SettingsDomainV1.MemorySearchReply(
            items: pageItems, semantic: false,
            sideEffects: SettingsDomainV1.MemorySearchSideEffects(),
            searchHandle: keepHandle,
            nextCursor: hasMore ? String(index) : nil,
            hasMore: hasMore)
    }

    // MARK: - memory.candidates.list

    /// Mutating read in ONE DatabaseManager WRITER transaction exactly like
    /// the original candidates() (Personalization.swift:453-468): the
    /// ORIGINAL expiry sweep UPDATE runs verbatim first, its real
    /// changesCount discloses `expiredSweepApplied` honestly, then a
    /// BOUNDED paged SELECT with the same filter/ordering and the n+1
    /// probe — never the original unbounded array (Main review issue 5).
    /// Row decoding mirrors the original Self.candidate (:496-516) incl.
    /// scope decoding (:527-541); each row carries the
    /// floe.memory-candidate.v1 digest.
    public func candidatesPage(_ request: MemoryCandidatesListRequest) async throws
        -> SettingsDomainV1.MemoryCandidatesReply
    {
        let database = self.database
        let limit = min(SettingsDomainV1.maximumCandidatePage,
                        max(1, request.limit))
        let statusRaw = request.status?.rawValue
        let offset = request.cursor
        return try await database.writer { db in
            let now = Self.secondDate(Date())
            try db.execute(sql: """
                UPDATE memory_candidates
                SET status = 'rejected', review_reason = 'review window expired',
                    updated_at = ?
                WHERE status = 'pending' AND expires_at IS NOT NULL AND expires_at <= ?
                """, arguments: [now, now])
            let sweepChanged = db.changesCount
            var sql = "SELECT * FROM memory_candidates"
            var arguments = StatementArguments()
            if let statusRaw {
                sql += " WHERE status = ?"
                arguments += [statusRaw]
            }
            sql += " ORDER BY importance DESC, created_at DESC LIMIT ? OFFSET ?"
            arguments += [limit + 1, offset]
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            let hasMore = rows.count > limit
            var candidates: [SettingsDomainV1.MemoryCandidate] = []
            for row in rows.prefix(limit) {
                let raw = FacadeCandidateRawRow(row)
                candidates.append(try raw.candidateDTO(digest: raw.digest))
            }
            return SettingsDomainV1.MemoryCandidatesReply(
                candidates: candidates,
                nextCursor: hasMore ? String(offset + limit) : nil,
                expiredSweepApplied: sweepChanged > 0)
        }
    }

    // MARK: - memory.candidate.resolve

    /// SINGLE writer transaction replacing the original THREE-transaction
    /// resolvePending sequence (Personalization.swift:834-856; Main review
    /// issue 5), preserving every original validation and mapping
    /// (commandTable entry 10):
    /// (1) the original expiry sweep verbatim FIRST (deterministic inside
    /// the transaction); (2) bounded single-row SELECT by id; (3) missing →
    /// notFound{candidateMissing}; (4) status guard BEFORE the token check
    /// → notFound{candidateNotPending:<actualStatus>}; (5) full-row
    /// floe.memory-candidate.v1 digest CAS → staleRevision (producer
    /// replays that keep status pending but change any field are detected;
    /// no second-precision timestamp CAS); (6) activation builds the
    /// MemoryEntry EXACTLY like the original (:840-847) and writes it
    /// in-transaction with saveMemory's guards and column set (:394-398,
    /// :424-445) + evidence rewrite (:446-455) computing
    /// excerpt_digest = stableDigest(stored redacted excerpt) — the
    /// original double-digest byte-exactly; the factIdentity supersession
    /// branch cannot fire (MemoryCandidate carries no factIdentity);
    /// (7) the status UPDATE writes the same columns the original
    /// saveCandidate ON CONFLICT branch updates (:439-440) with the
    /// original reason strings; (8) read-after-write in-transaction.
    /// Any injected failure between the entry write and the status write
    /// rolls the WHOLE transaction back: no entry, candidate still
    /// pending, retry converges.
    public func resolveCandidate(expectedRevision: String, id: UUID, activate: Bool) async throws
        -> SettingsDomainV1.MemoryCandidateResolveReply
    {
        let database = self.database
        let fault = self.faultInjection
        do {
            return try await database.writer { db in
                let now = Self.secondDate(Date())
                try db.execute(sql: """
                    UPDATE memory_candidates
                    SET status = 'rejected', review_reason = 'review window expired',
                        updated_at = ?
                    WHERE status = 'pending' AND expires_at IS NOT NULL AND expires_at <= ?
                    """, arguments: [now, now])
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT * FROM memory_candidates WHERE id = ?
                    """, arguments: [id.uuidString]) else {
                    throw MemoryAdapterError.notFound("candidateMissing")
                }
                let raw = FacadeCandidateRawRow(row)
                guard raw.string("status") == "pending" else {
                    throw MemoryAdapterError.notFound(
                        "candidateNotPending:\(raw.string("status") ?? "unknown")")
                }
                guard raw.digest == expectedRevision else {
                    throw MemoryAdapterError.staleRevision(staleIDs: [id], missingIDs: [])
                }
                guard let createdDate = raw.string("created_at").flatMap(FacadeStoreTime.parse) else {
                    throw MemoryAdapterError
                        .persistenceUnavailable("corruptCandidateRow:\(id.uuidString)")
                }
                if activate {
                    let scopeName = raw.string("scope") ?? ""
                    let workspaceUUID = raw.string("workspace_id").flatMap(UUID.init(uuidString:))
                    let conversationUUID = raw.string("conversation_id").flatMap(UUID.init(uuidString:))
                    let nativeScope: MemoryScope
                    switch scopeName {
                    case "user": nativeScope = .userProfile
                    case "agent": nativeScope = .agentGlobal
                    case "workspace":
                        guard let workspaceUUID else {
                            throw MemoryAdapterError
                                .persistenceUnavailable("corruptCandidateRow:\(id.uuidString)")
                        }
                        nativeScope = .workspace(workspaceUUID)
                    case "task":
                        guard let conversationUUID else {
                            throw MemoryAdapterError
                                .persistenceUnavailable("corruptCandidateRow:\(id.uuidString)")
                        }
                        nativeScope = .task(conversationUUID)
                    default:
                        throw MemoryAdapterError
                            .persistenceUnavailable("corruptCandidateRow:\(id.uuidString)")
                    }
                    let content = raw.string("content") ?? ""
                    let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    // Original activation guards (memoryRejected re-validation).
                    guard !normalized.isEmpty else {
                        throw MemoryAdapterError.invalidEnvelope("memoryRejected:empty")
                    }
                    guard !WireMemorySupport.containsSecretLikeMarker(content) else {
                        throw MemoryAdapterError.invalidEnvelope("memoryRejected:secretLike")
                    }
                    guard let nativeOrigin = MemoryCandidateOrigin(rawValue: raw.string("origin") ?? "") else {
                        throw MemoryAdapterError
                            .persistenceUnavailable("corruptCandidateRow:\(id.uuidString)")
                    }
                    let entry = MemoryEntry(
                        id: id, scope: nativeScope, status: .active,
                        content: content,
                        confidence: raw.number(at: 4),
                        importance: raw.number(at: 6),
                        sourceKind: nativeOrigin,
                        expiresAt: raw.string("expires_at").flatMap(FacadeStoreTime.parse),
                        createdAt: createdDate)
                    // saveMemory UPSERT column set verbatim
                    // (IntelligenceStore.swift:424-445). The native init has
                    // applied its clamps (content prefix 4096, confidence/
                    // importance 0..1, origin-id filling from scope,
                    // factIdentity nil).
                    let triple = Self.scopeTriple(entry.scope)
                    try db.execute(sql: """
                        INSERT INTO memory_entries (
                            id, scope, workspace_id, conversation_id, status, content,
                            normalized_content, confidence, importance, is_pinned,
                            source_kind, expires_at, origin_conversation_id,
                            origin_workspace_id, subject_key, attribute_key,
                            created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET status=excluded.status,
                            content=excluded.content,
                            normalized_content=excluded.normalized_content,
                            confidence=excluded.confidence,
                            importance=excluded.importance,
                            is_pinned=excluded.is_pinned,
                            expires_at=excluded.expires_at,
                            subject_key=excluded.subject_key,
                            attribute_key=excluded.attribute_key,
                            origin_conversation_id=COALESCE(memory_entries.origin_conversation_id, excluded.origin_conversation_id),
                            origin_workspace_id=COALESCE(memory_entries.origin_workspace_id, excluded.origin_workspace_id),
                            updated_at=excluded.updated_at
                        """, arguments: [entry.id.uuidString, triple.0,
                            triple.1?.uuidString, triple.2?.uuidString,
                            entry.status.rawValue, entry.content, normalized,
                            entry.confidence, entry.importance, entry.isPinned,
                            entry.sourceKind.rawValue,
                            entry.expiresAt.map { Self.secondDate($0) },
                            entry.originConversationID?.uuidString,
                            entry.originWorkspaceID?.uuidString,
                            entry.factIdentity?.subjectKey,
                            entry.factIdentity?.attributeKey,
                            Self.secondDate(entry.createdAt),
                            Self.secondDate(entry.updatedAt)])
                    // Evidence rewrite (:446-455): the stored candidate
                    // evidence excerpt is the REDACTED 'sha256:<digest>'
                    // string; excerpt_digest = stableDigest(redacted)
                    // reproduces the original double-digest byte-exactly
                    // (MemoryContentDigest.make was already applied at
                    // saveCandidate time — Personalization.swift:426).
                    try db.execute(sql: "DELETE FROM memory_evidence WHERE memory_id = ?",
                                   arguments: [entry.id.uuidString])
                    let candidate = try raw.candidateDTO(digest: raw.digest)
                    for reference in candidate.evidence {
                        try db.execute(sql: """
                            INSERT INTO memory_evidence (
                                id, memory_id, conversation_id, message_id,
                                excerpt_digest, created_at
                            ) VALUES (?, ?, ?, ?, ?, ?)
                            """, arguments: [reference.id.uuidString,
                                entry.id.uuidString,
                                entry.originConversationID?.uuidString,
                                reference.messageID.uuidString,
                                FacadeStableDigest.fnvRadix16(reference.excerpt),
                                Self.secondDate(entry.updatedAt)])
                    }
                    try fault?("candidate.afterEntryWriteBeforeStatus")
                }
                try db.execute(sql: """
                    UPDATE memory_candidates SET status = ?, review_reason = ?,
                        updated_at = ? WHERE id = ?
                    """, arguments: [
                        activate ? "activated" : "rejected",
                        activate ? "approved by user" : "rejected by user",
                        Self.secondDate(Date()),
                        id.uuidString,
                    ])
                try fault?("candidate.afterStatusWrite")
                guard let finalRow = try Row.fetchOne(db, sql: """
                    SELECT * FROM memory_candidates WHERE id = ?
                    """, arguments: [id.uuidString]) else {
                    throw MemoryAdapterError.notFound("candidateMissing")
                }
                let finalRaw = FacadeCandidateRawRow(finalRow)
                let committed = try finalRaw.candidateDTO(digest: finalRaw.digest)
                if committed.status == .pending {
                    throw MemoryAdapterError
                        .persistenceUnavailable("candidateResolveDidNotApply")
                }
                if activate {
                    guard let entryRow = try Row.fetchOne(db, sql: """
                        SELECT * FROM memory_entries WHERE id = ?
                        """, arguments: [id.uuidString]) else {
                        throw MemoryAdapterError
                            .persistenceUnavailable("candidateResolveDidNotApply")
                    }
                    let entryRaw = FacadeMemoryRawRow(entryRow)
                    let entryDTO = try FacadeMemoryRowCodec.entry(from: entryRaw,
                                                                  digest: entryRaw.digest)
                    return SettingsDomainV1.MemoryCandidateResolveReply(
                        status: .activated, entry: entryDTO)
                }
                return SettingsDomainV1.MemoryCandidateResolveReply(
                    status: .rejected, entry: nil)
            }
        } catch let error as MemoryAdapterError {
            throw error
        } catch let error as DatabaseError
            where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            // Activation content colliding with another live row's
            // (scope, owner, normalized_content) UNIQUE: the WHOLE
            // transaction rolled back (candidate still pending, no entry);
            // typed, never raw. Other constraints are NOT reported as a
            // content duplicate.
            throw MemoryAdapterError.invalidEnvelope("memoryDuplicateContent")
        } catch {
            throw MemoryAdapterError.persistenceUnavailable(nil)
        }
    }

    // MARK: - Shared helpers

    private func validateScopeIdentities(scope: MemoryScope?,
                                         originConversationID: UUID?,
                                         originWorkspaceID: UUID?) async throws {
        if case .workspace(let id)? = scope {
            guard try await workspaceStore.workspace(id: id) != nil else {
                throw MemoryAdapterError.notFound("workspaceMissing")
            }
        }
        if case .task(let id)? = scope {
            guard try await conversationStore.conversation(id: id) != nil else {
                throw MemoryAdapterError.notFound("conversationMissing")
            }
        }
        if let originWorkspaceID {
            guard try await workspaceStore.workspace(id: originWorkspaceID) != nil else {
                throw MemoryAdapterError.notFound("workspaceMissing")
            }
        }
        if let originConversationID {
            guard try await conversationStore.conversation(id: originConversationID) != nil else {
                throw MemoryAdapterError.notFound("conversationMissing")
            }
        }
    }

    static func secondDate(_ date: Date) -> String { FacadeStoreTime.second(date) }

    static func nativeScopeThrowing(_ scope: SettingsDomainV1.MemoryScope) throws
        -> MemoryScope
    {
        switch scope.kind {
        case .user: return .userProfile
        case .agent: return .agentGlobal
        case .workspace:
            guard let id = scope.workspaceID else {
                throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:scope")
            }
            return .workspace(id)
        case .task:
            guard let id = scope.conversationID else {
                throw MemoryAdapterError.invalidEnvelope("invalidPayloadField:scope")
            }
            return .task(id)
        }
    }

    /// EXACT copy of the original private Self.scope triple
    /// (IntelligenceStore.swift:1377-1384).
    static func scopeTriple(_ scope: MemoryScope) -> (String, UUID?, UUID?) {
        switch scope {
        case .userProfile: ("user", nil, nil)
        case .agentGlobal: ("agent", nil, nil)
        case .workspace(let id): ("workspace", id, nil)
        case .task(let id): ("task", nil, id)
        }
    }

    static func normalizeFactKey(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().prefix(160))
    }

    /// Mirrors IntelligenceStore.swift:977-993 EXACTLY (delete + tombstone
    /// upsert with the CASE/MAX ordering semantics).
    static func deleteWithTombstone(id: String, revision: Int64,
                                    deletedAt: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM memory_entries WHERE id = ?", arguments: [id])
        try db.execute(sql: """
            INSERT INTO memory_tombstones (memory_id, deleted_at, sync_revision)
            VALUES (?, ?, ?) ON CONFLICT(memory_id) DO UPDATE SET
            deleted_at=CASE
                WHEN excluded.sync_revision >= memory_tombstones.sync_revision THEN excluded.deleted_at
                ELSE memory_tombstones.deleted_at
            END,
            sync_revision=MAX(memory_tombstones.sync_revision, excluded.sync_revision)
            """, arguments: [id, deletedAt, revision])
    }

    /// Original write failures surface typed: constraint collisions as
    /// memoryDuplicateContent; everything else persistenceUnavailable. Raw
    /// SQL text and row content never leak into wire reasons.
    static func translateWriteError(_ error: Error) -> MemoryAdapterError {
        if let databaseError = error as? DatabaseError,
           databaseError.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            return .invalidEnvelope("memoryDuplicateContent")
        }
        return .persistenceUnavailable(nil)
    }
}

// MARK: - Organizer support

extension SettingsDomainV1.MemorySuggestionKind {
    init?(native: MemoryOrganizationSuggestionKind) {
        switch native {
        case .exactDuplicate: self = .exactDuplicate
        case .sameFactReplacement: self = .sameFactReplacement
        case .possibleDuplicate: self = .possibleDuplicate
        case .expired: self = .expired
        case .missingOwnership: self = .missingOwnership
        }
    }

    var native: MemoryOrganizationSuggestionKind? {
        switch self {
        case .exactDuplicate: return .exactDuplicate
        case .sameFactReplacement: return .sameFactReplacement
        case .possibleDuplicate: return .possibleDuplicate
        case .expired: return .expired
        case .missingOwnership: return .missingOwnership
        }
    }
}

/// Semantic suggestion provider. The P4 mirror
/// (RuntimeFacadeSemanticOrganizer.swift) implements this over the REAL
/// configured general-auxiliary adapter (RB-2 credentials + qualified
/// transport). Provider absence is the honest typed `unavailable` outcome;
/// the organizer NEVER fabricates a model, a route or suggestions.
public enum MemorySemanticError: Error, Sendable, Equatable {
    case needsConfiguration
    case credentialUnavailable(String)
    case transportUnavailable
    case modelRedacted
    case invalidModelJSON
}

public protocol MemorySemanticProposalProviding: Sendable {
    /// Suggestions must be restricted to the provided inventory ids. The
    /// organizer re-validates (knownIDs, closed kinds, kind restrictions)
    /// REGARDLESS: model output is untrusted data, never authority
    /// (contract trustBoundary; commandTable entry 11.safety).
    func suggestions(for entries: [MemoryEntry],
                     allowAutomaticApplication: Bool) async throws
        -> [MemoryOrganizationSuggestion]
}

/// Typed cancellation outcome for the two async memory phases.
/// Wire mapping (binder): failure outcome `canceled{phase}` per
/// commandTable entry 11.failureOutcomes.
public enum MemoryOperationCanceled: Error, Sendable, Equatable {
    case phase(SettingsDomainV1.OperationCancelPhase)
}

/// Deterministic proposal derivation — a PURE MIRROR of organizationPreview
/// (IntelligenceStore.swift:539-588): the same grouping keys (case-
/// insensitive trimmed content; fact slot; expiry against `now`), the same
/// within-group ordering (updatedAt DESC over the SQL-ordered snapshot), the
/// same preferred choice (first), the SAME reason strings (the same
/// FloeL10n keys — catalog parity, never re-worded), and the same
/// canApplyAutomatically rules. Pinned by the equivalence host test that
/// compares the adapter proposal (suggestions, preferred ids,
/// canApplyAutomatically, entries) against the original method on bounded
/// fixture DBs with multiset equality; the original iterates
/// `Dictionary(grouping:).values`, whose order is not deterministic, so the
/// adapter additionally sorts its output canonically — an ORDERING-ONLY
/// deviation documented in HANDOFF §known. The original deterministic policy
/// is preserved by equivalence, not re-implemented ad hoc.
internal enum FacadeDeterministicPreview {
    struct Row: Sendable {
        let id: UUID
        let scope: MemoryScope
        let content: String
        let factKey: String?
        let updatedAt: Date
        let expiresAt: Date?
    }

    static func rows(from raws: [FacadeMemoryRawRow]) -> [Row] {
        raws.compactMap { raw in
            guard let id = UUID(uuidString: raw.id) else { return nil }
            return Row(id: id,
                       scope: nativeScope(from: raw),
                       content: raw.string("content") ?? "",
                       factKey: factKey(from: raw),
                       updatedAt: FacadeStoreTime.parse(raw.string("updated_at") ?? "")
                        ?? Date.distantPast,
                       expiresAt: raw.string("expires_at")
                        .map { FacadeStoreTime.parse($0) ?? Date.distantPast })
        }
    }

    /// ORIGINAL Self.memory(row) scope fallback semantics
    /// (IntelligenceStore.swift:1353-1362) for GROUPING comparisons: an
    /// ownerless workspace/task row decodes as agentGlobal exactly like the
    /// native projection; the CAS digest still covers the raw bytes.
    static func nativeScope(from raw: FacadeMemoryRawRow) -> MemoryScope {
        switch raw.scopeName {
        case "workspace":
            if let owner = raw.string("workspace_id") ?? raw.string("origin_workspace_id"),
               let id = UUID(uuidString: owner) {
                return .workspace(id)
            }
            return .agentGlobal
        case "task":
            if let owner = raw.string("conversation_id") ?? raw.string("origin_conversation_id"),
               let id = UUID(uuidString: owner) {
                return .task(id)
            }
            return .agentGlobal
        case "user":
            return .userProfile
        default:
            return .agentGlobal
        }
    }

    static func factKey(from raw: FacadeMemoryRawRow) -> String? {
        guard let subject = raw.string("subject_key"), !subject.isEmpty,
              let attribute = raw.string("attribute_key"), !attribute.isEmpty else {
            return nil
        }
        return subject + "|" + attribute
    }

    static func derive(rows: [Row], now: Date)
        -> [MemoryOrganizationSuggestion]
    {
        var suggestions: [MemoryOrganizationSuggestion] = []
        let exactGroups = Dictionary(grouping: rows) {
            $0.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        for group in exactGroups.values where group.count > 1 {
            let ordered = group.sorted { $0.updatedAt > $1.updatedAt }
            suggestions.append(MemoryOrganizationSuggestion(
                kind: .exactDuplicate,
                memoryIDs: ordered.map(\.id),
                preferredMemoryID: ordered.first?.id,
                reason: FloeL10n.l("runtime.intelligence_store.the_content_is_identical_cross_scope"),
                canApplyAutomatically: Set(ordered.map(\.scope)).count == 1
            ))
        }
        let factGroups = Dictionary(grouping: rows.filter { $0.factKey != nil }) {
            $0.factKey!
        }
        for group in factGroups.values where group.count > 1 {
            let ordered = group.sorted { $0.updatedAt > $1.updatedAt }
            let staysWithinOneScope = Set(ordered.map(\.scope)).count == 1
            suggestions.append(MemoryOrganizationSuggestion(
                kind: .sameFactReplacement,
                memoryIDs: ordered.map(\.id),
                preferredMemoryID: ordered.first?.id,
                reason: staysWithinOneScope
                    ? FloeL10n.l("runtime.intelligence_store.a_fact_slot_in_the_same")
                    : FloeL10n.l("runtime.intelligence_store.the_same_fact_slot_has_different"),
                canApplyAutomatically: staysWithinOneScope
            ))
        }
        for row in rows where row.expiresAt.map({ $0 <= now }) == true {
            suggestions.append(MemoryOrganizationSuggestion(
                kind: .expired,
                memoryIDs: [row.id],
                reason: FloeL10n.l("runtime.intelligence_store.the_memory_has_passed_its_validity"),
                canApplyAutomatically: false
            ))
        }
        return canonicalOrder(suggestions)
    }

    /// Deterministic wire ordering over the original's unordered grouping
    /// (ordering only — membership/fields identical).
    static func canonicalOrder(_ suggestions: [MemoryOrganizationSuggestion])
        -> [MemoryOrganizationSuggestion]
    {
        func category(_ kind: MemoryOrganizationSuggestionKind) -> Int {
            switch kind {
            case .exactDuplicate: return 0
            case .sameFactReplacement: return 1
            case .possibleDuplicate: return 2
            case .expired: return 3
            case .missingOwnership: return 4
            }
        }
        return suggestions.sorted { lhs, rhs in
            if category(lhs.kind) != category(rhs.kind) {
                return category(lhs.kind) < category(rhs.kind)
            }
            let left = lhs.memoryIDs.map(\.uuidString).sorted()
            let right = rhs.memoryIDs.map(\.uuidString).sorted()
            if left != right { return left.lexicographicallyPrecedes(right) }
            return (lhs.preferredMemoryID?.uuidString ?? "")
                < (rhs.preferredMemoryID?.uuidString ?? "")
        }
    }

    /// Static merging rules, mirrored EXACTLY from the original
    /// (MemoryView.swift:817-847): the same (kind, sorted ids) key merges
    /// with the semantic suggestion replacing the deterministic one ONLY
    /// when the semantic form is automatic and the deterministic form is
    /// not.
    static func merging(_ deterministic: [MemoryOrganizationSuggestion],
                        _ semantic: [MemoryOrganizationSuggestion])
        -> [MemoryOrganizationSuggestion]
    {
        func key(_ suggestion: MemoryOrganizationSuggestion) -> String {
            suggestion.kind.rawValue + ":" + suggestion.memoryIDs
                .map(\.uuidString).sorted().joined(separator: ",")
        }
        var result = deterministic
        var indexByKey: [String: Int] = [:]
        for (offset, suggestion) in result.enumerated() {
            indexByKey[key(suggestion)] = offset
        }
        for suggestion in semantic {
            let suggestionKey = key(suggestion)
            if let index = indexByKey[suggestionKey] {
                if suggestion.canApplyAutomatically,
                   !result[index].canApplyAutomatically {
                    result[index] = suggestion
                }
            } else {
                indexByKey[suggestionKey] = result.count
                result.append(suggestion)
            }
        }
        return result
    }

    /// EXACT mirror of MemoryView.automaticDeleteIDs (:242-254).
    static func automaticDeleteIDs(
        in suggestions: [MemoryOrganizationSuggestion]) -> Set<UUID>
    {
        Set(suggestions.flatMap { suggestion -> [UUID] in
            guard suggestion.canApplyAutomatically else { return [] }
            if suggestion.kind == .expired { return suggestion.memoryIDs }
            guard [.exactDuplicate, .possibleDuplicate, .sameFactReplacement]
                .contains(suggestion.kind),
                  let preferred = suggestion.preferredMemoryID,
                  suggestion.memoryIDs.contains(preferred) else { return [] }
            return suggestion.memoryIDs.filter { $0 != preferred }
        })
    }

    /// EXACT deleteIDs derivation of native applyOrganizationSuggestion
    /// (MemoryView.swift:256-266).
    static func applyDeleteIDs(
        for suggestion: MemoryOrganizationSuggestion) -> [UUID]
    {
        if suggestion.kind == .expired {
            return suggestion.memoryIDs
        } else if [.exactDuplicate, .possibleDuplicate, .sameFactReplacement]
            .contains(suggestion.kind),
            let preferred = suggestion.preferredMemoryID {
            return suggestion.memoryIDs.filter { $0 != preferred }
        }
        return []
    }

    /// Untrusted-output re-validation applied ON TOP of the P4 mirror's own
    /// knownIDs gate (defense in depth, commandTable entry 11.safety):
    /// closed kinds, ids restricted to the known inventory set,
    /// exactDuplicate never accepted from the model, possibleDuplicate
    /// requires ≥2 ids, canApplyAutomatically only under modelManaged +
    /// the original kind/preferred restrictions (:793-814).
    static func revalidateModelSuggestions(
        _ semantic: [MemoryOrganizationSuggestion],
        knownIDs: Set<UUID>,
        allowAutomaticApplication: Bool)
        -> [MemoryOrganizationSuggestion]
    {
        semantic.compactMap { suggestion in
            let ids = Array(Set(suggestion.memoryIDs.filter { knownIDs.contains($0) })).sorted {
                $0.uuidString < $1.uuidString
            }
            guard !ids.isEmpty,
                  suggestion.kind != .exactDuplicate,
                  suggestion.kind != .possibleDuplicate || ids.count > 1 else { return nil }
            let preferred = suggestion.preferredMemoryID.flatMap { ids.contains($0) ? $0 : nil }
            let canApplyAutomatically = allowAutomaticApplication
                && (suggestion.kind == .expired
                    || ([.possibleDuplicate, .sameFactReplacement].contains(suggestion.kind)
                        && preferred != nil))
            return MemoryOrganizationSuggestion(
                kind: suggestion.kind,
                memoryIDs: ids,
                preferredMemoryID: preferred,
                reason: suggestion.reason,
                canApplyAutomatically: canApplyAutomatically)
        }
    }
}

// MARK: - FacadeMemoryOrganizer

/// memory.organize.* orchestration over the ORIGINAL shared APIs with a
/// single proposal snapshot for freshness (commandTable entry 11):
/// maintainMemoryLifecycle (original actor, OUTSIDE transactions) → ONE
/// reader transaction capturing the EXACT organizationPreview SQL and the
/// EXACT listMemories(status:.active, limit:500) SQL plus EVERY referenced
/// row's canonical digest BEFORE any semantic await → pure equivalence-
/// pinned derivation → optional semantic pass over the SAME snapshot
/// inventory (never a fake success) → static merge → automatic deletions in
/// ONE writer transaction over the union of automatic-suggestion referenced
/// ids (delete targets AND preferred/retained rows): ledger-first, digest-
/// gated, all-or-nothing. Any changed-but-existing, owner-detached/re-owned
/// (preserve* columns) or missing row → ZERO automatic deletions, NO ledger
/// row, staleIDs reported, proposal marked stale. The proposal handle is
/// process-lifetime and bounded; NEVER durable; recovery is a real re-read.
public actor FacadeMemoryOrganizer {
    private let database: DatabaseManager
    private let intelligenceStore: SQLiteIntelligenceStore
    private let semanticProvider: (any MemorySemanticProposalProviding)?
    private let proposals = FacadeProposalStore()
    private let operations = FacadeAsyncOperationRegistry()

    public init(database: DatabaseManager,
                intelligenceStore: SQLiteIntelligenceStore,
                semanticProvider: (any MemorySemanticProposalProviding)?) {
        self.database = database
        self.intelligenceStore = intelligenceStore
        self.semanticProvider = semanticProvider
    }

    /// Registry safe point translated to the typed wire outcome.
    private func cancellationPoint(_ receipt: String) throws {
        do {
            try operations.cancellationPoint(receipt)
        } catch is FacadeAsyncOperationRegistry.OperationCanceled {
            throw MemoryOperationCanceled.phase(
                operations.phase(of: receipt) ?? .queued)
        }
    }

    // MARK: - start

    public func start(mode: SettingsDomainV1.OrganizeMode,
                      includeSemantic: Bool,
                      operationReceiptID: String) async throws
        -> SettingsDomainV1.MemoryOrganizeStartEffect
    {
        operations.begin(operationReceiptID, phase: .queued)
        do {
            let effect = try await executeStart(mode: mode,
                                                includeSemantic: includeSemantic,
                                                receipt: operationReceiptID)
            operations.finish(operationReceiptID,
                              outcome: .completed(phase: .committed))
            return effect
        } catch let canceled as MemoryOperationCanceled {
            switch canceled {
            case .phase(let phase):
                operations.finish(operationReceiptID, outcome: .canceled(phase: phase))
            }
            throw canceled
        } catch {
            // Real failure terminal: keep the last recorded phase honest.
            operations.finish(operationReceiptID,
                              outcome: .completed(
                                phase: operations.phase(of: operationReceiptID) ?? .apply))
            throw error
        }
    }

    private func executeStart(mode: SettingsDomainV1.OrganizeMode,
                              includeSemantic: Bool,
                              receipt: String) async throws
        -> SettingsDomainV1.MemoryOrganizeStartEffect
    {
        try cancellationPoint(receipt)
        // (1) ORIGINAL actor call, OUTSIDE any transaction.
        operations.advance(receipt, phase: .scan)
        try await intelligenceStore.maintainMemoryLifecycle()
        // (2)+(3) ONE proposal SNAPSHOT reader transaction: exact
        // organizationPreview SQL (:541-545) + exact listMemories
        // (status:.active, limit:500) SQL/ordering (:466-521 page one) as
        // raw DatabaseValue rows with per-row digests.
        let database = self.database
        let snapshot = try await database.reader { db -> ([FacadeMemoryRawRow], [FacadeMemoryRawRow]) in
            let previewRows = try Row.fetchAll(db, sql: """
                SELECT * FROM memory_entries ORDER BY updated_at DESC LIMIT ?
                """, arguments: [10_000]).map(FacadeMemoryRawRow.init)
            let inventoryRows = try Row.fetchAll(db, sql: """
                SELECT * FROM memory_entries
                WHERE status = ?
                ORDER BY is_pinned DESC, importance DESC, updated_at DESC, id
                LIMIT ? OFFSET ?
                """, arguments: ["active", 500, 0]).map(FacadeMemoryRawRow.init)
            return (previewRows, inventoryRows)
        }
        let now = Date()
        let generatedAt = FacadeStoreTime.second(now)
        let previewRows = snapshot.0
        let inventoryRows = snapshot.1
        // (4) BEFORE any semantic await: expected digests for EVERY
        // deterministic-referenced id AND every inventory row, captured
        // from this same snapshot (a row cannot change between derivation
        // and digest capture).
        var expectedDigests: [UUID: String] = [:]
        for raw in previewRows + inventoryRows {
            if let id = UUID(uuidString: raw.id) {
                expectedDigests[id] = raw.digest
            }
        }
        let derivedRows = FacadeDeterministicPreview.rows(from: previewRows)
        let deterministic = FacadeDeterministicPreview.derive(rows: derivedRows, now: now)
        // (5) Semantic pass over the SAME snapshot inventory, native gate
        // parity (MemoryView.swift:180 `inventory.count > 1`).
        var semanticOutcome: SettingsDomainV1.MemoryOrganizeStartEffect.Semantic = .skipped
        var semanticSuggestions: [MemoryOrganizationSuggestion] = []
        if includeSemantic, inventoryRows.count > 1 {
            operations.advance(receipt, phase: .semantic)
            try cancellationPoint(receipt)
            if let provider = semanticProvider {
                do {
                    let nativeInventory = try inventoryRows.map {
                        try Self.nativeEntry(from: $0)
                    }
                    let known = Set(nativeInventory.map(\.id))
                    let rawSuggestions = try await provider.suggestions(
                        for: nativeInventory,
                        allowAutomaticApplication: mode == .modelManaged)
                    semanticSuggestions = FacadeDeterministicPreview
                        .revalidateModelSuggestions(rawSuggestions,
                                                    knownIDs: known,
                                                    allowAutomaticApplication: mode == .modelManaged)
                    semanticOutcome = .applied
                } catch let error as MemorySemanticError {
                    switch error {
                    case .needsConfiguration:
                        semanticOutcome = .unavailable(reason: .needsConfiguration)
                    case .credentialUnavailable:
                        semanticOutcome = .unavailable(reason: .credentialUnavailable)
                    case .transportUnavailable:
                        semanticOutcome = .unavailable(reason: .transportUnavailable)
                    case .modelRedacted:
                        semanticOutcome = .unavailable(reason: .modelError)
                    case .invalidModelJSON:
                        semanticOutcome = .unavailable(reason: .invalidModelJSON)
                    }
                } catch is CancellationError {
                    // The mailbox canceled this operation's task during the
                    // cloud stream: cooperative cancel at this safe point.
                    throw MemoryOperationCanceled.phase(.semantic)
                }
            } else {
                // Route/adapter/credentials not attached (P4 dependency):
                // deterministic-only, typed, NEVER a fake success.
                semanticOutcome = .unavailable(reason: .needsConfiguration)
            }
        }
        // (6) Pure merge (mirrors the original static merging rules).
        let merged = FacadeDeterministicPreview.canonicalOrder(
            FacadeDeterministicPreview.merging(deterministic, semanticSuggestions))
        let wireSuggestions = merged.map {
            SettingsDomainV1.MemoryOrganizeSuggestion(
                id: $0.id,
                kind: SettingsDomainV1.MemorySuggestionKind(native: $0.kind) ?? .possibleDuplicate,
                memoryIDs: $0.memoryIDs,
                preferredMemoryID: $0.preferredMemoryID,
                reason: $0.reason,
                canApplyAutomatically: $0.canApplyAutomatically)
        }
        let referencedIDs = Set(merged.flatMap(\.memoryIDs))
        let entrySummaries = try previewRows
            .filter { raw in
                guard let id = UUID(uuidString: raw.id) else { return false }
                return referencedIDs.contains(id)
            }
            .map { try Self.entrySummary(from: $0) }
        // (7) Automatic deletes (canApplyAutomatically suggestions only,
        // mode-gated exactly as native automaticDeleteIDs) in ONE writer
        // transaction over the union of automatic-suggestion referenced
        // ids — DELETE TARGETS AND PREFERRED/RETAINED ROWS. Fresh REAL
        // autoBatchID per start attempt; internal retries of THIS
        // transaction reuse it; a later user re-run is a new attempt.
        let automaticDeletes = FacadeDeterministicPreview.automaticDeleteIDs(in: merged)
        var autoDelete = SettingsDomainV1.MemoryOrganizeStartAutoDelete(status: .none,
                                                                        batchID: nil,
                                                                        staleIDs: [])
        var proposalStale = false
        var autoDeletedCount = 0
        if !automaticDeletes.isEmpty {
            operations.advance(receipt, phase: .apply)
            try cancellationPoint(receipt)
            // Immutable snapshot for the @Sendable writer closure.
            let expectedSnapshot = expectedDigests
            let autoBatchID = UUID()
            let allReferenced = Set(merged.filter(\.canApplyAutomatically).flatMap(\.memoryIDs))
            let syncRevision = FacadeStoreTime.wallClockMillis(Date())
            let deletedAt = FacadeStoreTime.second(now)
            let outcome: (applied: Int, stale: [UUID], missing: [UUID]) =
                try await database.writer { db in
                    let ledgerExists = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM memory_maintenance_batches WHERE id = ?)
                        """, arguments: [autoBatchID.uuidString]) ?? false
                    if ledgerExists {
                        // Fresh UUID cannot pre-exist; honest zero path.
                        return (applied: 0, stale: [], missing: [])
                    }
                    var stale: [UUID] = []
                    var missing: [UUID] = []
                    for id in allReferenced {
                        guard let expected = expectedSnapshot[id] else {
                            missing.append(id)
                            continue
                        }
                        guard let row = try Row.fetchOne(db, sql: """
                            SELECT * FROM memory_entries WHERE id = ?
                            """, arguments: [id.uuidString]) else {
                            missing.append(id)
                            continue
                        }
                        if FacadeMemoryRawRow(row).digest != expected {
                            stale.append(id)
                        }
                    }
                    guard stale.isEmpty, missing.isEmpty else {
                        // ZERO destructive mutation, NO ledger row.
                        return (applied: -1,
                               stale: stale.sorted { $0.uuidString < $1.uuidString },
                               missing: missing.sorted { $0.uuidString < $1.uuidString })
                    }
                    var applied = 0
                    for id in automaticDeletes.sorted(by: { $0.uuidString < $1.uuidString }) {
                        try FacadeMemoryAdapter.deleteWithTombstone(
                            id: id.uuidString,
                            revision: syncRevision,
                            deletedAt: deletedAt,
                            db: db)
                        applied += 1
                    }
                    try db.execute(sql: """
                        INSERT INTO memory_maintenance_batches (
                            id, operation_count, deleted_count, replaced_count,
                            sync_revision, applied_at
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [autoBatchID.uuidString, applied, applied, 0,
                                         syncRevision, FacadeStoreTime.second(Date())])
                    return (applied: applied, stale: [], missing: [])
                }
            if outcome.applied < 0 {
                let staleIDs = (outcome.stale + outcome.missing)
                    .sorted { $0.uuidString < $1.uuidString }
                proposalStale = true
                autoDelete = SettingsDomainV1.MemoryOrganizeStartAutoDelete(
                    status: .staleRejected, batchID: nil, staleIDs: staleIDs)
            } else if outcome.applied == 0 {
                autoDelete = SettingsDomainV1.MemoryOrganizeStartAutoDelete(
                    status: .none, batchID: nil, staleIDs: [])
            } else {
                autoDeletedCount = outcome.applied
                autoDelete = SettingsDomainV1.MemoryOrganizeStartAutoDelete(
                    status: .applied, batchID: autoBatchID, staleIDs: [])
            }
        }
        // (8) The process-lifetime proposal handle stores expected digests,
        // deterministic/model provenance and the auto-delete outcome —
        // bounded, never durable.
        let proposalHandle = FacadeProposalStore.mintHandle()
        proposals.store(handle: proposalHandle,
                        proposal: FacadeProposalStore.Proposal(
                            proposalID: UUID(),
                            generatedAt: generatedAt,
                            scannedCount: previewRows.count,
                            suggestions: wireSuggestions,
                            entries: entrySummaries,
                            expectedDigests: expectedDigests,
                            modelProvenance: semanticOutcome == .applied,
                            stale: proposalStale,
                            staleIDs: autoDelete.staleIDs,
                            autoDelete: SettingsDomainV1.MemoryOrganizeAutoDelete(
                                status: autoDelete.status,
                                batchID: autoDelete.batchID)))
        return SettingsDomainV1.MemoryOrganizeStartEffect(
            scannedCount: previewRows.count,
            autoDeletedCount: autoDeletedCount,
            pendingReviewCount: merged.filter { !$0.canApplyAutomatically }.count,
            autoDelete: autoDelete,
            proposalStale: proposalStale,
            semantic: semanticOutcome,
            proposalHandle: proposalHandle)
    }

    /// ORIGINAL Self.memory(row) reconstruction for the semantic provider
    /// prompt (MemoryView.swift:740-742 consumes entry.scope/content/
    /// updatedAt; the clamps come from the original init).
    static func nativeEntry(from raw: FacadeMemoryRawRow) throws
        -> MemoryEntry
    {
        let corrupt = MemoryAdapterError.persistenceUnavailable("corruptMemoryRow")
        guard let id = UUID(uuidString: raw.id),
              let status = MemoryEntryStatus(rawValue: raw.statusRaw),
              let source = MemoryCandidateOrigin(rawValue: raw.sourceKindRaw),
              let content = raw.string("content") else {
            throw corrupt
        }
        var factIdentity: MemoryFactIdentity?
        if let subject = raw.string("subject_key"), let attribute = raw.string("attribute_key") {
            factIdentity = MemoryFactIdentity(subjectKey: subject, attributeKey: attribute)
        }
        return MemoryEntry(
            id: id, scope: FacadeDeterministicPreview.nativeScope(from: raw),
            status: status, content: content, confidence: raw.confidence,
            importance: raw.importance,
            isPinned: raw.isPinnedInteger != 0, sourceKind: source,
            originConversationID: raw.string("origin_conversation_id")
                .flatMap(UUID.init(uuidString:)),
            originWorkspaceID: raw.string("origin_workspace_id")
                .flatMap(UUID.init(uuidString:)),
            factIdentity: factIdentity,
            expiresAt: raw.string("expires_at").flatMap(FacadeStoreTime.parse),
            createdAt: FacadeStoreTime.parse(raw.string("created_at") ?? "") ?? .distantPast,
            updatedAt: FacadeStoreTime.parse(raw.string("updated_at") ?? "") ?? .distantPast)
    }

    /// The ORIGINAL summary projection (MemoryOrganizationEntrySummary init,
    /// MemoryMaintenance.swift:65-75): the 1024-char store-level prefix is
    /// a STORE projection, not wire truncation; full content stays
    /// reachable via memory.get.
    static func entrySummary(from raw: FacadeMemoryRawRow) throws
        -> SettingsDomainV1.MemoryOrganizeEntrySummary
    {
        guard let id = UUID(uuidString: raw.id),
              let wireStatus = SettingsDomainV1.MemoryEntryStatus(rawValue: raw.statusRaw) else {
            throw MemoryAdapterError.persistenceUnavailable("corruptMemoryRow")
        }
        let entry = try nativeEntry(from: raw)
        let wireScope: SettingsDomainV1.MemoryScope
        switch entry.scope {
        case .userProfile:
            wireScope = try SettingsDomainV1.MemoryScope(kind: .user)
        case .agentGlobal:
            wireScope = try SettingsDomainV1.MemoryScope(kind: .agent)
        case .workspace(let workspaceID):
            wireScope = try SettingsDomainV1.MemoryScope(kind: .workspace,
                                                         workspaceID: workspaceID)
        case .task(let conversationID):
            wireScope = try SettingsDomainV1.MemoryScope(kind: .task,
                                                         conversationID: conversationID)
        }
        var factIdentity: SettingsDomainV1.FactIdentity?
        if let identity = entry.factIdentity {
            factIdentity = SettingsDomainV1.FactIdentity(subjectKey: identity.subjectKey,
                                                         attributeKey: identity.attributeKey)
        }
        return SettingsDomainV1.MemoryOrganizeEntrySummary(
            id: id,
            scope: wireScope,
            status: wireStatus,
            content: String((raw.string("content") ?? "").prefix(1_024)),
            factIdentity: factIdentity,
            originConversationID: entry.originConversationID,
            originWorkspaceID: entry.originWorkspaceID,
            updatedAt: raw.string("updated_at") ?? "")
    }

    // MARK: - proposal.read

    /// Owned-handle read over the REAL proposal snapshot (commandTable
    /// entry 12). Both lists are paged from the SAME client-owned offset
    /// cursor and advance together, so a budget-stopped page loses nothing:
    /// the cursor only moves past items actually delivered.
    public func proposalPage(_ request: MemoryProposalReadRequest) async throws
        -> SettingsDomainV1.MemoryOrganizeProposalReply
    {
        let proposal: FacadeProposalStore.Proposal
        switch proposals.lookup(request.handle) {
        case .found(let stored): proposal = stored
        case .expired:
            throw MemoryAdapterError.notFound("handleExpired")
        case .unknown:
            throw MemoryAdapterError.notFound("handleUnknown")
        }
        let limit = min(SettingsDomainV1.maximumOrganizeProposalPage,
                        max(1, request.limit))
        let start = min(request.cursor, max(proposal.suggestions.count,
                                            proposal.entries.count))
        let suggestionSlice = Array(proposal.suggestions.dropFirst(start).prefix(limit))
        let entrySlice = Array(proposal.entries.dropFirst(start).prefix(limit))
        func reply(_ suggestions: [SettingsDomainV1.MemoryOrganizeSuggestion],
                   _ entries: [SettingsDomainV1.MemoryOrganizeEntrySummary],
                   _ nextCursor: String?) -> SettingsDomainV1.MemoryOrganizeProposalReply {
            SettingsDomainV1.MemoryOrganizeProposalReply(
                proposalID: proposal.proposalID,
                generatedAt: proposal.generatedAt,
                scannedCount: proposal.scannedCount,
                suggestions: suggestions,
                entries: entries,
                nextCursor: nextCursor,
                stale: proposal.stale,
                staleIDs: proposal.staleIDs,
                autoDelete: proposal.autoDelete)
        }
        // Rows are atomic: the page is the index window
        // [start, start+acceptedCount) applied to BOTH lists; shrinking the
        // window when the complete encoded reply would exceed the 48 KiB
        // budget never loses data because the cursor advances exactly by
        // the delivered window size (a length difference between the two
        // lists simply continues on the next page).
        var acceptedCount = min(limit, max(suggestionSlice.count, entrySlice.count))
        acceptedCount = min(acceptedCount,
                            max(suggestionSlice.count, entrySlice.count))
        while acceptedCount > 0 {
            let trial = reply(Array(suggestionSlice.prefix(acceptedCount)),
                              Array(entrySlice.prefix(acceptedCount)),
                              String(start + acceptedCount))
            if FacadeWireBytes.count(trial) <= SettingsDomainV1.pageBudgetBytes { break }
            acceptedCount -= 1
        }
        if acceptedCount == 0, !suggestionSlice.isEmpty, !entrySlice.isEmpty {
            // A single paired window could not fit: never silently skipped.
            // Unreachable for ≤500-char reasons + ≤1024-char summaries under
            // the 48 KiB budget; kept typed rather than truncating items.
            throw MemoryAdapterError.persistenceUnavailable("pageItemOverBudget")
        }
        let nextStart = start + acceptedCount
        let hasMore = nextStart < max(proposal.suggestions.count,
                                      proposal.entries.count)
        return reply(Array(suggestionSlice.prefix(acceptedCount)),
                     Array(entrySlice.prefix(acceptedCount)),
                     hasMore ? String(nextStart) : nil)
    }

    // MARK: - apply

    /// Explicit user-driven application of one proposal suggestion through
    /// the batch adapter transaction (commandTable entry 13): ledger-first
    /// replay; per-id full-row digests for ALL rows referenced by the
    /// suggestion — delete targets AND preferred/retained group members —
    /// compared against the GENERATION snapshot inside the same
    /// transaction; any changed-but-existing, owner-detached/re-owned
    /// (preserve* columns) or missing row → zero mutation, no ledger row,
    /// staleRevision{staleIDs|missingIDs}. The original existence precheck
    /// is subsumed: a same-id edit still exists but MUST fail.
    public func apply(_ request: MemoryOrganizeApplyRequest) async throws
        -> SettingsDomainV1.MemoryOrganizeApplyReply
    {
        let proposal: FacadeProposalStore.Proposal
        switch proposals.lookup(request.handle) {
        case .found(let stored): proposal = stored
        case .expired:
            throw MemoryAdapterError.notFound("handleExpired")
        case .unknown:
            throw MemoryAdapterError.notFound("handleUnknown")
        }
        guard let wire = proposal.suggestions.first(where: { $0.id == request.suggestionID }) else {
            throw MemoryAdapterError.notFound("suggestionUnknown")
        }
        guard let kind = wire.kind.native else {
            throw MemoryAdapterError.notFound("suggestionNotApplicable")
        }
        let native = MemoryOrganizationSuggestion(
            id: wire.id, kind: kind, memoryIDs: wire.memoryIDs,
            preferredMemoryID: wire.preferredMemoryID,
            reason: wire.reason, canApplyAutomatically: wire.canApplyAutomatically)
        let deleteIDs = FacadeDeterministicPreview.applyDeleteIDs(for: native)
        guard !deleteIDs.isEmpty else {
            throw MemoryAdapterError.notFound("suggestionNotApplicable")
        }
        let referenced = native.memoryIDs
        let expected = proposal.expectedDigests
        let database = self.database
        do {
            return try await database.writer { db in
                if let ledger = try Row.fetchOne(db, sql: """
                    SELECT deleted_count FROM memory_maintenance_batches WHERE id = ?
                    """, arguments: [request.batchID.uuidString]) {
                    let deletedCount: Int64 = ledger["deleted_count"]
                    return SettingsDomainV1.MemoryOrganizeApplyReply(
                        batchID: request.batchID, result: .alreadyApplied,
                        deletedCount: Int(deletedCount))
                }
                var seen = Set<UUID>()
                for id in deleteIDs {
                    guard seen.insert(id).inserted else {
                        throw MemoryAdapterError.invalidEnvelope("duplicateBatchEntry")
                    }
                }
                var stale: [UUID] = []
                var missing: [UUID] = []
                for id in referenced {
                    guard let expectedDigest = expected[id] else {
                        missing.append(id)
                        continue
                    }
                    guard let row = try Row.fetchOne(db, sql: """
                        SELECT * FROM memory_entries WHERE id = ?
                        """, arguments: [id.uuidString]) else {
                        missing.append(id)
                        continue
                    }
                    if FacadeMemoryRawRow(row).digest != expectedDigest {
                        stale.append(id)
                    }
                }
                guard stale.isEmpty, missing.isEmpty else {
                    throw MemoryAdapterError.staleRevision(
                        staleIDs: stale.sorted { $0.uuidString < $1.uuidString },
                        missingIDs: missing.sorted { $0.uuidString < $1.uuidString })
                }
                let deletedAt = FacadeStoreTime.second(Date())
                var deleted = 0
                for id in deleteIDs {
                    try FacadeMemoryAdapter.deleteWithTombstone(
                        id: id.uuidString,
                        revision: request.syncRevision,
                        deletedAt: deletedAt,
                        db: db)
                    deleted += 1
                }
                try db.execute(sql: """
                    INSERT INTO memory_maintenance_batches (
                        id, operation_count, deleted_count, replaced_count,
                        sync_revision, applied_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [request.batchID.uuidString, deleteIDs.count,
                                     deleted, 0, request.syncRevision,
                                     FacadeStoreTime.second(Date())])
                return SettingsDomainV1.MemoryOrganizeApplyReply(
                    batchID: request.batchID, result: .applied, deletedCount: deleted)
            }
        } catch let error as MemoryAdapterError {
            throw error
        } catch {
            throw MemoryAdapterError.persistenceUnavailable(nil)
        }
    }

    // MARK: - cancel

    /// memory.organize.cancel by operation receipt (commandTable entry 14;
    /// wire-stateless per-operation cancel, precedent system.shutdown).
    /// Queued-vs-started mailbox semantics belong to RB-1; this answers for
    /// operations the facade owns. DB transactions are not interruptible
    /// mid-commit: a cancel arriving after the terminal effect reports
    /// completed with the REAL final phase; the executing lifetime is
    /// accounted until the terminal effect, never freed early.
    public func cancel(operationReceiptID: String) -> SettingsDomainV1.OperationCancelReply? {
        operations.requestCancel(operationReceiptID)
    }
}
