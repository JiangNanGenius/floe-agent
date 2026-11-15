import SwiftUI
import FloeChemistryCore
import FloeChemistryEngine

@MainActor struct ChemistryMoleculePreviewPane: View {
    let editor: ChemistryEditorState
    let object: ChemicalObject
    @Binding var selectedAtoms: [Int]
    @State private var previewAtoms: [Int] = []
    @State private var attempt = UUID()
    @State private var activeID: UUID?
    @State private var cancelledInput: Input?
    @State private var worker: Task<ChemistryMoleculePreview, Error>?
    @State private var phase = Phase.loading

    private enum Phase { case loading, ready(Input, ChemistryMoleculePreview), failed(String), cancelled }
    private struct Input: Equatable { let object: ChemicalObject; let attempt: UUID }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView(chemistryText("Preparing 3D preview…", "正在准备三维预览…")).accessibilityIdentifier("chemistry.preview.loading")
                    Button(chemistryText("Cancel", "取消")) {
                        cancelledInput = Input(object: object, attempt: attempt)
                        activeID = nil
                        worker?.cancel()
                        worker = nil
                        phase = .cancelled
                    }.accessibilityIdentifier("chemistry.preview.cancel")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .cancelled:
                message(chemistryText("Preview cancelled", "已取消预览"), identifier: "chemistry.preview.cancelled")
            case .failed(let text):
                message(text, identifier: "chemistry.preview.error")
            case .ready(let input, let preview):
                if input == Input(object: object, attempt: attempt) {
                    ChemistryMoleculeView(object: ChemicalObject(id: object.id, title: object.title, format: "cjson", source: preview.cjson,
                        revision: object.revision), selectedAtoms: preview.origin == .original ? $selectedAtoms : $previewAtoms,
                        previewOrigin: preview.origin, optimizationStatus: preview.optimizationStatus)
                } else {
                    ProgressView(chemistryText("Preparing 3D preview…", "正在准备三维预览…"))
                }
            }
        }
        .task(id: Input(object: object, attempt: attempt)) { await load() }
    }

    private func message(_ text: String, identifier: String) -> some View {
        VStack(spacing: 12) {
            Text(text).multilineTextAlignment(.center).accessibilityIdentifier(identifier)
            Button(chemistryText("Try again", "重试")) { attempt = UUID() }.accessibilityIdentifier("chemistry.preview.retry")
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        let input = Input(object: object, attempt: attempt)
        guard cancelledInput != input else { phase = .cancelled; return }
        let id = UUID()
        worker?.cancel()
        activeID = id
        phase = .loading
        previewAtoms = []
        let task = Task { try await editor.moleculePreview(for: object) }
        worker = task
        defer { if activeID == id { worker = nil } }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard activeID == id, editor.selectedID == object.id, editor.selected == object else { return }
            phase = .ready(input, result)
        } catch {
            guard !Task.isCancelled, activeID == id else { return }
            if error is CancellationError { phase = .cancelled; return }
            let text: String
            switch error as? ChemistryPreviewError {
            case .emptyDrawing: text = chemistryText("Add an atom to the drawing first.", "请先在绘图中添加原子。")
            case .tooLarge: text = chemistryText("This molecule is too large for a local preview.", "分子超出本机预览大小限制。")
            case .timedOut: text = chemistryText("The preview timed out. Try again.", "预览生成超时，可重试。")
            case .changed: text = chemistryText("The drawing changed. Preview the saved structure again.", "绘图已更改，请重新预览已保存的结构。")
            case .unsupported, .invalidMolecule: text = chemistryText("Use a single, complete molecule for this preview.", "请使用一个完整的分子结构生成预览。")
            default: text = chemistryText("Couldn’t open the 3D preview. Check the drawing and try again.", "无法打开三维预览，请检查绘图后重试。")
            }
            phase = .failed(text)
        }
    }
}
