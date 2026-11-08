// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeHeavyEditorSupport

// These views own presentation gestures and drafts only. The engine remains the
// single source of truth for glyphs, master topology, undo and exported fonts.
@MainActor enum FontNativePanels {
    static func canvas(_ controller: HeavyEditorController) -> AnyView? {
        switch controller.presentation["ui"]["mode"].string ?? "overview" {
        case "outline": controller.presentation["glyph"] == .null ? AnyView(ContentUnavailableView(EditorText.t("此母版没有字形", "This master has no glyphs"), systemImage: "character.textbox", description: Text(EditorText.t("切换母版，或从其他母版复制字形。", "Switch masters or copy a glyph from another master.")))) : AnyView(FontOutlineCanvas(controller: controller))
        case "features": AnyView(FontFeatureEditor(controller: controller))
        case "variations": AnyView(FontVariationPanel(controller: controller))
        case "metrics": AnyView(FontSpacingCanvas(controller: controller))
        case "proof": nil // WebKit uses the compiled FontFace for real shaping.
        default: AnyView(FontCharacterGrid(controller: controller))
        }
    }
}

private extension EditorJSON {
    var fontText: String { string ?? "" }
    var fontNumber: Double { number ?? 0 }
    var fontID: String { self["id"].string ?? self["name"].string ?? self["tag"].string ?? "" }
    var fontStrings: [String] { array.compactMap(\.string) }
    var fontUnicode: String {
        array.compactMap { item in item.number.flatMap { Unicode.Scalar(Int($0)) } }.map { String($0) }.joined()
    }
    func replacing(_ key: String, _ value: EditorJSON) -> EditorJSON {
        var values = object; values[key] = value; return .object(values)
    }
}

@MainActor struct FontGlyphOutline: View {
    let controller: HeavyEditorController
    private var state: EditorJSON { controller.presentation }
    @State private var search = ""
    var body: some View {
        VStack(spacing: 10) {
            TextField(EditorText.t("搜索字形或字符", "Find glyph or character"), text: $search)
                .textFieldStyle(.roundedBorder).onSubmit { searchGlyphs() }
                .task(id: search) {
                    do { try await Task.sleep(for: .milliseconds(220)); try Task.checkCancellation(); searchGlyphs() } catch { }
                }
                .accessibilityIdentifier("font.glyphSearch")
            Picker(EditorText.t("母版", "Master"), selection: Binding(
                get: { state["masterID"].string ?? "default" },
                set: { controller.runCommand("font.ui.master", arguments: .object(["master": .string($0)])) })) {
                ForEach(state["masters"].array, id: \.fontID) { master in Text(master["name"].fontText).tag(master["id"].fontText) }
            }.pickerStyle(.menu)
            HStack {
                Text(EditorText.t("字形", "Glyphs")).font(.headline)
                Spacer()
                Button { controller.showCommand("glyph.create") } label: { Image(systemName: "plus") }
                    .accessibilityLabel(EditorText.t("新建字形", "New glyph"))
            }
            List(state["glyphList"]["items"].array, id: \.fontID) { glyph in
                Button {
                    controller.runCommand("font.ui.glyph", arguments: .object(["glyph": glyph["name"]]))
                } label: {
                    HStack(spacing: 8) {
                        Text(glyph["unicodes"].fontUnicode).font(.title3).frame(width: 28)
                        Text(glyph["name"].fontText).font(.callout).lineLimit(1)
                        Spacer(minLength: 0)
                        if glyph["name"] == state["glyph"]["name"] { Image(systemName: "checkmark").font(.caption).foregroundStyle(.tint) }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.listStyle(.plain)
            FontGlyphPagination(controller: controller)
            HStack {
                Button(EditorText.t("字符集", "Character set")) { controller.showCommand("glyph.charset") }
                Spacer()
                Button(EditorText.t("字体信息", "Font info")) { controller.showCommand("font.info", preset: state["info"]) }
            }.font(.caption)
        }.padding(12).onAppear { search = state["ui"]["search"].fontText }
    }
    private func searchGlyphs() {
        guard search != state["ui"]["search"].fontText else { return }
        controller.runCommand("font.ui.search", arguments: .object(["query": .string(search)]))
    }
}

@MainActor private struct FontGlyphPagination: View {
    let controller: HeavyEditorController
    private var list: EditorJSON { controller.presentation["glyphList"] }
    var body: some View {
        HStack {
            Button { page(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(list["page"].fontNumber <= 0).accessibilityLabel(EditorText.t("上一页", "Previous page"))
            Spacer()
            let count = Int(list["filtered"].fontNumber), start = Int(list["page"].fontNumber * list["pageSize"].fontNumber)
            Text("\(count == 0 ? 0 : start + 1)–\(min(start + list["items"].array.count, count)) / \(count)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button { page(1) } label: { Image(systemName: "chevron.right") }
                .disabled(start + list["items"].array.count >= count).accessibilityLabel(EditorText.t("下一页", "Next page"))
        }.buttonStyle(.borderless)
    }
    private func page(_ delta: Int) { controller.runCommand("font.ui.page", arguments: .object(["page": .number(list["page"].fontNumber + Double(delta))])) }
}

@MainActor struct FontModeToolbar: View {
    let controller: HeavyEditorController
    private var state: EditorJSON { controller.presentation }
    private let modes = ["overview", "outline", "metrics", "features", "variations", "proof"]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Picker(EditorText.t("工作模式", "Mode"), selection: Binding(
                    get: { state["ui"]["mode"].string ?? "overview" },
                    set: { controller.runCommand("font.ui.mode", arguments: .object(["mode": .string($0)])) })) {
                    ForEach(modes, id: \.self) { Text(modeTitle($0)).tag($0) }
                }.pickerStyle(.segmented).frame(minWidth: 520)
                if state["ui"]["mode"].string == "outline" { outlineTools }
                Menu {
                    Button(EditorText.t("字体信息", "Font information")) { controller.showCommand("font.info", preset: state["info"]) }
                    Button(EditorText.t("检查字体", "Validate font")) { controller.showCommand("font.validate") }
                    Button(EditorText.t("编译预览", "Compile preview")) { controller.runCommand("font.preview") }
                    Divider()
                    Button(EditorText.t("导出字体", "Export font")) { controller.showCommand("file.export") }
                    Button(EditorText.t("导出示字页", "Export specimen")) { controller.showCommand("specimen.export") }
                    Button(EditorText.t("合并字体", "Merge font")) { controller.requestImport("file.merge") }
                } label: { Label(EditorText.t("字体", "Font"), systemImage: "character.textbox") }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
    private var outlineTools: some View {
        HStack(spacing: 10) {
            Picker(EditorText.t("工具", "Tool"), selection: Binding(
                get: { state["ui"]["tool"].string ?? "select" },
                set: { controller.runCommand("font.ui.tool", arguments: .object(["tool": .string($0)])) })) {
                Label(EditorText.t("选择", "Select"), systemImage: "cursorarrow").tag("select")
                Label(EditorText.t("框选", "Box select"), systemImage: "rectangle.dashed").tag("marquee")
                Label(EditorText.t("平移", "Pan"), systemImage: "hand.draw").tag("pan")
                Label(EditorText.t("钢笔", "Pen"), systemImage: "pencil.tip").tag("pen")
                Label(EditorText.t("矩形", "Rectangle"), systemImage: "rectangle").tag("rectangle")
                Label(EditorText.t("椭圆", "Ellipse"), systemImage: "oval").tag("ellipse")
            }.pickerStyle(.menu).frame(minWidth: 92)
            Picker(EditorText.t("曲线", "Curve"), selection: Binding(
                get: { state["ui"]["curveType"].string ?? "line" },
                set: { controller.runCommand("font.ui.tool", arguments: .object(["curveType": .string($0)])) })) {
                Text(EditorText.t("直线", "Line")).tag("line")
                Text(EditorText.t("二次", "Quadratic")).tag("qcurve")
                Text(EditorText.t("三次", "Cubic")).tag("curve")
            }.pickerStyle(.menu).frame(minWidth: 82)
            Menu {
                ForEach([0, 1, 5, 10, 20], id: \.self) { value in
                    Button(value == 0 ? EditorText.t("无吸附", "No snapping") : "\(value)") {
                        controller.runCommand("font.ui.tool", arguments: .object(["snap": .number(Double(value))]))
                    }
                }
            } label: { Text(EditorText.t("吸附", "Snap") + ": \(Int(state["ui"]["snap"].fontNumber))") }
            Menu {
                ForEach([("point.smooth", EditorText.t("平滑节点", "Smooth points")), ("point.delete", EditorText.t("删除节点", "Delete points")), ("segment.split", EditorText.t("分割曲线", "Split curve")), ("contour.openClose", EditorText.t("开放／闭合轮廓", "Open / close contour")), ("outline.align", EditorText.t("对齐节点", "Align points")), ("glyph.transform", EditorText.t("变换", "Transform")), ("outline.removeOverlap", EditorText.t("去除重叠", "Remove overlaps"))], id: \.0) { command in
                    Button(command.1) { controller.showCommand(command.0, preset: .object(["glyph": state["glyph"]["name"]])) }
                }
            } label: { Label(EditorText.t("轮廓", "Outline"), systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
        }
    }
    private func modeTitle(_ mode: String) -> String {
        switch mode {
        case "outline": EditorText.t("轮廓", "Outlines")
        case "metrics": EditorText.t("字距", "Spacing")
        case "features": EditorText.t("特性", "Features")
        case "variations": EditorText.t("变量", "Variations")
        case "proof": EditorText.t("打样", "Proof")
        default: EditorText.t("字符集", "Characters")
        }
    }
}

@MainActor private struct FontCharacterGrid: View {
    let controller: HeavyEditorController
    private var state: EditorJSON { controller.presentation }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(state["info"]["familyName"].fontText).font(.headline)
                Spacer()
                Text("\(Int(state["glyphList"]["total"].fontNumber)) " + EditorText.t("字形", "glyphs")).foregroundStyle(.secondary)
                Button { controller.showCommand("glyph.create") } label: { Label(EditorText.t("新建", "New"), systemImage: "plus") }
            }.padding()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 10)], spacing: 10) {
                    ForEach(state["glyphList"]["items"].array, id: \.fontID) { glyph in
                        Button { controller.runCommand("font.ui.glyph", arguments: .object(["glyph": glyph["name"]])) } label: {
                            VStack(spacing: 6) {
                                FontGlyphThumbnail(glyph: glyph, info: state["info"]).frame(height: 86)
                                Text(glyph["name"].fontText).font(.caption).lineLimit(1)
                                Text(glyph["unicodes"].array.compactMap(\.number).map { String(format: "U+%04X", Int($0)) }.joined(separator: " "))
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(8).frame(maxWidth: .infinity)
                                .background(glyph["name"] == state["glyph"]["name"] ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).accessibilityLabel(glyph["name"].fontText)
                    }
                }.padding()
            }
            FontGlyphPagination(controller: controller).padding()
        }
    }
}

private struct FontGlyphThumbnail: View {
    let glyph: EditorJSON
    let info: EditorJSON
    var body: some View {
        Canvas { context, size in
            let viewport = FontViewport(size: size, info: info, glyph: glyph, margin: 10)
            let path = fontCommandPath(glyph["commands"].array, viewport: viewport)
            context.fill(path, with: .foreground, style: FillStyle(eoFill: false))
        }.overlay {
            if glyph["previewOmitted"].bool == true { Image(systemName: "square.dashed").foregroundStyle(.tertiary) }
        }.accessibilityHidden(true)
    }
}

@MainActor struct FontInspector: View {
    let controller: HeavyEditorController
    @State private var pane = "glyph"
    private var state: EditorJSON { controller.presentation }
    private var glyph: EditorJSON { state["glyph"] }
    var body: some View {
        Form {
            Section {
                Picker(EditorText.t("检查器", "Inspector"), selection: $pane) {
                    Text(EditorText.t("字形", "Glyph")).tag("glyph")
                    Text(EditorText.t("字体", "Font")).tag("font")
                    Text(EditorText.t("字距", "Kerning")).tag("kerning")
                    Text(EditorText.t("打样", "Proof")).tag("proof")
                    Text(EditorText.t("变量", "Variations")).tag("variations")
                }.pickerStyle(.menu)
            }
            switch pane {
            case "font": fontInformation
            case "kerning": FontKerningSections(controller: controller)
            case "proof": FontProofSections(controller: controller)
            case "variations": FontVariationSections(controller: controller)
            default:
                if glyph == .null { Text(EditorText.t("切换母版，或从其他母版复制字形。", "Switch masters or copy a glyph from another master.")) }
                else { glyphInformation }
            }
            Section(EditorText.t("输出", "Output")) {
                Button(EditorText.t("编译预览", "Compile preview")) { controller.runCommand("font.preview") }
                Button(EditorText.t("导出字体…", "Export font…")) { controller.showCommand("file.export") }
                Button(EditorText.t("导出示字页…", "Export specimen…")) { controller.showCommand("specimen.export") }
                if state["preview"]["hasOriginal"].bool == true {
                    Button(EditorText.t("导出导入原件", "Export imported original")) { controller.runCommand("file.export", arguments: .object(["format": .string("original")])) }
                    Text(EditorText.t("重建使用当前轮廓、字距和特性；其他原始表保留在可导出的原件中。", "Rebuilding uses current outlines, kerning and features. Other source tables remain in the exportable original.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped).onAppear { matchMode() }
            .onChange(of: state["ui"]["mode"]) { _, _ in matchMode() }
    }
    private func matchMode() {
        switch state["ui"]["mode"].string { case "metrics": pane = "kerning"; case "proof": pane = "proof"; case "variations": pane = "variations"; case "outline", "overview": pane = "glyph"; default: break }
    }
    private var glyphInformation: some View {
        Group {
            Section(glyph["name"].fontText) {
                Text(glyph["unicodes"].array.compactMap(\.number).map { String(format: "U+%04X", Int($0)) }.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                FontNumberField(title: EditorText.t("字宽", "Advance"), value: glyph["advance"].fontNumber) { value in metrics("advance", value) }
                FontNumberField(title: EditorText.t("左边距", "Left bearing"), value: glyph["bounds"]["xMin"].fontNumber) { value in metrics("left", value) }
                FontNumberField(title: EditorText.t("右边距", "Right bearing"), value: glyph["advance"].fontNumber - glyph["bounds"]["xMax"].fontNumber) { value in metrics("right", value) }
                Button(EditorText.t("字符映射…", "Character mapping…")) { controller.showCommand("glyph.encoding", preset: .object(["glyph": glyph["name"], "unicode": .string(glyph["unicodes"].fontUnicode)])) }
                Button(EditorText.t("重命名…", "Rename…")) { controller.showCommand("glyph.rename", preset: .object(["glyph": glyph["name"]])) }
                Button(EditorText.t("复制字形…", "Duplicate glyph…")) { controller.showCommand("glyph.duplicate", preset: .object(["glyph": glyph["name"]])) }
            }
            Section(EditorText.t("垂直字宽", "Vertical metrics")) {
                FontNumberField(title: EditorText.t("高度", "Advance height"), value: glyph["advanceHeight"].fontNumber) { value in vertical("advanceHeight", value) }
                FontNumberField(title: EditorText.t("原点", "Vertical origin"), value: glyph["verticalOrigin"].fontNumber) { value in vertical("verticalOrigin", value) }
            }
            Section(EditorText.t("选中节点", "Selected points")) {
                let selected = Set(state["selectedPoints"].fontStrings)
                let points = glyph["contours"].array.flatMap(\.array).filter { selected.contains($0["id"].fontText) }
                if points.isEmpty { Text(EditorText.t("点按节点或拖出选框。", "Tap a point or drag a selection box.")).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(points.prefix(4)), id: \.fontID) { point in
                    LabeledContent(point["type"].fontText, value: point["smooth"].bool == true ? EditorText.t("平滑", "Smooth") : EditorText.t("转角", "Corner"))
                    FontNumberField(title: "X", value: point["x"].fontNumber) { value in editPoint(point, key: "x", value: .number(value)) }
                    FontNumberField(title: "Y", value: point["y"].fontNumber) { value in editPoint(point, key: "y", value: .number(value)) }
                    Button(EditorText.t("节点属性…", "Point properties…")) { controller.showCommand("point.edit", preset: point.replacing("point", point["id"]).replacing("glyph", glyph["name"])) }
                }
                if !points.isEmpty {
                    Button(EditorText.t("平滑／切线…", "Smooth / tangent…")) { controller.showCommand("point.smooth", preset: .object(["glyph": glyph["name"]])) }
                    Button(EditorText.t("删除节点", "Delete points"), role: .destructive) { controller.runCommand("point.delete", arguments: .object(["glyph": glyph["name"]])) }
                }
            }
            Section(EditorText.t("锚点与组件", "Anchors & components")) {
                ForEach(Array(glyph["anchors"].array.enumerated()), id: \.offset) { _, anchor in
                    Button("\(anchor["name"].fontText) · \(Int(anchor["x"].fontNumber)), \(Int(anchor["y"].fontNumber))") { controller.showCommand("glyph.anchor", preset: anchor.replacing("glyph", glyph["name"])) }
                }
                ForEach(Array(glyph["components"].array.enumerated()), id: \.offset) { index, component in
                    Button(component["base"].fontText) { controller.showCommand("glyph.componentEdit", preset: .object(["glyph": glyph["name"], "index": .number(Double(index)), "matrix": .string(component["matrix"].array.map { String($0.fontNumber) }.joined(separator: ","))])) }
                }
                Button(EditorText.t("添加锚点…", "Add anchor…")) { controller.showCommand("glyph.anchor", preset: .object(["glyph": glyph["name"]])) }
                Button(EditorText.t("添加组件…", "Add component…")) { controller.showCommand("glyph.component", preset: .object(["glyph": glyph["name"]])) }
                if !glyph["components"].array.isEmpty { Button(EditorText.t("分解组件", "Decompose components")) { controller.runCommand("glyph.decompose", arguments: .object(["glyph": glyph["name"]])) } }
                Button(EditorText.t("添加参考线…", "Add guideline…")) { controller.showCommand("glyph.guideline", preset: .object(["glyph": glyph["name"]])) }
            }
        }
    }
    private var fontInformation: some View {
        Group {
            Section(EditorText.t("字体信息", "Font information")) {
                LabeledContent(EditorText.t("家族", "Family"), value: state["info"]["familyName"].fontText)
                LabeledContent(EditorText.t("样式", "Style"), value: state["info"]["styleName"].fontText)
                Button(EditorText.t("编辑完整信息…", "Edit font information…")) { controller.showCommand("font.info", preset: state["info"]) }
                ForEach([("unitsPerEm", EditorText.t("每 em 单位", "Units per em")), ("ascender", EditorText.t("上升线", "Ascender")), ("descender", EditorText.t("下降线", "Descender")), ("xHeight", EditorText.t("x 字高", "x-height")), ("capHeight", EditorText.t("大写字高", "Cap height"))], id: \.0) { field in
                    FontNumberField(title: field.1, value: state["info"][field.0].fontNumber) { value in controller.runCommand("font.info", arguments: state["info"].replacing(field.0, .number(value))) }
                }
                Button(EditorText.t("竖排参数…", "Vertical layout…")) { controller.showCommand("font.vertical", preset: .object(["enabled": .bool(state["info"]["openTypeVheaVertTypoAscender"].number != nil), "ascender": .number(state["info"]["openTypeVheaVertTypoAscender"].number ?? 500), "descender": .number(state["info"]["openTypeVheaVertTypoDescender"].number ?? -500), "lineGap": .number(state["info"]["openTypeVheaVertTypoLineGap"].number ?? 0)])) }
                Button(EditorText.t("字形顺序…", "Glyph order…")) { controller.showCommand("font.glyphOrder") }
                Button(EditorText.t("检查字体", "Validate font")) { controller.showCommand("font.validate") }
            }
            Section(EditorText.t("OpenType 特性", "OpenType features")) {
                Button(EditorText.t("编辑特性程序", "Edit feature source")) { controller.runCommand("font.ui.mode", arguments: .object(["mode": .string("features")])) }
                Button(EditorText.t("添加替代规则…", "Add substitution…")) { controller.showCommand("features.substitution") }
            }
        }
    }
    private func metrics(_ key: String, _ value: Double) {
        var args: [String: EditorJSON] = ["glyph": glyph["name"], "advance": glyph["advance"], "left": glyph["bounds"]["xMin"], "right": .string("")]
        args[key] = key == "right" ? .string(String(value)) : .number(value)
        controller.runCommand("metrics.edit", arguments: .object(args))
    }
    private func vertical(_ key: String, _ value: Double) {
        let args: EditorJSON = .object(["glyph": glyph["name"], "advanceHeight": glyph["advanceHeight"], "verticalOrigin": glyph["verticalOrigin"]])
        controller.runCommand("metrics.vertical", arguments: args.replacing(key, .number(value)))
    }
    private func editPoint(_ point: EditorJSON, key: String, value: EditorJSON) { controller.runCommand("point.edit", arguments: point.replacing("point", point["id"]).replacing("glyph", glyph["name"]).replacing(key, value)) }
}

@MainActor private struct FontNumberField: View {
    let title: String
    let value: Double
    let commit: (Double) -> Void
    @State private var text = ""
    @State private var submitted: Double?
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            TextField(title, text: $text).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                .frame(maxWidth: 100).focused($focused).onSubmit { submit() }
                .accessibilityLabel(title)
        }.onAppear { update() }.onChange(of: value) { _, _ in if !focused { update() } }
            .onChange(of: focused) { was, isNow in if was && !isNow { submit() }; if isNow { submitted = nil } }
    }
    private func update() { text = value.formatted(.number.precision(.fractionLength(0...3)).grouping(.never)) }
    private func submit() { guard let number = Double(text), number.isFinite else { update(); return }; if abs(number - value) > 0.000001 && submitted != number { submitted = number; commit(number) } }
}

@MainActor private struct FontKerningSections: View {
    let controller: HeavyEditorController
    private var state: EditorJSON { controller.presentation }
    var body: some View {
        Section(EditorText.t("当前母版字距", "Current master kerning")) {
            Button(EditorText.t("添加字距对…", "Add kerning pair…")) { controller.showCommand("kerning.pair") }
            ForEach(Array(state["kerning"]["pairs"].array.enumerated()), id: \.offset) { _, pair in
                FontNumberField(title: pair["left"].fontText + " · " + pair["right"].fontText, value: pair["value"].fontNumber) { value in
                    controller.runCommand("kerning.pair", arguments: pair.replacing("value", .number(value)))
                }.contextMenu {
                    Button(EditorText.t("删除字距对", "Remove pair"), role: .destructive) { controller.runCommand("kerning.pair", arguments: pair.replacing("remove", .bool(true))) }
                }
            }
            if state["kerning"]["total"].fontNumber > 240 { Text(EditorText.t("显示前 240 对；使用字距命令编辑其他对。", "Showing the first 240 pairs. Use the kerning command for another pair.")).font(.caption).foregroundStyle(.secondary) }
        }
        Section(EditorText.t("字距类", "Kerning classes")) {
            ForEach(state["kerning"]["groups"].array, id: \.fontID) { group in
                Button { controller.showCommand("kerning.group", preset: group) } label: {
                    VStack(alignment: .leading) { Text(group["name"].fontText); Text(group["glyphs"].fontText).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
            Button(EditorText.t("添加／编辑字距类…", "Add / edit class…")) { controller.showCommand("kerning.group") }
        }
    }
}

@MainActor private struct FontProofSections: View {
    let controller: HeavyEditorController
    @State private var text = ""
    @State private var size = 72.0
    @State private var language = ""
    private var state: EditorJSON { controller.presentation }
    private var ui: EditorJSON { state["ui"] }
    var body: some View {
        Section(EditorText.t("打样文本", "Proof text")) {
            TextEditor(text: $text).frame(minHeight: 90).accessibilityLabel(EditorText.t("打样文本", "Proof text"))
            Button(EditorText.t("更新文本", "Update text")) { update(["text": .string(text)]) }
            HStack { Text(EditorText.t("字号", "Size")); Slider(value: $size, in: 12...200, step: 1, onEditingChanged: { if !$0 { update(["size": .number(size)]) } }); Text("\(Int(size))").monospacedDigit() }
            TextField(EditorText.t("语言，如 zh / ar", "Language, e.g. zh / ar"), text: $language).onSubmit { update(["language": .string(language)]) }
            Picker(EditorText.t("方向", "Direction"), selection: Binding(get: { ui["direction"].string ?? "auto" }, set: { update(["direction": .string($0)]) })) {
                Text(EditorText.t("自动", "Automatic")).tag("auto"); Text(EditorText.t("从左到右", "Left to right")).tag("ltr"); Text(EditorText.t("从右到左", "Right to left")).tag("rtl")
            }
            Toggle(EditorText.t("竖排", "Vertical"), isOn: Binding(get: { ui["vertical"].bool ?? false }, set: { update(["vertical": .bool($0)]) }))
            Toggle(EditorText.t("多字号对照", "Compare sizes"), isOn: Binding(get: { ui["multisize"].bool ?? false }, set: { update(["multisize": .bool($0)]) }))
            Button(EditorText.t("编译当前字体", "Compile current font")) { controller.runCommand("font.preview") }
        }.onAppear { sync() }.onChange(of: ui["size"]) { _, _ in size = ui["size"].number ?? 72 }
            .onChange(of: ui["text"]) { old, value in if text == old.fontText { text = value.fontText } }.onChange(of: ui["language"]) { old, value in if language == old.fontText { language = value.fontText } }
        Section(EditorText.t("成形特性", "Shaping features")) {
            ForEach(["kern", "liga", "calt", "mark", "locl", "smcp"], id: \.self) { tag in
                Toggle(tag, isOn: Binding(get: { ui["previewFeatures"][tag].bool ?? false }, set: { update(["features": .object([tag: .bool($0)])]) }))
            }
        }
        if !state["axes"].array.isEmpty {
            Section(EditorText.t("变量位置", "Variation location")) {
                ForEach(state["axes"].array, id: \.fontID) { axis in FontProofAxis(controller: controller, axis: axis) }
            }
        }
    }
    private func sync() { text = ui["text"].fontText; size = ui["size"].number ?? 72; language = ui["language"].fontText }
    private func update(_ args: [String: EditorJSON]) { controller.runCommand("font.ui.proof", arguments: .object(args)) }
}

@MainActor private struct FontProofAxis: View {
    let controller: HeavyEditorController
    let axis: EditorJSON
    @State private var value = 0.0
    private var current: Double { controller.presentation["ui"]["previewLocation"][axis["tag"].fontText].number ?? axis["default"].fontNumber }
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text(axis["name"].fontText); Spacer(); Text(value.formatted(.number.precision(.fractionLength(0...1)))).font(.caption).monospacedDigit() }
            if axis["min"].fontNumber < axis["max"].fontNumber {
                Slider(value: $value, in: axis["min"].fontNumber...axis["max"].fontNumber, onEditingChanged: { editing in
                    if !editing {
                        let location = controller.presentation["ui"]["previewLocation"].replacing(axis["tag"].fontText, .number(value))
                        controller.runCommand("font.ui.proof", arguments: .object(["location": location]))
                    }
                }).accessibilityLabel(axis["name"].fontText)
            }
        }.onAppear { value = current }.onChange(of: current) { _, value in self.value = value }
    }
}

@MainActor private struct FontFeatureEditor: View {
    let controller: HeavyEditorController
    @State private var source = ""
    @State private var baseline = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(EditorText.t("OpenType 特性", "OpenType features")).font(.headline)
                Spacer()
                Button(EditorText.t("添加替代规则…", "Add substitution…")) { controller.showCommand("features.substitution") }
                Button(EditorText.t("保存特性", "Save features")) { controller.runCommand("features.edit", arguments: .object(["source": .string(source)])) }.disabled(source == baseline)
                Button(EditorText.t("编译检查", "Compile & check")) {
                    controller.runCommand("features.edit", arguments: .object(["source": .string(source)]))
                    controller.runCommand("font.preview")
                }
            }
            TextEditor(text: $source).font(.system(.body, design: .monospaced)).autocorrectionDisabled()
                .accessibilityLabel(EditorText.t("OpenType 特性程序", "OpenType feature source"))
            Text(EditorText.t("支持标准 OpenType 特性语法；编译后在打样中检查真实成形。", "Use standard OpenType feature syntax. Compile and inspect actual shaping in Proof.")).font(.caption).foregroundStyle(.secondary)
        }.padding().onAppear { source = controller.presentation["features"].fontText; baseline = source }
            .onChange(of: controller.presentation["features"]) { old, value in if source == old.fontText { source = value.fontText }; baseline = value.fontText }
    }
}

@MainActor private struct FontVariationPanel: View {
    let controller: HeavyEditorController
    var body: some View {
        Form { FontVariationSections(controller: controller) }.formStyle(.grouped)
    }
}

@MainActor private struct FontVariationSections: View {
    let controller: HeavyEditorController
    private var state: EditorJSON { controller.presentation }
    var body: some View {
        Section(EditorText.t("变量轴", "Variation axes")) {
            ForEach(state["axes"].array, id: \.fontID) { axis in
                Button { controller.showCommand("variation.axis", preset: axis.replacing("mapping", .string(axis["mapping"].array.map { $0.array.compactMap(\.number).map { String($0) }.joined(separator: ":") }.joined(separator: ",")))) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(axis["name"].fontText + " · " + axis["tag"].fontText)
                        Text("\(axis["min"].fontNumber.formatted()) … \(axis["default"].fontNumber.formatted()) … \(axis["max"].fontNumber.formatted())").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button(EditorText.t("添加变量轴…", "Add axis…")) { controller.showCommand("variation.axis") }
            if state["axisTotal"].fontNumber > Double(state["axes"].array.count) { Text(EditorText.t("更多轴可通过“添加／更新变量轴”按标签编辑。", "Edit another axis by its tag using Add / update variation axis.")).font(.caption).foregroundStyle(.secondary) }
        }
        Section(EditorText.t("母版", "Masters")) {
            ForEach(state["masters"].array, id: \.fontID) { master in
                HStack {
                    Button { controller.runCommand("font.ui.master", arguments: .object(["master": master["id"]])) } label: {
                        VStack(alignment: .leading) { Text(master["name"].fontText); Text(master["location"].fontText).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if master["id"] == state["masterID"] { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    if master["id"].string != "default" {
                        Button { controller.showCommand("variation.masterEdit", preset: master.replacing("master", master["id"])) } label: { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel(EditorText.t("编辑母版", "Edit master"))
                    }
                }
            }
            Button(EditorText.t("创建母版…", "Create master…")) { controller.showCommand("variation.master") }
            Button(EditorText.t("复制字形到母版…", "Copy glyph to master…")) { controller.showCommand("variation.copyGlyph", preset: .object(["glyph": state["glyph"]["name"]])) }
            if state["masterTotal"].fontNumber > Double(state["masters"].array.count) { Button(EditorText.t("其他母版…", "Other masters…")) { controller.showCommand("variation.masterEdit") } }
        }
        Section(EditorText.t("命名实例", "Named instances")) {
            ForEach(state["instances"].array, id: \.fontID) { instance in
                Button { controller.showCommand("variation.instance", preset: instance) } label: {
                    VStack(alignment: .leading) { Text(instance["name"].fontText); Text(instance["location"].fontText).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Button(EditorText.t("添加命名实例…", "Add named instance…")) { controller.showCommand("variation.instance") }
            Button(EditorText.t("生成静态实例…", "Generate static instance…")) { controller.showCommand("variation.generate") }
            if state["instanceTotal"].fontNumber > Double(state["instances"].array.count) { Text(EditorText.t("更多实例可通过“添加命名实例”按名称编辑。", "Edit another instance by name using Add named instance.")).font(.caption).foregroundStyle(.secondary) }
        }
        Section(EditorText.t("母版兼容性", "Master compatibility")) {
            let count = Int(state["compatibility"]["count"].fontNumber)
            Text(count == 0 ? EditorText.t("母版轮廓兼容", "Master outlines are compatible") : EditorText.t("不兼容项目：", "Incompatibilities: ") + String(count))
                .foregroundStyle(count == 0 ? Color.secondary : Color.orange)
            ForEach(Array(state["compatibility"]["issues"].array.enumerated()), id: \.offset) { _, issue in
                Button(issue["master"].fontText + " · " + issue["glyph"].fontText + " · " + issue["error"].fontText) {
                    controller.runCommand("font.ui.master", arguments: .object(["master": issue["masterID"]]))
                    controller.runCommand("font.ui.glyph", arguments: .object(["glyph": issue["glyph"]]))
                }.font(.caption)
            }
            Button(EditorText.t("完整检查结果", "Full validation results")) { controller.showCommand("variation.validate") }
        }
    }
}

@MainActor struct FontStatusBar: View {
    let controller: HeavyEditorController
    var body: some View {
        HStack {
            Text(controller.presentation["glyph"]["name"].fontText)
            Text("· \(Int(controller.presentation["glyph"]["advance"].fontNumber)) " + EditorText.t("单位", "units")).foregroundStyle(.secondary)
            Spacer()
            Text("\(controller.presentation["selectedPoints"].array.count) " + EditorText.t("个节点已选", "points selected")).foregroundStyle(.secondary)
        }.font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
    }
}

// MARK: Native font-space paths and gestures

private struct FontNode: Identifiable, Equatable {
    let id: String
    var x: Double
    var y: Double
    var type: String
    var smooth: Bool
    init(_ value: EditorJSON) { id = value["id"].fontText; x = value["x"].fontNumber; y = value["y"].fontNumber; type = value["type"].fontText; smooth = value["smooth"].bool ?? false }
    init(id: String = UUID().uuidString, x: Double, y: Double, type: String = "line", smooth: Bool = false) { self.id = id; self.x = x; self.y = y; self.type = type; self.smooth = smooth }
    var position: CGPoint { CGPoint(x: x, y: y) }
    var json: EditorJSON { .object(["id": .string(id), "x": .number(x), "y": .number(y), "type": .string(type), "smooth": .bool(smooth)]) }
}

private struct FontViewport {
    let scale: CGFloat
    let origin: CGPoint
    init(size: CGSize, info: EditorJSON, glyph: EditorJSON, margin: CGFloat = 42, zoom: CGFloat = 1, pan: CGSize = .zero) {
        let bounds = glyph["bounds"], xMin = min(-60, bounds["xMin"].fontNumber - 30), xMax = max(max(info["unitsPerEm"].number ?? 1000, glyph["advance"].fontNumber), bounds["xMax"].fontNumber + 30)
        let top = max(info["ascender"].number ?? 800, bounds["yMax"].fontNumber), bottom = min(info["descender"].number ?? -200, bounds["yMin"].fontNumber)
        scale = max(0.0001, min(max(1, size.width - margin * 2) / CGFloat(max(1, xMax - xMin)), max(1, size.height - margin * 2) / CGFloat(max(1, top - bottom)))) * zoom
        origin = CGPoint(x: margin - xMin * scale + pan.width, y: margin + top * scale + pan.height)
    }
    func screen(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y - y * scale) }
    func screen(_ point: FontNode) -> CGPoint { screen(point.x, point.y) }
    func font(_ point: CGPoint, snap: Double = 0) -> CGPoint {
        let x = (point.x - origin.x) / scale, y = (origin.y - point.y) / scale
        return snap > 0 ? CGPoint(x: (x / snap).rounded() * snap, y: (y / snap).rounded() * snap) : CGPoint(x: x, y: y)
    }
}

private func fontCommandPath(_ commands: [EditorJSON], viewport: FontViewport) -> Path {
    var path = Path()
    for c in commands {
        let end = viewport.screen(c["x"].fontNumber, c["y"].fontNumber)
        switch c["op"].string {
        case "M": path.move(to: end)
        case "L": path.addLine(to: end)
        case "Q": path.addQuadCurve(to: end, control: viewport.screen(c["x1"].fontNumber, c["y1"].fontNumber))
        case "C": path.addCurve(to: end, control1: viewport.screen(c["x1"].fontNumber, c["y1"].fontNumber), control2: viewport.screen(c["x2"].fontNumber, c["y2"].fontNumber))
        case "Z": path.closeSubpath()
        default: break
        }
    }
    return path
}

private func fontContourPath(_ contours: [[FontNode]], viewport: FontViewport) -> Path {
    var path = Path()
    for original in contours where !original.isEmpty {
        var points = original
        let closed = !points.contains { $0.type == "move" }
        if !points.contains(where: { $0.type != "offcurve" }), let a = points.last, let b = points.first {
            points.insert(FontNode(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, type: "qcurve"), at: 0)
        }
        guard let first = points.firstIndex(where: { $0.type != "offcurve" }) else { continue }
        if closed { points = Array(points[first...]) + Array(points[..<first]) }
        let start = points[0]; path.move(to: viewport.screen(start)); var controls: [FontNode] = []
        let rest = Array(points.dropFirst()) + (closed ? [start] : [])
        for end in rest {
            if end.type == "offcurve" { controls.append(end); continue }
            if end.type == "curve", controls.count == 2 {
                path.addCurve(to: viewport.screen(end), control1: viewport.screen(controls[0]), control2: viewport.screen(controls[1]))
            } else if !controls.isEmpty {
                for (index, control) in controls.enumerated() {
                    let target = index == controls.count - 1 ? end.position : CGPoint(x: (control.x + controls[index + 1].x) / 2, y: (control.y + controls[index + 1].y) / 2)
                    path.addQuadCurve(to: viewport.screen(target.x, target.y), control: viewport.screen(control))
                }
            } else { path.addLine(to: viewport.screen(end)) }
            controls.removeAll()
        }
        if closed { path.closeSubpath() }
    }
    return path
}

// Match moveGlyphPoints: translated anchors carry handles; a dragged handle
// preserves a smooth anchor's opposite tangent and its original handle length.
private func fontMoveNodes(_ original: [[FontNode]], ids: Set<String>, delta: CGPoint) -> [[FontNode]] {
    var contours = original
    for c in contours.indices {
        guard !contours[c].isEmpty else { continue }
        let count = contours[c].count
        for i in contours[c].indices {
            let point = original[c][i]
            var moves = ids.contains(point.id)
            if !moves && point.type == "offcurve" {
                let neighbors = [original[c][(i + count - 1) % count], original[c][(i + 1) % count]]
                moves = neighbors.contains { $0.type != "offcurve" && ids.contains($0.id) }
            }
            if moves { contours[c][i].x = point.x + delta.x; contours[c][i].y = point.y + delta.y }
        }
        for i in contours[c].indices where contours[c][i].type == "offcurve" && ids.contains(contours[c][i].id) {
            for offset in [-1, 1] {
                let ai = (i + offset + count) % count, oi = (i + 2 * offset + 2 * count) % count
                let anchor = contours[c][ai], opposite = contours[c][oi], handle = contours[c][i]
                if anchor.type == "offcurve" || !anchor.smooth || opposite.type != "offcurve" || ids.contains(opposite.id) || ids.contains(anchor.id) { continue }
                let length = hypot(opposite.x - anchor.x, opposite.y - anchor.y), direction = hypot(handle.x - anchor.x, handle.y - anchor.y)
                if direction > 0 { contours[c][oi].x = anchor.x - (handle.x - anchor.x) * length / direction; contours[c][oi].y = anchor.y - (handle.y - anchor.y) * length / direction }
            }
        }
    }
    return contours
}

@MainActor private struct FontOutlineCanvas: View {
    let controller: HeavyEditorController
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    @State private var draft: [[FontNode]]?
    @State private var drag: FontCanvasDrag?
    @State private var selection: Set<String> = []
    @State private var addSelection = false
    @State private var drawing: [FontNode] = []
    @State private var pinching = false
    @State private var pointerRecords: [SpatialEventCollection.Event.ID: FontOutlinePointer] = [:]
    @State private var editingPointer: SpatialEventCollection.Event.ID?
    @State private var navigation: FontOutlineNavigation?
    @State private var fingerNavigationOnly = false
    @State private var inputEpoch: UInt64 = 0
    @State private var ignoredPointers: Set<SpatialEventCollection.Event.ID> = []
    @State private var fittedGlyph: EditorJSON = .null
    @FocusState private var canvasFocused: Bool
    private var state: EditorJSON { controller.presentation }
    private var glyph: EditorJSON { state["glyph"] }
    private var contours: [[FontNode]] { glyph["contours"].array.map { $0.array.map(FontNode.init) } }
    private var tool: String { state["ui"]["tool"].string ?? "select" }
    private var fingerDrawing: Bool { state["ui"]["fingerDrawing"].bool ?? false }
    private var canvasKey: String { (state["masterID"].string ?? "default") + ":" + glyph["id"].fontText }
    var body: some View {
        GeometryReader { proxy in
            let gestureEpoch = inputEpoch
            let viewport = FontViewport(size: proxy.size, info: state["info"], glyph: fittedGlyph == .null ? glyph : fittedGlyph, zoom: zoom * magnification, pan: pan)
            Canvas { context, size in draw(context: &context, size: size, viewport: viewport) }
                .background(.background).contentShape(Rectangle())
                .focusable().focused($canvasFocused).onKeyPress { press in keyPress(press) }
                .gesture(SpatialEventGesture(coordinateSpace: .local)
                    .onChanged { events in spatial(events, viewport: viewport, size: proxy.size, epoch: gestureEpoch) }
                    .onEnded { events in spatial(events, viewport: viewport, size: proxy.size, epoch: gestureEpoch); if gestureEpoch == inputEpoch { resetPointers() } })
                .id(gestureEpoch)
                #if os(macOS)
                .simultaneousGesture(MagnificationGesture().updating($magnification) { value, state, _ in state = value }.onChanged { _ in if !pinching { cancelCurrentPointers() }; pinching = true }.onEnded { value in zoom = min(15, max(0.2, zoom * value)); pinching = false; navigation = nil })
                #endif
                .overlay(alignment: .topLeading) { canvasControls }
                .accessibilityLabel(EditorText.t("字形轮廓画布", "Glyph outline canvas"))
                .onAppear { selection = Set(state["selectedPoints"].fontStrings); fittedGlyph = glyph }
        }.clipped().onChange(of: canvasKey) { _, _ in invalidateInput(); zoom = 1; pan = .zero; drawing = []; selection = []; fittedGlyph = glyph }
            .onChange(of: state["selectedPoints"]) { _, value in if drag == nil { selection = Set(value.fontStrings) } }
            .onChange(of: tool) { _, _ in invalidateInput(); drawing = [] }
            .onChange(of: fingerDrawing) { _, _ in invalidateInput() }
    }
    private var canvasControls: some View {
        ScrollView(.horizontal) {
          HStack(spacing: 10) {
            Button { zoom = max(0.2, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel(EditorText.t("缩小", "Zoom out"))
            Button { zoom = min(15, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel(EditorText.t("放大", "Zoom in"))
            Button("\(Int(zoom * 100))%") { zoom = 1; pan = .zero; fittedGlyph = glyph }.monospacedDigit().accessibilityLabel(EditorText.t("适合画布", "Fit canvas"))
            Toggle(EditorText.t("追加选择", "Add selection"), isOn: $addSelection).toggleStyle(.button)
            Toggle(EditorText.t("手指绘图", "Finger drawing"), isOn: Binding(get: { fingerDrawing }, set: {
                controller.runCommand("font.ui.tool", arguments: .object(["fingerDrawing": .bool($0)]))
            })).toggleStyle(.button).accessibilityIdentifier("font.outline.fingerDrawing")
            Button { selection = Set(contours.flatMap { $0 }.map(\.id)); commitSelection() } label: { Image(systemName: "checkmark.square") }.accessibilityLabel(EditorText.t("全选节点", "Select all points"))
            if tool == "pen" {
                Button(EditorText.t("闭合", "Close")) { finishDrawing(closed: true) }.disabled(!canCloseDrawing)
                Button(EditorText.t("完成开放轮廓", "Finish open")) { finishDrawing(closed: false) }.disabled(!canFinishDrawing)
                Button { drawing = [] } label: { Image(systemName: "xmark") }.accessibilityLabel(EditorText.t("取消绘制", "Cancel drawing"))
            }
          }.buttonStyle(.borderless).controlSize(.small).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true).padding(10)
    }
    private var canFinishDrawing: Bool { drawing.count > 1 && drawing.last?.type != "offcurve" }
    private var canCloseDrawing: Bool { drawing.count > 1 && drawing.reversed().prefix(while: { $0.type == "offcurve" }).count <= 2 }
    private func finishDrawing(closed: Bool) { controller.runCommand("outline.addContour", arguments: .object(["glyph": glyph["name"], "points": .array(drawing.map(\.json)), "closed": .bool(closed)])); drawing = [] }
    private func commitSelection() { controller.runCommand("font.ui.points", arguments: .object(["glyph": glyph["name"], "points": .array(selection.sorted().map(EditorJSON.string))])) }
    private func draw(context: inout GraphicsContext, size: CGSize, viewport: FontViewport) {
        let current = draft ?? contours, info = state["info"]
        for (key, label) in [("ascender", EditorText.t("上升线", "Ascender")), ("descender", EditorText.t("下降线", "Descender")), ("xHeight", EditorText.t("x 字高", "x-height")), ("capHeight", EditorText.t("大写字高", "Cap height")), ("baseline", EditorText.t("基线", "Baseline"))] {
            let y = key == "baseline" ? 0 : info[key].fontNumber, position = viewport.screen(0, y)
            var path = Path(); path.move(to: CGPoint(x: 0, y: position.y)); path.addLine(to: CGPoint(x: size.width, y: position.y))
            context.stroke(path, with: .color(.secondary.opacity(key == "baseline" ? 0.6 : 0.22)), lineWidth: 1)
            context.draw(Text(label).font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: size.width - 8, y: position.y - 6), anchor: .bottomTrailing)
        }
        for x in [0.0, glyph["advance"].fontNumber] {
            let p = viewport.screen(x, 0); var path = Path(); path.move(to: CGPoint(x: p.x, y: 0)); path.addLine(to: CGPoint(x: p.x, y: size.height)); context.stroke(path, with: .color(.red.opacity(0.4)), lineWidth: 1)
        }
        for guide in glyph["guidelines"].array {
            let angle = guide["angle"].fontNumber * .pi / 180, x = guide["x"].fontNumber, y = guide["y"].fontNumber
            var path = Path(); path.move(to: viewport.screen(x - cos(angle) * 10000, y - sin(angle) * 10000)); path.addLine(to: viewport.screen(x + cos(angle) * 10000, y + sin(angle) * 10000))
            context.stroke(path, with: .color(.orange.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        var path = fontContourPath(current, viewport: viewport); path.addPath(fontCommandPath(glyph["componentCommands"].array, viewport: viewport))
        context.fill(path, with: .color(.accentColor.opacity(0.12)), style: FillStyle(eoFill: false)); context.stroke(path, with: .foreground, lineWidth: 1.25)
        for contour in current {
            for (i, point) in contour.enumerated() {
                let next = contour[(i + 1) % contour.count]
                if (point.type == "offcurve" || next.type == "offcurve") && !(next.type == "move") {
                    var handle = Path(); handle.move(to: viewport.screen(point)); handle.addLine(to: viewport.screen(next)); context.stroke(handle, with: .color(.secondary.opacity(0.65)), lineWidth: 1)
                }
            }
            for point in contour {
                let p = viewport.screen(point), frame = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                let node = point.type == "offcurve" ? Path(ellipseIn: frame) : Path(frame)
                context.fill(node, with: .color(selection.contains(point.id) ? .accentColor : .white)); context.stroke(node, with: .color(.accentColor), lineWidth: 1.5)
                if point.smooth && point.type != "offcurve" { context.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)), with: .color(.accentColor)) }
            }
        }
        for anchor in glyph["anchors"].array {
            let p = viewport.screen(anchor["x"].fontNumber, anchor["y"].fontNumber)
            context.stroke(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.orange), lineWidth: 1.5)
            context.draw(Text(anchor["name"].fontText).font(.caption2).foregroundStyle(.orange), at: CGPoint(x: p.x + 6, y: p.y - 6), anchor: .bottomLeading)
        }
        if !drawing.isEmpty {
            var preview = drawing; preview[0].type = "move"
            context.stroke(fontContourPath([preview], viewport: viewport), with: .color(.accentColor), lineWidth: 1.5)
            var pen = Path(); pen.move(to: viewport.screen(drawing[0])); for point in drawing.dropFirst() { pen.addLine(to: viewport.screen(point)) }
            context.stroke(pen, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            for point in drawing { let p = viewport.screen(point); context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.accentColor)) }
        }
        if let drag, drag.kind == "marquee" || drag.kind == "rectangle" || drag.kind == "ellipse" {
            let a = viewport.screen(drag.start.x, drag.start.y), b = viewport.screen(drag.end.x, drag.end.y), rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            let path = drag.kind == "ellipse" ? Path(ellipseIn: rect) : Path(rect)
            context.fill(path, with: .color(.accentColor.opacity(0.1))); context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
    /// SpatialEventGesture is available on iOS18+/macOS15, unlike DragGesture
    /// inputKinds (27+). It keeps the iOS26 path on the same native canvas.
    private func spatial(_ events: SpatialEventCollection, viewport: FontViewport, size: CGSize, epoch: UInt64) {
        // A recreated gesture cannot finish a draft from an older glyph,
        // master, tool or input mode. Drain retired IDs without reusing them.
        let retired = ignoredPointers
        for event in events where event.phase == .ended || event.phase == .cancelled { ignoredPointers.remove(event.id) }
        guard epoch == inputEpoch else { return }
        var terminals: [SpatialEventCollection.Event.ID: (FontOutlinePointer, Bool)] = [:]
        var fingersSeen = Set(pointerRecords.filter { $0.value.finger }.map(\.key))
        for event in events {
            if retired.contains(event.id) { continue }
            let finger = event.kind == .touch
            if finger { fingersSeen.insert(event.id) }
            let editable: Bool
            switch event.kind {
            case .pointer: editable = true
            #if os(iOS)
            case .pencil: editable = true
            #endif
            case .touch: editable = fingerDrawing
            default: editable = false
            }
            var pointer = pointerRecords[event.id] ?? FontOutlinePointer(start: event.location, location: event.location,
                finger: finger, editable: editable, timestamp: event.timestamp)
            pointer.location = event.location
            switch event.phase {
            case .active: pointerRecords[event.id] = pointer
            case .ended, .cancelled:
                terminals[event.id] = (pointer, event.phase == .cancelled); pointerRecords[event.id] = nil
            default: break
            }
        }
        let fingers = pointerRecords.filter { $0.value.finger }
        let precise = pointerRecords.filter { !$0.value.finger && $0.value.editable }
        if fingersSeen.count > 1 || !precise.isEmpty && !fingers.isEmpty { fingerNavigationOnly = true }
        guard !controller.isWorking, !pinching else { cancelCurrentPointers(); return }
        if let id = editingPointer, let (pointer, cancelled) = terminals[id] {
            if cancelled || pointer.finger && fingerNavigationOnly { cancelOutlineDrag() }
            else { ended(pointer.value, viewport: viewport) }
            editingPointer = nil
        }
        // Pencil/mouse owns its stroke; concurrent fingers cannot move its
        // viewport or become an edit after the precise pointer is lifted.
        let next = editingPointer.flatMap { id in precise[id].map { (id, $0) } }
            ?? precise.min(by: { $0.value.timestamp < $1.value.timestamp }).map { ($0.key, $0.value) }
            ?? (fingers.count == 1 && !fingerNavigationOnly ? fingers.first.flatMap { $0.value.editable ? ($0.key, $0.value) : nil } : nil)
        if let (id, pointer) = next {
            if editingPointer != id { cancelOutlineDrag(); editingPointer = id }
            navigation = nil; changed(pointer.value, viewport: viewport)
        } else if !fingers.isEmpty {
            cancelOutlineDrag(); editingPointer = nil
            let values = fingers.values.map(\.location), center = CGPoint(
                x: values.reduce(0) { $0 + $1.x } / CGFloat(values.count), y: values.reduce(0) { $0 + $1.y } / CGFloat(values.count))
            let distance = values.count > 1 ? hypot(values[0].x - values[1].x, values[0].y - values[1].y) : 0
            let ids = Set(fingers.keys)
            if navigation?.ids != ids {
                navigation = FontOutlineNavigation(ids: ids, anchor: viewport.font(center), distance: distance, zoom: zoom)
            }
            if let navigation {
                let scale = navigation.distance > 0 && distance > 0 ? distance / navigation.distance : 1
                zoom = min(15, max(0.2, navigation.zoom * scale))
                let base = FontViewport(size: size, info: state["info"], glyph: fittedGlyph == .null ? glyph : fittedGlyph, zoom: zoom)
                let anchor = base.screen(navigation.anchor.x, navigation.anchor.y)
                pan = CGSize(width: center.x - anchor.x, height: center.y - anchor.y)
            }
        } else {
            navigation = nil
        }
        if fingers.isEmpty { fingerNavigationOnly = false }
    }
    private func cancelOutlineDrag() {
        if drag != nil { selection = Set(state["selectedPoints"].fontStrings) }
        drag = nil; draft = nil
    }
    private func cancelCurrentPointers() {
        ignoredPointers.formUnion(pointerRecords.keys)
        resetPointers()
    }
    private func invalidateInput() {
        cancelCurrentPointers(); inputEpoch &+= 1
    }
    private func resetPointers() {
        cancelOutlineDrag(); pointerRecords = [:]; editingPointer = nil; navigation = nil; fingerNavigationOnly = false
    }
    private func changed(_ value: FontOutlineDragValue, viewport: FontViewport) {
        guard !controller.isWorking, !pinching else { return }
        canvasFocused = true
        let position = viewport.font(value.location, snap: state["ui"]["snap"].fontNumber)
        if drag == nil {
            let start = viewport.font(value.startLocation, snap: state["ui"]["snap"].fontNumber)
            var kind = tool
            if tool == "select" {
                let closest = contours.flatMap { $0 }.min { a, b in let pa = viewport.screen(a), pb = viewport.screen(b); return hypot(pa.x - value.startLocation.x, pa.y - value.startLocation.y) < hypot(pb.x - value.startLocation.x, pb.y - value.startLocation.y) }
                if let point = closest, hypot(viewport.screen(point).x - value.startLocation.x, viewport.screen(point).y - value.startLocation.y) <= 15 {
                    if addSelection { if selection.contains(point.id) { selection.remove(point.id) } else { selection.insert(point.id) } }
                    else if !selection.contains(point.id) { selection = [point.id] }
                    kind = "points"
                } else { kind = "pan" }
            }
            drag = FontCanvasDrag(kind: kind, start: start, end: start, pan: pan, original: contours, ids: selection)
        }
        guard var current = drag else { return }; current.end = position; drag = current
        if current.kind == "pan" { pan = CGSize(width: current.pan.width + value.translation.width, height: current.pan.height + value.translation.height) }
        if current.kind == "points" { draft = fontMoveNodes(current.original, ids: current.ids, delta: CGPoint(x: position.x - current.start.x, y: position.y - current.start.y)) }
    }
    private func ended(_ value: FontOutlineDragValue, viewport: FontViewport) {
        defer { drag = nil; draft = nil }
        guard !pinching, let current = drag else { return }
        if current.kind == "points" {
            commitSelection()
            if let draft {
                let before = Dictionary(uniqueKeysWithValues: current.original.flatMap { $0 }.map { ($0.id, $0) })
                let changes = draft.flatMap { $0 }.filter { before[$0.id]?.x != $0.x || before[$0.id]?.y != $0.y }.map { .object(["id": EditorJSON.string($0.id), "x": .number($0.x), "y": .number($0.y)]) as EditorJSON }
                if !changes.isEmpty { controller.runCommand("point.move", arguments: .object(["glyph": glyph["name"], "points": .array(changes), "follow": .bool(false)])) }
            }
        } else if current.kind == "marquee" {
            let a = current.start, b = current.end
            let ids = current.original.flatMap { $0 }.filter { $0.x >= min(a.x, b.x) && $0.x <= max(a.x, b.x) && $0.y >= min(a.y, b.y) && $0.y <= max(a.y, b.y) }.map(\.id)
            selection = addSelection ? selection.union(ids) : Set(ids); commitSelection()
        } else if current.kind == "rectangle" || current.kind == "ellipse" {
            let a = current.start, b = current.end, width = abs(a.x - b.x), height = abs(a.y - b.y)
            if width > 0 && height > 0 { controller.runCommand("outline.shape", arguments: .object(["glyph": glyph["name"], "shape": .string(current.kind), "x": .number(min(a.x, b.x)), "y": .number(min(a.y, b.y)), "width": .number(width), "height": .number(height)])) }
        } else if current.kind == "pen" {
            let curve = state["ui"]["curveType"].string ?? "line", controls = curve == "curve" ? 2 : curve == "qcurve" ? 1 : 0
            let nextType = drawing.isEmpty ? "line" : (drawing.count - 1) % (controls + 1) < controls ? "offcurve" : curve
            drawing.append(FontNode(x: current.end.x, y: current.end.y, type: nextType))
        } else if current.kind == "pan" && hypot(value.translation.width, value.translation.height) < 2 && tool == "select" && !addSelection { selection = []; commitSelection() }
    }
    private func keyPress(_ press: KeyPress) -> KeyPress.Result {
        guard !controller.isWorking else { return .ignored }
        if press.modifiers.contains(.command) && press.characters.lowercased() == "a" {
            selection = Set(contours.flatMap { $0 }.map(\.id)); commitSelection(); return .handled
        }
        if press.characters == "\u{1b}" { drawing = []; drag = nil; draft = nil; return .handled }
        if press.characters == "\r" && canCloseDrawing && tool == "pen" { finishDrawing(closed: true); return .handled }
        if press.characters == "\u{7f}" || press.characters == "\u{08}" {
            guard !selection.isEmpty else { return .ignored }
            controller.runCommand("point.delete", arguments: .object(["glyph": glyph["name"]])); return .handled
        }
        let step = press.modifiers.contains(.shift) ? 10.0 : 1.0
        let delta: CGPoint
        switch press.key {
        case .leftArrow: delta = CGPoint(x: -step, y: 0)
        case .rightArrow: delta = CGPoint(x: step, y: 0)
        case .upArrow: delta = CGPoint(x: 0, y: step)
        case .downArrow: delta = CGPoint(x: 0, y: -step)
        default: return .ignored
        }
        let points = contours.flatMap { $0 }.filter { selection.contains($0.id) }.map { point in EditorJSON.object(["id": .string(point.id), "x": .number(point.x + delta.x), "y": .number(point.y + delta.y)]) }
        guard !points.isEmpty else { return .ignored }
        controller.runCommand("point.move", arguments: .object(["glyph": glyph["name"], "points": .array(points)])); return .handled
    }
}

private struct FontOutlineDragValue {
    let startLocation: CGPoint
    let location: CGPoint
    var translation: CGSize { CGSize(width: location.x - startLocation.x, height: location.y - startLocation.y) }
}
private struct FontOutlinePointer {
    let start: CGPoint
    var location: CGPoint
    let finger: Bool
    let editable: Bool
    let timestamp: TimeInterval
    var value: FontOutlineDragValue { .init(startLocation: start, location: location) }
}
private struct FontOutlineNavigation {
    let ids: Set<SpatialEventCollection.Event.ID>
    let anchor: CGPoint
    let distance: CGFloat
    let zoom: CGFloat
}
private struct FontCanvasDrag {
    let kind: String
    let start: CGPoint
    var end: CGPoint
    let pan: CGSize
    let original: [[FontNode]]
    let ids: Set<String>
}

@MainActor private struct FontSpacingCanvas: View {
    let controller: HeavyEditorController
    @State private var text = ""
    @State private var dragIndex: Int?
    @State private var delta: CGFloat = 0
    private var state: EditorJSON { controller.presentation }
    private var spacing: [EditorJSON] { state["spacing"].array }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(EditorText.t("字距打样文本", "Spacing proof text"), text: $text).textFieldStyle(.roundedBorder).onSubmit { applyText() }
                Button(EditorText.t("更新", "Update")) { applyText() }
                Button(EditorText.t("字距对…", "Kerning pair…")) { controller.showCommand("kerning.pair") }
                Button(EditorText.t("字距类…", "Kerning class…")) { controller.showCommand("kerning.group") }
            }.padding(.horizontal)
            Text(EditorText.t("拖动字形起点线，调整当前母版中与前一字形的字距。", "Drag a glyph origin line to adjust its preceding pair in the current master.")).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            GeometryReader { proxy in
                let scale = max(0.02, min(0.35, (proxy.size.height - 100) / CGFloat(max(1, state["info"]["ascender"].fontNumber - state["info"]["descender"].fontNumber))))
                let total = spacing.last.map { $0["x"].fontNumber + $0["advance"].fontNumber } ?? 1000
                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                      Canvas { context, size in
                        let viewport = FontViewportForSpacing(info: state["info"], scale: scale)
                        var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: viewport.y(0))); baseline.addLine(to: CGPoint(x: size.width, y: viewport.y(0))); context.stroke(baseline, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                        for (index, glyph) in spacing.enumerated() {
                            let shift = dragIndex.map { index >= $0 ? delta : 0 } ?? 0
                            let origin = CGFloat(glyph["x"].fontNumber) * scale + 36 + shift
                            let vp = viewport.viewport(origin: origin)
                            let path = fontCommandPath(glyph["commands"].array, viewport: vp)
                            context.fill(path, with: .foreground)
                            var line = Path(); line.move(to: CGPoint(x: origin, y: 32)); line.addLine(to: CGPoint(x: origin, y: size.height - 30)); context.stroke(line, with: .color(dragIndex == index ? .accentColor : .red.opacity(0.45)), lineWidth: 1.5)
                            context.draw(Text(glyph["name"].fontText).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: origin + 3, y: size.height - 16), anchor: .leading)
                            if index > 0 { context.draw(Text("\(Int(glyph["kern"].fontNumber + (dragIndex == index ? Double(delta / scale) : 0)))").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: origin + 3, y: 16), anchor: .leading) }
                        }
                      }.accessibilityHidden(true)
                      ForEach(Array(spacing.enumerated()).dropFirst(), id: \.offset) { index, glyph in
                        Color.clear.frame(width: 32, height: max(160, proxy.size.height)).contentShape(Rectangle())
                            .position(x: CGFloat(glyph["x"].fontNumber) * scale + 36 + (dragIndex.map { index >= $0 ? delta : 0 } ?? 0), y: max(160, proxy.size.height) / 2)
                            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("font.spacing")).onChanged { value in dragIndex = index; delta = value.translation.width }.onEnded { value in
                                setKerning(glyph, value: (glyph["kern"].fontNumber + Double(value.translation.width / scale)).rounded()); dragIndex = nil; delta = 0
                            })
                            .accessibilityElement().accessibilityLabel(glyph["previous"].fontText + " · " + glyph["name"].fontText).accessibilityValue(String(Int(glyph["kern"].fontNumber)))
                            .accessibilityAdjustableAction { direction in
                                switch direction { case .increment: setKerning(glyph, value: glyph["kern"].fontNumber + 10); case .decrement: setKerning(glyph, value: glyph["kern"].fontNumber - 10); @unknown default: break }
                            }
                      }
                    }.frame(width: max(proxy.size.width, CGFloat(total) * scale + 100), height: max(160, proxy.size.height)).coordinateSpace(name: "font.spacing")
                        .accessibilityLabel(EditorText.t("字距画布", "Spacing canvas"))
                }
            }
            Button(EditorText.t("查看真实成形打样", "View shaped proof")) { controller.runCommand("font.ui.mode", arguments: .object(["mode": .string("proof")])) }.padding()
        }.padding(.top).onAppear { text = state["ui"]["text"].fontText }.onChange(of: state["ui"]["text"]) { old, value in if text == old.fontText { text = value.fontText } }
    }
    private func applyText() { controller.runCommand("font.ui.proof", arguments: .object(["text": .string(text)])) }
    private func setKerning(_ glyph: EditorJSON, value: Double) { controller.runCommand("kerning.pair", arguments: .object(["left": glyph["previous"], "right": glyph["name"], "value": .number(value)])) }
}

private struct FontViewportForSpacing {
    let info: EditorJSON
    let scale: CGFloat
    func y(_ value: Double) -> CGFloat { 48 + CGFloat(info["ascender"].fontNumber - value) * scale }
    func viewport(origin: CGFloat) -> FontViewport { FontViewport(scale: scale, origin: CGPoint(x: origin, y: y(0))) }
}

private extension FontViewport {
    init(scale: CGFloat, origin: CGPoint) { self.scale = scale; self.origin = origin }
}
