import SwiftUI
import FloeToolboxUtilities
#if os(iOS)
import UIKit
#endif

/// A dual-axis level when flat, or a spirit-level tube when held upright.
@MainActor public struct ToolboxLevelView: View {
    public init() {}

    #if os(iOS)
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .largeTitle) private var mainReadingSize: CGFloat = 72
    @State private var lease: InstrumentMotionLease?
    @State private var session = InstrumentMotionSession()
    @State private var userPaused = false
    @State private var locked = false
    @State private var frozenUp: InstrumentVec3?
    @State private var frozenGravity: InstrumentVec3?
    @State private var frozenReferenceUp: InstrumentVec3?
    @State private var displayMode: InstrumentLevelDisplayMode = .dualAxis

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
    private var screenOrientation: InstrumentScreenOrientation { .current }
    private var screenUp: InstrumentVec3? {
        up.map { InstrumentMath.screenVector($0, orientation: screenOrientation) }
    }
    private var angles: InstrumentLevelAngles? { screenUp.flatMap { InstrumentMath.levelAngles(up: $0) } }
    private var barReferenceUp: InstrumentVec3? {
        locked ? frozenReferenceUp : session.levelReference.flatMap { InstrumentMath.upVector(attitude: $0) }
    }
    private var barAngle: Double? {
        guard let gravity else { return nil }
        return InstrumentMath.barLevelAngle(gravity: gravity, referenceUp: barReferenceUp, orientation: screenOrientation)
    }
    private var level: Bool {
        displayMode == .bar ? abs(barAngle ?? 90) < 1 : (angles?.tilt ?? 90) < 1
    }

    public var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 680 && geometry.size.width > geometry.size.height
                && !dynamicTypeSize.isAccessibilitySize
            let inset: CGFloat = geometry.size.width >= 680 ? 24 : 16
            let panelWidth = max(0, min(geometry.size.width, 1100) - inset * 2)
            let compactLimit: CGFloat = dynamicTypeSize.isAccessibilitySize ? 260 : 340
            let tabletPortrait = UIDevice.current.userInterfaceIdiom == .pad && geometry.size.width >= 680
                && geometry.size.height >= geometry.size.width && !dynamicTypeSize.isAccessibilitySize
            let usableHeight = max(0, geometry.size.height - geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom)
            // Reserve the scaled reading, axes, status, controls, diagnostics
            // and insets before allowing the portrait tablet gauge to grow.
            let readingBudget = mainReadingSize * 1.2 + 84
            let supportBudget: CGFloat = 176
            let tabletGaugeHeight = min(panelWidth, 560, max(180, usableHeight - readingBudget - supportBudget - inset * 2))
            let visualHeight: CGFloat = displayMode == .bar ? (wide ? 220 : 150)
                : wide ? max(180, min(420, geometry.size.height - 190))
                : tabletPortrait ? tabletGaugeHeight : max(180, min(panelWidth, compactLimit))
            ScrollView {
                VStack(spacing: 12) {
                    instrumentPanel(wide: wide, visualHeight: visualHeight)
                    diagnostics
                }
                .padding(inset)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: wide ? .center : .top)
            }
        }
        .background(.background)
        .navigationTitle(workbenchText("水平仪", "Level", locale))
        .onAppear(perform: startIfNeeded)
        .onDisappear(perform: stop)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { startIfNeeded() } else { stop() }
        }
        .onChange(of: gravity, initial: true) { _, gravity in
            guard let gravity else { return }
            displayMode = InstrumentMath.levelDisplayMode(gravity: gravity, previous: displayMode)
        }
        .onChange(of: locked) { _, isLocked in
            if isLocked {
                frozenUp = session.latest.map { session.levelUpVector(for: $0) }
                frozenGravity = session.latest?.gravity
                frozenReferenceUp = session.levelReference.flatMap { InstrumentMath.upVector(attitude: $0) }
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
        Group {
            if displayMode == .bar {
                InstrumentLevelBarCanvas(position: barAngle.flatMap { InstrumentMath.barBubblePosition(angleDegrees: $0) },
                                         level: level, active: running)
                    .frame(maxWidth: 620)
                    .frame(height: 140)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    let side = min(proxy.size.width, proxy.size.height)
                    InstrumentLevelBubbleCanvas(bubble: bubblePoint, level: level, active: running)
                        .frame(width: side, height: side)
                        .overlay {
                            if colorScheme == .light { targetGuides }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bubbleAccessibilityLabel)
        .accessibilityIdentifier("toolbox.level.bubble")
    }

    /// Higher-contrast target guides for Level only; the shared bubble
    /// canvas and Motion's appearance keep their existing drawing.
    private var targetGuides: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 * 0.92
            let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(.primary.opacity(0.5)), lineWidth: 2)
            let inner = Path(ellipseIn: CGRect(x: center.x - radius * 0.55, y: center.y - radius * 0.55,
                                               width: radius * 1.1, height: radius * 1.1))
            context.stroke(inner, with: .color(.primary.opacity(0.45)), lineWidth: 1)
            for (dx, dy) in [(CGFloat(0), CGFloat(-1)), (0, 1), (-1, 0), (1, 0)] {
                let start = CGPoint(x: center.x + dx * radius * 0.9, y: center.y + dy * radius * 0.9)
                let end = CGPoint(x: center.x + dx * radius, y: center.y + dy * radius)
                var tick = Path(); tick.move(to: start); tick.addLine(to: end)
                context.stroke(tick, with: .color(.primary.opacity(0.6)), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var bubblePoint: (x: Double, y: Double)? {
        screenUp.flatMap { InstrumentMath.bubblePosition(up: $0) }
    }

    private func instrumentPanel(wide: Bool, visualHeight: CGFloat) -> some View {
        VStack(spacing: 12) {
            if wide {
                HStack(alignment: .center, spacing: 32) {
                    bubblePanel.frame(maxWidth: .infinity).frame(height: visualHeight)
                    readouts.frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 12) {
                    bubblePanel.frame(height: visualHeight)
                    readouts
                }
            }
            VStack(spacing: 8) {
                stateNote
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                controls
            }
        }
        .frame(maxWidth: .infinity)
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
        } else if mainAngle == nil {
            Label(workbenchText("正在获取读数…", "Waiting for a reading…", locale), systemImage: "hourglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if session.levelReference != nil {
            Label(displayMode == .bar
                  ? workbenchText("横向边已按参考姿态置零", "Edge zeroed to the reference pose", locale)
                  : workbenchText("已按当前角度置零", "Zeroed to the current angle", locale), systemImage: "record.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var readouts: some View {
        VStack(spacing: 10) {
            mainReading
            if displayMode == .bar {
                Text(barReferenceUp == nil
                     ? workbenchText("竖直时，测量横向边缘是否水平。", "When upright, measures whether the horizontal edge is level.", locale)
                     : workbenchText("显示横向边缘相对置零姿态的倾角。", "Shows the horizontal edge's angle relative to the zeroed pose.", locale))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        axisReadouts
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(spacing: 12) {
                        axisReadouts
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Presentation validity does not depend on running or sample: a locked
    /// reading uses frozenUp, and a paused one keeps its last sample.
    private var canDisplayReading: Bool { available && session.streamError == nil }
    private var mainAngle: Double? {
        guard canDisplayReading else { return nil }
        return displayMode == .bar ? barAngle : angles?.tilt
    }

    private var mainReading: some View {
        let title = displayMode == .bar
            ? workbenchText("横向倾角", "Edge angle", locale)
            : workbenchText("倾斜角", "Inclination", locale)
        let value = mainAngle.map { String(format: displayMode == .bar ? "%+.1f°" : "%.1f°", $0) } ?? "—"
        return VStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                Text(value).font(.system(size: mainReadingSize, weight: .medium, design: .rounded))
                Text(value).font(.system(.largeTitle, design: .rounded).weight(.medium))
            }
            .monospacedDigit()
            .foregroundStyle(mainAngle.map { _ in level ? Color.green : Color.primary } ?? .secondary)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(mainAngle.map { angle in
                let number = String(format: "%.1f", angle)
                return workbenchText("\(number) 度", "\(number) degrees", locale)
            } ?? workbenchText("无读数", "No reading", locale)))
            .accessibilityIdentifier("toolbox.level.mainReading")
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var axisReadouts: some View {
        axisReadout(title: workbenchText("左右", "L–R", locale), value: canDisplayReading ? angles?.x : nil)
        axisReadout(title: workbenchText("前后", "Top–Bottom", locale), value: canDisplayReading ? angles?.y : nil)
    }

    private func axisReadout(title: String, value: Double?) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value.map { String(format: "%+.1f°", $0) } ?? "—")
                .font(.title3.weight(.medium))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(value.map { _ in level ? Color.green : Color.primary } ?? .secondary)
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value.map { value in
            let number = String(format: "%+.1f", value)
            return workbenchText("\(number) 度", "\(number) degrees", locale)
        } ?? workbenchText("无读数", "No reading", locale)))
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                calibrationButtons
                lockButton
                pauseButton
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    calibrationButtons
                }
                HStack(spacing: 8) {
                    lockButton
                    pauseButton
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 8) {
                calibrationButtons
                lockButton
                pauseButton
            }
        }
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity)
    }

    private var pauseButton: some View {
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
    }

    @ViewBuilder private var calibrationButtons: some View {
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
    }

    private var lockButton: some View {
        controlButton(title: locked ? workbenchText("解锁", "Unlock", locale) : workbenchText("锁定", "Lock", locale),
                      systemImage: locked ? "lock.open.fill" : "lock.fill",
                      disabled: !available || (!locked && sample == nil)) {
            locked.toggle()
        }
        .accessibilityIdentifier("toolbox.level.lock")
    }

    private func controlButton(title: String, systemImage: String, disabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body)
                .frame(minHeight: 44)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .disabled(disabled)
    }

    private var diagnostics: some View {
        DisclosureGroup {
            if let gravity {
                LabeledContent(workbenchText("重力", "Gravity", locale)) {
                    Text(String(format: "%.2f, %.2f, %.2f m/s²", gravity.x, gravity.y, gravity.z))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            } else {
                LabeledContent(workbenchText("重力", "Gravity", locale), value: "—")
                    .font(.callout)
            }
        } label: {
            Text(workbenchText("诊断详情", "Diagnostics", locale))
                .font(.callout)
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("toolbox.level.diagnostics")
    }

    private var bubbleAccessibilityLabel: String {
        if displayMode == .bar {
            guard canDisplayReading, let barAngle else { return workbenchText("条形水平仪无读数", "The bar level has no reading", locale) }
            let value = String(format: "%+.1f", barAngle)
            return workbenchText("条形水平仪：横向倾角 \(value) 度", "Bar level: edge angle \(value) degrees", locale)
        }
        guard canDisplayReading, let angles else {
            return workbenchText("水平仪无读数", "The level has no reading", locale)
        }
        let xText = String(format: "%+.1f", angles.x)
        let yText = String(format: "%+.1f", angles.y)
        return workbenchText("水平仪：左右 \(xText) 度，前后 \(yText) 度，倾斜 \(String(format: "%.1f", angles.tilt)) 度",
                             "Level: left–right \(xText) degrees, top–bottom \(yText) degrees, tilt \(String(format: "%.1f", angles.tilt)) degrees", locale)
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

#if os(iOS)
@MainActor
extension InstrumentScreenOrientation {
    static var current: Self {
        switch InstrumentMotionService.currentInterfaceOrientation() {
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }
}

struct InstrumentLevelBarCanvas: View {
    let position: Double?
    let level: Bool
    let active: Bool

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let tubeHeight = min(size.height * 0.4, 56)
            let tube = CGRect(x: 8, y: center.y - tubeHeight / 2,
                              width: max(size.width - 16, 1), height: tubeHeight)
            let outline = Path(roundedRect: tube, cornerRadius: tubeHeight / 2)
            context.fill(outline, with: .color(.secondary.opacity(0.06)))
            context.stroke(outline, with: .color(.secondary.opacity(0.45)), lineWidth: 2)
            let bubbleWidth = min(tubeHeight * 1.3, tube.width * 0.25)
            for direction in [-1.0, 1.0] {
                let x = center.x + CGFloat(direction) * bubbleWidth * 0.65
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: tube.minY - 6))
                tick.addLine(to: CGPoint(x: x, y: tube.maxY + 6))
                context.stroke(tick, with: .color(.secondary.opacity(0.6)), lineWidth: 2)
            }
            let travel = max((tube.width - bubbleWidth) / 2 - 6, 0)
            let x = center.x + CGFloat(position ?? 0) * travel
            let bubble = Path(roundedRect: CGRect(x: x - bubbleWidth / 2, y: center.y - tubeHeight * 0.32,
                                                   width: bubbleWidth, height: tubeHeight * 0.64),
                              cornerRadius: tubeHeight * 0.32)
            let fill: Color = position == nil ? .secondary.opacity(0.4) : (level ? .green : .blue)
            context.fill(bubble, with: .color(fill.opacity(active || position != nil ? 0.95 : 0.5)))
            context.stroke(bubble, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
        }
    }
}

struct InstrumentLevelBubbleCanvas: View {
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
#endif

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
