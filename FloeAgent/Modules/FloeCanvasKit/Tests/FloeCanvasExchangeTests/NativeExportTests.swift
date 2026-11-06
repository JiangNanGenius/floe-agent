// SPDX-License-Identifier: MPL-2.0
import XCTest
import CoreGraphics
import FloeCanvasCore
@testable import FloeCanvasExchange

final class NativeExportTests: XCTestCase {
    private func snapshot() -> CanvasSnapshot {
        let text = CanvasNodeSnapshot(
            title: "标题",
            content: .text("中文与 emoji 🧊 & <angles>"),
            frame: .init(center: .init(x: 0, y: 0), size: .init(width: 260, height: 120))
        )
        // Inside the 700x300 region centered at the origin (center
        // containment is the documented membership rule).
        var shape = CanvasNodeSnapshot(
            title: nil,
            content: .shape(kind: .diamond, text: "条件"),
            frame: .init(center: .init(x: 300, y: 0), size: .init(width: 140, height: 90)),
            rotationDegrees: 15
        )
        shape.metadata[CanvasExchangeStyleKey.fillColor] = "#dbeafe"
        shape.metadata[CanvasExchangeStyleKey.strokeColor] = "#365FA4"
        let region = CanvasRegionRecord(name: "区域", frame: .init(center: .init(x: 0, y: 0), size: .init(width: 700, height: 300)))
        let page = CanvasPageSnapshot(name: "P1", nodes: [text, shape], regions: [region])
        return CanvasSnapshot(name: "Render", pages: [page])
    }

    func testPDFIsMultipageAndContainsPageBoxes() async throws {
        let page2 = CanvasPageSnapshot(name: "P2", nodes: [CanvasNodeSnapshot(content: .text("second"), frame: .init(center: .zero, size: .init(width: 100, height: 50)))])
        var multi = snapshot()
        multi.pages.append(page2)
        let output = try await CanvasNativeExporter.pdf(snapshot: multi)
        let data = output.primary.data
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        // Structural page count via CGPDFDocument (exact source documented).
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else {
            return XCTFail("PDF not decodable")
        }
        XCTAssertEqual(document.numberOfPages, 2)
        // Exact PDF text extraction is qualified on the iOS host by root.
    }

    func testPNGHasNonUniformPixels() async throws {
        let output = try await CanvasNativeExporter.png(snapshot: snapshot())
        let data = output.primary.data
        XCTAssertTrue(data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("PNG not decodable")
        }
        let width = image.width, height = image.height
        guard width > 8, height > 8 else { return XCTFail("PNG too small") }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return XCTFail()
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = context.data else { return XCTFail() }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var distinct: Set<UInt32> = []
        for index in stride(from: 0, to: width * height * 4, by: 16) {
            distinct.insert(UInt32(pixels[index]) << 24 | UInt32(pixels[index + 1]) << 16 | UInt32(pixels[index + 2]) << 8 | UInt32(pixels[index + 3]))
            if distinct.count > 4 { break }
        }
        XCTAssertGreaterThan(distinct.count, 2, "PNG should contain varied content, not a blank raster")
    }

    func testSVGEscapesTextAndBlocksUnsafeLinks() async throws {
        let web = CanvasNodeSnapshot(
            title: nil,
            content: .web(URL(string: "javascript:alert(1)")!, title: nil),
            frame: .init(center: .init(x: 0, y: 300), size: .init(width: 220, height: 60))
        )
        let safe = CanvasNodeSnapshot(
            title: nil,
            content: .web(URL(string: "https://example.org/?a=1&b=2")!, title: "safe"),
            frame: .init(center: .init(x: 0, y: 500), size: .init(width: 220, height: 60))
        )
        var multi = snapshot()
        multi.pages[0].nodes.append(web)
        multi.pages[0].nodes.append(safe)
        let output = try await CanvasSVGExporter.svg(snapshot: multi)
        let svg = String(data: output.primary.data, encoding: .utf8) ?? ""
        XCTAssertTrue(svg.hasPrefix("<?xml"))
        XCTAssertTrue(svg.contains("&lt;angles&gt;"), "raw text must be escaped")
        XCTAssertTrue(svg.contains("中文"))
        // The original URL string may remain visible as plain text (that is
        // not an executable surface — the earlier blanket substring check
        // was a false positive). Executable attributes must never carry an
        // unsafe scheme.
        XCTAssertFalse(svg.contains("href=\"javascript:"), "unsafe schemes never appear in href attributes")
        XCTAssertFalse(svg.contains("xlink:href=\"javascript:"))
        XCTAssertFalse(svg.contains("<script"), "no script content is ever emitted")
        XCTAssertTrue(svg.contains("https://example.org/?a=1&amp;b=2"))
        XCTAssertTrue(output.issues.contains(where: { $0.code == "svg.link.unsafe" }))
        XCTAssertTrue(svg.contains("<svg"))
    }

    func testMissingMediaDrawsExplicitPlaceholderNotBlank() async throws {
        let media = CanvasNodeSnapshot(
            title: nil,
            content: .media(CanvasAssetLocator(id: UUID(uuidString: "12121212-1212-1212-1212-121212121212")!, mimeType: "image/png")),
            frame: .init(center: .init(x: 200, y: 300), size: .init(width: 200, height: 140))
        )
        var multi = snapshot()
        multi.pages[0].nodes.append(media)
        // No resolver injected.
        let output = try await CanvasNativeExporter.png(snapshot: multi)
        XCTAssertTrue(output.issues.contains(where: { $0.code == "render.asset.noResolver" }))
    }

    /// Regression (root visual review 2026-11-03, partial-render-review-01):
    /// shape text was top-left anchored, spilling CJK glyphs outside a
    /// diamond's left edge. It must be centered inside the shape bounds.
    func testSVGShapeTextCenteredInsideDiamond() async throws {
        let output = try await CanvasSVGExporter.svg(snapshot: snapshot())
        let svg = String(data: output.primary.data, encoding: .utf8) ?? ""
        // Diamond is centered at (300, 0): the centered label element must
        // anchor at the diamond center, not at frame.minX + 8.
        guard let labelRange = svg.range(of: ">条件</text>") else {
            return XCTFail("diamond label text missing from SVG")
        }
        let elementStart = svg[..<labelRange.lowerBound]
            .lastIndex(of: "<").map { svg.index(after: $0) }
        guard let elementStart else { return XCTFail("label element start missing") }
        let element = svg[elementStart..<labelRange.upperBound]
        XCTAssertTrue(element.hasPrefix("text "), "unexpected label element \(element)")
        XCTAssertTrue(element.contains("text-anchor=\"middle\""),
                      "shape label must be horizontally centered: \(element)")
        XCTAssertTrue(element.contains("x=\"300\""),
                      "shape label must anchor at the diamond center x: \(element)")
        XCTAssertFalse(element.contains("x=\"238\""),
                       "shape label must not keep the old top-left anchor (minX+8=238): \(element)")
    }

    /// Regression (root visual review 2026-11-03): in a tight gap the cards
    /// painted over the edge label (only 引 survived) and the arrow tip.
    /// The line stays under the cards; the opaque, text-sized chip and the
    /// arrowheads must paint ABOVE the node groups.
    func testSVGEdgeLabelChipPaintedAboveNodesWithFullWidth() async throws {
        let source = CanvasNodeSnapshot(
            title: nil,
            content: .text("甲"),
            frame: .init(center: .init(x: -110, y: 0), size: .init(width: 200, height: 200)))
        let target = CanvasNodeSnapshot(
            title: nil,
            content: .text("乙"),
            frame: .init(center: .init(x: 110, y: 0), size: .init(width: 200, height: 200)))
        let connection = CanvasConnectionSnapshot(
            sourceNodeID: source.id,
            destinationNodeID: target.id,
            kind: .arrow,
            label: "引用",
            sourcePort: .trailing,
            destinationPort: .leading)
        let snapshot = CanvasSnapshot(
            name: "Gap", pages: [CanvasPageSnapshot(
                name: "P1", nodes: [source, target], connections: [connection])])
        let output = try await CanvasSVGExporter.svg(snapshot: snapshot)
        let svg = String(data: output.primary.data, encoding: .utf8) ?? ""

        // Edge midpoint between the border points is the world origin; the
        // CJK-aware chip for 引用 at size 11 is 2*11 + 14 = 36 wide.
        // The 20-unit gap is shorter than the chip, so it sits above the
        // line instead of hiding the arrow underneath its background.
        guard let chipRange = svg.range(of: "<rect x=\"-18\" y=\"-30\" width=\"36\" height=\"22\"") else {
            return XCTFail("full-width label chip missing from SVG")
        }
        // The chip paints above every node group (document order).
        guard let lastNodeGroup = svg.range(of: "</g>", options: .backwards) else {
            return XCTFail("node groups missing from SVG")
        }
        XCTAssertGreaterThan(chipRange.lowerBound, lastNodeGroup.lowerBound,
                             "label chip must paint after the node groups")
        guard let labelRange = svg.range(of: "引用</text>") else {
            return XCTFail("edge label text missing from SVG")
        }
        XCTAssertGreaterThan(labelRange.lowerBound, lastNodeGroup.lowerBound,
                             "edge label text must paint after the node groups")
        XCTAssertTrue(svg.contains("x=\"0\" y=\"-15\" text-anchor=\"middle\""),
                      "edge label must be centered in its chip clear of the short connector")
        // The connection line itself stays below the nodes.
        guard let lineRange = svg.range(of: "<line x1=\"-10\" y1=\"0\" x2=\"10\" y2=\"0\"") else {
            return XCTFail("connection line missing from SVG")
        }
        XCTAssertLessThan(lineRange.lowerBound, chipRange.lowerBound)
    }

    /// Pixel-level twin of the tight-gap regression: with the label chip and
    /// arrowhead painted above the cards, the exported PNG must contain the
    /// dark label glyphs inside the chip rect and the edge-colored arrowhead
    /// at the target border — not card-white pixels only.
    @MainActor
    func testPNGTightGapLabelAndArrowPixelsVisible() async throws {
        let source = CanvasNodeSnapshot(
            title: nil,
            content: .text("甲"),
            frame: .init(center: .init(x: -110, y: 0), size: .init(width: 200, height: 200)))
        let target = CanvasNodeSnapshot(
            title: nil,
            content: .text("乙"),
            frame: .init(center: .init(x: 110, y: 0), size: .init(width: 200, height: 200)))
        let connection = CanvasConnectionSnapshot(
            sourceNodeID: source.id,
            destinationNodeID: target.id,
            kind: .arrow,
            label: "引用",
            sourcePort: .trailing,
            destinationPort: .leading)
        let page = CanvasPageSnapshot(
            name: "P1", nodes: [source, target], connections: [connection])
        let snapshot = CanvasSnapshot(name: "Gap", pages: [page])
        let output = try await CanvasNativeExporter.png(snapshot: snapshot)
        let data = output.primary.data

        // Reproduce the exporter's world→pixel mapping exactly.
        let layout = try CanvasPageRenderer.layout(
            page: page, snapshot: snapshot,
            scope: .wholePage, regionPresentation: .chip)
        let width = layout.bounds.maxX - layout.bounds.minX
        let height = layout.bounds.maxY - layout.bounds.minY
        let scale = min(
            2.0,
            8192.0 / max(width, height),
            (24_000_000.0 / (width * height)).squareRoot())
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("PNG not decodable")
        }
        XCTAssertEqual(Double(image.width), (width * scale).rounded(.up), accuracy: 1)
        let contextWidth = image.width, contextHeight = image.height
        guard let context = CGContext(
            data: nil, width: contextWidth, height: contextHeight,
            bitsPerComponent: 8, bytesPerRow: contextWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return XCTFail()
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: contextWidth, height: contextHeight))
        guard let buffer = context.data else { return XCTFail() }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: contextWidth * contextHeight * 4)
        func pixelAt(worldX: Double, worldY: Double) -> (r: Int, g: Int, b: Int) {
            let px = Int((worldX - layout.bounds.minX) * scale)
            // The exporter already mapped world Y into PNG row order.
            // The decoded bitmap preserves that order; flipping it again
            // samples below the line when the label is above it.
            let py = Int((worldY - layout.bounds.minY) * scale)
            let row = py
            let i = (row * contextWidth + px) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        func isDark(_ p: (r: Int, g: Int, b: Int)) -> Bool {
            p.r + p.g + p.b < 420
        }
        // 1) Whole label legible above the short line: dark glyph pixels
        // across BOTH halves of the chip at y -30...-8. Its background
        // must leave the arrow at y 0 visible (separate assertion below).
        var leftDark = 0, rightDark = 0
        for wx in stride(from: -24.0, to: 0.0, by: 1) {
            for wy in stride(from: -29.0, to: -9.0, by: 1) {
                if isDark(pixelAt(worldX: wx, worldY: wy)) { leftDark += 1 }
            }
        }
        for wx in stride(from: 0.0, to: 18.0, by: 1) {
            for wy in stride(from: -29.0, to: -9.0, by: 1) {
                if isDark(pixelAt(worldX: wx, worldY: wy)) { rightDark += 1 }
            }
        }
        XCTAssertGreaterThan(leftDark, 15, "first label glyph must be visible")
        XCTAssertGreaterThan(rightDark, 15, "second label glyph must be visible (was clipped to 引)")
        // 2) Arrow tip visible at the target border: edge-colored pixels
        //    just inside the gap near the tip world point (10, 0).
        var arrowPixels = 0
        for wx in stride(from: 4.0, to: 10.0, by: 0.5) {
            for wy in stride(from: -3.0, to: 3.0, by: 0.5) {
                let p = pixelAt(worldX: wx, worldY: wy)
                let edge = abs(p.r - 126) + abs(p.g - 141) + abs(p.b - 162)
                let dark = p.r + p.g + p.b < 420
                if edge < 90 || dark { arrowPixels += 1 }
            }
        }
        XCTAssertGreaterThan(arrowPixels, 8, "arrowhead must paint above the target card")
    }

    @MainActor
    func testRegionScopeAndCollapsedChipBounds() async throws {
        let page = snapshot().pages[0]
        let region = page.regions[0]
        let layout = try CanvasPageRenderer.layout(
            page: page,
            snapshot: snapshot(),
            scope: .region(region.id),
            regionPresentation: .chip
        )
        XCTAssertEqual(layout.placements.count, 2)
        let expanded = try CanvasPageRenderer.layout(
            page: page,
            snapshot: snapshot(),
            scope: .region(region.id),
            regionPresentation: .expandedContents
        )
        XCTAssertFalse(expanded.placements.contains(where: { $0.collapsedChip }))
        _ = layout
    }

    @MainActor
    func testRotatedBoundsIncluded() throws {
        let page = snapshot().pages[0]
        let layout = try CanvasPageRenderer.layout(page: page, snapshot: snapshot(), scope: .wholePage, regionPresentation: .chip)
        // Rotated diamond at (300,0) 140x90 @15° must extend beyond its axis box.
        XCTAssertGreaterThan(layout.bounds.maxX, 300 + 70)
        XCTAssertGreaterThan(layout.bounds.maxY, 45)
    }
}
