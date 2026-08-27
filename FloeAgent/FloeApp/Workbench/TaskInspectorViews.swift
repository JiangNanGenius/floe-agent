#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import GRDB
import LocalAuthentication
import FloeCore
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
    var isLocalModel: Bool? = nil
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var conversationCenter: ConversationCenter
    @State private var policy: TaskPolicy?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var didSave = false
    @State private var resolvedIsLocalModel = false

    var body: some View {
        Form {
            if policy != nil {
                Section("审批模式") {
                    Picker("本任务", selection: approvalModeBinding) {
                        Text("询问").tag(TaskApprovalMode.ask.rawValue)
                        Text("自动审批").tag(TaskApprovalMode.automatic.rawValue)
                        Text("完全访问")
                            .tag(TaskApprovalMode.fullAccess.rawValue)
                            .disabled(resolvedIsLocalModel)
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
                    if isSaving {
                        Label("正在保存…", systemImage: "arrow.triangle.2.circlepath")
                    } else if didSave {
                        Label("已保存并应用到当前任务", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("修改会自动保存，并立即应用到当前运行的下一次工具调用。")
                            .foregroundStyle(.secondary)
                    }
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
    }

    private var approvalModeBinding: Binding<String> {
        Binding<String>(
            get: { policy?.resolvedApprovalMode.rawValue ?? TaskApprovalMode.ask.rawValue },
            set: { value in
                if value == TaskApprovalMode.fullAccess.rawValue {
                    guard !resolvedIsLocalModel else { return }
                    Task { await authenticateFullAccess() }
                } else {
                    policy?.approvalMode = value
                    Task { await save() }
                }
            }
        )
    }

    private var modeExplanation: String {
        switch policy?.resolvedApprovalMode ?? .ask {
        case .ask: "读取自动运行，副作用操作会先询问。"
        case .automatic: "以完成当前任务为目标自动放行范围内的常规步骤；审批模型只在目标不明确、权限明显扩大或存在高风险后果时介入。"
        case .fullAccess: "本任务工具自动执行；灾难性命令始终阻止，软件包安装仍需模型审查。"
        }
    }

    private func authenticateFullAccess() async {
        guard !resolvedIsLocalModel else { return }
        do {
            let allowed = try await DeviceOwnerAuthenticator.authenticate(
                reason: "确认本任务启用完全访问权限"
            )
            if allowed {
                policy?.approvalMode = TaskApprovalMode.fullAccess.rawValue
                await save()
            }
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
            set: { value in
                policy?[keyPath: keyPath] = value
                Task { await save() }
            }
        )
    }

    private func load() async {
        guard let conversationID else { policy = nil; return }
        let store = SQLiteWorkspaceStore(database: environment.database)
        policy = (try? await store.taskPolicy(conversationID: conversationID))
            ?? TaskPolicy(conversationID: conversationID)
        if let isLocalModel {
            resolvedIsLocalModel = isLocalModel
        } else if let modelID = (try? await environment.runStore
            .runs(conversationID: conversationID))?.first?.modelID {
            resolvedIsLocalModel = conversationCenter
                .providerAndModel(modelID: modelID)?.0.kind == .local
        } else {
            resolvedIsLocalModel = false
        }
        if resolvedIsLocalModel,
           policy?.resolvedApprovalMode == .fullAccess {
            policy?.approvalMode = TaskApprovalMode.automatic.rawValue
        }
    }

    private func save() async {
        guard var policy else { return }
        isSaving = true
        defer { isSaving = false }
        policy.updatedAt = Date()
        // Defensive: a save that fails (e.g. the conversation row vanished
        // mid-edit, or the DB is momentarily locked) surfaces as an inline
        // error instead of crashing the inspector.
        do {
            try await conversationCenter.updateTaskPolicy(policy)
            self.policy = policy
            errorMessage = nil
            didSave = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                didSave = false
            }
        } catch {
            errorMessage = error.localizedDescription
            FloeLogger(category: .app).error("taskPolicySaveFailed conversation=\(policy.conversationID.uuidString) error=\(error.localizedDescription)")
        }
    }
}
#endif
