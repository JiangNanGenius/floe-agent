import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration

/// Native snapshot fidelity through the REAL file repository: unknown
/// payload literals (beyond Int64 / high precision) must survive commit,
/// undo and a full close/reopen byte-for-byte at the JSONValue level.
final class FileRepositoryFidelityTests: XCTestCase {
    private func makeSnapshot() -> CanvasSnapshot {
        let payload = JSONValue.object([
            "bigint": .number("9223372036854775808123"),
            "decimal": .number("0.12345678901234567890123456789"),
            "twoPointZero": .number("2.0"),
            "negativeZero": .number("-0"),
            "exponent": .number("1e0"),
            "markerLookalike": .object([
                "$floecanvas.rawNumber": .object([
                    "literal": .string("123"),
                ]),
            ]),
            "ordinary": .object(["nested": .array([.number("1.50")])]),
        ])
        let node = CanvasNodeSnapshot(
            content: .unknown(kind: "hologram", payload: payload),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 10, height: 10)))
        return CanvasSnapshot(
            name: "Fidelity", pages: [CanvasPageSnapshot(nodes: [node])])
    }

    private func payloadOf(_ snapshot: CanvasSnapshot) -> JSONValue? {
        guard case .unknown(_, let payload) =
            snapshot.pages[0].nodes[0].content else { return nil }
        return payload
    }

    func testUnknownPayloadLiteralsSurviveCommitUndoAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-fidelity-\(UUID().uuidString)")
        let snapshot = makeSnapshot()
        let originalPayload = payloadOf(snapshot)!
        do {
            let repo = try FileCanvasRepository(root: root)
            try await repo.create(
                canvasID: snapshot.id, snapshot: snapshot, requestID: UUID())
            let node = snapshot.pages[0].nodes[0]
            let batch = CanvasEditBatch(
                pageID: snapshot.pages[0].id,
                operations: [.updateTitle(nodeID: node.id, title: "touched")])
            try await repo.commit(
                batch, canvasID: snapshot.id,
                expectedRevision: 0, requestID: UUID())

            // Undo back to the revision holding the original payload, then
            // a full reopen: literals must be EXACTLY equal.
            _ = try await repo.undo(canvasID: snapshot.id)
            let reopened = try FileCanvasRepository(root: root)
            let loaded = try await reopened.load(canvasID: snapshot.id)
            XCTAssertEqual(payloadOf(loaded), originalPayload)
            XCTAssertEqual(
                loaded.pages[0].nodes[0].content.unknownKind, "hologram")
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testDocumentBatchSurvivesReopenWithGraphsAndCards() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-docfile-\(UUID().uuidString)")
        let snapshot = makeSnapshot()
        do {
            let repo = try FileCanvasRepository(root: root)
            try await repo.create(
                canvasID: snapshot.id, snapshot: snapshot, requestID: UUID())
            let flowNode = FlowNode(
                kind: .source, name: "in",
                parameters: CanvasFlowSourceBinding(
                    canvasID: snapshot.id, pageID: snapshot.pages[0].id,
                    nodeID: snapshot.pages[0].nodes[0].id,
                    usedRevision: 0).parameters())
            let graph = FlowGraph(id: UUID(), revision: 0, nodes: [flowNode])
            _ = try await repo.commitDocument(
                CanvasDocumentBatch(operations: [
                    .insertFlowGraph(pageID: snapshot.pages[0].id, graph: graph)
                ]),
                canvasID: snapshot.id,
                expectedRevision: 0, requestID: UUID())

            let reopened = try FileCanvasRepository(root: root)
            let loaded = try await reopened.load(canvasID: snapshot.id)
            XCTAssertEqual(loaded.pages[0].flowGraphs, [graph])
            let locator = CanvasFlowSourceBinding(
                parameters: loaded.pages[0].flowGraphs[0].nodes[0].parameters)
            XCTAssertEqual(locator?.nodeID, snapshot.pages[0].nodes[0].id)

            // Undo the document batch after reopen.
            _ = try await reopened.undo(canvasID: snapshot.id)
            let undone = try await reopened.load(canvasID: snapshot.id)
            XCTAssertTrue(undone.pages[0].flowGraphs.isEmpty)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        try? FileManager.default.removeItem(at: root)
    }
}
