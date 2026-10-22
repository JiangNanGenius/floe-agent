import Foundation
import Testing
@testable import FloePersistence

@Suite("Skill compare-and-swap persistence")
struct SkillMutationTests {
    @Test func updatePreservesPermissionsAndRejectsStaleMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("skill-cas-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseManager(path: directory.appendingPathComponent("db.sqlite"))
        try await database.migrate()
        let store = SQLiteSkillStore(database: database)
        try await store.save(.init(id: "example", name: "Example", version: "1.0.0", skillMarkdown: "old", manifestJSON: "{}", rewrittenDigest: "old"))
        try await store.setPermission(skillID: "example", capability: "localPython", decision: "allow")
        try await store.updateInstructions(id: "example", markdown: "new", digest: "new", expectedDigest: "old")
        await #expect(throws: SkillStoreConflict.self) { try await store.updateInstructions(id: "example", markdown: "lost", digest: "lost", expectedDigest: "old") }
        await #expect(throws: SkillStoreConflict.self) { try await store.remove(id: "example", expectedDigest: "old") }
        await #expect(throws: SkillStoreConflict.self) { try await store.setEnabled(false, id: "example", expectedDigest: "old") }
        #expect(try await store.all().first?.skillMarkdown == "new")
        #expect(try await store.allowedCapabilities(skillID: "example") == ["localPython"])
        try await store.setEnabled(false, id: "example", expectedDigest: "new")
        #expect(try await store.all().first?.status == "disabled")
        try await store.remove(id: "example", expectedDigest: "new")
        #expect(try await store.all().isEmpty)
    }

    @Test("Origin bindings survive enable toggles and instruction updates")
    func provenanceBindingsSurviveMutations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("skill-origin-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseManager(path: directory.appendingPathComponent("db.sqlite"))
        try await database.migrate()
        let store = SQLiteSkillStore(database: database)
        let creatorURL = "floe-creator://local/audit-probe-skill"
        try await store.save(.init(
            id: "audit-probe-skill", name: "Audit probe skill", version: "1.0.0",
            skillMarkdown: "body", manifestJSON: "{}",
            sourceURL: creatorURL, sourceDigest: "source-digest",
            rewrittenDigest: "old", rewriteModelID: "local-skill-creator"))
        // The creator/finder bindings are the badge evidence: status toggles
        // and instruction updates must never drop or rewrite them.
        try await store.setEnabled(false, id: "audit-probe-skill", expectedDigest: "old")
        try await store.updateInstructions(
            id: "audit-probe-skill", markdown: "edited", digest: "new", expectedDigest: "old")
        let updated = try #require(await store.all().first)
        #expect(updated.sourceURL == creatorURL)
        #expect(updated.sourceDigest == "source-digest")
        #expect(updated.rewriteModelID == "local-skill-creator")
        #expect(updated.rewrittenDigest == "new")
        #expect(updated.status == "disabled")
        // A reviewed upgrade legitimately replaces the bindings with the
        // newly verified source (upsert keeps the row single).
        try await store.save(.init(
            id: "audit-probe-skill", name: "Audit probe skill", version: "1.1.0", status: "disabled",
            skillMarkdown: "upstream body", manifestJSON: "{}",
            sourceURL: "https://github.com/owner/repo/blob/abc/SKILL.md",
            sourceDigest: "upstream", rewrittenDigest: "upgraded",
            rewriteModelID: "github-reviewed-abc"))
        let rows = try await store.all()
        #expect(rows.count == 1)
        let upgraded = try #require(rows.first)
        #expect(upgraded.sourceURL == "https://github.com/owner/repo/blob/abc/SKILL.md")
        #expect(upgraded.rewriteModelID == "github-reviewed-abc")
        // Legacy rows without provenance stay NULL and must decode as nil.
        try await store.save(.init(
            id: "legacy-skill", name: "Legacy skill", version: "1.0.0",
            skillMarkdown: "body", manifestJSON: "{}", rewrittenDigest: "d"))
        let legacy = try #require(await store.all().first { $0.id == "legacy-skill" })
        #expect(legacy.sourceURL == nil)
        #expect(legacy.sourceDigest == nil)
        #expect(legacy.rewriteModelID == nil)
    }
}
