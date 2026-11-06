// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import simd

/// A small drafting context over the existing viewport and command bars.
/// Geometry, revisions, undo and native source files keep their current owner.
struct CAD2DDraftingBar: View {
    let document: FloeCADDocument
    @Bindable private var settings = CADPreferences.shared
    @State private var showSketches = false
    @State private var showCurve = false
    private var model: EditorViewModel { document.viewModel() }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button { document.activate2DWorkspace() } label: { Label(text("平面", "Plan"), systemImage: "square.grid.3x3").frame(minHeight: 44) }
                Divider().frame(height: 22)
                Menu {
                    draw(text("直线", "Line"), .line)
                    draw(text("矩形", "Rectangle"), .rect)
                    draw(text("圆", "Circle"), .circle)
                    draw(text("圆弧", "Arc"), .arc)
                    draw(text("椭圆", "Ellipse"), .ellipse)
                    draw(text("多边形", "Polygon"), .polygon)
                    Button(text("拟合曲线", "Fit spline")) { ensureSketch(); showCurve = true }
                    draw(text("文字", "Text"), .text)
                } label: { Label(text("绘制", "Draw"), systemImage: "pencil.tip").frame(minHeight: 44) }.disabled(document.isReadOnly)
                Menu {
                    Button(text("修剪", "Trim")) { edit(.trim) }
                    Button(text("延伸", "Extend")) { edit(.extend) }
                    Button(text("偏移", "Offset")) { ensureSketch(); model.startSketch(tool: .offset) }
                    Button(text("移动/旋转", "Move/Rotate")) { ensureSketch(); model.deselectSketchTool(); model.sketchCopyOnDrag = false; model.sketchTransformActive = true }
                    Button(text("复制", "Copy")) { ensureSketch(); model.deselectSketchTool(); model.sketchTransformActive = true; model.sketchCopyOnDrag = true }
                } label: { Label(text("修改", "Modify"), systemImage: "scissors").frame(minHeight: 44) }.disabled(document.isReadOnly)
                Button { model.beginDimensionForSelection() } label: { Label(text("尺寸", "Dimension"), systemImage: "ruler").frame(minHeight: 44) }.disabled(document.isReadOnly || !model.canDimensionSelection)
                Button { showSketches = true } label: { Label(text("草图", "Sketches"), systemImage: "square.3.layers.3d").frame(minHeight: 44) }
                Menu {
                    Toggle(text("网格捕捉", "Grid snap"), isOn: $settings.snapToGrid)
                    Toggle(text("端点/圆心捕捉", "Sketch point snap"), isOn: $settings.snapToSketchGuidepoints)
                    Toggle(text("参考线", "Guide lines"), isOn: $settings.snapToSketchGuidelines)
                    Toggle(text("捕捉提示", "Snap hints"), isOn: $settings.showSnapHints)
                } label: { Label(text("捕捉", "Snap"), systemImage: "scope").frame(minHeight: 44) }
                Menu {
                    ForEach(DisplayUnit.allCases, id: \.self) { unit in Button(unit.symbol) { settings.unit = unit } }
                } label: { Text(settings.unit.symbol).font(.callout.monospacedDigit()).frame(minWidth: 44, minHeight: 44) }
                Button { model.fitView() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44) }.accessibilityLabel(text("适应图纸", "Fit drawing"))
            }.font(.callout).buttonStyle(.borderless).padding(.horizontal, 10)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .bottom) { Divider() }
        .sheet(isPresented: $showSketches) { sketchSheet }
        .sheet(isPresented: $showCurve) { CAD2DFitSplineSheet(document: document) }
        .accessibilityIdentifier("CAD2DDraftingBar")
    }
    private func ensureSketch() { if model.activeSketch == nil { document.activate2DWorkspace() } }
    private func draw(_ title: String, _ tool: SketchTool) -> some View {
        Button(title) { ensureSketch(); model.startSketch(tool: tool) }.disabled(document.isReadOnly)
    }
    private func edit(_ kind: SketchCurveEditKind) {
        ensureSketch(); model.sketchCurveEditKind = kind; model.startSketch(tool: .trim)
    }
    private var sketchSheet: some View {
        NavigationStack {
            List {
                ForEach(document.session.document.sketches, id: \.id) { sketch in
                    HStack {
                        Button { model.openItemSketch(sketch.id); model.requestDraftingCamera(for: sketch.plane); showSketches = false } label: {
                            HStack { Text(sketch.name); Spacer(); if model.activeSketch?.id == sketch.id { Image(systemName: "checkmark") } }.frame(minHeight: 44)
                        }
                        Button { model.setItemHidden(.sketch(sketch.id), hidden: !sketch.isHidden) } label: { Image(systemName: sketch.isHidden ? "eye.slash" : "eye").frame(width: 44, height: 44) }.buttonStyle(.borderless)
                            .disabled(document.isReadOnly)
                            .accessibilityLabel(sketch.isHidden ? text("显示草图", "Show sketch") : text("隐藏草图", "Hide sketch"))
                    }
                }
                Button(text("新建草图", "New sketch"), systemImage: "plus") {
                    let sketch = Sketch(name: text("草图", "Sketch") + " \(document.session.document.sketches.count + 1)", plane: model.activeSketch?.plane ?? .worldXY)
                    document.session.perform(AddSketchCommand(sketch: sketch, title: text("新建草图", "New sketch")))
                    model.openItemSketch(sketch.id); model.requestDraftingCamera(for: sketch.plane); showSketches = false
                }.disabled(document.isReadOnly).frame(minHeight: 44)
            }
            .navigationTitle(text("草图", "Sketches")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(text("完成", "Done")) { showSketches = false } } }
        }.presentationDetents([.medium, .large])
    }
    private func text(_ zh: String, _ en: String) -> String { CAD2DDraftingText.text(zh, en) }
}

private struct CAD2DFitSplineSheet: View {
    let document: FloeCADDocument
    @Environment(\.dismiss) private var dismiss
    private struct PointDraft: Identifiable { let id = UUID(); var x: Double; var y: Double }
    @State private var points = [PointDraft(x: 0, y: 0), PointDraft(x: 10, y: 10), PointDraft(x: 20, y: 0)]
    @State private var closed = false
    @State private var base: Int?
    @State private var unit = DisplayUnit.millimeters
    @State private var diagnostic: String?
    var body: some View {
        NavigationStack {
            Form {
                Section(text("通过点", "Fit points") + " · " + unit.symbol) {
                    ForEach($points) { $point in
                        HStack {
                            Text("X").font(.caption)
                            TextField("X", value: $point.x, format: .number).keyboardType(.numbersAndPunctuation)
                            Text("Y").font(.caption)
                            TextField("Y", value: $point.y, format: .number).keyboardType(.numbersAndPunctuation)
                        }
                    }.onDelete { offsets in if points.count - offsets.count >= 2 { points.remove(atOffsets: offsets) } }
                    Button(text("添加点", "Add point"), systemImage: "plus") { let last = points.last!; points.append(.init(x: last.x + 10, y: last.y)) }.disabled(points.count >= 256)
                    Toggle(text("闭合曲线", "Closed spline"), isOn: $closed)
                }
                if let diagnostic { Text(diagnostic).font(.caption).foregroundStyle(.orange) }
            }
            .navigationTitle(text("拟合曲线", "Fit spline")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(text("取消", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(text("应用", "Apply")) { apply() }.disabled(document.isReadOnly) }
            }
            .onAppear { if base == nil { base = document.session.changeCount; unit = CADPreferences.shared.unit } }
        }
    }
    private func apply() {
        let session = document.session, model = document.viewModel()
        guard let sketch = model.activeSketch, base == session.changeCount,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { diagnostic = text("图纸或参数已改变，请重新打开。", "The drawing or parameters changed. Open this panel again."); return }
        let entity = SketchEntity.spline(id: UUID(), points: points.map { SIMD2(unit.mm(fromDisplay: $0.x), unit.mm(fromDisplay: $0.y)) }, closed: closed)
        do {
            _ = try SketchCurveDefinition(entity)
            let command = AddSketchEntitiesCommand(sketchID: sketch.id, entities: [entity], title: text("拟合曲线", "Fit spline"))
            guard session.performWithSketchRebuild(command, sketchID: sketch.id) else { diagnostic = text("曲线未能提交，原图保持不变。", "The spline could not be committed. The drawing is unchanged."); return }
            dismiss()
        } catch { diagnostic = text("请检查通过点的位置。", "Check the fit point positions.") }
    }
    private func text(_ zh: String, _ en: String) -> String { CAD2DDraftingText.text(zh, en) }
}

private enum CAD2DDraftingText {
    static func text(_ zh: String, _ en: String) -> String {
        // Use the host's resolved language, including its in-App override.
        let marker = FloeCADStrings.text("cad.ui.common.done", "Done")
        let chinese = marker.unicodeScalars.contains { (0x3400...0x9FFF).contains(Int($0.value)) }
        return chinese ? zh : en
    }
}
