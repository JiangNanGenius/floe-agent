import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration

private actor TypedFakeSourceService: CanvasSourceService {
    struct Entry: Sendable {
        var revision: Int64
        var text: String
        var typed: CanvasContent?
    }
    var entries: [UUID: Entry] = [:]

    func setEntry(_ entry: Entry, for sourceID: UUID) {
        entries[sourceID] = entry
    }

    func currentRevision(sourceID: UUID) throws -> Int64 {
        guard let entry = entries[sourceID] else {
            throw CanvasKitError.sourceUnavailable(sourceID)
        }
        return entry.revision
    }

    func read(sourceID: UUID, fragment: String?) throws -> CanvasSourceContent {
        guard let entry = entries[sourceID] else {
            throw CanvasKitError.sourceUnavailable(sourceID)
        }
        return CanvasSourceContent(
            sourceID: sourceID, revision: entry.revision,
            text: entry.text, fragment: fragment, typedContent: entry.typed)
    }
}

final class TypedSourceRefreshTests: XCTestCase {
    private func makeNode(
        content: CanvasContent, usedRevision: Int64 = 3
    ) -> (CanvasSnapshot, CanvasPageSnapshot, CanvasNodeSnapshot, UUID) {
        let sourceID = UUID()
        let node = CanvasNodeSnapshot(
            content: content,
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 10, height: 10)),
            source: CanvasSourceReference(
                sourceID: sourceID,
                usedRevision: usedRevision,
                annotations: [CanvasSourceAnnotation(author: "u", text: "keep")]
            ))
        let page = CanvasPageSnapshot(nodes: [node])
        let snapshot = CanvasSnapshot(name: "T", pages: [page])
        return (snapshot, page, node, sourceID)
    }

    func testLegacyTextRefreshOnTableNodeCreatesAlternativeNotPlainText() async throws {
        let (snapshot, page, node, sourceID) = makeNode(
            content: .table(header: ["a"], rows: [["b"]]))
        let service = TypedFakeSourceService()
        await service.setEntry(.init(revision: 5, text: "flattened text", typed: nil),
                               for: sourceID)
        let refresher = CanvasSourceRefresher(sourceService: service)
        let result = try await refresher.refresh(
            canvasID: snapshot.id, in: snapshot, pageID: page.id,
            nodeIDs: [node.id], instruction: .default)
        guard case .conflict(let alternatives, let originals) = result.outcome else {
            XCTFail("expected conflict alternative, got \(result.outcome)")
            return
        }
        XCTAssertEqual(originals, [node.id])
        XCTAssertEqual(result.snapshot.pages[0].nodes.count, 2)
        // Original table untouched; the alternative carries the text.
        guard case .table = result.snapshot.pages[0].nodes[0].content else {
            XCTFail("original table was converted")
            return
        }
        guard case .text(let text) = result.snapshot.pages[0].nodes
            .first(where: { $0.id == alternatives[0] })?.content else {
            XCTFail("alternative missing")
            return
        }
        XCTAssertEqual(text, "flattened text")
    }

    func testTypedTablePayloadRefreshesTableInPlacePreservingAnnotations() async throws {
        let (snapshot, page, node, sourceID) = makeNode(
            content: .table(header: ["a"], rows: [["old"]]))
        let service = TypedFakeSourceService()
        await service.setEntry(
            .init(revision: 5, text: "ignored",
                  typed: .table(header: ["a", "b"], rows: [["n1", "n2"]])),
            for: sourceID)
        let refresher = CanvasSourceRefresher(sourceService: service)
        let result = try await refresher.refresh(
            canvasID: snapshot.id, in: snapshot, pageID: page.id,
            nodeIDs: [node.id], instruction: .default)
        guard case .updated(let updated) = result.outcome else {
            XCTFail("expected updated, got \(result.outcome)")
            return
        }
        XCTAssertEqual(updated, [node.id])
        let refreshed = result.snapshot.pages[0].nodes[0]
        guard case .table(let header, let rows) = refreshed.content else {
            XCTFail("table lost")
            return
        }
        XCTAssertEqual(header, ["a", "b"])
        XCTAssertEqual(rows, [["n1", "n2"]])
        XCTAssertEqual(refreshed.source?.annotations.count, 1)
        XCTAssertEqual(refreshed.source?.usedRevision, 5)
    }

    func testFormulaNodeWithTextOnlyPayloadBranches() async throws {
        let (snapshot, page, node, sourceID) = makeNode(
            content: .formula(source: "x^2", renderedAssetID: nil))
        let service = TypedFakeSourceService()
        await service.setEntry(.init(revision: 4, text: "x^3", typed: nil),
                               for: sourceID)
        let refresher = CanvasSourceRefresher(sourceService: service)
        let result = try await refresher.refresh(
            canvasID: snapshot.id, in: snapshot, pageID: page.id,
            nodeIDs: [node.id], instruction: .replace)
        // Even an explicit .replace must not silently flatten a formula.
        guard case .conflict = result.outcome else {
            XCTFail("expected conflict, got \(result.outcome)")
            return
        }
        guard case .formula(let source, _) = result.snapshot.pages[0].nodes[0].content else {
            XCTFail("formula was flattened")
            return
        }
        XCTAssertEqual(source, "x^2")
    }

    func testRichTextPayloadSameKindRefreshesInPlace() async throws {
        let document = CanvasRichTextDocument(runs: [
            CanvasRichTextRun(text: "v1")
        ])
        let (snapshot, page, node, sourceID) = makeNode(
            content: .richText(document: document))
        let service = TypedFakeSourceService()
        await service.setEntry(
            .init(revision: 4, text: "v2",
                  typed: .richText(document: CanvasRichTextDocument(runs: [
                    CanvasRichTextRun(text: "v2", bold: true)
                  ]))),
            for: sourceID)
        let refresher = CanvasSourceRefresher(sourceService: service)
        let result = try await refresher.refresh(
            canvasID: snapshot.id, in: snapshot, pageID: page.id,
            nodeIDs: [node.id], instruction: .default)
        guard case .updated = result.outcome else {
            XCTFail("expected updated, got \(result.outcome)")
            return
        }
        guard case .richText(let decoded) = result.snapshot.pages[0].nodes[0].content else {
            XCTFail("rich text lost")
            return
        }
        XCTAssertEqual(decoded.runs.first?.bold, true)
    }

    func testLegacyTextNodeKeepsExistingInPlaceBehavior() async throws {
        let (snapshot, page, node, sourceID) = makeNode(
            content: .text("old"))
        let service = TypedFakeSourceService()
        await service.setEntry(.init(revision: 9, text: "new", typed: nil),
                               for: sourceID)
        let refresher = CanvasSourceRefresher(sourceService: service)
        let result = try await refresher.refresh(
            canvasID: snapshot.id, in: snapshot, pageID: page.id,
            nodeIDs: [node.id], instruction: .default)
        guard case .updated(let updated) = result.outcome else {
            XCTFail("expected updated, got \(result.outcome)")
            return
        }
        XCTAssertEqual(updated, [node.id])
        guard case .text(let text) = result.snapshot.pages[0].nodes[0].content else {
            XCTFail("text lost")
            return
        }
        XCTAssertEqual(text, "new")
    }
}
