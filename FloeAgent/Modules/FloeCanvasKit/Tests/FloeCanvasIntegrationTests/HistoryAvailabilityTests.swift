import Foundation
import XCTest
import FloeCanvasCore
@testable import FloeCanvasIntegration

final class HistoryAvailabilityTests: XCTestCase {
    func testAvailabilityUsesStacksAndSurvivesReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = CanvasPageSnapshot(name: "History")
        let snapshot = CanvasSnapshot(name: "History", pages: [page])
        let file = try FileCanvasRepository(root: root)
        try await file.create(canvasID: snapshot.id, snapshot: snapshot, requestID: UUID())
        try await verify(file, snapshot: snapshot, page: page)
        let reopened = try FileCanvasRepository(root: root)
        let state = try await reopened.historyAvailability(canvasID: snapshot.id)
        XCTAssertEqual(state, .init(undoCount: 1, redoCount: 0))
        let audit = try await reopened.undoHistory(canvasID: snapshot.id)
        XCTAssertEqual(audit.count, 2, "audit entries are independent of available stack counts")
        try await verify(InMemoryCanvasRepository(snapshot: snapshot), snapshot: snapshot, page: page)
    }

    private func verify(_ repository: any CanvasDocumentStore,
                        snapshot: CanvasSnapshot, page: CanvasPageSnapshot) async throws {
        let empty = try await repository.historyAvailability(canvasID: snapshot.id)
        XCTAssertEqual(empty, .init(undoCount: 0, redoCount: 0))
        let receipt = try await repository.commit(.init(pageID: page.id, scope: .wholeDocument,
            operations: [.insertNode(.init(content: .text("one edit"),
                frame: .init(center: .zero, size: .init(width: 200, height: 100))))]),
            canvasID: snapshot.id, expectedRevision: 0, requestID: UUID())
        let edited = try await repository.historyAvailability(canvasID: snapshot.id)
        XCTAssertEqual(edited, .init(undoCount: 1, redoCount: 0))
        let undo = try await repository.undo(canvasID: snapshot.id,
            expectedRevision: receipt.revision, requestID: UUID())
        let undone = try await repository.historyAvailability(canvasID: snapshot.id)
        XCTAssertEqual(undone, .init(undoCount: 0, redoCount: 1))
        _ = try await repository.redo(canvasID: snapshot.id,
            expectedRevision: undo.revision, requestID: UUID())
        let redone = try await repository.historyAvailability(canvasID: snapshot.id)
        XCTAssertEqual(redone, .init(undoCount: 1, redoCount: 0))
    }
}
