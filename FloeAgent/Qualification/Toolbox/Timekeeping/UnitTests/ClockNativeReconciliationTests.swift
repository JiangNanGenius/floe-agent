// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeToolboxUtilities
@testable import FloeToolboxWorkbenches

private enum ClockReconciliationTestFailure: Error, Sendable {
    case timedOut(String)
}

/// Both arrival and release are awaitable; a missing callback fails the test
/// instead of leaving an unchecked continuation suspended indefinitely.
@MainActor private final class ClockReconciliationGate {
    private let name: String
    private var opened = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    init(_ name: String) { self.name = name }

    func open() {
        opened = true
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait(timeout: Duration = .seconds(5)) async throws {
        if opened { return }
        let id = UUID()
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) }
            catch { return }
            guard let self else { return }
            self.fail(id, with: ClockReconciliationTestFailure.timedOut(self.name))
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                if opened { waiter.resume() }
                else if Task.isCancelled { waiter.resume(throwing: CancellationError()) }
                else { waiters[id] = waiter }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(id, with: CancellationError()) }
        }
    }

    private func fail(_ id: UUID, with error: any Error) {
        waiters.removeValue(forKey: id)?.resume(throwing: error)
    }
}

@MainActor private final class ClockSynchronizationBarrier {
    let action: ToolboxTimerAlarmAction
    let entered = ClockReconciliationGate("native synchronize did not reach its barrier")
    let release = ClockReconciliationGate("native synchronize barrier was not released")

    init(action: ToolboxTimerAlarmAction) { self.action = action }
}

/// A second next() proves that the service finished processing the first
/// event. Yielding into a buffered stream alone would not prove that order.
@MainActor private final class ClockNativeEventSource {
    let processed = ClockReconciliationGate("the service did not process the native event")
    private var pending: [ToolboxTimerAlarmState] = []
    private var receiver: CheckedContinuation<ToolboxTimerAlarmState?, Never>?
    private var delivered = false
    private var finished = false

    func stream() -> AsyncStream<ToolboxTimerAlarmState> {
        AsyncStream(unfolding: { await self.next() }, onCancel: {
            Task { @MainActor in self.finish() }
        })
    }

    func send(_ value: ToolboxTimerAlarmState) {
        guard !finished else { return }
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: value)
        } else { pending.append(value) }
    }

    func finish() {
        finished = true
        pending.removeAll()
        receiver?.resume(returning: nil)
        receiver = nil
    }

    private func next() async -> ToolboxTimerAlarmState? {
        if delivered { processed.open() }
        guard !finished else { return nil }
        let value: ToolboxTimerAlarmState?
        if !pending.isEmpty { value = pending.removeFirst() }
        else { value = await withCheckedContinuation { receiver = $0 } }
        if value != nil { delivered = true }
        return value
    }
}

/// Pure bridge fake: no AlarmKit, notifications, system permissions or clock
/// singleton. A held refresh returns its earlier read, even after OS Stop.
@MainActor private final class ClockReconciliationProbe {
    let events = ClockNativeEventSource()
    private(set) var requests: [ToolboxTimerAlarmRequest] = []
    private(set) var responses: [(action: ToolboxTimerAlarmAction, phase: ToolboxTimerAlarmState.Phase)] = []
    private(set) var cancelledActions: [ToolboxTimerAlarmAction] = []
    private(set) var nativePhase: ToolboxTimerAlarmState.Phase = .stopped
    private var nativeRemaining: Double?
    private var nextBarrier: ClockSynchronizationBarrier?
    private var barriers: [ClockSynchronizationBarrier] = []

    var bridge: ToolboxTimerReminderBridge {
        .init(authorize: { true }, synchronize: { try await self.synchronize($0) },
            cancel: { _ in self.nativePhase = .stopped; self.nativeRemaining = nil },
            prune: { _ in }, updates: { self.events.stream() })
    }

    func holdNext(_ action: ToolboxTimerAlarmAction) -> ClockSynchronizationBarrier {
        let barrier = ClockSynchronizationBarrier(action: action)
        nextBarrier = barrier
        barriers.append(barrier)
        return barrier
    }

    func seedRunning(remaining: Double) {
        nativePhase = .running
        nativeRemaining = remaining
    }

    func stopFromSystem(timerID: UUID, generation: UInt64) {
        nativePhase = .stopped
        nativeRemaining = nil
        events.send(.init(timerID: timerID, generation: generation, phase: .stopped, remaining: nil))
    }

    func finish() {
        for barrier in barriers { barrier.release.open() }
        events.finish()
    }

    private func state(for request: ToolboxTimerAlarmRequest) -> ToolboxTimerAlarmState {
        .init(timerID: request.timerID, generation: request.generation,
            phase: nativePhase, remaining: nativeRemaining)
    }

    private func synchronize(_ request: ToolboxTimerAlarmRequest) async throws -> ToolboxTimerAlarmState? {
        requests.append(request)
        let earlierRead = request.action == .refresh ? state(for: request) : nil
        do {
            if let barrier = nextBarrier, barrier.action == request.action {
                nextBarrier = nil
                barrier.entered.open()
                try await barrier.release.wait()
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            cancelledActions.append(request.action)
            throw CancellationError()
        }
        switch request.action {
        case .start, .resume, .restart:
            nativePhase = .running; nativeRemaining = request.remaining
        case .pause, .reset:
            nativePhase = .paused; nativeRemaining = request.remaining
        case .refresh:
            break
        }
        let result = earlierRead ?? state(for: request)
        responses.append((request.action, result.phase))
        return result
    }
}

@MainActor private func awaitClockReconciliation(
    _ description: String,
    timeout: Duration = .seconds(5),
    until condition: @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw ClockReconciliationTestFailure.timedOut(description) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor private func withClockReconciliationFixture(
    _ body: @MainActor (ToolboxTimekeepingService, ToolboxTimekeepingStore, ClockReconciliationProbe) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clock-native-" + UUID().uuidString)
    let store = ToolboxTimekeepingStore(url: root.appendingPathComponent("state.json"))
    let service = ToolboxTimekeepingService(store: store)
    let probe = ClockReconciliationProbe()
    func cleanUp() async {
        probe.finish()
        try? await awaitClockReconciliation("service cleanup", timeout: .seconds(2)) {
            !service.saving && !service.reminderStatus.values.contains(.working)
        }
        try? FileManager.default.removeItem(at: root)
    }
    do {
        try await body(service, store, probe)
        await cleanUp()
    } catch {
        await cleanUp()
        throw error
    }
}

@MainActor private func startClockWithAlarm(
    service: ToolboxTimekeepingService, probe: ClockReconciliationProbe
) async throws -> UUID {
    await service.load(reminders: probe.bridge)
    service.addTimer(label: "Native reconciliation", duration: 300)
    let id = try #require(service.state.timers.first?.id)
    service.setReminder(true, for: id)
    try await awaitClockReconciliation("initial native timer acknowledgement") {
        service.reminderStatus[id] == .scheduled && service.state.timers.first?.pendingAlarmAction == nil
    }
    return id
}

@Suite("Clock native reconciliation regressions") @MainActor
struct ClockNativeReconciliationTests {
    @Test("Foreground refresh preserves an explicit action still awaiting the native bridge",
        arguments: [ToolboxTimerAlarmAction.pause, .reset])
    func refreshDoesNotCancelExplicitAction(_ action: ToolboxTimerAlarmAction) async throws {
        try await withClockReconciliationFixture { service, _, probe in
            let id = try await startClockWithAlarm(service: service, probe: probe)
            let barrier = probe.holdNext(action)
            if action == .pause { service.pause(id) }
            else { service.reset(id) }
            try await barrier.entered.wait()
            #expect(service.state.timers.first?.pendingAlarmAction == action)

            service.refreshReminders()
            barrier.release.open()

            try await awaitClockReconciliation("explicit action and its coalesced refresh") {
                probe.responses.count == 3 && service.state.timers.first?.phase == .paused &&
                    service.state.timers.first?.pendingAlarmAction == nil && service.reminderStatus[id] == .off
            }
            #expect(probe.requests.map(\.action) == [.start, action, .refresh])
            #expect(probe.cancelledActions.isEmpty)
            #expect(probe.nativePhase == .paused)
            #expect(service.state.timers.first?.reminder == true)
            if action == .reset { #expect(service.state.timers.first?.retained == 300) }
        }
    }

    @Test("An OS Stop received while busy forces a fresh read after the earlier response")
    func busySystemStopIsReconciledAfterAnEarlierRunningResponse() async throws {
        try await withClockReconciliationFixture { service, _, probe in
            let id = try await startClockWithAlarm(service: service, probe: probe)
            let barrier = probe.holdNext(.refresh)
            service.refreshReminders()
            try await barrier.entered.wait()
            let generation = try #require(service.state.timers.first?.generation)

            probe.stopFromSystem(timerID: id, generation: generation)
            try await probe.events.processed.wait()
            #expect(service.state.timers.first?.reminder == true) // The earlier request still owns reconciliation.
            barrier.release.open()

            try await awaitClockReconciliation("fresh stopped read after the earlier running response") {
                probe.responses.count == 3 && service.state.timers.first?.reminder == false &&
                    service.reminderStatus[id] == .off
            }
            #expect(probe.responses.filter { $0.action == .refresh }.map { $0.phase } == [.running, .stopped])
            #expect(probe.requests.map(\.action) == [.start, .refresh, .refresh])
            #expect(service.state.timers.first?.phase == .paused)
            #expect(probe.cancelledActions.isEmpty)
        }
    }

    @Test("Cold load replays a persisted pause before acknowledging or clearing it")
    func coldLoadReplaysPendingPauseInsteadOfRefreshingItAway() async throws {
        try await withClockReconciliationFixture { service, store, probe in
            var timer = try ToolboxCountdown(label: "Persisted pause", duration: 300, now: .now)
            timer.reminder = true
            timer.pause(at: .now)
            timer.pendingAlarmAction = .pause
            var archive = ToolboxTimekeepingArchive()
            archive.revision = 7
            archive.timers = [timer]
            try await store.save(archive)
            probe.seedRunning(remaining: timer.retained)
            let barrier = probe.holdNext(.pause)

            await service.load(reminders: probe.bridge)
            try await barrier.entered.wait()
            #expect(probe.requests.map(\.action) == [.pause])
            #expect(service.state.timers.first?.pendingAlarmAction == .pause)
            #expect(probe.nativePhase == .running)
            barrier.release.open()

            try await awaitClockReconciliation("persisted pause acknowledgement") {
                service.state.timers.first?.pendingAlarmAction == nil &&
                    service.state.timers.first?.phase == .paused && !service.saving &&
                    service.reminderStatus[timer.id] == .off
            }
            let saved = try await store.load()
            #expect(saved.timers.first?.pendingAlarmAction == nil)
            #expect(saved.timers.first?.phase == .paused && saved.timers.first?.reminder == true)
            #expect(probe.requests.map(\.action) == [.pause])
            #expect(probe.nativePhase == .paused && probe.cancelledActions.isEmpty)
        }
    }
}
