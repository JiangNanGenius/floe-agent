// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import QuickLook
import FloeCanvasUI
import FloeCanvasIntegration
import FloeDiagramCore
import FloeDiagramUI
import FloeDiagramIntegration
import FloeManufacturingUI

struct PersonalContentEditor: View {
    let record: PersonalContentRecord
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @State private var content: LoadedContent?
    @State private var error: String?
    @State private var showingAssistant = false

    private enum LoadedContent {
        case canvas(CanvasEditorStore)
        case diagram(DiagramEditorModel)
        case file(URL)
        case printing(PrintProjectSession)
        case manufacturing(ManufacturingModel)
        case music(MusicProjectSession)
        case meeting(MeetingProjectSession)
    }

    var body: some View {
        Group {
            if let content, case .diagram(let model) = content {
                // This editor owns its split navigation. Wrapping that split in
                // another NavigationStack can discard its detail column.
                DiagramEditorView(model: model, onClose: { Task { await model.close(); dismiss() } },
                    onAssistant: { showingAssistant = true })
            } else if let content, case .manufacturing(let model) = content {
                ManufacturingWorkbenchView(model: model, onClose: {
                    do { try model.saveDraft(); dismiss() } catch { model.report(error) }
                }, onAssistant: { showingAssistant = true })
            } else {
                navigationContent
            }
        }
        .task { await load() }
        .sheet(isPresented: $showingAssistant, onDismiss: { refreshEditor() }) {
            StudioAssistantView(record: record)
        }
        .onReceive(NotificationCenter.default.publisher(for: .floeStudioDocumentDidChange)) { notification in
            if notification.object as? UUID == record.id { refreshEditor() }
        }
    }

    private var navigationContent: some View {
        NavigationStack {
            Group {
                if let content {
                    switch content {
                    case .canvas(let store):
                        CanvasEditorView(store: store)
                    case .diagram(let model):
                        DiagramEditorView(model: model)
                    case .file(let url):
                        PersonalFilePreview(url: url)
                    case .printing(let session):
                        PrintProjectView(session: session)
                    case .manufacturing:
                        EmptyView()
                    case .music(let session):
                        MusicEditorView(session: session)
                    case .meeting(let session):
                        MeetingProjectView(session: session)
                    }
                } else if let error {
                    ContentUnavailableView {
                        Label(IDELanguageRunText.t("无法打开", "Unable to open"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(IDELanguageRunText.t("重试", "Retry")) { Task { await load() } }
                    }
                } else {
                    ProgressView(IDELanguageRunText.t("正在打开", "Opening"))
                }
            }
            .navigationTitle(record.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("完成", "Done")) { dismiss() }
                        .accessibilityIdentifier("space.editor.done")
                }
                if content != nil, record.kind != .document {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(IDELanguageRunText.t("作品助手", "Work assistant"), systemImage: "sparkles") {
                            showingAssistant = true
                        }.accessibilityIdentifier("space.editor.assistant")
                    }
                }
            }
        }
    }

    @MainActor private func load() async {
        error = nil
        do {
            let library = try await PersonalContentService.shared.library()
            let value = try await library.resolve(record.id)
            switch record.kind {
            case .canvas:
                let repository = try FileCanvasRepository(root: value.url.appendingPathComponent("Canvas"))
                _ = try await repository.load(canvasID: record.id)
                content = .canvas(CanvasEditorStore(canvasID: record.id,
                    services: CanvasEditorServices(documentStore: repository)))
            case .diagram:
                let repository = try FileDiagramRepository(directory: value.url.appendingPathComponent("Diagram"))
                let assets = try FileDiagramAssets(directory: value.url.appendingPathComponent("Assets"))
                let document = try await repository.load(record.id)
                content = .diagram(DiagramEditorModel(document: document, repository: repository, assets: assets))
            case .document:
                content = .file(try await PersonalContentService.shared.originalFile(record.id))
            case .printing:
                content = .printing(try await PrintProjectSession.open(id: record.id, directory: value.url.appendingPathComponent("Printing")))
            case .manufacturing:
                content = .manufacturing(ManufacturingSessions.open(id: record.id, directory: value.url.appendingPathComponent("Manufacturing")))
            case .music:
                content = .music(try await MusicProjectSession.open(id: record.id, directory: value.url.appendingPathComponent("Music"), environment: environment))
            case .meeting:
                content = .meeting(try await MeetingProjectSession.open(id: record.id, directory: value.url.appendingPathComponent("Meeting"), environment: environment))
            default:
                throw PersonalContentError.invalidProject
            }
            try await library.markOpened(record.id)
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func refreshEditor() {
        switch content {
        case .diagram(let model):
            model.flushPendingInk(); model.reload()
        case .canvas(let store):
            Task { await store.refreshFromHost() }
        case .meeting(let session): Task { await session.refresh() }
        default: break // These process-owned sessions are already observed.
        }
    }
}

private struct PersonalFilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
#endif
