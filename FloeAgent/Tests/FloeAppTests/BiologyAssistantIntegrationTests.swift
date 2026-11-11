// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeTools
import FloeBiologyCore
import FloeBiologyEngine
import FloeBiologyHostAdapter
@testable import FloeApp

/// The biology editor's AI surface is the same persistent shared file
/// assistant as every other editor: one durable conversation binding per
/// original, real registered-tool discovery for blank creation, and no
/// isolated one-shot request path. These tests exercise the App-side
/// contracts that wiring relies on through the real store/bridge boundary.
@Suite("Biology shared assistant and blank creation integration", .serialized)
@MainActor struct BiologyAssistantIntegrationTests {
    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("biology-assistant-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private struct Fixture: Sendable {
        let root: URL
        let database: DatabaseManager
        let conversations: SQLiteConversationStore
        let authority: StudioDocumentAccess
        let library: PersonalContentLibrary
        let store: BiologyProjectStore
        let access: BiologyHostAccess
        let taskID: UUID
        let runID: UUID
        let projectID: UUID
        let registry: ToolRunnerRegistry
        let service: BiologyService
        @MainActor func context(_ tool: String, call: String = UUID().uuidString) -> ToolContext {
            var context = ToolContext(runID: runID, toolCallID: call,
                allowedToolNames: BiologyHostServices.names, workspaceRootURL: root,
                cancellation: CancellationToken(), conversationID: taskID,
                frozenEffectiveCatalogNames: BiologyHostServices.names)
            context.executionToolName = tool
            return context
        }
    }

    private func fixture() async throws -> Fixture {
        let root = try sandbox()
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let authority = try StudioDocumentAccess(root: root.appendingPathComponent("Authority"))
        let libraryRoot = root.appendingPathComponent("Library"), library = PersonalContentLibrary(root: libraryRoot)
        let store = try BiologyProjectStore(root: root.appendingPathComponent("Projects"))
        let taskID = UUID(), runID = UUID(), projectID = UUID(), now = Date()
        try await conversations.saveConversation(.init(id: taskID, title: "Shared assistant task", createdAt: now, updatedAt: now))
        try await runs.saveRun(.init(id: runID, conversationID: taskID, state: "executing", goal: "Contract", startedAt: now))
        _ = try await library.create(kind: .biology, title: "Board", id: projectID) { directory, id in
            _ = try await store.createBound(id: id, title: "Board")
            try BiologyOriginalBinding(projectID: id).write(to: directory)
        }
        try await authority.finishCreation(conversationID: taskID, projectID: projectID)
        try await authority.bindAssistant(conversationID: taskID, projectID: projectID)
        let access = BiologyHostAccess(runs: runs, conversations: conversations, authority: authority,
            libraryRoot: libraryRoot, library: { library })
        let service = try BiologyService(store: store, authorize: { try await access.permit($0) })
        let bridge = BiologyToolBridge(service: service, contexts: BiologyExecutionContexts(),
            grant: { try await access.grant($0) }, registerCreatedProject: { _, _ in throw BiologyHostError.readOnly })
        let registry = ToolRunnerRegistry(); try await bridge.register(in: registry)
        let hooks = BiologyLibraryHooks(attachCreated: { _, _ in throw BiologyHostError.readOnly },
            lifecycle: { _, _, _ in throw BiologyHostError.readOnly })
        let boundary = BiologyToolCallBoundary(access: access, hooks: hooks, didMutate: { ids, name in
            if name != "biology.deleteProject" { try await access.synchronizeMetadata(ids, store: store) }
        })
        for name in BiologyHostServices.names {
            let original = try #require(registry.runner(named: name))
            let isolated = AnyAgentTool(descriptor: original.descriptor, run: original.run,
                validateArguments: original.validateArguments,
                preflightSubmission: original.preflightSubmission, routing: ToolEnvironmentRouting())
            registry.register(boundary.wrap(isolated))
        }
        return Fixture(root: root, database: database, conversations: conversations,
            authority: authority, library: library, store: store, access: access,
            taskID: taskID, runID: runID, projectID: projectID, registry: registry, service: service)
    }

    @Test func assistantBindingIsOnePersistentConversationPerOriginal() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        // The shared assistant resolves through the same durable binding the
        // Studio coordinator uses; reopening never mints a second conversation.
        let first = try await f.authority.assistant(projectID: f.projectID)
        let second = try await f.authority.assistant(projectID: f.projectID)
        #expect(first == f.taskID && second == f.taskID)
        let conversation = try #require(try await f.conversations.conversation(id: f.taskID))
        #expect(conversation.purpose == .ordinary)
        // An original never touched by creation has no silently invented assistant.
        let unbound = UUID()
        #expect(try await f.authority.assistant(projectID: unbound) == nil)
    }

    @Test func blankCreateRenameAndDeleteFlowThroughRegisteredBridge() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        // Writable discovery: blank creation is a real, revision-checked edit
        // tool, not a UI-only appearance.
        #expect(!BiologyToolSchemas.readOnlyNames.contains("biology.update"))
        let update = try #require(f.registry.runner(named: "biology.update"))
        let head = try await f.store.load(f.projectID)
        let created = try await update.execute(argumentsJSON: try BiologyCoding.encode(BiologyJSON.object([
            "projectID": .string(f.projectID.uuidString), "operation": .string("asset.create"),
            "expectedRevision": .number(Double(head.revision)),
            "parameters": .object(["title": .string("Construct"), "kind": .string("sequence"),
                "sequence": .string("ATGGCTAGCACTGAGT"),
                "annotation": .object(["name": .string("CDS"), "start": .number(0), "end": .number(16)])])])), context: f.context("biology.update", call: "blank-create"))
        #expect(created.exitStatus == 0)
        let captured = try #require(created.capturedOutput)
        let createdResult = try JSONDecoder().decode(BiologyJSON.self, from: Data(captured.utf8))
        let createdID = try #require(createdResult["assetID"]?.string)
        let withSequence = try await f.store.load(f.projectID)
        #expect(withSequence.assets.count == 1)
        #expect(withSequence.activeAssetID?.uuidString == createdID)
        guard case .sequence(let records) = withSequence.assets[0].payload else { Issue.record("Sequence missing"); return }
        #expect(records[0].annotations.count == 1)
        // Rename through the same bridge.
        let renamed = try await update.execute(argumentsJSON: try BiologyCoding.encode(BiologyJSON.object([
            "projectID": .string(f.projectID.uuidString), "assetID": .string(createdID), "operation": .string("asset.rename"),
            "expectedRevision": .number(1), "parameters": .object(["title": .string("Construct R1")])])), context: f.context("biology.update", call: "blank-rename"))
        #expect(renamed.exitStatus == 0)
        // A starter network is creatable on the same empty board.
        let network = try await update.execute(argumentsJSON: try BiologyCoding.encode(BiologyJSON.object([
            "projectID": .string(f.projectID.uuidString), "operation": .string("asset.create"),
            "expectedRevision": .number(Double(try await f.store.load(f.projectID).revision)),
            "parameters": .object(["title": .string("Pathway"), "kind": .string("biochemicalNetwork")])])), context: f.context("biology.update", call: "blank-network"))
        #expect(network.exitStatus == 0)
        // Deletion removes the real stored dataset and moves the active selection.
        let beforeDeletion = try await f.store.load(f.projectID)
        let assetToDelete = try #require(beforeDeletion.assets.first { $0.id.uuidString == createdID })
        let removed = try await update.execute(argumentsJSON: try BiologyCoding.encode(BiologyJSON.object([
            "projectID": .string(f.projectID.uuidString), "assetID": .string(createdID), "operation": .string("asset.delete"),
            "expectedRevision": .number(Double(assetToDelete.revision)), "parameters": .object([:])])), context: f.context("biology.update", call: "blank-delete"))
        #expect(removed.exitStatus == 0)
        let after = try await f.store.load(f.projectID)
        #expect(after.assets.count == 1)
        #expect(after.assets[0].kind == .biochemicalNetwork)
        #expect(after.activeAssetID == after.assets[0].id)
    }

    @Test func blankCreateRejectsUnsupportedKindAndOutOfRangeAnnotation() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let update = try #require(f.registry.runner(named: "biology.update"))
        let head = try await f.store.load(f.projectID)
        for parameters in [
            BiologyJSON.object(["title": .string("X"), "kind": .string("microscopyImage")]),
            BiologyJSON.object(["title": .string("X"), "kind": .string("sequence"), "sequence": .string("ATGC"),
                "annotation": .object(["name": .string("bad"), "start": .number(2), "end": .number(99)])]),
        ] {
            do {
                _ = try await update.execute(argumentsJSON: try BiologyCoding.encode(BiologyJSON.object([
                    "projectID": .string(f.projectID.uuidString), "operation": .string("asset.create"),
                    "expectedRevision": .number(Double(head.revision)), "parameters": parameters])), context: f.context("biology.update"))
                Issue.record("Invalid blank creation reached the original")
            } catch { }
        }
        #expect(try await f.store.load(f.projectID).assets.isEmpty)
    }
}
#endif
