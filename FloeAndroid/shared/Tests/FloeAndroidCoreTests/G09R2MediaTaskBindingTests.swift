// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 trusted task/project association tests (job-385365036e904fb1).
//
// SOURCE-AUTHORED, focused deterministic tests. They use a temporary explicit
// root, an in-memory database and the real accepted creative/media hosts. They
// do NOT execute the Kotlin renderer, Compose UI, JNI or a device; those remain
// Main gates. The tests exercise the actual binding CAS, runtime-authority
// read-only pin, exact environment/workspace matching, revoke/delete refusal,
// original single-use grant and the normalized capability answer.
import XCTest
import Foundation
import GRDB
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeAndroidWorkbench

final class G09R2MediaTaskBindingTests: XCTestCase {
    private var roots: [URL] = []
    private var database: DatabaseManager?
    private var mailbox: G09R2MediaRenderHostMailbox!
    private var service: G09CreativeDomainService!
    private var cluster: G09R2BoundCluster!
    private var proposals: G09R2MediaToolProposalStore!
    private var grants: G09R2MediaToolGrants!
    private var conversationStore: SQLiteConversationStore!
    private var workspaceStore: SQLiteWorkspaceStore!
    private var conversationID: UUID!
    private var workspaceID: UUID!
    private var epoch: UInt64 = 0
    private var authorityStore: RuntimeAuthorityStore!

    override func tearDown() async throws {
        if let mailbox, epoch > 0 {
            _ = mailbox.prepareRootStop(epoch: epoch)
        }
        G09R2SnapshotLeases.shared.retire(epoch: epoch)
        if let service, epoch > 0 {
            _ = await service.close(epoch: epoch)
        }
        G09R2MediaToolAvailability.shared.resetForTesting()
        if let database { try? await database.close() }
        database = nil
        mailbox = nil
        service = nil
        cluster = nil
        proposals = nil
        grants = nil
        conversationStore = nil
        workspaceStore = nil
        authorityStore = nil
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixture

    private func makeFixture() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-media-binding-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        database = manager
        workspaceStore = SQLiteWorkspaceStore(database: manager)
        conversationStore = SQLiteConversationStore(database: manager)
        let root = try XCTUnwrap(RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
        conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "Media Binding Task",
            createdAt: Date(), updatedAt: Date()))
        workspaceID = UUID()
        try await workspaceStore.saveWorkspace(WorkspaceRecord(
            id: workspaceID, name: "Media Binding Task", rootBookmark: Data(),
            kind: .privateTask,
            internalRelativePath: "PrivateTasks/\(workspaceID.uuidString)"))
        try await workspaceStore.assignConversation(
            workspaceID: workspaceID, conversationID: conversationID)

        mailbox = G09R2MediaRenderHostMailbox()
        service = G09CreativeDomainService()
        epoch = UInt64.random(in: 50_000...900_000)
        let context = G09CreativeStorageContext(
            root: root, database: manager, workspaceStore: workspaceStore,
            conversationStore: conversationStore)
        _ = try await service.bind(epoch: epoch, storage: context)
        let boundCluster = await service.r2BoundCluster()
        cluster = try XCTUnwrap(boundCluster)
        XCTAssertTrue(mailbox.bind(epoch: epoch))
        XCTAssertTrue(mailbox.consumerHeartbeat(epoch: epoch))
        proposals = G09R2MediaToolProposalStore()
        grants = G09R2MediaToolGrants(
            service: service, mailbox: mailbox, proposals: proposals)
        authorityStore = RuntimeAuthorityStore()
    }

    private func taskContext() async throws
        -> G09R2MediaTaskBindingCoordinator.TaskContext {
        try await G09R2MediaTaskBindingCoordinator.resolveTask(
            service: service, cluster: cluster, conversationID: conversationID)
    }

    private func createStandaloneProject(name: String = "Standalone") async throws
        -> MediaProject {
        let created = try await cluster.media.create(
            name: name, kind: .image, width: 640, height: 480, frameRate: nil,
            storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        return created.project
    }

    private func createWorkspaceEditCopyProject(name: String = "Document copy") async throws
        -> MediaProject {
        let created = try await cluster.media.create(
            name: name, kind: .image, width: 640, height: 480, frameRate: nil,
            storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .workspace, ownerID: workspaceID))
        return created.project
    }

    private func select(_ projectID: UUID,
                        taskID: UUID? = nil,
                        expectedRevision: Int64? = nil,
                        opID: String = "select-\(UUID().uuidString.lowercased())")
        async throws -> G09R2MediaTaskBindingRecord {
        try await G09R2MediaTaskBindingCoordinator.select(
            service: service,
            request: G09R2MediaTaskSelectionRequest(
                selectionOpID: opID,
                projectID: projectID,
                taskID: taskID ?? conversationID,
                expectedRevision: expectedRevision,
                replaceExisting: false))
    }

    private func makeScope(
        projectID: UUID,
        environmentID: String?,
        workspaceRoot: URL,
        temporary: Bool = false,
        action: MediaProjectAction = .read
    ) async throws -> G09R2MediaToolCallContext {
        let data = try JSONSerialization.data(withJSONObject: [
            "action": action.rawValue,
            "project_id": projectID.uuidString,
        ], options: [.sortedKeys])
        let args = try JSONDecoder().decode(MediaProjectArguments.self, from: data)
        var context = ToolContext(
            runID: UUID(),
            toolCallID: "call-\(UUID().uuidString.lowercased())",
            toolIdempotencyKey: "idem-\(UUID().uuidString.lowercased())",
            approvalGrantID: UUID(),
            workspaceRootURL: workspaceRoot,
            cancellation: CancellationToken(),
            environmentID: environmentID,
            conversationID: conversationID,
            temporaryReadOnly: temporary)
        let scope = G09R2MediaToolCallContext(
            projectID: projectID, arguments: args, context: context,
            authorityStore: authorityStore)
        let binding = try scope.runtimeAuthorityBinding()
        let authority = await authorityStore.issue(RuntimeAuthorityEvidence(
            runID: binding.runID,
            taskID: binding.taskID,
            environmentBinding: binding.environmentBinding,
            canonicalTarget: binding.canonicalTarget,
            toolName: binding.toolName,
            operation: binding.operation,
            operationID: binding.operationID,
            idempotencyKey: binding.idempotencyKey,
            baseRevision: binding.baseRevision,
            payloadDigest: binding.payloadDigest,
            approvalGrantID: UUID()))
        context.runtimeAuthority = authority
        return G09R2MediaToolCallContext(
            projectID: projectID, arguments: args, context: context,
            authorityStore: authorityStore)
    }

    private func access(task: G09R2MediaTaskBindingCoordinator.TaskContext,
                        environmentID: String?) -> MediaProjectAccess {
        MediaProjectAccess(
            environmentID: environmentID,
            workspacePath: task.workspaceRoot.path,
            ownerKind: "chat",
            ownerID: conversationID)
    }

    private func host(_ call: G09R2MediaToolCallContext) -> G09R2MediaProjectToolHost {
        G09R2MediaProjectToolHost(
            service: service, mailbox: mailbox, proposals: proposals,
            grants: grants, config: G09R2MediaToolHostConfig(
                exportAwaitSeconds: 5, exportPollMillis: 50),
            call: call)
    }

    // MARK: - Explicit selection / first-call pin

    func testStandaloneProjectSelectionPinsExactTaskEnvironmentAndWorkspace() async throws {
        try await makeFixture()
        let project = try await createStandaloneProject()
        let record = try await select(project.id, expectedRevision: 0)
        XCTAssertEqual(record.state, .pending)
        XCTAssertEqual(record.storageKind, .appOwned)
        XCTAssertEqual(record.taskID, conversationID)

        let task = try await taskContext()
        let scope = try await makeScope(
            projectID: project.id, environmentID: "env-run-a",
            workspaceRoot: task.workspaceRoot)
        let scoped = host(scope)
        try await scoped.authorizeAccess(
            projectID: project.id, access: access(task: task, environmentID: "env-run-a"))
        let loadedProject = try await scoped.loadProject(id: project.id)
        let loaded = try XCTUnwrap(loadedProject)
        XCTAssertEqual(loaded.id, project.id)

        let storeOptional = await service.r2TaskBindingStore()
        let store = try XCTUnwrap(storeOptional)
        let active = try await store.active(projectID: project.id)
        let pinned = try XCTUnwrap(active)
        XCTAssertEqual(pinned.state, .pinned)
        XCTAssertEqual(pinned.environmentMode, "explicit")
        XCTAssertEqual(pinned.environmentID, "env-run-a")
        XCTAssertEqual(pinned.workspaceRootDigest,
                       G09R2MediaTaskBindingCoordinator.pathDigest(task.workspaceRoot.path))
    }

    /// G09-R2: the durable association is the ONE source of the model's
    /// data-only task context. It names the exact connected project for the
    /// exact task, disappears on revoke, and is scoped to its own task.
    func testTaskContextNamesTheExactConnectedProjectAndDisappearsOnRevoke() async throws {
        try await makeFixture()
        let project = try await createStandaloneProject()
        _ = try await select(project.id)
        let notes = await service.r2MediaTaskContext(taskID: conversationID)
        XCTAssertEqual(notes.count, 1)
        let line = try XCTUnwrap(notes.first)
        XCTAssertTrue(line.contains(project.id.uuidString.lowercased()))
        XCTAssertTrue(line.contains("pending its first authorized call"))
        XCTAssertTrue(line.contains("reference data, not permission"))
        let others = await service.r2MediaTaskContext(taskID: UUID())
        XCTAssertTrue(others.isEmpty)

        let storeOptional = await service.r2TaskBindingStore()
        let store = try XCTUnwrap(storeOptional)
        _ = try await store.revoke(projectID: project.id, bindingID: nil,
                                   taskID: conversationID)
        let revoked = await service.r2MediaTaskContext(taskID: conversationID)
        XCTAssertTrue(revoked.isEmpty)
    }

    /// Two same-display-name projects and a reselection: the context names
    /// the ONE exact explicit selection (the later reselected project), never
    /// the earlier association or a timestamp guess.
    func testTaskContextFollowsTheExactExplicitSelection() async throws {
        try await makeFixture()
        let first = try await createStandaloneProject(name: "Poster")
        let second = try await createStandaloneProject(name: "Poster")

        _ = try await select(first.id, opID: "select-first")
        let firstNotes = await service.r2MediaTaskContext(taskID: conversationID)
        XCTAssertEqual(firstNotes.count, 1)
        XCTAssertTrue(firstNotes[0].contains(first.id.uuidString.lowercased()))

        _ = try await select(second.id, opID: "select-second")
        let secondNotes = await service.r2MediaTaskContext(taskID: conversationID)
        XCTAssertEqual(secondNotes.count, 1)
        XCTAssertTrue(secondNotes[0].contains(second.id.uuidString.lowercased()))
        XCTAssertFalse(secondNotes[0].contains(first.id.uuidString.lowercased()),
                       "an older association must not be presented as current")

        // Reselect the FIRST project with a NEW explicit operation: the
        // durable selection marker moves even though the association itself
        // (and therefore its authority) is unchanged.
        let reselected = try await select(first.id, opID: "select-first-again")
        XCTAssertEqual(reselected.state, .pending)
        let again = await service.r2MediaTaskContext(taskID: conversationID)
        XCTAssertEqual(again.count, 1)
        XCTAssertTrue(again[0].contains(first.id.uuidString.lowercased()),
                      "the reselected older project must be the current context")
        XCTAssertFalse(again[0].contains(second.id.uuidString.lowercased()))
    }

    /// The task context belongs to ONE accepted generation: a Root stop or an
    /// unbind advertises nothing, so a replacement run can never inherit the
    /// retired generation's connected-project note.
    func testTaskContextStopsAtRootStopAndUnbind() async throws {
        try await makeFixture()
        let project = try await createStandaloneProject()
        _ = try await select(project.id)
        let live = await service.r2MediaTaskContext(taskID: conversationID)
        XCTAssertEqual(live.count, 1)
        XCTAssertTrue(live[0].contains(project.id.uuidString.lowercased()))

        _ = await service.r2BeginRootStop(epoch: epoch)
        let stopping = await service.r2MediaTaskContext(taskID: conversationID)
        XCTAssertTrue(stopping.isEmpty,
                      "a stopping generation must not advertise task context")

        _ = await service.close(epoch: epoch)
        let unbound = await service.r2MediaTaskContext(taskID: conversationID)
        XCTAssertTrue(unbound.isEmpty,
                      "an unbound generation must not advertise task context")
    }

    /// A run-context read must never create the additive table as a side
    /// effect: an ordinary database that never used Ask AI stays untouched.
    func testTaskContextReadDoesNotCreateTheBindingTable() async throws {
        try await makeFixture()
        let database = try XCTUnwrap(self.database)
        let store = G09R2MediaTaskBindingStore(database: database)
        let selection = try await store.currentSelection(taskID: conversationID)
        XCTAssertNil(selection)
        let exists = try await database.reader { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type = 'table' AND name = 'g09_media_task_bindings'
                    """) ?? 0
        }
        XCTAssertEqual(exists, 0, "the read-only task-context lookup must not create the table")
    }

    func testWorkspaceEditCopyWithOmittedEnvironmentIsUsableOnlyThroughPin() async throws {
        try await makeFixture()
        let project = try await createWorkspaceEditCopyProject()
        let record = try await select(project.id, expectedRevision: 0)
        XCTAssertEqual(record.projectOwnerKind, "workspace")
        XCTAssertNil(record.recordedEnvironment)

        // The legacy exact-provenance path refuses the omitted environment
        // when the runtime has a real environment. The explicit association
        // is the only route that may pin it.
        let task = try await taskContext()
        let legacyAccess = access(task: task, environmentID: "env-run-doc")
        let legacy = G09R2MediaProjectToolHost(
            service: service, mailbox: mailbox, proposals: proposals, grants: grants)
        do {
            try await legacy.authorizeAccess(projectID: project.id, access: legacyAccess)
            XCTFail("legacy provenance-only access must not accept a nil recorded environment")
        } catch {
            // expected typed refusal
        }

        let scope = try await makeScope(
            projectID: project.id, environmentID: "env-run-doc",
            workspaceRoot: task.workspaceRoot)
        let scoped = host(scope)
        try await scoped.authorizeAccess(projectID: project.id, access: legacyAccess)
        let loadedProject = try await scoped.loadProject(id: project.id)
        XCTAssertEqual(try XCTUnwrap(loadedProject).id, project.id)
        let storeOptional = await service.r2TaskBindingStore()
        let store = try XCTUnwrap(storeOptional)
        let active = try await store.active(projectID: project.id)
        let pinned = try XCTUnwrap(active)
        XCTAssertEqual(pinned.state, .pinned)
        XCTAssertEqual(pinned.environmentID, "env-run-doc")
    }

    func testCrossTaskEnvironmentAndWorkspaceAreRefusedAfterPin() async throws {
        try await makeFixture()
        let project = try await createStandaloneProject()
        _ = try await select(project.id)
        let task = try await taskContext()
        let first = try await makeScope(
            projectID: project.id, environmentID: "env-run-a",
            workspaceRoot: task.workspaceRoot)
        try await host(first).authorizeAccess(
            projectID: project.id, access: access(task: task, environmentID: "env-run-a"))

        let wrongEnvironment = try await makeScope(
            projectID: project.id, environmentID: "env-run-b",
            workspaceRoot: task.workspaceRoot)
        do {
            try await host(wrongEnvironment).authorizeAccess(
                projectID: project.id, access: access(task: task, environmentID: "env-run-b"))
            XCTFail("a different environment must not reuse the pinned association")
        } catch {
            XCTAssertEqual(error as? FloeError, .unauthorized)
        }

        let wrongWorkspace = try await makeScope(
            projectID: project.id, environmentID: "env-run-a",
            workspaceRoot: FileManager.default.temporaryDirectory)
        do {
            try await host(wrongWorkspace).authorizeAccess(
                projectID: project.id,
                access: MediaProjectAccess(
                    environmentID: "env-run-a",
                    workspacePath: FileManager.default.temporaryDirectory.path,
                    ownerKind: "chat", ownerID: conversationID))
            XCTFail("a different workspace must not reuse the pinned association")
        } catch {
            XCTAssertEqual(error as? FloeError, .unauthorized)
        }
    }

    func testTemporaryContextAndForgedStoragePathAreRefused() async throws {
        try await makeFixture()
        let project = try await createStandaloneProject()
        _ = try await select(project.id)
        let task = try await taskContext()
        let temporary = try await makeScope(
            projectID: project.id, environmentID: "env-run-a",
            workspaceRoot: task.workspaceRoot, temporary: true)
        do {
            try await host(temporary).authorizeAccess(
                projectID: project.id, access: access(task: task, environmentID: "env-run-a"))
            XCTFail("temporary chat must not authorize media.project")
        } catch {
            XCTAssertEqual(error as? FloeError, .unauthorized)
        }

        let url = URL(fileURLWithPath: cluster.media.projectDirectoryPath,
                      isDirectory: true)
            .appendingPathComponent(MediaProjectStore.projectFileName(id: project.id))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        object["taskWorkspacePath"] = "/tmp/forged-media-root"
        let forged = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try forged.write(to: url)
        do {
            _ = try await select(project.id,
                                 opID: "select-\(UUID().uuidString.lowercased())")
            XCTFail("a forged recorded path must not select storage")
        } catch let failure as G09R2MediaTaskBindingFailure {
            XCTAssertTrue(failure == .storageUnresolved || failure == .projectGone)
        }
        XCTAssertEqual(try Data(contentsOf: url), forged)
    }

    func testRevokeAndDeletedTaskCannotReuseTheAssociation() async throws {
        try await makeFixture()
        let project = try await createStandaloneProject()
        let record = try await select(project.id)
        let storeOptional = await service.r2TaskBindingStore()
        let store = try XCTUnwrap(storeOptional)
        let revoked = try await store.revoke(
            projectID: project.id, bindingID: record.bindingID, taskID: nil)
        XCTAssertTrue(revoked)
        let task = try await taskContext()
        let scope = try await makeScope(
            projectID: project.id, environmentID: "env-run-a",
            workspaceRoot: task.workspaceRoot)
        do {
            try await host(scope).authorizeAccess(
                projectID: project.id, access: access(task: task, environmentID: "env-run-a"))
            XCTFail("a revoked association must not authorize a standalone project")
        } catch {
            // expected typed refusal
        }

        // A real task deletion cascades the association in the same DB.
        let second = try await createStandaloneProject(name: "Deleted task")
        _ = try await select(second.id,
                             opID: "select-\(UUID().uuidString.lowercased())")
        try await conversationStore.deleteConversation(id: conversationID)
        let afterDelete = try await store.active(projectID: second.id)
        XCTAssertNil(afterDelete)
    }

    func testPinnedAssociationIssuesTheOriginalSingleUseGrantOnce() async throws {
        try await makeFixture()
        let project = try await createStandaloneProject()
        _ = try await select(project.id)
        let task = try await taskContext()
        let scope = try await makeScope(
            projectID: project.id, environmentID: "env-run-a",
            workspaceRoot: task.workspaceRoot, action: .propose)
        let scoped = host(scope)
        try await scoped.authorizeAccess(
            projectID: project.id, access: access(task: task, environmentID: "env-run-a"))
        var layer = ImageLayer(kind: .text, name: "Title")
        layer.text = ImageTextContent(text: "Hello")
        let proposal = MediaProposal(
            projectID: project.id, baseRevision: 0,
            summary: "Add title", commands: [.addImageLayer(layer)])
        try await scoped.storeProposal(proposal)

        let grant = try await G09R2MediaTaskBindingCoordinator.issueGrant(
            service: service, grants: grants, proposals: proposals,
            request: G09R2MediaProjectGrantRequest(
                projectID: project.id, proposalID: proposal.id,
                revision: 0, taskID: conversationID))
        let first = await scoped.consumeGrant(
            grantID: grant, proposalID: proposal.id,
            projectID: project.id, revision: 0)
        XCTAssertEqual(first, .authorized)
        let second = await scoped.consumeGrant(
            grantID: grant, proposalID: proposal.id,
            projectID: project.id, revision: 0)
        XCTAssertEqual(second, .alreadyConsumed)
    }



    func testConcurrentFirstCallsPinExactlyOneEnvironment() async throws {
        try await makeFixture()
        let project = try await createStandaloneProject()
        _ = try await select(project.id)
        let task = try await taskContext()
        let first = try await makeScope(
            projectID: project.id, environmentID: "env-race-a",
            workspaceRoot: task.workspaceRoot)
        let second = try await makeScope(
            projectID: project.id, environmentID: "env-race-b",
            workspaceRoot: task.workspaceRoot)
        let firstHost = host(first)
        let secondHost = host(second)
        // Resolve the Sendable access values before spawning the child tasks:
        // the accessor reads test-instance state, which must not cross a
        // concurrent `async let` boundary.
        let firstAccess = access(task: task, environmentID: "env-race-a")
        let secondAccess = access(task: task, environmentID: "env-race-b")
        async let firstCall: Void = firstHost.authorizeAccess(
            projectID: project.id, access: firstAccess)
        async let secondCall: Void = secondHost.authorizeAccess(
            projectID: project.id, access: secondAccess)
        var successes = 0
        var failures = 0
        do { try await firstCall; successes += 1 } catch { failures += 1 }
        do { try await secondCall; successes += 1 } catch { failures += 1 }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(failures, 1)
        let storeOptional = await service.r2TaskBindingStore()
        let store = try XCTUnwrap(storeOptional)
        let active = try await store.active(projectID: project.id)
        let pinned = try XCTUnwrap(active)
        XCTAssertEqual(pinned.state, .pinned)
        XCTAssertTrue(["env-race-a", "env-race-b"].contains(pinned.environmentID ?? ""))
    }

    func testDifferentTaskCannotUseThePinnedAssociation() async throws {
        try await makeFixture()
        let project = try await createStandaloneProject()
        _ = try await select(project.id)
        let task = try await taskContext()
        let firstScope = try await makeScope(
            projectID: project.id, environmentID: "env-run-a",
            workspaceRoot: task.workspaceRoot)
        try await host(firstScope).authorizeAccess(
            projectID: project.id, access: access(task: task, environmentID: "env-run-a"))

        let otherTask = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: otherTask, title: "Other task", createdAt: Date(), updatedAt: Date()))
        try await workspaceStore.assignConversation(
            workspaceID: workspaceID, conversationID: otherTask)
        var otherContext = ToolContext(
            runID: UUID(),
            toolCallID: "call-\(UUID().uuidString.lowercased())",
            toolIdempotencyKey: "idem-\(UUID().uuidString.lowercased())",
            approvalGrantID: UUID(),
            workspaceRootURL: task.workspaceRoot,
            cancellation: CancellationToken(),
            environmentID: "env-run-a",
            conversationID: otherTask)
        otherContext.runtimeAuthority = nil
        let otherScope = G09R2MediaToolCallContext(
            projectID: project.id, arguments: firstScope.arguments,
            context: otherContext, authorityStore: authorityStore)
        do {
            try await host(otherScope).authorizeAccess(
                projectID: project.id,
                access: MediaProjectAccess(
                    environmentID: "env-run-a",
                    workspacePath: task.workspaceRoot.path,
                    ownerKind: "chat", ownerID: otherTask))
            XCTFail("a different task must not reuse the project association")
        } catch {
            XCTAssertEqual(error as? FloeError, .unauthorized)
        }
    }

    func testCapabilityAnswerIsOneTruthfulSubset() async throws {
        try await makeFixture()
        let project = try await createStandaloneProject()
        _ = try await select(project.id)
        let task = try await taskContext()
        let scope = try await makeScope(
            projectID: project.id, environmentID: "env-run-a",
            workspaceRoot: task.workspaceRoot, action: .capabilities)
        let scoped = host(scope)
        try await scoped.authorizeAccess(
            projectID: project.id, access: access(task: task, environmentID: "env-run-a"))
        let text = try XCTUnwrap(scoped.normalizedCapabilityText())
        XCTAssertTrue(text.contains("merge_layers: unsupported"))
        XCTAssertTrue(text.contains("copy_selection: unsupported"))
        XCTAssertTrue(text.contains("image_export_formats: png, jpeg"))
        XCTAssertFalse(text.contains("heic (alpha)"))
        XCTAssertFalse(text.contains("user_confirm(grant) -> apply"))
    }
}
