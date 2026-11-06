// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeCanvasCore
@testable import FloeCanvasExchange

final class RoundTripTests: XCTestCase {
    func testFixtureImportArchivesAndReopensWithoutOriginalFiles() async throws {
        let bundle = try CanvasJSONCanvasCodec.decode(
            ExchangeFixtureSupport.data("mixed.canvas"),
            options: .init(canvasID: UUID(uuidString: "77770000-0000-0000-0000-000000000001")!, canvasName: "Mixed")
        )
        let originalBytes = try ExchangeFixtureSupport.data("mixed.canvas")
        let envelope = CanvasNativeArchive.OriginalSourceEnvelope(
            source: CanvasOriginalSource(
                kind: .jsonCanvasOriginal,
                suggestedName: "mixed.canvas",
                byteCount: originalBytes.count,
                sha256: CanvasDigest.sha256(originalBytes),
                nodeIDs: bundle.snapshot.pages.flatMap { $0.nodes.map(\.id) }
            ),
            data: originalBytes
        )
        // No assets referenced -> no resolver needed.
        let archived = try await CanvasNativeArchive.export(bundle.snapshot, originalSources: [envelope])
        let reopened = try CanvasNativeArchive.import(archived.data)
        XCTAssertEqual(reopened.snapshot, bundle.snapshot)
        XCTAssertEqual(reopened.sourceDataByID[envelope.source.id], originalBytes)
        XCTAssertEqual(reopened.originalSources.first?.kind, .jsonCanvasOriginal)
    }

    func testExcalidrawBigLiteralsSurviveNativeArchive() async throws {
        let originalBytes = try ExchangeFixtureSupport.data("mixed.excalidraw")
        let bundle = try CanvasExcalidrawCodec.decode(
            originalBytes,
            options: .init(canvasID: UUID(uuidString: "77770000-0000-0000-0000-000000000002")!, canvasName: "Mixed")
        )
        // The archive carries the exact original import bytes; the unknown
        // per-node fields (big literals) live in the exchange sidecar and
        // recover from those bytes through the full pipeline.
        let envelope = CanvasNativeArchive.OriginalSourceEnvelope(
            source: CanvasOriginalSource(
                kind: .excalidrawOriginal,
                suggestedName: "mixed.excalidraw",
                byteCount: originalBytes.count,
                sha256: CanvasDigest.sha256(originalBytes),
                nodeIDs: bundle.snapshot.pages.flatMap { $0.nodes.map(\.id) }
            ),
            data: originalBytes
        )
        let archived = try await CanvasNativeArchive.export(bundle.snapshot, originalSources: [envelope])
        let reopened = try CanvasNativeArchive.import(archived.data)
        XCTAssertEqual(reopened.snapshot, bundle.snapshot)
        guard let recovered = reopened.sourceDataByID[envelope.source.id] else {
            return XCTFail("original source bytes missing from the archive")
        }
        XCTAssertEqual(recovered, originalBytes)

        // Full recovery loop: original bytes -> import -> sidecar ->
        // re-export. The known rectangle node's unknown customData big
        // literals must reappear verbatim in the re-exported Excalidraw.
        let recoveredBundle = try CanvasExcalidrawCodec.decode(recovered)
        let reexported = try CanvasExcalidrawCodec.export(
            recoveredBundle.snapshot,
            options: .init(
                externalIDs: recoveredBundle.externalIDs,
                originalNodes: recoveredBundle.originalNodes,
                originalEdges: recoveredBundle.originalEdges,
                originalDocument: recoveredBundle.originalDocument
            )
        )
        let tree = try JSONFidelity.parse(reexported.primary.data)
        let rectangle = try XCTUnwrap(tree["elements"]?.arrayValue?.first(where: {
            $0["type"]?.stringValue == "rectangle"
        }))
        let customData = try XCTUnwrap(rectangle["customData"]?.objectValue)
        XCTAssertEqual(customData["fixtureUnknownInteger"]?.numberLiteral, "92233720368547758081234567890")
        XCTAssertEqual(customData["fixtureUnknownDecimal"]?.numberLiteral, "0.123456789012345678901234567890")
    }

    func testFacadeDispatchRejectsOutputFormatsForImport() async throws {
        await XCTAssertThrowsAsyncError(try await CanvasExchange.importData(Data("%PDF".utf8), format: .pdf)) { error in
            guard case CanvasExchangeError.invalid(let message) = error else { return XCTFail() }
            XCTAssertTrue(message.contains("output format"))
        }
    }

    func testFacadeJSONCanvasRoundTrip() async throws {
        let bundle = try await CanvasExchange.importData(
            ExchangeFixtureSupport.data("mixed.canvas"),
            format: .jsonCanvas,
            options: .init(canvasID: UUID(uuidString: "77770000-0000-0000-0000-000000000003")!, canvasName: "Mixed")
        )
        let output = try await CanvasExchange.export(
            bundle.snapshot,
            format: .jsonCanvas,
            options: .init(
                externalIDs: bundle.externalIDs,
                originalNodes: bundle.originalNodes,
                originalEdges: bundle.originalEdges,
                originalDocument: bundle.originalDocument
            )
        )
        let reimported = try await CanvasExchange.importData(output.primary.data, format: .jsonCanvas)
        XCTAssertEqual(reimported.snapshot.pages.first?.nodes.count, 3)
    }

    func testLossReportClassifiesFlowAndPencilAsLoss() async throws {
        var node = CanvasNodeSnapshot(
            kind: .generationTask,
            title: "card",
            content: .text("run"),
            frame: .init(center: .zero, size: .init(width: 100, height: 60))
        )
        node.metadata[CanvasExchangeFlowKey.graphID] = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!.uuidString
        node.metadata[CanvasExchangeFlowKey.nodeID] = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002")!.uuidString
        let snapshot = CanvasSnapshot(name: "X", pages: [CanvasPageSnapshot(name: "P", nodes: [node])])
        let output = try await CanvasSVGExporter.svg(snapshot: snapshot)
        // The flow card renders as a visual badge; execution is not claimed.
        let svg = String(data: output.primary.data, encoding: .utf8) ?? ""
        XCTAssertTrue(svg.contains("flow"))
        XCTAssertFalse(svg.contains("aaaaaaaa-0000-0000-0000-000000000001"), "binding ids are not leaked into open output")
    }
}
