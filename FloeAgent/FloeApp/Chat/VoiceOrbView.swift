// FloeApp — Floe's voice mark, driven by capture and played PCM amplitude.
#if canImport(UIKit)
import SwiftUI

struct VoiceOrbView: View {
    let coordinator: VoiceConversationCoordinator
    let state: VoiceConversationState
    let muted: Bool
    var diameter: CGFloat = 228
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var animates: Bool {
        !reduceMotion && !muted && state != .paused && state != .idle && state != .ending
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { timeline in
            let time = animates ? timeline.date.timeIntervalSinceReferenceDate : 0
            let measured = state == .answering ? coordinator.outputLevel : coordinator.audioLevel
            let level = animates ? CGFloat(min(1, max(0, measured))) : 0
            let waiting = state == .preparing || state == .waitingModel || state == .submitting
                || (state == .answering && coordinator.currentSpokenText.isEmpty)
            let breathing = waiting && animates ? CGFloat(sin(time * 1.5)) * 0.018 : 0
            ZStack {
                VoiceOrbContour(phase: time, amplitude: level * 0.055 + (waiting ? 0.012 : 0))
                    .fill(RadialGradient(
                        colors: [Color.cyan.opacity(scheme == .dark ? 0.32 : 0.18), Color.blue.opacity(0.12), Color.indigo.opacity(0.04)],
                        center: .init(x: 0.36, y: 0.29), startRadius: 10, endRadius: 155
                    ))
                    .frame(width: 258, height: 258)
                Image("VoiceMark")
                    .resizable().scaledToFit()
                    .frame(width: 228, height: 228)
                    .scaleEffect(0.98 + level * 0.075 + breathing)
                    .rotationEffect(.degrees(reduceMotion ? 0 : Double(level) * 2))
                    .saturation(muted || state == .paused ? 0.35 : 1)
                    .opacity(muted || state == .paused ? 0.6 : 1)
            }
            .frame(width: 286, height: 286)
        }
        .scaleEffect(diameter / 286)
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

private struct VoiceOrbContour: Shape {
    let phase: Double
    let amplitude: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2.12
        let count = 96
        var path = Path()
        for index in 0...count {
            let angle = Double(index) / Double(count) * .pi * 2
            let modulation = sin(angle * 3 + phase * 0.75) * 0.6 + sin(angle * 5 - phase * 0.45) * 0.4
            let r = radius * (1 + CGFloat(modulation) * amplitude)
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
#endif
