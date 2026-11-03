// SPDX-License-Identifier: MPL-2.0
//
// C01 project library — focused deterministic tests against the REAL
// DatabaseManager / workspaces table and the REAL managed-root filesystem
// shape. AUTHORED, NOT EXECUTED by the source-only lane. Inference,
// provider, App, APK and device behaviour are Main's separate gates.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
@testable import FloeAndroidCore

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 1_800_000_000

    func next() -> Date {
        lock.lock(); defer { lock.unlock() }
        seconds += 1
        return Date(timeIntervalSince1970: seconds)
    }
}

final class C01ProjectLibraryTests: XCTestCase {

    private actor RecordingLifecycle: ConversationDeletionLifecycle {
        var began: [UUID] = []
        var committed: [UUID] = []
        var aborted: [UUID] = []
        var failNextBegin: ConversationDeletionLifecycleFailure?

        func setFailNextBegin(_ failure: ConversationDeletionLifecycleFailure?) {
            failNextBegin = failure
        }

        func beginDeletionFence(conversationID: UUID, epoch: UInt64,
                                operationID: UUID) async throws
            -> ConversationDeletionFence {
            if let failure = failNextBegin {
                failNextBegin = nil
                throw failure
            }
            began.append(conversationID)
            return ConversationDeletionFence(
                conversationID: conversationID, epoch: epoch,
                operationID: operationID,
                authorityReceipt: "work:v1:test-\(operationID.uuidString)")
        }

        var drainCalls: [UUID] = []
        var drainFailure: ConversationDeletionLifecycleFailure?

        func setDrainFailure(_ failure: ConversationDeletionLifecycleFailure?) {
            drainFailure = failure
        }

        func drainOwnedWork(fence: ConversationDeletionFence) async throws
            -> ConversationQuiescenceReport {
            drainCalls.append(fence.conversationID)
            if let failure = drainFailure { throw failure }
            return ConversationQuiescenceReport()
        }

        func abortDeletionFence(_ fence: ConversationDeletionFence) async
            -> ConversationDeletionFenceSettlement {
            aborted.append(fence.conversationID)
            return .released
        }

        func commitDeletionFence(_ fence: ConversationDeletionFence) async
            -> ConversationDeletionFenceSettlement {
            committed.append(fence.conversationID)
            return .released
        }
    }

    private struct Fixture {
        let root: URL
        let database: DatabaseManager
        let cluster: G02OwnedStoreCluster
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c01-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let storage = RuntimeStorageRoot(validatingAbsoluteDirectory: root.path) else {
            throw FloeError.validationFailed("root")
        }
        let database = try DatabaseManager(path: storage.databaseURL)
        try await database.migrate()
        guard let identity = RuntimeOwnerIdentity(
            root: storage, token: "0123456789abcdef", epoch: 1) else {
            throw FloeError.validationFailed("identity")
        }
        let cluster = G02OwnedStoreCluster(
            identity: identity, database: database,
            conversationStore: SQLiteConversationStore(database: database),
            runStore: SQLiteRunStore(database: database),
            runningInputStore: SQLiteRunningInputStore(database: database),
            childRunStore: SQLiteChildRunStore(database: database),
            runLaunchStore: SQLiteRunLaunchStore(database: database),
            modelConfigurationStore: ModelConfigurationStore(database: database),
            workspaceStore: SQLiteWorkspaceStore(database: database),
            settingsStore: SQLiteSettingsStore(database: database),
            skillStore: SQLiteSkillStore(database: database),
            checkpointStore: FileCheckpointStore(directory: storage.checkpointDirectoryURL))
        do {
            try await body(Fixture(root: root, database: database, cluster: cluster))
            try await database.close()
            try? FileManager.default.removeItem(at: root)
        } catch {
            try? await database.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func library(_ fixture: Fixture,
                         lifecycle: RecordingLifecycle) -> C01ProjectLibrary {
        let clock = TestClock()
        return C01ProjectLibrary(epoch: 1, cluster: fixture.cluster,
                                 lifecycleProvider: { lifecycle },
                                 liveCheck: { true },
                                 now: { clock.next() })
    }

    private func fixedClockLibrary(_ fixture: Fixture,
                                   lifecycle: RecordingLifecycle) -> C01ProjectLibrary {
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        return C01ProjectLibrary(epoch: 1, cluster: fixture.cluster,
                                 lifecycleProvider: { lifecycle },
                                 liveCheck: { true },
                                 now: { fixed })
    }

    // MARK: - Create/list/rename/managed-root authority

    func testCreateListRenameExactCASAndMissingRootIsNeverRecreated() async throws {
        try await withFixture { fixture in
            let lifecycle = RecordingLifecycle()
            let projects = library(fixture, lifecycle: lifecycle)
            let created = try await projects.create(name: "  Alpha  ")
            XCTAssertEqual(created.name, "Alpha")
            XCTAssertEqual(created.taskCount, 0)

            let expectedRoot = C01ProjectRootLayout.projectDirectory(
                rootPath: fixture.root.path, projectID: created.id)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: expectedRoot, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
            let attributes = try FileManager.default.attributesOfItem(atPath: expectedRoot)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

            let row = try await fixture.cluster.workspaceStore.workspace(id: created.id)
            XCTAssertEqual(row?.kind, .project)
            XCTAssertEqual(row?.rootBookmark, Data())
            XCTAssertEqual(row?.internalRelativePath,
                           "Projects/\(created.id.uuidString)")

            let listed = try await projects.list()
            XCTAssertEqual(listed.map(\.id), [created.id])
            XCTAssertEqual(listed.first?.revision, created.revision)

            // Stale CAS writes nothing.
            do {
                _ = try await projects.rename(projectID: created.id, name: "Beta",
                                              expectedRevision: "stale")
                XCTFail("stale project rename succeeded")
            } catch C01ProjectError.staleRevision {
            }
            let unchanged = try await fixture.cluster.workspaceStore.workspace(id: created.id)
            XCTAssertEqual(unchanged?.name, "Alpha")

            let renamed = try await projects.rename(
                projectID: created.id, name: "Beta",
                expectedRevision: created.revision)
            XCTAssertEqual(renamed.name, "Beta")
            XCTAssertNotEqual(renamed.revision, created.revision)

            // A later missing leaf is reported, never materialized again.
            try FileManager.default.removeItem(atPath: expectedRoot)
            let detail = try await projects.get(projectID: created.id)
            XCTAssertEqual(detail.rootState, .missing)
            XCTAssertFalse(FileManager.default.fileExists(atPath: expectedRoot))
        }
    }

    func testCreateRejectsUnsafeNamesAndListsOnlyManagedProjects() async throws {
        try await withFixture { fixture in
            let lifecycle = RecordingLifecycle()
            let projects = library(fixture, lifecycle: lifecycle)
            for bad in ["", "   ", "../escape", "a/b", "a\\b", String(repeating: "x", count: 81)] {
                do {
                    _ = try await projects.create(name: bad)
                    XCTFail("unsafe project name accepted: \(bad)")
                } catch C01ProjectError.invalidName {
                }
            }
            let project = try await projects.create(name: "Only")

            // A legacy/private-task workspace must never enter the project
            // library, and an external/bookmark project row is refused too.
            let conversationID = UUID()
            try await fixture.cluster.conversationStore.saveConversation(
                ConversationRecord(id: conversationID, title: "Legacy",
                                   createdAt: Date(), updatedAt: Date()))
            _ = try await fixture.cluster.workspaceStore.ensureWorkspace(
                conversationID: conversationID, title: "Legacy")
            try await fixture.cluster.workspaceStore.saveWorkspace(
                WorkspaceRecord(name: "External", rootBookmark: Data([1, 2, 3]),
                                kind: .project))
            let listed = try await projects.list()
            XCTAssertEqual(listed.map(\.id), [project.id])
        }
    }

    // MARK: - Pre-first-run assignment

    func testAssignIsPreFirstRunAndRefusesExistingOrNonemptyTasks() async throws {
        try await withFixture { fixture in
            let lifecycle = RecordingLifecycle()
            let projects = library(fixture, lifecycle: lifecycle)
            let project = try await projects.create(name: "One")

            func conversation(_ purpose: ConversationPurpose = .ordinary) async throws -> UUID {
                let id = UUID()
                try await fixture.cluster.conversationStore.saveConversation(
                    ConversationRecord(id: id, title: "Fresh",
                                       createdAt: Date(), updatedAt: Date(),
                                       purpose: purpose))
                return id
            }

            let fresh = try await conversation()
            let receipt = try await projects.assign(
                projectID: project.id, conversationID: fresh,
                expectedRevision: project.revision)
            XCTAssertTrue(receipt.fenceSettled)
            let freshOwner = try await fixture.cluster.workspaceStore
                .workspaceID(conversationID: fresh)
            XCTAssertEqual(freshOwner, project.id)
            let began = await lifecycle.began
            let committed = await lifecycle.committed
            XCTAssertEqual(began, [fresh])
            XCTAssertEqual(committed, [fresh])

            let nonempty = try await conversation()
            try await fixture.cluster.conversationStore.appendMessage(
                PersistedMessage(id: UUID(), conversationID: nonempty,
                                 role: "user", content: "hello", createdAt: Date()))
            let afterFirst = try await projects.get(projectID: project.id)
            do {
                _ = try await projects.assign(
                    projectID: project.id, conversationID: nonempty,
                    expectedRevision: afterFirst.project.revision)
                XCTFail("nonempty assignment succeeded")
            } catch C01ProjectError.taskNotEmpty {
            }
            let nonemptyOwner = try await fixture.cluster.workspaceStore
                .workspaceID(conversationID: nonempty)
            XCTAssertNil(nonemptyOwner)

            // Existing ownership is never silently moved.
            let second = try await projects.create(name: "Two")
            do {
                _ = try await projects.assign(
                    projectID: second.id, conversationID: fresh,
                    expectedRevision: second.revision)
                XCTFail("existing task ownership moved")
            } catch C01ProjectError.taskAlreadyBound {
            }

            let notes = try await conversation(.notes)
            do {
                _ = try await projects.assign(
                    projectID: second.id, conversationID: notes,
                    expectedRevision: second.revision)
                XCTFail("notes conversation assigned")
            } catch C01ProjectError.purposeNotOrdinary {
            }

            do {
                _ = try await projects.assign(
                    projectID: second.id, conversationID: UUID(),
                    expectedRevision: second.revision)
                XCTFail("unknown conversation assigned")
            } catch C01ProjectError.conversationNotFound {
            }
        }
    }

    func testAssignmentRefusesFenceHeldAndStaleRevision() async throws {
        try await withFixture { fixture in
            let lifecycle = RecordingLifecycle()
            let projects = library(fixture, lifecycle: lifecycle)
            let project = try await projects.create(name: "Fence")
            let conversationID = UUID()
            try await fixture.cluster.conversationStore.saveConversation(
                ConversationRecord(id: conversationID, title: "Fresh",
                                   createdAt: Date(), updatedAt: Date()))

            do {
                _ = try await projects.assign(
                    projectID: project.id, conversationID: conversationID,
                    expectedRevision: "old")
                XCTFail("stale assignment succeeded")
            } catch C01ProjectError.staleRevision {
            }
            await lifecycle.setFailNextBegin(.fenceHeld)
            do {
                _ = try await projects.assign(
                    projectID: project.id, conversationID: conversationID,
                    expectedRevision: project.revision)
                XCTFail("fence-held assignment succeeded")
            } catch C01ProjectError.fenceHeld {
            }
            let unassignedOwner = try await fixture.cluster.workspaceStore
                .workspaceID(conversationID: conversationID)
            XCTAssertNil(unassignedOwner)
        }
    }

    // MARK: - Delete and root retention

    func testDeleteDefaultsToRetainingBytesAndRehomesSurvivingTasks() async throws {
        try await withFixture { fixture in
            let lifecycle = RecordingLifecycle()
            let projects = library(fixture, lifecycle: lifecycle)
            let project = try await projects.create(name: "Keep")
            let root = C01ProjectRootLayout.projectDirectory(
                rootPath: fixture.root.path, projectID: project.id)
            let marker = root + "/notes.txt"
            try Data("keep me".utf8).write(to: URL(fileURLWithPath: marker))

            let conversationID = UUID()
            try await fixture.cluster.conversationStore.saveConversation(
                ConversationRecord(id: conversationID, title: "Bound",
                                   createdAt: Date(), updatedAt: Date()))
            let current = try await projects.get(projectID: project.id)
            _ = try await projects.assign(
                projectID: project.id, conversationID: conversationID,
                expectedRevision: current.project.revision)

            let revision = try await projects.get(projectID: project.id).project.revision
            let receipt = try await projects.delete(
                projectID: project.id, expectedRevision: revision,
                deleteRoot: false, stopActiveTasks: false)
            XCTAssertTrue(receipt.rootRetained)
            XCTAssertEqual(receipt.retainedRelativeRoot, "Projects/\(project.id.uuidString)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
            let deletedRow = try await fixture.cluster.workspaceStore.workspace(id: project.id)
            XCTAssertNil(deletedRow)

            // The surviving task is rehomed into its own private workspace,
            // never deleted and never left ownerless.
            let moved = try await fixture.cluster.workspaceStore
                .workspaceID(conversationID: conversationID)
            XCTAssertNotNil(moved)
            let movedRecord = try await fixture.cluster.workspaceStore.workspace(id: moved!)
            XCTAssertEqual(movedRecord?.kind, .privateTask)
        }
    }

    func testExplicitDeleteRootRemovesOnlyExactProjectLeafNoFollow() async throws {
        try await withFixture { fixture in
            let lifecycle = RecordingLifecycle()
            let projects = library(fixture, lifecycle: lifecycle)
            let keep = try await projects.create(name: "Keep")
            let remove = try await projects.create(name: "Remove")
            let removeRoot = C01ProjectRootLayout.projectDirectory(
                rootPath: fixture.root.path, projectID: remove.id)
            try Data("inside".utf8).write(
                to: URL(fileURLWithPath: removeRoot + "/inside.txt"))

            // A symlink INSIDE the project must be removed itself, never
            // followed to the sentinel file outside the managed tree.
            let sentinel = fixture.root.appendingPathComponent("sentinel.txt")
            try Data("outside".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(
                atPath: removeRoot + "/escape", withDestinationPath: sentinel.path)

            let removeDetail = try await projects.get(projectID: remove.id)
            let receipt = try await projects.delete(
                projectID: remove.id,
                expectedRevision: removeDetail.project.revision,
                deleteRoot: true, stopActiveTasks: false)
            XCTAssertFalse(receipt.rootRetained)
            XCTAssertEqual(receipt.rootRemoval, C01ProjectRootRemoval.removed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: removeRoot))
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: C01ProjectRootLayout.projectDirectory(
                    rootPath: fixture.root.path, projectID: keep.id)))
        }
    }

    func testDeleteRefusesASecondLiveFenceAndLeavesProject() async throws {
        try await withFixture { fixture in
            let lifecycle = RecordingLifecycle()
            let projects = library(fixture, lifecycle: lifecycle)
            let project = try await projects.create(name: "Busy")
            let conversationID = UUID()
            try await fixture.cluster.conversationStore.saveConversation(
                ConversationRecord(id: conversationID, title: "Bound",
                                   createdAt: Date(), updatedAt: Date()))
            let assigned = try await projects.get(projectID: project.id)
            _ = try await projects.assign(
                projectID: project.id, conversationID: conversationID,
                expectedRevision: assigned.project.revision)

            await lifecycle.setFailNextBegin(.fenceHeld)
            let revision = try await projects.get(projectID: project.id).project.revision
            do {
                _ = try await projects.delete(
                    projectID: project.id, expectedRevision: revision,
                    deleteRoot: false, stopActiveTasks: false)
                XCTFail("delete ignored a live foreign fence")
            } catch C01ProjectError.fenceHeld {
            }
            let surviving = try await fixture.cluster.workspaceStore.workspace(id: project.id)
            XCTAssertNotNil(surviving)
        }
    }

    func testFixedClockMutationStrictlyAdvancesRevisionAndStaleCASIsRejected() async throws {
        try await withFixture { fixture in
            let lifecycle = RecordingLifecycle()
            let projects = fixedClockLibrary(fixture, lifecycle: lifecycle)
            let created = try await projects.create(name: "Clock")
            let renamed = try await projects.rename(
                projectID: created.id, name: "Clock 2",
                expectedRevision: created.revision)
            XCTAssertNotEqual(renamed.revision, created.revision)
            do {
                _ = try await projects.rename(
                    projectID: created.id, name: "Stale",
                    expectedRevision: created.revision)
                XCTFail("stale fixed-clock revision succeeded")
            } catch C01ProjectError.staleRevision {
            }
            let final = try await projects.get(projectID: created.id)
            XCTAssertEqual(final.project.name, "Clock 2")
        }
    }

    func testConditionalDeleteRejectsChangedOwnershipSnapshotAndDeletesAtomically() async throws {
        try await withFixture { fixture in
            let lifecycle = RecordingLifecycle()
            let projects = library(fixture, lifecycle: lifecycle)
            let project = try await projects.create(name: "Atomic")
            let conversationID = UUID()
            try await fixture.cluster.conversationStore.saveConversation(
                ConversationRecord(id: conversationID, title: "Bound",
                                   createdAt: Date(), updatedAt: Date()))
            let beforeAssign = try await projects.get(projectID: project.id)
            _ = try await projects.assign(
                projectID: project.id, conversationID: conversationID,
                expectedRevision: beforeAssign.project.revision)
            let revision = try await projects.get(projectID: project.id).project.revision

            let changed = try await fixture.cluster.workspaceStore
                .deleteWorkspaceConditional(
                    id: project.id, expectedUpdatedAt: revision,
                    expectedConversationIDs: [])
            XCTAssertEqual(changed, .ownerChanged)
            let stillOwned = try await fixture.cluster.workspaceStore
                .workspaceID(conversationID: conversationID)
            XCTAssertEqual(stillOwned, project.id)
            let stillProject = try await fixture.cluster.workspaceStore.workspace(id: project.id)
            XCTAssertNotNil(stillProject)

            let deleted = try await fixture.cluster.workspaceStore
                .deleteWorkspaceConditional(
                    id: project.id, expectedUpdatedAt: revision,
                    expectedConversationIDs: [conversationID])
            XCTAssertEqual(deleted, .deleted)
            let projectRow = try await fixture.cluster.workspaceStore.workspace(id: project.id)
            XCTAssertNil(projectRow)
        }
    }

    func testConditionalDeleteRollsBackRehomeWhenDeleteIsRefused() async throws {
        try await withFixture { fixture in
            let projects = library(fixture, lifecycle: RecordingLifecycle())
            let project = try await projects.create(name: "Rollback")
            let conversationID = UUID()
            try await fixture.cluster.conversationStore.saveConversation(
                ConversationRecord(id: conversationID, title: "Retained",
                                   createdAt: Date(), updatedAt: Date()))
            _ = try await projects.assign(
                projectID: project.id, conversationID: conversationID,
                expectedRevision: project.revision)
            let revision = try await projects.get(projectID: project.id).project.revision
            let countBefore = try await fixture.database.reader { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workspaces")
            }
            try await fixture.database.writer { db in
                // Simulate a real SQLite deletion refusal after rehome begins.
                try db.execute(sql: """
                    CREATE TRIGGER c01_refuse_project_delete
                    BEFORE DELETE ON workspaces
                    WHEN OLD.id = '\(project.id.uuidString)'
                    BEGIN SELECT RAISE(IGNORE); END
                    """)
            }
            do {
                _ = try await fixture.cluster.workspaceStore.deleteWorkspaceConditional(
                    id: project.id, expectedUpdatedAt: revision,
                    expectedConversationIDs: [conversationID])
                XCTFail("Refused delete must throw and roll back rehoming")
            } catch {
                // A normal failure receipt would commit earlier writes.
            }
            let owner = try await fixture.cluster.workspaceStore
                .workspaceID(conversationID: conversationID)
            let surviving = try await fixture.cluster.workspaceStore.workspace(id: project.id)
            let countAfter = try await fixture.database.reader { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workspaces")
            }
            XCTAssertEqual(owner, project.id)
            XCTAssertNotNil(surviving)
            XCTAssertEqual(countAfter, countBefore)
        }
    }

    func testStopActiveTasksAlwaysDrainsEveryFence() async throws {
        try await withFixture { fixture in
            let lifecycle = RecordingLifecycle()
            let projects = library(fixture, lifecycle: lifecycle)
            let project = try await projects.create(name: "Drain")
            let conversationID = UUID()
            try await fixture.cluster.conversationStore.saveConversation(
                ConversationRecord(id: conversationID, title: "Bound",
                                   createdAt: Date(), updatedAt: Date()))
            let beforeAssign = try await projects.get(projectID: project.id)
            _ = try await projects.assign(
                projectID: project.id, conversationID: conversationID,
                expectedRevision: beforeAssign.project.revision)
            let revision = try await projects.get(projectID: project.id).project.revision
            _ = try await projects.delete(
                projectID: project.id, expectedRevision: revision,
                deleteRoot: false, stopActiveTasks: true)
            let calls = await lifecycle.drainCalls
            XCTAssertEqual(calls, [conversationID])
        }
    }

    func testDetachedOwnedWorkProbeRefusesDefaultDeleteButExplicitStopDrains() async throws {
        try await withFixture { fixture in
            let lifecycle = RecordingLifecycle()
            let projects = library(fixture, lifecycle: lifecycle)
            let project = try await projects.create(name: "Detached")
            let conversationID = UUID()
            try await fixture.cluster.conversationStore.saveConversation(
                ConversationRecord(id: conversationID, title: "Bound",
                                   createdAt: Date(), updatedAt: Date()))
            let beforeAssign = try await projects.get(projectID: project.id)
            _ = try await projects.assign(
                projectID: project.id, conversationID: conversationID,
                expectedRevision: beforeAssign.project.revision)
            let revision = try await projects.get(projectID: project.id).project.revision

            let guarded = C01ProjectLibrary(
                epoch: 1, cluster: fixture.cluster,
                lifecycleProvider: { lifecycle },
                liveCheck: { true },
                liveOwnedWorkProbe: { _ in true })
            do {
                _ = try await guarded.delete(
                    projectID: project.id, expectedRevision: revision,
                    deleteRoot: false, stopActiveTasks: false)
                XCTFail("default delete ignored a still-attached detached token")
            } catch C01ProjectError.projectBusy {
            }
            let survivor = try await fixture.cluster.workspaceStore.workspace(id: project.id)
            XCTAssertNotNil(survivor)

            _ = try await guarded.delete(
                projectID: project.id, expectedRevision: revision,
                deleteRoot: false, stopActiveTasks: true)
            let calls = await lifecycle.drainCalls
            XCTAssertEqual(calls, [conversationID])
        }
    }

    func testDescriptorCleanerRemovesDirectorySymlinkWithoutFollowingIt() async throws {
        try await withFixture { fixture in
            let lifecycle = RecordingLifecycle()
            let projects = library(fixture, lifecycle: lifecycle)
            let project = try await projects.create(name: "Symlink")
            let root = C01ProjectRootLayout.projectDirectory(
                rootPath: fixture.root.path, projectID: project.id)
            let outside = fixture.root.appendingPathComponent("outside-dir")
            try FileManager.default.createDirectory(at: outside,
                                                    withIntermediateDirectories: true)
            let sentinel = outside.appendingPathComponent("sentinel.txt")
            try Data("outside".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(
                atPath: root + "/linked-dir", withDestinationPath: outside.path)
            let removed = C01ProjectRootLayout.removeProjectDirectory(
                rootPath: fixture.root.path, projectID: project.id)
            XCTAssertEqual(removed, .removed)
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        }
    }

    func testDescriptorCleanerRejectsAReplacedLeafSymlink() async throws {
        try await withFixture { fixture in
            let lifecycle = RecordingLifecycle()
            let projects = library(fixture, lifecycle: lifecycle)
            let project = try await projects.create(name: "Leaf")
            let root = C01ProjectRootLayout.projectDirectory(
                rootPath: fixture.root.path, projectID: project.id)
            let outside = fixture.root.appendingPathComponent("outside-leaf")
            try FileManager.default.createDirectory(at: outside,
                                                    withIntermediateDirectories: true)
            let sentinel = outside.appendingPathComponent("sentinel.txt")
            try Data("outside".utf8).write(to: sentinel)
            try FileManager.default.removeItem(atPath: root)
            try FileManager.default.createSymbolicLink(
                atPath: root, withDestinationPath: outside.path)
            let removal = C01ProjectRootLayout.removeProjectDirectory(
                rootPath: fixture.root.path, projectID: project.id)
            if case .failed = removal {
                // Expected: O_NOFOLLOW refuses the replaced leaf.
            } else {
                XCTFail("replaced symlinked project leaf was accepted")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        }
    }

    func testProjectRootLayoutRejectsTraversalAndSymlinkedComponents() async throws {
        XCTAssertNil(C01ProjectRootLayout.projectID(
            fromInternalRelativePath: "Projects/../escape"))
        XCTAssertNil(C01ProjectRootLayout.projectID(
            fromInternalRelativePath: "Projects/not-a-uuid"))
        let id = UUID()
        XCTAssertEqual(C01ProjectRootLayout.projectID(
            fromInternalRelativePath: "Projects/\(id.uuidString)"), id)

        try await withFixture { fixture in
            let projectsDir = C01ProjectRootLayout.projectsDirectory(
                rootPath: fixture.root.path)
            try FileManager.default.createDirectory(
                atPath: projectsDir, withIntermediateDirectories: true)
            let escaped = fixture.root.appendingPathComponent("escaped")
            try FileManager.default.createDirectory(at: escaped,
                                                    withIntermediateDirectories: true)
            try FileManager.default.removeItem(atPath: projectsDir)
            try FileManager.default.createSymbolicLink(
                atPath: projectsDir, withDestinationPath: escaped.path)
            let lifecycle = RecordingLifecycle()
            let projects = library(fixture, lifecycle: lifecycle)
            do {
                _ = try await projects.create(name: "Unsafe")
                XCTFail("project leaf created through a symlinked Projects component")
            } catch C01ProjectError.rootUnsafe {
            }
        }
    }
}
