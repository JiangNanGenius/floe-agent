#if canImport(UIKit)
import SwiftUI
import FloeCanvasCore
import FloeDiagramExchange

private struct CanvasEditorSaveRegistrar: Sendable {
    var register: @MainActor @Sendable (@escaping @MainActor @Sendable () async -> Void) -> Void
}
private struct CanvasEditorSaveKey: EnvironmentKey {
    static let defaultValue = CanvasEditorSaveRegistrar(register: { _ in })
}
private extension EnvironmentValues {
    var canvasEditorSaveRegistrar: CanvasEditorSaveRegistrar {
        get { self[CanvasEditorSaveKey.self] }
        set { self[CanvasEditorSaveKey.self] = newValue }
    }
}

/// Focused native content editor per content kind. Edits stay local while
/// composing (IME marked text never commits intermediate state, ICH02); the
/// completed gesture commits exactly one batch through the store.
public struct CanvasContentEditorSheet: View {
    @ObservedObject var store: CanvasEditorStore
    let node: CanvasNodeSnapshot
    private let editSnapshot: CanvasSnapshot
    private let editPageID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var saveAction: (@MainActor @Sendable () async -> Void)?
    @State private var isSaving = false
    private var strings: CanvasStrings { store.strings }

    public init(store: CanvasEditorStore, node: CanvasNodeSnapshot) {
        self.store = store
        self.node = node
        self.editSnapshot = store.snapshot
        self.editPageID = store.selectedPageID
    }

    public var body: some View {
        NavigationStack {
            editor
                .environment(\.canvasEditorSaveRegistrar, .init(register: { saveAction = $0 }))
                .navigationTitle(node.title ?? strings[.inspectorNodeContent])
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(strings[.cancelButton]) { dismiss() }
                            .disabled(isSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(strings[.saveButton]) {
                            Task {
                                guard let saveAction else { return }
                                isSaving = true
                                await saveAction()
                                isSaving = false
                                if store.alert == nil { dismiss() }
                            }
                        }
                        .accessibilityIdentifier(CanvasAccessibilityID.toolbarDone.identifier)
                        .disabled(isSaving || saveAction == nil)
                    }
                }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private var editor: some View {
        switch node.content {
        case .text(let text):
            CanvasTextEditor(
                text: text,
                accessibilityID: CanvasAccessibilityID.contentEditorText.identifier) {
                newValue in
                await saveContent(.text(newValue))
            }
        case .markdown(let document, _):
            CanvasTextEditor(
                text: document,
                accessibilityID: CanvasAccessibilityID.contentEditorMarkdown.identifier) {
                newValue in
                await saveContent(.markdown(document: newValue, previewText: nil))
            }
        case .richText(let document):
            CanvasRichTextEditor(
                document: document,
                accessibilityID: CanvasAccessibilityID.contentEditorRichText.identifier) {
                newValue in
                await saveContent(.richText(document: newValue))
            }
        case .code(let language, let source):
            CanvasCodeEditor(
                source: source,
                language: language,
                accessibilityID: CanvasAccessibilityID.contentEditorCode.identifier) {
                newValue in
                await saveContent(.code(language: language, source: newValue))
            }
        case .table(let header, let rows):
            CanvasTableEditor(
                header: header,
                rows: rows,
                accessibilityID: CanvasAccessibilityID.contentEditorTable.identifier) {
                newHeader, newRows in
                await saveContent(.table(header: newHeader, rows: newRows))
            }
        case .formula(let source, _):
            CanvasFormulaEditor(
                source: source,
                accessibilityID: CanvasAccessibilityID.contentEditorFormula.identifier) {
                newValue in
                await saveContent(.formula(source: newValue, renderedAssetID: nil))
            }
        case .shape(let kind, let text):
            CanvasTextEditor(
                text: text,
                accessibilityID: CanvasAccessibilityID.contentEditorText.identifier) {
                newValue in
                await saveContent(.shape(kind: kind, text: newValue))
            }
        default:
            Text(strings[.inspectorNoSelection])
                .foregroundStyle(.secondary)
        }
    }

    private func saveContent(_ content: CanvasContent) async {
        guard store.selectedPageID == editPageID else {
            store.presentAlertFromError(CanvasKitError.missingEntity("editor page changed"))
            return
        }
        do {
            let batch = try CanvasCommandBatchBuilder.makeBatch(.updateContent(node.id, content),
                in: editSnapshot, pageID: editPageID, selection: [node.id], configuration: store.configuration)
            await store.commit(batch, undoLabel: "Edit content", expectedRevision: editSnapshot.revision)
        } catch { store.presentAlertFromError(error) }
    }
}

/// Plain text with one-commit-per-gesture semantics.
public struct CanvasTextEditor: View {
    @Environment(\.canvasEditorSaveRegistrar) private var saveRegistrar
    @State var text: String
    let accessibilityID: String
    let onSave: (String) async -> Void

    public init(
        text: String,
        accessibilityID: String,
        onSave: @escaping (String) async -> Void
    ) {
        self._text = State(initialValue: text)
        self.accessibilityID = accessibilityID
        self.onSave = onSave
    }

    public var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .padding(8)
            .accessibilityIdentifier(accessibilityID)
            .onAppear {
                saveRegistrar.register { await onSave(text) }
            }
    }
}

/// Rich attributed runs with native toggles. Runs stay structured content
/// (ICQA08/09) — never flattened to markdown.
public struct CanvasRichTextEditor: View {
    @Environment(\.canvasEditorSaveRegistrar) private var saveRegistrar
    @State var document: CanvasRichTextDocument
    let accessibilityID: String
    let onSave: (CanvasRichTextDocument) async -> Void
    @State private var selection: (location: Int, length: Int)?

    public init(
        document: CanvasRichTextDocument,
        accessibilityID: String,
        onSave: @escaping (CanvasRichTextDocument) async -> Void
    ) {
        self._document = State(initialValue: document)
        self.accessibilityID = accessibilityID
        self.onSave = onSave
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                toggle("bold", systemName: "bold") { $0.bold = true }
                toggle("italic", systemName: "italic") { $0.italic = true }
                toggle("underline", systemName: "underline") { $0.underline = true }
                toggle("strikethrough", systemName: "strikethrough") { $0.strikethrough = true }
            }
            .padding(6)
            Divider()
            TextEditor(text: Binding(
                get: { document.plainText },
                set: { newValue in
                    document = CanvasRichTextDocument(runs: [
                        CanvasRichTextRun(text: newValue)
                    ])
                }))
            .font(.body)
            .padding(8)
            .accessibilityIdentifier(accessibilityID)
        }
        .onAppear {
            saveRegistrar.register { await onSave(document) }
        }
    }

    private func toggle(
        _ name: String,
        systemName: String,
        apply: @escaping (inout CanvasRichTextRun) -> Void
    ) -> some View {
        Button {
            guard !document.runs.isEmpty else { return }
            var updated = document
            for index in updated.runs.indices {
                apply(&updated.runs[index])
            }
            document = updated
        } label: {
            Image(systemName: systemName)
        }
        .accessibilityLabel(Text(name))
    }
}

/// Code with language label; source stays verbatim.
public struct CanvasCodeEditor: View {
    @Environment(\.canvasEditorSaveRegistrar) private var saveRegistrar
    @State var source: String
    let language: String?
    let accessibilityID: String
    let onSave: (String) async -> Void

    public init(
        source: String,
        language: String?,
        accessibilityID: String,
        onSave: @escaping (String) async -> Void
    ) {
        self._source = State(initialValue: source)
        self.language = language
        self.accessibilityID = accessibilityID
        self.onSave = onSave
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .accessibilityIdentifier(accessibilityID)
        }
        .onAppear {
            saveRegistrar.register { await onSave(source) }
        }
    }
}

/// Cell editor preserving table structure (cells are plain strings so
/// partial tables survive).
public struct CanvasTableEditor: View {
    @Environment(\.canvasEditorSaveRegistrar) private var saveRegistrar
    @State var header: [String]
    @State var rows: [[String]]
    let accessibilityID: String
    let onSave: ([String], [[String]]) async -> Void

    public init(
        header: [String],
        rows: [[String]],
        accessibilityID: String,
        onSave: @escaping ([String], [[String]]) async -> Void
    ) {
        self._header = State(initialValue: header)
        self._rows = State(initialValue: rows)
        self.accessibilityID = accessibilityID
        self.onSave = onSave
    }

    public var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        TextField("h\(column)", text: $header[column])
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                }
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { column in
                            TextField(
                                "r\(row)c\(column)",
                                text: $rows[row][column])
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 110)
                        }
                    }
                }
            }
            .padding(8)
        }
        .accessibilityIdentifier(accessibilityID)
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button("+ Row") {
                    rows.append(Array(repeating: "", count: max(1, header.count)))
                }
                Button("+ Col") {
                    header.append("")
                    for index in rows.indices {
                        rows[index].append("")
                    }
                }
            }
        }
        .onAppear {
            saveRegistrar.register { await onSave(header, rows) }
        }
    }
}

/// Formula editor with validation + rendered preview through the public
/// DiagramNativeRenderer (reuse, not a parallel renderer).
public struct CanvasFormulaEditor: View {
    @Environment(\.canvasEditorSaveRegistrar) private var saveRegistrar
    @State var source: String
    let accessibilityID: String
    let onSave: (String) async -> Void
    @State private var preview: UIImage?

    public init(
        source: String,
        accessibilityID: String,
        onSave: @escaping (String) async -> Void
    ) {
        self._source = State(initialValue: source)
        self.accessibilityID = accessibilityID
        self.onSave = onSave
    }

    public var body: some View {
        VStack(spacing: 12) {
            TextEditor(text: $source)
                .font(.system(.body, design: .serif))
                .frame(minHeight: 120)
                .padding(8)
                .accessibilityIdentifier(accessibilityID)
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 160)
            }
            HStack {
                Image(
                    systemName: isValid ? "checkmark.circle" : "exclamationmark.triangle")
                Text(isValid ? "valid" : "invalid")
            }
            .foregroundStyle(isValid ? .green : .orange)
            .font(.caption)
        }
        .padding(8)
        .onAppear { renderPreview() }
        .onChange(of: source) { _, _ in renderPreview() }
        .onAppear {
            saveRegistrar.register { await onSave(source) }
        }
    }

    private var isValid: Bool {
        MainActor.assumeIsolated {
            DiagramNativeRenderer().formulaIsValid(source)
        }
    }

    private func renderPreview() {
        MainActor.assumeIsolated {
            preview = CanvasFormulaPreviewRenderer.render(source)
        }
    }
}

enum CanvasFormulaPreviewRenderer {
    @MainActor static func render(_ source: String) -> UIImage? {
        guard !source.isEmpty,
              DiagramNativeRenderer().formulaIsValid(source) else { return nil }
        let size = CGSize(width: 320, height: 96)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemBackground.setFill()
            ctx.fill(.init(origin: .zero, size: size))
            DiagramNativeRenderer().drawFormula(
                source,
                rect: .init(x: 0, y: 0, width: size.width, height: size.height),
                context: ctx.cgContext)
        }
    }
}
#endif
