// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeCore
import FloeTools
import FloeWorkspace
import FloeGit
import FloeGameCore
import FloeGameIDEBridge
import FloeGameWorkspaceHost
import FloeGameBuildKit

#if canImport(Darwin)
@Suite("Game workspace import integration")
struct GameWorkspaceImportIntegrationTests {
    @Test("Workspace file edits are adopted by the game repository without changing Git metadata")
    func workspaceEditsBecomeTheGameRevision() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("floe-game-workspace-" + UUID().uuidString)
        let root = base.appendingPathComponent("game", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let git = LocalGitService.shared
        _ = try await git.initialize(at: root)
        let gitConfig = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let id = UUID(), workspaceID = UUID(), owner = GameProjectOwner.space(recordID: id)
        let context = try GameProjectContext(projectID: id, owner: owner, rootURL: root, savedRevision: "initial")
        let tracker = GameWorkspaceRevisionTracker(binding: try GameIDEWorkspacePin(workspaceID: workspaceID, context: context))
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        let target = try ExistingGameWorkspaceTarget(binding: GameWorkingTreeBinding(workspaceID: workspaceID, context: context), service: service, revisions: tracker)
        let history = base.appendingPathComponent("history")
        let tree = try ExistingWorkspaceGameFiles(targets: [target], repositoryDirectory: history)
        let repository = try FileGameProjectRepository(directory: history, workingTree: tree)
        let initial = try await repository.createProject(projectID: id, owner: owner, title: "Game")
        try service.createFile("script.js", content: "window.ready = true;")
        let updated = try await repository.open(id, owner: owner)
        #expect(updated.revision != initial.revision)
        #expect(updated.files.contains { $0.path.value == "script.js" })
        #expect(try await repository.read(id, owner: owner, revision: updated.revision,
                                          path: GameRelativePath("script.js")) == Data("window.ready = true;".utf8))
        #expect((try await git.snapshot(at: root)).changes.contains { $0.path == "script.js" })
        #expect(try Data(contentsOf: root.appendingPathComponent(".git/config")) == gitConfig)
    }

    @Test("Game folder imports through the real workspace transaction and remains recognizable")
    func gameImportThroughWorkspaceTransaction() async throws {
        let base = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("floe-game-transaction-" + UUID().uuidString)
        let source = base.appendingPathComponent("原始游戏", isDirectory: true)
        let root = base.appendingPathComponent("工作区", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("www/js"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("www/data"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for (path, content) in [("Game.exe", "windows"), ("package.json", "{}"),
                                ("www/index.html", "<html></html>"), ("www/js/rpg_core.js", "// MV"),
                                ("www/data/System.json", "{}")] {
            try Data(content.utf8).write(to: source.appendingPathComponent(path))
        }
        let large = source.appendingPathComponent("nw.dll")
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 190 * 1_024 * 1_024)
        try handle.close()

        let id = UUID(), workspaceID = UUID(), owner = GameProjectOwner.space(recordID: id)
        let context = try GameProjectContext(projectID: id, owner: owner, rootURL: root, savedRevision: "initial")
        let binding = try GameWorkingTreeBinding(workspaceID: workspaceID, context: context)
        let tracker = GameWorkspaceRevisionTracker(binding: try GameIDEWorkspacePin(workspaceID: workspaceID, context: context))
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        let target = try ExistingGameWorkspaceTarget(binding: binding, service: service, revisions: tracker)
        let repositoryDirectory = base.appendingPathComponent("repository", isDirectory: true)
        let workingTree = try ExistingWorkspaceGameFiles(targets: [target], repositoryDirectory: repositoryDirectory)
        let repository = try FileGameProjectRepository(directory: repositoryDirectory, workingTree: workingTree)
        let project = try await repository.createProject(projectID: id, owner: owner, title: "RPG")
        let originalStore = try GameArchiveOriginalStore(directory: base.appendingPathComponent("originals"))
        let result = try await GameProjectSourceImporter(originalStore: originalStore).importSource(
            source, into: project, repository: repository, workspace: base.appendingPathComponent("jobs"))
        #expect(result.project.files.first { $0.path.value == "nw.dll" }?.bytes == 190 * 1_024 * 1_024)
        #expect(result.preview.recognizedEngines.contains(.rpgMakerMV))
        #expect(try Data(contentsOf: root.appendingPathComponent("Game.exe")) == Data("windows".utf8))
        #expect(try FloeDigest.sha256Hex(ofFileAt: root.appendingPathComponent("nw.dll")) == FloeDigest.sha256Hex(ofFileAt: large))
        let inspection = try GameProjectInspector().inspect(rootURL: root.appendingPathComponent("www"))
        #expect(inspection.candidates.contains { $0.engine == .rpgMakerMV })
    }

    @Test("A replaced game root never reuses the earlier workspace snapshot")
    func replacedRootFailsClosed() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("floe-game-root-" + UUID().uuidString)
        let root = base.appendingPathComponent("game", isDirectory: true)
        let old = base.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("original".utf8).write(to: root.appendingPathComponent("index.html"))
        let id = UUID(), workspaceID = UUID(), owner = GameProjectOwner.space(recordID: id)
        let context = try GameProjectContext(projectID: id, owner: owner, rootURL: root, savedRevision: "initial")
        let binding = try GameWorkingTreeBinding(workspaceID: workspaceID, context: context)
        let tracker = GameWorkspaceRevisionTracker(binding: try GameIDEWorkspacePin(workspaceID: workspaceID, context: context))
        let target = try ExistingGameWorkspaceTarget(binding: binding,
            service: WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)), revisions: tracker)
        let tree = try ExistingWorkspaceGameFiles(targets: [target], repositoryDirectory: base.appendingPathComponent("history"))
        _ = try tree.snapshot(projectID: id, owner: owner, limits: GameRepositoryLimits())
        try FileManager.default.moveItem(at: root, to: old)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: root.appendingPathComponent("index.html"))
        #expect(throws: GameProjectError.rootUnavailable) {
            try tree.snapshot(projectID: id, owner: owner, limits: GameRepositoryLimits())
        }
        #expect(try Data(contentsOf: old.appendingPathComponent("index.html")) == Data("original".utf8))
    }
}
#endif
