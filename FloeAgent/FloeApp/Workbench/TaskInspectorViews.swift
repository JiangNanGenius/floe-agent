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
                ContentUnavailableView("workbench.task_inspector_views.no_run_progress_yet", systemImage: "chart.bar")
            }
        }
        .navigationTitle("chat.thread_detail_view.progress")
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
                Text(FloeL10n.l("workbench.task_inspector_views.budget_parent_run", child.budget, String(String(child.parentID.uuidString.prefix(8)))))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay {
            if children.isEmpty {
                ContentUnavailableView("workbench.task_inspector_views.no_sub_agents", systemImage: "person.2.slash")
            }
        }
        .navigationTitle("chat.thread_detail_view.subagents")
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
    @State private var policy: TaskPolicy?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var didSave = false
    @State private var resolvedIsLocalModel = false

    var body: some View {
        Form {
            if policy != nil {
                Section("home.draft_task_permissions_sheet.approval_mode") {
                    Picker("workbench.task_inspector_views.this_task", selection: approvalModeBinding) {
                        Text("settings.agent_permissions_view.ask").tag(TaskApprovalMode.ask.rawValue)
                        Text("settings.agent_permissions_view.auto_approve").tag(TaskApprovalMode.automatic.rawValue)
                        Text("settings.agent_permissions_view.full_access")
                            .tag(TaskApprovalMode.fullAccess.rawValue)
                            .disabled(resolvedIsLocalModel)
                    }
                    .pickerStyle(.segmented)
                    Text(modeExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("workbench.task_inspector_views.task_settings") {
                    Picker("workbench.task_inspector_views.background_recovery", selection: binding(\.recoveryPolicy, fallback: .safePoint)) {
                        Text("workbench.task_inspector_views.auto_resume_from_safety_point").tag(TaskRecoveryPolicy.safePoint)
                        Text("workbench.task_inspector_views.always_retry_automatically").tag(TaskRecoveryPolicy.alwaysRetry)
                    }
                    Picker("workbench.task_inspector_views.notifications", selection: binding(\.notificationPolicy, fallback: .stages)) {
                        Text("media.media_editor_view.close").tag(TaskNotificationPolicy.off)
                        Text("workbench.task_inspector_views.completion_failure_only").tag(TaskNotificationPolicy.terminal)
                        Text("workbench.task_inspector_views.approvals_and_exceptions").tag(TaskNotificationPolicy.critical)
                        Text("workbench.task_inspector_views.stage_progress").tag(TaskNotificationPolicy.stages)
                    }
                }
                Section {
                    if isSaving {
                        Label("workspace.office_document_editor_view.saving", systemImage: "arrow.triangle.2.circlepath")
                    } else if didSave {
                        Label("workbench.task_inspector_views.saved_and_applied_to_the_current", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("workbench.task_inspector_views.changes_save_automatically_and_apply_to")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("workbench.task_inspector_views.the_task_remains_limited_by_workspace")
                }
            } else {
                ContentUnavailableView("workbench.task_inspector_views.choose_a_task", systemImage: "lock.shield")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle("workspace.file_inspector_view.permissions")
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
        case .ask: FloeL10n.l("home.draft_task_permissions_sheet.reads_run_automatically_side_effecting_actions")
        case .automatic: FloeL10n.l("workbench.task_inspector_views.routine_in_scope_steps_toward_the")
        case .fullAccess: FloeL10n.l("workbench.task_inspector_views.tools_for_this_task_run_automatically")
        }
    }

    private func authenticateFullAccess() async {
        guard !resolvedIsLocalModel else { return }
        do {
            let allowed = try await DeviceOwnerAuthenticator.authenticate(
                reason: FloeL10n.l("workbench.task_inspector_views.confirm_enabling_full_access_for_this")
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
            resolvedIsLocalModel = environment.conversationCenter
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
            try await environment.conversationCenter.updateTaskPolicy(policy)
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
