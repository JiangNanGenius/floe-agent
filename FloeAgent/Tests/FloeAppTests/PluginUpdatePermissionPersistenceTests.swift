import Foundation
import Testing
import FloePersistence
import FloeSkills

@Suite("Plugin update permission persistence")
struct PluginUpdatePermissionPersistenceTests {
    @Test("Routine upgrade preserves prior deny, scope and expiry; reviewed expansion grants only new access")
    func permissionsSurviveUpgradeMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-permission-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DatabaseManager(path: root.appendingPathComponent("db.sqlite"))
        try await database.migrate()
        let store = SQLiteSkillStore(database: database)
        var row = PersistedSkill(id: "permission-fixture", name: "Permission fixture", version: "1.0.0",
            skillMarkdown: "body", manifestJSON: "{}", rewrittenDigest: "old")
        let original = try JSONDecoder().decode([PersistedSkillPermission].self, from: Data(#"""
        [{"capability":"localPython","decision":"deny","scopeJSON":"{\"path\":\"project\"}","grantedAt":"2026-01-01T00:00:00Z","expiresAt":"2026-01-02T00:00:00Z"},
         {"capability":"workspaceRead","decision":"allow","scopeJSON":"{\"path\":\"read-only-folder\"}","grantedAt":"2026-02-01T00:00:00Z","expiresAt":"2026-02-02T00:00:00Z"}]
        """#.utf8))
        try await store.save(row, restoringPermissions: original)
        let before = try await store.permissions(skillID: row.id)
        row.version = "2.0.0"; row.rewrittenDigest = "new"
        // Exact API used by InitialSkillMetadata.persist for a same-permission upgrade.
        let retained = SkillBulkUpdatePlan.installationGrants(
            declared: ["localPython", "workspaceRead"], upgradeAdded: [])
        try await store.save(row, grantCapabilities: retained)
        #expect(try await store.permissions(skillID: row.id) == before)
        row.version = "3.0.0"; row.rewrittenDigest = "reviewed-expansion"
        // Exact API after the user explicitly reviews added network access.
        let reviewed = SkillBulkUpdatePlan.installationGrants(
            declared: ["localPython", "workspaceRead", "network"], upgradeAdded: ["network"])
        try await store.save(row, grantCapabilities: reviewed)
        let after = try await store.permissions(skillID: row.id)
        #expect(after.filter { $0.capability != "network" } == before)
        #expect(after.first { $0.capability == "network" }?.decision == "allow")
    }
}
