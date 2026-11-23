// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes
import UniformTypeIdentifiers
import PencilKit

import FloeCore
struct NotesRootView: View {
    @FocusState private var searchFocused: Bool
    @SceneStorage("floe.windowSceneIdentity") private var sceneID = UUID().uuidString
    @State private var session = NotesSession(tabDefaults: .standard)
    @StateObject private var assistantLeave = DocumentAssistantLeaveCoordinator()
    @State private var query = ""
    @AppStorage("notes.library.grid") private var grid = true
    @State private var section: SectionFilter = .recent
    @State private var newTitle = ""
    @State private var creation: Creation?
    @State private var pendingCreation: (kind: Creation, title: String)?
    @State private var importing = false
    @State private var importingWorkspace = false
    @State private var pendingWorkspaceImport: [NoteDocument]?
    @EnvironmentObject private var environment: AppEnvironment
    @State private var deleting: NoteDocument?
    @State private var selectedNoteIDs: Set<UUID>?
    @State private var notesToTrash: [NoteDocument]?
    @State private var isTrashingSelection = false
    @State private var renaming: RenameTarget?
    @State private var selectedBook: UUID?
    @State private var meetings: [PersonalContentRecord] = []
    @State private var openingMeeting: PersonalContentRecord?
    /// Settled cover source and revision per document, reported by each
    /// thumbnail card so accessibility (and the UI acceptance tests) can
    /// distinguish real content covers from the explicit unsupported/placeholder
    /// state and prove a revision-keyed reload.
    private struct CoverState: Equatable {
        let identity: String
        let value: String
    }
    @State private var coverSources: [UUID: CoverState] = [:]
    /// The document whose cover dialog is presented (from the context menu).
    @State private var coverTarget: NoteDocument?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isSelecting: Bool { selectedNoteIDs != nil }

    private enum SectionFilter: String, CaseIterable {
        case recent, all, maps, favorites, trash
        var titleKey: LocalizedStringKey {
            switch self {
            case .recent: "home.recent"
            case .all: "notes.notes_root_view.all_content"
            case .maps: "notes.notes_office_view.mind_map"
            case .favorites: "notes.notes_root_view.favorites"
            case .trash: "notes.notes_root_view.trash"
            }
        }
    }
    private struct RenameTarget: Identifiable {
        let id: UUID
        let title: String
        let notebook: Bool
        var document: NoteDocument? = nil
    }
    private enum Creation: String, Identifiable {
        case note, map, notebook, word, sheet, slides, meeting
        var id: String { rawValue }
        var titleKey: LocalizedStringKey {
            switch self {
            case .note: "notes.notes_root_view.blank_note"
            case .map: "notes.notes_office_view.mind_map"
            case .notebook: "notes.notes_root_view.notebook"
            case .word: "notes.notes_root_view.word_document"
            case .sheet: "notes.notes_root_view.excel_spreadsheet"
            case .slides: "notes.notes_root_view.powerpoint_presentation"
            case .meeting: LocalizedStringKey(IDELanguageRunText.t("会议笔记", "Meeting notes"))
            }
        }
    }

    var body: some View {
        NavigationStack {
            library
            .modifier(NotesConflictAccess(session: session))
            .fullScreenCover(isPresented: Binding(
                get: { session.document != nil },
                set: { if !$0 { Task { await session.select(nil) } } }
            )) {
                NavigationStack {
                    if let document = session.document, document.deletedAt == nil {
                        NotesDocumentEditor(session: session, document: document)
                            .id(document.id)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar(.hidden, for: .navigationBar)
                    }
                }
                .modifier(NotesConflictAccess(session: session))
                .documentAssistantLeavePresentation(assistantLeave)
                .interactiveDismissDisabled()
            }
            .navigationTitle("notes.notes_root_view.notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("workspace.workspace_canvas_view.done") { selectedNoteIDs = nil }
                            .disabled(isTrashingSelection)
                            .accessibilityIdentifier("notes.selection.done")
                    }
                } else {
                    if section != .trash {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("workspace.file_tree_view.select") {
                                searchFocused = false
                                selectedNoteIDs = []
                            }
                            .disabled(session.store == nil || !session.documents.contains { $0.deletedAt == nil })
                            .accessibilityIdentifier("notes.library.select")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { creationMenu }
                }
            }
            .sheet(item: $renaming) { target in
                NotesRenameSheet(title: target.title) { name in
                    if target.notebook {
                        guard let store = session.store else { throw NoteError.resourceUnavailable }
                        try await store.renameNotebook(target.id, title: name)
                        try await session.reload()
                    } else if let base = target.document {
                        _ = try await session.commit([.rename(name)], documentID: base.id, expectedRevision: base.revision)
                    }
                    renaming = nil
                }
            }
            .sheet(item: $creation, onDismiss: {
                guard let pending = pendingCreation else { return }
                pendingCreation = nil
                if pending.kind == .meeting {
                    Task {
                        do {
                            openingMeeting = try await PersonalContentService.shared.create(kind: .meeting, title: pending.title)
                            await refreshMeetings()
                        } catch { session.errorMessage = error.localizedDescription }
                    }
                } else if pending.kind == .notebook { session.createNotebook(pending.title) }
                else if pending.kind == .word || pending.kind == .sheet || pending.kind == .slides {
                    session.createOffice(extension: pending.kind == .word ? "docx" : pending.kind == .sheet ? "xlsx" : "pptx", title: pending.title, notebookID: selectedBook)
                } else {
                    session.create(kind: pending.kind == .map ? .mindMap : .notebook, title: pending.title, notebookID: selectedBook)
                }
            }) { kind in
                NavigationStack {
                    Form { TextField("notes.notes_root_view.name", text: $newTitle).accessibilityIdentifier("notes.create.title") }
                        .navigationTitle(kind.titleKey)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("workspace.workspace_canvas_view.cancel") { creation = nil; newTitle = "" } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("settings.git_hub_settings_view.create") {
                                    pendingCreation = (kind, newTitle)
                                    creation = nil; newTitle = ""
                                }.disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                }.presentationDetents([.medium])
            }
            .sheet(isPresented: $importingWorkspace, onDismiss: {
                if let value = pendingWorkspaceImport {
                    pendingWorkspaceImport = nil
                    showAllImportedNotes()
                    session.importDocuments(value)
                }
            }) {
                OfficeWorkspaceAttachmentPicker(environment: environment, purpose: .notesImport) { url in
                    guard let store = session.store else { throw NoteError.resourceUnavailable }
                    let values: [NoteDocument]
                    if url.pathExtension.lowercased() == "floenote" {
                        values = try await NotesArchive.importDocuments(from: url, notebookID: selectedBook, store: store)
                    } else {
                        values = [try await NoteFileImporter.importFile(url, notebookID: selectedBook, store: store)]
                    }
                    // Copy/import finishes before the picker releases a remote temporary file.
                    // Present the editor only after the workspace picker has dismissed.
                    pendingWorkspaceImport = values
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image, .plainText, UTType(exportedAs: "org.floeagent.note", conformingTo: .data)] + ["docx", "doc", "odt", "rtf", "xlsx", "xls", "ods", "pptx", "ppt", "odp"].compactMap { UTType(filenameExtension: $0) } + NoteDocument.supportedEngineeringFileExtensions.sorted().compactMap { UTType(filenameExtension: $0) }) { result in
                Task {
                    do {
                        let url = try result.get()
                        if url.pathExtension.lowercased() == "floenote" {
                            showAllImportedNotes()
                            session.importArchive(url, notebookID: selectedBook)
                            return
                        }
                        guard let store = session.store else { return }
                        let document = try await NoteFileImporter.importFile(url, notebookID: selectedBook, store: store)
                        showAllImportedNotes()
                        session.importDocument(document)
                    } catch { session.errorMessage = error.localizedDescription }
                }
            }
            .confirmationDialog("notes.notes_root_view.permanently_delete_this_content", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { value in
                Button("notes.notes_root_view.delete_permanently", role: .destructive) { session.permanentlyDelete(value); deleting = nil }
                Button("workspace.workspace_canvas_view.cancel", role: .cancel) { deleting = nil }
            } message: { value in
                Text(FloeL10n.l("notes.notes_root_view.and_its_undo_history_cannot_be", value.title))
            }
            .alert("notes.notes_root_view.notes", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
                Button("workspace.office_document_editor_view.ok") { session.errorMessage = nil }
            } message: { Text(session.errorMessage ?? "") }
            .onChange(of: session.document?.id, initial: true) { _, documentID in
                DocumentIntakeRoutingRegistry.shared.noteSelectionChanged(documentID, sceneID: sceneID)
            }
            .onReceive(environment.documentIntakeCenter.$noteOpenRequest) { _ in
                adoptPendingDocument()
            }
            .onReceive(environment.$studioOpenRequest) { _ in adoptMeeting() }
            .onReceive(NotificationCenter.default.publisher(for: .floeStudioDocumentDidChange)) { _ in Task { await refreshMeetings() } }
            .fullScreenCover(item: $openingMeeting, onDismiss: { Task { await refreshMeetings(); try? await session.reload() } }) { value in
                PersonalContentEditor(record: value)
            }
            .task {
                await NotesRepository.shared.bindConversationCenter(environment.conversationCenter)
                DocumentAssistantLeaveBindings.installNotes(on: session, environment: environment, coordinator: assistantLeave)
                await session.open()
                adoptPendingDocument()
                await refreshMeetings()
                adoptMeeting()
                #if DEBUG
                await NotesOfficeThumbnailFixture.seedIfRequested(session: session)
                await NotesAIActualOutputFixture.seedIfRequested(session: session)
                await OfficeWorkspaceStageFixture.seedIfRequested(environment: environment)
                // Real-engine cloud simulator qualification fixture (office-floe-simulator).
                await OfficeRealEngineQualificationFixture.seedIfRequested(session: session)
                #endif
            }
        }
        .documentAssistantLeavePresentation(assistantLeave, enabled: session.document == nil)
    }

    private var creationMenu: some View {
        Menu {
            Button("notes.notes_root_view.blank_note", systemImage: "doc.badge.plus") { creation = .note }
            Button(IDELanguageRunText.t("会议笔记", "Meeting notes"), systemImage: "waveform.and.mic") { creation = .meeting }
                .accessibilityIdentifier("notes.create.meeting")
            Button("notes.notes_office_view.mind_map", systemImage: "point.3.connected.trianglepath.dotted") { creation = .map }
            Button("notes.notes_root_view.notebook", systemImage: "folder.badge.plus") { creation = .notebook }
            Menu("Office", systemImage: "doc.richtext") {
                Button("notes.notes_root_view.word_document") { creation = .word }.accessibilityIdentifier("notes.create.word")
                Button("notes.notes_root_view.excel_spreadsheet") { creation = .sheet }
                Button("notes.notes_root_view.powerpoint_presentation") { creation = .slides }
            }
            Button("notes.notes_root_view.import_from_floe_workspace", systemImage: "folder") { importingWorkspace = true }
                .accessibilityIdentifier("notes.import.workspace")
            Button("notes.import.all", systemImage: "square.and.arrow.down") { importing = true }
        } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
        .accessibilityLabel("notes.notes_root_view.new_or_import")
        .accessibilityIdentifier("notes.create")
        .disabled(session.store == nil)
    }

    private func showAllImportedNotes() {
        query = ""
        section = .all
    }

    private func adoptPendingDocument() {
        // Let the existing session-open task finish before claiming a replay.
        guard session.store != nil,
              let request = environment.documentIntakeCenter.noteOpenRequest,
              request.sceneID == nil || request.sceneID == sceneID,
              environment.documentIntakeCenter.claimNoteOpen(request) else { return }
        Task { @MainActor in
            let opened = await session.adoptImportedDocument(request.documentID)
            if opened {
                selectedNoteIDs = nil
                selectedBook = session.document?.notebookID
                showAllImportedNotes()
            }
            environment.documentIntakeCenter.completeNoteOpen(request, opened: opened)
        }
    }

    private func adoptMeeting() {
        guard let request = environment.studioOpenRequest, request.record.kind == .meeting,
              request.sceneID == sceneID else { return }
        environment.studioOpenRequest = nil
        openingMeeting = request.record
    }
    @MainActor private func refreshMeetings() async {
        do { meetings = try await PersonalContentService.shared.library().records().filter { $0.kind == .meeting } }
        catch { session.errorMessage = error.localizedDescription }
    }
    private var matchingMeetings: [PersonalContentRecord] {
        guard selectedBook == nil, section != .maps, section != .trash else { return [] }
        return meetings.filter { (section != .favorites || $0.isPinned) && (query.isEmpty || $0.title.localizedStandardContains(query)) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private var library: some View {
        // Body-search results keep title and excerpt beside the preview, even
        // with the landscape iPad keyboard taking most of the vertical space.
        let showsCovers = grid && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let documents = filtered
        return libraryContent(showsCovers: showsCovers, documents: documents)
            .disabled(isTrashingSelection)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting { selectionBar(documents: documents) }
            }
            .onChange(of: isSelecting ? documents.map(\.id) : []) { _, visibleIDs in
                selectedNoteIDs?.formIntersection(visibleIDs)
            }
            .onChange(of: section) { _, filter in
                if filter == .trash { selectedNoteIDs = nil }
            }
            .notesCoverPicker(target: $coverTarget, store: session.store) { _ in
                Task { try? await session.reload() }
            } onError: { message in
                session.errorMessage = message
            }
    }

    private func selectionBar(documents: [NoteDocument]) -> some View {
        let selected = documents.filter { selectedNoteIDs?.contains($0.id) == true }
        let allSelected = !documents.isEmpty && selected.count == documents.count
        return HStack {
            Button {
                selectedNoteIDs = allSelected ? [] : Set(documents.map(\.id))
            } label: {
                Text(LocalizedStringKey(allSelected ? "chat.conversation_batch_management_view.deselect_all" : "composer.editor.select_all"))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(documents.isEmpty)
            .accessibilityIdentifier("notes.selection.selectAll")
            Spacer()
            Text(FloeL10n.l("chat.conversation_batch_management_view.selected", selected.count))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("notes.selection.count")
            Spacer()
            if isTrashingSelection {
                ProgressView().frame(width: 44, height: 44)
            } else {
                Button(role: .destructive) {
                    searchFocused = false
                    notesToTrash = selected
                } label: {
                    Image(systemName: "trash").frame(width: 44, height: 44)
                }
                .accessibilityLabel("notes.notes_root_view.move_to_trash")
                .accessibilityIdentifier("notes.selection.trash")
                .disabled(selected.isEmpty)
                .confirmationDialog(
                    "notes.notes_root_view.trash_selection",
                    isPresented: Binding(get: { notesToTrash != nil }, set: { if !$0 { notesToTrash = nil } }),
                    titleVisibility: .visible,
                    presenting: notesToTrash
                ) { notes in
                    Button("notes.notes_root_view.move_to_trash", role: .destructive) {
                        notesToTrash = nil
                        isTrashingSelection = true
                        session.trash(notes) { committed in
                            isTrashingSelection = false
                            if committed { selectedNoteIDs = nil }
                        }
                    }
                    Button("workspace.workspace_canvas_view.cancel", role: .cancel) { notesToTrash = nil }
                } message: { notes in
                    Text(FloeL10n.l("chat.conversation_batch_management_view.selected", notes.count))
                }
            }
        }
        .padding(.horizontal, 16)
        .background(.bar)
        .disabled(isTrashingSelection)
    }

    private func selectionMark(_ isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .accessibilityHidden(true)
    }

    private func libraryContent(showsCovers: Bool, documents: [NoteDocument]) -> some View {
        let visibleMeetings = isSelecting ? [] : matchingMeetings
        return VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("notes.notes_root_view.search_document_names_and_content", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { searchFocused = false }
                    .accessibilityIdentifier("notes.search")
            }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)).padding()
            HStack {
                Picker("notes.notes_root_view.content", selection: $section) {
                    ForEach(SectionFilter.allCases, id: \.self) { Text($0.titleKey).tag($0) }
                }.pickerStyle(.menu)
                Spacer()
                Button(grid ? "notes.notes_root_view.list_view" : "notes.notes_root_view.cover_view", systemImage: grid ? "list.bullet" : "square.grid.2x2") { grid.toggle() }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                Picker("notes.notes_root_view.notebook", selection: $selectedBook) {
                    Text("notes.notes_root_view.all_notebooks").tag(Optional<UUID>.none)
                    ForEach(session.notebooks) { Text($0.title).tag(Optional($0.id)) }
                }.pickerStyle(.menu)
                if let book = session.notebooks.first(where: { $0.id == selectedBook }) {
                    Button("notes.notes_root_view.rename_notebook", systemImage: "pencil") { renaming = .init(id: book.id, title: book.title, notebook: true) }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
            }.padding(.horizontal)
            if let id = session.indexingDocumentID {
                ProgressView(FloeL10n.l("notes.notes_root_view.indexing", session.documents.first(where: { $0.id == id })?.title ?? FloeL10n.l("notes.notes_root_view.documents")))
                    .font(.caption).padding(.horizontal)
            }
            if !query.isEmpty && section != .trash {
                let incomplete = session.documents.filter { $0.deletedAt == nil && (($0.kind == .office && ($0.officeTextResourceID != $0.officeResourceID || $0.officeTextError != nil)) || $0.pages.contains { $0.textExtractionTruncated == true || ($0.needsVisualIndex && ($0.ocrSourceKey != $0.visualIndexKey || $0.ocrError != nil)) }) }.count
                if incomplete > 0 { Text(FloeL10n.plural("notes.notes_root_view.documents_are_not_fully_indexed_yet", count: incomplete)).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            }
            ScrollView {
              LazyVGrid(columns: showsCovers ? [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 20)] : [GridItem(.flexible())], spacing: 24) {
                ForEach(visibleMeetings) { meeting in
                    Button { openingMeeting = meeting } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "waveform.and.mic").font(.system(size: 36)).foregroundStyle(.tint)
                                .frame(maxWidth: .infinity, minHeight: showsCovers ? 130 : 44, alignment: .leading)
                            Text(meeting.title).font(.headline).foregroundStyle(.primary)
                            Text(IDELanguageRunText.t("会议笔记", "Meeting notes")).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).accessibilityIdentifier("notes.meeting.\(meeting.id)")
                }
                if !isSelecting && selectedBook == nil && section != .trash && query.isEmpty {
                    ForEach(session.notebooks) { book in
                        Button { selectedBook = book.id } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: "folder.fill").font(.system(size: 42)).foregroundStyle(.tint)
                                    .frame(maxWidth: .infinity, minHeight: showsCovers ? 130 : 44, alignment: .leading)
                                Text(book.title).font(.headline).foregroundStyle(.primary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
                ForEach(documents) { document in
                    let isSelected = selectedNoteIDs?.contains(document.id) == true
                    Button {
                        if var selection = selectedNoteIDs {
                            if !selection.insert(document.id).inserted { selection.remove(document.id) }
                            selectedNoteIDs = selection
                            return
                        }
                        Task {
                            await session.select(document)
                            let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !search.isEmpty {
                                // The same pure helper the agent uses resolves
                                // page/element and UTF-16 range; the session
                                // publishes it for the editor to scroll/highlight.
                                session.requestSearchFocus(in: document, query: search)
                            }
                        }
                    } label: {
                        let layout = showsCovers ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                        layout {
                            NotesDocumentThumbnail(document: document, store: session.store, exposesAccessibility: false) { source, revision, detail in
                                let value = CoverState(identity: "\(source.rawValue)#\(revision)", value: detail)
                                if coverSources[document.id] != value {
                                    coverSources[document.id] = value
                                }
                            }
                                .frame(width: showsCovers ? nil : 64, height: showsCovers ? 190 : 80)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .topTrailing) {
                                    if isSelecting && showsCovers {
                                        selectionMark(isSelected)
                                            .padding(5)
                                            .background(.regularMaterial, in: Circle())
                                            .padding(6)
                                    }
                                }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(document.title).font(.headline).foregroundStyle(.primary)
                                Text(document.kind == .mindMap ? FloeL10n.plural("notes.notes_root_view.topics", count: document.nodes.count) : document.kind == .office ? (document.officeFileName ?? "notes.notes_root_view.office_document") : document.kind == .engineering ? (document.engineeringFileName ?? String(localized: "notes.kind.engineering")) : FloeL10n.plural("notes.notes_knowledge_picker.pages", count: document.pages.count))
                                    .font(.caption).foregroundStyle(.secondary)
                                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(searchSnippet(document.searchableText))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                                if document.kind == .office {
                                    if document.officeTextResourceID != document.officeResourceID {
                                        Label("notes.notes_root_view.waiting_for_body_text_indexing", systemImage: "text.magnifyingglass").font(.caption2).foregroundStyle(.secondary)
                                    } else if document.officeTextError != nil {
                                        Label("notes.notes_root_view.body_text_not_indexed", systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Text(document.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isSelecting {
                                if !showsCovers { selectionMark(isSelected) }
                            } else if document.isFavorite {
                                Image(systemName: "star.fill").foregroundStyle(.yellow)
                            }
                        }.padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Keep the native Button and its text/snippet semantics;
                    // the decorative thumbnail does not create a second AX
                    // identity. Report its actual render state on this button.
                    .accessibilityIdentifier("notes.card.\(document.kind.rawValue).\(document.title).\(coverSources[document.id]?.identity ?? "none")")
                    .accessibilityValue(isSelecting ? "" : coverSources[document.id]?.value ?? "none")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .multilineTextAlignment(.leading)
                    .disabled(document.deletedAt != nil)
                    .contextMenu {
                        if document.deletedAt != nil {
                            Button("canvas.drawingHistory.restore", systemImage: "arrow.uturn.backward") { session.trash(document, restore: true) }
                            Button("notes.notes_root_view.delete_permanently", systemImage: "trash", role: .destructive) { deleting = document }
                        } else if !isSelecting {
                            Button("notes.notes_root_view.re_index_body_text", systemImage: "text.magnifyingglass") { session.rebuildSearchIndex(documentID: document.id) }
                            Button(document.coverResourceID == nil ? "notes.cover.menu.set" : "notes.cover.menu.change", systemImage: "photo") { coverTarget = document }
                            Button("workspace.file_tree_view.rename", systemImage: "pencil") { renaming = .init(id: document.id, title: document.title, notebook: false, document: document) }
                            Button(document.isFavorite ? "notes.notes_root_view.remove_from_favorites" : "notes.notes_root_view.favorites", systemImage: "star") {
                                session.apply([.favorite(!document.isFavorite)], title: FloeL10n.l("notes.notes_root_view.favorites"), base: document)
                            }
                            Menu("notes.notes_root_view.move_to_notebook") {
                                Button("workspace.workspace_canvas_view.uncategorized") { session.apply([.moveToNotebook(nil)], title: FloeL10n.l("workspace.file_tree_view.move"), base: document) }
                                ForEach(session.notebooks) { book in
                                    Button(book.title) { session.apply([.moveToNotebook(book.id)], title: FloeL10n.l("workspace.file_tree_view.move"), base: document) }
                                }
                            }
                            Button("notes.notes_root_view.move_to_trash", role: .destructive) { session.trash(document) }
                        }
                    }
                    if document.deletedAt != nil {
                        HStack {
                            Button(FloeL10n.l("notes.notes_root_view.restore", document.title)) { session.trash(document, restore: true) }
                            Spacer()
                            Button("notes.notes_root_view.delete_permanently", role: .destructive) { deleting = document }
                        }
                    }
                }
              }.padding(20)
            }
                .accessibilityIdentifier("notes.library.scroll")
                .scrollDismissesKeyboard(.interactively)
                .overlay {
                    if session.store == nil { ProgressView("notes.notes_root_view.opening_note") }
                    else if documents.isEmpty && visibleMeetings.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "notes.notes_root_view.nothing_here_yet" : "notes.notes_root_view.no_matching_content_found",
                            systemImage: query.isEmpty ? "book.closed" : "magnifyingglass",
                            description: Text(query.isEmpty ? "notes.notes_root_view.create_a_note_import_slides_or" : "notes.notes_root_view.try_other_keywords_scans_and_handwriting"))
                    }
                }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func searchSnippet(_ text: String) -> String {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) else { return String(text.prefix(140)) }
        let start = text.index(range.lowerBound, offsetBy: -45, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + text[start..<end] + (end == text.endIndex ? "" : "…")
    }

    private var filtered: [NoteDocument] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let recentOrder = Dictionary(uniqueKeysWithValues: session.recentDocumentIDs.enumerated().map { ($0.element, $0.offset) })
        return session.documents.filter { value in
            if !search.isEmpty {
                // Search across notebooks within either the library or Trash.
                return (value.deletedAt != nil) == (section == .trash)
                    && value.searchableText.localizedStandardContains(search)
            }
            let matchesSection: Bool
            switch section {
            case .trash: matchesSection = value.deletedAt != nil
            case .maps: matchesSection = value.deletedAt == nil && value.kind == .mindMap
            case .favorites: matchesSection = value.deletedAt == nil && value.isFavorite
            case .recent: matchesSection = value.deletedAt == nil && recentOrder[value.id] != nil
            case .all: matchesSection = value.deletedAt == nil
            }
            return matchesSection && (selectedBook == nil || value.notebookID == selectedBook)
        }.sorted { first, second in
            if section == .recent { return (recentOrder[first.id] ?? Int.max) < (recentOrder[second.id] ?? Int.max) }
            return first.updatedAt > second.updatedAt
        }
    }
}
private struct NotesRenameSheet: View {
    @State private var name: String
    let save: (String) async throws -> Void
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(title: String, save: @escaping (String) async throws -> Void) { _name = State(initialValue: title); self.save = save }
    var body: some View {
        NavigationStack {
            Form { TextField("notes.notes_root_view.name", text: $name).accessibilityIdentifier("notes.rename.title") }
                .navigationTitle("workspace.file_tree_view.rename")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("workspace.workspace_canvas_view.cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("workspace.workspace_canvas_view.save") {
                            saving = true
                            Task {
                                defer { saving = false }
                                do { try await save(name.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                            .accessibilityIdentifier("notes.rename.save")
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .disabled(saving)
                .alert("notes.notes_root_view.notes", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("workspace.office_document_editor_view.ok") { error = nil }
                } message: { Text(error ?? "") }
        }.presentationDetents([.medium]).interactiveDismissDisabled(saving)
    }
}

#endif
