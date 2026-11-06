// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeCanvasCore
@testable import FloeCanvasExchange

/// Output-boundary discipline: hostile file names must fail the whole save
/// before anything is written; codec-generated names from hostile titles
/// are sanitized to plain basenames.
final class SaveBoundaryTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-canvas-save-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: base)
    }

    func testEscapeNameFailsSaveAndTouchesNothing() throws {
        let target = base.appendingPathComponent("out", isDirectory: true)
        let sentinel = base.appendingPathComponent("sentinel.txt")
        try Data("sentinel".utf8).write(to: sentinel)
        let output = CanvasExchangeOutput(files: [
            CanvasExchangeFile(name: "first.txt", data: Data("one".utf8)),
            CanvasExchangeFile(name: "../escape.txt", data: Data("two".utf8)),
        ])
        XCTAssertThrowsError(try CanvasExchange.save(output, to: target)) { error in
            guard case CanvasExchangeError.invalid = error else {
                return XCTFail("invalid expected, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "validation runs before the directory is created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("escape.txt").path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("sentinel".utf8), "outside sentinel unchanged")
    }

    func testDuplicateNamesRejectedBeforeAnyWrite() throws {
        let target = base.appendingPathComponent("out", isDirectory: true)
        let output = CanvasExchangeOutput(files: [
            CanvasExchangeFile(name: "same.txt", data: Data("one".utf8)),
            CanvasExchangeFile(name: "same.txt", data: Data("two".utf8)),
        ])
        XCTAssertThrowsError(try CanvasExchange.save(output, to: target)) { error in
            guard case CanvasExchangeError.invalid(let message) = error else { return XCTFail() }
            XCTAssertTrue(message.contains("duplicate"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("same.txt").path))
    }

    func testAbsoluteAndDotSegmentNamesRejected() throws {
        for name in ["/tmp/x.txt", "a//b.txt", "a/./b.txt", "a\\b.txt", "a:b.txt", "..", ".", ""] {
            let output = CanvasExchangeOutput(files: [CanvasExchangeFile(name: name, data: Data("x".utf8))])
            XCTAssertThrowsError(try CanvasExchange.save(output, to: base.appendingPathComponent("d\(name.count)-\(name.hashValue)"))) { error in
                guard case CanvasExchangeError.invalid = error else {
                    return XCTFail("\"\(name)\" must be rejected, got \(error)")
                }
            }
        }
    }

    func testSuccessfulMultiFileSavePublishesAll() throws {
        let target = base.appendingPathComponent("out", isDirectory: true)
        let output = CanvasExchangeOutput(files: [
            CanvasExchangeFile(name: "a.txt", data: Data("A".utf8)),
            CanvasExchangeFile(name: "b.txt", data: Data("B".utf8)),
        ])
        try CanvasExchange.save(output, to: target)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("a.txt")), Data("A".utf8))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("b.txt")), Data("B".utf8))
    }

    func testCodecsSanitizeHostileTitles() async throws {
        let hostile = CanvasSnapshot(
            name: "../../etc/画布: name",
            pages: [CanvasPageSnapshot(name: "P/1", nodes: [CanvasNodeSnapshot(content: .text("x"), frame: .init(center: .zero, size: .init(width: 100, height: 40)))])]
        )
        let drawio = try await CanvasDrawIOCodec.export(hostile)
        XCTAssertEqual(drawio.primary.name, "--etc-画布- name.drawio")
        let jsonCanvas = try CanvasJSONCanvasCodec.export(hostile)
        XCTAssertEqual(jsonCanvas.primary.name, "--etc-画布- name.canvas")
        let excalidraw = try CanvasExcalidrawCodec.export(hostile)
        XCTAssertEqual(excalidraw.primary.name, "--etc-画布- name.excalidraw")
        let svg = try await CanvasSVGExporter.svg(snapshot: hostile)
        XCTAssertEqual(svg.primary.name, "--etc-画布- name-P-1.svg")
        for output in [drawio, jsonCanvas, excalidraw, svg] {
            for file in output.files {
                XCTAssertFalse(file.name.contains("/"))
                XCTAssertFalse(file.name.contains(".."))
            }
        }
    }
}
