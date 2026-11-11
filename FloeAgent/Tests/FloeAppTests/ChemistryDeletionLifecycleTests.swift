// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeChemistryCore
import FloeChemistryEngine
@testable import FloeApp

/// Chemistry file-deletion lifecycle. Decision-table tests pin the ownership
/// classification; the remaining tests drive the REAL adapter entry
/// (`stopAttemptForDeletion`) on the app's actual service graph with
/// synthetic worker-attempt journals, real run records and real job rows.
@MainActor @Suite("Chemistry deletion lifecycle classification", .serialized)
struct ChemistryDeletionLifecycleTests {
    private func attempt(state: ChemistryWorkerAttempt.State, nativeIntent: Bool, jobID: UUID? = UUID()) -> ChemistryWorkerAttempt {
        ChemistryWorkerAttempt(id: UUID(), kind: .probe, projectID: UUID(), chemistryRunID: nil,
            owner: .init(taskID: UUID(), hostRunID: UUID()), environmentID: "native.local",
            bindingGeneration: 7, runtimeGeneration: nil,
            workspaceRootPath: FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path,
            allowedWorkspacePaths: [], relativeDirectory: ".floe-chemistry/\(UUID().uuidString)",
            configurationDigest: "digest", inputSHA256: "input", manifestSHA256: "manifest",
            shellPayload: Data("{\"fixture\":\"\(UUID().uuidString)\"}".utf8), nativeIntent: nativeIntent,
            jobID: jobID, state: state)
    }

    // MARK: Decision table (synthetic)

    @Test func planSeparatesLiveOwnershipFromExpiredRunLifetime() async throws {
        for state in [ChemistryWorkerAttempt.State.succeeded, .failed, .cancelled, .interrupted] {
            #expect(attempt(state: state, nativeIntent: false).deletionStopPlan(hasLiveJob: true, owningRunEnded: false) == .skip)
        }
        #expect(attempt(state: .transferPending, nativeIntent: true).deletionStopPlan(hasLiveJob: false, owningRunEnded: true) == .reconcileFirst)
        for state in [ChemistryWorkerAttempt.State.awaitingSubmission, .submissionUnknown, .running, .cancelling] {
            #expect(attempt(state: state, nativeIntent: true).deletionStopPlan(hasLiveJob: true, owningRunEnded: true) == .stopOwnedJob)
            #expect(attempt(state: state, nativeIntent: false).deletionStopPlan(hasLiveJob: true, owningRunEnded: true) == .refuseLiveForeignJob)
            // The reported screenshot scenario: an owned file whose old AI run
            // context expired must reconcile, not read as Unauthorized.
            #expect(attempt(state: state, nativeIntent: false).deletionStopPlan(hasLiveJob: false, owningRunEnded: true) == .reconcileStale)
            #expect(attempt(state: state, nativeIntent: false).deletionStopPlan(hasLiveJob: false, owningRunEnded: false) == .refuseUnfinishedSubmit)
            #expect(attempt(state: state, nativeIntent: true).deletionStopPlan(hasLiveJob: false, owningRunEnded: false) == .reconcileStale)
        }
    }

    // MARK: Real adapter entry

    /// Files must open a cold original using native library ownership, not
    /// recover the permissions of a historical assistant calculation. Unlike
    /// the adapter fixtures below, this uses the visible App's real library,
    /// session authorizer, assistant lifecycle and batch menu entrypoint.
    @Test func coldFilesBatchDeletesLegacyChemistryWithoutRevivingTaskContexts() async throws {
        let environment = try await appQualificationEnvironment()
        let library = try await PersonalContentService.shared.library()
        struct Original {
            let record: PersonalContentRecord
            let directory: URL
            let metadata: Data
            let assistantID: UUID
            let oldTaskID: UUID
            let attemptID: UUID
        }
        var originals: [Original] = []
        for title in ["化学工程", "QA-Chat-Chemistry-1107", "QA-M4-Chemistry-1107"] {
            let record = try await PersonalContentService.shared.create(kind: .chemistry,
                title: "QA-P0-330-" + title + "-" + UUID().uuidString)
            let directory = try await library.resolve(record.id).url
            let metadata = try Data(contentsOf: directory.appendingPathComponent("FloeProject.json"))
            let assistant = try await environment.studioCoordinator.assistant(for: record)
            let oldTask = UUID(), oldRun = UUID(), now = Date(), attemptID = UUID()
            try await environment.conversationStore.saveConversation(.init(id: oldTask,
                title: "Unbound historical chemistry task", createdAt: now, updatedAt: now))
            try await environment.runStore.saveRun(.init(id: oldRun, conversationID: oldTask,
                state: "completed", goal: "Expired chemistry fixture", startedAt: now, endedAt: now))
            let value = ChemistryWorkerAttempt(id: attemptID, kind: .probe, projectID: record.id,
                chemistryRunID: nil, owner: .init(taskID: oldTask, hostRunID: oldRun),
                environmentID: "expired-fixture-environment", bindingGeneration: 1, runtimeGeneration: nil,
                workspaceRootPath: directory.path, allowedWorkspacePaths: [],
                relativeDirectory: ".floe-chemistry/" + attemptID.uuidString,
                configurationDigest: "expired-fixture", inputSHA256: "fixture", manifestSHA256: "fixture",
                shellPayload: Data("{}".utf8), nativeIntent: false, jobID: nil, state: .awaitingSubmission)
            try write(value, root: directory)
            originals.append(.init(record: record, directory: directory, metadata: metadata,
                assistantID: assistant, oldTaskID: oldTask, attemptID: attemptID))
        }
        let result = await PersonalLibraryFileActions.deleteBatch(originals.map { .work($0.record) },
            environment: environment, library: library)
        #expect(result.failed.isEmpty, "Real Files deletion failures: \(result.failed.map(\.message))")
        #expect(result.deleted.count == 3)
        let selectedIDs = Set(originals.map { $0.record.id })
        let entries = try await library.recentlyDeleted().filter { $0.projectID.map(selectedIDs.contains) == true }
        #expect(entries.count == 3)
        for original in originals {
            #expect(try Data(contentsOf: original.directory.appendingPathComponent("FloeProject.json")) == original.metadata)
            #expect(try read(original.attemptID, root: original.directory).state == .cancelled)
            let bindings = await environment.studioCoordinator.assistantBindings()
            #expect(bindings.contains { $0.projectID == original.record.id && $0.conversationID == original.assistantID })
        }
        let restored = await PersonalLibraryFileActions.restoreBatch(entries, environment: environment, library: library)
        #expect(restored.failed.isEmpty && restored.restored.count == 3)
        for original in originals {
            _ = try await library.resolve(original.record.id)
            #expect(try read(original.attemptID, root: original.directory).state == .cancelled)
        }
        // Cleanup is another real Files operation on these exact owned IDs.
        let deletedAgain = await PersonalLibraryFileActions.deleteBatch(originals.map { .work($0.record) },
            environment: environment, library: library)
        #expect(deletedAgain.failed.isEmpty && deletedAgain.deleted.count == 3)
        let trash = try await library.recentlyDeleted().filter { $0.projectID.map(selectedIDs.contains) == true }
        let plans = try await PersonalLibraryFileActions.permanentDeletionPlans(trash, environment: environment, library: library)
        let purged = await PersonalLibraryFileActions.permanentlyDeleteBatch(plans, environment: environment, library: library)
        #expect(purged.failed.isEmpty && purged.deleted.count == 3)
        for original in originals {
            let foreignConversation = try await environment.conversationStore.conversation(id: original.oldTaskID)
            #expect(foreignConversation != nil, "An expired calculation never grants ownership of its task")
            try await environment.conversationStore.deleteConversation(id: original.oldTaskID)
        }
    }

    private struct Harness {
        let environment: AppEnvironment
        let adapter: ChemistryEnvironmentJobAdapter
        let root: URL
        let store: ChemistryProjectStore
        let service: ChemistryService
    }
    private func harness() async throws -> Harness {
        let environment = try await appQualificationEnvironment()
        let adapter = environment.chemistryEnvironmentJobs
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chem-delete-" + UUID().uuidString)
        let store = try ChemistryProjectStore(root: root.appendingPathComponent("store"))
        let service = try ChemistryService(store: store, authorize: { _ in })
        adapter.deletionStopTimeout = 0.6
        adapter.deletionStopPollInterval = 0.05
        adapter.deletionSubmitGraceAttempts = 2
        adapter.deletionSubmitGraceInterval = 0.1
        adapter.deletionSubmitJoinTimeout = 2
        return Harness(environment: environment, adapter: adapter, root: root, store: store, service: service)
    }
    private func write(_ value: ChemistryWorkerAttempt, root: URL) throws {
        let journal = try ChemistryWorkerFiles.child("ChemistryJobs", root: root)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        try ChemistryWorkerFiles.write(try JSONEncoder().encode(value),
                                       path: value.id.uuidString + "/attempt.json", root: journal, limit: 256 * 1024)
    }
    private func read(_ id: UUID, root: URL) throws -> ChemistryWorkerAttempt {
        let file = try ChemistryWorkerFiles.child("ChemistryJobs/" + id.uuidString + "/attempt.json", root: root)
        return try JSONDecoder().decode(ChemistryWorkerAttempt.self, from: ChemistryWorkerFiles.read(file, limit: 256 * 1024))
    }
    private func saveRun(_ h: Harness, hostRunID: UUID, conversationID: UUID, ended: Bool) async throws {
        let now = Date()
        if try await h.environment.conversationStore.conversation(id: conversationID) == nil {
            try await h.environment.conversationStore.saveConversation(.init(
                id: conversationID, title: "Chemistry lifecycle fixture", createdAt: now, updatedAt: now))
        }
        try await h.environment.runStore.saveRun(RunRecord(id: hostRunID, conversationID: conversationID,
            state: ended ? "completed" : "running", goal: "Chemistry calculation fixture",
            startedAt: now, endedAt: ended ? now : nil))
    }
    private func saveJob(_ h: Harness, _ value: ChemistryWorkerAttempt, state: BackgroundJobState) async throws {
        try await saveRun(h, hostRunID: value.owner.hostRunID,
                          conversationID: value.owner.taskID, ended: value.nativeIntent)
        try await BackgroundJobStore(database: h.environment.database).save(BackgroundJob(
            id: value.jobID!, conversationID: value.owner.taskID, runID: value.owner.hostRunID,
            kind: .tool, targetTool: "exec.shell", payloadJSON: value.shellPayload, state: state,
            workspaceRootPath: value.workspaceRootPath, environmentID: value.environmentID))
    }

    @Test func terminalAttemptWithAReapedJobNeverTouchesTheJobsStore() async throws {
        let h = try await harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        // Terminal record whose jobID no longer exists in the store: deletion
        // must proceed instead of failing the lookup.
        let value = attempt(state: .succeeded, nativeIntent: true, jobID: UUID())
        try write(value, root: h.root)
        try await h.adapter.stopAttemptForDeletion(value, root: h.root, service: h.service)
        let settled = try read(value.id, root: h.root)
        #expect(settled.state == .succeeded)
    }

    @Test func staleNativeAttemptWithoutAJobIsReconciledForDeletion() async throws {
        let h = try await harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        var value = attempt(state: .awaitingSubmission, nativeIntent: true, jobID: nil)
        try write(value, root: h.root)
        try await h.adapter.stopAttemptForDeletion(value, root: h.root, service: h.service)
        value = try read(value.id, root: h.root)
        #expect(value.state == .cancelled)
    }

    @Test func staleAssistantAttemptReconcilesOnlyAfterItsRunEnded() async throws {
        let h = try await harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let live = attempt(state: .awaitingSubmission, nativeIntent: false, jobID: nil)
        try write(live, root: h.root)
        try await saveRun(h, hostRunID: live.owner.hostRunID, conversationID: live.owner.taskID, ended: false)
        await #expect(throws: (any Error).self) {
            try await h.adapter.stopAttemptForDeletion(live, root: h.root, service: h.service)
        }
        #expect(try read(live.id, root: h.root).state == .awaitingSubmission)

        let ended = attempt(state: .submissionUnknown, nativeIntent: false, jobID: nil)
        try write(ended, root: h.root)
        try await saveRun(h, hostRunID: ended.owner.hostRunID, conversationID: ended.owner.taskID, ended: true)
        try await h.adapter.stopAttemptForDeletion(ended, root: h.root, service: h.service)
        #expect(try read(ended.id, root: h.root).state == .cancelled)
    }

    @Test func liveNativeJobIsReallyStoppedWithTerminalProof() async throws {
        let h = try await harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let value = attempt(state: .running, nativeIntent: true)
        try write(value, root: h.root)
        try await saveJob(h, value, state: .queued)
        try await h.adapter.stopAttemptForDeletion(value, root: h.root, service: h.service)
        let settled = try read(value.id, root: h.root)
        #expect(settled.state == .cancelled)
        let job = try await BackgroundJobStore(database: h.environment.database).job(id: value.jobID!)
        #expect(job?.state == .cancelled)
    }

    @Test func stopFailureRetainsTheOriginalWithAnActionableReport() async throws {
        let h = try await harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let value = attempt(state: .running, nativeIntent: true)
        try write(value, root: h.root)
        // A running synthetic processor never acknowledges cancellation, so
        // the bounded join expires and the original is retained.
        try await saveJob(h, value, state: .running)
        var failure = ""
        do { try await h.adapter.stopAttemptForDeletion(value, root: h.root, service: h.service) }
        catch { failure = String(error.localizedDescription.prefix(200)) }
        #expect(!failure.isEmpty)
        #expect(failure.contains("still stopping") || failure.contains("仍在停止"))
        let retained = try read(value.id, root: h.root)
        #expect(retained.state == .cancelling)
        let job = try await BackgroundJobStore(database: h.environment.database).job(id: value.jobID!)
        #expect(job?.state == .running)
    }

    @Test(arguments: [ChemistryWorkerAttempt.State.awaitingSubmission, .submissionUnknown])
    func lateSubmitJoinsTheProducerWhileItsWorkerLeaseRemainsHeld(initialState: ChemistryWorkerAttempt.State) async throws {
        let h = try await harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let value = attempt(state: initialState, nativeIntent: true, jobID: nil)
        try write(value, root: h.root)
        // A native submit is still completing inside this process: the durable
        // record alone cannot prove otherwise.
        let lease = WorkspaceCenter.TaskRootLease(url: h.root, release: {})
        h.adapter.nativeLeases[value.id] = lease
        defer { h.adapter.nativeLeases.removeValue(forKey: value.id)?.release() }
        let lateJobID = UUID()
        let started = AsyncStream<Void>.makeStream()
        let completer = Task { @MainActor in
            try await h.adapter.nativeSubmissions.perform(value.id) {
                started.continuation.yield(()); started.continuation.finish()
                try await Task.sleep(for: .milliseconds(80))
                var settled = value
                settled.jobID = lateJobID
                settled.state = .running
                try await saveJob(h, settled, state: .queued)
                try write(settled, root: h.root)
                // Production keeps its worker lease through monitoring.
            }
        }
        for await _ in started.stream { break }
        try await h.adapter.stopAttemptForDeletion(value, root: h.root, service: h.service)
        try await completer.value
        #expect(h.adapter.nativeLeases[value.id] != nil)
        let settled = try read(value.id, root: h.root)
        // The late job was handled through the real stop path, not by blindly
        // marking the uncertain record cancelled behind its back.
        #expect(settled.state == .cancelled)
        let job = try await BackgroundJobStore(database: h.environment.database).job(id: lateJobID)
        #expect(job?.state == .cancelled)
    }
}
#endif
