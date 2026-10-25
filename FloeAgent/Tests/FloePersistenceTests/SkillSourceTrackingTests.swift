// FloePersistenceTests — Skill source-tracking persistence contracts.
//
// Source tracking reuses the existing `app_settings` key space and commits in
// the SAME writer transaction as the skill row, permissions and deletion. These
// tests run against the real in-memory migrated schema; every fixture is
// synthetic and no network, credential or production bytes are involved.

import Foundation
import GRDB
import Testing
@testable import FloePersistence

@Suite("Skill source tracking persistence")
struct SkillSourceTrackingTests {
    private static let trackedID = "source-tracked"

    @Test("Tracking survives status and instruction changes")
    func trackingSurvivesStatusAndInstructionChanges() async throws {
        let fixture = try await SkillPersistenceFixture.make()
        try await fixture.store.save(Self.skill(markdown: "original", digest: "d1"))
        try await fixture.store.save(
            Self.skill(id: "untracked-skill", name: "Untracked skill", digest: "u1"))

        let json = Self.trackingJSON(ref: "main")
        try await fixture.store.setSourceTracking(
            json, id: Self.trackedID, expectedDigest: "d1")
        // The value lives under the existing settings key, not a new column.
        #expect(try await fixture.tracking(id: Self.trackedID) == json)
        let columns = try await fixture.columns(of: "skills")
        #expect(!columns.contains("source_tracking_json"))

        // Ordinary mutations must neither drop nor rewrite the binding.
        try await fixture.store.setEnabled(false, id: Self.trackedID, expectedDigest: "d1")
        try await fixture.store.updateInstructions(
            id: Self.trackedID, markdown: "edited", digest: "d2", expectedDigest: "d1")

        let rows = try await fixture.store.all()
        #expect(rows.count == 2)
        let tracked = try #require(rows.first { $0.id == Self.trackedID })
        #expect(tracked.sourceTrackingJSON == json)
        #expect(tracked.status == "disabled")
        #expect(tracked.skillMarkdown == "edited")
        #expect(tracked.rewrittenDigest == "d2")
        // Another skill must not inherit the joined setting.
        let untracked = try #require(rows.first { $0.id == "untracked-skill" })
        #expect(untracked.sourceTrackingJSON == nil)
    }

    @Test("A stale digest cannot replace newer tracking")
    func staleCompareAndSwapIsRejected() async throws {
        let fixture = try await SkillPersistenceFixture.make()
        try await fixture.store.save(Self.skill(markdown: "original", digest: "d1"))

        let first = Self.trackingJSON(ref: "main")
        let second = Self.trackingJSON(ref: "next")
        try await fixture.store.setSourceTracking(
            first, id: Self.trackedID, expectedDigest: "d1")
        try await fixture.store.updateInstructions(
            id: Self.trackedID, markdown: "edited", digest: "d2", expectedDigest: "d1")

        // The instruction update advanced the digest: the old CAS must fail.
        await #expect(throws: SkillStoreConflict.self) {
            try await fixture.store.setSourceTracking(
                second, id: Self.trackedID, expectedDigest: "d1")
        }
        #expect(try await fixture.tracking(id: Self.trackedID) == first)

        // A stale removal must not delete the row or its tracking key either.
        await #expect(throws: SkillStoreConflict.self) {
            try await fixture.store.remove(id: Self.trackedID, expectedDigest: "d1")
        }
        let survivingRows = try await fixture.store.all()
        #expect(survivingRows.count == 1)
        #expect(try await fixture.tracking(id: Self.trackedID) == first)

        // The current digest advances and then clears the binding.
        try await fixture.store.setSourceTracking(
            second, id: Self.trackedID, expectedDigest: "d2")
        #expect(try await fixture.tracking(id: Self.trackedID) == second)
        try await fixture.store.setSourceTracking(nil, id: Self.trackedID, expectedDigest: "d2")
        #expect(try await fixture.tracking(id: Self.trackedID) == nil)

        // Non-object tracking JSON is refused under the same CAS and changes nothing.
        try await fixture.store.setSourceTracking(
            first, id: Self.trackedID, expectedDigest: "d2")
        await #expect(throws: SkillStoreConflict.self) {
            try await fixture.store.setSourceTracking(
                "[]", id: Self.trackedID, expectedDigest: "d2")
        }
        #expect(try await fixture.tracking(id: Self.trackedID) == first)
    }

    @Test("Removing a skill clears only its own tracking key")
    func removalClearsOnlyItsOwnKey() async throws {
        let fixture = try await SkillPersistenceFixture.make()
        try await fixture.store.save(Self.skill(markdown: "original", digest: "d1"))
        try await fixture.store.save(
            Self.skill(id: "other-skill", name: "Other skill", digest: "e1"))
        try await fixture.insertSetting("unrelated.preference", "{\"enabled\":true}")

        let trackedJSON = Self.trackingJSON(ref: "main")
        let otherJSON = Self.trackingJSON(ref: "release")
        try await fixture.store.setSourceTracking(
            trackedJSON, id: Self.trackedID, expectedDigest: "d1")
        try await fixture.store.setSourceTracking(
            otherJSON, id: "other-skill", expectedDigest: "e1")

        try await fixture.store.remove(id: Self.trackedID, expectedDigest: "d1")

        #expect(try await fixture.tracking(id: Self.trackedID) == nil)
        #expect(try await fixture.tracking(id: "other-skill") == otherJSON)
        #expect(try await fixture.setting("unrelated.preference") == "{\"enabled\":true}")
        let rows = try await fixture.store.all()
        #expect(rows.map { $0.id } == ["other-skill"])
    }

    @Test("A failed tracking write rolls back the skill and permission change")
    func inducedMetadataFailureRollsBackSkillAndPermissions() async throws {
        let fixture = try await SkillPersistenceFixture.make()
        try await fixture.store.save(
            Self.skill(markdown: "original", digest: "d1"),
            grantCapabilities: ["workspace.read"])

        try await fixture.installFailingTrackingTrigger()

        let changed = Self.skill(
            version: "2.0.0", markdown: "changed", digest: "d2",
            tracking: Self.trackingJSON(ref: "main"))
        await #expect(throws: (any Error).self) {
            try await fixture.store.save(changed, grantCapabilities: ["workspace.write"])
        }

        // Skill metadata, the new permission and the new setting are one transaction.
        let row = try #require(try await fixture.store.all().first)
        #expect(row.version == "1.0.0")
        #expect(row.skillMarkdown == "original")
        #expect(row.rewrittenDigest == "d1")
        #expect(row.sourceTrackingJSON == nil)
        #expect(try await fixture.store.allowedCapabilities(skillID: Self.trackedID) == ["workspace.read"])
        #expect(try await fixture.tracking(id: Self.trackedID) == nil)

        // Dropping the synthetic fault lets the exact same write commit atomically.
        try await fixture.dropFailingTrackingTrigger()
        try await fixture.store.save(changed, grantCapabilities: ["workspace.write"])

        let updated = try #require(try await fixture.store.all().first)
        #expect(updated.version == "2.0.0")
        #expect(updated.rewrittenDigest == "d2")
        #expect(updated.sourceTrackingJSON == Self.trackingJSON(ref: "main"))
        #expect(try await fixture.store.allowedCapabilities(skillID: Self.trackedID)
            == ["workspace.read", "workspace.write"])
        #expect(try await fixture.tracking(id: Self.trackedID) == Self.trackingJSON(ref: "main"))
    }

    @Test("Explicit removal wins recovery until a new successful installation")
    func removalTombstone() async throws {
        let fixture = try await SkillPersistenceFixture.make()
        let original = Self.skill(tracking: Self.trackingJSON(ref: "main"))
        try await fixture.store.save(original)
        #expect(!(try await fixture.store.wasExplicitlyRemoved(id: original.id)))
        try await fixture.store.remove(id: original.id, expectedDigest: original.rewrittenDigest)
        #expect(try await fixture.store.wasExplicitlyRemoved(id: original.id))
        #expect(try await fixture.store.all().isEmpty)
        // A failed reinstall cannot clear the removal choice.
        try await fixture.installFailingTrackingTrigger()
        await #expect(throws: (any Error).self) { try await fixture.store.save(original) }
        #expect(try await fixture.store.wasExplicitlyRemoved(id: original.id))
        try await fixture.dropFailingTrackingTrigger()
        try await fixture.store.save(original)
        #expect(!(try await fixture.store.wasExplicitlyRemoved(id: original.id)))
        #expect(try await fixture.store.all().count == 1)
    }

    // MARK: - Fixtures

    private static func skill(id: String = trackedID, name: String? = nil,
                              version: String = "1.0.0", markdown: String = "original",
                              digest: String = "d1", tracking: String? = nil) -> PersistedSkill {
        PersistedSkill(
            id: id,
            name: name ?? id,
            version: version,
            skillMarkdown: markdown,
            manifestJSON: "{}",
            rewrittenDigest: digest,
            sourceTrackingJSON: tracking)
    }

    private static func trackingJSON(ref: String) -> String {
        let commit = String(repeating: "a", count: 40)
        let digest = String(repeating: "b", count: 64)
        return """
        {"source":{"owner":"owner","repository":"repo","ref":"\(ref)","path":"skills/notes"},\
        "installedCommit":"\(commit)","installedContentDigest":"\(digest)"}
        """
    }
}

private struct SkillPersistenceFixture: Sendable {
    let database: DatabaseManager
    let store: SQLiteSkillStore

    static func make() async throws -> SkillPersistenceFixture {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return SkillPersistenceFixture(database: database, store: SQLiteSkillStore(database: database))
    }

    private init(database: DatabaseManager, store: SQLiteSkillStore) {
        self.database = database
        self.store = store
    }

    func tracking(id: String) async throws -> String? {
        try await setting("skills.update_source." + id)
    }

    func setting(_ key: String) async throws -> String? {
        try await database.reader { db in
            try String.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = ?",
                                arguments: [key])
        }
    }

    func insertSetting(_ key: String, _ json: String) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "INSERT INTO app_settings (key, value_json, updated_at) VALUES (?, ?, ?)",
                arguments: [key, json, "2026-01-01T00:00:00Z"])
        }
    }

    func columns(of table: String) async throws -> [String] {
        try await database.reader { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('\(table)')")
        }
    }

    func installFailingTrackingTrigger() async throws {
        try await database.writer { db in
            try db.execute(sql: """
                CREATE TRIGGER synthetic_tracking_insert_failure
                BEFORE INSERT ON app_settings
                WHEN NEW.key = 'skills.update_source.source-tracked'
                BEGIN SELECT RAISE(ABORT, 'synthetic source-tracking failure'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER synthetic_tracking_update_failure
                BEFORE UPDATE ON app_settings
                WHEN NEW.key = 'skills.update_source.source-tracked'
                BEGIN SELECT RAISE(ABORT, 'synthetic source-tracking failure'); END
                """)
        }
    }

    func dropFailingTrackingTrigger() async throws {
        try await database.writer { db in
            try db.execute(sql: "DROP TRIGGER synthetic_tracking_insert_failure")
            try db.execute(sql: "DROP TRIGGER synthetic_tracking_update_failure")
        }
    }
}
