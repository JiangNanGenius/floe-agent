// Host fixture for the production `LocalInferenceBackgroundCanceller`.
//
// The runner compiles this file together with the real
// `FloeAgent/Sources/FloeLocalModels/LocalInferenceBackgroundCanceller.swift`,
// so every admission/transition/relay assertion below exercises the shipping
// code. This file must not redefine any production type.
//
// The background branch cannot come from UIKit on a macOS host, so the fixture
// injects a scripted `foregroundProbe` through the production
// `installForegroundProbeForTesting` seam and drives lifecycle transitions
// through the production `applyLifecycleTransition(isBackground:)`, which is
// the exact function the iOS observers call.
import Foundation
import Synchronization

final class Calls: Sendable {
    private let values = Mutex<[String: Int]>([:])

    func record(_ trace: String) {
        values.withLock { $0[trace, default: 0] += 1 }
    }

    func count(_ trace: String) -> Int {
        values.withLock { $0[trace] ?? 0 }
    }

    var total: Int {
        values.withLock { $0.values.reduce(0, +) }
    }
}

@main
struct LifecycleProbe {
    static func main() async {
        var failures: [String] = []
        var passes = 0

        func expect(_ condition: Bool, _ label: String) {
            if condition {
                passes += 1
            } else {
                failures.append(label)
            }
        }

        // 1. Foreground registration is accepted and a resign-active
        //    transition cancels it exactly once.
        do {
            let canceller = LocalInferenceBackgroundCanceller()
            let calls = Calls()
            canceller.installForegroundProbeForTesting { true }
            let token = await canceller.registerForeground(traceID: "active") {
                calls.record("active")
            }
            expect(token != nil, "active registration is accepted")
            expect(canceller.activeCount == 1, "accepted registration is counted")
            let cancelled = canceller.applyLifecycleTransition(isBackground: true)
            expect(cancelled == ["active"], "resign-active cancels the registered generation")
            expect(calls.count("active") == 1, "cancel closure runs exactly once")
            expect(canceller.activeCount == 0, "registry is empty after the transition")
            let second = canceller.applyLifecycleTransition(isBackground: true)
            expect(second.isEmpty, "repeated transition does not re-cancel")
            expect(calls.total == 1, "no double cancel")
            if let token { canceller.unregister(token) }
            expect(canceller.activeCount == 0, "unregister after a transition stays idempotent")
        }

        // 2. First-ever registration while the app is already background (the
        //    lifecycle notification was never observed because no local
        //    generation had installed the observers yet) is refused and the
        //    closure is not retained anywhere.
        do {
            let canceller = LocalInferenceBackgroundCanceller()
            let calls = Calls()
            canceller.installForegroundProbeForTesting { false }
            let token = await canceller.registerForeground(traceID: "background") {
                calls.record("background")
            }
            expect(token == nil, "registration while the app is already background is refused")
            expect(canceller.activeCount == 0, "refused registration is not retained")
            canceller.applyLifecycleTransition(isBackground: true)
            canceller.cancelAll(reason: "after-refusal")
            expect(calls.total == 0, "refused registration never runs its closure")
        }

        // 3. A transition delivered while the probe is awaiting beats the
        //    stale probe result; a later foreground probe recovers.
        do {
            let canceller = LocalInferenceBackgroundCanceller()
            let calls = Calls()
            canceller.installForegroundProbeForTesting {
                // The notification is delivered during the await; the probe
                // still returns the state it read before the transition.
                _ = canceller.applyLifecycleTransition(isBackground: true)
                return true
            }
            let raced = await canceller.registerForeground(traceID: "race") {
                calls.record("race")
            }
            expect(raced == nil, "a transition during the probe beats a stale active probe")
            expect(calls.total == 0, "the race loser retains nothing")

            canceller.installForegroundProbeForTesting { true }
            let recovery = await canceller.registerForeground(traceID: "recovery") {
                calls.record("recovery")
            }
            expect(recovery != nil, "a later foreground registration is accepted again")
            _ = canceller.applyLifecycleTransition(isBackground: true)
            expect(calls.count("recovery") == 1, "the recovered generation is still cancellable")
        }

        // 4. didBecomeActive during the probe clears the suspension and the
        //    latest transition wins.
        do {
            let canceller = LocalInferenceBackgroundCanceller()
            let calls = Calls()
            _ = canceller.applyLifecycleTransition(isBackground: true)
            canceller.installForegroundProbeForTesting {
                _ = canceller.applyLifecycleTransition(isBackground: false)
                return true
            }
            let resumed = await canceller.registerForeground(traceID: "resume") {
                calls.record("resume")
            }
            expect(resumed != nil, "didBecomeActive during the probe accepts the registration")
            _ = canceller.applyLifecycleTransition(isBackground: true)
            expect(calls.count("resume") == 1, "accepted generation is cancellable after resume")
        }

        // 5. unregister suppresses a later transition.
        do {
            let canceller = LocalInferenceBackgroundCanceller()
            let calls = Calls()
            canceller.installForegroundProbeForTesting { true }
            let token = await canceller.registerForeground(traceID: "unregister") {
                calls.record("unregister")
            }
            if let token {
                canceller.unregister(token)
                _ = canceller.applyLifecycleTransition(isBackground: true)
                expect(calls.count("unregister") == 0, "unregistered closure must not fire")
            } else {
                expect(false, "unregister fixture registration must succeed")
            }
        }

        // 6. Registering after a delivered notification while the app stays
        //    background must still be refused (observers were installed by an
        //    earlier generation; no new notification will arrive).
        do {
            let canceller = LocalInferenceBackgroundCanceller()
            let calls = Calls()
            _ = canceller.applyLifecycleTransition(isBackground: true)
            canceller.installForegroundProbeForTesting { false }
            let late = await canceller.registerForeground(traceID: "late") {
                calls.record("late")
            }
            expect(late == nil, "register after the delivered notification is refused while background")
            expect(calls.total == 0, "late registration closure never runs")
        }

        // 7. The advisory probe used before mapping weights reports the same
        //    scripted state.
        do {
            let canceller = LocalInferenceBackgroundCanceller()
            canceller.installForegroundProbeForTesting { false }
            let background = await canceller.isForegroundEligible()
            expect(!background, "advisory probe reports background")
            canceller.installForegroundProbeForTesting { true }
            let foreground = await canceller.isForegroundEligible()
            expect(foreground, "advisory probe reports foreground")
        }

        // 8. Register storm during a background transition: every concurrent
        //    registration is refused and no closure is retained.
        do {
            let canceller = LocalInferenceBackgroundCanceller()
            let calls = Calls()
            canceller.installForegroundProbeForTesting {
                _ = canceller.applyLifecycleTransition(isBackground: true)
                return true
            }
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<32 {
                    group.addTask {
                        _ = await canceller.registerForeground(traceID: "storm\(index)") {
                            calls.record("storm\(index)")
                        }
                    }
                }
            }
            expect(canceller.activeCount == 0, "no registration survives the transition storm")
            expect(calls.total == 0, "storm closures are never retained")
        }

        // 9. Concurrent foreground registrations are all cancellable exactly
        //    once (the original stress fixture, ported).
        do {
            let canceller = LocalInferenceBackgroundCanceller()
            let calls = Calls()
            canceller.installForegroundProbeForTesting { true }
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<64 {
                    group.addTask {
                        _ = await canceller.registerForeground(traceID: "c\(index)") {
                            calls.record("c\(index)")
                        }
                    }
                }
            }
            expect(canceller.activeCount == 64, "all concurrent foreground registrations are accepted")
            let cancelled = canceller.applyLifecycleTransition(isBackground: true)
            expect(cancelled.count == 64, "one transition cancels all concurrent registrations")
            expect(calls.total == 64, "each concurrent closure runs exactly once")
            expect(canceller.activeCount == 0, "registry is empty after the storm cancel")
        }

        // 10. Relay: cancellation that arrives before the generation task
        //     exists is reported to the caller at attach time.
        do {
            let relay = LocalInferenceCancellationRelay()
            let calls = Calls()
            relay.requestCancellation()
            let alreadyCancelled = relay.attach { calls.record("forward") }
            expect(alreadyCancelled, "attach reports a cancellation that arrived first")
            relay.requestCancellation()
            expect(calls.total == 0, "attach must not forward when the caller already knows")
        }

        // 11. Relay: attach first, then repeated cancellation requests forward
        //     exactly once.
        do {
            let relay = LocalInferenceCancellationRelay()
            let calls = Calls()
            let alreadyCancelled = relay.attach { calls.record("forward") }
            expect(!alreadyCancelled, "attach before cancellation returns false")
            relay.requestCancellation()
            relay.requestCancellation()
            expect(calls.total == 1, "forward runs exactly once across repeated requests")
        }

        // 12. Production ordering: register → transition → attach. The
        //     transition that lands in the register→launch window must be
        //     remembered so the caller cancels the task itself.
        do {
            let canceller = LocalInferenceBackgroundCanceller()
            let relay = LocalInferenceCancellationRelay()
            let calls = Calls()
            canceller.installForegroundProbeForTesting { true }
            let token = await canceller.registerForeground(traceID: "ordered") {
                calls.record("background")
                relay.requestCancellation()
            }
            expect(token != nil, "ordered fixture registers in the foreground")
            _ = canceller.applyLifecycleTransition(isBackground: true)
            expect(calls.count("background") == 1, "transition reaches the registration closure")
            let alreadyCancelled = relay.attach { calls.record("task") }
            expect(alreadyCancelled, "a transition in the register→attach window is remembered")
            expect(calls.count("task") == 0, "caller cancels the task itself instead of attaching")
        }

        // 13. Production ordering: register → attach → transition. The
        //     registered task is cancelled through the relay exactly once.
        do {
            let canceller = LocalInferenceBackgroundCanceller()
            let relay = LocalInferenceCancellationRelay()
            let calls = Calls()
            canceller.installForegroundProbeForTesting { true }
            let token = await canceller.registerForeground(traceID: "attached") {
                calls.record("background")
                relay.requestCancellation()
            }
            expect(token != nil, "attached fixture registers in the foreground")
            let alreadyCancelled = relay.attach { calls.record("task") }
            expect(!alreadyCancelled, "attach succeeds while the app stays active")
            _ = canceller.applyLifecycleTransition(isBackground: true)
            expect(calls.count("background") == 1 && calls.count("task") == 1,
                   "transition cancels the launched task through the relay")
        }

        print("canceller lifecycle fixtures: \(passes) passed, \(failures.count) failed")
        for failure in failures {
            print("FAIL: \(failure)")
        }
        exit(failures.isEmpty ? 0 : 1)
    }
}
