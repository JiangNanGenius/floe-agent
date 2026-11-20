// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameCore
import FloeGameEditingCore

/// Native 2D tile map editor: layered grid painting (paint/erase/fill),
/// object placement/move/delete, selection, snapping and zoom.
public struct TileMapEditorView: View {
    public enum Tool: String, CaseIterable, Sendable {
        case paint, erase, fill, object, select
        var title: GameEditCopy {
            switch self {
            case .paint: return GameEditCopy("Paint", "绘制")
            case .erase: return GameEditCopy("Erase", "擦除")
            case .fill: return GameEditCopy("Fill", "填充")
            case .object: return GameEditCopy("Object", "对象")
            case .select: return GameEditCopy("Select", "选择")
            }
        }
    }

    @ObservedObject public var session: GameEditingSession
    public let path: GameRelativePath
    @Environment(\.gameEditLocale) private var locale

    @State private var map: EditableTileMap?
    @State private var activeLayerID: UUID?
    @State private var tool: Tool = .paint
    @State private var selectedGID: Int = 1
    @State private var zoom: Double = 2.0
    @State private var snap = true
    @State private var selection: EditableTileMap.Selection?
    @State private var selectedObjectID: UUID?
    @State private var strokeBase: EditableTileMap?
    @State private var lastCell: (x: Int, y: Int)?
    @State private var dragStart: CGPoint?
    @State private var showLayers = true
    @State private var issue: GameEditIssue?

    public init(session: GameEditingSession, path: GameRelativePath) {
        self.session = session; self.path = path
    }

    private var tilePixel: CGSize {
        guard let map else { return CGSize(width: 16, height: 16) }
        return CGSize(width: CGFloat(map.tileSize.width) * zoom, height: CGFloat(map.tileSize.height) * zoom)
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    canvas
                        .padding(24)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            if let selection, !selection.isEmpty {
                selectionBar(selection)
            }
            if let object = selectedObject {
                objectBar(object)
            }
        }
        .task(id: path) { await reload() }
        .onReceive(session.objectWillChange) {
            if strokeBase == nil { Task { await reload() } }
        }
        .inspector(isPresented: $showLayers) {
            layerPanel
                .inspectorColumnWidth(min: 220, ideal: 240, max: 320)
        }
        .alert(Text(GameEditCopy.editingIssueTitle.text(locale)), isPresented: issueBinding) {
            Button(role: .cancel) { issue = nil } label: { EditText(.close) }
        } message: {
            Text(issue?.diagnostics.map { $0.message.text(locale) }.joined(separator: "\n") ?? "")
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        Canvas { context, size in
            guard let map else { return }
            let origin = CGPoint(x: (size.width - contentSize(map).width) / 2,
                                 y: (size.height - contentSize(map).height) / 2)
            // Checkerboard background for empty cells.
            context.fill(
                Path(CGRect(origin: origin, size: contentSize(map))),
                with: .color(Color(.sRGB, white: 0.12, opacity: 1)))
            for layer in map.layers where layer.visible {
                draw(layer: layer, of: map, in: &context, origin: origin)
            }
            drawGrid(in: &context, map: map, origin: origin)
            if let selection, !selection.isEmpty {
                let rect = normalizedSelectionRect(selection, origin: origin)
                context.stroke(Path(rect), with: .color(.cyan), lineWidth: 2 / zoom * 2)
                context.fill(Path(rect), with: .color(.cyan.opacity(0.12)))
            }
        }
        .frame(width: map.map { contentSize($0).width + 48 } ?? 300,
               height: map.map { contentSize($0).height + 48 } ?? 300)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(GameEditCopy("Map canvas", "地图画布").text(locale))
        .accessibilityValue(tileSummary)
        .accessibilityIdentifier("game.edit.map.canvas")
        .gesture(canvasDrag)
        .simultaneousGesture(MagnifyGesture()
            .onEnded { value in
                zoom = min(max(0.5, zoom * value.magnification), 8.0)
            })
    }

    private func contentSize(_ map: EditableTileMap) -> CGSize {
        CGSize(width: CGFloat(map.mapSize.width) * tilePixel.width,
               height: CGFloat(map.mapSize.height) * tilePixel.height)
    }

    private func draw(layer: EditableTileMap.Layer, of map: EditableTileMap,
                      in context: inout GraphicsContext, origin: CGPoint) {
        if layer.kind == .tile {
            for y in 0..<layer.size.height {
                for x in 0..<layer.size.width {
                    let gid = layer.tileAt(x: x, y: y)
                    guard gid > 0 else { continue }
                    let rect = CGRect(x: origin.x + CGFloat(x) * tilePixel.width,
                                      y: origin.y + CGFloat(y) * tilePixel.height,
                                      width: tilePixel.width, height: tilePixel.height)
                    context.fill(Path(rect), with: .color(color(for: gid)))
                }
            }
        }
        for object in layer.objects {
            let rect = CGRect(x: origin.x + object.x * zoom,
                              y: origin.y + object.y * zoom,
                              width: object.width * zoom,
                              height: object.height * zoom)
            let isSelected = object.id == selectedObjectID
            let path = Path(roundedRect: rect, cornerRadius: 6)
            context.fill(path, with: .color(.orange.opacity(isSelected ? 0.5 : 0.3)))
            context.stroke(path, with: .color(isSelected ? .orange : .white.opacity(0.7)), lineWidth: isSelected ? 2.5 : 1)
            if isSelected || rect.width > 48 {
                let label = context.resolve(Text(object.name).font(.caption2))
                context.draw(label, at: CGPoint(x: rect.midX, y: rect.minY - 8))
            }
        }
    }

    private func drawGrid(in context: inout GraphicsContext, map: EditableTileMap, origin: CGPoint) {
        let size = contentSize(map)
        var path = Path()
        for x in 0...map.mapSize.width {
            let px = origin.x + CGFloat(x) * tilePixel.width
            path.move(to: CGPoint(x: px, y: origin.y))
            path.addLine(to: CGPoint(x: px, y: origin.y + size.height))
        }
        for y in 0...map.mapSize.height {
            let py = origin.y + CGFloat(y) * tilePixel.height
            path.move(to: CGPoint(x: origin.x, y: py))
            path.addLine(to: CGPoint(x: origin.x + size.width, y: py))
        }
        context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 1)
    }

    private func color(for gid: Int) -> Color {
        var value = UInt32(gid & 0x7FFFFFFF)
        value = value &* 2_654_435_761 &+ 97
        let hue = Double(value % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }

    // MARK: - Gestures

    private var canvasDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let map else { return }
                let point = mapPoint(from: value.location)
                let cell = cell(at: point)
                if dragStart == nil {
                    dragStart = value.location
                    strokeBase = map
                    lastCell = cell
                    beginInteraction(at: cell, map: map)
                } else {
                    continueInteraction(to: cell, map: map)
                }
            }
            .onEnded { value in
                guard let base = strokeBase, let map else {
                    dragStart = nil; strokeBase = nil; return
                }
                let isTap = (value.translation.width.magnitude + value.translation.height.magnitude) < 3
                finishInteraction(wasTap: isTap, at: cell(at: mapPoint(from: value.location)),
                                  base: base, map: map)
                dragStart = nil
                strokeBase = nil
                lastCell = nil
            }
    }

    private func beginInteraction(at cell: (x: Int, y: Int)?, map: EditableTileMap) {
        guard let cell else { return }
        switch tool {
        case .paint, .erase:
            let gid = tool == .paint ? max(1, selectedGID) : 0
            self.map = map.painting(gid: gid, atX: cell.x, y: cell.y, layerID: activeTileLayerID(in: map))
        case .fill:
            break // handled on tap end
        case .select:
            selection = EditableTileMap.Selection(x: cell.x, y: cell.y, width: 1, height: 1)
        case .object:
            selectedObjectID = hitTestObject(at: cell, in: map)
        }
    }

    private func continueInteraction(to cell: (x: Int, y: Int)?, map: EditableTileMap) {
        guard let cell, let previous = lastCell else { return }
        guard previous.x != cell.x || previous.y != cell.y else { return }
        lastCell = cell
        switch tool {
        case .paint, .erase:
            let gid = tool == .paint ? max(1, selectedGID) : 0
            // Extend the preview stroke from the last committed preview cell.
            self.map = (self.map ?? map).paintingStroke(gid: gid, from: previous, to: cell,
                                                        layerID: activeTileLayerID(in: map))
        case .select:
            if let start = dragStart {
                let originCell = self.cell(at: mapPoint(from: start)) ?? cell
                selection = EditableTileMap.Selection(x: originCell.x, y: originCell.y,
                                                      width: cell.x - originCell.x + 1,
                                                      height: cell.y - originCell.y + 1)
            }
        case .object:
            if let objectID = selectedObjectID,
               let layer = map.layers.first(where: { $0.id == activeLayerID && $0.kind == .object }),
               map.layer(id: layer.id) != nil {
                let point = CGPoint(x: CGFloat(cell.x) * tilePixel.width / zoom,
                                    y: CGFloat(cell.y) * tilePixel.height / zoom)
                var updated = self.map ?? map
                updated.apply(.moveObject(id: objectID,
                                          x: map.snapped(point.x, enabled: snap),
                                          y: map.snapped(point.y, enabled: snap),
                                          layerID: layer.id))
                self.map = updated
            }
        case .fill:
            break
        }
    }

    private func finishInteraction(wasTap: Bool, at cell: (x: Int, y: Int)?,
                                   base: EditableTileMap, map: EditableTileMap) {
        guard let cell else { return }
        switch tool {
        case .fill where wasTap:
            guard let layerID = activeTileLayerID() else { return }
            let gid = max(1, selectedGID)
            commit({ map in
                map.apply(.fill(gid: gid, fromX: cell.x, fromY: cell.y, layerID: layerID))
            }, summary: GameEditCopy("Fill region", "填充区域"))
        case .object where wasTap && selectedObjectID == nil:
            let point = CGPoint(x: CGFloat(cell.x) * Double(map.tileSize.width),
                                y: CGFloat(cell.y) * Double(map.tileSize.height))
            let object = EditableTileMap.TileMapObject(
                name: "Object \(map.layers.flatMap(\.objects).count + 1)",
                x: map.snapped(point.x, enabled: snap), y: map.snapped(point.y, enabled: snap),
                width: Double(map.tileSize.width), height: Double(map.tileSize.height))
            guard let layerID = activeObjectLayerID() else { return }
            commit({ map in
                map.apply(.placeObject(object, layerID: layerID))
            }, summary: GameEditCopy("Place object", "放置对象"))
        case .paint, .erase:
            // Preview state already equals the desired result; commit the
            // transformation against fresh session bytes.
            if let preview = self.map, preview != base {
                let layers = preview.layers
                commit({ current in current.apply(.replaceLayers(layers)) },
                       summary: tool == .paint ? GameEditCopy("Paint tiles", "绘制图块")
                                               : GameEditCopy("Erase tiles", "擦除图块"))
            }
        case .select:
            break // selection lives in view state only
        default:
            if let preview = self.map, preview != base {
                let layers = preview.layers
                commit({ current in current.apply(.replaceLayers(layers)) },
                       summary: GameEditCopy("Edit objects", "编辑对象"))
            }
        }
    }

    // MARK: - Commit / reload

    private func activeTileLayerID() -> UUID? {
        guard let map else { return nil }
        if let activeLayerID, let layer = map.layer(id: activeLayerID), layer.kind == .tile {
            return activeLayerID
        }
        return map.layers.first(where: { $0.kind == .tile })?.id
    }

    private func activeObjectLayerID() -> UUID? {
        guard let map else { return nil }
        if let activeLayerID, let layer = map.layer(id: activeLayerID), layer.kind == .object {
            return activeLayerID
        }
        return map.layers.first(where: { $0.kind == .object })?.id
    }

    private func commit(_ transform: @escaping (inout EditableTileMap) -> Void,
                        summary: GameEditCopy) {
        Task {
            do {
                try await session.editTileMapDocument(at: path,
                    binding: session.adapter.tileMapBinding(for: path, in: session.baseProject),
                    summary: summary, transform)
                await reload()
            } catch let error as GameEditIssue {
                issue = error
            } catch {
                issue = GameEditIssue([GameEditDiagnostic(severity: .error,
                    message: GameEditCopy(String(describing: error), String(describing: error)))])
            }
        }
    }

    private func decode(_ bytes: Data) throws -> EditableTileMap {
        if let binding = session.adapter.tileMapBinding(for: path, in: session.baseProject) {
            return try binding.decode(bytes)
        }
        return try EditableTileMap.decode(bytes)
    }

    private func reload() async {
        do {
            let bytes = try await session.documentBytes(at: path)
            let decoded = try decode(bytes)
            if decoded != map {
                map = decoded
                if activeLayerID == nil || decoded.layer(id: activeLayerID!) == nil {
                    activeLayerID = decoded.layers.first?.id
                }
            }
        } catch {
            issue = GameEditIssue([GameEditDiagnostic(severity: .error,
                message: GameEditCopy("This map could not be opened. The original file is kept; open it in the IDE or ask AI to inspect it.",
                                      "无法打开此地图。原文件已保留，可打开 IDE 或让 AI 检查。"), path: path)])
        }
    }

    // MARK: - Helpers

    private func mapPoint(from viewPoint: CGPoint) -> CGPoint {
        // Canvas centers the map; mirror the same origin math.
        guard let map else { return viewPoint }
        let size = CGSize(width: contentSize(map).width + 48, height: contentSize(map).height + 48)
        let origin = CGPoint(x: 24, y: 24)
        _ = size
        return CGPoint(x: (viewPoint.x - origin.x) / zoom, y: (viewPoint.y - origin.y) / zoom)
    }

    private func cell(at point: CGPoint) -> (x: Int, y: Int)? {
        guard let map else { return nil }
        let x = Int(point.x / CGFloat(map.tileSize.width))
        let y = Int(point.y / CGFloat(map.tileSize.height))
        guard x >= 0, y >= 0, x < map.mapSize.width, y < map.mapSize.height else { return nil }
        return (x, y)
    }

    private func activeTileLayerID(in map: EditableTileMap) -> UUID {
        if let activeLayerID, let layer = map.layer(id: activeLayerID), layer.kind == .tile {
            return activeLayerID
        }
        return map.layers.first(where: { $0.kind == .tile })?.id ?? activeLayerID ?? UUID()
    }

    private func activeObjectLayerID(in map: EditableTileMap) -> UUID {
        if let activeLayerID, let layer = map.layer(id: activeLayerID), layer.kind == .object {
            return activeLayerID
        }
        return map.layers.first(where: { $0.kind == .object })?.id ?? activeLayerID ?? UUID()
    }

    private func hitTestObject(at cell: (x: Int, y: Int), in map: EditableTileMap) -> UUID? {
        let point = CGPoint(x: CGFloat(cell.x) * Double(map.tileSize.width),
                            y: CGFloat(cell.y) * Double(map.tileSize.height))
        for layer in map.layers.reversed() where layer.kind == .object {
            for object in layer.objects.reversed() {
                let rect = CGRect(x: object.x, y: object.y, width: object.width, height: object.height)
                if rect.insetBy(dx: -4, dy: -4).contains(point) { return object.id }
            }
        }
        return nil
    }

    private var selectedObject: EditableTileMap.TileMapObject? {
        guard let map, let selectedObjectID else { return nil }
        return map.layers.flatMap(\.objects).first(where: { $0.id == selectedObjectID })
    }

    private func normalizedSelectionRect(_ selection: EditableTileMap.Selection,
                                         origin: CGPoint) -> CGRect {
        guard let map else { return .zero }
        let (x, y, w, h) = map.cellRect(for: selection)
        return CGRect(x: origin.x + CGFloat(x) * tilePixel.width,
                      y: origin.y + CGFloat(y) * tilePixel.height,
                      width: CGFloat(w) * tilePixel.width,
                      height: CGFloat(h) * tilePixel.height)
    }

    // MARK: - Chrome

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Picker("", selection: $tool) {
                    ForEach(Tool.allCases, id: \.self) { item in
                        EditText(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 320)
                .accessibilityIdentifier("game.edit.map.tool")

                if tool == .paint || tool == .fill {
                    palette
                }

                EditButton { snap.toggle() } label: {
                    Label {
                        EditText(GameEditCopy("Snap", "吸附"))
                    } icon: {
                        Image(systemName: snap ? "magnet" : "magnet")
                            .foregroundStyle(snap ? Color.accentColor : Color.secondary)
                    }
                }
                .accessibilityIdentifier("game.edit.map.snap")

                HStack(spacing: 2) {
                    EditButton { zoom = max(0.5, zoom / 1.5) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .accessibilityIdentifier("game.edit.map.zoomOut")
                    Text("\(Int(zoom * 100))%")
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 44, minHeight: 44)
                    EditButton { zoom = min(8, zoom * 1.5) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .accessibilityIdentifier("game.edit.map.zoomIn")
                }

                EditButton { showLayers.toggle() } label: {
                    Label { EditText(GameEditCopy("Layers", "图层")) } icon: { Image(systemName: "stack.3d.up") }
                }
                .accessibilityIdentifier("game.edit.map.layers")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var palette: some View {
        let maxGID = (map?.tileSets.map(\.firstGID).max() ?? 1) + 15
        return HStack(spacing: 4) {
            ForEach(1...max(2, maxGID), id: \.self) { gid in
                Button {
                    selectedGID = gid
                } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color(for: gid))
                        .frame(width: 30, height: 30)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(selectedGID == gid ? Color.cyan : Color.clear, lineWidth: 2))
                        .overlay(Text("\(gid)").font(.system(size: 9, weight: .medium)))
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("game.edit.map.palette.\(gid)")
            }
        }
    }

    private var tileSummary: String {
        guard let map else { return "tiles=0 layers=0" }
        var count = 0
        for layer in map.layers where layer.kind == .tile {
            for y in 0..<layer.size.height {
                for x in 0..<layer.size.width where layer.tileAt(x: x, y: y) > 0 {
                    count += 1
                }
            }
        }
        return "tiles=\(count) layers=\(map.layers.count)"
    }

    private func selectionBar(_ selection: EditableTileMap.Selection) -> some View {
        HStack(spacing: 10) {
            Text(locale == .chinese
                 ? "选中 \(max(1, abs(selection.width))) × \(max(1, abs(selection.height))) 格"
                 : "Selection \(max(1, abs(selection.width))) × \(max(1, abs(selection.height))) cells")
                .font(.callout)
            EditButton {
                if let layerID = activeTileLayerID() {
                    let gid = max(1, selectedGID)
                    let translation = selection
                    let cellRect = map?.cellRect(for: translation)
                        ?? (x: selection.x, y: selection.y, width: 1, height: 1)
                    commit({ map in
                        for yIndex in cellRect.y..<(cellRect.y + max(1, cellRect.height)) {
                            for xIndex in cellRect.x..<(cellRect.x + max(1, cellRect.width)) {
                                map.apply(.paint(gid: gid, x: xIndex, y: yIndex, layerID: layerID))
                            }
                        }
                    }, summary: GameEditCopy("Fill selection", "填充选区"))
                }
            } label: {
                EditText(GameEditCopy("Fill with tile \(selectedGID)", "用图块 \(selectedGID) 填充"))
            }
            EditButton { self.selection = nil } label: {
                EditText(GameEditCopy("Clear selection", "清除选区"))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private func objectBar(_ object: EditableTileMap.TileMapObject) -> some View {
        HStack(spacing: 10) {
            Text(object.name).font(.callout.bold())
            Text(locale == .chinese
                 ? "位置 \(Int(object.x)), \(Int(object.y)) · \(Int(object.width)) × \(Int(object.height))"
                 : "At \(Int(object.x)), \(Int(object.y)) · \(Int(object.width)) × \(Int(object.height))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            EditButton {
                if let layerID = activeObjectLayerID() {
                    commit({ map in
                        map.apply(.deleteObject(id: object.id, layerID: layerID))
                    }, summary: GameEditCopy("Delete object", "删除对象"))
                }
                selectedObjectID = nil
            } label: {
                Label { EditText(.deleted) } icon: { Image(systemName: "trash") }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var layerPanel: some View {
        List {
            if let map {
                ForEach(map.layers) { layer in
                    HStack {
                        Image(systemName: layer.kind == .tile ? "square.grid.2x2" : "skew")
                            .foregroundStyle(.secondary)
                        Text(layer.name)
                        Spacer()
                        if layer.id == activeLayerID {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan)
                        }
                        EditButton {
                            commit({ map in map.apply(.removeLayer(id: layer.id)) },
                                   summary: GameEditCopy("Remove layer", "删除图层"))
                            if activeLayerID == layer.id { activeLayerID = nil }
                        } label: { Image(systemName: "trash").foregroundStyle(.red) }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { activeLayerID = layer.id }
                }
            }
            Section {
                EditButton {
                    guard let map else { return }
                    let name = "Layer \(map.layers.count + 1)"
                    commit({ $0.apply(.addLayer(name: name, kind: .tile)) },
                           summary: GameEditCopy("Add tile layer", "添加图块图层"))
                } label: {
                    Label { EditText(GameEditCopy("Add tile layer", "添加图块图层")) } icon: { Image(systemName: "plus") }
                }
                EditButton {
                    guard let map else { return }
                    let name = "Objects \(map.layers.count + 1)"
                    commit({ $0.apply(.addLayer(name: name, kind: .object)) },
                           summary: GameEditCopy("Add object layer", "添加对象图层"))
                } label: {
                    Label { EditText(GameEditCopy("Add object layer", "添加对象图层")) } icon: { Image(systemName: "plus") }
                }
            }
        }
    }

    private var issueBinding: Binding<Bool> {
        Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })
    }
}
