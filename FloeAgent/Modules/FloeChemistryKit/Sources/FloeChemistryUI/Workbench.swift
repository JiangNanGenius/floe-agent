import SwiftUI
import Charts
import FloeChemistryCore
import FloeChemistryEngine

@MainActor public struct ChemistryLibraryView: View {
    public let service: ChemistryService
    @State private var projects: [ChemistryProject] = []
    @State private var title = chemistryText("Chemistry project", "化学工程")
    @State private var route: UUID?
    @State private var error: String?
    public init(service: ChemistryService) { self.service = service }
    public var body: some View {
        NavigationStack {
            List {
                Section(chemistryText("New project", "新建工程")) {
                    TextField(chemistryText("Project name", "工程名称"), text: $title)
                    Button(chemistryText("Create chemistry project", "新建化学工程"), systemImage: "plus") {
                        Task {
                            do { route = try await service.create(title: title).id; projects = try await service.projects() }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section(chemistryText("Projects", "工程")) {
                    ForEach(projects) { p in
                        Button { route = p.id } label: {
                            VStack(alignment: .leading) {
                                Text(p.title).font(.headline)
                                Text("\(p.objects.count) " + chemistryText("objects", "个对象")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let error { Section(chemistryText("Details", "详情")) { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(chemistryText("Chemistry", "化学"))
            .navigationDestination(item: $route) { id in ChemistryWorkbench(service: service, projectID: id) }
            .task { do { projects = try await service.projects() } catch { self.error = error.localizedDescription } }
        }
    }
}

private enum ChemistrySheet: String, Identifiable { case importer, inspector, history; var id: String { rawValue } }
@MainActor public struct ChemistryWorkbench: View {
    @State private var state: ChemistryEditorState
    @State private var mode = 0
    @State private var atoms: [Int] = []
    @State private var drawing = false
    @State private var showRuns = true
    @State private var sheet: ChemistrySheet?
    @Environment(\.scenePhase) private var scenePhase
    public init(service: ChemistryService, projectID: UUID) {
        _state = State(initialValue: ChemistryEditorState(service: service, projectID: projectID))
    }
    /// The App owns one editor state and calculation service across Notes,
    /// assistants and transient navigation. The standalone initializer remains.
    public init(state: ChemistryEditorState) { _state = State(initialValue: state) }
    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width > 750 && !(mode == 0 && drawing) { objectList.frame(width: 210); Divider() }
                VStack(spacing: 0) {
                    Picker(chemistryText("View", "视图"), selection: $mode) {
                        Text(chemistryText("Workbench", "工作台")).tag(0)
                        Text(chemistryText("Document", "文档")).tag(1)
                    }.pickerStyle(.segmented).frame(maxWidth: 320).padding(.horizontal).padding(.vertical, 8)
                    if mode == 0 { objectContent } else { document }
                    if state.project?.runs.isEmpty == false && !(mode == 0 && drawing) {
                        Divider()
                        HStack {
                            Button { showRuns.toggle() } label: {
                                Label(chemistryText("Calculations", "计算任务") + " (\(state.project?.runs.count ?? 0))", systemImage: showRuns ? "chevron.down" : "chevron.right")
                            }.buttonStyle(.plain).frame(minHeight: 36)
                            Spacer()
                        }.font(.subheadline.weight(.semibold)).padding(.horizontal)
                        if showRuns { runList.frame(maxHeight: 150) }
                    }
                }
                if geometry.size.width > 1100 && !(mode == 0 && drawing) { Divider(); inspector.frame(width: 300) }
            }
        }
        .navigationTitle(state.project?.title ?? chemistryText("Chemistry", "化学"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup {
                Text(state.saveStatus)
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("chemistry.saveStatus")
                Menu {
                    ForEach(state.project?.objects ?? []) { object in Button(object.title) { state.selectedID = object.id; atoms = [] } }
                } label: { Label(chemistryText("Objects", "对象"), systemImage: "square.stack.3d.up") }
                Menu {
                    Button(chemistryText("New drawing", "新建结构绘图"), systemImage: "pencil.tip") { Task { await state.createDrawing(); drawing = true } }
                    Button(chemistryText("Import or create", "导入或新建"), systemImage: "square.and.arrow.down") { sheet = .importer }
                } label: { Label(chemistryText("Add object", "添加对象"), systemImage: "plus") }
                Button { sheet = .inspector } label: { Label(chemistryText("Properties and methods", "属性与方法"), systemImage: "slider.horizontal.3") }
                Button { sheet = .history } label: { Label(chemistryText("History", "历史版本"), systemImage: "clock.arrow.circlepath") }
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .importer: ChemistryImportSheet(state: state)
            case .inspector: ChemistryInspectorSheet(state: state, selectedAtoms: atoms)
            case .history: ChemistryHistorySheet(state: state)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = state.error {
                DisclosureGroup(chemistryText("Operation incomplete · details", "操作未完成 · 详情")) {
                    Text(error).textSelection(.enabled).font(.caption)
                    Button(chemistryText("Dismiss", "关闭")) { state.error = nil }
                }.padding().background(.regularMaterial)
            }
        }
        .overlay { if state.busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .task {
            await state.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if state.project?.runs.contains(where: { [.queued, .running].contains($0.status) }) == true { await state.refresh() }
            }
        }
        .onChange(of: state.selectedID) { _, _ in atoms = []; drawing = state.selected?.sketchDocument != nil }
        .onDisappear { Task { await state.flush() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { Task { await state.flush() } } }
    }
    private var objectList: some View {
        List(selection: $state.selectedID) {
            Section(chemistryText("Objects", "对象")) {
            ForEach(state.project?.objects ?? []) { object in
                HStack {
                    Image(systemName: object.kind == .spectrum ? "waveform.path" : (object.kind == .crystal ? "cube" : (object.kind == .reaction ? "arrow.right" : "atom"))).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                    Text(object.title).lineLimit(2)
                    Text(object.displaySummary).font(.caption).foregroundStyle(.secondary)
                    }
                }.tag(object.id)
            }
            }
        }
    }
    @ViewBuilder private var objectContent: some View {
        if let object = state.selected {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(object.title).font(.headline)
                        Text(object.displaySummary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !object.requiresPreparation && (object.kind == .molecule || object.sketchDocument != nil) {
                        Picker(chemistryText("Structure view", "结构视图"), selection: $drawing) {
                            Text(chemistryText("2D drawing", "二维绘图")).tag(true)
                            Text(chemistryText("3D view", "三维视图")).tag(false)
                        }.pickerStyle(.segmented).frame(maxWidth: 240)
                    }
                }.padding(.horizontal).padding(.vertical, 8)
                Divider()
            if object.requiresPreparation {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(chemistryText("Awaiting processing", "待处理"), systemImage: "hourglass").font(.headline)
                        Text(chemistryText("The original is saved. Choose a processing method in Properties and methods.", "原始内容已保存，可在“属性与方法”中选择处理方法。"))
                            .foregroundStyle(.secondary)
                        Button(chemistryText("Properties and methods", "属性与方法")) { sheet = .inspector }
                        DisclosureGroup(chemistryText("Source preview", "原始内容预览")) {
                            Text(String(object.source.prefix(65536))).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            if object.source.prefix(65537).count > 65536 {
                                Text(chemistryText("Export the original format to save the full source.", "导出为原始格式可保存完整内容。")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }.accessibilityIdentifier("chemistry.pendingPreparation")
            } else if drawing && (object.kind == .molecule || object.sketchDocument != nil) {
                ChemistryDrawing(state: state, object: object).id(object.id)
            } else
            if object.kind == .spectrum, let data = try? SpectrumAnalysis.csv(object.source) {
                VStack {
                    Chart(data.points, id: \.x) { p in LineMark(x: .value("x", p.x), y: .value("Signal", p.y)) }.padding()
                    Text(chemistryText("Trapezoidal integral", "梯形积分") + ": \(data.area.formatted())").padding()
                }
            } else if object.kind == .reaction || object.kind == .note {
                ScrollView { VStack(alignment: .leading) {
                    Text(object.title).font(.title2)
                    Text(object.source).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    if let facts = object.facts, let bytes = try? JSONEncoder().encode(facts) { Text(String(decoding: bytes, as: UTF8.self)).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding() }
            } else { ChemistryMoleculeView(object: object, selectedAtoms: $atoms) }
            }
        } else {
            ContentUnavailableView {
                Label(chemistryText("Create a chemical object", "创建化学对象"), systemImage: "atom")
            } description: { Text(chemistryText("Import a structure, reaction or spectrum to begin.", "导入结构、反应或谱图，开始编辑与计算。")) }
            actions: {
                Button(chemistryText("New drawing", "新建结构绘图")) { Task { await state.createDrawing(); drawing = true } }.buttonStyle(.borderedProminent)
                Button(chemistryText("Import or create", "导入或新建")) { sheet = .importer }
            }
        }
    }
    private var document: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(state.project?.blocks ?? []) { block in
                    VStack(alignment: .leading) {
                        if let id = block.objectID, let object = state.project?.objects.first(where: { $0.id == id }) {
                            Button { state.selectedID = id; mode = 0 } label: { Label(object.title, systemImage: "atom").font(.headline) }
                            Text(object.displaySummary).foregroundStyle(.secondary)
                        }
                        TextEditor(text: Binding(get: { state.drafts[block.id] ?? block.text }, set: { state.setText(block.id, text: $0) }))
                            .frame(minHeight: 100).border(.quaternary)
                    }
                }
                Button(chemistryText("Add text", "添加文字"), systemImage: "text.badge.plus") {
                    Task { await state.perform { _ = try await state.service.addText(state.projectID, text: "") } }
                }
            }.padding()
        }
    }
    private var inspector: some View { ChemistryInspector(state: state, selectedAtoms: atoms) }
    private var runList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach((state.project?.runs ?? []).reversed()) { run in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(run.input.title + " · " + chemistryMethodTitle(run.method)).font(.headline)
                            Text(state.environmentTitle(run.environmentID) + " · " + run.status.displayTitle).font(.caption).foregroundStyle(.secondary)
                            if let energy = run.result?["energy"]?.number { Text("\(energy.formatted()) " + (run.result?["units"]?.string ?? "")) }
                            if let reason = run.result?["stopReason"]?.string, reason != "evaluated" {
                                Text(reason == "converged" ? chemistryText("Converged", "已收敛") : (reason == "stalled" ? chemistryText("Stopped making progress · not converged", "优化停滞 · 未收敛") : chemistryText("Iteration limit reached · not converged", "达到迭代上限 · 未收敛")))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = run.error { DisclosureGroup(chemistryText("Details", "详情")) { Text(error).font(.caption).textSelection(.enabled) } }
                        }
                        Spacer()
                        if [.queued, .running].contains(run.status) {
                            ProgressView()
                            Button(chemistryText("Stop", "停止")) { Task { await state.cancel(runID: run.id) } }
                        } else if run.status == .succeeded, run.result?["cjson"] != nil || run.result?["molblock"] != nil {
                            Button(chemistryText("Apply structure", "应用结构")) {
                                Task { await state.perform { _ = try await state.service.apply(state.projectID, runID: run.id, expectedObjectRevision: run.input.revision) } }
                            }.disabled(state.project?.objects.first(where: { $0.id == run.input.id }) != run.input)
                        }
                    }.padding(.horizontal)
                }
            }.padding(.vertical, 8)
        }
    }
}
