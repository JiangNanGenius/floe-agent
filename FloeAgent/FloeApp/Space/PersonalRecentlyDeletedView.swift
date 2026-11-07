// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

enum PersonalLibraryDeleteSelection {
    case work(PersonalContentRecord), folder(PersonalLibraryFolder)
    var message: String {
        switch self {
        case .work(let value):
            IDELanguageRunText.t("“\(value.title)”可以在“最近删除”中恢复。", "You can restore “\(value.title)” from Recently Deleted.")
        case .folder(let value):
            IDELanguageRunText.t("“\(value.name)”及其中的文件可以在“最近删除”中恢复。", "You can restore “\(value.name)” and its contents from Recently Deleted.")
        }
    }
}

struct PersonalRecentlyDeletedView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [PersonalLibraryTrashEntry] = []
    @State private var restoring: UUID?
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: entry.kind == .folder ? "folder" : entry.contentKind?.systemImage ?? "doc")
                            .foregroundStyle(.tint).frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).lineLimit(2)
                            Text(entry.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(entry.deletedAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button(IDELanguageRunText.t("恢复", "Restore")) { Task { await restore(entry) } }
                            .disabled(restoring != nil).buttonStyle(.bordered)
                            .accessibilityIdentifier("space.files.restore." + entry.id.uuidString)
                    }.padding(.vertical, 4)
                }
            }
            .accessibilityIdentifier("space.files.trash.list")
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(IDELanguageRunText.t("没有最近删除的文件", "No recently deleted files"),
                        systemImage: "trash")
                }
            }
            .navigationTitle(IDELanguageRunText.t("最近删除", "Recently Deleted"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(IDELanguageRunText.t("完成", "Done")) { dismiss() }
                    .accessibilityIdentifier("space.files.recentlyDeleted.done")
            } }
            .task { await refresh() }
            .refreshable { await refresh() }
            .alert(IDELanguageRunText.t("未能完成", "Unable to finish"), isPresented: Binding(
                get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                    Button(IDELanguageRunText.t("好", "OK"), role: .cancel) { notice = nil }
                } message: { Text(notice ?? "") }
        }
    }
    @MainActor private func refresh() async {
        do { entries = try await PersonalContentService.shared.library().recentlyDeleted() }
        catch { notice = error.localizedDescription }
    }
    @MainActor private func restore(_ entry: PersonalLibraryTrashEntry) async {
        guard restoring == nil else { return }; restoring = entry.id; defer { restoring = nil }
        do {
            try await PersonalContentService.shared.library().restore(entry.id)
            NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: entry.projectID ?? entry.id)
            await refresh()
        } catch { notice = error.localizedDescription }
    }
}
#endif
