// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes
import UniformTypeIdentifiers

/// One personal library above the existing Notes editor. Visiting another
/// location never changes the selected task's workspace or execution route.
struct SpaceRootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @SceneStorage("floe.windowSceneIdentity") private var sceneID = UUID().uuidString
    @State private var section: SpaceSection = .overview
    @State private var records: [PersonalContentRecord] = []
    @State private var notes: [NoteDocument] = []
    @State private var noteVisits: [NoteDocumentVisit] = []
    @State private var notesStore: NotesStore?
    @State private var folders: [String] = []
    @State private var childFolders: [PersonalLibraryFolder] = []
    @State private var deletion: PersonalLibraryDeleteSelection?
    @State private var showingRecentlyDeleted = false
    @State private var query = ""
    @State private var librarySearchPresented = false
    @FocusState private var searchFocused: Bool
    @State private var opening: PersonalContentRecord?
    @State private var pendingLibraryOpen: LibraryOpenRequest?
    @State private var presentedLibraryOpen: LibraryOpenRequest?
    @State private var creationRequest: PersonalContentCreationRequest?
    @State private var createdAfterNaming: PersonalContentRecord?
    @State private var newNote = false
    @State private var renaming: PersonalContentRecord?
    @State private var newTitle = ""
    @State private var creatingFolder = false
    @State private var importing = false
    @State private var importingLaTeX = false
    @State private var importingGeography = false
    @State private var busy = false
    @State private var notice: String?
    @AppStorage("space.personalFiles.showGrid") private var showingGrid = false
    @State private var fileKind: PersonalFileFilter = .all
    @State private var sortByName = true
    @State private var selection = PersonalLibrarySelectionModel()
    @State private var confirmingBatchDelete = false
    @State private var fileActionRequest: PersonalFileActionRequest?
    @State private var fileActionEditor: PersonalContentRecord?
    @State private var shareArtifact: PersonalShareArtifact?
    @State private var shareCleanup: PersonalShareArtifact?
    @State private var refreshGeneration = UUID()

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
    private struct LibraryOpenRequest: Identifiable {
        let id = UUID()
        let record: PersonalContentRecord
        let query: String
        let section: SpaceSection
        let folders: [String]
    }
#if DEBUG
    private var nativeInputObservationFlags: [String: Bool] {
        ["searchPresented": librarySearchPresented, "searchFocused": searchFocused,
         "pendingOpen": pendingLibraryOpen != nil, "coverOpen": opening != nil,
         "restoreRequest": presentedLibraryOpen != nil, "queryEmpty": query.isEmpty,
         "sectionFiles": section == .files, "sectionOverview": section == .overview]
    }
#endif

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
            case .document: kind == .document || kind == .latex
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
                    SpaceLibraryOpenBoundary(requestID: pendingLibraryOpen?.id, onReady: finishLibraryOpen) {
                        libraryList
                    }
                        .navigationTitle(section == .overview
                            ? IDELanguageRunText.t("空间", "Space")
                            : (folders.last ?? IDELanguageRunText.t("我的文件", "My files")))
                        .navigationBarTitleDisplayMode(.inline)
                        .searchable(text: $query, isPresented: librarySearchPresentation,
                            prompt: IDELanguageRunText.t("查找作品和文件", "Find works and files"))
                        .searchFocused($searchFocused)
                        .toolbar { libraryToolbar }
                }
            }
        }
        .task { await refresh() }
#if DEBUG
        .onChange(of: nativeInputObservationFlags, initial: true) { _, flags in
            SpaceNativeInputObservation.setLibraryFlags(flags)
        }
#endif
        .onChange(of: section) { old, new in
            selection.cancel()
            if pendingLibraryOpen?.section != new { pendingLibraryOpen = nil }
            if presentedLibraryOpen?.section != new { presentedLibraryOpen = nil }
            if old == .toolbox { environment.leaveToolboxSurface() }
            Task {
                await refresh()
            }
        }
        .onChange(of: folders) { _, new in
            // The directory scope changed; the previous selection can no
            // longer describe the visible results.
            selection.cancel()
            if pendingLibraryOpen?.folders != new { pendingLibraryOpen = nil }
            if presentedLibraryOpen?.folders != new { presentedLibraryOpen = nil }
        }
        .onChange(of: query) { _, _ in
            // Search results replace the visible scope. Never carry a hidden
            // selection into a new result set.
            if selection.isSelecting { selection.cancel() }
        }
        .onReceive(environment.documentIntakeCenter.$noteOpenRequest) { request in
            if request?.sceneID == sceneID { section = .notes }
        }
        .onReceive(environment.$studioOpenRequest) { request in
            guard let request, request.sceneID == sceneID else { return }
            if request.record.kind == .meeting { section = .notes; return }
            environment.studioOpenRequest = nil
            if section == .toolbox { section = .overview }
            presentWork(request.record)
        }
        .onReceive(NotificationCenter.default.publisher(for: .floeStudioDocumentDidChange)) { _ in
            Task { await refresh() }
        }
        .sheet(isPresented: $showingRecentlyDeleted, onDismiss: { Task { await refresh() } }) {
            PersonalRecentlyDeletedView()
        }
        .confirmationDialog(IDELanguageRunText.t("移到最近删除？", "Move to Recently Deleted?"),
            isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
            titleVisibility: .visible, presenting: deletion) { selection in
                Button(IDELanguageRunText.t("删除", "Delete"), role: .destructive) {
                    deletion = nil; Task { await delete(selection) }
                }.accessibilityIdentifier("space.files.delete.confirm")
                Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { deletion = nil }
            } message: { selection in
                Text(selection.message)
            }
        .confirmationDialog(IDELanguageRunText.t("将所选项目移到最近删除？", "Move the selected items to Recently Deleted?"),
            isPresented: $confirmingBatchDelete,
            titleVisibility: .visible) {
            Button(IDELanguageRunText.t("删除", "Delete"), role: .destructive) {
                confirmingBatchDelete = false
                Task { await deleteSelection() }
            }.accessibilityIdentifier("space.files.batchDelete.confirm")
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { confirmingBatchDelete = false }
        } message: {
            Text(IDELanguageRunText.t("所选项目可以在“最近删除”中恢复；未能删除的项目会保留在列表中。",
                "Selected items can be restored from Recently Deleted; items that cannot be deleted stay in the list."))
        }
        .sheet(item: $fileActionRequest, onDismiss: {
            if let record = fileActionEditor { fileActionEditor = nil; presentWork(record) }
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
        .fullScreenCover(item: $opening, onDismiss: finishPresentedWork) { record in
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
            Button(IDELanguageRunText.t("创建", "Create")) {
                let name = newTitle, destination = folders
                creatingFolder = false
                Task { await createFolder(name: name, in: destination) }
            }
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
                        if value.kind == .biology {
                            let lifecycle = try await environment.biologyComposition.libraryLifecycle()
                            try await PersonalLibraryFileActions.withBiologyLifecycle(projectID: value.id) { record, directory, library in
                                try await lifecycle.renameUnderHeldBarrier(record: record, directory: directory, library: library, title: name)
                            }
                        } else {
                            try await PersonalContentService.shared.library().markChanged(value.id, title: name)
                        }
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
                    let record:PersonalContentRecord
                    if importingGeography {record=try await PersonalContentService.shared.importGeography(file,folders:folders)}
                    else if importingLaTeX {record=try await PersonalContentService.shared.importLaTeX(file,folders:folders)}
                    else {record=try await PersonalContentService.shared.importFile(file,folders:folders)}
                    await refresh()
                    presentWork(record)
                } catch { notice = error.localizedDescription }
            }
        }
    }

    private var librarySearchPresentation: Binding<Bool> {
        Binding(get: {
            librarySearchPresented && opening == nil && pendingLibraryOpen == nil
        }, set: { presented in
            // A background refresh must not restart search input over an editor.
            librarySearchPresented = presented && opening == nil && pendingLibraryOpen == nil
        })
    }
    private func presentWork(_ record: PersonalContentRecord) {
        searchFocused = false
        librarySearchPresented = false
        if opening == nil, section == .overview || section == .files {
            pendingLibraryOpen = LibraryOpenRequest(record: record, query: query, section: section, folders: folders)
        } else { opening = record }
    }
    private func finishLibraryOpen(_ id: UUID) {
        guard let request = pendingLibraryOpen, request.id == id,
              request.section == section, request.folders == folders,
              section == .overview || section == .files else { return }
        presentedLibraryOpen = request
        pendingLibraryOpen = nil
        // Keep the filter in the owning request until the cover has closed.
        // Reapplying it here can restart the background search interaction.
        query = ""
        opening = request.record
    }
    private func finishPresentedWork() {
        if opening == nil, let request = presentedLibraryOpen {
            presentedLibraryOpen = nil
            searchFocused = false; librarySearchPresented = false
            if request.section == section, request.folders == folders, query.isEmpty { query = request.query }
        }
        Task { await refresh() }
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
        case work(PersonalContentRecord), note(NoteDocumentVisit)
        var id: String {
            switch self { case .work(let record): "work/\(record.id)"; case .note(let visit): "note/\(visit.document.id)" }
        }
        var date: Date {
            switch self { case .work(let record): record.lastOpenedAt ?? .distantPast; case .note(let visit): visit.openedAt }
        }
    }
    private var recentEntries: [RecentEntry] {
        let works = matchingRecords.filter { $0.lastOpenedAt != nil }.map(RecentEntry.work)
        let noteEntries = noteVisits.filter { query.isEmpty || $0.document.title.localizedStandardContains(query) }.map(RecentEntry.note)
        return Array((works + noteEntries).sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }.prefix(28))
    }

    private var libraryList: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700 && !dynamicTypeSize.isAccessibilitySize
            if section == .overview {
                overview(wide: wide)
            } else {
                filesList(wide: wide)
            }
        }
        .accessibilityIdentifier("space.library")
    }

    /// Overview directory actions. Quick entries and workbench groups reuse the
    /// same creation routes as the Files toolbar; nothing here moves originals
    /// or turns the directory into content categories.
    private enum OverviewQuickAction: Identifiable {
        case newNote
        case create(PersonalContentCreationRequest.Target)
        var id: String {
            switch self {
            case .newNote: "newNote"
            case .create(let target):
                switch target {
                case .work(let kind): "work." + kind.rawValue
                case .document(let format): "document." + format.rawValue
                }
            }
        }
    }
    private struct OverviewEntry: Identifiable {
        let title: String
        let systemImage: String
        let action: OverviewQuickAction
        var id: String { action.id }
    }
    private struct OverviewGroup: Identifiable {
        let id: String
        let title: String
        let entries: [OverviewEntry]
    }
    private func overviewEntry(_ title: String, _ systemImage: String, _ action: OverviewQuickAction) -> OverviewEntry {
        OverviewEntry(title: title, systemImage: systemImage, action: action)
    }
    private var overviewQuickEntries: [OverviewEntry] {
        let kind = PersonalContentKind.self
        return [
            overviewEntry(IDELanguageRunText.t("手记", "Notes"), "book.pages", .newNote),
            overviewEntry(PersonalOfficeFormat.word.title, PersonalOfficeFormat.word.systemImage, .create(.document(.word))),
            overviewEntry(IDELanguageRunText.t("绘画／图片", "Drawing / image"), kind.drawing.systemImage, .create(.work(.drawing))),
            overviewEntry(kind.video.title, kind.video.systemImage, .create(.work(.video))),
            overviewEntry(kind.music.title, kind.music.systemImage, .create(.work(.music))),
            overviewEntry(kind.cad2D.title, kind.cad2D.systemImage, .create(.work(.cad2D))),
            overviewEntry(kind.cad3D.title, kind.cad3D.systemImage, .create(.work(.cad3D))),
            overviewEntry(kind.chemistry.title, kind.chemistry.systemImage, .create(.work(.chemistry))),
            overviewEntry(kind.diagram.title, kind.diagram.systemImage, .create(.work(.diagram)))
        ]
    }
    /// Grouping mirrors the existing New menu's workbench relationships.
    private var overviewGroups: [OverviewGroup] {
        let kind = PersonalContentKind.self
        return [
            OverviewGroup(id: "documents", title: IDELanguageRunText.t("文档", "Documents"), entries: [
                overviewEntry(PersonalOfficeFormat.word.title, PersonalOfficeFormat.word.systemImage, .create(.document(.word))),
                overviewEntry(PersonalOfficeFormat.workbook.title, PersonalOfficeFormat.workbook.systemImage, .create(.document(.workbook))),
                overviewEntry(PersonalOfficeFormat.presentation.title, PersonalOfficeFormat.presentation.systemImage, .create(.document(.presentation))),
                overviewEntry(PersonalOfficeFormat.plainText.title, PersonalOfficeFormat.plainText.systemImage, .create(.document(.plainText))),
                overviewEntry(kind.latex.title,kind.latex.systemImage,.create(.work(.latex)))
            ]),
            OverviewGroup(id: "media", title: IDELanguageRunText.t("绘画与媒体", "Drawing & media"), entries: [
                overviewEntry(IDELanguageRunText.t("绘画／图片", "Drawing / image"), kind.drawing.systemImage, .create(.work(.drawing))),
                overviewEntry(kind.video.title, kind.video.systemImage, .create(.work(.video))),
                overviewEntry(kind.music.title, kind.music.systemImage, .create(.work(.music)))
            ]),
            OverviewGroup(id: "design", title: IDELanguageRunText.t("设计与工程", "Design & engineering"), entries: [
                overviewEntry(kind.cad2D.title, kind.cad2D.systemImage, .create(.work(.cad2D))),
                overviewEntry(kind.cad3D.title, kind.cad3D.systemImage, .create(.work(.cad3D))),
                overviewEntry(kind.electronics.title, kind.electronics.systemImage, .create(.work(.electronics))),
                overviewEntry(kind.geography.title, kind.geography.systemImage, .create(.work(.geography))),
                overviewEntry(kind.diagram.title, kind.diagram.systemImage, .create(.work(.diagram)))
            ]),
            OverviewGroup(id: "science", title: IDELanguageRunText.t("科学", "Science"), entries: [
                overviewEntry(kind.chemistry.title, kind.chemistry.systemImage, .create(.work(.chemistry))),
                overviewEntry(kind.biology.title, kind.biology.systemImage, .create(.work(.biology)))
            ]),
            OverviewGroup(id: "collaboration", title: IDELanguageRunText.t("协作", "Collaboration"), entries: [
                overviewEntry(IDELanguageRunText.t("手记", "Notes"), "book.pages", .newNote)
            ])
        ]
    }
    private func runOverviewEntry(_ action: OverviewQuickAction) {
        searchFocused = false
        switch action {
        case .newNote:
            newTitle = IDELanguageRunText.t("未命名手记", "Untitled note"); newNote = true
        case .create(let target):
            requestCreation(target)
        }
    }
    private func overviewQuickEntryButton(_ entry: OverviewEntry) -> some View {
        Button { runOverviewEntry(entry.action) } label: {
            VStack(spacing: 6) {
                Image(systemName: entry.systemImage).font(.title2).foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                Text(entry.title).font(.caption).foregroundStyle(.primary).lineLimit(1)
            }.frame(width: 76)
        }.buttonStyle(.plain)
        .accessibilityIdentifier("space.quick." + entry.id)
    }
    private func overviewGroupCard(_ group: OverviewGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.title).font(.headline).padding(.bottom, 4)
            ForEach(group.entries) { entry in
                Button { runOverviewEntry(entry.action) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entry.systemImage).foregroundStyle(.tint).frame(width: 24)
                        Text(entry.title).foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity, minHeight: 40).contentShape(.rect)
                }.buttonStyle(.plain)
                .accessibilityIdentifier("space.group." + group.id + "." + entry.id)
            }
        }.padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func overview(wide: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if busy { ProgressView(IDELanguageRunText.t("正在保存", "Saving")) }
                VStack(alignment: .leading, spacing: 10) {
                    Text(IDELanguageRunText.t("常用入口", "Quick access")).font(.title3.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(overviewQuickEntries) { overviewQuickEntryButton($0) }
                        }.padding(.horizontal, 2)
                    }
                }.accessibilityIdentifier("space.quickEntries")
                let pinned = matchingRecords.filter(\.isPinned)
                let favoriteNotes = notes.filter {
                    $0.isFavorite && (query.isEmpty || $0.title.localizedStandardContains(query))
                }
                if !pinned.isEmpty || !favoriteNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(IDELanguageRunText.t("置顶", "Pinned")).font(.title3.weight(.semibold))
                        LazyVGrid(columns: [.init(.adaptive(minimum: 170, maximum: 260))], alignment: .leading, spacing: 20) {
                            ForEach(pinned) { workCard($0) }
                            ForEach(favoriteNotes) { noteCard($0) }
                        }
                    }.accessibilityIdentifier("space.pinned")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(IDELanguageRunText.t("工作台", "Workbenches")).font(.title3.weight(.semibold))
                    if wide {
                        LazyVGrid(columns: [.init(.flexible(), alignment: .top), .init(.flexible(), alignment: .top)], alignment: .leading, spacing: 14) {
                            ForEach(overviewGroups) { overviewGroupCard($0) }
                        }
                    } else {
                        ForEach(overviewGroups) { overviewGroupCard($0) }
                    }
                }.accessibilityIdentifier("space.workbenches")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(IDELanguageRunText.t("继续使用", "Continue working")).font(.title3.weight(.semibold))
                        Spacer()
                        Text(IDELanguageRunText.t("按使用时间", "By last opened")).font(.caption).foregroundStyle(.secondary)
                    }
                    if !recentEntries.isEmpty {
                        if wide { fileColumnsHeader(recent: true) }
                        ForEach(recentEntries) { entry in
                            switch entry {
                            case .work(let work): workRow(work, wide: wide, openedAt: entry.date)
                            case .note(let visit): noteRow(visit.document, wide: wide, openedAt: visit.openedAt)
                            }
                            Divider()
                        }
                    } else {
                        ContentUnavailableView {
                            Label(IDELanguageRunText.t("还没有使用记录", "No recent items"), systemImage: "clock")
                        } description: {
                            Text(IDELanguageRunText.t("打开手记、文件或作品后，可以在这里继续。", "Open a note, file, or work to continue here later."))
                        } actions: {
                            Button(IDELanguageRunText.t("浏览我的文件", "Browse my files")) { section = .files }
                        }
                    }
                }.accessibilityIdentifier("space.recent")
            }.padding(20)
        }.refreshable { await refresh() }
    }

    private func filesList(wide: Bool) -> some View {
        List {
            if busy { ProgressView(IDELanguageRunText.t("正在保存", "Saving")) }
            folderPath
            if query.isEmpty && fileKind == .all && !childFolders.isEmpty {
                Section(IDELanguageRunText.t("文件夹", "Folders")) {
                    if wide {
                        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], alignment: .leading, spacing: 0) {
                            ForEach(childFolders) { folderRow($0) }
                        }
                    } else {
                        ForEach(childFolders) { folderRow($0) }
                    }
                }
            }
            Section {
                if showingGrid {
                    LazyVGrid(columns: [.init(.adaptive(minimum: 170, maximum: 260))], alignment: .leading, spacing: 20) {
                        ForEach(matchingRecords) { workCard($0) }
                    }.padding(.vertical, 8).listRowSeparator(.hidden)
                } else {
                    ForEach(matchingRecords) { workRow($0, wide: wide) }
                }
                if matchingRecords.isEmpty && (childFolders.isEmpty || !query.isEmpty || fileKind != .all) {
                    ContentUnavailableView(IDELanguageRunText.t("还没有文件", "No files yet"),
                        systemImage: "folder", description: Text(IDELanguageRunText.t("新建作品或导入文件。", "Create a work or import a file.")))
                }
            } header: {
                if wide && !showingGrid { fileColumnsHeader(recent: false) }
                else { Text(IDELanguageRunText.t("文件与作品", "Files and works")) }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 44)
        .refreshable { await refresh() }
    }

    private func folderRow(_ folder: PersonalLibraryFolder) -> some View {
        HStack(spacing: 8) {
            Button {
                if filesSelecting { selection.toggle(.folder(folder)) }
                else { folders = folder.components; Task { await refresh() } }
            } label: {
                HStack(spacing: 12) {
                    if filesSelecting { selectionCheckmark(for: .folder(folder)) }
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                    Text(folder.name).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    if !filesSelecting { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("space.folder." + folder.name)
            if !filesSelecting {
                Menu {
                    folderActions(folder)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(.rect)
                }.buttonStyle(.borderless).accessibilityLabel(IDELanguageRunText.t("文件夹操作", "Folder actions"))
                    .accessibilityIdentifier("space.folder.menu." + folder.relativePath)
            }
        }.contextMenu { folderActions(folder) }
    }
    @ViewBuilder private func folderActions(_ folder: PersonalLibraryFolder) -> some View {
        if section == .files {
            Button(IDELanguageRunText.t("选择", "Select"), systemImage: "checkmark.circle") {
                searchFocused = false
                selection.begin(with: .folder(folder))
            }.disabled(busy).accessibilityIdentifier("space.folder.select")
        }
        Button(role: .destructive) { deletion = .folder(folder) } label: {
            Label(IDELanguageRunText.t("删除", "Delete"), systemImage: "trash")
        }.disabled(busy).accessibilityIdentifier("space.folder.delete")
    }

    private func fileColumnsHeader(recent: Bool) -> some View {
        HStack(spacing: 12) {
            Text(IDELanguageRunText.t("名称", "Name")).frame(maxWidth: .infinity, alignment: .leading)
            if recent { Text(IDELanguageRunText.t("位置", "Location")).frame(width: 140, alignment: .leading) }
            else { Text(IDELanguageRunText.t("种类", "Kind")).frame(width: 100, alignment: .leading) }
            Text(recent ? IDELanguageRunText.t("上次打开", "Last opened") : IDELanguageRunText.t("修改日期", "Date modified"))
                .frame(width: 130, alignment: .leading)
            Color.clear.frame(width: 44, height: 1)
        }.font(.caption).foregroundStyle(.secondary).textCase(nil)
    }

    private var folderPath: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button(IDELanguageRunText.t("我的文件", "My files")) {
                    folders = []; Task { await refresh() }
                }.frame(minHeight: 44)
                ForEach(folders.indices, id: \.self) { index in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    Button(folders[index]) {
                        folders = Array(folders.prefix(index + 1)); Task { await refresh() }
                    }.frame(minHeight: 44)
                        .foregroundStyle(index == folders.count - 1 ? Color.primary : Color.accentColor)
                }
            }.font(.subheadline).lineLimit(1)
        }
        .listRowInsets(.init(top: 0, leading: 16, bottom: 0, trailing: 16))
        .accessibilityIdentifier("space.folderPath")
    }

    /// The visible rows of the Files page define the whole selection scope:
    /// folders only appear outside search with the type filter on, and the
    /// works are the current directory contents or the current search hits.
    private var visibleSelectionItems: [PersonalLibrarySelectionItem] {
        guard section == .files else { return [] }
        let folderItems = query.isEmpty && fileKind == .all
            ? childFolders.map(PersonalLibrarySelectionItem.folder) : []
        return folderItems + matchingRecords.map(PersonalLibrarySelectionItem.work)
    }

    @ViewBuilder private var selectionToolbarContent: some View {
        Button(IDELanguageRunText.t("全选", "Select All")) { selection.selectAll(visibleSelectionItems) }
            .disabled(busy).accessibilityIdentifier("space.files.selectAll")
        Text("\(selection.effectiveSelection().count)")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("space.files.selectionCount")
        Button(IDELanguageRunText.t("取消", "Cancel")) { selection.cancel() }
            .disabled(busy).accessibilityIdentifier("space.files.cancelSelection")
        Button(IDELanguageRunText.t("删除", "Delete"), role: .destructive) {
            confirmingBatchDelete = true
        }.disabled(busy || selection.effectiveSelection().isEmpty)
            .accessibilityIdentifier("space.files.batchDelete")
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if section == .files, selection.isSelecting {
                selectionToolbarContent
            } else {
            if section == .files { Menu {
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
            }
            Menu {
                Text(IDELanguageRunText.t("当前位置：", "Current location: ") + personalPath(folders))
                Button(IDELanguageRunText.t("文件夹", "Folder"), systemImage: "folder.badge.plus") {
                    searchFocused = false; newTitle = ""; creatingFolder = true
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
                ForEach([PersonalContentKind.drawing, .video], id: \.self) { kind in
                    Button(kind == .drawing ? IDELanguageRunText.t("绘画／图片", "Drawing / image") : kind.title, systemImage: kind.systemImage) {
                        requestCreation(.work(kind))
                    }
                }
                Menu {
                    ForEach([PersonalContentKind.cad2D, .cad3D], id: \.self) { kind in
                        Button(kind == .cad2D ? IDELanguageRunText.t("二维 CAD", "2D CAD") : IDELanguageRunText.t("三维 CAD", "3D CAD"), systemImage: kind.systemImage) {
                            requestCreation(.work(kind))
                        }.accessibilityIdentifier("space.create." + kind.rawValue)
                    }
                } label: { Label("CAD", systemImage: "cube.transparent") }
                .accessibilityIdentifier("space.new.cad")
                ForEach([PersonalContentKind.diagram, .music, .latex, .electronics, .geography], id: \.self) { kind in
                    Button(kind.title, systemImage: kind.systemImage) { requestCreation(.work(kind)) }
                        .accessibilityIdentifier("space.create." + kind.rawValue)
                }
                Button(PersonalContentKind.chemistry.title, systemImage: PersonalContentKind.chemistry.systemImage) {
                    requestCreation(.work(.chemistry))
                }
                Button(PersonalContentKind.biology.title, systemImage: PersonalContentKind.biology.systemImage) {
                    requestCreation(.work(.biology))
                }.accessibilityIdentifier("space.create.biology")
                Button(IDELanguageRunText.t("手记", "Notes"), systemImage: "book.pages") {
                    newTitle = IDELanguageRunText.t("未命名手记", "Untitled note"); newNote = true
                }
            } label: { Label(IDELanguageRunText.t("新建", "New"), systemImage: "plus") }
            .accessibilityIdentifier("space.new")
            Menu {
                // Import lives here (not as a standalone arrow) and keeps the
                // existing flow: one original copied into the current folder.
                Button(IDELanguageRunText.t("导入…", "Import…"), systemImage: "square.and.arrow.down") { importingGeography=false;importingLaTeX=false;importing = true }
                    .accessibilityIdentifier("space.import")
                Button(IDELanguageRunText.t("导入 LaTeX 工程…","Import LaTeX project…"),systemImage:"doc.richtext") {importingGeography=false;importingLaTeX=true;importing=true}
                    .accessibilityIdentifier("space.import.latex")
                Button(IDELanguageRunText.t("导入地理数据…", "Import geographic data…"), systemImage: "map") { importingGeography=true;importingLaTeX=false;importing=true }
                    .accessibilityIdentifier("space.import.geography")
                Button(IDELanguageRunText.t("最近删除", "Recently Deleted"), systemImage: "trash") { showingRecentlyDeleted = true }
                    .accessibilityIdentifier("space.files.recentlyDeleted")
                Divider()
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
    }

    private var filesSelecting: Bool { section == .files && selection.isSelecting }

    private func selectionCheckmark(for item: PersonalLibrarySelectionItem) -> some View {
        let checked = selection.isSelected(item)
        return Image(systemName: checked ? "checkmark.circle.fill" : "circle")
            .imageScale(.large)
            .foregroundStyle(checked ? Color.accentColor : Color.secondary)
            .accessibilityLabel(checked ? IDELanguageRunText.t("已选中", "Selected") : IDELanguageRunText.t("未选中", "Not selected"))
    }

    private func workRow(_ record: PersonalContentRecord, wide: Bool, openedAt: Date? = nil) -> some View {
        HStack(spacing: 12) {
            Button {
                if filesSelecting { selection.toggle(.work(record)) } else { presentWork(record) }
            } label: {
                HStack(spacing: 12) {
                    if filesSelecting { selectionCheckmark(for: .work(record)) }
                    Image(systemName: record.kind.systemImage).font(.body).frame(width: 28).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title).foregroundStyle(.primary).lineLimit(1)
                        if !wide {
                            HStack(spacing: 4) {
                                Text(record.kind.title)
                                Text("·")
                                Text(openedAt ?? record.modifiedAt, format: .dateTime.month().day().hour().minute())
                            }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if record.isPinned { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
                    if record.needsRecovery { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    if wide {
                        if openedAt != nil {
                            Text(personalPath(record.folders)).font(.subheadline).foregroundStyle(.secondary)
                                .lineLimit(1).frame(width: 140, alignment: .leading)
                        } else {
                            Text(record.kind.title).font(.subheadline).foregroundStyle(.secondary)
                                .lineLimit(1).frame(width: 100, alignment: .leading)
                        }
                        Text(openedAt ?? record.modifiedAt, format: .dateTime.month().day().hour().minute())
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            .frame(width: 130, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(.rect)
            }.buttonStyle(.plain)
            if !filesSelecting { fileMenu(record) }
        }
        .listRowInsets(.init(top: 0, leading: 16, bottom: 0, trailing: 16))
        .contextMenu { workActions(record) }
        .accessibilityIdentifier("space.file." + record.id.uuidString)
    }

    private func workCard(_ record: PersonalContentRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if filesSelecting { selection.toggle(.work(record)) } else { presentWork(record) }
            } label: {
                PersonalLibraryCover(record: record).frame(height: 104)
                    .overlay(alignment: .bottomTrailing) {
                        if filesSelecting { selectionCheckmark(for: .work(record)).padding(8) }
                    }
            }.buttonStyle(.plain)
            HStack(alignment: .top, spacing: 6) {
                Button {
                    if filesSelecting { selection.toggle(.work(record)) } else { presentWork(record) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                        Text(record.kind.title).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain)
                if record.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                if record.needsRecovery { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                if !filesSelecting { fileMenu(record) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contextMenu { workActions(record) }
    }

    private func fileMenu(_ record: PersonalContentRecord) -> some View {
        Menu { workActions(record) } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
        }.accessibilityLabel(IDELanguageRunText.t("更多操作：", "More actions: ") + record.title)
    }

    @ViewBuilder private func workActions(_ record: PersonalContentRecord) -> some View {
            if section == .files {
                Button(IDELanguageRunText.t("选择", "Select"), systemImage: "checkmark.circle") {
                    searchFocused = false
                    selection.begin(with: .work(record))
                }.disabled(busy).accessibilityIdentifier("space.files.select")
            }
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
            Divider()
            Button(role: .destructive) { deletion = .work(record) } label: {
                Label(IDELanguageRunText.t("删除", "Delete"), systemImage: "trash")
            }.disabled(busy).accessibilityIdentifier("space.files.delete")
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

    private func noteRow(_ note: NoteDocument, wide: Bool, openedAt: Date) -> some View {
        Button {
            openNote(note)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "book.pages").frame(width: 28).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title).foregroundStyle(.primary).lineLimit(1)
                    if !wide {
                        HStack(spacing: 4) {
                            Text(IDELanguageRunText.t("手记", "Notes"))
                            Text("·")
                            Text(openedAt, format: .dateTime.month().day().hour().minute())
                        }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if wide {
                    Text(IDELanguageRunText.t("手记", "Notes")).font(.subheadline).foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .leading)
                    Text(openedAt, format: .dateTime.month().day().hour().minute())
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: 130, alignment: .leading)
                }
                Color.clear.frame(width: 44, height: 1)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
        }.buttonStyle(.plain)
            .accessibilityIdentifier("space.note." + note.id.uuidString)
    }

    private func noteCard(_ note: NoteDocument) -> some View {
        Button { openNote(note) } label: {
            VStack(alignment: .leading, spacing: 10) {
                NotesDocumentThumbnail(document: note, store: notesStore, exposesAccessibility: false)
                    .frame(height: 104).clipped().clipShape(.rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                    Text(IDELanguageRunText.t("手记", "Notes")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
    }

    private func openNote(_ note: NoteDocument) {
        environment.documentIntakeCenter.presentSystemNote(documentID: note.id, title: note.title, sceneID: sceneID)
        section = .notes
    }

    @MainActor private func refresh() async {
        let generation = UUID()
        refreshGeneration = generation
        let requestedFolders = folders
        do {
            let library = try await PersonalContentService.shared.library()
            let updatedRecords = try await library.records()
            let updatedFolders = try await library.folderSnapshots(in: requestedFolders)
            let store = try await NotesRepository.shared.existingStore()
            let updatedNotes = try await store?.documents() ?? []
            let updatedVisits = try await store?.recentVisits(limit: 100) ?? []
            guard generation == refreshGeneration, folders == requestedFolders, !Task.isCancelled else { return }
            records = updatedRecords; childFolders = updatedFolders
            notesStore = store; notes = updatedNotes; noteVisits = updatedVisits
        } catch {
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            if case PersonalContentError.deleted = error, !folders.isEmpty {
                folders = []; await refresh()
            } else { notice = error.localizedDescription }
        }
    }
    @MainActor private func delete(_ selection: PersonalLibraryDeleteSelection) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            switch selection {
            case .work(let record): try await PersonalLibraryFileActions.delete(record, environment: environment)
            case .folder(let folder): try await PersonalLibraryFileActions.deleteFolder(folder, environment: environment)
            }
            await refresh()
        } catch { notice = error.localizedDescription }
    }
    /// Batch delete keeps every guard of the single-item operations. Partial
    /// failure is reported with the survivors still listed; cancel never
    /// drops an original before its own deletion ran.
    @MainActor private func deleteSelection() async {
        guard !busy else { return }
        let items = selection.effectiveSelection()
        guard !items.isEmpty else { selection.cancel(); return }
        let sourceFolders = folders, sourceQuery = query, sourceKind = fileKind
        busy = true; defer { busy = false }
        let result = await PersonalLibraryFileActions.deleteBatch(items, environment: environment)
        selection.cancel()
        await refresh()
        if !result.failed.isEmpty {
            if section == .files, folders == sourceFolders, query == sourceQuery, fileKind == sourceKind {
                let failedIDs = Set(result.failed.map { $0.item.id })
                selection.begin()
                selection.selectAll(visibleSelectionItems.filter { failedIDs.contains($0.id) })
            }
            notice = result.summary + "\n" + result.failureDetail
        }
    }
    @MainActor private func requestCreation(_ target: PersonalContentCreationRequest.Target) {
        searchFocused = false
        createdAfterNaming = nil
        creationRequest = .init(target: target, folders: folders)
    }
    @MainActor private func presentCreatedWorkAfterNaming() {
        guard let record = createdAfterNaming else { return }
        createdAfterNaming = nil
        // This callback is the presentation boundary: the naming sheet and
        // its keyboard have finished dismissal before a full-screen editor opens.
        presentWork(record)
        Task { await refresh() }
    }
    @MainActor private func createFolder(name: String, in destination: [String]) async {
        do {
            let library = try await PersonalContentService.shared.library()
            try await library.createFolder(name, in: destination)
            // Reveal the created folder even if a previous search/type filter
            // would hide every ordinary directory. The request owns its path.
            searchFocused = false; query = ""; fileKind = .all
            folders = destination; section = .files
            await refresh()
        } catch { notice = error.localizedDescription }
    }
}
#endif
