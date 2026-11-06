// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes
import FloeChemistryCore

@MainActor struct NotesChemistryPicker: View {
    let session: NotesSession
    let target: NotesChemistryTarget
    var onInserted: @MainActor (NoteDocument) -> Void
    var fixedWorkID: UUID? = nil
    var initialObjectID: UUID? = nil
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var works: [PersonalContentRecord] = []
    @State private var workID: UUID?
    @State private var project: ChemistryProject?
    @State private var objectID: UUID?
    @State private var mode = NotesChemistryInsertMode.image
    @State private var error: String?
    @State private var loading = false
    @State private var inserting = false
    @State private var generation = UUID()
    @State private var operation: Task<Void, Never>?

    private var selected: ChemicalObject? { project?.objects.first { $0.id == objectID } }
    private var canInsert: Bool {
        let imageAvailable: Bool
        if let selected { imageAvailable = NotesChemistryBridge.canExportImage(selected) } else { imageAvailable = false }
        return !loading && !inserting && workID != nil && project != nil && session.pendingWrites == 0
            && session.document?.id == target.documentID && !session.isSwitchingDocument
            && (mode == .link || imageAvailable)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(IDELanguageRunText.t("手记", "Note"), value: session.document?.title ?? "")
                    Picker(IDELanguageRunText.t("化学工程", "Chemistry project"), selection: $workID) {
                        Text(IDELanguageRunText.t("选择工程", "Choose project")).tag(UUID?.none)
                        ForEach(works) { work in Text(work.title).tag(Optional(work.id)) }
                    }.disabled(inserting || fixedWorkID != nil)
                    Picker(IDELanguageRunText.t("插入内容", "Insert content"), selection: $mode) {
                        Text(IDELanguageRunText.t("图片与工程链接", "Image and project link")).tag(NotesChemistryInsertMode.image)
                        Text(IDELanguageRunText.t("仅工程链接", "Project link only")).tag(NotesChemistryInsertMode.link)
                    }.disabled(inserting)
                    if let project {
                        Picker(IDELanguageRunText.t("结构或谱图", "Structure or spectrum"), selection: $objectID) {
                            if mode == .link { Text(IDELanguageRunText.t("整个工程", "Entire project")).tag(UUID?.none) }
                            ForEach(project.objects) { object in Text(object.title).tag(Optional(object.id)) }
                        }.disabled(inserting)
                    }
                    if mode == .image, let selected, !NotesChemistryBridge.canExportImage(selected) {
                        Text(IDELanguageRunText.t("这个对象暂无图片导出。可以改为插入工程链接。", "This object has no image export. Choose a project link instead.")).font(.footnote).foregroundStyle(.secondary)
                    }
                    if loading { ProgressView() }
                    if works.isEmpty, !loading {
                        Text(IDELanguageRunText.t("还没有化学工程，可先在空间中新建。", "Create a chemistry project in Space first.")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(IDELanguageRunText.t("插入已保存内容的图片副本，原工程会继续独立保存。", "Insert an image of saved content. The original project stays independent.")).font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) } }
                Section {
                    Button { insert() } label: {
                        HStack { Text(IDELanguageRunText.t("插入手记", "Insert into note")); Spacer(); if inserting { ProgressView() } }
                    }.disabled(!canInsert).accessibilityIdentifier("notes.chemistry.insert")
                }
            }
            .navigationTitle(IDELanguageRunText.t("插入化学工程", "Insert chemistry project"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("取消", "Cancel")) { operation?.cancel(); dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(inserting)
        .task {
            do {
                works = try await NotesChemistryBridge.host(environment: environment).list()
                if let fixedWorkID {
                    guard works.contains(where: { $0.id == fixedWorkID }) else { throw NotesChemistryError.changed }
                    works = works.filter { $0.id == fixedWorkID }; workID = fixedWorkID
                } else { workID = works.first?.id }
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: workID) { _, _ in Task { await reloadProject() } }
        .onDisappear { generation = UUID(); operation?.cancel(); operation = nil }
    }
    @MainActor private func reloadProject() async {
        let ticket = UUID(), requested = workID
        generation = ticket; project = nil; objectID = nil; loading = true
        defer { if generation == ticket { loading = false } }
        guard let requested else { return }
        do {
            let lease = try await NotesChemistryBridge.host(environment: environment).acquire(requested)
            let value = try await lease.service.project(lease.projectID)
            guard generation == ticket, workID == requested, !Task.isCancelled else { return }
            project = value; error = nil
            objectID = initialObjectID.flatMap { id in value.objects.contains(where: { $0.id == id }) ? id : nil } ?? value.objects.first?.id
            if value.objects.isEmpty { mode = .link }
        } catch { if generation == ticket { self.error = error.localizedDescription } }
    }
    @MainActor private func insert() {
        guard canInsert, let workID else { return }; inserting = true; error = nil
        let selectedObject = objectID, selectedMode = mode
        operation = Task { @MainActor in
            defer { inserting = false; operation = nil }
            do {
                let saved = try await NotesChemistryBridge.insert(host: NotesChemistryBridge.host(environment: environment),
                    workID: workID, objectID: selectedObject, mode: selectedMode, session: session, target: target)
                try Task.checkCancellation(); onInserted(saved)
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Explicit chemistry-editor callback destination. Its temporary NotesSession
/// is separate from the chemistry editor and any assistant conversation.
@MainActor struct NotesChemistryReturnSheet: View {
    let recordID: UUID
    let projectID: UUID
    var objectID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var session = NotesSession()
    @State private var selected: NoteDocument?
    @State private var error: String?
    @State private var creating = false
    @State private var title = ""
    @State private var busy = false
    @State private var inserted: NoteDocument?
    var body: some View {
        Group {
            if let inserted {
                NavigationStack {
                    ContentUnavailableView {
                        Label(IDELanguageRunText.t("已插入手记", "Inserted into note"), systemImage: "checkmark.circle")
                    } description: { Text(inserted.title) }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(IDELanguageRunText.t("完成", "Done")) { dismiss() } } }
                }
            } else if let selected {
                NotesChemistryPicker(session: session,
                    target: .init(documentID: selected.id, pageID: selected.pages.first?.id, parentNodeID: nil),
                    onInserted: { inserted = $0 }, fixedWorkID: recordID, initialObjectID: objectID)
            } else {
                NavigationStack {
                    List {
                        Section(IDELanguageRunText.t("选择手记", "Choose note")) {
                            ForEach(session.documents.filter { $0.deletedAt == nil && [.notebook, .mindMap].contains($0.kind) }) { note in
                                Button(note.title) { Task { if await session.select(note) { selected = session.document } } }.disabled(busy)
                            }
                            Button(IDELanguageRunText.t("新建手记", "New note"), systemImage: "plus") {
                                title = IDELanguageRunText.t("化学记录", "Chemistry notes"); creating = true
                            }.disabled(busy || recordID != projectID)
                        }
                        if let error { Section { Text(error).font(.footnote).foregroundStyle(.secondary) } }
                    }
                    .navigationTitle(IDELanguageRunText.t("插入手记", "Insert into note"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(IDELanguageRunText.t("取消", "Cancel")) { dismiss() } } }
                    .alert(IDELanguageRunText.t("新建手记", "New note"), isPresented: $creating) {
                        TextField(IDELanguageRunText.t("名称", "Name"), text: $title)
                        Button(IDELanguageRunText.t("创建", "Create")) { Task { await createNote() } }
                        Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) {}
                    }
                }
            }
        }.task {
            do {
                guard recordID == projectID else { throw NotesChemistryError.changed }
                if let store = try await NotesRepository.shared.existingStore() { await session.open(using: store) }
            } catch { self.error = error.localizedDescription }
        }
    }
    @MainActor private func createNote() async {
        guard !busy, recordID == projectID else { return }; busy = true; defer { busy = false }
        do {
            let store = try await NotesRepository.shared.store()
            let note = try await store.create(NoteDocument(title: title))
            await session.open(using: store)
            if await session.select(note) { selected = session.document }
        } catch { self.error = error.localizedDescription }
    }
}
#endif
