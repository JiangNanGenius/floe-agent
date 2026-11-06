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

/// Feature-local chrome inside PersonalContentEditor's existing navigation.
/// The board, selection, history and drafts belong to the one injected store.
struct CreativeCanvasSurface: View {
    let record: PersonalContentRecord
    @ObservedObject var store: CanvasEditorStore
    @EnvironmentObject private var environment: AppEnvironment
    @State private var sheet: Sheet?
    @State private var importing = false
    @State private var diagnostic: String?
    @State private var busy = false
    private enum Sheet: String, Identifiable {
        case templates, sources, goal, saveTemplate
        var id: String { rawValue }
    }
    private var chinese: Bool { FloeL10n.currentLanguageCode.hasPrefix("zh") }

    var body: some View {
        CanvasEditorView(store: store)
            .overlay {
                if store.isLoaded && store.page.nodes.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.and.pencil.and.ellipsis").font(.largeTitle).foregroundStyle(.secondary)
                        Text(IDELanguageRunText.t("把想法放到画布上", "Put your ideas on the canvas")).font(.title3.bold())
                        Text(IDELanguageRunText.t("加入资料、选一个场景，或从目标开始。", "Add sources, choose a scenario, or start with a goal."))
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(IDELanguageRunText.t("浏览场景", "Browse scenarios")) { sheet = .templates }
                                .buttonStyle(.borderedProminent)
                            Button(IDELanguageRunText.t("添加资料", "Add sources")) { sheet = .sources }
                                .buttonStyle(.bordered)
                        }
                    }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(IDELanguageRunText.t("导入素材", "Import media"), systemImage: "square.and.arrow.down") { importing = true }
                        Button(IDELanguageRunText.t("引用资料或作品", "Link a source or work"), systemImage: "link") { sheet = .sources }
                        Divider()
                        Button(IDELanguageRunText.t("加入场景与流程", "Add a scenario or workflow"), systemImage: "square.grid.2x2") { sheet = .templates }
                        Button(IDELanguageRunText.t("从目标生成初稿", "Draft from a goal"), systemImage: "sparkles.rectangle.stack") { sheet = .goal }
                        Button(IDELanguageRunText.t("存为我的流程", "Save as my workflow"), systemImage: "square.and.arrow.up.on.square") { sheet = .saveTemplate }
                        Divider()
                        Menu(IDELanguageRunText.t("导出", "Export"), systemImage: "square.and.arrow.up") {
                            ForEach(CanvasExchangeFormat.allCases, id: \.self) { format in
                                Button(exportTitle(format)) { Task { await export(format) } }
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
                    } label: { Label(IDELanguageRunText.t("画布", "Canvas"), systemImage: "ellipsis.circle") }
                    .disabled(busy || store.isMutating)
                    .accessibilityIdentifier("canvas.host.actions")
                }
            }
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

    @MainActor private func session() async throws -> CanvasHostSession {
        let location = try await PersonalContentService.shared.library().resolve(record.id)
        return try await CanvasHostSessions.shared.session(record: location.record, directory: location.url, environment: environment)
    }
    @MainActor private func append(_ template: CanvasTemplate) async {
        busy = true; defer { busy = false }
        do {
            let session = try await session()
            let workspace = CanvasTemplateWorkspace(documents: session.repository, library: try CanvasHostServices.templateLibrary(),
                ownershipResolver: CanvasHostOwnershipResolver())
            let activated = try await workspace.activate(canvasID: record.id, pageID: store.selectedPageID)
            let receipt = try await workspace.append(template, to: activated)
            await store.refreshFromHost(); await store.selectPage(receipt.pageID); store.fitToContent()
            try await PersonalContentService.shared.library().markChanged(record.id)
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
            try await PersonalContentService.shared.library().markChanged(record.id)
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
    func ownership(for projectID: UUID) async throws -> TemplateOwnership {
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
