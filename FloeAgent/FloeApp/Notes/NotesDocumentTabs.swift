// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes

/// Only the active document mounts an editor. Other tabs retain lightweight navigation state.
struct NotesDocumentTabs: View {
    let session: NotesSession
    @State private var choosingDocument = false
    @State private var pendingDocument: NoteDocument?
    @State private var query = ""
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var openDocuments: [NoteDocument] {
        session.tabs.documentIDs.compactMap { id in session.documents.first { $0.id == id && $0.deletedAt == nil } }
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(openDocuments) { document in
                            HStack(spacing: 0) {
                                Button {
                                    Task { await session.select(document) }
                                } label: {
                                    Text(document.title).font(.subheadline.weight(.medium))
                                        .lineLimit(1).frame(width: sizeClass == .compact ? 80 : 150, height: 44)
                                        .padding(.leading, 10)
                                }
                                .accessibilityIdentifier("notes.tab.\(document.id.uuidString)")
                                .accessibilityValue(session.unsavedDocumentIDs.contains(document.id) ? "尚有未保存修改" : session.pendingWrites > 0 && session.document?.id == document.id ? "正在保存" : "已保存到本机")
                                .accessibilityAddTraits(session.document?.id == document.id ? .isSelected : [])
                                Button {
                                    Task { await session.closeTab(document.id) }
                                } label: { Image(systemName: "xmark").font(.caption).frame(width: 44, height: 44) }
                                    .accessibilityLabel("关闭标签：\(document.title)")
                                    .accessibilityIdentifier("notes.tab.close.\(document.id.uuidString)")
                            }
                            .background(session.document?.id == document.id ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                            .id(document.id)
                        }
                    }
                }
                .onChange(of: session.document?.id, initial: true) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Button { choosingDocument = true } label: {
                Image(systemName: "plus").frame(width: 44, height: 44)
            }.accessibilityLabel("打开其他文档").accessibilityIdentifier("notes.tabs.open")
        }
        .buttonStyle(NotesToolbarButtonStyle())
        .disabled(session.isSwitchingDocument)
        .sheet(isPresented: $choosingDocument, onDismiss: {
            guard let pendingDocument else { return }
            self.pendingDocument = nil
            Task { await session.select(pendingDocument) }
        }) {
            NavigationStack {
                List {
                    ForEach(session.documents.filter { document in
                        document.deletedAt == nil && (query.isEmpty || document.searchableText.localizedStandardContains(query))
                    }) { document in
                        Button {
                            pendingDocument = document
                            choosingDocument = false
                        } label: {
                            Label(document.title, systemImage: document.kind == .mindMap ? "point.3.connected.trianglepath.dotted" : "doc")
                        }.accessibilityIdentifier("notes.tabs.choose.\(document.id.uuidString)")
                    }
                }
                .searchable(text: $query, prompt: "搜索文档名称与内容")
                .navigationTitle("打开文档")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { choosingDocument = false } } }
            }
        }
    }
}
#endif
