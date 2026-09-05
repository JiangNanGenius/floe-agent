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
}
