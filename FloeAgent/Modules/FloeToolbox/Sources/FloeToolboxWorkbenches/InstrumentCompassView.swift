import SwiftUI
import FloeToolboxUtilities

/// Magnetic compass driven by the shared CoreMotion service (magnetic-north
/// reference frame, no CoreLocation involvement and no true-north mode).
@MainActor public struct ToolboxCompassView: View {
    public init() {}

    #if os(iOS)
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @State private var lease: InstrumentMotionLease?
    @State private var session = InstrumentMotionSession()
    @State private var userPaused = false

    private var service: InstrumentMotionService { .shared }

    private var available: Bool { service.isAvailable(.compass) }
    private var running: Bool { lease.map { service.isActive($0) } ?? false }
    private var sample: InstrumentMotionSample? { session.latest }
    private var heading: Double? { sample?.heading }
    private var calibrating: Bool {
        guard available else { return false }
        return running && (sample?.magneticAccuracy == .uncalibrated || (sample != nil && heading == nil))
    }

    public var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 680 && geometry.size.width > geometry.size.height
            Group {
                if wide {
                    HStack(spacing: 0) {
                        dialPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        ScrollView { readoutPanel.padding(24) }.frame(width: 320)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            dialPanel.frame(height: min(geometry.size.width - 32, 420))
                            readoutPanel.padding(.horizontal, 20)
                        }.padding(.vertical, 20)
                    }
                }
            }
        }
        .background(.background)
        .navigationTitle(workbenchText("指南针", "Compass", locale))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controlBar
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
        }
        .onAppear(perform: startIfNeeded)
        .onDisappear(perform: stop)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { startIfNeeded() } else { stop() }
        }
    }

    private func startIfNeeded() {
        guard available, !userPaused, !running else { return }
        lease = service.acquire(.compass, session: session)
    }

    private func stop() {
        if let lease { service.release(lease) }
        lease = nil
    }

    private var dialPanel: some View {
        CompassDialCanvas(heading: heading, active: running)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(dialAccessibilityLabel)
            .accessibilityIdentifier("toolbox.compass.dial")
    }

    private var readoutPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            stateNote
            headingReadout
            if let field = sample?.magneticField {
                VStack(alignment: .leading, spacing: 6) {
                    Text(workbenchText("磁场", "Magnetic field", locale))
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(format: "%.1f", field.magnitude))
                            .font(.system(.title3, design: .monospaced)).monospacedDigit()
                        Text("µT").font(.callout).foregroundStyle(.secondary)
                    }
                    Text(String(format: "X %.1f · Y %.1f · Z %.1f µT", field.x, field.y, field.z))
                        .font(.system(.caption, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var stateNote: some View {
        if !available {
            Label(workbenchText("此设备没有可用的磁力计，指南针无法工作。", "This device has no working magnetometer, so the compass cannot measure heading.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("toolbox.compass.unavailable")
        } else if session.streamError != nil {
            Label(workbenchText("传感器暂时不可用，请稍后重试。", "The sensor is temporarily unavailable. Try again shortly.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if calibrating {
            Label(workbenchText("正在校准磁力计，请持设备以 8 字缓慢移动。", "Calibrating the magnetometer. Move the device slowly in a figure-eight.", locale),
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !running {
            Label(workbenchText("已暂停", "Paused", locale), systemImage: "pause.circle")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        } else {
            Label(workbenchText("朝向为磁北极方向。", "Directions reference magnetic north.", locale),
                  systemImage: "arrow.up.forward.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var headingReadout: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(workbenchText("朝向", "Heading", locale))
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(heading.map { String(format: "%.0f°", $0) } ?? "—")
                    .font(.system(.largeTitle, design: .monospaced))
                    .monospacedDigit()
                if let heading {
                    Text(cardinalText(InstrumentMath.cardinal(headingDegrees: heading)))
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            controlButton(title: running ? workbenchText("暂停", "Pause", locale) : workbenchText("继续", "Resume", locale),
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
            .accessibilityIdentifier("toolbox.compass.pause")
            Spacer(minLength: 0)
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

    private var dialAccessibilityLabel: String {
        guard let heading else {
            return workbenchText("指南针无读数", "The compass has no reading", locale)
        }
        let value = String(format: "%.0f", heading)
        return workbenchText("指南针：朝向 \(value) 度（磁北）", "Compass: heading \(value) degrees magnetic", locale)
    }

    private func cardinalText(_ cardinal: InstrumentCardinal) -> String {
        switch cardinal {
        case .north: return workbenchText("北", "N", locale)
        case .northEast: return workbenchText("东北", "NE", locale)
        case .east: return workbenchText("东", "E", locale)
        case .southEast: return workbenchText("东南", "SE", locale)
        case .south: return workbenchText("南", "S", locale)
        case .southWest: return workbenchText("西南", "SW", locale)
        case .west: return workbenchText("西", "W", locale)
        case .northWest: return workbenchText("西北", "NW", locale)
        }
    }

    private struct CompassDialCanvas: View {
        let heading: Double?
        let active: Bool

        private let cardinals: [(String, Double)] = [("N", 0), ("E", 90), ("S", 180), ("W", 270)]

        var body: some View {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                let radius = side / 2 * 0.92
                Canvas { context, _ in
                    drawRing(context: &context, center: center, radius: radius)
                    drawCard(context: &context, center: center, radius: radius)
                    drawNeedle(context: &context, center: center, radius: radius)
                }
            }
        }

        private func drawRing(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
            let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(.secondary.opacity(0.45)), lineWidth: 2)
            for index in 0..<24 {
                let angle = CGFloat(index) * .pi / 12
                let major = index % 6 == 0
                let inner = radius * (major ? 0.84 : 0.9)
                var tick = Path()
                tick.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                tick.addLine(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
                context.stroke(tick, with: .color(.secondary.opacity(major ? 0.7 : 0.35)), lineWidth: major ? 2.5 : 1.2)
            }
        }

        private func drawCard(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
            guard let heading else { return }
            let rotation = Angle(degrees: -heading)
            var cardContext = context
            cardContext.translateBy(x: center.x, y: center.y)
            cardContext.rotate(by: rotation)
            cardContext.translateBy(x: -center.x, y: -center.y)
            for (letter, degrees) in cardinals {
                let angle = CGFloat(degrees) * .pi / 180
                let position = CGPoint(x: center.x + sin(angle) * radius * 0.68,
                                       y: center.y - cos(angle) * radius * 0.68)
                let text = Text(letter)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(degrees == 0 ? .red : .secondary)
                cardContext.draw(text, at: position, anchor: .center)
            }
        }

        private func drawNeedle(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
            let length = radius * 0.52
            var north = Path()
            north.move(to: CGPoint(x: center.x, y: center.y - length))
            north.addLine(to: CGPoint(x: center.x - length * 0.14, y: center.y + length * 0.22))
            north.addLine(to: CGPoint(x: center.x + length * 0.14, y: center.y + length * 0.22))
            north.closeSubpath()
            context.fill(north, with: .color(active ? Color.red.opacity(0.85) : Color.secondary.opacity(0.5)))
            let hub = Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
            context.fill(hub, with: .color(.secondary.opacity(0.8)))
        }
    }
    #else
    @Environment(\.locale) private var locale

    public var body: some View {
        InstrumentUnavailableSurface(
            title: workbenchText("指南针", "Compass", locale),
            message: workbenchText("此设备没有磁力计，指南针不可用。", "This device has no magnetometer, so the compass is not available.", locale),
            systemImage: "compass.drawing"
        )
        .navigationTitle(workbenchText("指南针", "Compass", locale))
    }
    #endif
}
