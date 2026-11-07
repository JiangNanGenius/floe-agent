// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeCore
import FloeCanvasCore
import FloeCanvasUI
import FloeCanvasFlow
import FloeCanvasExchange
import FloeCanvasIntegration
import FloeCanvasTemplates
import FloeCanvasTemplatesUI

private struct CanvasModuleMenus: Sendable {
    let actions: @MainActor @Sendable () -> AnyView
    let exports: @MainActor @Sendable () -> AnyView
}
private struct CanvasModuleMenusKey: EnvironmentKey {
    static let defaultValue: CanvasModuleMenus? = nil
}
private extension EnvironmentValues {
    var canvasModuleMenus: CanvasModuleMenus? {
        get { self[CanvasModuleMenusKey.self] }
        set { self[CanvasModuleMenusKey.self] = newValue }
    }
}

/// Reads the host menu at the descendant render site, so the old editor keeps
/// its own model/selection/undo while the modifier keeps its service actions.
struct CanvasModuleActionMenuItems: View {
    @Environment(\.canvasModuleMenus) private var menus
    var body: some View {
        if let menus {
            Section(IDELanguageRunText.t("素材与流程", "Media and workflow")) { menus.actions() }
        }
    }
}
struct CanvasModuleExportMenu<Legacy: View>: View {
    @Environment(\.canvasModuleMenus) private var menus
    let legacy: Legacy
    init(@ViewBuilder legacy: () -> Legacy) { self.legacy = legacy() }
    var body: some View {
        if let menus { menus.exports() } else { legacy }
    }
}

/// New components add tools to the original canvas; they never own a second
/// board, selection, gesture system or top-level editor.
@MainActor struct CanvasModuleTools: ViewModifier {
    let record: PersonalContentRecord
    @ObservedObject var store: CanvasEditorStore
    let providedSession: CanvasHostSession?
    @EnvironmentObject private var environment: AppEnvironment
    @State private var sheet: Sheet?
    @State private var importing = false
    @State private var diagnostic: String?
    @State private var busy = false
    private enum Sheet: String, Identifiable {
        case templates, sources, goal, saveTemplate, flow, flowDefinition
        var id: String { rawValue }
    }
    private var chinese: Bool { FloeL10n.currentLanguageCode.hasPrefix("zh") }

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .floeStudioDocumentDidChange)) { _ in
                Task { await store.refreshFromHost() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .floeCanvasFrameworkExportRequested)) { message in
                guard message.userInfo?["canvasID"] as? UUID == record.id,
                      let format = message.userInfo?["format"] as? String else { return }
                Task {
                    await store.refreshFromHost()
                    if format == "json" { await exportSnapshot() }
                    else { await export(format == "pdf" ? .pdf : format == "png" ? .png : .floecanvaslab) }
                }
            }
            .environment(\.canvasModuleMenus, CanvasModuleMenus(
                actions: { AnyView(moduleActionItems) },
                exports: { AnyView(moduleExportMenu) }))
            .sheet(item: $sheet) { value in
                switch value {
                case .templates:
                    NavigationStack {
                        CanvasHostTemplatePicker(chinese: chinese) { template in
                            sheet = nil
                            if let template { Task { await append(template) } }
                        }
                        .toolbar { ToolbarItem(placement: .cancellationAction) {
                            Button(IDELanguageRunText.t("取消", "Cancel")) { sheet = nil }
                        } }
                    }
                case .sources:
                    CanvasHostSourcePicker(excluding: record.id) { option in
                        sheet = nil; Task { await attach(option) }
                    }
                case .goal:
                    CanvasHostTextSheet(title: IDELanguageRunText.t("从目标开始", "Start with a goal"),
                        prompt: IDELanguageRunText.t("描述要研究或创作的内容", "Describe what you want to research or create"),
                        action: IDELanguageRunText.t("生成初稿", "Create draft")) { value in
                            sheet = nil; Task { await draft(value) }
                        }
                case .saveTemplate:
                    CanvasHostTextSheet(title: IDELanguageRunText.t("保存流程", "Save workflow"),
                        prompt: IDELanguageRunText.t("流程名称", "Workflow name"),
                        action: IDELanguageRunText.t("保存", "Save")) { value in
                            sheet = nil; Task { await saveTemplate(value) }
                        }
                case .flow:
                    NavigationStack {
                        CanvasFlowDebuggerView(store: store)
                            .navigationTitle(IDELanguageRunText.t("流程", "Workflow"))
                            .toolbar { ToolbarItem(placement: .confirmationAction) {
                                Button(IDELanguageRunText.t("完成", "Done")) { sheet = nil }
                            } }
                    }
                case .flowDefinition:
                    if let graph = store.activeFlowGraph { CanvasFlowDefinitionEditor(store: store, graphID: graph.id) }
                    else {
                        NavigationStack {
                            ContentUnavailableView(IDELanguageRunText.t("流程已更改", "Workflow changed"), systemImage: "point.3.connected.trianglepath.dotted")
                                .toolbar { ToolbarItem(placement: .confirmationAction) {
                                    Button(IDELanguageRunText.t("完成", "Done")) { sheet = nil }
                                } }
                        }
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .image, .movie, .audio, .pdf, .plainText], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let files): Task { await importFiles(files) }
                case .failure(let error): diagnostic = error.localizedDescription
                }
            }
            .alert(IDELanguageRunText.t("画布", "Canvas"), isPresented: .init(get: { diagnostic != nil }, set: { if !$0 { diagnostic = nil } })) {
                Button(IDELanguageRunText.t("好", "OK")) { diagnostic = nil }
            } message: { Text(diagnostic ?? "") }
            .overlay(alignment: .bottomLeading) { if busy { ProgressView().padding().background(.regularMaterial, in: Capsule()).padding() } }
    }

    private var moduleActionItems: some View {
        Group {
            Button(IDELanguageRunText.t("导入素材", "Import media"), systemImage: "square.and.arrow.down") { importing = true }
            Button(IDELanguageRunText.t("引用资料或作品", "Link a source or work"), systemImage: "link") { sheet = .sources }
            Divider()
            Button(IDELanguageRunText.t("加入场景与流程", "Add a scenario or workflow"), systemImage: "square.grid.2x2") { sheet = .templates }
            Button(IDELanguageRunText.t("从目标生成初稿", "Draft from a goal"), systemImage: "sparkles.rectangle.stack") { sheet = .goal }
            Button(IDELanguageRunText.t("存为我的流程", "Save as my workflow"), systemImage: "square.and.arrow.up.on.square") { sheet = .saveTemplate }
            Menu(IDELanguageRunText.t("添加流程步骤", "Add workflow step"), systemImage: "point.3.connected.trianglepath.dotted") {
                ForEach(FlowNodeKind.allCases, id: \.self) { kind in
                    Button(flowTitle(kind)) { Task { await insertStep(kind) } }
                }
            }
            if !store.page.flowGraphs.isEmpty {
                Divider()
                Menu(IDELanguageRunText.t("流程", "Workflow"), systemImage: "point.3.connected.trianglepath.dotted") {
                    ForEach(Array(store.page.flowGraphs.enumerated()), id: \.element.id) { index, graph in
                        Button(IDELanguageRunText.t("流程 ", "Workflow ") + String(index + 1)) {
                            store.selectFlowGraph(graph.id)
                            NotificationCenter.default.post(name: .floeCanvasFrameworkFlowRequested, object: nil,
                                userInfo: ["canvasID": record.id, "pageID": store.selectedPageID, "graphID": graph.id])
                        }
                    }
                    Button(IDELanguageRunText.t("编辑流程定义", "Edit workflow definition")) { sheet = .flowDefinition }
                    Button(IDELanguageRunText.t("运行流程", "Run workflow")) {
                        Task { _ = await store.startFlowRun(); sheet = .flow }
                    }
                }
            }
            if let open = store.services.openAssistant {
                Divider()
                Button(IDELanguageRunText.t("询问选区", "Ask about selection"), systemImage: "bubble.left.and.text.bubble.right") {
                    let request = CanvasAssistantRequest(context: .init(canvasID: record.id,
                        pageID: store.selectedPageID, revision: store.revision), selectedNodeIDs: Array(store.selection), instruction: "")
                    Task { do { try await open(request) } catch { diagnostic = error.localizedDescription } }
                }
            }
        }
        .disabled(busy || store.isMutating)
    }

    private var moduleExportMenu: some View {
        Menu(IDELanguageRunText.t("导出", "Export"), systemImage: "square.and.arrow.up") {
            ForEach(CanvasExchangeFormat.allCases, id: \.self) { format in
                Button(exportTitle(format)) {
                    Task { await store.refreshFromHost(); await export(format) }
                }
            }
            Button("workspace.workspace_canvas_view.canvas_json_without_assets") {
                Task { await store.refreshFromHost(); await exportSnapshot() }
            }
        }
        .disabled(busy || store.isMutating)
        .accessibilityIdentifier("canvas.export")
    }

    @MainActor private func session() async throws -> CanvasHostSession {
        if let providedSession { return providedSession }
        let location = try await PersonalContentService.shared.library().resolve(record.id)
        return try await CanvasHostSessions.shared.session(record: location.record, directory: location.url, environment: environment)
    }
    @MainActor private func append(_ template: CanvasTemplate) async {
        busy = true; defer { busy = false }
        do {
            let session = try await session()
            let workspace = CanvasTemplateWorkspace(documents: session.repository, library: try CanvasHostServices.templateLibrary(),
                ownershipResolver: CanvasHostOwnershipResolver(legacyCanvasID: providedSession == nil ? nil : record.id))
            let activated = try await workspace.activate(canvasID: record.id, pageID: store.selectedPageID)
            let receipt = try await workspace.append(template, to: activated)
            await store.refreshFromHost(); await store.selectPage(receipt.pageID); store.fitToContent()
            if providedSession == nil { try await PersonalContentService.shared.library().markChanged(record.id) }
        } catch { diagnostic = error.localizedDescription }
    }
    @MainActor private func importFiles(_ files: [URL]) async {
        busy = true; defer { busy = false }
        do {
            let session = try await session()
            let pageID = store.selectedPageID
            let base = store.revision
            var operations: [CanvasEditOperation] = []
            for (index, file) in files.prefix(32).enumerated() {
                let asset = try await session.assets.importFile(file)
                let content: CanvasContent = asset.mimeType == "application/pdf" ? .pdf(documentAssetID: asset.id, pageRange: nil) : .media(asset)
                let node = CanvasNodeSnapshot(title: file.deletingPathExtension().lastPathComponent, content: content,
                    frame: frame(index), metadata: ["floe.asset.locator": String(decoding: try JSONEncoder().encode(asset), as: UTF8.self)])
                operations.append(.insertNode(node))
            }
            _ = try await session.repository.commit(.init(pageID: pageID, scope: .wholeDocument, operations: operations),
                canvasID: record.id, expectedRevision: base, requestID: UUID())
            await store.refreshFromHost(); store.fitToContent()
            if providedSession == nil { try await PersonalContentService.shared.library().markChanged(record.id) }
        } catch { diagnostic = error.localizedDescription }
    }
    @MainActor private func attach(_ option: CanvasHostSourceOption) async {
        busy = true; defer { busy = false }
        do {
            let session = try await session()
            let node: CanvasNodeSnapshot
            if option.isEditor {
                node = CanvasNodeSnapshot(title: option.title, content: .editor(.init(projectID: option.id,
                    appliedRevision: option.revision, editorKind: option.kind)), frame: frame(0))
            } else {
                let source = try await CanvasHostSources().read(sourceID: option.id, fragment: nil)
                node = CanvasNodeSnapshot(kind: .sourced, title: option.title,
                    content: .markdown(document: source.text, previewText: nil), frame: frame(0),
                    source: .init(sourceID: option.id, usedRevision: source.revision))
            }
            _ = try await session.repository.commit(.init(pageID: store.selectedPageID, scope: .wholeDocument, operations: [.insertNode(node)]),
                canvasID: record.id, expectedRevision: store.revision, requestID: UUID())
            await store.refreshFromHost(); store.select(node.id)
        } catch { diagnostic = error.localizedDescription }
    }
    @MainActor private func draft(_ goal: String) async {
        guard let gateway = store.services.proposalGateway else {
            diagnostic = IDELanguageRunText.t("请先选择画布或文本模型，再生成初稿。", "Choose a canvas or text model before creating a draft."); return
        }
        busy = true; defer { busy = false }
        do {
            let request = CanvasAssistantRequest(context: .init(canvasID: record.id, pageID: store.selectedPageID, revision: store.revision),
                selectedNodeIDs: Array(store.selection), instruction: goal, disposition: .branch)
            let proposal = try await gateway.propose(request: request)
            let host = CanvasHostEditContext(canvasID: record.id, pageID: store.selectedPageID,
                revision: store.revision, selectedNodeIDs: store.selection, allowsCreation: true)
            let verified = try CanvasAssistantEditGuard.validatedProposal(proposal, request: host, against: store.snapshot)
            let session = try await session()
            switch verified {
            case .canvasBatch(let batch):
                _ = try await session.repository.commit(batch, canvasID: record.id, expectedRevision: store.revision, requestID: UUID())
            case .documentBatch(let batch):
                _ = try await session.repository.commitDocument(batch, canvasID: record.id, expectedRevision: store.revision, requestID: UUID())
            }
            await store.refreshFromHost(); store.fitToContent()
        } catch { diagnostic = error.localizedDescription }
    }
    @MainActor private func saveTemplate(_ title: String) async {
        do {
            let template = try CanvasTemplateEngine.capture(snapshot: store.snapshot, title: .init(title, title),
                category: .ideas, selectedNodeIDs: store.selection.isEmpty ? nil : store.selection)
            _ = try await CanvasHostServices.templateLibrary().save(template, expectedRevision: nil)
        } catch { diagnostic = error.localizedDescription }
    }
    @MainActor private func insertStep(_ kind: FlowNodeKind) async {
        busy = true; defer { busy = false }
        do {
            let session = try await session()
            let snapshot = try await session.repository.load(canvasID: record.id)
            let pageID = store.selectedPageID
            guard let page = snapshot.pages.first(where: { $0.id == pageID }) else { throw PersonalContentError.changedDocument }
            let right = page.nodes.map { $0.frame.center.x + $0.frame.size.width / 2 }.max() ?? 0
            let batch = try CanvasFlowGraphEditing.insertStepBatch(snapshot: snapshot, pageID: pageID,
                kind: kind, name: flowTitle(kind), at: .init(x: right + 180, y: 0), cardSize: .init(width: 260, height: 180))
            _ = try await session.repository.commitDocument(batch, canvasID: record.id,
                expectedRevision: snapshot.revision, requestID: UUID())
            await store.refreshFromHost()
            if providedSession == nil { try await PersonalContentService.shared.library().markChanged(record.id) }
        } catch { diagnostic = error.localizedDescription }
    }
    private func flowTitle(_ kind: FlowNodeKind) -> String {
        switch kind {
        case .source: IDELanguageRunText.t("输入", "Input")
        case .transform: IDELanguageRunText.t("处理", "Transform")
        case .condition: IDELanguageRunText.t("条件", "Condition")
        case .loop: IDELanguageRunText.t("循环", "Loop")
        case .batch: IDELanguageRunText.t("批量", "Batch")
        case .subgraph: IDELanguageRunText.t("子流程", "Subworkflow")
        case .customScript: IDELanguageRunText.t("脚本", "Script")
        case .customAPI: IDELanguageRunText.t("网络请求", "Network request")
        case .output: IDELanguageRunText.t("输出", "Output")
        }
    }
    @MainActor private func export(_ format: CanvasExchangeFormat) async {
        busy = true; defer { busy = false }
        do {
            let session = try await session()
            let snapshot = store.snapshot
            let output = try await CanvasExchange.export(snapshot, format: format,
                options: .init(pageID: store.selectedPageID, assetResolver: CanvasHostExchangeAssets(assets: session.assets),
                    scope: store.selection.isEmpty ? .wholePage : .selection(store.selection)))
            let directory = session.root.appendingPathComponent("Exports/" + UUID().uuidString)
            try CanvasExchange.save(output, to: directory)
            let urls = output.files.map { directory.appendingPathComponent($0.name) }
            guard !urls.isEmpty else { throw PersonalContentError.invalidProject }
            if !output.issues.isEmpty {
                diagnostic = output.issues.prefix(8).map(\.detail).joined(separator: "\n")
            }
            CanvasHostShare.present(urls)
        } catch { diagnostic = error.localizedDescription }
    }
    @MainActor private func exportSnapshot() async {
        busy = true; defer { busy = false }
        do {
            let session = try await session()
            let snapshot = try await session.repository.load(canvasID: record.id)
            let directory = session.root.appendingPathComponent("Exports/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("Canvas.json")
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            CanvasHostShare.present([file])
        } catch { diagnostic = error.localizedDescription }
    }
    private func frame(_ index: Int) -> CanvasGeometry.Frame {
        .init(center: .init(x: store.viewport.center.x + Double(index % 3) * 340,
            y: store.viewport.center.y + Double(index / 3) * 240), size: .init(width: 300, height: 200))
    }
    private func exportTitle(_ format: CanvasExchangeFormat) -> String {
        switch format {
        case .floecanvaslab: IDELanguageRunText.t("原生画布工程", "Native canvas project")
        case .jsonCanvas: "Obsidian Canvas"
        case .excalidraw: "Excalidraw"
        case .drawio: "draw.io"
        case .pdf: "PDF"
        case .svg: "SVG"
        case .png: "PNG"
        }
    }
}

private struct CanvasHostExchangeAssets: CanvasAssetResolver {
    let assets: CanvasHostAssets
    func data(for locator: CanvasAssetLocator) async throws -> Data { try await assets.bytes(for: locator) }
}

struct CanvasHostOwnershipResolver: TemplateOwnershipResolving {
    var legacyCanvasID: UUID? = nil
    func ownership(for projectID: UUID) async throws -> TemplateOwnership {
        if projectID == legacyCanvasID, WorkspaceCanvasRegistry.exists(canvasID: projectID) {
            return .init(kind: .canvas, ownerID: projectID, directoryID: projectID)
        }
        let value = try await PersonalContentService.shared.library().resolve(projectID)
        return .init(kind: .personal, ownerID: value.record.id, directoryID: value.record.id)
    }
}

private struct CanvasHostTemplatePicker: View {
    let chinese: Bool
    let choose: (CanvasTemplate?) -> Void
    @State private var personal: [CanvasTemplate] = []
    @State private var diagnostic: String?
    var body: some View {
        CanvasTemplatePicker(personal: personal, chinese: chinese, onChoose: choose)
            .task {
                do { personal = try await CanvasHostServices.templateLibrary().list().map(\.latest) }
                catch { diagnostic = error.localizedDescription }
            }
            .safeAreaInset(edge: .bottom) { if let diagnostic { Text(diagnostic).font(.caption).padding() } }
    }
}

struct CanvasHostSourceOption: Identifiable {
    var id: UUID; var title: String; var kind: String; var revision: Int64; var isEditor: Bool
}
private struct CanvasHostSourcePicker: View {
    let excluding: UUID
    let choose: (CanvasHostSourceOption) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options: [CanvasHostSourceOption] = []
    @State private var diagnostic: String?
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List(options.filter { query.isEmpty || $0.title.localizedStandardContains(query) }) { option in
                Button { choose(option) } label: {
                    Label(option.title, systemImage: option.isEditor ? "square.and.pencil" : "doc.text")
                }
            }
            .searchable(text: $query)
            .navigationTitle(IDELanguageRunText.t("引用资料与作品", "Link sources and works"))
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(IDELanguageRunText.t("取消", "Cancel")) { dismiss() }
            } }
            .overlay { if options.isEmpty { ContentUnavailableView(IDELanguageRunText.t("暂无资料", "No sources yet"), systemImage: "doc.text", description: Text(diagnostic ?? IDELanguageRunText.t("先在手记或文件中保存内容，也可直接导入素材。", "Save content in Notes or Files, or import media directly."))) } }
            .task {
                do {
                    let records = try await PersonalContentService.shared.library().records().filter { $0.id != excluding }
                    options = records.map { record in
                        .init(id: record.id, title: record.title, kind: record.kind.rawValue,
                            revision: Int64(record.modifiedAt.timeIntervalSince1970 * 1_000),
                            isEditor: ![.document, .canvas].contains(record.kind))
                    }
                    if let notes = try await NotesRepository.shared.existingStore() {
                        options += try await notes.documents().map { .init(id: $0.id, title: $0.title, kind: "notes", revision: Int64($0.revision), isEditor: false) }
                    }
                } catch { diagnostic = error.localizedDescription }
            }
        }
    }
}

private struct CanvasHostTextSheet: View {
    let title: String; let prompt: String; let action: String; let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField(prompt, text: $text, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder)
                Spacer()
            }.padding(24)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(IDELanguageRunText.t("取消", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action) { submit(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

@MainActor private enum CanvasHostShare {
    static func present(_ urls: [URL]) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        }
        presenter.present(controller, animated: true)
    }
}
#endif
