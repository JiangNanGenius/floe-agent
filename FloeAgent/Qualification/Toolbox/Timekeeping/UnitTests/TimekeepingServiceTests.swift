import Foundation
import Testing
import FloeToolboxUtilities
@testable import FloeToolboxWorkbenches

@MainActor private final class ReminderProbe {
    var authorizationCalls = 0
    var pruned = 0
    var scheduled: [UUID] = []
    var cancelled: [UUID] = []
    var deferPermission = false
    var permission: CheckedContinuation<Bool, Never>?
    var asked: CheckedContinuation<Void, Never>?
    var returned: CheckedContinuation<Void, Never>?
    var permissionReturned = false
    var scheduleWait: CheckedContinuation<Void, Never>?
    var cancelWait: CheckedContinuation<Void, Never>?
    var bridge: ToolboxTimerReminderBridge {
        .init(authorize: {
            self.authorizationCalls += 1; self.asked?.resume(); self.asked = nil
            let allowed = self.deferPermission ? await withCheckedContinuation { self.permission = $0 } : true
            self.permissionReturned = true; self.returned?.resume(); self.returned = nil
            return allowed
        }, synchronize: { request in
            self.scheduled.append(request.timerID); self.scheduleWait?.resume(); self.scheduleWait = nil
            return .init(timerID: request.timerID, generation: request.generation, phase: request.isRunning ? .running : .paused, remaining: request.remaining)
        }, cancel: { id in
            self.cancelled.append(id); self.cancelWait?.resume(); self.cancelWait = nil
        }, prune: { _ in self.pruned += 1 })
    }
    func waitForQuestion() async {
        if authorizationCalls == 0 { await withCheckedContinuation { asked = $0 } }
    }
    func waitForReturn() async {
        if !permissionReturned { await withCheckedContinuation { returned = $0 } }
    }
    func waitForSchedule() async {
        if scheduled.isEmpty { await withCheckedContinuation { scheduleWait = $0 } }
    }
    func waitForCancel() async {
        if cancelled.isEmpty { await withCheckedContinuation { cancelWait = $0 } }
    }
}

@MainActor private func temporaryClockService() -> (ToolboxTimekeepingService, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (ToolboxTimekeepingService(store: ToolboxTimekeepingStore(url: root.appendingPathComponent("state.json"))), root)
}

@Test @MainActor func loadingTimersDoesNotRequestPermissionAndIsSingleFlight() async {
    let (service, root) = temporaryClockService(); defer { try? FileManager.default.removeItem(at: root) }
    let probe = ReminderProbe()
    let first = Task { await service.load(reminders: probe.bridge) }
    let second = Task { await service.load(reminders: probe.bridge) }
    await first.value; await second.value
    #expect(service.loaded && probe.pruned == 1 && probe.authorizationCalls == 0)
}

@Test @MainActor func latePermissionAfterPauseCannotEnableOrScheduleTimer() async throws {
    let (service, root) = temporaryClockService(); defer { try? FileManager.default.removeItem(at: root) }
    let probe = ReminderProbe(); probe.deferPermission = true
    await service.load(reminders: probe.bridge)
    service.addTimer(label: "Permission fence", duration: 60)
    let id = try #require(service.state.timers.first?.id)
    service.setReminder(true, for: id)
    await probe.waitForQuestion()
    service.pause(id)
    probe.permission?.resume(returning: true); probe.permission = nil
    await probe.waitForReturn(); await Task.yield()
    #expect(service.state.timers.first?.reminder == false)
    #expect(service.state.timers.first?.phase == .paused && probe.scheduled.isEmpty)
}

@Test @MainActor func reminderSchedulesOnlyAfterExplicitActionAndDeletionCancelsIt() async throws {
    let (service, root) = temporaryClockService(); defer { try? FileManager.default.removeItem(at: root) }
    let probe = ReminderProbe(); await service.load(reminders: probe.bridge)
    service.addTimer(label: "Owned timer", duration: 60)
    let id = try #require(service.state.timers.first?.id)
    #expect(probe.authorizationCalls == 0 && probe.scheduled.isEmpty)
    service.setReminder(true, for: id)
    await probe.waitForSchedule()
    #expect(probe.scheduled == [id] && service.state.timers.first?.reminder == true)
    service.remove(id); await probe.waitForCancel()
    #expect(service.state.timers.isEmpty && probe.cancelled.contains(id))
}

@Test @MainActor func foregroundRefreshPreservesExplicitPermissionOperation() async throws {
    let (service, root) = temporaryClockService(); defer { try? FileManager.default.removeItem(at: root) }
    let probe = ReminderProbe(); probe.deferPermission = true
    await service.load(reminders: probe.bridge)
    service.addTimer(label: "Foreground permission", duration: 60)
    let id = try #require(service.state.timers.first?.id)
    service.setReminder(true, for: id)
    await probe.waitForQuestion()
    service.refreshReminders() // The scene becomes active when the permission sheet closes.
    probe.permission?.resume(returning: true); probe.permission = nil
    await probe.waitForSchedule()
    #expect(service.state.timers.first?.reminder == true && probe.scheduled == [id])
}

@Test @MainActor func nativePauseAndStopAreAppliedWithoutStartingAnotherAlarm() async throws {
    let (service, root) = temporaryClockService(); defer { try? FileManager.default.removeItem(at: root) }
    var continuation: AsyncStream<ToolboxTimerAlarmState>.Continuation?
    let stream = AsyncStream<ToolboxTimerAlarmState> { continuation = $0 }
    var requests: [ToolboxTimerAlarmRequest] = []
    let bridge = ToolboxTimerReminderBridge(authorize: { true }, synchronize: { request in
        requests.append(request)
        return .init(timerID: request.timerID, generation: request.generation,
            phase: request.isRunning ? .running : .paused, remaining: request.remaining)
    }, cancel: { _ in }, prune: { _ in }, updates: { stream })
    await service.load(reminders: bridge)
    service.addTimer(label: "Native pause", duration: 120)
    let id = try #require(service.state.timers.first?.id)
    service.setReminder(true, for: id)
    for _ in 0..<500 where service.reminderStatus[id] != .scheduled { try await Task.sleep(for: .milliseconds(10)) }
    let generation = try #require(service.state.timers.first?.generation)
    continuation?.yield(.init(timerID: id, generation: generation, phase: .paused, remaining: 83))
    for _ in 0..<500 where service.state.timers.first?.phase != .paused { try await Task.sleep(for: .milliseconds(10)) }
    #expect(service.state.timers.first?.phase == .paused)
    #expect(service.state.timers.first?.retained == 83)
    #expect(requests.count == 1) // An OS control never schedules another alert.
    continuation?.yield(.init(timerID: id, generation: generation - 1, phase: .running, remaining: 90))
    await Task.yield()
    #expect(service.state.timers.first?.phase == .paused) // stale observation
    continuation?.yield(.init(timerID: id, generation: generation, phase: .stopped, remaining: nil))
    for _ in 0..<500 where service.state.timers.first?.reminder == true { try await Task.sleep(for: .milliseconds(10)) }
    #expect(service.state.timers.first?.reminder == false)
    #expect(service.state.timers.first?.phase == .paused) // absence is not ringing
    continuation?.finish()
}

@Test @MainActor func coldLoadRetiresDisabledAlarmsAndKeepsStopwatchUsableIfCleanupFails() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ToolboxTimekeepingStore(url: root.appendingPathComponent("state.json"))
    var archive = ToolboxTimekeepingArchive()
    archive.timers = [try ToolboxCountdown(label: "Disabled before process death", duration: 120, now: .now)]
    archive.revision = 1
    try await store.save(archive)
    var kept: [UUID]?
    let service = ToolboxTimekeepingService(store: store)
    await service.load(reminders: .init(authorize: { false }, synchronize: { _ in nil }, cancel: { _ in }, prune: {
        kept = $0; throw ToolboxTimekeepingError.invalid
    }))
    #expect(kept == []) // Its old native binding must be retired, not kept by timer id alone.
    #expect(service.loaded)
    #expect(service.issue != nil)
    if let issue = service.issue {
        if case .reminder = issue {} else { Issue.record("Alarm cleanup failure must be surfaced") }
    }
    service.startStopwatch()
    #expect(service.state.stopwatch.running)
    for _ in 0..<500 where service.saving { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!service.saving)
}

@Test @MainActor func failedAlarmStopIsVisibleAndCanBeRetriedWithoutRequestingPermission() async throws {
    let (service, root) = temporaryClockService(); defer { try? FileManager.default.removeItem(at: root) }
    var failStop = true, permissionRequests = 0, stopCalls = 0
    await service.load(reminders: .init(authorize: { permissionRequests += 1; return true }, synchronize: { request in
        .init(timerID: request.timerID, generation: request.generation, phase: .running, remaining: request.remaining)
    }, cancel: { _ in stopCalls += 1; if failStop { throw ToolboxTimekeepingError.invalid } }, prune: { _ in }))
    service.addTimer(label: "Stop failure", duration: 120)
    let id = try #require(service.state.timers.first?.id)
    service.setReminder(true, for: id)
    for _ in 0..<500 where service.reminderStatus[id] != .scheduled { try await Task.sleep(for: .milliseconds(10)) }
    #expect(service.reminderStatus[id] == .scheduled)
    service.setReminder(false, for: id)
    for _ in 0..<500 where service.reminderStatus[id] != .failed { try await Task.sleep(for: .milliseconds(10)) }
    #expect(service.state.timers.first?.reminder == false && service.reminderStatus[id] == .failed)
    failStop = false
    service.setReminder(false, for: id)
    for _ in 0..<500 where service.reminderStatus[id] != .off { try await Task.sleep(for: .milliseconds(10)) }
    #expect(service.reminderStatus[id] == .off && stopCalls == 2 && permissionRequests == 1)
    for _ in 0..<500 where service.saving { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!service.saving)
}
