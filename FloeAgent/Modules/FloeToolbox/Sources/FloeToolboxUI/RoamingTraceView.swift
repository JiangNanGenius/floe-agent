import Foundation
import SwiftUI
import FloeToolboxCore


/// A presentation of host-owned measurements. No timers, entitlements or network calls live in this view.
public struct RoamingTraceView: View {
    @Environment(\.locale) private var toolboxLocale
    private func roamingText(_ zh: String,_ en: String) -> String { toolboxLocale.language.languageCode?.identifier == "zh" ? zh : en }
    private let snapshot: RoamingSnapshot
    private let isRecording: Bool
    private let onStart: (String, Double) -> Void
    private let onStop: () -> Void
    private let onExport: () -> Void
    private let defaultGateway: String?
    @State private var target: String
    @State private var interval: Double
    public init(snapshot: RoamingSnapshot, isRecording: Bool, onStart: @escaping (String,Double) -> Void,
                onStop: @escaping () -> Void, onExport: @escaping () -> Void, defaultGateway: String? = nil) {
        self.snapshot = snapshot; self.isRecording = isRecording; self.onStart = onStart; self.onStop = onStop; self.onExport = onExport
        _target = State(initialValue:snapshot.configuration.target); _interval = State(initialValue:snapshot.configuration.probeInterval)
        self.defaultGateway = defaultGateway
    }
    public var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(roamingText("漫游追踪","Roaming trace")).font(.title2)
            TextField(roamingText("探测目标","Probe target"),text:$target).textFieldStyle(.roundedBorder).disabled(isRecording)
                .accessibilityIdentifier("toolbox.roaming.target")
            if let defaultGateway {
                Button(roamingText("使用当前网关", "Use current gateway")) { target = defaultGateway }
                    .disabled(isRecording)
            }
            Picker(roamingText("Ping 间隔","Ping interval"),selection:$interval) {
                Text(roamingText("1 秒","1 second")).tag(1.0)
                Text(roamingText("2 秒","2 seconds")).tag(2.0)
                Text(roamingText("5 秒","5 seconds")).tag(5.0)
                if ![1.0,2.0,5.0].contains(interval) {
                    Text(String(format:"%.1f",interval)+" "+roamingText("秒","seconds")).tag(interval)
                }
            }.disabled(isRecording)
            HStack {
                if isRecording { Button(roamingText("停止追踪","Stop trace"),action:onStop).accessibilityIdentifier("toolbox.roaming.stop") }
                else { Button(roamingText("开始追踪","Start trace")) { onStart(target.trimmingCharacters(in: .whitespacesAndNewlines),interval) }.disabled(target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("toolbox.roaming.start") }
                Button(roamingText("导出记录","Export trace"),action:onExport).disabled(snapshot.samples.isEmpty)
                    .accessibilityIdentifier("toolbox.roaming.export")
            }
            LabeledContent(roamingText("接入点变化","AP changes"),value:String(snapshot.totalAccessPointChanges))
            LabeledContent(roamingText("平均延迟（当前窗口）","Mean latency (current window)"),
                           value:snapshot.meanLatencyMilliseconds.map { String(format:"%.1f ms",$0) } ?? "—")
            LabeledContent(roamingText("丢包（当前窗口）","Packet loss (current window)"),
                           value:snapshot.packetLoss.map { String(format:"%.1f%%",$0*100) } ?? "—")
            if let last = snapshot.samples.last(where: { $0.observation.status != .notObserved })?.observation, last.bssid == nil {
                Text(roamingText("接入点信息不可用；连通性探测仍可记录。","AP information is unavailable; connectivity probes can still be recorded.")).font(.caption).foregroundStyle(.secondary)
            }
            if snapshot.droppedSamples > 0 || snapshot.droppedEvents > 0 {
                Text(roamingText("较早记录已按滚动上限移除。","Older entries were removed by the rolling limit.")).font(.caption).foregroundStyle(.secondary)
            }
            List {
                if snapshot.samples.isEmpty { Text(roamingText("开始后查看接入点变化、延迟和丢包。","Start to see AP changes, latency and packet loss.")).foregroundStyle(.secondary) }
                ForEach(snapshot.events.reversed()) { event in
                    VStack(alignment:.leading,spacing:4) {
                        Text(eventTitle(event.kind))
                        Text(event.observedAt.formatted(date:.omitted,time:.standard)).font(.caption).foregroundStyle(.secondary)
                        if let from = event.fromBSSID, let to = event.toBSSID {
                            Text("\(from) → \(to)").font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                        }
                    }
                }
                ForEach(snapshot.samples.reversed()) { sample in
                    VStack(alignment:.leading,spacing:4) {
                        HStack {
                            Text(sample.observation.timestamp.formatted(date:.omitted,time:.standard)).font(.caption)
                            Spacer(); Text(probeText(sample.observation.probe)).font(.caption.monospacedDigit())
                        }
                        Text(sample.observation.bssid ?? (sample.observation.status == .notObserved ? roamingText("连通性探测","Connectivity probe") : roamingText("接入点未知","AP unknown"))).font(.system(.caption,design:.monospaced))
                        if let signal = sample.observation.signalDBM { Text("\(signal) dBm").font(.caption) }
                    }
                }
            }
            Text(roamingText("按采样观察切换，不推算精确漫游时长。","Changes are observed between samples; exact handoff duration is not inferred.")).font(.caption).foregroundStyle(.secondary)
        }.padding()
    }
    private func eventTitle(_ kind: RoamingEvent.Kind) -> String {
        switch kind {
        case .accessPointChanged: roamingText("接入点变化","Access point changed")
        case .networkChanged: roamingText("Wi-Fi 网络变化","Wi-Fi network changed")
        case .identityUnavailable: roamingText("接入点信息不可用","AP information unavailable")
        case .identityRestored: roamingText("恢复接入点观察","AP observation resumed")
        case .observationGap: roamingText("采样中断，期间切换未知","Observation gap; changes during the gap are unknown")
        }
    }
    private func probeText(_ result: RoamingProbeResult) -> String {
        switch result {
        case .reply(let ms): String(format:"%.1f ms",ms)
        case .timeout: roamingText("超时","Timeout")
        case .notAttempted: roamingText("未探测","Not probed")
        }
    }
}
