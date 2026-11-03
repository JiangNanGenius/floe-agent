// SPDX-License-Identifier: MPL-2.0
//
// C07 user-data restore adapters.
//
// The generic owned-data commit inserts one normalized, identity-remapped row
// per table. A small set of user-data tables has target-dependent semantics
// that a blind INSERT cannot express honestly; this adapter owns those rows
// INSIDE the same single GRDB writer transaction, after the same export-side
// normalization and reference mapping:
//
//   * model_preferences — a singleton preference row. The restore MERGES:
//     unset model routes are filled with the remapped model identities,
//     explicit local choices are never overwritten, and the sync revision is
//     advanced by exactly one on a real change (same-writer CAS discipline as
//     the original store). The user's chosen defaults/overrides survive
//     without clobbering newer local configuration.
//   * personalization_documents — versioned user-authored documents.
//     Revisions are renumbered above the target's per-(kind, workspace)
//     maximum so history order is preserved and no existing document is
//     overwritten or displaced; the originally-active revision becomes
//     active only when the target has no active document for that slot.
//   * personalization_update_cursors — the auto-update preference toggle.
//     Inserted only when the target has no cursor for the (kind,
//     remapped-workspace) key; counters and generation timestamps are
//     runtime state and start at zero/nil.
//   * skills — installed definitions are restored as DISABLED reference
//     rows: content, manifest, declared capabilities and the custom
//     source/install references (source_url/source_digest) survive so the
//     original services can recover them; enabled state, effective grants
//     and model bindings never travel. A same-name conflict with different
//     content is restored under an explicit " (restored …)" display name —
//     content is preserved, the existing skill is never overwritten.
//
// Everything here runs on the ORIGINAL tables through the ONE
// DatabaseManager writer; there is no second store, no second registry and
// no fabricated trust.
import Foundation
import GRDB
import FloeCore
import FloePersistence
import FloeAndroidDataExchange

public enum C07UserDataAdapters {
    /// Tables whose live commit is owned by this adapter. The generic commit
    /// still validates their identity/reference closure up front; only the
    /// final INSERT is routed here.
    public static func isAdapterOwned(_ table: String) -> Bool {
        switch table {
        case "model_preferences", "personalization_documents",
             "personalization_update_cursors", "skills":
            return true
        default:
            return false
        }
    }

    /// Every model-route column carried by the singleton preferences row.
    static let modelPreferenceColumns: [String] = [
        "default_agent_model_id",
        "general_auxiliary_llm_model_id",
        "canvas_agent_model_id",
        "vision_model_id",
        "canvas_vision_model_id",
        "approval_model_id",
        "package_review_model_id",
        "shared_image_model_id",
        "image_generation_model_id",
        "image_editing_model_id",
        "default_video_model_id",
    ]

    static func dbValue(_ value: DatabaseValue) -> C07DBValue {
        C07DatabaseValueCodec.value(value)
    }

    static func insert(
        _ table: String, _ values: C07DBRow, into db: Database
    ) throws {
        let schemaColumns = Set(try db.columns(in: table).map(\.name))
        let present = values.keys
            .filter { schemaColumns.contains($0) && c07SafeIdentifier($0) }
            .sorted()
        guard !present.isEmpty else {
            throw C07DataExchangeError.schemaMismatch(0)
        }
        let quoted = present.map { "\"\($0)\"" }.joined(separator: ",")
        let placeholders = Array(
            repeating: "?", count: present.count).joined(separator: ",")
        try db.execute(
            sql: "INSERT INTO \"\(table)\" (\(quoted)) VALUES (\(placeholders))",
            arguments: StatementArguments(
                present.map { c07DatabaseValue(values[$0] ?? .null) }))
    }

    public static func commitRow(
        table: String,
        values: C07DBRow,
        restoreID: UUID,
        db: Database,
        receipt: inout C07OwnedDataCommitReceipt,
        warnings: inout [String]
    ) throws {
        switch table {
        case "model_preferences":
            try mergeModelPreferences(
                values: values, db: db, receipt: &receipt,
                warnings: &warnings)
        case "personalization_documents":
            try insertPersonalizationDocument(
                values: values, db: db, receipt: &receipt,
                warnings: &warnings)
        case "personalization_update_cursors":
            try insertPersonalizationCursor(
                values: values, db: db, receipt: &receipt,
                warnings: &warnings)
        case "skills":
            try insertSkill(
                values: values, restoreID: restoreID, db: db,
                receipt: &receipt, warnings: &warnings)
        default:
            throw C07DataExchangeError.invalidManifest("adapterTable:\(table)")
        }
    }

    // MARK: - Model preferences (singleton merge)

    static func mergeModelPreferences(
        values: C07DBRow,
        db: Database,
        receipt: inout C07OwnedDataCommitReceipt,
        warnings: inout [String]
    ) throws {
        let now = c07DateString(Date())
        guard let current = try Row.fetchOne(
            db, sql: "SELECT * FROM model_preferences WHERE id = 'default'"
        ) else {
            var created = values
            created["id"] = .string("default")
            created["sync_revision"] = .int(0)
            created["updated_at"] = .string(now)
            try insert("model_preferences", created, into: db)
            receipt.modelPreferences = 1
            return
        }
        var changed = false
        for column in modelPreferenceColumns {
            guard let incoming = values[column], !incoming.isNull else {
                continue
            }
            let existing = dbValue(current[column])
            if existing.isNull {
                try db.execute(
                    sql: """
                        UPDATE model_preferences SET \(column) = ?
                        WHERE id = 'default' AND \(column) IS NULL
                        """,
                    arguments: [c07DatabaseValue(incoming)])
                if db.changesCount > 0 { changed = true }
            } else if existing != incoming {
                warnings.append("modelPreferencesExistingKept:\(column)")
            }
        }
        let existingOnboarding = dbValue(current["onboarding_status"])
        if let onboarding = values["onboarding_status"],
           !onboarding.isNull,
           onboarding.stringValue != "unseen",
           (existingOnboarding.isNull
            || existingOnboarding.stringValue == "unseen") {
            try db.execute(
                sql: """
                    UPDATE model_preferences SET onboarding_status = ?
                    WHERE id = 'default' AND onboarding_status = 'unseen'
                    """,
                arguments: [c07DatabaseValue(onboarding)])
            if db.changesCount > 0 { changed = true }
        }
        // auxiliary_image_mode / autonomous_image_routing keep their local
        // values: they are transition state of the live picker, not a stale
        // route, and overwriting them could corrupt an in-flight switch.
        if changed {
            try db.execute(
                sql: """
                    UPDATE model_preferences
                    SET updated_at = ?,
                        sync_revision = CASE
                            WHEN sync_revision >= 9223372036854775807
                            THEN 9223372036854775807
                            ELSE sync_revision + 1 END
                    WHERE id = 'default'
                    """,
                arguments: [now])
            receipt.modelPreferences = 1
        }
    }

    // MARK: - Personalization documents (revision renumbering)

    static func insertPersonalizationDocument(
        values: C07DBRow,
        db: Database,
        receipt: inout C07OwnedDataCommitReceipt,
        warnings: inout [String]
    ) throws {
        guard let kind = values["kind"]?.stringValue, !kind.isEmpty else {
            throw C07DataExchangeError.invalidManifest("personalizationKind")
        }
        let workspaceValue = values["workspace_id"] ?? .null
        let sourceRevision = values["revision"]?.integerValue ?? 0
        guard sourceRevision > 0 else {
            throw C07DataExchangeError.invalidManifest(
                "personalizationRevision")
        }
        let maximum = try Int.fetchOne(
            db,
            sql: """
                SELECT COALESCE(MAX(revision), 0) FROM personalization_documents
                WHERE kind = ? AND workspace_id IS ?
                """,
            arguments: [
                DatabaseValue(value: kind),
                c07DatabaseValue(workspaceValue),
            ]) ?? 0
        var stored = values
        stored["revision"] = .int(Int64(maximum) + sourceRevision)
        if stored["is_active"]?.integerValue == 1 {
            let activeCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM personalization_documents
                    WHERE kind = ? AND workspace_id IS ? AND is_active = 1
                    """,
                arguments: [
                    DatabaseValue(value: kind),
                    c07DatabaseValue(workspaceValue),
                ]) ?? 0
            if activeCount > 0 {
                stored["is_active"] = .int(0)
                warnings.append("personalizationKeptCurrentActive:\(kind)")
            }
        }
        try insert("personalization_documents", stored, into: db)
        receipt.personalizationDocuments += 1
    }

    // MARK: - Personalization update cursors (insert-if-absent toggle)

    static func insertPersonalizationCursor(
        values: C07DBRow,
        db: Database,
        receipt: inout C07OwnedDataCommitReceipt,
        warnings: inout [String]
    ) throws {
        guard let kind = values["kind"]?.stringValue, !kind.isEmpty else {
            throw C07DataExchangeError.invalidManifest("cursorKind")
        }
        // The workspace_key is structural identity: it follows the remapped
        // workspace id (or '' for the global slot), never the old id.
        let workspaceKey = values["workspace_id"]?.stringValue ?? ""
        let existing = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM personalization_update_cursors
                WHERE kind = ? AND workspace_key = ?
                """,
            arguments: [kind, workspaceKey]) ?? 0
        guard existing == 0 else {
            warnings.append("personalizationCursorKept:\(kind):\(workspaceKey)")
            return
        }
        var stored = values
        stored["workspace_key"] = .string(String(workspaceKey.prefix(256)))
        stored["last_generated_at"] = .null
        stored["completed_runs_since_update"] = .int(0)
        stored["user_messages_since_update"] = .int(0)
        stored["updated_at"] = .string(c07DateString(Date()))
        try insert("personalization_update_cursors", stored, into: db)
        receipt.personalizationCursors += 1
    }

    // MARK: - Skills (disabled reference-only restore)

    static func insertSkill(
        values: C07DBRow,
        restoreID: UUID,
        db: Database,
        receipt: inout C07OwnedDataCommitReceipt,
        warnings: inout [String]
    ) throws {
        guard let name = values["name"]?.stringValue, !name.isEmpty else {
            throw C07DataExchangeError.invalidManifest("skillName")
        }
        let existing = try Row.fetchOne(
            db,
            sql: "SELECT * FROM skills WHERE name = ? COLLATE NOCASE LIMIT 1",
            arguments: [name])
        var storedName = name
        if let existing {
            let sameContent =
                dbValue(existing["skill_markdown"])
                    == (values["skill_markdown"] ?? .null)
                    && dbValue(existing["version"])
                        == (values["version"] ?? .null)
                    && dbValue(existing["source_digest"])
                        == (values["source_digest"] ?? .null)
            if sameContent {
                // Byte-identical definition already installed: an honest
                // de-duplication, counted separately from restored skills.
                return
            }
            // Same name, different content: never overwrite. Restore under an
            // explicit display name so BOTH definitions survive.
            var candidate = "\(name) (restored)"
            var attempt = 2
            while try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM skills WHERE name = ? COLLATE NOCASE)",
                arguments: [candidate]) == true {
                guard attempt <= 20 else {
                    throw C07DataExchangeError.duplicateIdentity(
                        "skillName:\(name)")
                }
                candidate = "\(name) (restored \(attempt))"
                attempt += 1
            }
            storedName = String(candidate.prefix(240))
            warnings.append("skillNameRestored:\(name)")
        }
        var stored = values
        stored["name"] = .string(storedName)
        stored["updated_at"] = .string(c07DateString(Date()))
        _ = restoreID
        try insert("skills", stored, into: db)
        receipt.skills += 1
    }
}
