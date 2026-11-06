// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCore
import FloeChemistryCore
import FloeChemistryEngine

/// Explicit user calculations in a configured environment. Dismissing this
/// sheet stops only its status refresh; processors remain service-owned.
struct ChemistryEnvironmentPanel: View {
    let session: ChemistryProjectSession
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var record: PersonalContentRecord?
    @State private var taskID: UUID?
    @State private var environmentID: String?
    @State private var environmentName = ""
    @State private var showingEnvironment = false
    @State private var selectedObjectID: UUID?
    @State private var selectedMethod = ""
    @State private var optionsJSON = "{}"
    @State private var methods: [String] = []
    @State private var results: [ChemistryEnvironmentResult] = []
    @State private var activeAttempt: UUID?
    @State private var busy = false
    @State private var diagnostic: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(copy("运行位置", "Execution environment")) {
                    LabeledContent(copy("当前位置", "Selected environment"), value: environmentName.isEmpty ? copy("尚未选择", "Not selected") : environmentName)
                    Button(copy("选择运行位置", "Choose environment"), systemImage: "network") { showingEnvironment = true }
                        .disabled(taskID == nil || busy)
                        .accessibilityIdentifier("chemistry.environment.choose")
                    Button(copy("检查可用方法", "Check available methods"), systemImage: "checkmark.circle") { startProbe() }
                        .disabled(record == nil || busy)
                        .accessibilityIdentifier("chemistry.environment.probe")
                }
                Section(copy("计算", "Calculation")) {
                    Picker(copy("结构", "Structure"), selection: $selectedObjectID) {
                        Text(copy("选择结构", "Choose structure")).tag(nil as UUID?)
                        ForEach(session.editor.project?.objects ?? []) { object in
                            Text(object.title).tag(Optional(object.id))
                        }
                    }
                    Picker(copy("方法", "Method"), selection: $selectedMethod) {
                        Text(copy("选择方法", "Choose method")).tag("")
                        ForEach(methods, id: \.self) { Text(methodName($0)).tag($0) }
                    }.disabled(methods.isEmpty)
                    if methods.isEmpty {
                        Text(copy("检查所选环境后，会显示它实际支持的方法。", "Check the selected environment to see its available methods."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    DisclosureGroup(copy("计算选项", "Calculation options")) {
                        TextEditor(text: $optionsJSON).font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 96).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .accessibilityIdentifier("chemistry.environment.options")
                    }
                    Button(copy("开始计算", "Start calculation"), systemImage: "play.fill") { startCalculation() }
                        .disabled(record == nil || busy || selectedObjectID == nil || selectedMethod.isEmpty)
                        .accessibilityIdentifier("chemistry.environment.start")
                }
                if busy { ProgressView(copy("正在准备", "Preparing")) }
                if !results.isEmpty {
                    Section(copy("计算记录", "Calculations")) {
                        ForEach(results, id: \.attemptID) { output in resultRow(output) }
                    }
                }
                if let diagnostic {
                    Section {
                        Text(diagnostic).font(.footnote).textSelection(.enabled)
                        Button(copy("刷新", "Refresh")) { Task { await refresh() } }
                    } header: { Text(copy("详情", "Details")) }
                }
            }
            .navigationTitle(copy("环境计算", "Environment calculations"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(copy("完成", "Done")) { dismiss() }
                    .accessibilityIdentifier("chemistry.environment.done")
            } }
            .task { await open() }
            .task(id: activeAttempt) { await pollVisibleAttempt() }
            .sheet(isPresented: $showingEnvironment, onDismiss: { Task { await refresh() } }) {
                if let taskID { TaskExecutionEnvironmentView(environment: environment, conversationID: taskID) }
            }
        }
        .accessibilityIdentifier("chemistry.environment.panel")
    }

    @ViewBuilder private func resultRow(_ output: ChemistryEnvironmentResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(output.chemistryRunID == nil ? copy("环境检查", "Environment check") : copy("结构计算", "Structure calculation"),
                      systemImage: output.chemistryRunID == nil ? "checkmark.circle" : "atom")
                Spacer()
                Text(statusName(output.state)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(copy("刷新状态", "Refresh status")) { Task { await refreshAttempt(output.attemptID) } }
                if !output.state.terminal {
                    Button(copy("停止", "Stop"), role: .destructive) { cancel(output.attemptID) }
                        .disabled(busy || output.state == .submissionUnknown)
                }
            }.buttonStyle(.borderless)
            if let error = output.error {
                DisclosureGroup(copy("查看详情", "View details")) { Text(error).font(.caption).textSelection(.enabled) }
            }
            if let unavailable = output.unavailable, !unavailable.isEmpty {
                DisclosureGroup(copy("其他方法", "Other methods")) {
                    ForEach(unavailable.keys.sorted(), id: \.self) { name in
                        Text(name + ": " + (unavailable[name] ?? "")).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }.padding(.vertical, 3)
    }

    @MainActor private func open() async {
        do {
            let value = try await PersonalContentService.shared.library().resolve(session.projectID)
            guard value.record.kind.rawValue == "chemistry",
                  ChemistryWorkerFiles.canonical(value.url) == ChemistryWorkerFiles.canonical(session.root) else {
                throw PersonalContentError.changedDocument
            }
            record = value.record
            taskID = try await environment.chemistryEnvironmentJobs.uiTask(for: value.record)
            selectedObjectID = session.editor.selectedID
            await refresh()
        } catch { diagnostic = error.localizedDescription }
    }
    @MainActor private func refresh() async {
        guard let taskID else { return }
        await environment.taskExecutionEnvironments.load(taskID)
        let binding = environment.taskExecutionEnvironments.snapshots[taskID]?.binding
        environmentID = binding?.target.environmentID
        await environment.chemistryEnvironmentJobs.refreshDisplayNames(session)
        environmentName = environmentID.map { session.editor.environmentTitle($0) } ?? ""
        await session.refreshFromHost()
        let capabilities = await session.service.capabilities()
        methods = environmentID.flatMap { capabilities[$0] } ?? []
        if !methods.contains(selectedMethod) { selectedMethod = methods.first ?? "" }
        do { results = try environment.chemistryEnvironmentJobs.recent(projectID: session.projectID, root: session.root) }
        catch { diagnostic = error.localizedDescription }
    }
    @MainActor private func accept(_ output: ChemistryEnvironmentResult) async {
        results.removeAll { $0.attemptID == output.attemptID }; results.insert(output, at: 0)
        if let available = output.methods { methods = available; if !methods.contains(selectedMethod) { selectedMethod = methods.first ?? "" } }
        activeAttempt = output.state.terminal || output.state == .transferPending ? nil : output.attemptID
        await session.refreshFromHost()
        await session.editor.refreshCapabilities()
        if let environmentID {
            methods = await session.service.capabilities()[environmentID] ?? []
            if !methods.contains(selectedMethod) { selectedMethod = methods.first ?? "" }
        }
    }
    private func startProbe() {
        guard let record else { return }; busy = true; diagnostic = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                guard await session.flushForClose() else { return }
                let output = try await environment.chemistryEnvironmentJobs.startNativeProbe(record: record,
                    root: session.root, service: session.service)
                await refresh(); await accept(output)
            } catch { diagnostic = error.localizedDescription; await refresh() }
        }
    }
    private func startCalculation() {
        guard let record, let objectID = selectedObjectID else { return }
        busy = true; diagnostic = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                guard await session.flushForClose() else { return }
                let project = try await session.service.project(session.projectID)
                guard let object = project.objects.first(where: { $0.id == objectID }), optionsJSON.utf8.count <= 32768,
                      case .object = try JSONDecoder().decode(FloeChemistryCore.JSONValue.self, from: Data(optionsJSON.utf8)) else {
                    throw FloeError.validationFailed(copy("请选择结构并检查计算选项。", "Choose a structure and check the calculation options."))
                }
                let options = try JSONDecoder().decode(FloeChemistryCore.JSONValue.self, from: Data(optionsJSON.utf8))
                let output = try await environment.chemistryEnvironmentJobs.startNativeRun(record: record, root: session.root,
                    service: session.service, objectID: objectID, expectedRevision: object.revision,
                    method: selectedMethod, options: options)
                await accept(output)
            } catch { diagnostic = error.localizedDescription; await refresh() }
        }
    }
    private func cancel(_ id: UUID) {
        guard let record else { return }; busy = true
        Task { @MainActor in
            defer { busy = false }
            do { await accept(try await environment.chemistryEnvironmentJobs.cancelNative(id,
                record: record, root: session.root, service: session.service)) }
            catch { diagnostic = error.localizedDescription }
        }
    }
    @MainActor private func refreshAttempt(_ id: UUID) async {
        guard let record else { return }
        do { await accept(try await environment.chemistryEnvironmentJobs.statusNative(id,
            record: record, root: session.root, service: session.service)) }
        catch { diagnostic = error.localizedDescription }
    }
    private func pollVisibleAttempt() async {
        guard let id = activeAttempt else { return }
        while !Task.isCancelled, activeAttempt == id {
            await refreshAttempt(id)
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }
    private func copy(_ chinese: String, _ english: String) -> String { IDELanguageRunText.t(chinese, english) }
    private func methodName(_ method: String) -> String {
        switch method {
        case "rdkit.embed": copy("三维结构生成", "3D structure generation")
        case "rdkit.conformers": copy("构象搜索", "Conformer search")
        case "rdkit.describe": copy("分子描述符", "Molecular descriptors")
        case "rdkit.similarity": copy("分子相似性", "Molecular similarity")
        case "rdkit.substructure": copy("子结构检索", "Substructure search")
        case "rdkit.reaction": copy("反应规则", "Reaction rules")
        case "gemmi.crystal": copy("晶体结构", "Crystal structure")
        case "gemmi.diffraction": copy("X 射线衍射", "X-ray diffraction")
        case "gemmi.structure": copy("生物结构分析", "Biomolecular structure analysis")
        case "openmm.lennardJones": copy("Lennard-Jones 粒子动力学", "Lennard-Jones particle dynamics")
        case "openmm.system": copy("OpenMM 动力学 · 指定体系", "OpenMM dynamics · supplied system")
        case "xtb.singlepoint": copy("xTB 单点能", "xTB single-point energy")
        case "xtb.optimize": copy("xTB 几何优化", "xTB geometry optimization")
        default: method
        }
    }
    private func statusName(_ state: ChemistryWorkerAttempt.State) -> String {
        switch state {
        case .awaitingSubmission: copy("待执行", "Prepared")
        case .submissionUnknown: copy("等待核对", "Awaiting reconciliation")
        case .running: copy("进行中", "Running")
        case .cancelling: copy("正在停止", "Stopping")
        case .transferPending: copy("等待结果文件", "Awaiting result files")
        case .succeeded: copy("已完成", "Completed")
        case .failed: copy("未完成", "Failed")
        case .cancelled: copy("已停止", "Stopped")
        case .interrupted: copy("已中断", "Interrupted")
        }
    }
}
#endif
