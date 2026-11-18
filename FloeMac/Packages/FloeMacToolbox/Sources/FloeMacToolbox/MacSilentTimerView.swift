// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeToolboxUtilities

struct MacSilentTimerView: View {
    @ObservedObject var service: MacSilentTimekeeping
    @Environment(\.locale) private var locale
    @State private var name = ""
    @State private var minutes = 5
    @State private var confirmUnconfirmedExit = false

    private func t(_ zh: String, _ en: String) -> String { MacToolboxText.t(zh, en, locale) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let sample = ToolboxTimeSample.now
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(t("秒表与倒计时", "Stopwatch and timers")).font(.title2.weight(.semibold))
                    Text(t("当前版本为静音计时，不会发送通知。关闭工具箱窗口后仍会计时；重新打开应用后可恢复记录。",
                           "Timers are silent in this version and do not send notifications. They continue when the toolbox window closes; saved records can be restored when the app reopens."))
                        .foregroundStyle(.secondary)
                    if service.loading { ProgressView(t("正在读取记录", "Loading records")) }
                    if service.archive.clockReview {
                        Label(t("系统时钟发生变化，请检查计时结果。", "The system clock changed. Check your timers."), systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                    if let issue = service.issue { issueView(issue) }
                    stopwatch(sample)
                    Divider()
                    HStack {
                        TextField(t("倒计时名称", "Timer name"), text: $name).textFieldStyle(.roundedBorder)
                        Stepper("\(minutes) \(t("分钟", "min"))", value: $minutes, in: 1...1_440)
                        Button(t("添加", "Add")) {
                            service.addTimer(name: name.trimmingCharacters(in: .whitespacesAndNewlines), seconds: Double(minutes * 60))
                        }.disabled(!service.loaded || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ForEach(service.archive.timers) { timer in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(timer.label)
                                Text(ToolboxTimeText.duration(timer.remaining(at: sample)))
                                    .font(.system(.title3, design: .monospaced))
                            }
                            Spacer()
                            if timer.phase != .finished {
                                Button(timer.phase == .running ? t("暂停", "Pause") : t("继续", "Resume")) {
                                    if timer.phase == .running { service.pause(timer.id) } else { service.resume(timer.id) }
                                }
                            } else { Text(t("已结束", "Finished")).foregroundStyle(.secondary) }
                            Button(t("删除", "Delete"), role: .destructive) { service.remove(timer.id) }
                        }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if service.saving { ProgressView(t("正在保存", "Saving")).controlSize(.small) }
                }.padding(24).frame(maxWidth: 920, alignment: .leading)
            }
        }
        .task { await service.load() }
        .confirmationDialog(t("允许退出？", "Allow quit?"), isPresented: $confirmUnconfirmedExit, titleVisibility: .visible) {
            Button(t("允许退出", "Allow quit"), role: .destructive) { service.allowExitWithoutConfirmedSave() }
            Button(t("取消", "Cancel"), role: .cancel) { }
        } message: {
            Text(t("最近的计时更改未能确认保存。退出可能丢失这些更改；原记录不会被删除。",
                   "Recent timer changes could not be confirmed saved. Quitting may lose them; the existing archive will not be deleted."))
        }
    }

    private func stopwatch(_ sample: ToolboxTimeSample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("秒表", "Stopwatch")).font(.headline)
            Text(ToolboxTimeText.duration(service.archive.stopwatch.elapsed(at: sample)))
                .font(.system(.largeTitle, design: .monospaced))
            HStack {
                Button(service.archive.stopwatch.running ? t("暂停", "Pause") : t("开始", "Start")) {
                    if service.archive.stopwatch.running { service.pauseStopwatch() } else { service.startStopwatch() }
                }
                Button(t("分段", "Lap")) { service.lap() }.disabled(!service.archive.stopwatch.running)
                Button(t("重置", "Reset")) { service.resetStopwatch() }
            }.disabled(!service.loaded)
            ForEach(Array(service.archive.stopwatch.laps.enumerated()), id: \.element.id) { index, lap in
                Text("\(index + 1)  \(ToolboxTimeText.duration(lap.split))  /  \(ToolboxTimeText.duration(lap.elapsed))")
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder private func issueView(_ issue: MacSilentTimekeeping.Issue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch issue {
            case .load:
                Text(t("无法读取计时记录，原文件已保留。", "Timer records could not be read. The original file was preserved."))
                Button(t("重试读取", "Retry loading")) { Task { await service.load() } }
            case .save:
                Text(t("无法确认更改是否保存。请重试，或明确允许退出。", "Could not confirm that changes were saved. Retry, or explicitly allow quitting."))
                HStack {
                    Button(t("重试保存", "Retry saving")) { service.retrySave() }
                    Button(t("允许退出…", "Allow quit…")) { confirmUnconfirmedExit = true }
                }
            case .limit: Text(t("已达到计时数量或记录上限。", "The timer or history limit was reached."))
            case .invalid: Text(t("计时设置无效，请检查输入。", "The timer settings are invalid."))
            }
        }.foregroundStyle(.orange)
    }
}
