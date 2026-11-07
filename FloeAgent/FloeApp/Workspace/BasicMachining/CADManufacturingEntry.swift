// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCAD
import FloeManufacturingCore
import FloeManufacturingUI
import FloeWorkspace

/// A host action inside the CAD editor. Printing and subtractive machining
/// retain their existing service/session owners underneath this common entry.
@MainActor
struct CADManufacturingEntry: ViewModifier {
    let document: FloeCADDocument
    var directory: URL? = nil
    var ownerID: UUID? = nil
    var available = true
    var offered = true
    let onPreparePrint: () -> Void
    var onAssistant: (() -> Void)? = nil
    @Environment(\.cadWorkbenchTransientlyCovered) private var alreadyCovered
    @State private var presented = false
    @State private var afterClose: Followup?
    private enum Followup: Equatable { case printing, assistant }
    func body(content: Content) -> some View {
        content
            .environment(\.cadWorkbenchTransientlyCovered, alreadyCovered || presented)
            .toolbar {
                if offered { Button(IDELanguageRunText.t("加工", "Manufacture"), systemImage: "gearshape.2") { presented = true }
                    .disabled(!available || document.isClosed || document.isReadOnly)
                    .accessibilityIdentifier("cad.manufacturing.open") }
            }
            .sheet(isPresented: $presented, onDismiss: {
                let action = afterClose; afterClose = nil
                if action == .printing { onPreparePrint() }
                else if action == .assistant { onAssistant?() }
            }) {
                CADManufacturingHome(document: document, directory: directory ?? Self.workspaceDirectory(document), ownerID: ownerID,
                    onPrint: { afterClose = .printing; presented = false },
                    onAssistant: onAssistant == nil ? nil : { afterClose = .assistant; presented = false })
            }
            .onChange(of: document.isClosed) { _, closed in if closed { presented = false; afterClose = nil } }
    }
    static func workspaceDirectory(_ document: FloeCADDocument) -> URL {
        CADMachiningCompanion.directory(forCADURL:document.url)
    }
}

@MainActor
private struct CADManufacturingHome: View {
    let document: FloeCADDocument
    let directory: URL
    let ownerID: UUID?
    let onPrint: () -> Void
    var onAssistant: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(document.name, systemImage: "cube")
                    Text(IDELanguageRunText.t("使用当前 CAD 模型，所有零件保持模型坐标。", "Uses the current CAD model with every part in its model coordinates."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(IDELanguageRunText.t("加工方式", "Manufacturing process")) {
                    Button(action: onPrint) { Label(IDELanguageRunText.t("3D 打印", "3D Printing"), systemImage: "printer") }
                        .accessibilityIdentifier("cad.manufacturing.printing")
                    NavigationLink {
                        CADCuttingSetupView(document: document, directory: directory, ownerID: ownerID, onAssistant: onAssistant)
                    } label: { Label(IDELanguageRunText.t("切削加工", "Machining"), systemImage: "wrench.and.screwdriver") }
                        .accessibilityIdentifier("cad.manufacturing.cutting")
                }
            }
            .navigationTitle(IDELanguageRunText.t("加工", "Manufacture"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(IDELanguageRunText.t("完成", "Done")) { dismiss() }
            } }
        }
    }
}

@MainActor
private struct CADCuttingSetupView: View {
    let document: FloeCADDocument
    let directory: URL
    let ownerID: UUID?
    var onAssistant: (() -> Void)?
    @State private var model: ManufacturingModel?
    @State private var kind: ManufacturingMachineSetup.Kind = .milling3Axis
    @State private var problem: String?
    @State private var loading = false
    @State private var workbench: WorkbenchRequest?
    @State private var assistantAfterClose = false
    @State private var preparingWorkbench: Task<Void,Never>?
    private struct WorkbenchRequest: Identifiable { let id = UUID(); let model: ManufacturingModel; let storageLease: AnyObject }
    var body: some View {
        Form {
            Section(IDELanguageRunText.t("机床类型", "Machine type")) {
                Picker(IDELanguageRunText.t("类型", "Type"), selection: $kind) {
                    Text(IDELanguageRunText.t("数控车床", "CNC lathe")).tag(ManufacturingMachineSetup.Kind.lathe)
                    Text(IDELanguageRunText.t("三轴铣床", "3-axis mill")).tag(ManufacturingMachineSetup.Kind.milling3Axis)
                    Text(IDELanguageRunText.t("A/C 五轴铣床", "A/C 5-axis mill")).tag(ManufacturingMachineSetup.Kind.milling5AxisAC)
                    Text(IDELanguageRunText.t("车铣复合（单主轴）", "Single-spindle turn-mill")).tag(ManufacturingMachineSetup.Kind.turnMill)
                }.accessibilityIdentifier("cad.manufacturing.machine")
                if kind == .milling5AxisAC {
                    Text(IDELanguageRunText.t("采用相交 A/C 转台；其他五轴结构可在后续机床设置中扩展。", "Uses an intersecting A/C table. Other 5-axis layouts require their own machine definition."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if kind == .lathe || kind == .turnMill {
                    Text(IDELanguageRunText.t("车削轴为模型 Z 轴。初始型线来自模型的径向外包络，请先检查型线与装夹。", "The model Z axis is the turning axis. The initial profile is the model's radial envelope; check the profile and clamping first."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                if loading { ProgressView(IDELanguageRunText.t("正在准备模型", "Preparing model")) }
                if let model {
                    LabeledContent(IDELanguageRunText.t("模型", "Model"), value: model.study.name)
                    Button(IDELanguageRunText.t("继续：毛坯与工序", "Continue to stock and operations"), action: openWorkbench)
                        .disabled(loading || model.isBusy).accessibilityIdentifier("cad.manufacturing.continue")
                    Button(IDELanguageRunText.t("从当前 CAD 更新模型", "Update from current CAD")) {
                        Task { await refresh(model) }
                    }.disabled(loading || model.isBusy).accessibilityIdentifier("cad.manufacturing.refresh")
                    Text(IDELanguageRunText.t("已有工序随本 CAD 文档保存。修改模型后，更新加工模型并重新生成刀路。", "Operations are saved with this CAD document. After changing the model, update the machining model and regenerate toolpaths."))
                        .font(.footnote).foregroundStyle(.secondary)
                } else if !loading {
                    Button(IDELanguageRunText.t("重新准备模型", "Prepare model again")) { Task { await load() } }
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }
        .navigationTitle(IDELanguageRunText.t("切削加工", "Machining"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { preparingWorkbench?.cancel(); preparingWorkbench = nil }
        .fullScreenCover(item: $workbench, onDismiss: {
            if assistantAfterClose { assistantAfterClose = false; onAssistant?() }
        }) { request in
                ManufacturingWorkbenchView(model: request.model, hostedInCAD: true, beforeCalculate: {
                    try await ManufacturingSessions.validateCADSource(document: document, model: request.model, ownerID: ownerID)
                }, onClose: {
                    do { try request.model.saveDraft(); workbench = nil } catch { request.model.report(error) }
                }, onAssistant: onAssistant == nil ? nil : { assistantAfterClose = true; workbench = nil })
        }
    }
    private func load() async {
        guard model == nil, !loading else { return }
        loading = true; defer { loading = false }; problem = nil
        do {
            let value = try await ManufacturingSessions.openCAD(document: document, directory: directory, ownerID: ownerID)
            try Task.checkCancellation(); model = value
            if let selected = value.study.machineSetup?.kind { kind = selected }
        } catch { if !Task.isCancelled { problem = error.localizedDescription } }
    }
    private func refresh(_ model: ManufacturingModel) async {
        loading = true; defer { loading = false }; problem = nil
        do { try await ManufacturingSessions.refreshCAD(document: document, model: model, ownerID: ownerID) }
        catch { if !Task.isCancelled { problem = error.localizedDescription } }
    }
    private func openWorkbench() {
        guard let model, !document.isClosed, !loading else { return }
        let selectedKind = kind
        loading = true; problem = nil
        preparingWorkbench = Task { @MainActor in
            defer { loading = false; preparingWorkbench = nil }
            do {
                try await ManufacturingSessions.validateCADSource(document: document, model: model, ownerID: ownerID)
                try Task.checkCancellation()
                guard kind == selectedKind else { throw ManufacturingError.stale }
                if model.study.machineSetup?.kind != selectedKind {
                    let b = model.study.stock.bounds
                    let frame = ManufacturingCAM.Frame(originMM: [(b.min[0]+b.max[0])/2, (b.min[1]+b.max[1])/2, b.max[2]])
                    let value = try model.study.applyingMachineSetup(.init(kind: selectedKind, coordinateFrame: frame))
                    try model.replaceStudy(value, expectedFingerprint: model.study.fingerprint())
                }
                try model.saveDraft()
                let lease = try CADMachiningCompanion.storageLease(cadURL:document.url,directory:directory)
                workbench = .init(model:model,storageLease:lease)
            } catch { if !Task.isCancelled { problem = error.localizedDescription } }
        }
    }
}
#endif
