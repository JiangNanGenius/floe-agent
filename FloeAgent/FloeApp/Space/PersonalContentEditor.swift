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
import FloeNotes
import FloeCAD
import FloeChemistryUI

struct PersonalContentEditor: View {
    let record: PersonalContentRecord
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @State private var content: LoadedContent?
    @State private var error: String?
    @State private var showingAssistant = false
    @State private var childWork: PersonalContentRecord?
    @State private var sourceNote: NoteDocument?
    @State private var sourceNotes = NotesSession()
    @State private var printPreparation: PrintPreparationRequest?
    @State private var printPreparationError: String?
    @State private var chemistryNotesRequest: ChemistryNotesRequest?
    @State private var chemistryEpoch = UUID()

    private struct ChemistryNotesRequest: Identifiable {
        let id = UUID()
        let recordID: UUID
        let projectID: UUID
        let objectID: UUID?
    }

    private enum LoadedContent {
        case canvas(CanvasEditorStore)
        case diagram(DiagramEditorModel)
        case file(URL)
        case printing(PrintProjectSession)
        case manufacturing(ManufacturingModel)
        case music(MusicProjectSession)
        case meeting(MeetingProjectSession)
        case chemistry(ChemistryProjectSession)
        case text(PersonalTextDocument)
        case office(PersonalOfficeDocument)
        case media(URL)
        case cad(FloeCADDocument)
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
            } else if let content, case .office(let document) = content {
                NavigationStack {
                    PersonalOfficeDocumentView(document: document, onClose: { dismiss() },
                        onAssistant: { showingAssistant = true })
                }
            } else {
                navigationContent
            }
        }
        .task { await load() }
        .interactiveDismissDisabled()
        .environment(\.cadWorkbenchTransientlyCovered, showingAssistant || childWork != nil || sourceNote != nil || printPreparation != nil)
        .sheet(item: $printPreparation, onDismiss: { refreshEditor() }) { request in
            PrintPreparationSheet(request: request)
        }
        .alert(IDELanguageRunText.t("无法准备打印", "Unable to prepare print"), isPresented: Binding(
            get: { printPreparationError != nil }, set: { if !$0 { printPreparationError = nil } })) {
            Button(IDELanguageRunText.t("好", "OK")) { printPreparationError = nil }
        } message: { Text(printPreparationError ?? "") }
        .onChange(of: record.id) { _, _ in
            printPreparation = nil; chemistryNotesRequest = nil; chemistryEpoch = UUID()
        }
        .sheet(item: $chemistryNotesRequest, onDismiss: { refreshEditor() }) { request in
            NotesChemistryReturnSheet(recordID: request.recordID, projectID: request.projectID, objectID: request.objectID)
        }
        .sheet(isPresented: $showingAssistant, onDismiss: { refreshEditor() }) {
            StudioAssistantView(record: record)
        }
        .sheet(item: $childWork, onDismiss: { refreshEditor() }) { value in
            PersonalContentEditor(record: value)
        }
        .sheet(item: $sourceNote, onDismiss: { refreshEditor() }) { value in
            NavigationStack {
                if let current = sourceNotes.document, current.id == value.id {
                    NotesDocumentEditor(session: sourceNotes, document: current, embedded: true)
                        .modifier(NotesConflictAccess(session: sourceNotes))
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button(IDELanguageRunText.t("完成", "Done")) { sourceNote = nil }
                        } }
                }
            }
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
                        CreativeCanvasSurface(record: record, store: store)
                    case .diagram(let model):
                        DiagramEditorView(model: model)
                    case .file(let url):
                        PersonalFilePreview(url: url)
                    case .printing(let session):
                        PrintProjectView(session: session)
                    case .manufacturing:
                        EmptyView()
                    case .music(let session):
                        MusicEditorView(session: session, onAssistant: { showingAssistant = true })
                    case .meeting(let session):
                        MeetingProjectView(session: session)
                    case .chemistry(let session):
                        chemistrySurface(session)
                    case .text(let document):
                        PersonalTextDocumentView(document: document)
                    case .office:
                        EmptyView() // The Office branch above owns guarded close and chrome.
                    case .media(let directory):
                        PersonalMediaEditorView(record: record, directory: directory, onAssistant: { showingAssistant = true })
                    case .cad(let document):
                        if record.kind == .cad2D { FloeCAD2DWorkbenchView(document: document) }
                        else { FloeCADWorkbenchView(document: document) }
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
                    Button(IDELanguageRunText.t("完成", "Done")) { Task { await finish() } }
                        .accessibilityIdentifier("space.editor.done")
                }
                if canPreparePrint {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(IDELanguageRunText.t("准备打印", "Prepare Print"), systemImage: "printer") {
                            Task { await preparePrint() }
                        }.accessibilityIdentifier("space.editor.preparePrint")
                    }
                }
                if content != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(IDELanguageRunText.t("作品助手", "Work assistant"), systemImage: "sparkles") {
                            showingAssistant = true
                        }.accessibilityIdentifier("space.editor.assistant")
                    }
                }
            }
        }
    }

    @MainActor private func chemistrySurface(_ session: ChemistryProjectSession) -> some View {
        let epoch = chemistryEpoch
        return ChemistryEditorSurface(session: session, onInsertIntoNotes: { recordID, projectID, objectID in
            guard chemistryEpoch == epoch, record.id == recordID, projectID == recordID else { throw CancellationError() }
            chemistryNotesRequest = .init(recordID: recordID, projectID: projectID, objectID: objectID)
        })
    }

    private var canPreparePrint: Bool {
        switch content {
        case .cad(let document): return !document.isClosed
        case .file(let url): return PrintProjectHandoff.fileExtensions.contains(url.pathExtension.lowercased())
        default: return false
        }
    }
    @MainActor private func preparePrint() async {
        do {
            let document: FloeCADDocument?
            if case .cad(let value) = content { document = value } else { document = nil }
            printPreparation = try await PrintProjectHandoff.personalRequest(record: record, document: document)
        } catch { printPreparationError = error.localizedDescription }
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
                let navigation = CanvasHostNavigation(openWork: { id in
                    let work = try await library.resolve(id)
                    childWork = work.record
                }, openSource: { id, _ in
                    if let work = try? await library.resolve(id) {
                        childWork = work.record
                    } else {
                        let store = try await NotesRepository.shared.store()
                        let note = try await store.document(id)
                        guard note.deletedAt == nil else { throw PersonalContentError.missingDocument }
                        await sourceNotes.open(using: store)
                        _ = await sourceNotes.select(note)
                        sourceNote = note
                    }
                }, openAssistant: { _ in showingAssistant = true })
                let services = try await CanvasHostServices.make(record: record, directory: value.url,
                    environment: environment, navigation: navigation)
                content = .canvas(CanvasEditorStore(canvasID: record.id,
                    services: services))
            case .diagram:
                let repository = try FileDiagramRepository(directory: value.url.appendingPathComponent("Diagram"))
                let assets = try FileDiagramAssets(directory: value.url.appendingPathComponent("Assets"))
                let document = try await repository.load(record.id)
                content = .diagram(DiagramEditorModel(document: document, repository: repository, assets: assets))
            case .document:
                let file = try await PersonalContentService.shared.originalFile(record.id)
                if WorkspaceFileType.isOffice(file.lastPathComponent) {
                    content = .office(try await PersonalOfficeDocument.open(record: record, directory: value.url, url: file))
                } else if ["md", "markdown", "txt", "json", "csv", "yaml", "yml"].contains(file.pathExtension.lowercased()) {
                    content = .text(try PersonalTextDocument.open(url: file, projectID: record.id))
                } else { content = .file(file) }
            case .image, .drawing, .video:
                try await PersonalMediaFactory.verify(kind: record.kind, id: record.id, directory: value.url)
                content = .media(value.url)
            case .cad2D, .cad3D:
                content = .cad(try await PersonalCADSessions.open(id: record.id, directory: value.url))
            case .printing:
                content = .printing(try await PrintProjectSession.open(id: record.id, directory: value.url.appendingPathComponent("Printing")))
            case .manufacturing:
                content = .manufacturing(ManufacturingSessions.open(id: record.id, directory: value.url.appendingPathComponent("Manufacturing")))
            case .music:
                content = .music(try await MusicProjectSession.open(id: record.id, directory: value.url.appendingPathComponent("Music"), environment: environment))
            case .chemistry:
                let epoch = chemistryEpoch
                let session = try await ChemistryProjectSession.open(id: record.id, directory: value.url, environment: environment)
                guard chemistryEpoch == epoch else { throw CancellationError() }
                content = .chemistry(session)
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
        case .chemistry(let session): Task { await session.refreshFromHost() }
        default: break // These process-owned sessions are already observed.
        }
    }
    @MainActor private func finish() async {
        switch content {
        case .text(let document): guard await document.close() else { return }
        case .chemistry(let session): guard await session.flushForClose() else { return }
        case .cad(let document):
            let saved = await document.save()
            guard saved.succeeded else { error = saved.error; return }
            document.close()
        default: break
        }
        dismiss()
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
