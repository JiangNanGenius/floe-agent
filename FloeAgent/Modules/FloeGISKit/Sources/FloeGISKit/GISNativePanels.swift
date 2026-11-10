// SPDX-License-Identifier: MPL-2.0
import Foundation
import SwiftUI
import FloeHeavyEditorSupport
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private func gisText(_ zh: String, _ en: String) -> String { EditorText.t(zh, en) }
private extension EditorJSON {
    var gisObject: [String: EditorJSON] { if case .object(let value) = self { value } else { [:] } }
    var gisBool: Bool { if case .bool(let value) = self { value } else { false } }
    var gisString: String { string ?? "" }
    var gisInt: Int { Int(number ?? 0) }
}
private struct GISLayerSummary: Identifiable {
    let raw: EditorJSON
    var id: String { raw["id"].gisString }
    var name: String { raw["name"].gisString }
    var kind: String { raw["kind"].gisString }
    var index: Int { raw["index"].gisInt }
    var group: String { raw["group"].gisString }
    var locked: Bool { raw["locked"].gisBool }
    var visible: Bool { raw["visible"].gisBool }
    var symbol: String { kind == "raster" ? "square.3.layers.3d" : kind == "tiles" ? "square.grid.3x3" : "point.3.connected.trianglepath.dotted" }
}
private struct GISFieldSummary: Identifiable {
    let raw: EditorJSON
    var id: String { raw["name"].gisString }
    var type: String { raw["type"].gisString }
}
private struct GISFeatureSummary: Identifiable {
    let raw: EditorJSON
    var id: String { raw["id"].gisString }
    var rawID: EditorJSON { raw["rawID"] }
}
private struct GISCellSummary: Identifiable {
    let raw: EditorJSON
    var id: String { raw["name"].gisString }
    var text: String { raw["text"].gisString }
    var type: String { raw["type"].gisString }
    var truncated: Bool { raw["truncated"].gisBool }
}
private struct GISSnapshot {
    let raw: EditorJSON
    var layers: [GISLayerSummary] { raw["layers"].array.map(GISLayerSummary.init) }
    var layer: GISLayerSummary? { raw["selectedLayer"]["id"].string.map { _ in GISLayerSummary(raw: raw["selectedLayer"]) } }
    var fields: [GISFieldSummary] { raw["selectedLayer"]["fields"].array.map(GISFieldSummary.init) }
    var mode: String { raw["ui"]["mode"].string ?? "map" }
    var tool: String { raw["ui"]["tool"].string ?? "select" }
    var selectedIDs: [String] { raw["selection"]["featureIDs"].array.compactMap(\.string) }
}

@MainActor private struct GISNativeActions {
    let controller: HeavyEditorController
    var snapshot: GISSnapshot { .init(raw: controller.presentation) }
    func run(_ name: String, _ arguments: [String: EditorJSON] = [:], result: Bool = false) {
        controller.runCommand(name, arguments: .object(arguments), showResult: result)
    }
    func form(_ name: String, _ preset: [String: EditorJSON] = [:]) { controller.showCommand(name, preset: .object(preset)) }
    func layer(_ id: String, _ changes: [String: EditorJSON]) {
        var values = changes; values["layer"] = .string(id); run("layer.properties", values)
    }
    func style(_ changes: [String: EditorJSON]) {
        guard let layer = snapshot.layer else { return }
        var values = snapshot.raw["selectedLayer"]["style"].gisObject
        for (key, value) in changes { values[key] = value }
        values["layer"] = .string(layer.id); run("layer.style", values)
    }
    func rasterStyle(_ changes: [String: EditorJSON]) {
        guard let layer = snapshot.layer else { return }
        var values = snapshot.raw["selectedLayer"]["style"].gisObject
        if values["min"] == nil || values["min"] == .null { values["min"] = .string("") }
        if values["max"] == nil || values["max"] == .null { values["max"] = .string("") }
        for (key, value) in changes { values[key] = value }
        values["layer"] = .string(layer.id); run("raster.style", values)
    }
    func attribute(layer: String, feature: EditorJSON, field: GISCellSummary, value: EditorJSON) {
        run("attribute.set", ["layer": .string(layer), "feature": feature, "field": .string(field.id), "type": .string(field.type), "value": value])
    }
    func attributeForm(layer: String, feature: EditorJSON, field: GISCellSummary) {
        form("attribute.set", ["layer": .string(layer), "feature": feature, "field": .string(field.id), "type": .string(field.type)])
    }
    func selectFeature(_ id: String, selected: Bool) {
        guard let layer = snapshot.layer else { return }
        var ids = snapshot.selectedIDs.filter { $0 != id }; if selected { ids.append(id) }
        run("gis.ui.selection", ["layer": .string(layer.id), "features": .array(ids.map(EditorJSON.string))])
    }
    func reorder(_ rows: [GISLayerSummary], from source: IndexSet, to destination: Int) {
        guard source.count == 1, let index = source.first else { return }
        let target = destination > index ? destination - 1 : destination
        guard rows.indices.contains(index), rows.indices.contains(target), target != index else { return }
        run("layer.move", ["layer": .string(rows[index].id), "index": .number(Double(rows[target].index))])
    }
}

@MainActor struct GISNativeOutline: View {
    let controller: HeavyEditorController
    private var actions: GISNativeActions { .init(controller: controller) }
    private var snapshot: GISSnapshot { actions.snapshot }
    private var groupNames: [String] {
        Array(Set(snapshot.layers.map(\.group))).sorted { lhs, rhs in
            (snapshot.layers.filter { $0.group == lhs }.map(\.index).max() ?? 0) >
                (snapshot.layers.filter { $0.group == rhs }.map(\.index).max() ?? 0)
        }
    }
    var body: some View {
        List {
            Section {
                Button { actions.form("layer.create") } label: { Label(gisText("新建图层", "New layer"), systemImage: "plus") }
                if snapshot.layers.isEmpty {
                    Button { actions.run("project.sample") } label: { Label(gisText("打开样例", "Open sample"), systemImage: "map") }
                }
            }
            ForEach(groupNames, id: \.self) { group in
                let rows = snapshot.layers.filter { $0.group == group }.sorted { $0.index > $1.index }
                Section {
                    ForEach(rows) { layer in GISNativeLayerRow(controller: controller, layer: layer) }
                        .onMove { source, destination in actions.reorder(rows, from: source, to: destination) }
                } header: { groupHeader(group, rows: rows) }
            }
            if !snapshot.raw["bookmarks"].array.isEmpty {
                Section(gisText("视图书签", "View bookmarks")) {
                    ForEach(snapshot.raw["bookmarks"].array.map(GISFeatureSummary.init)) { bookmark in
                        Button { actions.run("project.bookmarkOpen", ["bookmark": bookmark.raw["id"]]) } label: {
                            Label(bookmark.raw["name"].gisString, systemImage: "bookmark")
                        }
                    }
                }
            }
            Section(gisText("坐标系", "Coordinate system")) {
                Button { actions.form("project.crs", ["crs": snapshot.raw["crs"]]) } label: {
                    Label(snapshot.raw["crs"].gisString, systemImage: "globe")
                }
                Button(gisText("保存视图书签", "Bookmark view")) { actions.form("project.bookmark") }
            }
        }
        .listStyle(.sidebar)
        .disabled(!controller.isReady || controller.isWorking)
        .accessibilityIdentifier("gis.native.outline")
    }
    private func groupHeader(_ group: String, rows: [GISLayerSummary]) -> some View {
        HStack {
            Text(group.isEmpty ? gisText("图层", "Layers") : group).lineLimit(1)
            Spacer()
            Menu {
                Button(gisText("图层组属性", "Group properties")) {
                    actions.form("group.properties", ["group": .string(group), "name": .string(group), "visible": .bool(rows.contains(where: \.visible)), "locked": .bool(rows.allSatisfy(\.locked))])
                }
                Button(rows.contains(where: \.visible) ? gisText("隐藏此组", "Hide group") : gisText("显示此组", "Show group")) {
                    actions.run("group.properties", ["group": .string(group), "visible": .bool(!rows.contains(where: \.visible))])
                }
                Button(rows.allSatisfy(\.locked) ? gisText("解锁此组", "Unlock group") : gisText("锁定此组", "Lock group")) {
                    actions.run("group.properties", ["group": .string(group), "locked": .bool(!rows.allSatisfy(\.locked))])
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel(gisText("图层组操作", "Group actions"))
        }
    }
}

@MainActor private struct GISNativeLayerRow: View {
    let controller: HeavyEditorController
    let layer: GISLayerSummary
    private var actions: GISNativeActions { .init(controller: controller) }
    var body: some View {
        HStack(spacing: 8) {
            Button { actions.layer(layer.id, ["visible": .bool(!layer.visible)]) } label: { Image(systemName: layer.visible ? "eye" : "eye.slash") }
                .accessibilityLabel(layer.visible ? gisText("隐藏图层", "Hide layer") : gisText("显示图层", "Show layer"))
            Button { actions.run("gis.ui.selectLayer", ["layer": .string(layer.id)]) } label: {
                HStack(spacing: 7) {
                    Image(systemName: layer.symbol)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(layer.name).lineLimit(2)
                        if let count = layer.raw["count"].number { Text("\(Int(count))").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                    if actions.snapshot.layer?.id == layer.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { actions.layer(layer.id, ["locked": .bool(!layer.locked)]) } label: { Image(systemName: layer.locked ? "lock.fill" : "lock.open") }
                .accessibilityLabel(layer.locked ? gisText("解锁图层", "Unlock layer") : gisText("锁定图层", "Lock layer"))
        }
        .buttonStyle(.borderless)
        .contextMenu {
            Button(gisText("图层属性", "Layer properties")) { actions.form("layer.properties", layer.raw.gisObject.merging(["layer": .string(layer.id)], uniquingKeysWith: { _, new in new })) }
            Button(gisText("上移", "Move up")) { actions.run("layer.move", ["layer": .string(layer.id), "index": .number(Double(layer.index + 1))]) }
                .disabled(layer.index >= actions.snapshot.layers.count - 1)
            Button(gisText("下移", "Move down")) { actions.run("layer.move", ["layer": .string(layer.id), "index": .number(Double(layer.index - 1))]) }.disabled(layer.index == 0)
            Button(gisText("导出图层", "Export layer")) { actions.form("file.export", ["layer": .string(layer.id)]) }
            Button(role: .destructive) { actions.run("layer.delete", ["layer": .string(layer.id)]) } label: { Text(gisText("删除图层", "Delete layer")) }.disabled(layer.locked)
        }
        .accessibilityIdentifier("gis.native.layer.\(layer.id)")
    }
}

@MainActor struct GISNativeCanvasToolbar: View {
    let controller: HeavyEditorController
    private var actions: GISNativeActions { .init(controller: controller) }
    private var snapshot: GISSnapshot { actions.snapshot }
    private var layerPreset: [String: EditorJSON] { snapshot.layer.map { ["layer": .string($0.id)] } ?? [:] }
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                Picker(gisText("视图", "View"), selection: Binding(get: { snapshot.mode }, set: { actions.run("gis.ui.mode", ["mode": .string($0)]) })) {
                    Text(gisText("地图", "Map")).tag("map")
                    Text(gisText("属性表", "Table")).tag("table")
                    Text("3D").tag("terrain")
                    Text(gisText("制图", "Layout")).tag("layout")
                }.pickerStyle(.segmented).frame(width: 280)
                if snapshot.mode == "map" { mapControls }
                if snapshot.mode == "table" { tableControls }
                if snapshot.mode == "terrain" { terrainControls }
                if snapshot.mode == "layout" { layoutControls }
                analysisMenu
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }
        .disabled(!controller.isReady || controller.isWorking)
        .accessibilityIdentifier("gis.native.canvas-toolbar")
    }
    private var mapControls: some View {
        HStack(spacing: 10) {
            Picker(gisText("工具", "Tool"), selection: Binding(get: { snapshot.tool }, set: { actions.run("gis.ui.tool", ["tool": .string($0)]) })) {
                Label(gisText("选择", "Select"), systemImage: "cursorarrow").tag("select")
                Label(gisText("点", "Point"), systemImage: "mappin").tag("Point")
                Label(gisText("线", "Line"), systemImage: "line.diagonal").tag("LineString")
                Label(gisText("面", "Polygon"), systemImage: "pentagon").tag("Polygon")
                Label(gisText("节点", "Vertices"), systemImage: "point.3.connected.trianglepath.dotted").tag("modify")
                Label(gisText("移动", "Move"), systemImage: "arrow.up.and.down.and.arrow.left.and.right").tag("translate")
            }.pickerStyle(.menu)
            Toggle(gisText("多选", "Multi-select"), isOn: Binding(get: { snapshot.raw["ui"]["multiselect"].gisBool }, set: { actions.run("gis.ui.options", ["multiselect": .bool($0)]) })).toggleStyle(.button)
            Toggle(gisText("捕捉", "Snap"), isOn: Binding(get: { snapshot.raw["ui"]["snapping"].gisBool }, set: { actions.run("gis.ui.options", ["snapping": .bool($0)]) })).toggleStyle(.button)
            Toggle(gisText("手指绘图", "Draw with finger"), isOn: Binding(get: { snapshot.raw["ui"]["fingerDrawing"].gisBool }, set: { actions.run("gis.ui.options", ["fingerDrawing": .bool($0)]) })).toggleStyle(.button).accessibilityIdentifier("gis.fingerDrawing")
            canvasButton("fitLayer", "缩放至图层", "Fit layer", "arrow.up.left.and.arrow.down.right")
            canvasButton("zoomIn", "放大", "Zoom in", "plus.magnifyingglass")
            canvasButton("zoomOut", "缩小", "Zoom out", "minus.magnifyingglass")
            if ["LineString", "Polygon"].contains(snapshot.tool) {
                canvasButton("finishDrawing", "完成绘制", "Finish drawing", "checkmark").disabled(!snapshot.raw["ui"]["drawing"].gisBool)
                canvasButton("abortDrawing", "取消绘制", "Cancel drawing", "xmark")
            }
            if snapshot.tool == "modify" {
                Button(gisText("插入节点", "Insert vertex")) { actions.run("gis.ui.canvas", ["action": .string("insertVertex")]) }
                Button(gisText("删除节点", "Delete vertex")) { actions.run("gis.ui.canvas", ["action": .string("deleteVertex")]) }
            }
        }
    }
    private var tableControls: some View {
        HStack {
            Button(gisText("管理字段", "Manage fields")) { actions.form("field.edit", layerPreset) }
            Button(gisText("计算字段", "Calculate field")) { actions.form("field.calculate", layerPreset) }
            Button(gisText("SQL 查询", "SQL query")) { actions.form("query.sql", layerPreset) }
        }
    }
    private var terrainControls: some View {
        HStack {
            Text(snapshot.raw["terrain"]["name"].gisString).font(.caption).lineLimit(1)
            GISNativeSlider(title: gisText("高程夸大", "Elevation exaggeration"), initial: snapshot.raw["terrain"]["factor"].number ?? 1, range: 0.1...20) {
                actions.run("gis.ui.terrain", ["factor": .number($0)])
            }.frame(width: 210)
        }
    }
    private var layoutControls: some View {
        HStack {
            Button(gisText("纸张与比例尺", "Paper & scale")) { actions.form("layout.settings", snapshot.raw["layout"].gisObject) }
            Button(gisText("添加标注", "Add annotation")) { actions.form("layout.annotation") }
            Button(gisText("导出地图", "Export map")) { actions.form("layout.export") }
        }
    }
    private var analysisMenu: some View {
        Menu {
            if snapshot.layer?.kind == "vector" {
                commandButton("vector.buffer", "缓冲区", "Buffer")
                commandButton("vector.clip", "裁剪", "Clip")
                commandButton("vector.intersection", "相交", "Intersection")
                commandButton("vector.union", "合并面", "Union")
                commandButton("vector.difference", "差集／挖洞", "Difference / hole")
                commandButton("vector.dissolve", "按字段融合", "Dissolve")
                commandButton("vector.simplify", "简化几何", "Simplify")
                commandButton("vector.hull", "凸包", "Convex hull")
                commandButton("vector.split", "切割线", "Split lines")
                commandButton("vector.mergeLines", "连接线段", "Merge lines")
                commandButton("vector.spatialJoin", "空间连接", "Spatial join")
                commandButton("network.route", "最短／成本路径", "Shortest / cost route")
                commandButton("raster.idw", "IDW 插值", "IDW interpolation")
                Divider()
                commandButton("query.attributes", "属性查询", "Query attributes")
                commandButton("query.spatial", "空间查询", "Query location")
                commandButton("query.nearest", "最近要素与距离", "Nearest features")
                commandButton("vector.validate", "检查拓扑", "Validate topology")
                commandButton("vector.repair", "修复几何", "Repair geometry")
            } else if snapshot.layer?.kind == "raster" {
                commandButton("raster.calculate", "波段计算／指数", "Band calculator / index")
                commandButton("raster.classify", "阈值／分类", "Threshold / classify")
                commandButton("raster.resample", "重采样／重投影", "Resample / warp")
                commandButton("raster.clip", "按面裁切", "Clip by polygon")
                commandButton("raster.mosaic", "拼接", "Mosaic")
                commandButton("raster.sample", "采样至点", "Sample at points")
                commandButton("raster.zonal", "分区统计", "Zonal statistics")
                commandButton("terrain.contours", "等高线", "Contours")
                commandButton("terrain.slope", "坡度", "Slope")
                commandButton("terrain.aspect", "坡向", "Aspect")
                commandButton("terrain.hillshade", "山体阴影", "Hillshade")
                commandButton("terrain.profile", "高程剖面", "Elevation profile")
            }
        } label: { Label(gisText("分析", "Analysis"), systemImage: "function") }
        .disabled(snapshot.layer == nil)
    }
    private func commandButton(_ name: String, _ zh: String, _ en: String) -> some View {
        Button(gisText(zh, en)) { actions.form(name, layerPreset) }
    }
    private func canvasButton(_ action: String, _ zh: String, _ en: String, _ symbol: String) -> some View {
        Button { actions.run("gis.ui.canvas", ["action": .string(action)]) } label: { Image(systemName: symbol) }
            .accessibilityLabel(gisText(zh, en)).help(gisText(zh, en))
    }
}

@MainActor struct GISNativeInspector: View {
    let controller: HeavyEditorController
    private var actions: GISNativeActions { .init(controller: controller) }
    private var snapshot: GISSnapshot { actions.snapshot }
    var body: some View {
        Group {
            if let layer = snapshot.layer {
                GISNativeLayerInspector(controller: controller, layer: layer).id(layer.id)
            } else {
                ContentUnavailableView(gisText("选择图层", "Choose a layer"), systemImage: "map", description: Text(gisText("选择图层后可修改属性与样式。", "Select a layer to edit properties and appearance.")))
            }
        }.accessibilityIdentifier("gis.native.inspector")
    }
}

@MainActor private struct GISNativeLayerInspector: View {
    let controller: HeavyEditorController
    let layer: GISLayerSummary
    private var actions: GISNativeActions { .init(controller: controller) }
    private var snapshot: GISSnapshot { actions.snapshot }
    private var preset: [String: EditorJSON] { ["layer": .string(layer.id)] }
    var body: some View {
        Form {
            Section(layer.name) {
                LabeledContent(gisText("坐标系", "CRS"), value: layer.raw["crs"].gisString)
                Toggle(gisText("显示", "Visible"), isOn: Binding(get: { layer.visible }, set: { actions.layer(layer.id, ["visible": .bool($0)]) }))
                Toggle(gisText("锁定", "Locked"), isOn: Binding(get: { layer.locked }, set: { actions.layer(layer.id, ["locked": .bool($0)]) }))
                GISNativeSlider(title: gisText("不透明度", "Opacity"), initial: layer.raw["opacity"].number ?? 1, range: 0...1) { actions.layer(layer.id, ["opacity": .number($0)]) }
                Button(gisText("名称与分组", "Name & group")) { actions.form("layer.properties", layer.raw.gisObject.merging(preset, uniquingKeysWith: { _, new in new })) }
            }
            if layer.kind == "vector" {
                GISNativeVectorStyle(controller: controller).disabled(layer.locked)
                selectedFeatures
                Section(gisText("字段与查询", "Fields & queries")) {
                    Button(gisText("管理字段", "Manage fields")) { actions.form("field.edit", preset) }.disabled(layer.locked)
                    Button(gisText("计算字段", "Calculate field")) { actions.form("field.calculate", preset) }.disabled(layer.locked)
                    Button(gisText("按属性选择", "Select by attributes")) { actions.form("query.attributes", preset) }
                    Button(gisText("SQL 查询", "SQL query")) { actions.form("query.sql", preset) }
                }
            } else if layer.kind == "raster" { rasterControls }
            else { Section { LabeledContent(gisText("瓦片数", "Tiles"), value: "\(layer.raw["count"].gisInt)") } }
            Section(gisText("图例", "Legend")) {
                ForEach(Array(snapshot.raw["selectedLayer"]["legend"].array.enumerated()), id: \.offset) { _, item in
                    Label { Text(item["label"].gisString) } icon: { Rectangle().fill(gisColor(item["color"].gisString)).frame(width: 16, height: 10) }
                }
            }
            Section { Button(gisText("导出数据／工程", "Export data / project")) { actions.form("file.export", preset) } }
        }.formStyle(.grouped).disabled(!controller.isReady || controller.isWorking)
    }
    private var selectedFeatures: some View {
        Section(gisText("选区", "Selection")) {
            LabeledContent(gisText("已选要素", "Selected features"), value: "\(snapshot.raw["selection"]["count"].gisInt)")
            HStack {
                Button { actions.run("feature.copy", preset) } label: { Image(systemName: "document.on.document") }.accessibilityLabel(gisText("复制", "Copy")).disabled(snapshot.selectedIDs.isEmpty)
                Button { actions.run("feature.cut", preset) } label: { Image(systemName: "scissors") }.accessibilityLabel(gisText("剪切", "Cut")).disabled(layer.locked || snapshot.selectedIDs.isEmpty)
                Button { actions.run("feature.paste", preset) } label: { Image(systemName: "document.on.clipboard") }.accessibilityLabel(gisText("粘贴", "Paste")).disabled(layer.locked || !snapshot.raw["selection"]["hasClipboard"].gisBool)
                Button { actions.run("feature.duplicate", preset) } label: { Image(systemName: "plus.square.on.square") }.accessibilityLabel(gisText("创建副本", "Duplicate")).disabled(layer.locked || snapshot.selectedIDs.isEmpty)
                Button(role: .destructive) { actions.run("feature.delete", preset) } label: { Image(systemName: "trash") }.accessibilityLabel(gisText("删除选区", "Delete selection")).disabled(layer.locked || snapshot.selectedIDs.isEmpty)
            }.buttonStyle(.borderless)
            if !snapshot.selectedIDs.isEmpty {
                Button(gisText("移动／旋转／缩放", "Move / rotate / scale")) { actions.form("feature.transform", preset) }.disabled(layer.locked)
                Button(gisText("测量选区", "Measure selection")) { actions.run("query.measure", preset, result: true) }
                Button(gisText("清除选择", "Clear selection")) { actions.run("gis.ui.canvas", ["action": .string("clearSelection")]) }
            }
            ForEach(snapshot.raw["selection"]["features"].array.map(GISFeatureSummary.init)) { feature in
                DisclosureGroup(feature.raw["name"].gisString) {
                    LabeledContent(gisText("类型", "Type"), value: feature.raw["geometryType"].gisString)
                    ForEach(feature.raw["attributes"].array.map(GISCellSummary.init)) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.id).font(.caption).foregroundStyle(.secondary)
                            GISNativeAttributeCell(controller: controller, layerID: layer.id, featureID: feature.rawID, field: field, locked: layer.locked)
                        }
                    }
                    Menu(gisText("编辑完整属性", "Edit full attribute")) {
                        ForEach(snapshot.fields) { field in
                            Button(field.id) { actions.attributeForm(layer: layer.id, feature: feature.rawID, field: GISCellSummary(raw: field.raw)) }
                        }
                    }.disabled(layer.locked)
                    Button(gisText("编辑节点", "Edit vertex")) { actions.form("feature.node", ["layer": .string(layer.id), "feature": feature.rawID]) }.disabled(layer.locked)
                }
            }
        }
    }
    private var rasterControls: some View {
        Section(gisText("栅格", "Raster")) {
            LabeledContent(gisText("尺寸", "Dimensions"), value: "\(layer.raw["width"].gisInt) × \(layer.raw["height"].gisInt)")
            LabeledContent(gisText("波段", "Bands"), value: "\(layer.raw["bandCount"].gisInt)")
            Picker(gisText("色带", "Palette"), selection: Binding(get: { snapshot.raw["selectedLayer"]["style"]["palette"].string ?? "terrain" }, set: { actions.rasterStyle(["palette": .string($0)]) })) {
                Text(gisText("地形", "Terrain")).tag("terrain")
                Text(gisText("灰度", "Grayscale")).tag("gray")
                Text(gisText("分类", "Classes")).tag("classes")
                Text("RGB").tag("rgb")
            }.disabled(layer.locked)
            Picker(gisText("显示波段", "Display band"), selection: Binding(get: { snapshot.raw["selectedLayer"]["style"]["band"].gisInt }, set: { actions.rasterStyle(["band": .number(Double($0))]) })) {
                ForEach(0..<max(1, layer.raw["bandCount"].gisInt), id: \.self) { index in Text("\(index + 1)").tag(index) }
            }.disabled(layer.locked)
            Button(gisText("显示范围", "Display range")) { actions.form("raster.style", snapshot.raw["selectedLayer"]["style"].gisObject.merging(preset, uniquingKeysWith: { _, new in new })) }.disabled(layer.locked)
            Button(gisText("设置地理配准", "Set georeference")) { actions.form("raster.georeference", preset) }.disabled(layer.locked)
            Button(gisText("栅格统计", "Raster statistics")) { actions.run("raster.statistics", preset, result: true) }
        }
    }
}

@MainActor private struct GISNativeVectorStyle: View {
    let controller: HeavyEditorController
    private var actions: GISNativeActions { .init(controller: controller) }
    private var snapshot: GISSnapshot { actions.snapshot }
    private var style: EditorJSON { snapshot.raw["selectedLayer"]["style"] }
    var body: some View {
        Section(gisText("样式与标签", "Style & labels")) {
            Picker(gisText("渲染", "Rendering"), selection: Binding(get: { style["mode"].string ?? "single" }, set: { actions.style(["mode": .string($0)]) })) {
                Text(gisText("单色", "Single symbol")).tag("single")
                Text(gisText("分类", "Categories")).tag("categorical")
                Text(gisText("分级", "Graduated")).tag("graduated")
            }
            fieldPicker(gisText("分类字段", "Class field"), key: "field")
            if style["mode"].string == "graduated" {
                Stepper(gisText("级数", "Classes") + ": \(style["classes"].gisInt)", value: Binding(get: { max(2, style["classes"].gisInt) }, set: { actions.style(["classes": .number(Double($0))]) }), in: 2...16)
            }
            GISNativeColorField(title: gisText("线／点颜色", "Line / point color"), initial: style["color"].string ?? "#2879c7") { actions.style(["color": .string($0)]) }
            GISNativeColorField(title: gisText("填充颜色", "Fill color"), initial: style["fill"].string ?? "#2879c7") { actions.style(["fill": .string($0)]) }
            GISNativeSlider(title: gisText("填充不透明度", "Fill opacity"), initial: style["fillOpacity"].number ?? 0.2, range: 0...1) { actions.style(["fillOpacity": .number($0)]) }
            GISNativeSlider(title: gisText("线宽", "Line width"), initial: style["width"].number ?? 2, range: 0...16) { actions.style(["width": .number($0)]) }
            GISNativeSlider(title: gisText("点大小", "Point size"), initial: style["radius"].number ?? 5, range: 1...30) { actions.style(["radius": .number($0)]) }
            fieldPicker(gisText("标签字段", "Label field"), key: "label")
        }
    }
    private func fieldPicker(_ title: String, key: String) -> some View {
        Picker(title, selection: Binding(get: { style[key].gisString }, set: { actions.style([key: .string($0)]) })) {
            Text(gisText("无", "None")).tag("")
            ForEach(snapshot.fields) { field in Text(field.id).tag(field.id) }
        }
    }
}

@MainActor struct GISNativeAttributeTable: View {
    let controller: HeavyEditorController
    @State private var filter = ""
    private var actions: GISNativeActions { .init(controller: controller) }
    private var snapshot: GISSnapshot { actions.snapshot }
    private var table: EditorJSON { snapshot.raw["table"] }
    var body: some View {
        VStack(spacing: 0) {
            tableHeader
            Divider()
            if let layer = snapshot.layer, layer.kind == "vector" {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        columnHeader
                        ForEach(table["rows"].array.map(GISFeatureSummary.init)) { row in
                            GISNativeTableRow(controller: controller, layer: layer, row: row)
                            Divider()
                        }
                    }.padding(8)
                }
                pagination
            } else {
                ContentUnavailableView(gisText("选择矢量图层", "Choose a vector layer"), systemImage: "tablecells", description: Text(gisText("属性表显示当前矢量图层的要素。", "The table shows features in the selected vector layer.")))
            }
        }
        .onAppear { filter = table["filter"].gisString }
        .onChange(of: table["layerID"]) { _, _ in filter = table["filter"].gisString }
        .accessibilityIdentifier("gis.native.attribute-table")
    }
    private var tableHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TextField(gisText("筛选属性", "Filter attributes"), text: $filter)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    .onSubmit { actions.run("gis.ui.table", ["filter": .string(filter)]) }
                Button(gisText("筛选", "Filter")) { actions.run("gis.ui.table", ["filter": .string(filter)]) }
            }
            HStack(spacing: 12) {
                Toggle(gisText("只看选区", "Selection only"), isOn: Binding(get: { table["onlySelected"].gisBool }, set: { actions.run("gis.ui.table", ["onlySelected": .bool($0)]) }))
                Menu {
                    Text(gisText("每次最多显示 12 列", "Show up to 12 columns"))
                    ForEach(table["fields"].array.map(GISFieldSummary.init)) { field in
                        Toggle(field.id, isOn: Binding(get: { table["columns"].array.contains { $0["name"].string == field.id } }, set: { enabled in
                            var columns = table["columns"].array.compactMap { $0["name"].string }.filter { $0 != field.id }
                            if enabled { columns.append(field.id) }
                            actions.run("gis.ui.table", ["columns": .array(columns.map(EditorJSON.string))])
                        })).disabled(table["columns"].array.count >= 12 && !table["columns"].array.contains { $0["name"].string == field.id })
                    }
                } label: { Label(gisText("列", "Columns"), systemImage: "rectangle.split.3x1") }
            }
        }.padding(10).disabled(!controller.isReady || controller.isWorking)
    }
    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text(gisText("选择", "Select")).frame(width: 48)
            Text("ID").font(.caption).frame(width: 120, alignment: .leading)
            ForEach(table["columns"].array.map(GISFieldSummary.init)) { field in
                Button {
                    actions.run("gis.ui.table", ["sort": .string(field.id), "sortDescending": .bool(table["sort"].string == field.id ? !table["sortDescending"].gisBool : false)])
                } label: {
                    HStack { Text(field.id).lineLimit(1); if table["sort"].string == field.id { Image(systemName: table["sortDescending"].gisBool ? "arrow.down" : "arrow.up") } }
                }.frame(width: 180, alignment: .leading)
            }
        }.font(.caption.weight(.semibold)).padding(.vertical, 7)
    }
    private var pagination: some View {
        HStack {
            Button { actions.run("gis.ui.table", ["page": .number(Double(table["page"].gisInt - 1))]) } label: { Label(gisText("上一页", "Previous"), systemImage: "chevron.left") }.disabled(table["page"].gisInt == 0)
            Spacer()
            Text("\(table["pageCount"].gisInt == 0 ? 0 : table["page"].gisInt + 1) / \(table["pageCount"].gisInt) · \(table["filteredCount"].gisInt)").font(.caption).monospacedDigit()
            Spacer()
            Button { actions.run("gis.ui.table", ["page": .number(Double(table["page"].gisInt + 1))]) } label: { Label(gisText("下一页", "Next"), systemImage: "chevron.right") }.disabled(table["page"].gisInt + 1 >= table["pageCount"].gisInt)
        }.padding(10).disabled(controller.isWorking)
    }
}

@MainActor private struct GISNativeTableRow: View {
    let controller: HeavyEditorController
    let layer: GISLayerSummary
    let row: GISFeatureSummary
    private var actions: GISNativeActions { .init(controller: controller) }
    var body: some View {
        HStack(spacing: 8) {
            Toggle(gisText("选择要素", "Select feature"), isOn: Binding(get: { row.raw["selected"].gisBool }, set: { actions.selectFeature(row.id, selected: $0) }))
                .labelsHidden().frame(width: 48)
            Text(row.id).font(.caption.monospaced()).lineLimit(1).frame(width: 120, alignment: .leading)
            ForEach(row.raw["cells"].array.map(GISCellSummary.init)) { field in
                GISNativeAttributeCell(controller: controller, layerID: layer.id, featureID: row.rawID, field: field, locked: layer.locked)
                    .frame(width: 180, alignment: .leading)
            }
        }.padding(.vertical, 5).disabled(!controller.isReady || controller.isWorking)
    }
}

@MainActor private struct GISNativeAttributeCell: View {
    let controller: HeavyEditorController
    let layerID: String
    let featureID: EditorJSON
    let field: GISCellSummary
    let locked: Bool
    @State private var text: String
    @FocusState private var focused: Bool
    init(controller: HeavyEditorController, layerID: String, featureID: EditorJSON, field: GISCellSummary, locked: Bool) {
        self.controller = controller; self.layerID = layerID; self.featureID = featureID; self.field = field; self.locked = locked
        _text = State(initialValue: field.text)
    }
    private var actions: GISNativeActions { .init(controller: controller) }
    var body: some View {
        Group {
            if field.truncated {
                Button { actions.attributeForm(layer: layerID, feature: featureID, field: field) } label: { Label(gisText("编辑完整内容", "Edit full value"), systemImage: "square.and.pencil") }
            } else if field.type == "boolean" {
                Toggle(field.id, isOn: Binding(get: { field.text == "true" }, set: { actions.attribute(layer: layerID, feature: featureID, field: field, value: .bool($0)) })).labelsHidden()
            } else {
                TextField(field.id, text: $text, axis: .vertical).lineLimit(1...4)
                    .textFieldStyle(.roundedBorder).focused($focused).onSubmit(commit)
                    .onChange(of: focused) { _, value in if !value { commit() } }
            }
        }
        .disabled(locked)
        .onChange(of: field.text) { _, value in if !focused { text = value } }
        .contextMenu {
            Button(gisText("编辑完整内容", "Edit full value")) { actions.attributeForm(layer: layerID, feature: featureID, field: field) }
            Button(gisText("设为空值", "Set null")) { actions.attribute(layer: layerID, feature: featureID, field: field, value: .null) }
        }
        .accessibilityLabel(field.id)
    }
    private func commit() {
        guard !locked, !field.truncated, text != field.text else { return }
        actions.attribute(layer: layerID, feature: featureID, field: field, value: .string(text))
    }
}

@MainActor struct GISNativeStatusBar: View {
    let controller: HeavyEditorController
    var body: some View {
        let snapshot = GISSnapshot(raw: controller.presentation)
        VStack(alignment: .leading, spacing: 6) {
            if let notice = snapshot.raw["ui"]["notice"].string, !notice.isEmpty {
                HStack(spacing: 8) {
                    Label(notice, systemImage: "info.circle").lineLimit(2)
                    Spacer(minLength: 4)
                    if snapshot.layer?.kind != "vector" {
                        Button(gisText("新建矢量图层", "New vector layer")) {
                            GISNativeActions(controller: controller).form("layer.create")
                        }.frame(minHeight: 44)
                    } else if snapshot.layer?.locked == true, let layer = snapshot.layer {
                        Button(gisText("解锁", "Unlock")) {
                            GISNativeActions(controller: controller).run("layer.properties", ["layer": .string(layer.id), "locked": .bool(false)])
                        }.frame(minHeight: 44)
                    }
                }.accessibilityIdentifier("gis.native.editNotice")
            }
            HStack(spacing: 12) {
                Text(snapshot.raw["crs"].gisString)
                if let layer = snapshot.layer { Text(layer.name).lineLimit(1) }
                Spacer()
                if let count = snapshot.raw["selection"]["count"].number { Text(gisText("已选", "Selected") + " \(Int(count))") }
                if let action = snapshot.raw["ui"]["vertexAction"].string { Text(action == "insert" ? gisText("点按线段插入节点", "Tap a segment to insert a vertex") : gisText("点按节点删除", "Tap a vertex to delete")) }
            }
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 5)
    }
}

@MainActor private struct GISNativeSlider: View {
    let title: String
    let initial: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var value: Double
    @State private var editing = false
    init(title: String, initial: Double, range: ClosedRange<Double>, commit: @escaping (Double) -> Void) {
        self.title = title; self.initial = initial; self.range = range; self.commit = commit; _value = State(initialValue: initial)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(title); Spacer(); Text(value, format: .number.precision(.fractionLength(0...2))).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: $value, in: min(range.lowerBound, initial)...max(range.upperBound, initial)) { active in
                editing = active; if !active { commit(value) }
            }
        }.onChange(of: initial) { _, updated in if !editing { value = updated } }
    }
}
private func gisColor(_ hex: String) -> Color {
    let source = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard source.count >= 6, let value = UInt64(source.prefix(6), radix: 16) else { return .accentColor }
    return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
}
@MainActor private func gisHex(_ color: Color, fallback: String) -> String {
    #if canImport(UIKit)
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return fallback }
    #elseif canImport(AppKit)
    guard let value = NSColor(color).usingColorSpace(.sRGB) else { return fallback }
    let red = value.redComponent, green = value.greenComponent, blue = value.blueComponent
    #else
    return fallback
    #endif
    #if canImport(UIKit) || canImport(AppKit)
    return String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    #endif
}
@MainActor private struct GISNativeColorField: View {
    let title: String
    let initial: String
    let commit: (String) -> Void
    @State private var color: Color
    init(title: String, initial: String, commit: @escaping (String) -> Void) { self.title = title; self.initial = initial; self.commit = commit; _color = State(initialValue: gisColor(initial)) }
    var body: some View {
        HStack {
            ColorPicker(title, selection: $color, supportsOpacity: false)
            if gisHex(color, fallback: initial) != initial {
                Button(gisText("应用", "Apply")) { commit(gisHex(color, fallback: initial)) }
            }
        }.onChange(of: initial) { _, value in color = gisColor(value) }
    }
}
