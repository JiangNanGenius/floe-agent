// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeEnvironments
import FloeModels
import FloeTools
@testable import FloeApp

/// Real registry/coordinator leases with synthetic task roots. No interpreter,
/// guest, remote connection, installed scientific engine or user file is used.
@Suite("Native scientific task environment routing")
struct ChemistryEnvironmentRoutingTests {
    private struct Fixture: Sendable {
        let root: URL
        let workspace: URL
        let registry: EnvironmentRegistry
        let coordinator: EnvironmentExecutionCoordinator
        let record: ContainerRecord
        let context: ToolContext
    }

    private func fixture(backend: EnvironmentExecutionBackend) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("science-routing-" + UUID().uuidString)
        let workspace = root.appendingPathComponent("Workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let roots = EnvironmentRoots(rootURL: root.appendingPathComponent("Environments"))
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "science-routing-fixture")
        let taskID = UUID()
        let workspaceID = FloeDigest.sha256Hex(Data(workspace.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
        let record: ContainerRecord
        if backend == .remoteSSH {
            record = try await registry.ensureRemoteSessionContainer(conversationID: taskID.uuidString,
                workspaceID: workspaceID, workspaceRootPath: workspace.path, hostID: UUID(),
                remoteRootPath: "/home/floe/science-fixture", operatingSystem: "linux", architecture: "aarch64",
                distribution: "debian", runtimeGeneration: "fixture-boot-1")
        } else {
            record = try await registry.ensureSessionContainer(conversationID: taskID.uuidString,
                workspaceID: workspaceID, workspaceRootPath: workspace.path, executionBackend: backend)
        }
        var context = ToolContext(runID: UUID(), toolCallID: "native-science-fixture", approvalGrantID: UUID(),
            scope: record.remoteHostID.map(ToolScope.host) ?? .local,
            allowedToolNames: [ChemistryEnvironmentTool.name, "jobs.submit", "exec.shell"],
            workspaceRootURL: workspace, cancellation: CancellationToken(), environmentID: record.id,
            executionBindingGeneration: 7, conversationID: taskID)
        context.executionToolName = ChemistryEnvironmentTool.name
        return Fixture(root: root, workspace: workspace, registry: registry,
            coordinator: EnvironmentExecutionCoordinator(roots: roots, registry: registry), record: record, context: context)
    }

    @Test("Native routing stays native while scientific preparation resolves the selected task lease")
    func nativeScienceResolvesOnlyItsSelectedTaskEnvironment() async throws {
        for backend in [EnvironmentExecutionBackend.linuxVM, .remoteSSH] {
            let f = try await fixture(backend: backend)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let originalIDs = await f.registry.all().map(\.id).sorted()
            // This is the actual source failure: the ordinary native route
            // intentionally retains the run's ID but has no resolved object.
            let native = try await f.coordinator.acquire(f.context)
            #expect(native.context.environmentID == f.record.id)
            #expect(native.context.environment == nil)
            #expect(await f.coordinator.activeLeaseCount(environmentID: f.record.id) == 0)
            await native.finish()

            let selected = try await f.coordinator.acquireSelectedTaskEnvironment(f.context)
            #expect(selected.context.environment?.id == f.record.id)
            #expect(selected.backend == backend)
            #expect(selected.context.executionToolName == ChemistryEnvironmentTool.name)
            #expect(selected.context.runID == f.context.runID)
            #expect(selected.context.conversationID == f.context.conversationID)
            #expect(selected.context.toolCallID == f.context.toolCallID)
            #expect(selected.context.approvalGrantID == f.context.approvalGrantID)
            #expect(selected.context.scope == f.context.scope)
            #expect(selected.context.allowedToolNames == f.context.allowedToolNames)
            #expect(selected.context.executionBindingGeneration == f.context.executionBindingGeneration)
            #expect(selected.context.workspaceRootURL == f.workspace)
            #expect(await f.coordinator.activeLeaseCount(environmentID: f.record.id) == 1)
            #expect(await f.coordinator.fenceMigrationIfIdle(environmentID: f.record.id) == false)
            await selected.finish()
            #expect(await f.coordinator.activeLeaseCount(environmentID: f.record.id) == 0)
            #expect(await f.registry.all().map(\.id).sorted() == originalIDs)
        }
    }

    @Test("Scientific resolution preserves selection, ownership, cancellation and lifecycle fences")
    func selectedScienceEnvironmentRetainsOwnershipAndLifecycleFences() async throws {
        let f = try await fixture(backend: .linuxVM)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let originalIDs = await f.registry.all().map(\.id).sorted()
        var missing = f.context; missing.environmentID = nil
        var unknown = f.context; unknown.environmentID = "missing-science-fixture"
        var foreign = f.context; foreign.conversationID = UUID()
        // A caller's labels cannot turn another task's selection into a grant.
        foreign.environment = ToolEnvironment(id: f.record.id, writableLayerURL: f.workspace,
            layerURLs: [f.workspace], variables: ["FLOE_EXECUTION_BACKEND": "linuxVM"])
        var wrongHost = f.context; wrongHost.scope = .host(UUID())
        var readOnly = f.context; readOnly.temporaryReadOnly = true
        for rejected in [missing, unknown, foreign, wrongHost, readOnly] {
            await #expect(throws: (any Error).self) {
                _ = try await f.coordinator.acquireSelectedTaskEnvironment(rejected)
            }
        }
        var wrongWorkspace = f.context
        wrongWorkspace.environmentID = try #require(f.record.parentID)
        wrongWorkspace.workspaceRootURL = f.root.appendingPathComponent("AnotherWorkspace")
        await #expect(throws: (any Error).self) {
            _ = try await f.coordinator.acquireSelectedTaskEnvironment(wrongWorkspace)
        }
        #expect(await f.registry.all().map(\.id).sorted() == originalIDs)
        #expect(await f.coordinator.activeLeaseCount(environmentID: f.record.id) == 0)

        #expect(await f.coordinator.fenceMigrationIfIdle(environmentID: f.record.id))
        await #expect(throws: (any Error).self) {
            _ = try await f.coordinator.acquireSelectedTaskEnvironment(f.context)
        }
        await f.coordinator.releaseMigrationFence(environmentID: f.record.id)
        try await f.registry.transition(id: f.record.id, state: .stopped)
        await #expect(throws: (any Error).self) {
            _ = try await f.coordinator.acquireSelectedTaskEnvironment(f.context)
        }
        try await f.registry.transition(id: f.record.id, state: .active)
        try await f.registry.markRebuild(id: f.record.id, reason: "fixture-rebuild")
        await #expect(throws: (any Error).self) {
            _ = try await f.coordinator.acquireSelectedTaskEnvironment(f.context)
        }
        try await f.registry.clearRebuild(id: f.record.id)
        var cancelled = f.context; cancelled.cancellation = CancellationToken(); cancelled.cancellation.cancel()
        await #expect(throws: (any Error).self) {
            _ = try await f.coordinator.acquireSelectedTaskEnvironment(cancelled)
        }
        _ = try await f.registry.beginRuntimeReset(id: UUID().uuidString)
        await #expect(throws: (any Error).self) {
            _ = try await f.coordinator.acquireSelectedTaskEnvironment(f.context)
        }
        #expect(await f.coordinator.activeLeaseCount(environmentID: f.record.id) == 0)
        #expect(await f.registry.all().map(\.id).sorted() == originalIDs)
    }
}
#endif
