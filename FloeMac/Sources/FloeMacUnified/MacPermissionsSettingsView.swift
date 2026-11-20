// SPDX-License-Identifier: MPL-2.0

import FloeModels
import SwiftUI

/// Mac permissions settings, aligned with the iPad `AgentPermissionsView`:
/// the default approval mode for new tasks, the auto-approval reviewer
/// model, an honest full-access explanation, the preserved workspace write
/// ceiling, and the saved approval grants owned by
/// `MacSavedApprovalGrantsView`.
///
/// State lives on `HostAgentWorkspace`: `setApprovalMode(_:asDefault:)`
/// authenticates this Mac's user before enabling full access and reports
/// progress through `savingApprovalMode`; this view never re-implements
/// authentication or grant storage, and it weakens no approval ceiling.
/// New copy follows the `MacProviderText` inline bilingual convention so
/// English and Simplified Chinese stay aligned without new catalog keys.
struct MacPermissionsSettingsView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    @State private var confirmsFullAccess = false

    /// Reviewer candidates use the same eligibility rule as the workspace
    /// validator: enabled provider, enabled model, and an approval-capable
    /// model surface.
    private var reviewers: [HostAgentProvider] {
        workspace.providers.filter {
            $0.profile.isEnabled && $0.model.isEnabled && $0.model.supportsApprovalSurface
        }
    }

    var body: some View {
        ScrollView {
            Form {
                Section {
                    Picker(selection: defaultModeBinding) {
                        ForEach(TaskApprovalMode.allCases, id: \.self) { mode in
                            Text(mode.macPermissionsTitle).tag(mode)
                        }
                    } label: {
                        Text(MacPermissionsText.t("新任务默认审批模式", "Default Approval Mode"))
                    }
                    .pickerStyle(.segmented)
                    .disabled(workspace.savingApprovalMode)
                } footer: {
                    Text(MacPermissionsText.t(
                        "只影响之后创建的任务。已有任务可在输入栏更改。",
                        "Applies to new tasks. Change an existing task in its composer."))
                }

                Section {
                    Picker(selection: reviewerBinding) {
                        Text(MacPermissionsText.t("未配置（遇到中风险操作时询问）", "Not Configured (asks on medium-risk actions)"))
                            .tag(UUID?.none)
                        ForEach(reviewers, id: \.model.id) { provider in
                            Text(verbatim: provider.model.displayName)
                                .tag(UUID?.some(provider.model.id))
                        }
                    } label: {
                        Text(MacPermissionsText.t("审批模型", "Approval Model"))
                    }
                    .disabled(workspace.savingApprovalMode)
                    Text(MacPermissionsText.t(
                        "审批模型只判断允许、拒绝或询问。需要人工确认时，任务中会显示审批卡。",
                        "The reviewer can allow, deny or ask for confirmation. When you need to decide, a card appears in the task."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Label {
                        Text(MacPermissionsText.t(
                            "完全访问允许任务自动执行项目中已启用的操作。高危操作仍受安全规则限制。",
                            "Full Access lets the task run enabled project actions automatically. Safety rules still apply to high-risk actions."))
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    Text(MacPermissionsText.t("完全访问", "Full Access"))
                }

                Section {
                    Toggle("mac.settings.workspaceWrites", isOn: $workspace.allowsWorkspaceWrites)
                } footer: {
                    Text("mac.settings.workspaceWrites.detail")
                }

                Section {
                    MacSavedApprovalGrantsView(workspace: workspace)
                } header: {
                    Text(MacPermissionsText.t("已保存的授权", "Saved Approvals"))
                } footer: {
                    Text(MacPermissionsText.t(
                        "授权只适用于选定文件和操作。撤销后，下次操作按任务的审批模式处理。",
                        "Each permission applies to the selected file and operation. After revocation, the next action follows the task’s approval mode."))
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 12)
            if let message = workspace.approvalSettingsError {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .confirmMacFullAccess(isPresented: $confirmsFullAccess, asDefault: true) {
            Task { await workspace.setApprovalMode(.fullAccess, asDefault: true) }
        }
    }

    private var defaultModeBinding: Binding<TaskApprovalMode> {
        Binding(
            get: { workspace.defaultApprovalMode },
            set: { mode in
                // The workspace authenticates the device owner before enabling
                // full access. A false result also covers a dismissed
                // authentication, which stays silent by design; genuine save
                // failures surface through the workspace notice.
                if mode == .fullAccess && workspace.defaultApprovalMode != .fullAccess { confirmsFullAccess = true }
                else { Task { await workspace.setApprovalMode(mode, asDefault: true) } }
            }
        )
    }

    private var reviewerBinding: Binding<UUID?> {
        Binding(
            get: { workspace.approvalModelID },
            set: { id in workspace.setApprovalModelID(id) }
        )
    }
}

/// EN / zh-CN inline strings for the permissions surfaces, following the
/// `MacProviderText` convention: the Mac host mirrors the system language
/// without adding catalog keys.
enum MacPermissionsText {
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true
    }

    static func t(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }
}

extension TaskApprovalMode {
    /// Shared titles for the settings picker and the composer permission chip.
    var macPermissionsTitle: String {
        switch self {
        case .ask: MacPermissionsText.t("询问", "Ask")
        case .automatic: MacPermissionsText.t("自动审批", "Auto Approve")
        case .fullAccess: MacPermissionsText.t("完全访问", "Full Access")
        }
    }
}

extension View {
    func confirmMacFullAccess(isPresented: Binding<Bool>, asDefault: Bool, confirm: @escaping () -> Void) -> some View {
        alert(asDefault ? Text("mac.permissions.confirmDefault") : Text("mac.permissions.confirmTask"), isPresented: isPresented) {
            Button("host.chat.cancel", role: .cancel) {}
            Button("mac.permissions.verifyOwner", role: .destructive, action: confirm)
        } message: { Text("mac.permissions.confirmDetail") }
    }
}
