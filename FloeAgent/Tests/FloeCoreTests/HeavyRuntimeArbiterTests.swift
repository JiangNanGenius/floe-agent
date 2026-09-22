// FloeCoreTests — Build 222 heavy-runtime arbitration.
//
// MLX inference and the TinyEMU Linux guest must never overlap: guest starts
// wait cancellably while a local inference session is active, and a local
// model start reports active guests/services through the app-facing decision
// interface, stopping them only after the caller confirms. These tests pin
// every branch of that contract with deterministic probes and no device.

import Foundation
import Testing
@testable import FloeCore

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool = false) { self.value = value }

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) { lock.withLock { events.append(event) } }
    var recorded: [String] { lock.withLock { events } }
}

@Suite("Heavy runtime arbitration")
struct HeavyRuntimeArbiterTests {
    private func emptyProbe() -> HeavyRuntimeArbiter.ActivityProbe {
        { HeavyRuntimeArbiter.LinuxActivity() }
    }

    private func allowHandler() -> HeavyRuntimeArbiter.DecisionHandler {
        { _ in .stopGuestsAndProceed }
    }

    @Test("A guest start waits until the last local inference session ends")
    func guestStartWaitsForInference() async throws {
        let arbiter = HeavyRuntimeArbiter()
        arbiter.configure(
            activityProbe: emptyProbe(),
            guestStopper: { _ in },
            decisionHandler: allowHandler()
        )
        #expect(!arbiter.isLocalInferenceActive)

        try await arbiter.beginLocalInferenceSession()
        #expect(arbiter.isLocalInferenceActive)

        let gate = Flag()
        let waiter = Task {
            try await arbiter.waitForLocalInferenceIdle()
            gate.set()
        }
        // Give the wait a chance to register; it must not proceed while the
        // session is open.
        try await Task.sleep(for: .milliseconds(80))
        #expect(!gate.isSet)

        arbiter.endLocalInferenceSession()
        try await waiter.value
        #expect(gate.isSet)
        #expect(!arbiter.isLocalInferenceActive)
    }

    @Test("A waiting guest start is cancellable and never proceeds later")
    func guestStartWaitIsCancellable() async throws {
        let arbiter = HeavyRuntimeArbiter()
        arbiter.configure(
            activityProbe: emptyProbe(),
            guestStopper: { _ in },
            decisionHandler: allowHandler()
        )
        try await arbiter.beginLocalInferenceSession()

        let waiter = Task { try await arbiter.waitForLocalInferenceIdle() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        do {
            try await waiter.value
            Issue.record("A cancelled wait must not return normally")
        } catch {
            #expect(error is CancellationError)
        }

        // Ending the session later must not resurrect the cancelled waiter.
        arbiter.endLocalInferenceSession()
        #expect(!arbiter.isLocalInferenceActive)
    }

    @Test("Active guests are reported and stopped only after confirmation")
    func guestsStopOnlyAfterConfirmation() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let log = OrderLog()
        arbiter.configure(
            activityProbe: {
                // Active until the stopper runs.
                log.recorded.contains("stop")
                    ? HeavyRuntimeArbiter.LinuxActivity()
                    : HeavyRuntimeArbiter.LinuxActivity(
                        guestEnvironmentIDs: ["env-1", "env-2"],
                        localServices: ["env-1:1"]
                    )
            },
            guestStopper: { activity in
                log.append("stop")
                #expect(activity.guestEnvironmentIDs == ["env-1", "env-2"])
            },
            decisionHandler: { activity in
                log.append("decide:\(activity.summary)")
                return .stopGuestsAndProceed
            },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(200)
        )

        let activity = try await arbiter.beginLocalInferenceSession()
        #expect(activity.guestEnvironmentIDs == ["env-1", "env-2"])
        // The decision precedes the stop: no guest is touched without it.
        #expect(log.recorded.first?.hasPrefix("decide:") == true)
        #expect(log.recorded.contains("stop"))
        #expect(arbiter.stoppedGuestCount == 2)
        #expect(arbiter.conflictCount == 1)
        arbiter.endLocalInferenceSession()
    }

    @Test("A declined conflict defers the local model and never stops a guest")
    func deferDecisionDoesNotStopGuests() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let log = OrderLog()
        arbiter.configure(
            activityProbe: {
                HeavyRuntimeArbiter.LinuxActivity(guestEnvironmentIDs: ["env-1"])
            },
            guestStopper: { _ in log.append("stop") },
            decisionHandler: { _ in .deferLocalModel }
        )

        do {
            try await arbiter.beginLocalInferenceSession()
            Issue.record("A deferred conflict must not return normally")
        } catch {
            #expect(error as? HeavyRuntimeArbiter.ArbiterError == .deferredByCaller)
        }
        #expect(log.recorded.isEmpty)
        // The refused session is released: Linux is not left waiting forever.
        #expect(!arbiter.isLocalInferenceActive)
    }

    @Test("Without a decision handler nothing is stopped and the request is refused")
    func missingHandlerRefusesWithoutStopping() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let log = OrderLog()
        arbiter.configure(
            activityProbe: {
                HeavyRuntimeArbiter.LinuxActivity(guestEnvironmentIDs: ["env-1"])
            },
            guestStopper: { _ in log.append("stop") }
        )

        do {
            try await arbiter.beginLocalInferenceSession()
            Issue.record("A conflict with no confirmable handler must be refused")
        } catch {
            #expect(error as? HeavyRuntimeArbiter.ArbiterError == .confirmationUnavailable)
        }
        #expect(log.recorded.isEmpty)
        #expect(!arbiter.isLocalInferenceActive)
    }

    @Test("A confirmed stop that never settles refuses the local request")
    func unsettledStopRefuses() async throws {
        let arbiter = HeavyRuntimeArbiter()
        arbiter.configure(
            activityProbe: {
                HeavyRuntimeArbiter.LinuxActivity(guestEnvironmentIDs: ["env-1"])
            },
            guestStopper: { _ in },
            decisionHandler: { _ in .stopGuestsAndProceed },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(60)
        )

        do {
            try await arbiter.beginLocalInferenceSession()
            Issue.record("A guest that never stops must not admit local inference")
        } catch {
            #expect(error as? HeavyRuntimeArbiter.ArbiterError == .linuxStopIncomplete)
        }
        #expect(!arbiter.isLocalInferenceActive)
    }

    @Test("No configured probe means no Linux activity and no report")
    func unconfiguredArbiterAdmitsLocally() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let activity = try await arbiter.beginLocalInferenceSession()
        #expect(activity.isEmpty)
        #expect(arbiter.conflictCount == 0)
        arbiter.endLocalInferenceSession()
        #expect(!arbiter.isLocalInferenceActive)
    }
}
