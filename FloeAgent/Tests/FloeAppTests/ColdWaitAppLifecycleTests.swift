// SPDX-License-Identifier: MPL-2.0
// Hosted App tests: real preview environment, canonical SQLite and file actions.
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
import FloeAgentRuntime
@testable import FloeApp

@Suite("FloeApp.ColdWaitLifecycle", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ColdWaitAppLifecycleTests {
    private struct ColdWait {
        let conversationID: UUID
        let runID: UUID
        let record: AgentWaitRecord
        let binding: TaskExecutionBinding
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let environment: AppEnvironment
        let checkpoints: SQLiteRunCheckpointStore
        let library: PersonalContentLibrary
        let access: StudioDocumentAccess
        var conversations: Set<UUID> = []
        var beforeCommitReadbacks = 0
        var center: ConversationCenter { environment.conversationCenter }

        init() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("FloeColdWaitApp-" + UUID().uuidString, isDirectory: true)
            let library = PersonalContentLibrary(root: root.appendingPathComponent("Library"))
            let access = try StudioDocumentAccess(root: root.appendingPathComponent("Authority"))
            let environment = AppEnvironment.preview()
            try await environment.database.migrate()
            // Fail visibly if preview composition changes. Do not substitute
            // a file/mock store or bypass the canonical execution-pin check.
            let checkpoints = try #require(environment.checkpointStore as? SQLiteRunCheckpointStore)
            self.root = root
            self.library = library
            self.access = access
            self.environment = environment
            self.checkpoints = checkpoints
            environment.studioCoordinator = StudioCoordinator(
                environment: environment, authority: access, library: library)
        }

        func installColdWait(conversationID: UUID = UUID(), expired: Bool = false) async throws -> ColdWait {
            let now = Date(), runID = UUID(), callID = "cold-wait-" + UUID().uuidString
            let waitStartedAt = expired ? now.addingTimeInterval(-60) : now
            let runStartedAt = waitStartedAt.addingTimeInterval(-1)
            if try await environment.conversationStore.conversation(id: conversationID) == nil {
                try await environment.conversationStore.saveConversation(.init(
                    id: conversationID, title: "Synthetic cold wait", createdAt: runStartedAt, updatedAt: now))
            }
            conversations.insert(conversationID)
            let bindings = TaskExecutionBindingStore(database: environment.database)
            // A saved target is not started or claimed healthy. Native waits
            // retain its real persisted pin even while commands are unavailable.
            let binding = try await bindings.bindInitial(.init(conversationID: conversationID,
                target: .init(environmentID: "saved-cold-wait-" + conversationID.uuidString,
                    backend: .linuxVM, operatingSystem: "linux", architecture: "arm64"),
                generation: 7, updatedAt: runStartedAt))
            try await environment.runStore.saveRun(.init(id: runID, conversationID: conversationID,
                state: "executingTool", goal: "Synthetic persisted wait", startedAt: runStartedAt))
            try await bindings.pinRun(runID: runID, binding: binding)
            let request = RuntimeWaitRequest(seconds: expired ? 1 : 3_600)
            let call = try ToolCall(id: callID, toolName: AgentWaitTool.name,
                argumentsJSON: JSONEncoder().encode(request), scope: .local).withIDContext(runID: runID)
            let record = try AgentWaitRecord(owner: .init(conversationID: conversationID,
                runID: runID, callID: callID, clientSessionID: "run:" + runID.uuidString),
                request: request, now: waitStartedAt)
            let descriptor = AnyAgentTool(AgentWaitTool()).descriptor
            let checkpoint = AgentCheckpoint(runID: runID, conversationID: conversationID,
                state: .checkpointed(.init(reason: AgentWaitRecovery.markerPrefix + ":" + record.waitID.uuidString)),
                messages: [.init(role: "user", content: "Synthetic persisted wait", createdAt: runStartedAt)],
                pendingToolCalls: [call], createdAt: waitStartedAt.addingTimeInterval(0.1),
                conversationMode: .chat, executionBinding: binding,
                toolLifecycleEntries: [.init(callID: callID, toolName: AgentWaitTool.name,
                    authorizationIdentity: descriptor.authorizationIdentity, isSideEffecting: false,
                    phase: .dispatched, updatedAt: waitStartedAt)], runtimeWaits: [record])
            try await environment.checkpointStore.save(checkpoint)
            let independentlyLoaded = try #require(try await readCheckpoint(runID: runID))
            #expect(independentlyLoaded.executionBinding == binding)
            #expect(try await environment.runStore.run(id: runID)?.executionBinding == binding)
            #expect(AgentWaitRecovery.hasWaitingMarker(independentlyLoaded))
            #expect(try await checkpoints.pendingRuntimeWaitCheckpoints().contains { $0.runID == runID })
            return ColdWait(conversationID: conversationID, runID: runID, record: record, binding: binding)
        }

        func readCheckpoint(runID: UUID) async throws -> AgentCheckpoint? {
            // A fresh instance reads the same real canonical DB row; no
            // test-owned in-memory projection can satisfy the assertions.
            try await SQLiteRunCheckpointStore(database: environment.database, legacyDirectory: nil).load(runID: runID)
        }

        func expectStopped(_ cold: ColdWait) async throws {
            let checkpoint = try #require(try await readCheckpoint(runID: cold.runID))
            let receipt = try #require(checkpoint.runtimeWaits?.first?.receipt)
            let row = try #require(try await environment.runStore.run(id: cold.runID))
            #expect(!AgentWaitRecovery.hasWaitingMarker(checkpoint))
            #expect(receipt.status == .cancelled)
            #expect(receipt.waitID == cold.record.waitID)
            #expect(receipt.continuationInputID == cold.record.continuationInputID)
            #expect(checkpoint.executionBinding == cold.binding)
            #expect(row.executionBinding == cold.binding)
            #expect(row.state == "cancelled" && row.endedAt != nil)
            #expect(center.runtimeWaitRecoveryWork(conversationID: cold.conversationID).isEmpty)
            #expect(!center.hasLiveOwner(runID: cold.runID))
            #expect(try await environment.runStore.runs(conversationID: cold.conversationID).map(\.id) == [cold.runID])
            #expect(try await checkpoints.pendingRuntimeWaitCheckpoints().allSatisfy { $0.runID != cold.runID })
            #expect(try await environment.runningInputStore.pending(conversationID: cold.conversationID).isEmpty)
        }

        func finish() async {
            // Also drain on a thrown #require/read error so this test never
            // leaves an hour-long recovery worker in the reused App host.
            for id in conversations {
                let work = center.runtimeWaitRecoveryWork(conversationID: id)
                await center.stopRuntimeWaitRecovery(work)
                for run in (try? await environment.runStore.runs(conversationID: id)) ?? [] {
                    await center.cancel(runID: run.id)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("Stop drains freshly registered cold-wait recovery and commits cancellation to canonical SQLite")
    func refreshedColdWaitStopsWithoutCreatingAnotherRun() async throws {
        let f = try await Fixture()
        do {
            let cold = try await f.installColdWait()
            await f.center.refreshRuntimeWaitRecovery()
            // Stay on MainActor: no sleep, yield or DB await between refresh,
            // capturing its actual setup reservation and entering UI Stop.
            let captured = f.center.runtimeWaitRecoveryWork(conversationID: cold.conversationID)
            #expect(captured[cold.runID] != nil)
            await f.center.cancel(runID: cold.runID)
            // The real Stop joins the registered worker and settles its
            // checkpoint under an invocation reservation before returning.
            try await f.expectStopped(cold)
            await f.center.stopRuntimeWaitRecovery(captured) // repeat join is harmless
            await f.center.refreshRuntimeWaitRecovery()
            try await f.expectStopped(cold)
            await f.finish()
        } catch {
            await f.finish()
            throw error
        }
    }

    @Test("Actual file Trash/Restore persists the cold wait stop before commit and never restarts it")
    func fileTrashRestoreKeepsBytesAndDoesNotResumeExpiredColdWait() async throws {
        let f = try await Fixture()
        do {
            let payload = Data("original-file+history\0中文".utf8)
            let original = try await f.library.create(kind: .diagram, title: "Synthetic bound original") { directory, _ in
                try payload.write(to: directory.appendingPathComponent("original.bin"))
            }
            let assistant = UUID()
            let cold = try await f.installColdWait(conversationID: assistant, expired: true)
            try await f.access.bindAssistant(conversationID: assistant, projectID: original.id)
            #expect(try await f.access.assistant(projectID: original.id) == assistant)
            let originalURL = try await f.library.resolve(original.id).url.appendingPathComponent("original.bin")
            #expect(try Data(contentsOf: originalURL) == payload)
            // The expired checkpoint is a genuine cold recovery candidate;
            // do not arm it before the actual file deletion owns its fence.
            let elapsedDeadline = try #require(cold.record.deadline)
            #expect(elapsedDeadline < Date())
            let entry = try await PersonalLibraryFileActions.delete(original,
                environment: f.environment, library: f.library, validateSource: {
                    // This callback runs inside the production stop lease,
                    // before the original's file/trash commit. Later retire
                    // logic cannot mask a missing durable stop proof here.
                    try await f.expectStopped(cold)
                    #expect(try Data(contentsOf: originalURL) == payload)
                    f.beforeCommitReadbacks += 1
                })
            #expect(f.beforeCommitReadbacks > 0)
            #expect(try await f.library.records().isEmpty)
            #expect(try await f.library.recentlyDeleted().contains { $0.id == entry.id })
            #expect(!f.center.fileAssistantConversations.contains { $0.id == assistant })
            #expect(f.center.unavailableFileAssistantConversationIDs.contains(assistant))
            #expect(try await f.environment.conversationStore.conversation(id: assistant) != nil)
            #expect(try await f.access.assistant(projectID: original.id) == assistant)
            try await f.expectStopped(cold)
            try await PersonalLibraryFileActions.restore(entry, environment: f.environment, library: f.library)
            let restored = try await f.library.resolve(original.id)
            #expect(restored.record.id == original.id)
            #expect(try Data(contentsOf: restored.url.appendingPathComponent("original.bin")) == payload)
            #expect(try await f.access.assistant(projectID: original.id) == assistant)
            #expect(f.center.fileAssistantConversations.contains { $0.id == assistant })
            #expect(!f.center.unavailableFileAssistantConversationIDs.contains(assistant))
            #expect(try await f.access.pendingFileLifecycles().isEmpty)
            // The old deadline is already due. The actual foreground recovery
            // entry still must not recreate a worker, input or another run.
            await f.center.refreshRuntimeWaitRecovery()
            try await f.expectStopped(cold)
            await f.finish()
        } catch {
            await f.finish()
            throw error
        }
    }
}
#endif
