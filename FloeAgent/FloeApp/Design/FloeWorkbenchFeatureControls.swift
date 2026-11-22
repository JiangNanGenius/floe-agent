// SPDX-License-Identifier: MPL-2.0

import FloeCore
import FloeModels
import SwiftUI

struct FloeTaskApprovalSection: View {
    @Binding var mode: TaskApprovalMode
    let allowsFullAccess: Bool
    let explanation: String
    var isDraft = false

    var body: some View {
        Section(FloeL10n.isChinese ? "审批模式" : "Approval Mode") {
            if isDraft {
                modePicker(FloeL10n.isChinese ? "新任务" : "New Task").pickerStyle(.segmented)
            } else {
                modePicker(FloeL10n.isChinese ? "此任务" : "This Task").pickerStyle(.menu)
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func modePicker(_ title: String) -> some View {
        Picker(title, selection: $mode) {
            ForEach(TaskApprovalMode.allCases, id: \.self) { choice in
                Text(Self.title(choice)).tag(choice)
                    .disabled(choice == .fullAccess && !allowsFullAccess)
            }
        }
        .accessibilityIdentifier("task.permissions.approval")
    }

    static func title(_ mode: TaskApprovalMode) -> String {
        switch mode {
        case .ask: FloeL10n.isChinese ? "询问" : "Ask"
        case .automatic: FloeL10n.isChinese ? "自动审批" : "Auto Approve"
        case .fullAccess: FloeL10n.isChinese ? "完全访问" : "Full Access"
        }
    }
}

/// The existing-task fields used by the permissions sheet and inspector.
/// Hosts supply bindings so the runtime remains the owner of each write.
struct FloeSavedTaskPolicyFields: View {
    @Binding var approval: TaskApprovalMode?
    @Binding var recovery: TaskRecoveryPolicy
    @Binding var notifications: TaskNotificationPolicy
    let allowsFullAccess: Bool
    let explanation: String
    var offersInheritance = true

    var body: some View {
        Section(t("审批模式", "Approval Mode")) {
            Picker(t("此任务", "This Task"), selection: $approval) {
                if offersInheritance { Text(t("跟随全局默认", "Follow App Default")).tag(TaskApprovalMode?.none) }
                ForEach(TaskApprovalMode.allCases, id: \.self) { mode in
                    Text(FloeTaskApprovalSection.title(mode)).tag(Optional(mode))
                        .disabled(mode == .fullAccess && !allowsFullAccess)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("task.permissions.approval")
            Text(explanation).font(.caption).foregroundStyle(.secondary)
        }
        Section(t("任务设置", "Task Settings")) {
            Picker(t("后台恢复", "Background Recovery"), selection: $recovery) {
                Text(t("从安全点恢复", "Resume from a Safe Point")).tag(TaskRecoveryPolicy.safePoint)
                Text(t("自动尝试续跑", "Automatically Retry")).tag(TaskRecoveryPolicy.alwaysRetry)
            }
            .accessibilityIdentifier("task.permissions.recovery")
            Picker(t("通知", "Notifications"), selection: $notifications) {
                Text(t("关闭", "Off")).tag(TaskNotificationPolicy.off)
                Text(t("完成与失败", "Completion and Failure")).tag(TaskNotificationPolicy.terminal)
                Text(t("审批与异常", "Approvals and Exceptions")).tag(TaskNotificationPolicy.critical)
                Text(t("任务进度", "Task Progress")).tag(TaskNotificationPolicy.stages)
            }
            .accessibilityIdentifier("task.permissions.notifications")
        }
    }

    private func t(_ zh: String, _ en: String) -> String { FloeL10n.isChinese ? zh : en }
}

/// Form fields from the iPad schedule sheet. The platform owns scheduling
/// authorization, host availability and the save transaction.
struct FloeTaskScheduleTextFields: View {
    @Binding var title: String
    @Binding var prompt: String

    var body: some View {
        Section(FloeL10n.isChinese ? "任务" : "Task") {
            TextField(FloeL10n.isChinese ? "名称" : "Name", text: $title)
                .accessibilityIdentifier("home.schedule.title")
            TextEditor(text: $prompt)
                .frame(minHeight: 120)
                .accessibilityIdentifier("home.schedule.prompt")
        }
    }
}

struct FloeTaskScheduleTimingFields: View {
    @Binding var cadence: TaskScheduleCadence
    @Binding var scheduledAt: Date
    @Binding var intervalHours: Int
    var allowsAfterSuccess = false

    var body: some View {
        Picker(t("重复", "Repeat"), selection: $cadence) {
            Text(t("单次", "Once")).tag(TaskScheduleCadence.once)
            Text(t("每天", "Daily")).tag(TaskScheduleCadence.daily)
            Text(t("每周", "Weekly")).tag(TaskScheduleCadence.weekly)
            Text(t("固定间隔", "Interval")).tag(TaskScheduleCadence.interval)
            if allowsAfterSuccess { Text(t("任务成功后", "After a Task Succeeds")).tag(TaskScheduleCadence.afterSuccess) }
        }
        .accessibilityIdentifier("home.schedule.cadence")
        if cadence == .interval {
            Stepper(value: $intervalHours, in: 1...168) {
                Text(t("每 \(intervalHours) 小时", "Every \(intervalHours) hours"))
            }
        }
        if cadence != .afterSuccess {
            DatePicker(t("预计执行", "Scheduled Time"), selection: $scheduledAt)
                .accessibilityIdentifier("home.schedule.time")
        }
    }

    private func t(_ zh: String, _ en: String) -> String { FloeL10n.isChinese ? zh : en }
}

struct FloeCanvasStartRow: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.and.pencil.and.ellipsis").foregroundStyle(FloeTheme.primary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(FloeL10n.isChinese ? "新建画布" : "New Canvas").foregroundStyle(.primary)
                    Text(FloeL10n.isChinese ? "从目标、场景或空白开始" : "Start with a goal, scenario, or blank canvas")
                        .font(FloeTheme.Typography.metadata).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityIdentifier("canvas.home.create")
    }
}

struct FloeCanvasLibraryRow<Metadata: View>: View {
    let title: String
    var excerpt: String? = nil
    @ViewBuilder let metadata: () -> Metadata

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(FloeTheme.primary.opacity(0.12))
                .frame(width: 52, height: 38)
                .overlay { Image(systemName: "rectangle.and.pencil.and.ellipsis") }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                if let excerpt, !excerpt.isEmpty {
                    Text(excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                metadata().font(FloeTheme.Typography.metadata).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .frame(minHeight: FloeTheme.minimumTarget)
        .contentShape(Rectangle())
    }
}

struct FloeBrowserTabStrip: View {
    struct Tab: Identifiable {
        let id: UUID
        let title: String
        let active: Bool
    }

    let tabs: [Tab]
    let onOpen: () -> Void
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void

    private var newTab: String { FloeL10n.isChinese ? "新建标签页" : "New Tab" }
    private var closeTab: String { FloeL10n.isChinese ? "关闭标签页" : "Close Tab" }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    HStack(spacing: 0) {
                        Button { onClose(tab.id) } label: {
                            Image(systemName: "xmark").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel(closeTab)
                        Button { onSelect(tab.id) } label: {
                            Text(tab.title.isEmpty ? newTab : tab.title).font(.subheadline).lineLimit(1)
                                .foregroundStyle(tab.active ? .primary : .secondary)
                                .padding(.trailing, 16)
                                .frame(minWidth: 80, maxWidth: 180, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(tab.active ? .isSelected : [])
                    }
                    .background(tab.active ? FloeTheme.readingSurface : .clear,
                                in: UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
                    .accessibilityElement(children: .contain)
                }
                Button(action: onOpen) {
                    Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(newTab).accessibilityIdentifier("browser.newTab")
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 44)
    }
}
