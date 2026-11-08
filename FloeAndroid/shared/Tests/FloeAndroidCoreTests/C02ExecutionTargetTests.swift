// SPDX-License-Identifier: MPL-2.0
//
// C02 execution-target domain/store tests. AUTHORED, NOT RUN by this lane.
// They exercise the real SQLite CAS/migration/pin store plus deterministic
// fakes for environment/drain boundaries: no network, device, credential,
// provider or App action participates.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeSSH
import FloeTools
@testable import FloeAndroidCore

final class C02ExecutionTargetTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let database: DatabaseManager
        let store: C02SQLiteExecutionTargetStore
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c02-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try DatabaseManager(path: root.appendingPathComponent("db.sqlite"))
        try await database.migrate()
        try await database.writer { db in
            for statement in C02ExecutionTargetSchema.createStatements {
                try db.execute(sql: statement)
            }
        }
        do {
            try await body(Fixture(
                root: root,
                database: database,
                store: C02SQLiteExecutionTargetStore(database: database)
            ))
            try await database.close()
            try? FileManager.default.removeItem(at: root)
        } catch {
            try? await database.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func makeTask(
        database: DatabaseManager,
        title: String = "Task"
    ) async throws -> UUID {
        let taskID = UUID()
        let conversation = ConversationRecord(
            id: taskID,
            title: title,
            createdAt: Date(),
            updatedAt: Date(),
            purpose: .ordinary
        )
        try await SQLiteConversationStore(database: database).saveConversation(conversation)
        return taskID
    }

    private func makeRun(
        database: DatabaseManager,
        taskID: UUID,
        state: String = "running"
    ) async throws -> UUID {
        let runID = UUID()
        try await SQLiteRunStore(database: database).saveRun(RunRecord(
            id: runID,
            conversationID: taskID,
            state: state,
            goal: "test",
            startedAt: Date()
        ))
        return runID
    }

    private func localTarget(
        taskID: UUID,
        revision: Int64 = 1,
        environmentID: String = "env-a",
        workspaceID: UUID
    ) -> C02ExecutionTarget {
        C02ExecutionTarget(
            taskID: taskID,
            revision: revision,
            kind: .localLinux,
            environmentID: environmentID,
            projectID: nil,
            workspaceID: workspaceID,
            shellRootHash: String(repeating: "a", count: 64),
            engineOwnerHash: String(repeating: "b", count: 64),
            rootEpoch: 7,
            remote: nil,
            provenance: .explicitUserSelection,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func remoteTarget(
        taskID: UUID,
        revision: Int64 = 1,
        hostID: UUID,
        workspaceID: UUID
    ) -> C02ExecutionTarget {
        C02ExecutionTarget(
            taskID: taskID,
            revision: revision,
            kind: .ssh,
            environmentID: C02RemoteEnvironmentID.make(
                hostID: hostID, remoteRootPath: "/home/floe/.floe/tasks/task"),
            projectID: nil,
            workspaceID: workspaceID,
            shellRootHash: String(repeating: "a", count: 64),
            engineOwnerHash: String(repeating: "b", count: 64),
            rootEpoch: 7,
            remote: C02RemoteEnvironmentFacts(
                hostID: hostID,
                remoteRootPath: "/home/floe/.floe/tasks/task",
                operatingSystem: "linux",
                architecture: "aarch64",
                runtimeGeneration: "boot-1",
                distribution: "debian"
            ),
            provenance: .explicitUserSelection,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    // MARK: Store semantics

    func testStoreFirstWriterWinsAndRequiresSchema() async throws {
        try await withFixture { fixture in
            let taskID = try await makeTask(database: fixture.database)
            let workspaceID = UUID()
            let first = localTarget(taskID: taskID, environmentID: "env-a", workspaceID: workspaceID)
            let second = localTarget(taskID: taskID, environmentID: "env-b", workspaceID: workspaceID)
            let saved = try await fixture.store.insertInitial(first)
            XCTAssertEqual(saved.environmentID, "env-a")
            let again = try await fixture.store.insertInitial(second)
            XCTAssertEqual(again.environmentID, "env-a",
                           "A later default/selection must not rewrite the existing target")
            XCTAssertEqual(again.revision, 1)
        }
        let empty = try DatabaseManager.inMemory()
        // Deliberately unregistered DB: production migrate() now includes v52.
        let store = C02SQLiteExecutionTargetStore(database: empty)
        do {
            _ = try await store.target(taskID: UUID())
            XCTFail("missing target schema must fail closed")
        } catch let error as C02ExecutionTargetError {
            XCTAssertEqual(error, .schemaUnavailable)
        }
        try await empty.close()
    }

    func testRunPinSurvivesReopenAndRootEpochAdvancesOnlySameTarget() async throws {
        try await withFixture { fixture in
            let taskID = try await makeTask(database: fixture.database)
            let runID = try await makeRun(database: fixture.database, taskID: taskID)
            let workspaceID = UUID()
            let target = try await fixture.store.insertInitial(localTarget(
                taskID: taskID, environmentID: "env-a", workspaceID: workspaceID))
            let first = try await fixture.store.pinRun(C02RunTargetPin(
                runID: runID,
                taskID: taskID,
                targetRevision: target.revision,
                environmentID: target.environmentID,
                shellRootHash: target.shellRootHash,
                engineOwnerHash: target.engineOwnerHash,
                rootEpoch: 7,
                pinnedAt: Date()
            ))
            XCTAssertEqual(first.rootEpoch, 7)
            // Reopening reads the same durable pin.
            let reopened = try await C02SQLiteExecutionTargetStore(database: fixture.database)
                .runPin(runID: runID)
            XCTAssertEqual(reopened, first)
            // Same target revision + newer root generation: the execution
            // fence advances; target identity does not.
            let advanced = try await fixture.store.pinRun(C02RunTargetPin(
                runID: runID,
                taskID: taskID,
                targetRevision: target.revision,
                environmentID: target.environmentID,
                shellRootHash: target.shellRootHash,
                engineOwnerHash: target.engineOwnerHash,
                rootEpoch: 8,
                pinnedAt: Date()
            ))
            XCTAssertEqual(advanced.rootEpoch, 8)
            XCTAssertEqual(advanced.targetRevision, target.revision)
            do {
                _ = try await fixture.store.pinRun(C02RunTargetPin(
                    runID: runID,
                    taskID: taskID,
                    targetRevision: target.revision + 1,
                    environmentID: target.environmentID,
                    shellRootHash: target.shellRootHash,
                    engineOwnerHash: target.engineOwnerHash,
                    rootEpoch: 8,
                    pinnedAt: Date()
                ))
                XCTFail("a run cannot be rebound to another target revision")
            } catch let error as C02ExecutionTargetError {
                XCTAssertEqual(error, .runBoundToDifferentTarget)
            }
        }
    }

    func testReceiptTerminalStateCannotBeChangedBack() async throws {
        try await withFixture { fixture in
            let taskID = try await makeTask(database: fixture.database)
            let hostID = UUID()
            let dispatched = C02RemoteCommandReceipt(
                operationID: "run:\(UUID().uuidString):call:call_1",
                taskID: taskID,
                runID: nil,
                toolCallID: "call_1",
                targetRevision: 1,
                rootEpoch: 7,
                hostID: hostID,
                commandSHA256: String(repeating: "c", count: 64),
                state: .dispatched,
                startedAt: Date(),
                updatedAt: Date()
            )
            _ = try await fixture.store.recordReceipt(dispatched)
            let unknown = C02RemoteCommandReceipt(
                operationID: dispatched.operationID,
                taskID: dispatched.taskID,
                runID: nil,
                toolCallID: "call_1",
                targetRevision: 1,
                rootEpoch: 7,
                hostID: hostID,
                commandSHA256: dispatched.commandSHA256,
                state: .outcomeUnknown,
                startedAt: dispatched.startedAt,
                updatedAt: Date(),
                detailCode: "streamFailed"
            )
            let saved = try await fixture.store.recordReceipt(unknown)
            XCTAssertEqual(saved.state, .outcomeUnknown)
            do {
                _ = try await fixture.store.recordReceipt(C02RemoteCommandReceipt(
                    operationID: dispatched.operationID,
                    taskID: dispatched.taskID,
                    runID: nil,
                    toolCallID: "call_1",
                    targetRevision: 1,
                    rootEpoch: 7,
                    hostID: hostID,
                    commandSHA256: dispatched.commandSHA256,
                    state: .exited,
                    exitCode: 0,
                    startedAt: dispatched.startedAt,
                    updatedAt: Date()
                ))
                XCTFail("an unknown outcome must never be rewritten as a clean exit")
            } catch let error as C02ExecutionTargetError {
                XCTAssertEqual(error, .storeCorrupted)
            }
        }
    }

    // MARK: Domain

    private actor FakeOwnership: C02ExecutionTargetOwnershipProviding {
        var value: C02TargetOwnership
        init(_ value: C02TargetOwnership) { self.value = value }
        func ownership(taskID: UUID) async throws -> C02TargetOwnership? {
            value.taskID == taskID ? value : nil
        }
        func set(_ next: C02TargetOwnership) { value = next }
    }

    private actor FakePolicy: C02ExecutionTargetPolicyProviding {
        var value: C02TargetTaskPolicy
        init(_ value: C02TargetTaskPolicy) { self.value = value }
        func policy(taskID: UUID) async throws -> C02TargetTaskPolicy { value }
        func set(_ next: C02TargetTaskPolicy) { value = next }
    }

    private actor FakeEnvironments: C02ExecutionTargetEnvironmentProviding {
        var local: [C02LocalEnvironmentFacts]
        var hosts: [C02RemoteHostSummary]
        init(local: [C02LocalEnvironmentFacts], hosts: [C02RemoteHostSummary]) {
            self.local = local
            self.hosts = hosts
        }
        func localEnvironments(
            taskID: UUID,
            ownership: C02TargetOwnership
        ) async throws -> [C02LocalEnvironmentFacts] {
            local
        }
        func validateLocal(
            environmentID: String,
            taskID: UUID,
            ownership: C02TargetOwnership
        ) async throws -> C02LocalEnvironmentFacts {
            guard let row = local.first(where: { $0.id == environmentID }) else {
                throw C02ExecutionTargetError.environmentMissing(environmentID)
            }
            return row
        }
        func remoteHosts(taskID: UUID) async throws -> [C02RemoteHostSummary] { hosts }
        func validateRemoteHost(hostID: UUID, taskID: UUID) async throws -> C02RemoteHostSummary {
            guard let row = hosts.first(where: { $0.id == hostID }) else {
                throw C02ExecutionTargetError.remoteHostNotFound
            }
            return row
        }
        func setLocal(_ next: [C02LocalEnvironmentFacts]) { local = next }
    }

    private actor FakeProbe: C02RemoteTargetProbing {
        var result: Result<C02RemoteEnvironmentFacts, C02ExecutionTargetError>
        init(result: Result<C02RemoteEnvironmentFacts, C02ExecutionTargetError>) {
            self.result = result
        }
        func probeRemote(
            hostID: UUID,
            taskID: UUID,
            expectedFingerprint: String?
        ) async throws -> C02RemoteEnvironmentFacts {
            switch result {
            case .success(let facts): return facts
            case .failure(let error): throw error
            }
        }
        func set(_ next: Result<C02RemoteEnvironmentFacts, C02ExecutionTargetError>) {
            result = next
        }
    }

    private actor FakeTrust: C02RemoteHostTrusting {
        var writes: [(UUID, String, String)] = []
        func trust(
            hostID: UUID,
            address: String,
            port: Int,
            keyType: String,
            fingerprintSHA256: String
        ) async throws {
            writes.append((hostID, keyType, fingerprintSHA256))
        }
        func count() -> Int { writes.count }
    }

    private actor FakeDrain: C02ExecutionTargetDraining {
        var summary: C02OwnedWorkSummary
        var receipt: C02DrainReceipt
        var closeCount = 0
        var released = 0
        init(
            summary: C02OwnedWorkSummary = C02OwnedWorkSummary(),
            receipt: C02DrainReceipt = C02DrainReceipt(complete: true, timedOut: false)
        ) {
            self.summary = summary
            self.receipt = receipt
        }
        func preview(
            taskID: UUID,
            environmentID: String,
            targetRevision: Int64
        ) async throws -> C02OwnedWorkSummary { summary }
        func fence(
            taskID: UUID,
            environmentID: String,
            targetRevision: Int64,
            rootEpoch: UInt64
        ) async throws -> C02OwnedWorkFence {
            C02OwnedWorkFence(
                taskID: taskID,
                environmentID: environmentID,
                targetRevision: targetRevision,
                rootEpoch: rootEpoch,
                createdAt: Date()
            )
        }
        func drain(_ fence: C02OwnedWorkFence, timeout: Duration) async throws -> C02DrainReceipt {
            receipt
        }
        func release(_ fence: C02OwnedWorkFence) async { released += 1 }
        func closeRemoteSessions(taskID: UUID, targetRevision: Int64, rootEpoch: UInt64) async {
            closeCount += 1
        }
        func setReceipt(_ next: C02DrainReceipt) { receipt = next }
    }

    private struct Harness {
        let taskID: UUID
        let workspaceID: UUID
        let runID: UUID
        let ownership: FakeOwnership
        let policy: FakePolicy
        let environments: FakeEnvironments
        let probe: FakeProbe
        let trust: FakeTrust
        let drain: FakeDrain
        let domain: C02ExecutionTargetDomain
    }

    private func makeHarness(
        fixture: Fixture,
        remoteExecutionAllowed: Bool = true,
        temporary: Bool = false,
        localFacts: [C02LocalEnvironmentFacts]? = nil,
        hosts: [C02RemoteHostSummary]? = nil,
        drainSummary: C02OwnedWorkSummary = C02OwnedWorkSummary(),
        drainReceipt: C02DrainReceipt = C02DrainReceipt(complete: true, timedOut: false)
    ) async throws -> Harness {
        let taskID = try await makeTask(database: fixture.database)
        let workspaceID = UUID()
        let runID = try await makeRun(database: fixture.database, taskID: taskID)
        let ownershipValue = C02TargetOwnership(
            taskID: taskID,
            projectID: nil,
            workspaceID: workspaceID,
            workspaceRoot: fixture.root,
            shellRootHash: String(repeating: "a", count: 64),
            engineOwnerHash: String(repeating: "b", count: 64),
            rootEpoch: 7
        )
        let ownership = FakeOwnership(ownershipValue)
        let policy = FakePolicy(C02TargetTaskPolicy(
            isTemporary: temporary,
            isOrdinary: !temporary,
            remoteExecutionAllowed: remoteExecutionAllowed
        ))
        let local = localFacts ?? [
            C02LocalEnvironmentFacts(
                id: "env-a", name: "Linux A", kind: "session",
                state: "active", requiresRebuild: false,
                executionBackend: "linuxPRoot", ownerID: taskID.uuidString),
            C02LocalEnvironmentFacts(
                id: "env-b", name: "Linux B", kind: "session",
                state: "active", requiresRebuild: false,
                executionBackend: "linuxPRoot", ownerID: taskID.uuidString),
        ]
        let hostID = UUID()
        let remoteHosts = hosts ?? [
            C02RemoteHostSummary(
                id: hostID, displayName: "Build host", address: "host.example",
                port: 22, user: "floe", isExecutionEnvironment: true,
                sshConfigured: true)
        ]
        let environments = FakeEnvironments(local: local, hosts: remoteHosts)
        let probe = FakeProbe(result: .success(C02RemoteEnvironmentFacts(
            hostID: hostID,
            remoteRootPath: "/home/floe/.floe/tasks/\(taskID.uuidString.lowercased())",
            operatingSystem: "linux",
            architecture: "aarch64",
            runtimeGeneration: "boot-1",
            distribution: "debian"
        )))
        let trust = FakeTrust()
        let drain = FakeDrain(summary: drainSummary, receipt: drainReceipt)
        let domain = C02ExecutionTargetDomain(
            epoch: 7,
            store: fixture.store,
            ownership: ownership,
            policy: policy,
            environments: environments,
            remoteProbe: probe,
            remoteTrust: trust,
            drain: drain
        )
        return Harness(
            taskID: taskID,
            workspaceID: workspaceID,
            runID: runID,
            ownership: ownership,
            policy: policy,
            environments: environments,
            probe: probe,
            trust: trust,
            drain: drain,
            domain: domain
        )
    }

    func testInitialTargetPersistsAndLaterDefaultsCannotRewriteIt() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(fixture: fixture)
            let first = try await harness.domain.initialize(
                taskID: harness.taskID,
                selection: C02ExecutionTargetSelection(
                    kind: .localLinux, environmentID: "env-a",
                    remoteHostID: nil, explicitUserChoice: true)
            )
            XCTAssertEqual(first.environmentID, "env-a")
            let resolved = try await harness.domain.resolveForRun(
                taskID: harness.taskID,
                runID: harness.runID
            )
            XCTAssertEqual(resolved.target.environmentID, "env-a")
            XCTAssertEqual(resolved.pin.targetRevision, 1)
            do {
                _ = try await harness.domain.initialize(
                    taskID: harness.taskID,
                    selection: C02ExecutionTargetSelection(
                        kind: .localLinux, environmentID: "env-b",
                        remoteHostID: nil, explicitUserChoice: true)
                )
                XCTFail("changing a UI default must not silently change the task target")
            } catch let error as C02ExecutionTargetError {
                XCTAssertEqual(error, .targetAlreadyPinned)
            }
        }
    }

    func testResolveRequiresExplicitSelectionBeforeFirstRun() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(fixture: fixture)
            do {
                _ = try await harness.domain.resolveForRun(
                    taskID: harness.taskID, runID: harness.runID)
                XCTFail("a task with no target and no explicit choice must not invent one")
            } catch let error as C02ExecutionTargetError {
                XCTAssertEqual(error, .targetSelectionRequired)
            }
        }
    }

    func testHostAdoptsOnlyTheExactExistingEnvironmentAndPinsIt() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(fixture: fixture)
            let resolved = try await harness.domain.resolveUsingExistingEnvironment(
                taskID: harness.taskID, runID: harness.runID, preferredEnvironmentID: "env-a")
            XCTAssertEqual(resolved?.target.environmentID, "env-a")
            XCTAssertEqual(resolved?.target.provenance, .adoptedExistingEnvironment)
            XCTAssertEqual(resolved?.pin.environmentID, "env-a")
            let again = try await harness.domain.resolveUsingExistingEnvironment(
                taskID: harness.taskID, runID: harness.runID, preferredEnvironmentID: "env-b")
            XCTAssertEqual(again?.target.environmentID, "env-a")
        }
    }

    func testAmbiguousOrMissingLocalEnvironmentDoesNotCreateATarget() async throws {
        try await withFixture { fixture in
            let ambiguous = try await makeHarness(fixture: fixture)
            let result = try await ambiguous.domain.resolveUsingExistingEnvironment(
                taskID: ambiguous.taskID, runID: ambiguous.runID)
            XCTAssertNil(result)
            let target = try await ambiguous.domain.executionTarget(taskID: ambiguous.taskID)
            XCTAssertNil(target)
            let missing = try await makeHarness(fixture: fixture, localFacts: [])
            let absent = try await missing.domain.resolveUsingExistingEnvironment(
                taskID: missing.taskID, runID: missing.runID)
            XCTAssertNil(absent)
        }
    }

    func testHostAdoptionPreservesExplicitSSHSelection() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(fixture: fixture)
            let hosts = try await harness.environments.remoteHosts(taskID: harness.taskID)
            let selected = try await harness.domain.initialize(taskID: harness.taskID,
                selection: C02ExecutionTargetSelection(kind: .ssh, environmentID: nil,
                    remoteHostID: hosts[0].id, explicitUserChoice: true))
            let result = try await harness.domain.resolveUsingExistingEnvironment(
                taskID: harness.taskID, runID: harness.runID, preferredEnvironmentID: "env-a")
            XCTAssertEqual(result?.target.kind, .ssh)
            XCTAssertEqual(result?.target.environmentID, selected.environmentID)
        }
    }

    func testExistingTaskSessionKeepsPriorityOverItsProjectFallback() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(fixture: fixture)
            let owner = try await harness.ownership.ownership(taskID: harness.taskID)!
            let sessions = try await harness.environments.localEnvironments(
                taskID: harness.taskID, ownership: owner)
            let project = C02LocalEnvironmentFacts(
                id: "project-graphics", name: "Project", kind: "project", state: "active",
                requiresRebuild: false, executionBackend: "linuxPRoot", ownerID: harness.workspaceID.uuidString)
            await harness.environments.setLocal(Array(sessions.prefix(1)) + [project])
            let resolved = try await harness.domain.resolveUsingExistingEnvironment(
                taskID: harness.taskID, runID: harness.runID)
            XCTAssertEqual(resolved?.target.environmentID, "env-a")
            XCTAssertEqual(resolved?.pin.environmentID, "env-a")
        }
    }

    func testExplicitProjectPreferenceStillSelectsSharedSoftwareBeforeAnyPin() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(fixture: fixture)
            let owner = try await harness.ownership.ownership(taskID: harness.taskID)!
            let sessions = try await harness.environments.localEnvironments(taskID: harness.taskID, ownership: owner)
            await harness.environments.setLocal(sessions + [C02LocalEnvironmentFacts(
                id: "project-graphics", name: nil, kind: "project", state: "active",
                requiresRebuild: false, executionBackend: "linuxPRoot", ownerID: harness.workspaceID.uuidString)])
            let resolved = try await harness.domain.resolveUsingExistingEnvironment(
                taskID: harness.taskID, runID: harness.runID, preferredEnvironmentID: "project-graphics")
            XCTAssertEqual(resolved?.pin.environmentID, "project-graphics")
        }
    }

    func testCreatingProjectGraphicsDoesNotMigrateAnExistingSessionPin() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(fixture: fixture)
            _ = try await harness.domain.resolveUsingExistingEnvironment(
                taskID: harness.taskID, runID: harness.runID, preferredEnvironmentID: "env-a")
            let owner = try await harness.ownership.ownership(taskID: harness.taskID)!
            let sessions = try await harness.environments.localEnvironments(taskID: harness.taskID, ownership: owner)
            await harness.environments.setLocal(sessions + [C02LocalEnvironmentFacts(
                id: "project-graphics", name: nil, kind: "project", state: "active",
                requiresRebuild: false, executionBackend: "linuxPRoot", ownerID: harness.workspaceID.uuidString)])
            let resolved = try await harness.domain.resolveUsingExistingEnvironment(
                taskID: harness.taskID, runID: harness.runID)
            XCTAssertEqual(resolved?.target.environmentID, "env-a")
            XCTAssertEqual(resolved?.target.revision, 1)
        }
    }

    func testProjectGraphicsIsAdoptedWhenThereIsNoTaskSession() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(fixture: fixture)
            await harness.environments.setLocal([C02LocalEnvironmentFacts(
                id: "project-graphics", name: nil, kind: "project", state: "active",
                requiresRebuild: false, executionBackend: "linuxPRoot", ownerID: harness.workspaceID.uuidString)])
            let resolved = try await harness.domain.resolveUsingExistingEnvironment(
                taskID: harness.taskID, runID: harness.runID)
            XCTAssertEqual(resolved?.pin.environmentID, "project-graphics")
        }
    }

    func testAmbiguousSessionsDoNotImplicitlyFallBackToTheProject() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(fixture: fixture)
            let owner = try await harness.ownership.ownership(taskID: harness.taskID)!
            let sessions = try await harness.environments.localEnvironments(taskID: harness.taskID, ownership: owner)
            await harness.environments.setLocal(sessions + [C02LocalEnvironmentFacts(
                id: "project-graphics", name: nil, kind: "project", state: "active",
                requiresRebuild: false, executionBackend: "linuxPRoot", ownerID: harness.workspaceID.uuidString)])
            let resolved = try await harness.domain.resolveUsingExistingEnvironment(
                taskID: harness.taskID, runID: harness.runID)
            XCTAssertNil(resolved)
        }
    }

    func testAmbiguousProjectRowsNeverChooseTheFirstProjectOrAnotherTasksEnvironment() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(fixture: fixture)
            let projects = ["project-a", "project-b"].map { id in
                C02LocalEnvironmentFacts(id: id, name: nil, kind: "project", state: "active",
                    requiresRebuild: false, executionBackend: "linuxPRoot", ownerID: harness.workspaceID.uuidString)
            }
            await harness.environments.setLocal(projects)
            let ambiguous = try await harness.domain.resolveUsingExistingEnvironment(
                taskID: harness.taskID, runID: harness.runID)
            XCTAssertNil(ambiguous)
            await harness.environments.setLocal([C02LocalEnvironmentFacts(
                id: "foreign-project", name: nil, kind: "project", state: "active",
                requiresRebuild: false, executionBackend: "linuxPRoot", ownerID: UUID().uuidString)])
            let foreign = try await harness.domain.resolveUsingExistingEnvironment(
                taskID: harness.taskID, runID: harness.runID)
            XCTAssertNil(foreign)
        }
    }

    func testTemporaryTaskCannotCreateTarget() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(fixture: fixture, temporary: true)
            do {
                _ = try await harness.domain.initialize(
                    taskID: harness.taskID,
                    selection: C02ExecutionTargetSelection(
                        kind: .localLinux, environmentID: "env-a",
                        remoteHostID: nil, explicitUserChoice: true)
                )
                XCTFail("temporary chat must never create a target")
            } catch let error as C02ExecutionTargetError {
                XCTAssertEqual(error, .temporaryTaskRefused)
            }
            let options = try? await harness.domain.options(taskID: harness.taskID)
            XCTAssertNil(options)
        }
    }

    func testDrainTimeoutWritesNoTargetChange() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(
                fixture: fixture,
                drainSummary: C02OwnedWorkSummary(liveRuns: 1),
                drainReceipt: C02DrainReceipt(
                    complete: false, timedOut: true, stoppedRuns: 0,
                    detailCode: "drainDeadline")
            )
            let source = try await harness.domain.initialize(
                taskID: harness.taskID,
                selection: C02ExecutionTargetSelection(
                    kind: .localLinux, environmentID: "env-a",
                    remoteHostID: nil, explicitUserChoice: true)
            )
            do {
                _ = try await harness.domain.beginMigration(
                    taskID: harness.taskID,
                    expectedRevision: source.revision,
                    destination: C02ExecutionTargetSelection(
                        kind: .localLinux, environmentID: "env-b",
                        remoteHostID: nil, explicitUserChoice: true)
                )
                XCTFail("a timed-out drain must not commit")
            } catch let error as C02ExecutionTargetError {
                guard case .drainTimedOut(let receipt) = error else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertTrue(receipt.timedOut)
            }
            let unchanged = try await harness.domain.executionTarget(taskID: harness.taskID)
            XCTAssertEqual(unchanged?.environmentID, "env-a")
            XCTAssertEqual(unchanged?.revision, 1)
            let migration = try await harness.domain.migrationStatus(taskID: harness.taskID)
            XCTAssertEqual(migration?.phase, .failed)
            let released = await harness.drain.released
            XCTAssertEqual(released, 1)
        }
    }

    func testMigrationCommitIsCasOnceAndOldHistoricalRunKeepsPin() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(fixture: fixture)
            let completedRun = try await makeRun(
                database: fixture.database, taskID: harness.taskID, state: "completed")
            let source = try await harness.domain.initialize(
                taskID: harness.taskID,
                selection: C02ExecutionTargetSelection(
                    kind: .localLinux, environmentID: "env-a",
                    remoteHostID: nil, explicitUserChoice: true)
            )
            // Pin the live run and a historical completed run before moving.
            _ = try await harness.domain.resolveForRun(
                taskID: harness.taskID, runID: harness.runID)
            _ = try await fixture.store.pinRun(C02RunTargetPin(
                runID: completedRun,
                taskID: harness.taskID,
                targetRevision: source.revision,
                environmentID: source.environmentID,
                shellRootHash: source.shellRootHash,
                engineOwnerHash: source.engineOwnerHash,
                rootEpoch: 7,
                pinnedAt: Date()
            ))
            let commit = try await harness.domain.beginMigration(
                taskID: harness.taskID,
                expectedRevision: source.revision,
                destination: C02ExecutionTargetSelection(
                    kind: .localLinux, environmentID: "env-b",
                    remoteHostID: nil, explicitUserChoice: true)
            )
            XCTAssertEqual(commit.target.environmentID, "env-b")
            XCTAssertEqual(commit.target.revision, source.revision + 1)
            XCTAssertEqual(commit.migration.phase, .committed)
            let finished = try await harness.domain.completeMigration(commit.migration)
            XCTAssertEqual(finished.phase, .completed)
            // The live run was moved with the task.
            let livePin = try await fixture.store.runPin(runID: harness.runID)
            XCTAssertEqual(livePin?.targetRevision, commit.target.revision)
            XCTAssertEqual(livePin?.environmentID, "env-b")
            // The completed run remains bound to the target it actually ran in.
            let historical = try await fixture.store.runPin(runID: completedRun)
            XCTAssertEqual(historical?.targetRevision, source.revision)
            XCTAssertEqual(historical?.environmentID, "env-a")
            // The old callback cannot mutate the new target.
            let accepted = try await harness.domain.validateRunCompletion(
                runID: completedRun,
                targetRevision: source.revision,
                rootEpoch: 7
            )
            XCTAssertTrue(accepted, "the old callback is valid only for its old pin")
            let acceptedAgainstNew = try await harness.domain.validateRunCompletion(
                runID: harness.runID,
                targetRevision: source.revision,
                rootEpoch: 7
            )
            XCTAssertFalse(acceptedAgainstNew)
            // A second commit of the same migration cannot switch again.
            do {
                _ = try await fixture.store.commitMigration(commit.migration)
                XCTFail("commit must be exactly once")
            } catch let error as C02ExecutionTargetError {
                XCTAssertEqual(error, .migrationNotVerified)
            }
        }
    }

    func testStaleRevisionCannotStartMigration() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(fixture: fixture)
            _ = try await harness.domain.initialize(
                taskID: harness.taskID,
                selection: C02ExecutionTargetSelection(
                    kind: .localLinux, environmentID: "env-a",
                    remoteHostID: nil, explicitUserChoice: true)
            )
            do {
                _ = try await harness.domain.previewMigration(
                    taskID: harness.taskID,
                    expectedRevision: 99,
                    destination: C02ExecutionTargetSelection(
                        kind: .localLinux, environmentID: "env-b",
                        remoteHostID: nil, explicitUserChoice: true)
                )
                XCTFail("stale revision must be refused")
            } catch let error as C02ExecutionTargetError {
                XCTAssertEqual(error, .staleRevision(expected: 99, actual: 1))
            }
        }
    }

    func testRemoteHostKeyIsTrustedOnlyAfterExplicitApproval() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(fixture: fixture)
            _ = try await harness.domain.initialize(
                taskID: harness.taskID,
                selection: C02ExecutionTargetSelection(
                    kind: .localLinux, environmentID: "env-a",
                    remoteHostID: nil, explicitUserChoice: true)
            )
            let hosts = try await harness.environments.remoteHosts(taskID: harness.taskID)
            let hostID = try XCTUnwrap(hosts.first?.id)
            let challenge = C02RemoteHostKeyChallenge(
                taskID: harness.taskID,
                hostID: hostID,
                address: "host.example",
                port: 22,
                keyType: "ssh-ed25519",
                fingerprintSHA256: "SHA256:abcdefghijklmnopqrstuvwxyz0123456789",
                expectedFingerprintSHA256: nil,
                kind: .firstUse,
                createdAt: Date(),
                expiresAt: Date().addingTimeInterval(300)
            )
            await harness.probe.set(.failure(.hostKeyApprovalRequired(challenge)))
            do {
                _ = try await harness.domain.previewMigration(
                    taskID: harness.taskID,
                    expectedRevision: 1,
                    destination: C02ExecutionTargetSelection(
                        kind: .ssh, environmentID: nil,
                        remoteHostID: hostID, explicitUserChoice: true)
                )
                XCTFail("first-use key must require approval")
            } catch let error as C02ExecutionTargetError {
                guard case .hostKeyApprovalRequired = error else {
                    return XCTFail("unexpected error \(error)")
                }
            }
            let trustCountAfterChallenge = await harness.trust.count()
            XCTAssertEqual(trustCountAfterChallenge, 0,
                           "a surfaced challenge is not trust")
            let denied = try await harness.domain.approveHostKey(
                taskID: harness.taskID,
                challengeID: challenge.id,
                accept: false,
                replaceChanged: false,
                expectedFingerprint: nil
            )
            XCTAssertFalse(denied.trusted)
            let trustCountAfterDenial = await harness.trust.count()
            XCTAssertEqual(trustCountAfterDenial, 0)
            // Denial consumed the challenge. A later explicit approval must
            // follow a NEW probe, not reuse an already rejected request.
            do {
                _ = try await harness.domain.approveHostKey(
                    taskID: harness.taskID, challengeID: challenge.id,
                    accept: true, replaceChanged: false, expectedFingerprint: nil)
                XCTFail("a rejected challenge must not become trusted later")
            } catch let error as C02ExecutionTargetError {
                XCTAssertEqual(error, .invalidTarget("hostKeyChallengeNotFound"))
            }
            let renewed = C02RemoteHostKeyChallenge(
                taskID: harness.taskID, hostID: hostID, address: challenge.address,
                port: challenge.port, keyType: challenge.keyType,
                fingerprintSHA256: challenge.fingerprintSHA256,
                expectedFingerprintSHA256: nil, kind: .firstUse,
                createdAt: Date(), expiresAt: Date().addingTimeInterval(300))
            await harness.probe.set(.failure(.hostKeyApprovalRequired(renewed)))
            do {
                _ = try await harness.domain.previewMigration(
                    taskID: harness.taskID, expectedRevision: 1,
                    destination: C02ExecutionTargetSelection(kind: .ssh, environmentID: nil,
                        remoteHostID: hostID, explicitUserChoice: true))
                XCTFail("the new probe also requires explicit approval")
            } catch let error as C02ExecutionTargetError {
                guard case .hostKeyApprovalRequired(let pending) = error else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertEqual(pending.id, renewed.id)
            }
            let approved = try await harness.domain.approveHostKey(
                taskID: harness.taskID,
                challengeID: renewed.id,
                accept: true,
                replaceChanged: false,
                expectedFingerprint: nil
            )
            XCTAssertTrue(approved.trusted)
            let trustCountAfterApproval = await harness.trust.count()
            XCTAssertEqual(trustCountAfterApproval, 1)
        }
    }

    func testSSHExecutionAuthorizationRequiresPolicyAndMatchingPin() async throws {
        try await withFixture { fixture in
            let harness = try await makeHarness(fixture: fixture)
            let hosts = try await harness.environments.remoteHosts(taskID: harness.taskID)
            let hostID = try XCTUnwrap(hosts.first?.id)
            _ = try await harness.domain.initialize(
                taskID: harness.taskID,
                selection: C02ExecutionTargetSelection(
                    kind: .ssh, environmentID: nil,
                    remoteHostID: hostID, explicitUserChoice: true)
            )
            let authorization = try await harness.domain.authorizeSSHExecution(
                taskID: harness.taskID, runID: harness.runID)
            XCTAssertEqual(authorization.target.kind, .ssh)
            XCTAssertEqual(authorization.targetRevision, 1)
            XCTAssertEqual(authorization.rootEpoch, 7)
            // A fabricated target revision fails the adapter's pin check.
            let fake = C02SSHExecutionAuthorization(
                taskID: authorization.taskID,
                runID: authorization.runID,
                target: authorization.target,
                targetRevision: 2,
                rootEpoch: 7,
                ownerToken: authorization.ownerToken,
                sessionID: nil,
                sessionOwnerToken: nil,
                approvedHostKeyFingerprint: nil,
                permissionGrantID: UUID(),
                issuedAt: Date(),
                expiresAt: Date().addingTimeInterval(60)
            )
            let pin = try await fixture.store.runPin(runID: harness.runID)
            do {
                try fake.validate(now: Date(), pin: pin)
                XCTFail("target revision mismatch must be refused")
            } catch let error as C02SSHAdapterError {
                XCTAssertEqual(error, .targetMismatch)
            }
            await harness.policy.set(C02TargetTaskPolicy(
                isTemporary: false, isOrdinary: true, remoteExecutionAllowed: false))
            do {
                _ = try await harness.domain.authorizeSSHExecution(
                    taskID: harness.taskID, runID: harness.runID)
                XCTFail("remote execution policy must gate authorization")
            } catch let error as C02ExecutionTargetError {
                XCTAssertEqual(error, .remoteExecutionNotAllowed)
            }
        }
    }
}
