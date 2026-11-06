// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes
import UniformTypeIdentifiers

/// One personal library above the existing Notes editor. Visiting another
/// location never changes the selected task's workspace or execution route.
struct SpaceRootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @SceneStorage("floe.windowSceneIdentity") private var sceneID = UUID().uuidString
    @State private var section: SpaceSection = .overview
    @State private var records: [PersonalContentRecord] = []
    @State private var notes: [NoteDocument] = []
    @State private var folders: [String] = []
    @State private var childFolders: [String] = []
    @State private var query = ""
    @State private var opening: PersonalContentRecord?
    @State private var newKind: PersonalContentKind?
    @State private var newTitle = ""
    @State private var creatingFolder = false
    @State private var importing = false
    @State private var busy = false
    @State private var notice: String?

    private enum SpaceSection: String, CaseIterable, Identifiable {
        case overview, notes, files
        var id: Self { self }
        var title: String {
            switch self {
            case .overview: IDELanguageRunText.t("概览", "Overview")
            case .notes: IDELanguageRunText.t("手记", "Notes")
            case .files: IDELanguageRunText.t("文件", "Files")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(IDELanguageRunText.t("空间", "Space"), selection: $section) {
                ForEach(SpaceSection.allCases) { value in Text(value.title).tag(value) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 10)
            .accessibilityIdentifier("space.sections")
            Divider()
            if section == .notes {
                NotesRootView()
            } else {
                NavigationStack {
                    libraryList
                        .navigationTitle(section == .overview
                            ? IDELanguageRunText.t("空间", "Space")
                            : (folders.last ?? IDELanguageRunText.t("我的文件", "My files")))
                        .searchable(text: $query, prompt: IDELanguageRunText.t("查找作品和文件", "Find works and files"))
                        .toolbar { libraryToolbar }
                }
            }
        }
        .task { await refresh() }
        .onChange(of: section) { _, _ in Task { await refresh() } }
        .onReceive(environment.documentIntakeCenter.$noteOpenRequest) { request in
            if request?.sceneID == sceneID { section = .notes }
        }
        .fullScreenCover(item: $opening, onDismiss: { Task { await refresh() } }) { record in
            PersonalContentEditor(record: record)
        }
        .alert(IDELanguageRunText.t("新建作品", "New work"), isPresented: Binding(
            get: { newKind != nil }, set: { if !$0 { newKind = nil } })) {
            TextField(IDELanguageRunText.t("名称", "Name"), text: $newTitle)
            Button(IDELanguageRunText.t("创建", "Create")) {
                guard let kind = newKind else { return }
                newKind = nil
                Task { await create(kind) }
            }
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { newKind = nil }
        }
        .alert(IDELanguageRunText.t("新建文件夹", "New folder"), isPresented: $creatingFolder) {
            TextField(IDELanguageRunText.t("名称", "Name"), text: $newTitle)
            Button(IDELanguageRunText.t("创建", "Create")) { Task { await createFolder() } }
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) {}
        }
        .alert(IDELanguageRunText.t("未能完成", "Unable to finish"), isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button(IDELanguageRunText.t("好", "OK"), role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.content], allowsMultipleSelection: false) { result in
            Task {
                do {
                    guard let file = try result.get().first else { return }
                    busy = true
                    defer { busy = false }
                    let record = try await PersonalContentService.shared.importFile(file, folders: folders)
                    await refresh()
                    opening = record
                } catch { notice = error.localizedDescription }
            }
        }
    }

    private var matchingRecords: [PersonalContentRecord] {
        records.filter { record in
            (section == .overview || record.folders == folders)
                && (query.isEmpty || record.title.localizedStandardContains(query))
        }
    }

    private var libraryList: some View {
        List {
            if busy { ProgressView(IDELanguageRunText.t("正在保存", "Saving")) }
            if section == .files {
                if !folders.isEmpty {
                    Button(IDELanguageRunText.t("返回上一级", "Back to parent"), systemImage: "chevron.left") {
                        folders.removeLast(); Task { await refresh() }
                    }
                }
                ForEach(childFolders, id: \.self) { name in
                    Button { folders.append(name); Task { await refresh() } } label: {
                        Label(name, systemImage: "folder")
                    }
                }
            }
            if section == .overview {
                let pinned = matchingRecords.filter(\.isPinned)
                let favoriteNotes = notes.filter(\.isFavorite)
                if !pinned.isEmpty || !favoriteNotes.isEmpty {
                    Section(IDELanguageRunText.t("置顶", "Pinned")) {
                        ForEach(pinned) { workRow($0) }
                        ForEach(favoriteNotes) { noteRow($0) }
                    }
                }
                Section(IDELanguageRunText.t("最近使用", "Recent")) {
                    ForEach(Array(matchingRecords.prefix(20))) { workRow($0) }
                    ForEach(Array(notes.filter { query.isEmpty || $0.title.localizedStandardContains(query) }.prefix(8))) { noteRow($0) }
                    if matchingRecords.isEmpty && notes.isEmpty {
                        ContentUnavailableView(IDELanguageRunText.t("从一份作品开始", "Start with a work"),
                            systemImage: "square.and.pencil",
                            description: Text(IDELanguageRunText.t("新建作品，或把自己的文件导入空间。", "Create a work or import your files into Space.")))
                    }
                }
            } else {
                Section {
                    ForEach(matchingRecords) { workRow($0) }
                    if matchingRecords.isEmpty && childFolders.isEmpty {
                        ContentUnavailableView(IDELanguageRunText.t("还没有文件", "No files yet"),
                            systemImage: "folder", description: Text(IDELanguageRunText.t("新建作品或导入文件。", "Create a work or import a file.")))
                    }
                }
            }
            Section {
                NavigationLink {
                    AllWorkspacesFilesView(environment: environment)
                } label: { Label(IDELanguageRunText.t("其他位置", "Other locations"), systemImage: "externaldrive") }
                NavigationLink {
                    CreativeModeHubView()
                } label: { Label(IDELanguageRunText.t("已有画布", "Existing canvases"), systemImage: "rectangle.and.pencil.and.ellipsis") }
            }
        }
        .refreshable { await refresh() }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("space.library")
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                ForEach(PersonalContentKind.creationKinds, id: \.self) { kind in
                    Button(kind.title, systemImage: kind.systemImage) {
                        newTitle = kind.title; newKind = kind
                    }
                }
                Button(IDELanguageRunText.t("文件夹", "Folder"), systemImage: "folder.badge.plus") {
                    newTitle = ""; creatingFolder = true
                }
            } label: { Label(IDELanguageRunText.t("新建", "New"), systemImage: "plus") }
            .accessibilityIdentifier("space.new")
            Button(IDELanguageRunText.t("导入", "Import"), systemImage: "square.and.arrow.down") { importing = true }
                .accessibilityIdentifier("space.import")
        }
    }

    private func workRow(_ record: PersonalContentRecord) -> some View {
        Button { opening = record } label: {
            HStack(spacing: 12) {
                Image(systemName: record.kind.systemImage).font(.title2).frame(width: 36).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).foregroundStyle(.primary)
                    Text(record.kind.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if record.isPinned { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
                if record.needsRecovery { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            }.padding(.vertical, 5)
        }
        .contextMenu {
            Button(record.isPinned ? IDELanguageRunText.t("取消置顶", "Unpin") : IDELanguageRunText.t("置顶", "Pin"),
                   systemImage: record.isPinned ? "pin.slash" : "pin") {
                Task {
                    do {
                        let library = try await PersonalContentService.shared.library()
                        try await library.pin(record.id, pinned: !record.isPinned)
                        await refresh()
                    } catch { notice = error.localizedDescription }
                }
            }
        }
    }

    private func noteRow(_ note: NoteDocument) -> some View {
        Button {
            environment.documentIntakeCenter.presentSystemNote(documentID: note.id, title: note.title, sceneID: sceneID)
            section = .notes
        } label: {
            Label { Text(note.title).foregroundStyle(.primary) } icon: { Image(systemName: "book.pages").foregroundStyle(.tint) }
        }
    }

    @MainActor private func refresh() async {
        do {
            let library = try await PersonalContentService.shared.library()
            records = try await library.records()
            childFolders = try await library.folders(in: folders)
            if let store = try await NotesRepository.shared.existingStore() {
                notes = try await store.recentDocuments(limit: 100)
            }
        } catch { notice = error.localizedDescription }
    }
    @MainActor private func create(_ kind: PersonalContentKind) async {
        busy = true
        defer { busy = false }
        do {
            opening = try await PersonalContentService.shared.create(kind: kind, title: newTitle, folders: folders)
            await refresh()
        } catch { notice = error.localizedDescription }
    }
    @MainActor private func createFolder() async {
        do {
            let library = try await PersonalContentService.shared.library()
            try await library.createFolder(newTitle, in: folders)
            section = .files
            await refresh()
        } catch { notice = error.localizedDescription }
    }
}
#endif
