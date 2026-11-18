import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxUtilities
import FloeToolboxWorkbenches
import FloeMacMediaSystem
@testable import FloeMacToolbox

private enum TimerTestFailure: Error { case timeout }

@MainActor
private final class FakeTimerClock {
    var now = ContinuousClock.now
    func advance(_ seconds: Double) { now = now.advanced(by: .seconds(seconds)) }
}

@MainActor
private final class FakeSilentTimerClock {
    var sample = ToolboxTimeSample.now
    var sleeps: [TimeInterval] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func advance(_ seconds: Double, newProcess: Bool = false) {
        sample = .init(wall: sample.wall.addingTimeInterval(seconds),
                       continuous: sample.continuous + seconds,
                       process: newProcess ? UUID() : sample.process)
    }
    func sleep(_ delay: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                sleeps.append(delay)
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func fire() {
        let ready = waiters.values
        waiters.removeAll()
        for waiter in ready { waiter.resume() }
    }
}

@MainActor
private func waitForTimer(_ seconds: Double = 5, _ condition: @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(seconds))
    while !(await condition()) {
        guard clock.now < deadline else { throw TimerTestFailure.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private let timerProcess = UUID()
private func timerClock(_ elapsed: Double, wallDelta: Double = 0, process: UUID = timerProcess) -> ToolboxTimeSample {
    .init(wall: Date(timeIntervalSince1970: 1_800_000_000 + elapsed + wallDelta),
          continuous: 10_000 + elapsed, process: process)
}

@MainActor
@Suite("Mac timer state", .serialized)
struct MacTimerStateTests {
    private func root() throws -> URL {
        try MacToolboxTestRoot.unique("timer")
    }

    private func service(_ root: URL) -> (ToolboxTimekeepingService, ToolboxTimekeepingStore) {
        let store = ToolboxTimekeepingStore(url: root.appendingPathComponent("state.json"))
        return (ToolboxTimekeepingService(store: store), store)
    }

    @Test func countdownPauseResumeResetAndFinishMatchTheSharedModel() throws {
        var timer = try ToolboxCountdown(label: "Tea", duration: 60, now: timerClock(0))
        #expect(timer.phase == .running)
        #expect(timer.remaining(at: timerClock(20)) == 40)
        timer.pause(at: timerClock(20))
        #expect(timer.phase == .paused && timer.remaining(at: timerClock(90)) == 40)
        timer.resume(at: timerClock(100))
        #expect(timer.remaining(at: timerClock(110, wallDelta: 10_000)) == 30)
        let finished = timer.finishIfNeeded(at: timerClock(145))
        #expect(finished)
        #expect(timer.phase == .finished && timer.remaining(at: timerClock(200)) == 0)
        let finishedAgain = timer.finishIfNeeded(at: timerClock(200))
        #expect(!finishedAgain)
        timer.reset()
        #expect(timer.phase == .paused && timer.retained == 60)
    }

    @Test func servicePersistsAddsAndExpiresSilentTimersOnce() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (service, store) = service(root)
        await service.load()
        #expect(service.loaded)
        service.addTimer(label: "Silent", duration: 10, at: timerClock(0))
        let id = try #require(service.state.timers.first?.id)
        #expect(service.state.timers.count == 1)
        #expect(service.expiredIDs(at: timerClock(5)).isEmpty)
        #expect(service.expiredIDs(at: timerClock(20)) == [id])
        service.reconcile(at: timerClock(20))
        #expect(service.state.timers[0].phase == .finished)
        #expect(service.expiredIDs(at: timerClock(30)).isEmpty)
        try await waitForTimer {
            (try? await store.load())?.timers.first?.phase == .finished
        }
        service.remove(id)
        #expect(service.state.timers.isEmpty)
        try await waitForTimer { (try? await store.load())?.timers.isEmpty == true }
    }

    @Test func appOwnedCoordinatorPersistsDeadlineWithoutAView() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (service, store) = service(root)
        await service.load()
        let clock = FakeSilentTimerClock()
        let coordinator = MacSilentTimerCoordinator(service: service, now: { clock.sample }, sleep: { try await clock.sleep($0) })
        coordinator.start()
        service.addTimer(label: "Silent", duration: 10, at: clock.sample)
        try await waitForTimer { clock.sleeps.contains(10) }
        clock.advance(10)
        clock.fire()
        try await waitForTimer { (try? await store.load())?.timers.first?.phase == .finished }
        coordinator.stop()
    }

    @Test func coordinatorWakeReconcilesElapsedTimer() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (service, store) = service(root)
        await service.load()
        let clock = FakeSilentTimerClock()
        let coordinator = MacSilentTimerCoordinator(service: service, now: { clock.sample }, sleep: { try await clock.sleep($0) })
        coordinator.start()
        service.addTimer(label: "Wake", duration: 10, at: clock.sample)
        try await waitForTimer { clock.sleeps.contains(10) }
        clock.advance(15)
        coordinator.wake()
        try await waitForTimer { (try? await store.load())?.timers.first?.phase == .finished }
        coordinator.stop()
    }

    @Test func coordinatorReconcilesRestoredArchiveAtStartup() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (first, store) = service(root)
        await first.load()
        let clock = FakeSilentTimerClock()
        // The persisted timer belongs to a previous process, while its
        // continuous/wall offset still identifies the same machine boot.
        clock.advance(0, newProcess: true)
        #expect(clock.sample.process != ToolboxTimeSample.now.process)
        first.addTimer(label: "Restore", duration: 60, at: clock.sample)
        try await waitForTimer { (try? await store.load())?.timers.count == 1 }
        let (restored, restoredStore) = service(root)
        await restored.load()
        clock.advance(70)
        let coordinator = MacSilentTimerCoordinator(service: restored, now: { clock.sample }, sleep: { try await clock.sleep($0) })
        coordinator.start()
        try await waitForTimer { (try? await restoredStore.load())?.timers.first?.phase == .finished }
        coordinator.stop()
    }

    @Test func stopwatchLapsAndBoundsSurviveTheService() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (service, _) = service(root)
        await service.load()
        service.startStopwatch(at: timerClock(0))
        service.lap(at: timerClock(10))
        service.lap(at: timerClock(17))
        #expect(service.state.stopwatch.laps.map(\.split) == [10, 7])
        service.pauseStopwatch(at: timerClock(20))
        #expect(service.state.stopwatch.elapsed(at: timerClock(100)) == 20)
        service.resetStopwatch()
        #expect(service.state.stopwatch.laps.isEmpty && !service.state.stopwatch.running)
    }

    @Test func invalidTimerInputIsRejectedWithoutChangingTheArchive() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (service, _) = service(root)
        await service.load()
        service.addTimer(label: " ", duration: 60, at: timerClock(0))
        #expect(service.state.timers.isEmpty)
        service.addTimer(label: "Valid", duration: 0, at: timerClock(0))
        #expect(service.state.timers.isEmpty)
        service.addTimer(label: "Valid", duration: 60, at: timerClock(0))
        #expect(service.state.timers.count == 1)
    }

    @Test func toolboxServicesDoesNotLoadTimekeepingWhileLifecycleIsUnfinished() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = FakeNotificationGateway(status: .authorized)
        let services = MacToolboxServices(storageRoot: root, notificationGateway: gateway, mediaEnvironment: MacToolboxMediaEnvironment())
        #expect(services.storageRoot == root)
        await services.start()
        #expect(!services.timekeeping.loaded)
        let requestCount = await gateway.requestCount
        let authorizationReads = await gateway.authorizationReads
        #expect(requestCount == 0)
        #expect(authorizationReads == 0)
        services.shutdown()
        await services.start()
        #expect(!services.timekeeping.loaded)
    }

    @Test func shutdownBeforeServiceStartNeverTouchesFakeGatewayOrStore() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("unused", isDirectory: true)
        let gateway = FakeNotificationGateway(status: .authorized)
        let services = MacToolboxServices(storageRoot: storage, notificationGateway: gateway, mediaEnvironment: MacToolboxMediaEnvironment())
        services.shutdown()
        await services.start()
        let authorizationReads = await gateway.authorizationReads
        #expect(authorizationReads == 0)
        #expect(!services.timekeeping.loaded)
        #expect(!FileManager.default.fileExists(atPath: storage.path))
    }
}

actor FakeNotificationGateway: MacUserNotificationGateway {
    var status: MacTimerAuthorization
    var grantResult: Bool
    private(set) var requestCount = 0
    private(set) var authorizationReads = 0
    private(set) var pending: Set<String> = []
    private(set) var delivered: Set<String> = []
    private(set) var added: [(identifier: String, title: String, body: String, fireAfter: TimeInterval)] = []
    private(set) var removedPending: [String] = []
    private(set) var removedDelivered: [String] = []
    var addWithoutPending = false
    var ignorePendingRemoval = false
    private var blockPending = false
    private var pendingEntered = false
    private var pendingWaiter: CheckedContinuation<Void, Never>?
    private var blockAdd = false
    private var addEntered = false
    private var addWaiter: CheckedContinuation<Void, Never>?

    init(status: MacTimerAuthorization = .authorized, grantResult: Bool = true) {
        self.status = status
        self.grantResult = grantResult
    }

    func authorization() async -> MacTimerAuthorization { authorizationReads += 1; return status }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        if grantResult { status = .authorized }
        return grantResult
    }

    func add(identifier: String, title: String, body: String, fireAfter: TimeInterval) async throws {
        added.append((identifier, title, body, fireAfter))
        if !addWithoutPending { pending.insert(identifier) }
        if blockAdd {
            blockAdd = false
            addEntered = true
            await withCheckedContinuation { addWaiter = $0 }
        }
    }

    func pendingIdentifiers() async -> Set<String> {
        if blockPending {
            blockPending = false
            pendingEntered = true
            await withCheckedContinuation { pendingWaiter = $0 }
        }
        return pending
    }
    func deliveredIdentifiers() async -> Set<String> { delivered }
    func removePending(_ identifiers: [String]) async {
        removedPending += identifiers
        guard !ignorePendingRemoval else { return }
        for id in identifiers { pending.remove(id) }
    }
    func removeDelivered(_ identifiers: [String]) async {
        removedDelivered += identifiers
        for id in identifiers { delivered.remove(id) }
    }

    func seed(delivered ids: [String]) { delivered.formUnion(ids) }
    func seed(pending ids: [String]) { pending.formUnion(ids) }
    func setAddWithoutPending(_ value: Bool) { addWithoutPending = value }
    func setIgnorePendingRemoval(_ value: Bool) { ignorePendingRemoval = value }
    func suspendNextPendingRead() { blockPending = true; pendingEntered = false }
    func waitForPendingRead() async { while !pendingEntered { await Task.yield() } }
    func resumePendingRead() { pendingWaiter?.resume(); pendingWaiter = nil }
    func suspendNextAdd() { blockAdd = true; addEntered = false }
    func waitForAdd() async { while !addEntered { await Task.yield() } }
    func resumeAdd() { addWaiter?.resume(); addWaiter = nil }
    func addedIdentifiers() -> [String] { added.map(\.identifier) }
    func removedPendingIdentifiers() -> [String] { removedPending }
}

@MainActor
@Suite("Mac timer notifications", .serialized)
struct MacTimerNotificationTests {
    private func request(_ id: UUID, generation: UInt64 = 1, remaining: Double = 120,
                         action: ToolboxTimerAlarmAction = .start, running: Bool = true) -> ToolboxTimerAlarmRequest {
        .init(timerID: id, generation: generation, label: "Cooking", remaining: remaining,
              action: action, isRunning: running)
    }

    @Test func schedulingUsesDeadlineAfterSuspension() async throws {
        let clock = FakeTimerClock()
        let gateway = FakeNotificationGateway(status: .authorized)
        let controller = MacTimerNotificationController(gateway: gateway, clockNow: { clock.now })
        await gateway.suspendNextPendingRead()
        let start = Task { try await controller.synchronize(request(UUID(), remaining: 30)) }
        await gateway.waitForPendingRead()
        clock.advance(12)
        await gateway.resumePendingRead()
        let state = try await start.value
        #expect(await gateway.added.first?.fireAfter == 18)
        #expect(state?.remaining == 18)
    }

    @Test func expiredWhileWaitingDoesNotScheduleNotification() async throws {
        let clock = FakeTimerClock()
        let gateway = FakeNotificationGateway(status: .authorized)
        let controller = MacTimerNotificationController(gateway: gateway, clockNow: { clock.now })
        await gateway.suspendNextPendingRead()
        let start = Task { try await controller.synchronize(request(UUID(), remaining: 10)) }
        await gateway.waitForPendingRead()
        clock.advance(11)
        await gateway.resumePendingRead()
        #expect(try await start.value?.phase == .unverified)
        #expect(await gateway.added.isEmpty)
    }

    @Test func confirmationDelayDoesNotExtendRunningState() async throws {
        let clock = FakeTimerClock()
        let gateway = FakeNotificationGateway(status: .authorized)
        let controller = MacTimerNotificationController(gateway: gateway, clockNow: { clock.now })
        await gateway.suspendNextAdd()
        let start = Task { try await controller.synchronize(request(UUID(), remaining: 30)) }
        await gateway.waitForAdd()
        clock.advance(8)
        await gateway.resumeAdd()
        let state = try await start.value
        #expect(await gateway.added.first?.fireAfter == 30)
        #expect(state?.remaining == 22)
    }

    @Test func authorizationIsRequestedOnlyForAnUndecidedUser() async throws {
        let unknown = FakeNotificationGateway(status: .unknown)
        let controller = MacTimerNotificationController(gateway: unknown)
        #expect(try await controller.authorize())
        #expect(await unknown.requestCount == 1)
        #expect(controller.authorization == .authorized)

        let denied = FakeNotificationGateway(status: .denied)
        let deniedController = MacTimerNotificationController(gateway: denied)
        #expect(try await !deniedController.authorize())
        #expect(await denied.requestCount == 0)
        #expect(deniedController.authorization == .denied)
    }

    @Test func deniedPermissionNeverSchedulesAndNeverClaimsSuccess() async throws {
        let gateway = FakeNotificationGateway(status: .denied)
        let controller = MacTimerNotificationController(gateway: gateway)
        let id = UUID()
        let state = try await controller.synchronize(request(id))
        #expect(state?.phase == .unverified)
        #expect(await gateway.added.isEmpty)
    }

    @Test func startPauseResumeAndCancelUseOneConfirmedRequest() async throws {
        let gateway = FakeNotificationGateway(status: .authorized)
        let controller = MacTimerNotificationController(gateway: gateway)
        let id = UUID()

        let started = try await controller.synchronize(request(id, remaining: 120))
        #expect(started?.phase == .running)
        #expect(await gateway.addedIdentifiers() == [MacTimerNotificationController.identifier(for: id, generation: 1)])
        #expect(await gateway.pending == [MacTimerNotificationController.identifier(for: id, generation: 1)])

        let paused = try await controller.synchronize(request(id, generation: 2, remaining: 100, action: .pause, running: false))
        #expect(paused?.phase == .paused && paused?.remaining == 100)
        #expect(await gateway.pending.isEmpty)

        let resumed = try await controller.synchronize(request(id, generation: 3, remaining: 100, action: .resume))
        #expect(resumed?.phase == .running)
        #expect(await gateway.added.count == 2)
        #expect(await gateway.pending.count == 1)

        try await controller.cancel(timerID: id)
        #expect(await gateway.pending.isEmpty)
        #expect(await gateway.delivered.isEmpty)
    }

    @Test func deliveredNotificationBecomesAlertingEvidence() async throws {
        let gateway = FakeNotificationGateway(status: .authorized)
        let controller = MacTimerNotificationController(gateway: gateway)
        let id = UUID()
        await gateway.seed(delivered: [MacTimerNotificationController.identifier(for: id, generation: 1)])
        let state = try await controller.synchronize(request(id, action: .refresh))
        #expect(state?.phase == .alerting)
        #expect(state?.remaining == 0)
        #expect(await gateway.delivered.isEmpty)
    }

    @Test func explicitRestartReplacesStaleDeliveredEvidence() async throws {
        let gateway = FakeNotificationGateway(status: .authorized)
        let controller = MacTimerNotificationController(gateway: gateway)
        let id = UUID()
        await gateway.seed(delivered: [MacTimerNotificationController.identifier(for: id, generation: 1)])
        let state = try await controller.synchronize(request(id, generation: 2, remaining: 60, action: .restart))
        #expect(state?.phase == .running)
        #expect(await gateway.delivered.isEmpty)
        #expect(await gateway.added.count == 1)
        #expect(await gateway.pending.count == 1)
    }

    @Test func missingReadbackIsReportedAsNotScheduled() async throws {
        let gateway = FakeNotificationGateway(status: .authorized)
        let controller = MacTimerNotificationController(gateway: gateway)
        await gateway.setAddWithoutPending(true)
        await #expect(throws: MacTimerNotificationError.notScheduled) {
            _ = try await controller.synchronize(request(UUID()))
        }
    }

    @Test func suspendedStartCannotScheduleAfterPause() async throws {
        let gateway = FakeNotificationGateway(status: .authorized)
        let controller = MacTimerNotificationController(gateway: gateway)
        let id = UUID()
        await gateway.suspendNextPendingRead()
        let start = Task { try await controller.synchronize(request(id)) }
        await gateway.waitForPendingRead()
        var pauseEntered = false
        let pause = Task { @MainActor in
            pauseEntered = true
            return try await controller.synchronize(request(id, generation: 2, action: .pause, running: false))
        }
        while !pauseEntered { await Task.yield() }
        await gateway.resumePendingRead()
        do { _ = try await start.value; Issue.record("superseded start succeeded") }
        catch is CancellationError { }
        #expect(try await pause.value?.phase == .paused)
        #expect(await gateway.added.isEmpty)
        #expect(await gateway.pending.isEmpty)
    }

    @Test func inFlightAddIsRemovedBeforeQueuedDeleteCompletes() async throws {
        let gateway = FakeNotificationGateway(status: .authorized)
        let controller = MacTimerNotificationController(gateway: gateway)
        let id = UUID()
        await gateway.suspendNextAdd()
        let start = Task { try await controller.synchronize(request(id)) }
        await gateway.waitForAdd()
        var cancelEntered = false
        let cancel = Task { @MainActor in
            cancelEntered = true
            try await controller.cancel(timerID: id)
        }
        while !cancelEntered { await Task.yield() }
        await gateway.resumeAdd()
        do { _ = try await start.value; Issue.record("superseded start succeeded") }
        catch is CancellationError { }
        try await cancel.value
        #expect(await gateway.pending.isEmpty)
        #expect(await gateway.removedPending.contains(MacTimerNotificationController.identifier(for: id, generation: 1)))
    }

    @Test func cancelledStartCannotScheduleWithoutSuccessor() async throws {
        let gateway = FakeNotificationGateway(status: .authorized)
        let controller = MacTimerNotificationController(gateway: gateway)
        await gateway.suspendNextPendingRead()
        let start = Task { try await controller.synchronize(request(UUID())) }
        await gateway.waitForPendingRead()
        start.cancel()
        await gateway.resumePendingRead()
        do { _ = try await start.value; Issue.record("cancelled start succeeded") }
        catch is CancellationError { }
        #expect(await gateway.added.isEmpty)
        #expect(await gateway.pending.isEmpty)
    }

    @Test func cancelledInFlightAddIsRemovedWithoutSuccessor() async throws {
        let gateway = FakeNotificationGateway(status: .authorized)
        let controller = MacTimerNotificationController(gateway: gateway)
        await gateway.suspendNextAdd()
        let start = Task { try await controller.synchronize(request(UUID())) }
        await gateway.waitForAdd()
        start.cancel()
        await gateway.resumeAdd()
        do { _ = try await start.value; Issue.record("cancelled start succeeded") }
        catch is CancellationError { }
        #expect(await gateway.pending.isEmpty)
    }

    @Test func resetReportsFailureWhenSystemRetainsNotification() async throws {
        let gateway = FakeNotificationGateway(status: .authorized)
        let controller = MacTimerNotificationController(gateway: gateway)
        let id = UUID()
        await gateway.seed(pending: [MacTimerNotificationController.identifier(for: id, generation: 1)])
        await gateway.setIgnorePendingRemoval(true)
        await #expect(throws: MacTimerNotificationError.notScheduled) {
            _ = try await controller.synchronize(request(id, generation: 2, action: .reset, running: false))
        }
    }

    @Test func staleDeliveredGenerationCannotFinishNewTimer() async throws {
        let gateway = FakeNotificationGateway(status: .authorized)
        let controller = MacTimerNotificationController(gateway: gateway)
        let id = UUID()
        await gateway.seed(delivered: [MacTimerNotificationController.identifier(for: id, generation: 1)])
        let state = try await controller.synchronize(request(id, generation: 2, action: .refresh))
        #expect(state?.phase == .running)
        #expect(await gateway.delivered.isEmpty)
        #expect(await gateway.pending == [MacTimerNotificationController.identifier(for: id, generation: 2)])
    }

    @Test func pruneRemovesOnlyThisFeaturesNotifications() async throws {
        let gateway = FakeNotificationGateway(status: .authorized)
        let controller = MacTimerNotificationController(gateway: gateway)
        let kept = UUID(), stale = UUID(), foreign = "com.example.other.timer"
        await gateway.seed(pending: [
            MacTimerNotificationController.identifier(for: kept),
            MacTimerNotificationController.identifier(for: stale),
            foreign,
        ])
        await gateway.seed(delivered: [
            MacTimerNotificationController.identifier(for: stale),
            foreign + ".delivered",
        ])
        try await controller.prune(keeping: [kept])
        #expect(await gateway.pending == [MacTimerNotificationController.identifier(for: kept), foreign])
        #expect(await gateway.delivered == [foreign + ".delivered"])
        #expect(await gateway.removedPendingIdentifiers().contains(MacTimerNotificationController.identifier(for: kept)) == false)
    }

    @Test func bridgeDrivesTheSharedTimekeepingServiceEndToEnd() async throws {
        let gateway = FakeNotificationGateway(status: .authorized)
        let controller = MacTimerNotificationController(gateway: gateway)
        let root = try MacToolboxTestRoot.unique("timer-bridge")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ToolboxTimekeepingService(
            store: ToolboxTimekeepingStore(url: root.appendingPathComponent("state.json"))
        )
        await service.load(reminders: controller.reminderBridge)
        let start = ToolboxTimeSample.now
        service.addTimer(label: "Bridge", duration: 60, at: start)
        let id = try #require(service.state.timers.first?.id)
        service.setReminder(true, for: id)
        try await waitForTimer { service.reminderStatus[id] == .scheduled }
        #expect(service.state.timers[0].reminder)
        #expect(await gateway.pending.contains { $0.hasPrefix(MacTimerNotificationController.identifier(for: id) + ".") })

        service.pause(id, at: .now)
        #expect(service.state.timers[0].phase == .paused)
        try await waitForTimer { service.reminderStatus[id] == .off || service.reminderStatus[id] == nil }
        #expect(await gateway.pending.contains { $0.hasPrefix(MacTimerNotificationController.identifier(for: id) + ".") } == false)

        service.setReminder(false, for: id)
        try await waitForTimer { service.state.timers[0].reminder == false }
        // The model value changes synchronously, but its bridge cancellation
        // runs asynchronously. Wait for that cancellation to finish before
        // issuing the independent cleanup operation below.
        try await waitForTimer { service.reminderStatus[id] == .off }
        #expect(await gateway.pending.contains { $0.hasPrefix(MacTimerNotificationController.identifier(for: id) + ".") } == false)
        try await controller.cancel(timerID: id)
    }
}
