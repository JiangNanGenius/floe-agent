#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

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
                    Button("重新读取") { Task { await load() } }.disabled(busy || loading)
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
                            Button("查看", systemImage: "eye") { Task { await open(attachment, preview: true) } }
                            Button("存储到文件", systemImage: "square.and.arrow.up") { Task { await open(attachment, preview: false) } }
                        } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("\(attachment.name)，附件操作")
                    }
                }
                if loading { ProgressView("正在读取附件…") }
                if !loading, error == nil, attachments.isEmpty {
                    ContentUnavailableView("没有文件附件", systemImage: "paperclip",
                        description: Text("此处列出嵌入文档的文件附件。图表、图片等对象可在文档中操作。"))
                }
            }
            .disabled(busy)
            .overlay { if busy { ProgressView("正在读取附件…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .navigationTitle("文档附件")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(busy || loading) } }
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
