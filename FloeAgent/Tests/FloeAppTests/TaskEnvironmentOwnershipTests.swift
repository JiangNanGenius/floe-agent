import Foundation
import Testing
import FloeCore
import FloeEnvironments
import FloeTools
import FloeModels
import FloePersistence

@Suite("Task environment migration ownership")
struct TaskEnvironmentOwnershipTests {
    @Test func idleFenceJoinsOwnersAndKeepsNativeToolsAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let roots = EnvironmentRoots(rootURL: root.appendingPathComponent("environments"))
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "fixture")
        let conversation = UUID()
        let workspaceID = FloeDigest.sha256Hex(Data(workspace.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
        let record = try await registry.ensureRemoteSessionContainer(conversationID: conversation.uuidString,
            workspaceID: workspaceID, workspaceRootPath: workspace.path, hostID: UUID(),
            remoteRootPath: "/home/floe/.floe/tasks/fixture", operatingSystem: "linux", architecture: "aarch64",
            distribution: "debian", runtimeGeneration: "boot-1")
        let coordinator = EnvironmentExecutionCoordinator(roots: roots, registry: registry)
        let lease = try await coordinator.acquireManagement(environmentID: record.id, cancellation: CancellationToken())
        #expect(await coordinator.activeLeaseCount(environmentID: record.id) == 1)
        #expect(await coordinator.fenceMigrationIfIdle(environmentID: record.id) == false)
        await lease.finish()
        #expect(await coordinator.fenceMigrationIfIdle(environmentID: record.id))
        await #expect(throws: (any Error).self) {
            _ = try await coordinator.acquireManagement(environmentID: record.id, cancellation: CancellationToken())
        }
        await #expect(throws: (any Error).self) { try await coordinator.stopAndWait(environmentID: record.id) }
        var native = ToolContext(runID: UUID(), workspaceRootURL: workspace,
            cancellation: CancellationToken(), environmentID: record.id)
        native.executionToolName = "web.search"
        let nativeLease = try await coordinator.acquire(native)
        #expect(nativeLease.context.environment == nil)
        #expect(await coordinator.activeLeaseCount(environmentID: record.id) == 0)
        await nativeLease.finish()
        await coordinator.releaseMigrationFence(environmentID: record.id)
        let next = try await coordinator.acquireManagement(environmentID: record.id, cancellation: CancellationToken())
        #expect(next.context.environment?.variables["FLOE_EXECUTION_BACKEND"] == "remoteSSH")
        #expect(next.context.environment?.variables["HOME"] == nil)
        await next.finish()
    }

    @Test func migratedSessionNeverReplacesPreviousIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = EnvironmentRegistry(roots: EnvironmentRoots(rootURL: root), baseRevision: "fixture")
        let owner = UUID().uuidString
        let first = try await registry.ensureMacBridgeSessionContainer(conversationID: owner,
            workspaceID: "work", workspaceRootPath: "/fixture")
        let staging = try await registry.ensureMacBridgeSessionContainer(conversationID: owner,
            workspaceID: "work", workspaceRootPath: "/fixture", forceNew: true)
        #expect(first.id != staging.id)
        #expect(await registry.record(id: first.id)?.state == .active)
        #expect(await registry.record(id: first.id)?.effectiveExecutionBackend == .macBridge)
        let restored = EnvironmentRegistry(roots: EnvironmentRoots(rootURL: root), baseRevision: "fixture")
        try await restored.prepare()
        #expect(await restored.record(id: first.id)?.id == first.id)
        #expect(await restored.record(id: staging.id)?.id == staging.id)
    }
    @Test func uncertainPreparationCannotCommitOrBeClearedByStaleState() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversation = UUID()
        try await SQLiteConversationStore(database: database).saveConversation(.init(id: conversation,
            title: "Preparation ownership", createdAt: Date(), updatedAt: Date()))
        let store = TaskExecutionBindingStore(database: database)
        let source = try await store.bindInitial(.init(conversationID: conversation,
            target: .init(environmentID: "source", backend: .linuxVM, operatingSystem: "linux", architecture: "riscv64")))
        var value = TaskEnvironmentMigration(source: source,
            target: .init(environmentID: "target", backend: .remoteSSH, remoteHostID: UUID(),
                remoteRootPath: "/home/floe/.floe/tasks/fixture", operatingSystem: "linux", architecture: "arm64"))
        try await store.begin(value)
        try await store.recordPreparationOutcomeUnknown(conversationID: conversation, targetEnvironmentID: "another-target")
        #expect(try await store.activeMigration(conversationID: conversation)?.preparationOutcomeUnknown != true)
        try await store.recordPreparationOutcomeUnknown(conversationID: conversation, targetEnvironmentID: "target")
        value = try #require(try await store.activeMigration(conversationID: conversation))
        #expect(value.preparationOutcomeUnknown == true)
        value.preparationOutcomeUnknown = false
        value.phase = .failed
        value = try await store.update(value, expectedRevision: value.revision)
        #expect(value.preparationOutcomeUnknown == true)
        value.phase = .verified
        value.manifestDigest = String(repeating: "a", count: 64)
        value.dependencyReceiptDigest = String(repeating: "b", count: 64)
        value.skillDigests = [:]
        value = try await store.update(value, expectedRevision: value.revision)
        await #expect(throws: (any Error).self) { _ = try await store.commit(value) }
        #expect(try await store.binding(conversationID: conversation)?.target.environmentID == "source")
    }

}
