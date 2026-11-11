// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(AlarmKit)
import Foundation
import UserNotifications
import FloePersistence
import FloeToolboxUtilities

/// Manual timers have their own durable ownership map. They share the native
/// alarm facade and Live Activity, without manufacturing a chat task or run.
@MainActor final class ToolboxTimerReminders {
    static let shared = ToolboxTimerReminders()
    private let native: any SystemAlarmNativeManaging
    private let ledger: ToolboxManualAlarmLedger
    private let retireLegacyNotifications: Bool
    private var records: [UUID: ToolboxManualAlarmRecord] = [:]
    private var loaded = false
    private var tail: Task<Void, Never>?

    init(native: any SystemAlarmNativeManaging = AlarmKitNativeManager(), ledgerURL: URL? = nil,
         retireLegacyNotifications: Bool = true) {
        self.native = native
        self.retireLegacyNotifications = retireLegacyNotifications
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        ledger = ToolboxManualAlarmLedger(url: ledgerURL ?? root.appendingPathComponent("FloeToolbox/Timekeeping/alarms.json"))
    }
    func authorize() async throws -> Bool {
        guard native.isAvailable else { return false }
        switch await native.authorization {
        case .authorized: return true
        case .notDetermined: return try await native.requestAuthorization() == .authorized
        default: return false
        }
    }
    func synchronize(_ request: ToolboxTimerAlarmRequest) async throws -> ToolboxTimerAlarmState? {
        try await serialized {
            try await self.load()
            guard request.remaining.isFinite, (0...ToolboxCountdown.maximumDuration).contains(request.remaining),
                  !request.label.isEmpty, request.label.utf8.count <= 256 else { throw Failure.invalid }
            try Task.checkCancellation()
            var record = self.records[request.timerID]
            if let current = record, request.generation < current.generation { throw CancellationError() }
            if var current = record, current.state == .cancelling {
                try await self.removeNative(current)
                current.state = .reset; self.records[request.timerID] = current
                try await self.save(); record = current
            }
            if request.action == .reset {
                if let current = record { try await self.removeNative(current) }
                let reset = ToolboxManualAlarmRecord(timerID: request.timerID, nativeID: UUID(),
                    generation: request.generation, state: .reset)
                self.records[request.timerID] = reset; try await self.save()
                return .init(timerID: request.timerID, generation: request.generation, phase: .paused, remaining: request.remaining)
            }
            if request.action == .restart, let current = record, current.generation != request.generation {
                try await self.removeNative(current)
                let reset = ToolboxManualAlarmRecord(timerID: request.timerID, nativeID: UUID(),
                    generation: request.generation, state: .reset)
                self.records[request.timerID] = reset; try await self.save()
                record = reset
            }
            if var current = record {
                current.generation = request.generation; self.records[request.timerID] = current
                try await self.save(); record = current
            }
            let alarms = try await self.native.alarms()
            let existing = record.flatMap { row in alarms.first { $0.id == row.nativeID } }
            if var confirmed = record, existing != nil, confirmed.state != .active {
                confirmed.state = .active; self.records[request.timerID] = confirmed
                try await self.save(); record = confirmed
            }
            switch request.action {
            case .refresh:
                guard let record else { return Self.unverified(request) }
                if record.state == .reset {
                    return .init(timerID: request.timerID, generation: request.generation, phase: .paused, remaining: request.remaining)
                }
                return Self.state(record, snapshot: existing)
            case .pause:
                guard let record else { return Self.unverified(request) }
                if existing?.state == "countdown" { try await self.native.pause(id: record.nativeID) }
                return try await self.read(record)
            case .start, .resume, .restart:
                if !request.isRunning {
                    if let record, existing != nil {
                        if existing?.state == "countdown" { try await self.native.pause(id: record.nativeID) }
                        return try await self.read(record)
                    }
                    let waiting = ToolboxManualAlarmRecord(timerID: request.timerID, nativeID: UUID(),
                        generation: request.generation, state: .reset)
                    self.records[request.timerID] = waiting; try await self.save()
                    return .init(timerID: request.timerID, generation: request.generation, phase: .paused, remaining: request.remaining)
                }
                if let record, let existing {
                    if existing.state == "paused" { try await self.native.resume(id: record.nativeID) }
                    return try await self.read(record)
                }
                // An uncertain prior submission is reconciled by its exact id;
                // it is never retried as a new alarm after a crash.
                if let record, record.state == .intent || record.state == .unknown {
                    return Self.unverified(request)
                }
                guard request.remaining > 0, await self.native.authorization == .authorized else { throw Failure.permission }
                let intent = ToolboxManualAlarmRecord(timerID: request.timerID, nativeID: UUID(),
                    generation: request.generation, state: .intent)
                self.records[request.timerID] = intent
                try await self.save() // Durable identity before native mutation.
                var dispatched = false
                do {
                    try Task.checkCancellation()
                    dispatched = true
                    _ = try await self.native.schedule(id: intent.nativeID, kind: .timer,
                        intendedFireDate: nil, repeatRule: .never, timerDuration: request.remaining,
                        label: request.label, metadataOwnerReference: "toolbox:" + request.timerID.uuidString)
                    let found = try await self.native.alarms().first { $0.id == intent.nativeID }
                    guard let found else { throw Failure.notScheduled }
                    var confirmed = intent; confirmed.state = .active
                    self.records[request.timerID] = confirmed; try await self.save()
                    if Task.isCancelled {
                        var cancelling = confirmed; cancelling.state = .cancelling
                        self.records[request.timerID] = cancelling; try await self.save()
                        try await self.removeNative(confirmed)
                        var reset = confirmed; reset.state = .reset
                        self.records[request.timerID] = reset; try await self.save()
                        throw CancellationError()
                    }
                    return Self.state(confirmed, snapshot: found)
                } catch {
                    // Retain the exact id for recovery instead of claiming failure
                    // means there was no external effect.
                    if let current = self.records[request.timerID], current.nativeID == intent.nativeID,
                       current.state != .reset, current.state != .cancelling {
                        var unsettled = intent; unsettled.state = dispatched ? .unknown : .reset
                        self.records[request.timerID] = unsettled; try await self.save()
                    }
                    throw error
                }
            case .reset: preconditionFailure("handled above")
            }
        }
    }
    func cancel(timerID: UUID) async throws {
        try await serialized {
            try await self.load()
            guard var record = self.records[timerID] else { return }
            record.state = .cancelling; self.records[timerID] = record; try await self.save()
            try await self.removeNative(record)
            self.records.removeValue(forKey: timerID); try await self.save()
        }
    }
    func prune(keeping ids: [UUID]) async throws {
        try await serialized {
            try await self.load()
            let kept = Set(ids)
            for row in self.records.values.filter({ !kept.contains($0.timerID) }) {
                var cancelling = row; cancelling.state = .cancelling
                self.records[row.timerID] = cancelling; try await self.save()
                try await self.removeNative(row); self.records.removeValue(forKey: row.timerID)
                try await self.save()
            }
            // Retire only this feature's old notification implementation. No
            // notification permission prompt and no changes to App delegates.
            guard self.retireLegacyNotifications else { return }
            let center = UNUserNotificationCenter.current(), prefix = "floe.toolbox.timer."
            let pending = await center.pendingNotificationRequests()
            let delivered = await center.deliveredNotifications()
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
            center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { $0.hasPrefix(prefix) })
        }
    }
    func updates() -> AsyncStream<ToolboxTimerAlarmState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(24)) { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                for await snapshots in await self.native.alarmUpdates {
                    guard !Task.isCancelled else { break }
                    // Serialize reads after native mutations so a buffered old
                    // notification cannot become absence proof.
                    do {
                        let values: [ToolboxTimerAlarmState] = try await self.serialized {
                            try await self.load()
                            let fresh = try await self.native.alarms()
                            var changed = false
                            for var row in self.records.values where row.state == .intent || row.state == .unknown {
                                if fresh.contains(where: { $0.id == row.nativeID }) {
                                    row.state = .active; self.records[row.timerID] = row; changed = true
                                }
                            }
                            if changed { try await self.save() }
                            return self.records.values.filter { $0.state != .reset }.map { row in
                                Self.state(row, snapshot: fresh.first { $0.id == row.nativeID })
                            }
                        }
                        for value in values { continuation.yield(value) }
                    } catch {
                        for row in self.records.values {
                            continuation.yield(.init(timerID: row.timerID, generation: row.generation,
                                phase: .unverified, remaining: nil))
                        }
                    }
                    _ = snapshots
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private func read(_ record: ToolboxManualAlarmRecord) async throws -> ToolboxTimerAlarmState {
        let alarms = try await native.alarms()
        return Self.state(record, snapshot: alarms.first { $0.id == record.nativeID })
    }
    private static func state(_ row: ToolboxManualAlarmRecord, snapshot: SystemAlarmNativeSnapshot?) -> ToolboxTimerAlarmState {
        guard let snapshot else {
            return .init(timerID: row.timerID, generation: row.generation,
                phase: row.state == .active ? .stopped : .unverified, remaining: nil)
        }
        let phase: ToolboxTimerAlarmState.Phase
        let amount: Double?
        switch snapshot.state {
        case "countdown": phase = .running; amount = snapshot.fireDate.map { max(0, $0.timeIntervalSinceNow) }
        case "paused":
            phase = .paused
            if let total = snapshot.totalDuration, let elapsed = snapshot.previousElapsed { amount = max(0, total - elapsed) }
            else { amount = nil }
        case "alerting": phase = .alerting; amount = 0
        default: phase = .unverified; amount = nil
        }
        return .init(timerID: row.timerID, generation: row.generation,
            phase: (phase == .running || phase == .paused) && amount == nil ? .unverified : phase, remaining: amount)
    }
    private static func unverified(_ request: ToolboxTimerAlarmRequest) -> ToolboxTimerAlarmState {
        .init(timerID: request.timerID, generation: request.generation, phase: .unverified, remaining: nil)
    }
    private func removeNative(_ row: ToolboxManualAlarmRecord) async throws {
        let alarms = try await native.alarms()
        if alarms.contains(where: { $0.id == row.nativeID }) { try await native.cancel(id: row.nativeID) }
        guard try await !native.alarms().contains(where: { $0.id == row.nativeID }) else { throw Failure.notScheduled }
    }
    private func load() async throws {
        guard !loaded else { return }
        records = try await ledger.load(); loaded = true
    }
    private func save() async throws { try await ledger.save(records) }
    private func serialized<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let work = Task { @MainActor in
            await previous?.value
            try Task.checkCancellation()
            return try await body()
        }
        tail = Task { _ = await work.result }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    enum Failure: LocalizedError {
        case permission, invalid, notScheduled
        var errorDescription: String? {
            switch self {
            case .permission: IDELanguageRunText.t("请在系统设置中允许 Floe 使用闹钟。", "Allow Floe alarms in system settings.")
            case .invalid: IDELanguageRunText.t("无法设置此倒计时，请检查时间。", "Check the countdown duration.")
            case .notScheduled: IDELanguageRunText.t("系统计时器尚未确认，请重试。", "The system timer is not confirmed. Try again.")
            }
        }
    }
}

private struct ToolboxManualAlarmRecord: Codable, Sendable {
    enum State: String, Codable { case intent, active, reset, unknown, cancelling }
    var timerID: UUID
    var nativeID: UUID
    var generation: UInt64
    var state: State
}
private actor ToolboxManualAlarmLedger {
    private let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> [UUID: ToolboxManualAlarmRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 131_072 else { throw ToolboxTimekeepingError.corruptArchive }
        let rows = try JSONDecoder().decode([ToolboxManualAlarmRecord].self, from: Data(contentsOf: url))
        guard rows.count <= 32, Set(rows.map(\.timerID)).count == rows.count,
              Set(rows.map(\.nativeID)).count == rows.count else { throw ToolboxTimekeepingError.corruptArchive }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.timerID, $0) })
    }
    func save(_ records: [UUID: ToolboxManualAlarmRecord]) throws {
        _ = try load() // Never overwrite corrupt ownership information.
        guard records.count <= 32 else { throw ToolboxTimekeepingError.limit }
        let data = try JSONEncoder().encode(Array(records.values))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
#endif
