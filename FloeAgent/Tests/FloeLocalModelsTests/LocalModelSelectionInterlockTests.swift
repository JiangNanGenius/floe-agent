// SPDX-License-Identifier: MPL-2.0
//
// Selection-time heavy-runtime interlock for local MLX models. Choosing a
// local model while Linux guests/services run must confirm before any
// selection persistence, preload, benchmark or chat call; a cancel keeps the
// prior model selection and the running guests, a confirm stops and flushes
// them first. These tests drive the real `LocalModelRuntime
// .admitLocalModelSelection` through the real `HeavyRuntimeArbiter` with a
// scripted probe/decision/stopper, pinning the defer path (throws, no guest
// stopped), the confirm path (guest stopped, selection admitted) and the
// no-conflict path (no prompt at all).

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModels

@available(macOS 15.4, iOS 26.0, *)
private final class InterlockFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool = false) { self.value = value }
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
    func clear() { lock.withLock { value = false } }
}

@available(macOS 15.4, iOS 26.0, *)
private final class InterlockCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite("Local model selection heavy-runtime interlock")
struct LocalModelSelectionInterlockTests {
    private let modelID = "qwen3.8-4b-heretic-mlx4"

    @available(macOS 15.4, iOS 26.0, *)
    private func makeRuntime(arbiter: HeavyRuntimeArbiter) -> LocalModelRuntime {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-interlock-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return LocalModelRuntime(
            store: LocalModelStore(root: root),
            makeEngine: { _, _, _, _ in
                throw FloeError.notFound("the interlock must not map an engine")
            },
            measureAvailableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            modelSnapshot: { modelID in
                (directory: root.appendingPathComponent(modelID, isDirectory: true), weightBytes: 1_000_000)
            },
            preflightSettleSamples: 0,
            preflightSettleInterval: .milliseconds(1),
            idleUnloadInterval: .seconds(120),
            arbiter: arbiter
        )
    }

    @Test("Cancel keeps the prior selection and the guests: gate throws deferredByCaller, no guest stopped")
    @available(macOS 15.4, iOS 26.0, *)
    func deferPreservesSelectionAndGuests() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let stops = InterlockCounter()
        arbiter.configure(
            activityProbe: {
                HeavyRuntimeArbiter.LinuxActivity(
                    guestEnvironmentIDs: ["env-1"],
                    guests: [HeavyRuntimeArbiter.LinuxGuestActivity(environmentID: "env-1")]
                )
            },
            guestStopper: { _ in stops.increment() },
            decisionHandler: { _ in .deferLocalModel },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(50)
        )
        let runtime = makeRuntime(arbiter: arbiter)
        do {
            try await runtime.admitLocalModelSelection(modelID: modelID)
            Issue.record("expected deferredByCaller, selection admitted unexpectedly")
        } catch let error as HeavyRuntimeArbiter.ArbiterError {
            #expect(error == .deferredByCaller)
        }
        #expect(stops.count == 0, "a cancelled selection must not stop any guest")
    }

    @Test("Confirm stops and flushes the guests first, then admits the selection")
    @available(macOS 15.4, iOS 26.0, *)
    func confirmStopsGuestsAndAdmits() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let guestUp = InterlockFlag(true)
        let stops = InterlockCounter()
        arbiter.configure(
            activityProbe: {
                guard guestUp.isSet else { return HeavyRuntimeArbiter.LinuxActivity() }
                return HeavyRuntimeArbiter.LinuxActivity(
                    guestEnvironmentIDs: ["env-1"],
                    guests: [HeavyRuntimeArbiter.LinuxGuestActivity(environmentID: "env-1")]
                )
            },
            guestStopper: { _ in
                stops.increment()
                guestUp.clear()
            },
            decisionHandler: { _ in .stopGuestsAndProceed },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(400)
        )
        let runtime = makeRuntime(arbiter: arbiter)
        try await runtime.admitLocalModelSelection(modelID: modelID)
        #expect(stops.count == 1, "a confirmed selection stops the reported guest exactly once")
        #expect(!guestUp.isSet)
    }

    @Test("No active Linux work admits the selection without presenting a prompt")
    @available(macOS 15.4, iOS 26.0, *)
    func emptyActivityAdmitsWithoutPrompt() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let decisions = InterlockCounter()
        arbiter.configure(
            activityProbe: { HeavyRuntimeArbiter.LinuxActivity() },
            guestStopper: { _ in },
            decisionHandler: { _ in
                decisions.increment()
                return .deferLocalModel
            },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(50)
        )
        let runtime = makeRuntime(arbiter: arbiter)
        try await runtime.admitLocalModelSelection(modelID: modelID)
        #expect(decisions.count == 0, "an empty activity snapshot must not prompt")
    }
}
