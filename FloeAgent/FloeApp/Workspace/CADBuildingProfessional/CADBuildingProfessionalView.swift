// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeCAD
import FloeCore

@MainActor
struct CADBuildingProfessionalView: View {
    let document: FloeCADDocument
    let action: CADBuildingProfessionalAction
    let root: URL?
    let workspaceID: UUID?
    let conversationID: UUID?
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var structural = CADBuildingStructuralSettings()
    @State private var beams: [CADBuildingElement] = []
    @State private var inputsConfirmed = false
    @State private var operation: CADBuildingProfessionalOperation?
    @State private var starting = false
    @State private var cancelling = false
    @State private var message: String?
    @State private var artifacts: [URL] = []
    private func t(_ zh: String, _ en: String) -> String { FloeL10n.isChinese ? zh : en }
    private var title: String {
        switch action {
        case .ifc: t("导出 IFC", "Export IFC")
        case .structure: t("梁结构校核", "Beam analysis")
        case .mep: t("机电碰撞检查", "MEP coordination")
        case .information: t("信息要求检查", "Information requirements")
        }
    }
    private var structuralValid: Bool {
        structural.memberID != nil && inputsConfirmed && structural.elasticModulusNPerMM2.isFinite
            && (1...1e7).contains(structural.elasticModulusNPerMM2)
            && structural.poissonRatio.isFinite && (0..<0.5).contains(structural.poissonRatio)
            && structural.lineLoadNPerMM.isFinite && (0.000001...1e6).contains(structural.lineLoadNPerMM)
    }
    private var canStart: Bool {
        root != nil && workspaceID != nil && conversationID != nil && !starting
            && operation?.isRunning != true && (action != .structure || structuralValid)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(introduction).font(.callout).foregroundStyle(.secondary)
                    Text(t("在当前任务选择的 Linux 环境中运行，首次使用会安装计算组件。", "Runs in this task’s selected Linux environment. The first run installs its calculation components."))
                        .font(.caption).foregroundStyle(.secondary)
                    if root == nil || workspaceID == nil || conversationID == nil {
                        Text(t("请从任务工作区打开建筑模型，并选择 Linux 执行环境。", "Open the building from a task workspace and select a Linux execution environment."))
                    }
                }
                if action == .structure { structuralInputs.disabled(starting || operation?.isRunning == true) }
                Section {
                    if starting || operation?.isRunning == true {
                        HStack {
                            ProgressView()
                            Text(operation?.state == .cancelling ? t("正在取消…", "Cancelling…") : t("正在准备并计算…", "Preparing and calculating…"))
                            Spacer()
                            if let operation {
                                Button(t("取消", "Cancel"), role: .destructive) { cancel(operation.id) }.disabled(cancelling)
                            }
                        }.accessibilityIdentifier("cad.building.professional.progress")
                    } else {
                        Button(title, systemImage: "play.fill") { start() }
                            .disabled(!canStart).accessibilityIdentifier("cad.building.professional.start")
                    }
                    if let operation {
                        LabeledContent(t("状态", "Status"), value: stateTitle(operation.state))
                        if operation.state == .ready {
                            Text(t("结果对应此次计算启动时保存的模型。", "These results use the saved model captured when this study started."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let message {
                        Text(t("未能完成本次计算，请检查执行环境与输入。", "The study could not complete. Check its execution environment and inputs.")).foregroundStyle(.red)
                        DisclosureGroup(t("错误详情", "Error details")) { Text(message).font(.caption).textSelection(.enabled) }
                    }
                }
                if let result = operation?.result, operation?.state == .ready {
                    resultSections(result)
                    if !artifacts.isEmpty {
                        Section(t("文件", "Files")) {
                            ForEach(artifacts, id: \.self) { url in
                                ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up") }
                            }
                        }
                    }
                    Section {
                        DisclosureGroup(t("计算详情", "Calculation details")) {
                            ForEach(result.backendVersions.keys.sorted(), id: \.self) { key in LabeledContent(key, value: result.backendVersions[key] ?? "") }
                            LabeledContent(t("源版本", "Source revision"), value: "\(result.sourceRevision)")
                            LabeledContent(t("显示三角形", "Display triangles"), value: "\(result.triangles)")
                        }
                    }
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(t("完成", "Done")) { dismiss() } } }
            .onAppear {
                do { beams = try document.building()?.elements.filter { $0.kind == .beam } ?? [] }
                catch { message = error.localizedDescription }
            }
            .task(id: operation?.id) {
                if operation == nil, let root, let conversationID {
                    operation = environment.buildingProfessionalCenter.latest(documentURL: document.url, action: action, root: root, conversationID: conversationID)
                }
                while !Task.isCancelled, let current = operation {
                    await refresh()
                    if !current.isRunning { break }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                }
            }
        }
    }
    private var introduction: String {
        switch action {
        case .ifc: t("从当前建筑构件与保存的几何生成 IFC4，并重新读取检查。", "Generate IFC4 from the current building elements and saved geometry, then read it back for validation.")
        case .structure: t("对一根矩形梁进行线弹性计算。请明确选择梁、支撑条件、材料与均布载荷。", "Run a linear elastic calculation for one rectangular beam. Explicitly choose its supports, material and uniform load.")
        case .mep: t("检查管道、风管与墙、板、屋顶、梁柱之间的几何相交。", "Check geometric intersections between pipes or ducts and walls, slabs, roofs, beams and columns.")
        case .information: t("按 IDS 信息要求检查当前 IFC 构件是否具有名称。", "Use IDS information requirements to check that the current IFC elements have names.")
        }
    }
    private var structuralInputs: some View {
        Section(t("计算输入", "Analysis inputs")) {
            Picker(t("梁", "Beam"), selection: $structural.memberID) {
                Text(t("请选择梁", "Choose a beam")).tag(Optional<UUID>.none)
                ForEach(beams) { Text($0.name).tag(Optional($0.id)) }
            }.accessibilityIdentifier("cad.building.professional.beam")
            if beams.isEmpty { Text(t("先在建筑模型中添加一根梁。", "Add a beam to the building first.")).foregroundStyle(.secondary) }
            Picker(t("支撑", "Supports"), selection: $structural.support) {
                Text(t("简支", "Simply supported")).tag(CADBuildingStructuralSettings.Support.simplySupported)
                Text(t("悬臂", "Cantilever")).tag(CADBuildingStructuralSettings.Support.cantilever)
            }
            numberField(t("弹性模量 (N/mm²)", "Elastic modulus (N/mm²)"), value: $structural.elasticModulusNPerMM2)
            numberField(t("泊松比", "Poisson ratio"), value: $structural.poissonRatio)
            numberField(t("向下均布载荷 (kN/m)", "Downward uniform load (kN/m)"), value: $structural.lineLoadNPerMM)
            Toggle(t("使用以上支撑、材料与载荷", "Use these supports, material and load"), isOn: $inputsConfirmed)
                .accessibilityIdentifier("cad.building.professional.confirmInputs")
        }
    }
    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number).multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad).frame(maxWidth: 140)
        }
    }
    @ViewBuilder private func resultSections(_ result: CADBuildingProfessionalResult) -> some View {
        if let analysis = result.analysis {
            Section(t("单梁结果", "Single-beam results")) {
                LabeledContent(t("跨度", "Span"), value: number(analysis.spanMM, unit: "mm"))
                LabeledContent(t("向下均布载荷", "Downward uniform load"), value: number(analysis.lineLoadNPerMM, unit: "kN/m"))
                LabeledContent(t("最小竖向挠度", "Minimum vertical deflection"), value: number(analysis.minimumDeflectionMM, unit: "mm"))
                LabeledContent(t("支座反力合计", "Total support reaction"), value: number(analysis.reactionSumN, unit: "N"))
            }.accessibilityIdentifier("cad.building.professional.structuralResult")
        }
        if let coordination = result.coordination {
            Section(t("几何协调结果", "Geometric coordination")) {
                if coordination.status == "notEvaluated" {
                    Text(t("添加管道或风管及建筑构件后再运行检查。", "Add a pipe or duct and building geometry, then run this check again."))
                } else {
                    LabeledContent(t("相交数量", "Intersections"), value: "\(coordination.clashes.count)")
                    if let tolerance = coordination.toleranceM { LabeledContent(t("容差", "Tolerance"), value: number(tolerance * 1000, unit: "mm")) }
                    ForEach(Array(coordination.clashes.prefix(50).enumerated()), id: \.offset) { _, clash in
                        VStack(alignment: .leading) {
                            Text("\(clash.a) ↔ \(clash.b)").font(.caption.monospaced())
                            Text(number(clash.distanceM * 1000, unit: "mm")).font(.caption)
                        }
                    }
                }
            }.accessibilityIdentifier("cad.building.professional.mepResult")
        }
        if let information = result.information {
            Section(t("信息要求结果", "Information requirements")) {
                ForEach(Array(information.checks.enumerated()), id: \.offset) { _, check in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(check.name, systemImage: check.passed ? "checkmark.circle" : "exclamationmark.circle")
                        Text(t("适用 \(check.applicable) · 未通过 \(check.failed)", "Applicable \(check.applicable) · Failed \(check.failed)")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.accessibilityIdentifier("cad.building.professional.informationResult")
        }
    }
    private func number(_ value: Double, unit: String) -> String { "\(value.formatted(.number.precision(.significantDigits(5)))) \(unit)" }
    private func stateTitle(_ state: CADBuildingProfessionalOperation.State) -> String {
        switch state {
        case .preparing: t("准备中", "Preparing")
        case .running: t("计算中", "Running")
        case .ready: t("已完成", "Ready")
        case .cancelling: t("正在取消", "Cancelling")
        case .cancelled: t("已取消", "Cancelled")
        case .failed: t("失败", "Failed")
        case .interrupted: t("已中断", "Interrupted")
        }
    }
    private func start() {
        guard let root, let workspaceID, let conversationID, canStart else { return }
        starting = true; message = nil; artifacts = []
        Task {
            defer { starting = false }
            do { operation = try await environment.buildingProfessionalCenter.startFromUI(document: document, action: action,
                structural: structural, root: root, workspaceID: workspaceID, conversationID: conversationID) }
            catch { message = error.localizedDescription }
        }
    }
    private func cancel(_ id: UUID) {
        cancelling = true
        Task {
            defer { cancelling = false }
            do { operation = try await environment.buildingProfessionalCenter.cancel(id) }
            catch { message = error.localizedDescription }
        }
    }
    private func refresh() async {
        guard let current = operation else { return }
        do {
            let updated = try await environment.buildingProfessionalCenter.refresh(current.id)
            guard operation?.id == current.id else { return }
            operation = updated; message = updated.error
            if updated.state == .ready, artifacts.isEmpty { artifacts = try environment.buildingProfessionalCenter.artifactURLs(updated) }
        } catch is CancellationError { }
        catch { message = error.localizedDescription }
    }
}
