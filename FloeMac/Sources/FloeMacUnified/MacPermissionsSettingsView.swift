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
    @ObservedObject var bridge: BridgeAppModel
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
                    LabeledContent(MacPermissionsText.t("低风险", "Low risk"),
                                   value: MacPermissionsText.t("查看工作区文件列表等，可直接执行", "Workspace reads such as listing files run directly"))
                    LabeledContent(MacPermissionsText.t("中风险", "Medium risk"),
                                   value: MacPermissionsText.t("生成文件或构建项目，按任务审批设置处理", "File creation and builds follow the task’s approval setting"))
                    LabeledContent(MacPermissionsText.t("高风险", "High risk"),
                                   value: MacPermissionsText.t("删除或复杂命令，请你确认", "Deletion and complex commands ask for confirmation"))
                } header: {
                    Text(MacPermissionsText.t("普通任务的命令审批", "Command Approval for Standard Tasks"))
                } footer: {
                    Text(MacPermissionsText.t("访问工作区外的文件也需要你确认。", "Access to files outside the workspace also asks for confirmation."))
                }

                Section {
                    Label {
                        Text(MacPermissionsText.t(
                            "完全访问允许命令访问当前 Mac 账户可用的文件，包括工作区外的文件。macOS 隐私权限仍然生效。",
                            "Full Access lets commands access files available to your Mac account, including files outside the workspace. macOS privacy permissions still apply."))
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    Text(MacPermissionsText.t("完全访问", "Full Access"))
                }

                Section {
                    Toggle(MacPermissionsText.t("允许 Agent 执行操作", "Allow Agent Actions"), isOn: $workspace.allowsWorkspaceWrites)
                } footer: {
                    Text(MacPermissionsText.t("关闭后，新运行只能读取工作区文件。命令、文件修改和窗口操作均会停用。", "Turn off to make future runs read-only. Commands, file edits and window control will be unavailable."))
                }

                Section {
                    MacKimiCompanionRow()
                } header: {
                    Text(MacPermissionsText.t("后台操作其他应用", "Background App Control"))
                } footer: {
                    Text(MacPermissionsText.t("在 Kimi CU 中配置辅助功能和屏幕录制权限。", "Configure Accessibility and Screen Recording in Kimi CU."))
                }

                Section {
                    MacSystemPermissionRows(model: bridge)
                } header: {
                    Text(MacPermissionsText.t("Mac 系统权限", "Mac System Permissions"))
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
        } message: { Text(MacPermissionsText.t("命令可直接访问工作区外的本机文件。仅为可信任务启用。", "Commands can access files outside the workspace without asking. Enable this for trusted tasks.")) }
    }
}
