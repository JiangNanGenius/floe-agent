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
import FloeElectronicsUI

struct PersonalContentEditor: View {
    let record: PersonalContentRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var environment: AppEnvironment
    @State private var fileUsage: PersonalLibraryUsageLease?
    @State private var content: LoadedContent?
    @State private var error: String?
    @State private var showingAssistant = false
    @State private var childWork: PersonalContentRecord?
    @State private var sourceNote: NoteDocument?
    @State private var sourceNotes = NotesSession()
    @State private var printPreparation: PrintPreparationRequest?
    @State private var printPreparationError: String?
    @State private var cadImportRequest: PersonalCADImportRequest?
    @State private var importedCADRecord: PersonalContentRecord?
    @State private var chemistryNotesRequest: ChemistryNotesRequest?
    @State private var chemistryEpoch = UUID()
    @StateObject private var biologyNotesReturn = BiologyNotesReturn()
    @StateObject private var assistantLeave = DocumentAssistantLeaveCoordinator()
    @StateObject private var sourceAssistantLeave = DocumentAssistantLeaveCoordinator()
    @State private var closing = false
    @State private var presentationGeneration = UUID()
    @State private var editorOwnsTextInput = false
    @State private var officeReopenInFlight = false

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
        case biology(BiologyProjectSession)
        case latex(LaTeXProjectSession)
        case electronics(ElectronicsProjectSession)
        case geography(GISProjectSession)
        case text(PersonalTextDocument)
        case office(PersonalOfficeDocument)
        case media(URL)
        case cad(FloeCADDocument)
    }

    var body: some View {
        GeometryReader { viewport in
            editorPresentation
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
                .editorLayoutObservation("presentation.frame")
        }
        .editorLayoutObservation("presentation.viewport")
        .ignoresSafeArea(.keyboard, edges: canvasKeyboardEdges)
    }

    private var canvasKeyboardEdges: Edge.Set {
        let office: Bool
        if case .office? = content { office = true } else { office = false }
        let canvas = office || [.music, .cad2D, .cad3D, .drawing, .image, .video, .electronics, .chemistry].contains(record.kind)
        return canvas && !editorOwnsTextInput ? .bottom : []
    }

    private var editorPresentation: some View {
        Group {
            if let content, case .diagram(let model) = content {
                // This editor owns its split navigation. Wrapping that split in
                // another NavigationStack can discard its detail column.
                DiagramEditorView(model: model, onClose: { Task { await finish() } },
                    onAssistant: { showingAssistant = true })
            } else if let content, case .canvas(let store) = content {
                // The original canvas owns its split navigation and close path.
                CreativeCanvasSurface(record: record, store: store)
            } else if let content, case .geography(let session) = content {
                GISProjectEditorSurface(session: session, onClose: { Task { await finish() } },
                    onAssistant: { showingAssistant = true })
            } else if let content, case .manufacturing(let model) = content {
                ManufacturingWorkbenchView(model: model, onClose: {
                    Task { await finish() }
                }, onAssistant: { showingAssistant = true })
            } else if let content, case .office(let document) = content {
                NavigationStack {
                    PersonalOfficeDocumentView(document: document, onClose: { dismissAfterClosing() },
                        onAssistant: { showingAssistant = true },
                        presentationIsActive: isPresented,
                        onRetryOpen: { Task { await reopenOffice(document) } },
                        beforeClose: { await authorizeAssistantDeparture() })
                        .id(ObjectIdentifier(document))
                        .ignoresSafeArea(.keyboard, edges: canvasKeyboardEdges)
                        .editorLayoutObservation("office.original")
                        .background {
                            EditorInputOwnership(ownerID: record.id) { editorOwnsTextInput = $0 }
                                .id(record.id).allowsHitTesting(false)
                        }
                }
                .editorLayoutObservation("office.navigation.host")
                .ignoresSafeArea(.keyboard, edges: canvasKeyboardEdges)
            } else {
                navigationContent
            }
        }
        .task { await load() }
        .interactiveDismissDisabled()
        .documentAssistantLeavePresentation(assistantLeave)
        .environment(\.documentAssistantLeaveIntent, DocumentAssistantLeaveIntent(authorize: {
            guard !closing else { return false }
            closing = true; defer { closing = false }
            return await authorizeAssistantDeparture()
        }))
        .onChange(of: isPresented) { _, presented in
            if !presented {
                presentationGeneration = UUID()
                biologyNotesReturn.cancel()
                if case .biology(let session) = content { Task { await session.close() } }
                if case .geography(let session) = content { Task { await session.presentationEnded() } }
                if case .office(let document) = content { Task { await document.unmount() } }
                fileUsage?.release(); fileUsage = nil
            }
        }
        .onDisappear {
            // An internal full-screen preview still covers a presented editor.
            // Only dismissal releases its ownership; state deinit is a fallback.
            if !isPresented { fileUsage?.release(); fileUsage = nil }
        }
        .environment(\.editorCanvasOwnsTextInput, editorOwnsTextInput)
        .environment(\.cadWorkbenchTransientlyCovered,
                     (showingAssistant && horizontalSizeClass != .regular)
                     || childWork != nil || sourceNote != nil || printPreparation != nil)
        .sheet(item: $printPreparation, onDismiss: { refreshEditor() }) { request in
            PrintPreparationSheet(request: request)
        }
        .alert(IDELanguageRunText.t("无法准备打印", "Unable to prepare print"), isPresented: Binding(
            get: { printPreparationError != nil }, set: { if !$0 { printPreparationError = nil } })) {
            Button(IDELanguageRunText.t("好", "OK")) { printPreparationError = nil }
        } message: { Text(printPreparationError ?? "") }
        .onChange(of: record.id) { _, _ in
            presentationGeneration = UUID()
            editorOwnsTextInput = false
            biologyNotesReturn.cancel()
            showingAssistant = false
            printPreparation = nil; chemistryNotesRequest = nil; chemistryEpoch = UUID()
            cadImportRequest = nil; importedCADRecord = nil
        }
        .sheet(item: $chemistryNotesRequest, onDismiss: { refreshEditor() }) { request in
            NotesChemistryReturnSheet(recordID: request.recordID, projectID: request.projectID, objectID: request.objectID)
        }
        .sheet(item: Binding(get: { biologyNotesReturn.request }, set: { if $0 == nil { biologyNotesReturn.cancel() } }),
               onDismiss: { biologyNotesReturn.cancel(); refreshEditor() }) { request in
            BiologyNotesReturnSheet(request: request) { result in biologyNotesReturn.finish(id: request.id, result: result) }
        }
        .inspector(isPresented: Binding(get: { showingAssistant && record.kind != .meeting },
                                        set: { if record.kind != .meeting { showingAssistant = $0 } })) {
            StudioAssistantView(record: record, onClose: { showingAssistant = false })
                .id(record.id)
                .inspectorColumnWidth(min: 320, ideal: 420, max: 520)
        }
        .onChange(of: showingAssistant) { _, visible in
            if !visible, record.kind != .meeting { refreshEditor() }
        }
        .sheet(item: $childWork, onDismiss: { refreshEditor() }) { value in
            PersonalContentEditor(record: value)
        }
        .sheet(item: $cadImportRequest, onDismiss: {
            if let value = importedCADRecord { importedCADRecord = nil; childWork = value }
        }) { request in
            PersonalCADImportSheet(request: request) { value in
                importedCADRecord = value; cadImportRequest = nil
            }
        }
        .sheet(item: $sourceNote, onDismiss: { refreshEditor() }) { value in
            NavigationStack {
                if let current = sourceNotes.document, current.id == value.id {
                    NotesDocumentEditor(session: sourceNotes, document: current, embedded: true)
                        .modifier(NotesConflictAccess(session: sourceNotes))
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button(IDELanguageRunText.t("完成", "Done")) {
                                Task { if await sourceNotes.select(nil) { sourceNote = nil } }
                            }
                        } }
                }
            }
            .interactiveDismissDisabled()
            .documentAssistantLeavePresentation(sourceAssistantLeave)
            .task {
                DocumentAssistantLeaveBindings.installNotes(on: sourceNotes, environment: environment,
                                                            coordinator: sourceAssistantLeave)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .floeStudioDocumentDidChange)) { notification in
            if notification.object as? UUID == record.id { refreshEditor() }
        }
    }

    @ViewBuilder private var navigationContent: some View {
        if let content, case .cad(let document) = content {
            // Building is a navigation sibling of the viewport. Keep its host
            // presenter above the stack so the destination and sheet share it.
            editorNavigation.modifier(CADBuildingProfessionalEntry(document: document))
        } else {
            editorNavigation
        }
    }

    private var editorNavigation: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
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
                        MusicEditorView(session: session)
                            .ignoresSafeArea(.keyboard, edges: canvasKeyboardEdges)
                            .editorLayoutObservation("music")
                            .background {
                                EditorInputOwnership(ownerID: record.id) { editorOwnsTextInput = $0 }
                                    .id(record.id).allowsHitTesting(false)
                            }
                    case .meeting(let session):
                        MeetingProjectView(session: session, record: record, assistantRequested: $showingAssistant)
                    case .chemistry(let session):
                        chemistrySurface(session)
                            .ignoresSafeArea(.keyboard, edges: canvasKeyboardEdges)
                            .editorLayoutObservation("chemistry")
                            .background {
                                EditorInputOwnership(ownerID: record.id) { editorOwnsTextInput = $0 }
                                    .id(record.id).allowsHitTesting(false)
                            }
                    case .biology(let session):
                        BiologyEditorSurface(session: session, onInsertIntoNotes: { [returns = biologyNotesReturn] payload in
                            try await returns.insert(payload, host: session.host)
                        })
                    case .latex(let session):
                        LaTeXEditorSurface(session:session)
                    case .electronics(let session):
                        ElectronicsEditorSurface(session: session)
                            .ignoresSafeArea(.keyboard, edges: canvasKeyboardEdges)
                            .editorLayoutObservation("electronics")
                            .background {
                                EditorInputOwnership(ownerID: record.id) { editorOwnsTextInput = $0 }
                                    .id(record.id).allowsHitTesting(false)
                            }
                    case .geography:
                        EmptyView() // GIS owns its qualified native split-view chrome above.
                    case .text(let document):
                        PersonalTextDocumentView(document: document)
                    case .office:
                        EmptyView() // The Office branch above owns guarded close and chrome.
                    case .media(let directory):
                        PersonalMediaEditorView(record: record, directory: directory, onAssistant: { showingAssistant = true })
                            .ignoresSafeArea(.keyboard, edges: canvasKeyboardEdges)
                            .editorLayoutObservation("media")
                            .background {
                                EditorInputOwnership(ownerID: record.id) { editorOwnsTextInput = $0 }
                                    .id(record.id).allowsHitTesting(false)
                            }
                    case .cad(let document):
                        Group {
                            if record.kind == .cad2D { FloeCAD2DWorkbenchView(document: document) }
                            else { FloeCADWorkbenchView(document: document) }
                        }
                        .environment(\.cadCanvasKeyboardAvoidanceEnabled, editorOwnsTextInput)
                        .modifier(CADManufacturingEntry(document: document,
                            directory: document.url.deletingLastPathComponent().appendingPathComponent("Manufacturing", isDirectory: true),
                            ownerID: record.id,
                            onPreparePrint: { Task { await preparePrint() } },
                            onAssistant: { showingAssistant = true }))
                        .modifier(CADSimulationEntry(document:document,
                            directory:document.url.deletingLastPathComponent().appendingPathComponent("Simulation",isDirectory:true),ownerID:record.id))
                        .ignoresSafeArea(.keyboard, edges: canvasKeyboardEdges)
                        .editorLayoutObservation("cad")
                        .background {
                            EditorInputOwnership(ownerID: record.id) { editorOwnsTextInput = $0 }
                                .id(record.id).allowsHitTesting(false)
                        }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.keyboard, edges: canvasKeyboardEdges)
            .editorLayoutObservation("navigation.content")
            .navigationTitle(editorTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("完成", "Done")) { Task { await finish() } }
                        .accessibilityIdentifier("space.editor.done")
                }
                if canOpenFileInCAD {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(IDELanguageRunText.t("在 CAD 打开", "Open in CAD"), systemImage: "cube") {
                            if case .file(let file) = content { cadImportRequest = .init(record: record, file: file) }
                        }.accessibilityIdentifier("space.editor.openInCAD")
                    }
                }
                if content != nil, record.kind != .biology {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(record.kind == .meeting
                               ? IDELanguageRunText.t("会议助手", "Meeting assistant")
                               : IDELanguageRunText.t("作品助手", "Work assistant"), systemImage: "sparkles") {
                            showingAssistant = true
                        }.accessibilityIdentifier("space.editor.assistant")
                    }
                }
            }
        }
        .editorLayoutObservation("navigation.host")
        .ignoresSafeArea(.keyboard, edges: canvasKeyboardEdges)
    }
    private var editorTitle: String {
        if let content, case .music(let session) = content { return session.document.name }
        return record.title
    }

    @MainActor private func chemistrySurface(_ session: ChemistryProjectSession) -> some View {
        let epoch = chemistryEpoch
        return ChemistryEditorSurface(session: session, onInsertIntoNotes: { recordID, projectID, objectID in
            guard chemistryEpoch == epoch, record.id == recordID, projectID == recordID else { throw CancellationError() }
            chemistryNotesRequest = .init(recordID: recordID, projectID: projectID, objectID: objectID)
        })
    }

    private var canOpenFileInCAD: Bool {
        switch content {
        case .file(let url): return CADUnifiedModelImport.extensions.contains(url.pathExtension.lowercased())
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
            let loadingUse = try PersonalLibraryFileActions.acquireUse(id: record.id, directory: value.url)
            defer { loadingUse.release() }
            if fileUsage == nil { fileUsage = try PersonalLibraryFileActions.acquireUse(id: record.id, directory: value.url) }
            try Task.checkCancellation()
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
            case .biology:
                let host = try await environment.biologyComposition.host()
                try BiologyOriginalBinding.verify(id: record.id, directory: value.url)
                content = .biology(try await BiologyProjectSession.open(id: record.id, directory: value.url, host: host))
            case .latex:
                content = .latex(try await LaTeXProjectSession.open(id:record.id,composition:environment.latexComposition))
            case .geography:
                let session = try await GISProjectSession.open(id: record.id, directory: value.url)
                try session.beginPresentation(); content = .geography(session)
            case .electronics:
                content = .electronics(try await ElectronicsProjectSession.open(id: record.id, directory: value.url))
            case .meeting:
                content = .meeting(try await MeetingProjectSession.open(id: record.id, directory: value.url.appendingPathComponent("Meeting"), environment: environment))
            default:
                throw PersonalContentError.invalidProject
            }
            try await library.markOpened(record.id)
        } catch {
            if case nil = content { fileUsage?.release(); fileUsage = nil }
            self.error = error.localizedDescription
        }
    }

    /// Recovery of a pre-mount failure must resolve and open the same original
    /// again. A terminally closed owner is never reused for the new attempt.
    @MainActor private func reopenOffice(_ previous: PersonalOfficeDocument) async {
        guard !officeReopenInFlight, isPresented, record.id == previous.record.id,
              case .office(let current) = content, current === previous else { return }
        officeReopenInFlight = true
        defer { officeReopenInFlight = false }
        let generation = presentationGeneration
        func isCurrent() -> Bool {
            guard isPresented, presentationGeneration == generation, record.id == previous.record.id,
                  case .office(let current) = content else { return false }
            return current === previous
        }
        do {
            let replacement = try await previous.replacement()
            guard isCurrent() else { _ = await replacement.close(); return }
            content = .office(replacement)
        } catch {
            guard isCurrent() else { return }
            previous.session.reportOpenFailure(error)
        }
    }

    @MainActor private func refreshEditor() {
        switch content {
        case .diagram(let model):
            model.flushPendingInk(); model.reload()
        case .canvas(let store):
            Task { await store.refreshFromHost() }
        case .meeting(let session): Task { await session.refresh() }
        case .chemistry(let session): Task { await session.refreshFromHost() }
        case .biology(let session): Task { try? await session.refreshFromHost() }
        case .latex(let session): Task { await session.refresh() }
        case .geography(let session): Task { try? await session.refresh() }
        default: break // These process-owned sessions are already observed.
        }
    }
    @MainActor private func dismissAfterClosing() {
        presentationGeneration = UUID()
        fileUsage?.release(); fileUsage = nil
        dismiss()
    }
    @MainActor private func authorizeAssistantDeparture() async -> Bool {
        let id = record.id, generation = presentationGeneration
        do {
            return try await DocumentAssistantLeaveBindings.studio(record: record, environment: environment,
                coordinator: assistantLeave, isStillCurrent: {
                    record.id == id && presentationGeneration == generation && isPresented
                })
        } catch { self.error = error.localizedDescription; return false }
    }
    @MainActor private func finish() async {
        guard !closing else { return }
        closing = true; defer { closing = false }
        guard await authorizeAssistantDeparture() else { return }
        switch content {
        case .diagram(let model): await model.close()
        case .manufacturing(let model):
            do { try model.saveDraft() } catch { model.report(error); return }
        case .text(let document): guard await document.close() else { return }
        case .chemistry(let session): guard await session.flushForClose() else { return }
        case .biology(let session):
            guard await session.flushForClose() else { return }
            await session.close()
        case .latex(let session): guard await session.flushForClose() else {return}
        case .electronics(let session): guard await session.flushForClose() else { return }
        case .geography(let session):
            if let continued = assistantLeave.continuedSnapshot,
               continued.documentID == record.id,
               environment.conversationCenter.documentAssistantWorkIsOutstanding(continued),
               await session.endPresentationKeepingModelWork() {
                // The same service still owns its lease and pending commit.
                // This ends only presentation, and makes no save-success claim.
            } else { guard await session.flushForClose() else { return } }
        case .cad(let document):
            do { try await CADSimulationSessions.close(document:document) }
            catch { self.error = error.localizedDescription; return }
            let saved = await document.save()
            guard saved.succeeded else { error = saved.error; return }
            document.close()
        default: break
        }
        dismissAfterClosing()
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
