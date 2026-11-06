// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import QuickLook
import FloeCanvasUI
import FloeCanvasIntegration
import FloeDiagramCore
import FloeDiagramUI
import FloeDiagramIntegration

struct PersonalContentEditor: View {
    let record: PersonalContentRecord
    @Environment(\.dismiss) private var dismiss
    @State private var content: LoadedContent?
    @State private var error: String?

    private enum LoadedContent {
        case canvas(CanvasEditorServices)
        case diagram(DiagramEditorModel)
        case file(URL)
    }

    var body: some View {
        Group {
            if let content, case .diagram(let model) = content {
                // This editor owns its split navigation. Wrapping that split in
                // another NavigationStack can discard its detail column.
                DiagramEditorView(model: model, onClose: { dismiss() })
            } else {
                navigationContent
            }
        }
        .task { await load() }
    }

    private var navigationContent: some View {
        NavigationStack {
            Group {
                if let content {
                    switch content {
                    case .canvas(let services):
                        CanvasEditorView(canvasID: record.id, services: services)
                    case .diagram(let model):
                        DiagramEditorView(model: model)
                    case .file(let url):
                        PersonalFilePreview(url: url)
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
                content = .canvas(CanvasEditorServices(documentStore: repository))
            case .diagram:
                let repository = try FileDiagramRepository(directory: value.url.appendingPathComponent("Diagram"))
                let assets = try FileDiagramAssets(directory: value.url.appendingPathComponent("Assets"))
                let document = try await repository.load(record.id)
                content = .diagram(DiagramEditorModel(document: document, repository: repository, assets: assets))
            case .document:
                content = .file(try await PersonalContentService.shared.originalFile(record.id))
            default:
                throw PersonalContentError.invalidProject
            }
            try await library.markOpened(record.id)
        } catch { self.error = error.localizedDescription }
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
