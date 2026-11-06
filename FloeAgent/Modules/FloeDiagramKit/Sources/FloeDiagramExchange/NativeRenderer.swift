// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import FloeDiagramCore
import FloeDiagramLayout
import FloeDiagramIntegration
import SwiftMath
import PencilKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public enum DiagramAppearance: Sendable { case light, dark }
public enum DiagramPalette {
    public static func color(_ value: String, appearance: DiagramAppearance = .light) -> CGColor {
        let dark = appearance == .dark
        let colors = ["surface": dark ? "262A32" : "FFFFFF", "canvas": dark ? "1C1F25" : "F8F9FB",
                      "text": dark ? "EEF1F7" : "242D3C", "muted": dark ? "ADB8CB" : "626F82",
                      "border": dark ? "414B5C" : "DDE3EB", "edge": dark ? "8C9CB2" : "7E8DA2",
                      "accent": dark ? "9BBFFF" : "365FA4", "onAccent": dark ? "172A46" : "FFFFFF",
                      "soft": dark ? "293B57" : "EDF2FA", "green": dark ? "A3D7C5" : "457164"]
        if value == "transparent" || value == "none" { return CGColor(red: 0, green: 0, blue: 0, alpha: 0) }
        var hex = colors[value] ?? value.replacingOccurrences(of: "#", with: "")
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard (hex.count == 6 || hex.count == 8), let raw = UInt64(hex, radix: 16) else { return color("text", appearance: appearance) }
        let alpha = hex.count == 8 ? CGFloat(raw & 0xff)/255 : 1
        let rgb = hex.count == 8 ? raw >> 8 : raw
        return CGColor(red: CGFloat((rgb >> 16)&255)/255, green: CGFloat((rgb >> 8)&255)/255, blue: CGFloat(rgb&255)/255, alpha: alpha)
    }
}
extension DiagramRect {
    public var cgRect: CGRect { .init(x: x, y: y, width: width, height: height) }
}
extension DiagramPoint {
    public var cgPoint: CGPoint { .init(x: x, y: y) }
}
extension DiagramEdgeGeometry {
    public var cgPath: CGPath {
        let path = CGMutablePath(); path.move(to: start.cgPoint)
        for segment in segments {
            switch segment {
            case .line(let p): path.addLine(to: p.cgPoint)
            case .cubic(let a, let b, let end): path.addCurve(to: end.cgPoint, control1: a.cgPoint, control2: b.cgPoint)
            }
        }
        return path
    }
}

/// Shared native painter for viewport, PDF and PNG. All geometry is supplied by FloeDiagramLayout.
@MainActor public final class DiagramNativeRenderer {
    private var inkData: Data?
    private var inkImage: (CGImage, DiagramRect)?
    public var appearance: DiagramAppearance
    private let images = NSCache<NSString, CGImageBox>()
    private let formulas = NSCache<NSString, MTMathUILabel>()
    private final class CGImageBox: NSObject {
        let image: CGImage; let asset: DiagramAsset; let maximumPixelSize: Int
        init(_ image: CGImage,asset: DiagramAsset,maximumPixelSize: Int) { self.image = image; self.asset = asset; self.maximumPixelSize = maximumPixelSize }
    }
    public init(appearance: DiagramAppearance = .light) {
        self.appearance = appearance; images.totalCostLimit = 32*1_024*1_024; formulas.countLimit = 128
    }
    public func cacheAsset(_ asset: DiagramAsset, data: Data, maximumPixelSize: Int = 1_024) throws {
        _ = try decodeAsset(asset,data: data,maximumPixelSize: maximumPixelSize)
    }
    private func decodeAsset(_ asset: DiagramAsset,data: Data,maximumPixelSize: Int) throws -> CGImage {
        let maximumPixelSize = min(1_024,max(64,maximumPixelSize))
        guard data.count == asset.byteCount, asset.sha256.map({ DiagramCodec.digest(data) == $0 }) ?? true else { throw DiagramError.invalid("image integrity") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, Double(w)*Double(h) <= 120_000_000,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: min(1_024,max(64,maximumPixelSize)), kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { throw DiagramError.invalid("image format or dimensions") }
        images.setObject(CGImageBox(thumbnail,asset: asset,maximumPixelSize: maximumPixelSize), forKey: asset.id.uuidString as NSString, cost: thumbnail.width*thumbnail.height*4)
        return thumbnail
    }
    public func hasCachedAsset(_ id: UUID) -> Bool { images.object(forKey: id.uuidString as NSString) != nil }
    public func hasCachedAsset(_ asset: DiagramAsset, minimumPixelSize: Int = 0) -> Bool {
        if images.object(forKey: asset.id.uuidString as NSString)?.asset != asset { images.removeObject(forKey: asset.id.uuidString as NSString); return false }
        return (images.object(forKey: asset.id.uuidString as NSString)?.maximumPixelSize ?? -1) >= minimumPixelSize
    }
    public static func shapePath(_ kind: DiagramElementKind, rect: CGRect, radius: Double = 12) -> CGPath {
        let path = CGMutablePath()
        switch kind {
        case .ellipse: path.addEllipse(in: rect)
        case .diamond:
            path.move(to: .init(x: rect.midX, y: rect.minY)); path.addLine(to: .init(x: rect.maxX, y: rect.midY))
            path.addLine(to: .init(x: rect.midX, y: rect.maxY)); path.addLine(to: .init(x: rect.minX, y: rect.midY)); path.closeSubpath()
        case .parallelogram:
            let d = min(24, rect.width/5)
            path.move(to: .init(x: rect.minX+d, y: rect.minY)); path.addLine(to: .init(x: rect.maxX, y: rect.minY))
            path.addLine(to: .init(x: rect.maxX-d, y: rect.maxY)); path.addLine(to: .init(x: rect.minX, y: rect.maxY)); path.closeSubpath()
        default: path.addRoundedRect(in: rect, cornerWidth: kind == .rectangle ? 2 : radius, cornerHeight: kind == .rectangle ? 2 : radius)
        }
        return path
    }
    public func draw(document: DiagramDocument, page: DiagramPage, layout: DiagramLayoutResult, in context: CGContext,
                     visibleRect: DiagramRect? = nil, zoom: Double = 1, selection: Set<UUID> = [], selectedEdge: DiagramPathID? = nil,
                     editingElement: UUID? = nil) {
        let visible = visibleRect ?? layout.bounds.insetBy(-60)
        context.setFillColor(DiagramPalette.color(page.theme.background, appearance: appearance)); context.fill(visible.cgRect)
        let ids = layout.spatialIndex.query(visible.insetBy(-40))
        let containers = page.elements.filter { ids.contains($0.id) && ($0.kind.isContainer || $0.kind == .boundary) }.sorted { (layout.frames[$0.id]?.width ?? 0) > (layout.frames[$1.id]?.width ?? 0) }
        for node in containers { if let frame = layout.frames[node.id] { drawElement(node, frame: frame.cgRect, document: document, context: context, zoom: zoom, selected: selection.contains(node.id), editing: editingElement == node.id) } }
        for edge in layout.edges where edge.bounds.insetBy(-30).intersects(visible) {
            drawEdge(edge, context: context, selected: edge.id == selectedEdge, zoom: zoom)
        }
        for node in orderedNodes(page,ids: ids) {
            if let frame = layout.frames[node.id] { drawElement(node, frame: frame.cgRect, document: document, context: context, zoom: zoom, selected: selection.contains(node.id), editing: editingElement == node.id) }
        }
        drawInk(page.ink,in: context,visible: visible)
    }
    private func orderedNodes(_ page: DiagramPage,ids: Set<UUID>) -> [DiagramElement] {
        page.elements.enumerated().filter { ids.contains($0.element.id) && !$0.element.kind.isContainer && $0.element.kind != .boundary }.sorted { a,b in
            let x = Int(a.element.metadata["layer"] ?? "0") ?? 0, y = Int(b.element.metadata["layer"] ?? "0") ?? 0
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
    }
    private func drawInk(_ ink: Data?,in context: CGContext,visible: DiagramRect) {
        if let ink {
            if inkData != ink { inkData = ink; inkImage = try? DiagramNativeInk.image(ink) }
            if let (image, rect) = inkImage, rect.intersects(visible) {
                context.saveGState(); context.translateBy(x: rect.x,y: rect.maxY); context.scaleBy(x: 1,y: -1)
                context.draw(image,in: CGRect(x: 0,y: 0,width: rect.width,height: rect.height)); context.restoreGState()
            }
        }
    }
    /// Exports resolve each image immediately before painting it. Cache eviction cannot erase earlier assets.
    public func drawForExport(document: DiagramDocument,page: DiagramPage,layout: DiagramLayoutResult,
                              in context: CGContext,resolver: (any DiagramAssetResolver)?) async throws {
        var background = page; background.ink = nil
        background.elements = page.elements.filter { $0.kind.isContainer || $0.kind == .boundary }
        let visible = try Self.contentBounds(layout,ink: page.ink).insetBy(-32)
        draw(document: document,page: background,layout: layout,in: context,visibleRect: visible)
        let assets = Dictionary(uniqueKeysWithValues: document.assets.map { ($0.id,$0) })
        for node in orderedNodes(page,ids: Set(layout.frames.keys)) {
            try Task.checkCancellation()
            guard let frame = layout.frames[node.id]?.cgRect else { continue }
            var placements: [(UUID,CGRect)] = []
            let contentY = drawElement(node,frame: frame,document: document,context: context,zoom: 1,selected: false,editing: false,imagePlacement: { placements.append(($0,$1)) })
            context.saveGState(); context.clip(to: frame.insetBy(dx: 3,dy: 3))
            do {
                for (id,rect) in placements {
                    guard let asset = assets[id] else { throw DiagramError.notFound(id) }
                    let image: CGImage
                    if let cached = images.object(forKey: id.uuidString as NSString), cached.asset == asset, cached.maximumPixelSize >= 1_024 { image = cached.image }
                    else {
                        guard let resolver else { throw DiagramError.invalid("image resolver required") }
                        image = try decodeAsset(asset,data: await resolver.data(for: asset),maximumPixelSize: 1_024)
                    }
                    drawImage(image,rect: rect,context: context)
                }
                if let contentY { drawTaskStatus(node,frame: frame,contentY: contentY,document: document,context: context) }
                context.restoreGState()
            } catch { context.restoreGState(); throw error }
        }
        drawInk(page.ink,in: context,visible: visible)
    }
    private func drawEdge(_ edge: DiagramEdgeGeometry, context: CGContext, selected: Bool, zoom: Double) {
        context.saveGState(); defer { context.restoreGState() }
        let color = DiagramPalette.color(selected ? "accent" : edge.color, appearance: appearance)
        context.setStrokeColor(color); context.setFillColor(color); context.setLineWidth(edge.width+(selected ? 0.5 : 0))
        context.setLineCap(.round); context.setLineJoin(.round)
        context.setLineDash(phase: 0, lengths: edge.dashed ? [5, 6] : []); context.addPath(edge.cgPath); context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        let points = edge.polyline()
        if edge.endArrow, points.count >= 2 { arrow(tip: points.last!, previous: points[points.count-2], context: context) }
        if edge.startArrow, points.count >= 2 { arrow(tip: points[0], previous: points[1], context: context) }
        if !edge.label.isEmpty && zoom > 0.35 {
            let (rect, lines) = Self.connectionLabel(edge)
            context.setFillColor(DiagramPalette.color("canvas", appearance: appearance)); context.fill(rect)
            drawText(lines.joined(separator: "\n"), rect: rect.insetBy(dx: 6, dy: 3), size: 11, color: DiagramPalette.color("muted", appearance: appearance), context: context)
        }
        if selected {
            context.setFillColor(DiagramPalette.color("surface", appearance: appearance)); context.setStrokeColor(color); context.setLineWidth(1.5/max(0.1, zoom))
            for p in [edge.start, edge.end] {
                let r = 4/max(0.1, zoom); context.addEllipse(in: .init(x: p.x-r, y: p.y-r, width: 2*r, height: 2*r)); context.drawPath(using: .fillStroke)
            }
        }
    }
    /// CoreText measures fallback glyphs too, so Chinese labels do not get Latin-only width estimates.
    public static func connectionLabel(_ edge: DiagramEdgeGeometry) -> (CGRect, [String]) {
        let value = String(edge.label.prefix(512)) as NSString
        let font = CTFontCreateWithName("HelveticaNeue" as CFString,11,nil)
        let attributed = NSAttributedString(string: value as String,attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed), width = min(320,max(60,ceil(CTLineGetTypographicBounds(line,nil,nil,nil))+16))
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [String] = [], offset = 0
        while offset < value.length && lines.count < 4 {
            let count = max(1,CTTypesetterSuggestLineBreak(typesetter,offset,width-12))
            lines.append(value.substring(with: NSRange(location: offset,length: min(count,value.length-offset))).trimmingCharacters(in: .newlines)); offset += count
        }
        if offset < value.length || edge.label.count > 512 { if !lines.isEmpty { lines[lines.count-1] += "…" } }
        let height = min(60,max(26,Double(lines.count)*13+8)), point = edge.labelPoint
        return (.init(x: point.x-width/2,y: point.y-height/2,width: width,height: height),lines)
    }
    public static func contentBounds(_ layout: DiagramLayoutResult, ink: Data?) throws -> DiagramRect {
        var bounds = layout.bounds
        if let ink = try DiagramNativeInk.bounds(ink) { bounds = bounds.union(ink) }
        for edge in layout.edges where !edge.label.isEmpty {
            let rect = connectionLabel(edge).0
            bounds = bounds.union(.init(x: rect.minX,y: rect.minY,width: rect.width,height: rect.height))
        }
        return bounds
    }
    private func arrow(tip: DiagramPoint, previous: DiagramPoint, context: CGContext) {
        let angle = atan2(tip.y-previous.y, tip.x-previous.x), size = 9.0
        context.move(to: .init(x: tip.x-cos(angle-0.45)*size, y: tip.y-sin(angle-0.45)*size))
        context.addLine(to: tip.cgPoint); context.addLine(to: .init(x: tip.x-cos(angle+0.45)*size, y: tip.y-sin(angle+0.45)*size)); context.strokePath()
    }
    @discardableResult private func drawElement(_ node: DiagramElement, frame: CGRect, document: DiagramDocument, context: CGContext,
                             zoom: Double, selected: Bool, editing: Bool,imagePlacement: ((UUID,CGRect) -> Void)? = nil) -> Double? {
        if node.metadata["connectorEndpoint"] == "true" && !selected { return nil }
        context.saveGState(); defer { context.restoreGState() }
        let foreground = DiagramPalette.color(node.style.text, appearance: appearance)
        if node.kind == .summary {
            context.setStrokeColor(DiagramPalette.color("edge", appearance: appearance)); context.setLineWidth(1.5)
            context.move(to: .init(x: frame.minX+9, y: frame.minY)); context.addLine(to: .init(x: frame.minX, y: frame.minY))
            context.addLine(to: .init(x: frame.minX, y: frame.maxY)); context.addLine(to: .init(x: frame.minX+9, y: frame.maxY)); context.strokePath()
            drawText(node.title, rect: .init(x: frame.minX+15, y: frame.midY-16, width: frame.width-15, height: 40), size: 13, color: foreground, context: context)
            return nil
        }
        if node.kind != .text {
            let path = Self.shapePath(node.kind, rect: frame, radius: node.style.cornerRadius)
            if node.kind == .boundary { context.setLineDash(phase: 0, lengths: [5, 4]); context.setFillColor(CGColor(gray: 0, alpha: 0)) }
            else { context.setFillColor(DiagramPalette.color(node.style.fill, appearance: appearance)) }
            context.setStrokeColor(DiagramPalette.color(selected ? "accent" : node.style.stroke, appearance: appearance))
            context.setLineWidth(selected ? max(1.7/max(0.1, zoom), node.style.lineWidth) : node.style.lineWidth)
            context.addPath(path); context.drawPath(using: .fillStroke)
            context.setLineDash(phase: 0, lengths: [])
        }
        if zoom < 0.22 { return nil }
        if node.metadata["projectedTaskBar"] == "true" {
            if let progress = node.taskID.flatMap({ id in document.tasks.first { $0.id == id }?.progress }), progress > 0 {
                context.saveGState(); context.addPath(Self.shapePath(node.kind,rect: frame,radius: node.style.cornerRadius)); context.clip()
                context.setFillColor(DiagramPalette.color(node.style.text,appearance: appearance)); context.setAlpha(0.12)
                context.fill(CGRect(x: frame.minX,y: frame.minY,width: frame.width*progress,height: frame.height)); context.restoreGState()
            }
            if frame.width >= 54 { drawText(node.title,rect: frame.insetBy(dx: 7,dy: 8),size: 11,color: foreground,context: context) }
            return nil
        }
        if node.kind.isContainer || node.kind == .boundary {
            let vertical = node.metadata["orientation"] == "vertical" && (node.kind == .swimlane || node.kind == .swimlanePool)
            if vertical {
                context.saveGState(); context.translateBy(x: frame.minX+10,y: frame.maxY-14); context.rotate(by: -.pi/2)
                drawText(node.title,rect: CGRect(x: 0,y: 0,width: frame.height-28,height: 24),size: 12,color: DiagramPalette.color("muted",appearance: appearance),bold: true,context: context); context.restoreGState()
            } else { drawText(node.title, rect: frame.insetBy(dx: 14, dy: 10), size: 12, color: DiagramPalette.color("muted", appearance: appearance), bold: true, context: context) }
            if node.kind == .swimlane || node.kind == .swimlanePool {
                context.setStrokeColor(DiagramPalette.color("border", appearance: appearance)); context.setLineWidth(1)
                if vertical { context.move(to: .init(x: frame.minX+36,y: frame.minY)); context.addLine(to: .init(x: frame.minX+36,y: frame.maxY)) }
                else { context.move(to: .init(x: frame.minX, y: frame.minY+36)); context.addLine(to: .init(x: frame.maxX, y: frame.minY+36)) }; context.strokePath()
            }
            return nil
        }
        let padding = node.kind == .text ? 0.0 : (node.kind == .diamond ? 24.0 : 14.0)
        var inner = frame.insetBy(dx: padding, dy: node.kind == .text ? 0 : 12)
        if let marker = node.markers.first {
            #if canImport(UIKit)
            let symbol = UIImage(systemName: marker) ?? UIImage(systemName: "tag")
            let image = symbol?.withTintColor(UIColor(cgColor: foreground),renderingMode: .alwaysOriginal).cgImage
            #else
            var rect = CGRect(x: 0,y: 0,width: 16,height: 16)
            let image = (NSImage(systemSymbolName: marker,accessibilityDescription: nil) ?? NSImage(systemSymbolName: "tag",accessibilityDescription: nil))?.cgImage(forProposedRect: &rect,context: nil,hints: nil)
            #endif
            if let image { drawImage(image,rect: CGRect(x: frame.maxX-25,y: frame.minY+12,width: 13,height: 13),context: context); inner.size.width = max(20,inner.width-18) }
        }
        context.clip(to: node.kind == .text ? frame : frame.insetBy(dx: 3, dy: 3))
        let titleHeight = min(inner.height, max(22, Double((node.title.count+13)/14)*max(20,node.style.fontSize*1.3)))
        var y = inner.minY
        if !editing { drawText(node.title, rect: .init(x: inner.minX, y: y, width: inner.width, height: titleHeight), size: node.style.fontSize, color: foreground, bold: node.style.bold || node.parentID == nil && node.kind.isTopic, context: context) }
        y += titleHeight+7
        for block in node.content {
            if case .image(let id, _) = block {
                let rect = CGRect(x: inner.minX, y: y, width: inner.width, height: min(92, max(0, frame.maxY-12-y)))
                if rect.height > 0 {
                    if let imagePlacement { imagePlacement(id,rect) }
                    else if let image = images.object(forKey: id.uuidString as NSString)?.image { drawImage(image, rect: rect, context: context) }
                    else { drawText(Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "图片" : "Image",rect: rect,size: 11,color: DiagramPalette.color("muted",appearance: appearance),context: context) }
                }
                y += rect.height+8
                if !node.contentExpanded { break }
                continue
            }
            guard node.contentExpanded, y < frame.maxY-18 else { continue }
            let remaining = frame.maxY-12-y
            switch block {
            case .formula(let latex):
                let height = min(46, remaining)
                if !drawFormula(latex, rect: .init(x: inner.minX, y: y, width: inner.width, height: height), context: context) {
                    drawText(latex, rect: .init(x: inner.minX, y: y, width: inner.width, height: height), size: 12, color: foreground, monospace: true, context: context)
                }
                y += height+6
            case .table(let table):
                let columns = max(1, table.rows.first?.count ?? 1), cellWidth = inner.width/Double(columns)
                for (rowIndex, row) in table.rows.prefix(8).enumerated() {
                    if y+24 > frame.maxY-10 { break }
                    if rowIndex == 0 && table.header { context.setFillColor(DiagramPalette.color("soft", appearance: appearance)); context.fill(.init(x: inner.minX, y: y, width: inner.width, height: 24)) }
                    for (column, value) in row.enumerated() { drawText(value, rect: .init(x: inner.minX+Double(column)*cellWidth+4, y: y+4, width: cellWidth-8, height: 18), size: 11, color: foreground, bold: table.header && rowIndex == 0, context: context) }
                    context.setStrokeColor(DiagramPalette.color("border", appearance: appearance)); context.setLineWidth(0.5)
                    context.move(to: .init(x: inner.minX, y: y+24)); context.addLine(to: .init(x: inner.maxX, y: y+24)); context.strokePath(); y += 24
                }; y += 6
            case .richText(let runs):
                let height = min(120, max(22, Double((runs.map(\.text).joined().count+17)/18)*18+6))
                drawRuns(runs, rect: .init(x: inner.minX, y: y, width: inner.width, height: min(height, remaining)), size: 12, color: foreground, context: context); y += height+6
            case .code(_, let text):
                let height = min(68, remaining)
                context.setFillColor(DiagramPalette.color("canvas", appearance: appearance)); context.fill(.init(x: inner.minX, y: y, width: inner.width, height: height))
                drawText(text, rect: .init(x: inner.minX+5, y: y+5, width: inner.width-10, height: height-10), size: 11, color: foreground, monospace: true, context: context); y += height+6
            case .note(let text):
                let height = min(110, max(22, Double((text.count+17)/18)*18+6))
                drawText(text, rect: .init(x: inner.minX, y: y, width: inner.width, height: min(height, remaining)), size: 12, color: DiagramPalette.color("muted", appearance: appearance), context: context); y += height+6
            case .attachment(let id):
                let name = document.assets.first { $0.id == id }?.fileName ?? "Attachment"
                drawText(name, rect: .init(x: inner.minX, y: y, width: inner.width, height: 20), size: 11, color: DiagramPalette.color("accent", appearance: appearance), context: context); y += 24
            case .image: break
            }
        }
        if imagePlacement == nil { drawTaskStatus(node,frame: frame,contentY: y,document: document,context: context) }
        return y
    }
    private func drawTaskStatus(_ node: DiagramElement,frame: CGRect,contentY: Double,document: DiagramDocument,context: CGContext) {
        guard node.metadata["projectedTask"] != "true" else { return }
        let inner = frame.insetBy(dx: node.kind == .diamond ? 24 : 14,dy: 12)
        if let task = node.taskID.flatMap({ id in document.tasks.first { $0.id == id } }), frame.height < 100 || contentY+18 < frame.maxY {
            let text = "\(Int(task.progress*100))%"
            drawText(text, rect: .init(x: inner.minX, y: frame.maxY-23, width: inner.width, height: 16), size: 10, color: DiagramPalette.color(node.style.text == "onAccent" ? "onAccent" : "muted", appearance: appearance), context: context)
        }
    }
    public func drawText(_ text: String, rect: CGRect, size: Double, color: CGColor, bold: Bool = false, monospace: Bool = false, context: CGContext) {
        drawRuns([.init(text, bold: bold)], rect: rect, size: size, color: color, monospace: monospace, context: context)
    }
    private func drawRuns(_ runs: [DiagramTextRun], rect: CGRect, size: Double, color: CGColor, monospace: Bool = false, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let attributed = NSMutableAttributedString(string: "")
        for run in runs {
            let base = CTFontCreateWithName((monospace ? "Menlo" : ".AppleSystemUIFont") as CFString, size, nil)
            var traits: CTFontSymbolicTraits = []
            if run.bold { traits.insert(.traitBold) }; if run.italic { traits.insert(.traitItalic) }
            let font = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
            var attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): color]
            if run.underline { attributes[.init(kCTUnderlineStyleAttributeName as String)] = 1 }
            attributed.append(.init(string: run.text, attributes: attributes))
        }
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: rect); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1); context.textMatrix = .identity
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: .init(origin: .zero, size: rect.size), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil), context)
    }
    private func drawImage(_ image: CGImage, rect: CGRect, context: CGContext) {
        let scale = min(rect.width/Double(image.width), rect.height/Double(image.height))
        let size = CGSize(width: Double(image.width)*scale, height: Double(image.height)*scale)
        context.saveGState(); context.translateBy(x: rect.midX-size.width/2, y: rect.midY+size.height/2); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: .init(origin: .zero, size: size)); context.restoreGState()
    }
    public func formulaIsValid(_ latex: String) -> Bool { acceptableFormula(latex) && mathLabel(latex, width: 300, height: 60).error == nil }
    private func acceptableFormula(_ latex: String) -> Bool {
        guard latex.utf8.count <= 8_192 else { return false }
        var depth = 0
        for c in latex { if c == "{" { depth += 1 }; if c == "}" { depth -= 1 }; if depth > 64 || depth < 0 { return false } }
        return depth == 0
    }
    private func mathLabel(_ latex: String, width: Double, height: Double) -> MTMathUILabel {
        let key = "\(appearance)-\(width)-\(height)-\(latex)" as NSString
        if let label = formulas.object(forKey: key) { return label }
        let label = MTMathUILabel(frame: .init(x: 0, y: 0, width: width, height: height))
        label.fontSize = 18; label.latex = latex; label.displayErrorInline = false; label.preferredMaxLayoutWidth = width
        #if canImport(UIKit)
        label.textColor = UIColor(cgColor: DiagramPalette.color("text", appearance: appearance)); label.setNeedsLayout(); label.layoutIfNeeded()
        #else
        label.textColor = NSColor(cgColor: DiagramPalette.color("text", appearance: appearance)); label.needsLayout = true; label.layoutSubtreeIfNeeded()
        #endif
        formulas.setObject(label, forKey: key); return label
    }
    @discardableResult public func drawFormula(_ latex: String, rect: CGRect, context: CGContext) -> Bool {
        guard acceptableFormula(latex) else { return false }
        let label = mathLabel(latex, width: rect.width, height: rect.height)
        guard label.error == nil, let display = label.displayList else { return false }
        context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        display.draw(context); context.restoreGState(); return true
    }
}
