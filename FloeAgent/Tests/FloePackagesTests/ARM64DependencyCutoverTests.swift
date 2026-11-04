import Foundation
import Testing
import FloeCore
import FloeEnvironments
import FloeExecution
import FloeTools

@Suite(.serialized)
struct ARM64DependencyCutoverTests {
    private func fixture() throws -> (URL, EnvironmentRoots, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-arm64-cutover-" + UUID().uuidString)
        let workspace = root.appendingPathComponent("project-files")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (root, EnvironmentRoots(rootURL: root.appendingPathComponent("managed")), workspace)
    }

    @Test func retiredDependenciesAreReplacedWithoutMovingProjectFilesOrIdentity() async throws {
        let (root, roots, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = EnvironmentRegistry(roots: roots, baseRevision: "retired")
        let project = try await old.ensureProjectContainer(workspaceID: FloeDigest.sha256Hex(Data(workspace.resolvingSymlinksInPath().standardizedFileURL.path.utf8)), workspaceRootPath: workspace.path)
        let projectLayer = roots.layerURL(id: project.id, kind: .project)
        try Data("old ABI".utf8).write(to: roots.sharedURL.appendingPathComponent("old-dependency"))
        try Data("old ABI".utf8).write(to: projectLayer.appendingPathComponent("old-dependency"))
        let source = workspace.appendingPathComponent("keep.txt")
        try Data("user files".utf8).write(to: source)
        try await old.transition(id: project.id, state: .stopped)
        let current = EnvironmentRegistry(roots: roots, baseRevision: "arm64", retiredLinuxBaseRevisions: ["retired"])
        try await current.prepare()
        let shared = try #require(await current.record(id: EnvironmentRegistry.sharedContainerID))
        let retained = try #require(await current.record(id: project.id))
        #expect(shared.state == .active && !shared.requiresRebuild)
        #expect(retained.state == .stopped && !retained.requiresRebuild)
        #expect(retained.ownerID == project.ownerID && retained.architecture == "arm64")
        #expect(retained.runtimeGeneration != nil && retained.pendingRuntimeResetID == nil)
        #expect(try await current.workspaceRoot(for: project.id)?.path == workspace.path)
        #expect(try Data(contentsOf: source) == Data("user files".utf8))
        #expect(!FileManager.default.fileExists(atPath: roots.sharedURL.appendingPathComponent("old-dependency").path))
        #expect(!FileManager.default.fileExists(atPath: projectLayer.appendingPathComponent("old-dependency").path))
        // Reopening the current ABI must preserve its new installations.
        let dependency = projectLayer.appendingPathComponent("current-dependency")
        try Data("ARM64".utf8).write(to: dependency)
        let reopened = EnvironmentRegistry(roots: roots, baseRevision: "arm64", retiredLinuxBaseRevisions: ["retired"])
        try await reopened.prepare()
        #expect(try Data(contentsOf: dependency) == Data("ARM64".utf8))
    }

    @Test func undeclaredBaseChangeRetainsDependenciesAndTheRebuildGate() async throws {
        let (root, roots, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await EnvironmentRegistry(roots: roots, baseRevision: "unrelated").prepare()
        let file = roots.sharedURL.appendingPathComponent("keep-dependency")
        try Data("keep".utf8).write(to: file)
        let current = EnvironmentRegistry(roots: roots, baseRevision: "arm64", retiredLinuxBaseRevisions: ["retired"])
        try await current.prepare()
        #expect(await current.record(id: EnvironmentRegistry.sharedContainerID)?.requiresRebuild == true)
        #expect(try Data(contentsOf: file) == Data("keep".utf8))
    }

    @Test func nestedProjectFilesPreventTheWholeReplacementBatch() async throws {
        let (root, roots, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = EnvironmentRegistry(roots: roots, baseRevision: "retired")
        try await old.prepare()
        let workspace = roots.sharedURL.appendingPathComponent("user-project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let project = try await old.ensureProjectContainer(workspaceID: FloeDigest.sha256Hex(Data(workspace.resolvingSymlinksInPath().standardizedFileURL.path.utf8)), workspaceRootPath: workspace.path)
        let userFile = workspace.appendingPathComponent("keep.txt")
        let dependency = roots.layerURL(id: project.id, kind: .project).appendingPathComponent("keep-dependency")
        try Data("user".utf8).write(to: userFile)
        try Data("ABI".utf8).write(to: dependency)
        let current = EnvironmentRegistry(roots: roots, baseRevision: "arm64", retiredLinuxBaseRevisions: ["retired"])
        do { try await current.prepare(); Issue.record("Nested project data must prevent retirement") }
        catch { #expect(error.localizedDescription.contains("Project files are inside")) }
        #expect(try Data(contentsOf: userFile) == Data("user".utf8))
        #expect(try Data(contentsOf: dependency) == Data("ABI".utf8))
    }

    @Test func productionStoreCannotReopenRetiredRuntimePins() throws {
        let root = try RuntimeV2Layout.production().root
        #expect(root.lastPathComponent == "arm64-v1")
        #expect(root.deletingLastPathComponent().lastPathComponent == "Runtime")
    }
    @Test func relocatedPrivateTaskKeepsItsEnvironmentAndRejectsAnotherTask() async throws {
        let (root, roots, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID()
        let oldContainer = root.appendingPathComponent("Containers/Data/Application/" + UUID().uuidString)
        let oldTask = oldContainer.appendingPathComponent("Library/Application Support/FloeAgent/PrivateTasks/" + taskID.uuidString)
        try FileManager.default.createDirectory(at: oldTask, withIntermediateDirectories: true)
        let original = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        let oldOwner = FloeDigest.sha256Hex(Data(oldTask.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
        let project = try await original.ensureProjectContainer(workspaceID: oldOwner, workspaceRootPath: oldTask.path)
        try Data("retained file".utf8).write(to: oldTask.appendingPathComponent("keep.txt"))
        let managed = root.appendingPathComponent("new-app/PrivateTasks")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        let moved = managed.appendingPathComponent(taskID.uuidString)
        try FileManager.default.moveItem(at: oldTask, to: moved)
        let current = EnvironmentRegistry(roots: roots, baseRevision: "arm64", managedPrivateTasksRoot: managed)
        try await current.prepare()
        #expect(try await current.workspaceRoot(for: project.id)?.path == moved.path)
        let reused = try await current.ensureProjectContainer(
            workspaceID: FloeDigest.sha256Hex(Data(moved.path.utf8)), workspaceRootPath: moved.path)
        #expect(reused.id == project.id)
        let coordinator = EnvironmentExecutionCoordinator(roots: roots, registry: current)
        let lease = try await coordinator.acquire(ToolContext(runID: UUID(), workspaceRootURL: moved,
            cancellation: CancellationToken(), environmentID: project.id, conversationID: taskID))
        #expect(lease.context.environment?.id == project.id)
        await lease.finish()
        let other = managed.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        do {
            let wrong = try await coordinator.acquire(ToolContext(runID: UUID(), workspaceRootURL: other,
                cancellation: CancellationToken(), environmentID: project.id, conversationID: taskID))
            await wrong.finish()
            Issue.record("Relocation must not authorize another task root")
        } catch { #expect(error.localizedDescription.contains("another workspace")) }
        #expect(try Data(contentsOf: moved.appendingPathComponent("keep.txt")) == Data("retained file".utf8))
    }

    @Test func externalFolderNamedPrivateTasksIsNotReinterpreted() async throws {
        let (root, roots, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID().uuidString
        let external = root.appendingPathComponent("external/PrivateTasks/" + taskID)
        let managed = root.appendingPathComponent("current/PrivateTasks")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managed.appendingPathComponent(taskID), withIntermediateDirectories: true)
        let old = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        let record = try await old.ensureProjectContainer(
            workspaceID: FloeDigest.sha256Hex(Data(external.path.utf8)), workspaceRootPath: external.path)
        let current = EnvironmentRegistry(roots: roots, baseRevision: "arm64", managedPrivateTasksRoot: managed)
        try await current.prepare()
        #expect(try await current.workspaceRoot(for: record.id)?.path == external.path)
    }

}
