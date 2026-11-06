import XCTest
@testable import FloeCanvasCore

final class SnapshotCodableTests: XCTestCase {
    func testSnapshotRoundTrip() throws {
        var page = CanvasPageSnapshot(name: "Main")
        page.nodes = [
            CanvasNodeSnapshot(
                title: "Note",
                content: .markdown(document: "# Hello", previewText: "Hello"),
                frame: CanvasGeometry.Frame(
                    center: .init(x: 10, y: 20),
                    size: .init(width: 300, height: 200)),
                isLocked: true,
                source: CanvasSourceReference(
                    sourceID: UUID(),
                    fragment: "page:2",
                    usedRevision: 7,
                    annotations: [CanvasSourceAnnotation(author: "user", text: "keep me")]
                ),
                metadata: ["k": "v"]
            )
        ]
        page.connections = [
            CanvasConnectionSnapshot(
                sourceNodeID: page.nodes[0].id,
                destinationNodeID: page.nodes[0].id,
                kind: .arrow,
                label: "self"
            )
        ]
        page.regions = [CanvasRegionRecord(
            name: "Folded", frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 100, height: 100)),
            isCollapsed: true)]
        page.groups = [CanvasGroupRecord(name: "G", memberNodeIDs: [page.nodes[0].id])]
        page.scenes = [CanvasSceneRecord(name: "Intro", viewportScale: 0.8)]
        let snapshot = CanvasSnapshot(
            name: "Test",
            pages: [page],
            viewports: [page.id: CanvasViewport(center: .init(x: 1, y: 2), scale: 1.5)],
            revision: 42
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let decoded = try JSONDecoder().decode(CanvasSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.revision, 42)
        XCTAssertEqual(decoded.selectedPage?.nodes.first?.source?.annotations.count, 1)
    }

    func testUnknownContentPayloadSurvivesRoundTrip() throws {
        let payload = JSONValue.object([
            "kind": .string("hologram"),
            "matrix": .array([.number("1.5"), .number("2")]),
            "flags": .object(["nested": .bool(true)])
        ])
        let node = CanvasNodeSnapshot(
            content: .unknown(kind: "hologram", payload: payload),
            frame: CanvasGeometry.Frame(center: .zero, size: .init(width: 1, height: 1))
        )
        let snapshot = CanvasSnapshot(name: "U", pages: [CanvasPageSnapshot(nodes: [node])])

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CanvasSnapshot.self, from: data)
        guard case .unknown(let kind, let decodedPayload) =
            decoded.pages[0].nodes[0].content else {
            XCTFail("unknown content lost")
            return
        }
        XCTAssertEqual(kind, "hologram")
        guard case .object(let object) = decodedPayload else {
            XCTFail("payload shape lost")
            return
        }
        XCTAssertEqual(object["matrix"]?.arrayValue?.first?.numberLiteral, "1.5")
    }

    func testStructuredContentCasesRoundTrip() throws {
        let asset = CanvasAssetLocator(
            id: UUID(), contentHash: "sha256:x", relativePath: "a/b.png",
            mimeType: "image/png", byteCount: 10)
        let contents: [CanvasContent] = [
            .text("t"),
            .markdown(document: "m", previewText: nil),
            .code(language: "swift", source: "let a = 1"),
            .formula(source: "e=mc^2", renderedAssetID: nil),
            .table(header: ["a"], rows: [["1"]]),
            .media(asset),
            .pdf(documentAssetID: asset.id, pageRange: 2...5),
            .web(URL(string: "https://example.org")!, title: "Ex"),
            .editor(CanvasEditorReference(
                projectID: UUID(), appliedRevision: 3, editorKind: "cad"))
        ]
        for content in contents {
            let data = try JSONEncoder().encode(content)
            let decoded = try JSONDecoder().decode(CanvasContent.self, from: data)
            XCTAssertEqual(decoded, content)
        }
    }
}
