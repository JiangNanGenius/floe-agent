import SwiftUI
import UniformTypeIdentifiers
import FloeToolboxUtilities

/// CSV export payload for the motion instrument. Sharing stays user-driven.
public struct InstrumentMotionExportDocument: FileDocument {
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

/// Acceleration, rotation-rate and attitude instrument with bounded live curves.
@MainActor public struct ToolboxMotionView: View {
    public init() {}

    #if os(iOS)
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @State private var lease: InstrumentMotionLease?
    @State private var session = InstrumentMotionSession()
    @State private var userPaused = false
    @State private var exportDocument: InstrumentMotionExportDocument?
    @State private var exporting = false

    private var service: InstrumentMotionService { .shared }

    private var available: Bool { service.isAvailable(.motion) }
    private var running: Bool { lease.map { service.isActive($0) } ?? false }
    private var sample: InstrumentMotionSample? { session.latest }
    private var euler: InstrumentEulerAngles? { sample.flatMap { InstrumentMath.eulerDegrees(attitude: $0.attitude) } }

    public var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 680 && geometry.size.width > geometry.size.height
            Group {
                if wide {
                    HStack(spacing: 0) {
                        chartPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        ScrollView { readoutPanel.padding(24) }.frame(width: 320)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            chartPanel.frame(height: 420)
                            readoutPanel.padding(.horizontal, 20)
                        }.padding(.vertical, 20)
                    }
                }
            }
        }
        .background(.background)
        .navigationTitle(workbenchText("运动仪表", "Motion", locale))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controlBar
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
        }
        .fileExporter(isPresented: $exporting, document: exportDocument,
                      contentType: .commaSeparatedText,
                      defaultFilename: workbenchText("运动数据", "motion-data", locale)) { _ in }
        .onAppear(perform: startIfNeeded)
        .onDisappear(perform: stop)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { startIfNeeded() } else { stop() }
        }
    }

    private func startIfNeeded() {
        guard available, !userPaused, !running else { return }
        lease = service.acquire(.motion, session: session)
    }

    private func stop() {
        if let lease { service.release(lease) }
        lease = nil
    }

    private var chartPanel: some View {
        VStack(spacing: 20) {
            InstrumentCurveChart(
                title: workbenchText("加速度", "Acceleration", locale),
                unit: "m/s²",
                series: [
                    InstrumentCurveSeries(label: "X", color: .blue,
                                          values: session.motionHistory.values.map { $0.acceleration.x }),
                    InstrumentCurveSeries(label: "Y", color: .green,
                                          values: session.motionHistory.values.map { $0.acceleration.y }),
                    InstrumentCurveSeries(label: "Z", color: .orange,
                                          values: session.motionHistory.values.map { $0.acceleration.z })
                ],
                active: running
            )
            InstrumentCurveChart(
                title: workbenchText("角速度", "Rotation rate", locale),
                unit: "rad/s",
                series: [
                    InstrumentCurveSeries(label: "X", color: .blue,
                                          values: session.motionHistory.values.map { $0.rotation.x }),
                    InstrumentCurveSeries(label: "Y", color: .green,
                                          values: session.motionHistory.values.map { $0.rotation.y }),
                    InstrumentCurveSeries(label: "Z", color: .orange,
                                          values: session.motionHistory.values.map { $0.rotation.z })
                ],
                active: running
            )
        }
        .padding(20)
        .accessibilityElement(children: .contain)
    }

    private var readoutPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            stateNote
            if let sample {
                Group {
                    vectorGroup(title: workbenchText("用户加速度", "User acceleration", locale),
                                unit: "m/s²", vector: sample.userAcceleration)
                    vectorGroup(title: workbenchText("角速度", "Rotation rate", locale),
                                unit: "rad/s", vector: sample.rotationRate)
                    if let euler {
                        LabeledContent(workbenchText("姿态", "Attitude", locale)) {
                            Text(String(format: "%+.1f° / %+.1f° / %+.1f°", euler.pitch, euler.roll, euler.yaw))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            } else if available {
                Text(workbenchText("开始后，这里会显示加速度、角速度和姿态读数。", "Start to see acceleration, rotation-rate and attitude readings here.", locale))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var stateNote: some View {
        if !available {
            Label(workbenchText("此设备不支持动作传感器，无法使用运动仪表。", "Motion sensors are unavailable on this device, so the motion instrument cannot measure.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if session.streamError != nil {
            Label(workbenchText("传感器暂时不可用，请稍后重试。", "The sensor is temporarily unavailable. Try again shortly.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !running {
            Label(workbenchText("已暂停，图表保留最后记录。", "Paused. The charts keep the last recorded samples.", locale),
                  systemImage: "pause.circle")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        } else if session.motionHistory.droppedCount > 0 {
            Text(workbenchText("图表保留最近约 8 秒的采样。", "The charts keep about the last 8 seconds of samples.", locale))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func vectorGroup(title: String, unit: String, vector: InstrumentVec3) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    vectorComponents(vector, unit: unit)
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) {
                    vectorComponents(vector, unit: unit)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func vectorComponents(_ vector: InstrumentVec3, unit: String) -> some View {
        componentLabel("X", value: vector.x, unit: unit, color: .blue)
        componentLabel("Y", value: vector.y, unit: unit, color: .green)
        componentLabel("Z", value: vector.z, unit: unit, color: .orange)
    }

    private func componentLabel(_ axis: String, value: Double, unit: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(axis).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(String(format: "%+.2f %@", value, unit))
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                controlButton(title: running ? workbenchText("暂停", "Pause", locale) : workbenchText("开始", "Start", locale),
                              systemImage: running ? "pause.fill" : "play.fill",
                              disabled: !available) {
                    if running {
                        userPaused = true
                        stop()
                    } else {
                        userPaused = false
                        startIfNeeded()
                    }
                }
                .accessibilityIdentifier("toolbox.motion.start")
                controlButton(title: workbenchText("重置", "Reset", locale), systemImage: "arrow.counterclockwise",
                              disabled: session.motionHistory.isEmpty) {
                    session.resetHistory()
                }
                .accessibilityIdentifier("toolbox.motion.reset")
                Spacer(minLength: 8)
                controlButton(title: workbenchText("导出 CSV", "Export CSV", locale), systemImage: "square.and.arrow.up",
                              disabled: session.motionHistory.isEmpty) {
                    exportDocument = InstrumentMotionExportDocument(text: makeCSV())
                    exporting = true
                }
                .accessibilityIdentifier("toolbox.motion.export")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    controlButton(title: running ? workbenchText("暂停", "Pause", locale) : workbenchText("开始", "Start", locale),
                                  systemImage: running ? "pause.fill" : "play.fill", disabled: !available) {
                        if running {
                            userPaused = true
                            stop()
                        } else {
                            userPaused = false
                            startIfNeeded()
                        }
                    }
                    controlButton(title: workbenchText("重置", "Reset", locale), systemImage: "arrow.counterclockwise",
                                  disabled: session.motionHistory.isEmpty) { session.resetHistory() }
                }
                controlButton(title: workbenchText("导出 CSV", "Export CSV", locale), systemImage: "square.and.arrow.up",
                              disabled: session.motionHistory.isEmpty) {
                    exportDocument = InstrumentMotionExportDocument(text: makeCSV())
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

    private func makeCSV() -> String {
        var lines = ["time_s,acc_x_mps2,acc_y_mps2,acc_z_mps2,rot_x_rads,rot_y_rads,rot_z_rads,pitch_deg,roll_deg,yaw_deg"]
        for point in session.motionHistory.values {
            lines.append(String(format: "%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f,%.2f",
                                point.timestamp, point.acceleration.x, point.acceleration.y, point.acceleration.z,
                                point.rotation.x, point.rotation.y, point.rotation.z,
                                point.pitch, point.roll, point.yaw))
        }
        return lines.joined(separator: "\n") + "\n"
    }
    #else
    @Environment(\.locale) private var locale

    public var body: some View {
        InstrumentUnavailableSurface(
            title: workbenchText("运动仪表", "Motion", locale),
            message: workbenchText("此设备不支持动作传感器，运动仪表不可用。", "Motion sensors are unavailable on this device, so the motion instrument is not available.", locale),
            systemImage: "gyroscope"
        )
        .navigationTitle(workbenchText("运动仪表", "Motion", locale))
    }
    #endif
}

#if os(iOS)
private struct InstrumentCurveSeries {
    let label: String
    let color: Color
    let values: [Double]
}

/// Three-series live curve with a symmetric auto-scaled window.
private struct InstrumentCurveChart: View {
    let title: String
    let unit: String
    let series: [InstrumentCurveSeries]
    let active: Bool

    private var bound: Double {
        let peak = series.flatMap { $0.values }.map(abs).max() ?? 0
        return max(peak * 1.15, 0.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.subheadline.weight(.medium))
                Text(ChartFormat.unitString(bound, unit: unit)).font(.caption.monospaced())
                    .monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                    Text(item.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.color)
                }
            }
            Canvas { context, size in
                let plot = CGRect(x: 4, y: 4, width: size.width - 8, height: size.height - 8)
                let zeroY = plot.midY
                var zero = Path()
                zero.move(to: CGPoint(x: plot.minX, y: zeroY))
                zero.addLine(to: CGPoint(x: plot.maxX, y: zeroY))
                context.stroke(zero, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                guard let count = series.map({ $0.values.count }).max(), count > 1 else {
                    var placeholder = Path()
                    placeholder.move(to: CGPoint(x: plot.minX, y: zeroY))
                    placeholder.addLine(to: CGPoint(x: plot.maxX, y: zeroY))
                    context.stroke(placeholder, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                    return
                }
                for item in series {
                    let values = item.values
                    guard values.count > 1 else { continue }
                    var path = Path()
                    for (index, value) in values.enumerated() {
                        let x = plot.maxX - CGFloat(count - 1 - index) / CGFloat(count - 1) * plot.width
                        let y = zeroY - CGFloat(min(max(value / bound, -1), 1)) * plot.height / 2
                        let point = CGPoint(x: x, y: y)
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(item.color), lineWidth: 1.8)
                }
            }
            .frame(minHeight: 90)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .opacity(active ? 1 : 0.75)
            .accessibilityHidden(true)
        }
    }
}

private enum ChartFormat {
    static func unitString(_ value: Double, unit: String) -> String {
        String(format: "±%.1f %@", value, unit)
    }
}
#endif
