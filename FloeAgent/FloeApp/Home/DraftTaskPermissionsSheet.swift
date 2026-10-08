#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import LocalAuthentication
import FloeModels

import FloeCore
/// The new-task policy editor. It mutates only the draft value; persistence
/// happens atomically with the first task/run launch.
struct DraftTaskPermissionsSheet: View {
    @Binding var policy: DraftTaskPolicy
    var isLocalModel = false
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("home.draft_task_permissions_sheet.approval_mode") {
                    Picker("home.draft_task_permissions_sheet.new_task", selection: modeBinding) {
                        Text("settings.agent_permissions_view.ask").tag(TaskApprovalMode.ask)
                        Text("settings.agent_permissions_view.auto_approve").tag(TaskApprovalMode.automatic)
                        Text("settings.agent_permissions_view.full_access")
                            .tag(TaskApprovalMode.fullAccess)
                            .disabled(isLocalModel)
                    }
                    .pickerStyle(.segmented)
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                Section {
                    Text("home.draft_task_permissions_sheet.deletion_payments_credentials_uploads_and_catastrophic")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("home.draft_task_permissions_sheet.task_permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("workspace.workspace_canvas_view.done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { normalizeLocalPolicy() }
        .onChange(of: isLocalModel) { _, _ in normalizeLocalPolicy() }
    }

    private var modeBinding: Binding<TaskApprovalMode> {
        Binding(
            get: { policy.approvalMode },
            set: { requested in
                guard !(isLocalModel && requested == .fullAccess) else { return }
                guard requested == .fullAccess else {
                    policy.approvalMode = requested
                    return
                }
                Task { await authenticateFullAccess() }
            }
        )
    }

    private var explanation: String {
        switch policy.approvalMode {
        case .ask: FloeL10n.l("home.draft_task_permissions_sheet.reads_run_automatically_side_effecting_actions")
        case .automatic: FloeL10n.l("home.draft_task_permissions_sheet.low_risk_actions_are_approved_automatically")
        case .fullAccess: FloeL10n.l("home.draft_task_permissions_sheet.ordinary_actions_run_automatically_mandatory_protections")
        }
    }

    private func authenticateFullAccess() async {
        guard !isLocalModel else { return }
        do {
            if try await DeviceOwnerAuthenticator.authenticate(
                reason: FloeL10n.l("home.draft_task_permissions_sheet.confirm_enabling_full_access_for_the")
            ) {
                policy.approvalMode = .fullAccess
                errorMessage = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func normalizeLocalPolicy() {
        if isLocalModel, policy.approvalMode == .fullAccess {
            policy.approvalMode = .automatic
        }
    }
}
#endif
