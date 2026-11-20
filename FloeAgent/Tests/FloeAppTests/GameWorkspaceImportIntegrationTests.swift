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
#if canImport(UIKit)
import FloePersistence
import FloeModels
@testable import FloeApp
#endif

#if canImport(Darwin)
@Suite("Game workspace import integration")
struct GameWorkspaceImportIntegrationTests {
    #if canImport(UIKit)
    @Test("Reopening a conversation reads its current durable workspace owner")
    @MainActor func reopenedTaskUsesPersistedOwnerAfterReassignment() async throws {
        let environment = FloeAgentApp.liveEnvironment
        let conversation = UUID(), now = Date()
        let store = SQLiteWorkspaceStore(database: environment.database)
        try await environment.conversationStore.saveConversation(.init(id: conversation, title: "Workspace owner fixture", createdAt: now, updatedAt: now))
        let first = try await store.ensureWorkspace(conversationID: conversation, title: "First")
        let second = WorkspaceRecord(name: "Replacement", rootBookmark: Data(), kind: .privateTask,
                       internalRelativePath: "PrivateTasks/" + UUID().uuidString, createdAt: now, updatedAt: now)
        try await store.saveWorkspace(second)
        let center = WorkspaceCenter(environment: environment, publishesSharedState: false)
        try await center.openTaskWorkspace(conversationID: conversation)
        let previousRoot = try #require(center.currentRootURL)
        defer { try? FileManager.default.removeItem(at: previousRoot) }
        #expect(center.currentWorkspace?.id == first.id)
        try await store.assignConversation(workspaceID: second.id, conversationID: conversation)
        try await center.openTaskWorkspace(conversationID: conversation)
        let newRoot = try #require(center.currentRootURL)
        defer { try? FileManager.default.removeItem(at: newRoot) }
        #expect(center.currentWorkspace?.id == second.id)
        #expect(newRoot != previousRoot)
        #expect(center.workspaceID(for: conversation) == second.id)
        center.closeCurrentWorkspace()
        try await environment.conversationStore.deleteConversation(id: conversation)
        try await store.deleteWorkspace(id: first.id)
        try await store.deleteWorkspace(id: second.id)
    }

    @Test("Workspace-authored files can run without a game record and deleting the entry prevents another run")
    @MainActor func actualFilesDetermineWhetherTheChatHasARunnableGame() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let owner = UUID(), run = UUID(), now = Date()
        try await environment.conversationStore.saveConversation(.init(id: owner, title: "Disk game fixture", createdAt: now, updatedAt: now))
        let store = SQLiteWorkspaceStore(database: environment.database)
        let workspace = try await store.ensureWorkspace(conversationID: owner, title: "Disk game fixture")
        let lease = try await environment.workspaceCenter.acquireTaskRoot(workspace, conversationID: owner)
        defer { lease.release() }
        let registry = environment.gameWorkspaces
        let service = GameProjectToolService(environment: environment, registry: registry)
        var context = ToolContext(runID: run, toolCallID: "file-only", allowedToolNames: ["game.run", "game.list"],
                                  workspaceRootURL: lease.url, cancellation: CancellationToken(), conversationID: owner)
        context.executionToolName = "game.run"
        var historyRoot: URL?
        var failure: Error?
        do {
            try await environment.runStore.saveRun(.init(id: run, conversationID: owner, state: "executing", goal: "Run from files", startedAt: now))
            #expect(try await service.boundChatSession(context, conversationID: owner) == nil)
            #expect(!registry.hasSavedChatGame(conversationID: owner, workspaceID: workspace.id))
            let entry = lease.url.appendingPathComponent("index.html")
            let story = """
                <!doctype html><html><body><p>Forest clearing</p>
                <tw-storydata name="Forest" startnode="1" creator="Twine" creator-version="2.8.1" ifid="8E7C4F3A-1D2B-4C5E-9F60-112233445566" format="SugarCube" format-version="2.37.3">
                <tw-passagedata pid="1" name="Start">Forest clearing</tw-passagedata></tw-storydata></body></html>
                """
            try Data(story.utf8).write(to: entry)
            let discovered = try await service.resolve(context)
            historyRoot = discovered.support
            #expect(discovered.selection?.runSelection?.engine == .twine)
            let started = try await service.run(discovered, action: .run, context: context)
            #expect(started.receipt.runID != nil)
            _ = try await service.run(discovered, action: .stop, context: context)
            try FileManager.default.removeItem(at: entry)
            var listContext = context
            listContext.executionToolName = "game.list"
            let list = try #require(ToolRunnerRegistry.shared.runner(named: "game.list"))
            let output = try await list.execute(argumentsJSON: Data("{}".utf8), context: listContext)
            let json = try #require(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
            let works = try #require(json["works"] as? [[String: Any]])
            #expect(works.allSatisfy { $0["engine"] == nil })
            await #expect(throws: (any Error).self) { _ = try await service.run(discovered, action: .run, context: context) }
            #expect(!FileManager.default.fileExists(atPath: entry.path))
        } catch { failure = error }
        if let session = registry.session(projectID: workspace.id, owner: .conversation(conversationID: owner, workspaceID: workspace.id)) {
            _ = await registry.close(session)
        }
        try await environment.conversationStore.deleteConversation(id: owner)
        try await store.deleteWorkspace(id: workspace.id)
        if let historyRoot { try FileManager.default.removeItem(at: historyRoot) }
        try FileManager.default.removeItem(at: lease.url)
        if let failure { throw failure }
    }

    @Test("A relaunched ordinary chat runs its saved game and rejects a foreign root")
    @MainActor func ordinaryGameRunsAfterRegistryRecreation() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let conversation = UUID(), run = UUID(), now = Date()
        try await environment.conversationStore.saveConversation(.init(id: conversation, title: "Game reopen fixture", createdAt: now, updatedAt: now))
        let store = SQLiteWorkspaceStore(database: environment.database)
        let workspace = try await store.ensureWorkspace(conversationID: conversation, title: "Game reopen fixture")
        let lease = try await environment.workspaceCenter.acquireTaskRoot(workspace, conversationID: conversation)
        defer { lease.release() }
        let initial = GameWorkspaceRegistry(environment: environment)
        let relaunched = GameWorkspaceRegistry(environment: environment)
        let session = try await initial.openChatTaskGame(conversationID: conversation, title: workspace.name)
        let alternate = WorkspaceRecord(name: "Other game workspace", rootBookmark: Data(), kind: .privateTask,
                                        internalRelativePath: "PrivateTasks/" + UUID().uuidString, createdAt: now, updatedAt: now)
        try await store.saveWorkspace(alternate)
        var alternateRoot: URL?
        var runFailure: Error?
        do {
            try await environment.conversationStore.setArchived(id: conversation, archived: true)
            try await environment.runStore.saveRun(.init(id: run, conversationID: conversation, state: "executing", goal: "Reopen saved game", startedAt: now))
            try await initial.initializeStarter(for: .rpgMakerMV, session: session)
            #expect(session.key.projectID == workspace.id)
            _ = await initial.close(session)
            var context = ToolContext(runID: run, toolCallID: "cold-run", allowedToolNames: ["game.run"],
                                      workspaceRootURL: lease.url, cancellation: CancellationToken(), conversationID: conversation)
            context.executionToolName = "game.run"
            let service = GameProjectToolService(environment: environment, registry: relaunched)
            var foreign = context
            foreign.workspaceRootURL = lease.url.deletingLastPathComponent()
            await #expect(throws: (any Error).self) { _ = try await service.resolve(foreign, projectID: workspace.id) }
            let reopened = try await service.resolve(context, projectID: workspace.id)
            #expect(reopened.key == session.key)
            let started = try await service.run(reopened, action: .run, context: context)
            #expect(started.receipt.projectID == workspace.id)
            #expect(started.receipt.runID != nil)
            _ = try await service.run(reopened, action: .stop, context: context)

            // The IDE keeps its center while the user closes this game and opens a different folder.
            let visibleCenter = reopened.center
            try await visibleCenter.openAppOwnedWorkspace(id: alternate.id)
            alternateRoot = visibleCenter.currentRootURL
            #expect(reopened.project.currentPin == nil)
            let restored = try await service.resolve(context, projectID: workspace.id)
            #expect(restored.project.currentPin?.workspaceID == workspace.id)
            let restarted = try await service.run(restored, action: .run, context: context)
            #expect(restarted.receipt.runID != nil)
            #expect(visibleCenter.currentWorkspace?.id == alternate.id)
            _ = try await service.run(restored, action: .stop, context: context)
            visibleCenter.closeCurrentWorkspace()

        } catch {
            runFailure = error
        }
        _ = await initial.closeAll()
        _ = await relaunched.closeAll()
        try await environment.conversationStore.deleteConversation(id: conversation)
        try await store.deleteWorkspace(id: workspace.id)
        try await store.deleteWorkspace(id: alternate.id)
        if let alternateRoot { try FileManager.default.removeItem(at: alternateRoot) }
        try FileManager.default.removeItem(at: session.support)
        try FileManager.default.removeItem(at: lease.url)
        if let runFailure { throw runFailure }
    }
    #endif

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
