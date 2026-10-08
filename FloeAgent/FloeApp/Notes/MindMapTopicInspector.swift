// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeNotes

import FloeCore
/// A draft owns its revision. Concurrent Agent edits produce a conflict instead of being overwritten.
struct MindMapTopicInspector: View {
    let session: NotesSession
    let document: NoteDocument
    @State var node: MindMapNode
    var onOpenSource: ((NoteSourceReference) async -> Bool)? = nil
    @State private var pendingSource: NoteSourceReference?
    @State private var savedRevision: Int?
    @State private var openedRevision: Int
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

    init(session: NotesSession, document: NoteDocument, node: MindMapNode,
         onOpenSource: ((NoteSourceReference) async -> Bool)? = nil) {
        self.session = session; self.document = document
        self._node = State(initialValue: node)
        self._openedRevision = State(initialValue: document.revision)
        self.onOpenSource = onOpenSource
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("notes.notes_document_editor.topic") {
                    TextField("shortcuts.floe_shortcuts.title", text: $node.title)
                    TextField("notes.mind_map_topic_inspector.details", text: $node.note, axis: .vertical).lineLimit(4...12)
                    TextField("notes.mind_map_topic_inspector.web_link_https", text: Binding(get: { node.hyperLink ?? "" }, set: { node.hyperLink = $0.isEmpty ? nil : $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    if let source = node.source {
                        Button("notes.mind_map_topic_inspector.open_source", systemImage: "arrow.up.forward.app") {
                            requestSource(source)
                        }
                    }
                }
                Section {
                    ForEach(node.attachments ?? []) { attachment in
                        attachmentRow(attachment)
                    }
                    Button("notes.mind_map_topic_inspector.add_images_documents_audio_or_video", systemImage: "paperclip") {
                        replacing = nil; importing = true
                    }.disabled((node.attachments ?? []).count >= 32 || busy)
                } header: { Text(FloeL10n.l("notes.mind_map_topic_inspector.attachment_32", (node.attachments ?? []).count)) }
                footer: { Text("notes.mind_map_topic_inspector.attachments_are_saved_with_the_mind") }
            }
            .disabled(busy)
            .navigationTitle("notes.mind_map_topic_inspector.topic_content")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("workspace.workspace_canvas_view.cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("workspace.workspace_canvas_view.save") { save() }.disabled(busy || node.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay { if busy { ProgressView("envdetail.working").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
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
            .alert("notes.mind_map_topic_inspector.topic_content", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("workspace.office_document_editor_view.ok") { error = nil }
            } message: { Text(error ?? "") }
        }.presentationDetents([.large])
            .confirmationDialog("notes.mind_map_topic_inspector.save_topic_changes_before_leaving", isPresented: Binding(get: { pendingSource != nil }, set: { if !$0 { pendingSource = nil } }), titleVisibility: .visible) {
                if let source = pendingSource {
                    Button("notes.mind_map_topic_inspector.save_and_open_source") { navigate(source, saveChanges: true) }
                    Button("notes.mind_map_topic_inspector.discard_changes_and_open_source", role: .destructive) { navigate(source, saveChanges: false) }
                }
                Button("workspace.workspace_canvas_view.cancel", role: .cancel) { pendingSource = nil }
            }.interactiveDismissDisabled(busy)
    }

    private func attachmentRow(_ attachment: MindMapAttachment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { preparePreview(attachment) } label: {
                Label(attachment.fileName, systemImage: icon(attachment.kind)).lineLimit(2)
            }
            TextField("notes.mind_map_topic_inspector.attachment_description", text: Binding(get: {
                node.attachments?.first(where: { $0.id == attachment.id })?.caption ?? ""
            }, set: { text in
                if let index = node.attachments?.firstIndex(where: { $0.id == attachment.id }) { node.attachments?[index].caption = text }
            }), axis: .vertical)
            HStack {
                if attachment.kind == .image {
                    Button("notes.mind_map_topic_inspector.set_as_topic_image") { node.imageResourceID = attachment.resourceID }
                }
                Button("workspace.text_file_editor_view.replace") { replacing = attachment.id; importing = true }
                if let source = attachment.source {
                    Button("skills.review.source") { requestSource(source) }
                }
                Spacer()
                Button("localmodels.remove", role: .destructive) {
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
                    let saved = try await session.commit([.upsertNode(node)], documentID: document.id, expectedRevision: savedRevision ?? openedRevision)
                    savedRevision = saved.revision; savedNode = node
                }
                let opened: Bool
                if let onOpenSource { opened = await onOpenSource(source) }
                else { opened = await session.openSource(source) }
                if opened { dismiss() }
                else { error = session.errorMessage ?? FloeL10n.l("notes.mind_map_topic_inspector.could_not_open_the_source_check") }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await session.commit([.upsertNode(node)], documentID: document.id, expectedRevision: savedRevision ?? openedRevision)
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
