import Foundation
import Testing
import FloeCore
import FloeEnvironments
import FloeTools
import FloeModels
import FloePersistence
#if canImport(UIKit)
@testable import FloeApp
#endif

@Suite("Task environment migration ownership")
struct TaskEnvironmentOwnershipTests {

#if canImport(UIKit)
    @MainActor @Test("A saved Linux pin loads the cold registry without starting or replacing its environment")
    func savedLinuxPinLoadsColdRegistry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let roots = EnvironmentRoots(rootURL: root.appendingPathComponent("environments"))
        let original = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        let owner = FloeDigest.sha256Hex(Data(workspace.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
        let record = try await original.ensureProjectContainer(workspaceID: owner, workspaceRootPath: workspace.path)
        let dependency = roots.layerURL(id: record.id, kind: record.kind).appendingPathComponent("retained-dependency")
        try Data("installed once".utf8).write(to: dependency)
        let saved = TaskExecutionTarget(environmentID: record.id, backend: .linuxVM,
            operatingSystem: "linux", architecture: "arm64")
        let originalIDs = await original.all().map(\.id).sorted()
        let cold = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        #expect(await cold.record(id: record.id) == nil)
        try await TaskExecutionEnvironmentCenter.validateSavedTarget(saved, registry: cold)
        #expect(await cold.record(id: record.id)?.ownerID == owner)
        #expect(await cold.all().map(\.id).sorted() == originalIDs)
        #expect(try await cold.ownsExecutionLocation(containerID: record.id, conversationID: UUID(), taskRoot: workspace))
        #expect(try Data(contentsOf: dependency) == Data("installed once".utf8))
        // This performs metadata restoration only: no runtime service or
        // replacement target participates in restoring the saved pin.
        try await TaskExecutionEnvironmentCenter.validateSavedTarget(saved, registry: cold)
    }

    @MainActor @Test("Loading a saved pin retains missing, incompatible and rebuild validation")
    func coldSavedPinDoesNotBypassUnavailableTargets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root.appendingPathComponent("environments"))
        let original = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        try await original.prepare()
        let id = EnvironmentRegistry.sharedContainerID
        let wrong = TaskExecutionTarget(environmentID: id, backend: .linuxVM,
            operatingSystem: "linux", architecture: "x86_64")
        let cold = EnvironmentRegistry(roots: roots, baseRevision: "arm64")
        await #expect(throws: TaskExecutionAvailabilityError.self) {
            try await TaskExecutionEnvironmentCenter.validateSavedTarget(wrong, registry: cold)
        }
        var missing = wrong
        missing.environmentID = "missing"
        await #expect(throws: TaskExecutionAvailabilityError.self) {
            try await TaskExecutionEnvironmentCenter.validateSavedTarget(missing, registry: cold)
        }
        var valid = wrong
        valid.architecture = "arm64"
        let changedABI = EnvironmentRegistry(roots: roots, baseRevision: "different-ABI")
        await #expect(throws: TaskExecutionAvailabilityError.self) {
            try await TaskExecutionEnvironmentCenter.validateSavedTarget(valid, registry: changedABI)
        }
        #expect(await changedABI.record(id: id)?.requiresRebuild == true)
    }
    @MainActor @Test("retaining rebuild rejects an old pin while allowing the explicitly chosen current generation")
    func residentGenerationIsAnExplicitSavedTargetBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resident-task-boundary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = EnvironmentRegistry(roots: .init(rootURL: root), baseRevision: "arm64")
        try await registry.prepare()
        let oldTarget = TaskExecutionTarget(environmentID: EnvironmentRegistry.sharedContainerID, backend: .linuxVM,
            operatingSystem: "linux", architecture: "arm64")
        let recovery = UUID()
        try await registry.reconcileResidentRuntimeGeneration(recoveryID: recovery)
        await #expect(throws: TaskExecutionAvailabilityError.self) {
            try await TaskExecutionEnvironmentCenter.validateSavedTarget(oldTarget, registry: registry)
        }
        var target = oldTarget
        target.runtimeGeneration = LinuxResidentRuntimeGeneration.value(recoveryID: recovery)
        try await TaskExecutionEnvironmentCenter.validateSavedTarget(target, registry: registry)
    }
#endif

    @Test func sharedProjectConfigurationRequiresTheLeasedTaskRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project"), other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let registry = EnvironmentRegistry(roots: .init(rootURL: root.appendingPathComponent("environments")), baseRevision: "fixture")
        let owner = FloeDigest.sha256Hex(Data(project.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
        let record = try await registry.ensureProjectContainer(workspaceID: owner, workspaceRootPath: project.path, executionBackend: .linuxVM)
        #expect(try await registry.ownsExecutionLocation(containerID: record.id, conversationID: UUID(), taskRoot: project))
        #expect(try await registry.ownsExecutionLocation(containerID: record.id, conversationID: UUID(), taskRoot: other) == false)
        #expect(try await registry.ownsExecutionLocation(containerID: "missing", conversationID: UUID(), taskRoot: project) == false)
        let taskID = UUID()
        let session = try await registry.ensureSessionContainer(conversationID: taskID.uuidString,
            workspaceID: owner, workspaceRootPath: project.path, executionBackend: .linuxVM)
        #expect(try await registry.ownsExecutionLocation(containerID: session.id, conversationID: taskID, taskRoot: project))
        #expect(try await registry.ownsExecutionLocation(containerID: session.id, conversationID: UUID(), taskRoot: project) == false)
    }

    @Test("The task pin survives an authorized working-folder change without giving another task its environment")
    func pinnedSessionFollowsTaskRatherThanOldWorkingFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), current = root.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let roots = EnvironmentRoots(rootURL: root.appendingPathComponent("environments"))
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "fixture")
        let owner = UUID()
        let record = try await registry.ensureSessionContainer(conversationID: owner.uuidString,
            workspaceID: FloeDigest.sha256Hex(Data(old.resolvingSymlinksInPath().standardizedFileURL.path.utf8)),
            workspaceRootPath: old.path, executionBackend: .linuxVM)
        let coordinator = EnvironmentExecutionCoordinator(roots: roots, registry: registry)
        var context = ToolContext(runID: UUID(), workspaceRootURL: current,
            cancellation: CancellationToken(), environmentID: record.id, conversationID: owner)
        context.executionToolName = "exec.shell"
        let lease = try await coordinator.acquire(context)
        #expect(lease.context.environmentID == record.id)
        #expect(lease.context.workspaceRootURL == current)
        await lease.finish()
        var foreign = context
        foreign.conversationID = UUID()
        await #expect(throws: (any Error).self) { _ = try await coordinator.acquire(foreign) }
        var unowned = context
        unowned.conversationID = nil
        await #expect(throws: (any Error).self) { _ = try await coordinator.acquire(unowned) }
        var project = context
        project.environmentID = record.parentID
        await #expect(throws: (any Error).self) { _ = try await coordinator.acquire(project) }
    }
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

    @Test func dispatchIntentSurvivesUntilEveryPreparationActuallyFinishes() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversation = UUID()
        try await SQLiteConversationStore(database: database).saveConversation(.init(id: conversation,
            title: "Preparation receipt", createdAt: Date(), updatedAt: Date()))
        let store = TaskExecutionBindingStore(database: database)
        let source = try await store.bindInitial(.init(conversationID: conversation,
            target: .init(environmentID: "source", backend: .linuxVM, operatingSystem: "linux", architecture: "riscv64")))
        var value = TaskEnvironmentMigration(source: source,
            target: .init(environmentID: "target", backend: .remoteSSH, remoteHostID: UUID(),
                remoteRootPath: "/home/floe/.floe/tasks/fixture", operatingSystem: "linux", architecture: "arm64"))
        try await store.begin(value)
        value.phase = .preparing
        value = try await store.update(value, expectedRevision: value.revision)
        let first = UUID(), second = UUID()
        #expect(try await store.beginPreparationOperation(conversationID: conversation, targetEnvironmentID: "target", operationID: first))
        #expect(try await store.beginPreparationOperation(conversationID: conversation, targetEnvironmentID: "target", operationID: second))
        try await store.endPreparationOperation(conversationID: conversation, targetEnvironmentID: "target", operationID: first)
        value = try #require(try await store.activeMigration(conversationID: conversation))
        #expect(value.preparationOperationIDs == [second])
        value.phase = .verified
        value.manifestDigest = String(repeating: "a", count: 64)
        value.dependencyReceiptDigest = String(repeating: "b", count: 64)
        value.skillDigests = [:]
        value = try await store.update(value, expectedRevision: value.revision)
        await #expect(throws: (any Error).self) { _ = try await store.commit(value) }
        #expect(try await store.binding(conversationID: conversation)?.target.environmentID == "source")
        try await store.endPreparationOperation(conversationID: conversation, targetEnvironmentID: "target", operationID: second)
        value = try #require(try await store.activeMigration(conversationID: conversation))
        value = try await store.commit(value)
        #expect(value.phase == .committed)
        #expect(try await store.binding(conversationID: conversation)?.target.environmentID == "target")
    }

}
