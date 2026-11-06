// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloePrintCore
import UniformTypeIdentifiers

struct PrintProjectView: View {
    @Bindable var session: PrintProjectSession
    @State private var importing = false

    var body: some View {
        Form {
            Section(IDELanguageRunText.t("模型", "Model")) {
                if session.triangleCount > 0 {
                    PrintMeshPreview(disk: session.disk, document: session.document)
                    LabeledContent(IDELanguageRunText.t("三角面", "Triangles"), value: session.triangleCount.formatted())
                }
                Button(IDELanguageRunText.t("导入 STL", "Import STL"), systemImage: "square.and.arrow.down") { importing = true }
                    .accessibilityIdentifier("printing.import")
                Button(IDELanguageRunText.t("添加 20 mm 立方体", "Add a 20 mm cube"), systemImage: "cube") {
                    Task { await session.addCube() }
                }.accessibilityIdentifier("printing.cube")
            }.disabled(session.isBusy)
            Section(IDELanguageRunText.t("切片设置", "Slicing settings")) {
                Picker(IDELanguageRunText.t("配置", "Profile"), selection: $session.preset) {
                    Text(IDELanguageRunText.t("通用 FDM · PLA", "Generic FDM · PLA")).tag(PrintPreset.genericMarlinPLA)
                    Text(IDELanguageRunText.t("通用树脂 · CTB v3", "Generic resin · CTB v3")).tag(PrintPreset.genericCTBV3)
                }
                HStack {
                    Text(IDELanguageRunText.t("层高（mm）", "Layer height (mm)"))
                    Spacer()
                    TextField("mm", value: $session.layerHeight, format: .number)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 120)
                        .accessibilityIdentifier("printing.layerHeight")
                }
                let bed = session.preset.bed
                LabeledContent(IDELanguageRunText.t("成型尺寸（mm）", "Build volume (mm)"),
                    value: "\(Int(bed.width)) × \(Int(bed.depth)) × \(Int(bed.height))")
            }.disabled(session.isBusy)
            Section {
                if session.isBusy {
                    ProgressView(value: session.progress) {
                        Text(session.isCancelling ? IDELanguageRunText.t("正在停止", "Stopping")
                            : IDELanguageRunText.t("正在切片", "Slicing"))
                    }.accessibilityIdentifier("printing.progress")
                    Button(IDELanguageRunText.t("停止", "Stop"), role: .destructive) { session.cancel() }
                        .disabled(session.isCancelling)
                } else {
                    Button(IDELanguageRunText.t("切片", "Slice"), systemImage: "play.fill") { session.slice() }
                        .disabled(session.triangleCount == 0)
                        .accessibilityIdentifier("printing.slice")
                }
                if let url = session.result {
                    Label(session.preset == session.document.preset && session.layerHeight == session.document.layerHeight
                        ? IDELanguageRunText.t("结果已保存", "Result saved")
                        : IDELanguageRunText.t("上次结果已保存；设置已改变，请重新切片", "Previous result saved. Slice again to apply changed settings."),
                        systemImage: "checkmark.circle")
                    if let layers = session.document.resultLayerCount {
                        LabeledContent(IDELanguageRunText.t("层数", "Layers"), value: layers.formatted())
                    }
                    ShareLink(item: url) { Label(IDELanguageRunText.t("导出结果", "Export result"), systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("printing.export")
                }
                if let diagnostic = session.diagnostic {
                    Label(IDELanguageRunText.t("切片未完成", "Slicing did not finish"), systemImage: "exclamationmark.triangle")
                    DisclosureGroup(IDELanguageRunText.t("详情", "Details")) { Text(diagnostic).textSelection(.enabled) }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "stl") ?? .data]) { result in
            switch result {
            case .success(let url): Task { await session.importSTL(url) }
            case .failure(let error): session.diagnostic = error.localizedDescription
            }
        }
    }
}
#endif
