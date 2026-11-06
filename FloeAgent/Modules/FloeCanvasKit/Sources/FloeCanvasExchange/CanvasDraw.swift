// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import ImageIO
import FloeCanvasCore
import FloeDiagramCore
import FloeDiagramExchange

/// Paints a laid-out canvas page into a CoreGraphics context. Shared by the
/// PDF and PNG exporters so both produce identical geometry and content.
@MainActor
public enum CanvasPageDrawer {
    @discardableResult
    public static func draw(
        layout: CanvasPageRenderer.Layout,
        snapshot: CanvasSnapshot,
        appearance: CanvasRenderAppearance,
        resolver: (any CanvasAssetResolver)?,
        in context: CGContext
    ) async throws -> [CanvasExchangeIssue] {
        var issues: [CanvasExchangeIssue] = []
        let page = layout.page
        let background = CanvasPageRenderer.color("canvas", fallback: "canvas", appearance: appearance)
        let bounds = CGRect(
            x: layout.bounds.minX, y: layout.bounds.minY,
            width: layout.bounds.maxX - layout.bounds.minX,
            height: layout.bounds.maxY - layout.bounds.minY
        )
        context.setFillColor(background)
        context.fill(bounds)

        // Regions first (behind everything).
        for region in layout.regions {
            let rect = CGRect(x: region.frame.minX, y: region.frame.minY, width: region.frame.size.width, height: region.frame.size.height)
            context.saveGState()
            context.setStrokeColor(CanvasPageRenderer.color("border", fallback: "border", appearance: appearance))
            context.setLineWidth(1.2)
            context.setLineDash(phase: 0, lengths: [6, 5])
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.strokePath()
            context.restoreGState()
            if !region.name.isEmpty {
                CanvasPageRenderer.drawText(region.name, rect: CGRect(x: rect.minX + 10, y: rect.minY + 6, width: rect.width - 20, height: 20), style: .init(size: 12, bold: true), context: context)
            }
        }

        // Connection lines first (under the cards): endpoints stay at the
        // exact border/port points so relation geometry is never re-anchored.
        for connection in layout.connections {
            guard let source = layout.placements.first(where: { $0.node.id == connection.sourceNodeID }),
                  let target = layout.placements.first(where: { $0.node.id == connection.destinationNodeID }) else { continue }
            drawConnectionLine(connection, source: source.node, target: target.node, appearance: appearance, in: context)
        }

        // Nodes in z order.
        for placement in layout.placements.sorted(by: { $0.node.zIndex == $1.node.zIndex ? $0.node.id.uuidString < $1.node.id.uuidString : $0.node.zIndex < $1.node.zIndex }) {
            try await drawNode(placement, appearance: appearance, resolver: resolver, in: context, issues: &issues)
        }

        // Arrowheads and label chips ABOVE the cards: in a tight gap the
        // cards would otherwise paint over the label (only its first glyph
        // survived) and the arrow tip. Chips are opaque and sized to the
        // measured text so the whole label stays legible.
        for connection in layout.connections {
            guard let source = layout.placements.first(where: { $0.node.id == connection.sourceNodeID }),
                  let target = layout.placements.first(where: { $0.node.id == connection.destinationNodeID }) else { continue }
            drawConnectionDecorations(connection, source: source.node, target: target.node, appearance: appearance, in: context)
        }

        // Freehand strokes (eraser strokes repaint the background).
        for stroke in page.strokes {
            guard stroke.points.count > 1 else { continue }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: stroke.points[0].x, y: stroke.points[0].y))
            for point in stroke.points.dropFirst() {
                guard CanvasExchangeGeometry.isUsableCoordinate(point.x), CanvasExchangeGeometry.isUsableCoordinate(point.y) else { continue }
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            context.saveGState()
            context.setLineWidth(CGFloat(stroke.width))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if stroke.isEraser {
                context.setStrokeColor(background)
                context.setBlendMode(.copy)
            } else {
                context.setStrokeColor(CanvasPageRenderer.color(stroke.color, fallback: "text", appearance: appearance))
            }
            context.addPath(path)
            context.strokePath()
            context.restoreGState()
        }

        // Page-native PKDrawing ink (pressure/style preserved), world-space.
        if let data = CanvasExchangePencilSupport.drawingData(of: page) {
            do {
                if let (image, rect) = try DiagramNativeInk.image(data) {
                    context.saveGState()
                    context.translateBy(x: rect.x, y: rect.maxY)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
                    context.restoreGState()
                }
            } catch {
                issues.append(.init("render.ink.unavailable", "PencilKit ink on page \"\(page.name)\" could not be rasterized: \(error)", contentClass: "pencil", severity: .unavailable))
            }
        }
        return issues
    }

    private static func drawConnectionLine(_ connection: CanvasConnectionSnapshot, source: CanvasNodeSnapshot, target: CanvasNodeSnapshot, appearance: CanvasRenderAppearance, in context: CGContext) {
        let start = borderPoint(of: source.frame, towards: target.frame.center, port: connection.sourcePort)
        let end = borderPoint(of: target.frame, towards: source.frame.center, port: connection.destinationPort)
        let color = CanvasPageRenderer.color("edge", fallback: "edge", appearance: appearance)
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawConnectionDecorations(_ connection: CanvasConnectionSnapshot, source: CanvasNodeSnapshot, target: CanvasNodeSnapshot, appearance: CanvasRenderAppearance, in context: CGContext) {
        let start = borderPoint(of: source.frame, towards: target.frame.center, port: connection.sourcePort)
        let end = borderPoint(of: target.frame, towards: source.frame.center, port: connection.destinationPort)
        let color = CanvasPageRenderer.color("edge", fallback: "edge", appearance: appearance)
        if connection.kind != .line {
            CanvasPageRenderer.drawArrowhead(tip: end, previous: start, color: color, width: 1.5, context: context)
            if connection.kind == .source || connection.kind == .generatedFrom {
                CanvasPageRenderer.drawArrowhead(tip: start, previous: end, color: color, width: 1.5, context: context)
            }
        }
        if let label = connection.label, !label.isEmpty {
            let text = String(label.prefix(64))
            // Chip sized to the MEASURED text (CJK glyphs are ~1em): a
            // count*7 guess left the second 引用 glyph uncovered.
            let textWidth = CanvasPageRenderer.textWidth(text, size: 11)
            let rect = CanvasPageRenderer.connectionLabelRect(
                from: start, to: end, textWidth: textWidth)
            context.saveGState()
            context.setFillColor(CanvasPageRenderer.color("surface", fallback: "surface", appearance: appearance))
            context.fill(rect)
            context.restoreGState()
            // Text centered in the chip, matching the SVG label geometry.
            CanvasPageRenderer.drawText(
                text,
                rect: CGRect(x: rect.minX + 7, y: rect.minY + 2.5, width: textWidth, height: 17),
                style: .init(size: 11),
                context: context)
        }
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

    private static func drawNode(
        _ placement: CanvasPageRenderer.Placement,
        appearance: CanvasRenderAppearance,
        resolver: (any CanvasAssetResolver)?,
        in context: CGContext,
        issues: inout [CanvasExchangeIssue]
    ) async throws {
        let node = placement.node
        if placement.collapsedChip {
            let chip = CanvasPageRenderer.chipBounds(for: placement)
            let rect = CGRect(x: chip.minX, y: chip.minY, width: chip.maxX - chip.minX, height: chip.maxY - chip.minY)
            context.saveGState()
            context.setFillColor(CanvasPageRenderer.color("soft", fallback: "soft", appearance: appearance))
            context.setStrokeColor(CanvasPageRenderer.color("border", fallback: "border", appearance: appearance))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil))
            context.drawPath(using: .fillStroke)
            context.restoreGState()
            CanvasPageRenderer.drawText(node.title ?? "region", rect: rect.insetBy(dx: 10, dy: 4), style: .init(size: 12), context: context)
            return
        }

        let frame = CGRect(
            x: node.frame.center.x - node.frame.size.width / 2,
            y: node.frame.center.y - node.frame.size.height / 2,
            width: node.frame.size.width,
            height: node.frame.size.height
        )
        context.saveGState()
        context.translateBy(x: node.frame.center.x, y: node.frame.center.y)
        context.rotate(by: -node.rotationDegrees * .pi / 180)
        context.translateBy(x: -node.frame.center.x, y: -node.frame.center.y)

        let style = CanvasExchangeContent.style(of: node)
        let strokeColor = CanvasPageRenderer.color(style.stroke, fallback: "border", appearance: appearance)
        let fillColor = CanvasPageRenderer.color(style.fill, fallback: "surface", appearance: appearance)
        let textColor = CanvasPageRenderer.color(style.textColor, fallback: "text", appearance: appearance)

        // Card background for content nodes; shapes draw their own path.
        let isClosedShape: Bool = {
            guard let shape = CanvasExchangeContent.shapeValue(node.content) else { return false }
            return shape.kind != .line && shape.kind != .arrow
        }()
        if isClosedShape {
            guard let shape = CanvasExchangeContent.shapeValue(node.content) else { return }
            context.saveGState()
            context.setFillColor(fillColor)
            context.setStrokeColor(strokeColor)
            context.setLineWidth(CGFloat(style.strokeWidth ?? 2))
            let path = CanvasPageRenderer.shapePath(shape.kind, rect: frame)
            context.addPath(path)
            context.drawPath(using: .fillStroke)
            context.restoreGState()
            if !shape.text.isEmpty {
                // Centered inside the shape: a top-left anchor spills CJK
                // text outside a diamond's left edge at the baseline row.
                CanvasPageRenderer.drawCenteredText(
                    shape.text,
                    in: frame.insetBy(dx: 8, dy: 8),
                    style: .init(size: 14, color: textColor),
                    context: context)
            }
            context.restoreGState()
            return
        }

        context.saveGState()
        context.setFillColor(fillColor)
        context.setStrokeColor(strokeColor)
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.drawPath(using: .fillStroke)
        context.restoreGState()

        let inner = frame.insetBy(dx: 10, dy: 8)
        var y = inner.minY
        if let title = node.title, !title.isEmpty {
            CanvasPageRenderer.drawText(title, rect: CGRect(x: inner.minX, y: y, width: inner.width, height: 22), style: .init(size: 14, bold: true, color: textColor), context: context)
            y += 26
        }
        let content = node.content
        switch content {
        case .text(let text):
            drawWrappedText(text, in: CGRect(x: inner.minX, y: y, width: inner.width, height: inner.maxY - y), size: 13, color: textColor, context: context)
        case .markdown(let document, _):
            drawWrappedText(document, in: CGRect(x: inner.minX, y: y, width: inner.width, height: inner.maxY - y), size: 13, color: textColor, context: context)
        case .richText(let document):
            CanvasPageRenderer.drawRuns(document.runs, rect: CGRect(x: inner.minX, y: y, width: inner.width, height: inner.maxY - y), size: 13, fallbackColor: textColor, context: context)
        case .code(_, let source):
            let rect = CGRect(x: inner.minX, y: y, width: inner.width, height: min(120, inner.maxY - y))
            context.saveGState()
            context.setFillColor(CanvasPageRenderer.color("canvas", fallback: "canvas", appearance: appearance))
            context.fill(rect)
            context.restoreGState()
            drawWrappedText(source, in: rect.insetBy(dx: 6, dy: 4), size: 11, color: textColor, context: context, monospace: true)
        case .formula(let source, let renderedAssetID):
            var drawn = false
            if let assetID = renderedAssetID, let image = try await awaitImage(assetID: assetID, resolver: resolver, issues: &issues) {
                let rect = CGRect(x: inner.minX, y: y, width: inner.width, height: min(64, inner.maxY - y))
                context.draw(image, in: rect)
                drawn = true
            }
            if !drawn {
                drawWrappedText(source, in: CGRect(x: inner.minX, y: y, width: inner.width, height: inner.maxY - y), size: 12, color: textColor, context: context, monospace: true)
            }
        case .table(let header, let rows):
            drawTable(header: header, rows: rows, in: CGRect(x: inner.minX, y: y, width: inner.width, height: inner.maxY - y), color: textColor, appearance: appearance, context: context)
        case .media(let locator):
            if let image = try await awaitImage(assetID: locator.id, resolver: resolver, issues: &issues) {
                let scale = min(inner.width / Double(image.width), (inner.maxY - y) / Double(image.height), 1)
                let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
                context.saveGState()
                context.translateBy(x: inner.minX + (inner.width - size.width) / 2, y: y + (inner.maxY - y + size.height) / 2)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: size))
                context.restoreGState()
            } else {
                drawPlaceholder(text: "media \(locator.id.uuidString) — bytes unavailable", in: CGRect(x: inner.minX, y: y, width: inner.width, height: min(60, inner.maxY - y)), appearance: appearance, context: context)
            }
        case .pdf(let assetID, let pageRange):
            var drawn = false
            if let assetID, let resolver, let bytes = try await awaitBytes(assetID: assetID, resolver: resolver, issues: &issues) {
                drawn = CanvasNativeExporter.drawPDFCrop(bytes: bytes, pageRange: pageRange, rect: CGRect(x: inner.minX, y: y, width: inner.width, height: inner.maxY - y), context: context)
            }
            if !drawn {
                let rangeText = pageRange.map { "p.\($0.lowerBound)–\($0.upperBound)" } ?? "PDF"
                drawPlaceholder(text: "PDF \(assetID?.uuidString ?? "unresolved") — \(rangeText)", in: CGRect(x: inner.minX, y: y, width: inner.width, height: min(60, inner.maxY - y)), appearance: appearance, context: context)
                issues.append(.init("render.pdf.previewMissing", "node \(node.id): no PDF bytes resolved for the requested page crop; an explicit placeholder card was drawn instead", contentClass: "pdf", severity: .unavailable))
            }
        case .web(let url, let pageTitle):
            drawWrappedText(pageTitle ?? url.absoluteString, in: CGRect(x: inner.minX, y: y, width: inner.width, height: min(40, inner.maxY - y)), size: 13, color: textColor, context: context)
            drawWrappedText(url.absoluteString, in: CGRect(x: inner.minX, y: y + 24, width: inner.width, height: min(24, inner.maxY - y - 24)), size: 11, color: CanvasPageRenderer.color("accent", fallback: "accent", appearance: appearance), context: context)
        case .editor(let reference):
            drawPlaceholder(text: "child project \(reference.projectID.uuidString) · \(reference.editorKind) @\(reference.appliedRevision)", in: CGRect(x: inner.minX, y: y, width: inner.width, height: min(60, inner.maxY - y)), appearance: appearance, context: context)
            issues.append(.init("render.editor.previewMissing", "node \(node.id): professional child projects need a host-provided preview; an explicit card was drawn instead", contentClass: "editor", severity: .unavailable))
        case .unknown(let kind, _):
            drawWrappedText("[\(kind)]", in: CGRect(x: inner.minX, y: y, width: inner.width, height: min(20, inner.maxY - y)), size: 12, color: textColor, context: context, monospace: true)
        case .shape:
            break // closed shapes returned early; lines/arrows fall through as cards
        }

        // Flow card badge: visual marker only, never an execution claim.
        if CanvasExchangeFlowBindingSupport.isFlowCard(node) {
            let badge = "flow"
            let rect = CGRect(x: frame.maxX - 44, y: frame.minY + 6, width: 38, height: 16)
            context.saveGState()
            context.setFillColor(CanvasPageRenderer.color("accent", fallback: "accent", appearance: appearance))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.fillPath()
            context.restoreGState()
            CanvasPageRenderer.drawText(badge, rect: rect.insetBy(dx: 6, dy: 2), style: .init(size: 10, color: CanvasPageRenderer.color("onAccent", fallback: "onAccent", appearance: appearance)), context: context)
        }
        context.restoreGState()
    }

    private static func drawWrappedText(_ text: String, in rect: CGRect, size: Double, color: CGColor, context: CGContext, monospace: Bool = false) {
        guard rect.height > 4 else { return }
        let chars = max(8, Int(rect.width / (size * 0.55)))
        let lines = CanvasPageRenderer.wrap(text, maxCharacters: chars)
        var y = rect.minY
        for line in lines {
            guard y + size + 4 <= rect.maxY else { break }
            CanvasPageRenderer.drawText(line, rect: CGRect(x: rect.minX, y: y, width: rect.width, height: size + 4), style: .init(size: size, monospace: monospace, color: color), context: context)
            y += size + 5
        }
    }

    private static func drawPlaceholder(text: String, in rect: CGRect, appearance: CanvasRenderAppearance, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(CanvasPageRenderer.color("border", fallback: "border", appearance: appearance))
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.strokePath()
        context.restoreGState()
        CanvasPageRenderer.drawText(text, rect: rect.insetBy(dx: 8, dy: 6), style: .init(size: 11, color: CanvasPageRenderer.color("muted", fallback: "muted", appearance: appearance)), context: context)
    }

    private static func drawTable(header: [String], rows: [[String]], in rect: CGRect, color: CGColor, appearance: CanvasRenderAppearance, context: CGContext) {
        let all = (header.isEmpty ? [] : [header]) + rows
        guard !all.isEmpty else { return }
        let columns = max(1, all.map(\.count).max() ?? 1)
        let cellWidth = rect.width / Double(columns)
        var y = rect.minY
        for (rowIndex, row) in all.prefix(12).enumerated() {
            guard y + 22 <= rect.maxY else { break }
            if rowIndex == 0 && !header.isEmpty {
                context.saveGState()
                context.setFillColor(CanvasPageRenderer.color("soft", fallback: "soft", appearance: appearance))
                context.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: 22))
                context.restoreGState()
            }
            for (column, value) in row.enumerated() {
                CanvasPageRenderer.drawText(String(value.prefix(Int(cellWidth / 7))), rect: CGRect(x: rect.minX + Double(column) * cellWidth + 4, y: y + 3, width: cellWidth - 8, height: 16), style: .init(size: 11, bold: rowIndex == 0 && !header.isEmpty, color: color), context: context)
            }
            context.saveGState()
            context.setStrokeColor(CanvasPageRenderer.color("border", fallback: "border", appearance: appearance))
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: rect.minX, y: y + 22))
            context.addLine(to: CGPoint(x: rect.maxX, y: y + 22))
            context.strokePath()
            context.restoreGState()
            y += 22
        }
    }

    private static func awaitBytes(assetID: UUID, resolver: (any CanvasAssetResolver)?, issues: inout [CanvasExchangeIssue]) async throws -> Data? {
        guard let resolver else {
            issues.append(.init("render.asset.noResolver", "asset \(assetID) needs bytes but no asset resolver was injected", contentClass: "media", severity: .unavailable))
            return nil
        }
        let locator = CanvasAssetLocator(id: assetID)
        do {
            return try await resolver.data(for: locator)
        } catch {
            issues.append(.init("render.asset.unavailable", "asset \(assetID): \(error)", contentClass: "media", severity: .unavailable))
            return nil
        }
    }

    private static func awaitImage(assetID: UUID, resolver: (any CanvasAssetResolver)?, issues: inout [CanvasExchangeIssue]) async throws -> CGImage? {
        guard let bytes = try await awaitBytes(assetID: assetID, resolver: resolver, issues: &issues) else { return nil }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              Double(width) * Double(height) <= 120_000_000,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1_024,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else {
            issues.append(.init("render.asset.notAnImage", "asset \(assetID) is not a decodable image", contentClass: "media", severity: .unavailable))
            return nil
        }
        return thumbnail
    }
}
