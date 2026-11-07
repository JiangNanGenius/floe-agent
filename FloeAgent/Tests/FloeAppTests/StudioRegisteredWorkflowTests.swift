// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloePersistence
import FloeTools
import FloeDiagramCore
@testable import FloeApp

/// Calls the actual registered runners and the App's ONE existing service
/// graph. No provider request, fake repository or second environment is used.
@Suite("Registered native work editing", .serialized)
@MainActor struct StudioRegisteredWorkflowTests {
    private func object(_ output: ToolExecutionOutput) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data((output.capturedOutput ?? output.summary).utf8)) as? [String: Any])
    }
    private func invoke(_ name: String, _ args: [String: Any], _ context: ToolContext) async throws -> ToolExecutionOutput {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: name))
        return try await runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: args), context: context)
    }
    @Test func createdOriginalIsEditableReopenableAndIsolatedFromAnotherTask() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let conversationID = UUID(), otherID = UUID(), runID = UUID(), otherRun = UUID(), now = Date()
        for id in [conversationID, otherID] {
            try await environment.conversationStore.saveConversation(.init(id: id, title: "Native runner qualification", createdAt: now, updatedAt: now))
            _ = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: id, title: "Native runner qualification")
            try await environment.conversationStore.setArchived(id: id, archived: true)
        }
        try await environment.runStore.saveRun(.init(id: runID, conversationID: conversationID, state: "executing", goal: "Native runner qualification", startedAt: now))
        try await environment.runStore.saveRun(.init(id: otherRun, conversationID: otherID, state: "executing", goal: "Native runner isolation", startedAt: now))
        do {
            var context = ToolContext(runID: runID, toolCallID: "create-original", allowedToolNames: StudioCoordinator.names,
                cancellation: CancellationToken(), conversationID: conversationID)
            context.frozenEffectiveCatalogNames = StudioCoordinator.names
            let title = "Runner " + UUID().uuidString.prefix(8)
            do {
                _ = try await invoke("studio.create", ["kind": "diagram", "title": title], context)
                Issue.record("A native mutation proceeded without the runtime grant.")
            } catch { #expect(error.localizedDescription.contains("approval grant")) }
            // The dispatcher supplies this trusted field after its ordinary
            // approval policy; this check exercises the native consumer seam.
            context.approvalGrantID = UUID()
            let creation = try object(try await invoke("studio.create", ["kind": "diagram", "title": title], context))
            let record = try #require(creation["record"] as? [String: Any])
            let projectID = try #require(record["id"] as? String)
            let initial = try object(try await invoke("studio.read", ["projectID": projectID], context))
            let revision = try #require(initial["revision"] as? String)
            let editedTitle = "Edited through native runner"
            context.toolCallID = "rename-original"
            _ = try await invoke("studio.edit", ["projectID": projectID, "expectedRevision": revision,
                "operationsJSON": #"[{"rename":{"_0":"Edited through native runner"}}]"#], context)
            let reopened = try object(try await invoke("studio.read", ["projectID": projectID], context))
            #expect(reopened["title"] as? String == editedTitle)
            let content = try #require(reopened["contentJSON"] as? String)
            let original = try #require(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
            #expect(original["title"] as? String == editedTitle)
            #expect(reopened["revision"] as? String != revision)
            let format = try #require(reopened["editFormat"] as? String)
            let example = try #require(format.components(separatedBy: "\nExample JSON:\n").last)
            let edits = try JSONDecoder().decode([DiagramEdit].self, from: Data(example.utf8))
            #expect(edits.count == 3)
            context.toolCallID = "example-two-boxes-and-line"
            _ = try await invoke("studio.edit", ["projectID": projectID,
                "expectedRevision": try #require(reopened["revision"] as? String), "operationsJSON": example], context)
            let reread = try object(try await invoke("studio.read", ["projectID": projectID], context))
            let persisted = try JSONDecoder().decode(DiagramDocument.self,
                from: Data(try #require(reread["contentJSON"] as? String).utf8))
            for edit in edits {
                switch edit {
                case .upsertElement(let page, let element):
                    #expect(persisted.pages.first(where: { $0.id == page })?.elements.contains(element) == true)
                case .upsertConnection(let page, let connection):
                    #expect(persisted.pages.first(where: { $0.id == page })?.connections.contains(connection) == true)
                default: Issue.record("Unexpected edit in the published diagram example")
                }
            }
            context.toolCallID = "create-original"
            let retried = try object(try await invoke("studio.create", ["kind": "diagram", "title": title], context))
            #expect((retried["record"] as? [String: Any])?["id"] as? String == projectID)
            #expect((retried["record"] as? [String: Any])?["title"] as? String == editedTitle)
            let foreign = ToolContext(runID: otherRun, cancellation: CancellationToken(), conversationID: otherID)
            do {
                _ = try await invoke("studio.read", ["projectID": projectID], foreign)
                Issue.record("Another saved task read an unbound original.")
            } catch { #expect(error.localizedDescription.contains("Open this work")) }
            context.allowedToolNames = []
            do {
                _ = try await invoke("studio.read", ["projectID": projectID], context)
                Issue.record("A frozen tool ceiling was bypassed.")
            } catch { #expect(error.localizedDescription.contains("capabilities")) }
        } catch {
            try? await environment.conversationStore.deleteConversation(id: conversationID)
            try? await environment.conversationStore.deleteConversation(id: otherID)
            throw error
        }
        // The independent personal original intentionally survives task
        // deletion, matching the product ownership contract.
        try await environment.conversationStore.deleteConversation(id: conversationID)
        try await environment.conversationStore.deleteConversation(id: otherID)
    }
}
#endif
