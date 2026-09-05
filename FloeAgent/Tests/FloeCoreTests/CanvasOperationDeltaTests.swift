import Foundation
import Testing
@testable import FloeCore

@Suite("Canvas reusable mutation evidence")
struct CanvasOperationDeltaTests {
    @Test("Create, connect, update and delete return the exact committed delta")
    func mutationChain() throws {
        let document = CanvasDocument(name: "Test")
        let original = CanvasProject(id: UUID(), name: "Test", documents: [document], selectedDocumentID: document.id)
        let a = UUID(), b = UUID(), edge = UUID()
        let (created, first) = try CanvasCommandService.applying(CanvasPatch(
            canvasID: original.id, documentID: document.id, expectedRevision: original.revision,
            operations: [
                .init(kind: .create, nodeID: a, nodeKind: .text, text: "A", position: .init(x: 0, y: 0)),
                .init(kind: .create, nodeID: b, nodeKind: .text, text: "B", position: .init(x: 400, y: 0)),
                .init(kind: .connect, sourceNodeID: a, destinationNodeID: b, connectionID: edge)
            ]
        ), to: original)
        #expect(first.delta?.nodes.map(\.id) == [a, b])
        #expect(first.delta?.connections.map(\.id) == [edge])
        #expect(first.delta?.removedNodeIDs.isEmpty == true)
        let (updated, second) = try CanvasCommandService.applying(CanvasPatch(
            canvasID: first.canvasID, documentID: first.documentID, expectedRevision: first.revision,
            operations: [.init(kind: .update, nodeID: a, text: "Changed")]
        ), to: created)
        #expect(second.delta?.nodes.map(\.text) == ["Changed"])
        let (_, third) = try CanvasCommandService.applying(CanvasPatch(
            canvasID: second.canvasID, documentID: second.documentID, expectedRevision: second.revision,
            operations: [.init(kind: .delete, nodeID: a)]
        ), to: updated)
        #expect(third.delta?.removedNodeIDs == [a])
        #expect(third.delta?.removedConnectionIDs == [edge])
    }

    @Test("Older checkpoint results without delta still decode")
    func oldCheckpoint() throws {
        let result = CanvasOperationResult(canvasID: UUID(), documentID: UUID(), previousRevision: 0,
                                          revision: 1, changedNodeIDs: [], changedConnectionIDs: [])
        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(CanvasOperationResult.self, from: data).delta == nil)
    }
}
