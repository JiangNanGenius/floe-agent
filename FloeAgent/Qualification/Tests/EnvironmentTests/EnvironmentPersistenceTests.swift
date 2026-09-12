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
        try await cas.retain([digest])
        let copy = root.appendingPathComponent("editable")
        try await cas.link(digest: digest, to: copy)
        try Data("changed".utf8).write(to: copy)
        let second = root.appendingPathComponent("second")
        try await cas.link(digest: digest, to: second)
        #expect(try Data(contentsOf: second) == bytes)
        try await cas.release([digest])
        #expect(try await cas.garbageCollect(grace: 0) == 0)
        try await cas.release([digest])
        #expect(try await cas.garbageCollect(grace: 0) == Int64(bytes.count))
        #expect(try await cas.stats().blobCount == 0)
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

extension EnvironmentPersistenceTests {
    @Test func corruptCASIndexNeverAuthorizesCollection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root)
        let initial = ContainerCAS(roots: roots)
        let digest = try await initial.ingest(data: Data("retained".utf8))
        let indexURL = roots.casURL.appendingPathComponent("index.json")
        let corrupt = Data("invalid index".utf8)
        try corrupt.write(to: indexURL)
        let restarted = ContainerCAS(roots: roots)
        do { _ = try await restarted.garbageCollect(grace: 0); Issue.record("Corrupt index allowed GC") } catch {}
        #expect(try Data(contentsOf: indexURL) == corrupt)
        #expect(FileManager.default.fileExists(atPath: roots.casURL.appendingPathComponent(String(digest.prefix(2))).appendingPathComponent(digest).path))
    }

    @Test func failedCASReferenceWriteDoesNotEnableCollection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root)
        let cas = ContainerCAS(roots: roots)
        let digest = try await cas.ingest(data: Data("retained".utf8))
        let indexURL = roots.casURL.appendingPathComponent("index.json")
        let durable = try Data(contentsOf: indexURL)
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: false)
        do { try await cas.release([digest]); Issue.record("Index write failure ignored") } catch {}
        do { _ = try await cas.garbageCollect(grace: 0); Issue.record("Uncommitted count used for GC") } catch {}
        try FileManager.default.removeItem(at: indexURL)
        try durable.write(to: indexURL)
        #expect(try await cas.garbageCollect(grace: 0) == 0)
        let copy = root.appendingPathComponent("verified")
        try await cas.link(digest: digest, to: copy)
        #expect(try Data(contentsOf: copy) == Data("retained".utf8))
    }
}

extension EnvironmentPersistenceTests {
    @Test func sessionOwnershipIncludesWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = EnvironmentRegistry(roots: EnvironmentRoots(rootURL: root), baseRevision: "one")
        let a = try await registry.ensureSessionContainer(conversationID: "same-chat", workspaceID: "a", workspaceRootPath: "/a")
        let b = try await registry.ensureSessionContainer(conversationID: "same-chat", workspaceID: "b", workspaceRootPath: "/b")
        #expect(a.id != b.id)
        #expect(a.parentID != b.parentID)
        #expect(try await registry.ensureSessionContainer(conversationID: "same-chat", workspaceID: "a", workspaceRootPath: "/a").id == a.id)
    }
    @Test func failedCreationAndTransitionRollBackRegistryMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root)
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "one")
        let project = try await registry.ensureProjectContainer(workspaceID: "a", workspaceRootPath: "/a")
        try FileManager.default.removeItem(at: roots.registryURL)
        try FileManager.default.createDirectory(at: roots.registryURL, withIntermediateDirectories: false)
        do { try await registry.transition(id: project.id, state: .deleting); Issue.record("Failed transition accepted") } catch {}
        #expect(await registry.record(id: project.id)?.state == .active)
        do { _ = try await registry.ensureProjectContainer(workspaceID: "b", workspaceRootPath: "/b"); Issue.record("Failed creation accepted") } catch {}
        #expect(await registry.containersOwned(by: "b").isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: roots.containersURL.path).count == 1)
    }
}

extension EnvironmentPersistenceTests {
    @Test func templateCopySurvivesSourceCASCollectionAndRejectsDuplicateName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root)
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "one")
        let cas = ContainerCAS(roots: roots)
        let source = try await registry.ensureProjectContainer(workspaceID: "a", workspaceRootPath: "/a")
        let sourceURL = roots.layerURL(id: source.id, kind: .project)
        let digest = try await cas.ingest(data: Data("template-data".utf8))
        try await cas.link(digest: digest, to: sourceURL.appendingPathComponent("usr/lib/value"))
        var manifest = try #require(try LayerManifest.loadChecked(from: sourceURL))
        manifest.casRefs = [digest]
        try manifest.write(to: sourceURL)
        let template = try await registry.createTemplate(from: source.id, name: "saved")
        try await cas.release([digest])
        _ = try await cas.garbageCollect(grace: 0)
        let templateURL = roots.layerURL(id: template.id, kind: .template)
        #expect(try Data(contentsOf: templateURL.appendingPathComponent("usr/lib/value")) == Data("template-data".utf8))
        #expect(try LayerManifest.loadChecked(from: templateURL)?.casRefs.isEmpty == true)
        do { _ = try await registry.createTemplate(from: source.id, name: "saved"); Issue.record("Duplicate template accepted") } catch {}
        let restarted = EnvironmentRegistry(roots: roots, baseRevision: "one")
        try await restarted.prepare()
        #expect(await restarted.template(named: "saved")?.id == template.id)
    }
}
