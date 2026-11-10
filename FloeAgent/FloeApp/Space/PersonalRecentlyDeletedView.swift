// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

enum PersonalLibraryDeleteSelection {
    case work(PersonalContentRecord), folder(PersonalLibraryFolder)
    var item: PersonalLibrarySelectionItem {
        switch self { case .work(let value): .work(value); case .folder(let value): .folder(value) }
    }
    func message(usingTrash: Bool) -> String {
        guard usingTrash else {
            return IDELanguageRunText.t("“\(item.title)”及其中所有内容都将被永久删除。此操作无法撤销。",
                "“\(item.title)” and all its contents will be permanently deleted. This cannot be undone.")
        }
        switch self {
        case .work(let value): return IDELanguageRunText.t("“\(value.title)”可以在回收站中恢复。", "You can restore “\(value.title)” from Trash.")
        case .folder(let value): return IDELanguageRunText.t("“\(value.name)”及其中的文件可以在回收站中恢复。", "You can restore “\(value.name)” and its contents from Trash.")
        }
    }
}

struct PersonalRecentlyDeletedView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [PersonalLibraryTrashEntry] = []
    @State private var pending: Set<UUID> = []
    @State private var selected: Set<UUID> = []
    @State private var selecting = false
    @State private var busy = false
    @State private var notice: String?
    @State private var confirmation: [PersonalPermanentDeletePlan] = []
    @State private var confirming = false
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    HStack(spacing: 12) {
                        if selecting {
                            Button {
                                if !selected.insert(entry.id).inserted { selected.remove(entry.id) }
                            } label: { Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle").frame(minWidth: 44, minHeight: 44) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(entry.title)
                            .accessibilityIdentifier("space.files.trash.select." + entry.id.uuidString)
                        }
                        Image(systemName: entry.kind == .folder ? "folder" : entry.contentKind?.systemImage ?? "doc")
                            .foregroundStyle(.tint).frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).lineLimit(2)
                            Text(entry.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(entry.deletedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            if pending.contains(entry.id) { Text(IDELanguageRunText.t("清理未完成，可重试删除", "Cleanup incomplete. Retry deletion.")).font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if !selecting {
                            VStack {
                                Button(IDELanguageRunText.t("恢复", "Restore")) { task = Task { await restore(entry) } }
                                    .disabled(busy || pending.contains(entry.id)).frame(minHeight: 44)
                                    .accessibilityIdentifier("space.files.restore." + entry.id.uuidString)
                                Button(IDELanguageRunText.t("永久删除", "Delete Permanently"), role: .destructive) { prepare([entry]) }
                                    .disabled(busy).frame(minHeight: 44)
                                    .accessibilityIdentifier("space.files.permanentDelete." + entry.id.uuidString)
                            }.buttonStyle(.borderless)
                        }
                    }.padding(.vertical, 4).disabled(busy)
                }
            }
            .accessibilityIdentifier("space.files.trash.list")
            .overlay {
                if entries.isEmpty { ContentUnavailableView(IDELanguageRunText.t("回收站为空", "Trash is empty"), systemImage: "trash") }
                else if busy { ProgressView() }
            }
            .navigationTitle(IDELanguageRunText.t("回收站", "Trash"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? IDELanguageRunText.t("取消选择", "Cancel Selection") : IDELanguageRunText.t("选择", "Select")) {
                        selecting.toggle(); selected.removeAll()
                    }.disabled(busy || entries.isEmpty)
                    .accessibilityIdentifier("space.files.trash.selectionMode")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(IDELanguageRunText.t("完成", "Done")) { dismiss() }.disabled(busy)
                        .accessibilityIdentifier("space.files.recentlyDeleted.done")
                }
                if selecting {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(allSelected ? IDELanguageRunText.t("取消全选", "Deselect All") : IDELanguageRunText.t("全选", "Select All")) {
                            selected = allSelected ? [] : Set(entries.map(\.id))
                        }.disabled(busy || entries.isEmpty)
                            .accessibilityIdentifier("space.files.trash.selectAll")
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(IDELanguageRunText.t("恢复", "Restore")) {
                            let frozen = entries.filter { selected.contains($0.id) }
                            task = Task { await restoreSelected(frozen) }
                        }.disabled(busy || selected.isEmpty)
                            .accessibilityIdentifier("space.files.trash.restoreSelected")
                        Spacer()
                        Text(IDELanguageRunText.t("已选 \(selected.count) 项", "\(selected.count) selected"))
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("space.files.trash.selectionCount")
                        Spacer()
                        Button(IDELanguageRunText.t("永久删除", "Delete Permanently"), role: .destructive) {
                            prepare(entries.filter { selected.contains($0.id) })
                        }.disabled(busy || selected.isEmpty).accessibilityIdentifier("space.files.trash.deleteSelected")
                    }
                }
            }
            .interactiveDismissDisabled(busy)
            .task { await refresh() }
            .refreshable { if !busy { await refresh() } }
            .confirmationDialog(IDELanguageRunText.t("永久删除所选内容？", "Permanently delete the selected content?"),
                isPresented: $confirming, titleVisibility: .visible) {
                    Button(IDELanguageRunText.t("永久删除", "Delete Permanently"), role: .destructive) {
                        let frozen = confirmation; confirmation = []
                        task = Task { await permanentlyDelete(frozen) }
                    }
                    Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { confirmation = [] }
                } message: {
                    Text(confirmation.count == 1
                        ? IDELanguageRunText.t("“\(confirmation.first?.entry.title ?? "")”及其中所有内容都将被永久删除。此操作无法撤销。", "“\(confirmation.first?.entry.title ?? "")” and all its contents will be permanently deleted. This cannot be undone.")
                        : IDELanguageRunText.t("所选 \(confirmation.count) 项及其中所有内容都将被永久删除。此操作无法撤销。", "The selected \(confirmation.count) items and all their contents will be permanently deleted. This cannot be undone."))
                }
            .alert(IDELanguageRunText.t("未能完成", "Unable to finish"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button(IDELanguageRunText.t("好", "OK"), role: .cancel) { notice = nil }
            } message: { Text(notice ?? "") }
            .onDisappear { generation = UUID(); task?.cancel(); confirmation = []; confirming = false }
        }
    }
    private var allSelected: Bool { !entries.isEmpty && selected == Set(entries.map(\.id)) }
    @MainActor private func refresh() async {
        do {
            let library = try await PersonalContentService.shared.library()
            entries = try await library.recentlyDeleted(); pending = try await library.permanentDeletionPendingIDs()
            selected.formIntersection(Set(entries.map(\.id)))
        } catch { notice = error.localizedDescription }
    }
    @MainActor private func prepare(_ frozen: [PersonalLibraryTrashEntry]) {
        guard !busy, !frozen.isEmpty else { return }; busy = true
        let expected = generation
        task = Task {
            defer { busy = false }
            do {
                let plans = try await PersonalLibraryFileActions.permanentDeletionPlans(frozen, environment: environment)
                guard !Task.isCancelled, generation == expected else { return }; confirmation = plans; confirming = true
            } catch { if !Task.isCancelled, generation == expected { notice = error.localizedDescription } }
        }
    }
    @MainActor private func permanentlyDelete(_ frozen: [PersonalPermanentDeletePlan]) async {
        guard !busy, !frozen.isEmpty else { return }; busy = true; defer { busy = false }
        let expected = generation
        let result = await PersonalLibraryFileActions.permanentlyDeleteBatch(frozen, environment: environment)
        guard generation == expected else { return }
        if !result.failed.isEmpty {
            notice = IDELanguageRunText.t("已清理 \(result.deleted.count) 项，\(result.failed.count) 项未能完成。", "Removed \(result.deleted.count); \(result.failed.count) could not be completed.")
                + "\n" + result.failed.prefix(3).map(\.message).joined(separator: "\n")
        }
        let failedIDs = Set(result.failed.map(\.entryID))
        selected = Set(frozen.filter { failedIDs.contains($0.id) }.flatMap { $0.coveredEntries.map(\.id) + [$0.id] })
        selecting = !selected.isEmpty
        await refresh()
    }
    @MainActor private func restoreSelected(_ frozen: [PersonalLibraryTrashEntry]) async {
        guard !busy, !frozen.isEmpty else { return }; busy = true; defer { busy = false }
        let expected = generation
        let result = await PersonalLibraryFileActions.restoreBatch(frozen, environment: environment)
        guard generation == expected else { return }
        selected = Set(result.failed.map { $0.entry.id }); selecting = !selected.isEmpty
        if !result.failed.isEmpty {
            notice = IDELanguageRunText.t("已恢复 \(result.restored.count) 项，\(result.failed.count) 项未能完成。",
                "Restored \(result.restored.count); \(result.failed.count) could not be completed.")
                + "\n" + result.failed.prefix(3).map { $0.message }.joined(separator: "\n")
        }
        await refresh()
    }
    @MainActor private func restore(_ entry: PersonalLibraryTrashEntry) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try await PersonalLibraryFileActions.restore(entry, environment: environment)
            NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: entry.projectID ?? entry.id)
            await refresh()
        } catch { notice = error.localizedDescription }
    }
}
#endif
