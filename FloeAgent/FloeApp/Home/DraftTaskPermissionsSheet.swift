#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import LocalAuthentication
import FloeModels

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
                Section("审批模式") {
                    Picker("新任务", selection: modeBinding) {
                        Text("询问").tag(TaskApprovalMode.ask)
                        Text("自动审批").tag(TaskApprovalMode.automatic)
                        Text("完全访问")
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
                    Text("删除、付款、凭据、上传和灾难性命令仍受强制保护。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("任务权限")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
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
        case .ask: "读取自动运行，副作用操作会先询问。"
        case .automatic: "低风险自动批准，敏感操作仍会询问。"
        case .fullAccess: "普通操作自动执行，强制保护仍然有效。"
        }
    }

    private func authenticateFullAccess() async {
        guard !isLocalModel else { return }
        do {
            if try await DeviceOwnerAuthenticator.authenticate(
                reason: "确认新任务启用完全访问权限"
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
