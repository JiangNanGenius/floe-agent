import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FloeToolboxUtilities
import FloeToolboxWorkbenches

struct MacTimerToolView: View {
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var service: ToolboxTimekeepingService
    private let bridge: ToolboxTimerReminderBridge

    @State private var adding = false
    @State private var name = ""
    @State private var hours = 0
    @State private var minutes = 5
    @State private var seconds = 0
    @State private var notifyOnFinish = false
    @State private var refreshRequested: Set<UUID> = []

    init(service: ToolboxTimekeepingService, bridge: ToolboxTimerReminderBridge) {
        self.service = service
        self.bridge = bridge
    }

    private func t(_ zh: String, _ en: String) -> String {
        MacToolboxText.t(zh, en, locale)
    }

    private var ticking: Bool {
        service.state.stopwatch.running || service.state.timers.contains { $0.phase == .running }
    }

    private var timeline: MacToolboxClockTimeline {
        MacToolboxClockTimeline(interval: service.state.stopwatch.running ? 1.0 / 30 : 1,
                                paused: !ticking || scenePhase != .active)
    }

    var body: some View {
        TimelineView(timeline) { _ in
            let now = ToolboxTimeSample.now
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if service.loading { ProgressView(t("正在读取计时记录", "Loading timers")) }
                    if service.state.clockReview { recoveryNotice }
                    if let issue = service.issue { issueNotice(issue) }
                    stopwatch(now)
                    timers(now)
                }
                .padding(24)
                .frame(maxWidth: 1_080, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: reminderExpiryIDs(now)) { _, ids in
                guard !ids.isEmpty else { return }
                let fresh = ids.filter { !refreshRequested.contains($0) }
                guard !fresh.isEmpty else { return }
                refreshRequested.formUnion(fresh)
                service.refreshReminders()
            }
            .onChange(of: service.expiredIDs(at: now), initial: true) { _, ids in
                guard !ids.isEmpty else { return }
                service.reconcile(at: now)
            }
        }
        .task { await service.load(reminders: bridge) }
        .onChange(of: scenePhase) { _, value in
            if value == .active {
                refreshRequested.removeAll()
                service.refreshReminders()
            }
        }
        .sheet(isPresented: $adding) { addTimerSheet }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("秒表与倒计时", "Stopwatch and timers"))
                    .font(.title2.weight(.semibold))
                Text(t("静音计时在窗口关闭后继续；到时通知需要系统通知权限。",
                       "Silent timers continue after this window closes; alerts require notification permission."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if service.saving { ProgressView().controlSize(.small) }
            Button(t("导出记录", "Export"), systemImage: "square.and.arrow.up") {
                exportCSV()
            }
            .disabled(!service.loaded)
            .accessibilityIdentifier("mac.toolbox.timer.export")
            Button(t("添加", "Add"), systemImage: "plus") {
                adding = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(!service.loaded || service.state.timers.count >= ToolboxTimekeepingArchive.maximumTimers)
            .accessibilityIdentifier("mac.toolbox.timer.add")
        }
    }

    private func stopwatch(_ now: ToolboxTimeSample) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("秒表", "Stopwatch")).font(.headline)
            HStack(alignment: .center, spacing: 0) {
                Text(ToolboxTimeText.duration(service.state.stopwatch.elapsed(at: now), hundredths: true))
                    .font(.system(.largeTitle, design: .rounded).monospacedDigit().weight(.medium))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("mac.toolbox.timer.stopwatch.reading")
                Spacer(minLength: 24)
                HStack(spacing: 8) {
                    Button {
                        if service.state.stopwatch.running {
                            service.pauseStopwatch(at: now)
                        } else {
                            service.startStopwatch(at: now)
                        }
                    } label: {
                        Label(service.state.stopwatch.running ? t("暂停", "Pause") : t("开始", "Start"),
                              systemImage: service.state.stopwatch.running ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mac.toolbox.timer.stopwatch.start")
                    Button {
                        service.lap(at: now)
                    } label: {
                        Label(t("分段", "Lap"), systemImage: "flag")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!service.state.stopwatch.running
                              || service.state.stopwatch.laps.count >= ToolboxStopwatch.maximumLaps)
                    .accessibilityIdentifier("mac.toolbox.timer.stopwatch.lap")
                    Button {
                        service.resetStopwatch()
                    } label: {
                        Label(t("重置", "Reset"), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("mac.toolbox.timer.stopwatch.reset")
                }
            }
            if !service.state.stopwatch.laps.isEmpty {
                Divider()
                DisclosureGroup(t("分段记录", "Laps") + " (\(service.state.stopwatch.laps.count))") {
                    VStack(spacing: 0) {
                        HStack {
                            Text(t("分段", "Lap"))
                            Spacer()
                            Text(t("本段 / 累计", "Split / Total"))
                        }
                        .font(.caption)
                        .padding(.vertical, 8)
                        ForEach(Array(service.state.stopwatch.laps.enumerated()).reversed(), id: \.element.id) { index, lap in
                            HStack {
                                Text(String(index + 1)).monospacedDigit()
                                Spacer()
                                Text(ToolboxTimeText.duration(lap.split, hundredths: true) + " / "
                                     + ToolboxTimeText.duration(lap.elapsed, hundredths: true))
                                    .font(.caption.monospacedDigit())
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
                .accessibilityIdentifier("mac.toolbox.timer.laps")
            }
        }
        .padding(16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14))
    }

    private func timers(_ now: ToolboxTimeSample) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text(t("倒计时", "Timers")).font(.title2.bold())
                Spacer()
                ForEach([1, 5, 15, 25], id: \.self) { value in
                    Button("\(value) " + t("分钟", "min")) {
                        service.addTimer(label: "\(value) " + t("分钟", "minutes"),
                                         duration: Double(value * 60), ring: false)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!service.loaded || service.state.timers.count >= ToolboxTimekeepingArchive.maximumTimers)
                    .accessibilityIdentifier("mac.toolbox.timer.preset.\(value)")
                }
            }
            if service.state.timers.isEmpty {
                ContentUnavailableView(t("还没有倒计时", "No timers yet"),
                                       systemImage: "timer",
                                       description: Text(t("选一个常用时长，或添加自定义倒计时。",
                                                           "Choose a preset or add your own timer.")))
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top),
                                GridItem(.flexible(), spacing: 12, alignment: .top)],
                      spacing: 12) {
                ForEach(service.state.timers) { timer in
                    timerCard(timer, now: now)
                }
            }
        }
    }

    private func timerCard(_ timer: ToolboxCountdown, now: ToolboxTimeSample) -> some View {
        let remaining = timer.remaining(at: now)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(timer.label)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("mac.toolbox.timer.title.\(timer.id.uuidString)")
                    Label(statusText(timer, remaining: remaining), systemImage: statusSymbol(timer, remaining: remaining))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Menu {
                    Button(t("重置", "Reset"), systemImage: "arrow.counterclockwise") {
                        refreshRequested.remove(timer.id)
                        service.reset(timer.id)
                    }
                    Button(t("删除", "Delete"), systemImage: "trash", role: .destructive) {
                        refreshRequested.remove(timer.id)
                        service.remove(timer.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(t("倒计时操作", "Timer actions") + " " + timer.label)
                .accessibilityIdentifier("mac.toolbox.timer.actions.\(timer.id.uuidString)")
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(ToolboxTimeText.duration(ceil(remaining)))
                    .font(.system(.title, design: .rounded).monospacedDigit().weight(.medium))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("mac.toolbox.timer.remaining.\(timer.id.uuidString)")
                Spacer()
                timerToggle(timer, remaining: remaining)
            }
            Divider()
            Toggle(t("到时通知", "Notify when finished"),
                   isOn: Binding(get: { timer.reminder }, set: { service.setReminder($0, for: timer.id) }))
                .font(.subheadline)
                .disabled(remaining <= 0 || service.reminderStatus[timer.id] == .working)
                .accessibilityIdentifier("mac.toolbox.timer.reminder.\(timer.id.uuidString)")
            if service.reminderStatus[timer.id] == .working {
                ProgressView().controlSize(.small)
            }
            if service.reminderStatus[timer.id] == .scheduled {
                Label(t("系统通知已就绪", "System notification ready"), systemImage: "bell.badge")
                    .font(.caption)
                    .accessibilityIdentifier("mac.toolbox.timer.reminder.status.\(timer.id.uuidString)")
            }
            if service.reminderStatus[timer.id] == .ringing {
                Button {
                    service.setReminder(false, for: timer.id)
                } label: {
                    Label(t("停止提醒", "Stop alert"), systemImage: "bell.slash")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("mac.toolbox.timer.stopRinging.\(timer.id.uuidString)")
            }
            if timer.reminder, service.reminderStatus[timer.id] == .failed {
                HStack {
                    Label(t("系统通知尚未确认", "System notification not confirmed"),
                          systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(t("刷新", "Refresh")) {
                        service.refreshReminders()
                    }
                    .accessibilityIdentifier("mac.toolbox.timer.reminder.retry.\(timer.id.uuidString)")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14))
    }

    private func timerToggle(_ timer: ToolboxCountdown, remaining: Double) -> some View {
        Button {
            if remaining <= 0 {
                refreshRequested.remove(timer.id)
                service.restart(timer.id)
            } else if timer.phase == .running {
                service.pause(timer.id)
            } else {
                service.resume(timer.id)
            }
        } label: {
            Label(remaining <= 0 ? t("重新开始", "Restart")
                  : timer.phase == .running ? t("暂停", "Pause") : t("继续", "Resume"),
                  systemImage: timer.phase == .running && remaining > 0 ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("mac.toolbox.timer.toggle.\(timer.id.uuidString)")
    }

    private func statusText(_ timer: ToolboxCountdown, remaining: Double) -> String {
        if remaining <= 0 || timer.phase == .finished { return t("已结束", "Finished") }
        return timer.phase == .running ? t("计时中", "Running") : t("已暂停", "Paused")
    }

    private func statusSymbol(_ timer: ToolboxCountdown, remaining: Double) -> String {
        if remaining <= 0 || timer.phase == .finished { return "checkmark.circle" }
        return timer.phase == .running ? "timer" : "pause.circle"
    }

    private var recoveryNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Label(t("恢复的计时已暂停，请核对后继续。",
                    "Recovered timers are paused. Check them before continuing."),
                  systemImage: "clock.badge.exclamationmark")
            Spacer()
            Button(t("知道了", "Got it")) { service.acknowledgeClockReview() }
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func issueNotice(_ issue: ToolboxClockIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Label(issueText(issue), systemImage: "exclamationmark.circle")
            Spacer()
            if case .reminder = issue {
                Button(t("打开通知设置", "Open Notification Settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .accessibilityIdentifier("mac.toolbox.timer.openSettings")
            }
            if issue == .load {
                Button(t("重试读取", "Retry loading")) {
                    Task { await service.load(reminders: bridge) }
                }
            }
            Button(t("关闭提示", "Dismiss")) { service.issue = nil }
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("mac.toolbox.timer.issue")
    }

    private func issueText(_ issue: ToolboxClockIssue) -> String {
        switch issue {
        case .load: t("计时记录未能读取，原文件已保留。", "Timer records could not be read. The original file is preserved.")
        case .save: t("记录未能保存，本次计时仍保留在这里。", "Records could not be saved. This session is still here.")
        case .export: t("未能导出记录，请重试。", "The records could not be exported. Try again.")
        case .limit: t("已达到计时或分段数量上限。", "The timer or lap limit has been reached.")
        case .invalid: t("请检查计时名称或时长。", "Check the timer name or duration.")
        case .reminder(let detail):
            detail.isEmpty
                ? t("未能设置通知，请在系统设置中允许 Floe 通知。",
                    "Allow Floe notifications in System Settings to enable alerts.")
                : detail
        }
    }

    private var addTimerSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("添加倒计时", "Add a timer"))
                .font(.title2.weight(.semibold))
            Form {
                TextField(t("名称", "Name"), text: $name)
                    .accessibilityIdentifier("mac.toolbox.timer.name")
                if name.utf8.count > 256 {
                    Text(t("名称太长，请缩短。", "The name is too long. Shorten it."))
                        .foregroundStyle(.red)
                }
                HStack(spacing: 16) {
                    Stepper(value: $hours, in: 0...maximumHours) {
                        Text(t("\(hours) 小时", "\(hours) hr"))
                    }
                    Stepper(value: $minutes, in: 0...59) {
                        Text(t("\(minutes) 分钟", "\(minutes) min"))
                    }
                    .disabled(hours == maximumHours)
                    Stepper(value: $seconds, in: 0...59) {
                        Text(t("\(seconds) 秒", "\(seconds) sec"))
                    }
                    .disabled(hours == maximumHours)
                }
                .onChange(of: hours) { _, value in
                    if value == maximumHours { minutes = 0; seconds = 0 }
                }
                Text(t("最长 31 天，可同时保留 12 个倒计时。",
                       "Up to 31 days, with 12 timers at a time."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if enteredDuration == nil {
                    Text(t("请选择大于零的时长。", "Choose a duration greater than zero."))
                        .foregroundStyle(.red)
                }
                Toggle(t("到时通知", "Notify when finished"), isOn: $notifyOnFinish)
            }
            .formStyle(.grouped)
            HStack {
                Button(t("取消", "Cancel")) { adding = false }
                Spacer()
                Button(t("添加并开始", "Add and start")) {
                    guard let duration = enteredDuration else { return }
                    let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    service.addTimer(label: label.isEmpty ? t("倒计时", "Timer") : label,
                                     duration: duration, ring: notifyOnFinish)
                    adding = false
                    name = ""
                    hours = 0
                    minutes = 5
                    seconds = 0
                    notifyOnFinish = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(enteredDuration == nil || name.utf8.count > 256)
                .accessibilityIdentifier("mac.toolbox.timer.confirmAdd")
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var maximumHours: Int { Int(ToolboxCountdown.maximumDuration / 3600) }

    private var enteredDuration: Double? {
        guard (0...maximumHours).contains(hours), (0...59).contains(minutes), (0...59).contains(seconds) else {
            return nil
        }
        let value = Double(hours * 3600 + minutes * 60 + seconds)
        return value > 0 && value <= ToolboxCountdown.maximumDuration ? value : nil
    }

    private func reminderExpiryIDs(_ now: ToolboxTimeSample) -> [UUID] {
        service.state.timers.filter {
            $0.reminder && $0.phase == .running && $0.remaining(at: now) <= 0
        }.map(\.id)
    }

    private func exportCSV() {
        let now = ToolboxTimeSample.now
        var rows = ["Kind,Name,SplitSeconds,ElapsedSeconds,DurationSeconds,RemainingSeconds,State"]
        rows.append("Stopwatch,,,\(service.state.stopwatch.elapsed(at: now)),,,\(service.state.stopwatch.running ? "running" : "paused")")
        rows += service.state.stopwatch.laps.enumerated().map {
            "Lap,\($0.offset + 1),\($0.element.split),\($0.element.elapsed),,,"
        }
        for timer in service.state.timers {
            var label = timer.label.replacingOccurrences(of: "\"", with: "\"\"")
            if let first = label.first, "=+-@".contains(first) { label = "'" + label }
            rows.append("Timer,\"\(label)\",,,\(timer.duration),\(timer.remaining(at: now)),\(timer.phase.rawValue)")
        }
        let text = rows.joined(separator: "\n")
        Task { @MainActor in
            do {
                _ = try await MacToolboxFilePanels.saveText(text, suggestedName: "Floe-Timers.csv",
                                                            contentType: .commaSeparatedText,
                                                            locale: locale,
                                                            title: t("导出记录", "Export records"))
            } catch {
                service.issue = .export
            }
        }
    }

    private var cardBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }
}

/// A scheduled clock read while running; a finite paused schedule keeps the
/// scroll position stable when nothing is moving.
private struct MacToolboxClockTimeline: TimelineSchedule {
    let interval: TimeInterval
    let paused: Bool

    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        if paused { return AnySequence(CollectionOfOne(startDate)) }
        return AnySequence(PeriodicTimelineSchedule(from: startDate, by: interval).entries(from: startDate, mode: mode))
    }
}
