#if canImport(UIKit)
import Foundation
import Testing
import FloeSkills
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.SkillLifecycle", .serialized)
struct SkillLifecycleTests {
    @Test @MainActor func createReadUpdateDisableRemovePreservesPackageAndConflicts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-lifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let center = SkillsCenter(environment: environment, installationRoot: root.appendingPathComponent("Skills"))
        let created = try await center.createSkill(.init(name: "Lifecycle Test", description: "Use for fixture testing", instructions: "Original instructions"))
        let initial = try #require(try await center.readSkills(id: created.id).first)
        let manifest = try Data(contentsOf: root.appendingPathComponent("Skills/\(created.id)/floe.json"))
        _ = try await center.manageSkill(.init(action: .update, id: created.id, expectedDigest: initial.digest, instructions: "Updated instructions"))
        let updated = try #require(try await center.readSkills(id: created.id).first)
        #expect(updated.digest != initial.digest)
        #expect(updated.markdown?.contains("Updated instructions") == true)
        #expect(try Data(contentsOf: root.appendingPathComponent("Skills/\(created.id)/floe.json")) == manifest)
        await #expect(throws: SkillStoreConflict.self) {
            try await center.manageSkill(.init(action: .remove, id: created.id, expectedDigest: initial.digest))
        }
        _ = try await center.manageSkill(.init(action: .setEnabled, id: created.id, expectedDigest: updated.digest, enabled: false))
        #expect(try await center.readSkills(id: created.id).first?.enabled == false)
        let removed = try await center.manageSkill(.init(action: .remove, id: created.id, expectedDigest: updated.digest))
        #expect(removed.contains("recoverablePackage="))
        #expect(try await center.readSkills(id: nil).isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("RemovedSkills"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0].appendingPathComponent("floe.json")) == manifest)
    }
}
#endif
