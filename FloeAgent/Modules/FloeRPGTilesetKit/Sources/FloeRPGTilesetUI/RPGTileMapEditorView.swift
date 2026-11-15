// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import CoreGraphics
import FloeGameCore
import FloeGameEditingCore
import FloeGameEditingUI
import FloeRPGCore
import FloeRPGTilesetKit

/// Visual RPG Maker map editor backed by real tileset atlases. It reuses the
/// existing `GameEditingSession` for bytes, undo/history, save and revision
/// fencing; only the palette and canvas are replaced by engine-aware visuals.
@MainActor
public struct RPGTileMapEditorView: View {
    public enum Tool: String, CaseIterable, Hashable, Sendable {
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
    public let engine: RPGEngine
    @Environment(\.gameEditLocale) private var locale
    @StateObject private var model: RPGTileMapEditorModel

    @State private var activeLayerID: UUID?
    @State private var tool: Tool = .paint
    @State private var selectedItem: RPGTilePaletteItem?
    @State private var sectionID: String?
    @State private var zoom: Double = 2.0
    @State private var previewMap: EditableTileMap?
    @State private var selection: EditableTileMap.Selection?
    @State private var selectedObjectID: UUID?
    @State private var strokeBase: EditableTileMap?
    @State private var lastCell: (x: Int, y: Int)?
    @State private var dragStart: CGPoint?
    @State private var showLayers = true
    @State private var showDiagnostics = false
    @State private var showTileDetails = false
    @State private var issue: GameEditIssue?
    @State private var scrollOffset = CGPoint.zero
    @State private var viewportSize = CGSize.zero

    public init(session: GameEditingSession, path: GameRelativePath, engine: RPGEngine) {
        self.session = session; self.path = path; self.engine = engine
        _model = StateObject(wrappedValue: RPGTileMapEditorModel(
            session: session, path: path, engine: engine))
    }

    public static func supports(path: GameRelativePath, engine: RPGEngine, selectedRoot: GameRelativePath?) -> Bool {
        RPGMapAssetScope(map: path, engine: engine)?.belongs(to: selectedRoot) == true
    }

    private var displayMap: EditableTileMap? { previewMap ?? model.map }
    private var tilePixel: CGSize {
        let size = displayMap?.tileSize ?? .init(width: engine.tileSize, height: engine.tileSize)
        return CGSize(width: CGFloat(size.width) * CGFloat(zoom), height: CGFloat(size.height) * CGFloat(zoom))
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !model.diagnostics.isEmpty || model.loadError != nil {
                diagnosticBanner
            }
            GameEditorAdaptive { _ in
                HStack(spacing: 0) {
                    paletteSidebar.frame(width: 248)
                    Divider()
                    mapWorkspace
                }
            } compact: {
                VStack(spacing: 0) {
                    paletteBar
                    Divider()
                    mapWorkspace
                }
            }
        }
        .task(id: reloadKey) { await model.reload(); synchronizeSelection() }
        .onReceive(session.objectWillChange) {
            if strokeBase == nil, previewMap == nil {
                Task { await model.reload(); synchronizeSelection() }
            }
        }
        .onChange(of: model.palette?.sections.map(\.id)) { _, sections in
            synchronizePalette(sections)
        }
        .onChange(of: model.map?.layers.map(\.id)) { _, _ in
            synchronizeLayer()
        }
        .inspector(isPresented: $showLayers) {
            layerPanel
                .inspectorColumnWidth(min: 230, ideal: 260, max: 340)
        }
        .sheet(isPresented: $showTileDetails) {
            tileDetails
        }
        .sheet(isPresented: $showDiagnostics) {
            diagnosticsSheet
        }
        .alert(Text(GameEditCopy.editingIssueTitle.text(locale)), isPresented: issueBinding) {
            Button(role: .cancel) { issue = nil } label: { EditText(.close) }
        } message: {
            Text(issue?.diagnostics.map { $0.message.text(locale) }.joined(separator: "\n") ?? "")
        }
    }

    private var reloadKey: String {
        "\(session.projectID.uuidString)|\(session.expectedRevision)|\(path.value)"
    }

    // MARK: - Canvas

    private var mapWorkspace: some View {
        VStack(spacing: 0) {
            mapArea
            if let selection, !selection.isEmpty { selectionBar(selection) }
            if let object = selectedObject { objectBar(object) }
        }
    }

    private var mapArea: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                mapContent
                    .background(GeometryReader { geometry in
                        Color.clear.preference(
                            key: RPGScrollOffsetKey.self,
                            value: geometry.frame(in: .named("rpgMapScroll")).origin)
                    })
            }
            .coordinateSpace(name: "rpgMapScroll")
            .onPreferenceChange(RPGScrollOffsetKey.self) { offset in
                if abs(offset.x - scrollOffset.x) > 0.5 || abs(offset.y - scrollOffset.y) > 0.5 {
                    scrollOffset = offset
                }
            }
            .onAppear { viewportSize = proxy.size }
            .onChange(of: proxy.size) { _, size in viewportSize = size }
        }
    }

    private var mapContent: some View {
        let map = displayMap
        let contentSize = map.map {
            CGSize(width: CGFloat($0.mapSize.width) * tilePixel.width,
                   height: CGFloat($0.mapSize.height) * tilePixel.height)
        } ?? CGSize(width: 320, height: 240)
        let visible = visibleCells(for: map, contentSize: contentSize)
        let plan = model.plan(visibleCells: visible)
        let sprites = plan.map { spriteMap($0) } ?? [:]
        return ZStack(alignment: .topLeading) {
            Color(.sRGB, white: 0.09, opacity: 1)
            if let plan, let map {
                RPGMapCanvas(plan: plan, sprites: sprites, zoom: CGFloat(zoom),
                             tilePixel: CGFloat(map.tileSize.width) * CGFloat(zoom),
                             showGrid: true)
                    .frame(width: contentSize.width, height: contentSize.height)
            } else if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    EditText(GameEditCopy("Map unavailable", "地图不可用"))
                } description: {
                    EditText(GameEditCopy(
                        "The original file is preserved. Check the asset message above or open the file in the IDE.",
                        "原文件已保留。请检查上方素材提示，或在 IDE 中打开该文件。"))
                }
            }
        }
        .frame(width: max(contentSize.width, 320), height: max(contentSize.height, 240))
        .contentShape(Rectangle())
        .gesture(canvasDrag)
        .simultaneousGesture(MagnifyGesture()
            .onEnded { value in
                zoom = min(max(0.5, zoom * Double(value.magnification)), 8.0)
            })
        .accessibilityIdentifier("game.edit.rpg.canvas")
    }

    private func visibleCells(for map: EditableTileMap?, contentSize: CGSize) -> CGRect {
        guard let map else { return .zero }
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: CGFloat(min(map.mapSize.width, 24)),
                          height: CGFloat(min(map.mapSize.height, 18)))
        }
        let pixel = max(1, CGFloat(map.tileSize.width) * CGFloat(zoom))
        let originX = max(0, -scrollOffset.x)
        let originY = max(0, -scrollOffset.y)
        let minX = max(0, (originX / pixel).rounded(.down) - 1)
        let minY = max(0, (originY / pixel).rounded(.down) - 1)
        let maxX = min(CGFloat(map.mapSize.width),
                       (originX + viewportSize.width) / pixel + 2)
        let maxY = min(CGFloat(map.mapSize.height),
                       (originY + viewportSize.height) / pixel + 2)
        guard maxX > minX, maxY > minY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func spriteMap(_ plan: RPGTileRenderPlan) -> [String: CGImage] {
        var result: [String: CGImage] = [:]
        for command in plan.commands {
            let key = RPGMapCanvas.spriteKey(path: command.imagePath, source: command.source)
            if result[key] == nil, let image = model.sprite(path: command.imagePath, source: command.source) {
                result[key] = image
            }
        }
        return result
    }

    // MARK: - Gestures

    private var canvasDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let map = displayMap else { return }
                let cell = cell(at: mapPoint(from: value.location, map: map), in: map)
                if dragStart == nil {
                    dragStart = value.location
                    strokeBase = map
                    lastCell = cell
                    beginInteraction(at: cell, map: map)
                } else if let cell, let previous = lastCell,
                          previous.x != cell.x || previous.y != cell.y {
                    lastCell = cell
                    continueInteraction(to: cell, map: map)
                }
            }
            .onEnded { value in
                guard let base = strokeBase, let map = displayMap else {
                    dragStart = nil; strokeBase = nil; return
                }
                let isTap = (value.translation.width.magnitude + value.translation.height.magnitude) < 3
                let cell = self.cell(at: mapPoint(from: value.location, map: map), in: map)
                finishInteraction(wasTap: isTap, at: cell, base: base, map: map)
                dragStart = nil
                strokeBase = nil
                lastCell = nil
            }
    }

    private func beginInteraction(at cell: (x: Int, y: Int)?, map: EditableTileMap) {
        guard let cell else { return }
        switch tool {
        case .paint, .erase:
            let gid = tool == .paint ? selectedGID : 0
            previewMap = map.painting(gid: gid, atX: cell.x, y: cell.y,
                                      layerID: activeTileLayerID(in: map))
        case .fill:
            break
        case .select:
            selection = EditableTileMap.Selection(x: cell.x, y: cell.y, width: 1, height: 1)
        case .object:
            selectedObjectID = hitTestObject(at: cell, in: map)
        }
    }

    private func continueInteraction(to cell: (x: Int, y: Int), map: EditableTileMap) {
        switch tool {
        case .paint, .erase:
            let gid = tool == .paint ? selectedGID : 0
            guard let previous = lastCell else { return }
            previewMap = (previewMap ?? map).paintingStroke(
                gid: gid, from: previous, to: cell, layerID: activeTileLayerID(in: map))
        case .select:
            if let start = dragStart {
                let origin = self.cell(at: mapPoint(from: start, map: map), in: map) ?? cell
                selection = EditableTileMap.Selection(
                    x: origin.x, y: origin.y,
                    width: cell.x - origin.x + 1, height: cell.y - origin.y + 1)
            }
        case .object:
            guard let objectID = selectedObjectID,
                  let layerID = activeObjectLayerID(in: map) else { return }
            let point = CGPoint(x: CGFloat(cell.x * map.tileSize.width),
                                y: CGFloat(cell.y * map.tileSize.height))
            var updated = previewMap ?? map
            updated.apply(.moveObject(id: objectID, x: point.x, y: point.y, layerID: layerID))
            previewMap = updated
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
            let gid = selectedGID
            commit(summary: GameEditCopy("Fill region", "填充区域")) { map in
                map.apply(.fill(gid: gid, fromX: cell.x, fromY: cell.y, layerID: layerID))
            }
        case .object where wasTap && selectedObjectID == nil:
            guard let layerID = activeObjectLayerID() else { return }
            guard engine == .rpgMakerMV || engine == .rpgMakerMZ else {
                issue = GameEditIssue([GameEditDiagnostic(
                    severity: .warning,
                    message: GameEditCopy(
                        "New events on XP/VX/Ace maps need an existing event template. Select an existing event to move or edit it in the event editor.",
                        "XP/VX/Ace 地图上的新事件需要现有事件模板。请选择现有事件进行移动，或在事件编辑器中编辑。"))])
                previewMap = nil
                return
            }
            let nextID = (map.layers.flatMap(\.objects)
                .compactMap { $0.properties["eventId"]?.intValue }
                .max() ?? 0) + 1
            let point = CGPoint(x: CGFloat(cell.x * map.tileSize.width),
                                y: CGFloat(cell.y * map.tileSize.height))
            let object = EditableTileMap.TileMapObject(
                name: "Event \(nextID)", x: point.x, y: point.y,
                width: Double(map.tileSize.width), height: Double(map.tileSize.height),
                properties: ["eventId": .number(Double(nextID))])
            commit(summary: GameEditCopy("Place event", "放置事件")) { map in
                map.apply(.placeObject(object, layerID: layerID))
            }
        case .paint, .erase:
            if let preview = previewMap, preview != base {
                let layers = preview.layers
                commit(summary: tool == .paint ? GameEditCopy("Paint tiles", "绘制图块")
                                               : GameEditCopy("Erase tiles", "擦除图块")) { map in
                    map.apply(.replaceLayers(layers))
                }
            } else {
                previewMap = nil
            }
        case .select:
            previewMap = nil
        default:
            if let preview = previewMap, preview != base {
                let layers = preview.layers
                commit(summary: GameEditCopy("Edit objects", "编辑对象")) { map in
                    map.apply(.replaceLayers(layers))
                }
            } else {
                previewMap = nil
            }
        }
    }

    // MARK: - Commit / selection

    private func commit(summary: GameEditCopy,
                        _ transform: @escaping (inout EditableTileMap) -> Void) {
        Task {
            do {
                try await model.commit(summary: summary, transform)
                previewMap = nil
                synchronizeLayer()
            } catch let error as GameEditIssue {
                issue = error
                previewMap = nil
            } catch {
                issue = GameEditIssue([GameEditDiagnostic(
                    severity: .error,
                    message: GameEditCopy(String(describing: error), String(describing: error)))])
                previewMap = nil
            }
        }
    }

    private func synchronizeSelection() {
        guard let palette = model.palette else { return }
        synchronizePalette(palette.sections.map(\.id))
        if let selectedItem, let section = palette.section(id: selectedItem.sectionID) {
            sectionID = section.id
            if let exact = section.items.first(where: { $0.gid == selectedItem.gid }) {
                self.selectedItem = exact
            } else if let base = section.items.first(where: {
                $0.autotileKind != nil && $0.autotileKind == selectedItem.autotileKind
            }) {
                self.selectedItem = palette.shapeVariants(for: base)
                    .first(where: { $0.gid == selectedItem.gid }) ?? base
            } else {
                self.selectedItem = section.items.first
            }
        } else if let section = palette.sections.first {
            selectedItem = section.items.first
            sectionID = section.id
        } else {
            selectedItem = nil
        }
        synchronizeLayer()
    }

    private func synchronizePalette(_ sections: [String]?) {
        guard let sections, !sections.isEmpty else { return }
        if let sectionID, sections.contains(sectionID) { return }
        sectionID = sections.first
        selectedItem = model.palette?.section(id: sections[0])?.items.first
    }

    private func synchronizeLayer() {
        guard let map = model.map else { return }
        if let activeLayerID, map.layer(id: activeLayerID) != nil { return }
        activeLayerID = map.layers.first(where: { $0.kind == .tile })?.id ?? map.layers.first?.id
    }

    // MARK: - Geometry

    private func mapPoint(from viewPoint: CGPoint, map: EditableTileMap) -> CGPoint {
        CGPoint(x: viewPoint.x / CGFloat(zoom), y: viewPoint.y / CGFloat(zoom))
    }

    private func cell(at point: CGPoint, in map: EditableTileMap) -> (x: Int, y: Int)? {
        let x = Int(point.x / CGFloat(map.tileSize.width))
        let y = Int(point.y / CGFloat(map.tileSize.height))
        guard x >= 0, y >= 0, x < map.mapSize.width, y < map.mapSize.height else { return nil }
        return (x, y)
    }

    private func activeTileLayerID() -> UUID? {
        guard let map = displayMap ?? model.map else { return nil }
        return activeTileLayerID(in: map)
    }

    private func activeTileLayerID(in map: EditableTileMap) -> UUID {
        if let activeLayerID, let layer = map.layer(id: activeLayerID), layer.kind == .tile {
            return activeLayerID
        }
        return map.layers.first(where: { $0.kind == .tile })?.id ?? UUID()
    }

    private func activeObjectLayerID() -> UUID? {
        guard let map = displayMap ?? model.map else { return nil }
        return activeObjectLayerID(in: map)
    }

    private func activeObjectLayerID(in map: EditableTileMap) -> UUID? {
        if let activeLayerID, let layer = map.layer(id: activeLayerID), layer.kind == .object {
            return activeLayerID
        }
        return map.layers.first(where: { $0.kind == .object })?.id
    }

    private func hitTestObject(at cell: (x: Int, y: Int), in map: EditableTileMap) -> UUID? {
        let point = CGPoint(x: CGFloat(cell.x * map.tileSize.width),
                            y: CGFloat(cell.y * map.tileSize.height))
        for layer in map.layers.reversed() where layer.kind == .object {
            for object in layer.objects.reversed() {
                let rect = CGRect(x: CGFloat(object.x), y: CGFloat(object.y),
                                  width: max(1, CGFloat(object.width)),
                                  height: max(1, CGFloat(object.height)))
                if rect.insetBy(dx: -4, dy: -4).contains(point) { return object.id }
            }
        }
        return nil
    }

    private var selectedObject: EditableTileMap.TileMapObject? {
        guard let map = displayMap ?? model.map, let selectedObjectID else { return nil }
        return map.layers.flatMap(\.objects).first(where: { $0.id == selectedObjectID })
    }

    private var selectedGID: Int { max(1, selectedItem?.gid ?? 1) }

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

                if tool == .paint || tool == .fill {
                    HStack(spacing: 8) {
                        if let selectedItem, let path = model.definition?.imagePath(for: selectedItem.sheet) {
                            RPGTileSwatch(item: selectedItem, image: model.tilesetImages[path],
                                          size: 34, selected: true)
                                .frame(width: 44, height: 44)
                                .accessibilityLabel(Text(selectedItem.titleEN))
                        }
                        EditButton { showTileDetails = true } label: {
                            Label { EditText(GameEditCopy("Tiles", "图块")) }
                                icon: { Image(systemName: "square.grid.3x3") }
                        }
                    }
                }

                EditButton { showTileDetails = true } label: {
                    Label { EditText(GameEditCopy("Variants", "变体")) }
                        icon: { Image(systemName: "square.grid.3x3.square") }
                }

                HStack(spacing: 2) {
                    EditButton { zoom = max(0.5, zoom / 1.5) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    Text("\(Int(zoom * 100))%")
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 44, minHeight: 44)
                    EditButton { zoom = min(8, zoom * 1.5) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                }

                EditButton { showLayers.toggle() } label: {
                    Label { EditText(GameEditCopy("Layers", "图层")) }
                        icon: { Image(systemName: "square.3.layers.3d") }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
        }
    }

    private var paletteSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                EditText(GameEditCopy("Tiles", "图块")).font(.subheadline.bold())
                Spacer()
                EditButton { showTileDetails = true } label: {
                    Image(systemName: "square.grid.3x3.square")
                }
                .accessibilityLabel(GameEditCopy("Variants", "变体").text(locale))
            }
            .padding(.horizontal, 12)
            if let palette = model.palette, !palette.sections.isEmpty {
                Picker(selection: Binding(
                    get: { sectionID ?? palette.sections.first?.id ?? "" },
                    set: { id in
                        sectionID = id
                        selectedItem = palette.section(id: id)?.items.first
                    })) {
                    ForEach(palette.sections) { section in
                        Text(locale == .chinese ? section.titleZH : section.titleEN).tag(section.id)
                    }
                } label: { EditText(GameEditCopy("Tileset", "图块集")) }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                Divider()
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 52), spacing: 4)], spacing: 4) {
                        ForEach(currentItems(palette)) { item in
                            paletteButton(item)
                        }
                    }
                    .padding(6)
                }
                Divider()
                Text(selectedItemTitle)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 12)
            } else {
                paletteBar
                Spacer(minLength: 0)
            }
        }
        .background(GameEditorSurfaces.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("game.edit.rpg.palettePane")
    }

    private func paletteButton(_ item: RPGTilePaletteItem) -> some View {
        let path = model.definition?.imagePath(for: item.sheet)
        return Button { selectedItem = item } label: {
            RPGTileSwatch(item: item, image: path.flatMap { model.tilesetImages[$0] },
                          size: 40, selected: isPaletteItemSelected(item))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(locale == .chinese ? item.titleZH : item.titleEN)
        .accessibilityHint(GameEditCopy(item.isAutotile
            ? "Select this tile; open Variants for shapes." : "Select this tile.", item.isAutotile
            ? "选择图块；可打开变体选择形状。" : "选择图块。").text(locale))
        .accessibilityIdentifier("game.edit.rpg.palette.\(item.id)")
    }

    private var paletteBar: some View {
        VStack(spacing: 0) {
            if let palette = model.palette, !palette.sections.isEmpty {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(palette.sections) { section in
                            Button {
                                sectionID = section.id
                                selectedItem = section.items.first
                            } label: {
                                Text(locale == .chinese ? section.titleZH : section.titleEN)
                            }
                        }
                    } label: {
                        Label(currentSectionTitle(palette), systemImage: "square.grid.2x2")
                            .frame(minHeight: 44)
                    }
                    if let item = selectedItem, item.isAutotile {
                        Button { showTileDetails = true } label: {
                            Label { EditText(GameEditCopy("Shapes", "形状")) }
                                icon: { Image(systemName: "square.grid.3x3.square") }
                        }
                        .frame(minHeight: 44)
                    }
                    Spacer()
                    Text(selectedItemTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 4) {
                        ForEach(currentItems(palette)) { item in
                            paletteButton(item)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
                .frame(height: 52)
            } else if model.isLoading {
                ProgressView().padding(6)
            } else if model.definition == nil || (model.palette?.sections.isEmpty ?? true) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.orange)
                    EditText(GameEditCopy(
                        "No tileset image is available. The map keeps its original tile ids; add or fix the image to preview it.",
                        "没有可用的图块图片。地图会保留原始图块 ID；添加或修复图片后即可预览。"))
                        .font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    private func currentSectionTitle(_ palette: RPGTilePalette) -> String {
        guard let section = palette.section(id: sectionID ?? "") ?? palette.sections.first else { return "" }
        return locale == .chinese ? section.titleZH : section.titleEN
    }

    private func isPaletteItemSelected(_ item: RPGTilePaletteItem) -> Bool {
        guard let selectedItem else { return false }
        if selectedItem.id == item.id { return true }
        return selectedItem.sectionID == item.sectionID
            && selectedItem.autotileKind != nil
            && selectedItem.autotileKind == item.autotileKind
    }

    private func currentItems(_ palette: RPGTilePalette) -> [RPGTilePaletteItem] {
        if let sectionID, let section = palette.section(id: sectionID) { return section.items }
        return palette.sections.first?.items ?? []
    }

    private var selectedItemTitle: String {
        guard let item = selectedItem else { return "" }
        return locale == .chinese ? item.titleZH : item.titleEN
    }

    private var diagnosticBanner: some View {
        Button { showDiagnostics = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(locale == .chinese
                     ? "素材需要处理（\(model.diagnostics.count)）"
                     : "Assets need attention (\(model.diagnostics.count))")
                    .font(.callout)
                Spacer()
                Image(systemName: "info.circle")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(.thinMaterial)
        .accessibilityIdentifier("game.edit.rpg.assetBanner")
    }

    private func selectionBar(_ selection: EditableTileMap.Selection) -> some View {
        HStack(spacing: 10) {
            Text(locale == .chinese
                 ? "选中 \(max(1, abs(selection.width))) × \(max(1, abs(selection.height))) 格"
                 : "Selection \(max(1, abs(selection.width))) × \(max(1, abs(selection.height))) cells")
                .font(.callout)
            EditButton {
                guard let layerID = activeTileLayerID() else { return }
                let gid = selectedGID
                let rect = (displayMap ?? model.map)?.cellRect(for: selection)
                    ?? (x: selection.x, y: selection.y, width: 1, height: 1)
                commit(summary: GameEditCopy("Fill selection", "填充选区")) { map in
                    for y in rect.y..<(rect.y + max(1, rect.height)) {
                        for x in rect.x..<(rect.x + max(1, rect.width)) {
                            map.apply(.paint(gid: gid, x: x, y: y, layerID: layerID))
                        }
                    }
                }
            } label: {
                EditText(GameEditCopy("Fill selection", "填充选区"))
            }
            EditButton { self.selection = nil } label: {
                EditText(GameEditCopy("Clear selection", "清除选区"))
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private func objectBar(_ object: EditableTileMap.TileMapObject) -> some View {
        HStack(spacing: 10) {
            Text(object.name).font(.callout.bold())
            Text("\(Int(object.x)), \(Int(object.y)) · \(Int(object.width)) × \(Int(object.height))")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            EditButton {
                if let layerID = activeObjectLayerID() {
                    commit(summary: GameEditCopy("Delete object", "删除对象")) { map in
                        map.apply(.deleteObject(id: object.id, layerID: layerID))
                    }
                }
                selectedObjectID = nil
            } label: {
                Label { EditText(.deleted) } icon: { Image(systemName: "trash") }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var layerPanel: some View {
        List {
            if let map = model.map {
                ForEach(map.layers) { layer in
                    HStack(spacing: 8) {
                        Button {
                            var layers = map.layers
                            if let index = layers.firstIndex(where: { $0.id == layer.id }) {
                                layers[index].visible.toggle()
                            }
                            commit(summary: GameEditCopy("Toggle layer", "切换图层")) { map in
                                map.apply(.replaceLayers(layers))
                            }
                        } label: {
                            Image(systemName: layer.visible ? "eye" : "eye.slash")
                                .frame(width: 34, height: 44)
                        }
                        .buttonStyle(.plain)
                        Image(systemName: layer.kind == .tile ? "square.grid.2x2" : "skew")
                            .foregroundStyle(.secondary)
                        Text(layer.name)
                        Spacer()
                        if layer.id == activeLayerID {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan)
                        }
                        Button {
                            commit(summary: GameEditCopy("Remove layer", "删除图层")) { map in
                                map.apply(.removeLayer(id: layer.id))
                            }
                            if activeLayerID == layer.id { activeLayerID = nil }
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.red)
                                .frame(width: 34, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { activeLayerID = layer.id }
                }
                Section {
                    EditButton {
                        let name = "Layer \(map.layers.count + 1)"
                        commit(summary: GameEditCopy("Add tile layer", "添加图块图层")) { map in
                            map.apply(.addLayer(name: name, kind: .tile))
                        }
                    } label: {
                        Label { EditText(GameEditCopy("Add tile layer", "添加图块图层")) }
                            icon: { Image(systemName: "plus") }
                    }
                    EditButton {
                        let name = "Objects \(map.layers.count + 1)"
                        commit(summary: GameEditCopy("Add object layer", "添加对象图层")) { map in
                            map.apply(.addLayer(name: name, kind: .object))
                        }
                    } label: {
                        Label { EditText(GameEditCopy("Add object layer", "添加对象图层")) }
                            icon: { Image(systemName: "plus") }
                    }
                }
            }
        }
    }

    private var tileDetails: some View {
        NavigationStack {
            Group {
                if let item = selectedItem, let palette = model.palette {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 12) {
                                let path = model.definition?.imagePath(for: item.sheet)
                                RPGTileSwatch(item: item, image: path.flatMap { model.tilesetImages[$0] },
                                              size: 96, selected: true)
                                    .frame(width: 112, height: 112)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(locale == .chinese ? item.titleZH : item.titleEN)
                                        .font(.headline)
                                    Text("GID \(item.gid)").font(.caption.monospaced())
                                    Text(item.sheetDescription)
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let path {
                                        Text(path).font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(2).textSelection(.enabled)
                                    }
                                }
                            }
                            if item.isAutotile {
                                Text(locale == .chinese ? "形状（边、角、水面、墙）"
                                                        : "Shapes (edges, corners, water, walls)")
                                    .font(.headline)
                                let variants = palette.shapeVariants(for: item)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))], spacing: 6) {
                                    ForEach(variants) { variant in
                                        let path = model.definition?.imagePath(for: variant.sheet)
                                        Button {
                                            selectedItem = variant
                                        } label: {
                                            VStack(spacing: 2) {
                                                RPGTileSwatch(item: variant,
                                                              image: path.flatMap { model.tilesetImages[$0] },
                                                              size: 44,
                                                              selected: selectedItem?.id == variant.id)
                                                    .frame(width: 48, height: 48)
                                                Text("\(variant.autotileShape ?? 0)")
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                } else {
                    ContentUnavailableView {
                        EditText(GameEditCopy("No tile selected", "未选择图块"))
                    }
                }
            }
            .navigationTitle(locale == .chinese ? "图块详情" : "Tile details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { showTileDetails = false } label: { EditText(.close) }
                }
            }
        }
    }

    private var diagnosticsSheet: some View {
        NavigationStack {
            List {
                if let error = model.loadError {
                    Section {
                        Text(error).font(.caption.monospaced()).textSelection(.enabled)
                    } header: { EditText(GameEditCopy("Load error", "加载错误")) }
                }
                Section {
                    if model.diagnostics.isEmpty {
                        EditText(GameEditCopy("No asset problems reported.", "未报告素材问题。"))
                    }
                    ForEach(model.diagnostics) { diagnostic in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(diagnostic.message(chinese: locale == .chinese))
                            if let path = diagnostic.path {
                                Text(path).font(.caption2.monospaced())
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                } header: {
                    EditText(GameEditCopy("Asset diagnostics", "素材诊断"))
                }
            }
            .navigationTitle(locale == .chinese ? "素材诊断" : "Asset diagnostics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { showDiagnostics = false } label: { EditText(.close) }
                }
            }
        }
    }

    private var issueBinding: Binding<Bool> {
        Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })
    }
}

private struct RPGScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

private struct RPGMapCanvas: View {
    let plan: RPGTileRenderPlan
    let sprites: [String: CGImage]
    let zoom: CGFloat
    let tilePixel: CGFloat
    let showGrid: Bool

    static func spriteKey(path: String, source: CGRect) -> String {
        "\(path)|\(Int(source.minX)),\(Int(source.minY)),\(Int(source.width)),\(Int(source.height))"
    }

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(x: zoom, y: zoom)
            for command in plan.commands {
                let key = Self.spriteKey(path: command.imagePath, source: command.source)
                if let image = sprites[key] {
                    context.draw(Image(decorative: image, scale: 1).interpolation(.none),
                                 in: command.destination)
                } else {
                    context.fill(Path(command.destination), with: .color(.orange.opacity(0.12)))
                    context.stroke(Path(command.destination), with: .color(.orange.opacity(0.65)),
                                   lineWidth: 1 / max(0.01, zoom))
                }
            }
            for marker in plan.markers {
                context.fill(Path(marker.rect), with: .color(.orange.opacity(0.22)))
                context.stroke(Path(marker.rect), with: .color(.orange.opacity(0.9)),
                               lineWidth: 1.5 / max(0.01, zoom))
            }
            if showGrid {
                var grid = Path()
                let tile = max(1, tilePixel / max(0.01, zoom))
                let minX = max(0, plan.visibleCellRect.minX)
                let minY = max(0, plan.visibleCellRect.minY)
                let maxX = min(CGFloat(plan.mapSize.width), plan.visibleCellRect.maxX)
                let maxY = min(CGFloat(plan.mapSize.height), plan.visibleCellRect.maxY)
                var x = minX
                while x <= maxX {
                    grid.move(to: CGPoint(x: x * tile, y: minY * tile))
                    grid.addLine(to: CGPoint(x: x * tile, y: maxY * tile))
                    x += 1
                }
                var y = minY
                while y <= maxY {
                    grid.move(to: CGPoint(x: minX * tile, y: y * tile))
                    grid.addLine(to: CGPoint(x: maxX * tile, y: y * tile))
                    y += 1
                }
                context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Map canvas"))
    }
}

/// Draws one tile/autotile thumbnail from real atlas quarters. It is used in
/// the palette and the opened details sheet; internal GIDs are not printed
/// here.
struct RPGTileSwatch: View {
    let item: RPGTilePaletteItem
    let image: CGImage?
    let size: CGFloat
    let selected: Bool

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            context.fill(Path(rect), with: .color(Color(.sRGB, white: 0.18, opacity: 1)))
            guard let image else {
                context.fill(Path(rect), with: .color(.orange.opacity(0.10)))
                context.stroke(Path(rect.insetBy(dx: 1, dy: 1)),
                               with: .color(.orange.opacity(0.7)), lineWidth: 1)
                return
            }
            let destinations = RPGTileGeometry.destinationQuarters(for: rect,
                                                                    count: item.sourceQuarters.count)
            for (index, source) in item.sourceQuarters.enumerated()
            where destinations.indices.contains(index) {
                let integral = CGRect(x: source.minX.rounded(), y: source.minY.rounded(),
                                      width: source.width.rounded(), height: source.height.rounded())
                guard let cropped = image.cropping(to: integral) else { continue }
                context.draw(Image(decorative: cropped, scale: 1).interpolation(.none),
                             in: destinations[index])
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(selected ? Color.cyan : Color.white.opacity(0.20),
                        lineWidth: selected ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .frame(width: size, height: size)
    }
}

extension RPGTilePaletteItem {
    var sheetDescription: String {
        switch sheet {
        case .xpTileset: return "Graphics/Tilesets"
        case .xpAutotile(let index): return "XP autotile \(index + 1)"
        case .section(let section): return section.rawValue.uppercased()
        case .character: return "Character"
        }
    }
}
