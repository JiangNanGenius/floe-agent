import XCTest
import Foundation
import GRDB
import FloePersistence
import FloeSkills

/// Real SQLite store/migration tests. Synthetic metadata only; independent
/// store reopening is not an Android process-death or device durability claim.
final class AndroidSkillSourcePersistenceTests: XCTestCase, @unchecked Sendable {
    private let digest = String(repeating: "a", count: 64)

    private func row() -> PersistedSkill {
        PersistedSkill(id: "source-fixture", name: "Source fixture", version: "1.0.0",
                       skillMarkdown: "fixture", manifestJSON: "{}", rewrittenDigest: digest)
    }

    private func intent() throws -> String {
        let source = try GitHubSkillSource(owner: "octo-org", repository: "community-skill",
                                           ref: "feature/next", path: "pkg/inventory.json")
        let binding = try SkillGitHubBinding(source: source, installedCommit: nil,
                                             installedContentDigest: nil)
        return String(decoding: try JSONEncoder().encode(binding), as: UTF8.self)
    }

    private func migrated() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    func testLegacyRowsAndBackupRecordsHaveNoInventedSource() async throws {
        let database = try await migrated()
        let store = SQLiteSkillStore(database: database)
        try await store.save(row())
        let saved = try await store.skill(id: row().id)
        XCTAssertNil(saved?.sourceTrackingJSON)
        let version = try await database.userVersion()
        XCTAssertEqual(version, DatabaseManager.currentSchemaVersion)
        // Old journals/backups omit the newly optional model property.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row())) as? [String: Any])
        json.removeValue(forKey: "sourceTrackingJSON")
        let decoded = try JSONDecoder().decode(PersistedSkill.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.sourceTrackingJSON)
    }

    func testSourceReopensFromTheExistingDatabaseAndClearsWithoutChangingGrants() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floe-source-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite")
        let first = try DatabaseManager(path: path)
        try await first.migrate()
        let store = SQLiteSkillStore(database: first)
        try await store.save(row(), grantCapabilities: ["workspace.read"])
        let json = try intent()
        try await store.setSourceTracking(json, id: row().id, expectedDigest: digest)
        let second = try DatabaseManager(path: path)
        try await second.migrate()
        let reopened = SQLiteSkillStore(database: second)
        let saved = try await reopened.skill(id: row().id)
        XCTAssertEqual(saved?.sourceTrackingJSON, json)
        let binding = try JSONDecoder().decode(SkillGitHubBinding.self, from: Data(json.utf8))
        XCTAssertNil(binding.installedCommit)
        XCTAssertNil(binding.installedContentDigest)
        try await reopened.setSourceTracking(nil, id: row().id, expectedDigest: digest)
        let cleared = try await store.all()
        let permissions = try await reopened.permissions(skillID: row().id)
        XCTAssertNil(cleared.first?.sourceTrackingJSON)
        XCTAssertEqual(permissions.map(\.capability), ["workspace.read"])
        XCTAssertEqual(permissions.first?.decision, "allow")
    }

    func testStaleDigestAndRetiredOwnerCannotReplaceSource() async throws {
        let store = SQLiteSkillStore(database: try await migrated())
        try await store.save(row())
        let original = try intent()
        try await store.setSourceTracking(original, id: row().id, expectedDigest: digest)
        do {
            try await store.setSourceTracking(nil, id: row().id,
                                               expectedDigest: String(repeating: "b", count: 64))
            XCTFail("stale content CAS must refuse the source mutation")
        } catch is SkillStoreConflict {}
        do {
            try await store.setSourceTracking(nil, id: row().id, expectedDigest: digest,
                                               isCurrent: { false })
            XCTFail("retired work must be rejected inside the actual write transaction")
        } catch is SkillStoreConflict {}
        let unchanged = try await store.skill(id: row().id)
        XCTAssertEqual(unchanged?.sourceTrackingJSON, original)
    }

    func testInvalidTrackingRollsBackMetadataAndPermissionChangesTogether() async throws {
        let store = SQLiteSkillStore(database: try await migrated())
        var original = row()
        original.sourceTrackingJSON = try intent()
        try await store.save(original, grantCapabilities: ["workspace.read"])
        var replacement = original
        replacement.version = "2.0.0"
        replacement.rewrittenDigest = String(repeating: "b", count: 64)
        replacement.sourceTrackingJSON = "[invalid"
        do {
            try await store.save(replacement, grantCapabilities: ["device.write"], replaceGrants: true)
            XCTFail("invalid tracking must abort the entire real SQLite transaction")
        } catch is SkillStoreConflict {}
        let kept = try await store.skill(id: original.id)
        let permissions = try await store.permissions(skillID: original.id)
        XCTAssertEqual(kept?.version, original.version)
        XCTAssertEqual(kept?.rewrittenDigest, original.rewrittenDigest)
        XCTAssertEqual(kept?.sourceTrackingJSON, original.sourceTrackingJSON)
        XCTAssertEqual(permissions.map(\.capability), ["workspace.read"])
    }

    func testOversizedTrackingFailsWithoutChangingTheSavedIntent() async throws {
        let store = SQLiteSkillStore(database: try await migrated())
        var original = row()
        original.sourceTrackingJSON = try intent()
        try await store.save(original)
        let oversized = "{\"padding\":\"" + String(repeating: "x", count: 16_384) + "\"}"
        do {
            try await store.setSourceTracking(oversized, id: original.id, expectedDigest: digest)
            XCTFail("unbounded metadata must not persist")
        } catch is SkillStoreConflict {}
        let kept = try await store.skill(id: original.id)
        XCTAssertEqual(kept?.sourceTrackingJSON, original.sourceTrackingJSON)
    }

    func testRemovalRetiresSourceInTheSameTransaction() async throws {
        let database = try await migrated()
        let store = SQLiteSkillStore(database: database)
        var original = row()
        original.sourceTrackingJSON = try intent()
        try await store.save(original)
        try await store.remove(id: original.id, expectedDigest: digest)
        let removed = try await store.skill(id: original.id)
        let leftover = try await database.reader { db in
            try String.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = ?",
                                arguments: ["skills.update_source.source-fixture"])
        }
        XCTAssertNil(removed)
        XCTAssertNil(leftover)
    }

    func testVerifiedBindingRoundTripsAndRejectsForgedCommitShape() throws {
        let source = try GitHubSkillSource(owner: "octo-org", repository: "community-skill",
                                           ref: "main", path: "SKILL.md")
        let verified = try SkillGitHubBinding(source: source, installedCommit: String(repeating: "b", count: 40),
                                               installedContentDigest: digest)
        var installed = row()
        installed.sourceTrackingJSON = String(decoding: try JSONEncoder().encode(verified), as: UTF8.self)
        let decoded = try JSONDecoder().decode(PersistedSkill.self, from: JSONEncoder().encode(installed))
        XCTAssertEqual(decoded.sourceTrackingJSON, installed.sourceTrackingJSON)
        XCTAssertThrowsError(try SkillGitHubBinding(source: source, installedCommit: "main",
                                                    installedContentDigest: digest))
    }
}
