import SwiftUI
import AppKit
import Combine
import FloeMacMediaCore
import FloeMacMediaSystem

/// Native macOS sound analyzer: explicit start, live dBFS level, 40-band
/// spectrum, retained history and CSV export. dBFS values are relative digital
/// levels, never calibrated sound-pressure levels.
@MainActor
public struct MacToolboxSoundView: View {
    private let environment: MacToolboxMediaEnvironment
    @State private var session: MacSoundSession
    @State private var windowReference = MacMediaWindowReference()
    @State private var exportNote: String?
    @State private var exportFailure: String?

    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase

    public init(environment: MacToolboxMediaEnvironment? = nil) {
        let resolved = environment ?? .shared
        self.environment = resolved
        _session = State(initialValue: resolved.makeSoundSession())
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if showsPermissionCard { permissionCard }
                    meterCard
                    spectrumCard
                    historyCard
                    if let failure = session.streamFailure, failure != .notAuthorized {
                        failureCard(failure)
                    }
                    if let exportFailure {
                        Label(exportFailure, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if let exportNote {
                        Label(exportNote, systemImage: "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            controlBar
        }
        .navigationTitle(macToolboxText("声音分析", "Sound Analyzer", locale))
        .background(MacMediaWindowTracker(reference: windowReference))
        .onDisappear { session.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            // A system permission sheet also deactivates the app; never tear the
            // start down while that prompt is legitimately pending.
            if !session.awaitingPermissionPrompt { session.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { notification in
            if windowReference.contains(notification) { session.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if windowReference.contains(notification) { session.stop() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(macToolboxText("声音分析", "Sound Analyzer", locale))
                .font(.largeTitle.weight(.semibold))
            Text(macToolboxText(
                "按下开始后才请求麦克风权限并采样；停止、关闭窗口或切换应用时立即释放设备。",
                "The microphone is requested and sampled only after you press Start; stopping, closing the window, or switching away releases the device immediately.",
                locale
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            Label(macToolboxText(
                "读数为相对数字满刻度 dBFS，不是校准声压级。",
                "Readings are relative digital full-scale dBFS, not calibrated sound pressure.",
                locale
            ), systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var showsPermissionCard: Bool {
        session.authorization == .denied || session.authorization == .restricted
            || session.streamFailure == .notAuthorized
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(macToolboxText("需要麦克风权限", "Microphone Access Needed", locale),
                  systemImage: "mic.slash")
                .font(.headline)
            Text(macToolboxText(
                "请在“系统设置 › 隐私与安全性 › 麦克风”中允许 Floe 访问，然后重新开始。",
                "Allow Floe under System Settings › Privacy & Security › Microphone, then start again.",
                locale
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            Button(macToolboxText("打开系统设置", "Open System Settings", locale)) {
                macOpenPrivacySettings(.microphone)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("mac.toolbox.sound.openSettings")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("mac.toolbox.sound.denied")
    }

    private var meterCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(macToolboxText("电平", "Level", locale), systemImage: "waveform")
                    .font(.headline)
                Spacer()
                Text(levelText)
                    .font(.system(.title3, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(session.levelDBFS == nil ? .secondary : .primary)
            }
            levelBar(value: normalizedDB(session.levelDBFS), height: 16)
            HStack {
                Text(macToolboxText("峰值", "Peak", locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(peakText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(macToolboxText("主频", "Dominant", locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(dominantText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("mac.toolbox.sound.meter")
    }

    private var spectrumCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(macToolboxText("频谱", "Spectrum", locale), systemImage: "chart.bar")
                .font(.headline)
            if let spectrum = session.spectrum, !spectrum.bands.isEmpty {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(spectrum.bands.enumerated()), id: \.offset) { _, band in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.tint)
                            .frame(maxWidth: .infinity)
                            .frame(height: max(2, CGFloat(band) * 140))
                    }
                }
                .frame(height: 140, alignment: .bottom)
                .accessibilityLabel(macToolboxText("实时频谱", "Live spectrum", locale))
                HStack {
                    Text("\(Int(spectrum.bandFrequencies.first ?? 20)) Hz")
                    Spacer()
                    Text("\(Int(spectrum.bandFrequencies.last ?? 16_000)) Hz")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text(macToolboxText("开始后显示 20 Hz 至 16 kHz 的实时频段。",
                                    "Start measurement to see live bands from 20 Hz to 16 kHz.", locale))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(macToolboxText("记录", "History", locale), systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Text(macToolboxText("\(session.history.count) / \(session.historyCapacity) 条",
                                    "\(session.history.count) / \(session.historyCapacity) samples", locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if session.history.isEmpty {
                Text(macToolboxText("尚无记录。记录之间保持约 5 帧的抽样间隔。",
                                    "No samples yet. History is sampled about every fifth frame.", locale))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                SoundHistoryLine(samples: session.history)
                    .frame(height: 64)
                    .accessibilityLabel(macToolboxText("声音记录曲线", "Sound history line", locale))
                if session.droppedHistoryCount > 0 {
                    Text(macToolboxText("较早记录已按上限移除 \(session.droppedHistoryCount) 条。",
                                        "\(session.droppedHistoryCount) older samples were removed by the rolling limit.", locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func failureCard(_ failure: MacMediaFailure) -> some View {
        Label(macMediaFailureText(failure, locale), systemImage: "exclamationmark.triangle")
            .font(.callout)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 12) {
            if session.isActive {
                Button {
                    session.stop()
                } label: {
                    Label(macToolboxText("停止", "Stop", locale), systemImage: "stop.fill")
                        .frame(minWidth: 88, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(".", modifiers: .command)
                .accessibilityIdentifier("mac.toolbox.sound.stop")
            } else {
                Button {
                    start()
                } label: {
                    Label(macToolboxText("开始", "Start", locale), systemImage: "play.fill")
                        .frame(minWidth: 88, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityIdentifier("mac.toolbox.sound.start")
            }
            Button(macToolboxText("重置", "Reset", locale)) { session.reset() }
                .disabled(session.history.isEmpty && session.levelDBFS == nil)
                .accessibilityIdentifier("mac.toolbox.sound.reset")
            Spacer()
            Text(macToolboxText("输入 \(session.isMicrophoneAvailable ? "可用" : "不可用")",
                                session.isMicrophoneAvailable ? "Input available" : "No input",
                                locale))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                exportCSV()
            } label: {
                Label(macToolboxText("导出 CSV", "Export CSV", locale), systemImage: "square.and.arrow.down")
            }
            .disabled(session.history.isEmpty)
            .accessibilityIdentifier("mac.toolbox.sound.export")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Actions

    private func start() {
        exportNote = nil
        exportFailure = nil
        Task {
            let started = await session.start()
            // A permission prompt can leave the app inactive; if it granted
            // while the app is no longer frontmost, do not keep sampling.
            if started, !NSApp.isActive {
                session.stop()
            }
        }
    }

    private func exportCSV() {
        exportNote = nil
        exportFailure = nil
        let data = Data(session.makeCSV().utf8)
        let artifact = MacExportArtifact(
            format: .csv,
            data: data,
            suggestedFilename: MacExportNaming.suggestedName(format: .csv, prefix: "floe-sound")
        )
        do {
            if let url = try environment.exporter.save(artifact) {
                exportNote = macToolboxText("已保存到 \(url.lastPathComponent)。",
                                            "Saved as \(url.lastPathComponent).", locale)
            }
        } catch {
            exportFailure = macMediaFailureText((error as? MacMediaFailure) ?? .writeFailed("io"), locale)
        }
    }

    // MARK: - Display helpers

    private var levelText: String {
        guard let level = session.levelDBFS else { return "—" }
        return String(format: "%.1f dBFS", level)
    }

    private var peakText: String {
        guard let peak = session.peakDBFS else { return "—" }
        return String(format: "%.1f", peak)
    }

    private var dominantText: String {
        guard let frequency = session.dominantFrequency else { return "—" }
        return String(format: "%.0f Hz", frequency)
    }

    private func normalizedDB(_ value: Double?) -> Double {
        guard let value else { return 0 }
        return min(max((value + 100) / 100, 0), 1)
    }

    private func levelBar(value: Double, height: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(value > 0.94 ? Color.red : Color.accentColor)
                    .frame(width: max(0, geometry.size.width * value))
            }
        }
        .frame(height: height)
        .accessibilityValue("\(Int(value * 100))%")
    }
}

/// Compact history line; deterministic and free of any chart dependency.
struct SoundHistoryLine: View {
    let samples: [MacSoundSample]

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard samples.count > 1 else { return }
                let width = geometry.size.width
                let height = geometry.size.height
                for (index, sample) in samples.enumerated() {
                    let x = width * CGFloat(index) / CGFloat(samples.count - 1)
                    let normalized = min(max((sample.levelDBFS + 100) / 100, 0), 1)
                    let y = height * (1 - CGFloat(normalized))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
