// FloeApp — Floe's voice mark, driven by capture and played PCM amplitude.
#if canImport(UIKit)
import SwiftUI

// MARK: - Presentation policy (the ACTUAL decision the view uses)

/// Extracted so the production view and the host tests exercise ONE
/// decision surface — never a copied rule in a fake.
enum VoiceOrbPresentation {
    /// Active drawing cadence (primary decision 2026-10-25): 60 Hz for the
    /// states that carry real level semantics or the waiting breathing, so
    /// meter-driven motion is continuous rather than stepped. Everything
    /// that presents a constant zero-level shape stops the timeline
    /// entirely — including `failed` and the permission-only phase.
    static let activeFrameInterval: TimeInterval = 1.0 / 60.0
    /// Exponential-approach time constant smoothing the ~12 Hz RMS meter
    /// steps into continuous transform motion. This shapes the presentation
    /// of REAL levels only: motion never exists without measured input, a
    /// constant level yields a constant shape, and reduce-motion/mute keep
    /// the static mark.
    static let smoothingTau: TimeInterval = 0.08
    /// A tick gap at/above this makes the smoother snap instead of gliding
    /// from a stale value across it. It is a PRESENTATION choice only: the
    /// cadence aggregates record every finite active gap (a 1 s tick gap is
    /// a real severe stall, not something to hide). Intentional inactivity
    /// is excluded by explicit `suspend()` from the view's lifecycle hooks,
    /// never inferred from the gap size.
    static let reactivationGap: TimeInterval = 0.5

    static func animates(
        state: VoiceConversationState,
        muted: Bool,
        reduceMotion: Bool
    ) -> Bool {
        guard !reduceMotion, !muted else { return false }
        switch state {
        case .preparing, .listening, .submitting, .waitingModel, .answering:
            return true
        case .idle, .requestingPermission, .paused, .ending, .failed:
            // Constant (zero-level) shape: no 60 Hz redraw is warranted.
            return false
        }
    }
}

// MARK: - Real-meter smoothing kernel (pure, host-testable)

/// Single-pole, dt-based smoother over the real measured meter. Pure value
/// semantics so tests pin exact behavior: first sample snaps (no stale
/// glide), non-advancing clocks hold, reactivation gaps snap, input is
/// clamped to 0...1, and the output approaches — never invents — the target.
struct VoiceOrbLevelSmoother: Equatable {
    private(set) var value: Float = 0
    private var lastTime: TimeInterval?

    mutating func next(toward target: Float, at time: TimeInterval, tau: TimeInterval = VoiceOrbPresentation.smoothingTau) -> Float {
        let clamped = target.isFinite ? min(1, max(0, target)) : 0
        guard time.isFinite else { return value }
        guard let last = lastTime else {
            value = clamped
            lastTime = time
            return value
        }
        let gap = time - last
        guard gap > 0 else { return value }                 // non-advancing: hold
        lastTime = time
        guard gap < VoiceOrbPresentation.reactivationGap else {
            value = clamped                                 // paused/background boundary: snap
            return value
        }
        let alpha = Float(1 - exp(-gap / max(tau, 0.001)))
        value += (clamped - value) * alpha
        return value
    }

    mutating func reset() {
        value = 0
        lastTime = nil
    }
}

// MARK: - Session-owned presentation state + bounded cadence evidence

/// Per-session orb state: the meter smoother and count-only cadence
/// aggregates (active tick count / max inter-tick gap). NOT an
/// ObservableObject and NOT `@Published`: the TimelineView owns redraws, so
/// mutating this inside the render closure never invalidates any view and
/// never starts an extra redraw loop. The screen session flushes ONE
/// summary line at the session boundary. EVERY finite active tick gap is
/// recorded — including a 1 s stall, which is exactly the severe cadence
/// pressure this instrument exists to surface. Intentional inactivity is
/// excluded only by an EXPLICIT `suspend()` (animation becoming inactive,
/// view disappearance, scene lifecycle), never by assuming a large gap must
/// have been deliberate. Tick gaps measure SwiftUI timeline cadence
/// pressure — they are NOT a GPU presented-FPS claim.
@MainActor
final class VoiceOrbPresentationState {
    private var smoother = VoiceOrbLevelSmoother()
    private var activeTicks = 0
    private var maxTickGapMs = 0
    private var lastTick: TimeInterval?

    /// Advances the real meter toward `measured` and records the redraw tick.
    func level(toward measured: Float, at time: TimeInterval) -> Float {
        if time.isFinite {
            if let last = lastTick {
                let gap = time - last
                // A same-runloop re-evaluation is not a cadence sample; any
                // real active gap is, at every size. The active/inactive
                // boundary is an explicit `suspend()`, not a gap threshold.
                if gap >= 0.002 {
                    activeTicks += 1
                    maxTickGapMs = max(maxTickGapMs, Int((gap * 1000).rounded()))
                }
            }
            lastTick = time
        }
        return smoother.next(toward: measured, at: time)
    }

    /// Explicit end of active redraw (animation became inactive, view
    /// disappeared, scene left active, mute/reduce-motion): the next gap is
    /// a lifecycle boundary, never a captured stutter. The view calls this
    /// from its lifecycle hooks, so no gap-size inference is involved.
    func suspend() {
        lastTick = nil
        smoother.reset()
    }

    /// One-shot counts-only summary for a session boundary; nil when the
    /// orb never actively drew (an idle session must not log a line).
    func summaryAndReset() -> String? {
        defer {
            activeTicks = 0
            maxTickGapMs = 0
            lastTick = nil
        }
        guard activeTicks > 0 else { return nil }
        return "orbTicks=\(activeTicks) maxTickGapMs=\(maxTickGapMs)"
    }
}

// MARK: - The mark

struct VoiceOrbView: View {
    let coordinator: VoiceConversationCoordinator
    let state: VoiceConversationState
    let muted: Bool
    /// Session-owned smoother + cadence aggregates (nil in isolated hosts:
    /// the mark stays a faithful raw meter in that case).
    var presentation: VoiceOrbPresentationState? = nil
    var diameter: CGFloat = 228
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    private var animates: Bool {
        VoiceOrbPresentation.animates(state: state, muted: muted, reduceMotion: reduceMotion)
    }

    /// The level for this tick. A normal returning helper (never branch
    /// assignments inside the ViewBuilder) keeps the builder receiving one
    /// plain value; the inactive branch is also the explicit suspend path.
    @MainActor
    private func presentedLevel(at time: TimeInterval) -> CGFloat {
        guard animates else {
            presentation?.suspend()
            return 0
        }
        let measured = state == .answering ? coordinator.outputLevel : coordinator.audioLevel
        guard let presentation else {
            return CGFloat(min(1, max(0, measured)))
        }
        return CGFloat(presentation.level(toward: measured, at: time))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: VoiceOrbPresentation.activeFrameInterval, paused: !animates)) { timeline in
            let time = animates ? timeline.date.timeIntervalSinceReferenceDate : 0
            let level = presentedLevel(at: time)
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
        // Explicit inactivity boundaries (never a gap-size inference): a
        // paused timeline, a disappeared view and a non-active scene all
        // suspend the cadence anchor, so their gaps are NOT counted as
        // active UI stalls and the next activation snaps the smoother.
        .onChange(of: animates) { _, active in
            if !active { presentation?.suspend() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { presentation?.suspend() }
        }
        .onDisappear { presentation?.suspend() }
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
