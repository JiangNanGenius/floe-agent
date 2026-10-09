//
//  CADDrawingPanelView.swift
//  FloeCADKit
//
//  Drawing panel for the Floe workbench: real projected-vector page preview
//  (SwiftUI Canvas over the same `pageGeometry` payload the exports use — never
//  a screenshot), full page/view editing (kind, sources, scale, paper,
//  orientation, section/detail windows, title, part numbers, centerlines,
//  dimensions) through `CADDrawingService`, and vector PDF/SVG/DXF export of
//  exactly the document shown.
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

struct CADDrawingPreview {
    var pageID: UUID
    var name: String
    var kind: String
    var scale: Double
    var entities: [CADDrawingPreviewEntity]
    var dimensions: [CADDrawingPreviewDimension]
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

// MARK: - Panel

struct CADDrawingPanelView: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    @State private var pages: [[String: Any]] = []
    @State private var outcome: [String: Any] = [:]
    @State private var exportURL: URL?
    @State private var busy = false
    @State private var preview: CADDrawingPreview?
    @State private var editingPage: CADDrawingPageEditorRequest?

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
                    editingPage = CADDrawingPageEditorRequest(page: nil)
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.drawing.sheet", "Standard sheet"),
                                  systemImage: "doc.on.doc", disabled: busy || selectedBodyID == nil) {
                    standardSheet()
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
                                Text("· \(page["kind"] as? String ?? "")")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                if let scale = page["scale"] as? Double, scale > 0 {
                                    Text("· 1:\(Self.scaleText(scale))")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
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
                                    editingPage = CADDrawingPageEditorRequest(page: page)
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
        .sheet(item: $editingPage) { request in
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
                for dimension in preview.dimensions {
                    let position = transform(dimension.position)
                    context.draw(Text(dimension.text).font(.caption2).foregroundStyle(.teal),
                                 at: position)
                }
            }
            .frame(minHeight: 220, maxHeight: 320)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            .accessibilityIdentifier("CADDrawingPreview")

            HStack(spacing: 8) {
                ForEach(preview.counts.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    PanelBadge(text: "\(key) \(value)")
                }
            }
            if !preview.notes.isEmpty {
                Text(preview.notes.joined(separator: " · "))
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
        _name = State(initialValue: page?["name"] as? String ?? "Sheet")
        _kind = State(initialValue: page?["kind"] as? String ?? "front")
        if let list = page?["sourceBodyIDs"] as? [String] {
            _sourceIDs = State(initialValue: Set(list.compactMap(UUID.init(uuidString:))))
        } else if let preferredSourceBodyID {
            _sourceIDs = State(initialValue: [preferredSourceBodyID])
        } else {
            _sourceIDs = State(initialValue: [])
        }
        _scale = State(initialValue: number(page?["scale"]))
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
    }

    private var bodies: [CADPanelBodyOption] { document.panelBodyOptions }

    private var canSave: Bool {
        guard !busy, !sourceIDs.isEmpty, sourceIDs.count <= CADDrawingService.maxSourceBodies,
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
                        Text("Front").tag("front")
                        Text("Top").tag("top")
                        Text("Side").tag("side")
                        Text("Isometric").tag("iso")
                        Text("Section").tag("section")
                        Text("Detail").tag("detail")
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
        ]
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
#endif
