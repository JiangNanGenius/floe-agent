// FloeApp — Task-scoped file change evidence.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import Crypto
import FloeModels
import FloePersistence

@MainActor
private final class TaskChangesInspectorModel: ObservableObject {
    struct Change: Identifiable, Hashable {
        let id: UUID
        let path: String
        let action: String
        let summary: String
        let added: Int
        let removed: Int
        let createdAt: Date
        let artifact: ToolArtifactReference?
    }

    @Published private(set) var changes: [Change] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    private struct Payload: Decodable {
        var tool: String?
        var status: String?
        var summary: String?
        var artifactRefsJSON: String?

        var artifacts: [ToolArtifactReference] {
            guard let artifactRefsJSON,
                  let data = artifactRefsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([ToolArtifactReference].self, from: data)) ?? []
        }
    }

    func load(conversationID: UUID, runStore: any RunStore) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let runs = try await runStore.runs(conversationID: conversationID)
            var collected: [Change] = []
            for run in runs {
                let events = try await runStore.events(runID: run.id)
                for event in events where event.kind == .toolResult {
                    guard let data = event.payloadJSON.data(using: .utf8),
                          let payload = try? JSONDecoder().decode(Payload.self, from: data),
                          payload.status == nil || payload.status == "ok",
                          let summary = payload.summary,
                          let parsed = Self.parse(summary: summary, tool: payload.tool)
                    else { continue }
                    collected.append(Change(
                        id: event.id,
                        path: parsed.path,
                        action: parsed.action,
                        summary: summary,
                        added: parsed.added,
                        removed: parsed.removed,
                        createdAt: event.createdAt,
                        artifact: payload.artifacts.first(where: { $0.mimeType == "text/x-diff" })
                    ))
                }
            }
            changes = collected.sorted { $0.createdAt > $1.createdAt }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func verifiedDiff(for change: Change) throws -> String? {
        guard let artifact = change.artifact,
              artifact.relativePath.hasPrefix("ChangeArtifacts/"),
              !artifact.relativePath.split(separator: "/").contains(".."),
              artifact.byteCount > 0,
              artifact.byteCount <= 512 * 1024
        else { return nil }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let url = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(artifact.relativePath, isDirectory: false)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == artifact.byteCount else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256.lowercased() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func parse(summary: String, tool: String?) -> (path: String, action: String, added: Int, removed: Int)? {
        let candidates = [
            ("patched=", "修改", " hunks="),
            ("written=", "写入", " bytes="),
            ("created=", "新建", " bytes="),
            ("deleted=", "删除", " ")
        ]
        guard tool?.hasPrefix("workspace.") != false else { return nil }
        for (prefix, action, delimiter) in candidates where summary.hasPrefix(prefix) {
            let remainder = String(summary.dropFirst(prefix.count))
            let path = remainder.components(separatedBy: delimiter).first ?? remainder
            guard !path.isEmpty else { return nil }
            return (
                path,
                action,
                integer(after: "added=", in: summary),
                integer(after: "removed=", in: summary)
            )
        }
        return nil
    }

    private static func integer(after marker: String, in text: String) -> Int {
        guard let range = text.range(of: marker) else { return 0 }
        let tail = text[range.upperBound...]
        return Int(tail.prefix { $0.isNumber }) ?? 0
    }
}

struct TaskChangesInspectorView: View {
    let conversationID: UUID?
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = TaskChangesInspectorModel()
    @State private var selected: TaskChangesInspectorModel.Change?
    @State private var selectedDiff: String?

    var body: some View {
        Group {
            if let selected, let selectedDiff {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            self.selected = nil
                            self.selectedDiff = nil
                        } label: {
                            Label("返回", systemImage: "chevron.left")
                        }
                        Spacer()
                        Text(selected.path).lineLimit(1)
                    }
                    .padding(12)
                    Divider()
                    DiffView(diffText: selectedDiff)
                }
            } else {
                changeList
            }
        }
        .background(FloeTheme.readingSurface)
        .task(id: conversationID) {
            guard let conversationID else { return }
            await model.load(conversationID: conversationID, runStore: environment.runStore)
        }
    }

    private var changeList: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.changes.isEmpty {
                ContentUnavailableView(
                    "暂无文件变更",
                    systemImage: "plusminus",
                    description: Text("当前任务修改文件后，变更和可验证 diff 会显示在这里。")
                )
            } else {
                List(model.changes) { change in
                    Button { openDiff(change) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(change.path).font(.body.weight(.medium)).lineLimit(2)
                                Spacer()
                                Text(change.action).font(.caption).foregroundStyle(.secondary)
                            }
                            if change.added > 0 || change.removed > 0 {
                                Text("+\(change.added)  −\(change.removed)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(change.removed > 0 ? FloeTheme.destructive : FloeTheme.success)
                            }
                            Text(change.createdAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(change.artifact == nil)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("打开文件") { openFile(change.path) }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("变更").font(.headline)
                Text("\(model.changes.count) 个文件操作")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { router.hideInspector() } label: {
                Image(systemName: "xmark")
                    .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
            }
            .accessibilityLabel("关闭检查器")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func openDiff(_ change: TaskChangesInspectorModel.Change) {
        do {
            if let diff = try model.verifiedDiff(for: change) {
                selected = change
                selectedDiff = diff
            }
        } catch {
            model.error = error.localizedDescription
        }
    }

    private func openFile(_ path: String) {
        Task {
            var state = environment.workspaceCenter.currentWorkspace?.inspectorState ?? InspectorState()
            state.selectedRelativePath = path
            state.isExpanded = true
            await environment.workspaceCenter.updateInspectorState(state)
            router.showInspector(.workspaceFiles)
        }
    }
}
#endif
