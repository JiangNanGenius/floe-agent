// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import FloeCanvasCore
import FloeDiagramCore
import FloeDiagramExchange

/// Native SVG export. Declarative twin of the PDF/PNG painter: identical
/// scope, colors, wrapping and content projections. Safety: all text is
/// XML-escaped, embedded images are data URIs from injected bytes only,
/// hyperlinks are restricted to http/https/mailto (no script, no foreign
/// network reference), and no executable content is ever emitted.
public enum CanvasSVGExporter {
    public struct Options: Sendable {
        public var scope: CanvasExportScope
        public var regionPresentation: CanvasCollapsedRegionPresentation
        public var appearance: CanvasRenderAppearance
        public var assetResolver: (any CanvasAssetResolver)?
        public init(scope: CanvasExportScope = .wholePage, regionPresentation: CanvasCollapsedRegionPresentation = .chip, appearance: CanvasRenderAppearance = .light, assetResolver: (any CanvasAssetResolver)? = nil) {
            self.scope = scope
            self.regionPresentation = regionPresentation
            self.appearance = appearance
            self.assetResolver = assetResolver
        }
    }

    @MainActor
    public static func svg(snapshot: CanvasSnapshot, pageID: UUID? = nil, options: Options = Options()) async throws -> CanvasExchangeOutput {
        guard let page = snapshot.pages.first(where: { $0.id == pageID }) ?? (pageID == nil ? snapshot.selectedPage ?? snapshot.pages.first : nil) else {
            throw CanvasExchangeError.invalid("page \(pageID?.uuidString ?? "selected") not found")
        }
        let layout = try CanvasPageRenderer.layout(page: page, snapshot: snapshot, scope: options.scope, regionPresentation: options.regionPresentation)
        var issues: [CanvasExchangeIssue] = []
        let svg = try await render(layout: layout, snapshot: snapshot, options: options, issues: &issues)
        return CanvasExchangeOutput(
            files: [CanvasExchangeFile(name: CanvasExchangeFilename.sanitized("\(snapshot.name)-\(page.name)", extension: "svg", fallback: "page"), data: Data(svg.utf8))],
            issues: issues
        )
    }

    @MainActor
    private static func render(layout: CanvasPageRenderer.Layout, snapshot: CanvasSnapshot, options: Options, issues: inout [CanvasExchangeIssue]) async throws -> String {
        func number(_ value: Double) -> String { CanvasExchangeGeometry.number(value) }
        func color(_ value: String?, fallback: String) -> String {
            let cg = CanvasPageRenderer.color(value, fallback: fallback, appearance: options.appearance)
            guard let components = cg.components, components.count >= 3 else { return "#000000" }
            func channel(_ value: CGFloat) -> String {
                String(format: "%02X", Int((value * 255).rounded()))
            }
            if components.count >= 4, components[3] == 0 { return "none" }
            return "#" + channel(components[0]) + channel(components[1]) + channel(components[2])
        }
        func textElement(_ text: String, x: Double, y: Double, size: Double, fill: String, bold: Bool = false, monospace: Bool = false) -> String {
            "<text x=\"\(number(x))\" y=\"\(number(y))\" font-family=\"\(monospace ? "Menlo,monospace" : "-apple-system,BlinkMacSystemFont,Arial,sans-serif")\" font-size=\"\(number(size))\" fill=\"\(fill)\" xml:space=\"preserve\">\(escape(text))</text>"
        }
        func wrapped(_ text: String, x: Double, y: Double, width: Double, maxY: Double, size: Double, fill: String, monospace: Bool = false) -> (String, Double) {
            let chars = max(8, Int(width / (size * 0.55)))
            var output = ""
            var cursorY = y
            for line in CanvasPageRenderer.wrap(text, maxCharacters: chars) {
                guard cursorY + size + 4 <= maxY else { break }
                output += textElement(line, x: x, y: cursorY + size, size: size, fill: fill, monospace: monospace)
                cursorY += size + 5
            }
            return (output, cursorY)
        }
        func safeLink(_ url: URL) -> String? {
            guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
            return url.absoluteString
        }

        var body = ""
        let background = color("canvas", fallback: "canvas")
        body += "<rect x=\"\(number(layout.bounds.minX))\" y=\"\(number(layout.bounds.minY))\" width=\"\(number(layout.bounds.maxX - layout.bounds.minX))\" height=\"\(number(layout.bounds.maxY - layout.bounds.minY))\" fill=\"\(background)\"/>"

        // Regions.
        for region in layout.regions {
            body += "<rect x=\"\(number(region.frame.minX))\" y=\"\(number(region.frame.minY))\" width=\"\(number(region.frame.size.width))\" height=\"\(number(region.frame.size.height))\" rx=\"10\" fill=\"none\" stroke=\"\(color("border", fallback: "border"))\" stroke-width=\"1.2\" stroke-dasharray=\"6 5\"/>"
            if !region.name.isEmpty {
                body += textElement(region.name, x: region.frame.minX + 10, y: region.frame.minY + 20, size: 12, fill: color("muted", fallback: "muted"), bold: true)
            }
        }

        // Connection lines first (under the cards); arrowheads and label
        // chips are accumulated and emitted AFTER the nodes so a tight-gap
        // edge keeps its whole label and its arrow tips on top of the
        // cards' paint (endpoints stay at the exact border/port points).
        var connectionDecorations = ""
        for connection in layout.connections {
            guard let source = layout.placements.first(where: { $0.node.id == connection.sourceNodeID }),
                  let target = layout.placements.first(where: { $0.node.id == connection.destinationNodeID }) else { continue }
            let start = borderPoint(of: source.node.frame, towards: target.node.frame.center, port: connection.sourcePort)
            let end = borderPoint(of: target.node.frame, towards: source.node.frame.center, port: connection.destinationPort)
            let stroke = color("edge", fallback: "edge")
            body += "<line x1=\"\(number(start.x))\" y1=\"\(number(start.y))\" x2=\"\(number(end.x))\" y2=\"\(number(end.y))\" stroke=\"\(stroke)\" stroke-width=\"1.5\" stroke-linecap=\"round\"/>"
            if connection.kind != .line {
                connectionDecorations += arrowhead(tip: end, prior: start, color: stroke)
                if connection.kind == .source || connection.kind == .generatedFrom {
                    connectionDecorations += arrowhead(tip: start, prior: end, color: stroke)
                }
            }
            if let label = connection.label, !label.isEmpty {
                let text = String(label.prefix(64))
                // Chip sized to the estimated text (CJK-aware): a
                // count*7 guess left the second 引用 glyph uncovered.
                let textWidth = CanvasPageRenderer.estimatedTextWidth(text, size: 11)
                let chip = CanvasPageRenderer.connectionLabelRect(from: start, to: end, textWidth: textWidth)
                connectionDecorations += "<rect x=\"\(number(chip.minX))\" y=\"\(number(chip.minY))\" width=\"\(number(chip.width))\" height=\"22\" fill=\"\(color("surface", fallback: "surface"))\"/>"
                connectionDecorations += "<text x=\"\(number(chip.midX))\" y=\"\(number(chip.midY + 4))\" text-anchor=\"middle\" font-family=\"-apple-system,BlinkMacSystemFont,Arial,sans-serif\" font-size=\"11\" fill=\"\(color("muted", fallback: "muted"))\" xml:space=\"preserve\">\(escape(text))</text>"
            }
        }

        // Nodes.
        for placement in layout.placements.sorted(by: { $0.node.zIndex == $1.node.zIndex ? $0.node.id.uuidString < $1.node.id.uuidString : $0.node.zIndex < $1.node.zIndex }) {
            body += try await renderNode(placement, options: options, color: color, textElement: textElement, wrapped: wrapped, safeLink: safeLink, issues: &issues)
        }

        // Edge labels and arrowheads above the cards.
        body += connectionDecorations

        // Freehand strokes.
        for stroke in layout.page.strokes where stroke.points.count > 1 {
            let points = stroke.points
                .filter { CanvasExchangeGeometry.isUsableCoordinate($0.x) && CanvasExchangeGeometry.isUsableCoordinate($0.y) }
                .map { "\(number($0.x)),\(number($0.y))" }
                .joined(separator: " ")
            guard !points.isEmpty else { continue }
            let strokeColor = stroke.isEraser ? background : color(stroke.color, fallback: "text")
            body += "<polyline points=\"\(points)\" fill=\"none\" stroke=\"\(strokeColor)\" stroke-width=\"\(number(stroke.width))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
        }
        if layout.page.strokes.contains(where: { $0.isEraser }) {
            issues.append(.init("svg.eraserApproximated", "eraser strokes are repainted with the background color in SVG (no compositing); editable strokes remain in the native archive", contentClass: "stroke", severity: .preserved))
        }

        // Page-native PKDrawing ink.
        if let data = CanvasExchangePencilSupport.drawingData(of: layout.page) {
            do {
                if let (image, rect) = try DiagramNativeInk.image(data) {
                    let png = try CanvasNativeExporter.encodePNG(image)
                    body += "<image x=\"\(number(rect.x))\" y=\"\(number(rect.y))\" width=\"\(number(rect.width))\" height=\"\(number(rect.height))\" xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/>"
                    issues.append(.init("svg.inkRasterized", "SVG embeds PencilKit strokes as a bounded image; editable ink remains in the native archive", contentClass: "pencil", severity: .preserved))
                }
            } catch {
                issues.append(.init("svg.ink.unavailable", "PencilKit ink could not be rasterized: \(error)", contentClass: "pencil", severity: .unavailable))
            }
        }

        let title = escape(snapshot.name)
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"\(number(layout.bounds.maxX - layout.bounds.minX))\" height=\"\(number(layout.bounds.maxY - layout.bounds.minY))\" viewBox=\"\(number(layout.bounds.minX)) \(number(layout.bounds.minY)) \(number(layout.bounds.maxX - layout.bounds.minX)) \(number(layout.bounds.maxY - layout.bounds.minY))\"><title>\(title)</title>\(body)</svg>"
    }

    @MainActor
    private static func renderNode(
        _ placement: CanvasPageRenderer.Placement,
        options: Options,
        color: (String?, String) -> String,
        textElement: (String, Double, Double, Double, String, Bool, Bool) -> String,
        wrapped: (String, Double, Double, Double, Double, Double, String, Bool) -> (String, Double),
        safeLink: (URL) -> String?,
        issues: inout [CanvasExchangeIssue]
    ) async throws -> String {
        let node = placement.node
        if placement.collapsedChip {
            let chip = CanvasPageRenderer.chipBounds(for: placement)
            return "<rect x=\"\(CanvasExchangeGeometry.number(chip.minX))\" y=\"\(CanvasExchangeGeometry.number(chip.minY))\" width=\"\(CanvasExchangeGeometry.number(chip.maxX - chip.minX))\" height=\"\(CanvasExchangeGeometry.number(chip.maxY - chip.minY))\" rx=\"16\" fill=\"\(color("soft", "soft"))\" stroke=\"\(color("border", "border"))\"/>"
                + textElement(node.title ?? "region", chip.minX + 10, chip.minY + 14, 12, color("text", "text"), false, false)
        }
        let style = CanvasExchangeContent.style(of: node)
        let stroke = color(style.stroke, "border")
        let fill = color(style.fill, "surface")
        let text = color(style.textColor, "text")
        let frame = node.frame
        var transform = ""
        if node.rotationDegrees != 0 {
            transform = " transform=\"rotate(\(CanvasExchangeGeometry.number(-node.rotationDegrees)) \(CanvasExchangeGeometry.number(frame.center.x)) \(CanvasExchangeGeometry.number(frame.center.y)))\""
        }
        var body = ""
        var links: [String] = []

        func card() -> String {
            "<rect x=\"\(CanvasExchangeGeometry.number(frame.minX))\" y=\"\(CanvasExchangeGeometry.number(frame.minY))\" width=\"\(CanvasExchangeGeometry.number(frame.size.width))\" height=\"\(CanvasExchangeGeometry.number(frame.size.height))\" rx=\"8\" fill=\"\(fill)\" stroke=\"\(stroke)\"/>"
        }

        if let shape = CanvasExchangeContent.shapeValue(node.content), shape.kind != .line && shape.kind != .arrow {
            let rect = frame
            let element: String
            switch shape.kind {
            case .ellipse:
                element = "<ellipse cx=\"\(CanvasExchangeGeometry.number(rect.center.x))\" cy=\"\(CanvasExchangeGeometry.number(rect.center.y))\" rx=\"\(CanvasExchangeGeometry.number(rect.size.width / 2))\" ry=\"\(CanvasExchangeGeometry.number(rect.size.height / 2))\" fill=\"\(fill)\" stroke=\"\(stroke)\" stroke-width=\"\(CanvasExchangeGeometry.number(style.strokeWidth ?? 2))\"/>"
            case .diamond:
                element = "<polygon points=\"\(CanvasExchangeGeometry.number(rect.center.x)),\(CanvasExchangeGeometry.number(rect.minY)) \(CanvasExchangeGeometry.number(rect.maxX)),\(CanvasExchangeGeometry.number(rect.center.y)) \(CanvasExchangeGeometry.number(rect.center.x)),\(CanvasExchangeGeometry.number(rect.maxY)) \(CanvasExchangeGeometry.number(rect.minX)),\(CanvasExchangeGeometry.number(rect.center.y))\" fill=\"\(fill)\" stroke=\"\(stroke)\" stroke-width=\"\(CanvasExchangeGeometry.number(style.strokeWidth ?? 2))\"/>"
            case .rectangle, .roundedRectangle:
                element = "<rect x=\"\(CanvasExchangeGeometry.number(rect.minX))\" y=\"\(CanvasExchangeGeometry.number(rect.minY))\" width=\"\(CanvasExchangeGeometry.number(rect.size.width))\" height=\"\(CanvasExchangeGeometry.number(rect.size.height))\" rx=\"\(shape.kind == .roundedRectangle ? "10" : "2")\" fill=\"\(fill)\" stroke=\"\(stroke)\" stroke-width=\"\(CanvasExchangeGeometry.number(style.strokeWidth ?? 2))\"/>"
            case .line, .arrow:
                element = ""
            }
            body += element
            if !shape.text.isEmpty {
                // Centered inside the shape: a top-left anchor spills CJK
                // text outside a diamond's left edge at the baseline row.
                body += "<text x=\"\(CanvasExchangeGeometry.number(rect.center.x))\" y=\"\(CanvasExchangeGeometry.number(rect.center.y + 5))\" text-anchor=\"middle\" font-family=\"-apple-system,BlinkMacSystemFont,Arial,sans-serif\" font-size=\"14\" fill=\"\(text)\" xml:space=\"preserve\">\(escape(shape.text))</text>"
            }
        } else {
            body += card()
            var y = frame.minY + 8
            if let title = node.title, !title.isEmpty {
                body += textElement(title, frame.minX + 10, y + 14, 14, text, true, false)
                y += 26
            }
            let innerWidth = frame.size.width - 20
            let maxY = frame.maxY - 6
            switch node.content {
            case .text(let value), .markdown(let value, _):
                body += wrapped(value, frame.minX + 10, y, innerWidth, maxY, 13, text, false).0
            case .richText(let document):
                let plain = CanvasExchangeContent.plainText(runs: document.runs)
                body += wrapped(plain, frame.minX + 10, y, innerWidth, maxY, 13, text, false).0
                for run in document.runs {
                    if let link = run.link, let href = safeLink(link) {
                        links.append(href)
                    }
                }
                if document.runs.contains(where: { $0.bold || $0.italic || $0.underline || $0.strikethrough }) {
                    issues.append(.init("svg.richTextStyle", "node \(node.id): character styles are projected as plain text in SVG; PDF/PNG retain the styles", contentClass: "richText", severity: .preserved))
                }
            case .code(_, let source):
                body += "<rect x=\"\(CanvasExchangeGeometry.number(frame.minX + 10))\" y=\"\(CanvasExchangeGeometry.number(y))\" width=\"\(CanvasExchangeGeometry.number(innerWidth))\" height=\"\(CanvasExchangeGeometry.number(min(120, maxY - y)))\" fill=\"\(color("canvas", "canvas"))\"/>"
                body += wrapped(source, frame.minX + 16, y + 4, innerWidth - 12, maxY, 11, text, true).0
            case .formula(let source, let renderedAssetID):
                var drawn = false
                if let assetID = renderedAssetID, let image = try await svgImage(assetID: assetID, options: options, issues: &issues) {
                    body += imageTag(image: image, rect: (frame.minX + 10, y, innerWidth, min(64, maxY - y)))
                    drawn = true
                }
                if !drawn {
                    body += wrapped(source, frame.minX + 10, y, innerWidth, maxY, 12, text, true).0
                }
            case .table(let header, let rows):
                let all = (header.isEmpty ? [] : [header]) + rows
                guard !all.isEmpty else { break }
                let columns = max(1, all.map(\.count).max() ?? 1)
                let cellWidth = innerWidth / Double(columns)
                var rowY = y
                for (rowIndex, row) in all.prefix(12).enumerated() {
                    guard rowY + 22 <= maxY else { break }
                    if rowIndex == 0 && !header.isEmpty {
                        body += "<rect x=\"\(CanvasExchangeGeometry.number(frame.minX + 10))\" y=\"\(CanvasExchangeGeometry.number(rowY))\" width=\"\(CanvasExchangeGeometry.number(innerWidth))\" height=\"22\" fill=\"\(color("soft", "soft"))\"/>"
                    }
                    for (column, value) in row.enumerated() {
                        body += textElement(String(value.prefix(Int(cellWidth / 7))), frame.minX + 14 + Double(column) * cellWidth, rowY + 15, 11, text, rowIndex == 0 && !header.isEmpty, false)
                    }
                    body += "<line x1=\"\(CanvasExchangeGeometry.number(frame.minX + 10))\" y1=\"\(CanvasExchangeGeometry.number(rowY + 22))\" x2=\"\(CanvasExchangeGeometry.number(frame.maxX - 10))\" y2=\"\(CanvasExchangeGeometry.number(rowY + 22))\" stroke=\"\(color("border", "border"))\" stroke-width=\"0.5\"/>"
                    rowY += 22
                }
            case .media(let locator):
                if let image = try await svgImage(assetID: locator.id, options: options, issues: &issues) {
                    body += imageTag(image: image, rect: (frame.minX + 10, y, innerWidth, min(240, maxY - y)))
                } else {
                    body += "<rect x=\"\(CanvasExchangeGeometry.number(frame.minX + 10))\" y=\"\(CanvasExchangeGeometry.number(y))\" width=\"\(CanvasExchangeGeometry.number(innerWidth))\" height=\"60\" rx=\"6\" fill=\"none\" stroke=\"\(color("border", "border"))\" stroke-dasharray=\"4 3\"/>"
                    body += textElement("media \(locator.id.uuidString) — bytes unavailable", frame.minX + 18, y + 24, 11, color("muted", "muted"), false, false)
                }
            case .pdf(let assetID, let pageRange):
                if let assetID, let bytes = try await svgBytes(assetID: assetID, options: options, issues: &issues),
                   !bytes.isEmpty,
                   let provider = CGDataProvider(data: bytes as CFData),
                   let document = CGPDFDocument(provider) {
                    let first = max(1, pageRange?.lowerBound ?? 1)
                    if first <= document.numberOfPages, let pdfPage = document.page(at: first) {
                        // PDF pages cannot be embedded directly in SVG; draw
                        // a labeled crop card instead of pretending.
                        body += "<rect x=\"\(CanvasExchangeGeometry.number(frame.minX + 10))\" y=\"\(CanvasExchangeGeometry.number(y))\" width=\"\(CanvasExchangeGeometry.number(innerWidth))\" height=\"\(CanvasExchangeGeometry.number(min(120, maxY - y)))\" fill=\"\(color("surface", "surface"))\" stroke=\"\(color("border", "border"))\"/>"
                        body += textElement("PDF p.\(first) (\(document.numberOfPages) pages)", frame.minX + 18, y + 24, 12, text, true, false)
                        issues.append(.init("svg.pdf.notEmbeddable", "node \(node.id): SVG cannot embed live PDF pages; a labeled crop card was drawn (PDF export renders the real page)", contentClass: "pdf", severity: .preserved))
                    }
                } else {
                    body += "<rect x=\"\(CanvasExchangeGeometry.number(frame.minX + 10))\" y=\"\(CanvasExchangeGeometry.number(y))\" width=\"\(CanvasExchangeGeometry.number(innerWidth))\" height=\"60\" rx=\"6\" fill=\"none\" stroke=\"\(color("border", "border"))\" stroke-dasharray=\"4 3\"/>"
                    body += textElement("PDF \(assetID?.uuidString ?? "unresolved")", frame.minX + 18, y + 24, 11, color("muted", "muted"), false, false)
                    issues.append(.init("svg.pdf.previewMissing", "node \(node.id): no PDF bytes resolved; an explicit placeholder card was drawn", contentClass: "pdf", severity: .unavailable))
                }
            case .web(let url, let pageTitle):
                body += wrapped(pageTitle ?? url.absoluteString, frame.minX + 10, y, innerWidth, maxY, 13, text, false).0
                if let href = safeLink(url) {
                    links.append(href)
                } else {
                    issues.append(.init("svg.link.unsafe", "node \(node.id): link scheme \"\(url.scheme ?? "none")\" is not allowed in SVG output", contentClass: "web", severity: .preserved))
                }
            case .editor(let reference):
                body += "<rect x=\"\(CanvasExchangeGeometry.number(frame.minX + 10))\" y=\"\(CanvasExchangeGeometry.number(y))\" width=\"\(CanvasExchangeGeometry.number(innerWidth))\" height=\"60\" rx=\"6\" fill=\"none\" stroke=\"\(color("border", "border"))\" stroke-dasharray=\"4 3\"/>"
                body += textElement("child project \(reference.projectID.uuidString) · \(reference.editorKind) @\(reference.appliedRevision)", frame.minX + 18, y + 24, 11, color("muted", "muted"), false, false)
                issues.append(.init("svg.editor.previewMissing", "node \(node.id): professional child projects need a host-provided preview", contentClass: "editor", severity: .unavailable))
            case .unknown(let kind, _):
                body += textElement("[\(kind)]", frame.minX + 10, y + 14, 12, text, false, true)
            case .shape:
                break
            }
        }

        if CanvasExchangeFlowBindingSupport.isFlowCard(node) {
            body += "<rect x=\"\(CanvasExchangeGeometry.number(frame.maxX - 44))\" y=\"\(CanvasExchangeGeometry.number(frame.minY + 6))\" width=\"38\" height=\"16\" rx=\"8\" fill=\"\(color("accent", "accent"))\"/>"
            body += textElement("flow", frame.maxX - 38, frame.minY + 17, 10, color("onAccent", "onAccent"), false, false)
        }

        for href in links {
            body += "<a xlink:href=\"\(escape(href))\"><text x=\"\(CanvasExchangeGeometry.number(frame.minX + 10))\" y=\"\(CanvasExchangeGeometry.number(frame.maxY - 8))\" font-size=\"10\" fill=\"\(color("accent", "accent"))\" text-decoration=\"underline\">\(escape(href))</text></a>"
        }
        return "<g\(transform)>\(body)</g>"
    }

    @MainActor
    private static func svgBytes(assetID: UUID, options: Options, issues: inout [CanvasExchangeIssue]) async throws -> Data? {
        guard let resolver = options.assetResolver else {
            issues.append(.init("svg.asset.noResolver", "asset \(assetID) needs bytes but no asset resolver was injected", contentClass: "media", severity: .unavailable))
            return nil
        }
        do {
            return try await resolver.data(for: CanvasAssetLocator(id: assetID))
        } catch {
            issues.append(.init("svg.asset.unavailable", "asset \(assetID): \(error)", contentClass: "media", severity: .unavailable))
            return nil
        }
    }

    @MainActor
    private static func svgImage(assetID: UUID, options: Options, issues: inout [CanvasExchangeIssue]) async throws -> (data: Data, mime: String)? {
        guard let bytes = try await svgBytes(assetID: assetID, options: options, issues: &issues) else { return nil }
        // Only PNG/JPEG embed directly; other formats are not re-encoded
        // silently — the caller gets an explicit issue instead.
        let header = bytes.prefix(8).map { $0 }
        if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return (bytes, "image/png") }
        if header.starts(with: [0xFF, 0xD8]) { return (bytes, "image/jpeg") }
        issues.append(.init("svg.imageFormat", "asset \(assetID) is not PNG/JPEG and is not embedded in SVG (no silent re-encode)", contentClass: "media", severity: .preserved))
        return nil
    }

    private static func imageTag(image: (data: Data, mime: String), rect: (x: Double, y: Double, width: Double, height: Double)) -> String {
        "<image x=\"\(CanvasExchangeGeometry.number(rect.x))\" y=\"\(CanvasExchangeGeometry.number(rect.y))\" width=\"\(CanvasExchangeGeometry.number(rect.width))\" height=\"\(CanvasExchangeGeometry.number(rect.height))\" preserveAspectRatio=\"xMidYMid meet\" xlink:href=\"data:\(image.mime);base64,\(image.data.base64EncodedString())\"/>"
    }

    private static func borderPoint(of frame: CanvasGeometry.Frame, towards target: CanvasGeometry.Point, port: CanvasConnectionPort?) -> CGPoint {
        let center = CGPoint(x: frame.center.x, y: frame.center.y)
        if let port {
            switch port {
            case .top: return .init(x: center.x, y: center.y - frame.size.height / 2)
            case .bottom: return .init(x: center.x, y: center.y + frame.size.height / 2)
            case .leading: return .init(x: center.x - frame.size.width / 2, y: center.y)
            case .trailing: return .init(x: center.x + frame.size.width / 2, y: center.y)
            }
        }
        let dx = target.x - frame.center.x, dy = target.y - frame.center.y
        guard dx != 0 || dy != 0 else { return center }
        let scaleX = dx == 0 ? .infinity : (frame.size.width / 2) / abs(dx)
        let scaleY = dy == 0 ? .infinity : (frame.size.height / 2) / abs(dy)
        let scale = min(scaleX, scaleY)
        return .init(x: center.x + dx * scale, y: center.y + dy * scale)
    }

    private static func arrowhead(tip: CGPoint, prior: CGPoint, color: String) -> String {
        let angle = atan2(tip.y - prior.y, tip.x - prior.x)
        let size = 9.0
        let p1 = CGPoint(x: tip.x - cos(angle - 0.45) * size, y: tip.y - sin(angle - 0.45) * size)
        let p2 = CGPoint(x: tip.x - cos(angle + 0.45) * size, y: tip.y - sin(angle + 0.45) * size)
        func n(_ point: CGPoint) -> String { "\(CanvasExchangeGeometry.number(Double(point.x))),\(CanvasExchangeGeometry.number(Double(point.y)))" }
        return "<polyline points=\"\(n(p1)) \(n(tip)) \(n(p2))\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
