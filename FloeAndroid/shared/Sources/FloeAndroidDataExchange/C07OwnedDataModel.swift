// SPDX-License-Identifier: MPL-2.0
//
// C07 full owned-data graph — schema-neutral logical rows, verified ID
// mapping, workspace descriptors and app-owned artifact manifests.
//
// This file deliberately does NOT import GRDB or FloePersistence. It defines
// the bounded, testable wire contract used by FloeAndroidCore:
//
//   * every database table is exported as JSON Lines of typed SQLite values
//     read inside one GRDB consistent read transaction — the live
//     floe.sqlite/WAL pair is never copied;
//   * every restored row receives a NEW root identity through a durable,
//     journaled mapping; references are remapped by exact identity, never by
//     title/order/path guessing;
//   * secrets, grants and executable state are removed or normalized before
//     bytes leave the device and again before a row can reach live storage;
//   * Canvas/media documents and their resource bytes are described by
//     role-specific artifact records, not an opaque directory copy.
import Foundation
import Crypto

// MARK: - Limits

public enum C07OwnedDataLimits {
    public static let format = "floe.owneddata"
    public static let formatVersion = 1
    public static let manifestEntry = "data/owned-data.json"
    public static let workspacesEntry = "data/workspaces.json"
    public static let tableDirectory = "data/tables"
    public static let artifactDirectory = "artifacts"

    public static let maximumTables = 48
    public static let maximumRowsPerTable = 5_000_000
    public static let maximumRowBytes = 8 * 1_024 * 1_024
    public static let maximumTableBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    public static let maximumArtifacts = 200_000
    public static let maximumArtifactBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
    public static let maximumArtifactTotal: Int64 = 16 * 1_024 * 1_024 * 1_024
    public static let maximumWorkspaces = 20_000
    public static let maximumWorkspaceBytes: Int64 = 64 * 1_024 * 1_024
    public static let maximumPlanBytes = 256 * 1_024 * 1_024
    public static let maximumJSONDepth = 64
    public static let maximumJSONNodes = 2_000_000
    public static let copyChunkBytes = 1_048_576
}

public func c07OwnedTableEntry(_ name: String) -> String {
    "\(C07OwnedDataLimits.tableDirectory)/\(name).jsonl"
}

// MARK: - Typed SQLite value

/// Exact SQLite storage class of one column. JSON carries the storage class
/// explicitly so an INTEGER 1 never becomes REAL 1.0 or TEXT "1" on restore.
public struct C07DBValue: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case null, integer, real, text, blob
    }

    public var kind: Kind
    public var integer: Int64?
    public var real: Double?
    public var text: String?
    public var blob: Data?

    private enum CodingKeys: String, CodingKey {
        case kind, integer, real, text, blob
    }

    public init(kind: Kind, integer: Int64? = nil, real: Double? = nil,
                text: String? = nil, blob: Data? = nil) {
        self.kind = kind
        self.integer = integer
        self.real = real
        self.text = text
        self.blob = blob
    }

    public static let null = C07DBValue(kind: .null)
    public static func int(_ value: Int64) -> C07DBValue {
        C07DBValue(kind: .integer, integer: value)
    }
    public static func double(_ value: Double) -> C07DBValue {
        C07DBValue(kind: .real, real: value)
    }
    public static func string(_ value: String) -> C07DBValue {
        C07DBValue(kind: .text, text: value)
    }
    public static func data(_ value: Data) -> C07DBValue {
        C07DBValue(kind: .blob, blob: value)
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        self.kind = kind
        switch kind {
        case .null:
            integer = nil; real = nil; text = nil; blob = nil
        case .integer:
            integer = try values.decode(Int64.self, forKey: .integer)
            real = nil; text = nil; blob = nil
        case .real:
            let value = try values.decode(Double.self, forKey: .real)
            guard value.isFinite else {
                throw C07DataExchangeError.invalidManifest("nonFiniteReal")
            }
            real = value; integer = nil; text = nil; blob = nil
        case .text:
            text = try values.decode(String.self, forKey: .text)
            guard text?.utf8.count ?? 0 <= C07OwnedDataLimits.maximumRowBytes else {
                throw C07DataExchangeError.entryTooLarge("textColumn")
            }
            integer = nil; real = nil; blob = nil
        case .blob:
            let value = try values.decode(Data.self, forKey: .blob)
            guard value.count <= C07OwnedDataLimits.maximumRowBytes else {
                throw C07DataExchangeError.entryTooLarge("blobColumn")
            }
            blob = value; integer = nil; real = nil; text = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        switch kind {
        case .null:
            break
        case .integer:
            guard let integer else { throw C07DataExchangeError.invalidManifest("integerValue") }
            try values.encode(integer, forKey: .integer)
        case .real:
            guard let real, real.isFinite else {
                throw C07DataExchangeError.invalidManifest("realValue")
            }
            try values.encode(real, forKey: .real)
        case .text:
            guard let text else { throw C07DataExchangeError.invalidManifest("textValue") }
            try values.encode(text, forKey: .text)
        case .blob:
            guard let blob else { throw C07DataExchangeError.invalidManifest("blobValue") }
            try values.encode(blob, forKey: .blob)
        }
    }

    public var isNull: Bool { kind == .null }
    public var stringValue: String? { text }
    public var integerValue: Int64? { integer }

    /// Decodes a JSON-encoded column only. Nil means "not a JSON object or
    /// array"; the caller keeps the original value untouched.
    public func decodedJSONObject() -> Any? {
        guard kind == .text, let text, let data = text.data(using: .utf8) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        guard object is [String: Any] || object is [Any] else { return nil }
        return object
    }
}

public typealias C07DBRow = [String: C07DBValue]

public enum C07IDDerivation {
    /// Deterministic fresh identity for internal rows that are never used as
    /// an external reference. A retry of the same restore plan therefore
    /// recreates the same ids instead of a different set.
    public static func fresh(restoreID: UUID, table: String, old: String) -> String {
        let digest = SHA256.hash(data: Data(
            "\(restoreID.uuidString)|\(table)|\(old)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        return [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20).prefix(12)),
        ].joined(separator: "-")
    }
}

// MARK: - Identity kinds and map

public enum C07IDKind: String, Codable, Sendable, CaseIterable {
    case conversation
    case message
    case attachment
    case run
    case toolCall
    case childRun
    case workspace
    case schedule
    case occurrence
    case plan
    case goal
    case provider
    case model
    case canvas
    case mediaProject
    case questionRequest
    case userQuestion
    /// Receipt-only rows whose primary identity is not rewritten because
    /// they never enter a live authorization table.
    case executionEvidence

    /// Root identities are checked against live storage before commit. Child
    /// rows are protected by their own primary keys and exact journal plan.
    public var isRoot: Bool {
        switch self {
        case .conversation, .workspace, .schedule, .provider, .model,
             .canvas, .mediaProject:
            return true
        default:
            return false
        }
    }
}

/// Durable old→new identity mapping. Keys are string identifiers because
/// user-question rows use opaque text ids, not UUIDs.
public struct C07IDMap: Codable, Sendable, Equatable {
    public var values: [String: [String: String]]

    public init(values: [String: [String: String]] = [:]) {
        self.values = values
    }

    public subscript(kind: C07IDKind) -> [String: String] {
        get { values[kind.rawValue] ?? [:] }
        set { values[kind.rawValue] = newValue }
    }

    public mutating func insert(_ kind: C07IDKind, old: String, new: String) throws {
        guard !old.isEmpty, !new.isEmpty else {
            throw C07DataExchangeError.invalidManifest("emptyIdentity")
        }
        var table = values[kind.rawValue] ?? [:]
        if let existing = table[old] {
            guard existing == new else {
                throw C07DataExchangeError.duplicateIdentity("\(kind.rawValue):\(old)")
            }
            return
        }
        table[old] = new
        values[kind.rawValue] = table
    }

    public func newID(_ kind: C07IDKind, old: String) -> String? {
        values[kind.rawValue]?[old]
    }

    public func contains(_ kind: C07IDKind, old: String) -> Bool {
        values[kind.rawValue]?[old] != nil
    }

    public func oldID(_ kind: C07IDKind, new: String) -> String? {
        values[kind.rawValue]?.first(where: { $0.value == new })?.key
    }

    public func allNewIDs(_ kind: C07IDKind) -> [String] {
        Array((values[kind.rawValue] ?? [:]).values)
    }

    public var totalEntries: Int {
        values.values.reduce(0) { $0 + $1.count }
    }
}

// MARK: - Table policy

public enum C07TableDisposition: String, Codable, Sendable, Equatable {
    /// Inserted into the original live table with a new identity.
    case live
    /// Verified and retained under DataExchange/RestoredReceipts as evidence.
    /// Never inserted into the live table: a historical target/pin/receipt is
    /// not current authorization.
    case evidenceArchive
}

public enum C07RowNormalization: String, Codable, Sendable {
    case none
    case run
    case toolCall
    case childRun
    case goal
    case questionRequest
    case question
    case schedule
    case occurrence
    case provider
    case model
    case attachment
    case conversation
}

public struct C07OwnedTablePolicy: Sendable {
    public var name: String
    public var primaryColumn: String
    public var primaryKind: C07IDKind
    /// Required references: a row whose reference cannot be mapped is
    /// rejected, never silently attached to unrelated local data.
    public var references: [String: C07IDKind]
    /// Optional references become NULL when their target was not restored.
    public var optionalReferences: [String: C07IDKind]
    /// These columns are emptied on export and stay empty on restore.
    public var clearedOnExport: [String: C07DBValue]
    /// JSON/ID-bearing text columns whose exact UUID tokens are remapped.
    public var jsonIDColumns: Set<String>
    public var normalization: C07RowNormalization
    public var requiredColumns: Set<String>
    public var disposition: C07TableDisposition
    /// Tables whose primary key is not referenced elsewhere get a fresh,
    /// deterministic per-row identity instead of a durable global mapping.
    public var freshPrimary: Bool
    /// Evidence tables may be absent before the coordinated schema
    /// registration; their absence is declared, never hidden.
    public var optional: Bool

    public init(name: String,
                primaryColumn: String = "id",
                primaryKind: C07IDKind,
                references: [String: C07IDKind] = [:],
                optionalReferences: [String: C07IDKind] = [:],
                clearedOnExport: [String: C07DBValue] = [:],
                jsonIDColumns: Set<String> = [],
                normalization: C07RowNormalization = .none,
                freshPrimary: Bool = false,
                requiredColumns: Set<String> = [],
                disposition: C07TableDisposition = .live,
                optional: Bool = false) {
        self.name = name
        self.primaryColumn = primaryColumn
        self.primaryKind = primaryKind
        self.references = references
        self.optionalReferences = optionalReferences
        self.clearedOnExport = clearedOnExport
        self.jsonIDColumns = jsonIDColumns
        self.normalization = normalization
        self.requiredColumns = requiredColumns
        self.disposition = disposition
        self.freshPrimary = freshPrimary
        self.optional = optional
    }
}

public enum C07OwnedDataPolicy {
    /// Closed, ordered restore graph. Order is dependency order: a target
    /// table always appears before the tables that reference it.
    public static let tables: [C07OwnedTablePolicy] = [
        .init(name: "providers", primaryKind: .provider,
              clearedOnExport: [
                  "secret_ref_account": .null,
                  "secret_ref_synchronizable": .null,
                  "non_secret_headers_json": .string("{}"),
              ],
              normalization: .provider,
              requiredColumns: ["id", "kind", "wire_protocol", "base_url",
                                "is_enabled", "created_at", "updated_at"]),
        .init(name: "models", primaryKind: .model,
              references: ["provider_id": .provider],
              normalization: .model,
              requiredColumns: ["id", "provider_id", "remote_model_id",
                                "display_name", "context_tokens",
                                "max_output_tokens", "capabilities", "is_enabled"]),
        .init(name: "conversations", primaryKind: .conversation,
              normalization: .conversation,
              requiredColumns: ["id", "title", "created_at", "updated_at"]),
        .init(name: "plan_drafts", primaryKind: .plan,
              references: ["conversation_id": .conversation],
              optionalReferences: ["workspace_id": .workspace],
              jsonIDColumns: ["source_message_ids_json",
                              "source_conversation_refs_json"],
              normalization: .none,
              requiredColumns: ["id", "conversation_id", "revision", "status",
                                "title", "summary", "digest", "created_at",
                                "updated_at"]),
        .init(name: "conversation_goals", primaryKind: .goal,
              references: ["conversation_id": .conversation],
              optionalReferences: ["source_plan_id": .plan],
              jsonIDColumns: ["criteria_json", "steps_json", "evidence_json",
                              "progress_json"],
              normalization: .goal,
              requiredColumns: ["id", "conversation_id", "objective", "status",
                                "created_at", "updated_at"]),
        .init(name: "goal_criteria", primaryKind: .goal,
              references: ["goal_id": .goal],
              jsonIDColumns: ["evidence_json"],
              freshPrimary: true,
              requiredColumns: ["id", "goal_id", "criterion_index", "text",
                                "status", "updated_at"]),
        .init(name: "goal_steps", primaryKind: .goal,
              references: ["goal_id": .goal],
              jsonIDColumns: ["evidence_json"],
              freshPrimary: true,
              requiredColumns: ["id", "goal_id", "step_index", "title",
                                "detail", "status", "updated_at"]),
        .init(name: "runs", primaryKind: .run,
              references: ["conversation_id": .conversation],
              optionalReferences: ["goal_id": .goal,
                                   "provider_id": .provider,
                                   "model_id": .model],
              normalization: .run,
              requiredColumns: ["id", "conversation_id", "state", "goal",
                                "started_at"]),
        .init(name: "goal_events", primaryKind: .goal,
              references: ["goal_id": .goal],
              optionalReferences: ["run_id": .run],
              jsonIDColumns: ["payload_json"],
              freshPrimary: true,
              requiredColumns: ["id", "goal_id", "sequence", "kind",
                                "payload_json", "created_at"]),
        .init(name: "messages", primaryKind: .message,
              references: ["conversation_id": .conversation],
              optionalReferences: ["run_id": .run],
              requiredColumns: ["id", "conversation_id", "role", "content",
                                "created_at"]),
        .init(name: "attachments", primaryKind: .attachment,
              references: ["conversation_id": .conversation],
              optionalReferences: ["message_id": .message],
              clearedOnExport: ["url_bookmark": .null],
              normalization: .attachment,
              requiredColumns: ["id", "conversation_id", "kind",
                                "display_name", "uti", "byte_count",
                                "sha256", "storage", "created_at"]),
        .init(name: "message_parts", primaryKind: .message,
              references: ["message_id": .message],
              optionalReferences: ["attachment_id": .attachment],
              jsonIDColumns: ["metadata_json"],
              freshPrimary: true,
              requiredColumns: ["id", "message_id", "part_index", "kind",
                                "metadata_json", "created_at"]),
        .init(name: "run_events", primaryKind: .run,
              references: ["run_id": .run],
              jsonIDColumns: ["payload_json"],
              freshPrimary: true,
              requiredColumns: ["id", "run_id", "sequence", "kind",
                                "payload_json", "created_at"]),
        .init(name: "run_usage", primaryKind: .run,
              references: ["run_id": .run],
              freshPrimary: true,
              requiredColumns: ["id", "run_id", "input_tokens",
                                "output_tokens", "recorded_at"]),
        .init(name: "run_errors", primaryKind: .run,
              references: ["run_id": .run],
              freshPrimary: true,
              requiredColumns: ["id", "run_id", "kind", "message",
                                "recoverable", "recorded_at"]),
        .init(name: "tool_calls", primaryKind: .toolCall,
              references: ["run_id": .run],
              clearedOnExport: [
                  "arguments_json": .string("{}"),
                  "scope_json": .string("{}"),
              ],
              normalization: .toolCall,
              requiredColumns: ["id", "run_id", "tool_name",
                                "idempotency_key", "status", "created_at"]),
        .init(name: "child_runs", primaryKind: .childRun,
              references: ["conversation_id": .conversation],
              optionalReferences: ["parent_run_id": .run,
                                   "root_run_id": .run],
              normalization: .childRun,
              requiredColumns: ["id", "parent_run_id", "root_run_id",
                                "conversation_id", "child_index", "kind",
                                "task_summary", "state", "started_at",
                                "updated_at"]),
        .init(name: "child_run_entries", primaryKind: .childRun,
              references: ["child_run_id": .childRun],
              jsonIDColumns: ["payload_json"],
              freshPrimary: true,
              requiredColumns: ["id", "child_run_id", "sequence", "kind",
                                "payload_json", "created_at"]),
        .init(name: "run_relations", primaryColumn: "parent_run_id",
              primaryKind: .run,
              references: ["parent_run_id": .run, "child_run_id": .run],
              jsonIDColumns: [],
              requiredColumns: ["parent_run_id", "child_run_id",
                                "child_index", "task_summary", "created_at"]),
        .init(name: "user_question_requests", primaryColumn: "request_id",
              primaryKind: .questionRequest,
              references: ["conversation_id": .conversation,
                           "run_id": .run],
              jsonIDColumns: ["request_json"],
              normalization: .questionRequest,
              requiredColumns: ["request_id", "conversation_id", "run_id",
                                "tool_call_id", "request_digest", "wait_policy",
                                "state", "created_at", "updated_at",
                                "request_json"]),
        .init(name: "user_questions", primaryColumn: "question_id",
              primaryKind: .userQuestion,
              references: ["request_id": .questionRequest,
                           "conversation_id": .conversation,
                           "run_id": .run],
              jsonIDColumns: ["payload_json"],
              normalization: .question,
              requiredColumns: ["question_id", "request_id",
                                "conversation_id", "run_id", "ordinal",
                                "revision", "status", "payload_json",
                                "updated_at"]),
        .init(name: "task_schedules", primaryKind: .schedule,
              optionalReferences: ["workspace_id": .workspace,
                                   "upstream_run_id": .run,
                                   "model_id": .model],
              clearedOnExport: [
                  "policy_json": .string("{}"),
                  "permission_json": .string("{}"),
              ],
              normalization: .schedule,
              requiredColumns: ["id", "title", "prompt", "cadence",
                                "scheduled_at", "is_enabled", "created_at",
                                "updated_at"]),
        .init(name: "task_schedule_occurrences", primaryKind: .occurrence,
              references: ["schedule_id": .schedule],
              optionalReferences: ["run_id": .run,
                                   "conversation_id": .conversation],
              jsonIDColumns: ["dedupe_key"],
              normalization: .occurrence,
              requiredColumns: ["id", "schedule_id", "scheduled_for", "state",
                                "dedupe_key", "created_at", "updated_at"]),
        // C02 execution-target evidence. These rows are exported and
        // verified, then restored ONLY into the read-only receipt archive.
        // A historical target, run pin or remote-command receipt never
        // becomes current authorization or a replayable command.
        .init(name: "task_execution_targets", primaryColumn: "conversation_id",
              primaryKind: .executionEvidence,
              references: ["conversation_id": .conversation],
              optionalReferences: ["workspace_id": .workspace],
              jsonIDColumns: ["body_json"],
              requiredColumns: ["conversation_id", "revision", "kind",
                                "environment_id", "workspace_id",
                                "shell_root_hash", "engine_owner_hash",
                                "root_epoch", "provenance", "body_json",
                                "created_at", "updated_at"],
              disposition: .evidenceArchive, optional: true),
        .init(name: "task_execution_target_migrations",
              primaryKind: .executionEvidence,
              references: ["conversation_id": .conversation],
              jsonIDColumns: ["body_json"],
              requiredColumns: ["id", "conversation_id", "phase", "revision",
                                "source_revision", "body_json", "created_at",
                                "updated_at"],
              disposition: .evidenceArchive, optional: true),
        .init(name: "task_run_execution_targets", primaryColumn: "run_id",
              primaryKind: .executionEvidence,
              references: ["run_id": .run,
                           "conversation_id": .conversation],
              jsonIDColumns: ["body_json"],
              requiredColumns: ["run_id", "conversation_id",
                                "target_revision", "environment_id",
                                "shell_root_hash", "engine_owner_hash",
                                "root_epoch", "body_json", "pinned_at"],
              disposition: .evidenceArchive, optional: true),
        .init(name: "task_remote_command_receipts",
              primaryColumn: "operation_id",
              primaryKind: .executionEvidence,
              references: ["task_id": .conversation],
              optionalReferences: ["run_id": .run],
              jsonIDColumns: ["body_json"],
              requiredColumns: ["operation_id", "task_id",
                                "target_revision", "root_epoch", "host_id",
                                "command_sha256", "state", "started_at",
                                "updated_at", "body_json"],
              disposition: .evidenceArchive, optional: true),
    ]

    public static func policy(for table: String) -> C07OwnedTablePolicy? {
        tables.first { $0.name == table }
    }

    public static var tableNames: [String] { tables.map(\.name) }

    /// Tables whose existence is mandatory for a full backup. A missing
    /// mandatory table is a hard failure, never an unnoticed scope reduction.
    public static let evidenceTableNames: Set<String> = Set(
        tables.filter { $0.disposition == .evidenceArchive }.map(\.name))

    public static let optionalTableNames: Set<String> = Set(
        tables.filter(\.optional).map(\.name))

    public static let mandatoryTableNames: Set<String> = [
        "providers", "models", "conversations", "plan_drafts",
        "conversation_goals", "goal_criteria", "goal_steps", "runs",
        "goal_events", "messages", "attachments", "message_parts",
        "run_events", "run_usage", "run_errors", "tool_calls", "child_runs",
        "child_run_entries", "run_relations", "user_question_requests",
        "user_questions", "task_schedules", "task_schedule_occurrences",
    ]

    /// Export-time row admission. Temporary chats never leave RAM and must
    /// never appear in a package, even if a historical bug wrote one.
    public static func shouldExportRow(table: String, row: C07DBRow) -> Bool {
        switch table {
        case "conversations":
            return row["purpose"]?.stringValue != "temporary"
        case "attachments":
            // An attachment without an owning conversation has no verified
            // restore owner; it is declared, not guessed.
            return row["conversation_id"]?.stringValue?.isEmpty == false
        case "providers":
            return true
        default:
            return true
        }
    }

    /// Makes a row safe to write into the package. Runs again on restore so
    /// a hand-edited archive cannot reintroduce a secret-bearing column.
    public static func exportedRow(table: String, row: C07DBRow) -> C07DBRow {
        guard let policy = policy(for: table) else { return [:] }
        var result = row
        for (column, value) in policy.clearedOnExport {
            if result[column] != nil { result[column] = value }
        }
        result = redactKnownSecretBearingPayloads(table: table, row: result)
        return result
    }

    /// Restore-time normalization. This is the second, independent gate:
    /// even a package assembled by an older/buggy writer cannot re-arm a
    /// schedule, mark a run active, expose a pending question, or grant a
    /// provider credential.
    public static func restoredRow(table: String, row: C07DBRow) -> C07DBRow {
        guard let policy = policy(for: table) else { return [:] }
        var result = row
        switch policy.normalization {
        case .none:
            break
        case .run:
            let state = result["state"]?.stringValue ?? ""
            if !terminalRunStates.contains(state) {
                result["state"] = .string("interrupted")
            }
        case .toolCall:
            let status = result["status"]?.stringValue ?? ""
            if !terminalToolStates.contains(status) {
                result["status"] = .string("interrupted")
            }
        case .childRun:
            let state = result["state"]?.stringValue ?? ""
            if !terminalRunStates.contains(state) {
                result["state"] = .string("interrupted")
            }
        case .goal:
            let status = result["status"]?.stringValue ?? ""
            if !terminalGoalStates.contains(status) {
                result["status"] = .string("interrupted")
            }
            result["blocking_fingerprint"] = .null
            result["consecutive_blocked_cycles"] = .int(0)
        case .questionRequest:
            let state = result["state"]?.stringValue ?? ""
            if state == "awaitingAnswer" || state == "awaitingOptional" {
                result["state"] = .string("settled")
            }
        case .question:
            let status = result["status"]?.stringValue ?? ""
            if status == "pending" {
                result["status"] = .string("expired")
                result["delivered_at"] = .null
            }
        case .schedule:
            // Restored schedules are history until the user explicitly
            // re-enables them. No alarm, occurrence or run is armed here.
            result["is_enabled"] = .int(0)
            result["next_expected_at"] = .null
            result["policy_json"] = .string("{}")
            if result["permission_json"] != nil {
                result["permission_json"] = .string("{}")
            }
            result["environment_id"] = .null
        case .occurrence:
            let state = result["state"]?.stringValue ?? ""
            if state == "pending" || state == "claimed" || state == "running" {
                result["state"] = .string("interrupted")
            }
        case .provider:
            result["is_enabled"] = .int(0)
            result["secret_ref_account"] = .null
            result["secret_ref_synchronizable"] = .null
            result["non_secret_headers_json"] = .string("{}")
            result["sync_revision"] = .int(0)
            if let base = result["base_url"]?.stringValue {
                result["base_url"] = .string(sanitizedBaseURL(base))
            }
        case .model:
            // A restored model belongs to a credential-less provider. Keep
            // its catalog entry but never make it selectable by default.
            result["is_enabled"] = .int(0)
        case .attachment:
            let storage = result["storage"]?.stringValue ?? "none"
            if storage == "securityScopedBookmark" || storage == "none" {
                result["storage"] = .string("none")
                result["relative_path"] = .null
            }
            result["url_bookmark"] = .null
        case .conversation:
            let purpose = result["purpose"]?.stringValue ?? "ordinary"
            if purpose != "ordinary" && purpose != "notes" {
                result["purpose"] = .string("ordinary")
            }
        }
        // Never let an archive reintroduce a secret column even if the
        // writer predates the export-side redaction.
        result = redactKnownSecretBearingPayloads(table: table, row: result)
        return result
    }

    private static let terminalRunStates: Set<String> = [
        "completed", "failed", "cancelled", "checkpointed", "interrupted",
    ]
    private static let terminalToolStates: Set<String> = [
        "completed", "succeeded", "failed", "cancelled", "denied",
        "interrupted", "expired",
    ]
    private static let terminalGoalStates: Set<String> = [
        "completed", "cancelled", "failed", "interrupted",
    ]

    /// Tool/approval payloads are action bodies that may embed arguments,
    /// remote tokens or headers. The receipt identity (tool name, status,
    /// digest, exit) stays; the body does not.
    private static func redactKnownSecretBearingPayloads(table: String,
                                                        row: C07DBRow) -> C07DBRow {
        var result = row
        switch table {
        case "run_events":
            let kind = result["kind"]?.stringValue ?? ""
            if ["toolRequest", "toolResult", "approval"].contains(kind) {
                result["payload_json"] = .string(
                    "{\"redacted\":\"secretBearingActionPayload\",\"kind\":\"\(kind)\"}")
            }
        case "tool_calls":
            if result["arguments_json"] != nil {
                result["arguments_json"] = .string("{}")
            }
            if result["scope_json"] != nil {
                result["scope_json"] = .string("{}")
            }
        default:
            break
        }
        return result
    }

    /// Keeps scheme/host/port/path. Drops userinfo and a query/fragment that
    /// could carry a signed key. A non-URL value is replaced, not kept.
    public static func sanitizedBaseURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else {
            return ""
        }
        components.user = nil
        components.password = nil
        let query = (components.percentEncodedQuery ?? "").lowercased()
        if ["key", "token", "secret", "sig", "auth", "password"].contains(
            where: { query.contains($0) }) {
            components.percentEncodedQuery = nil
        }
        components.fragment = nil
        return components.string ?? ""
    }
}

// MARK: - UUID token / path rewriting

public enum C07IDRewrite {
    private static let uuidPattern =
        "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"

    /// Replaces exact UUID tokens that exist in the durable map. User text
    /// that merely contains a UUID is not altered unless the token is a
    /// mapped identity; this function is used on identity/binding columns,
    /// never on free-form message bodies.
    public static func rewrite(_ text: String, mapping: C07IDMap) -> String {
        guard text.contains("-"), mapping.totalEntries > 0 else { return text }
        let regex = try? NSRegularExpression(pattern: uuidPattern)
        guard let regex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let tokenRange = Range(match.range, in: result) else { continue }
            let token = String(result[tokenRange])
            for kind in C07IDKind.allCases {
                if let replacement = mapping.newID(kind, old: token)
                    ?? mapping.newID(kind, old: token.lowercased())
                    ?? mapping.newID(kind, old: token.uppercased()) {
                    result.replaceSubrange(tokenRange, with: replacement)
                    break
                }
            }
        }
        return result
    }

    public static func rewriteJSONValue(_ value: Any, mapping: C07IDMap,
                                        depth: Int = 0) throws -> Any {
        guard depth <= C07OwnedDataLimits.maximumJSONDepth else {
            throw C07DataExchangeError.invalidManifest("jsonDepth")
        }
        if let string = value as? String {
            return rewrite(string, mapping: mapping)
        }
        if let array = value as? [Any] {
            return try array.map {
                try rewriteJSONValue($0, mapping: mapping, depth: depth + 1)
            }
        }
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, item) in object {
                let newKey = rewrite(key, mapping: mapping)
                result[newKey] = try rewriteJSONValue(
                    item, mapping: mapping, depth: depth + 1)
            }
            return result
        }
        return value
    }

    /// Rewrites only identity-bearing JSON text columns. Returns the original
    /// value when it is not a JSON object/array.
    public static func rewriteJSONColumn(_ value: C07DBValue,
                                         mapping: C07IDMap) throws -> C07DBValue {
        guard let object = value.decodedJSONObject() else {
            if value.kind == .text, let text = value.text {
                return .string(rewrite(text, mapping: mapping))
            }
            return value
        }
        let rewritten = try rewriteJSONValue(object, mapping: mapping)
        let data = try JSONSerialization.data(
            withJSONObject: rewritten, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8),
              text.utf8.count <= C07OwnedDataLimits.maximumRowBytes else {
            throw C07DataExchangeError.entryTooLarge("jsonColumn")
        }
        return .string(text)
    }

    /// App-root-relative paths carry UUID directory names. The same exact
    /// identity map is applied to each component; no other path component is
    /// invented or normalized.
    public static func rewritePath(_ path: String, mapping: C07IDMap) -> String {
        rewrite(path, mapping: mapping)
    }
}

// MARK: - Workspace descriptors

public enum C07WorkspaceRestoreMode: String, Codable, Sendable {
    /// Managed `Projects/<uuid>` root. Files are restored through the ONE C01
    /// project library, which allocates the new project identity.
    case managedProject
    /// Retained `Projects/<uuid>` root with no live row. Also restored as an
    /// explicit new C01 project.
    case retainedProject
    /// `Workspace/PrivateTasks/<conversationID>` root. Files are restored by
    /// the C07 artifact phase after the conversation mapping is durable.
    case privateTask
    /// External/SAF/shared root. Only metadata is carried; the user must
    /// grant the root again. The original bookmark/token is never
    /// transplanted.
    case externalRegrant
}

public struct C07WorkspaceDescriptor: Codable, Sendable, Equatable {
    public var workspaceID: UUID
    public var name: String
    public var kind: String
    public var internalRelativePath: String?
    public var mode: C07WorkspaceRestoreMode
    public var conversationIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date
    public var requiresRegrant: Bool
    public var warnings: [String]

    public init(workspaceID: UUID, name: String, kind: String,
                internalRelativePath: String?,
                mode: C07WorkspaceRestoreMode,
                conversationIDs: [UUID],
                createdAt: Date, updatedAt: Date,
                requiresRegrant: Bool, warnings: [String] = []) {
        self.workspaceID = workspaceID
        self.name = String(name.prefix(256))
        self.kind = String(kind.prefix(32))
        self.internalRelativePath = internalRelativePath.map { String($0.prefix(1_024)) }
        self.mode = mode
        self.conversationIDs = Array(conversationIDs.prefix(100_000))
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.requiresRegrant = requiresRegrant
        self.warnings = Array(warnings.prefix(16))
    }

    public var isBytesCarried: Bool {
        mode == .managedProject || mode == .retainedProject || mode == .privateTask
    }
}

// MARK: - Artifacts

public enum C07ArtifactRole: String, Codable, Sendable, CaseIterable {
    case canvasProject
    case canvasMediaProject
    case canvasAsset
    case canvasMaterial
    case canvasNodeAsset
    case attachment
    case privateTaskFile
    case mailReceipt
    case environmentCheckpoint

    public var packageRoot: String {
        switch self {
        case .canvasProject: return "\(C07OwnedDataLimits.artifactDirectory)/canvas"
        case .canvasMediaProject: return "\(C07OwnedDataLimits.artifactDirectory)/canvas-media"
        case .canvasAsset: return "\(C07OwnedDataLimits.artifactDirectory)/canvas-assets"
        case .canvasMaterial: return "\(C07OwnedDataLimits.artifactDirectory)/canvas-materials"
        case .canvasNodeAsset: return "\(C07OwnedDataLimits.artifactDirectory)/canvas-nodes"
        case .attachment: return "\(C07OwnedDataLimits.artifactDirectory)/attachments"
        case .privateTaskFile: return "\(C07OwnedDataLimits.artifactDirectory)/private-tasks"
        case .mailReceipt: return "\(C07OwnedDataLimits.artifactDirectory)/mail-receipts"
        case .environmentCheckpoint: return "\(C07OwnedDataLimits.artifactDirectory)/environments"
        }
    }
}

public struct C07ArtifactRecord: Codable, Sendable, Equatable {
    public var role: C07ArtifactRole
    public var ownerID: UUID?
    public var containerID: UUID?
    /// Role-specific logical path (media asset path, attachment path, …).
    public var logicalPath: String
    /// Exact package entry name.
    public var entry: String
    public var byteCount: Int64
    public var sha256: String
    public var mode: Int?

    public init(role: C07ArtifactRole, ownerID: UUID?, containerID: UUID?,
                logicalPath: String, entry: String, byteCount: Int64,
                sha256: String, mode: Int? = nil) {
        self.role = role
        self.ownerID = ownerID
        self.containerID = containerID
        self.logicalPath = logicalPath
        self.entry = entry
        self.byteCount = byteCount
        self.sha256 = sha256
        self.mode = mode
    }
}

public enum C07ArtifactPath {
    public static func entry(role: C07ArtifactRole,
                             containerID: UUID?,
                             ownerID: UUID?,
                             logicalPath: String) throws -> String {
        let logical = try C07Path.validateRelative(logicalPath)
        let root = role.packageRoot
        switch role {
        case .canvasProject:
            guard let containerID, logical == "project.json" else {
                throw C07DataExchangeError.unsafePath(logicalPath)
            }
            return "\(root)/\(containerID.uuidString)/project.json"
        case .canvasMediaProject:
            guard let containerID, let ownerID,
                  logical == "media-project-\(ownerID.uuidString).json" else {
                throw C07DataExchangeError.unsafePath(logicalPath)
            }
            return "\(root)/\(containerID.uuidString)/\(ownerID.uuidString).json"
        case .canvasMaterial, .canvasNodeAsset, .canvasAsset:
            guard let containerID else {
                throw C07DataExchangeError.unsafePath(logicalPath)
            }
            return "\(root)/\(containerID.uuidString)/\(logical)"
        case .attachment:
            guard let ownerID else {
                throw C07DataExchangeError.unsafePath(logicalPath)
            }
            return "\(root)/\(ownerID.uuidString)/\(logical)"
        case .privateTaskFile:
            guard let ownerID else {
                throw C07DataExchangeError.unsafePath(logicalPath)
            }
            return "\(root)/\(ownerID.uuidString)/\(logical)"
        case .mailReceipt:
            return "\(root)/\(logical)"
        case .environmentCheckpoint:
            guard let ownerID else {
                throw C07DataExchangeError.unsafePath(logicalPath)
            }
            return "\(root)/\(ownerID.uuidString)/\(logical)"
        }
    }

    /// Role-specific destination containment check used by the live sink.
    public static func isContained(entry: String, under root: String) -> Bool {
        let normalizedEntry = entry.precomposedStringWithCanonicalMapping
        let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
        return normalizedEntry.hasPrefix(normalizedRoot)
    }
}

// MARK: - Data manifest and counts

public struct C07OwnedDataCounts: Codable, Sendable, Equatable {
    public var conversations: Int
    public var messages: Int
    public var messageParts: Int
    public var runs: Int
    public var toolCalls: Int
    public var attachments: Int
    public var workspaces: Int
    public var canvasProjects: Int
    public var mediaProjects: Int
    public var mediaAssets: Int
    public var schedules: Int
    public var occurrences: Int
    public var actionReceipts: Int
    public var mailReceipts: Int
    public var privateTaskFiles: Int
    public var providers: Int
    public var models: Int
    public var executionTargets: Int
    public var executionTargetMigrations: Int
    public var runExecutionPins: Int
    public var remoteCommandReceipts: Int
    public var artifacts: Int
    public var artifactBytes: Int64

    public init(conversations: Int = 0, messages: Int = 0,
                messageParts: Int = 0, runs: Int = 0, toolCalls: Int = 0,
                attachments: Int = 0, workspaces: Int = 0,
                canvasProjects: Int = 0, mediaProjects: Int = 0,
                mediaAssets: Int = 0, schedules: Int = 0,
                occurrences: Int = 0, actionReceipts: Int = 0,
                mailReceipts: Int = 0, privateTaskFiles: Int = 0,
                providers: Int = 0, models: Int = 0,
                executionTargets: Int = 0,
                executionTargetMigrations: Int = 0,
                runExecutionPins: Int = 0,
                remoteCommandReceipts: Int = 0, artifacts: Int = 0,
                artifactBytes: Int64 = 0) {
        self.conversations = conversations
        self.messages = messages
        self.messageParts = messageParts
        self.runs = runs
        self.toolCalls = toolCalls
        self.attachments = attachments
        self.workspaces = workspaces
        self.canvasProjects = canvasProjects
        self.mediaProjects = mediaProjects
        self.mediaAssets = mediaAssets
        self.schedules = schedules
        self.occurrences = occurrences
        self.actionReceipts = actionReceipts
        self.mailReceipts = mailReceipts
        self.privateTaskFiles = privateTaskFiles
        self.providers = providers
        self.models = models
        self.executionTargets = executionTargets
        self.executionTargetMigrations = executionTargetMigrations
        self.runExecutionPins = runExecutionPins
        self.remoteCommandReceipts = remoteCommandReceipts
        self.artifacts = artifacts
        self.artifactBytes = artifactBytes
    }
}

public struct C07OwnedTableRecord: Codable, Sendable, Equatable {
    public var name: String
    public var entry: String
    public var rowCount: Int
    public var byteCount: Int64
    public var sha256: String

    public init(name: String, entry: String, rowCount: Int,
                byteCount: Int64, sha256: String) {
        self.name = name
        self.entry = entry
        self.rowCount = rowCount
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct C07OwnedDataManifest: Codable, Sendable, Equatable {
    public var format: String
    public var formatVersion: Int
    public var createdAt: Date
    public var sourceAppSchemaVersion: Int
    public var tables: [C07OwnedTableRecord]
    public var workspacesEntry: String
    public var workspaceCount: Int
    public var workspaceByteCount: Int64
    public var workspaceSHA256: String
    public var counts: C07OwnedDataCounts
    public var excluded: [C07ExcludedScope]
    public var linuxCheckpointPort: String
    public var linuxCheckpointReason: String?
    public var warnings: [String]

    public init(format: String = C07OwnedDataLimits.format,
                formatVersion: Int = C07OwnedDataLimits.formatVersion,
                createdAt: Date = Date(),
                sourceAppSchemaVersion: Int,
                tables: [C07OwnedTableRecord],
                workspacesEntry: String = C07OwnedDataLimits.workspacesEntry,
                workspaceCount: Int,
                workspaceByteCount: Int64,
                workspaceSHA256: String,
                counts: C07OwnedDataCounts,
                excluded: [C07ExcludedScope],
                linuxCheckpointPort: String,
                linuxCheckpointReason: String? = nil,
                warnings: [String] = []) {
        self.format = format
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.sourceAppSchemaVersion = sourceAppSchemaVersion
        self.tables = tables
        self.workspacesEntry = workspacesEntry
        self.workspaceCount = workspaceCount
        self.workspaceByteCount = workspaceByteCount
        self.workspaceSHA256 = workspaceSHA256
        self.counts = counts
        self.excluded = excluded
        self.linuxCheckpointPort = linuxCheckpointPort
        self.linuxCheckpointReason = linuxCheckpointReason
        self.warnings = warnings
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> C07OwnedDataManifest {
        guard data.count <= C07DataExchangeLimits.maximumManifestBytes else {
            throw C07DataExchangeError.entryTooLarge(
                C07OwnedDataLimits.manifestEntry)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(C07OwnedDataManifest.self, from: data) }
        catch { throw C07DataExchangeError.invalidManifest("ownedDataDecode") }
    }

    public func validate() throws {
        guard format == C07OwnedDataLimits.format else {
            throw C07DataExchangeError.unsupportedFormat(format)
        }
        guard formatVersion == C07OwnedDataLimits.formatVersion else {
            throw C07DataExchangeError.unsupportedVersion(formatVersion)
        }
        guard tables.count <= C07OwnedDataLimits.maximumTables,
              workspaceCount <= C07OwnedDataLimits.maximumWorkspaces,
              workspaceByteCount <= C07OwnedDataLimits.maximumWorkspaceBytes,
              counts.artifacts <= C07OwnedDataLimits.maximumArtifacts else {
            throw C07DataExchangeError.tooManyEntries
        }
        var names = Set<String>()
        for table in tables {
            guard names.insert(table.name).inserted,
                  C07OwnedDataPolicy.policy(for: table.name) != nil,
                  table.entry == c07OwnedTableEntry(table.name),
                  table.rowCount >= 0,
                  table.rowCount <= C07OwnedDataLimits.maximumRowsPerTable,
                  table.byteCount >= 0,
                  table.byteCount <= C07OwnedDataLimits.maximumTableBytes,
                  C07SHA256Hex.isSHA256(table.sha256) else {
                throw C07DataExchangeError.invalidManifest(
                    "ownedTable:\(table.name)")
            }
        }
        let provided = Set(tables.map(\.name))
        guard C07OwnedDataPolicy.mandatoryTableNames.isSubset(of: provided) else {
            throw C07DataExchangeError.invalidManifest("ownedTablesMissing")
        }
        let missingOptional = C07OwnedDataPolicy.optionalTableNames
            .subtracting(provided)
        guard missingOptional.allSatisfy({
            C07OwnedDataPolicy.evidenceTableNames.contains($0)
        }) else {
            throw C07DataExchangeError.invalidManifest("ownedOptionalTables")
        }
        guard workspacesEntry == C07OwnedDataLimits.workspacesEntry,
              C07SHA256Hex.isSHA256(workspaceSHA256) else {
            throw C07DataExchangeError.invalidManifest("workspacesRecord")
        }
        guard ["available", "unavailable"].contains(linuxCheckpointPort) else {
            throw C07DataExchangeError.invalidManifest("checkpointPort")
        }
    }
}

// MARK: - Staged/producer types

public struct C07SourceTable: Sendable, Equatable {
    public var name: String
    public var url: URL
    public var rowCount: Int

    public init(name: String, url: URL, rowCount: Int) {
        self.name = name
        self.url = url
        self.rowCount = rowCount
    }
}

public struct C07SourceWorkspaces: Sendable, Equatable {
    public var url: URL
    public var count: Int

    public init(url: URL, count: Int) {
        self.url = url
        self.count = count
    }
}

public struct C07SourceArtifact: Sendable, Equatable {
    public var record: C07ArtifactRecord
    public var url: URL

    public init(record: C07ArtifactRecord, url: URL) {
        self.record = record
        self.url = url
    }
}

public struct C07SourceOwnedData: Sendable {
    public var tables: [C07SourceTable]
    public var workspaces: C07SourceWorkspaces?
    public var artifacts: [C07SourceArtifact]
    public var counts: C07OwnedDataCounts
    public var excluded: [C07ExcludedScope]
    public var linuxCheckpointPort: String
    public var linuxCheckpointReason: String?
    public var warnings: [String]

    public init(tables: [C07SourceTable],
                workspaces: C07SourceWorkspaces?,
                artifacts: [C07SourceArtifact],
                counts: C07OwnedDataCounts,
                excluded: [C07ExcludedScope],
                linuxCheckpointPort: String,
                linuxCheckpointReason: String? = nil,
                warnings: [String] = []) {
        self.tables = tables
        self.workspaces = workspaces
        self.artifacts = artifacts
        self.counts = counts
        self.excluded = excluded
        self.linuxCheckpointPort = linuxCheckpointPort
        self.linuxCheckpointReason = linuxCheckpointReason
        self.warnings = warnings
    }
}

public struct C07StagedTable: Sendable, Equatable {
    public var record: C07OwnedTableRecord
    public var url: URL

    public init(record: C07OwnedTableRecord, url: URL) {
        self.record = record
        self.url = url
    }
}

public struct C07StagedArtifact: Sendable, Equatable {
    public var record: C07ArtifactRecord
    public var url: URL

    public init(record: C07ArtifactRecord, url: URL) {
        self.record = record
        self.url = url
    }
}

public struct C07StagedOwnedData: Sendable {
    public var manifest: C07OwnedDataManifest
    public var manifestSHA256: String
    public var tables: [C07StagedTable]
    public var workspaces: [C07WorkspaceDescriptor]
    public var artifacts: [C07StagedArtifact]
    public var totalBytes: Int64

    public init(manifest: C07OwnedDataManifest,
                manifestSHA256: String,
                tables: [C07StagedTable],
                workspaces: [C07WorkspaceDescriptor],
                artifacts: [C07StagedArtifact],
                totalBytes: Int64) {
        self.manifest = manifest
        self.manifestSHA256 = manifestSHA256
        self.tables = tables
        self.workspaces = workspaces
        self.artifacts = artifacts
        self.totalBytes = totalBytes
    }
}

// MARK: - Restore plan file (durable rollback identity)

public struct C07OwnedDataRestorePlanFile: Codable, Sendable, Equatable {
    public var restoreID: UUID
    public var planVersion: Int
    public var idMap: C07IDMap
    public var artifactRoots: [String]
    public var attachmentPaths: [String: String]
    public var workspaceIDs: [String]
    public var environmentIDs: [UUID]?
    public var environmentIdentityMap: [String: String]?
    public var counts: C07OwnedDataCounts
    public var warnings: [String]

    public init(restoreID: UUID, planVersion: Int = 1,
                idMap: C07IDMap,
                artifactRoots: [String],
                attachmentPaths: [String: String],
                workspaceIDs: [String],
                environmentIDs: [UUID]? = nil,
                environmentIdentityMap: [String: String]? = nil,
                counts: C07OwnedDataCounts,
                warnings: [String]) {
        self.restoreID = restoreID
        self.planVersion = planVersion
        self.idMap = idMap
        self.artifactRoots = artifactRoots
        self.attachmentPaths = attachmentPaths
        self.workspaceIDs = workspaceIDs
        self.environmentIDs = environmentIDs
        self.environmentIdentityMap = environmentIdentityMap
        self.counts = counts
        self.warnings = warnings
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        guard data.count <= C07OwnedDataLimits.maximumPlanBytes else {
            throw C07DataExchangeError.entryTooLarge("restorePlan")
        }
        return data
    }

    public static func decode(_ data: Data) throws -> C07OwnedDataRestorePlanFile {
        guard data.count <= C07OwnedDataLimits.maximumPlanBytes else {
            throw C07DataExchangeError.entryTooLarge("restorePlan")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(C07OwnedDataRestorePlanFile.self, from: data) }
        catch { throw C07DataExchangeError.invalidManifest("restorePlanDecode") }
    }
}

// MARK: - Durable plan writer

public enum C07DurablePlan {
    public static func write(_ plan: C07OwnedDataRestorePlanFile,
                             root: URL) throws -> (url: URL, sha256: String) {
        try C07FileSystem.ensureDirectory(root)
        let url = root.appendingPathComponent(
            "owneddata-\(plan.restoreID.uuidString).plan.json")
        let data = try plan.encoded()
        let temporary = root.appendingPathComponent(".plan-\(UUID().uuidString).tmp")
        defer { C07FileSystem.removeIfPresent(temporary) }
        do {
            try data.write(to: temporary)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            throw C07DataExchangeError.storageUnavailable("planWrite")
        }
        return (url, C07Digest.sha256(data))
    }

    public static func read(url: URL) throws -> C07OwnedDataRestorePlanFile {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw C07DataExchangeError.storageUnavailable("planRead") }
        return try C07OwnedDataRestorePlanFile.decode(data)
    }
}

// MARK: - Row stream validation

public enum C07RowStream {
    public static func encodeLine(_ row: C07DBRow) throws -> Data {
        guard !row.isEmpty else {
            throw C07DataExchangeError.invalidManifest("emptyRow")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data: Data
        do { data = try encoder.encode(row) }
        catch { throw C07DataExchangeError.invalidManifest("rowEncode") }
        guard data.count <= C07OwnedDataLimits.maximumRowBytes else {
            throw C07DataExchangeError.entryTooLarge("row")
        }
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ data: Data, table: String) throws -> C07DBRow {
        guard !data.isEmpty, data.count <= C07OwnedDataLimits.maximumRowBytes else {
            throw C07DataExchangeError.entryTooLarge("\(table)Row")
        }
        let decoder = JSONDecoder()
        let row: C07DBRow
        do { row = try decoder.decode(C07DBRow.self, from: data) }
        catch { throw C07DataExchangeError.invalidManifest("\(table)RowDecode") }
        guard !row.isEmpty, row.count <= 256 else {
            throw C07DataExchangeError.invalidManifest("\(table)RowShape")
        }
        for (column, value) in row {
            guard column.utf8.count <= 128,
                  column.unicodeScalars.allSatisfy({
                      ($0.value >= 0x21 && $0.value < 0x7F) || $0.value == 0x20
                  }) else {
                throw C07DataExchangeError.invalidManifest("\(table)Column")
            }
            if value.kind == .text, value.text?.utf8.count ?? 0
                > C07OwnedDataLimits.maximumRowBytes {
                throw C07DataExchangeError.entryTooLarge("\(table).\(column)")
            }
        }
        return row
    }

    public static func rows(in url: URL, table: String,
                            maximumRows: Int = C07OwnedDataLimits.maximumRowsPerTable,
                            _ body: (C07DBRow) throws -> Void) throws {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw C07DataExchangeError.storageUnavailable("tableOpen") }
        defer { try? handle.close() }
        var buffer = Data()
        var count = 0
        var totalBytes = 0
        let endOfLine = Data([0x0A])
        do {
            while let chunk = try handle.read(upToCount: C07OwnedDataLimits.copyChunkBytes),
                  !chunk.isEmpty {
                if Task.isCancelled { throw C07DataExchangeError.cancelled }
                buffer.append(chunk)
                while let index = buffer.range(of: endOfLine)?.lowerBound {
                    let line = buffer.subdata(in: buffer.startIndex..<index)
                    buffer.removeSubrange(buffer.startIndex...index)
                    count += 1
                    totalBytes += line.count + 1
                    guard count <= maximumRows else {
                        throw C07DataExchangeError.tooManyEntries
                    }
                    guard Int64(totalBytes) <= C07OwnedDataLimits.maximumTableBytes else {
                        throw C07DataExchangeError.totalTooLarge
                    }
                    try body(try decodeLine(line, table: table))
                }
                guard buffer.count <= C07OwnedDataLimits.maximumRowBytes else {
                    throw C07DataExchangeError.entryTooLarge("\(table)Row")
                }
            }
            if !buffer.isEmpty {
                count += 1
                guard count <= maximumRows else {
                    throw C07DataExchangeError.tooManyEntries
                }
                try body(try decodeLine(buffer, table: table))
            }
        } catch let error as C07DataExchangeError {
            throw error
        } catch {
            throw C07DataExchangeError.storageUnavailable("tableRead")
        }
    }

    /// Streaming writer used by the consistent database read. Rows are
    /// written one at a time; the full table is never resident in memory.
    public static func makeWriter(at url: URL) throws -> C07RowLineWriter {
        try C07RowLineWriter(url: url)
    }

    public static func writeRows(_ rows: [C07DBRow], to url: URL) throws -> Int {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw C07DataExchangeError.storageUnavailable("tableCreate")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: url) }
        catch { throw C07DataExchangeError.storageUnavailable("tableOpenWrite") }
        defer { try? handle.close() }
        var count = 0
        var total: Int64 = 0
        do {
            for row in rows {
                let line = try encodeLine(row)
                total += Int64(line.count)
                guard total <= C07OwnedDataLimits.maximumTableBytes else {
                    throw C07DataExchangeError.totalTooLarge
                }
                try handle.write(contentsOf: line)
                count += 1
            }
            try handle.synchronize()
        } catch let error as C07DataExchangeError {
            throw error
        } catch {
            throw C07DataExchangeError.storageUnavailable("tableWrite")
        }
        return count
    }
}


// MARK: - Restore execution results

public struct C07PreparedOwnedData: Sendable {
    public var plan: C07OwnedDataRestorePlanFile
    public var planURL: URL
    public var planSHA256: String
    public var staged: C07StagedOwnedData

    public init(plan: C07OwnedDataRestorePlanFile,
                planURL: URL, planSHA256: String,
                staged: C07StagedOwnedData) {
        self.plan = plan
        self.planURL = planURL
        self.planSHA256 = planSHA256
        self.staged = staged
    }
}

public struct C07ArtifactCommitReceipt: Sendable, Equatable {
    public var createdRoots: [String]
    public var attachmentPaths: [String: String]
    public var canvasProjects: Int
    public var mediaProjects: Int
    public var mediaAssets: Int
    public var privateTaskFiles: Int
    public var mailReceipts: Int
    public var evidenceRows: Int
    public var warnings: [String]

    public init(createdRoots: [String],
                attachmentPaths: [String: String],
                canvasProjects: Int, mediaProjects: Int, mediaAssets: Int,
                privateTaskFiles: Int, mailReceipts: Int,
                evidenceRows: Int = 0,
                warnings: [String] = []) {
        self.createdRoots = createdRoots
        self.attachmentPaths = attachmentPaths
        self.canvasProjects = canvasProjects
        self.mediaProjects = mediaProjects
        self.mediaAssets = mediaAssets
        self.privateTaskFiles = privateTaskFiles
        self.mailReceipts = mailReceipts
        self.evidenceRows = evidenceRows
        self.warnings = warnings
    }
}

public struct C07OwnedDataCommitReceipt: Sendable, Equatable {
    public var conversations: Int
    public var messages: Int
    public var runs: Int
    public var toolCalls: Int
    public var attachments: Int
    public var workspaces: Int
    public var schedules: Int
    public var providers: Int
    public var models: Int
    public var evidenceRows: Int
    public var warnings: [String]

    public init(conversations: Int = 0, messages: Int = 0, runs: Int = 0,
                toolCalls: Int = 0, attachments: Int = 0,
                workspaces: Int = 0, schedules: Int = 0,
                providers: Int = 0, models: Int = 0,
                evidenceRows: Int = 0, warnings: [String] = []) {
        self.conversations = conversations
        self.messages = messages
        self.runs = runs
        self.toolCalls = toolCalls
        self.attachments = attachments
        self.workspaces = workspaces
        self.schedules = schedules
        self.providers = providers
        self.models = models
        self.evidenceRows = evidenceRows
        self.warnings = warnings
    }
}


public final class C07RowLineWriter {
    private let handle: FileHandle
    private(set) public var rowCount: Int = 0
    private(set) public var byteCount: Int64 = 0
    private var finished = false

    public init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw C07DataExchangeError.storageUnavailable("tableCreate")
        }
        do { handle = try FileHandle(forWritingTo: url) }
        catch { throw C07DataExchangeError.storageUnavailable("tableOpenWrite") }
    }

    deinit { try? handle.close() }

    public func append(_ row: C07DBRow) throws {
        guard !finished else {
            throw C07DataExchangeError.storageUnavailable("tableClosed")
        }
        let line = try C07RowStream.encodeLine(row)
        byteCount += Int64(line.count)
        guard byteCount <= C07OwnedDataLimits.maximumTableBytes else {
            throw C07DataExchangeError.totalTooLarge
        }
        do { try handle.write(contentsOf: line) }
        catch { throw C07DataExchangeError.storageUnavailable("tableWrite") }
        rowCount += 1
        guard rowCount <= C07OwnedDataLimits.maximumRowsPerTable else {
            throw C07DataExchangeError.tooManyEntries
        }
    }

    public func finish() throws {
        guard !finished else { return }
        finished = true
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            throw C07DataExchangeError.storageUnavailable("tableClose")
        }
    }
}
