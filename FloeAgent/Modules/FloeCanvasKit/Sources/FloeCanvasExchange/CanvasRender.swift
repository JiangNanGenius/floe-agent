// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreText
import FloeCanvasCore
import FloeDiagramCore
import FloeDiagramExchange

/// Shared projection from a canvas page to renderable content. Used by the
/// PDF, PNG and SVG exporters so all three agree on geometry, wrapping,
/// colors and scope handling.
///
/// Coordinates are world-space canvas coordinates; exporters translate the
/// origin. Bounds include rotated frame corners, stroke points, connection
/// labels and PencilKit ink bounds.
@MainActor
public enum CanvasPageRenderer {
    /// A node plus its resolved draw order.
    public struct Placement {
        public var node: CanvasNodeSnapshot
        public var regionFrame: CanvasGeometry.Frame?
        public var collapsedChip: Bool
    }

    public struct Layout {
        public var page: CanvasPageSnapshot
        public var placements: [Placement]
        public var connections: [CanvasConnectionSnapshot]
        public var regions: [CanvasRegionRecord]
        public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)
    }

    public static func layout(
        page: CanvasPageSnapshot,
        snapshot: CanvasSnapshot,
        scope: CanvasExportScope,
        regionPresentation: CanvasCollapsedRegionPresentation
    ) throws -> Layout {
        let placements: [Placement]
        var regions = page.regions
        switch scope {
        case .wholePage:
            placements = page.nodes.map { node in
                let region = node.regionID.flatMap { id in page.regions.first(where: { $0.id == id }) }
                    ?? page.regions.first(where: { nodeContainsInRegion(node, region: $0) })
                let chip = region?.isCollapsed == true && regionPresentation == .chip
                return Placement(node: node, regionFrame: nil, collapsedChip: chip)
            }
        case .region(let regionID):
            guard let region = page.regions.first(where: { $0.id == regionID }) else {
                throw CanvasExchangeError.invalid("region \(regionID) not found")
            }
            regions = [region]
            placements = page.nodes
                .filter { nodeContainsInRegion($0, region: region) }
                .map { Placement(node: $0, regionFrame: region.frame, collapsedChip: false) }
        case .scene(let sceneID):
            guard let scene = page.scenes.first(where: { $0.id == sceneID }) else {
                throw CanvasExchangeError.invalid("scene \(sceneID) not found")
            }
            let sceneRegions = page.regions.filter { scene.focusedRegionIDs.contains($0.id) }
            regions = sceneRegions
            let focused = Set(scene.focusedNodeIDs)
            placements = page.nodes
                .filter { node in
                    focused.contains(node.id)
                        || sceneRegions.contains(where: { region in nodeContainsInRegion(node, region: region) })
                }
                .map { node in
                    let region = sceneRegions.first(where: { nodeContainsInRegion(node, region: $0) })
                    return Placement(node: node, regionFrame: region?.frame, collapsedChip: region?.isCollapsed == true && regionPresentation == .chip)
                }
        case .selection(let ids):
            placements = page.nodes.filter { ids.contains($0.id) }.map { Placement(node: $0, regionFrame: nil, collapsedChip: false) }
            regions = page.regions.filter { region in placements.contains(where: { nodeContainsInRegion($0.node, region: region) }) }
        }
        let connections = page.connections.filter { connection in
            placements.contains(where: { $0.node.id == connection.sourceNodeID })
                && placements.contains(where: { $0.node.id == connection.destinationNodeID })
        }
        let bounds = try contentBounds(page: page, placements: placements, connections: connections, regions: regions)
        return Layout(page: page, placements: placements, connections: connections, regions: regions, bounds: bounds)
    }

    public static func nodeContainsInRegion(_ node: CanvasNodeSnapshot, region: CanvasRegionRecord) -> Bool {
        node.frame.center.x > region.frame.minX && node.frame.center.x < region.frame.maxX
            && node.frame.center.y > region.frame.minY && node.frame.center.y < region.frame.maxY
    }

    public static func contentBounds(
        page: CanvasPageSnapshot,
        placements: [Placement],
        connections: [CanvasConnectionSnapshot],
        regions: [CanvasRegionRecord]
    ) throws -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        func extend(_ rect: (minX: Double, minY: Double, maxX: Double, maxY: Double)) {
            minX = min(minX, rect.minX); minY = min(minY, rect.minY)
            maxX = max(maxX, rect.maxX); maxY = max(maxY, rect.maxY)
        }
        for placement in placements where !placement.collapsedChip {
            extend(CanvasExchangeGeometry.rotatedBounds(placement.node.frame, rotationDegrees: placement.node.rotationDegrees))
        }
        for placement in placements where placement.collapsedChip {
            extend(chipBounds(for: placement))
        }
        for region in regions {
            extend((region.frame.minX, region.frame.minY, region.frame.maxX, region.frame.maxY))
        }
        for stroke in page.strokes {
            guard let first = stroke.points.first else { continue }
            var xs = [first.x], ys = [first.y]
            for point in stroke.points {
                guard CanvasExchangeGeometry.isUsableCoordinate(point.x), CanvasExchangeGeometry.isUsableCoordinate(point.y) else { continue }
                xs.append(point.x); ys.append(point.y)
            }
            guard let minXS = xs.min(), let maxXS = xs.max(), let minYS = ys.min(), let maxYS = ys.max() else { continue }
            extend((minXS - stroke.width, minYS - stroke.width, maxXS + stroke.width, maxYS + stroke.width))
        }
        if let ink = try CanvasExchangePencilSupport.inkBounds(of: page) {
            extend(ink)
        }
        for connection in connections {
            let label = connection.label ?? ""
            if label.isEmpty { continue }
            guard let source = placements.first(where: { $0.node.id == connection.sourceNodeID }),
                  let target = placements.first(where: { $0.node.id == connection.destinationNodeID }) else { continue }
            let mid = CanvasGeometry.Point(
                x: (source.node.frame.center.x + target.node.frame.center.x) / 2,
                y: (source.node.frame.center.y + target.node.frame.center.y) / 2
            )
            // Opaque chips are sized to the label text (CJK-aware) and
            // centered on the edge midpoint; bounds must cover the whole
            // chip, not a fixed guess.
            let halfWidth = max(120, estimatedTextWidth(String(label.prefix(64)), size: 11) / 2 + 16)
            extend((mid.x - halfWidth, mid.y - 20, mid.x + halfWidth, mid.y + 20))
            let chip = connectionLabelRect(
                from: .init(x: source.node.frame.center.x, y: source.node.frame.center.y),
                to: .init(x: target.node.frame.center.x, y: target.node.frame.center.y),
                textWidth: estimatedTextWidth(String(label.prefix(64)), size: 11))
            extend((chip.minX - 16, chip.minY - 16, chip.maxX + 16, chip.maxY + 16))
        }
        guard minX <= maxX, minY <= maxY else {
            throw CanvasExchangeError.invalid("page \"\(page.name)\" has no renderable content for the requested scope")
        }
        let pad = 32.0
        return (minX - pad, minY - pad, maxX + pad, maxY + pad)
    }

    public static func chipBounds(for placement: Placement) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let name = placement.node.title ?? "region"
        let width = max(96, Double(name.count) * 8 + 48)
        return (placement.node.frame.center.x - width / 2, placement.node.frame.center.y - 16, placement.node.frame.center.x + width / 2, placement.node.frame.center.y + 16)
    }

    // MARK: Colors

    /// Resolves a style metadata value (hex, "#rgb", "1"..."6" JSON Canvas
    /// presets, "transparent", or DiagramKit palette token) to a CGColor.
    public static func color(_ value: String?, fallback: String, appearance: CanvasRenderAppearance) -> CGColor {
        guard let value, !value.isEmpty else {
            return DiagramPalette.color(fallback, appearance: appearance == .dark ? .dark : .light)
        }
        switch value {
        case "1": return CGColor(gray: 0.25, alpha: 1)
        case "2": return CGColor(srgbRed: 0.55, green: 0.13, blue: 0.13, alpha: 1)
        case "3": return CGColor(srgbRed: 0.10, green: 0.42, blue: 0.20, alpha: 1)
        case "4": return CGColor(srgbRed: 0.75, green: 0.35, blue: 0.05, alpha: 1)
        case "5": return CGColor(srgbRed: 0.12, green: 0.35, blue: 0.65, alpha: 1)
        case "6": return CGColor(srgbRed: 0.45, green: 0.20, blue: 0.60, alpha: 1)
        default: return DiagramPalette.color(value, appearance: appearance == .dark ? .dark : .light)
        }
    }

    // MARK: Text

    public struct TextStyle: Sendable {
        public var size: Double
        public var bold: Bool
        public var monospace: Bool
        public var color: CGColor?
        public init(size: Double, bold: Bool = false, monospace: Bool = false, color: CGColor? = nil) {
            self.size = size
            self.bold = bold
            self.monospace = monospace
            self.color = color
        }
    }

    /// CoreText font used by `drawText`/`textWidth` for a style, kept in one
    /// place so measurement and drawing can never disagree about the face.
    public static func font(for style: TextStyle) -> CTFont {
        let base = CTFontCreateWithName(
            (style.monospace ? "Menlo" : ".AppleSystemUIFont") as CFString,
            style.size, nil)
        var traits: CTFontSymbolicTraits = []
        if style.bold { traits.insert(.traitBold) }
        return CTFontCreateCopyWithSymbolicTraits(base, style.size, nil, traits, traits) ?? base
    }

    /// Exact typographic advance width of one line in the given style.
    /// Used to size opaque label chips so a whole label (including CJK,
    /// which is ~1em wide per character) stays legible.
    public static func textWidth(_ text: String, size: Double, bold: Bool = false, monospace: Bool = false) -> Double {
        guard !text.isEmpty else { return 0 }
        let font = font(for: .init(size: size, bold: bold, monospace: monospace))
        let attributed = NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        return Double(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Scalar-aware width estimate for exporters that cannot run CoreText
    /// (SVG): ASCII averages ~0.56em, everything else (CJK, emoji, symbols)
    /// is treated as a full 1em. Matches `textWidth` closely enough for
    /// background-chip sizing and content bounds.
    public static func estimatedTextWidth(_ text: String, size: Double) -> Double {
        var units = 0.0
        for scalar in text.unicodeScalars {
            units += scalar.value < 0x2000 ? 0.56 : 1.0
        }
        return units * size
    }

    /// Keep a short connector's label clear of its arrow tips. Longer
    /// connectors have room for an inline chip at their midpoint.
    public nonisolated static func connectionLabelRect(
        from start: CGPoint, to end: CGPoint, textWidth: Double
    ) -> CGRect {
        let width = max(0, textWidth) + 14
        let height = 22.0
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        let length = hypot(dx, dy)
        var x = Double(start.x + end.x) / 2
        var y = Double(start.y + end.y) / 2
        if length < width + 18 {
            let nx = length > 0 ? dy / length : 0
            let ny = length > 0 ? -dx / length : -1
            let clearance = abs(nx) * width / 2 + abs(ny) * height / 2 + 8
            x += nx * clearance
            y += ny * clearance
        }
        return CGRect(x: x - width / 2, y: y - height / 2,
                      width: width, height: height)
    }

    /// Draws one line horizontally and vertically centered in `rect`. Text
    /// wider than the rect falls back to top-anchored clipped layout so no
    /// glyph is ever silently dropped.
    public static func drawCenteredText(_ text: String, in rect: CGRect, style: TextStyle, context: CGContext) {
        guard rect.width > 1, rect.height > 1, !text.isEmpty else { return }
        let width = textWidth(text, size: style.size, bold: style.bold, monospace: style.monospace)
        let lineHeight = style.size * 1.3
        let drawRect: CGRect
        if width <= rect.width {
            drawRect = CGRect(
                x: rect.midX - width / 2,
                y: rect.midY - lineHeight / 2,
                width: width,
                height: lineHeight)
        } else {
            drawRect = rect
        }
        drawText(text, rect: drawRect, style: style, context: context)
    }

    public static func drawText(_ text: String, rect: CGRect, style: TextStyle, context: CGContext) {
        guard rect.width > 1, rect.height > 1, !text.isEmpty else { return }
        let attributed = NSMutableAttributedString(string: "")
        let font = font(for: style)
        let color = style.color ?? DiagramPalette.color("text")
        attributed.append(.init(string: text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color,
        ]))
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: .init(origin: .zero, size: rect.size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        CTFrameDraw(frame, context)
    }

    public static func drawRuns(_ runs: [CanvasRichTextRun], rect: CGRect, size: Double, fallbackColor: CGColor, context: CGContext) {
        guard rect.width > 1, rect.height > 1 else { return }
        let attributed = NSMutableAttributedString(string: "")
        for run in runs {
            let base = CTFontCreateWithName(".AppleSystemUIFont" as CFString, size, nil)
            var traits: CTFontSymbolicTraits = []
            if run.bold { traits.insert(.traitBold) }
            if run.italic { traits.insert(.traitItalic) }
            let font = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
            var attributes: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): run.foregroundColor.map { color($0, fallback: "text", appearance: .light) } ?? fallbackColor,
            ]
            if run.underline { attributes[.init(kCTUnderlineStyleAttributeName as String)] = 1 }
            if run.strikethrough { attributes[NSAttributedString.Key.strikethroughStyle] = 1 }
            attributed.append(.init(string: run.text, attributes: attributes))
        }
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: .init(origin: .zero, size: rect.size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        CTFrameDraw(frame, context)
    }

    /// Simple greedy wrap used by all exporters (and the SVG pre-layout).
    public static func wrap(_ text: String, maxCharacters: Int) -> [String] {
        var lines: [String] = []
        for sourceLine in text.components(separatedBy: "\n") {
            var remainder = sourceLine
            while remainder.count > maxCharacters {
                let split = remainder.index(remainder.startIndex, offsetBy: maxCharacters)
                var cursor = split
                while cursor > remainder.startIndex && remainder[cursor] != " " {
                    remainder.formIndex(before: &cursor)
                }
                let breakAt = cursor > remainder.startIndex ? cursor : split
                lines.append(String(remainder[..<breakAt]))
                remainder = String(remainder[breakAt...]).trimmingCharacters(in: .whitespaces)
            }
            lines.append(remainder)
        }
        return lines
    }

    // MARK: Shapes

    public static func shapePath(_ kind: CanvasShapeKind, rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        switch kind {
        case .ellipse:
            path.addEllipse(in: rect)
        case .diamond:
            path.move(to: .init(x: rect.midX, y: rect.minY))
            path.addLine(to: .init(x: rect.maxX, y: rect.midY))
            path.addLine(to: .init(x: rect.midX, y: rect.maxY))
            path.addLine(to: .init(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        case .rectangle:
            path.addRect(rect)
        case .roundedRectangle:
            path.addRoundedRect(in: rect, cornerWidth: 10, cornerHeight: 10)
        case .line, .arrow:
            path.move(to: .init(x: rect.minX, y: rect.midY))
            path.addLine(to: .init(x: rect.maxX, y: rect.midY))
        }
        return path
    }

    public static func drawArrowhead(tip: CGPoint, previous: CGPoint, color: CGColor, width: CGFloat, context: CGContext) {
        let angle = atan2(tip.y - previous.y, tip.x - previous.x)
        let size = 9.0
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.move(to: .init(x: tip.x - cos(angle - 0.45) * size, y: tip.y - sin(angle - 0.45) * size))
        context.addLine(to: tip)
        context.addLine(to: .init(x: tip.x - cos(angle + 0.45) * size, y: tip.y - sin(angle + 0.45) * size))
        context.strokePath()
        context.restoreGState()
    }
}
