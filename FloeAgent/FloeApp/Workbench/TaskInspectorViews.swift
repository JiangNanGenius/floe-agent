#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import GRDB
import FloeModels
import FloePersistence

struct TaskProgressInspectorView: View {
    let conversationID: UUID?
    @EnvironmentObject private var environment: AppEnvironment
    @State private var runs: [RunRecord] = []

    var body: some View {
        List(runs) { run in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(RunStateLocalizer.title(for: run.state))
                    Spacer()
                    Text(run.startedAt, style: .time).foregroundStyle(.secondary)
                }
                ProgressView(value: RunStateLocalizer.isTerminal(run.state) ? 1 : 0.45)
                Text(run.goal).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if runs.isEmpty {
                ContentUnavailableView("暂无运行进度", systemImage: "chart.bar")
            }
        }
        .navigationTitle("进度")
        .task(id: conversationID) {
            guard let conversationID else { runs = []; return }
            runs = (try? await environment.runStore.runs(conversationID: conversationID)) ?? []
        }
    }
}

struct ChildAgentsInspectorView: View {
    private struct ChildRunRow: Identifiable {
        let run: RunRecord
        let parentID: UUID
        let budget: Int
        var id: UUID { run.id }
    }

    let conversationID: UUID?
    @EnvironmentObject private var environment: AppEnvironment
    @State private var children: [ChildRunRow] = []

    var body: some View {
        List(children) { child in
            VStack(alignment: .leading, spacing: 5) {
                Label(RunStateLocalizer.title(for: child.run.state), systemImage: "person.2")
                Text(child.run.goal).lineLimit(2)
                Text("预算 \(child.budget) · 父运行 \(child.parentID.uuidString.prefix(8))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay {
            if children.isEmpty {
                ContentUnavailableView("暂无子 Agent", systemImage: "person.2.slash")
            }
        }
        .navigationTitle("子 Agent")
        .task(id: conversationID) { await load() }
    }

    private func load() async {
        guard let conversationID else { children = []; return }
        children = (try? await environment.database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT r.*, rr.parent_run_id, rr.budget_tokens
                FROM run_relations rr JOIN runs r ON r.id = rr.child_run_id
                WHERE r.conversation_id = ? ORDER BY rr.created_at DESC
                """, arguments: [conversationID.uuidString]).compactMap { row in
                    guard let runID = UUID(uuidString: row["id"]),
                          let parentID = UUID(uuidString: row["parent_run_id"]),
                          let startedAt = Self.decodeDate(row["started_at"]) else { return nil }
                    return ChildRunRow(
                        run: RunRecord(
                            id: runID,
                            conversationID: conversationID,
                            state: row["state"],
                            goal: row["goal"],
                            startedAt: startedAt,
                            endedAt: (row["ended_at"] as String?).flatMap(Self.decodeDate)
                        ),
                        parentID: parentID,
                        budget: row["budget_tokens"] as Int? ?? 0
                    )
                }
            }) ?? []
    }

    nonisolated private static func decodeDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

struct TaskPermissionsInspectorView: View {
    let conversationID: UUID?
    @EnvironmentObject private var environment: AppEnvironment
    @State private var policy: TaskPolicy?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var fileScopeText = ""

    var body: some View {
        Form {
            if policy != nil {
                Section("审批模式") {
                    Picker("本任务", selection: approvalModeBinding) {
                        Text("继承全局设置").tag("inherit")
                        Text("每次副作用均询问").tag("askEveryTime")
                        Text("只读工具").tag("readOnly")
                    }
                }
                Section("任务权限") {
                    optionalToggle("网络访问", keyPath: \.networkAllowed)
                    optionalToggle("浏览器控制", keyPath: \.browserControlAllowed)
                    optionalToggle("文件上传", keyPath: \.uploadAllowed)
                    optionalToggle("使用凭据", keyPath: \.credentialsAllowed)
                    optionalToggle("远程执行", keyPath: \.remoteExecutionAllowed)
                }
                Section {
                    TextField("相对路径，逗号分隔；留空允许整个任务工作区", text: $fileScopeText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("文件范围")
                } footer: {
                    Text("路径始终相对于本任务唯一绑定的工作区；不能访问其他任务或项目。")
                }
                Section("恢复与通知") {
                    Picker("后台恢复", selection: binding(\.recoveryPolicy, fallback: .safePoint)) {
                        Text("安全点自动恢复").tag(TaskRecoveryPolicy.safePoint)
                        Text("总是自动重试").tag(TaskRecoveryPolicy.alwaysRetry)
                    }
                    Picker("通知", selection: binding(\.notificationPolicy, fallback: .stages)) {
                        Text("关闭").tag(TaskNotificationPolicy.off)
                        Text("仅完成/失败").tag(TaskNotificationPolicy.terminal)
                        Text("审批与异常").tag(TaskNotificationPolicy.critical)
                        Text("阶段进度").tag(TaskNotificationPolicy.stages)
                    }
                }
                Section {
                    Button("保存任务权限") { Task { await save() } }
                        .disabled(isSaving)
                } footer: {
                    Text("删除、付款、登录、凭据、上传和灾难性命令仍会逐次确认。任务权限不能突破全局与工作区上限。")
                }
            } else {
                ContentUnavailableView("请选择任务", systemImage: "lock.shield")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle("权限")
        .task(id: conversationID) { await load() }
    }

    private func optionalToggle(
        _ title: String,
        keyPath: WritableKeyPath<TaskPolicy, Bool?>
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { policy?[keyPath: keyPath] ?? false },
            set: { value in policy?[keyPath: keyPath] = value }
        ))
    }

    private var approvalModeBinding: Binding<String> {
        Binding<String>(
            get: { policy?.approvalMode ?? "inherit" },
            set: { value in
                if value == "inherit" { policy?.approvalMode = nil }
                else { policy?.approvalMode = value }
            }
        )
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<TaskPolicy, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { policy?[keyPath: keyPath] ?? fallback },
            set: { value in policy?[keyPath: keyPath] = value }
        )
    }

    private func load() async {
        guard let conversationID else { policy = nil; return }
        let store = SQLiteWorkspaceStore(database: environment.database)
        policy = (try? await store.taskPolicy(conversationID: conversationID))
            ?? TaskPolicy(conversationID: conversationID)
        fileScopeText = policy?.filePaths.joined(separator: ", ") ?? ""
    }

    private func save() async {
        guard var policy else { return }
        isSaving = true
        defer { isSaving = false }
        policy.updatedAt = Date()
        policy.filePaths = fileScopeText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            try await SQLiteWorkspaceStore(database: environment.database).saveTaskPolicy(policy)
            self.policy = policy
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
#endif
