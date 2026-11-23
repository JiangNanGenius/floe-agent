// SPDX-License-Identifier: MPL-2.0

import AppKit
import FloeModels
import SwiftUI

struct MacTaskPermissionsSheet: View {
    @ObservedObject var workspace: HostAgentWorkspace
    let selectionID: UUID
    let isDraft: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsFullAccess = false
    @State private var fullAccessChoice: TaskApprovalMode? = .fullAccess

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(MacPermissionsText.t("任务权限", "Task Permissions")).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("task.permissions.done")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: FloeTheme.minimumTarget + 4)
            Divider()
            Form {
                if isDraft {
                    FloeTaskApprovalSection(mode: selection, allowsFullAccess: true, explanation: explanation, isDraft: true)
                        .disabled(disablesEdit)
                } else if workspace.selectedTaskPolicy != nil {
                    FloeSavedTaskPolicyFields(approval: savedApproval, recovery: recovery, notifications: notifications,
                                              allowsFullAccess: true, explanation: explanation)
                        .disabled(disablesEdit)
                    if let center = workspace.taskNotifications { MacNotificationAuthorizationRow(center: center) }
                }
                if workspace.savingApprovalMode { ProgressView() }
            }
            .formStyle(.grouped)
        }
        .frame(width: 490, height: isDraft ? 230 : 390)
        .onExitCommand { dismiss() }
        .accessibilityIdentifier("task.permissions.sheet")
        .confirmMacFullAccess(isPresented: $confirmsFullAccess, asDefault: false) {
            if isDraft { apply(.fullAccess) }
            else { applySaved(.approval(fullAccessChoice)) }
        }
    }

    private var disablesEdit: Bool { workspace.savingApprovalMode || workspace.isStopping || workspace.isResolvingApproval }

    private var savedApproval: Binding<TaskApprovalMode?> {
        Binding(get: {
            guard let policy = workspace.selectedTaskPolicy, policy.approvalMode != nil else { return nil }
            return policy.resolvedApprovalMode
        }, set: { mode in
            if (mode ?? workspace.defaultApprovalMode) == .fullAccess {
                fullAccessChoice = mode
                confirmsFullAccess = true
            } else {
                applySaved(.approval(mode))
            }
        })
    }

    private var recovery: Binding<TaskRecoveryPolicy> {
        Binding(get: { workspace.selectedTaskPolicy?.recoveryPolicy ?? .safePoint }, set: { applySaved(.recovery($0)) })
    }

    private var notifications: Binding<TaskNotificationPolicy> {
        Binding(get: { workspace.selectedTaskPolicy?.notificationPolicy ?? .stages }, set: { applySaved(.notifications($0)) })
    }

    private func applySaved(_ setting: TaskPolicySetting) {
        Task {
            guard selectionID == workspace.draftSelectionID else { return }
            await workspace.editSelectedTaskPolicy(setting)
        }
    }

    private var selection: Binding<TaskApprovalMode> {
        Binding(get: { workspace.taskApprovalMode }, set: { mode in
            guard mode != workspace.taskApprovalMode else { return }
            if mode == .fullAccess {
                confirmsFullAccess = true
            } else {
                apply(mode)
            }
        })
    }

    private func apply(_ mode: TaskApprovalMode) {
        Task {
            guard selectionID == workspace.draftSelectionID else { return }
            await workspace.setApprovalMode(mode, asDefault: false)
        }
    }

    private var explanation: String {
        switch workspace.taskApprovalMode {
        case .ask: MacPermissionsText.t("读取直接运行，执行操作前询问。", "Reads run directly. Actions ask for approval.")
        case .automatic: MacPermissionsText.t("常规工作区操作可自动批准，其他操作会请求确认。", "Routine workspace actions can be approved automatically. Other actions ask for confirmation.")
        case .fullAccess: MacPermissionsText.t("可以使用当前 Mac 账户有权访问的文件。", "The task can use files available to the current Mac account.")
        }
    }
}

struct MacNotificationAuthorizationRow: View {
    @ObservedObject var center: MacTaskNotifications

    var body: some View {
        Group {
            if center.authorization == .notDetermined {
                Button(MacPermissionsText.t("允许系统通知", "Allow System Notifications")) {
                    Task { await center.requestAuthorization() }
                }
            } else if center.authorization == .denied {
                Text(MacPermissionsText.t("可在 macOS 的「系统设置 → 通知」开启。", "Enable notifications in macOS System Settings."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await center.updateAuthorization() }
    }
}

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
    @State private var showsCommandLevels = false
    @State private var systemSettingsUnavailable = false
    #if FLOE_MAC_HOST_SMOKE
    static var smokeActionsFrame: CGRect?
    #endif

    /// Reviewer candidates use the same eligibility rule as the workspace
    /// validator: enabled provider, enabled model, and an approval-capable
    /// model surface.
    private var reviewers: [HostAgentProvider] {
        workspace.providers.filter {
            $0.profile.isEnabled && $0.model.isEnabled && $0.model.supportsApprovalSurface
        }
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: defaultModeBinding) {
                    ForEach(TaskApprovalMode.allCases, id: \.self) { mode in
                        Text(mode.macPermissionsTitle)
                            .accessibilityIdentifier("settings.permissions.mode." + mode.rawValue)
                            .tag(mode)
                    }
                } label: {
                    Text(MacPermissionsText.t("新任务默认审批模式", "Default Approval Mode"))
                }
                .pickerStyle(.segmented)
                .disabled(workspace.savingApprovalMode)
            } footer: {
                Text(MacPermissionsText.t(
                    "适用于新任务。已有任务可在输入栏更改审批模式，子代理跟随所属任务。",
                    "Applies to new tasks. Change an existing task in its composer. Its subagents follow the same approval mode."))
            }

            Section {
                Toggle(MacPermissionsText.t("允许 Agent 执行操作", "Allow Agent Actions"), isOn: $workspace.allowsWorkspaceWrites)
                    .accessibilityIdentifier("settings.permissions.allowActions")
                    #if FLOE_MAC_HOST_SMOKE
                    .background(MacWorkbenchButtonFrameReader { Self.smokeActionsFrame = $0 })
                    #endif
            } footer: {
                Text(MacPermissionsText.t("关闭后，新的运行和子代理保留只读工具。命令、文件修改和窗口操作均会停用。", "Turn off to limit new runs and their subagents to read-only tools. Commands, file edits and window control will be unavailable."))
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
                DisclosureGroup(isExpanded: $showsCommandLevels) {
                    LabeledContent(MacPermissionsText.t("低风险", "Low risk"),
                                   value: MacPermissionsText.t("工作区内的简单读取可直接执行", "Simple workspace reads run directly"))
                    LabeledContent(MacPermissionsText.t("中风险", "Medium risk"),
                                   value: MacPermissionsText.t("生成文件或构建项目按任务审批设置处理", "File creation and builds follow the task’s approval setting"))
                    LabeledContent(MacPermissionsText.t("高风险", "High risk"),
                                   value: MacPermissionsText.t("删除和复杂命令需要确认", "Deletion and complex commands require confirmation"))
                } label: {
                    Text(MacPermissionsText.t("普通任务如何审批命令", "How standard tasks approve commands"))
                }
            } footer: {
                Text(MacPermissionsText.t("普通任务越出工作区需要确认。完全访问可直接使用当前账户已获准的本机文件。", "Standard tasks ask before accessing files outside the workspace. Full Access can use files available to your Mac account directly."))
            }

            Section {
                Picker(MacPermissionsText.t("后台操作后端", "Background Control Backend"), selection: $workspace.computerUseBackend) {
                    Text("Kimi CU")
                        .accessibilityIdentifier("settings.computerUse.kimi")
                        .tag(MacComputerUseBackend.kimi)
                    Text(MacPermissionsText.t("Floe 本机", "Floe Native"))
                        .accessibilityIdentifier("settings.computerUse.floe")
                        .tag(MacComputerUseBackend.floe)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.permissions.computerUseBackend")
                if workspace.computerUseBackend == .kimi {
                    MacKimiCompanionRow()
                }
            } header: {
                Text("Computer Use")
            } footer: {
                switch workspace.computerUseBackend {
                case .kimi:
                    Text(MacPermissionsText.t("下次运行将使用 Kimi CU。请在 Kimi CU 中配置本地 Agent 连接、辅助功能和屏幕录制。",
                                              "Kimi CU will be used on the next run. Configure local agent access, Accessibility and Screen Recording in Kimi CU."))
                case .floe:
                    Text(MacPermissionsText.t("下次运行将使用 Floe 本机。请在下方为 Floe Agent 允许辅助功能。截取窗口还需屏幕录制权限。",
                                              "Floe Native will be used on the next run. Allow Accessibility for Floe Agent below. Window captures also require Screen Recording."))
                }
            }

            Section {
                MacSystemPermissionRows(model: bridge)
                LabeledContent(MacPermissionsText.t("完全磁盘访问权限", "Full Disk Access")) {
                    Button(MacPermissionsText.t("打开系统设置…", "Open System Settings…")) {
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                        systemSettingsUnavailable = !NSWorkspace.shared.open(url)
                    }
                    .accessibilityIdentifier("settings.permissions.fullDisk")
                }
                if systemSettingsUnavailable {
                    Text(MacPermissionsText.t("请打开系统设置 → 隐私与安全性 → 完全磁盘访问权限。", "Go to System Settings → Privacy & Security → Full Disk Access."))
                }
            } header: {
                Text(MacPermissionsText.t("Floe Agent 的系统权限", "System Permissions for Floe Agent"))
            } footer: {
                Text(MacPermissionsText.t("如需处理受 macOS 保护的文件，请在系统设置中为 Floe Agent 授权。", "To work with files protected by macOS, grant Floe Agent access in System Settings."))
            }

            Section {
                let ready = MacAgentWorkspaceTools.approvalGateAvailable
                Label(ready ? MacPermissionsText.t("高风险保护已启用", "High-Risk Protection Active")
                    : MacPermissionsText.t("保护规则无法加载", "Protection Rules Unavailable"),
                    systemImage: ready ? "shield.checkered" : "shield.slash")
                    .foregroundStyle(ready ? FloeTheme.success : FloeTheme.destructive)
            } footer: {
                Text(MacPermissionsText.t("此保护对所有审批模式生效。", "This protection applies to all approval modes."))
            }

            Section {
                MacSavedApprovalGrantsView(workspace: workspace)
            } header: {
                Text(MacPermissionsText.t("已保存的授权", "Saved Approvals"))
            } footer: {
                Text(MacPermissionsText.t(
                    "授权只适用于选定的文件、工具或会话范围。撤销后，下次操作按任务的审批模式处理；会话授权在退出应用后自动失效。",
                    "Each permission applies to the selected file, tool or session scope. After revocation, the next action follows the task’s approval mode; session approvals expire when the app quits."))
            }
            if let message = workspace.approvalSettingsError {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
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
                .accessibilityIdentifier("settings.permissions.confirmOwner")
        } message: { Text(MacPermissionsText.t("命令可直接访问工作区外的本机文件。仅为可信任务启用。", "Commands can access files outside the workspace without asking. Enable this for trusted tasks.")) }
    }
}
