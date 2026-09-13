// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes
import UniformTypeIdentifiers
import PencilKit

struct NotesRootView: View {
    @State private var session = NotesSession()
    @State private var query = ""
    @AppStorage("notes.library.grid") private var grid = true
    @State private var section: SectionFilter = .recent
    @State private var newTitle = ""
    @State private var creation: Creation?
    @State private var importing = false
    @State private var deleting: NoteDocument?
    @State private var renaming: RenameTarget?
    @State private var selectedBook: UUID?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private enum SectionFilter: String, CaseIterable {
        case recent = "最近", all = "全部内容", maps = "思维导图", favorites = "收藏", trash = "回收站"
    }
    private struct RenameTarget: Identifiable {
        let id: UUID
        let title: String
        let notebook: Bool
    }
    private enum Creation: String, Identifiable {
        case note = "新建手记", map = "新建思维导图", notebook = "新建笔记本"
        case word = "新建 Word 文档", sheet = "新建 Excel 表格", slides = "新建 PowerPoint 演示文稿"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            library
            .fullScreenCover(isPresented: Binding(
                get: { session.document != nil },
                set: { if !$0 { Task { await session.select(nil) } } }
            )) {
                NavigationStack {
                    if let document = session.document, document.deletedAt == nil {
                        NotesDocumentEditor(session: session, document: document)
                            .id(document.id)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                if document.kind != .office {
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button("返回手记", systemImage: "chevron.left") {
                                            Task { await session.select(nil) }
                                        }.accessibilityIdentifier("notes.back")
                                    }
                                }
                            }
                    }
                }
                .interactiveDismissDisabled()
            }
            .navigationTitle("手记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if session.document != nil {
                        Button("返回", systemImage: "chevron.left") { Task { await session.select(nil) } }
                            .accessibilityIdentifier("notes.back")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("空白手记", systemImage: "doc.badge.plus") { creation = .note }
                        Button("思维导图", systemImage: "point.3.connected.trianglepath.dotted") { creation = .map }
                        Button("笔记本", systemImage: "folder.badge.plus") { creation = .notebook }
                        Menu("Office", systemImage: "doc.richtext") {
                            Button("Word 文档") { creation = .word }
                            Button("Excel 表格") { creation = .sheet }
                            Button("PowerPoint 演示文稿") { creation = .slides }
                        }
                        Button("导入手记、PDF、Office 或图片", systemImage: "square.and.arrow.down") { importing = true }
                    } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("新建或导入")
                    .accessibilityIdentifier("notes.create")
                    .disabled(session.store == nil)
                }
            }
            .sheet(item: $renaming) { target in
                NotesRenameSheet(title: target.title) { name in
                    if target.notebook { session.renameNotebook(target.id, title: name) }
                    else { session.apply([.rename(name)], title: "重命名", documentID: target.id) }
                    renaming = nil
                }
            }
            .sheet(item: $creation) { kind in
                NavigationStack {
                    Form { TextField("名称", text: $newTitle).accessibilityIdentifier("notes.create.title") }
                        .navigationTitle(kind.rawValue)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { creation = nil; newTitle = "" } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("创建") {
                                    if kind == .notebook { session.createNotebook(newTitle) }
                                    else if kind == .word || kind == .sheet || kind == .slides {
                                        session.createOffice(extension: kind == .word ? "docx" : kind == .sheet ? "xlsx" : "pptx", title: newTitle, notebookID: selectedBook)
                                    }
                                    else { session.create(kind: kind == .map ? .mindMap : .notebook, title: newTitle, notebookID: selectedBook) }
                                    creation = nil; newTitle = ""
                                }.disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                }.presentationDetents([.medium])
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image, UTType(exportedAs: "org.floeagent.note", conformingTo: .data)] + ["docx", "doc", "odt", "rtf", "xlsx", "xls", "ods", "pptx", "ppt", "odp"].compactMap { UTType(filenameExtension: $0) }) { result in
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
            .task { await session.open() }
        }
    }

    private var library: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索手记与导图", text: $query)
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
            ScrollView {
              LazyVGrid(columns: grid ? [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 20)] : [GridItem(.flexible())], spacing: 24) {
                if selectedBook == nil && section != .trash && query.isEmpty {
                    ForEach(session.notebooks) { book in
                        Button { selectedBook = book.id } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: "folder.fill").font(.system(size: 42)).foregroundStyle(.tint)
                                    .frame(maxWidth: .infinity, minHeight: grid ? 130 : 44, alignment: .leading)
                                Text(book.title).font(.headline).foregroundStyle(.primary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
                ForEach(filtered) { document in
                    Button { Task { await session.select(document) } } label: {
                        let layout = grid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                        layout {
                            NotesCoverPreview(document: document, store: session.store)
                                .frame(width: grid ? nil : 64, height: grid ? 190 : 80)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(document.title).font(.headline).foregroundStyle(.primary)
                                Text(document.kind == .mindMap ? "\(document.nodes.count) 个主题" : document.kind == .office ? (document.officeFileName ?? "Office 文档") : "\(document.pages.count) 页")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(document.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if document.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                        }.padding(.vertical, 6)
                    }
                    .disabled(document.deletedAt != nil)
                    .contextMenu {
                        if document.deletedAt != nil {
                            Button("恢复", systemImage: "arrow.uturn.backward") { session.trash(document, restore: true) }
                            Button("永久删除", systemImage: "trash", role: .destructive) { deleting = document }
                        } else {
                            Button("重命名", systemImage: "pencil") { renaming = .init(id: document.id, title: document.title, notebook: false) }
                            Button(document.isFavorite ? "取消收藏" : "收藏", systemImage: "star") {
                                session.apply([.favorite(!document.isFavorite)], title: "收藏", documentID: document.id)
                            }
                            Menu("移到笔记本") {
                                Button("未分类") { session.apply([.moveToNotebook(nil)], title: "移动", documentID: document.id) }
                                ForEach(session.notebooks) { book in
                                    Button(book.title) { session.apply([.moveToNotebook(book.id)], title: "移动", documentID: document.id) }
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
                .overlay {
                    if session.store == nil { ProgressView("正在打开手记…") }
                    else if filtered.isEmpty {
                        ContentUnavailableView("还没有内容", systemImage: "book.closed", description: Text("新建手记、导入课件，或开始一张思维导图。"))
                    }
                }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
            return matchesSection && (selectedBook == nil || value.notebookID == selectedBook)
                && (query.isEmpty || value.searchableText.localizedStandardContains(query))
        }.sorted { first, second in
            if section == .recent { return (recentOrder[first.id] ?? Int.max) < (recentOrder[second.id] ?? Int.max) }
            return first.updatedAt > second.updatedAt
        }
    }
}
private struct NotesRenameSheet: View {
    @State private var name: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    init(title: String, save: @escaping (String) -> Void) { _name = State(initialValue: title); self.save = save }
    var body: some View {
        NavigationStack {
            Form { TextField("名称", text: $name) }
                .navigationTitle("重命名")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { save(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.presentationDetents([.medium])
    }
}
@MainActor private struct NotesCoverPreview: View {
    let document: NoteDocument
    let store: NotesStore?
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else {
                VStack(spacing: 12) {
                    Image(systemName: document.kind == .mindMap ? "point.3.connected.trianglepath.dotted" : document.kind == .office ? "doc.richtext" : "book.closed")
                        .font(.largeTitle).foregroundStyle(.tint)
                    Text(document.kind == .mindMap ? document.nodes.first?.title ?? document.title : document.officeFileName ?? document.title)
                        .font(.caption).lineLimit(3).multilineTextAlignment(.center)
                }.padding()
            }
        }
        .task(id: document.revision) {
            guard let store, let page = document.pages.first else { return }
            do {
                let background = (try await NoteFileImporter.background(page: page, store: store)).flatMap { UIImage(data: $0) }
                let ink: PKDrawing?
                if let id = page.drawingResourceID { ink = try PKDrawing(data: Data(contentsOf: await store.resourceURL(id))) }
                else { ink = nil }
                try Task.checkCancellation()
                let scale = min(240 / page.width, 320 / page.height)
                let size = CGSize(width: page.width * scale, height: page.height * scale)
                image = UIGraphicsImageRenderer(size: size).image { context in
                    context.cgContext.scaleBy(x: scale, y: scale)
                    NotePageRenderer.draw(page, background: background, images: [:])
                    ink?.image(from: CGRect(x: 0, y: 0, width: page.width, height: page.height), scale: 240 / page.width)
                        .draw(in: CGRect(x: 0, y: 0, width: page.width, height: page.height))
                }
            } catch { image = nil }
        }
    }
}

#endif
