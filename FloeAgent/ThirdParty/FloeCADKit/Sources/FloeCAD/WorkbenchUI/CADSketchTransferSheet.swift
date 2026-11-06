// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// SolidWorks-style bounded 2D-to-3D aid: select a view group in 2D, choose
/// its destination plane and matching reference point. It does not infer a
/// solid or reconstruct an arbitrary multi-view drawing.
struct CADSketchTransferSheet: View {
    let source: CADSketchTransferEnvelope
    let hasSelection: Bool
    let onImport: (CADSketchTransferPlacement) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var target: CADSketchTransferPlacement.Target
    @State private var scale: Double
    @State private var anchorX = 0.0
    @State private var anchorY = 0.0
    @State private var offsetX = 0.0
    @State private var offsetY = 0.0
    @State private var rotation = 0.0
    @State private var acceptOmissions = false
    @State private var error: String?
    init(source: CADSketchTransferEnvelope, hasSelection: Bool,
         onImport: @escaping (CADSketchTransferPlacement) throws -> Void) {
        self.source = source; self.hasSelection = hasSelection; self.onImport = onImport
        _target = State(initialValue: hasSelection ? .selected : .front)
        _scale = State(initialValue: source.snapshot.unitScaleMM ?? 0)
    }
    private func t(_ zh: String, _ en: String) -> String { locale.identifier.hasPrefix("zh") ? zh : en }
    var body: some View {
        NavigationStack {
            Form {
                Section(t("图纸", "Drawing")) {
                    Text(source.sourceName)
                    LabeledContent(t("曲线", "Curves"), value: String(source.snapshot.curves.count))
                    LabeledContent(t("原图单位", "Source units"), value: source.snapshot.unitName)
                    Picker(t("导入单位", "Import units"), selection: $scale) {
                        if source.snapshot.unitScaleMM == nil { Text(t("请选择单位", "Choose units")).tag(0.0) }
                        if let original = source.snapshot.unitScaleMM, ![1.0,10.0,1000.0,25.4,304.8].contains(original) { Text(t("按原图单位", "Use source units")).tag(original) }
                        Text(t("毫米", "Millimeters")).tag(1.0)
                        Text(t("厘米", "Centimeters")).tag(10.0)
                        Text(t("米", "Meters")).tag(1000.0)
                        Text(t("英寸", "Inches")).tag(25.4)
                        Text(t("英尺", "Feet")).tag(304.8)
                    }
                }
                Section(t("草图平面", "Sketch plane")) {
                    Picker(t("目标平面", "Destination"), selection: $target) {
                        if hasSelection { Text(t("已选草图／平面／面", "Selected sketch / plane / face")).tag(CADSketchTransferPlacement.Target.selected) }
                        Text(t("正视图", "Front")).tag(CADSketchTransferPlacement.Target.front)
                        Text(t("顶视图", "Top")).tag(CADSketchTransferPlacement.Target.top)
                        Text(t("右视图", "Right")).tag(CADSketchTransferPlacement.Target.right)
                        Text(t("原图平面", "Source plane")).tag(CADSketchTransferPlacement.Target.source)
                    }
                    Text(t("分别选择正、顶、侧视图，设置对应参考点和偏移，即可将多视图对齐到不同草图平面。", "Select front, top and side view groups separately, then use matching reference points and offsets to align their sketches."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(t("参考点与对齐", "Reference point and alignment")) {
                    number(t("原图参考 X", "Source reference X"), $anchorX)
                    number(t("原图参考 Y", "Source reference Y"), $anchorY)
                    number(t("目标偏移 X（毫米）", "Destination X (mm)"), $offsetX)
                    number(t("目标偏移 Y（毫米）", "Destination Y (mm)"), $offsetY)
                    number(t("旋转角度", "Rotation (degrees)"), $rotation)
                }
                if !source.snapshot.omissions.isEmpty {
                    Section(t("未导入内容", "Omitted content")) {
                        Text(t("原文件会保留。以下对象不会成为可编辑草图曲线。", "The original file is retained. These objects will not become editable sketch curves."))
                        ForEach(Array(source.snapshot.omissions.prefix(50).enumerated()), id: \.offset) { _, omission in
                            Text("\(omission.entityType) · \(omission.layer) · \(omission.handle)").font(.caption)
                        }
                        Toggle(t("接受这些遗漏", "Accept these omissions"), isOn: $acceptOmissions)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(t("转三维草图", "Create 3D sketch"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(t("取消", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("导入", "Import")) {
                        do {
                            try onImport(CADSketchTransferPlacement(target: target, sourceAnchor: [anchorX, anchorY],
                                offsetMM: [offsetX, offsetY], rotationDegrees: rotation, unitScaleMM: scale,
                                acceptOmissions: acceptOmissions))
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(scale <= 0 || (!source.snapshot.omissions.isEmpty && !acceptOmissions))
                }
            }
        }
        .accessibilityIdentifier("CADSketchTransferSheet")
    }
    private func number(_ label: String, _ value: Binding<Double>) -> some View {
        HStack { Text(label); Spacer(); TextField(label, value: value, format: .number).multilineTextAlignment(.trailing).frame(maxWidth: 160).keyboardType(.numbersAndPunctuation) }
    }
}
