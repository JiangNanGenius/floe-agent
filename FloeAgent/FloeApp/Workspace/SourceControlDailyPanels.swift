// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeGit

struct SourceControlConflictEditor: View {
    @ObservedObject var center: SourceControlCenter
    let expected: GitConflictSnapshot
    let pinnedRoot: URL
    let onResolved: (GitMergeOutcome) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pane = Pane.result
    @State private var result: String
    @State private var deleteFile = false
    @State private var error: String?
    private enum Pane: String, CaseIterable, Identifiable {
        case result, current, incoming, ancestor
        var id: Self { self }
        var title: String {
            switch self {
            case .result: IDELanguageRunText.t("合并结果", "Result")
            case .current: IDELanguageRunText.t("当前", "Current")
            case .incoming: IDELanguageRunText.t("传入", "Incoming")
            case .ancestor: IDELanguageRunText.t("共同版本", "Base")
            }
        }
    }
    init(center: SourceControlCenter, expected: GitConflictSnapshot, pinnedRoot: URL, onResolved: @escaping (GitMergeOutcome) -> Void) {
        self.center = center; self.expected = expected; self.pinnedRoot = pinnedRoot
        self.onResolved = onResolved; _result = State(initialValue: expected.result)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(IDELanguageRunText.t("版本", "Version"), selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Menu {
                    Button(IDELanguageRunText.t("采用当前版本", "Use Current")) { choose(expected.ours) }
                    Button(IDELanguageRunText.t("采用传入版本", "Use Incoming")) { choose(expected.theirs) }
                    Button(IDELanguageRunText.t("保留为文件", "Keep as File")) { deleteFile = false; pane = .result }
                    Button(IDELanguageRunText.t("删除此文件", "Delete File"), role: .destructive) { deleteFile = true; pane = .result }
                } label: { Label(IDELanguageRunText.t("采用", "Use"), systemImage: "arrow.down.doc").labelStyle(.iconOnly).frame(width: 44, height: 44) }
            }.padding(.horizontal).padding(.vertical, 6)
            Divider()
            if pane == .result && !deleteFile {
                TextEditor(text: $result).font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("sourceControl.conflict.editor")
            } else if pane == .result {
                ContentUnavailableView(IDELanguageRunText.t("将删除此文件", "This File Will Be Deleted"), systemImage: "trash")
            } else if let text = selectedText {
                ScrollView([.horizontal, .vertical]) { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding() }
            } else {
                ContentUnavailableView(IDELanguageRunText.t("此版本没有该文件", "No File in This Version"), systemImage: "doc.badge.minus")
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, alignment: .leading) }
        }
        .navigationTitle(expected.path).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(IDELanguageRunText.t("取消", "Cancel")) { dismiss() }.disabled(center.isBusy) }
            ToolbarItem(placement: .confirmationAction) {
                Button(IDELanguageRunText.t("标记已解决", "Mark Resolved")) {
                    let content: String? = deleteFile ? nil : result
                    Task { @MainActor in
                        await center.perform(pinnedRoot: pinnedRoot) {
                            do {
                                let outcome = try await center.resolveConflict(expected: expected, content: content)
                                onResolved(outcome); dismiss()
                            } catch { self.error = SecretRedactor.redact(error.localizedDescription) }
                        }
                    }
                }.disabled(center.isBusy).accessibilityIdentifier("sourceControl.conflict.resolve")
            }
        }
        .interactiveDismissDisabled(center.isBusy)
    }
    private var selectedText: String? {
        switch pane { case .result: result; case .current: expected.ours; case .incoming: expected.theirs; case .ancestor: expected.base }
    }
    private func choose(_ text: String?) { if let text { result = text; deleteFile = false } else { deleteFile = true }; pane = .result }
}

struct SourceControlRecoveryView: View {
    @ObservedObject var center: SourceControlCenter
    let pinnedRoot: URL
    @Environment(\.dismiss) private var dismiss
    @State private var records: [GitRecoveryRecord] = []
    @State private var loaded = false
    @State private var notice: String?
    @State private var pending: Restore?
    private struct Restore: Identifiable { let id = UUID(); let record: String; let path: String; let layer: GitRecoveryLayer }
    var body: some View {
        List {
            if !loaded { ProgressView() }
            else if records.isEmpty {
                ContentUnavailableView(IDELanguageRunText.t("暂无恢复副本", "No Recovery Copies"), systemImage: "clock.arrow.circlepath",
                    description: Text(IDELanguageRunText.t("放弃修改或中止合并时，会先保留可恢复内容。", "Discarding changes or aborting a merge first keeps recoverable content.")))
            }
            ForEach(records) { record in
                Section {
                    ForEach(record.entries) { entry in
                        DisclosureGroup {
                            Button(IDELanguageRunText.t("恢复工作文件", "Restore Working File")) { pending = .init(record: record.id, path: entry.path, layer: .worktree) }
                            Button(IDELanguageRunText.t("恢复暂存内容", "Restore Staged Content")) { pending = .init(record: record.id, path: entry.path, layer: .index) }
                        } label: { Label(entry.path, systemImage: "doc.text").lineLimit(2) }.disabled(!record.completed || center.isBusy)
                    }
                    if !record.completed { Label(IDELanguageRunText.t("此次操作未完成，已保留原件供检查。", "This operation did not finish. The original data was retained for inspection."), systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    HStack { Text(record.kind == "abortMerge" ? IDELanguageRunText.t("中止合并", "Abort Merge") : IDELanguageRunText.t("放弃修改", "Discard Changes")); Spacer(); Text(record.createdAt, style: .date) }
                }
            }
            if let notice { Section { Text(notice).foregroundStyle(.secondary) } }
        }
        .navigationTitle(IDELanguageRunText.t("恢复修改", "Recover Changes"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(IDELanguageRunText.t("完成", "Done")) { dismiss() } } }
        .task { await load() }
        .confirmationDialog(IDELanguageRunText.t("恢复这份内容？", "Restore This Content?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let pending {
                Button(IDELanguageRunText.t("恢复", "Restore")) {
                    self.pending = nil
                    Task { @MainActor in
                        await center.perform(pinnedRoot: pinnedRoot) {
                            try await center.restoreRecovery(id: pending.record, path: pending.path, layer: pending.layer)
                            notice = IDELanguageRunText.t("已恢复所选内容。", "The selected content was restored.")
                            await load()
                        }
                    }
                }
            }
        } message: { Text(IDELanguageRunText.t("若文件已有新的修改，将保留新内容并停止恢复。", "If the file has newer edits, they are kept and restoration stops.")) }
    }
    private func load() async {
        do {
            guard center.rootMatchesPinned(pinnedRoot) else { throw CancellationError() }
            let values = try await center.recoveries()
            guard center.rootMatchesPinned(pinnedRoot) else { return }
            records = values; loaded = true
        } catch { notice = SecretRedactor.redact(error.localizedDescription); loaded = true }
    }
}
struct SourceControlCommitView: View {
    let details: GitCommitDetails
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(details.message).font(.headline).textSelection(.enabled)
                HStack { Text(details.author); Spacer(); Text(details.date, style: .date) }.font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(IDELanguageRunText.t("提交信息", "Commit Information")) {
                    Text(details.oid).font(.caption.monospaced()).textSelection(.enabled)
                    ForEach(details.parentOIDs, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                }.font(.caption).foregroundStyle(.secondary)
            }.padding()
            Divider()
            if details.diff.isEmpty { ContentUnavailableView(IDELanguageRunText.t("没有文件差异", "No File Differences"), systemImage: "doc.text.magnifyingglass") }
            else { DiffView(diffText: details.diff) }
            if details.diffTruncated { Text(IDELanguageRunText.t("差异较长，此处仅显示前一部分。", "This is a long diff. Only the beginning is shown here.")).font(.footnote).foregroundStyle(.secondary).padding() }
        }
        .navigationTitle(String(details.oid.prefix(8))).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(IDELanguageRunText.t("完成", "Done")) { dismiss() } } }
    }
}
#endif
