// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import FloeCanvasCore
@testable import FloeCanvasExchange

/// Real codec output samples for the coordinator's target-software
/// validation (Obsidian / Excalidraw / diagrams.net / host renderers).
///
/// These files are produced by the actual export code paths — never
/// hand-authored. Set `FLOE_CANVAS_SAMPLE_DIR` to a writable directory and
/// run this test; each format's output files and an exact per-format
/// loss/issue JSON land there. Without the variable the test skips.
final class RootSampleExportTests: XCTestCase {
    func testEmitRootCodecSamples() async throws {
        guard let raw = ProcessInfo.processInfo.environment["FLOE_CANVAS_SAMPLE_DIR"], !raw.isEmpty else {
            throw XCTSkip("FLOE_CANVAS_SAMPLE_DIR not set")
        }
        let directory = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let environment = ProcessInfo.processInfo.environment
        let snapshot: CanvasSnapshot
        if let source = environment["FLOE_CANVAS_INSPECT_SOURCE"] {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: source))
            XCTAssertLessThan(bytes.count, 64 * 1024 * 1024)
            snapshot = try CanvasExchangeJSON.decode(CanvasSnapshot.self, from: bytes)
        } else {
            snapshot = Self.mixedSnapshot()
        }
        let assetID = UUID(uuidString: "5a5a5a5a-0000-0000-0000-0000000000a1")!
        let assetBytes = Self.patternPNG()
        let templateID = UUID(uuidString: "5a5a5a5a-0000-0000-0000-0000000000b2")!
        let template = CanvasNativeArchive.FlowTemplateDefinition(
            id: templateID,
            version: 1,
            name: "sample-template",
            graph: FlowGraph(
                nodes: [FlowNode(kind: .subgraph, name: "draft")],
                variables: [FlowVariable(
                    name: "media",
                    dataType: .asset,
                    ownerNodeID: UUID(uuidString: "5a5a5a5a-0000-0000-0000-0000000000c3")!,
                    initial: .asset(CanvasAssetLocator(id: assetID, mimeType: "image/png", byteCount: Int64(assetBytes.count)))
                )]
            )
        )

        // Source snapshot for reference/diffing.
        try CanvasExchangeJSON.encode(snapshot, pretty: true).write(to: directory.appendingPathComponent("source-snapshot.json"))

        struct Format: Sendable {
            var name: String
            var format: CanvasExchangeFormat
        }
        let formats = [
            Format(name: "jsoncanvas", format: .jsonCanvas),
            Format(name: "excalidraw", format: .excalidraw),
            Format(name: "drawio", format: .drawio),
            Format(name: "svg", format: .svg),
            Format(name: "pdf", format: .pdf),
            Format(name: "png", format: .png),
            Format(name: "floecanvaslab", format: .floecanvaslab),
        ]
        let requestedFormat = environment["FLOE_CANVAS_INSPECT_FORMAT"]
        if let requestedFormat { XCTAssertTrue(formats.contains { $0.name == requestedFormat }) }
        for item in formats where requestedFormat == nil || item.name == requestedFormat {
            // JSON Canvas / Excalidraw hold one page per file: emit every
            // page as its own fragment instead of silently skipping pages.
            let perPageFiles = item.format == .jsonCanvas || item.format == .excalidraw
            let options = CanvasExportOptions(
                multiPageStrategy: perPageFiles ? .oneFilePerPage : .selectedPageOnly,
                assetBytes: [assetID: assetBytes],
                assetResolver: CanvasInMemoryAssetResolver([assetID: assetBytes]),
                flowTemplates: [template],
                drawioCompressed: item.format == .drawio
            )
            let output = try await CanvasExchange.export(snapshot, format: item.format, options: options)
            var report: [String: JSONValue] = [:]
            var files: [JSONValue] = []
            for file in output.files {
                try file.data.write(to: directory.appendingPathComponent("\(item.name)-\(file.name)"))
                files.append(.object([
                    "name": .string(file.name),
                    "bytes": .number(String(file.data.count)),
                    "sha256": .string(CanvasDigest.sha256(file.data)),
                ]))
            }
            report["files"] = .array(files)
            report["issues"] = .array(output.issues.map { issue in
                .object([
                    "code": .string(issue.code),
                    "detail": .string(issue.detail),
                    "contentClass": .string(issue.contentClass),
                    "severity": .string(issue.severity.rawValue),
                ])
            })
            if item.format == .floecanvaslab, let lab = output.files.first {
                // Expose the verified manifest next to the archive sample.
                let imported = try CanvasNativeArchive.import(lab.data)
                try CanvasExchangeJSON.encode(imported.manifest, pretty: true)
                    .write(to: directory.appendingPathComponent("floecanvaslab-manifest.json"))
            }
            let reportData = try CanvasExchangeJSON.encode(JSONValue.object(report), pretty: true)
            try reportData.write(to: directory.appendingPathComponent("\(item.name)-loss-report.json"))
        }
    }

    /// One page carrying every major content class, a region, a group, a
    /// labelled connection, a discrete stroke and one flow graph.
    private static func mixedSnapshot() -> CanvasSnapshot {
        let text = CanvasNodeSnapshot(
            title: "markdown",
            content: .markdown(document: "# 标题\n\n中文与 emoji 🧊", previewText: nil),
            frame: .init(center: .init(x: -300, y: -160), size: .init(width: 280, height: 160))
        )
        let code = CanvasNodeSnapshot(
            title: "code",
            content: .code(language: "swift", source: "let value = 42"),
            frame: .init(center: .init(x: 0, y: -160), size: .init(width: 280, height: 140))
        )
        let table = CanvasNodeSnapshot(
            title: "table",
            content: .table(header: ["列一", "列二"], rows: [["a", "b"], ["c", "d"]]),
            frame: .init(center: .init(x: 300, y: -160), size: .init(width: 280, height: 140))
        )
        var shape = CanvasNodeSnapshot(
            title: nil,
            content: .shape(kind: .diamond, text: "条件"),
            frame: .init(center: .init(x: -160, y: 60), size: .init(width: 160, height: 100))
        )
        shape.metadata[CanvasExchangeStyleKey.fillColor] = "#dbeafe"
        shape.metadata[CanvasExchangeStyleKey.strokeColor] = "#1e293b"
        let media = CanvasNodeSnapshot(
            title: "media",
            content: .media(CanvasAssetLocator(
                id: UUID(uuidString: "5a5a5a5a-0000-0000-0000-0000000000a1")!,
                mimeType: "image/png",
                byteCount: Int64(Self.patternPNG().count)
            )),
            frame: .init(center: .init(x: 80, y: 60), size: .init(width: 160, height: 120))
        )
        let web = CanvasNodeSnapshot(
            title: "web",
            content: .web(URL(string: "https://example.org/reference")!, title: "参考"),
            frame: .init(center: .init(x: 320, y: 60), size: .init(width: 180, height: 80))
        )
        var groupNode = CanvasNodeSnapshot(
            title: nil,
            content: .text("组成员"),
            frame: .init(center: .init(x: -320, y: 240), size: .init(width: 120, height: 60))
        )
        groupNode.groupID = UUID(uuidString: "5a5a5a5a-0000-0000-0000-0000000000d4")!
        let connection = CanvasConnectionSnapshot(
            sourceNodeID: text.id,
            destinationNodeID: code.id,
            kind: .arrow,
            label: "引用",
            sourcePort: .trailing,
            destinationPort: .leading
        )
        let stroke = CanvasStrokeSnapshot(
            points: [.init(x: -400, y: 320), .init(x: -360, y: 350), .init(x: -320, y: 330)],
            width: 2,
            color: "#1e293b"
        )
        let region = CanvasRegionRecord(
            name: "区域一",
            frame: .init(center: .init(x: 0, y: 0), size: .init(width: 900, height: 560))
        )
        let group = CanvasGroupRecord(
            id: UUID(uuidString: "5a5a5a5a-0000-0000-0000-0000000000d4")!,
            name: "组一",
            memberNodeIDs: [groupNode.id]
        )
        let flowNode = FlowNode(
            id: UUID(uuidString: "5a5a5a5a-0000-0000-0000-0000000000e5")!,
            kind: .subgraph,
            name: "sample-template",
            subgraphTemplateID: UUID(uuidString: "5a5a5a5a-0000-0000-0000-0000000000b2")!
        )
        let page = CanvasPageSnapshot(
            name: "样例页",
            nodes: [text, code, table, shape, media, web, groupNode],
            connections: [connection],
            strokes: [stroke],
            groups: [group],
            regions: [region],
            flowGraphs: [FlowGraph(nodes: [flowNode])]
        )

        // Page 2 exercises per-page open formats: a titled text card, a
        // link card, a labelled arrow between them and a small executable
        // graph shape set (visual projection only in open formats).
        let title2 = CanvasNodeSnapshot(
            title: "标题",
            content: .text("画布第二页"),
            frame: .init(center: .init(x: -220, y: -120), size: .init(width: 240, height: 80))
        )
        let card2 = CanvasNodeSnapshot(
            title: "card",
            content: .web(URL(string: "https://example.org/card")!, title: "链接卡片"),
            frame: .init(center: .init(x: 140, y: -120), size: .init(width: 200, height: 90))
        )
        let arrow2 = CanvasConnectionSnapshot(
            sourceNodeID: title2.id,
            destinationNodeID: card2.id,
            kind: .arrow,
            label: "跳转",
            sourcePort: .trailing,
            destinationPort: .leading
        )
        let graphOut = FlowPort(name: "out", dataType: .string, direction: .output)
        let graphIn = FlowPort(name: "in", dataType: .string, direction: .input)
        let graphA = FlowNode(kind: .transform, name: "生成", ports: [graphOut])
        let graphB = FlowNode(kind: .transform, name: "校验", ports: [graphIn])
        let graphEdge = FlowEdge(
            sourceNodeID: graphA.id, sourcePortID: graphOut.id,
            destinationNodeID: graphB.id, destinationPortID: graphIn.id)
        let page2 = CanvasPageSnapshot(
            name: "第二页",
            nodes: [title2, card2],
            connections: [arrow2],
            flowGraphs: [FlowGraph(nodes: [graphA, graphB], edges: [graphEdge])]
        )
        return CanvasSnapshot(name: "格式样例", pages: [page, page2])
    }

    /// A real, deterministic 96x64 PNG (212 bytes, 8-bit RGB): an 8px
    /// two-tone checkerboard with a contrasting slate border frame, so the
    /// media card in every exported sample shows inspectable, meaningful
    /// image content instead of a single tinted pixel. The byte count is
    /// wired into the media locator above — keep them equal.
    private static func patternPNG() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAGAAAABACAIAAABqVuVZAAAAm0lEQVR42u3csQ2AIBQEUCaxs3AGxmFsN9AdjD2CIVYIL7nyV6+6XPHDskV5SUDQBLQfV5Y1ncU8L0e9BwQIECBAfwGaGaJ2DwgQIECAAAGaA0hR1KQBAQIECBAge5CiqEkDAgQIECBA9iBFERAgQIAAAQJkD1IUAQECBAgQIED2IE0aECBAgAABAmQP0qQBAQIECFAvQOL7y8fckB2lw6SKjw8AAAAASUVORK5CYII=")!
    }
}
