import SwiftUI
import UniformTypeIdentifiers
import FloeToolboxUtilities

/// CSV export payload for the sound analyzer. Sharing stays user-driven.
public struct ToolboxSoundExportDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    public let text: String
    public init(text: String) { self.text = text }
    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let decoded = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderReadCorrupt)
        }
        text = decoded
    }
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Microphone sound analyzer with an explicit start. The host may inject its
/// audio-session lease (`acquireAudio` must run before capture starts and throw
/// to refuse — for example while Picture in Picture holds the session); the view
/// stops the engine first and releases the lease on every stop path. Levels are
/// relative digital full-scale values (dBFS), never calibrated sound pressure.
@MainActor public struct ToolboxSoundView: View {
    private let acquireAudio: (@MainActor () throws -> Void)?
    private let releaseAudio: (@MainActor () -> Void)?

    /// Standalone preview: the service owns a local audio session conservatively.
    public init() {
        self.init(acquireAudio: nil, releaseAudio: nil)
    }

    /// Host-lease integration: `acquireAudio` runs on explicit start before any
    /// engine/session mutation and throws to refuse; `releaseAudio` runs after
    /// the engine has stopped on every stop/error/disappear path.
    public init(acquireAudio: (@MainActor () throws -> Void)?,
                releaseAudio: (@MainActor () -> Void)?) {
        self.acquireAudio = acquireAudio
        self.releaseAudio = releaseAudio
    }

    #if os(iOS)
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @State private var leaseHeld = false
    @State private var hostError: String?
    @State private var startError: ToolboxSoundError?
    @State private var isMounted = false
    /// Invalidates a pending permission-gated start on exit/background.
    @State private var lifecycleGeneration = 0
    @State private var exportDocument: ToolboxSoundExportDocument?
    @State private var exporting = false

    private var service: ToolboxSoundService { .shared }
    private var running: Bool { service.phase == .running || service.phase == .starting }

    public var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 680 && geometry.size.width > geometry.size.height
            Group {
                if wide {
                    HStack(spacing: 0) {
                        spectrumPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        ScrollView { sidePanel.padding(24) }.frame(width: 320)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            spectrumPanel.frame(minHeight: 320)
                            sidePanel.padding(.horizontal, 20)
                        }.padding(.vertical, 20)
                    }
                }
            }
        }
        .background(.background)
        .navigationTitle(workbenchText("声音分析", "Sound Analyzer", locale))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controlBar
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
        }
        .fileExporter(isPresented: $exporting, document: exportDocument,
                      contentType: .commaSeparatedText,
                      defaultFilename: workbenchText("声音分析记录", "sound-analysis", locale)) { _ in }
        .onAppear {
            isMounted = true
            service.refreshAuthorization()
        }
        .onDisappear {
            isMounted = false
            lifecycleGeneration += 1
            exitMeasurement()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                lifecycleGeneration += 1
                exitMeasurement()
            }
        }
        .onChange(of: service.phase) { _, phase in
            // The service stopped itself (error, route change, media reset):
            // the engine is already down, so the lease can go back to the host.
            if phase == .idle { releaseLease() }
        }
    }

    // MARK: - Measurement lifecycle

    private func startTapped() {
        hostError = nil
        startError = nil
        guard service.authorization == .granted else {
            let request = lifecycleGeneration
            Task {
                let granted = await service.requestAuthorization()
                // The system permission sheet leaves the app inactive, not
                // backgrounded; only a real exit/background invalidates the
                // pending start.
                guard granted, isMounted, request == lifecycleGeneration,
                      scenePhase != .background else { return }
                beginMeasurement()
            }
            return
        }
        beginMeasurement()
    }

    private func beginMeasurement() {
        guard !leaseHeld, service.phase == .idle else { return }
        do {
            try acquireAudio?()
        } catch {
            hostError = error.localizedDescription
            return
        }
        leaseHeld = true
        do {
            try service.start(sessionOwnership: acquireAudio == nil ? .standalone : .hostManaged)
        } catch let error as ToolboxSoundError {
            startError = error
            releaseLease()
        } catch {
            startError = .invalidInputFormat
            releaseLease()
        }
    }

    /// Explicit user Stop: a deliberate global pause of the shared instrument.
    private func stopMeasurement() {
        service.pause()
        releaseLease()
    }

    /// Lifecycle exit (disappear/background): only the lease-owning view may
    /// stop capture — a second window that never held the lease must not
    /// silently stop another window's measurement.
    private func exitMeasurement() {
        guard leaseHeld else { return }
        service.pause()
        releaseLease()
    }

    private func releaseLease() {
        guard leaseHeld else { return }
        leaseHeld = false
        releaseAudio?()
    }

    // MARK: - Panels

    private var spectrumPanel: some View {
        VStack(spacing: 20) {
            SpectrumChart(spectrum: service.spectrum, active: running)
            Text(workbenchText("频谱（相对幅度）", "Spectrum (relative magnitude)", locale))
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            levelMeter
        }
        .padding(20)
        .accessibilityElement(children: .contain)
    }

    private var levelMeter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(workbenchText("相对电平", "Relative level", locale))
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(service.levelDBFS.map { String(format: "%.0f dBFS", $0) } ?? "—")
                    .font(.system(.title3, design: .monospaced))
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                let level = service.levelDBFS ?? EnvironmentalSignalMath.dbFloor
                let fraction = min(max((level + 60) / 60, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.5))
                    Capsule().fill(.blue)
                        .frame(width: max(proxy.size.width * fraction, service.levelDBFS == nil ? 0 : 4))
                }
            }
            .frame(height: 12)
            .accessibilityHidden(true)
            HStack {
                Text("-60").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text("0 dBFS").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(workbenchText("电平为相对数字电平（dBFS），未经声压级校准，不代表环境声压级。",
                               "Levels are relative digital full-scale values (dBFS), without sound-pressure calibration. They do not measure environmental sound pressure levels.",
                               locale))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(workbenchText("相对电平", "Relative level", locale))
        .accessibilityValue(Text(service.levelDBFS.map { String(format: "%.0f dBFS", $0) }
                                    ?? workbenchText("无读数", "no reading", locale)))
        .accessibilityHint(workbenchText("未经声压级校准，不代表环境声压级。",
                                        "Uncalibrated; does not measure environmental sound pressure levels.", locale))
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            stateNote
            readouts
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var stateNote: some View {
        if let hostError {
            Label(hostError, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("toolbox.sound.hosterror")
        } else if service.authorization == .denied {
            Label(workbenchText("没有麦克风权限，请在系统设置中允许后重试。", "Microphone access is denied. Allow it in Settings and try again.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("toolbox.sound.denied")
        } else if startError == .microphoneNotAuthorized {
            Label(workbenchText("没有麦克风权限，请在系统设置中允许后重试。", "Microphone access is denied. Allow it in Settings and try again.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if startError == .microphoneUnavailable {
            Label(workbenchText("未检测到可用的麦克风输入。", "No microphone input is available.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if startError != nil {
            Label(workbenchText("音频采集无法开始，请重试。", "Audio capture could not start. Try again.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let streamError = service.streamError {
            Label(workbenchText("音频采集已停止，请重试。", "Audio capture stopped. Try again.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHint(Text(streamError))
        } else if service.isInterrupted {
            Label(workbenchText("音频被中断，等待恢复。", "Audio was interrupted. Waiting to resume.", locale),
                  systemImage: "phone.down")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        } else if !running, service.history.isEmpty, service.levelDBFS == nil {
            Label(workbenchText("点“开始”后才会采集麦克风。", "The microphone starts only after you tap Start.", locale),
                  systemImage: "mic")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !running {
            Label(workbenchText("已暂停，记录保留。", "Paused. Retained samples are kept.", locale),
                  systemImage: "pause.circle")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        } else if service.levelDBFS == EnvironmentalSignalMath.dbFloor {
            Label(workbenchText("未检测到声音信号。", "No sound signal detected.", locale),
                  systemImage: "waveform")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    dominantReading
                    peakReading
                }
                VStack(alignment: .leading, spacing: 16) {
                    dominantReading
                    peakReading
                }
            }
            if service.history.droppedCount > 0 {
                Text(workbenchText("记录保留最近约 5 分钟的采样。", "The record keeps about the last 5 minutes of samples.", locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var dominantReading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(workbenchText("主要频率", "Dominant frequency", locale))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(service.dominantFrequency.map { String(format: "%.0f", $0) } ?? "—")
                .font(.system(.largeTitle, design: .monospaced))
                .monospacedDigit()
            Text(service.dominantFrequency == nil && running
                 ? workbenchText("未检测到明显频率", "No clear tone detected", locale)
                 : "Hz")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(workbenchText("主要频率", "Dominant frequency", locale))
        .accessibilityValue(Text(service.dominantFrequency.map { String(format: "%.0f hertz", $0) }
                                    ?? workbenchText("无", "none", locale)))
    }

    private var peakReading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(workbenchText("峰值（本次）", "Peak (session)", locale))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(service.peakDBFS.map { String(format: "%.1f", $0) } ?? "—")
                .font(.system(.largeTitle, design: .monospaced))
                .monospacedDigit()
            Text("dBFS")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(workbenchText("峰值", "Peak", locale))
        .accessibilityValue(Text(service.peakDBFS.map { String(format: "%.1f dBFS", $0) }
                                    ?? workbenchText("无读数", "no reading", locale)))
    }

    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                startButton
                controlButton(title: workbenchText("重置", "Reset", locale), systemImage: "arrow.counterclockwise",
                              disabled: service.history.isEmpty && service.peakDBFS == nil) {
                    service.reset()
                }
                .accessibilityIdentifier("toolbox.sound.reset")
                Spacer(minLength: 8)
                controlButton(title: workbenchText("导出 CSV", "Export CSV", locale), systemImage: "square.and.arrow.up",
                              disabled: service.history.isEmpty) {
                    exportDocument = ToolboxSoundExportDocument(text: service.makeCSV())
                    exporting = true
                }
                .accessibilityIdentifier("toolbox.sound.export")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    startButton
                    controlButton(title: workbenchText("重置", "Reset", locale), systemImage: "arrow.counterclockwise",
                                  disabled: service.history.isEmpty && service.peakDBFS == nil) {
                        service.reset()
                    }
                }
                controlButton(title: workbenchText("导出 CSV", "Export CSV", locale), systemImage: "square.and.arrow.up",
                              disabled: service.history.isEmpty) {
                    exportDocument = ToolboxSoundExportDocument(text: service.makeCSV())
                    exporting = true
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var startButton: some View {
        controlButton(title: running ? workbenchText("停止", "Stop", locale) : workbenchText("开始", "Start", locale),
                      systemImage: running ? "stop.fill" : "play.fill",
                      disabled: service.authorization == .denied) {
            if running {
                stopMeasurement()
            } else {
                startTapped()
            }
        }
        .accessibilityIdentifier("toolbox.sound.start")
    }

    private func controlButton(title: String, systemImage: String, disabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body)
                .frame(minHeight: 44)
                .padding(.horizontal, 14)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
    }
    #else
    @Environment(\.locale) private var locale

    public var body: some View {
        EnvironmentalUnavailableSurface(
            title: workbenchText("声音分析", "Sound Analyzer", locale),
            message: workbenchText("此平台不提供麦克风分析，声音分析不可用。", "This platform does not provide microphone analysis, so the sound analyzer is not available.", locale),
            systemImage: "waveform"
        )
        .navigationTitle(workbenchText("声音分析", "Sound Analyzer", locale))
    }
    #endif
}

#if os(iOS)
/// Log-spaced spectrum bars with honest empty/placeholder states.
private struct SpectrumChart: View {
    let spectrum: ToolboxSoundSpectrum?
    let active: Bool

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 4, y: 4, width: size.width - 8, height: size.height - 8)
            guard let spectrum, !spectrum.bands.isEmpty else {
                var placeholder = Path()
                placeholder.move(to: CGPoint(x: plot.minX, y: plot.maxY))
                placeholder.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                context.stroke(placeholder, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                return
            }
            let count = spectrum.bands.count
            let slot = plot.width / CGFloat(count)
            for (index, value) in spectrum.bands.enumerated() where value > 0 {
                let height = max(CGFloat(value) * plot.height, 2)
                let bar = CGRect(x: plot.minX + CGFloat(index) * slot + slot * 0.15,
                                 y: plot.maxY - height,
                                 width: slot * 0.7,
                                 height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(.blue))
            }
            var baseline = Path()
            baseline.move(to: CGPoint(x: plot.minX, y: plot.maxY))
            baseline.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
            context.stroke(baseline, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
        }
        .frame(minHeight: 160)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .opacity(active ? 1 : 0.75)
        .accessibilityHidden(true)
    }
}
#endif
