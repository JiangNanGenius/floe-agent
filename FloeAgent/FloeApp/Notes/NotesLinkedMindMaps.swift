// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes

struct NotesLinkedMindMaps: View {
    let session: NotesSession
    let document: NoteDocument
    let pageID: UUID?
    let open: (NoteMindMapLink) -> Void
    @State private var title = ""
    @State private var anchorToPage = true
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var links: [NoteMindMapLink] { document.linkedMindMaps ?? [] }
    private var candidates: [NoteDocument] {
        session.documents.filter { $0.kind == .mindMap && $0.deletedAt == nil && !links.map(\.documentID).contains($0.id) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section("已关联") {
                    if links.isEmpty { Text("还没有关联导图").foregroundStyle(.secondary) }
                    ForEach(links) { link in
                        if let map = session.documents.first(where: { $0.id == link.documentID }) {
                            HStack {
                                Button {
                                    open(link); dismiss()
                                } label: {
                                    VStack(alignment: .leading) {
                                        Label(map.title, systemImage: "point.3.connected.trianglepath.dotted")
                                        Text(map.deletedAt != nil ? "已移入回收站" : link.pageID == nil ? "整个文档" : "关联到指定页面")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.disabled(map.deletedAt != nil)
                                Spacer()
                                Menu {
                                    if map.deletedAt != nil {
                                        Button("恢复导图") { session.trash(map, restore: true) }
                                    }
                                    if let pageID, map.deletedAt == nil {
                                        Button("关联到当前页") { var updated = link; updated.pageID = pageID; change(.linkMindMap(updated)) }
                                    }
                                    if link.pageID != nil {
                                        Button("改为整个文档") { var updated = link; updated.pageID = nil; change(.linkMindMap(updated)) }
                                    }
                                    Button("解除关联", role: .destructive) { change(.unlinkMindMap(link.id)) }
                                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                            }
                        }
                    }
                }
                Section {
                    if pageID != nil { Toggle("关联到当前页", isOn: $anchorToPage) }
                    TextField("新导图名称", text: $title)
                    Button("新建并关联", systemImage: "plus") { create() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || links.count >= 100)
                } header: { Text("新建") } footer: {
                    Text("导图独立保存，也会出现在手记的导图列表中。解除关联或删除这份文档，不会删除导图。")
                }
                Section("关联已有导图") {
                    ForEach(candidates) { map in
                        Button(map.title) {
                            let link = NoteMindMapLink(documentID: map.id, pageID: anchorToPage ? pageID : nil)
                            change(.linkMindMap(link))
                        }.disabled(links.count >= 100)
                    }
                }
            }.disabled(busy)
                .navigationTitle("文档导图")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .alert("文档导图", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("好") { error = nil }
                } message: { Text(error ?? "") }
        }.presentationDetents([.medium, .large])
    }
    private func change(_ edit: NoteEdit) {
        busy = true
        Task {
            defer { busy = false }
            do {
                guard let store = session.store else { throw NoteError.resourceUnavailable }
                let latest = try await store.document(document.id)
                _ = try await session.commit([edit], documentID: latest.id, expectedRevision: latest.revision)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func create() {
        busy = true
        Task {
            defer { busy = false }
            do {
                guard let store = session.store else { throw NoteError.resourceUnavailable }
                let latest = try await store.document(document.id)
                let map = try await store.createLinkedMindMap(parentID: latest.id, expectedRevision: latest.revision,
                                                            title: title, pageID: anchorToPage ? pageID : nil)
                try await session.reload()
                if let link = session.documents.first(where: { $0.id == document.id })?.linkedMindMaps?.first(where: { $0.documentID == map.id }) {
                    open(link); dismiss()
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Viewport state belongs to the document reader. The map has a separate session and undo stack.
struct NotesMindMapWindow: View {
    let parentSession: NotesSession
    let link: NoteMindMapLink
    let close: () -> Void
    @State private var session = NotesSession()
    @State private var images: [UUID: Data] = [:]
    @State private var selected: UUID?
    @State private var inspector: MindMapNode?
    let onAssistant: (NoteDocument) -> Void
    @State private var expanded = false
    @AppStorage private var relativeX: Double
    @AppStorage private var relativeY: Double
    @AppStorage private var relativeWidth: Double
    @AppStorage private var relativeHeight: Double
    @GestureState private var moving: CGSize = .zero
    @GestureState private var resizing: CGSize = .zero

    init(parentSession: NotesSession, parentID: UUID, link: NoteMindMapLink, close: @escaping () -> Void, onAssistant: @escaping (NoteDocument) -> Void) {
        self.parentSession = parentSession; self.link = link; self.close = close; self.onAssistant = onAssistant
        let key = "notes.mapWindow.\(parentID.uuidString)"
        _relativeX = AppStorage(wrappedValue: 0.98, key + ".x")
        _relativeY = AppStorage(wrappedValue: 0.08, key + ".y")
        _relativeWidth = AppStorage(wrappedValue: 0.5, key + ".width")
        _relativeHeight = AppStorage(wrappedValue: 0.52, key + ".height")
    }
    private var imageIDs: Set<UUID> { Set(session.document?.nodes.compactMap(\.imageResourceID) ?? []) }
    private var selectedNode: MindMapNode? {
        session.document?.nodes.first { $0.id == selected } ?? session.document?.nodes.first { $0.parentID == nil }
    }
    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size
            let compact = available.width < 600
            let width = expanded || compact ? available.width : min(available.width, max(340, available.width * relativeWidth + resizing.width))
            let height = expanded ? available.height : min(available.height, max(280, available.height * relativeHeight + resizing.height))
            let x = expanded || compact ? 0 : max(0, min(available.width - width, (available.width - width) * relativeX + moving.width))
            let y = expanded ? 0 : max(0, min(available.height - height, (available.height - height) * relativeY + moving.height))
            panel
                .frame(width: width, height: height)
                .background(.background, in: RoundedRectangle(cornerRadius: expanded ? 0 : 18))
                .clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : 18))
                .overlay(alignment: .top) {
                    if !expanded {
                        Capsule().fill(.secondary).frame(width: 44, height: 5)
                            .frame(width: 100, height: 28).contentShape(Rectangle())
                            .accessibilityLabel("拖动导图小窗")
                            .gesture(DragGesture().updating($moving) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    relativeX = max(0, min(1, ((available.width - width) * relativeX + value.translation.width) / max(1, available.width - width)))
                                    relativeY = max(0, min(1, ((available.height - height) * relativeY + value.translation.height) / max(1, available.height - height)))
                                })
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !expanded {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption)
                            .frame(width: 44, height: 44).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("调整导图小窗大小")
                            .gesture(DragGesture().updating($resizing) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    relativeWidth = min(1, max(min(1, 340 / available.width), relativeWidth + value.translation.width / max(1, available.width)))
                                    relativeHeight = min(1, max(min(1, 280 / available.height), relativeHeight + value.translation.height / max(1, available.height)))
                                })
                    }
                }
                .shadow(color: .black.opacity(0.18), radius: 16, y: 5)
                .offset(x: x, y: y)
        }
        .task(id: link.documentID) {
            await session.open(using: parentSession.store)
            if let map = session.documents.first(where: { $0.id == link.documentID }) { await session.select(map) }
        }
        .task(id: imageIDs) {
            guard let store = session.store else { return }
            do { images = try await NoteFileImporter.images(resourceIDs: imageIDs, store: store) }
            catch { session.errorMessage = error.localizedDescription }
        }
        .sheet(item: $inspector) { node in
            if let document = session.document { MindMapTopicInspector(session: session, document: document, node: node) }
        }
        .alert("导图", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("好") { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
    }
    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.document?.title ?? "导图").font(.headline).lineLimit(1)
                Spacer()
                Button("完整编辑器", systemImage: "arrow.up.forward.app") {
                    Task { if let map = session.document { await parentSession.select(map); close() } }
                }
                Button(expanded ? "还原小窗" : "展开", systemImage: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") { expanded.toggle() }
                Button("关闭小窗", systemImage: "xmark") { close() }
            }.labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.large).padding(.horizontal, 12).padding(.top, expanded ? 8 : 22).padding(.bottom, 6)
            Divider()
            if let document = session.document, document.deletedAt == nil {
                HStack(spacing: 16) {
                    Button("撤销", systemImage: "arrow.uturn.backward") { session.undo() }.disabled(!session.canUndo)
                    Button("重做", systemImage: "arrow.uturn.forward") { session.undo(redo: true) }.disabled(!session.canRedo)
                    Button("主题附件", systemImage: "paperclip") { inspector = selectedNode }
                    Button("Floe 助手", systemImage: "bubble.left.and.bubble.right") { onAssistant(document) }
                    Spacer()
                    Text(session.pendingWrites > 0 ? "保存中" : "已保存").font(.caption).foregroundStyle(.secondary)
                }.labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.large).padding(8)
                    .disabled(session.pendingWrites > 0)
                NoteMindMapView(document: document, onEdit: { edits, revision in
                    try await session.commit(edits, documentID: document.id, expectedRevision: revision)
                }, onHistory: { session.undo(redo: $0) }, onError: { session.errorMessage = $0 }, images: images, onSelection: { selected = $0 })
            } else {
                ContentUnavailableView("导图不可用", systemImage: "doc.questionmark", description: Text("请在文档导图列表中检查关联或从回收站恢复。"))
            }
        }.accessibilityIdentifier("notes.mindmap.window")
    }
}
#endif
