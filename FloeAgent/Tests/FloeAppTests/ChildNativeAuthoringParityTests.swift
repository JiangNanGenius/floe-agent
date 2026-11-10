// SPDX-License-Identifier: MPL-2.0
// App-target candidate: Root must compile/run on the canonical Simulator.
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
@testable import FloeApp

@Suite("Same-task child native authoring parity", .serialized)
@MainActor struct ChildNativeAuthoringParityTests {
    private func invoke(_ name: String, _ context: ToolContext) async throws {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: name))
        _ = try await runner.execute(argumentsJSON: Data("{}".utf8), context: context)
    }

    /// Exercises the App guard seam with the real parent identity shape;
    /// canonical dispatcher authorization is covered by runtime tests.
    private func childHandoff(runID: UUID, conversationID: UUID) -> ChildExecutionHandoff {
        ChildExecutionHandoff(
            identity: ChildExecutionIdentity(parentRunID: runID, rootTaskID: conversationID,
                delegateCallID: "delegate-parity-call"),
            dispatcher: ChildToolDispatcher(
                descriptorProvider: { _ in nil }, allDescriptors: { [] },
                dispatch: { call, _ in ToolResult(callID: call.id, status: .denied,
                    outputSummary: "unused test dispatcher", outputDigest: "") }
            ),
            peers: PeerCollaborationHandle(register: { _ in }, unregister: {}, drain: { [] },
                peers: { _ in [] }, send: { _, _, _ in SubagentPeerSendReceipt(accepted: false) })
        )
    }

    private func withSavedTask(_ body: @MainActor (UUID, UUID) async throws -> Void) async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let conversationID = UUID(), runID = UUID(), now = Date()
        try await environment.conversationStore.saveConversation(.init(id: conversationID,
            title: "Child parity qualification", createdAt: now, updatedAt: now))
        let workspace = try await SQLiteWorkspaceStore(database: environment.database)
            .ensureWorkspace(conversationID: conversationID, title: "Child parity qualification")
        let result: Result<Void, Error>
        do {
            try await environment.conversationStore.setArchived(id: conversationID, archived: true)
            try await environment.runStore.saveRun(.init(id: runID, conversationID: conversationID,
                state: "executing", goal: "Child parity qualification", startedAt: now))
            try await body(conversationID, runID)
            result = .success(())
        } catch { result = .failure(error) }
        do {
            try await environment.conversationStore.deleteConversation(id: conversationID)
            try await environment.workspaceCenter.deleteWorkspace(id: workspace.id)
        } catch {
            Issue.record("Parity fixture cleanup failed: \(error.localizedDescription)")
        }
        try result.get()
    }

    private func makeContext(runID: UUID, conversationID: UUID, child: Bool) -> ToolContext {
        var context = ToolContext(runID: runID, toolCallID: child ? "child-list" : "main-list",
            allowedToolNames: StudioCoordinator.names, cancellation: CancellationToken(),
            conversationID: conversationID)
        context.frozenEffectiveCatalogNames = StudioCoordinator.names
        context.executionToolName = "studio.list"
        if child { context.childExecution = childHandoff(runID: runID, conversationID: conversationID) }
        return context
    }

    @Test func sameTaskChildAndMainReadTheSameSavedWork() async throws {
        try await withSavedTask { conversationID, runID in
            try await invoke("studio.list", makeContext(runID: runID, conversationID: conversationID, child: true))
            try await invoke("studio.list", makeContext(runID: runID, conversationID: conversationID, child: false))
        }
    }

    @Test func endedRunStillDeniesAChild() async throws {
        try await withSavedTask { conversationID, runID in
            try await FloeAgentApp.liveEnvironment.runStore.updateRunState(id: runID, state: "completed", endedAt: Date())
            let context = makeContext(runID: runID, conversationID: conversationID, child: true)
            await #expect(throws: (any Error).self) { try await invoke("studio.list", context) }
        }
    }

    @Test func crossTaskRunPairingStillDeniesAChild() async throws {
        try await withSavedTask { conversationID, _ in
            try await withSavedTask { _, foreignRunID in
                let context = makeContext(runID: foreignRunID, conversationID: conversationID, child: true)
                await #expect(throws: (any Error).self) { try await invoke("studio.list", context) }
            }
        }
    }

    @Test func temporaryReadOnlyStillDeniesAChild() async throws {
        try await withSavedTask { conversationID, runID in
            var candidate = makeContext(runID: runID, conversationID: conversationID, child: true)
            candidate.temporaryReadOnly = true
            let context = candidate
            await #expect(throws: (any Error).self) { try await invoke("studio.list", context) }
        }
    }

    @Test func publicWebCeilingStillDeniesAChild() async throws {
        try await withSavedTask { conversationID, runID in
            var candidate = makeContext(runID: runID, conversationID: conversationID, child: true)
            candidate.publicWebOnly = true
            let context = candidate
            await #expect(throws: (any Error).self) { try await invoke("studio.list", context) }
        }
    }
}
#endif
