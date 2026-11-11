// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(AlarmKit)
import Foundation
import Testing
import FloePersistence
import FloeToolboxUtilities
@testable import FloeApp

@MainActor private final class ManualAlarmProbe: SystemAlarmNativeManaging {
    let isAvailable = true
    var authorization: SystemAlarmAuthorization = .authorized
    var values: [UUID: SystemAlarmNativeSnapshot] = [:]
    var creations: [UUID] = []
    var cancellations: [UUID] = []
    var pauses = 0
    var resumes = 0
    var throwAfterNativeCommit = false
    var onSchedule: (() async -> Void)?
    var observerCount = 0
    private var continuation: AsyncStream<[SystemAlarmNativeSnapshot]>.Continuation!
    private var stream: AsyncStream<[SystemAlarmNativeSnapshot]>!
    init() { stream = AsyncStream { continuation = $0 } }
    var alarmUpdates: AsyncStream<[SystemAlarmNativeSnapshot]> { observerCount += 1; return stream }
    func emit() { continuation.yield(Array(values.values)) }
    func requestAuthorization() async throws -> SystemAlarmAuthorization { authorization }
    func alarms() async throws -> [SystemAlarmNativeSnapshot] { Array(values.values) }
    func schedule(id: UUID, kind: SystemAlarmKind, intendedFireDate: Date?, repeatRule: SystemAlarmRepeat,
                  timerDuration: TimeInterval?, label: String, metadataOwnerReference: String) async throws -> SystemAlarmNativeSnapshot {
        creations.append(id)
        var value = SystemAlarmNativeSnapshot(id: id, state: "countdown")
        value.totalDuration = timerDuration
        value.previousElapsed = 0
        value.fireDate = Date().addingTimeInterval(timerDuration ?? 0)
        values[id] = value
        await onSchedule?()
        if throwAfterNativeCommit { throw Failure.readback }
        return value
    }
    func cancel(id: UUID) async throws { cancellations.append(id); values.removeValue(forKey: id) }
    func pause(id: UUID) async throws {
        guard var value = values[id] else { throw Failure.missing }
        pauses += 1; value.state = "paused"; value.previousElapsed = 17; value.fireDate = nil; values[id] = value
    }
    func resume(id: UUID) async throws {
        guard var value = values[id] else { throw Failure.missing }
        resumes += 1; value.state = "countdown"
        value.fireDate = Date().addingTimeInterval((value.totalDuration ?? 0) - (value.previousElapsed ?? 0))
        values[id] = value
    }
    enum Failure: Error { case readback, missing }
}

@MainActor private final class ManualAlarmGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
@MainActor private func awaitManualAlarm(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard clock.now < deadline else { throw ManualAlarmProbe.Failure.readback }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Suite("Toolbox manual AlarmKit ownership") @MainActor
struct ToolboxTimerAlarmTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-alarm-" + UUID().uuidString).appendingPathComponent("alarms.json")
    }
    private func request(_ id: UUID, _ generation: UInt64, _ action: ToolboxTimerAlarmAction, running: Bool = true) -> ToolboxTimerAlarmRequest {
        .init(timerID: id, generation: generation, label: "Cooking stage", remaining: 120, action: action, isRunning: running)
    }
    @Test func duplicateStartPauseResumeAndRelaunchUseTheSameNativeID() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let native = ManualAlarmProbe(), id = UUID()
        let first = ToolboxTimerReminders(native: native, ledgerURL: url, retireLegacyNotifications: false)
        let started = try await first.synchronize(request(id, 1, .start))
        #expect(started?.phase == .running && native.creations.count == 1)
        _ = try await first.synchronize(request(id, 1, .start))
        #expect(native.creations.count == 1)
        let paused = try await first.synchronize(request(id, 2, .pause, running: false))
        #expect(paused?.phase == .paused && paused?.remaining == 103 && native.pauses == 1)
        let second = ToolboxTimerReminders(native: native, ledgerURL: url, retireLegacyNotifications: false)
        let reopened = try await second.synchronize(request(id, 2, .refresh, running: false))
        #expect(reopened?.phase == .paused && reopened?.remaining == 103)
        let resumed = try await second.synchronize(request(id, 3, .resume))
        #expect(resumed?.phase == .running && native.resumes == 1 && native.creations.count == 1)
    }
    @Test func uncertainNativeCommitIsReadBackWithoutRepeatingTheAlert() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let native = ManualAlarmProbe(), id = UUID(); native.throwAfterNativeCommit = true
        let first = ToolboxTimerReminders(native: native, ledgerURL: url, retireLegacyNotifications: false)
        await #expect(throws: ManualAlarmProbe.Failure.self) { _ = try await first.synchronize(request(id, 1, .start)) }
        let second = ToolboxTimerReminders(native: native, ledgerURL: url, retireLegacyNotifications: false)
        let result = try await second.synchronize(request(id, 1, .refresh))
        #expect(result?.phase == .running && native.creations.count == 1)
    }
    @Test func pruneNeverTouchesAlarmsOutsideTheManualLedger() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let native = ManualAlarmProbe(), id = UUID(), foreign = UUID()
        native.values[foreign] = .init(id: foreign, state: "scheduled")
        let adapter = ToolboxTimerReminders(native: native, ledgerURL: url, retireLegacyNotifications: false)
        _ = try await adapter.synchronize(request(id, 1, .start))
        try await adapter.prune(keeping: [])
        #expect(native.values[foreign] != nil && !native.cancellations.contains(foreign))
        #expect(native.values.count == 1)
    }
    @Test func corruptOwnershipIsPreservedWithoutNativeMutation() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("unreadable ownership".utf8); try original.write(to: url)
        let native = ManualAlarmProbe(), adapter = ToolboxTimerReminders(native: native, ledgerURL: url, retireLegacyNotifications: false)
        await #expect(throws: (any Error).self) { _ = try await adapter.synchronize(request(UUID(), 1, .start)) }
        #expect(try Data(contentsOf: url) == original)
        #expect(native.creations.isEmpty && native.cancellations.isEmpty)
    }
    @Test func enablingAnAlarmForAPausedTimerDoesNotStartIt() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let native = ManualAlarmProbe(), adapter = ToolboxTimerReminders(native: native, ledgerURL: url, retireLegacyNotifications: false), id = UUID()
        let value = try await adapter.synchronize(request(id, 1, .start, running: false))
        #expect(value?.phase == .paused && native.creations.isEmpty)
        _ = try await adapter.synchronize(request(id, 2, .resume))
        #expect(native.creations.count == 1)
    }
    @Test func confirmedCompensationAfterCancellationAllowsResume() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let native = ManualAlarmProbe(), gate = ManualAlarmGate(), id = UUID()
        native.onSchedule = { await gate.wait() }
        let adapter = ToolboxTimerReminders(native: native, ledgerURL: url, retireLegacyNotifications: false)
        let work = Task { try await adapter.synchronize(request(id, 1, .start)) }
        do { try await awaitManualAlarm { native.creations.count == 1 } }
        catch { gate.open(); work.cancel(); _ = await work.result; throw error }
        work.cancel(); gate.open()
        await #expect(throws: CancellationError.self) { _ = try await work.value }
        #expect(native.values.isEmpty && native.cancellations.count == 1)
        _ = try await adapter.synchronize(request(id, 2, .resume))
        #expect(native.creations.count == 2 && native.values.count == 1)
    }
    @Test func observationPersistsPositiveProofBeforeSystemStopAndRelaunch() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let native = ManualAlarmProbe(), id = UUID(); native.throwAfterNativeCommit = true
        let adapter = ToolboxTimerReminders(native: native, ledgerURL: url, retireLegacyNotifications: false)
        await #expect(throws: ManualAlarmProbe.Failure.self) { _ = try await adapter.synchronize(request(id, 1, .start)) }
        var observations: [ToolboxTimerAlarmState] = []
        let reader = Task {
            for await value in adapter.updates() {
                observations.append(value)
                if observations.count == 2 { break }
            }
        }
        do {
            try await awaitManualAlarm { native.observerCount == 1 }; native.emit()
            try await awaitManualAlarm { observations.first?.phase == .running }
            native.values.removeAll(); native.emit()
            try await awaitManualAlarm { observations.count == 2 }
            await reader.value
        } catch { reader.cancel(); await reader.value; throw error }
        #expect(observations.last?.phase == .stopped)
        let reopened = ToolboxTimerReminders(native: native, ledgerURL: url, retireLegacyNotifications: false)
        let status = try await reopened.synchronize(request(id, 1, .refresh))
        #expect(status?.phase == .stopped && native.creations.count == 1)
    }
}
#endif
