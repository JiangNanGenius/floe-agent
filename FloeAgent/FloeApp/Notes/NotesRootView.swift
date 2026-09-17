// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes
import UniformTypeIdentifiers
import PencilKit

struct NotesRootView: View {
    @FocusState private var searchFocused: Bool
    @State private var session = NotesSession(tabDefaults: .standard)
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
    @State private var renaming: RenameTarget?
    @State private var selectedBook: UUID?
    /// Settled cover source and revision per document, reported by each
    /// thumbnail card so accessibility (and the UI acceptance tests) can
    /// distinguish real content covers from the explicit unsupported/placeholder
    /// state and prove a revision-keyed reload.
    @State private var coverSources: [UUID: String] = [:]
    @Environment(\.horizontalSizeClass) private var sizeClass

    private enum SectionFilter: String, CaseIterable {
        case recent = "最近", all = "全部内容", maps = "思维导图", favorites = "收藏", trash = "回收站"
    }
    private struct RenameTarget: Identifiable {
        let id: UUID
        let title: String
        let notebook: Bool
        var document: NoteDocument? = nil
    }
    private enum Creation: String, Identifiable {
        case note = "新建手记", map = "新建思维导图", notebook = "新建笔记本"
        case word = "新建 Word 文档", sheet = "新建 Excel 表格", slides = "新建 PowerPoint 演示文稿"
        var id: String { rawValue }
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
                .interactiveDismissDisabled()
            }
            .navigationTitle("手记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("空白手记", systemImage: "doc.badge.plus") { creation = .note }
                        Button("思维导图", systemImage: "point.3.connected.trianglepath.dotted") { creation = .map }
                        Button("笔记本", systemImage: "folder.badge.plus") { creation = .notebook }
                        Menu("Office", systemImage: "doc.richtext") {
                            Button("Word 文档") { creation = .word }.accessibilityIdentifier("notes.create.word")
                            Button("Excel 表格") { creation = .sheet }
                            Button("PowerPoint 演示文稿") { creation = .slides }
                        }
                        Button("从 Floe 工作区导入", systemImage: "folder") { importingWorkspace = true }
                            .accessibilityIdentifier("notes.import.workspace")
                        Button("notes.import.all", systemImage: "square.and.arrow.down") { importing = true }
                    } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("新建或导入")
                    .accessibilityIdentifier("notes.create")
                    .disabled(session.store == nil)
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
                if pending.kind == .notebook { session.createNotebook(pending.title) }
                else if pending.kind == .word || pending.kind == .sheet || pending.kind == .slides {
                    session.createOffice(extension: pending.kind == .word ? "docx" : pending.kind == .sheet ? "xlsx" : "pptx", title: pending.title, notebookID: selectedBook)
                } else {
                    session.create(kind: pending.kind == .map ? .mindMap : .notebook, title: pending.title, notebookID: selectedBook)
                }
            }) { kind in
                NavigationStack {
                    Form { TextField("名称", text: $newTitle).accessibilityIdentifier("notes.create.title") }
                        .navigationTitle(kind.rawValue)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { creation = nil; newTitle = "" } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("创建") {
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
                            session.importArchive(url, notebookID: selectedBook)
                            return
                        }
                        guard let store = session.store else { return }
                        let document = try await NoteFileImporter.importFile(url, notebookID: selectedBook, store: store)
                        session.importDocument(document)
                    } catch { session.errorMessage = error.localizedDescription }
                }
            }
            .confirmationDialog("永久删除此内容？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { value in
                Button("永久删除", role: .destructive) { session.permanentlyDelete(value); deleting = nil }
                Button("取消", role: .cancel) { deleting = nil }
            } message: { value in
                Text("“\(value.title)”及其撤销记录将无法恢复。独立关联导图和其他内容使用的附件会保留。")
            }
            .alert("手记", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
                Button("好") { session.errorMessage = nil }
            } message: { Text(session.errorMessage ?? "") }
            .task {
                await session.open()
                #if DEBUG
                await NotesOfficeThumbnailFixture.seedIfRequested(session: session)
                #endif
            }
        }
    }

    private var library: some View {
        // Body-search results keep title and excerpt beside the preview, even
        // with the landscape iPad keyboard taking most of the vertical space.
        let showsCovers = grid && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return libraryContent(showsCovers: showsCovers)
    }

    private func libraryContent(showsCovers: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索所有文档的名称与内容", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { searchFocused = false }
                    .accessibilityIdentifier("notes.search")
            }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)).padding()
            HStack {
                Picker("内容", selection: $section) {
                    ForEach(SectionFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
                Spacer()
                Button(grid ? "列表视图" : "封面视图", systemImage: grid ? "list.bullet" : "square.grid.2x2") { grid.toggle() }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                Picker("笔记本", selection: $selectedBook) {
                    Text("所有笔记本").tag(Optional<UUID>.none)
                    ForEach(session.notebooks) { Text($0.title).tag(Optional($0.id)) }
                }.pickerStyle(.menu)
                if let book = session.notebooks.first(where: { $0.id == selectedBook }) {
                    Button("重命名笔记本", systemImage: "pencil") { renaming = .init(id: book.id, title: book.title, notebook: true) }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
            }.padding(.horizontal)
            if let id = session.indexingDocumentID {
                ProgressView("正在索引：\(session.documents.first(where: { $0.id == id })?.title ?? "文档")")
                    .font(.caption).padding(.horizontal)
            }
            if !query.isEmpty {
                let incomplete = session.documents.filter { $0.deletedAt == nil && (($0.kind == .office && ($0.officeTextResourceID != $0.officeResourceID || $0.officeTextError != nil)) || $0.pages.contains { $0.textExtractionTruncated == true || ($0.needsVisualIndex && ($0.ocrSourceKey != $0.visualIndexKey || $0.ocrError != nil)) }) }.count
                if incomplete > 0 { Text("\(incomplete) 份文档尚未完整索引，搜索结果可能不完整。").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            }
            ScrollView {
              LazyVGrid(columns: showsCovers ? [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 20)] : [GridItem(.flexible())], spacing: 24) {
                if selectedBook == nil && section != .trash && query.isEmpty {
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
                ForEach(filtered) { document in
                    Button {
                        Task {
                            await session.select(document)
                            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                session.requestedPageID = document.pages.first { page in
                                    ((page.extractedText ?? "") + "\n" + (page.indexedVisualText ?? "") + "\n" + page.elements.map(\.text).joined(separator: "\n"))
                                        .localizedStandardContains(query.trimmingCharacters(in: .whitespacesAndNewlines))
                                }?.id
                            }
                        }
                    } label: {
                        let layout = showsCovers ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                        layout {
                            NotesDocumentThumbnail(document: document, store: session.store) { source, revision in
                                let value = "\(source.rawValue)#\(revision)"
                                if coverSources[document.id] != value {
                                    coverSources[document.id] = value
                                }
                            }
                                .frame(width: showsCovers ? nil : 64, height: showsCovers ? 190 : 80)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(document.title).font(.headline).foregroundStyle(.primary)
                                Text(document.kind == .mindMap ? "\(document.nodes.count) 个主题" : document.kind == .office ? (document.officeFileName ?? "Office 文档") : document.kind == .engineering ? (document.engineeringFileName ?? String(localized: "notes.kind.engineering")) : "\(document.pages.count) 页")
                                    .font(.caption).foregroundStyle(.secondary)
                                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(searchSnippet(document.searchableText))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                                if document.kind == .office {
                                    if document.officeTextResourceID != document.officeResourceID {
                                        Label("等待正文索引", systemImage: "text.magnifyingglass").font(.caption2).foregroundStyle(.secondary)
                                    } else if document.officeTextError != nil {
                                        Label("正文未索引", systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Text(document.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if document.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                        }.padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("notes.card.\(document.kind.rawValue).\(document.title).\(coverSources[document.id] ?? "none")")
                    .accessibilityValue(coverSources[document.id] ?? "none")
                    .multilineTextAlignment(.leading)
                    .disabled(document.deletedAt != nil)
                    .contextMenu {
                        if document.deletedAt != nil {
                            Button("恢复", systemImage: "arrow.uturn.backward") { session.trash(document, restore: true) }
                            Button("永久删除", systemImage: "trash", role: .destructive) { deleting = document }
                        } else {
                            Button("重新索引正文", systemImage: "text.magnifyingglass") { session.rebuildSearchIndex(documentID: document.id) }
                            Button("重命名", systemImage: "pencil") { renaming = .init(id: document.id, title: document.title, notebook: false, document: document) }
                            Button(document.isFavorite ? "取消收藏" : "收藏", systemImage: "star") {
                                session.apply([.favorite(!document.isFavorite)], title: "收藏", base: document)
                            }
                            Menu("移到笔记本") {
                                Button("未分类") { session.apply([.moveToNotebook(nil)], title: "移动", base: document) }
                                ForEach(session.notebooks) { book in
                                    Button(book.title) { session.apply([.moveToNotebook(book.id)], title: "移动", base: document) }
                                }
                            }
                            Button("移到回收站", role: .destructive) { session.trash(document) }
                        }
                    }
                    if document.deletedAt != nil {
                        HStack {
                            Button("恢复“\(document.title)”") { session.trash(document, restore: true) }
                            Spacer()
                            Button("永久删除", role: .destructive) { deleting = document }
                        }
                    }
                }
              }.padding(20)
            }
                .accessibilityIdentifier("notes.library.scroll")
                .scrollDismissesKeyboard(.interactively)
                .overlay {
                    if session.store == nil { ProgressView("正在打开手记…") }
                    else if filtered.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "还没有内容" : "没有找到匹配的内容",
                            systemImage: query.isEmpty ? "book.closed" : "magnifyingglass",
                            description: Text(query.isEmpty ? "新建手记、导入课件，或开始一张思维导图。" : "试试其他关键词。扫描件和手写内容需要识别后才能按文字搜索。"))
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
        let recentOrder = Dictionary(uniqueKeysWithValues: session.recentDocumentIDs.enumerated().map { ($0.element, $0.offset) })
        return session.documents.filter { value in
            let matchesSection: Bool
            switch section {
            case .trash: matchesSection = value.deletedAt != nil
            case .maps: matchesSection = value.deletedAt == nil && value.kind == .mindMap
            case .favorites: matchesSection = value.deletedAt == nil && value.isFavorite
            case .recent: matchesSection = value.deletedAt == nil && recentOrder[value.id] != nil
            case .all: matchesSection = value.deletedAt == nil
            }
            let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !search.isEmpty {
                // Global search must include documents outside Recently Opened or the current notebook.
                return value.deletedAt == nil && value.searchableText.localizedStandardContains(search)
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
            Form { TextField("名称", text: $name).accessibilityIdentifier("notes.rename.title") }
                .navigationTitle("重命名")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
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
                .alert("手记", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("好") { error = nil }
                } message: { Text(error ?? "") }
        }.presentationDetents([.medium]).interactiveDismissDisabled(saving)
    }
}

#endif
