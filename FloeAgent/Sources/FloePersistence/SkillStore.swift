import Foundation
import GRDB

public struct PersistedSkill: Codable, Sendable, Hashable, Identifiable {
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
    public var sourceTrackingJSON: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, name: String, version: String, status: String = "enabled",
        skillMarkdown: String, manifestJSON: String,
        declaredCapabilitiesJSON: String = "[]", effectiveCapabilitiesJSON: String = "[]",
        sourceURL: String? = nil, sourceDigest: String? = nil, rewrittenDigest: String,
        rewriteModelID: String? = nil, compatibilityReportJSON: String = "{}", sourceTrackingJSON: String? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id; self.name = name; self.version = version; self.status = status
        self.skillMarkdown = skillMarkdown; self.manifestJSON = manifestJSON
        self.declaredCapabilitiesJSON = declaredCapabilitiesJSON
        self.effectiveCapabilitiesJSON = effectiveCapabilitiesJSON
        self.sourceURL = sourceURL; self.sourceDigest = sourceDigest
        self.rewrittenDigest = rewrittenDigest; self.rewriteModelID = rewriteModelID
        self.compatibilityReportJSON = compatibilityReportJSON
        self.sourceTrackingJSON = sourceTrackingJSON
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// One retained official Skill publication identity. Released bytes are
/// immutable: an official curated package `id`+`version` observed by this
/// device must never be replaced by different signed bytes under the same
/// id+version. The identity commits in the SAME write transaction as the
/// skill metadata (existing CAS/rollback boundary), so a ledger or database
/// failure can never let a same-version replacement through, and there is no
/// best-effort post-commit write to lose.
///
/// Honest scope: this table records OBSERVED identities only — it is not a
/// universal immutability proof, and publisher CI remains the authority for
/// history this client never observed. The table is unbounded (no silent
/// eviction): its rows are created exclusively by successful curated
/// installs/updates and explicit receipt-derived seeding.
public struct OfficialSkillPublicationRecord: Codable, Sendable, Equatable {
    public let skillID: String
    public let version: String
    public let contentDigest: String
    public let publicationCommit: String?
    public let updatedAt: Date

    public init(skillID: String, version: String, contentDigest: String,
                publicationCommit: String?, updatedAt: Date = Date()) {
        self.skillID = skillID
        self.version = version
        self.contentDigest = contentDigest
        self.publicationCommit = publicationCommit
        self.updatedAt = updatedAt
    }

    public var isCanonical: Bool {
        !skillID.isEmpty && skillID.utf8.count <= 128
            && OfficialSkillPublicationLedgerRules.isValidVersion(version)
            && OfficialSkillPublicationLedgerRules.isValidDigest(contentDigest)
            && (publicationCommit.map(OfficialSkillPublicationLedgerRules.isValidCommit) ?? true)
    }
}

/// Same id+version previously observed from different signed bytes. Carries
/// both digests so the boundary can state the conflict without guessing.
public struct OfficialSkillPublicationConflict: Error, Equatable, Sendable, LocalizedError {
    public let skillID: String
    public let version: String
    public let seenDigest: String
    public let candidateDigest: String
    public init(skillID: String, version: String, seenDigest: String, candidateDigest: String) {
        self.skillID = skillID; self.version = version
        self.seenDigest = seenDigest; self.candidateDigest = candidateDigest
    }
    public var errorDescription: String? {
        "Official Skill publication identity conflict: '\(skillID)' version '\(version)' was previously installed from digest "
        + "\(seenDigest.prefix(12))…, and these bytes hash to \(candidateDigest.prefix(12))…. A released package version is immutable; "
        + "an update must raise the package version. Nothing was written."
    }
}

/// A caller-constructed identity that is not canonical (never a stored-shape
/// problem): rejected before any write.
public struct OfficialSkillPublicationCandidateInvalid: Error, Equatable, Sendable, LocalizedError {
    public let skillID: String
    public init(skillID: String) { self.skillID = skillID }
    public var errorDescription: String? {
        "The proposed official publication identity for '\(skillID)' is not canonical and was rejected before any write."
    }
}

/// The retained ledger itself refuses to read or commit through a damaged
/// row: malformed stored shapes are surfaced, never dropped to "unknown".
public struct OfficialSkillPublicationLedgerDamage: Error, Equatable, Sendable, LocalizedError {
    public let skillID: String
    public let version: String
    public init(skillID: String, version: String) { self.skillID = skillID; self.version = version }
    public var errorDescription: String? {
        "The official Skill publication identity ledger holds a malformed entry for '\(skillID)' version '\(version)'. "
        + "Curated installs and updates are refused until the damaged entry is honestly resolved; ordinary skills are unaffected."
    }
}

public enum OfficialSkillPublicationLedgerRules {
    public static func isValidDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }
    public static func isValidCommit(_ value: String) -> Bool {
        value.count == 40 && value.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }
    public static func isValidVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && (part == "0" || !part.hasPrefix("0")) && Int(part) != nil
                && part.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
        }
    }
}

public struct PersistedSkillPermission: Codable, Sendable, Equatable {
    public let capability: String
    public let decision: String
    public let scopeJSON: String
    public let grantedAt: String?
    public let expiresAt: String?
}

public actor SQLiteSkillStore {
    private let database: DatabaseManager
    public init(database: DatabaseManager) { self.database = database }

    /// - Parameter officialPublication: when the caller is committing an
    ///   official curated install/update, the typed identity is checked and
    ///   written inside THIS transaction. A same id+version row with a
    ///   different digest throws `OfficialSkillPublicationConflict` and rolls
    ///   the entire skill-metadata write back (existing GRDB transaction +
    ///   the staging service's file rollback); a malformed stored row throws
    ///   `OfficialSkillPublicationLedgerDamage` instead of being ignored.
    ///   `nil` never touches the ledger: external/user installs and local
    ///   instruction edits keep their exact historical behavior.
    public func save(_ skill: PersistedSkill, grantCapabilities: [String] = [], replaceGrants: Bool = false,
                     restoringPermissions: [PersistedSkillPermission]? = nil,
                     officialPublication: OfficialSkillPublicationRecord? = nil) async throws {
        try await database.writer { db in
            try Self.ensureOfficialPublicationsTable(db)
            if let officialPublication {
                guard officialPublication.skillID == skill.id,
                      officialPublication.version == skill.version,
                      officialPublication.contentDigest == skill.rewrittenDigest else {
                    throw OfficialSkillPublicationCandidateInvalid(skillID: skill.id)
                }
                try Self.commitOfficialPublication(officialPublication, db: db)
            }
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
            if replaceGrants { try db.execute(sql: "DELETE FROM skill_permissions WHERE skill_id = ?", arguments: [skill.id]) }
            for capability in grantCapabilities {
                try db.execute(sql: """
                    INSERT INTO skill_permissions (skill_id, capability, decision, scope_json, granted_at, expires_at)
                    VALUES (?, ?, 'allow', '{}', ?, NULL)
                    ON CONFLICT(skill_id, capability) DO UPDATE SET decision='allow', granted_at=excluded.granted_at, expires_at=NULL
                    """, arguments: [skill.id, capability, Self.date(Date())])
            }
            if let restoringPermissions {
                try db.execute(sql: "DELETE FROM skill_permissions WHERE skill_id = ?", arguments: [skill.id])
                for permission in restoringPermissions {
                    try db.execute(sql: """
                        INSERT INTO skill_permissions (skill_id, capability, decision, scope_json, granted_at, expires_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [skill.id, permission.capability, permission.decision,
                            permission.scopeJSON, permission.grantedAt, permission.expiresAt])
                }
            }
            try Self.persistSourceTracking(skill.sourceTrackingJSON, id: skill.id, db: db)
            try db.execute(sql: "DELETE FROM app_settings WHERE key = ?", arguments: [Self.removedPrefix + skill.id])
        }
    }

    public func permissions(skillID: String) async throws -> [PersistedSkillPermission] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: "SELECT * FROM skill_permissions WHERE skill_id = ? ORDER BY capability", arguments: [skillID]).map {
                PersistedSkillPermission(capability: $0["capability"], decision: $0["decision"],
                    scopeJSON: $0["scope_json"], grantedAt: $0["granted_at"], expiresAt: $0["expires_at"])
            }
        }
    }

    public func all() async throws -> [PersistedSkill] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT skills.*, app_settings.value_json AS source_tracking_json
                FROM skills LEFT JOIN app_settings ON app_settings.key = ? || skills.id
                ORDER BY skills.name COLLATE NOCASE
                """, arguments: [Self.sourceTrackingPrefix]).map(Self.row)
        }
    }

    /// Non-secret source intent shares the existing settings storage, while
    /// its CAS and installation/deletion commit share the skill transaction.
    /// No independent file can claim a source after an installation rolled back.
    public func setSourceTracking(_ json: String?, id: String, expectedDigest: String) async throws {
        try await database.writer { db in
            try Self.checkDigest(db, id: id, expected: expectedDigest)
            try Self.persistSourceTracking(json, id: id, db: db)
        }
    }

    public func wasExplicitlyRemoved(id: String) async throws -> Bool {
        try await database.reader { db in
            try String.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = ?",
                arguments: [Self.removedPrefix + id]) == "true"
        }
    }

    public func setEnabled(_ enabled: Bool, id: String, expectedDigest: String? = nil) async throws {
        try await database.writer { db in
            try Self.checkDigest(db, id: id, expected: expectedDigest)
            try db.execute(sql: "UPDATE skills SET status = ?, updated_at = ? WHERE id = ?",
                           arguments: [enabled ? "enabled" : "disabled", Self.date(Date()), id])
        }
    }

    public func remove(id: String, expectedDigest: String? = nil, suppressBundledSeed: Bool = false) async throws {
        try await database.writer { db in
            try Self.checkDigest(db, id: id, expected: expectedDigest)
            try db.execute(sql: """
                INSERT OR REPLACE INTO app_settings (key, value_json, updated_at) VALUES (?, 'true', ?)
                """, arguments: [Self.removedPrefix + id, Self.date(Date())])
            if suppressBundledSeed {
                try db.execute(sql: "INSERT OR REPLACE INTO app_settings (key, value_json, updated_at) VALUES (?, 'true', ?)",
                    arguments: [Self.bundledSeedSuppressionPrefix + id, Self.date(Date())])
            }
            try db.execute(sql: "DELETE FROM skills WHERE id = ?", arguments: [id])
            try Self.persistSourceTracking(nil, id: id, db: db)
        }
    }

    public func wasBundledSkillRemoved(id: String) async throws -> Bool {
        try await database.reader { db in
            try String.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = ?",
                arguments: [Self.bundledSeedSuppressionPrefix + id]) == "true"
        }
    }

    public func requestBundledSkillInstallation(id: String) async throws {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM app_settings WHERE key = ?", arguments: [Self.bundledSeedSuppressionPrefix + id])
        }
    }

    /// Clears both persisted removal intents (the hub-update marker and the
    /// bundled-seed suppression marker) for one preinstalled ID inside a
    /// single transaction. Callers use this only after the trusted bundled
    /// seed has verified the installation: a repair either fully lands or the
    /// markers stay in place for a later retry pass.
    public func clearBundledSkillRemovalMarkers(id: String) async throws {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM app_settings WHERE key IN (?, ?)",
                arguments: [Self.removedPrefix + id, Self.bundledSeedSuppressionPrefix + id])
        }
    }

    public func updateInstructions(id: String, markdown: String, digest: String, expectedDigest: String) async throws {
        try await database.writer { db in
            try Self.checkDigest(db, id: id, expected: expectedDigest)
            try db.execute(sql: "UPDATE skills SET skill_markdown = ?, rewritten_digest = ?, updated_at = ? WHERE id = ?",
                           arguments: [markdown, digest, Self.date(Date()), id])
        }
    }

    private static func checkDigest(_ db: Database, id: String, expected: String?) throws {
        guard let expected else { return }
        guard try String.fetchOne(db, sql: "SELECT rewritten_digest FROM skills WHERE id = ?", arguments: [id]) == expected else {
            throw SkillStoreConflict.changedOrMissing
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

    // MARK: - Official publication identity ledger

    private static func ensureOfficialPublicationsTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS official_skill_publications (
                skill_id TEXT NOT NULL,
                version TEXT NOT NULL,
                content_digest TEXT NOT NULL,
                publication_commit TEXT,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (skill_id, version)
            )
            """)
    }

    /// Transaction-body enforcement. Callers pass a candidate already derived
    /// from the typed curated receipt; the shape gate keeps forged data out
    /// even if a caller misconstructed it.
    private static func commitOfficialPublication(_ publication: OfficialSkillPublicationRecord, db: Database) throws {
        guard publication.isCanonical else {
            throw OfficialSkillPublicationCandidateInvalid(skillID: publication.skillID)
        }
        try applyOfficialPublication(publication, db: db)
    }

    private static func applyOfficialPublication(_ publication: OfficialSkillPublicationRecord, db: Database) throws {
        struct StoredRow {
            let digest: String
            let commit: String?
        }
        let stored: StoredRow? = try Row.fetchOne(db, sql: """
            SELECT content_digest, publication_commit FROM official_skill_publications
            WHERE skill_id = ? AND version = ?
            """, arguments: [publication.skillID, publication.version]).flatMap { row in
            StoredRow(digest: row["content_digest"], commit: row["publication_commit"])
        }
        if let stored {
            guard OfficialSkillPublicationLedgerRules.isValidDigest(stored.digest) else {
                throw OfficialSkillPublicationLedgerDamage(skillID: publication.skillID, version: publication.version)
            }
            if let commit = stored.commit, !OfficialSkillPublicationLedgerRules.isValidCommit(commit) {
                throw OfficialSkillPublicationLedgerDamage(skillID: publication.skillID, version: publication.version)
            }
            guard stored.digest == publication.contentDigest else {
                throw OfficialSkillPublicationConflict(
                    skillID: publication.skillID, version: publication.version,
                    seenDigest: stored.digest, candidateDigest: publication.contentDigest
                )
            }
            try db.execute(sql: """
                UPDATE official_skill_publications
                SET content_digest = ?, publication_commit = ?, updated_at = ?
                WHERE skill_id = ? AND version = ?
                """, arguments: [publication.contentDigest, publication.publicationCommit,
                                 Self.date(publication.updatedAt), publication.skillID, publication.version])
            return
        }
        try db.execute(sql: """
            INSERT INTO official_skill_publications (skill_id, version, content_digest, publication_commit, updated_at)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [publication.skillID, publication.version, publication.contentDigest,
                             publication.publicationCommit, Self.date(publication.updatedAt)])
    }

    /// The retained identity for one id+version, or nil when this device has
    /// never committed official bytes for it. A malformed stored entry throws
    /// `OfficialSkillPublicationLedgerDamage` — never a silent nil.
    public func officialPublication(id: String, version: String) async throws -> OfficialSkillPublicationRecord? {
        try await database.writer { db in
            try Self.ensureOfficialPublicationsTable(db)
            guard let row = try Row.fetchOne(db, sql: """
                SELECT content_digest, publication_commit, updated_at FROM official_skill_publications
                WHERE skill_id = ? AND version = ?
                """, arguments: [id, version]) else { return nil }
            let digest: String = row["content_digest"]
            let commit: String? = row["publication_commit"]
            guard OfficialSkillPublicationLedgerRules.isValidDigest(digest),
                  (commit.map(OfficialSkillPublicationLedgerRules.isValidCommit) ?? true) else {
                throw OfficialSkillPublicationLedgerDamage(skillID: id, version: version)
            }
            let storedStamp: String = row["updated_at"]
            let storedDate = ISO8601DateFormatter().date(from: storedStamp) ?? Date(timeIntervalSince1970: 0)
            return OfficialSkillPublicationRecord(
                skillID: id, version: version, contentDigest: digest,
                publicationCommit: commit, updatedAt: storedDate
            )
        }
    }

    public func countOfficialPublications() async throws -> Int {
        try await database.writer { db in
            try Self.ensureOfficialPublicationsTable(db)
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM official_skill_publications") ?? 0
        }
    }

    /// Idempotent migration seed for curated installs that predate the ledger:
    /// identities derived from the typed receipts of installed rows and
    /// retained upgrade journals. Missing pairs are inserted; a same pair
    /// with the SAME digest refreshes its commit; a same pair with a
    /// DIFFERENT digest throws (nothing partial is written — the whole seed
    /// transaction rolls back) so a genuinely damaged or contradicted ledger
    /// is surfaced honestly instead of being silently overwritten.
    public func seedOfficialPublications(_ publications: [OfficialSkillPublicationRecord]) async throws {
        guard !publications.isEmpty else { return }
        try await database.writer { db in
            try Self.ensureOfficialPublicationsTable(db)
            for publication in publications {
                guard publication.isCanonical else {
                    throw OfficialSkillPublicationCandidateInvalid(skillID: publication.skillID)
                }
                try Self.applyOfficialPublication(publication, db: db)
            }
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
            sourceTrackingJSON: row["source_tracking_json"],
            createdAt: parseDate(row["created_at"]), updatedAt: parseDate(row["updated_at"])
        )
    }

    private static func date(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
    private static let sourceTrackingPrefix = "skills.update_source."
    private static let removedPrefix = "skills.user_removed."
    /// Historical second spelling persisted by older releases alongside
    /// `removedPrefix` when a bundled plugin was deleted. Preinstalled IDs are
    /// no longer removable; this marker only gates legacy repair.
    private static let bundledSeedSuppressionPrefix = "skills.userRemoved."

    private static func persistSourceTracking(_ json: String?, id: String, db: Database) throws {
        let key = sourceTrackingPrefix + id
        guard let json else {
            try db.execute(sql: "DELETE FROM app_settings WHERE key = ?", arguments: [key])
            return
        }
        guard json.utf8.count <= 16_384,
              (try? JSONSerialization.jsonObject(with: Data(json.utf8))) is [String: Any] else {
            throw SkillStoreConflict.changedOrMissing
        }
        try db.execute(sql: """
            INSERT INTO app_settings (key, value_json, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=excluded.updated_at
            """, arguments: [key, json, date(Date())])
    }
    private static func parseDate(_ value: String) -> Date { ISO8601DateFormatter().date(from: value) ?? .distantPast }
}

public enum SkillStoreConflict: Error, LocalizedError, Sendable {
    case changedOrMissing
    public var errorDescription: String? { "Skill changed or was removed; read its current state before retrying." }
}
