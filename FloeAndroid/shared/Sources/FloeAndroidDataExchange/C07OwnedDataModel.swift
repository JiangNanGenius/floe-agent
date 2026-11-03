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
    /// C08: retained Office recovery working copies and verified exports are
    /// user documents, not disposable cache. The section index is bounded
    /// descriptive metadata; every content entry is a separate exact-byte
    /// artifact below `artifacts/office-drafts/`.
    public static let officeDraftsEntry = "data/office-drafts.json"
    public static let officeDraftDirectory = "artifacts/office-drafts"
    public static let maximumOfficeDrafts = 64
    public static let maximumOfficeDraftBytes: Int64 = 256 * 1_024 * 1_024
    public static let maximumOfficeDraftTotalBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    public static let maximumOfficeDraftSectionBytes: Int64 = 512 * 1_024
    public static let maximumOfficeDraftDisplayNameBytes = 240

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
    /// Result engine retention caps: 8 MiB per retained result, 64 MiB per
    /// task, 64 results per task. The aggregate is bounded well below the
    /// 8 GiB table cap.
    public static let maximumToolResultBytes = 8 * 1_024 * 1_024
    public static let maximumToolResultRowBytes = 12 * 1_024 * 1_024
    public static let maximumToolResults = 200_000
    public static let maximumToolResultTotalBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
    public static let maximumConfigEntries = 4_096
    public static let maximumConfigBytes: Int64 = 32 * 1_024 * 1_024
    public static let maximumOmissions = 20_000
    public static let maximumOmissionBytes = 16 * 1_024 * 1_024
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
    /// App-local calendar todo. New identity is allocated so a restore never
    /// overwrites or collides with an existing todo.
    case todo
    /// Configuration-only identities. They are remapped inside the restored
    /// non-secret config archive, never inserted into a live table.
    case remoteHost
    case mailAccount
    /// Saved MCP definition. Restore allocates a fresh identity so a
    /// definition can never overwrite a current user server.
    case mcpServer
    /// Receipt-only rows whose primary identity is not rewritten because
    /// they never enter a live authorization table.
    case executionEvidence
    /// Durable user memory entry. New identity is allocated so a restore
    /// never collides with an existing memory; the user's text travels
    /// verbatim and memory stays data-only (no tool permission or trust).
    case memoryEntry
    /// Pending/activated/rejected durable memory candidate awaiting review.
    case memoryCandidate
    /// Versioned user-authored personalization document (soul / userProfile).
    case personalizationDocument
    /// Personalization auto-update preference cursor (composite key;
    /// `preservePrimary` keeps the kind/workspace key, never remapped).
    case preference
    /// Installed skill definition row. Content and install/source references
    /// are restored; installed/enabled state and grants are not.
    case skill

    /// Root identities are checked against live storage before commit. Child
    /// rows are protected by their own primary keys and exact journal plan.
    public var isRoot: Bool {
        switch self {
        case .conversation, .workspace, .schedule, .provider, .model,
             .canvas, .mediaProject, .todo:
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
    case todo
    /// Memory rows keep content/status verbatim; derived sync/recall state
    /// is reset so a restore never replays usage history or remote revisions.
    case memory
    /// Durable memory candidates are review queue entries, not authority.
    case memoryCandidate
    /// Versioned personalization document (revision renumbering happens in
    /// the commit adapter against the target DB).
    case personalizationDocument
    /// Auto-update preference cursor: only the user toggle travels;
    /// counters and last-generated timestamps are runtime state.
    case personalizationCursor
    /// A restored skill is reference-only: disabled, ungranted, unbound.
    case skill
    /// Singleton model preferences merge into the existing 'default' row.
    case modelPreferences
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
    /// Singleton/preference rows whose PRIMARY column is a fixed key
    /// ('default', personalization kind, workspace_key) rather than a
    /// remappable identity. The primary value travels verbatim; identity
    /// allocation and mapping are skipped for it.
    public var preservePrimary: Bool
    /// The table is expected to exist from this coordinated schema onward.
    /// Below this version its absence is a declared schema fact, not a
    /// silent scope reduction; at or above it, absence is a hard failure.
    /// For the 2026-11-02 user-data expansion this is set to the coordinated
    /// v52 freeze so archives written by earlier builds (schema <= 51,
    /// legacy scope) still validate while full v2 archives written from v52
    /// onward always carry the expanded coverage.
    public var minimumSchemaVersion: Int?
    /// Columns that only become required from a later coordinated schema.
    /// Used for `calendar_todos.reminders_suspended` (schema 52). A package
    /// written by a newer schema still fails closed on a narrowed app.
    public var requiredColumnMinimumSchema: [String: Int]

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
                 optional: Bool = false,
                 preservePrimary: Bool = false,
                 minimumSchemaVersion: Int? = nil,
                 requiredColumnMinimumSchema: [String: Int] = [:]) {
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
        self.preservePrimary = preservePrimary
        self.minimumSchemaVersion = minimumSchemaVersion
        self.requiredColumnMinimumSchema = requiredColumnMinimumSchema
    }

    /// Columns that must exist on an app at `schemaVersion`.
    public func requiredColumns(at schemaVersion: Int) -> Set<String> {
        var result = requiredColumns
        for (column, minimum) in requiredColumnMinimumSchema
        where schemaVersion >= minimum {
            result.insert(column)
        }
        return result
    }

    /// True when the table is expected on this schema version.
    public func isExpected(at schemaVersion: Int) -> Bool {
        guard let minimumSchemaVersion else { return true }
        return schemaVersion >= minimumSchemaVersion
    }
}

public enum C07OwnedDataPolicy {
    /// Archive entry for the bounded tool-result retention records. The body
    /// is produced by the result engine; the manifest carries its exact
    /// count/byte/digest contract.
    public static let toolResultsEntry = "data/tool-results.jsonl"

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
        // User-chosen model defaults/overrides (the singleton 'default' row).
        // The row merges into the target's existing preferences: unset routes
        // are filled with the remapped model identities; explicit local
        // choices are never overwritten. Sync revisions never travel.
        .init(name: "model_preferences", primaryKind: .preference,
              optionalReferences: [
                  "default_agent_model_id": .model,
                  "general_auxiliary_llm_model_id": .model,
                  "canvas_agent_model_id": .model,
                  "vision_model_id": .model,
                  "canvas_vision_model_id": .model,
                  "approval_model_id": .model,
                  "package_review_model_id": .model,
                  "shared_image_model_id": .model,
                  "image_generation_model_id": .model,
                  "image_editing_model_id": .model,
                  "default_video_model_id": .model,
              ],
              normalization: .modelPreferences,
              requiredColumns: ["id", "onboarding_status", "auxiliary_image_mode",
                                "updated_at", "sync_revision"],
              preservePrimary: true,
              minimumSchemaVersion: 52),
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
        // Durable user memory. Content/status/pinning travel verbatim;
        // recall statistics and the sync revision are runtime state and are
        // reset on restore. Owner references that no longer exist become
        // NULL (the retained text and its origin label still identify it).
        .init(name: "memory_entries", primaryKind: .memoryEntry,
              optionalReferences: ["workspace_id": .workspace,
                                    "conversation_id": .conversation,
                                    "origin_workspace_id": .workspace,
                                    "origin_conversation_id": .conversation],
              normalization: .memory,
              requiredColumns: ["id", "scope", "status", "content",
                                "normalized_content", "source_kind",
                                "created_at", "updated_at"],
              minimumSchemaVersion: 52),
        // Durable memory candidates awaiting (or concluded) review. The
        // review queue entry is user data; it grants nothing.
        .init(name: "memory_candidates", primaryKind: .memoryCandidate,
              optionalReferences: ["workspace_id": .workspace,
                                    "conversation_id": .conversation,
                                    "source_attachment_id": .attachment],
              jsonIDColumns: ["evidence_json", "conflicts_json"],
              normalization: .memoryCandidate,
              requiredColumns: ["id", "scope", "content", "confidence",
                                "stability", "importance", "sensitivity",
                                "origin", "evidence_json", "conflicts_json",
                                "status", "created_at", "updated_at"],
              minimumSchemaVersion: 52),
        // Versioned user-authored personalization documents (soul /
        // userProfile). Revisions are renumbered above the target's current
        // maximum per kind/workspace by the commit adapter so history order
        // is preserved without ever overwriting an existing document.
        .init(name: "personalization_documents",
              primaryKind: .personalizationDocument,
              optionalReferences: ["workspace_id": .workspace],
              normalization: .personalizationDocument,
              requiredColumns: ["id", "kind", "revision", "content",
                                "source_kind", "evidence_digest", "is_active",
                                "created_at"],
              minimumSchemaVersion: 52),
        // Auto-update preference per document kind/workspace. Only the
        // user's automatic_updates_enabled toggle travels; the kind/
        // workspace_key primary is preserved and the workspace reference is
        // remapped. Inserted only when the target has no cursor for the key.
        .init(name: "personalization_update_cursors",
              primaryColumn: "kind",
              primaryKind: .preference,
              optionalReferences: ["workspace_id": .workspace],
              normalization: .personalizationCursor,
              requiredColumns: ["kind", "workspace_key",
                                "automatic_updates_enabled",
                                "completed_runs_since_update",
                                "user_messages_since_update", "updated_at"],
              preservePrimary: true,
              minimumSchemaVersion: 52),
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
        // C06 App-local todos. They are independent user data, not a chat
        // projection. Due time, content, completion and reminder preference
        // survive; the planner's new `reminders_suspended` gate keeps a
        // restored reminder from firing until the user re-enables it.
        .init(name: "calendar_todos", primaryKind: .todo,
              optionalReferences: ["owner_conversation_id": .conversation,
                                   "owner_task_id": .conversation],
              normalization: .todo,
              requiredColumns: ["id", "title", "notes", "due_at",
                                "due_timezone", "all_day", "recurrence",
                                "recurrence_interval", "recurrence_until",
                                "reminder_minutes_before", "completed",
                                "completed_at", "revision",
                                "owner_conversation_id", "owner_task_id",
                                "owner_environment_id", "last_reminder_at",
                                "last_reminder_occurrence", "created_at",
                                "updated_at"],
              minimumSchemaVersion: 52,
              requiredColumnMinimumSchema: ["reminders_suspended": 52]),
        // User-authored task checklist version history. The composite
        // (conversation_id, revision) key is content, not resumable state:
        // the conversation/run references are remapped, the revision body
        // travels verbatim, and nothing auto-resumes a restored plan.
        .init(name: "task_checklist_revisions", primaryColumn: "conversation_id",
              primaryKind: .conversation,
              references: ["conversation_id": .conversation,
                            "run_id": .run],
              normalization: .none,
              requiredColumns: ["conversation_id", "revision", "run_id",
                                "operation_id", "request_digest", "body_json"],
              minimumSchemaVersion: 52),
        // Installed skill definitions: the user's custom source/config/
        // install references (source_url/source_digest, markdown, manifest,
        // declared capabilities) are restored through the original skills
        // table so they stay recoverable through the original services.
        // Installed/enabled state and capability grants never travel
        // (see `skillPermissionsAndTrust` in the scope exclusions).
        .init(name: "skills", primaryKind: .skill,
              normalization: .skill,
              requiredColumns: ["id", "name", "version", "status",
                                "skill_markdown", "manifest_json",
                                "declared_capabilities_json",
                                "effective_capabilities_json",
                                "rewritten_digest", "compatibility_report_json",
                                "created_at", "updated_at"],
              minimumSchemaVersion: 52),
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
        // Parent-run -> background-job dependency edges. The durable edge is
        // user plan/history content: it is exported, reference-verified and
        // retained ONLY under RestoredReceipts as read-only recovery
        // evidence. It is never inserted into the live table, so a
        // historical edge can never pin a run nonterminal again.
        .init(name: "run_dependencies", primaryColumn: "job_id",
              primaryKind: .executionEvidence,
              references: ["run_id": .run,
                            "conversation_id": .conversation],
              requiredColumns: ["job_id", "run_id", "conversation_id",
                                "kind", "state", "created_at"],
              disposition: .evidenceArchive, optional: true,
              minimumSchemaVersion: 52),
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

    /// Tables required for a full backup at one coordinated schema version.
    /// `calendar_todos` is required from schema 52 onward; on an older app it
    /// does not exist and its absence is a declared schema fact, not a
    /// silent scope reduction. The 2026-11-02 user-data expansion tables are
    /// likewise required from the coordinated v52 freeze onward: archives
    /// written by earlier builds (schema <= 51) validate with the legacy
    /// scope, while full v2 archives from v52 onward always carry them.
    public static func mandatoryTableNames(forSchema schemaVersion: Int) -> Set<String> {
        var result = mandatoryTableNames
        if schemaVersion >= 52 {
            result.insert("calendar_todos")
            result.formUnion(expandedUserDataTableNames)
        }
        return result
    }

    /// Live user-data tables added by the 2026-11-02 coverage expansion.
    public static let expandedUserDataTableNames: Set<String> = [
        "model_preferences", "memory_entries", "memory_candidates",
        "personalization_documents", "personalization_update_cursors",
        "task_checklist_revisions", "skills",
    ]

    /// Export-time row admission. Temporary chats never leave RAM and must
    /// never appear in a package, even if a historical bug wrote one; the
    /// same rule binds every user-data row that references a conversation.
    public static func shouldExportRow(table: String, row: C07DBRow,
                                       excludedConversationIDs: Set<String> = [])
        -> Bool
    {
        func referencesExcludedConversation() -> Bool {
            for column in ["conversation_id", "origin_conversation_id"] {
                if let id = row[column]?.stringValue,
                   !id.isEmpty, excludedConversationIDs.contains(id) {
                    return true
                }
            }
            return false
        }
        switch table {
        case "conversations":
            return row["purpose"]?.stringValue != "temporary"
        case "attachments":
            // An attachment without an owning conversation has no verified
            // restore owner; it is declared, not guessed.
            return row["conversation_id"]?.stringValue?.isEmpty == false
        case "memory_entries", "memory_candidates", "task_checklist_revisions",
             "run_dependencies":
            return !referencesExcludedConversation()
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
        case .todo:
            // Content/due/completion/reminder preference survive. The
            // reminder itself is suspended so no alarm or notification is
            // re-armed by a restore; the user resumes it explicitly. Set the
            // field unconditionally so a hand-edited row that omits it still
            // fails closed instead of taking the schema default (0).
            result["reminders_suspended"] = .int(1)
            result["owner_environment_id"] = .null
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
        case .memory:
            // The user's memory text, status, pinning, fact identity and
            // retention policy travel verbatim. Recall statistics and the
            // sync revision are runtime/remote state: a restore never
            // replays usage history or claims a remote revision.
            result["sync_revision"] = .int(0)
            result["last_recalled_at"] = .null
            result["recall_count"] = .int(0)
        case .memoryCandidate:
            // Review-queue content only; nothing to disarm.
            break
        case .personalizationDocument:
            // Revision renumbering is target-dependent and happens in the
            // commit adapter; content/source/evidence travel verbatim.
            break
        case .personalizationCursor:
            // Only the user's automatic-updates toggle travels. Counters
            // and the last-generated timestamp are runtime state.
            result["last_generated_at"] = .null
            result["completed_runs_since_update"] = .int(0)
            result["user_messages_since_update"] = .int(0)
        case .skill:
            // Reference-only restore: the definition and its source/install
            // references survive; installed/enabled state, effective
            // capability grants and model bindings are never fabricated.
            result["status"] = .string("disabled")
            result["effective_capabilities_json"] = .string("[]")
            result["selected_by_model_id"] = .null
            result["rewrite_model_id"] = .null
        case .modelPreferences:
            // Remote sync state never travels; the merge adapter advances
            // the target revision inside the one writer transaction.
            result["sync_revision"] = .int(0)
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
            if kind == "toolResult" {
                // A settled result receipt is user data: keep the bounded
                // redacted summary and identity, drop action bodies and any
                // artifact/output-file link that could point at an old id.
                if let payload = result["payload_json"]?.stringValue,
                   let sanitized = C07ToolResultReceipt.sanitize(payload) {
                    result["payload_json"] = .string(sanitized)
                } else {
                    result["payload_json"] = .string(
                        "{\"redacted\":\"secretBearingActionPayload\",\"kind\":\"toolResult\"}")
                }
            } else if ["toolRequest", "approval"].contains(kind) {
                result["payload_json"] = .string(
                    "{\"redacted\":\"secretBearingActionPayload\",\"kind\":\"\(kind)\"}")
            }
        case "child_run_entries":
            let kind = result["kind"]?.stringValue ?? ""
            if kind == "toolResult" {
                if let payload = result["payload_json"]?.stringValue,
                   let sanitized = C07ToolResultReceipt.sanitize(
                    payload, includeText: false) {
                    result["payload_json"] = .string(sanitized)
                } else {
                    result["payload_json"] = .string(
                        "{\"redacted\":\"secretBearingActionPayload\",\"kind\":\"toolResult\"}")
                }
            } else if ["toolRequest", "approval"].contains(kind) {
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

// MARK: - Office recovery documents (C08)

/// Which persisted Office recovery artifact the content came from. This is a
/// descriptive provenance marker, never an instruction or a live recovery
/// state: restore always writes a fresh App-owned document with a fresh
/// identity.
public enum C07OfficeDraftKind: String, Codable, Sendable, CaseIterable {
    /// The mutable `files/OfficeInputs/working/<session>/document.<ext>`
    /// copy an editable Office session was writing. It is a real user
    /// document even when no save completed.
    case workingCopy
    /// A module-verified `no_backup/floe-office-outputs/...` export whose
    /// exact bytes were verified by the Office engine.
    case verifiedOutput
}

/// One retained Office recovery content record. Only bounded, non-secret
/// descriptive metadata is carried. The old session/task/workspace/run/root/
/// native-generation/operation identities, destination URIs, grants and
/// credential references are deliberately absent.
public struct C07OwnedOfficeDraftRecord: Codable, Sendable, Equatable {
    /// Exact package-relative content entry.
    public var entry: String
    public var kind: C07OfficeDraftKind
    /// Bounded user-facing name (no local path).
    public var displayName: String
    /// `docx` / `xlsx` / `pptx` / `pdf`.
    public var format: String
    public var byteCount: Int64
    public var sha256: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Stable proof that the capture accepted the source only from the
    /// App-owned Office recovery roots. It is not an archive-controlled
    /// permission.
    public var ownership: String

    public static let ownershipMarker = "appOwnedOfficeRecovery"
    public static let allowedFormats: Set<String> = ["docx", "xlsx", "pptx", "pdf"]

    public init(entry: String, kind: C07OfficeDraftKind,
                displayName: String, format: String,
                byteCount: Int64, sha256: String,
                createdAt: Date, updatedAt: Date,
                ownership: String = C07OwnedOfficeDraftRecord.ownershipMarker) {
        self.entry = entry
        self.kind = kind
        self.displayName = C07OwnedOfficeDraftRecord.boundedName(displayName)
        self.format = format.lowercased()
        self.byteCount = byteCount
        self.sha256 = sha256
        // ISO-8601 metadata serialization is second-granular. Normalize here
        // so the writer's in-memory catalog and the reader's decoded catalog
        // compare equal (never a spurious hash/metadata failure).
        self.createdAt = Date(
            timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.towardZero))
        self.updatedAt = Date(
            timeIntervalSince1970: updatedAt.timeIntervalSince1970.rounded(.towardZero))
        self.ownership = ownership
    }

    /// Truncates at a Unicode scalar boundary so a long CJK name can never
    /// exceed the byte bound after initialization.
    public static func boundedName(_ raw: String) -> String {
        var result = ""
        for character in raw {
            let candidate = result + String(character)
            if candidate.utf8.count > C07OwnedDataLimits.maximumOfficeDraftDisplayNameBytes {
                break
            }
            result = candidate
        }
        return result
    }

    public func validate() throws {
        let relative = try C07Path.validateRelative(entry)
        guard relative.hasPrefix(C07OwnedDataLimits.officeDraftDirectory + "/") else {
            throw C07DataExchangeError.invalidManifest("officeDraftEntry")
        }
        let leaf = (relative as NSString).lastPathComponent
        let split = leaf.split(separator: ".", maxSplits: 1,
                               omittingEmptySubsequences: false)
        guard split.count == 2,
              let identifier = UUID(uuidString: String(split[0])),
              identifier.uuidString.lowercased() == String(split[0]).lowercased(),
              String(split[1]) == format,
              Self.allowedFormats.contains(format) else {
            throw C07DataExchangeError.invalidManifest("officeDraftName")
        }
        guard !displayName.isEmpty,
              displayName.utf8.count <= C07OwnedDataLimits.maximumOfficeDraftDisplayNameBytes,
              !displayName.contains("/"), !displayName.contains("\\"),
              displayName.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value != 0x7F
                      && !CharacterSet.controlCharacters.contains($0)
              }),
              !displayName.hasPrefix(".") else {
            throw C07DataExchangeError.invalidManifest("officeDraftDisplayName")
        }
        guard byteCount >= 1,
              byteCount <= C07OwnedDataLimits.maximumOfficeDraftBytes,
              C07SHA256Hex.isSHA256(sha256),
              ownership == Self.ownershipMarker else {
            throw C07DataExchangeError.invalidManifest("officeDraftBytes")
        }
    }
}

/// `data/office-drafts.json`: the bounded metadata index for retained Office
/// recovery content. This is the archive ENTRY body; `C07OwnedOfficeDraftSection`
/// in the owned-data manifest carries only the entry digest/size contract, the
/// same split used for tool-result retention records.
public struct C07OfficeDraftCatalog: Codable, Sendable, Equatable {
    public var records: [C07OwnedOfficeDraftRecord]

    public init(records: [C07OwnedOfficeDraftRecord]) {
        self.records = records
    }

    public var contentBytes: Int64 {
        records.reduce(0) { $0 + $1.byteCount }
    }

    public func validate() throws {
        guard records.count <= C07OwnedDataLimits.maximumOfficeDrafts,
              contentBytes <= C07OwnedDataLimits.maximumOfficeDraftTotalBytes else {
            throw C07DataExchangeError.tooManyEntries
        }
        var entries = Set<String>()
        var contents = Set<String>()
        for record in records {
            try record.validate()
            guard entries.insert(C07Path.collisionKey(record.entry)).inserted else {
                throw C07DataExchangeError.duplicateEntry(record.entry)
            }
            guard contents.insert("\(record.sha256)|\(record.byteCount)").inserted else {
                throw C07DataExchangeError.invalidManifest("officeDraftDuplicate")
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        guard Int64(data.count) <= C07OwnedDataLimits.maximumOfficeDraftSectionBytes else {
            throw C07DataExchangeError.entryTooLarge(
                C07OwnedDataLimits.officeDraftsEntry)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> C07OfficeDraftCatalog {
        guard Int64(data.count) <= C07OwnedDataLimits.maximumOfficeDraftSectionBytes else {
            throw C07DataExchangeError.entryTooLarge(
                C07OwnedDataLimits.officeDraftsEntry)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(C07OfficeDraftCatalog.self, from: data) }
        catch { throw C07DataExchangeError.invalidManifest("officeDraftDecode") }
    }
}

/// Manifest half of the retained Office recovery section: the metadata entry
/// and its exact count/size/digest contract.
public struct C07OwnedOfficeDraftSection: Codable, Sendable, Equatable {
    public var entry: String
    public var count: Int
    public var byteCount: Int64
    public var sha256: String
    /// Content records dropped because an identical digest+size was already
    /// carried (a working copy identical to its verified export, or two
    /// recovery records holding the same bytes).
    public var deduplicated: Int?

    public init(entry: String = C07OwnedDataLimits.officeDraftsEntry,
                count: Int, byteCount: Int64, sha256: String,
                deduplicated: Int? = nil) {
        self.entry = entry
        self.count = count
        self.byteCount = byteCount
        self.sha256 = sha256
        self.deduplicated = deduplicated
    }

    public func validate() throws {
        guard entry == C07OwnedDataLimits.officeDraftsEntry,
              count >= 0,
              count <= C07OwnedDataLimits.maximumOfficeDrafts,
              byteCount >= 0,
              byteCount <= C07OwnedDataLimits.maximumOfficeDraftSectionBytes,
              C07SHA256Hex.isSHA256(sha256) else {
            throw C07DataExchangeError.invalidManifest("officeDraftSection")
        }
        if let deduplicated {
            guard deduplicated >= 0,
                  deduplicated <= C07OwnedDataLimits.maximumOfficeDrafts * 2 else {
                throw C07DataExchangeError.invalidManifest("officeDraftDedupe")
            }
        }
    }
}

/// One staged content file for a validated office-draft record.
public struct C07SourceOfficeDraft: Sendable, Equatable {
    public var record: C07OwnedOfficeDraftRecord
    public var url: URL

    public init(record: C07OwnedOfficeDraftRecord, url: URL) {
        self.record = record
        self.url = url
    }
}

public struct C07SourceOfficeDraftSection: Sendable, Equatable {
    public var section: C07OwnedOfficeDraftSection
    public var catalog: C07OfficeDraftCatalog
    public var metadataURL: URL
    public var contents: [String: URL]

    public init(section: C07OwnedOfficeDraftSection,
                catalog: C07OfficeDraftCatalog,
                metadataURL: URL,
                contents: [String: URL]) {
        self.section = section
        self.catalog = catalog
        self.metadataURL = metadataURL
        self.contents = contents
    }
}

public struct C07StagedOfficeDraftSection: Sendable, Equatable {
    public var section: C07OwnedOfficeDraftSection
    public var catalog: C07OfficeDraftCatalog
    public var metadataURL: URL
    public var contents: [String: URL]

    public init(section: C07OwnedOfficeDraftSection,
                catalog: C07OfficeDraftCatalog,
                metadataURL: URL,
                contents: [String: URL]) {
        self.section = section
        self.catalog = catalog
        self.metadataURL = metadataURL
        self.contents = contents
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
    /// A durable file in one of the existing `ArtifactNamespace` roots
    /// (`GeneratedImages`, `VNCArtifacts`, `RDPArtifacts`, `RunOutputs`,
    /// `JobDownloads`, ...). The logical path keeps the namespace-relative
    /// path verbatim.
    case appArtifact
    /// Global App-managed font catalogue and exact digest-named payloads.
    /// Typeface validation and adoption stay with the App font resource adapter.
    case managedFont
    /// A user-owned capture file outside the artifact root (packet captures
    /// and their App-owned analysis). Restored into a read-only recovery
    /// area, never into a live capture library.
    case captureFile
    /// One non-secret configuration document (`remoteHosts`, `rdpEndpoints`,
    /// `mailAccounts`). Never live authorization.
    case configuration
    /// Opaque donor CAD sections carried by a `.flocanvas` package. Android
    /// has no CAD editing kernel; bytes are preserved read-only.
    case canvasCADDraft
    case canvasCADRevision
    case canvasNativeCAD

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
        case .appArtifact: return "\(C07OwnedDataLimits.artifactDirectory)/app"
        case .managedFont: return "\(C07OwnedDataLimits.artifactDirectory)/fonts"
        case .captureFile: return "\(C07OwnedDataLimits.artifactDirectory)/captures"
        case .configuration: return "\(C07OwnedDataLimits.artifactDirectory)/config"
        case .canvasCADDraft: return "\(C07OwnedDataLimits.artifactDirectory)/canvas-cad-drafts"
        case .canvasCADRevision: return "\(C07OwnedDataLimits.artifactDirectory)/canvas-cad-revisions"
        case .canvasNativeCAD: return "\(C07OwnedDataLimits.artifactDirectory)/canvas-native-cad"
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
        case .managedFont:
            guard ownerID == nil, containerID == nil,
                  logical == "catalog.json" || (logical.utf8.count == 68 && logical.hasSuffix(".ttf")
                    && logical.dropLast(4).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })) else {
                throw C07DataExchangeError.unsafePath(logicalPath)
            }
            return "\(root)/\(logical)"
        case .appArtifact, .captureFile, .configuration:
            guard ownerID == nil, containerID == nil else {
                throw C07DataExchangeError.unsafePath(logicalPath)
            }
            // `logical` already includes the namespace/area prefix so two
            // different roots can never collide silently.
            return "\(root)/\(logical)"
        case .canvasCADDraft, .canvasCADRevision, .canvasNativeCAD:
            guard let containerID else {
                throw C07DataExchangeError.unsafePath(logicalPath)
            }
            return "\(root)/\(containerID.uuidString)/\(logical)"
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
    // Added after the first v2 packages shipped. Optional so an existing
    // archive still decodes; absent means zero for that category.
    public var todos: Int?
    public var appArtifacts: Int?
    public var captureFiles: Int?
    public var configSections: Int?
    /// MCP server definitions represented in the typed `mcpServers`
    /// configuration section. Optional so an existing archive still decodes.
    public var mcpDefinitions: Int?
    public var toolResults: Int?
    public var omissions: Int?
    // 2026-11-02 user-data expansion counts. Optional so an existing
    // archive still decodes; absent means zero for that category.
    public var memoryEntries: Int?
    public var memoryCandidates: Int?
    public var personalizationDocuments: Int?
    public var personalizationCursors: Int?
    public var checklistRevisions: Int?
    public var skills: Int?
    public var modelPreferences: Int?
    public var runDependencies: Int?
    /// Retained Office recovery document content carried by this package.
    public var officeDrafts: Int?
    public var officeDraftBytes: Int64?

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
                artifactBytes: Int64 = 0, todos: Int? = nil,
                appArtifacts: Int? = nil, captureFiles: Int? = nil,
                configSections: Int? = nil, mcpDefinitions: Int? = nil,
                toolResults: Int? = nil,
                omissions: Int? = nil, memoryEntries: Int? = nil,
                memoryCandidates: Int? = nil,
                personalizationDocuments: Int? = nil,
                personalizationCursors: Int? = nil,
                checklistRevisions: Int? = nil, skills: Int? = nil,
                modelPreferences: Int? = nil, runDependencies: Int? = nil,
                officeDrafts: Int? = nil, officeDraftBytes: Int64? = nil) {
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
        self.todos = todos
        self.appArtifacts = appArtifacts
        self.captureFiles = captureFiles
        self.configSections = configSections
        self.mcpDefinitions = mcpDefinitions
        self.toolResults = toolResults
        self.omissions = omissions
        self.memoryEntries = memoryEntries
        self.memoryCandidates = memoryCandidates
        self.personalizationDocuments = personalizationDocuments
        self.personalizationCursors = personalizationCursors
        self.checklistRevisions = checklistRevisions
        self.skills = skills
        self.modelPreferences = modelPreferences
        self.runDependencies = runDependencies
        self.officeDrafts = officeDrafts
        self.officeDraftBytes = officeDraftBytes
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
    // Optional additions keep older v2 packages readable. A writer always
    // sets them, and `validate()` requires internal consistency.
    public var completeness: C07DataCompleteness?
    public var omissions: [C07DataOmission]?
    public var toolResults: C07OwnedToolResultSection?
    public var configSections: [C07OwnedConfigSection]?
    public var deduplicatedArtifacts: Int?
    /// C08 retained Office recovery content. Optional so archives written by
    /// earlier builds still decode.
    public var officeDrafts: C07OwnedOfficeDraftSection?

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
                warnings: [String] = [],
                completeness: C07DataCompleteness? = nil,
                omissions: [C07DataOmission]? = nil,
                toolResults: C07OwnedToolResultSection? = nil,
                configSections: [C07OwnedConfigSection]? = nil,
                deduplicatedArtifacts: Int? = nil,
                officeDrafts: C07OwnedOfficeDraftSection? = nil) {
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
        self.completeness = completeness
        self.omissions = omissions
        self.toolResults = toolResults
        self.configSections = configSections
        self.deduplicatedArtifacts = deduplicatedArtifacts
        self.officeDrafts = officeDrafts
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
        guard C07OwnedDataPolicy.mandatoryTableNames(
            forSchema: sourceAppSchemaVersion).isSubset(of: provided) else {
            throw C07DataExchangeError.invalidManifest("ownedTablesMissing")
        }
        // A table that belongs to a newer coordinated schema may be absent
        // only when the archive itself was written by an older schema.
        for policy in C07OwnedDataPolicy.tables
        where !provided.contains(policy.name) {
            if policy.isExpected(at: sourceAppSchemaVersion) && !policy.optional {
                throw C07DataExchangeError.invalidManifest(
                    "ownedTableMissing:\(policy.name)")
            }
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

        let declaredOmissions = omissions ?? []
        guard declaredOmissions.count <= C07OwnedDataLimits.maximumOmissions else {
            throw C07DataExchangeError.tooManyEntries
        }
        for omission in declaredOmissions { try omission.validate() }
        let resolvedCompleteness: C07DataCompleteness =
            completeness ?? (declaredOmissions.isEmpty ? .complete : .partial)
        switch resolvedCompleteness {
        case .complete:
            guard declaredOmissions.isEmpty else {
                throw C07DataExchangeError.invalidManifest("completeWithOmissions")
            }
        case .partial:
            guard !declaredOmissions.isEmpty else {
                throw C07DataExchangeError.invalidManifest("partialWithoutOmissions")
            }
        }
        if let toolResults {
            try toolResults.validate()
        }
        if let configSections {
            guard configSections.count <= C07OwnedConfigKind.allCases.count else {
                throw C07DataExchangeError.tooManyEntries
            }
            var kinds = Set<C07OwnedConfigKind>()
            var entries = Set<String>()
            for section in configSections {
                try section.validate()
                guard kinds.insert(section.kind).inserted,
                      entries.insert(section.entry).inserted else {
                    throw C07DataExchangeError.invalidManifest("configDuplicate")
                }
            }
            if kinds.contains(.rdpEndpoints) {
                guard kinds.contains(.remoteHosts) else {
                    throw C07DataExchangeError.referenceMissing("rdpHostsSection")
                }
            }
        }
        if let deduplicatedArtifacts {
            guard deduplicatedArtifacts >= 0,
                  deduplicatedArtifacts <= C07OwnedDataLimits.maximumArtifacts else {
                throw C07DataExchangeError.invalidManifest("deduplicatedArtifacts")
            }
        }
        if let officeDrafts {
            try officeDrafts.validate()
            guard (counts.officeDrafts ?? officeDrafts.count) == officeDrafts.count else {
                throw C07DataExchangeError.invalidManifest("officeDraftCountField")
            }
            // The bytes total is verified against the decoded catalog by the
            // archive reader/writer; the manifest only names the metadata
            // entry, so it cannot self-reference its own digest.
        } else if (counts.officeDrafts ?? 0) != 0 {
            throw C07DataExchangeError.invalidManifest("officeDraftMissingSection")
        }
        if let toolResults {
            guard (counts.toolResults ?? toolResults.count) == toolResults.count else {
                throw C07DataExchangeError.invalidManifest("toolResultCountField")
            }
        }
        if let configSections {
            guard (counts.configSections ?? configSections.count) == configSections.count else {
                throw C07DataExchangeError.invalidManifest("configCountField")
            }
        }
        if let declaredMCP = counts.mcpDefinitions {
            let sectionCount = configSections?
                .first(where: { $0.kind == .mcpServers })?.count ?? 0
            guard declaredMCP == sectionCount else {
                throw C07DataExchangeError.invalidManifest("mcpCountField")
            }
        }
        if let declaredCount = counts.omissions,
           declaredCount != declaredOmissions.count {
            throw C07DataExchangeError.invalidManifest("omissionCountField")
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

public struct C07SourceConfigSection: Sendable, Equatable {
    public var section: C07OwnedConfigSection
    public var url: URL

    public init(section: C07OwnedConfigSection, url: URL) {
        self.section = section
        self.url = url
    }
}

public struct C07SourceToolResultSection: Sendable, Equatable {
    public var section: C07OwnedToolResultSection
    public var url: URL

    public init(section: C07OwnedToolResultSection, url: URL) {
        self.section = section
        self.url = url
    }
}

public struct C07SourceOwnedData: Sendable {
    public var tables: [C07SourceTable]
    public var workspaces: C07SourceWorkspaces?
    public var artifacts: [C07SourceArtifact]
    public var toolResults: C07SourceToolResultSection?
    public var configs: [C07SourceConfigSection]
    public var officeDrafts: C07SourceOfficeDraftSection?
    public var omissions: [C07DataOmission]
    public var deduplicatedArtifacts: Int
    public var counts: C07OwnedDataCounts
    public var excluded: [C07ExcludedScope]
    public var linuxCheckpointPort: String
    public var linuxCheckpointReason: String?
    public var warnings: [String]

    public init(tables: [C07SourceTable],
                workspaces: C07SourceWorkspaces?,
                artifacts: [C07SourceArtifact],
                toolResults: C07SourceToolResultSection? = nil,
                configs: [C07SourceConfigSection] = [],
                officeDrafts: C07SourceOfficeDraftSection? = nil,
                omissions: [C07DataOmission] = [],
                deduplicatedArtifacts: Int = 0,
                counts: C07OwnedDataCounts,
                excluded: [C07ExcludedScope],
                linuxCheckpointPort: String,
                linuxCheckpointReason: String? = nil,
                warnings: [String] = []) {
        self.tables = tables
        self.workspaces = workspaces
        self.artifacts = artifacts
        self.toolResults = toolResults
        self.configs = configs
        self.officeDrafts = officeDrafts
        self.omissions = omissions
        self.deduplicatedArtifacts = deduplicatedArtifacts
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

public struct C07StagedConfigSection: Sendable, Equatable {
    public var section: C07OwnedConfigSection
    public var url: URL

    public init(section: C07OwnedConfigSection, url: URL) {
        self.section = section
        self.url = url
    }
}

public struct C07StagedToolResultSection: Sendable, Equatable {
    public var section: C07OwnedToolResultSection
    public var url: URL

    public init(section: C07OwnedToolResultSection, url: URL) {
        self.section = section
        self.url = url
    }
}

public struct C07StagedOwnedData: Sendable {
    public var manifest: C07OwnedDataManifest
    public var manifestSHA256: String
    public var tables: [C07StagedTable]
    public var workspaces: [C07WorkspaceDescriptor]
    public var artifacts: [C07StagedArtifact]
    public var toolResults: C07StagedToolResultSection?
    public var configs: [C07StagedConfigSection]
    public var officeDrafts: C07StagedOfficeDraftSection?
    public var totalBytes: Int64

    public init(manifest: C07OwnedDataManifest,
                manifestSHA256: String,
                tables: [C07StagedTable],
                workspaces: [C07WorkspaceDescriptor],
                artifacts: [C07StagedArtifact],
                toolResults: C07StagedToolResultSection? = nil,
                configs: [C07StagedConfigSection] = [],
                officeDrafts: C07StagedOfficeDraftSection? = nil,
                totalBytes: Int64) {
        self.manifest = manifest
        self.manifestSHA256 = manifestSHA256
        self.tables = tables
        self.workspaces = workspaces
        self.artifacts = artifacts
        self.toolResults = toolResults
        self.configs = configs
        self.officeDrafts = officeDrafts
        self.totalBytes = totalBytes
    }
}

// MARK: - Restore plan file (durable rollback identity)

/// One retained tool result to recreate through the real result engine under
/// NEW identities. `newRef` is derived from the new run/call pair and is what
/// the durable toolResult checkpoint summary is rewritten to.
public struct C07ToolResultPlanEntry: Codable, Sendable, Equatable {
    public var oldTaskID: UUID
    public var oldRunID: UUID
    public var oldCallID: String
    public var newTaskID: UUID
    public var newRunID: UUID
    public var newCallID: String
    public var newRef: String
    public var byteCount: Int
    public var sha256: String
    public var originalDigest: String?
    /// Source retention/execution truncation facts. Optional so a plan written
    /// before this field still decodes (treated as false).
    public var retentionTruncated: Bool?
    public var executionReportedTruncation: Bool?

    public init(oldTaskID: UUID, oldRunID: UUID, oldCallID: String,
                newTaskID: UUID, newRunID: UUID, newCallID: String,
                newRef: String, byteCount: Int, sha256: String,
                originalDigest: String?,
                retentionTruncated: Bool? = nil,
                executionReportedTruncation: Bool? = nil) {
        self.oldTaskID = oldTaskID
        self.oldRunID = oldRunID
        self.oldCallID = oldCallID
        self.newTaskID = newTaskID
        self.newRunID = newRunID
        self.newCallID = newCallID
        self.newRef = newRef
        self.byteCount = byteCount
        self.sha256 = sha256
        self.originalDigest = originalDigest
        self.retentionTruncated = retentionTruncated
        self.executionReportedTruncation = executionReportedTruncation
    }
}

/// One fresh App-owned Office document this restore will create from retained
/// recovery content. `documentID` is a NEW identity allocated at prepare
/// time; no old recovery candidate/session identity is carried.
public struct C07OfficeDraftPlanEntry: Codable, Sendable, Equatable {
    public var documentID: UUID
    public var sourceEntry: String
    public var displayName: String
    public var format: String
    public var kind: C07OfficeDraftKind
    public var byteCount: Int64
    public var sha256: String

    public init(documentID: UUID, sourceEntry: String,
                displayName: String, format: String,
                kind: C07OfficeDraftKind, byteCount: Int64,
                sha256: String) {
        self.documentID = documentID
        self.sourceEntry = sourceEntry
        self.displayName = displayName
        self.format = format
        self.kind = kind
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public func validate() throws {
        guard !sourceEntry.isEmpty,
              sourceEntry.utf8.count <= C07DataExchangeLimits.maximumPathBytes,
              !displayName.isEmpty,
              displayName.utf8.count <= C07OwnedDataLimits.maximumOfficeDraftDisplayNameBytes,
              !displayName.contains("/"), !displayName.contains("\\"),
              C07OwnedOfficeDraftRecord.allowedFormats.contains(format),
              byteCount >= 1,
              byteCount <= C07OwnedDataLimits.maximumOfficeDraftBytes,
              C07SHA256Hex.isSHA256(sha256) else {
            throw C07DataExchangeError.invalidManifest("officeDraftPlan")
        }
    }
}

public struct C07OwnedDataRestorePlanFile: Codable, Sendable, Equatable {
    public var restoreID: UUID
    public var planVersion: Int
    public var idMap: C07IDMap
    public var artifactRoots: [String]
    /// Optional for older journals; identifies a prepared App font transaction
    /// by this plan's own restoreID, never an archive-supplied host path.
    public var managedFontCount: Int?
    public var attachmentPaths: [String: String]
    public var workspaceIDs: [String]
    public var environmentIDs: [UUID]?
    public var environmentIdentityMap: [String: String]?
    public var toolResultEntries: [C07ToolResultPlanEntry]?
    public var toolResultTaskIDs: [UUID]?
    public var remoteHostIDs: [String: String]?
    public var mailAccountIDs: [String: String]?
    public var configEntries: [String]?
    /// Old MCP definition UUID -> fresh restored UUID. The values are the
    /// EXACT identities a rollback removes from the original MCP settings
    /// row; nothing else in that row is rewritten.
    public var mcpServerIDs: [String: String]?
    /// Whether `floe.mcp.remoteServers.v1` existed before the restore. A
    /// rollback removes the row only when it did not exist and no concurrent
    /// local definition remains.
    public var mcpServersRowExisted: Bool?
    /// Pre-restore snapshot of the singleton model_preferences row so a
    /// rollback can restore the exact prior preferences after a merge.
    /// Nil means the row did not exist at prepare time.
    public var previousModelPreferences: C07DBRow?
    /// Exact (kind, workspace_key) personalization cursor keys this restore
    /// will INSERT (target had no cursor for them at prepare time), so a
    /// rollback removes precisely those rows and nothing else.
    public var personalizationCursorKeys: [String]?
    /// Fresh restored Office document identities/content this plan creates.
    /// Optional so a plan written before C08 still decodes.
    public var officeDrafts: [C07OfficeDraftPlanEntry]?
    public var counts: C07OwnedDataCounts
    public var warnings: [String]

    public init(restoreID: UUID, planVersion: Int = 1,
                idMap: C07IDMap,
                artifactRoots: [String],
                managedFontCount: Int? = nil,
                attachmentPaths: [String: String],
                workspaceIDs: [String],
                environmentIDs: [UUID]? = nil,
                environmentIdentityMap: [String: String]? = nil,
                toolResultEntries: [C07ToolResultPlanEntry]? = nil,
                toolResultTaskIDs: [UUID]? = nil,
                remoteHostIDs: [String: String]? = nil,
                mailAccountIDs: [String: String]? = nil,
                configEntries: [String]? = nil,
                mcpServerIDs: [String: String]? = nil,
                mcpServersRowExisted: Bool? = nil,
                previousModelPreferences: C07DBRow? = nil,
                personalizationCursorKeys: [String]? = nil,
                officeDrafts: [C07OfficeDraftPlanEntry]? = nil,
                counts: C07OwnedDataCounts,
                warnings: [String]) {
        self.restoreID = restoreID
        self.planVersion = planVersion
        self.idMap = idMap
        self.artifactRoots = artifactRoots
        self.managedFontCount = managedFontCount
        self.attachmentPaths = attachmentPaths
        self.workspaceIDs = workspaceIDs
        self.environmentIDs = environmentIDs
        self.environmentIdentityMap = environmentIdentityMap
        self.toolResultEntries = toolResultEntries
        self.toolResultTaskIDs = toolResultTaskIDs
        self.remoteHostIDs = remoteHostIDs
        self.mailAccountIDs = mailAccountIDs
        self.configEntries = configEntries
        self.mcpServerIDs = mcpServerIDs
        self.mcpServersRowExisted = mcpServersRowExisted
        self.previousModelPreferences = previousModelPreferences
        self.personalizationCursorKeys = personalizationCursorKeys
        self.officeDrafts = officeDrafts
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
    public var appArtifacts: Int
    public var captureFiles: Int
    public var cadPreservedFiles: Int
    public var toolResults: Int
    public var configSections: Int
    public var officeDrafts: Int
    public var warnings: [String]

    public init(createdRoots: [String],
                attachmentPaths: [String: String],
                canvasProjects: Int, mediaProjects: Int, mediaAssets: Int,
                privateTaskFiles: Int, mailReceipts: Int,
                evidenceRows: Int = 0,
                appArtifacts: Int = 0, captureFiles: Int = 0,
                cadPreservedFiles: Int = 0, toolResults: Int = 0,
                configSections: Int = 0, officeDrafts: Int = 0,
                warnings: [String] = []) {
        self.createdRoots = createdRoots
        self.attachmentPaths = attachmentPaths
        self.canvasProjects = canvasProjects
        self.mediaProjects = mediaProjects
        self.mediaAssets = mediaAssets
        self.privateTaskFiles = privateTaskFiles
        self.mailReceipts = mailReceipts
        self.evidenceRows = evidenceRows
        self.appArtifacts = appArtifacts
        self.captureFiles = captureFiles
        self.cadPreservedFiles = cadPreservedFiles
        self.toolResults = toolResults
        self.configSections = configSections
        self.officeDrafts = officeDrafts
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
    public var todos: Int
    // 2026-11-02 user-data expansion receipts.
    public var memoryEntries: Int
    public var memoryCandidates: Int
    public var personalizationDocuments: Int
    public var personalizationCursors: Int
    public var checklistRevisions: Int
    public var skills: Int
    public var modelPreferences: Int
    /// Fresh disabled/unbound MCP definitions inserted into the original
    /// settings row by this restore.
    public var mcpDefinitions: Int
    public var partial: Bool
    public var omissions: Int
    public var warnings: [String]

    public init(conversations: Int = 0, messages: Int = 0, runs: Int = 0,
                toolCalls: Int = 0, attachments: Int = 0,
                workspaces: Int = 0, schedules: Int = 0,
                providers: Int = 0, models: Int = 0,
                evidenceRows: Int = 0, todos: Int = 0,
                memoryEntries: Int = 0, memoryCandidates: Int = 0,
                personalizationDocuments: Int = 0,
                personalizationCursors: Int = 0,
                checklistRevisions: Int = 0, skills: Int = 0,
                modelPreferences: Int = 0, mcpDefinitions: Int = 0,
                partial: Bool = false, omissions: Int = 0,
                warnings: [String] = []) {
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
        self.todos = todos
        self.memoryEntries = memoryEntries
        self.memoryCandidates = memoryCandidates
        self.personalizationDocuments = personalizationDocuments
        self.personalizationCursors = personalizationCursors
        self.checklistRevisions = checklistRevisions
        self.skills = skills
        self.modelPreferences = modelPreferences
        self.mcpDefinitions = mcpDefinitions
        self.partial = partial
        self.omissions = omissions
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
