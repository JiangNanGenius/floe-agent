// SPDX-License-Identifier: MPL-2.0
// FloeMacUnified — Mac adapter for the shared task-activity inspectors.
//
// The rows, the change projection and the verified-artifact policy are the
// exact ones the iPad ships (`FloeAgent/FloeApp/Workbench/FloeTaskActivityRows.swift`);
// this adapter only feeds them a real task/run journal snapshot supplied by
// the coordinator and renders the digest-verified diff in a Mac sheet. It
// never reads the workspace, never synthesizes a diff and never touches the
// durable store itself — artifact bytes come in through the injected reader.

import SwiftUI
import FloeCore
import FloeModels
import FloePersistence

// MARK: - Data API

/// A real task/run journal snapshot: durable run headers plus their
/// append-only event threads, keyed by run ID (the common `RunEventRecord`
/// type from `FloeModels`).
struct MacTaskActivitySnapshot: Hashable, Sendable {
    var runs: [RunRecord]
    var events: [UUID: [RunEventRecord]]

    init(runs: [RunRecord] = [], events: [UUID: [RunEventRecord]] = [:]) {
        self.runs = runs
        self.events = events
    }
}

/// Coordinator-supplied resolver for recorded artifact bytes from the real
/// durable store. `nil` means "not retained"; a thrown error surfaces as the
/// inspector's error state. Arbitrary paths are never accepted: only the
/// reference the tool result recorded is passed, and only after it passed
/// `FloeVerifiedChangeArtifact.isDiffCandidate`.
typealias MacTaskActivityArtifactReader = (ToolArtifactReference) throws -> Data?

@MainActor
final class MacTaskActivityInspectorModel: ObservableObject {
    @Published private(set) var runs: [RunRecord] = []
    @Published private(set) var changes: [FloeTaskActivityChange] = []
    /// Diff text that already reproduced its recorded byte count + sha256.
    /// A change is absent here exactly when no verified artifact exists.
    @Published private(set) var verifiedDiffs: [UUID: String] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    /// Loads (or reloads) the inspector from a journal snapshot. Successful,
    /// task-owned mutations come from `FloeTaskActivityProjection`; when an
    /// `artifactReader` is supplied, each recorded diff receipt is verified
    /// and `onVerifiedReceipt` fires once per change whose bytes reproduce
    /// the recorded size + sha256 — the exact-receipt moment.
    func load(
        runs newRuns: [RunRecord],
        events: [UUID: [RunEventRecord]],
        artifactReader: MacTaskActivityArtifactReader? = nil,
        onVerifiedReceipt: ((FloeTaskActivityChange, String) -> Void)? = nil
    ) {
        isLoading = true
        defer { isLoading = false }
        runs = newRuns
        changes = FloeTaskActivityProjection.changes(runs: newRuns, events: events)
        error = nil
        var verified: [UUID: String] = [:]
        if let artifactReader {
            for change in changes {
                guard let artifact = change.artifact,
                      FloeVerifiedChangeArtifact.isDiffCandidate(artifact) else { continue }
                do {
                    guard let data = try artifactReader(artifact) else { continue }
                    guard let text = FloeVerifiedChangeArtifact.verifiedDiffText(
                        data: data, artifact: artifact) else { continue }
                    verified[change.id] = text
                    onVerifiedReceipt?(change, text)
                } catch {
                    // Keep the rest of the journal usable; report once.
                    if self.error == nil { self.error = error.localizedDescription }
                }
            }
        }
        verifiedDiffs = verified
    }
}

// MARK: - View

private enum MacTaskActivityText {
    static let progress = ChatBilingualCatalog.localized(
        key: "chat.thread_detail_view.progress",
        en: "Progress", zh: "进度")
    static let changes = ChatBilingualCatalog.localized(
        key: "chat.thread_detail_view.changes",
        en: "Changes", zh: "变更")
    static let noRunProgress = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.no_run_progress_yet",
        en: "No run progress yet", zh: "暂无运行进度")
    static let noFileChanges = ChatBilingualCatalog.localized(
        key: "workbench.task_changes_inspector_view.no_file_changes",
        en: "No file changes", zh: "暂无文件变更")
    static let diffUnavailable = ChatBilingualCatalog.localized(
        key: "workbench.task_changes_inspector_view.diff_unavailable",
        en: "The verified diff for this change is not available.",
        zh: "此变更的已验证差异不可用。")
}

private struct MacTaskActivityDiffSheet: Identifiable {
    let change: FloeTaskActivityChange
    let text: String
    var id: UUID { change.id }
}

/// Renders the shared run-progress and file-change rows for one journal
/// snapshot, with the same loading / empty / error states as the iPad
/// inspector. A diff opens only from `verifiedDiffs` — bytes that already
/// matched their recorded receipt — never from a synthesized or re-read
/// source.
struct MacTaskActivityInspectorView: View {
    enum Content: Equatable { case progress, changes }

    let snapshot: MacTaskActivitySnapshot
    let content: Content
    var artifactReader: MacTaskActivityArtifactReader?
    var onVerifiedReceipt: ((FloeTaskActivityChange, String) -> Void)? = nil

    @StateObject private var model = MacTaskActivityInspectorModel()
    @State private var presentedDiff: MacTaskActivityDiffSheet?
    @State private var unavailableChangeID: UUID?

    var body: some View {
        List {
            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.destructive)
                        .accessibilityIdentifier("mac.taskActivity.error")
                }
            }
            if content == .progress {
                Section(MacTaskActivityText.progress) {
                    if model.runs.isEmpty && !model.isLoading {
                        Text(MacTaskActivityText.noRunProgress)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.runs) { run in
                        FloeRunProgressRow(run: run)
                    }
                }
            } else {
                Section(MacTaskActivityText.changes) {
                    if model.changes.isEmpty && !model.isLoading {
                        Text(MacTaskActivityText.noFileChanges)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.changes) { change in
                        FloeTaskActivityChangeRow(
                            change: change,
                            isEnabled: model.verifiedDiffs[change.id] != nil
                        ) { openDiff(change) }
                        if unavailableChangeID == change.id {
                            Text(MacTaskActivityText.diffUnavailable)
                                .font(.caption)
                                .foregroundStyle(FloeTheme.pending)
                        }
                    }
                }
            }
        }
        .overlay {
            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(FloeTheme.readingSurface.opacity(0.6))
            }
        }
        .sheet(item: $presentedDiff) { sheet in
            MacTaskActivityDiffView(change: sheet.change, diffText: sheet.text)
        }
        .task(id: snapshot) {
            model.load(
                runs: snapshot.runs,
                events: snapshot.events,
                artifactReader: artifactReader,
                onVerifiedReceipt: onVerifiedReceipt)
        }
        .accessibilityIdentifier("mac.taskActivity.inspector")
    }

    private func openDiff(_ change: FloeTaskActivityChange) {
        guard let text = model.verifiedDiffs[change.id] else {
            unavailableChangeID = change.id
            return
        }
        unavailableChangeID = nil
        presentedDiff = MacTaskActivityDiffSheet(change: change, text: text)
    }
}

struct MacLiveShellOutput: View {
    let output: MacShellOutputUpdate
    let stop: () -> Void

    private var approval: String {
        switch output.approval {
        case .humanCard: MacPermissionsText.t("人工批准", "Approved by You")
        case .policy("full-access"): MacPermissionsText.t("完全访问", "Full Access")
        case .policy("approval-model"): MacPermissionsText.t("审批模型", "Approval Model")
        case .policy: MacPermissionsText.t("任务策略", "Task Policy")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(MacPermissionsText.t("命令输出", "Command Output"), systemImage: "terminal")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(MacPermissionsText.t("停止任务", "Stop Task"), action: stop)
            }
            let scope = output.scope == .host ? MacPermissionsText.t("本机", "This Mac") : MacPermissionsText.t("工作区", "Workspace")
            Text([output.risk.title, scope, approval].joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: output.text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 128)
            if output.truncated {
                Text(MacPermissionsText.t("预览已截断", "Preview Truncated")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .accessibilityIdentifier("workspace.command.output")
    }
}

// MARK: - Verified diff presentation
//
// Plain, read-only rendering of the verified unified diff. No patch
// application, no file access — coloring is presentation only.

private struct MacTaskActivityDiffView: View {
    let change: FloeTaskActivityChange
    let diffText: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(change.path).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(MacTaskActivityText.closeInspector)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(diffText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated()), id: \.offset) { _, line in
                        Text(String(line))
                            .font(FloeTheme.Typography.evidence)
                            .foregroundStyle(color(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
        }
        .frame(minWidth: 520, idealWidth: 680, minHeight: 320, idealHeight: 420)
        .background(FloeTheme.readingSurface)
    }

    private func color(for line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("+") { return FloeTheme.success }
        if line.hasPrefix("-") { return FloeTheme.destructive }
        if line.hasPrefix("@@") { return FloeTheme.pending }
        return .primary
    }
}

private extension MacTaskActivityText {
    static let closeInspector = ChatBilingualCatalog.localized(
        key: "inspector.close",
        en: "Close inspector", zh: "关闭检查器")
}
