#if canImport(UIKit)
import Foundation
import Testing
import FloeSkills
import FloePersistence
import FloeTools
@testable import FloeApp

@Suite("FloeApp.SkillLifecycle", .serialized)
struct SkillLifecycleTests {
    @Test(arguments: ["prepared", "rollingBack"]) @MainActor func interruptedUpgradeRestoresFilesBeforeServingSkills(phase: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-recover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let center = SkillsCenter(environment: environment, installationRoot: root)
        let created = try await center.createSkill(.init(name: "Recover Test", description: "Fixture", instructions: "Original"))
        let old = try #require(try await environment.skillStore.all().first { $0.id == created.id })
        let history = root.appendingPathComponent(".upgrade-history/\(UUID())")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent(old.id), to: history.appendingPathComponent("previous"))
        let oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old))
        let journal: [String: Any] = ["oldSkill": oldJSON, "oldGrants": [], "newDigest": String(repeating: "a", count: 64),
            "source": ["owner": "o", "repository": "r", "ref": "main", "path": "SKILL.md"], "commit": String(repeating: "b", count: 40),
            "phase": phase, "createdAt": Date().timeIntervalSinceReferenceDate]
        try JSONSerialization.data(withJSONObject: journal).write(to: history.appendingPathComponent("transaction.json"))
        try Data("interrupted replacement".utf8).write(to: root.appendingPathComponent("\(old.id)/SKILL.md"))
        let relaunched = SkillsCenter(environment: environment, installationRoot: root)
        await relaunched.load()
        #expect(relaunched.errorMessage == nil)
        #expect(try SkillPackageValidator().validate(packageAt: root.appendingPathComponent(old.id)).canonicalSHA256 == old.rewrittenDigest)
        #expect(try await relaunched.readSkills(id: old.id).first?.digest == old.rewrittenDigest)
    }

    @Test @MainActor func reviewedUpgradeRollbackAndRunningVersionPin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-upgrade-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let install = root.appendingPathComponent("Skills")
        let center = SkillsCenter(environment: environment, installationRoot: install)
        let created = try await center.createSkill(.init(name: "Upgrade Test", description: "Fixture", instructions: "Original"))
        let initial = try #require(try await center.readSkills(id: created.id).first)
        let runID = UUID()
        try await environment.skillStore.setPermission(skillID: created.id, capability: "workspace.read", decision: "allow",
            scopeJSON: #"{"path":"reports"}"#, expiresAt: Date().addingTimeInterval(60))
        try await environment.skillStore.setPermission(skillID: created.id, capability: "network", decision: "deny")
        let originalPermissions = try await environment.skillStore.permissions(skillID: created.id)
        _ = await center.runtimeSelection(runID: runID)
        let current = try SkillContentSnapshot(root: install.appendingPathComponent(created.id), expectedDigest: initial.digest)
        let proposedRoot = root.appendingPathComponent("proposed")
        try FileManager.default.copyItem(at: current.package.rootURL, to: proposedRoot)
        try (current.files["SKILL.md"]! + Data("\nNew reviewed instructions\n".utf8)).write(to: proposedRoot.appendingPathComponent("SKILL.md"))
        let proposed = try SkillPackageValidator().validate(packageAt: proposedRoot)
        let source = try GitHubSkillSource(owner: "floe", repository: "guides", ref: "main", path: "SKILL.md")
        let candidate = try SkillUpgradeCandidate(source: source, commit: String(repeating: "a", count: 40), installed: current,
            proposed: SkillContentSnapshot(root: proposedRoot, expectedDigest: proposed.canonicalSHA256))
        try await center.stageUpgradeForReview(candidate, at: proposedRoot)
        await center.applyReviewedUpgrade()
        #expect(center.errorMessage == nil)
        #expect(try await center.readSkills(id: created.id).first?.digest == proposed.canonicalSHA256)
        #expect(try await center.readSkills(id: created.id, runID: runID).first?.digest == initial.digest)
        #expect(try await center.readSkills(id: created.id, runID: runID).first?.currentDigest == proposed.canonicalSHA256)
        // A new coordinator simulates process relaunch; task snapshots persist.
        let relaunched = SkillsCenter(environment: environment, installationRoot: install)
        #expect(try await relaunched.readSkills(id: created.id, runID: runID).first?.digest == initial.digest)
        let updated = try #require(try await environment.skillStore.all().first { $0.id == created.id })
        await center.rollbackLatestUpgrade(skill: updated)
        #expect(center.errorMessage == nil)
        #expect(try await center.readSkills(id: created.id).first?.digest == initial.digest)
        #expect(try await environment.skillStore.permissions(skillID: created.id) == originalPermissions)
    }

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
        #expect(try await center.readSkills(id: nil).allSatisfy { $0.id != created.id })
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("RemovedSkills"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0].appendingPathComponent("floe.json")) == manifest)
    }

    @Test @MainActor func firstReadSeedsGuidesAndKeepsPythonIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-seed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let center = SkillsCenter(environment: environment, installationRoot: root)
        let pdf = try #require(try await center.readSkills(id: "floe-pdf").first)
        #expect(pdf.requiredToolNames?.contains("document.pdf.inspect") == true)
        #expect(center.builtinSeedFailures.isEmpty)
        let catalogNames = Set(ToolCatalog.allDescriptors.map(\.name))
        for guide in BundledDomainSkills.all {
            #expect(Set(guide.toolNames).isSubset(of: catalogNames), "Unknown tool reference in \(guide.id): \(Set(guide.toolNames).subtracting(catalogNames))")
        }
        #expect(try await center.readSkills(id: nil).count == BundledDomainSkills.all.count)
        let selection = await center.runtimeSelection(runID: UUID())
        #expect(selection.allowedToolNames == nil)
        let python = try #require(try await center.readSkills(id: "floe-python").first)
        await #expect(throws: (any Error).self) {
            try await center.manageSkill(.init(action: .setEnabled, id: python.id, expectedDigest: python.digest, enabled: false))
        }
    }
}
#endif
