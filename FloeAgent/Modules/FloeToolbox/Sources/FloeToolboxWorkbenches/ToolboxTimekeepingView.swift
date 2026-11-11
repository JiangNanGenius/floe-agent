import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
import FloeToolboxUtilities

@MainActor public struct ToolboxTimerView: View {
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var service = ToolboxTimekeepingService.shared
    @State private var adding = false
    @State private var name = ""
    @State private var hours = "0"
    @State private var minutes = "5"
    @State private var seconds = "0"
    @State private var ringOnStart = true
    @State private var exporting = false
    @State private var rebuilding = false
    @State private var exportDocument = ToolboxClockExport(text: "")
    private let reminders: ToolboxTimerReminderBridge?
    public init(reminders: ToolboxTimerReminderBridge? = nil) { self.reminders = reminders }
    private func t(_ zh: String, _ en: String) -> String { workbenchText(zh, en, locale) }
    private var ticking: Bool { service.state.stopwatch.running || service.state.timers.contains { $0.phase == .running } }

    public var body: some View {
        GeometryReader { geometry in
            TimelineView(ToolboxClockTimeline(interval: service.state.stopwatch.running ? 1.0 / 30 : 1,
                                             paused: !ticking || scenePhase != .active)) { _ in
                let now = ToolboxTimeSample.now
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if service.loading { ProgressView(t("正在读取计时记录", "Loading timers")) }
                        if service.state.clockReview { recoveryNotice }
                        if let issue = service.issue { issueNotice(issue) }
                        stopwatch(now)
                        timers(now, wide: geometry.size.width >= 760 && !typeSize.isAccessibilitySize)
                    }
                    .padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
                }
                .onChange(of: service.expiredIDs(at: now)) { _, ids in
                    if !ids.isEmpty { service.reconcile(at: now) }
                }
            }
        }
        .background(clockBackground)
        .navigationTitle(t("秒表与倒计时", "Stopwatch and timers"))
        .toolbar {
            Button(t("导出记录", "Export"), systemImage: "square.and.arrow.up") {
                exportDocument = ToolboxClockExport(text: csv(at: .now)); exporting = true
            }.disabled(!service.loaded).accessibilityIdentifier("toolbox.timer.export")
        }
        .task { await service.load(reminders: reminders) }
        .onChange(of: scenePhase) { _, value in if value == .active { service.refreshReminders() } }
        .sheet(isPresented: $adding) { addSheet }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: "Floe-Timers") { result in
            if case .failure = result { service.issue = .export }
        }
        .confirmationDialog(t("重新建立计时记录？", "Rebuild timer records?"), isPresented: $rebuilding, titleVisibility: .visible) {
            Button(t("保留备份并重新开始", "Keep a backup and start again"), role: .destructive) {
                Task { await service.rebuildRecords() }
            }
        } message: {
            Text(t("原文件会保留为备份，然后建立空的计时记录。", "The original file will be kept as a backup before creating empty timer records."))
        }
    }

    private func stopwatch(_ now: ToolboxTimeSample) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t("秒表", "Stopwatch")).font(.title2.bold())
                Spacer()
                if service.saving { ProgressView().controlSize(.small).accessibilityLabel(t("正在保存", "Saving")) }
            }
            ViewThatFits(in: .horizontal) {
                Text(ToolboxTimeText.duration(service.state.stopwatch.elapsed(at: now), hundredths: true))
                    .font(.system(.largeTitle, design: .monospaced).weight(.medium))
                Text(ToolboxTimeText.duration(service.state.stopwatch.elapsed(at: now), hundredths: true))
                    .font(.body.monospacedDigit())
            }.accessibilityIdentifier("toolbox.timer.stopwatch.reading")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { stopwatchActions(now) }
                VStack(alignment: .leading, spacing: 12) { stopwatchActions(now) }
            }
            .disabled(!service.loaded)
            if !service.state.stopwatch.laps.isEmpty {
                DisclosureGroup(t("分段记录", "Laps") + " (\(service.state.stopwatch.laps.count))") {
                    LazyVStack(spacing: 0) {
                        HStack {
                            Text(t("分段", "Lap")); Spacer()
                            Text(t("本段 / 累计", "Split / Total"))
                        }.font(.caption).padding(.vertical, 10)
                        ForEach(Array(service.state.stopwatch.laps.enumerated()).reversed(), id: \.element.id) { index, lap in
                            HStack(alignment: .firstTextBaseline) {
                                Text(String(index + 1)).monospacedDigit()
                                Spacer()
                                ViewThatFits(in: .horizontal) {
                                    Text(ToolboxTimeText.duration(lap.split, hundredths: true) + " / " + ToolboxTimeText.duration(lap.elapsed, hundredths: true))
                                    VStack(alignment: .trailing) {
                                        Text(ToolboxTimeText.duration(lap.split, hundredths: true))
                                        Text(ToolboxTimeText.duration(lap.elapsed, hundredths: true))
                                    }
                                }.font(.caption.monospacedDigit())
                            }.padding(.vertical, 12)
                            Divider()
                        }
                    }
                }.accessibilityIdentifier("toolbox.timer.laps")
            }
        }
        .padding(20).background(clockReadingBackground, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private func stopwatchActions(_ now: ToolboxTimeSample) -> some View {
        Button {
            if service.state.stopwatch.running { service.pauseStopwatch(at: now) }
            else { service.startStopwatch(at: now) }
        } label: {
            Label(service.state.stopwatch.running ? t("暂停", "Pause") : t("开始", "Start"),
                  systemImage: service.state.stopwatch.running ? "pause.fill" : "play.fill")
                .frame(minHeight: 32)
        }.buttonStyle(.borderedProminent).accessibilityIdentifier("toolbox.timer.stopwatch.start")
        Button { service.lap(at: now) } label: { Label(t("分段", "Lap"), systemImage: "flag").frame(minHeight: 32) }
            .buttonStyle(.bordered)
            .disabled(!service.state.stopwatch.running || service.state.stopwatch.laps.count >= ToolboxStopwatch.maximumLaps)
            .accessibilityIdentifier("toolbox.timer.stopwatch.lap")
        Button { service.resetStopwatch() } label: { Label(t("重置", "Reset"), systemImage: "arrow.counterclockwise").frame(minHeight: 44) }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("toolbox.timer.stopwatch.reset")
    }

    private func timers(_ now: ToolboxTimeSample, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t("倒计时", "Timers")).font(.title2.bold())
                Spacer()
                Button { adding = true } label: { Label(t("添加", "Add"), systemImage: "plus").frame(minHeight: 44) }
                    .disabled(!service.loaded || service.state.timers.count >= ToolboxTimekeepingArchive.maximumTimers)
                    .accessibilityIdentifier("toolbox.timer.add")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach([1, 5, 15, 25], id: \.self) { value in
                        Button {
                            service.addTimer(label: "\(value) " + t("分钟", "minutes"), duration: Double(value * 60), ring: reminders != nil)
                        } label: { Text("\(value) " + t("分钟", "min")).frame(minHeight: 32) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("toolbox.timer.preset.\(value)")
                    }
                }
            }.scrollIndicators(.hidden).disabled(!service.loaded || service.state.timers.count >= ToolboxTimekeepingArchive.maximumTimers)
            if service.state.timers.isEmpty {
                ContentUnavailableView(t("还没有倒计时", "No timers yet"), systemImage: "timer",
                    description: Text(t("选一个常用时长，或添加自定义倒计时。", "Choose a preset or add your own timer.")))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: wide ? 2 : 1), spacing: 16) {
                ForEach(service.state.timers) { timer in timerCard(timer, now: now) }
            }
        }
    }

    private func timerCard(_ timer: ToolboxCountdown, now: ToolboxTimeSample) -> some View {
        let remaining = timer.remaining(at: now)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(timer.label).font(.headline).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("toolbox.timer.title.\(timer.id.uuidString)")
                Spacer(minLength: 8)
                Menu {
                    Button(t("重置", "Reset"), systemImage: "arrow.counterclockwise") { service.reset(timer.id) }
                    Button(t("删除", "Delete"), systemImage: "trash", role: .destructive) { service.remove(timer.id) }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .accessibilityLabel(t("倒计时操作", "Timer actions") + " " + timer.label)
                    .accessibilityIdentifier("toolbox.timer.actions.\(timer.id.uuidString)")
            }
            ViewThatFits(in: .horizontal) {
                Text(ToolboxTimeText.duration(ceil(remaining))).font(.system(.title, design: .monospaced).weight(.medium))
                Text(ToolboxTimeText.duration(ceil(remaining))).font(.body.monospacedDigit())
            }.accessibilityIdentifier("toolbox.timer.remaining.\(timer.id.uuidString)")
            HStack {
                Label(remaining <= 0 ? t("已结束", "Finished") : timer.phase == .running ? t("计时中", "Running") : t("已暂停", "Paused"),
                      systemImage: remaining <= 0 ? "checkmark.circle" : timer.phase == .running ? "timer" : "pause.circle")
                    .font(.subheadline)
                Spacer()
                Button {
                    if remaining <= 0 { service.restart(timer.id) }
                    else if timer.phase == .running { service.pause(timer.id) }
                    else { service.resume(timer.id) }
                } label: {
                    Label(remaining <= 0 ? t("重新开始", "Restart") : timer.phase == .running ? t("暂停", "Pause") : t("继续", "Resume"),
                          systemImage: timer.phase == .running && remaining > 0 ? "pause.fill" : "play.fill")
                        .frame(minHeight: 32)
                }.buttonStyle(.bordered)
                    .accessibilityIdentifier("toolbox.timer.toggle.\(timer.id.uuidString)")
            }
            Divider()
            Toggle(t("到时响铃", "Ring when finished"), isOn: Binding(get: { timer.reminder }, set: { service.setReminder($0, for: timer.id) }))
                .disabled(reminders == nil || service.reminderStatus[timer.id] == .working)
                .accessibilityIdentifier("toolbox.timer.reminder.\(timer.id.uuidString)")
            if service.reminderStatus[timer.id] == .working { ProgressView().controlSize(.small) }
            if service.reminderStatus[timer.id] == .scheduled {
                Label(t("系统计时器已就绪", "System timer ready"), systemImage: "bell.badge").font(.caption)
                    .accessibilityIdentifier("toolbox.timer.reminder.status.\(timer.id.uuidString)")
            }
            if service.reminderStatus[timer.id] == .ringing {
                Button { service.setReminder(false, for: timer.id) } label: {
                    Label(t("停止响铃", "Stop ringing"), systemImage: "bell.slash").frame(minHeight: 44)
                }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("toolbox.timer.stopRinging.\(timer.id.uuidString)")
            }
            if timer.reminder, service.reminderStatus[timer.id] == .failed {
                HStack {
                    Label(t("系统计时器尚未确认", "System timer not confirmed"), systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(t("刷新", "Refresh")) { service.refreshReminders() }.frame(minHeight: 44)
                }
            }
            if !timer.reminder, service.reminderStatus[timer.id] == .failed {
                HStack {
                    Text(t("尚未确认关闭响铃", "Stop not confirmed")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(t("重试", "Retry")) { service.setReminder(false, for: timer.id) }.frame(minHeight: 44)
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(clockReadingBackground, in: RoundedRectangle(cornerRadius: 14))
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                TextField(t("名称", "Name"), text: $name).accessibilityIdentifier("toolbox.timer.name")
                if name.utf8.count > 256 { Text(t("名称太长，请缩短。", "The name is too long. Shorten it.")).foregroundStyle(.red) }
                Section(t("时长", "Duration")) {
                    durationField(t("小时", "Hours"), text: $hours)
                    durationField(t("分钟", "Minutes"), text: $minutes)
                    durationField(t("秒", "Seconds"), text: $seconds)
                }
                Text(t("最长 31 天，可同时保留 12 个倒计时。", "Up to 31 days, with 12 timers at a time.")).font(.caption)
                if reminders != nil { Toggle(t("到时响铃", "Ring when finished"), isOn: $ringOnStart) }
                if enteredDuration == nil {
                    Text(t("请输入有效时长；分和秒需在 0–59 之间。", "Enter a valid duration; minutes and seconds must be between 0 and 59.")).font(.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle(t("添加倒计时", "Add a timer"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(t("取消", "Cancel")) { adding = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("添加并开始", "Add and start")) {
                        guard let duration = enteredDuration else { return }
                        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        service.addTimer(label: label.isEmpty ? t("倒计时", "Timer") : label,
                                         duration: duration, ring: reminders != nil && ringOnStart)
                        adding = false
                    }.disabled(enteredDuration == nil || name.utf8.count > 256)
                        .accessibilityIdentifier("toolbox.timer.confirmAdd")
                }
            }
        }.presentationDetents([.medium, .large])
    }
    private func durationField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            TextField("0", text: text).multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
        }
    }
    private var enteredDuration: Double? {
        guard let h = Int(hours), let m = Int(minutes), let s = Int(seconds),
              (0...744).contains(h), (0...59).contains(m), (0...59).contains(s) else { return nil }
        let value = Double(h * 3600 + m * 60 + s)
        return value > 0 && value <= ToolboxCountdown.maximumDuration ? value : nil
    }
    private var recoveryNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(t("恢复的计时已暂停，请核对后继续。", "Recovered timers are paused. Check them before continuing."), systemImage: "clock.badge.exclamationmark")
            Button(t("知道了", "Got it")) { service.acknowledgeClockReview() }.frame(minHeight: 44)
        }.font(.callout)
    }
    private func issueNotice(_ issue: ToolboxClockIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(issueText(issue), systemImage: "exclamationmark.circle").font(.callout)
            if issue == .load {
                Button(t("重试读取", "Retry loading")) { Task { await service.load(reminders: reminders) } }.frame(minHeight: 44)
                Button(t("保留备份并重新开始", "Keep a backup and start again")) { rebuilding = true }.frame(minHeight: 44)
            } else {
                #if canImport(UIKit)
                if case .reminder(let detail) = issue, detail.isEmpty,
                   let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    Link(t("打开设置", "Open Settings"), destination: settingsURL)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("toolbox.timer.openSettings")
                }
                #endif
                Button(t("关闭提示", "Dismiss")) { service.issue = nil }.frame(minHeight: 44)
            }
        }.accessibilityIdentifier("toolbox.timer.issue")
    }
    private func issueText(_ issue: ToolboxClockIssue) -> String {
        switch issue {
        case .load: t("计时记录未能读取，原文件已保留。", "Timer records could not be read. The original file is preserved.")
        case .save: t("记录未能保存，本次计时仍保留在这里。", "Records could not be saved. This session is still here.")
        case .export: t("未能导出记录，请重试。", "The records could not be exported. Try again.")
        case .limit: t("已达到计时或分段数量上限。", "The timer or lap limit has been reached.")
        case .invalid: t("请检查计时名称或时长。", "Check the timer name and duration.")
        case .reminder(let detail): detail.isEmpty ? t("未能设置响铃，请在系统设置中允许闹钟。", "Allow alarms in system settings to enable ringing.") : detail
        }
    }
    private func csv(at now: ToolboxTimeSample) -> String {
        var rows = ["Kind,Name,SplitSeconds,ElapsedSeconds,DurationSeconds,RemainingSeconds,State"]
        rows.append("Stopwatch,,,\(service.state.stopwatch.elapsed(at: now)),,,\(service.state.stopwatch.running ? "running" : "paused")")
        rows += service.state.stopwatch.laps.enumerated().map { "Lap,\($0.offset + 1),\($0.element.split),\($0.element.elapsed),,," }
        for timer in service.state.timers {
            var label = timer.label.replacingOccurrences(of: "\"", with: "\"\"")
            if let first = label.first, "=+-@".contains(first) { label = "'" + label }
            rows.append("Timer,\"\(label)\",,,\(timer.duration),\(timer.remaining(at: now)),\(timer.phase.rawValue)")
        }
        return rows.joined(separator: "\n")
    }
    private var clockBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
    private var clockReadingBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

/// Clock labels need scheduled reads rather than a continuous animation driver.
/// A finite paused schedule keeps the same view hierarchy and scroll position.
private struct ToolboxClockTimeline: TimelineSchedule {
    let interval: TimeInterval
    let paused: Bool

    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        if paused { return AnySequence(CollectionOfOne(startDate)) }
        return AnySequence(PeriodicTimelineSchedule(from: startDate, by: interval)
            .entries(from: startDate, mode: mode))
    }
}

private struct ToolboxClockExport: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
