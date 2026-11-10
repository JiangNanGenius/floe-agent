#if canImport(UIKit) && DEBUG
import XCTest
import FloeModels
import FloePersistence
@testable import FloeApp

@MainActor final class NextRoundStudioPolicyTests: XCTestCase {
    func testNewDocumentAssistantReceivesItsInitialPolicy() async throws {
        try await withWork { app, record in
            let id = try await app.studioCoordinator.assistant(for: record)
            let policy = try await SQLiteWorkspaceStore(database: app.database).taskPolicy(conversationID: id)
            XCTAssertEqual(policy.approvalMode, "automatic")
            XCTAssertEqual(policy.networkAllowed, true)
            XCTAssertEqual(policy.uploadAllowed, false)
            XCTAssertEqual(policy.browserControlAllowed, false)
            XCTAssertEqual(policy.credentialsAllowed, false)
            XCTAssertEqual(policy.remoteExecutionAllowed, false)
            let accessible = try await app.studioCoordinator.access.get().canAccess(
                conversationID: id, projectID: record.id, editing: true)
            XCTAssertTrue(accessible)
        }
    }

    func testReopeningTheSameOriginalPreservesEverySavedPolicyField() async throws {
        try await withWork { app, record in
            let id = try await app.studioCoordinator.assistant(for: record)
            let workspace = SQLiteWorkspaceStore(database: app.database)
            let chosen = TaskPolicy(conversationID: id, approvalMode: "ask",
                allowedToolNames: ["studio.read", "studio.edit"], filePaths: ["Drafts"],
                networkAllowed: false, browserControlAllowed: false, uploadAllowed: false,
                credentialsAllowed: false, remoteExecutionAllowed: false,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
            try await workspace.saveTaskPolicy(chosen)
            let before = try await workspace.taskPolicy(conversationID: id)
            let reopened = try await app.studioCoordinator.assistant(for: record)
            let after = try await workspace.taskPolicy(conversationID: id)
            XCTAssertEqual(reopened, id)
            XCTAssertEqual(after, before, "Opening a document must not replace its saved permissions or approval choice")
        }
    }

    private func withWork(_ body: @MainActor (AppEnvironment, PersonalContentRecord) async throws -> Void) async throws {
        let app = try await appQualificationEnvironment()
        let service = PersonalContentService.shared
        let record = try await service.create(kind: .image, title: "QA-Studio-Policy-" + UUID().uuidString)
        func cleanup() async throws {
            let current = try await service.library().resolve(record.id).record
            try await PersonalLibraryFileActions.deleteFromFiles(.work(current), usingTrash: false, environment: app)
        }
        do { try await body(app, record) }
        catch { try? await cleanup(); throw error }
        try await cleanup()
    }
}
#endif
