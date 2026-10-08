#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

import FloeCore
struct OfficeAttachmentItem: Identifiable, Sendable {
    let id: String
    let name: String
    let byteCount: UInt64
}

struct OfficeAttachmentListView: View {
    @ObservedObject var session: OfficeFileSession
    @Environment(\.dismiss) private var dismiss
    @State private var attachments: [OfficeAttachmentItem] = []
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?
    @State private var presentation: Presentation?

    private struct Presentation: Identifiable {
        let id = UUID()
        let url: URL
        let preview: Bool
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("action.reload") { Task { await load() } }.disabled(busy || loading)
                }
                ForEach(attachments) { attachment in
                    HStack {
                        Image(systemName: "doc").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(attachment.name)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: attachment.byteCount), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("chat.thread_detail_view_model.view", systemImage: "eye") { Task { await open(attachment, preview: true) } }
                            Button("workspace.office_attachment_list_view.save_to_files", systemImage: "square.and.arrow.up") { Task { await open(attachment, preview: false) } }
                        } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel(FloeL10n.l("workspace.office_attachment_list_view.attachment_action", attachment.name))
                    }
                }
                if loading { ProgressView("workspace.office_attachment_list_view.reading_attachment") }
                if !loading, error == nil, attachments.isEmpty {
                    ContentUnavailableView("workspace.office_attachment_list_view.no_file_attachments", systemImage: "paperclip",
                        description: Text("workspace.office_attachment_list_view.file_attachments_embedded_in_the_document"))
                }
            }
            .disabled(busy)
            .overlay { if busy { ProgressView("workspace.office_attachment_list_view.reading_attachment").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .navigationTitle("workspace.office_attachment_list_view.document_attachments")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("workspace.workspace_canvas_view.done") { dismiss() }.disabled(busy || loading) } }
            .task { await load() }
            .sheet(item: $presentation) { item in
                if item.preview { QuickLookView(url: item.url).ignoresSafeArea() }
                else { OfficeCopyDestinationPicker(url: item.url) { _ in presentation = nil } }
            }
        }
        .interactiveDismissDisabled(busy || loading)
    }

    private func load() async {
        guard !busy else { return }
        loading = true
        defer { loading = false }
        do { attachments = try await session.listAttachments(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func open(_ attachment: OfficeAttachmentItem, preview: Bool) async {
        guard !busy, !loading else { return }
        busy = true
        defer { busy = false }
        do {
            let url = try await session.exportAttachment(id: attachment.id)
            presentation = Presentation(url: url, preview: preview)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
#endif
