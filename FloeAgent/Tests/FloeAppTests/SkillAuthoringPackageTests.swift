#if canImport(UIKit)
import Foundation
import Testing
import FloePersistence
import FloeSkills
@testable import FloeApp

@Suite("Skill authoring immutable package review")
struct SkillAuthoringPackageTests {
    private let skill = "---\nname: authoring-fixture\ndescription: Synthetic fixture\n---\nUse the supplied reference.\n"
    private func response(_ files: [[String: String]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["files": files]), as: UTF8.self)
    }
    @Test func importedBytesAndAssetsRemainExact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original"), storage = SkillAuthoringPackageStorage(root: root.appendingPathComponent("owned"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let bytes = Data([0, 255, 1, 4, 128])
        try Data(skill.utf8).write(to: source.appendingPathComponent("SKILL.md"))
        try bytes.write(to: source.appendingPathComponent("assets/source.bin"))
        let owner = UUID(), original = try storage.importFolder(source, ownerID: owner)
        #expect(try storage.snapshot(ownerID: owner, id: original.snapshotID).files["SKILL.md"] == Data(skill.utf8))
        #expect(try storage.snapshot(ownerID: owner, id: original.snapshotID).files["assets/source.bin"] == bytes)
        let adapted = try storage.generatedPackage(from: response([["path": "SKILL.md", "text": skill + "Updated.\n"]]), ownerID: owner, adapting: original.snapshotID)
        #expect(adapted.parentSnapshotID == original.snapshotID)
        #expect(try storage.snapshot(ownerID: owner, id: adapted.snapshotID).files["assets/source.bin"] == bytes)
        #expect(try storage.snapshot(ownerID: owner, id: original.snapshotID).files["SKILL.md"] == Data(skill.utf8))
    }
    @Test func rejectsUnsafePathsAndDuplicateCase() throws {
        for path in ["../SKILL.md", "/SKILL.md", "assets/../x", "assets//x", "assets\\x"] {
            #expect(throws: (any Error).self) { _ = try SkillAuthoringPackageStorage.validatedPath(path) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SkillAuthoringPackageStorage(root: root)
        #expect(throws: (any Error).self) {
            _ = try storage.generatedPackage(from: response([["path": "SKILL.md", "text": skill], ["path": "assets/A.txt", "text": "a"], ["path": "assets/a.txt", "text": "b"]]), ownerID: UUID())
        }
    }
    @Test func rejectsExecutablePayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SkillAuthoringPackageStorage(root: root)
        #expect(throws: (any Error).self) {
            _ = try storage.generatedPackage(from: response([["path": "SKILL.md", "text": skill], ["path": "scripts/evil", "base64": Data([0x7f, 0x45, 0x4c, 0x46, 0, 0, 0, 0]).base64EncodedString()]]), ownerID: UUID())
        }
    }
    @Test func clarificationIsExclusive() throws {
        #expect(try SkillAuthoringPackageStorage.question(from: "{\"question\":\"Which format?\"}") == "Which format?")
        #expect(throws: (any Error).self) { _ = try SkillAuthoringPackageStorage.question(from: "{\"question\":\"Which?\",\"files\":[]}") }
        #expect(throws: (any Error).self) { _ = try SkillAuthoringPackageStorage.question(from: "{\"question\":\"  \"}") }
        #expect(try SkillAuthoringPackageStorage.question(from: "{\"files\":[]}") == nil)
    }
    @Test func nativeInstructionsFenceOwnerRunAndRoute() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), run = UUID(), provider = UUID(), model = UUID(), attempt = UUID()
        let tokenData = try JSONSerialization.data(withJSONObject: ["conversationID": owner.uuidString, "inputRevision": 1, "attemptID": attempt.uuidString, "generation": 1, "runID": run.uuidString])
        let token = try JSONDecoder().decode(SkillAuthoringAttemptToken.self, from: tokenData)
        let input = SkillAuthoringInputSnapshot(ownerID: owner, runID: run, attemptID: attempt, inputRevision: 1, providerID: provider, modelID: model, instructions: "Native fixture")
        try input.persist(root: root)
        #expect(try SkillAuthoringInputSnapshot.instructions(conversationID: owner, runID: run, providerID: provider, modelID: model, expectedAttempt: token, root: root) == "Native fixture")
        #expect(try SkillAuthoringInputSnapshot.instructions(conversationID: owner, runID: UUID(), providerID: provider, modelID: model, expectedAttempt: token, root: root) == nil)
        #expect(throws: (any Error).self) { _ = try SkillAuthoringInputSnapshot.instructions(conversationID: owner, runID: run, providerID: provider, modelID: UUID(), expectedAttempt: token, root: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(owner.uuidString).appendingPathComponent("input-" + run.uuidString + ".json"))
        #expect(throws: (any Error).self) { _ = try SkillAuthoringInputSnapshot.instructions(conversationID: owner, runID: run, providerID: provider, modelID: model, expectedAttempt: token, root: root) }
    }
    @Test func preparedGitHubSnapshotPreservesResourcesAndProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data(skill.utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let bytes = Data([0, 255, 7, 4]); try bytes.write(to: source.appendingPathComponent("assets/data.bin"))
        let validated = try SkillPackageValidator().validate(packageAt: source, requireManifest: false)
        let snapshot = try SkillContentSnapshot(root: source, expectedDigest: validated.canonicalSHA256, manifestOverride: validated.manifest)
        let commit = String(repeating: "a", count: 40)
        let gitHub = try GitHubSkillSource(owner: "fixture", repository: "skills", ref: "main", path: "test")
        let binding = try SkillGitHubBinding(source: gitHub, installedCommit: commit, installedContentDigest: snapshot.package.canonicalSHA256)
        let url = URL(string: "https://github.com/fixture/skills/tree/" + commit + "/test")!
        let storage = SkillAuthoringPackageStorage(root: root.appendingPathComponent("owned")), owner = UUID()
        let copied = try storage.importPrepared(.init(snapshot: snapshot, sourceURL: url, gitHubBinding: binding), ownerID: owner)
        try FileManager.default.removeItem(at: source)
        let reloaded = try storage.descriptor(ownerID: owner, id: copied.snapshotID)
        #expect(reloaded.sourceURL == url && reloaded.gitHubBinding == binding)
        #expect(try storage.snapshot(ownerID: owner, id: copied.snapshotID).files["assets/data.bin"] == bytes)
        #expect(reloaded.digest == snapshot.package.canonicalSHA256)
        let adapted = try storage.generatedPackage(from: response([["path": "SKILL.md", "text": skill + "Changed.\n"]]), ownerID: owner, adapting: copied.snapshotID)
        #expect(adapted.origin == .adapted && adapted.parentSnapshotID == copied.snapshotID)
        #expect(adapted.gitHubBinding == nil && adapted.sourceURL == nil)
    }

}
#endif
