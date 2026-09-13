// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeNotes

/// A draft owns its revision. Concurrent Agent edits produce a conflict instead of being overwritten.
struct MindMapTopicInspector: View {
    let session: NotesSession
    let document: NoteDocument
    @State var node: MindMapNode
    var onOpenSource: ((NoteSourceReference) async -> Bool)? = nil
    @State private var pendingSource: NoteSourceReference?
    @State private var savedRevision: Int?
    @State private var savedNode: MindMapNode?
    @State private var importing = false
    @State private var replacing: UUID?
    @State private var busy = false
    @State private var preview: Preview?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private struct Preview: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("主题") {
                    TextField("标题", text: $node.title)
                    TextField("详细说明", text: $node.note, axis: .vertical).lineLimit(4...12)
                    TextField("网页链接 https://…", text: Binding(get: { node.hyperLink ?? "" }, set: { node.hyperLink = $0.isEmpty ? nil : $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    if let source = node.source {
                        Button("打开来源", systemImage: "arrow.up.forward.app") {
                            requestSource(source)
                        }
                    }
                }
                Section {
                    ForEach(node.attachments ?? []) { attachment in
                        attachmentRow(attachment)
                    }
                    Button("添加图片、文档或音视频", systemImage: "paperclip") {
                        replacing = nil; importing = true
                    }.disabled((node.attachments ?? []).count >= 32 || busy)
                } header: { Text("附件 · \((node.attachments ?? []).count) / 32") }
                footer: { Text("附件随导图长期保存。移除附件可在保存后撤销；网页链接在系统浏览器中打开。") }
            }
            .disabled(busy)
            .navigationTitle("主题内容")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(busy || node.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay { if busy { ProgressView("正在处理…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                importAttachment(result)
            }
            .sheet(item: $preview, onDismiss: { }) { item in
                NavigationStack {
                    QuickLookView(url: item.url).navigationTitle(item.url.lastPathComponent)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { ShareLink(item: item.url) } }
                }
                .onDisappear { try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent()) }
            }
            .alert("主题内容", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }.presentationDetents([.large])
            .confirmationDialog("离开前保存主题修改？", isPresented: Binding(get: { pendingSource != nil }, set: { if !$0 { pendingSource = nil } }), titleVisibility: .visible) {
                if let source = pendingSource {
                    Button("保存并打开来源") { navigate(source, saveChanges: true) }
                    Button("放弃修改并打开来源", role: .destructive) { navigate(source, saveChanges: false) }
                }
                Button("取消", role: .cancel) { pendingSource = nil }
            }.interactiveDismissDisabled(busy)
    }

    private func attachmentRow(_ attachment: MindMapAttachment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { preparePreview(attachment) } label: {
                Label(attachment.fileName, systemImage: icon(attachment.kind)).lineLimit(2)
            }
            TextField("附件说明", text: Binding(get: {
                node.attachments?.first(where: { $0.id == attachment.id })?.caption ?? ""
            }, set: { text in
                if let index = node.attachments?.firstIndex(where: { $0.id == attachment.id }) { node.attachments?[index].caption = text }
            }), axis: .vertical)
            HStack {
                if attachment.kind == .image {
                    Button("设为主题图片") { node.imageResourceID = attachment.resourceID }
                }
                Button("替换") { replacing = attachment.id; importing = true }
                if let source = attachment.source {
                    Button("来源") { requestSource(source) }
                }
                Spacer()
                Button("移除", role: .destructive) {
                    node.attachments?.removeAll { $0.id == attachment.id }
                    if node.imageResourceID == attachment.resourceID { node.imageResourceID = nil }
                }
            }.font(.callout).buttonStyle(.borderless)
        }.padding(.vertical, 4)
    }

    private func icon(_ kind: MindMapAttachment.Kind) -> String {
        switch kind { case .image: "photo"; case .document: "doc.richtext"; case .audio: "waveform"; case .video: "film"; case .file: "paperclip" }
    }

    private func requestSource(_ source: NoteSourceReference) {
        if (savedNode ?? document.nodes.first(where: { $0.id == node.id })) != node { pendingSource = source }
        else { navigate(source, saveChanges: false) }
    }

    private func navigate(_ source: NoteSourceReference, saveChanges: Bool) {
        pendingSource = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                if saveChanges {
                    let saved = try await session.commit([.upsertNode(node)], documentID: document.id, expectedRevision: savedRevision ?? document.revision)
                    savedRevision = saved.revision; savedNode = node
                }
                let opened: Bool
                if let onOpenSource { opened = await onOpenSource(source) }
                else { opened = await session.openSource(source) }
                if opened { dismiss() }
                else { error = session.errorMessage ?? "无法打开来源，请检查资料是否仍然可用。" }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await session.commit([.upsertNode(node)], documentID: document.id, expectedRevision: savedRevision ?? document.revision)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func importAttachment(_ result: Result<[URL], Error>) {
        guard let store = session.store else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                guard let url = try result.get().first else { return }
                var attachment = try await NoteFileImporter.attachment(url, replacing: replacing, store: store)
                let kind = attachment.kind
                if let index = node.attachments?.firstIndex(where: { $0.id == attachment.id }), let previous = node.attachments?[index] {
                    attachment.caption = previous.caption
                    node.attachments?[index] = attachment
                    if node.imageResourceID == previous.resourceID { node.imageResourceID = kind == .image ? attachment.resourceID : nil }
                } else {
                    if node.attachments == nil { node.attachments = [] }
                    node.attachments?.append(attachment)
                    if kind == .image, node.imageResourceID == nil { node.imageResourceID = attachment.resourceID }
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func preparePreview(_ attachment: MindMapAttachment) {
        guard let store = session.store else { return }
        busy = true
        Task {
            defer { busy = false }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notes-preview-\(UUID().uuidString)", isDirectory: true)
            do {
                try attachment.validate()
                let source = try await store.resourceURL(attachment.resourceID)
                let destination = folder.appendingPathComponent(attachment.fileName)
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: destination)
                }.value
                preview = Preview(url: destination)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                self.error = error.localizedDescription
            }
        }
    }
}
#endif
