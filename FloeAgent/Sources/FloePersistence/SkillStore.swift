import Foundation
import GRDB

public struct PersistedSkill: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var status: String
    public var skillMarkdown: String
    public var manifestJSON: String
    public var declaredCapabilitiesJSON: String
    public var effectiveCapabilitiesJSON: String
    public var sourceURL: String?
    public var sourceDigest: String?
    public var rewrittenDigest: String
    public var rewriteModelID: String?
    public var compatibilityReportJSON: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, name: String, version: String, status: String = "enabled",
        skillMarkdown: String, manifestJSON: String,
        declaredCapabilitiesJSON: String = "[]", effectiveCapabilitiesJSON: String = "[]",
        sourceURL: String? = nil, sourceDigest: String? = nil, rewrittenDigest: String,
        rewriteModelID: String? = nil, compatibilityReportJSON: String = "{}",
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id; self.name = name; self.version = version; self.status = status
        self.skillMarkdown = skillMarkdown; self.manifestJSON = manifestJSON
        self.declaredCapabilitiesJSON = declaredCapabilitiesJSON
        self.effectiveCapabilitiesJSON = effectiveCapabilitiesJSON
        self.sourceURL = sourceURL; self.sourceDigest = sourceDigest
        self.rewrittenDigest = rewrittenDigest; self.rewriteModelID = rewriteModelID
        self.compatibilityReportJSON = compatibilityReportJSON
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public actor SQLiteSkillStore {
    private let database: DatabaseManager
    public init(database: DatabaseManager) { self.database = database }

    public func save(_ skill: PersistedSkill) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO skills (
                    id, name, version, status, skill_markdown, manifest_json,
                    declared_capabilities_json, effective_capabilities_json,
                    source_url, source_digest, rewritten_digest, rewrite_model_id,
                    compatibility_report_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name=excluded.name, version=excluded.version, status=excluded.status,
                    skill_markdown=excluded.skill_markdown, manifest_json=excluded.manifest_json,
                    declared_capabilities_json=excluded.declared_capabilities_json,
                    effective_capabilities_json=excluded.effective_capabilities_json,
                    source_url=excluded.source_url, source_digest=excluded.source_digest,
                    rewritten_digest=excluded.rewritten_digest, rewrite_model_id=excluded.rewrite_model_id,
                    compatibility_report_json=excluded.compatibility_report_json,
                    updated_at=excluded.updated_at
                """, arguments: [
                    skill.id, skill.name, skill.version, skill.status, skill.skillMarkdown,
                    skill.manifestJSON, skill.declaredCapabilitiesJSON,
                    skill.effectiveCapabilitiesJSON, skill.sourceURL, skill.sourceDigest,
                    skill.rewrittenDigest, skill.rewriteModelID, skill.compatibilityReportJSON,
                    Self.date(skill.createdAt), Self.date(skill.updatedAt)
                ])
        }
    }

    public func all() async throws -> [PersistedSkill] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: "SELECT * FROM skills ORDER BY name COLLATE NOCASE").map(Self.row)
        }
    }

    public func setEnabled(_ enabled: Bool, id: String) async throws {
        try await database.writer { db in
            try db.execute(sql: "UPDATE skills SET status = ?, updated_at = ? WHERE id = ?",
                           arguments: [enabled ? "enabled" : "disabled", Self.date(Date()), id])
        }
    }

    public func remove(id: String) async throws {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM skills WHERE id = ?", arguments: [id])
        }
    }

    public func setPermission(
        skillID: String, capability: String, decision: String,
        scopeJSON: String = "{}", expiresAt: Date? = nil
    ) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO skill_permissions (
                    skill_id, capability, decision, scope_json, granted_at, expires_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(skill_id, capability) DO UPDATE SET decision=excluded.decision,
                    scope_json=excluded.scope_json, granted_at=excluded.granted_at,
                    expires_at=excluded.expires_at
                """, arguments: [skillID, capability, decision, scopeJSON,
                    decision == "allow" ? Self.date(Date()) : nil, expiresAt.map(Self.date)])
        }
    }

    public func allowedCapabilities(skillID: String, now: Date = Date()) async throws -> Set<String> {
        try await database.reader { db in
            Set(try String.fetchAll(db, sql: """
                SELECT capability FROM skill_permissions
                WHERE skill_id = ? AND decision = 'allow'
                  AND (expires_at IS NULL OR expires_at > ?)
                """, arguments: [skillID, Self.date(now)]))
        }
    }

    private static func row(_ row: Row) throws -> PersistedSkill {
        PersistedSkill(
            id: row["id"], name: row["name"], version: row["version"], status: row["status"],
            skillMarkdown: row["skill_markdown"], manifestJSON: row["manifest_json"],
            declaredCapabilitiesJSON: row["declared_capabilities_json"],
            effectiveCapabilitiesJSON: row["effective_capabilities_json"], sourceURL: row["source_url"],
            sourceDigest: row["source_digest"], rewrittenDigest: row["rewritten_digest"],
            rewriteModelID: row["rewrite_model_id"], compatibilityReportJSON: row["compatibility_report_json"],
            createdAt: parseDate(row["created_at"]), updatedAt: parseDate(row["updated_at"])
        )
    }

    private static func date(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
    private static func parseDate(_ value: String) -> Date { ISO8601DateFormatter().date(from: value) ?? .distantPast }
}
