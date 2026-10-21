// FloeApp — Selected-plan system automation setup (system Shortcuts).
//
// SPDX-License-Identifier: MPL-2.0
//
// A small feature-local sheet for ONE EXISTING schedule. It shows the plan's
// own title, cadence, anchor time and time zone, then only the steps needed to
// add Floe's "Run Scheduled Task" action in the system Shortcuts app and to
// attach a Specific Time trigger that matches the plan. Floe cannot detect
// whether the system automation was created or enabled; this sheet only opens
// Shortcuts and never claims an enrollment happened.
//
// When (and only when) the app bundle carries the Apple-SIGNED Shortcuts
// template file, the sheet also offers a REAL import handoff: the system
// shows its own "Add Shortcut" confirmation for the signed file. Opening or
// handing off is recorded as evidence with distinct states; an installed
// automation is never claimed, and the manual path stays available.
// An actual handoff — or the user's explicit confirmation, import or manual
// — durably (re)starts SILENT monitoring for this plan, so that a later
// permanent delete or terminal one-shot run can surface exactly one honest
// cleanup reminder. Never-configured plans have no record and no reminder.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import AppIntents
import FloeCore
import FloeModels
import FloePersistence

struct TaskScheduleAutomationSetupView: View {
    let schedule: TaskScheduleRecord
    /// Monitoring/cleanup evidence authority, injected by Home. Without it
    /// the sheet degrades to display-only evidence (no durable monitoring).
    var cleanupStore: TaskScheduleCleanupReminderStore?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var importModel = TaskScheduleShortcutImport()

    private var anchorCalendar: Calendar {
        TaskSchedulePlanner.calendar(for: schedule)
    }

    /// The signed template import is only ever shown for the cadence
    /// families whose automation this sheet actually explains (the same
    /// once/daily/weekly set the Home row button gates). interval/afterSuccess
    /// plans keep showing the honest "no time automation" limitations.
    private var showsImport: Bool {
        importModel.availability != .noTemplate
    }

    /// Compact honest status line under the import button. Every state says
    /// what FLOE did, never what the system confirmed; only the user's own
    /// mark may read "added".
    private var importStatusText: String? {
        switch importModel.evidence?.attempt?.state {
        case nil, .filePrepared:
            return nil
        case .importFlowOpened:
            return setupText(
                zh: "已打开导入页，请在系统页面确认添加。",
                en: "Import page opened. Confirm the add there.")
        case .handedOffToUser:
            return setupText(
                zh: "文件已交给系统，请在快捷指令中确认添加。",
                en: "File handed to the system. Confirm the add in Shortcuts.")
        case .cancelled:
            return setupText(zh: "导入未完成，可重试。", en: "Import not completed — you can retry.")
        case .failed:
            return setupText(
                zh: "无法打开导入页，可重试或手动设置。",
                en: "Could not open import. Retry or use manual setup.")
        }
    }

    private var importShareBinding: Binding<FloeShortcutShareItem?> {
        Binding(
            get: { importModel.shareItem },
            set: { newValue in
                if newValue == nil {
                    // Sheet dismissed. The activity's own completion already
                    // records when it ran; a bare dismissal records cancel.
                    Task { await importModel.finishShareSheet(completed: false) }
                }
            })
    }

    private var timezoneName: String {
        schedule.anchorTimezone ?? TimeZone.current.identifier
    }

    private var isChinese: Bool { FloeL10n.isChinese }

    /// Trigger recommendation: the plan's own anchor wall-clock rounded UP to
    /// the next whole minute (an exact minute stays), as a real `Date` in the
    /// plan's anchor time zone. Stored plan times can carry seconds; a
    /// Specific Time trigger set to the truncated displayed minute would fire
    /// BEFORE the plan's real due instant and be refused as not due. The
    /// stored plan time is never changed here.
    private var recommendedTriggerDate: Date? {
        switch schedule.cadence {
        case .once, .daily, .weekly:
            return TaskScheduleAutomationTiming.roundedUpWholeMinute(
                for: schedule.scheduledAt,
                calendar: anchorCalendar)
        case .interval, .afterSuccess:
            return nil
        }
    }

    private func anchorFormatter(_ dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = anchorCalendar
        formatter.timeZone = anchorCalendar.timeZone
        formatter.locale = isChinese
            ? Locale(identifier: "zh_CN")
            : Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dateFormat
        return formatter
    }

    /// The suggested trigger moment — the real rounded `Date`, never a fake
    /// "today" — formatted in the plan's anchor time zone for the cadence.
    private var triggerTimeText: String {
        guard let recommendedTriggerDate else { return "" }
        switch schedule.cadence {
        case .daily:
            return anchorFormatter("HH:mm").string(from: recommendedTriggerDate)
        case .weekly:
            // Formats the actual rounded date, so the weekday always matches
            // the plan anchor and only shifts when the round-up truly crosses
            // midnight in the anchor zone.
            return anchorFormatter("EEEE HH:mm").string(from: recommendedTriggerDate)
        case .once:
            return anchorFormatter("yyyy-MM-dd HH:mm")
                .string(from: recommendedTriggerDate)
        case .interval, .afterSuccess:
            return ""
        }
    }

    /// True when the plan's anchor zone differs from the device's zone: the
    /// suggested clock is anchored to the plan, while the system trigger
    /// usually follows the device zone, so the match is not unconditional.
    private var showsTimezoneMismatch: Bool {
        anchorCalendar.timeZone.identifier != TimeZone.current.identifier
    }

    private var timezoneMismatchText: String {
        setupText(
            zh: "建议时间按计划锚点时区显示；系统触发通常跟随设备时区。两者不同时，请在快捷指令中按同一时刻设置。",
            en: "The suggested time is shown in the plan's anchor time zone; the system trigger usually follows the device time zone. When they differ, set the automation to the same instant in Shortcuts.")
    }

    /// The plan's own anchor time, for context only.
    private var planTimeText: String? {
        switch schedule.cadence {
        case .daily, .weekly:
            return anchorFormatter("HH:mm:ss").string(from: schedule.scheduledAt)
        case .once:
            return anchorFormatter("yyyy-MM-dd HH:mm:ss").string(from: schedule.scheduledAt)
        case .interval:
            return anchorFormatter("yyyy-MM-dd HH:mm").string(from: schedule.scheduledAt)
        case .afterSuccess:
            return nil
        }
    }

    private var cadenceText: String {
        switch schedule.cadence {
        case .once: return setupText(zh: "一次", en: "One time")
        case .daily: return setupText(zh: "每天", en: "Daily")
        case .weekly: return setupText(zh: "每周", en: "Weekly")
        case .interval:
            let seconds = schedule.intervalSeconds ?? 0
            if seconds >= 3_600 {
                return setupText(zh: "每 \(seconds / 3_600) 小时", en: "Every \(seconds / 3_600) hours")
            }
            return setupText(zh: "每 \(max(1, seconds / 60)) 分钟", en: "Every \(max(1, seconds / 60)) minutes")
        case .afterSuccess:
            return setupText(zh: "任务成功后", en: "After a task succeeds")
        }
    }

    /// Short cadence-specific limit, actionable instead of promising what the
    /// system trigger cannot do.
    private var limitationText: String? {
        switch schedule.cadence {
        case .once:
            setupText(zh: "系统定时会重复触发；请在预期的一次运行成功后关闭此自动化。",
                      en: "The system trigger repeats. After the intended run succeeds, turn this automation off.")
        case .interval:
            setupText(zh: "固定间隔请使用应用内计划，后台执行时间由系统安排。",
                      en: "Use the in-app plan for this interval. iOS schedules its background execution.")
        case .afterSuccess:
            setupText(zh: "此计划随选定的任务成功触发，没有按时间的运行，无法用时间自动化设置。",
                      en: "This plan runs when the selected task succeeds and has no time-based run, so there is no time automation to set up.")
        case .daily, .weekly:
            nil
        }
    }

    /// What to choose in the trigger's Repeat row, kept inside step 1.
    private var repeatInstruction: String {
        switch schedule.cadence {
        case .daily: setupText(zh: "重复选「每天」", en: "set Repeat to Daily")
        case .weekly: setupText(zh: "重复选「每周」并勾选对应的星期", en: "set Repeat to Weekly with its weekday")
        case .once: setupText(zh: "重复保持默认", en: "leave Repeat at its default")
        case .interval: setupText(zh: "用「每天」近似开始时间", en: "use Daily to approximate the start time")
        case .afterSuccess: ""
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !schedule.isEnabled {
                    Section {
                        Label(setupText(zh: "此计划已停用。先在主页启用后，自动化才能运行它。",
                                        en: "This plan is disabled. Enable it on Home before an automation can run it."),
                              systemImage: "pause.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                if schedule.cadence == .once || schedule.cadence == .daily || schedule.cadence == .weekly {
                    Section(setupText(zh: "快捷指令", en: "Shortcut")) {
                        if showsImport {
                            Button {
                                Task { await importModel.presentImport() }
                            } label: {
                                Label(setupText(zh: "导入定时快捷指令",
                                               en: "Import scheduled-task shortcut"),
                                      systemImage: "square.and.arrow.down")
                                    .frame(minHeight: FloeTheme.minimumTarget)
                            }
                            .buttonStyle(.borderless)
                            if let importStatusText {
                                Text(importStatusText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ShortcutsLink { }
                        Toggle(
                            setupText(zh: "我已添加该计划的自动化",
                                      en: "I added an automation for this plan"),
                            isOn: Binding(
                                get: { importModel.evidence?.userConfirmedSetup ?? false },
                                set: { confirmed in
                                    if confirmed {
                                        Task { await importModel.markSetupConfirmedByUser() }
                                    } else {
                                        importModel.undoSetupConfirmation()
                                    }
                                }))
                        Text(setupText(
                            zh: "Floe 无法自行检测系统自动化，这里只记录你自己的确认。",
                            en: "Floe cannot detect system automations; this records only your confirmation."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section(setupText(zh: "计划", en: "Plan")) {
                    LabeledContent(setupText(zh: "名称", en: "Name"), value: schedule.title)
                    LabeledContent(setupText(zh: "周期", en: "Cadence"), value: cadenceText)
                    if let planTimeText {
                        LabeledContent(setupText(zh: "计划时间", en: "Plan time"), value: planTimeText)
                    }
                    LabeledContent(setupText(zh: "时区", en: "Time zone"), value: timezoneName)
                }
                if schedule.cadence == .afterSuccess || schedule.cadence == .interval {
                    Section {
                        Text(limitationText ?? "")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section(setupText(zh: "设置步骤", en: "Set up")) {
                        if !triggerTimeText.isEmpty {
                            LabeledContent(setupText(zh: "建议触发时间", en: "Suggested trigger time"),
                                           value: triggerTimeText)
                        }
                        if showsTimezoneMismatch {
                            Text(timezoneMismatchText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if showsImport {
                            Text(setupText(
                                zh: "添加后，点「日程」选择计划「\(schedule.title)」，再返回保存。",
                                en: "After adding, set Schedule to “\(schedule.title)”, then return to save."))
                            Text(setupText(
                                zh: "新建「特定时间」自动化，运行该快捷指令；\(repeatInstruction)。",
                                en: "Create a Specific Time automation for that shortcut; \(repeatInstruction)."))
                            Text(enableStepText)
                            DisclosureGroup(setupText(zh: "手动设置", en: "Manual setup")) {
                                manualSetupSteps
                            }
                        } else {
                            manualSetupSteps
                        }
                    }
                    if let limitationText {
                        Section {
                            Text(limitationText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .task {
                importModel.refresh(
                    scheduleID: schedule.id, title: schedule.title, cleanupStore: cleanupStore)
            }
            .sheet(item: importShareBinding) { item in
                FloeShortcutShareActivity(items: [item.url]) { completed in
                    Task { await importModel.finishShareSheet(completed: completed) }
                }
            }
            .navigationTitle(setupText(zh: "系统定时", en: "Automation"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("workspace.workspace_canvas_view.cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var manualSetupSteps: some View {
        Text(stepOneText)
        Text(setupText(zh: "2. 添加 Floe 的「运行定时任务」操作。",
                       en: "2. Add Floe’s Run Scheduled Task action."))
        Text(setupText(zh: "3. 选择计划「\(schedule.title)」。",
                       en: "3. Choose “\(schedule.title)”."))
        Text(enableStepText)
    }

    private var stepOneText: String {
        setupText(zh: "1. 在快捷指令的「自动化」页新建「特定时间」，时间设为上方建议值，\(repeatInstruction)。",
                  en: "1. In Shortcuts, create a Specific Time automation at the suggested time above, and \(repeatInstruction).")
    }

    private var enableStepText: String {
        setupText(zh: "设为「立即运行」，并启用自动化。",
                  en: "Select Run Immediately and enable the automation.")
    }

    /// Inline bilingual fallback for strings whose central catalog entry has
    /// not landed yet: a missing key must never render raw.
    private func setupText(zh: String, en: String) -> String {
        isChinese ? zh : en
    }
}
#endif
