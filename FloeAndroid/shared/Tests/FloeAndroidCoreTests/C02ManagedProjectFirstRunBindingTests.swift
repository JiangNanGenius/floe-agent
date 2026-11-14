// SPDX-License-Identifier: MPL-2.0
//
// First-Send binding regression for a FRESH MANAGED PROJECT.
//
// The failing Full119 receipt (real Full14 run) had a ready/qualified Linux
// generation, no `environmentID`, a complete 133-name tool directory that
// omitted exactly `exec.shell` / `jobs.submit` / the four `shell.*` names, and
// `tools.search exec.shell =>` empty. The exact six-name removal is produced by
// ONE place: the run assembly's "no resolved execution target" narrowing. That
// narrowing was reached through a swallowed `try?`; a non-domain catalog error
// therefore became an indistinguishable "no Linux" for the whole run.
//
// These tests use the REAL C01 project library, REAL SQLite conversation /
// workspace binding, the REAL C02 ownership provider/policy/store/domain and
// the REAL catalog envelope decoder. Only the runtime `environment.list` BYTES
// are synthetic (there is no Kotlin/Android runtime on the host), so the exact
// first nil/throw of the first-Send chain is exercised rather than a fake.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
import FloeAndroidShellTools
@testable import FloeAndroidCore

final class C02ManagedProjectFirstRunBindingTests: XCTestCase {

    // MARK: - Fixture (REAL stores + REAL managed project root)

    private actor RecordingLifecycle: ConversationDeletionLifecycle {
        func beginDeletionFence(conversationID: UUID, epoch: UInt64,
                                operationID: UUID) async throws
            -> ConversationDeletionFence {
            ConversationDeletionFence(
                conversationID: conversationID, epoch: epoch,
                operationID: operationID,
                authorityReceipt: "work:v1:test-\(operationID.uuidString)")
        }
        func drainOwnedWork(fence: ConversationDeletionFence) async throws
            -> ConversationQuiescenceReport { ConversationQuiescenceReport() }
        func abortDeletionFence(_ fence: ConversationDeletionFence) async
            -> ConversationDeletionFenceSettlement { .released }
        func commitDeletionFence(_ fence: ConversationDeletionFence) async
            -> ConversationDeletionFenceSettlement { .released }
    }

    private struct Fixture {
        let root: URL
        let database: DatabaseManager
        let cluster: G02OwnedStoreCluster
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c02-managed-bind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let storage = RuntimeStorageRoot(validatingAbsoluteDirectory: root.path) else {
            throw FloeError.validationFailed("root")
        }
        let database = try DatabaseManager(path: storage.databaseURL)
        try await database.migrate()
        try await database.writer { db in
            for statement in C02ExecutionTargetSchema.createStatements {
                try db.execute(sql: statement)
            }
        }
        guard let identity = RuntimeOwnerIdentity(
            root: storage, token: "0123456789abcdef", epoch: 7) else {
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

    /// One real fresh managed project + one real ordinary first-Send task.
    private struct FirstSend {
        let projectID: UUID
        let taskID: UUID
        let runID: UUID
        let workspaceRoot: URL
    }

    private func firstSend(_ fixture: Fixture) async throws -> FirstSend {
        let projects = C01ProjectLibrary(
            epoch: 7, cluster: fixture.cluster,
            lifecycleProvider: { RecordingLifecycle() }, liveCheck: { true })
        let project = try await projects.create(name: "Sydney120Demo")
        let taskID = UUID()
        try await fixture.cluster.conversationStore.saveConversation(ConversationRecord(
            id: taskID, title: "Prep", createdAt: Date(), updatedAt: Date(),
            purpose: .ordinary))
        _ = try await projects.assign(projectID: project.id,
                                      conversationID: taskID,
                                      expectedRevision: project.revision)
        try await fixture.cluster.workspaceStore.saveTaskPolicy(
            TaskPolicy(conversationID: taskID))
        let runID = UUID()
        try await fixture.cluster.runStore.saveRun(RunRecord(
            id: runID, conversationID: taskID, state: "running",
            goal: "prepare the Sydney creator meetup", startedAt: Date()))
        return FirstSend(
            projectID: project.id, taskID: taskID, runID: runID,
            workspaceRoot: URL(fileURLWithPath: C01ProjectRootLayout.projectDirectory(
                rootPath: fixture.root.path, projectID: project.id), isDirectory: true))
    }

    // MARK: - Synthetic runtime catalog bytes

    private struct EmptyMetadata: G073EnvironmentMetadataSource {
        func environmentMetadata(id: String) async -> G073EnvironmentMetadata? { nil }
        func allEnvironmentMetadata() async -> [G073EnvironmentMetadata] { [] }
    }
    private struct NoProbe: C02RemoteTargetProbing {
        func probeRemote(hostID: UUID, taskID: UUID,
                         expectedFingerprint: String?) async throws
            -> C02RemoteEnvironmentFacts {
            throw C02ExecutionTargetError.remoteHostNotFound
        }
    }
    private struct NoTrust: C02RemoteHostTrusting {
        func trust(hostID: UUID, address: String, port: Int,
                   keyType: String, fingerprintSHA256: String) async throws {}
    }
    private struct NoDrain: C02ExecutionTargetDraining {
        func preview(taskID: UUID, environmentID: String,
                     targetRevision: Int64) async throws -> C02OwnedWorkSummary {
            C02OwnedWorkSummary()
        }
        func fence(taskID: UUID, environmentID: String, targetRevision: Int64,
                   rootEpoch: UInt64) async throws -> C02OwnedWorkFence {
            throw C02ExecutionTargetError.drainTimedOut(
                C02DrainReceipt(complete: false, timedOut: true))
        }
        func drain(_ fence: C02OwnedWorkFence, timeout: Duration) async throws
            -> C02DrainReceipt { C02DrainReceipt(complete: true, timedOut: false) }
        func release(_ fence: C02OwnedWorkFence) async {}
        func closeRemoteSessions(taskID: UUID, targetRevision: Int64,
                                 rootEpoch: UInt64) async {}
    }

    private func row(_ id: String, kind: String, owner: String,
                     parent: String? = nil) -> [String: Any] {
        var value: [String: Any] = [
            "id": id, "kind": kind, "ownerID": owner,
            "name": kind == "project" ? "Sydney120Demo" : "Linux",
            "state": "active", "baseRevision": "debian-bookworm-test",
            "requiresRebuild": false, "executionBackend": "linuxPRoot",
            "layerFormat": 1,
        ]
        if let parent { value["parentID"] = parent }
        return value
    }

    private func catalogBytes(projectID: UUID, owner: String,
                              rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "phase": "ready", "projectID": projectID.uuidString,
            "workspaceOwnerID": owner, "environments": rows,
        ], options: [.sortedKeys])
    }

    private func environmentProvider(_ bytes: Data,
                                     projectID: UUID,
                                     database: DatabaseManager)
        -> C02MetadataTargetEnvironmentProvider {
        C02MetadataTargetEnvironmentProvider(
            metadata: EmptyMetadata(),
            hosts: RemoteHostStore(database: database),
            liveCatalog: { _ in
                try C02RuntimeEnvironmentCatalog.decodeEnvelope(bytes, projectID: projectID)
            })
    }

    private func domain(_ fixture: Fixture,
                        ownership: C02SQLiteTargetOwnershipProvider,
                        environments: C02MetadataTargetEnvironmentProvider)
        -> C02ExecutionTargetDomain {
        C02ExecutionTargetDomain(
            epoch: 7,
            store: C02SQLiteExecutionTargetStore(database: fixture.database),
            ownership: ownership,
            policy: C02SQLiteTargetPolicyProvider(database: fixture.database),
            environments: environments,
            remoteProbe: NoProbe(), remoteTrust: NoTrust(), drain: NoDrain(),
            liveEpoch: { 7 })
    }

    private func ownerHash(_ root: URL) -> String {
        FloeDigest.sha256Hex(Data(root.standardizedFileURL.path.utf8))
    }

    // MARK: - 1. The real ownership chain for a fresh managed project

    func testRealManagedProjectTaskOwnershipIsAdoptable() async throws {
        try await withFixture { fixture in
            let send = try await firstSend(fixture)
            let provider = C02SQLiteTargetOwnershipProvider(
                database: fixture.database, storageRoot: fixture.root, rootEpoch: { 7 })
            let ownership = try await provider.ownership(taskID: send.taskID)
            XCTAssertNotNil(ownership, "a fresh, assigned managed project must own its first task")
            XCTAssertEqual(ownership?.workspaceID, send.projectID)
            XCTAssertEqual(ownership?.projectID, send.projectID)
            XCTAssertEqual(ownership?.workspaceRoot.standardizedFileURL,
                           send.workspaceRoot.standardizedFileURL)
        }
    }

    func testUnassignedTaskReportsTheExactOwnershipGuard() async throws {
        try await withFixture { fixture in
            let taskID = UUID()
            try await fixture.cluster.conversationStore.saveConversation(ConversationRecord(
                id: taskID, title: "Unassigned", createdAt: Date(), updatedAt: Date(),
                purpose: .ordinary))
            let provider = C02SQLiteTargetOwnershipProvider(
                database: fixture.database, storageRoot: fixture.root, rootEpoch: { 7 })
            do {
                _ = try await provider.ownership(taskID: taskID)
                XCTFail("a task without a workspace binding must not report ownership")
            } catch let error as C02ExecutionTargetError {
                XCTAssertEqual(error, .workspaceOwnershipUnresolved("unassigned"))
            }
        }
    }

    func testNotesPurposeAndMissingProjectRootAreDistinctTypedGuards() async throws {
        try await withFixture { fixture in
            let notesID = UUID()
            try await fixture.cluster.conversationStore.saveConversation(ConversationRecord(
                id: notesID, title: "Notes", createdAt: Date(), updatedAt: Date(),
                purpose: .notes))
            let provider = C02SQLiteTargetOwnershipProvider(
                database: fixture.database, storageRoot: fixture.root, rootEpoch: { 7 })
            do {
                _ = try await provider.ownership(taskID: notesID)
                XCTFail("a Notes conversation is not an ordinary project task")
            } catch let error as C02ExecutionTargetError {
                XCTAssertEqual(error, .workspaceOwnershipUnresolved("purposeNotOrdinary"))
            }

            let send = try await firstSend(fixture)
            // The persisted row stays; only the leaf disappears. The refusal
            // must name the guard and must never recreate the directory.
            try FileManager.default.removeItem(at: send.workspaceRoot)
            do {
                _ = try await provider.ownership(taskID: send.taskID)
                XCTFail("a missing managed leaf is not a usable ownership root")
            } catch let error as C02ExecutionTargetError {
                XCTAssertEqual(error, .workspaceOwnershipUnresolved("projectRootMissing"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: send.workspaceRoot.path),
                           "ownership resolution must never recreate a missing leaf")
        }
    }

    // MARK: - 2. No environment yet = a definitive, non-throwing no-route

    func testEmptyCatalogIsDefinitiveAndCreatesNoTarget() async throws {
        try await withFixture { fixture in
            let send = try await firstSend(fixture)
            let ownership = C02SQLiteTargetOwnershipProvider(
                database: fixture.database, storageRoot: fixture.root, rootEpoch: { 7 })
            let projectID = LinuxShellProjectMapping.projectID(
                forCanonicalCoreWorkspaceRoot: send.workspaceRoot)
            let empty = try catalogBytes(projectID: projectID,
                                         owner: ownerHash(send.workspaceRoot), rows: [])
            let domain = domain(fixture, ownership: ownership,
                                environments: environmentProvider(
                                    empty, projectID: projectID, database: fixture.database))

            let admission = await FacadeRunDomain.linuxRoute(
                attempts: 2, sleep: { _ in }) {
                    try await domain.resolveUsingExistingEnvironment(
                        taskID: send.taskID, runID: send.runID)
                }
            XCTAssertEqual(admission, .noAdoptableEnvironment)
            XCTAssertEqual(admission.contextToken, "unavailable:noEnvironment")
            let target = try await domain.executionTarget(taskID: send.taskID)
            XCTAssertNil(target, "no environment must never invent a target")
            let options = try await domain.options(taskID: send.taskID)
            XCTAssertFalse(options.hasUsableLocalEnvironment)
            XCTAssertFalse(options.canCreateInitialTarget)
        }
    }

    // MARK: - 3. The post-preflight project+session catalog adopts the exact task

    func testPostPreflightCatalogAdoptsTheExactTaskSessionAndPins() async throws {
        try await withFixture { fixture in
            let send = try await firstSend(fixture)
            let ownership = C02SQLiteTargetOwnershipProvider(
                database: fixture.database, storageRoot: fixture.root, rootEpoch: { 7 })
            let projectID = LinuxShellProjectMapping.projectID(
                forCanonicalCoreWorkspaceRoot: send.workspaceRoot)
            let projectRow = UUID().uuidString.lowercased()
            let sessionRow = UUID().uuidString.lowercased()
            let bytes = try catalogBytes(
                projectID: projectID, owner: ownerHash(send.workspaceRoot),
                rows: [row(projectRow, kind: "project", owner: ownerHash(send.workspaceRoot)),
                       row(sessionRow, kind: "session",
                           owner: send.taskID.uuidString, parent: projectRow)])
            let domain = domain(fixture, ownership: ownership,
                                environments: environmentProvider(
                                    bytes, projectID: projectID, database: fixture.database))

            let admission = await FacadeRunDomain.linuxRoute(
                attempts: 2, sleep: { _ in }) {
                    try await domain.resolveUsingExistingEnvironment(
                        taskID: send.taskID, runID: send.runID)
                }
            guard case .resolved(let resolved) = admission else {
                return XCTFail("post-preflight catalog must be adopted, got \(admission)")
            }
            XCTAssertEqual(resolved.target.kind, .localLinux)
            XCTAssertEqual(resolved.target.environmentID, sessionRow,
                           "the exact task session wins over its project fallback")
            XCTAssertEqual(resolved.target.provenance, .adoptedExistingEnvironment)
            XCTAssertEqual(resolved.pin.environmentID, sessionRow)

            // The next Send re-validates the SAME pin (revision 1), never a new one.
            let again = try await domain.resolveUsingExistingEnvironment(
                taskID: send.taskID, runID: send.runID)
            XCTAssertEqual(again?.target.environmentID, sessionRow)
            XCTAssertEqual(again?.target.revision, 1)
        }
    }

    // MARK: - 4. A failed catalog read is typed (never a foreign error)

    func testCatalogReadFailureIsTypedAndNeverCreatesATarget() async throws {
        try await withFixture { fixture in
            let send = try await firstSend(fixture)
            let ownership = C02SQLiteTargetOwnershipProvider(
                database: fixture.database, storageRoot: fixture.root, rootEpoch: { 7 })
            struct Unreachable: Error {}
            let environments = C02MetadataTargetEnvironmentProvider(
                metadata: EmptyMetadata(),
                hosts: RemoteHostStore(database: fixture.database),
                liveCatalog: { _ in throw Unreachable() })
            let domain = domain(fixture, ownership: ownership, environments: environments)

            do {
                _ = try await domain.options(taskID: send.taskID)
                XCTFail("an unreachable catalog must not answer options")
            } catch let error as C02ExecutionTargetError {
                XCTAssertEqual(error.code, "environmentCatalogUnavailable")
                XCTAssertTrue(error.retryable)
            }
            let admission = await FacadeRunDomain.linuxRoute(
                attempts: 2, sleep: { _ in }) {
                    try await domain.resolveUsingExistingEnvironment(
                        taskID: send.taskID, runID: send.runID)
                }
            guard case .unavailable(let reason) = admission else {
                return XCTFail("a failed catalog read must stay visibly unavailable")
            }
            XCTAssertTrue(reason.hasPrefix("catalog"), reason)
            let target = try await domain.executionTarget(taskID: send.taskID)
            XCTAssertNil(target)
        }
    }

    // MARK: - 5. The bounded retry recovers exactly one transient failure

    func testRouteAdmissionRetriesOneTransientCatalogFailure() async throws {
        let taskID = UUID()
        let target = C02ExecutionTarget(
            taskID: taskID, revision: 1, kind: .localLinux,
            environmentID: "env-session", projectID: nil, workspaceID: UUID(),
            shellRootHash: String(repeating: "a", count: 64),
            engineOwnerHash: String(repeating: "b", count: 64),
            rootEpoch: 7, remote: nil, provenance: .adoptedExistingEnvironment,
            createdAt: Date(), updatedAt: Date())
        let runID = UUID()
        let resolved = C02ResolvedExecutionTarget(
            target: target,
            pin: C02RunTargetPin(
                runID: runID, taskID: taskID, targetRevision: 1,
                environmentID: "env-session",
                shellRootHash: String(repeating: "a", count: 64),
                engineOwnerHash: String(repeating: "b", count: 64),
                rootEpoch: 7, pinnedAt: Date()))

        let counter = AttemptCounter()
        let admission = await FacadeRunDomain.linuxRoute(
            attempts: 2, sleep: { _ in }) {
                let attempt = await counter.next()
                if attempt == 1 {
                    throw C02ExecutionTargetError
                        .environmentCatalogUnavailable("transportUnbound")
                }
                return resolved
            }
        XCTAssertEqual(admission, .resolved(resolved))
        let firstCount = await counter.value
        XCTAssertEqual(firstCount, 2, "exactly one bounded retry")

        let permanent = AttemptCounter()
        let failed = await FacadeRunDomain.linuxRoute(
            attempts: 2, sleep: { _ in }) {
                _ = await permanent.next()
                throw C02ExecutionTargetError
                    .environmentCatalogUnavailable("hostFenced")
            }
        XCTAssertEqual(failed, .unavailable("catalog:hostFenced"))
        let permanentCount = await permanent.value
        XCTAssertEqual(permanentCount, 2)
    }

    func testDeterministicOwnershipRefusalIsNotRetried() async throws {
        let counter = AttemptCounter()
        let admission = await FacadeRunDomain.linuxRoute(
            attempts: 2, sleep: { _ in }) {
                _ = await counter.next()
                throw C02ExecutionTargetError.workspaceOwnershipUnresolved("unassigned")
            }
        XCTAssertEqual(admission, .unavailable("ownership:unassigned"))
        let attempts = await counter.value
        XCTAssertEqual(attempts, 1,
                       "a deterministic ownership refusal must not be retried")
    }

    private actor AttemptCounter {
        private(set) var value = 0
        func next() -> Int { value += 1; return value }
    }

    // MARK: - 6. Exact ceiling narrowing (the six-name receipt)

    private let shellNames: Set<String> = ["exec.shell", "jobs.submit",
        "shell.open", "shell.exchange", "shell.signal", "shell.close"]
    private let otherNames: Set<String> = ["workspace.writeFile", "browser.observe",
        "device.observe", "environment.linuxStatus", "jobs.status"]

    func testNoRouteRemovesExactlyTheSixShellNames() {
        let universe = shellNames.union(otherNames)
        for admission in [LinuxRouteAdmission.notAttempted,
                          .noAdoptableEnvironment,
                          .unavailable("catalog:hostFenced")] {
            let narrowed = FacadeRunDomain.narrowedToolCeiling(
                nil, universe: universe, admission: admission,
                hasTargetDomain: true, temporary: false, isNotes: false)
            XCTAssertEqual(narrowed, otherNames,
                           "the Full14 133-name receipt is exactly this removal")
        }
        // An explicit task ceiling is intersected, never widened.
        let explicit: Set<String> = ["exec.shell", "browser.observe"]
        XCTAssertEqual(
            FacadeRunDomain.narrowedToolCeiling(
                explicit, universe: universe, admission: .noAdoptableEnvironment,
                hasTargetDomain: true, temporary: false, isNotes: false),
            ["browser.observe"])
    }

    func testResolvedLocalTargetKeepsTheCeilingAndSecureShellKeepsExecShell() {
        let universe = shellNames.union(otherNames)
        let local = C02ResolvedExecutionTarget(
            target: C02ExecutionTarget(
                taskID: UUID(), revision: 1, kind: .localLinux,
                environmentID: "env", projectID: nil, workspaceID: UUID(),
                shellRootHash: String(repeating: "a", count: 64),
                engineOwnerHash: String(repeating: "b", count: 64),
                rootEpoch: 7, remote: nil, provenance: .adoptedExistingEnvironment,
                createdAt: Date(), updatedAt: Date()),
            pin: C02RunTargetPin(
                runID: UUID(), taskID: UUID(), targetRevision: 1, environmentID: "env",
                shellRootHash: String(repeating: "a", count: 64),
                engineOwnerHash: String(repeating: "b", count: 64),
                rootEpoch: 7, pinnedAt: Date()))
        XCTAssertNil(
            FacadeRunDomain.narrowedToolCeiling(
                nil, universe: universe, admission: .resolved(local),
                hasTargetDomain: true, temporary: false, isNotes: false),
            "a resolved local target leaves the legacy ceiling (nil = full catalog)")

        let remote = C02ResolvedExecutionTarget(
            target: C02ExecutionTarget(
                taskID: UUID(), revision: 1, kind: .ssh, environmentID: "ssh:host",
                projectID: nil, workspaceID: UUID(),
                shellRootHash: String(repeating: "a", count: 64),
                engineOwnerHash: String(repeating: "b", count: 64),
                rootEpoch: 7,
                remote: C02RemoteEnvironmentFacts(
                    hostID: UUID(), remoteRootPath: "/home/floe/task",
                    operatingSystem: "linux", architecture: "aarch64",
                    runtimeGeneration: "boot-1", distribution: "debian"),
                provenance: .explicitUserSelection,
                createdAt: Date(), updatedAt: Date()),
            pin: C02RunTargetPin(
                runID: UUID(), taskID: UUID(), targetRevision: 1, environmentID: "ssh:host",
                shellRootHash: String(repeating: "a", count: 64),
                engineOwnerHash: String(repeating: "b", count: 64),
                rootEpoch: 7, pinnedAt: Date()))
        let narrowed = FacadeRunDomain.narrowedToolCeiling(
            nil, universe: universe, admission: .resolved(remote),
            hasTargetDomain: true, temporary: false, isNotes: false)
        XCTAssertTrue(narrowed?.contains("exec.shell") ?? false)
        XCTAssertFalse(narrowed?.contains("shell.open") ?? true)
    }

    func testTemporaryNotesAndNoDomainCeilingsAreUntouched() {
        let universe = shellNames.union(otherNames)
        for (temporary, notes) in [(true, false), (false, true)] {
            XCTAssertNil(
                FacadeRunDomain.narrowedToolCeiling(
                    nil, universe: universe, admission: .notAttempted,
                    hasTargetDomain: true, temporary: temporary, isNotes: notes))
        }
        XCTAssertNil(
            FacadeRunDomain.narrowedToolCeiling(
                nil, universe: universe, admission: .notAttempted,
                hasTargetDomain: false, temporary: false, isNotes: false))
    }

    // MARK: - 7. Temporary tasks never adopt or pin

    private struct TemporaryPolicy: C02ExecutionTargetPolicyProviding {
        func policy(taskID: UUID) async throws -> C02TargetTaskPolicy {
            C02TargetTaskPolicy(isTemporary: true, isOrdinary: false,
                                remoteExecutionAllowed: false)
        }
    }

    func testTemporaryTaskNeverAdopts() async throws {
        try await withFixture { fixture in
            let send = try await firstSend(fixture)
            let ownership = C02SQLiteTargetOwnershipProvider(
                database: fixture.database, storageRoot: fixture.root, rootEpoch: { 7 })
            let projectID = LinuxShellProjectMapping.projectID(
                forCanonicalCoreWorkspaceRoot: send.workspaceRoot)
            let bytes = try catalogBytes(
                projectID: projectID, owner: ownerHash(send.workspaceRoot),
                rows: [row(projectID.uuidString.lowercased(), kind: "project",
                           owner: ownerHash(send.workspaceRoot))])
            let domain = C02ExecutionTargetDomain(
                epoch: 7,
                store: C02SQLiteExecutionTargetStore(database: fixture.database),
                ownership: ownership,
                policy: TemporaryPolicy(),
                environments: environmentProvider(
                    bytes, projectID: projectID, database: fixture.database),
                remoteProbe: NoProbe(), remoteTrust: NoTrust(), drain: NoDrain(),
                liveEpoch: { 7 })
            let admission = await FacadeRunDomain.linuxRoute(
                attempts: 2, sleep: { _ in }) {
                    try await domain.resolveUsingExistingEnvironment(
                        taskID: send.taskID, runID: send.runID)
                }
            XCTAssertEqual(admission, .unavailable("temporaryTaskRefused"))
            let temporaryTarget = try await domain.executionTarget(taskID: send.taskID)
            XCTAssertNil(temporaryTarget)
        }
    }

    // MARK: - 8. The host refusal envelope is a typed answer, not a decode error

    func testNonReadyCatalogEnvelopeIsATypedRefusal() throws {
        let projectID = UUID()
        let refusal = try JSONSerialization.data(withJSONObject: [
            "phase": "unavailable", "code": "catalogTimeout",
        ])
        XCTAssertThrowsError(
            try C02RuntimeEnvironmentCatalog.decodeEnvelope(refusal, projectID: projectID)
        ) { error in
            XCTAssertEqual(error as? C02ExecutionTargetError,
                           .environmentCatalogUnavailable("catalogTimeout"))
        }
        let hostile = try JSONSerialization.data(withJSONObject: [
            "phase": "unavailable", "code": "/data/user/0/secret/path",
        ])
        XCTAssertThrowsError(
            try C02RuntimeEnvironmentCatalog.decodeEnvelope(hostile, projectID: projectID)
        ) { error in
            XCTAssertEqual(error as? C02ExecutionTargetError,
                           .environmentCatalogUnavailable("hostRefused"),
                           "an untrusted code string must never reach the run context")
        }
        let readyMissingOwner = try JSONSerialization.data(withJSONObject: [
            "phase": "ready", "projectID": projectID.uuidString,
            "environments": [],
        ])
        XCTAssertThrowsError(
            try C02RuntimeEnvironmentCatalog.decodeEnvelope(
                readyMissingOwner, projectID: projectID)
        ) { error in
            XCTAssertEqual(error as? C02ExecutionTargetError,
                           .environmentCatalogUnavailable("hostShapeMismatch"))
        }
        let readyForeignProject = try JSONSerialization.data(withJSONObject: [
            "phase": "ready", "projectID": UUID().uuidString,
            "workspaceOwnerID": String(repeating: "a", count: 64),
            "environments": [],
        ])
        XCTAssertThrowsError(
            try C02RuntimeEnvironmentCatalog.decodeEnvelope(
                readyForeignProject, projectID: projectID)
        ) { error in
            XCTAssertEqual(error as? C02ExecutionTargetError,
                           .environmentCatalogUnavailable("hostShapeMismatch"))
        }
    }
}
