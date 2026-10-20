// SPDX-License-Identifier: MPL-2.0
//
// P1 — Settings global-defaults adapter (private source candidate; UNCOMPILED).
//
// Authority: settings-domain-main-acceptance-20261019/input-final/contract.json
// (sha256 f3ddecdca061ae17fbe4280b7bfb549d8a1673fd8d9ae6e1ba363332ef5db46c),
// commandTable[0] config.defaults.get and commandTable[1] config.defaults.save;
// COMMANDS.md §2; IMPLEMENTATION_HANDOFF.md P1.
//
// Real dependencies:
// * ONE original DatabaseManager / schema 46 (FloePersistence).
// * app_settings rows written by the original SQLiteSettingsStore
//   (FloeAgent/Sources/FloePersistence/SettingsStore.swift:52-99).
// * typed decode shapes used by SettingsCenter.applyStoredValues
//   (FloeAgent/FloeApp/Settings/SettingsCenter.swift:326-380) and the original
//   FloeCore AgentMode / RunningInputMode / Bool Codable encodings.
//
// Why raw SQL here: the original SQLiteSettingsStore is single-key only and
// exposes no multi-key transaction, no CAS and no updated_at read. The public
// DatabaseManager.writer transaction is the ONLY original mechanism that can
// provide one atomic multi-key CAS. The adapter therefore mirrors the exact
// original single-key UPSERT statement (:64-73) and the exact read shape
// (:52-60/:86-99) while never editing shared source. No second database and
// no in-memory revision are introduced.
//
// No handler is registered by this file. A real host binder must inject the
// original DatabaseManager after P0 and the RB-1 mailbox have landed and Main
// has admitted publication.

import Foundation
import GRDB
import FloeCore
import FloePersistence

/// Typed failures of the global-defaults adapter.
///
/// `wireCode`/`wireReason` map directly to the frozen Settings-domain error
/// vocabulary. `persistenceUnavailable` deliberately carries no row values.
public enum SettingsDefaultsAdapterError: Error, Sendable, Equatable {
    case invalidEnvelope(String)
    case staleRevision
    case persistenceUnavailable(String?)

    public var wireCode: String {
        switch self {
        case .invalidEnvelope:
            return "invalidEnvelope"
        case .staleRevision:
            return "staleRevision"
        case .persistenceUnavailable:
            return "persistenceUnavailable"
        }
    }

    public var wireReason: String? {
        switch self {
        case .invalidEnvelope(let reason):
            return reason
        case .staleRevision:
            return nil
        case .persistenceUnavailable(let reason):
            return reason
        }
    }
}

/// Closed partial save payload: exactly the three whitelisted AppSettings keys.
/// Presence in this patch means "write this key explicitly"; absence means
/// "leave the current row (or absence) untouched".
public struct SettingsDefaultsPatch: Sendable, Equatable {
    public let defaultAgentMode: SettingsDomainV1.DefaultAgentMode?
    public let runningInputMode: SettingsDomainV1.RunningInputMode?
    public let verifyFinalAnswer: Bool?

    public init(defaultAgentMode: SettingsDomainV1.DefaultAgentMode? = nil,
                runningInputMode: SettingsDomainV1.RunningInputMode? = nil,
                verifyFinalAnswer: Bool? = nil) {
        self.defaultAgentMode = defaultAgentMode
        self.runningInputMode = runningInputMode
        self.verifyFinalAnswer = verifyFinalAnswer
    }

    public var isEmpty: Bool {
        defaultAgentMode == nil && runningInputMode == nil &&
            verifyFinalAnswer == nil
    }

    /// Structural parsing of the validated wire payload. P0 already enforces
    /// this grammar; the adapter repeats it so a direct caller can never widen
    /// the closed whitelist or bypass a typed check. Errors and reasons match
    /// commandTable[1].request and SettingsDomainV1.validateDefaultsSave.
    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws -> SettingsDefaultsPatch {
        guard let payload else {
            throw SettingsDefaultsAdapterError.invalidEnvelope("missingPayload")
        }
        guard case .object(let root) = payload else {
            throw SettingsDefaultsAdapterError.invalidEnvelope("invalidPayload")
        }
        for key in root.keys where key != "values" {
            throw SettingsDefaultsAdapterError.invalidEnvelope("unknownDefaultsField")
        }
        guard let valuesValue = root["values"] else {
            throw SettingsDefaultsAdapterError.invalidEnvelope("missingPayloadField:values")
        }
        guard case .object(let values) = valuesValue else {
            throw SettingsDefaultsAdapterError.invalidEnvelope("invalidPayloadField:values")
        }
        guard !values.isEmpty else {
            throw SettingsDefaultsAdapterError.invalidEnvelope("invalidPayloadField:values")
        }
        for key in values.keys where !SettingsGlobalDefaultsKeys.wireFields.contains(key) {
            throw SettingsDefaultsAdapterError.invalidEnvelope("unknownDefaultsField")
        }

        var mode: SettingsDomainV1.DefaultAgentMode?
        if let value = values["defaultAgentMode"] {
            guard case .string(let raw) = value,
                  let decoded = SettingsDomainV1.DefaultAgentMode(rawValue: raw) else {
                throw SettingsDefaultsAdapterError.invalidEnvelope(
                    "invalidDefaultsValue:defaultAgentMode"
                )
            }
            mode = decoded
        }
        var input: SettingsDomainV1.RunningInputMode?
        if let value = values["runningInputMode"] {
            guard case .string(let raw) = value,
                  let decoded = SettingsDomainV1.RunningInputMode(rawValue: raw) else {
                throw SettingsDefaultsAdapterError.invalidEnvelope(
                    "invalidDefaultsValue:runningInputMode"
                )
            }
            input = decoded
        }
        var verify: Bool?
        if let value = values["verifyFinalAnswer"] {
            guard case .boolean(let decoded) = value else {
                throw SettingsDefaultsAdapterError.invalidEnvelope(
                    "invalidDefaultsValue:verifyFinalAnswer"
                )
            }
            verify = decoded
        }
        return SettingsDefaultsPatch(defaultAgentMode: mode,
                                     runningInputMode: input,
                                     verifyFinalAnswer: verify)
    }
}

/// The three fixed rows in canonical order. Order is semantic: the
/// floe.settings-defaults.v2 record stream MUST use this order.
public enum SettingsGlobalDefaultsKeys {
    // Actual shared key constants (FloeAgent/Sources/FloeCore/AppSettings.swift:
    // 141-158). No literal copy and no App-only SettingsCenter import.
    public static let defaultAgentMode = AppSettingsKey.defaultAgentMode
    public static let runningInputMode = AppSettingsKey.runningInputMode
    public static let verifyFinalAnswer = AppSettingsKey.verifyFinalAnswer

    /// STORAGE keys (app_settings rows) — never the wire field names.
    public static let whitelist: [String] = [
        defaultAgentMode,
        runningInputMode,
        verifyFinalAnswer,
    ]

    /// WIRE field names of the closed AgentDefaultsDTO used by
    /// defaults.save. The storage keys above are `agent.*` row keys; the
    /// payload is camelCase (contract commandTable[1].request), so validating
    /// the payload against `whitelist` would reject every real field.
    public static let wireFields: [String] = [
        "defaultAgentMode",
        "runningInputMode",
        "verifyFinalAnswer",
    ]
}

/// Global default-policy backend. This is a FUTURE-RUN policy store only; it
/// never reads or writes ModelSelectionPreferences, and never touches an
/// active run's policy.
public actor FacadeSettingsDefaultsAdapter {
    public static let domain = SettingsDomainV1.CanonicalDigest.domainSettingsDefaults
    public static let keys = SettingsGlobalDefaultsKeys.whitelist

    private let database: DatabaseManager
    /// Internal, test-only fault seam. It runs INSIDE the writer transaction so
    /// a thrown error proves real rollback; it is never reachable from a
    /// production initializer and never substitutes a store.
    private let faultInjection: (@Sendable (Int) throws -> Void)?

    public init(database: DatabaseManager) {
        self.database = database
        self.faultInjection = nil
    }

    init(database: DatabaseManager,
         faultInjection: (@Sendable (Int) throws -> Void)?) {
        self.database = database
        self.faultInjection = faultInjection
    }

    // MARK: - Read

    /// ONE original DatabaseManager.reader transaction.
    public func read() async throws -> SettingsDomainV1.DefaultsReply {
        let database = self.database
        do {
            return try await database.reader { db in
                let raw = try Self.rawSnapshot(db)
                return try Self.reply(from: raw)
            }
        } catch let error as SettingsDefaultsAdapterError {
            throw error
        } catch {
            throw SettingsDefaultsAdapterError.persistenceUnavailable(nil)
        }
    }

    // MARK: - Save

    /// Parses the closed payload and saves it atomically. The returned reply is
    /// built from an in-transaction read-after-write, so it is visible only
    /// after the actual transaction commit.
    public func save(expectedRevision: String,
                     payload: SettingsDomainV1.JSONValue) async throws -> SettingsDomainV1.DefaultsReply {
        let patch = try SettingsDefaultsPatch.parse(payload)
        return try await save(expectedRevision: expectedRevision, patch: patch)
    }

    /// ONE original DatabaseManager.writer transaction:
    /// SELECT whitelist -> canonical raw-row digest -> CAS compare -> UPSERT
    /// only changed keys -> in-transaction read-after-write + new digest.
    public func save(expectedRevision: String,
                     patch: SettingsDefaultsPatch) async throws -> SettingsDomainV1.DefaultsReply {
        guard !patch.isEmpty else {
            throw SettingsDefaultsAdapterError.invalidEnvelope("invalidPayloadField:values")
        }
        let database = self.database
        let fault = self.faultInjection
        do {
            return try await database.writer { db in
                let before = try Self.rawSnapshot(db)
                // CAS is decided on the EXACT raw rows before any typed decode
                // or write. A stale client therefore learns staleRevision and
                // never inspects or mutates the concurrent writer's rows.
                guard before.digest == expectedRevision else {
                    throw SettingsDefaultsAdapterError.staleRevision
                }
                let decodedBefore = try Self.reply(from: before)

                var writes = 0
                func write(_ key: String, _ json: String) throws {
                    try db.execute(sql: Self.upsertSQL,
                                   arguments: [key, json, Self.timestamp(Date())])
                    writes += 1
                    if let fault {
                        try fault(writes)
                    }
                }

                if let mode = patch.defaultAgentMode,
                   !(decodedBefore.explicit.defaultAgentMode &&
                     decodedBefore.values.defaultAgentMode == mode) {
                    try write(SettingsGlobalDefaultsKeys.defaultAgentMode,
                              try Self.encode(Self.core(mode)))
                }
                if let input = patch.runningInputMode,
                   !(decodedBefore.explicit.runningInputMode &&
                     decodedBefore.values.runningInputMode == input) {
                    try write(SettingsGlobalDefaultsKeys.runningInputMode,
                              try Self.encode(Self.core(input)))
                }
                if let verify = patch.verifyFinalAnswer,
                   !(decodedBefore.explicit.verifyFinalAnswer &&
                     decodedBefore.values.verifyFinalAnswer == verify) {
                    try write(SettingsGlobalDefaultsKeys.verifyFinalAnswer,
                              try Self.encode(verify))
                }

                let after = try Self.rawSnapshot(db)
                return try Self.reply(from: after)
            }
        } catch let error as SettingsDefaultsAdapterError {
            throw error
        } catch {
            throw SettingsDefaultsAdapterError.persistenceUnavailable(nil)
        }
    }

    // MARK: - Row snapshot and canonical digest

    private struct StoredRow: Sendable {
        let valueJSON: DatabaseValue
        let updatedAt: DatabaseValue
    }

    private struct RawSnapshot: Sendable {
        /// Only present whitelist rows. Absence is the real "no row" state.
        let rows: [String: StoredRow]
        let digest: String
    }

    /// Exact three-record stream, in fixed whitelist order:
    /// [key TEXT, present INTEGER 0|1, value_json TEXT|NULL, updated_at TEXT|NULL].
    /// A present row is present=1 with the exact DatabaseValue storage classes.
    /// An absent row is present=0 with two SQL NULLs. No CAST/COALESCE and no
    /// delimiter are used; see SettingsDomainV1.CanonicalDigest.
    private static func rawSnapshot(_ db: Database) throws -> RawSnapshot {
        let placeholders = Array(repeating: "?", count: keys.count)
            .joined(separator: ", ")
        let sql = """
            SELECT key, value_json, updated_at
            FROM app_settings
            WHERE key IN (\(placeholders))
            ORDER BY key
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(keys))

        var present: [String: StoredRow] = [:]
        present.reserveCapacity(rows.count)
        for row in rows {
            let key: String = row["key"]
            guard keys.contains(key) else { continue }
            let valueJSON: DatabaseValue = row["value_json"]
            let updatedAt: DatabaseValue = row["updated_at"]
            present[key] = StoredRow(valueJSON: valueJSON,
                                     updatedAt: updatedAt)
        }

        let records: [[SettingsDomainV1.CanonicalDigest.Field]] = keys.map { key in
            if let row = present[key] {
                return [
                    .text(key),
                    .integer(1),
                    field(row.valueJSON),
                    field(row.updatedAt),
                ]
            }
            return [.text(key), .integer(0), .null, .null]
        }
        return RawSnapshot(
            rows: present,
            digest: SettingsDomainV1.CanonicalDigest.token(domain: domain,
                                                           records: records)
        )
    }

    private static func field(_ value: DatabaseValue) -> SettingsDomainV1.CanonicalDigest.Field {
        switch value.storage {
        case .null:
            return .null
        case .int64(let value):
            return .integer(value)
        case .double(let value):
            return .real(value)
        case .string(let value):
            return .text(value)
        case .blob(let value):
            return .blob(value)
        }
    }

    // MARK: - Typed decode (original Codable shapes)

    private static func reply(from snapshot: RawSnapshot) throws -> SettingsDomainV1.DefaultsReply {
        var mode = SettingsDomainV1.DefaultAgentMode.human
        var input = SettingsDomainV1.RunningInputMode.queue
        var verify = false
        var explicitMode = false
        var explicitInput = false
        var explicitVerify = false

        if let row = snapshot.rows[SettingsGlobalDefaultsKeys.defaultAgentMode] {
            explicitMode = true
            mode = try decodeAgentMode(row.valueJSON,
                                       key: SettingsGlobalDefaultsKeys.defaultAgentMode)
        }
        if let row = snapshot.rows[SettingsGlobalDefaultsKeys.runningInputMode] {
            explicitInput = true
            input = try decodeRunningInputMode(
                row.valueJSON,
                key: SettingsGlobalDefaultsKeys.runningInputMode
            )
        }
        if let row = snapshot.rows[SettingsGlobalDefaultsKeys.verifyFinalAnswer] {
            explicitVerify = true
            verify = try decodeBool(row.valueJSON,
                                    key: SettingsGlobalDefaultsKeys.verifyFinalAnswer)
        }

        return SettingsDomainV1.DefaultsReply(
            values: SettingsDomainV1.DefaultsValues(
                defaultAgentMode: mode,
                runningInputMode: input,
                verifyFinalAnswer: verify
            ),
            explicit: SettingsDomainV1.DefaultsExplicitness(
                defaultAgentMode: explicitMode,
                runningInputMode: explicitInput,
                verifyFinalAnswer: explicitVerify
            ),
            revision: snapshot.digest
        )
    }

    /// PRESENT-but-undecodable rows are a typed persistence failure, never a
    /// silent default substitution (contract commandTable[0].defaults, Main Q4).
    private static func corrupt(_ key: String) -> SettingsDefaultsAdapterError {
        .persistenceUnavailable("corruptSettingsKey:\(key)")
    }

    private static func text(_ value: DatabaseValue,
                             key: String) throws -> String {
        guard case .string(let raw) = value.storage else {
            throw corrupt(key)
        }
        return raw
    }

    private static func decodeAgentMode(_ value: DatabaseValue,
                                        key: String) throws -> SettingsDomainV1.DefaultAgentMode {
        let raw = try text(value, key: key)
        let decoded: FloeCore.AgentMode
        do {
            decoded = try JSONDecoder().decode(FloeCore.AgentMode.self,
                                                from: Data(raw.utf8))
        } catch {
            throw corrupt(key)
        }
        switch decoded {
        case .human:
            return .human
        case .approvalModel:
            return .approvalModel
        case .fullControl:
            return .fullControl
        }
    }

    private static func decodeRunningInputMode(_ value: DatabaseValue,
                                               key: String) throws -> SettingsDomainV1.RunningInputMode {
        let raw = try text(value, key: key)
        let decoded: FloeCore.RunningInputMode
        do {
            decoded = try JSONDecoder().decode(FloeCore.RunningInputMode.self,
                                                from: Data(raw.utf8))
        } catch {
            throw corrupt(key)
        }
        switch decoded {
        case .queue:
            return .queue
        case .steer:
            return .steer
        }
    }

    private static func decodeBool(_ value: DatabaseValue,
                                   key: String) throws -> Bool {
        let raw = try text(value, key: key)
        do {
            return try JSONDecoder().decode(Bool.self, from: Data(raw.utf8))
        } catch {
            throw corrupt(key)
        }
    }

    // MARK: - Native encoding

    private static func core(_ mode: SettingsDomainV1.DefaultAgentMode) -> FloeCore.AgentMode {
        switch mode {
        case .human:
            return .human
        case .approvalModel:
            return .approvalModel
        case .fullControl:
            return .fullControl
        }
    }

    private static func core(_ mode: SettingsDomainV1.RunningInputMode) -> FloeCore.RunningInputMode {
        switch mode {
        case .queue:
            return .queue
        case .steer:
            return .steer
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SettingsDefaultsAdapterError.persistenceUnavailable(nil)
        }
        return string
    }

    /// Reproduces PersistenceCodec.encode exactly:
    /// ISO-8601 internet date-time WITH fractional seconds. The original
    /// PersistenceCodec is internal to FloePersistence, so this single line of
    /// formatting is locally reproduced instead of changing shared source.
    /// This timestamp is a WRITE value only; it is never the CAS token.
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Mirrors SettingsStore.swift:64-73 (INSERT ... ON CONFLICT(key) DO
    /// UPDATE value_json + updated_at), untouched by this adapter.
    private static let upsertSQL = """
        INSERT INTO app_settings (key, value_json, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            value_json = excluded.value_json,
            updated_at = excluded.updated_at
        """
}
