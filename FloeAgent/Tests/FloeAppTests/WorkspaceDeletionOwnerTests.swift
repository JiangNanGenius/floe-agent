// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCAD
import FloePersistence
@testable import FloeApp

@Suite("Workspace delete active owners", .serialized)
struct WorkspaceDeletionOwnerTests {
    @Test @MainActor func cadSubtreeRetainsEveryPresentationAndDoesNotConfusePrefixSiblings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cad-delete-owner-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await FloeCADDocument.create(at: root.appendingPathComponent("A/model.floecad"), name: "Original")
        defer { document.close() }
        let first = CADFilePresentationLease(), second = CADFilePresentationLease()
        first.attach(document); second.attach(document)
        defer { first.release(); second.release() }
        first.release(); first.release()
        #expect(throws: WorkspaceFileDeletionError.self) { try FloeCAD3DBridge.shared.requireClosedForFileAction(at: root.appendingPathComponent("A")) }
        try FloeCAD3DBridge.shared.requireClosedForFileAction(at: root.appendingPathComponent("AB"))
        #expect(!document.isClosed)
        second.release()
        try FloeCAD3DBridge.shared.requireClosedForFileAction(at: root.appendingPathComponent("A"))
        #expect(FileManager.default.fileExists(atPath: document.url.path))
    }
    @Test @MainActor func officeDescendantRetainsEarlierOwnerWhenTheNewerCommandOwnerReleases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("office-delete-owner-" + UUID().uuidString)
        let first = OfficeFileSession(), second = OfficeFileSession(), registry = OfficeLiveSessionRegistry.shared
        registry.register(session: first, root: root, relativePath: "A/report.docx")
        registry.register(session: second, root: root, relativePath: "A/report.docx")
        defer {
            registry.unregister(session: first, root: root, relativePath: "A/report.docx")
            registry.unregister(session: second, root: root, relativePath: "A/report.docx")
        }
        #expect(registry.session(root: root, relativePath: "A/report.docx") === second)
        registry.unregister(session: second, root: root, relativePath: "A/report.docx")
        // Original command selection semantics stay unchanged: no restoration
        // of A as command target, although A is still a real deletion owner.
        #expect(registry.session(root: root, relativePath: "A/report.docx") == nil)
        #expect(throws: WorkspaceFileDeletionError.self) { try registry.requireClosedForFileAction(root: root, relativePath: "A") }
        try registry.requireClosedForFileAction(root: root, relativePath: "AB")
        registry.unregister(session: first, root: root, relativePath: "A/report.docx")
        try registry.requireClosedForFileAction(root: root, relativePath: "A")
    }
    @Test @MainActor func aConfirmedBatchCannotRetargetTheSameRelativePathAfterSwitchingToAnotherTask() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let center = WorkspaceCenter(environment: environment, publishesSharedState: false)
        let ids = [UUID(), UUID()]
        var roots: [URL] = []
        @MainActor func cleanup() async {
            center.closeCurrentWorkspace()
            for id in ids { try? await environment.conversationStore.deleteConversation(id: id) }
            for root in roots { try? FileManager.default.removeItem(at: root) }
        }
        do {
            for (index, id) in ids.enumerated() {
                let now = Date()
                try await environment.conversationStore.saveConversation(.init(id: id, title: "Frozen delete batch \(index)", createdAt: now, updatedAt: now))
                _ = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: id, title: "Frozen delete batch \(index)")
                try await environment.conversationStore.setArchived(id: id, archived: true)
            }
            try await center.openTaskWorkspace(conversationID: ids[0])
            let rootA = try #require(center.currentRootURL); roots.append(rootA)
            try Data("A original".utf8).write(to: rootA.appendingPathComponent("same.txt"))
            let model = FileTreeViewModel(center: center); await model.loadRoot()
            let batch = try await model.prepareDeletionBatch(["same.txt"], scope: model.loadedScope)
            #expect(batch.requests.map(\.relativePath) == ["same.txt"])
            try await center.openTaskWorkspace(conversationID: ids[1])
            let rootB = try #require(center.currentRootURL); roots.append(rootB)
            try Data("B original".utf8).write(to: rootB.appendingPathComponent("same.txt"))
            await model.loadRoot()
            #expect(model.loadedScope != batch.scope)
            let failures = await model.deleteBatch(batch)
            #expect(Set(failures.keys) == ["same.txt"])
            #expect(try Data(contentsOf: rootA.appendingPathComponent("same.txt")) == Data("A original".utf8))
            #expect(try Data(contentsOf: rootB.appendingPathComponent("same.txt")) == Data("B original".utf8))
        } catch { await cleanup(); throw error }
        await cleanup()
    }

}
#endif
