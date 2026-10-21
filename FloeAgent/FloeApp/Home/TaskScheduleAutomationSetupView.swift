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

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import AppIntents
import FloeCore
import FloeModels

struct TaskScheduleAutomationSetupView: View {
    let schedule: TaskScheduleRecord
    @Environment(\.dismiss) private var dismiss

    private var anchorCalendar: Calendar {
        TaskSchedulePlanner.calendar(for: schedule)
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
            setupText(zh: "单次计划请添加日期判断，避免提前触发。完成后关闭重复的自动化。",
                      en: "For a one-time plan, add a date condition to avoid early triggers. Turn off any repeating automation after completion.")
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
        case .once: setupText(zh: "仅此一次；运行后请回到快捷指令关闭该自动化", en: "run it once; turn the automation off in Shortcuts after it runs")
        case .interval: setupText(zh: "用「每天」近似开始时间", en: "use Daily to approximate the start time")
        case .afterSuccess: ""
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(setupText(zh: "计划", en: "Plan")) {
                    LabeledContent(setupText(zh: "名称", en: "Name"), value: schedule.title)
                    LabeledContent(setupText(zh: "周期", en: "Cadence"), value: cadenceText)
                    if let planTimeText {
                        LabeledContent(setupText(zh: "计划时间", en: "Plan time"), value: planTimeText)
                    }
                    LabeledContent(setupText(zh: "时区", en: "Time zone"), value: timezoneName)
                }
                if !schedule.isEnabled {
                    Section {
                        Label(setupText(zh: "此计划已停用。先在主页启用后，自动化才能运行它。",
                                        en: "This plan is disabled. Enable it on Home before an automation can run it."),
                              systemImage: "pause.circle")
                            .foregroundStyle(.secondary)
                    }
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
                        Text(stepOneText)
                        Text(setupText(zh: "2. 添加操作，选择 Floe 的「运行定时任务」。",
                                       en: "2. Add the action “Run Scheduled Task” from Floe."))
                        Text(setupText(zh: "3. 在该操作中选择计划「\(schedule.title)」。",
                                       en: "3. Pick the plan “\(schedule.title)” in the action."))
                    }
                    Section {
                        ShortcutsLink { }
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
            .navigationTitle(setupText(zh: "系统定时", en: "Automation"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("workspace.workspace_canvas_view.cancel") { dismiss() }
                }
            }
        }
    }

    private var stepOneText: String {
        setupText(zh: "1. 在快捷指令的「自动化」页新建「特定时间」，时间设为上方建议值，\(repeatInstruction)，并打开「自动化」开关。",
                  en: "1. In Shortcuts, add a Specific Time automation, set the time to the suggested value above, \(repeatInstruction), and turn the automation switch on.")
    }

    /// Inline bilingual fallback for strings whose central catalog entry has
    /// not landed yet: a missing key must never render raw.
    private func setupText(zh: String, en: String) -> String {
        isChinese ? zh : en
    }
}
#endif
