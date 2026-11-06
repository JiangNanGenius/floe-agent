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
    @State private var creationRequest: PersonalContentCreationRequest?
    @State private var createdAfterNaming: PersonalContentRecord?
    @State private var newNote = false
    @State private var renaming: PersonalContentRecord?
    @State private var newTitle = ""
    @State private var creatingFolder = false
    @State private var importing = false
    @State private var busy = false
    @State private var notice: String?
    @AppStorage("space.personalFiles.showGrid") private var showingGrid = false
    @State private var fileKind: PersonalFileFilter = .all
    @State private var sortByName = true
    @State private var fileActionRequest: PersonalFileActionRequest?
    @State private var fileActionEditor: PersonalContentRecord?
    @State private var shareArtifact: PersonalShareArtifact?
    @State private var shareCleanup: PersonalShareArtifact?

    private enum SpaceSection: String, CaseIterable, Identifiable {
        case overview, notes, files, toolbox
        var id: Self { self }
        var title: String {
            switch self {
            case .overview: IDELanguageRunText.t("概览", "Overview")
            case .notes: IDELanguageRunText.t("手记", "Notes")
            case .files: IDELanguageRunText.t("文件", "Files")
            case .toolbox: IDELanguageRunText.t("工具箱", "Toolbox")
            }
        }
    }

    // The accepted Files preview filters the same directory. These choices
    // never create categories, move originals, or expose editor internals.
    private enum PersonalFileFilter: String, CaseIterable, Identifiable {
        case all, document, drawing, video, cad
        var id: Self { self }
        var title: String {
            switch self {
            case .all: IDELanguageRunText.t("所有类型", "All types")
            case .document: IDELanguageRunText.t("文档", "Documents")
            case .drawing: IDELanguageRunText.t("绘画／图片", "Drawing / images")
            case .video: IDELanguageRunText.t("视频", "Video")
            case .cad: "CAD"
            }
        }
        func includes(_ kind: PersonalContentKind) -> Bool {
            switch self {
            case .all: true
            case .document: kind == .document
            case .drawing: [.image, .drawing, .canvas].contains(kind)
            case .video: kind == .video
            case .cad: [.cad2D, .cad3D].contains(kind)
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
            } else if section == .toolbox {
                ToolboxRootView(center: environment.toolboxCenter)
            } else {
                NavigationStack {
                    libraryList
                        .navigationTitle(section == .overview
                            ? IDELanguageRunText.t("空间", "Space")
                            : (folders.last ?? IDELanguageRunText.t("我的文件", "My files")))
                        .navigationBarTitleDisplayMode(.inline)
                        .searchable(text: $query, prompt: IDELanguageRunText.t("查找作品和文件", "Find works and files"))
                        .toolbar { libraryToolbar }
                }
            }
        }
        .task { await refresh() }
        .onChange(of: section) { old, _ in
            if old == .toolbox { environment.leaveToolboxSurface() }
            Task {
                await refresh()
            }
        }
        .onReceive(environment.documentIntakeCenter.$noteOpenRequest) { request in
            if request?.sceneID == sceneID { section = .notes }
        }
        .onReceive(environment.$studioOpenRequest) { request in
            guard let request, request.sceneID == sceneID else { return }
            if request.record.kind == .meeting { section = .notes; return }
            environment.studioOpenRequest = nil
            if section == .toolbox { section = .overview }
            opening = request.record
        }
        .onReceive(NotificationCenter.default.publisher(for: .floeStudioDocumentDidChange)) { _ in
            Task { await refresh() }
        }
        .sheet(item: $fileActionRequest, onDismiss: {
            if let record = fileActionEditor { fileActionEditor = nil; opening = record }
            Task { await refresh() }
        }) { request in
            PersonalLibraryActionSheet(request: request, onFinished: { record in
                folders = record.folders; section = .files; fileActionRequest = nil
                Task { await refresh() }
            }, onOpenEditor: { record in
                fileActionEditor = record; fileActionRequest = nil
            })
        }
        .sheet(item: $shareArtifact, onDismiss: {
            shareCleanup?.finish(); shareCleanup = nil
        }) { artifact in
            PersonalLibraryShareSheet(artifact: artifact, onFinished: {
                artifact.finish(); shareArtifact = nil
            })
        }
        .fullScreenCover(item: $opening, onDismiss: { Task { await refresh() } }) { record in
            PersonalContentEditor(record: record)
        }
        .sheet(item: $creationRequest, onDismiss: presentCreatedWorkAfterNaming) { request in
            PersonalContentNamingSheet(request: request) { record in
                guard creationRequest?.id == request.id else { return }
                createdAfterNaming = record
            }
        }
        .alert(IDELanguageRunText.t("新建文件夹", "New folder"), isPresented: $creatingFolder) {
            TextField(IDELanguageRunText.t("名称", "Name"), text: $newTitle)
            Button(IDELanguageRunText.t("创建", "Create")) { Task { await createFolder() } }
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) {}
        }
        .alert(IDELanguageRunText.t("新建手记", "New note"), isPresented: $newNote) {
            TextField(IDELanguageRunText.t("名称", "Name"), text: $newTitle)
            Button(IDELanguageRunText.t("创建", "Create")) {
                Task {
                    do {
                        let store = try await NotesRepository.shared.store()
                        let document = try await store.create(NoteDocument(title: newTitle))
                        environment.documentIntakeCenter.presentSystemNote(documentID: document.id, title: document.title, sceneID: sceneID)
                        section = .notes
                    } catch { notice = error.localizedDescription }
                }
            }
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) {}
        }
        .alert(IDELanguageRunText.t("重命名", "Rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(IDELanguageRunText.t("名称", "Name"), text: $newTitle)
            Button(IDELanguageRunText.t("保存", "Save")) {
                guard let value = renaming else { return }; renaming = nil
                Task {
                    do {
                        let name = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, name.count <= 160 else { throw PersonalContentError.invalidName }
                        try await PersonalContentService.shared.library().markChanged(value.id, title: name)
                        await refresh()
                    } catch { notice = error.localizedDescription }
                }
            }
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { renaming = nil }
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
            (section == .overview || !query.isEmpty || record.folders == folders)
                && (section != .files || fileKind.includes(record.kind))
                && (query.isEmpty || record.title.localizedStandardContains(query))
        }.sorted {
            if sortByName { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.modifiedAt == $1.modifiedAt ? $0.id.uuidString < $1.id.uuidString : $0.modifiedAt > $1.modifiedAt
        }
    }

    private enum RecentEntry: Identifiable {
        case work(PersonalContentRecord), note(NoteDocument)
        var id: String {
            switch self { case .work(let record): "work/\(record.id)"; case .note(let note): "note/\(note.id)" }
        }
        var date: Date {
            switch self { case .work(let record): max(record.lastOpenedAt ?? record.createdAt, record.modifiedAt); case .note(let note): note.updatedAt }
        }
    }
    private var recentEntries: [RecentEntry] {
        let works = matchingRecords.filter { $0.lastOpenedAt != nil }.map(RecentEntry.work)
        let noteEntries = notes.filter { query.isEmpty || $0.title.localizedStandardContains(query) }.map(RecentEntry.note)
        return Array((works + noteEntries).sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }.prefix(28))
    }

    private var libraryList: some View {
        List {
            if busy { ProgressView(IDELanguageRunText.t("正在保存", "Saving")) }
            if section == .files {
                if !folders.isEmpty {
                    folderPath
                }
                if query.isEmpty && fileKind == .all && !childFolders.isEmpty {
                    Section(IDELanguageRunText.t("文件夹", "Folders")) {
                        ForEach(childFolders, id: \.self) { name in
                            Button { folders.append(name); Task { await refresh() } } label: {
                                HStack {
                                    Label(name, systemImage: "folder").foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }.frame(minHeight: 36)
                            }.listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }
                    }
                }
            }
            if section == .overview {
                let pinned = matchingRecords.filter(\.isPinned)
                let favoriteNotes = notes.filter(\.isFavorite)
                if !pinned.isEmpty || !favoriteNotes.isEmpty {
                    Section(IDELanguageRunText.t("置顶", "Pinned")) {
                        if showingGrid {
                            LazyVGrid(columns: [.init(.adaptive(minimum: 170, maximum: 260))], spacing: 18) {
                                ForEach(pinned) { workCard($0) }
                            }.padding(.vertical, 8).listRowBackground(Color.clear)
                        } else { ForEach(pinned) { workRow($0) } }
                        ForEach(favoriteNotes) { noteRow($0) }
                    }
                }
                Section(IDELanguageRunText.t("最近使用", "Recent")) {
                    ForEach(recentEntries) { entry in
                        switch entry { case .work(let work): workRow(work); case .note(let note): noteRow(note) }
                    }
                    if matchingRecords.isEmpty && notes.isEmpty {
                        ContentUnavailableView(IDELanguageRunText.t("从一份作品开始", "Start with a work"),
                            systemImage: "square.and.pencil",
                            description: Text(IDELanguageRunText.t("新建作品，或把自己的文件导入空间。", "Create a work or import your files into Space.")))
                    }
                }
            } else {
                Section(IDELanguageRunText.t("文件与作品", "Files and works")) {
                    if showingGrid {
                        LazyVGrid(columns: [.init(.adaptive(minimum: 170, maximum: 280))], alignment: .leading, spacing: 20) {
                            ForEach(matchingRecords) { workCard($0) }
                        }.padding(.vertical, 8).listRowBackground(Color.clear)
                    } else { ForEach(matchingRecords) { workRow($0) } }
                    if matchingRecords.isEmpty && (childFolders.isEmpty || !query.isEmpty || fileKind != .all) {
                        ContentUnavailableView(IDELanguageRunText.t("还没有文件", "No files yet"),
                            systemImage: "folder", description: Text(IDELanguageRunText.t("新建作品或导入文件。", "Create a work or import a file.")))
                    }
                }
            }
        }
        .refreshable { await refresh() }
        .listStyle(.plain)
        .accessibilityIdentifier("space.library")
    }

    private var folderPath: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button(IDELanguageRunText.t("我的文件", "My files")) {
                    folders = []; Task { await refresh() }
                }
                ForEach(folders.indices, id: \.self) { index in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    Button(folders[index]) {
                        folders = Array(folders.prefix(index + 1)); Task { await refresh() }
                    }.foregroundStyle(index == folders.count - 1 ? Color.primary : Color.accentColor)
                }
            }.font(.subheadline).lineLimit(1)
        }
        .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
        .accessibilityIdentifier("space.folderPath")
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker(IDELanguageRunText.t("显示方式", "View"), selection: $showingGrid) {
                    Label(IDELanguageRunText.t("缩略图", "Thumbnails"), systemImage: "square.grid.2x2").tag(true)
                    Label(IDELanguageRunText.t("列表", "List"), systemImage: "list.bullet").tag(false)
                }
                Picker(IDELanguageRunText.t("排序", "Sort"), selection: $sortByName) {
                    Text(IDELanguageRunText.t("最近修改", "Date modified")).tag(false)
                    Text(IDELanguageRunText.t("名称", "Name")).tag(true)
                }
                if section == .files {
                    Picker(IDELanguageRunText.t("文件类型", "File type"), selection: $fileKind) {
                        ForEach(PersonalFileFilter.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                }
            } label: { Label(IDELanguageRunText.t("视图", "View"), systemImage: showingGrid ? "square.grid.2x2" : "list.bullet") }
                .accessibilityIdentifier("space.viewOptions")
                .accessibilityValue(showingGrid ? IDELanguageRunText.t("缩略图", "Thumbnails") : IDELanguageRunText.t("列表", "List"))
            Menu {
                Text(IDELanguageRunText.t("当前位置：", "Current location: ") + personalPath(folders))
                Button(IDELanguageRunText.t("文件夹", "Folder"), systemImage: "folder.badge.plus") {
                    newTitle = ""; creatingFolder = true
                }
                Menu {
                    ForEach([PersonalOfficeFormat.word, .workbook, .presentation], id: \.self) { format in
                        Button(format.title, systemImage: format.systemImage) {
                            requestCreation(.document(format))
                        }.accessibilityIdentifier("space.create." + format.rawValue)
                    }
                    Divider()
                    Button(PersonalOfficeFormat.plainText.title, systemImage: PersonalOfficeFormat.plainText.systemImage) {
                        requestCreation(.document(.plainText))
                    }.accessibilityIdentifier("space.create.plainText")
                } label: { Label(IDELanguageRunText.t("文档…", "Document…"), systemImage: "doc.text") }
                .accessibilityIdentifier("space.new.document")
                ForEach([PersonalContentKind.drawing, .video, .cad2D], id: \.self) { kind in
                    Button(kind == .drawing ? IDELanguageRunText.t("绘画／图片", "Drawing / image") : kind == .cad2D ? IDELanguageRunText.t("二维 CAD", "2D CAD") : kind.title, systemImage: kind.systemImage) {
                        requestCreation(.work(kind))
                    }
                }
                Button(PersonalContentKind.chemistry.title, systemImage: PersonalContentKind.chemistry.systemImage) {
                    requestCreation(.work(.chemistry))
                }
                Button(IDELanguageRunText.t("手记", "Notes"), systemImage: "book.pages") {
                    newTitle = IDELanguageRunText.t("未命名手记", "Untitled note"); newNote = true
                }
            } label: { Label(IDELanguageRunText.t("新建", "New"), systemImage: "plus") }
            .accessibilityIdentifier("space.new")
            Menu {
                ForEach([PersonalContentKind.printing, .music, .manufacturing, .diagram, .cad3D], id: \.self) { kind in
                    Button(kind.title, systemImage: kind.systemImage) { requestCreation(.work(kind)) }
                }
            } label: { Label(IDELanguageRunText.t("工作台", "Workbenches"), systemImage: "square.grid.2x2") }
                .accessibilityIdentifier("space.workbenches")
            Button(IDELanguageRunText.t("导入", "Import"), systemImage: "square.and.arrow.down") { importing = true }
                .accessibilityIdentifier("space.import")
            Menu {
                NavigationLink {
                    AllWorkspacesFilesView(environment: environment)
                } label: { Label(IDELanguageRunText.t("浏览其他位置…", "Browse other locations…"), systemImage: "externaldrive") }
                NavigationLink {
                    DocumentRecoveryListView()
                } label: { Label(IDELanguageRunText.t("保留的文档", "Kept documents"), systemImage: "doc.badge.clock") }
                NavigationLink {
                    AllWorkspacesFilesView(environment: environment, initialFilter: 3)
                } label: { Label(IDELanguageRunText.t("归档聊天文件", "Archived chat files"), systemImage: "archivebox") }
            } label: { Label(IDELanguageRunText.t("更多", "More"), systemImage: "ellipsis") }
                .accessibilityIdentifier("space.more")
        }
    }

    private func workRow(_ record: PersonalContentRecord) -> some View {
        HStack(spacing: 8) {
            Button { opening = record } label: {
                HStack(spacing: 10) {
                    Image(systemName: record.kind.systemImage).font(.body).frame(width: 28).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title).foregroundStyle(.primary).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(record.kind.title)
                            Text("·")
                            Text(record.modifiedAt, format: .dateTime.month().day().hour().minute())
                        }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    ViewThatFits(in: .horizontal) {
                        Text(personalPath(record.folders)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).frame(width: 180, alignment: .leading)
                        EmptyView()
                    }
                    if record.isPinned { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
                    if record.needsRecovery { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(.rect)
            }.buttonStyle(.plain)
            fileMenu(record)
        }
        .listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 16))
        .contextMenu { workActions(record) }
    }

    private func workCard(_ record: PersonalContentRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { opening = record } label: {
                PersonalLibraryCover(record: record).frame(height: 104)
            }.buttonStyle(.plain)
            HStack(alignment: .top, spacing: 6) {
                Button { opening = record } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                        Text(record.kind.title).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                if record.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                if record.needsRecovery { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                fileMenu(record)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contextMenu { workActions(record) }
    }

    private func fileMenu(_ record: PersonalContentRecord) -> some View {
        Menu { workActions(record) } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
        }.accessibilityLabel(IDELanguageRunText.t("更多操作：", "More actions: ") + record.title)
    }

    @ViewBuilder private func workActions(_ record: PersonalContentRecord) -> some View {
            Button(IDELanguageRunText.t("移动", "Move"), systemImage: "folder") {
                fileActionRequest = .init(record: record, action: .move)
            }.disabled(busy).accessibilityIdentifier("space.files.move")
            Button(IDELanguageRunText.t("复制", "Duplicate"), systemImage: "doc.on.doc") {
                fileActionRequest = .init(record: record, action: .duplicate)
            }.disabled(busy).accessibilityIdentifier("space.files.duplicate")
            Button(IDELanguageRunText.t("分享", "Share"), systemImage: "square.and.arrow.up") {
                if PersonalLibraryFileActions.supports(.share, kind: record.kind) { Task { await share(record) } }
                else { fileActionRequest = .init(record: record, action: .share) }
            }.disabled(busy).accessibilityIdentifier("space.files.share")
            Divider()
            Button(IDELanguageRunText.t("查看所在位置", "Show location"), systemImage: "folder") {
                folders = record.folders; section = .files; query = ""; fileKind = .all
                Task { await refresh() }
            }
            Button(IDELanguageRunText.t("重命名", "Rename"), systemImage: "pencil") { newTitle = record.title; renaming = record }
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

    private func personalPath(_ path: [String]) -> String {
        ([IDELanguageRunText.t("我的文件", "My files")] + path).joined(separator: " / ")
    }

    @MainActor private func share(_ record: PersonalContentRecord) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let artifact = try await PersonalLibraryFileActions.share(record)
            shareCleanup?.finish(); shareCleanup = artifact; shareArtifact = artifact
        } catch { notice = error.localizedDescription }
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
    @MainActor private func requestCreation(_ target: PersonalContentCreationRequest.Target) {
        createdAfterNaming = nil
        creationRequest = .init(target: target, folders: folders)
    }
    @MainActor private func presentCreatedWorkAfterNaming() {
        guard let record = createdAfterNaming else { return }
        createdAfterNaming = nil
        // This callback is the presentation boundary: the naming sheet and
        // its keyboard have finished dismissal before a full-screen editor opens.
        opening = record
        Task { await refresh() }
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

/// Shows original text when available; unsaved or binary works retain a plain
/// type cover rather than fabricated artwork or a screenshot of another file.
private struct PersonalLibraryCover: View {
    let record: PersonalContentRecord
    @State private var excerpt: String?
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemGroupedBackground))
            if let excerpt, !excerpt.isEmpty {
                Text(excerpt).font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(15)
            } else {
                Image(systemName: record.kind.systemImage).font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tint).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity).clipShape(.rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1) }
            .accessibilityHidden(true)
            .task(id: record.modifiedAt) {
                excerpt = nil
                guard record.kind == .document,
                      let url = try? await PersonalContentService.shared.originalFile(record.id),
                      ["txt", "md", "markdown", "csv", "json"].contains(url.pathExtension.lowercased()) else { return }
                let text = await Task.detached(priority: .utility) {
                    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= 128 * 1024, let data = try? Data(contentsOf: url) else { return String?.none }
                    return String(data: data, encoding: .utf8).map { String($0.prefix(1400)) }
                }.value
                guard !Task.isCancelled else { return }
                excerpt = text
            }
    }
}
#endif
