import SwiftUI
import UniformTypeIdentifiers
import FloeToolboxUtilities

/// CSV export payload for the barometer. Sharing stays user-driven.
public struct ToolboxPressureExportDocument: FileDocument {
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

/// Barometric altimeter: live pressure, relative altitude, zero reference,
/// retained extrema and a bounded trend. Readings are honest relative values —
/// pressure in hPa and pressure-derived altitude relative to the zero baseline,
/// never an invented absolute altitude or GPS floor.
@MainActor public struct ToolboxPressureView: View {
    public init() {}

    #if os(iOS)
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @State private var userPaused = false
    /// True only while this view owns the shared stream, so a second window's
    /// exit can never stop another window's measurement.
    @State private var ownsStream = false
    @State private var exportDocument: ToolboxPressureExportDocument?
    @State private var exporting = false

    private var service: ToolboxPressureService { .shared }
    private var available: Bool { service.isAvailable }
    private var running: Bool { service.phase == .running || service.phase == .starting }
    private var sample: ToolboxPressureSample? { service.latest }

    public var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 680 && geometry.size.width > geometry.size.height
            Group {
                if wide {
                    HStack(spacing: 0) {
                        chartPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        ScrollView { sidePanel.padding(24) }.frame(width: 320)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            chartPanel.frame(height: 380)
                            sidePanel.padding(.horizontal, 20)
                        }.padding(.vertical, 20)
                    }
                }
            }
        }
        .background(.background)
        .navigationTitle(workbenchText("气压高度仪", "Barometric Altimeter", locale))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controlBar
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
        }
        .fileExporter(isPresented: $exporting, document: exportDocument,
                      contentType: .commaSeparatedText,
                      defaultFilename: workbenchText("气压高度记录", "pressure-altitude", locale)) { _ in }
        .onAppear {
            service.refreshAuthorization()
            startIfNeeded()
        }
        .onDisappear(perform: pause)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { startIfNeeded() } else { pause() }
        }
    }

    private func startIfNeeded() {
        // The service stops itself on delivery errors; drop stale ownership then.
        if ownsStream, !running { ownsStream = false }
        guard available, !userPaused, !running, !ownsStream else { return }
        service.start()
        ownsStream = service.phase == .running || service.phase == .starting
    }

    private func pause() {
        guard ownsStream else { return }
        ownsStream = false
        service.pause()
    }

    private var chartPanel: some View {
        VStack(spacing: 20) {
            PressureCurveChart(
                title: workbenchText("相对高度", "Relative altitude", locale),
                unit: "m",
                values: service.history.values.map { $0.altitude },
                active: running,
                zeroCentered: true)
            PressureCurveChart(
                title: workbenchText("气压", "Pressure", locale),
                unit: "hPa",
                values: service.history.values.map { $0.pressureHpa },
                active: running,
                zeroCentered: false)
            if let caption = referenceCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .accessibilityElement(children: .contain)
    }

    /// ISA pressure-trend conversion, clearly labeled as a reference only.
    private var referenceCaption: String? {
        guard let first = service.history.values.first,
              let last = service.history.values.last,
              let difference = EnvironmentalSignalMath.standardAtmosphereAltitudeDifference(
                pressureHpa: last.pressureHpa, referenceHpa: first.pressureHpa),
              abs(difference) >= 1 else { return nil }
        return workbenchText(
            "气压变化约相当于 \(String(format: "%+.1f", difference)) m 高度差（标准大气参考换算，非实测海拔）。",
            "The pressure change equals about \(String(format: "%+.1f", difference)) m of altitude difference (standard-atmosphere reference, not measured elevation).",
            locale)
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            stateNote
            readouts
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var stateNote: some View {
        if !available {
            Label(workbenchText("此设备没有气压计，无法使用气压高度仪。", "This device has no barometer, so the barometric altimeter cannot measure.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("toolbox.pressure.unavailable")
        } else if service.authorization == .denied || service.authorization == .restricted {
            Label(workbenchText("没有气压传感器权限，请在系统设置中允许后重试。", "Barometer access is denied. Allow it in Settings and try again.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("toolbox.pressure.denied")
        } else if service.streamError != nil {
            Label(workbenchText("气压传感器暂时不可用，请稍后重试。", "The barometer is temporarily unavailable. Try again shortly.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !running {
            Label(workbenchText("已暂停，趋势与记录保留。", "Paused. The trend and retained samples are kept.", locale),
                  systemImage: "pause.circle")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        } else if service.isZeroed {
            Label(workbenchText("已按当前位置归零", "Zeroed to the current position", locale), systemImage: "record.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 16) {
            primaryReadings
            extremaReadings
        }
        .accessibilityElement(children: .contain)
    }

    /// Short readings share a row when width and content allow; long values and
    /// accessibility sizes fall back to a single column.
    private var primaryReadings: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                pressureReading
                altitudeReading
            }
            VStack(alignment: .leading, spacing: 16) {
                pressureReading
                altitudeReading
            }
        }
    }

    private var pressureReading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(workbenchText("气压", "Pressure", locale)).font(.subheadline).foregroundStyle(.secondary)
            Text(sample.map { String(format: "%.1f", $0.pressureHpa) } ?? "—")
                .font(.system(.largeTitle, design: .monospaced))
                .monospacedDigit()
            if let kilopascals = sample.flatMap({ EnvironmentalSignalMath.kilopascals(fromHectopascals: $0.pressureHpa) }) {
                Text(String(format: "%.3f kPa", kilopascals))
                    .font(.callout.monospaced())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(workbenchText("气压", "Pressure", locale))
        .accessibilityValue(Text(sample.map { String(format: "%.1f hectopascals", $0.pressureHpa) }
                                    ?? workbenchText("无读数", "no reading", locale)))
    }

    private var altitudeReading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(service.isZeroed
                 ? workbenchText("相对高度（已归零）", "Relative altitude (zeroed)", locale)
                 : workbenchText("相对高度", "Relative altitude", locale))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(service.displayedAltitude.map { String(format: "%+.2f", $0) } ?? "—")
                .font(.system(.largeTitle, design: .monospaced))
                .monospacedDigit()
            Text("m")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(workbenchText("相对高度", "Relative altitude", locale))
        .accessibilityValue(Text(service.displayedAltitude.map { String(format: "%.2f meters", $0) }
                                    ?? workbenchText("无读数", "no reading", locale)))
    }

    private var extremaReadings: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let minimum = service.minimumAltitude, let maximum = service.maximumAltitude {
                LabeledContent(workbenchText("高度范围（本次）", "Altitude range (session)", locale)) {
                    Text(String(format: "%+.2f … %+.2f m", minimum, maximum))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if let minimum = service.minimumPressureHpa, let maximum = service.maximumPressureHpa {
                LabeledContent(workbenchText("气压范围（本次）", "Pressure range (session)", locale)) {
                    Text(String(format: "%.1f … %.1f hPa", minimum, maximum))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if service.history.droppedCount > 0 {
                Text(workbenchText("趋势保留最近约 20 分钟的采样。", "The trend keeps about the last 20 minutes of samples.", locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                controlButton(title: running ? workbenchText("暂停", "Pause", locale) : workbenchText("开始", "Start", locale),
                              systemImage: running ? "pause.fill" : "play.fill",
                              disabled: !available || service.authorization == .denied || service.authorization == .restricted) {
                    if running {
                        userPaused = true
                        pause()
                    } else {
                        userPaused = false
                        startIfNeeded()
                    }
                }
                .accessibilityIdentifier("toolbox.pressure.start")
                controlButton(title: service.isZeroed ? workbenchText("清除归零", "Clear zero", locale) : workbenchText("归零", "Zero", locale),
                              systemImage: service.isZeroed ? "xmark.circle" : "record.circle",
                              disabled: !available || sample == nil) {
                    if service.isZeroed { service.clearZeroReference() } else { service.setZeroReference() }
                }
                .accessibilityIdentifier("toolbox.pressure.zero")
                controlButton(title: workbenchText("清除", "Clear", locale), systemImage: "arrow.counterclockwise",
                              disabled: service.history.isEmpty) {
                    service.resetHistory()
                }
                .accessibilityIdentifier("toolbox.pressure.reset")
                Spacer(minLength: 8)
                controlButton(title: workbenchText("导出 CSV", "Export CSV", locale), systemImage: "square.and.arrow.up",
                              disabled: service.history.isEmpty) {
                    exportDocument = ToolboxPressureExportDocument(text: service.makeCSV())
                    exporting = true
                }
                .accessibilityIdentifier("toolbox.pressure.export")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    controlButton(title: running ? workbenchText("暂停", "Pause", locale) : workbenchText("开始", "Start", locale),
                                  systemImage: running ? "pause.fill" : "play.fill",
                                  disabled: !available || service.authorization == .denied || service.authorization == .restricted) {
                        if running {
                            userPaused = true
                            pause()
                        } else {
                            userPaused = false
                            startIfNeeded()
                        }
                    }
                    controlButton(title: service.isZeroed ? workbenchText("清除归零", "Clear zero", locale) : workbenchText("归零", "Zero", locale),
                                  systemImage: service.isZeroed ? "xmark.circle" : "record.circle",
                                  disabled: !available || sample == nil) {
                        if service.isZeroed { service.clearZeroReference() } else { service.setZeroReference() }
                    }
                    controlButton(title: workbenchText("清除", "Clear", locale), systemImage: "arrow.counterclockwise",
                                  disabled: service.history.isEmpty) { service.resetHistory() }
                }
                controlButton(title: workbenchText("导出 CSV", "Export CSV", locale), systemImage: "square.and.arrow.up",
                              disabled: service.history.isEmpty) {
                    exportDocument = ToolboxPressureExportDocument(text: service.makeCSV())
                    exporting = true
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
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
            title: workbenchText("气压高度仪", "Barometric Altimeter", locale),
            message: workbenchText("此平台没有气压计，气压高度仪不可用。", "This platform has no barometer, so the barometric altimeter is not available.", locale),
            systemImage: "gauge.with.dots.needle.33percent"
        )
        .navigationTitle(workbenchText("气压高度仪", "Barometric Altimeter", locale))
    }
    #endif
}

#if !os(iOS)
/// Shared honest placeholder for platforms without the required sensor.
struct EnvironmentalUnavailableSurface: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
#endif

#if os(iOS)
/// Single-series live curve with an auto-scaled window around the data range.
private struct PressureCurveChart: View {
    let title: String
    let unit: String
    let values: [Double]
    let active: Bool
    /// Altitude charts center on zero; pressure charts show the data range.
    let zeroCentered: Bool

    private var window: (low: Double, high: Double) {
        guard let minimum = values.min(), let maximum = values.max() else { return (-1, 1) }
        if zeroCentered {
            let bound = max(abs(minimum), abs(maximum), 0.5) * 1.2
            return (-bound, bound)
        }
        let padding = max((maximum - minimum) * 0.15, 0.2)
        return (minimum - padding, maximum + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.subheadline.weight(.medium))
                Text(String(format: "%.1f–%.1f %@", window.low, window.high, unit))
                    .font(.caption.monospaced())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
            Canvas { context, size in
                let plot = CGRect(x: 4, y: 4, width: size.width - 8, height: size.height - 8)
                let (low, high) = window
                func y(_ value: Double) -> CGFloat {
                    let fraction = (value - low) / (high - low)
                    return plot.maxY - CGFloat(min(max(fraction, 0), 1)) * plot.height
                }
                if zeroCentered {
                    var zero = Path()
                    zero.move(to: CGPoint(x: plot.minX, y: y(0)))
                    zero.addLine(to: CGPoint(x: plot.maxX, y: y(0)))
                    context.stroke(zero, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                }
                guard values.count > 1 else {
                    var placeholder = Path()
                    placeholder.move(to: CGPoint(x: plot.minX, y: y(zeroCentered ? 0 : high)))
                    placeholder.addLine(to: CGPoint(x: plot.maxX, y: y(zeroCentered ? 0 : high)))
                    context.stroke(placeholder, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                    return
                }
                var path = Path()
                for (index, value) in values.enumerated() {
                    let x = plot.minX + CGFloat(index) / CGFloat(values.count - 1) * plot.width
                    let point = CGPoint(x: x, y: y(value))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(.blue), lineWidth: 1.8)
            }
            .frame(minHeight: 90)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .opacity(active ? 1 : 0.75)
            .accessibilityHidden(true)
        }
    }
}
#endif
