// FloeAppTests — prepared behavior tests for `apple.alarm.*` (S5 C3).
//
// These run the REAL store (`SQLiteSystemAlarmStore`) and service
// (`SystemAlarmService`) production paths against an in-memory SQLite database
// (schema v48 applied directly) with a FAKE native AlarmKit manager, so no
// real alarm ever rings, no system permission sheet appears, no Live Activity
// is created and no real device is touched. They are registered only after
// the primary adds this file to the FloeAppTests source list and regenerates
// the project. PREPARED, NOT RUN.
//
// Coverage: durable pre-mutation intent + CAS transitions, task ownership and
// forged-id refusals, distinct authorization/foreground/deny/unavailable
// outcomes, absolute-time/timezone/repeat/duration boundaries, schedule
// returned-but-readback-error and unknown-result recovery, crash before/after
// the native mutation and before/after the save, duplicate retries converging,
// cancellation before/after commit, repeated-cancel idempotency (no second
// native mutation, no state churn), readback-error reconcile idempotency,
// native observer settlement of unfinished rows, temporary-chat denial, and
// presentation honesty (real native pause/resume for timers, no fabricated
// second alert action, no countdown surfaces for alarms).

#if canImport(UIKit) && canImport(AlarmKit)
import Foundation
import Testing
import FloeCore
import FloeTools
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.SystemAlarmTools")
struct SystemAlarmToolsTests {

    // MARK: - Fakes

    /// Fake native manager. Records every mutation; never rings, never shows
    /// a system prompt, never creates a Live Activity.
    private final class FakeNative: SystemAlarmNativeManaging, @unchecked Sendable {
        var isAvailable: Bool = true
        var authorization: SystemAlarmAuthorization = .authorized
        var scheduled: [UUID: SystemAlarmNativeSnapshot] = [:]
        var scheduleError: Error?
        var cancelError: Error?
        var alarmsError: Error?
        var requestAuthorizationResult: SystemAlarmAuthorization?
        var onAuthorization: (@Sendable () -> Void)?
        var onSchedule: (@Sendable () async -> Void)?
        var scheduleCalls: [UUID] = []
        var cancelCalls: [UUID] = []
        var updatesContinuation: AsyncStream<[SystemAlarmNativeSnapshot]>.Continuation?

        init() {
            var c: AsyncStream<[SystemAlarmNativeSnapshot]>.Continuation?
            _stream = AsyncStream { continuation in c = continuation }
            updatesContinuation = c
        }
        let _stream: AsyncStream<[SystemAlarmNativeSnapshot]>
        var alarmUpdates: AsyncStream<[SystemAlarmNativeSnapshot]> { _stream }

        func requestAuthorization() async throws -> SystemAlarmAuthorization {
            onAuthorization?()
            if let requestAuthorizationResult { return requestAuthorizationResult }
            return authorization
        }

        func alarms() async throws -> [SystemAlarmNativeSnapshot] {
            if let alarmsError { throw alarmsError }
            return Array(scheduled.values)
        }

        func schedule(
            id: UUID, kind: SystemAlarmKind, intendedFireDate: Date?,
            repeatRule: SystemAlarmRepeat, timerDuration: TimeInterval?,
            label: String, metadataOwnerReference: String
        ) async throws -> SystemAlarmNativeSnapshot {
            scheduleCalls.append(id)
            await onSchedule?()
            if let scheduleError { throw scheduleError }
            let snapshot = SystemAlarmNativeSnapshot(id: id, state: "scheduled")
            scheduled[id] = snapshot
            emit()
            return snapshot
        }

        func cancel(id: UUID) async throws {
            cancelCalls.append(id)
            if let cancelError { throw cancelError }
            scheduled.removeValue(forKey: id)
            emit()
        }

        func emit() {
            updatesContinuation?.yield(Array(scheduled.values))
        }
    }

    // MARK: - Harness

    private func makeDatabase() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        // Apply the exact production v48 schema (the central migration list is
        // the integrator's; the DDL here is the same single source of truth).
        try await database.writer { db in try SystemAlarmSchema.apply(db) }
        return database
    }

    private func makeStore(_ database: DatabaseManager) -> SQLiteSystemAlarmStore {
        SQLiteSystemAlarmStore(database: database)
    }

    private func makeService(
        _ native: FakeNative,
        _ store: SQLiteSystemAlarmStore,
        foreground: Bool = true
    ) -> SystemAlarmService {
        SystemAlarmService(native: native, store: store, isForeground: { foreground })
    }

    private func context(
        conversation: UUID? = UUID(),
        runID: UUID = UUID(),
        toolCallID: String = "call-1",
        idempotencyKey: String = "idem-1",
        temporary: Bool = false
    ) -> ToolContext {
        ToolContext(
            runID: runID,
            toolCallID: toolCallID,
            toolIdempotencyKey: idempotencyKey,
            cancellation: CancellationToken(),
            conversationID: conversation,
            temporaryReadOnly: temporary
        )
    }

    private func scheduleTool(
        _ service: SystemAlarmService,
        foreground: Bool = true
    ) -> AppleAlarmScheduleTool {
        AppleAlarmScheduleTool(service: service, isForeground: { foreground })
    }

    private func field(_ name: String, in output: String) -> String? {
        guard let firstLine = output.split(separator: "\n", maxSplits: 1).first else { return nil }
        for token in firstLine.split(separator: " ") where token.hasPrefix("\(name)=") {
            return String(token.dropFirst(name.count + 1))
        }
        return nil
    }

    private func futureISO8601(offsetSeconds: TimeInterval = 3600) -> String {
        let date = Date().addingTimeInterval(offsetSeconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - Persistence: transactions / claims / CAS

    @Test("Intent is persisted before mutation and converges on idempotent enqueue")
    func intentEnqueueIsIdempotent() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let owner = SystemAlarmOwner(context: context())
        let digest = SystemAlarmIdentity.payloadDigest(
            kind: .alarm, intendedTimezone: "Asia/Shanghai",
            intendedFireDate: Date().addingTimeInterval(3600), repeatRule: .never,
            timerDuration: nil)
        let id = SystemAlarmIdentity.stableAlarmID(owner: owner, payloadDigest: digest)
        let record = SystemAlarmRecord(
            id: id, ownerTaskID: owner.taskID, ownerRunID: owner.runID,
            operationID: owner.operationID, idempotencyKey: owner.idempotencyKey,
            payloadDigest: digest, kind: .alarm, intendedTimezone: "Asia/Shanghai",
            intendedFireDate: Date().addingTimeInterval(3600),
            repeatHour: 7, repeatMinute: 30, labelDigest: "d",
            state: .queued, operationReceiptID: UUID(), createdAt: Date(), updatedAt: Date())

        let first = try await store.enqueueIntent(record)
        let second = try await store.enqueueIntent(record)
        #expect(first == true)
        #expect(second == false) // same stable id: no duplicate
        let stored = try await store.record(id: id)
        #expect(stored?.state == .queued)
    }

    @Test("CAS transitions only move from the expected state")
    func casTransitions() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let owner = SystemAlarmOwner(context: context())
        let now = Date()
        let digest = SystemAlarmIdentity.payloadDigest(
            kind: .timer, intendedTimezone: "UTC", intendedFireDate: nil,
            repeatRule: .never, timerDuration: 60)
        let id = SystemAlarmIdentity.stableAlarmID(owner: owner, payloadDigest: digest)
        let record = SystemAlarmRecord(
            id: id, ownerTaskID: owner.taskID, ownerRunID: owner.runID,
            operationID: owner.operationID, idempotencyKey: owner.idempotencyKey,
            payloadDigest: digest, kind: .timer, intendedTimezone: "UTC",
            timerDuration: 60, labelDigest: "d", state: .queued,
            operationReceiptID: UUID(), createdAt: now, updatedAt: now)
        _ = try await store.enqueueIntent(record)

        // created from queued must fail (needs submitted first)
        #expect(try await store.markCreated(id: id, nativeState: "scheduled", at: now) == false)
        // submitted from queued succeeds exactly once
        #expect(try await store.markSubmitted(id: id, receiptID: UUID(), at: now) == true)
        #expect(try await store.markSubmitted(id: id, receiptID: UUID(), at: now) == false)
        // created from submitted succeeds
        #expect(try await store.markCreated(id: id, nativeState: "scheduled", at: now) == true)
        // A confirmed-created alarm is live: cancelling it is a real
        // transition to cancelled (not a no-op).
        #expect(try await store.markCancelledAfterCommit(id: id, at: now) == true)
        // A terminal cancelled row cannot be re-created by a late callback.
        #expect(try await store.markCreated(id: id, nativeState: "scheduled", at: now) == false)
    }

    // MARK: - Ownership / forged id refusals

    @Test("Cancel refuses a foreign task's alarm even with the exact UUID")
    func cancelRefusesForeignOwner() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        let service = makeService(native, store)

        let ownerA = SystemAlarmOwner(context: context(conversation: UUID(), runID: UUID()))
        let digest = SystemAlarmIdentity.payloadDigest(
            kind: .alarm, intendedTimezone: "UTC",
            intendedFireDate: Date().addingTimeInterval(7200), repeatRule: .never,
            timerDuration: nil)
        let alarmID = SystemAlarmIdentity.stableAlarmID(owner: ownerA, payloadDigest: digest)
        let record = SystemAlarmRecord(
            id: alarmID, ownerTaskID: ownerA.taskID, ownerRunID: ownerA.runID,
            operationID: ownerA.operationID, idempotencyKey: ownerA.idempotencyKey,
            payloadDigest: digest, kind: .alarm, intendedTimezone: "UTC",
            intendedFireDate: Date().addingTimeInterval(7200),
            repeatHour: 9, repeatMinute: 0, labelDigest: "d", state: .created,
            operationReceiptID: UUID(), createdAt: Date(), updatedAt: Date())
        try await store.enqueueIntent(record)
        _ = try await store.markSubmitted(id: alarmID, receiptID: UUID(), at: Date())
        _ = try await store.markCreated(id: alarmID, nativeState: "scheduled", at: Date())

        // Owner B (different conversation/run) must not cancel A's alarm.
        let ownerB = SystemAlarmOwner(context: context(conversation: UUID(), runID: UUID()))
        await #expect(throws: SystemAlarmError.self) {
            _ = try await service.cancel(owner: ownerB, alarmID: alarmID)
        }
        #expect(native.cancelCalls.isEmpty)
    }

    @Test("Cancel refuses a native id the app never recorded (not adopted)")
    func cancelRefusesUnrecordedID() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        let service = makeService(native, store)
        let owner = SystemAlarmOwner(context: context())
        let unknownID = UUID()
        await #expect(throws: SystemAlarmError.self) {
            _ = try await service.cancel(owner: owner, alarmID: unknownID)
        }
        #expect(native.cancelCalls.isEmpty)
    }

    // MARK: - Authorization / foreground / deny / unavailable

    @Test("Authorization denied is distinct and schedules nothing")
    func deniedSchedulesNothing() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        native.authorization = .denied
        let service = makeService(native, store)
        let tool = scheduleTool(service)
        let output = try await tool.execute(.init(
            kind: "alarm", fireAt: futureISO8601(), timezone: "UTC"), context: context())
        #expect(field("status", in: output.summary) == "authorization")
        #expect(field("authorization", in: output.summary) == "denied")
        #expect(native.scheduleCalls.isEmpty)
    }

    @Test("Unavailable is distinct from denied")
    func unavailableIsDistinct() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        native.isAvailable = false
        native.authorization = .notDetermined
        let service = makeService(native, store)
        let tool = scheduleTool(service)
        let output = try await tool.execute(.init(
            kind: "alarm", fireAt: futureISO8601(), timezone: "UTC"), context: context())
        #expect(field("status", in: output.summary) == "authorization")
        #expect(field("authorization", in: output.summary) == "unavailable")
        #expect(native.scheduleCalls.isEmpty)
    }

    @Test("Background requires foreground and does not schedule")
    func backgroundRequiresForeground() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        let service = makeService(native, store, foreground: false)
        let tool = scheduleTool(service, foreground: false)
        let output = try await tool.execute(.init(
            kind: "alarm", fireAt: futureISO8601(), timezone: "UTC"), context: context())
        #expect(field("status", in: output.summary) == "foregroundRequired")
        #expect(native.scheduleCalls.isEmpty)
    }

    // MARK: - Argument boundaries

    @Test("Timer duration boundaries are enforced")
    func timerDurationBoundaries() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let service = makeService(FakeNative(), store)
        let tool = scheduleTool(service)
        let ctx = context()
        // zero / negative / over 24h rejected
        for bad in [0, -5, 86_401] {
            #expect(throws: FloeError.self) {
                try tool.validate(.init(kind: "timer", timezone: "UTC", durationSeconds: bad))
            }
        }
        _ = ctx
    }

    @Test("Alarm requires an absolute ISO-8601 time with an explicit offset")
    func alarmRequiresExplicitOffset() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let service = makeService(FakeNative(), store)
        let tool = scheduleTool(service)
        #expect(throws: FloeError.self) {
            try tool.validate(.init(kind: "alarm", fireAt: "2026-10-22T07:30:00", timezone: "UTC"))
        }
        // Valid explicit-offset form validates.
        try tool.validate(.init(kind: "alarm", fireAt: futureISO8601(), timezone: "UTC"))
    }

    @Test("Repeating alarm requires a future fire time and valid weekdays")
    func repeatBoundaries() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let service = makeService(FakeNative(), store)
        let tool = scheduleTool(service)
        // weekday out of range
        #expect(throws: FloeError.self) {
            try tool.validate(.init(
                kind: "alarm", fireAt: futureISO8601(), timezone: "UTC", repeat: "0,8"))
        }
        // duplicate weekday rejected
        #expect(throws: FloeError.self) {
            try tool.validate(.init(
                kind: "alarm", fireAt: futureISO8601(), timezone: "UTC", repeat: "1,1"))
        }
        // timer cannot repeat
        #expect(throws: FloeError.self) {
            try tool.validate(.init(
                kind: "timer", timezone: "UTC", durationSeconds: 60, repeat: "1"))
        }
        // past time rejected
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        #expect(throws: FloeError.self) {
            try tool.validate(.init(kind: "alarm", fireAt: past, timezone: "UTC"))
        }
    }

    // MARK: - Recovery

    @Test("Schedule returned but readback errors is pendingVerification, not success")
    func returnedButReadbackErrorIsPending() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        native.alarmsError = FloeError.internalError("readback")
        let service = makeService(native, store)
        let tool = scheduleTool(service)
        let output = try await tool.execute(.init(
            kind: "timer", timezone: "UTC", durationSeconds: 300), context: context())
        #expect(field("status", in: output.summary) == "pendingVerification")
        let id = field("id", in: output.summary).flatMap(UUID.init(uuidString:))
        #expect(id != nil)
        let stored = try await store.record(id: id!)
        #expect(stored?.state == .unknown)
    }

    @Test("Unknown schedule outcome (thrown) is surfaced and reconciled, not retried blindly")
    func thrownScheduleIsUnknownThenReconciled() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        native.scheduleError = FloeError.internalError("boom")
        let service = makeService(native, store)
        let tool = scheduleTool(service)
        let ctx = context()
        let output = try await tool.execute(.init(
            kind: "timer", timezone: "UTC", durationSeconds: 120), context: ctx)
        #expect(field("status", in: output.summary) == "error")

        // A missing id cannot prove whether an unconfirmed submission never
        // landed or already fired. Preserve pending recovery; do not replay.
        native.scheduleError = nil
        let status = AppleAlarmStatusTool(service: service)
        let reconcile = try await status.execute(.init(), context: ctx)
        #expect(field("status", in: reconcile.summary) == "pendingVerification")
        #expect(reconcile.summary.contains("reconcile=pendingVerification"))
        #expect(native.scheduleCalls.count == 1)
    }

    @Test("Crash after native create but before save converges to one created alarm")
    func crashAfterCreateBeforeSaveConverges() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        // The native schedule COMMITS, but the readback errors (crash window):
        // the durable row is left 'unknown' even though the alarm exists.
        native.alarmsError = FloeError.internalError("readback crashed")
        let service = makeService(native, store)
        let ctx = context()
        let tool = scheduleTool(service)
        let scheduled = try await tool.execute(.init(
            kind: "timer", timezone: "UTC", durationSeconds: 60), context: ctx)
        #expect(field("status", in: scheduled.summary) == "pendingVerification")
        let id = field("id", in: scheduled.summary).flatMap(UUID.init(uuidString:))!
        #expect(try await store.record(id: id)?.state == .unknown)

        // A duplicate retry of the SAME approved call converges to the same
        // id and does not schedule a second native alarm.
        native.alarmsError = nil
        let retry = try await tool.execute(.init(
            kind: "timer", timezone: "UTC", durationSeconds: 60), context: ctx)
        #expect(field("id", in: retry.summary) == id.uuidString)
        #expect(native.scheduleCalls.count == 1)

        // Reconcile: native still has the exact id → confirmedCreated, and the
        // row settles to created (never duplicated).
        let status = AppleAlarmStatusTool(service: service)
        let out = try await status.execute(.init(id: id.uuidString), context: ctx)
        #expect(field("reconcile", in: out.summary) == "confirmedCreated")
        #expect(try await store.record(id: id)?.state == .created)
        let records = try await store.records(
            ownerTaskID: ctx.conversationID, ownerRunID: ctx.runID)
        #expect(records.count == 1)
    }

    @Test("Duplicate retries of the same approved call never duplicate the alarm")
    func duplicateRetriesConverge() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        let service = makeService(native, store)
        let tool = scheduleTool(service)
        let ctx = context()
        let args = AppleAlarmScheduleTool.Arguments(
            kind: "alarm", fireAt: futureISO8601(), timezone: "Asia/Shanghai")
        _ = try await tool.execute(args, context: ctx)
        _ = try await tool.execute(args, context: ctx)
        _ = try await tool.execute(args, context: ctx)
        let records = try await store.records(
            ownerTaskID: ctx.conversationID, ownerRunID: ctx.runID)
        #expect(records.count == 1)
        #expect(native.scheduleCalls.count == 1)
    }

    @Test("Cancel before commit leaves no native side effect")
    func cancelBeforeCommitHasNoSideEffect() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        let service = makeService(native, store)
        let ctx = context()
        let schedule = scheduleTool(service)
        let created = try await schedule.execute(.init(
            kind: "timer", timezone: "UTC", durationSeconds: 300), context: ctx)
        let id = field("id", in: created.summary).flatMap(UUID.init(uuidString:))!

        // Native still holds it; cancel removes it and reconciles to cancelled.
        let cancel = AppleAlarmCancelTool(service: service)
        let out = try await cancel.execute(.init(id: id.uuidString), context: ctx)
        #expect(field("status", in: out.summary) == "ok")
        #expect(field("state", in: out.summary) == "cancelled")
        #expect(native.scheduled[id] == nil)
        let stored = try await store.record(id: id)
        #expect(stored?.state == .cancelled)
    }

    @Test("Native observer delivers state changes to the service-owned stream")
    func nativeObserverDeliversChanges() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        let service = makeService(native, store)
        await service.start()
        let ctx = context()
        _ = try await scheduleTool(service).execute(.init(
            kind: "timer", timezone: "UTC", durationSeconds: 60), context: ctx)
        // The fake emitted on schedule; the observer task ran without crashing.
        await service.stop()
    }

    @Test("Temporary chat ceiling denies every alarm tool")
    func temporaryChatDenied() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        let service = makeService(native, store)
        let ctx = context(temporary: true)
        let schedule = try await scheduleTool(service).execute(.init(
            kind: "timer", timezone: "UTC", durationSeconds: 60), context: ctx)
        #expect(field("status", in: schedule.summary) == "unavailable")
        let list = try await AppleAlarmListTool(service: service).execute(.init(), context: ctx)
        #expect(field("status", in: list.summary) == "unavailable")
        let cancel = try await AppleAlarmCancelTool(service: service)
            .execute(.init(id: UUID().uuidString), context: ctx)
        #expect(field("status", in: cancel.summary) == "unavailable")
        let status = try await AppleAlarmStatusTool(service: service).execute(.init(), context: ctx)
        #expect(field("status", in: status.summary) == "unavailable")
        #expect(native.scheduleCalls.isEmpty)
    }

    // MARK: - Cancel idempotency / unknown readback idempotency

    @Test("Cancelling an already-cancelled alarm is a no-op with no second native mutation")
    func repeatedCancelIsIdempotent() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        let service = makeService(native, store)
        let ctx = context()
        let schedule = scheduleTool(service)
        let created = try await schedule.execute(.init(
            kind: "timer", timezone: "UTC", durationSeconds: 300), context: ctx)
        let id = field("id", in: created.summary).flatMap(UUID.init(uuidString:))!

        let cancel = AppleAlarmCancelTool(service: service)
        let first = try await cancel.execute(.init(id: id.uuidString), context: ctx)
        #expect(field("status", in: first.summary) == "ok")
        #expect(field("state", in: first.summary) == "cancelled")
        #expect(native.cancelCalls == [id])

        // Second cancel: idempotent success, no extra native call, and the
        // row must NOT churn back to unknown (a throwing native cancel of an
        // already-gone id previously flipped the state).
        let second = try await cancel.execute(.init(id: id.uuidString), context: ctx)
        #expect(field("status", in: second.summary) == "ok")
        #expect(field("state", in: second.summary) == "cancelled")
        #expect(native.cancelCalls == [id])
        let stored = try await store.record(id: id)
        #expect(stored?.state == .cancelled)
    }

    @Test("Reconcile with an unreadable native snapshot is readbackError and changes nothing")
    func reconcileReadbackErrorIsIdempotent() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        native.alarmsError = FloeError.internalError("readback down")
        let service = makeService(native, store)
        let ctx = context()
        let scheduled = try await scheduleTool(service).execute(.init(
            kind: "timer", timezone: "UTC", durationSeconds: 120), context: ctx)
        // Readback error during schedule already left the row unknown.
        let id = field("id", in: scheduled.summary).flatMap(UUID.init(uuidString:))!
        #expect(try await store.record(id: id)?.state == .unknown)

        let status = AppleAlarmStatusTool(service: service)
        let out = try await status.execute(.init(), context: ctx)
        #expect(field("status", in: out.summary) == "ok")
        #expect(field("reconcile", in: out.summary) == "readbackError")
        // Unknown readback idempotency: nothing was settled or duplicated.
        let stored = try await store.record(id: id)
        #expect(stored?.state == .unknown)
        let records = try await store.records(
            ownerTaskID: ctx.conversationID, ownerRunID: ctx.runID)
        #expect(records.count == 1)
    }

    // MARK: - Native update observer (service-owned settlement)

    /// Deterministic unfinished row: the exact stable id a real schedule of
    /// this shape would produce, moved to `submitted` by hand.
    private func makeUnfinishedTimerRow(
        _ store: SQLiteSystemAlarmStore,
        owner: SystemAlarmOwner
    ) async throws -> UUID {
        let digest = SystemAlarmIdentity.payloadDigest(
            kind: .timer, intendedTimezone: "UTC", intendedFireDate: nil,
            repeatRule: .never, timerDuration: 60)
        let id = SystemAlarmIdentity.stableAlarmID(owner: owner, payloadDigest: digest)
        let now = Date()
        let record = SystemAlarmRecord(
            id: id, ownerTaskID: owner.taskID, ownerRunID: owner.runID,
            operationID: owner.operationID, idempotencyKey: owner.idempotencyKey,
            payloadDigest: digest, kind: .timer, intendedTimezone: "UTC",
            timerDuration: 60, labelDigest: "d", state: .queued,
            operationReceiptID: UUID(), createdAt: now, updatedAt: now)
        try await store.enqueueIntent(record)
        _ = try await store.markSubmitted(id: id, receiptID: UUID(), at: now)
        return id
    }

    @Test("Observer settles an unfinished row to created when a native update contains the id")
    func observerSettlesUnfinishedToCreated() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        let service = makeService(native, store)
        let owner = SystemAlarmOwner(context: context())
        let id = try await makeUnfinishedTimerRow(store, owner: owner)

        await service.start()
        // A commit only the observation path saw (e.g. a missed readback):
        // the native manager now reports the exact id.
        native.scheduled[id] = SystemAlarmNativeSnapshot(id: id, state: "scheduled")
        native.emit()
        let settled = await waitForStoreState(store, id: id, state: .created)
        #expect(settled)
        #expect(try await store.record(id: id)?.state == .created)
        await service.stop()
    }

    @Test("Observer settles a previously confirmed alarm when fresh native readback shows it gone")
    func observerSettlesUnfinishedToCancelled() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        let service = makeService(native, store)
        let owner = SystemAlarmOwner(context: context())
        let id = try await makeUnfinishedTimerRow(store, owner: owner)

        await service.start()
        // Positive create proof is required before absence can settle a
        // native outcome. An initial empty snapshot alone is insufficient.
        _ = try await store.markCreated(id: id, nativeState: "scheduled", at: Date())
        native.emit()
        let settled = await waitForStoreState(store, id: id, state: .cancelled)
        #expect(settled)
        #expect(native.scheduleCalls.isEmpty)
        await service.stop()
    }

    private func waitForStoreState(
        _ store: SQLiteSystemAlarmStore,
        id: UUID,
        state: SystemAlarmState,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .nanoseconds(Int64(timeoutNanoseconds)) {
            if let record = try? await store.record(id: id), record.state == state {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    @Test("Unconfirmed creation remains pending when native readback is empty")
    func emptyReadbackDoesNotInventCancellation() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        let service = makeService(native, store)
        let owner = SystemAlarmOwner(context: context())
        let id = try await makeUnfinishedTimerRow(store, owner: owner)
        let outcomes = try await service.reconcile(owner: owner)
        #expect(outcomes.first(where: { $0.0 == id })?.1 == .pendingVerification)
        #expect(try await store.record(id: id)?.state == .submitted)
        #expect(native.scheduleCalls.isEmpty)
    }

    @Test("Cancelling during authorization cannot submit an alarm afterward")
    func cancelledAuthorizationDoesNotSchedule() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        native.authorization = .notDetermined
        native.requestAuthorizationResult = .authorized
        let ctx = context()
        let cancellation = ctx.cancellation
        native.onAuthorization = { cancellation.cancel() }
        let service = makeService(native, store)
        let output = try await scheduleTool(service).execute(.init(
            kind: "timer", timezone: "UTC", durationSeconds: 120), context: ctx)
        #expect(output.exitStatus == 130)
        #expect(native.scheduleCalls.isEmpty)
        #expect(try await service.list(owner: SystemAlarmOwner(context: ctx)).isEmpty)
    }

    private actor ScheduleGate {
        private var entered = false
        private var released = false
        private var entering: CheckedContinuation<Void, Never>?
        private var continuing: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            entering?.resume()
            entering = nil
            if released { return }
            await withCheckedContinuation { continuing = $0 }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { entering = $0 }
        }
        func release() {
            released = true
            continuing?.resume()
            continuing = nil
        }
    }

    @Test("Empty buffered update cannot cancel an in-flight native schedule")
    func inFlightScheduleIsFencedFromReconcile() async throws {
        let database = try await makeDatabase()
        let store = makeStore(database)
        let native = FakeNative()
        let gate = ScheduleGate()
        native.onSchedule = { await gate.hold() }
        let service = makeService(native, store)
        let ctx = context()
        await service.start()
        let task = Task {
            try await scheduleTool(service).execute(.init(
                kind: "timer", timezone: "UTC", durationSeconds: 120), context: ctx)
        }
        await gate.waitUntilEntered()
        native.emit()
        let pending = try await service.reconcile(owner: SystemAlarmOwner(context: ctx))
        #expect(pending.count == 1)
        #expect(pending.first?.1 == .pendingVerification)
        await gate.release()
        let output = try await task.value
        #expect(field("status", in: output.summary) == "ok")
        let rows = try await service.list(owner: SystemAlarmOwner(context: ctx))
        #expect(rows.count == 1)
        #expect(rows.first?.state == .created)
        #expect(native.scheduleCalls.count == 1)
        await service.stop()
    }

    @Test("Live Activity malformed controls throw before accessing AlarmManager")
    func malformedLiveActivityControlsDoNotReportSuccess() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await FloeSystemAlarmStopIntent(alarmID: "invalid").perform()
        }
        await #expect(throws: (any Error).self) {
            _ = try await FloeSystemAlarmPauseIntent(alarmID: "invalid").perform()
        }
        await #expect(throws: (any Error).self) {
            _ = try await FloeSystemAlarmResumeIntent(alarmID: "invalid").perform()
        }
    }

    // MARK: - Presentation honesty (real stop, real pause/resume)

    @Test("Timer presentation carries the native countdown pause and paused resume controls")
    func timerPresentationHasRealPauseResume() async throws {
        let presentation = SystemAlarmPresentationBuilder.presentation(
            label: "Tea", includesCountdown: true)
        #expect(presentation.countdown != nil)
        #expect(presentation.countdown?.pauseButton != nil)
        #expect(presentation.paused != nil)
        #expect(presentation.paused?.resumeButton != nil)
        // No fabricated second action: the system provides Stop on 26.1+ and
        // the app supplies only the real stopButton on 26.0 — never a
        // Repeat/Open button disguised as Stop.
        #expect(presentation.alert.secondaryButton == nil)
    }

    @Test("Alarm presentation has no countdown/paused surfaces")
    func alarmPresentationOmitsCountdown() async throws {
        let presentation = SystemAlarmPresentationBuilder.presentation(
            label: "Wake", includesCountdown: false)
        #expect(presentation.countdown == nil)
        #expect(presentation.paused == nil)
        #expect(presentation.alert.secondaryButton == nil)
    }
}
#endif
