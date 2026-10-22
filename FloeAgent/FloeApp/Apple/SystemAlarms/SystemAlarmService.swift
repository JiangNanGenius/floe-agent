// FloeApp — S5 C3 system AlarmKit service (native plumbing + recovery).
//
// SPDX-License-Identifier: MPL-2.0
//
// The service owns the real AlarmKit boundary and the durable ledger. It is
// created once at registration (service-owned, never View-owned) and torn
// down only by its owner. It exposes create/list/cancel/status with durable
// pre-mutation intent and genuine unknown-result recovery:
//
//   1. A `queued` intent row (with the exact stable app-owned id) is
//      persisted BEFORE any native mutation. A crash before the native call
//      leaves a `queued` row that the next reconcile converges (no native
//      side effect happened, so nothing is duplicated).
//   2. The row moves `queued → submitted` (CAS) before the native mutation,
//      binding a durable operation receipt. A crash after the native commit
//      but before the save leaves `submitted`, which reconcile reads back
//      against the real AlarmManager state — converging to `created` (native
//      confirms the exact id) or `unknown`, never silently duplicating.
//   3. An unknown schedule/cancel outcome is NOT retried blindly and never
//      reported as success from "no thrown error" alone: the exact stable id
//      is read back from the native manager before the row is reconciled.
//
// Ownership: list/cancel only ever touch alarms recorded for the caller's
// own task/run provenance. A native id that maps to no owned row is never
// adopted, and a cancel that addresses another task's alarm id is refused.

#if canImport(UIKit) && canImport(AlarmKit)
import Foundation
import FloeCore
import FloeTools
import FloePersistence
import AlarmKit

/// One reconciliation verdict for an unfinished (submitted/unknown) row.
enum SystemAlarmReconcileOutcome: String, Sendable, Equatable {
    /// Native readback confirms the exact stable id is scheduled.
    case confirmedCreated
    /// Native readback shows the id is gone; the one-shot already fired or
    /// the cancel committed.
    case confirmedGone
    /// Native readback is unavailable/error; outcome stays unknown (surfaced,
    /// never auto-resumed or auto-cancelled).
    case readbackError
    /// Absence alone cannot settle an unconfirmed native submission.
    case pendingVerification
    /// The recorded id is not in the owned ledger mapping; not adopted.
    case foreign
}

actor SystemAlarmService {
    private let native: any SystemAlarmNativeManaging
    private let store: any SystemAlarmStore
    private let isForeground: @Sendable () async -> Bool

    /// Service-owned observation lifecycle. Started by `start()`, cancelled
    /// exactly once by `stop()`. Bounded: a single subscription, no polling.
    private var observationTask: Task<Void, Never>?
    private var activeMutations: Set<UUID> = []
    private(set) var observationFailure: String?

    init(
        native: any SystemAlarmNativeManaging,
        store: any SystemAlarmStore,
        isForeground: @escaping @Sendable () async -> Bool
    ) {
        self.native = native
        self.store = store
        self.isForeground = isForeground
    }

    // MARK: - Lifecycle (service-owned, not View-owned)

    /// Starts the native observer so launch/explicit reconcile sees real
    /// native state changes. Each native update settles unfinished
    /// (`submitted`/`unknown`) ledger rows against the fresh snapshot
    /// (compare-and-set, bounded to the live-record window) so an alarm the
    /// process missed — a commit observed only via `alarmUpdates` — converges
    /// to `created`, and one that disappeared converges to `cancelled`,
    /// never duplicating and never resurrecting. Idempotent.
    func start() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self, native] in
            guard !Task.isCancelled else { return }
            let stream = await native.alarmUpdates
            for await snapshots in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.reconcileUnfinishedAgainstSnapshot(snapshots)
            }
        }
    }

    /// Tears down only this service's own observation task. The integrator
    /// calls this from app-lifecycle teardown; the observation task is also
    /// cancelled with the service's actor context (an actor `deinit` cannot
    /// touch isolated state, so teardown is explicit here).
    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Authorization

    func authorization() async -> SystemAlarmAuthorization {
        guard native.isAvailable else { return .unavailable }
        let current = await native.authorization
        if current == .notDetermined {
            // The system prompt cannot appear for a backgrounded app; the
            // caller must resurface in the foreground rather than hang.
            guard await isForeground() else { return .foregroundRequired }
            do {
                return try await native.requestAuthorization()
            } catch {
                return .denied
            }
        }
        return current
    }

    // MARK: - Create (durable pre-mutation intent + readback recovery)

    /// Schedules a real native alarm/timer. Persists the `queued` intent row
    /// BEFORE the native mutation, moves it `submitted` (CAS), schedules, then
    /// reconciles the exact stable id against the native readback. Returns
    /// the durable record and the resolved authorization.
    func schedule(
        owner: SystemAlarmOwner,
        kind: SystemAlarmKind,
        intendedTimezone: String,
        intendedFireDate: Date?,
        repeatRule: SystemAlarmRepeat,
        timerDuration: TimeInterval?,
        label: String,
        now: Date = Date(),
        cancellation: CancellationToken? = nil
    ) async throws -> SystemAlarmRecord {
        guard !owner.operationID.isEmpty || !owner.idempotencyKey.isEmpty else {
            throw SystemAlarmError.missingOwner
        }
        let digest = SystemAlarmIdentity.payloadDigest(
            kind: kind,
            intendedTimezone: intendedTimezone,
            intendedFireDate: intendedFireDate,
            repeatRule: repeatRule,
            timerDuration: timerDuration
        )
        let alarmID = SystemAlarmIdentity.stableAlarmID(owner: owner, payloadDigest: digest)
        guard activeMutations.insert(alarmID).inserted else {
            throw SystemAlarmError.operationInProgress
        }
        defer { activeMutations.remove(alarmID) }
        try Self.checkCancellation(cancellation)
        let receiptID = UUID()
        // The existing ledger schema requires a wall-clock hour/minute for
        // every alarm row, including one-shot alarms. Derive those fields
        // from the exact approved instant in its intended zone; never alter
        // the absolute native schedule date or the idempotency payload.
        var repeatHour: Int? = nil
        var repeatMinute: Int? = nil
        if kind == .alarm {
            guard let intendedFireDate, let timezone = TimeZone(identifier: intendedTimezone) else {
                throw SystemAlarmError.invalidRequest("an alarm requires an absolute date and valid timezone")
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timezone
            repeatHour = calendar.component(.hour, from: intendedFireDate)
            repeatMinute = calendar.component(.minute, from: intendedFireDate)
        }

        var record = SystemAlarmRecord(
            id: alarmID,
            ownerTaskID: owner.taskID,
            ownerRunID: owner.runID,
            operationID: owner.operationID,
            idempotencyKey: owner.idempotencyKey,
            payloadDigest: digest,
            kind: kind,
            intendedTimezone: intendedTimezone,
            intendedFireDate: intendedFireDate,
            nativeScheduleDate: repeatRule == .never ? intendedFireDate : nil,
            repeatHour: repeatHour,
            repeatMinute: repeatMinute,
            repeatRule: repeatRule,
            timerDuration: timerDuration,
            labelDigest: SystemAlarmIdentity.labelDigest(label),
            state: .queued,
            operationReceiptID: receiptID,
            createdAt: now,
            updatedAt: now
        )

        // 1. Persist the intent BEFORE the native mutation. Idempotent: a
        //    crash-retry of the same approved call re-enqueues to the same
        //    stable id and does not duplicate.
        _ = try await store.enqueueIntent(record)
        try Self.checkCancellation(cancellation)

        // 2. Move queued → submitted (CAS). Cancellation before this point
        //    leaves only the queued intent; no native side effect occurred.
        guard try await store.markSubmitted(id: alarmID, receiptID: receiptID, at: now) else {
            // The row was already moved (a concurrent/cancelled path settled
            // it). Read back the real recorded state instead of duplicating.
            if let existing = try await store.record(id: alarmID) {
                return existing
            }
            throw SystemAlarmError.cancelledBeforeCommit
        }

        // Cancellation after the intent is durable but before the native call:
        // the native mutation is skipped, and the durable row is reconciled as
        // cancelled (never left half-mutated).
        // No native action was submitted yet. A cancellation here can
        // retire this intent truthfully; cancellation after submission must
        // preserve the committed or unknown outcome instead.
        do {
            try Self.checkCancellation(cancellation)
        } catch {
            _ = try await store.markCancelledAfterCommit(id: alarmID, at: Date())
            throw error
        }
        // 3. Native schedule.
        let snapshot: SystemAlarmNativeSnapshot
        do {
            snapshot = try await native.schedule(
                id: alarmID,
                kind: kind,
                intendedFireDate: intendedFireDate,
                repeatRule: repeatRule,
                timerDuration: timerDuration,
                label: label,
                metadataOwnerReference: owner.logDescription
            )
        } catch {
            // A thrown schedule is an unknown native outcome: the mutation may
            // or may not have committed. Surface it as `unknown` for explicit
            // reconcile — never reported as success, never blindly retried.
            try await store.markUnknown(id: alarmID, at: Date())
            record.state = .unknown
            throw SystemAlarmError.native(String(describing: error))
        }

        // 4. Readback reconciliation: the returned snapshot alone is not ring
        //    evidence. Confirm the exact stable id is present in the native
        //    manager before declaring the alarm created.
        do {
            let nativeAlarms = try await native.alarms()
            let confirmed = nativeAlarms.contains { $0.id == alarmID }
            if confirmed {
                _ = try await store.markCreated(id: alarmID, nativeState: snapshot.state, at: Date())
                record.state = .created
                record.nativeState = snapshot.state
            } else {
                // Returned but readback does not show the exact id: an
                // inconsistent native state — surface as unknown, not success.
                try await store.markUnknown(id: alarmID, at: Date())
                record.state = .unknown
            }
        } catch {
            // Readback error (e.g. maximumLimitReached on the getter): the
            // schedule returned but we could not verify — typed pending
            // verification, not a fabricated success.
            try await store.markUnknown(id: alarmID, at: Date())
            record.state = .unknown
        }
        return try await requiredRecord(id: alarmID)
    }

    // MARK: - List (owner-scoped)

    func list(owner: SystemAlarmOwner) async throws -> [SystemAlarmRecord] {
        try await store.records(ownerTaskID: owner.taskID, ownerRunID: owner.runID)
    }

    // MARK: - Cancel (owner-scoped, committed-result reconciliation)

    /// Cancels a native alarm by its exact stable id, but ONLY when the id is
    /// recorded for the caller's own task/run. A foreign or unknown id is
    /// refused, not adopted. The committed result is reconciled into the
    /// durable row (cancelled after commit is returned as cancelled, not
    /// dropped).
    @discardableResult
    func cancel(owner: SystemAlarmOwner, alarmID: UUID, now: Date = Date(),
                cancellation: CancellationToken? = nil) async throws -> SystemAlarmRecord {
        guard activeMutations.insert(alarmID).inserted else {
            throw SystemAlarmError.operationInProgress
        }
        defer { activeMutations.remove(alarmID) }
        try Self.checkCancellation(cancellation)
        guard let record = try await store.record(id: alarmID) else {
            // Native unknown/unmapped id — not adopted, not cancelled.
            throw SystemAlarmError.native("alarm \(alarmID.uuidString) is not owned by this app")
        }
        guard owner.sameTask(taskID: record.ownerTaskID, runID: record.ownerRunID) else {
            // Another task's alarm: refuse regardless of UUID knowledge.
            throw SystemAlarmError.native("alarm \(alarmID.uuidString) belongs to another task")
        }

        try Self.checkCancellation(cancellation)
        switch record.state {
        case .queued:
            // Not yet committed natively: cancel the intent only, no native call.
            if try await store.cancelQueued(id: alarmID, at: now) {
                guard let cancelled = try await store.record(id: alarmID) else {
                    throw SystemAlarmError.native("cancelled alarm receipt is unavailable")
                }
                return cancelled
            }
            // raced: fall through to reconcile the real current row below
            guard let current = try await store.record(id: alarmID) else { return record }
            return try await reconcileCancel(owner: owner, record: current)
        case .cancelled:
            // Idempotent: the row is already terminal-cancelled. A repeated
            // cancel performs NO second native mutation (a throwing native
            // cancel of an already-gone id must not churn the row back to
            // unknown) and returns the settled record.
            return record
        default:
            return try await reconcileCancel(owner: owner, record: record)
        }
    }

    /// Performs the native cancel for an already-committed row and reconciles
    /// the committed-then-cancelled outcome into the durable ledger.
    private func reconcileCancel(
        owner: SystemAlarmOwner,
        record: SystemAlarmRecord
    ) async throws -> SystemAlarmRecord {
        do {
            try await native.cancel(id: record.id)
            // Readback: confirm the id is actually gone.
            let nativeAlarms = try await native.alarms()
            if nativeAlarms.contains(where: { $0.id == record.id }) {
                // Cancel returned but the id persists: surface unknown.
                try await store.markUnknown(id: record.id, at: Date())
                return try await requiredRecord(id: record.id)
            }
            _ = try await store.markCancelledAfterCommit(id: record.id, at: Date())
            return try await requiredRecord(id: record.id)
        } catch {
            try await store.markUnknown(id: record.id, at: Date())
            throw SystemAlarmError.native(String(describing: error))
        }
    }

    // MARK: - Reconcile (launch / explicit query)

    /// Notifications trigger a fresh read under the same per-alarm gate as
    /// native mutations. A buffered old notification is never absence proof.
    private func reconcileUnfinishedAgainstSnapshot(
        _ snapshots: [SystemAlarmNativeSnapshot]
    ) async {
        do {
            let rows = try await store.liveRecords(limit: 200)
            _ = try await settle(rows)
            observationFailure = nil
        } catch {
            observationFailure = String(describing: type(of: error))
            FloeLogger(category: .tools).error(
                "System alarm observation save/read failed errorType=\(String(describing: type(of: error)))")
        }
    }

    func reconcile(owner: SystemAlarmOwner) async throws -> [(UUID, SystemAlarmReconcileOutcome)] {
        let owned = try await store.records(ownerTaskID: owner.taskID, ownerRunID: owner.runID)
        return try await settle(owned.filter {
            $0.state == .submitted || $0.state == .unknown || $0.state == .created
        })
    }

    private func settle(_ rows: [SystemAlarmRecord]) async throws
        -> [(UUID, SystemAlarmReconcileOutcome)] {
        let eligible = rows.filter { !activeMutations.contains($0.id) }
        let claimed = Set(eligible.map(\.id))
        activeMutations.formUnion(claimed)
        defer { activeMutations.subtract(claimed) }
        var outcomes = rows.filter { !claimed.contains($0.id) }.map {
            ($0.id, SystemAlarmReconcileOutcome.pendingVerification)
        }
        guard !eligible.isEmpty else { return outcomes }
        let current: [SystemAlarmNativeSnapshot]
        do {
            current = try await native.alarms()
        } catch {
            return outcomes + eligible.map { ($0.id, .readbackError) }
        }
        for row in eligible {
            if let snapshot = current.first(where: { $0.id == row.id }) {
                _ = try await store.markCreated(id: row.id, nativeState: snapshot.state, at: Date())
                outcomes.append((row.id, .confirmedCreated))
            } else if row.nativeState != nil || row.state == .created {
                // The ledger contains positive native-create proof, followed
                // by an authoritative absence after all in-process mutations.
                _ = try await store.markCancelledAfterCommit(id: row.id, at: Date())
                outcomes.append((row.id, .confirmedGone))
            } else {
                // A pending creation may not have been submitted, may have
                // failed, or may have fired. Never invent which from absence
                // or silently grant permission to repeat the side effect.
                outcomes.append((row.id, .pendingVerification))
            }
        }
        return outcomes
    }

    private func requiredRecord(id: UUID) async throws -> SystemAlarmRecord {
        guard let record = try await store.record(id: id) else {
            throw SystemAlarmError.native("alarm receipt is unavailable; query status before retrying")
        }
        return record
    }

    private static func checkCancellation(_ cancellation: CancellationToken?) throws {
        if Task.isCancelled || cancellation?.isCancelled == true {
            throw SystemAlarmError.cancelledBeforeCommit
        }
    }
}
#endif
