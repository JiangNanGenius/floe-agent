import SwiftUI
import FloeToolboxUtilities

/// Dual-axis bubble level backed by the shared CoreMotion service.
@MainActor public struct ToolboxLevelView: View {
    public init() {}

    #if os(iOS)
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @State private var lease: InstrumentMotionLease?
    @State private var session = InstrumentMotionSession()
    @State private var userPaused = false
    @State private var locked = false
    @State private var frozenUp: InstrumentVec3?
    @State private var frozenGravity: InstrumentVec3?

    private var service: InstrumentMotionService { .shared }

    private var available: Bool { service.isAvailable(.level) }
    private var running: Bool { lease.map { service.isActive($0) } ?? false }
    private var sample: InstrumentMotionSample? { locked ? nil : session.latest }
    private var up: InstrumentVec3? {
        if locked { return frozenUp }
        guard let sample else { return nil }
        return session.levelUpVector(for: sample)
    }
    private var gravity: InstrumentVec3? { locked ? frozenGravity : sample?.gravity }
    private var angles: InstrumentLevelAngles? { up.flatMap { InstrumentMath.levelAngles(up: $0) } }
    private var level: Bool { (angles?.tilt ?? 90) < 1 }

    public var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 680 && geometry.size.width > geometry.size.height
            Group {
                if wide {
                    HStack(spacing: 0) {
                        bubblePanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        ScrollView { sidePanel.padding(24) }.frame(width: 320)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            bubblePanel.frame(height: min(geometry.size.width - 32, 420))
                            sidePanel.padding(.horizontal, 20)
                        }.padding(.vertical, 20)
                    }
                }
            }
        }
        .background(.background)
        .navigationTitle(workbenchText("水平仪", "Level", locale))
        .onAppear(perform: startIfNeeded)
        .onDisappear(perform: stop)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { startIfNeeded() } else { stop() }
        }
        .onChange(of: locked) { _, isLocked in
            if isLocked {
                frozenUp = session.latest.map { session.levelUpVector(for: $0) }
                frozenGravity = session.latest?.gravity
                stop()
            } else {
                startIfNeeded()
            }
        }
    }

    private func startIfNeeded() {
        guard available, !locked, !userPaused, !running else { return }
        lease = service.acquire(.level, session: session)
    }

    private func stop() {
        if let lease { service.release(lease) }
        lease = nil
    }

    private var bubblePanel: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            LevelBubbleCanvas(bubble: bubblePoint, level: level, active: running)
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bubbleAccessibilityLabel)
        .accessibilityIdentifier("toolbox.level.bubble")
    }

    private var bubblePoint: (x: Double, y: Double)? {
        up.flatMap {
            let point = InstrumentMotionService.screenBubble(
                up: $0, orientation: InstrumentMotionService.currentInterfaceOrientation())
            return (point.x, point.y)
        }
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            stateNote
            readouts
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var stateNote: some View {
        if !available {
            Label(workbenchText("此设备不支持动作传感器，无法使用水平仪。", "Motion sensors are unavailable on this device, so the level cannot measure tilt.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("toolbox.level.unavailable")
        } else if session.streamError != nil {
            Label(workbenchText("传感器暂时不可用，请稍后重试。", "The sensor is temporarily unavailable. Try again shortly.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if locked {
            Label(workbenchText("读数已锁定", "Reading locked", locale), systemImage: "lock.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        } else if !running {
            Label(workbenchText("已暂停", "Paused", locale), systemImage: "pause.circle")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        } else if session.levelReference != nil {
            Label(workbenchText("已按当前角度置零", "Zeroed to the current angle", locale), systemImage: "record.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    axisReadouts
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 16) {
                    axisReadouts
                }
            }
            LabeledContent(workbenchText("倾斜角", "Inclination", locale)) {
                Text(angles.map { String(format: "%.1f°", $0.tilt) } ?? "—")
                    .monospacedDigit()
            }
            .font(.body)
            if let gravity {
                LabeledContent(workbenchText("重力", "Gravity", locale)) {
                    Text(String(format: "%.2f, %.2f, %.2f m/s²", gravity.x, gravity.y, gravity.z))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var axisReadouts: some View {
        axisReadout(title: workbenchText("左右", "L–R", locale), value: angles?.x)
        axisReadout(title: workbenchText("前后", "Top–Bottom", locale), value: angles?.y)
    }

    private func axisReadout(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value.map { String(format: "%+.1f°", $0) } ?? "—")
                .font(.system(.largeTitle, design: .monospaced))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(value.map { _ in level ? Color.green : Color.primary } ?? .secondary)
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value.map { String(format: "%+.1f degrees", $0) } ?? "unavailable"))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                controlButton(title: workbenchText("置零", "Zero", locale), systemImage: "record.circle",
                              disabled: !available || locked || sample == nil) {
                    if let sample { session.setLevelReference(sample.attitude) }
                }
                .accessibilityIdentifier("toolbox.level.zero")
                if session.levelReference != nil {
                    controlButton(title: workbenchText("清除", "Clear", locale), systemImage: "xmark.circle",
                                  disabled: !available) {
                        session.clearLevelReference()
                    }
                    .accessibilityIdentifier("toolbox.level.clear")
                }
                Spacer(minLength: 0)
                controlButton(title: locked ? workbenchText("解锁", "Unlock", locale) : workbenchText("锁定", "Lock", locale),
                              systemImage: locked ? "lock.open.fill" : "lock.fill",
                              disabled: !available || (!locked && sample == nil)) {
                    locked.toggle()
                }
                .accessibilityIdentifier("toolbox.level.lock")
            }
            HStack(spacing: 12) {
                controlButton(title: running ? workbenchText("暂停", "Pause", locale) : workbenchText("继续", "Resume", locale),
                              systemImage: running ? "pause.fill" : "play.fill",
                              disabled: !available || locked) {
                    if running {
                        userPaused = true
                        stop()
                    } else {
                        userPaused = false
                        startIfNeeded()
                    }
                }
                .accessibilityIdentifier("toolbox.level.pause")
                Spacer(minLength: 0)
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

    private var bubbleAccessibilityLabel: String {
        guard let angles else {
            return workbenchText("水平仪无读数", "The level has no reading", locale)
        }
        let xText = String(format: "%+.1f", angles.x)
        let yText = String(format: "%+.1f", angles.y)
        return workbenchText("水平仪：左右 \(xText) 度，前后 \(yText) 度，倾斜 \(String(format: "%.1f", angles.tilt)) 度",
                             "Level: left–right \(xText) degrees, top–bottom \(yText) degrees, tilt \(String(format: "%.1f", angles.tilt)) degrees", locale)
    }

    private struct LevelBubbleCanvas: View {
        let bubble: (x: Double, y: Double)?
        let level: Bool
        let active: Bool

        var body: some View {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 * 0.92
                let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                  width: radius * 2, height: radius * 2))
                context.stroke(ring, with: .color(.secondary.opacity(0.45)), lineWidth: 2)
                let inner = Path(ellipseIn: CGRect(x: center.x - radius * 0.55, y: center.y - radius * 0.55,
                                                   width: radius * 1.1, height: radius * 1.1))
                context.stroke(inner, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                for (dx, dy) in [(CGFloat(0), CGFloat(-1)), (0, 1), (-1, 0), (1, 0)] {
                    let start = CGPoint(x: center.x + dx * radius * 0.9, y: center.y + dy * radius * 0.9)
                    let end = CGPoint(x: center.x + dx * radius, y: center.y + dy * radius)
                    var tick = Path(); tick.move(to: start); tick.addLine(to: end)
                    context.stroke(tick, with: .color(.secondary.opacity(0.6)), lineWidth: 2)
                }
                let offset: CGSize
                if let bubble {
                    offset = CGSize(width: bubble.x * radius * 0.78, height: -bubble.y * radius * 0.78)
                } else {
                    offset = .zero
                }
                let bubbleCenter = CGPoint(x: center.x + offset.width, y: center.y + offset.height)
                let bubbleRadius = radius * 0.13
                let bubblePath = Path(ellipseIn: CGRect(x: bubbleCenter.x - bubbleRadius, y: bubbleCenter.y - bubbleRadius,
                                                        width: bubbleRadius * 2, height: bubbleRadius * 2))
                let fill: Color = bubble == nil ? .secondary.opacity(0.4) : (level ? .green : .blue)
                context.fill(bubblePath, with: .color(fill.opacity(active || bubble != nil ? 0.95 : 0.5)))
                context.stroke(bubblePath, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
            }
        }
    }
    #else
    @Environment(\.locale) private var locale

    public var body: some View {
        InstrumentUnavailableSurface(
            title: workbenchText("水平仪", "Level", locale),
            message: workbenchText("此设备不支持动作传感器，水平仪不可用。", "Motion sensors are unavailable on this device, so the level is not available.", locale),
            systemImage: "bubble.middle.bottom"
        )
        .navigationTitle(workbenchText("水平仪", "Level", locale))
    }
    #endif
}

#if !os(iOS)
/// Shared polished placeholder for platforms without CoreMotion.
struct InstrumentUnavailableSurface<Content: View>: View {
    let title: String
    let message: String
    let systemImage: String
    @ViewBuilder let visual: Content

    init(title: String, message: String, systemImage: String,
         @ViewBuilder visual: () -> Content = { EmptyView() }) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.visual = visual()
    }

    var body: some View {
        VStack(spacing: 20) {
            visual
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
