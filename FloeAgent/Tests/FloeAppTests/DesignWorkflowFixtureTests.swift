// FloeAppTests — Design workflow GUI fixture seeding: the named synthetic
// fixtures must seed COMPLETELY through the real stores/typed services
// (conversation + workspace + launch binding + owner envelope + freeze), so
// the UI acceptance can rely on them. A partial seed (conversation without
// binding/candidate) would present a thread with no design page — this test
// fails loudly instead.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.DesignWorkflowFixture")
@MainActor
struct DesignWorkflowFixtureTests {
    private func makeEnvironment() async throws -> AppEnvironment {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        return environment
    }

    @Test("every named fixture seeds its conversation, binding, envelope and freeze")
    func fixturesSeedCompletely() async throws {
        let environment = try await makeEnvironment()
        await DesignWorkflowFixture.seedModifyFixture(environment: environment)
        await DesignWorkflowFixture.seedCreativeFixture(environment: environment)
        await DesignWorkflowFixture.seedRestructureFixture(environment: environment)
        await DesignWorkflowFixture.seedOfficeFixture(environment: environment)

        let store = SQLiteConversationStore(database: environment.database)
        let workspaceStore = SQLiteWorkspaceStore(database: environment.database)
        let workflow = environment.designOwnerWorkflow
        let registry = DesignFreezeRegistry.shared

        // The production thread mounts the task root before the design page
        // resolves anything; hold the same leases while asserting so the
        // file-owner adapter authorization sees the mounted roots.
        func lease(for conversationID: UUID) async throws -> WorkspaceCenter.TaskRootLease {
            let workspaceID = try #require(DesignWorkflowFixture.fixtureWorkspaceIDs[conversationID])
            let record = try #require(try await workspaceStore.workspace(id: workspaceID))
            return try await environment.workspaceCenter.acquireTaskRoot(record, conversationID: conversationID)
        }
        let modifyLease = try await lease(for: DesignWorkflowFixture.modifyConversationID)
        let restructureLease = try await lease(for: DesignWorkflowFixture.restructureConversationID)
        let officeLease = try await lease(for: DesignWorkflowFixture.officeConversationID)
        defer {
            modifyLease.release()
            restructureLease.release()
            officeLease.release()
        }

        // 1. Bound modify: conversation + binding + envelope with base +
        //    pending candidate + live freeze.
        let modify = DesignWorkflowFixture.modifyConversationID
        let modifyConversation = try #require(try await store.conversation(id: modify))
        #expect(modifyConversation.title == "设计验收-网页修改")
        let modifyBinding = try #require(DesignLaunchBindingStore.load(conversationID: modify))
        #expect(modifyBinding.workMode == .modify)
        let modifyEnvelope = try #require(try await workflow.state(modifyBinding.target))
        #expect(modifyEnvelope.project.candidates.contains { $0.status == .pending })
        #expect(registry.protection(
            for: modifyLease.url.appendingPathComponent("site/index.html")) != nil)

        // 2. Creative: first result bound + one pending candidate, AND the
        //    sidebar ownership row (conversation_workspace_ownership via the
        //    real workspace store) so it lists in the chat section.
        let creative = DesignWorkflowFixture.creativeConversationID
        let creativeConversation = try #require(try await store.conversation(id: creative))
        #expect(creativeConversation.title == "设计验收-创意成果")
        #expect(try await workspaceStore.workspaceID(conversationID: creative) != nil,
                "the creative fixture must own a workspace so the sidebar lists it")
        let creativeBinding = try #require(DesignLaunchBindingStore.load(conversationID: creative))
        #expect(creativeBinding.workMode == .create)
        let creativeEnvelope = try #require(try await workflow.state(creativeBinding.target))
        #expect(creativeEnvelope.project.creativeRequest?.state == .firstResultBound)
        #expect(creativeEnvelope.project.candidates.contains { $0.status == .pending })

        // 3. Restructure: frozen webroot directory original.
        let restructure = DesignWorkflowFixture.restructureConversationID
        let restructureBinding = try #require(DesignLaunchBindingStore.load(conversationID: restructure))
        #expect(restructureBinding.workMode == .restructure)
        #expect(restructureBinding.frozenRestructureOperationID != nil)
        #expect(registry.protection(
            for: restructureLease.url.appendingPathComponent("site")) != nil)

        // 4. Office: readonly-preview fixture with a pending candidate and a
        //    frozen original.
        let office = DesignWorkflowFixture.officeConversationID
        let officeBinding = try #require(DesignLaunchBindingStore.load(conversationID: office))
        let officeEnvelope = try #require(try await workflow.state(officeBinding.target))
        #expect(officeEnvelope.project.candidates.contains { $0.status == .pending })
        #expect(registry.protection(
            for: officeLease.url.appendingPathComponent("文稿.docx")) != nil)

        // Cleanup: release the fixture-owned freezes so the shared registry
        // is not polluted for other tests in the process.
        for id in [modify, restructure, office] {
            DesignFreezeProtectionCoordinator.release(conversationID: id)
        }
    }
}
#endif
