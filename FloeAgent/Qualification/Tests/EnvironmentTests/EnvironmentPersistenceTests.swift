import Foundation
import Testing
import FloeEnvironments
import FloeTools

@Suite("Environment durability")
struct EnvironmentPersistenceTests {
    @Test func registrySurvivesRestartAndMarksNewBase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root)
        let first = EnvironmentRegistry(roots: roots, baseRevision: "one")
        let project = try await first.ensureProjectContainer(workspaceID: "project-a", workspaceRootPath: "/workspace/a")
        let session = try await first.ensureSessionContainer(conversationID: "chat-a", workspaceID: "project-a", workspaceRootPath: "/workspace/a")
        let second = EnvironmentRegistry(roots: roots, baseRevision: "two")
        try await second.prepare()
        #expect(await second.record(id: project.id)?.requiresRebuild == true)
        #expect(await second.record(id: session.id)?.parentID == project.id)
        #expect(await second.all().count == 3)
    }

    @Test func corruptRegistryIsPreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root)
        try roots.prepare()
        let bytes = Data("corrupt".utf8)
        try bytes.write(to: roots.registryURL)
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "one")
        do { try await registry.prepare(); Issue.record("Corrupt registry accepted") } catch {}
        #expect(try Data(contentsOf: roots.registryURL) == bytes)
    }

    @Test func casRetainsSharedBlobsAndCopiesAreIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cas = ContainerCAS(roots: EnvironmentRoots(rootURL: root))
        let bytes = Data("original".utf8)
        let digest = try await cas.ingest(data: bytes)
        await cas.retain([digest])
        let copy = root.appendingPathComponent("editable")
        try await cas.link(digest: digest, to: copy)
        try Data("changed".utf8).write(to: copy)
        let second = root.appendingPathComponent("second")
        try await cas.link(digest: digest, to: second)
        #expect(try Data(contentsOf: second) == bytes)
        await cas.release([digest])
        #expect(await cas.garbageCollect(grace: 0) == 0)
        await cas.release([digest])
        #expect(await cas.garbageCollect(grace: 0) == Int64(bytes.count))
        #expect(await cas.stats().blobCount == 0)
    }

    @Test func failedStopPreservesEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root)
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "one")
        let project = try await registry.ensureProjectContainer(workspaceID: "a", workspaceRootPath: "/a")
        let lifecycle = ContainerLifecycle(roots: roots, registry: registry, cas: ContainerCAS(roots: roots))
        do { _ = try await lifecycle.destroy(containerID: project.id); Issue.record("Deletion ignored missing lifecycle hooks") } catch {}
        #expect(await registry.record(id: project.id)?.state == .active)
        #expect(FileManager.default.fileExists(atPath: roots.layerURL(id: project.id, kind: .project).path))
    }
    @Test func projectsAndCancellationRemainScoped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root)
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "one")
        let coordinator = EnvironmentExecutionCoordinator(roots: roots, registry: registry)
        let firstToken = CancellationToken(), secondToken = CancellationToken()
        let first = try await coordinator.acquire(ToolContext(runID: UUID(), workspaceRootURL: root.appendingPathComponent("a"), cancellation: firstToken, conversationID: UUID()))
        let second = try await coordinator.acquire(ToolContext(runID: UUID(), workspaceRootURL: root.appendingPathComponent("b"), cancellation: secondToken, conversationID: UUID()))
        let firstID = try #require(first.context.environmentID)
        #expect(firstID != second.context.environmentID)
        #expect(first.context.environment?.writableLayerURL != second.context.environment?.writableLayerURL)
        do { try await coordinator.stopAndWait(environmentID: firstID, timeout: .milliseconds(50)); Issue.record("Active execution was reported stopped") } catch {}
        #expect(firstToken.isCancelled)
        #expect(!secondToken.isCancelled)
        await first.finish()
        try await coordinator.stopAndWait(environmentID: firstID)
        await second.finish()
    }

}

extension EnvironmentPersistenceTests {
    @Test func explicitEnvironmentCannotCrossWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root)
        let coordinator = EnvironmentExecutionCoordinator(roots: roots, registry: EnvironmentRegistry(roots: roots, baseRevision: "one"))
        let first = try await coordinator.acquire(ToolContext(runID: UUID(), workspaceRootURL: root.appendingPathComponent("a"), cancellation: CancellationToken()))
        defer { Task { await first.finish() } }
        await #expect(throws: (any Error).self) {
            try await coordinator.acquire(ToolContext(runID: UUID(), workspaceRootURL: root.appendingPathComponent("b"), cancellation: CancellationToken(), environmentID: first.context.environmentID))
        }
    }
}
