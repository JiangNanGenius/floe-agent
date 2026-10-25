// FloeAppTests — The voice orb's ACTUAL presentation policy, real-meter
// smoothing and bounded cadence evidence (2026-10-25).
//
// SPDX-License-Identifier: MPL-2.0
//
// Primary decision: active orb drawing cadence raised toward 60 Hz, with
// smoothing of the REAL ~12 Hz meter values (no invented motion), while
// failed / permission-only / paused / idle / ending / muted / reduce-motion
// states stop the timeline entirely (a constant zero-level shape must not
// run 60 Hz redraws). These tests exercise the exact policy the production
// view consults, the exact smoothing kernel, and the count-only cadence
// aggregates — never a copied rule inside a fake.

#if canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import Testing
@testable import FloeApp

@MainActor
@Suite("Voice orb presentation policy", .serialized)
struct VoiceOrbPresentationTests {

    @Test("60 Hz only for genuinely active states; failed/permission/idle/paused/ending never redraw")
    func animatesTruthTable() {
        #expect(VoiceOrbPresentation.activeFrameInterval == 1.0 / 60.0)
        for state in [VoiceConversationState.preparing, .listening, .submitting, .waitingModel, .answering] {
            #expect(VoiceOrbPresentation.animates(state: state, muted: false, reduceMotion: false))
        }
        for state in [VoiceConversationState.idle, .requestingPermission, .paused, .ending, .failed(.noAudioInput)] {
            #expect(!VoiceOrbPresentation.animates(state: state, muted: false, reduceMotion: false))
        }
        #expect(!VoiceOrbPresentation.animates(state: .answering, muted: true, reduceMotion: false))
        #expect(!VoiceOrbPresentation.animates(state: .listening, muted: false, reduceMotion: true))
        #expect(!VoiceOrbPresentation.animates(state: .listening, muted: true, reduceMotion: true))
    }

    @Test("Real 12 Hz meter steps become continuous motion without inventing level")
    func smootherIsAFaithfulLowPass() {
        var smoother = VoiceOrbLevelSmoother()
        let step = 1.0 / 60.0

        // First sample snaps: no stale glide from an unset value.
        #expect(smoother.next(toward: 0.8, at: 0) == 0.8)

        // A real RMS drop glides at 60 Hz ticks: strictly between the old
        // and the new value, monotone, never negative.
        var last = smoother.next(toward: 0, at: step)
        #expect(last > 0)                       // not a hard cut
        #expect(last < 0.8)
        for index in 2...12 {
            let value = smoother.next(toward: 0, at: step * Double(index))
            #expect(value <= last)              // monotone toward the real target
            #expect(value >= 0)
            last = value
        }
        #expect(last < 0.2)                     // ~0.2 s of real silence is near zero

        // A constant real target converges without overshoot or oscillation.
        for index in 0..<60 {
            last = smoother.next(toward: 0.6, at: step * Double(13 + index))
        }
        #expect(abs(last - 0.6) < 0.01)

        // Input clamping never invents level outside the real 0...1 range.
        #expect(smoother.next(toward: 2, at: 10) <= 1)
        #expect(smoother.next(toward: -1, at: 10.1) >= 0)
        #expect(smoother.next(toward: Float.nan, at: 10.2) >= 0)

        // Non-advancing clock holds; a deliberate pause/background gap
        // (≥ reactivationGap) snaps instead of gliding across it.
        let held = smoother.next(toward: 0.5, at: 10.2)
        #expect(smoother.next(toward: 0.5, at: 10.2) == held)
        #expect(smoother.next(toward: 0.9, at: 12.0) == 0.9)

        // Reset is the inactive path: the next activation snaps to the
        // current real value instead of resuming the stale one.
        smoother.reset()
        #expect(smoother.next(toward: 0.25, at: 20) == 0.25)
    }

    @Test("Cadence aggregates count active ticks only and exclude pause/background gaps")
    func cadenceAggregatesAreBoundedAndHonest() {
        let state = VoiceOrbPresentationState()
        #expect(state.summaryAndReset() == nil)                  // idle: no line

        _ = state.level(toward: 0, at: 0)                         // first tick: no gap yet
        _ = state.level(toward: 0.5, at: 0.010)                   // counted
        _ = state.level(toward: 0.5, at: 0.020)                   // counted
        state.suspend()                                           // explicit pause/background boundary
        _ = state.level(toward: 0.5, at: 30.0)                    // reactivation: NOT a gap
        _ = state.level(toward: 0.5, at: 30.3)                    // counted (300 ms)

        let summary = state.summaryAndReset()
        #expect(summary?.contains("orbTicks=3") == true)
        #expect(summary?.contains("maxTickGapMs=300") == true)
        #expect(state.summaryAndReset() == nil)                   // one-shot, resets

        // The smoother is integrated here too: a real measured level still
        // drives the returned value (never a timer).
        let level = state.level(toward: 0, at: 40.0)
        #expect(level == 0)
        #expect(state.summaryAndReset() == nil)                    // a single tick is not a cadence sample
    }

    @Test("A real 1 s active stall is recorded; a gap across explicit suspend is not")
    func activeOneSecondStallVersusExplicitSuspend() {
        let state = VoiceOrbPresentationState()

        // Active stretch: 50 ms cadence, then a real 1000 ms UI stall. That
        // gap is exactly the severe cadence pressure this instrument exists
        // to surface — dropping it would hide the failure.
        _ = state.level(toward: 0.4, at: 100.0)                   // first tick: no gap yet
        _ = state.level(toward: 0.4, at: 100.05)                  // counted (50 ms)
        _ = state.level(toward: 0.4, at: 101.05)                  // counted (1000 ms)
        let active = state.summaryAndReset()
        #expect(active?.contains("orbTicks=2") == true)
        #expect(active?.contains("maxTickGapMs=1000") == true)

        // Intentional inactivity is excluded by the EXPLICIT suspend the
        // view calls on inactive animation / disappearance / scene change —
        // never by guessing from the size of the gap.
        state.suspend()
        _ = state.level(toward: 0.4, at: 161.05)                  // 60 s away: boundary
        _ = state.level(toward: 0.4, at: 161.10)                  // counted (50 ms)
        let resumed = state.summaryAndReset()
        #expect(resumed?.contains("orbTicks=1") == true)
        #expect(resumed?.contains("maxTickGapMs=50") == true)
    }
    @Test("The hosted SwiftUI orb reports live cadence and excludes a deliberate pause")
    func hostedOrbCadenceAndPause() async throws {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            Issue.record("No active App scene for the hosted orb")
            return
        }
        let rig = VoiceRig()
        await rig.coordinator.start()
        defer { rig.coordinator.end() }
        // Synthetic meter input, real SwiftUI TimelineView rendering. This
        // does not claim microphone, audible output or GPU presented FPS.
        rig.stack.yieldLevel(0.6, speech: true, duration: 0.1)
        #expect(await rig.waitUntil { rig.coordinator.audioLevel == 0.6 })
        let presentation = VoiceOrbPresentationState()
        let host = UIHostingController(rootView: VoiceOrbView(
            coordinator: rig.coordinator, state: .listening, muted: false,
            presentation: presentation).environment(\.accessibilityReduceMotion, false))
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        window.rootViewController = host
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(600))
        let summary = presentation.summaryAndReset()
        #expect(summary != nil)
        print("voiceOrbHostedSimulator syntheticMeter=true \(summary ?? "no-active-ticks")")

        host.rootView = VoiceOrbView(
            coordinator: rig.coordinator, state: .paused, muted: false,
            presentation: presentation).environment(\.accessibilityReduceMotion, false)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        _ = presentation.summaryAndReset() // Exclude the view transition itself.
        try await Task.sleep(for: .milliseconds(200))
        #expect(presentation.summaryAndReset() == nil)
    }

}
#endif
