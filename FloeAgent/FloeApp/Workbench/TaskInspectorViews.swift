#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import GRDB
import LocalAuthentication
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
    @EnvironmentObject private var conversationCenter: ConversationCenter
    @State private var policy: TaskPolicy?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isConfirmingFullAccess = false

    var body: some View {
        Form {
            if policy != nil {
                Section("审批模式") {
                    Picker("本任务", selection: approvalModeBinding) {
                        Text("询问").tag(TaskApprovalMode.ask.rawValue)
                        Text("自动审批").tag(TaskApprovalMode.automatic.rawValue)
                        Text("完全放开").tag(TaskApprovalMode.fullAccess.rawValue)
                    }
                    .pickerStyle(.segmented)
                    Text(modeExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("任务设置") {
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
                    Text("任务仍受工作区和工具范围限制；灾难性命令始终阻止。")
                }
            } else {
                ContentUnavailableView("请选择任务", systemImage: "lock.shield")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle("权限")
        .task(id: conversationID) { await load() }
        .alert("确认完全放开？", isPresented: $isConfirmingFullAccess) {
            Button("取消", role: .cancel) {}
            Button("继续并验证身份", role: .destructive) {
                Task { await authenticateFullAccess() }
            }
        } message: {
            Text("启用后，普通文件写入、远程命令和网页操作会在任务范围内自动执行；删除、凭据和上传仍会逐次询问，灾难性命令始终阻止。")
        }
    }

    private var approvalModeBinding: Binding<String> {
        Binding<String>(
            get: { policy?.resolvedApprovalMode.rawValue ?? TaskApprovalMode.ask.rawValue },
            set: { value in
                if value == TaskApprovalMode.fullAccess.rawValue {
                    isConfirmingFullAccess = true
                } else {
                    policy?.approvalMode = value
                }
            }
        )
    }

    private var modeExplanation: String {
        switch policy?.resolvedApprovalMode ?? .ask {
        case .ask: "读取自动运行，副作用操作会先询问。"
        case .automatic: "低风险自动批准；浏览器、远程执行和高风险操作仍会询问。"
        case .fullAccess: "普通操作自动执行；删除、凭据和上传仍询问，灾难性命令始终阻止。"
        }
    }

    private func authenticateFullAccess() async {
        let context = LAContext()
        do {
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
                errorMessage = "设备未设置可用的身份验证。"
                return
            }
            let allowed = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "确认本任务启用完全放开权限"
            )
            if allowed { policy?.approvalMode = TaskApprovalMode.fullAccess.rawValue }
        } catch {
            errorMessage = error.localizedDescription
        }
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
    }

    private func save() async {
        guard var policy else { return }
        isSaving = true
        defer { isSaving = false }
        policy.updatedAt = Date()
        do {
            try await conversationCenter.updateTaskPolicy(policy)
            self.policy = policy
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
#endif
