import Foundation
import Testing
import FloeCore
import FloeEnvironments
import FloeTools

@Suite(.serialized)
struct ResidentRuntimeGenerationTests {
    private func fixture() throws -> (URL, EnvironmentRoots, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resident-registry-" + UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (root, EnvironmentRoots(rootURL: root.appendingPathComponent("environments")), workspace)
    }

    @Test func settingsCleanupFindsTheInstalledSharedContainerBeforeFirstShell() async throws {
        let (root, roots, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        #expect(try await setup.existingSharedContainer() == nil)
        #expect(!FileManager.default.fileExists(atPath: roots.rootURL.path))

        try await setup.prepare()
        let saved = try Data(contentsOf: roots.registryURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(EnvironmentRegistry.Snapshot.self, from: saved)
        let expected = try #require(snapshot.containers.first { $0.id == EnvironmentRegistry.sharedContainerID })
        let cold = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        #expect(try await cold.existingSharedContainer() == expected)
        #expect(try Data(contentsOf: roots.registryURL) == saved)
        #expect(await cold.record(id: EnvironmentRegistry.sharedContainerID) == nil)
    }

    @Test func committedGenerationPreservesAllHostSoftwareRecordsAndFiles() async throws {
        let (root, roots, workspace) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        let project = try await registry.ensureProjectContainer(workspaceID: "project", workspaceRootPath: workspace.path)
        let layer = roots.layerURL(id: project.id, kind: project.kind)
        let package = InstalledPackage(name: "kept-package", version: "1.2", architecture: "arm64", layer: .project,
            files: ["usr/local/bin/keep"])
        try LayerManifest(id: project.id, kind: .project, baseRevision: "arm64", packages: [package], pythonPackages: ["kept-python"]).write(to: layer)
        let file = layer.appendingPathComponent("usr/local/bin/keep")
        try Data("kept executable bytes".utf8).write(to: file)
        try await registry.updateBytes(id: project.id, bytes: 123, packageCount: 1)
        let before = try #require(await registry.record(id: project.id))
        let manifest = try Data(contentsOf: layer.appendingPathComponent(LayerManifest.fileName))
        let id = UUID()
        try await registry.reconcileResidentRuntimeGeneration(recoveryID: id)
        let after = try #require(await registry.record(id: project.id))
        var expected = before; expected.runtimeGeneration = LinuxResidentRuntimeGeneration.value(recoveryID: id)
        #expect(after == expected)
        #expect(try Data(contentsOf: file) == Data("kept executable bytes".utf8))
        #expect(try Data(contentsOf: layer.appendingPathComponent(LayerManifest.fileName)) == manifest)
        #expect(try LayerManifest.loadChecked(from: layer)?.packages == [package])
    }

    @Test func repeatedReceiptIsIdempotentAndFutureContainersInheritIt() async throws {
        let (root, roots, workspace) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        try await registry.prepare()
        let id = UUID(), generation = LinuxResidentRuntimeGeneration.value(recoveryID: id)
        try await registry.reconcileResidentRuntimeGeneration(recoveryID: id)
        let first = try Data(contentsOf: roots.registryURL)
        try await registry.reconcileResidentRuntimeGeneration(recoveryID: id)
        #expect(try Data(contentsOf: roots.registryURL) == first)
        let reopened = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        try await reopened.prepare()
        let project = try await reopened.ensureProjectContainer(workspaceID: "new-project", workspaceRootPath: workspace.path)
        #expect(project.runtimeGeneration == generation)
        let session = try await reopened.ensureSessionContainer(conversationID: UUID().uuidString,
            workspaceID: "new-project", workspaceRootPath: workspace.path)
        #expect(session.runtimeGeneration == generation)
        let bridge = try await reopened.ensureMacBridgeProjectContainer(workspaceID: "mac", workspaceRootPath: workspace.path)
        #expect(bridge.runtimeGeneration == nil)
    }

    @Test func missingNativeReceiptCannotErasePreviouslyCommittedGeneration() async throws {
        let (root, roots, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        try await registry.reconcileResidentRuntimeGeneration(recoveryID: nil)
        let id = UUID()
        try await registry.reconcileResidentRuntimeGeneration(recoveryID: id)
        let before = try Data(contentsOf: roots.registryURL)
        await #expect(throws: (any Error).self) {
            try await registry.reconcileResidentRuntimeGeneration(recoveryID: nil)
        }
        #expect(try Data(contentsOf: roots.registryURL) == before)
        #expect(await registry.record(id: EnvironmentRegistry.sharedContainerID)?.runtimeGeneration == LinuxResidentRuntimeGeneration.value(recoveryID: id))
    }

    @Test func registryPersistenceFailureRollsBackGenerationAndKeepsSoftware() async throws {
        let (root, roots, workspace) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        let project = try await registry.ensureProjectContainer(workspaceID: "project", workspaceRootPath: workspace.path)
        let before = try Data(contentsOf: roots.registryURL)
        // A real write failure, entirely inside this test-owned fixture.
        try FileManager.default.removeItem(at: roots.registryURL)
        try FileManager.default.createDirectory(at: roots.registryURL, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await registry.reconcileResidentRuntimeGeneration(recoveryID: UUID())
        }
        #expect(await registry.record(id: project.id)?.runtimeGeneration == project.runtimeGeneration)
        try FileManager.default.removeItem(at: roots.registryURL)
        try before.write(to: roots.registryURL)
        try await registry.reconcileResidentRuntimeGeneration(recoveryID: nil)
    }

    @Test func explicitInitialResetClearsTheOldRebuildNamespaceInItsCommit() async throws {
        let (root, roots, workspace) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        let project = try await registry.ensureProjectContainer(workspaceID: "project", workspaceRootPath: workspace.path)
        try await registry.reconcileResidentRuntimeGeneration(recoveryID: UUID())
        let resetID = UUID().uuidString
        _ = try await registry.beginRuntimeReset(id: resetID)
        // Models the existing native controller's successful physical reset;
        // this test exercises only its registry publication boundary.
        try await registry.finishRuntimeReset(id: resetID)
        try await registry.reconcileResidentRuntimeGeneration(recoveryID: nil)
        let current = try #require(await registry.record(id: project.id))
        #expect(!LinuxResidentRuntimeGeneration.requiresExplicitTaskRebind(current.runtimeGeneration))
        let another = try await registry.ensureProjectContainer(workspaceID: "another", workspaceRootPath: workspace.path)
        #expect(another.runtimeGeneration == nil)
    }
    @Test func linuxMaintenanceWaitsForRealLeaseFinishAndNeverDropsItOnTimeout() async throws {
        let (root, roots, workspace) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        let owner = UUID()
        let session = try await registry.ensureSessionContainer(conversationID: owner.uuidString,
            workspaceID: "project", workspaceRootPath: workspace.path)
        let coordinator = EnvironmentExecutionCoordinator(roots: roots, registry: registry)
        let token = CancellationToken()
        var context = ToolContext(runID: UUID(), workspaceRootURL: workspace,
            cancellation: token, environmentID: session.id, conversationID: owner)
        context.executionToolName = "exec.shell"
        let lease = try await coordinator.acquire(context)
        let maintenance = try await coordinator.beginLinuxRuntimeMaintenance()
        #expect(token.isCancelled)
        await #expect(throws: (any Error).self) {
            try await coordinator.waitForLinuxRuntimeMaintenance(maintenance, timeout: .milliseconds(25))
        }
        #expect(await coordinator.activeLeaseCount(environmentID: session.id) == 1)
        var other = ToolContext(runID: UUID(), workspaceRootURL: workspace,
            cancellation: CancellationToken(), environmentID: session.id, conversationID: owner)
        other.executionToolName = "exec.shell"
        await #expect(throws: (any Error).self) { _ = try await coordinator.acquire(other) }
        await lease.finish()
        try await coordinator.waitForLinuxRuntimeMaintenance(maintenance)
        #expect(await coordinator.activeLeaseCount(environmentID: session.id) == 0)
        await coordinator.endLinuxRuntimeMaintenance(maintenance)
        let resumed = try await coordinator.acquire(other)
        await resumed.finish()
    }

    private actor FinishOrder {
        var activeBeforeFinish: Int?
        func set(_ value: Int) { activeBeforeFinish = value }
    }

    @Test func physicalFinalizerRunsBeforeCoordinatorPublishesIdle() async throws {
        let (root, roots, workspace) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "arm64"), owner = UUID()
        let session = try await registry.ensureSessionContainer(conversationID: owner.uuidString,
            workspaceID: "project", workspaceRootPath: workspace.path)
        let coordinator = EnvironmentExecutionCoordinator(roots: roots, registry: registry)
        var context = ToolContext(runID: UUID(), workspaceRootURL: workspace,
            cancellation: CancellationToken(), environmentID: session.id, conversationID: owner)
        context.executionToolName = "studio.biology_environment"
        let lease = try await coordinator.acquireSelectedTaskEnvironment(context)
        let order = FinishOrder()
        let holding = lease.holdingFinalizer {
            await order.set(await coordinator.activeLeaseCount(environmentID: session.id))
        }
        await holding.finish()
        #expect(await order.activeBeforeFinish == 1)
        #expect(await coordinator.activeLeaseCount(environmentID: session.id) == 0)
    }

    @Test func linuxMaintenanceLeavesRemoteLeasesAvailableAndUncancelled() async throws {
        let (root, roots, workspace) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "arm64"), owner = UUID()
        let remote = try await registry.ensureRemoteSessionContainer(conversationID: owner.uuidString,
            workspaceID: "remote", workspaceRootPath: workspace.path, hostID: UUID(), remoteRootPath: "/home/test/task",
            operatingSystem: "linux", architecture: "arm64", runtimeGeneration: "remote-boot")
        let coordinator = EnvironmentExecutionCoordinator(roots: roots, registry: registry), token = CancellationToken()
        var context = ToolContext(runID: UUID(), workspaceRootURL: workspace,
            cancellation: token, environmentID: remote.id, conversationID: owner)
        context.executionToolName = "exec.shell"
        let original = try await coordinator.acquire(context)
        let maintenance = try await coordinator.beginLinuxRuntimeMaintenance()
        #expect(!token.isCancelled)
        let another = try await coordinator.acquire(context)
        try await coordinator.waitForLinuxRuntimeMaintenance(maintenance)
        await another.finish(); await original.finish()
        await coordinator.endLinuxRuntimeMaintenance(maintenance)
    }

    @Test func anOwnedLinuxMigrationFenceBlocksRuntimeRebuildWithoutBeingRemoved() async throws {
        let (root, roots, workspace) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        let project = try await registry.ensureProjectContainer(workspaceID: "project", workspaceRootPath: workspace.path)
        let coordinator = EnvironmentExecutionCoordinator(roots: roots, registry: registry)
        #expect(await coordinator.fenceMigrationIfIdle(environmentID: project.id))
        await #expect(throws: (any Error).self) { _ = try await coordinator.beginLinuxRuntimeMaintenance() }
        #expect(await coordinator.fenceMigrationIfIdle(environmentID: project.id) == false)
        await coordinator.releaseMigrationFence(environmentID: project.id)
        let maintenance = try await coordinator.beginLinuxRuntimeMaintenance()
        #expect(await coordinator.fenceMigrationIfIdle(environmentID: project.id) == false)
        await coordinator.endLinuxRuntimeMaintenance(maintenance)
    }

}
