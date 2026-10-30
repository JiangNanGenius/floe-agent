//
//  CADDrawingPanelView.swift
//  FloeCADKit
//
//  Drawing panel for the Floe workbench: real projected-vector page preview
//  (SwiftUI Canvas over the same `pageGeometry` payload the exports use — never
//  a screenshot), full page/view editing (kind, sources, scale, paper,
//  orientation, section/detail windows, title, part numbers, centerlines,
//  dimensions) through `CADDrawingService`, assembly-aware projected views with
//  named exploded offsets, BOM/balloons/manual dimensions/text annotations, and
//  vector PDF/SVG/DXF export of exactly the document shown.
//
//  SPDX-License-Identifier: MPL-2.0
//

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreGraphics

// MARK: - Preview model

struct CADDrawingPreviewEntity {
    enum Shape {
        case line(CGPoint, CGPoint)
        case circle(center: CGPoint, radius: CGFloat)
        case arc(center: CGPoint, radius: CGFloat, startAngle: Double, endAngle: Double)
        case polyline(points: [CGPoint], closed: Bool)
    }
    var shape: Shape
    var layer: String
}

struct CADDrawingPreviewDimension {
    var text: String
    var position: CGPoint
    var kind: String
}

struct CADDrawingPreviewText {
    var text: String
    var position: CGPoint
    var height: Double
    var layer: String
}

struct CADDrawingPreview {
    var pageID: UUID
    var name: String
    var kind: String
    var scale: Double
    var entities: [CADDrawingPreviewEntity]
    var dimensions: [CADDrawingPreviewDimension]
    var texts: [CADDrawingPreviewText] = []
    var balloons: [[String: Any]] = []
    var manualDimensions: [[String: Any]] = []
    var bomRows: [[String: Any]] = []
    var centerlines: [CADDrawingPreviewEntity] = []
    var counts: [String: Int] = [:]
    var notes: [String] = []
    var stale: Bool = false

    init(reply: [String: Any]) {
        let page = reply["page"] as? [String: Any] ?? [:]
        pageID = UUID(uuidString: page["id"] as? String ?? "") ?? UUID()
        name = page["name"] as? String ?? "—"
        kind = page["kind"] as? String ?? ""
        scale = page["scale"] as? Double ?? 1
        stale = page["stale"] as? Bool ?? false
        counts = reply["counts"] as? [String: Int] ?? [:]
        notes = reply["notes"] as? [String] ?? []
        entities = (reply["entities"] as? [[String: Any]] ?? []).compactMap(Self.parseEntity)
        centerlines = (reply["centerlines"] as? [[String: Any]] ?? []).compactMap(Self.parseEntity)
        dimensions = (reply["dimensions"] as? [[String: Any]] ?? []).compactMap { row in
            guard let text = row["text"] as? String,
                  let position = row["textPosition"] as? [Double], position.count == 2 else {
                return nil
            }
            return CADDrawingPreviewDimension(
                text: text,
                position: CGPoint(x: position[0], y: position[1]),
                kind: row["kind"] as? String ?? "linear")
        }
        texts = (reply["texts"] as? [[String: Any]] ?? []).compactMap { row in
            guard let text = row["text"] as? String,
                  let position = row["position"] as? [Double], position.count == 2 else {
                return nil
            }
            return CADDrawingPreviewText(
                text: text,
                position: CGPoint(x: position[0], y: position[1]),
                height: row["height"] as? Double ?? 3,
                layer: row["layer"] as? String ?? "annotation")
        }
        balloons = reply["balloons"] as? [[String: Any]] ?? []
        manualDimensions = reply["manualDimensions"] as? [[String: Any]] ?? []
        bomRows = ((reply["bom"] as? [String: Any])?["entries"] as? [[String: Any]]) ?? []
        if let issues = reply["bindingIssues"] as? [String], !issues.isEmpty {
            notes.append(contentsOf: issues)
        }
    }

    private static func parseEntity(_ row: [String: Any]) -> CADDrawingPreviewEntity? {
        let layer = row["layer"] as? String ?? "geometry"
        switch row["kind"] as? String {
        case "line":
            guard let a = point(row["a"]), let b = point(row["b"]) else { return nil }
            return CADDrawingPreviewEntity(shape: .line(a, b), layer: layer)
        case "circle":
            guard let center = point(row["center"]), let radius = row["radius"] as? Double else { return nil }
            return CADDrawingPreviewEntity(shape: .circle(center: center, radius: radius), layer: layer)
        case "arc":
            guard let center = point(row["center"]), let radius = row["radius"] as? Double,
                  let start = row["startAngle"] as? Double,
                  let end = row["endAngle"] as? Double else { return nil }
            return CADDrawingPreviewEntity(
                shape: .arc(center: center, radius: radius, startAngle: start, endAngle: end),
                layer: layer)
        case "polyline":
            guard let raw = row["points"] as? [[Double]] else { return nil }
            return CADDrawingPreviewEntity(
                shape: .polyline(points: raw.compactMap(point), closed: row["closed"] as? Bool ?? false),
                layer: layer)
        default:
            return nil
        }
    }

    private static func point(_ raw: Any?) -> CGPoint? {
        guard let values = raw as? [Double], values.count == 2 else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }
}

// MARK: - Localized display helpers

/// Localized drawing-view-kind label (the raw service value stays on disk).
func localizedDrawingKind(_ raw: String) -> String {
    let fallback: String
    switch raw {
    case "front": fallback = "Front"
    case "top": fallback = "Top"
    case "side": fallback = "Side"
    case "iso": fallback = "Isometric"
    case "section": fallback = "Section"
    case "detail": fallback = "Detail"
    default: fallback = raw
    }
    return FloeCADStrings.text("cad.workbench.drawing.kind.\(raw)", fallback)
}

/// Localized label for a projected-entity/element count bucket.
func localizedDrawingCount(_ key: String) -> String {
    let fallback: String
    switch key {
    case "entities": fallback = "entities"
    case "lines": fallback = "lines"
    case "circles": fallback = "circles"
    case "arcs": fallback = "arcs"
    case "polylines": fallback = "polylines"
    case "dimensions": fallback = "dimensions"
    case "centerlines": fallback = "centerlines"
    default: fallback = key
    }
    return FloeCADStrings.text("cad.workbench.drawing.count.\(key)", fallback)
}

/// Defaults for the page editor (unit-testable): a NEW page must start at a
/// valid scale of 1 — the old `Double(text) ?? 0` default displayed 0 and
/// disabled Save (CUA 2026-10-10).
enum CADDrawingPageEditorDefaults {
    static func scale(page: [String: Any]?) -> String {
        guard let page, let value = page["scale"] as? Double, value > 0 else {
            return "1"
        }
        return CADPanelTransform.format(value)
    }

    static func name(page: [String: Any]?) -> String {
        if let name = page?["name"] as? String, !name.isEmpty { return name }
        return FloeCADStrings.text("cad.workbench.drawing.sheetDefault", "Sheet")
    }
}

// MARK: - Panel

struct CADDrawingPanelView: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    @State private var pages: [[String: Any]] = []
    @State private var outcome: [String: Any] = [:]
    @State private var exportURL: URL?
    @State private var busy = false
    @State private var preview: CADDrawingPreview?
    @State private var activeSheet: CADDrawingSheetRoute?

    /// Explicit source body: the current viewport selection ONLY (never a
    /// silent first body).
    private var selectedBodyID: UUID? {
        viewModel.selection.first?.raw
    }

    var body: some View {
        WorkbenchPanelChrome(title: FloeCADStrings.text("cad.workbench.panel.drawing", "Drawings"),
                             identifier: "CADDrawingPanel") {
            PanelActionGrid {
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.drawing.add", "Add page"),
                                  systemImage: "plus.rectangle", disabled: busy) {
                    activeSheet = .edit(CADDrawingPageEditorRequest(page: nil))
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.drawing.sheet", "Standard sheet"),
                                  systemImage: "doc.on.doc", disabled: busy || selectedBodyID == nil) {
                    standardSheet()
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.drawing.assemblySheet",
                                                              "Assembly sheet"),
                                  systemImage: "square.stack.3d.up",
                                  disabled: busy) {
                    assemblySheet()
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.drawing.refresh", "Refresh"),
                                  systemImage: "arrow.clockwise", disabled: busy) {
                    refresh()
                }
            }
            if selectedBodyID == nil {
                Text(FloeCADStrings.text("cad.workbench.drawing.selectBodyForSheet",
                                         "Select a body in the viewport to create a standard sheet for it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if busy { ProgressView().controlSize(.small) }
            PanelOutcome(reply: outcome)

            if let preview {
                CADDrawingVectorPreview(preview: preview) {
                    self.preview = nil
                }
            }

            if pages.isEmpty {
                PanelEmptyState(
                    text: FloeCADStrings.text("cad.workbench.drawing.empty", "No drawing pages yet."),
                    hint: FloeCADStrings.text("cad.workbench.drawing.emptyHint",
                                              "Add a page (or a standard sheet for the selected body); pages carry their own scale, paper and dimensions, and mark themselves stale when the model moves."))
            } else {
                PanelSection(title: FloeCADStrings.text("cad.workbench.drawing.pages", "Pages")) {
                    ForEach(pages.indices, id: \.self) { index in
                        let page = pages[index]
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(page["name"] as? String ?? "—")
                                    .font(.callout.weight(.semibold))
                                Text("· \(localizedDrawingKind(page["kind"] as? String ?? ""))")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                if let scale = page["scale"] as? Double, scale > 0 {
                                    Text("· 1:\(Self.scaleText(scale))")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                if page["assemblyMode"] as? Bool == true {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.drawing.badgeAssembly",
                                                                         "assembly"))
                                }
                                if let name = page["explodedViewName"] as? String, !name.isEmpty {
                                    PanelBadge(text: name, tint: .purple)
                                }
                                if page["showBOM"] as? Bool == true {
                                    PanelBadge(text: "BOM \(page["bomEntryCount"] as? Int ?? 0)",
                                               tint: .brown)
                                }
                                Spacer(minLength: 4)
                                if page["stale"] as? Bool == true {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.stale", "stale"),
                                               tint: .orange)
                                }
                            }
                            PanelActionGrid {
                                panelHitTarget(Button(FloeCADStrings.label("cad.workbench.drawing.project", "Preview")) {
                                    showGeometry(page)
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                                panelHitTarget(Button(FloeCADStrings.label("cad.workbench.drawing.edit", "Edit")) {
                                    activeSheet = .edit(CADDrawingPageEditorRequest(page: page))
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                                panelHitTarget(Button(FloeCADStrings.label("cad.workbench.drawing.pdf", "PDF")) {
                                    export(page, format: "pdf")
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                                panelHitTarget(Button("SVG") { export(page, format: "svg") }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                                panelHitTarget(Button("DXF") { export(page, format: "dxf") }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                                panelHitTarget(Button(FloeCADStrings.label("cad.workbench.drawing.bom", "BOM")) {
                                    activeSheet = .bom(CADDrawingAnnotationPageRequest(page: page))
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                                panelHitTarget(Button(FloeCADStrings.label("cad.workbench.drawing.balloon",
                                                                           "Balloon")) {
                                    activeSheet = .balloon(CADDrawingAnnotationPageRequest(page: page))
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                                panelHitTarget(Button(FloeCADStrings.label("cad.workbench.drawing.dimension",
                                                                           "Dimension")) {
                                    activeSheet = .dimension(CADDrawingAnnotationPageRequest(page: page))
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                                panelHitTarget(Button(FloeCADStrings.label("cad.workbench.drawing.annotate",
                                                                           "Text")) {
                                    activeSheet = .annotation(CADDrawingAnnotationPageRequest(page: page))
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                                panelHitTarget(Button(role: .destructive) {
                                    removePage(page)
                                } label: {
                                    Text(FloeCADStrings.text("cad.workbench.drawing.delete", "Delete"))
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("CADDrawingPage-\(page["id"] as? String ?? "\(index)")")
                    }
                }
            }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label(FloeCADStrings.label("cad.workbench.drawing.share", "Share export"),
                          systemImage: "square.and.arrow.up")
                }
                .font(.callout)
            }
        }
        .task { refresh() }
        .sheet(item: $activeSheet) { route in
            switch route {
            case .bom(let request):
                CADDrawingBOMSheet(document: document, page: request.page,
                                   onChanged: { reply in
                                       outcome = reply
                                       if reply["mutated"] as? Bool == true { refresh() }
                                   })
            case .balloon(let request):
                CADDrawingBalloonSheet(document: document, page: request.page,
                                       onChanged: { reply in
                                           outcome = reply
                                           if reply["mutated"] as? Bool == true { refresh() }
                                       })
            case .dimension(let request):
                CADDrawingDimensionSheet(document: document, page: request.page,
                                         onChanged: { reply in
                                             outcome = reply
                                             if reply["mutated"] as? Bool == true { refresh() }
                                         })
            case .annotation(let request):
                CADDrawingAnnotationSheet(document: document, page: request.page,
                                          onChanged: { reply in
                                              outcome = reply
                                              if reply["mutated"] as? Bool == true { refresh() }
                                          })
            case .edit(let request):
                CADDrawingPageEditorSheet(
                    document: document,
                    page: request.page,
                    preferredSourceBodyID: selectedBodyID,
                    busy: $busy,
                    onSaved: { reply in
                        outcome = reply
                        if reply["ok"] as? Bool == true {
                            if let page = reply["page"] as? [String: Any],
                               let id = page["id"] as? String {
                                showGeometry(pages.first { $0["id"] as? String == id } ?? page)
                            }
                            refresh()
                        }
                    })
            }
        }
    }

    private static func scaleText(_ scale: Double) -> String {
        if scale >= 1 { return String(format: "%g", 1 / scale) }
        return String(format: "%g", 1 / scale)
    }

    private func refresh() {
        let service = CADDrawingService(document: document)
        let reply = service.handle(action: "pages", args: [:])
        pages = reply["pages"] as? [[String: Any]] ?? []
        outcome = reply
    }

    private func standardSheet() {
        guard let bodyID = selectedBodyID else { return }
        busy = true
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            let reply = service.handle(action: "standardSheet",
                                       args: ["bodyID": bodyID.uuidString, "title": document.name])
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            outcome = reply
            refresh()
            busy = false
        }
    }

    private func assemblySheet() {
        busy = true
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            let reply = service.handle(action: "assemblySheet",
                                       args: ["title": document.name])
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            outcome = reply
            refresh()
            busy = false
        }
    }

    private func showGeometry(_ page: [String: Any]) {
        guard let id = page["id"] as? String, let uuid = UUID(uuidString: id) else { return }
        let service = CADDrawingService(document: document)
        let reply = service.pageGeometry(pageID: uuid)
        outcome = reply
        if reply["ok"] as? Bool == true {
            var loaded = CADDrawingPreview(reply: reply)
            loaded.stale = page["stale"] as? Bool ?? loaded.stale
            preview = loaded
        }
    }

    private func removePage(_ page: [String: Any]) {
        guard let id = page["id"] as? String, let uuid = UUID(uuidString: id) else { return }
        busy = true
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            let reply = service.handle(action: "removePage", args: ["pageID": uuid.uuidString])
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            outcome = reply
            if preview?.pageID == uuid { preview = nil }
            refresh()
            busy = false
        }
    }

    private func export(_ page: [String: Any], format: String) {
        guard let id = page["id"] as? String, let uuid = UUID(uuidString: id) else { return }
        busy = true
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            do {
                let data = try service.exportData(pageID: uuid, format: format)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(document.name)-\(page["kind"] as? String ?? "page").\(format)")
                try data.write(to: url, options: [.atomic])
                exportURL = url
                outcome = ["ok": true,
                           "message": FloeCADStrings.format("cad.workbench.drawing.exported",
                                                            "%@ export ready (%lld bytes).",
                                                            format.uppercased(), data.count)]
            } catch {
                outcome = ["ok": false, "message": error.localizedDescription]
            }
            busy = false
        }
    }
}

// MARK: - Vector preview

struct CADDrawingVectorPreview: View {
    let preview: CADDrawingPreview
    var onClose: () -> Void

    private var bounds: CGRect {
        var minPoint = CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude)
        var maxPoint = CGPoint(x: -CGFloat.greatestFiniteMagnitude, y: -CGFloat.greatestFiniteMagnitude)
        func include(_ point: CGPoint) {
            minPoint.x = min(minPoint.x, point.x)
            minPoint.y = min(minPoint.y, point.y)
            maxPoint.x = max(maxPoint.x, point.x)
            maxPoint.y = max(maxPoint.y, point.y)
        }
        for entity in preview.entities + preview.centerlines {
            switch entity.shape {
            case let .line(a, b): include(a); include(b)
            case let .circle(center, radius):
                include(CGPoint(x: center.x - radius, y: center.y - radius))
                include(CGPoint(x: center.x + radius, y: center.y + radius))
            case let .arc(center, radius, _, _):
                include(CGPoint(x: center.x - radius, y: center.y - radius))
                include(CGPoint(x: center.x + radius, y: center.y + radius))
            case let .polyline(points, _):
                points.forEach(include)
            }
        }
        if minPoint.x > maxPoint.x { return CGRect(x: 0, y: 0, width: 100, height: 100) }
        let width = max(maxPoint.x - minPoint.x, 1)
        let height = max(maxPoint.y - minPoint.y, 1)
        return CGRect(x: minPoint.x, y: minPoint.y, width: width, height: height)
    }

    private func color(for layer: String) -> Color {
        switch layer {
        case "outline": return .primary
        case "edges": return .secondary
        case "section": return .orange
        case "dimension": return .teal
        case "centerline": return .gray
        case "annotation": return .indigo
        case "balloon": return .purple
        case "bom": return .brown
        case "title": return .brown
        default: return .primary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(FloeCADStrings.format("cad.workbench.drawing.previewTitle", "Vector preview · %@",
                                           "\(preview.entities.count)"))
                    .font(.subheadline.weight(.semibold))
                if preview.stale {
                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.stale", "stale"),
                               tint: .orange)
                }
                Spacer()
                Button(FloeCADStrings.text("cad.ui.common.close", "Close")) { onClose() }
                    .accessibilityIdentifier("CADDrawingPreviewClose")
            }
            Canvas { context, size in
                let source = bounds
                let inset: CGFloat = 12
                let scale = min((size.width - inset * 2) / source.width,
                                (size.height - inset * 2) / source.height)
                let offsetX = (size.width - source.width * scale) / 2 - source.minX * scale
                let offsetY = (size.height - source.height * scale) / 2 + source.maxY * scale

                func transform(_ point: CGPoint) -> CGPoint {
                    // Drawing y is up; SwiftUI y is down.
                    CGPoint(x: point.x * scale + offsetX, y: -point.y * scale + offsetY)
                }

                var paths: [String: Path] = [:]
                for entity in preview.centerlines + preview.entities {
                    var path = Path()
                    switch entity.shape {
                    case let .line(a, b):
                        path.move(to: transform(a))
                        path.addLine(to: transform(b))
                    case let .circle(center, radius):
                        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2)
                        let mapped = CGRect(x: transform(CGPoint(x: rect.minX, y: rect.minY)).x,
                                            y: transform(CGPoint(x: rect.minX, y: rect.maxY)).y,
                                            width: rect.width * scale,
                                            height: rect.height * scale)
                        path.addEllipse(in: mapped)
                    case let .arc(center, radius, startAngle, endAngle):
                        path.addArc(center: transform(center),
                                    radius: radius * scale,
                                    startAngle: .radians(-endAngle),
                                    endAngle: .radians(-startAngle),
                                    clockwise: false)
                    case let .polyline(points, closed):
                        guard let first = points.first else { break }
                        path.move(to: transform(first))
                        for point in points.dropFirst() { path.addLine(to: transform(point)) }
                        if closed { path.closeSubpath() }
                    }
                    if var existing = paths[entity.layer] {
                        existing.addPath(path)
                        paths[entity.layer] = existing
                    } else {
                        paths[entity.layer] = path
                    }
                }
                for (layer, path) in paths {
                    let dashed = layer == "centerline"
                    context.stroke(path, with: .color(color(for: layer)),
                                   style: StrokeStyle(lineWidth: layer == "outline" ? 1.6 : 1.0,
                                                      dash: dashed ? [4, 3] : []))
                }
                for text in preview.texts {
                    let position = transform(text.position)
                    let fontSize = max(6, CGFloat(text.height) * scale * 1.15)
                    context.draw(Text(text.text)
                                    .font(.system(size: fontSize))
                                    .foregroundStyle(color(for: text.layer)),
                                 at: position)
                }
            }
            .frame(minHeight: 220, maxHeight: 320)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            .accessibilityIdentifier("CADDrawingPreview")

            HStack(spacing: 8) {
                ForEach(preview.counts.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    PanelBadge(text: "\(localizedDrawingCount(key)) \(value)")
                }
            }
            if !preview.bomRows.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(FloeCADStrings.text("cad.workbench.drawing.bom", "BOM"))
                        .font(.caption.weight(.semibold))
                    ForEach(Array(preview.bomRows.prefix(8).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            Text("\(row["itemNumber"] as? Int ?? 0)")
                                .font(.caption2.monospacedDigit())
                                .frame(width: 22, alignment: .leading)
                            Text(row["name"] as? String ?? "—")
                                .font(.caption2)
                            Spacer(minLength: 4)
                            Text("×\(row["quantity"] as? Int ?? 0)")
                                .font(.caption2.monospacedDigit())
                            if row["stale"] as? Bool == true {
                                Text(FloeCADStrings.text("cad.workbench.badge.stale", "stale"))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            if !preview.notes.isEmpty {
                Text(preview.notes.prefix(6).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Page editor

struct CADDrawingPageEditorRequest: Identifiable {
    let id = UUID()
    let page: [String: Any]?
}

struct CADDrawingAnnotationPageRequest: Identifiable {
    let id = UUID()
    let page: [String: Any]
}

enum CADDrawingSheetRoute: Identifiable {
    case edit(CADDrawingPageEditorRequest)
    case bom(CADDrawingAnnotationPageRequest)
    case balloon(CADDrawingAnnotationPageRequest)
    case dimension(CADDrawingAnnotationPageRequest)
    case annotation(CADDrawingAnnotationPageRequest)

    var id: String {
        switch self {
        case .edit(let request): return "edit-\(request.id.uuidString)"
        case .bom(let request): return "bom-\(request.id.uuidString)"
        case .balloon(let request): return "balloon-\(request.id.uuidString)"
        case .dimension(let request): return "dimension-\(request.id.uuidString)"
        case .annotation(let request): return "annotation-\(request.id.uuidString)"
        }
    }
}

private struct CADDrawingPageEditorSheet: View {
    let document: FloeCADDocument
    let page: [String: Any]?
    let preferredSourceBodyID: UUID?
    @Binding var busy: Bool
    let onSaved: ([String: Any]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kind: String
    @State private var sourceIDs: Set<UUID>
    @State private var scale: String
    @State private var paper: String
    @State private var customWidth: String
    @State private var customHeight: String
    @State private var title: String
    @State private var partNumbers: String
    @State private var normalX: String
    @State private var normalY: String
    @State private var normalZ: String
    @State private var upX: String
    @State private var upY: String
    @State private var upZ: String
    @State private var sectionOriginX: String
    @State private var sectionOriginY: String
    @State private var sectionOriginZ: String
    @State private var sectionNormalX: String
    @State private var sectionNormalY: String
    @State private var sectionNormalZ: String
    @State private var detailOriginX: String
    @State private var detailOriginY: String
    @State private var detailOriginZ: String
    @State private var detailWidth: String
    @State private var detailHeight: String
    @State private var showCenterlines: Bool
    @State private var showDimensions: Bool
    @State private var assemblyMode: Bool
    @State private var explodedViewID: String?
    @State private var explodedViewName: String?
    @State private var showBOM: Bool
    @State private var explodedViews: [[String: Any]] = []
    @State private var errorText: String?

    init(document: FloeCADDocument, page: [String: Any]?, preferredSourceBodyID: UUID?,
         busy: Binding<Bool>, onSaved: @escaping ([String: Any]) -> Void) {
        self.document = document
        self.page = page
        self.preferredSourceBodyID = preferredSourceBodyID
        self._busy = busy
        self.onSaved = onSaved
        func number(_ value: Any?) -> String {
            guard let value = value as? Double else { return "0" }
            return CADPanelTransform.format(value)
        }
        func vector(_ value: Any?, fallback: [Double]) -> [Double] {
            (value as? [Double]) ?? fallback
        }
        _name = State(initialValue: CADDrawingPageEditorDefaults.name(page: page))
        _kind = State(initialValue: page?["kind"] as? String ?? "front")
        if let list = page?["sourceBodyIDs"] as? [String] {
            _sourceIDs = State(initialValue: Set(list.compactMap(UUID.init(uuidString:))))
        } else if let preferredSourceBodyID {
            _sourceIDs = State(initialValue: [preferredSourceBodyID])
        } else {
            _sourceIDs = State(initialValue: [])
        }
        _scale = State(initialValue: CADDrawingPageEditorDefaults.scale(page: page))
        _paper = State(initialValue: page?["paper"] as? String ?? "a3")
        _customWidth = State(initialValue: (page?["customWidthMM"] as? Double).map { number($0) } ?? "")
        _customHeight = State(initialValue: (page?["customHeightMM"] as? Double).map { number($0) } ?? "")
        _title = State(initialValue: page?["title"] as? String ?? "")
        _partNumbers = State(initialValue: (page?["partNumbers"] as? [String] ?? []).joined(separator: ", "))
        let normal = vector(page?["viewNormal"], fallback: [0, -1, 0])
        let up = vector(page?["viewUp"], fallback: [0, 1, 0])
        _normalX = State(initialValue: number(normal[0]))
        _normalY = State(initialValue: number(normal[1]))
        _normalZ = State(initialValue: number(normal[2]))
        _upX = State(initialValue: number(up[0]))
        _upY = State(initialValue: number(up[1]))
        _upZ = State(initialValue: number(up[2]))
        let sectionOrigin = vector(page?["sectionOrigin"], fallback: [0, 0, 0])
        let sectionNormal = vector(page?["sectionNormal"], fallback: [0, 0, 1])
        _sectionOriginX = State(initialValue: number(sectionOrigin[0]))
        _sectionOriginY = State(initialValue: number(sectionOrigin[1]))
        _sectionOriginZ = State(initialValue: number(sectionOrigin[2]))
        _sectionNormalX = State(initialValue: number(sectionNormal[0]))
        _sectionNormalY = State(initialValue: number(sectionNormal[1]))
        _sectionNormalZ = State(initialValue: number(sectionNormal[2]))
        let detailOrigin = vector(page?["detailOrigin"], fallback: [0, 0, 0])
        let detailSize = vector(page?["detailSizeMM"], fallback: [50, 50])
        _detailOriginX = State(initialValue: number(detailOrigin[0]))
        _detailOriginY = State(initialValue: number(detailOrigin[1]))
        _detailOriginZ = State(initialValue: number(detailOrigin[2]))
        _detailWidth = State(initialValue: number(detailSize.count > 0 ? detailSize[0] : 50))
        _detailHeight = State(initialValue: number(detailSize.count > 1 ? detailSize[1] : 50))
        _showCenterlines = State(initialValue: page?["showCenterlines"] as? Bool ?? false)
        _showDimensions = State(initialValue: page?["showDimensions"] as? Bool ?? false)
        _assemblyMode = State(initialValue: page?["assemblyMode"] as? Bool ?? false)
        _explodedViewID = State(initialValue: page?["explodedViewID"] as? String)
        _explodedViewName = State(initialValue: page?["explodedViewName"] as? String)
        _showBOM = State(initialValue: page?["showBOM"] as? Bool ?? false)
    }

    private var bodies: [CADPanelBodyOption] { document.panelBodyOptions }

    private var canSave: Bool {
        guard !busy,
              assemblyMode || !sourceIDs.isEmpty,
              sourceIDs.count <= CADDrawingService.maxSourceBodies,
              let scaleValue = Double(scale), scaleValue > 0, scaleValue <= 1000 else { return false }
        if paper == "custom" {
            guard let w = Double(customWidth), let h = Double(customHeight), w > 0, h > 0 else { return false }
        }
        if kind == "section" { return sectionPlaneComplete }
        if kind == "detail" {
            guard let w = Double(detailWidth), let h = Double(detailHeight), w > 0, h > 0 else { return false }
        }
        return true
    }

    private var sectionPlaneComplete: Bool {
        [sectionOriginX, sectionOriginY, sectionOriginZ,
         sectionNormalX, sectionNormalY, sectionNormalZ].allSatisfy { Double($0) != nil }
            && (Double(sectionNormalX) != 0 || Double(sectionNormalY) != 0 || Double(sectionNormalZ) != 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(FloeCADStrings.text("cad.workbench.drawing.page", "Page")) {
                    TextField(FloeCADStrings.text("cad.workbench.drawing.name", "Name"), text: $name)
                        .accessibilityIdentifier("CADDrawingPageName")
                    Picker(FloeCADStrings.text("cad.workbench.drawing.kind", "View kind"), selection: $kind) {
                        Text(localizedDrawingKind("front")).tag("front")
                        Text(localizedDrawingKind("top")).tag("top")
                        Text(localizedDrawingKind("side")).tag("side")
                        Text(localizedDrawingKind("iso")).tag("iso")
                        Text(localizedDrawingKind("section")).tag("section")
                        Text(localizedDrawingKind("detail")).tag("detail")
                        Text(localizedDrawingKind("exploded")).tag("exploded")
                    }
                    .accessibilityIdentifier("CADDrawingPageKind")
                    CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.drawing.scale", "Scale (drawing mm per model mm)"),
                                        text: $scale, identifier: "CADDrawingPageScale")
                    Picker(FloeCADStrings.text("cad.workbench.drawing.paper", "Paper"), selection: $paper) {
                        ForEach(["a4", "a3", "a2", "a1", "a0", "letter", "tabloid", "custom"], id: \.self) {
                            Text($0.uppercased()).tag($0)
                        }
                    }
                    if paper == "custom" {
                        HStack(spacing: 10) {
                            CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.drawing.width", "Width (mm)"),
                                                text: $customWidth)
                            CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.drawing.height", "Height (mm)"),
                                                text: $customHeight)
                        }
                    }
                }

                Section(FloeCADStrings.text("cad.workbench.drawing.sources", "Source bodies (≤ 12)")) {
                    ForEach(bodies) { body in
                        Button {
                            if sourceIDs.contains(body.id) { sourceIDs.remove(body.id) }
                            else if sourceIDs.count < CADDrawingService.maxSourceBodies { sourceIDs.insert(body.id) }
                        } label: {
                            HStack {
                                Image(systemName: sourceIDs.contains(body.id)
                                      ? "checkmark.square.fill" : "square")
                                Text(body.name).foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                        .accessibilityIdentifier("CADDrawingSource-\(body.id.uuidString)")
                    }
                }

                Section(FloeCADStrings.text("cad.workbench.drawing.assembly", "Assembly")) {
                    Toggle(FloeCADStrings.text("cad.workbench.drawing.projectInstances",
                                               "Project assembly instances"),
                           isOn: $assemblyMode)
                        .accessibilityIdentifier("CADDrawingPageAssemblyMode")
                        .onChange(of: assemblyMode) { _, value in
                            if !value { explodedViewID = nil }
                        }
                    Picker(FloeCADStrings.text("cad.workbench.drawing.explodedView", "Exploded view"),
                           selection: $explodedViewID) {
                        Text(FloeCADStrings.text("cad.workbench.drawing.noExplodedView", "None"))
                            .tag(String?.none)
                        ForEach(Array(explodedViews.enumerated()), id: \.offset) { _, view in
                            if let id = view["id"] as? String {
                                Text(view["name"] as? String ?? id).tag(String?.some(id))
                            }
                        }
                    }
                    .disabled(explodedViews.isEmpty)
                    .accessibilityIdentifier("CADDrawingPageExplodedView")
                    if let explodedViewName, !explodedViewName.isEmpty,
                       explodedViewID != nil {
                        Text(FloeCADStrings.format("cad.workbench.drawing.explodedActive",
                                                   "Using %@ offsets (base geometry unchanged).",
                                                   explodedViewName))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle(FloeCADStrings.text("cad.workbench.drawing.showBOM", "BOM table"),
                           isOn: $showBOM)
                        .accessibilityIdentifier("CADDrawingPageShowBOM")
                }

                Section(FloeCADStrings.text("cad.workbench.drawing.orientation", "View orientation")) {
                    HStack(spacing: 10) {
                        CADPanelNumberField(title: "Nx", text: $normalX)
                        CADPanelNumberField(title: "Ny", text: $normalY)
                        CADPanelNumberField(title: "Nz", text: $normalZ)
                    }
                    HStack(spacing: 10) {
                        CADPanelNumberField(title: "Ux", text: $upX)
                        CADPanelNumberField(title: "Uy", text: $upY)
                        CADPanelNumberField(title: "Uz", text: $upZ)
                    }
                }

                if kind == "section" {
                    Section(FloeCADStrings.text("cad.workbench.drawing.sectionPlane", "Section plane")) {
                        HStack(spacing: 10) {
                            CADPanelNumberField(title: "Ox", text: $sectionOriginX)
                            CADPanelNumberField(title: "Oy", text: $sectionOriginY)
                            CADPanelNumberField(title: "Oz", text: $sectionOriginZ)
                        }
                        HStack(spacing: 10) {
                            CADPanelNumberField(title: "Nx", text: $sectionNormalX)
                            CADPanelNumberField(title: "Ny", text: $sectionNormalY)
                            CADPanelNumberField(title: "Nz", text: $sectionNormalZ)
                        }
                    }
                }

                if kind == "detail" {
                    Section(FloeCADStrings.text("cad.workbench.drawing.detailWindow", "Detail window")) {
                        HStack(spacing: 10) {
                            CADPanelNumberField(title: "Cx", text: $detailOriginX)
                            CADPanelNumberField(title: "Cy", text: $detailOriginY)
                            CADPanelNumberField(title: "Cz", text: $detailOriginZ)
                        }
                        HStack(spacing: 10) {
                            CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.drawing.width", "Width (mm)"),
                                                text: $detailWidth)
                            CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.drawing.height", "Height (mm)"),
                                                text: $detailHeight)
                        }
                    }
                }

                Section(FloeCADStrings.text("cad.workbench.drawing.titleBlock", "Title block")) {
                    TextField(FloeCADStrings.text("cad.workbench.drawing.title", "Title"), text: $title)
                        .accessibilityIdentifier("CADDrawingPageTitle")
                    TextField(FloeCADStrings.text("cad.workbench.drawing.partNumbers", "Part numbers (comma separated)"),
                              text: $partNumbers)
                        .accessibilityIdentifier("CADDrawingPagePartNumbers")
                    Toggle(FloeCADStrings.text("cad.workbench.drawing.centerlines", "Centerlines"),
                           isOn: $showCenterlines)
                    Toggle(FloeCADStrings.text("cad.workbench.drawing.dimensions", "Dimensions & leaders"),
                           isOn: $showDimensions)
                }

                if let errorText {
                    Section {
                        Text(errorText).font(.callout).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(page == nil
                             ? FloeCADStrings.text("cad.workbench.drawing.add", "Add page")
                             : FloeCADStrings.text("cad.workbench.drawing.edit", "Edit page"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.save", "Save")) { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("CADDrawingPageSave")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { loadExplodedViews() }
    }

    private func loadExplodedViews() {
        let service = CADAssemblyService(document: document)
        let reply = service.handle(action: "explodedViews", args: [:])
        explodedViews = reply["views"] as? [[String: Any]] ?? []
        if let id = explodedViewID,
           let view = explodedViews.first(where: { $0["id"] as? String == id }) {
            explodedViewName = view["name"] as? String
        }
    }

    private func save() {
        guard canSave, let scaleValue = Double(scale) else { return }
        var args: [String: Any] = [
            "kind": kind,
            "name": name,
            "bodyIDs": sourceIDs.map(\.uuidString),
            "scale": scaleValue,
            "paper": paper,
            "title": title,
            "partNumbers": partNumbers.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            "showCenterlines": showCenterlines,
            "showDimensions": showDimensions,
            "assemblyMode": assemblyMode,
            "showBOM": showBOM,
        ]
        if let explodedViewID {
            args["explodedViewID"] = explodedViewID
        } else {
            args["explodedViewID"] = NSNull()
        }
        if let nx = Double(normalX), let ny = Double(normalY), let nz = Double(normalZ),
           nx != 0 || ny != 0 || nz != 0 {
            args["viewNormal"] = [nx, ny, nz]
        }
        if let ux = Double(upX), let uy = Double(upY), let uz = Double(upZ) {
            args["viewUp"] = [ux, uy, uz]
        }
        if paper == "custom" {
            if let w = Double(customWidth) { args["customWidthMM"] = w }
            if let h = Double(customHeight) { args["customHeightMM"] = h }
        }
        if kind == "section" {
            args["sectionOrigin"] = [Double(sectionOriginX) ?? 0, Double(sectionOriginY) ?? 0,
                                     Double(sectionOriginZ) ?? 0]
            args["sectionNormal"] = [Double(sectionNormalX) ?? 0, Double(sectionNormalY) ?? 0,
                                     Double(sectionNormalZ) ?? 1]
        }
        if kind == "detail" {
            args["detailOrigin"] = [Double(detailOriginX) ?? 0, Double(detailOriginY) ?? 0,
                                    Double(detailOriginZ) ?? 0]
            args["detailSizeMM"] = [Double(detailWidth) ?? 50, Double(detailHeight) ?? 50]
        }
        let pageID = page?["id"] as? String
        busy = true
        errorText = nil
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            let reply: [String: Any]
            if let pageID {
                var update = args
                update["pageID"] = pageID
                reply = service.handle(action: "updatePage", args: update)
            } else {
                reply = service.handle(action: "addPage", args: args)
            }
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            busy = false
            onSaved(reply)
            if reply["ok"] as? Bool == true {
                dismiss()
            } else {
                errorText = reply["message"] as? String
            }
        }
    }
}
// MARK: - BOM sheet

private struct CADDrawingBOMSheet: View {
    let document: FloeCADDocument
    let page: [String: Any]
    let onChanged: ([String: Any]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [[String: Any]] = []
    @State private var issues: [String] = []
    @State private var showBOM = true
    @State private var busy = false
    @State private var errorText: String?

    private var pageID: String? { page["id"] as? String }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(FloeCADStrings.text("cad.workbench.drawing.showBOM", "BOM table"),
                           isOn: $showBOM)
                        .onChange(of: showBOM) { _, value in
                            setVisible(value)
                        }
                        .accessibilityIdentifier("CADDrawingBOMVisible")
                    Button {
                        derive()
                    } label: {
                        Label(FloeCADStrings.text("cad.workbench.drawing.deriveBOM",
                                                  "Refresh from assembly"),
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("CADDrawingBOMDerive")
                } header: {
                    Text(FloeCADStrings.text("cad.workbench.drawing.bom", "BOM"))
                }

                if entries.isEmpty {
                    Text(FloeCADStrings.text("cad.workbench.drawing.bomEmpty",
                                             "No BOM items. Refresh from a live assembly to derive names and quantities."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 8) {
                                Text("\(row["itemNumber"] as? Int ?? 0)")
                                    .font(.callout.monospacedDigit())
                                    .frame(width: 24, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row["name"] as? String ?? "—")
                                        .font(.callout)
                                    if let part = row["partNumber"] as? String, !part.isEmpty {
                                        Text(part).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 4)
                                Text("×\(row["quantity"] as? Int ?? 0)")
                                    .font(.callout.monospacedDigit())
                                if row["stale"] as? Bool == true {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.stale", "stale"),
                                               tint: .orange)
                                }
                            }
                        }
                    }
                }

                if !issues.isEmpty {
                    Section {
                        ForEach(issues, id: \.self) { issue in
                            Text(issue).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.workbench.drawing.bom", "BOM"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.close", "Close")) { dismiss() }
                }
            }
            .task { load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() {
        guard let pageID = pageID else { return }
        let reply = CADDrawingService(document: document).pageGeometry(pageID: UUID(uuidString: pageID) ?? UUID())
        let bom = reply["bom"] as? [String: Any] ?? [:]
        entries = bom["entries"] as? [[String: Any]] ?? []
        issues = bom["issues"] as? [String] ?? []
        showBOM = page["showBOM"] as? Bool ?? false
        if reply["ok"] as? Bool != true {
            errorText = reply["message"] as? String
        }
    }

    private func derive() {
        guard let pageID else { return }
        busy = true
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            let reply = service.handle(action: "setBOM",
                                       args: ["pageID": pageID, "showBOM": true])
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            busy = false
            onChanged(reply)
            if reply["ok"] as? Bool == true {
                entries = reply["entries"] as? [[String: Any]] ?? []
                issues = reply["issues"] as? [String] ?? []
                showBOM = true
            } else {
                errorText = reply["message"] as? String
            }
        }
    }

    private func setVisible(_ value: Bool) {
        guard let pageID else { return }
        busy = true
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            let reply = service.handle(action: "updatePage",
                                       args: ["pageID": pageID, "showBOM": value])
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            busy = false
            onChanged(reply)
            if reply["ok"] as? Bool != true {
                errorText = reply["message"] as? String
            }
        }
    }
}

// MARK: - Balloon sheet

private struct CADDrawingBalloonSheet: View {
    let document: FloeCADDocument
    let page: [String: Any]
    let onChanged: ([String: Any]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var instances: [[String: Any]] = []
    @State private var balloons: [[String: Any]] = []
    @State private var bomRows: [[String: Any]] = []
    @State private var itemNumber = "1"
    @State private var instanceID: String?
    @State private var anchorX = ""
    @State private var anchorY = ""
    @State private var busy = false
    @State private var errorText: String?

    private var pageID: String? { page["id"] as? String }

    var body: some View {
        NavigationStack {
            Form {
                Section(FloeCADStrings.text("cad.workbench.drawing.newBalloon", "New balloon")) {
                    CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.drawing.itemNumber", "Item"),
                                        text: $itemNumber)
                    if !bomRows.isEmpty {
                        Text(FloeCADStrings.format("cad.workbench.drawing.bomItems",
                                                   "%@ BOM items available; the balloon links to the matching item.",
                                                   bomRows.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker(FloeCADStrings.text("cad.workbench.drawing.balloonInstance", "Instance"),
                           selection: $instanceID) {
                        Text(FloeCADStrings.text("cad.workbench.drawing.pickInstance", "Select…"))
                            .tag(String?.none)
                        ForEach(Array(instances.enumerated()), id: \.offset) { _, row in
                            if let id = row["instanceID"] as? String {
                                Text(row["name"] as? String ?? id).tag(String?.some(id))
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.drawing.anchorX",
                                                                       "X (auto)"), text: $anchorX)
                        CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.drawing.anchorY",
                                                                       "Y (auto)"), text: $anchorY)
                    }
                    Button(FloeCADStrings.text("cad.workbench.drawing.addBalloon", "Add balloon")) {
                        add()
                    }
                    .disabled(busy || instanceID == nil || Int(itemNumber) == nil)
                    .accessibilityIdentifier("CADDrawingBalloonAdd")
                }

                if !balloons.isEmpty {
                    Section(FloeCADStrings.text("cad.workbench.drawing.balloons", "Balloons")) {
                        ForEach(Array(balloons.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 8) {
                                Text(row["text"] as? String ?? "—")
                                    .font(.callout.monospacedDigit())
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("item \(row["itemNumber"] as? Int ?? 0)")
                                        .font(.caption)
                                    if let reasons = row["reasons"] as? [String], !reasons.isEmpty {
                                        Text(reasons.joined(separator: " · "))
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer(minLength: 4)
                                if row["invalid"] as? Bool == true {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.invalid",
                                                                         "invalid"), tint: .red)
                                } else if row["stale"] as? Bool == true {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.stale",
                                                                         "stale"), tint: .orange)
                                }
                                Button(role: .destructive) {
                                    remove(row["id"] as? String ?? "")
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.workbench.drawing.balloon", "Balloon"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.close", "Close")) { dismiss() }
                }
            }
            .task { load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() {
        guard let pageID, let uuid = UUID(uuidString: pageID) else { return }
        let reply = CADDrawingService(document: document).pageGeometry(pageID: uuid)
        instances = reply["instances"] as? [[String: Any]] ?? []
        balloons = reply["balloons"] as? [[String: Any]] ?? []
        bomRows = ((reply["bom"] as? [String: Any])?["entries"] as? [[String: Any]]) ?? []
        if instanceID == nil {
            instanceID = instances.first?["instanceID"] as? String
        }
        if let first = bomRows.first?["itemNumber"] as? Int {
            itemNumber = "\(first)"
        }
        if reply["ok"] as? Bool != true {
            errorText = reply["message"] as? String
        }
    }

    private func add() {
        guard let pageID, let instanceID, let number = Int(itemNumber) else { return }
        var args: [String: Any] = [
            "pageID": pageID,
            "itemNumber": number,
            "instanceID": instanceID,
        ]
        if let x = Double(anchorX), let y = Double(anchorY) {
            args["anchor"] = [x, y]
        }
        busy = true
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            let reply = service.handle(action: "addBalloon", args: args)
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            busy = false
            onChanged(reply)
            if reply["ok"] as? Bool == true {
                balloons = reply["balloons"] as? [[String: Any]] ?? balloons
                errorText = nil
            } else {
                errorText = reply["message"] as? String
            }
        }
    }

    private func remove(_ balloonID: String) {
        guard let pageID, let uuid = UUID(uuidString: balloonID) else { return }
        busy = true
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            let reply = service.handle(action: "removeBalloon",
                                       args: ["pageID": pageID, "balloonID": uuid.uuidString])
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            busy = false
            onChanged(reply)
            if reply["ok"] as? Bool == true { load() } else {
                errorText = reply["message"] as? String
            }
        }
    }
}

// MARK: - Manual dimension sheet

private struct CADDrawingDimensionSheet: View {
    let document: FloeCADDocument
    let page: [String: Any]
    let onChanged: ([String: Any]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind = "length"
    @State private var instanceID: String?
    @State private var instances: [[String: Any]] = []
    @State private var manual: [[String: Any]] = []
    @State private var points: [String] = ["0", "0", "0", "0", "0", "0"]
    @State private var text = ""
    @State private var textX = ""
    @State private var textY = ""
    @State private var busy = false
    @State private var errorText: String?

    private var pageID: String? { page["id"] as? String }
    private var requiredPoints: Int { kind == "angle" ? 3 : 2 }

    var body: some View {
        NavigationStack {
            Form {
                Section(FloeCADStrings.text("cad.workbench.drawing.newDimension", "New dimension")) {
                    Picker(FloeCADStrings.text("cad.workbench.drawing.dimensionKind", "Kind"),
                           selection: $kind) {
                        ForEach(CADDrawingDimensionKind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind.rawValue)
                        }
                    }
                    .onChange(of: kind) { _, _ in prefill() }
                    Picker(FloeCADStrings.text("cad.workbench.drawing.boundInstance", "Instance"),
                           selection: $instanceID) {
                        Text(FloeCADStrings.text("cad.workbench.drawing.pickInstance", "Select…"))
                            .tag(String?.none)
                        ForEach(Array(instances.enumerated()), id: \.offset) { _, row in
                            if let id = row["instanceID"] as? String {
                                Text(row["name"] as? String ?? id).tag(String?.some(id))
                            }
                        }
                    }
                    .onChange(of: instanceID) { _, _ in prefill() }
                    ForEach(0..<requiredPoints, id: \.self) { index in
                        HStack(spacing: 10) {
                            CADPanelNumberField(title: "P\(index) x", text: Binding(
                                get: { points[index * 2] },
                                set: { points[index * 2] = $0 }))
                            CADPanelNumberField(title: "P\(index) y", text: Binding(
                                get: { points[index * 2 + 1] },
                                set: { points[index * 2 + 1] = $0 }))
                        }
                    }
                    TextField(FloeCADStrings.text("cad.workbench.drawing.dimensionText",
                                                  "Text override (optional)"), text: $text)
                    HStack(spacing: 10) {
                        CADPanelNumberField(title: "Text X", text: $textX)
                        CADPanelNumberField(title: "Text Y", text: $textY)
                    }
                    Button(FloeCADStrings.text("cad.workbench.drawing.addDimension", "Add dimension")) {
                        add()
                    }
                    .disabled(busy || instanceID == nil || !pointsComplete)
                    .accessibilityIdentifier("CADDrawingDimensionAdd")
                }

                if !manual.isEmpty {
                    Section(FloeCADStrings.text("cad.workbench.drawing.manualDimensions",
                                                "Manual dimensions")) {
                        ForEach(Array(manual.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 8) {
                                Text(row["text"] as? String ?? "—")
                                    .font(.callout)
                                Spacer(minLength: 4)
                                if row["invalid"] as? Bool == true {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.invalid",
                                                                         "invalid"), tint: .red)
                                } else if row["stale"] as? Bool == true {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.stale",
                                                                         "stale"), tint: .orange)
                                } else if row["unbound"] as? Bool == true {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.unbound",
                                                                         "unbound"), tint: .secondary)
                                }
                                Button(role: .destructive) {
                                    remove(row["id"] as? String ?? "")
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.workbench.drawing.dimension", "Dimension"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.close", "Close")) { dismiss() }
                }
            }
            .task { load() }
        }
        .presentationDetents([.medium, .large])
    }

    private var pointsComplete: Bool {
        (0..<requiredPoints).allSatisfy {
            Double(points[$0 * 2]) != nil && Double(points[$0 * 2 + 1]) != nil
        }
    }

    private func load() {
        guard let pageID, let uuid = UUID(uuidString: pageID) else { return }
        let reply = CADDrawingService(document: document).pageGeometry(pageID: uuid)
        instances = reply["instances"] as? [[String: Any]] ?? []
        manual = reply["manualDimensions"] as? [[String: Any]] ?? []
        if instanceID == nil { instanceID = instances.first?["instanceID"] as? String }
        prefill()
        if reply["ok"] as? Bool != true {
            errorText = reply["message"] as? String
        }
    }

    private func prefill() {
        guard let instanceID,
              let row = instances.first(where: { $0["instanceID"] as? String == instanceID }),
              let bounds = row["bounds"] as? [[Double]], bounds.count == 2,
              bounds[0].count == 2, bounds[1].count == 2 else { return }
        let minPoint = bounds[0]
        let maxPoint = bounds[1]
        points[0] = CADPanelTransform.format(minPoint[0])
        points[1] = CADPanelTransform.format(minPoint[1])
        if kind == "radius" || kind == "diameter" {
            points[0] = CADPanelTransform.format((minPoint[0] + maxPoint[0]) / 2)
            points[1] = CADPanelTransform.format((minPoint[1] + maxPoint[1]) / 2)
            points[2] = CADPanelTransform.format((minPoint[0] + maxPoint[0]) / 2)
            points[3] = CADPanelTransform.format(maxPoint[1])
        } else if kind == "angle" {
            points[2] = CADPanelTransform.format(maxPoint[0])
            points[3] = CADPanelTransform.format(minPoint[1])
            points[4] = CADPanelTransform.format(minPoint[0])
            points[5] = CADPanelTransform.format(maxPoint[1])
        } else {
            points[2] = CADPanelTransform.format(maxPoint[0])
            points[3] = CADPanelTransform.format(minPoint[1])
        }
    }

    private func add() {
        guard let pageID, let instanceID else { return }
        var drawingPoints: [[Double]] = []
        for index in 0..<requiredPoints {
            guard let x = Double(points[index * 2]), let y = Double(points[index * 2 + 1]) else {
                return
            }
            drawingPoints.append([x, y])
        }
        var args: [String: Any] = [
            "pageID": pageID,
            "kind": kind,
            "instanceID": instanceID,
            "drawingPoints": drawingPoints,
        ]
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { args["text"] = text }
        if let x = Double(textX), let y = Double(textY) { args["textPosition"] = [x, y] }
        busy = true
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            let reply = service.handle(action: "addDimension", args: args)
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            busy = false
            onChanged(reply)
            if reply["ok"] as? Bool == true {
                manual = reply["manualDimensions"] as? [[String: Any]] ?? manual
                errorText = nil
            } else {
                errorText = reply["message"] as? String
            }
        }
    }

    private func remove(_ dimensionID: String) {
        guard let pageID, let uuid = UUID(uuidString: dimensionID) else { return }
        busy = true
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            let reply = service.handle(action: "removeDimension",
                                       args: ["pageID": pageID, "dimensionID": uuid.uuidString])
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            busy = false
            onChanged(reply)
            if reply["ok"] as? Bool == true { load() } else {
                errorText = reply["message"] as? String
            }
        }
    }
}

// MARK: - Text annotation sheet

private struct CADDrawingAnnotationSheet: View {
    let document: FloeCADDocument
    let page: [String: Any]
    let onChanged: ([String: Any]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var annotations: [[String: Any]] = []
    @State private var instances: [[String: Any]] = []
    @State private var text = ""
    @State private var x = "20"
    @State private var y = "20"
    @State private var height = "3.5"
    @State private var instanceID: String?
    @State private var busy = false
    @State private var errorText: String?

    private var pageID: String? { page["id"] as? String }

    var body: some View {
        NavigationStack {
            Form {
                Section(FloeCADStrings.text("cad.workbench.drawing.newAnnotation", "New text")) {
                    TextField(FloeCADStrings.text("cad.workbench.drawing.annotationText", "Text"),
                              text: $text, axis: .vertical)
                        .lineLimit(1...4)
                    HStack(spacing: 10) {
                        CADPanelNumberField(title: "X", text: $x)
                        CADPanelNumberField(title: "Y", text: $y)
                        CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.drawing.textHeight",
                                                                       "Height"), text: $height)
                    }
                    Picker(FloeCADStrings.text("cad.workbench.drawing.bindText", "Bind to instance"),
                           selection: $instanceID) {
                        Text(FloeCADStrings.text("cad.workbench.drawing.noBinding", "Free text"))
                            .tag(String?.none)
                        ForEach(Array(instances.enumerated()), id: \.offset) { _, row in
                            if let id = row["instanceID"] as? String {
                                Text(row["name"] as? String ?? id).tag(String?.some(id))
                            }
                        }
                    }
                    Button(FloeCADStrings.text("cad.workbench.drawing.addAnnotation", "Add text")) {
                        add()
                    }
                    .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty
                              || Double(x) == nil || Double(y) == nil)
                    .accessibilityIdentifier("CADDrawingAnnotationAdd")
                }

                if !annotations.isEmpty {
                    Section(FloeCADStrings.text("cad.workbench.drawing.annotations", "Text annotations")) {
                        ForEach(Array(annotations.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 8) {
                                Text(row["text"] as? String ?? "—")
                                    .font(.callout)
                                Spacer(minLength: 4)
                                if row["stale"] as? Bool == true {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.stale", "stale"),
                                               tint: .orange)
                                } else if row["invalid"] as? Bool == true {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.invalid",
                                                                         "invalid"), tint: .red)
                                }
                                Button(role: .destructive) {
                                    remove(row["id"] as? String ?? "")
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.workbench.drawing.annotate", "Text"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.close", "Close")) { dismiss() }
                }
            }
            .task { load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() {
        guard let pageID, let uuid = UUID(uuidString: pageID) else { return }
        let reply = CADDrawingService(document: document).pageGeometry(pageID: uuid)
        instances = reply["instances"] as? [[String: Any]] ?? []
        annotations = reply["annotations"] as? [[String: Any]] ?? []
        if reply["ok"] as? Bool != true {
            errorText = reply["message"] as? String
        }
    }

    private func add() {
        guard let pageID, let xValue = Double(x), let yValue = Double(y) else { return }
        var args: [String: Any] = [
            "pageID": pageID,
            "text": text,
            "position": [xValue, yValue],
            "heightMM": Double(height) ?? 3.5,
        ]
        if let instanceID { args["instanceID"] = instanceID }
        busy = true
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            let reply = service.handle(action: "addAnnotation", args: args)
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            busy = false
            onChanged(reply)
            if reply["ok"] as? Bool == true {
                load()
                text = ""
            } else {
                errorText = reply["message"] as? String
            }
        }
    }

    private func remove(_ annotationID: String) {
        guard let pageID, let uuid = UUID(uuidString: annotationID) else { return }
        busy = true
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            let reply = service.handle(action: "removeAnnotation",
                                       args: ["pageID": pageID, "annotationID": uuid.uuidString])
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            busy = false
            onChanged(reply)
            if reply["ok"] as? Bool == true { load() } else {
                errorText = reply["message"] as? String
            }
        }
    }
}

#endif
