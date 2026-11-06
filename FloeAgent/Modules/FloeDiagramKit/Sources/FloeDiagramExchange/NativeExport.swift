// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FloeDiagramCore
import FloeDiagramLayout
import FloeDiagramIntegration

public enum DiagramNativeExporter {
    public static func rasterImagePNG(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,height > 0,Double(width)*Double(height) <= 120_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways: true,kCGImageSourceThumbnailMaxPixelSize: 1_024,kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw DiagramError.invalid("image format or dimensions") }
        return try png(image)
    }
    @MainActor public static func previewFormula(_ latex: String, width: Double = 240) throws -> Data? { try formulaPNG(latex, width: width) }
    @MainActor public static func export(_ document: DiagramDocument, format: DiagramFormat, pageID: UUID? = nil,
                                         resolver: (any DiagramAssetResolver)? = nil) async throws -> DiagramExportResult {
        guard format == .pdf || format == .png else { throw DiagramError.unsupported("native output format") }
        let pages = pageID.flatMap { document.page($0).map { [$0] } } ?? (format == .pdf ? document.pages : Array(document.pages.prefix(1)))
        guard !pages.isEmpty else { throw DiagramError.invalid("export pages") }
        let renderer = DiagramNativeRenderer()
        if format == .pdf {
            let storage = CFDataCreateMutable(kCFAllocatorDefault, 0)!
            guard let consumer = CGDataConsumer(data: storage), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw DiagramError.io("PDF context") }
            for page in pages {
                try Task.checkCancellation()
                let layout = try DiagramLayoutEngine.layout(page), bounds = try DiagramNativeRenderer.contentBounds(layout,ink: page.ink).insetBy(-32)
                var rect = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
                let box = NSData(bytes: &rect, length: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
                context.saveGState(); context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
                context.translateBy(x: -bounds.x, y: -bounds.y)
                try await renderer.drawForExport(document: document,page: page,layout: layout,in: context,resolver: resolver)
                context.restoreGState(); context.endPDFPage()
            }
            context.closePDF()
            return .init(data: storage as Data, format: .pdf, issues: pages.contains(where: { $0.ink != nil }) ? [.init("inkRasterized", "PencilKit strokes are embedded as bounded images to preserve eraser masks and ink effects. Editable ink remains in the native file.")] : [])
        }
        let page = pages[0], layout = try DiagramLayoutEngine.layout(page), bounds = try DiagramNativeRenderer.contentBounds(layout,ink: page.ink).insetBy(-32)
        let scale = min(2, 8_192/max(bounds.width, bounds.height), sqrt(24_000_000/(bounds.width*bounds.height)))
        let width = max(1, Int(ceil(bounds.width*scale))), height = max(1, Int(ceil(bounds.height*scale)))
        guard let context = bitmap(width: width, height: height) else { throw DiagramError.io("PNG bitmap") }
        context.translateBy(x: 0, y: Double(height)); context.scaleBy(x: scale, y: -scale); context.translateBy(x: -bounds.x, y: -bounds.y)
        try await renderer.drawForExport(document: document,page: page,layout: layout,in: context,resolver: resolver)
        guard let image = context.makeImage() else { throw DiagramError.io("PNG image") }
        let issues = scale < 1 ? [DiagramExchangeIssue("rasterScaleReduced", "PNG resolution is bounded to 8192 pixels and 24 megapixels; use PDF/SVG for large diagrams.")] : []
        return .init(data: try png(image), format: .png, issues: issues)
    }
    static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    static func png(_ image: CGImage) throws -> Data {
        let storage = CFDataCreateMutable(kCFAllocatorDefault, 0)!
        guard let destination = CGImageDestinationCreateWithData(storage, UTType.png.identifier as CFString, 1, nil) else { throw DiagramError.io("PNG destination") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DiagramError.io("PNG encoding") }
        return storage as Data
    }
    @MainActor static func formulaPNG(_ latex: String, width: Double, height: Double = 46) throws -> Data? {
        let renderer = DiagramNativeRenderer()
        guard let context = bitmap(width: max(1, Int(ceil(width*2))), height: Int(height*2)) else { throw DiagramError.io("formula bitmap") }
        context.translateBy(x: 0, y: height*2); context.scaleBy(x: 2, y: -2)
        guard renderer.drawFormula(latex, rect: .init(x: 0, y: 0, width: width, height: height), context: context), let image = context.makeImage() else { return nil }
        return try png(image)
    }
}

public enum DiagramSVGExporter {
    private static func color(_ token: String) -> String {
        let color = DiagramPalette.color(token)
        if color.alpha == 0 { return "none" }
        let components = color.components ?? [0, 0, 0, 1]
        return String(format: "#%02X%02X%02X", Int(components[0]*255), Int(components[1]*255), Int(components[2]*255))
    }
    public static func export(_ document: DiagramDocument, page: DiagramPage,
                              assets: (any DiagramAssetResolver)? = nil) async throws -> DiagramExportResult {
        let layout = try DiagramLayoutEngine.layout(page), bounds = try await DiagramNativeRenderer.contentBounds(layout,ink: page.ink).insetBy(-32)
        func number(_ x: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), x) }
        func text(_ value: String, x: Double, y: Double, size: Double = 13, fill: String = "text", bold: Bool = false) -> String {
            "<text x=\"\(number(x))\" y=\"\(number(y))\" fill=\"\(color(fill))\" font-family=\"-apple-system,BlinkMacSystemFont,Arial,sans-serif\" font-size=\"\(size)\"\(bold ? " font-weight=\"600\"" : "")>\(ExchangeText.escape(value))</text>"
        }
        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"\(number(bounds.width))\" height=\"\(number(bounds.height))\" viewBox=\"\(number(bounds.x)) \(number(bounds.y)) \(number(bounds.width)) \(number(bounds.height))\"><title>\(ExchangeText.escape(document.title))</title><rect x=\"\(bounds.x)\" y=\"\(bounds.y)\" width=\"\(bounds.width)\" height=\"\(bounds.height)\" fill=\"\(color(page.theme.background))\"/>"
        var issues: [DiagramExchangeIssue] = [], assetData: [UUID: Data] = [:]
        func shape(_ node: DiagramElement, frame: DiagramRect) -> String {
            let style = "fill=\"\(node.kind == .boundary ? "none" : color(node.style.fill))\" stroke=\"\(color(node.style.stroke))\" stroke-width=\"\(node.style.lineWidth)\""
            switch node.kind {
            case .ellipse: return "<ellipse cx=\"\(frame.center.x)\" cy=\"\(frame.center.y)\" rx=\"\(frame.width/2)\" ry=\"\(frame.height/2)\" \(style)/>"
            case .diamond: return "<polygon points=\"\(frame.center.x),\(frame.y) \(frame.maxX),\(frame.center.y) \(frame.center.x),\(frame.maxY) \(frame.x),\(frame.center.y)\" \(style)/>"
            case .parallelogram: return "<polygon points=\"\(frame.x+20),\(frame.y) \(frame.maxX),\(frame.y) \(frame.maxX-20),\(frame.maxY) \(frame.x),\(frame.maxY)\" \(style)/>"
            case .text: return ""
            case .summary: return "<path d=\"M \(frame.x+9) \(frame.y) H \(frame.x) V \(frame.maxY) H \(frame.x+9)\" fill=\"none\" stroke=\"\(color("edge"))\"/>"
            default: return "<rect x=\"\(frame.x)\" y=\"\(frame.y)\" width=\"\(frame.width)\" height=\"\(frame.height)\" rx=\"\(node.style.cornerRadius)\" \(style)\(node.kind == .boundary ? " stroke-dasharray=\"5 4\"" : "")/>"
            }
        }
        let containers = page.elements.filter { $0.kind.isContainer || $0.kind == .boundary }
        for node in containers { if let frame = layout.frames[node.id] { svg += shape(node, frame: frame); svg += text(node.title, x: frame.x+14, y: frame.y+24, size: 12, fill: "muted") } }
        for edge in layout.edges {
            var d = "M \(number(edge.start.x)) \(number(edge.start.y))"
            for segment in edge.segments {
                switch segment {
                case .line(let p): d += " L \(number(p.x)) \(number(p.y))"
                case .cubic(let a, let b, let p): d += " C \(number(a.x)) \(number(a.y)) \(number(b.x)) \(number(b.y)) \(number(p.x)) \(number(p.y))"
                }
            }
            svg += "<path d=\"\(d)\" fill=\"none\" stroke=\"\(color(edge.color))\" stroke-width=\"\(edge.width)\" stroke-linecap=\"round\" stroke-linejoin=\"round\"\(edge.dashed ? " stroke-dasharray=\"5 6\"" : "")/>"
            let points = edge.polyline()
            for (enabled, tip, prior) in [(edge.endArrow, points.last!, points.count > 1 ? points[points.count-2] : edge.start), (edge.startArrow, edge.start, points.count > 1 ? points[1] : edge.end)] where enabled {
                let angle = atan2(tip.y-prior.y, tip.x-prior.x)
                svg += "<path d=\"M \(tip.x-cos(angle-0.45)*9) \(tip.y-sin(angle-0.45)*9) L \(tip.x) \(tip.y) L \(tip.x-cos(angle+0.45)*9) \(tip.y-sin(angle+0.45)*9)\" fill=\"none\" stroke=\"\(color(edge.color))\" stroke-width=\"\(edge.width)\"/>"
            }
            if !edge.label.isEmpty {
                let (rect,lines) = await DiagramNativeRenderer.connectionLabel(edge)
                svg += "<rect x=\"\(rect.minX)\" y=\"\(rect.minY)\" width=\"\(rect.width)\" height=\"\(rect.height)\" fill=\"\(color("canvas"))\"/>"
                for (index,line) in lines.enumerated() { svg += text(line,x: rect.minX+6,y: rect.minY+14+Double(index)*13,size: 11,fill: "muted") }
            }
        }
        for node in page.elements where !node.kind.isContainer && node.kind != .boundary && node.metadata["connectorEndpoint"] != "true" {
            try Task.checkCancellation()
            guard let frame = layout.frames[node.id] else { continue }
            svg += shape(node, frame: frame)
            if node.metadata["projectedTaskBar"] == "true" {
                if let progress = node.taskID.flatMap({ id in document.tasks.first { $0.id == id }?.progress }),progress > 0 {
                    svg += "<clipPath id=\"bar-\(node.id)\"><rect x=\"\(frame.x)\" y=\"\(frame.y)\" width=\"\(frame.width)\" height=\"\(frame.height)\" rx=\"\(node.style.cornerRadius)\"/></clipPath><rect x=\"\(frame.x)\" y=\"\(frame.y)\" width=\"\(frame.width*progress)\" height=\"\(frame.height)\" fill=\"\(color(node.style.text))\" opacity=\"0.12\" clip-path=\"url(#bar-\(node.id))\"/>"
                }
                if frame.width >= 54 { svg += text(node.title,x: frame.x+7,y: frame.y+23,size: 11,fill: node.style.text) }; continue
            }
            let inset = node.kind == .diamond ? 24.0 : 14.0, width = max(20, frame.width-2*inset)
            let x = frame.x+inset
            var y = frame.y+28
            let chars = max(1, Int(width/max(8, node.style.fontSize*0.9)))
            var title = node.title[...]
            while !title.isEmpty && y < frame.maxY-8 {
                let end = title.index(title.startIndex, offsetBy: min(chars, title.count))
                svg += text(String(title[..<end]), x: x, y: y, size: node.style.fontSize, fill: node.style.text, bold: node.style.bold || node.parentID == nil && node.kind.isTopic)
                title = title[end...]; y += 20
            }
            y += 4
            svg += "<clipPath id=\"card-\(node.id.uuidString)\"><rect x=\"\(frame.x+3)\" y=\"\(frame.y+3)\" width=\"\(max(1,frame.width-6))\" height=\"\(max(1,frame.height-6))\"/></clipPath><g clip-path=\"url(#card-\(node.id.uuidString))\">"
            for block in node.content {
                guard y < frame.maxY-10 else { break }
                if case .image(let id, _) = block, let asset = document.assets.first(where: { $0.id == id }) {
                    guard let assets else { throw DiagramError.invalid("SVG image resolver required") }
                    let data: Data
                    if let cached = assetData[id] { data = cached } else {
                        data = try await assets.data(for: asset); assetData[id] = data
                        guard data.count == asset.byteCount, asset.sha256.map({ DiagramCodec.digest(data) == $0 }) ?? true else { throw DiagramError.invalid("SVG image integrity") }
                    }
                    let encoded: Data, mime: String
                    if ["image/png","image/jpeg"].contains(asset.mediaType) { encoded = data; mime = asset.mediaType }
                    else { encoded = try DiagramNativeExporter.rasterImagePNG(data); mime = "image/png"; issues.append(.init("imageConverted", "SVG embeds other raster formats as PNG thumbnails. Original image bytes remain in the native file.")) }
                    svg += "<image x=\"\(x)\" y=\"\(y-12)\" width=\"\(width)\" height=\"\(min(92, frame.maxY-y))\" xlink:href=\"data:\(mime);base64,\(encoded.base64EncodedString())\"/>"
                    y += 100; continue
                }
                guard node.contentExpanded else { continue }
                if case .formula(let latex) = block, let image = try await DiagramNativeExporter.formulaPNG(latex, width: width) {
                    svg += "<image x=\"\(x)\" y=\"\(y-12)\" width=\"\(width)\" height=\"46\" xlink:href=\"data:image/png;base64,\(image.base64EncodedString())\"/>"
                    y += 50; issues.append(.init("formulaRasterized", "SVG embeds native-rendered formula images; PDF retains native formula drawing.")); continue
                }
                if case .table(let table) = block {
                    let columns = max(1,table.rows.first?.count ?? 1), cell = width/Double(columns)
                    for (rowIndex,row) in table.rows.prefix(8).enumerated() where y+22 < frame.maxY-6 {
                        for (column,value) in row.enumerated() {
                            let left = x+Double(column)*cell
                            svg += "<rect x=\"\(left)\" y=\"\(y-12)\" width=\"\(cell)\" height=\"22\" fill=\"\(table.header && rowIndex == 0 ? color("soft") : color("surface"))\" stroke=\"\(color("border"))\" stroke-width=\"0.5\"/>"
                            svg += text(String(value.prefix(max(1,Int(cell/8)))),x: left+4,y: y+3,size: 10,fill: node.style.text,bold: table.header && rowIndex == 0)
                        }; y += 22
                    }; y += 6; continue
                }
                if case .richText(let runs) = block {
                    svg += "<text x=\"\(x)\" y=\"\(y)\" font-family=\"-apple-system,Arial,sans-serif\" font-size=\"12\" fill=\"\(color(node.style.text))\" xml:space=\"preserve\">"
                    var column = 0
                    for run in runs {
                        let style = (run.bold ? " font-weight=\"600\"" : "")+(run.italic ? " font-style=\"italic\"" : "")+(run.underline || run.link != nil ? " text-decoration=\"underline\"" : "")
                        for character in run.text {
                            if character == "\n" || column >= chars { y += 18; column = 0; svg += "<tspan x=\"\(x)\" dy=\"18\"/>"; if character == "\n" { continue } }
                            svg += "<tspan\(style)>\(ExchangeText.escape(String(character)))</tspan>"; column += 1
                        }
                    }; svg += "</text>"; y += 24; continue
                }
                if case .attachment(let id) = block {
                    svg += text(document.assets.first(where: { $0.id == id })?.fileName ?? "Attachment",x: x,y: y,size: 11,fill: "accent"); y += 24; continue
                }
                if case .code(_,let source) = block {
                    svg += "<rect x=\"\(x)\" y=\"\(y-12)\" width=\"\(width)\" height=\"\(min(68,frame.maxY-y))\" fill=\"\(color("canvas"))\"/>"
                    for line in source.components(separatedBy: "\n").prefix(4) where y < frame.maxY-10 { svg += "<text x=\"\(x+5)\" y=\"\(y)\" font-family=\"monospace\" font-size=\"11\" fill=\"\(color(node.style.text))\" xml:space=\"preserve\">\(ExchangeText.escape(String(line.prefix(chars))))</text>"; y += 16 }; y += 6; continue
                }
                for line in block.plainText.components(separatedBy: "\n") where y < frame.maxY-10 {
                    svg += text(String(line.prefix(chars)), x: x, y: y, size: 12, fill: "muted"); y += 18
                }
            }
            svg += "</g>"
        }
        if let ink = page.ink, let (image, bounds) = try await DiagramNativeInk.image(ink) {
            let png = try DiagramNativeExporter.png(image)
            svg += "<image x=\"\(bounds.x)\" y=\"\(bounds.y)\" width=\"\(bounds.width)\" height=\"\(bounds.height)\" xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/>"
            issues.append(.init("inkRasterized", "SVG embeds PencilKit strokes as bounded images; editable strokes remain in the native file."))
        }
        if page.elements.contains(where: { !$0.markers.isEmpty }) { issues.append(.init("platformSymbols", "SVG omits platform symbol icons; PDF/PNG and the editable native file retain them.")) }
        svg += "</svg>"
        return .init(data: Data(svg.utf8), format: .svg, issues: Array(Set(issues)))
    }
}

public enum DiagramPlanProjection {
    private static func stable(_ value: String) -> UUID {
        let h = Array(DiagramCodec.digest(Data(value.utf8)))
        return UUID(uuidString: String(h[0..<8])+"-"+String(h[8..<12])+"-"+String(h[12..<16])+"-"+String(h[16..<20])+"-"+String(h[20..<32]))!
    }
    /// Render-only projection with stable hit identities and references to the original shared task records.
    public static func document(_ original: DiagramDocument, board: Bool = false) throws -> DiagramDocument {
        guard !original.tasks.isEmpty else { throw DiagramError.invalid("no project tasks") }
        let zh = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        func label(_ cn: String, _ en: String) -> String { zh ? cn : en }
        func identity(_ key: String) -> UUID { stable(original.id.uuidString+":"+key) }
        var elements: [DiagramElement] = [], edges: [DiagramConnection] = [], bars: [UUID: UUID] = [:], metadata: [String: String] = [:]
        elements.append(.init(id: identity("heading"), kind: .text, title: original.title, frame: .init(x: 0, y: 0, width: 1_000, height: 48), style: .init(fontSize: 24, bold: true)))
        if board {
            for (column, status) in DiagramTaskStatus.allCases.enumerated() {
                let group = identity("column:"+status.rawValue), x = Double(column)*300
                let tasks = original.tasks.filter { $0.status == status }
                let title: String = switch status { case .todo: label("待办", "To do"); case .inProgress: label("进行中", "In progress"); case .done: label("已完成", "Done") }
                elements.append(.init(id: group, kind: .group, title: title+" · \(tasks.count)", frame: .init(x: x, y: 60, width: 280, height: Double(max(2, tasks.count))*100+60)))
                for (row, task) in tasks.enumerated() {
                    elements.append(.init(id: identity("task:"+task.id.uuidString), kind: .roundedRectangle, title: task.title, containerID: group,
                                          frame: .init(x: x+15, y: 110+Double(row)*100, width: 250, height: 80), contentExpanded: true,
                                          content: [.note(task.assignee.isEmpty ? "\(Int(task.progress*100))%" : task.assignee+" · \(Int(task.progress*100))%")], taskID: task.id,metadata: ["projectedTask": "true"]))
                }
            }
        } else {
            let calendar = original.workCalendar.calendar
            let starts = original.tasks.compactMap(\.start), ends = original.tasks.compactMap(\.end)
            let first = calendar.startOfDay(for: starts.min() ?? Date()), last = calendar.startOfDay(for: ends.max() ?? first)
            let total = Double(max(1,(calendar.dateComponents([.day],from: first,to: last).day ?? 0)+1)), unit = min(36, 850/total)
            metadata["dayWidth"] = String(unit); metadata["firstDate"] = String(first.timeIntervalSince1970); metadata["calendarTimeZone"] = calendar.timeZone.identifier
            let step = max(1, Int(ceil(60/unit))), days = min(365_000, Int(total))
            let formatter = DateFormatter(); formatter.dateFormat = "M/d"; formatter.timeZone = calendar.timeZone
            for day in stride(from: 0, through: days, by: step) {
                elements.append(.init(id: identity("day:\(day)"), kind: .text, title: formatter.string(from: calendar.date(byAdding: .day,value: day,to: first)!), frame: .init(x: 250+Double(day)*unit, y: 52, width: 65, height: 30), style: .init(text: "muted", fontSize: 11)))
            }
            for (row, task) in original.tasks.enumerated() {
                let y = 100+Double(row)*70, id = identity("task:"+task.id.uuidString)
                elements.append(.init(id: identity("task-label:"+task.id.uuidString), kind: .text, title: task.title,
                                      frame: .init(x: 0, y: y-8, width: 220, height: 68), contentExpanded: true,content: [.note(task.assignee)],taskID: task.id, metadata: ["taskLabel": "true","projectedTask": "true"]))
                guard let start = task.start, let end = task.end else { continue }
                bars[task.id] = id
                let offset = max(0,calendar.dateComponents([.day],from: first,to: calendar.startOfDay(for: start)).day ?? 0)
                let duration = max(1,(calendar.dateComponents([.day],from: calendar.startOfDay(for: start),to: calendar.startOfDay(for: end)).day ?? 0)+1)
                elements.append(.init(id: id, kind: .roundedRectangle, title: "\(Int(task.progress*100))%", frame: .init(x: 250+Double(offset)*unit, y: y, width: max(30, Double(duration)*unit), height: 38), style: .init(fill: task.status == .done ? "soft" : "accent", text: task.status == .done ? "text" : "onAccent", fontSize: 12), taskID: task.id,metadata: ["projectedTask": "true","projectedTaskBar": "true"]))
            }
            for dependency in original.dependencies {
                if let a = bars[dependency.predecessorID], let b = bars[dependency.successorID] { edges.append(.init(id: identity("dependency:"+dependency.id.uuidString), from: a, to: b, kind: .flow, route: .orthogonal, sourceAnchor: .right, targetAnchor: .left, endArrow: true, metadata: ["dependencyID": dependency.id.uuidString])) }
            }
        }
        var document = original
        document.pages = [.init(id: identity(board ? "board" : "gantt"), title: board ? label("看板", "Board") : label("甘特图", "Gantt"), structure: .free, elements: elements, connections: edges, metadata: metadata)]
        return document
    }
}
