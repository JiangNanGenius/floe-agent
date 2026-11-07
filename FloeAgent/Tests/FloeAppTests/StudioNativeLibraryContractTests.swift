// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && DEBUG
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeSecurity
import FloeTools
@testable import FloeApp

@Suite("Registered native Library recoverable actions", .serialized)
@MainActor struct StudioNativeLibraryContractTests {
    private func invoke(_ args: [String: Any], context: ToolContext) async throws -> [String: Any] {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: "studio.library"))
        let result = try await runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: args), context: context)
        let data = Data((result.capturedOutput ?? result.summary).utf8)
        #expect(StudioToolOutput.hash(data) == result.fullOutputSHA256)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func contexts(_ body: @MainActor (AppEnvironment, ToolContext, ToolContext) async throws -> Void) async throws {
        let app = try await appQualificationEnvironment(); try await app.ensureDurableAutomationReady()
        var ids: [UUID] = [], values: [ToolContext] = []
        func cleanup() async { for id in ids { try? await app.conversationStore.deleteConversation(id: id) } }
        do {
            for _ in 0..<2 {
                let id = UUID(), run = UUID(), now = Date(); ids.append(id)
                try await app.conversationStore.saveConversation(.init(id: id, title: "N13 Library contract", createdAt: now, updatedAt: now))
                try await app.conversationStore.setArchived(id: id, archived: true)
                try await app.runStore.saveRun(.init(id: run, conversationID: id, state: "executing", goal: "Recoverable native Library action", startedAt: now))
                var context = ToolContext(runID: run, toolCallID: "native-library-contract", allowedToolNames: StudioCoordinator.names,
                    cancellation: CancellationToken(), conversationID: id)
                context.frozenEffectiveCatalogNames = StudioCoordinator.names
                values.append(context) // Native works do not require a Linux/workspace directory.
            }
            try await body(app, values[0], values[1]); await cleanup()
        } catch { await cleanup(); throw error }
    }
    private func original(_ kind: PersonalContentKind, app: AppEnvironment, context: ToolContext,
                          body: @MainActor (PersonalContentRecord, URL) async throws -> Void) async throws {
        let record = try await PersonalContentService.shared.create(kind: kind, title: "QA-N13-Library-" + UUID().uuidString.prefix(8))
        let library = try await PersonalContentService.shared.library(), location = try await library.resolve(record.id)
        // Trusted native fixture binding, through the real persistent authority.
        try await app.studioCoordinator.access.get().finishCreation(conversationID: context.conversationID!, projectID: record.id)
        do {
            try await body(record, location.url)
            if let current = try? await library.resolve(record.id) { try await PersonalLibraryFileActions.delete(current.record, environment: app) }
        } catch {
            if let current = try? await library.resolve(record.id) { try? await PersonalLibraryFileActions.delete(current.record, environment: app) }
            throw error
        }
    }
    private func detail(_ id: UUID, context: ToolContext) async throws -> [String: Any] {
        let result = try await invoke(["action": "detail", "projectID": id.uuidString], context: context)
        return try #require(result["item"] as? [String: Any])
    }
    private func mutation(_ action: String, id: UUID, item: [String: Any], context initial: ToolContext) async throws -> [String: Any] {
        var context = initial; context.approvalGrantID = UUID(); context.toolCallID = "approved-native-library-" + UUID().uuidString
        var args: [String: Any] = ["action": action, "projectID": id.uuidString, "expectedIdentity": try #require(item["identity"] as? String)]
        if action == "restore" { args["trashEntryID"] = try #require(item["trashEntryID"] as? String) }
        return try await invoke(args, context: context)
    }

    @Test func actualWrapperTrashRestorePreservesBytesAndFencesBusyStaleAndLateDeletes() async throws {
        try await contexts { app, context, _ in
            try await original(.document, app: app, context: context) { record, directory in
                let library = try await PersonalContentService.shared.library(), source = try await PersonalContentService.shared.originalFile(record.id)
                let bytes = try Data(contentsOf: source), before = try await detail(record.id, context: context)
                let lease = try PersonalLibraryFileActions.acquireUse(id: record.id, directory: directory)
                do { _ = try await mutation("delete", id: record.id, item: before, context: context); Issue.record("An open original was deleted") } catch {}
                lease.release()
                try await library.markChanged(record.id)
                do { _ = try await mutation("delete", id: record.id, item: before, context: context); Issue.record("A stale original identity was deleted") } catch {}
                let current = try await detail(record.id, context: context)
                let deleted = try await mutation("delete", id: record.id, item: current, context: context)
                let tombstone = try #require(deleted["item"] as? [String: Any])
                #expect(tombstone["deletedAt"] != nil && tombstone["trashEntryID"] != nil)
                #expect(try Data(contentsOf: source) == bytes)
                let reopened = PersonalContentLibrary(root: await library.root)
                #expect(try await reopened.records().allSatisfy { $0.id != record.id })
                #expect(try await reopened.recentlyDeleted().contains { $0.projectID == record.id })
                _ = try await mutation("restore", id: record.id, item: tombstone, context: context)
                let restored = try await library.resolve(record.id), after = try await detail(record.id, context: context)
                #expect(restored.record.id == record.id && restored.url == directory && restored.record.deletedAt == nil)
                #expect(try Data(contentsOf: source) == bytes)
                #expect(after["identity"] as? String != current["identity"] as? String, "Restore must retire an earlier approved delete pin")
                do { _ = try await mutation("delete", id: record.id, item: current, context: context); Issue.record("A late old delete re-deleted the restored original") } catch {}
                #expect(try await library.resolve(record.id).record.deletedAt == nil)
            }
        }
    }

    @Test func registeredListsAreTaskScopedAndUnapprovedForeignTemporaryAndUnknownMutationsWriteNothing() async throws {
        try await contexts { app, first, foreign in
            try await original(.document, app: app, context: first) { record, _ in
                let library = try await PersonalContentService.shared.library(), item = try await detail(record.id, context: first)
                let own = try await invoke(["action": "list"], context: first), other = try await invoke(["action": "list"], context: foreign)
                #expect((own["items"] as? [[String: Any]])?.contains { ($0["projectID"] as? String)?.lowercased() == record.id.uuidString.lowercased() } == true)
                #expect((other["items"] as? [[String: Any]])?.isEmpty == true)
                let before = try await library.recentlyDeleted()
                let args: [String: Any] = ["action": "delete", "projectID": record.id.uuidString, "expectedIdentity": try #require(item["identity"] as? String)]
                var approvedForeign = foreign; approvedForeign.approvalGrantID = UUID()
                var temporary = first; temporary.temporaryReadOnly = true; temporary.approvalGrantID = UUID()
                var cancelled = first; cancelled.cancellation = CancellationToken(); cancelled.cancellation.cancel(); cancelled.approvalGrantID = UUID()
                for context in [first, approvedForeign, temporary, cancelled] {
                    do { _ = try await invoke(args, context: context); Issue.record("A missing approval/foreign/temporary/cancelled mutation was accepted") } catch {}
                }
                for invalid in [["action": "purge", "projectID": record.id.uuidString], ["action": "delete", "path": "guess.floeproject"], ["action": "list", "permanent": true]] as [[String: Any]] {
                    do { _ = try await invoke(invalid, context: first); Issue.record("Unknown/permanent/path-shaped library input was accepted") } catch {}
                }
                #expect(try await library.recentlyDeleted() == before)
                #expect(OrdinaryDocumentActionProfile.role(forToolName: "studio.library", arguments: ["action": "list"]) == .readOnly)
                #expect(OrdinaryDocumentActionProfile.role(forToolName: "studio.library", arguments: args) == nil)
                #expect(OrdinaryDocumentActionProfile.role(forToolName: "studio.library", arguments: ["action": "restore"]) == nil)
            }
        }
    }

    @Test func registeredBiologyTrashAndRestoreUseTheRealNativeStoreAndBinding() async throws {
        try await contexts { app, context, _ in
            try await original(.biology, app: app, context: context) { record, directory in
                let host = try await app.biologyComposition.host(), library = try await PersonalContentService.shared.library()
                let native = try await host.store.load(record.id), binding = directory.appendingPathComponent("biology-binding.json"), bytes = try Data(contentsOf: binding)
                let current = try await detail(record.id, context: context)
                let deleted = try await mutation("delete", id: record.id, item: current, context: context)
                #expect(try await host.store.deletedProjects().contains { $0.projectID == record.id })
                let tombstone = try #require(deleted["item"] as? [String: Any])
                _ = try await mutation("restore", id: record.id, item: tombstone, context: context)
                let restored = try await library.resolve(record.id)
                try BiologyOriginalBinding.verify(id: record.id, directory: restored.url)
                #expect(try Data(contentsOf: binding) == bytes)
                #expect(try await host.store.load(record.id).id == native.id)
                #expect(try await host.store.deletedProjects().allSatisfy { $0.projectID != record.id })
            }
        }
    }
}
#endif
