// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import FloeMacSelfCore
import FloeModels
import FloePersistence

/// The Agent process owns the schedule clock. The shared iPad store owns the
/// calendar, logical occurrence identity, exclusive claim and durable state.
@MainActor
final class MacTaskScheduleCenter: ObservableObject {
    typealias ManualLaunch = @MainActor (UUID) -> Void

    @Published private(set) var records: [TaskScheduleRecord] = []
    @Published private(set) var recent: [TaskScheduleOccurrence] = []
    @Published private(set) var isBusy = false
    @Published private(set) var launching = Set<UUID>()
    @Published private(set) var running = Set<UUID>()
    @Published private(set) var errorMessage: String?
    private weak var workspace: HostAgentWorkspace?
    private var store: SQLiteTaskScheduleStore?
    private var poll: Task<Void, Never>?
    private var wake: AnyCancellable?
    private var availableSince = Date()
    private var lastClockCheck = Date()
    private var reconciled = false

    func bind(store: SQLiteTaskScheduleStore, workspace: HostAgentWorkspace) {
        guard self.store == nil else { return }
        self.store = store
        self.workspace = workspace
        availableSince = Date()
        lastClockCheck = availableSince
        wake = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.availableSince = Date() } }
        startPolling()
    }

    func startPolling() {
        guard store != nil, poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkDue()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }

    func stopPolling() async {
        let task = poll
        task?.cancel()
        await task?.value
        poll = nil
    }

    func reload() async {
        await change { _ in }
    }

    func save(_ draft: TaskScheduleRecord) async -> Bool {
        guard !launching.contains(draft.id), !running.contains(draft.id) else { return false }
        return await change { store in
            try await store.save(draft)
            try await recoverUpstream(draft, store: store, at: Date())
        }
    }

    func linkedSchedules(for conversation: UUID) async -> Set<UUID> {
        guard let store, let linked = try? await store.schedulesLinked(to: conversation) else { return [] }
        return Set(linked.map(\.id))
    }

    func upstreamCompleted(_ runID: UUID) async {
        guard let store else { return }
        do {
            _ = try await store.recordRunCompletion(runID: runID, succeeded: true, cancelled: false, summary: nil, at: Date())
        } catch { showStorageError() }
    }

    func setEnabled(_ schedule: TaskScheduleRecord, enabled: Bool) async {
        await change { store in
            guard !launching.contains(schedule.id) else { return }
            try await store.setEnabled(id: schedule.id, enabled: enabled, at: Date())
            if enabled, let saved = try await store.schedule(id: schedule.id) {
                try await recoverUpstream(saved, store: store, at: Date())
            }
        }
    }

    /// Skip the next pending calendar fire without touching cadence. Mirrors
    /// the iPad plan-detail action and the shared store: the occurrence is
    /// retired (a one-shot plan ends disabled), the plan stays enabled and
    /// `nextExpectedAt` advances to the following fire. Returns the store
    /// receipt so the UI can surface the next fire time; nil on any failure
    /// (busy, launching, storage error) with `errorMessage` set.
    @discardableResult
    func skipNext(_ schedule: TaskScheduleRecord) async -> TaskScheduleSkipResult? {
        guard !isBusy, !launching.contains(schedule.id), !running.contains(schedule.id),
              let store, let workspace, workspace.isReady, !workspace.isTerminating,
              let release = workspace.admitScheduleWork() else { return nil }
        isBusy = true
        defer { isBusy = false; release() }
        do {
            let result = try await store.skipNext(id: schedule.id, at: Date())
            try await refresh(store)
            return result
        } catch {
            showStorageError()
            return nil
        }
    }

    func delete(_ schedule: TaskScheduleRecord) async {
        await change { store in
            guard !launching.contains(schedule.id), !running.contains(schedule.id) else { return }
            try await store.delete(id: schedule.id)
        }
    }

    func runNow(_ schedule: TaskScheduleRecord, onBound: ManualLaunch? = nil) async {
        await change { store in
            guard !launching.contains(schedule.id), !running.contains(schedule.id),
                  let saved = try await store.schedule(id: schedule.id),
                  let occurrence = try await store.runNow(id: schedule.id, at: Date()) else { return }
            try await dispatch(saved, occurrence: occurrence, store: store, onBound: onBound)
        }
    }

    private func checkDue() async {
        guard !Task.isCancelled else { return }
        let now = Date()
        if now.timeIntervalSince(lastClockCheck) > 15 { availableSince = now }
        lastClockCheck = now
        guard !reconciled || records.contains(where: { record in
            guard record.isEnabled, !launching.contains(record.id), !running.contains(record.id) else { return false }
            return record.cadence == .afterSuccess || (record.nextExpectedAt.map { $0 <= now } ?? false)
        }) else { return }
        await change { store in
            if !reconciled {
                _ = try await store.reconcileInterruptedOccurrences(at: now)
                try await refresh(store)
                for record in records {
                    try await recoverUpstream(record, store: store, at: now)
                }
                reconciled = true
            }
            for occurrence in try await store.pendingOccurrences(limit: 200) where occurrence.isUpstreamArmed {
                guard !Task.isCancelled, !launching.contains(occurrence.scheduleID), !running.contains(occurrence.scheduleID),
                      let record = try await store.schedule(id: occurrence.scheduleID),
                      record.isEnabled, record.cadence == .afterSuccess,
                      let upstream = record.upstreamRunID,
                      occurrence.dedupeKey == "upstream:\(upstream.uuidString)" else { continue }
                try await dispatch(record, occurrence: occurrence, store: store)
            }
            for schedule in try await store.due(at: now) {
                guard !Task.isCancelled, !launching.contains(schedule.id), !running.contains(schedule.id),
                      let next = schedule.nextExpectedAt else { continue }
                if next <= availableSince {
                    try await store.recordMissedCalendarOccurrences(id: schedule.id, through: availableSince)
                    continue
                }
                guard let fire = TaskSchedulePlanner.dueFireTimes(record: schedule, now: now).last,
                      fire >= next else { continue }
                let key = TaskSchedulePlanner.dedupeKey(for: fire, record: schedule)
                let id = TaskScheduleOccurrence.stableID(scheduleID: schedule.id, dedupeKey: key)
                let occurrence = TaskScheduleOccurrence(id: id, scheduleID: schedule.id, scheduledFor: fire, dedupeKey: key)
                _ = try await store.enqueueOccurrence(occurrence)
                if try await store.occurrence(id: id)?.state.isTerminal == true {
                    try await store.recordMissedCalendarOccurrences(id: schedule.id, through: now)
                    continue
                }
                try await dispatch(schedule, occurrence: occurrence, store: store)
            }
        }
    }

    /// Reconcile a crash between upstream completion and schedule admission.
    /// The store deduplicates by the concrete upstream run, including after a relaunch.
    private func recoverUpstream(_ record: TaskScheduleRecord, store: SQLiteTaskScheduleStore, at date: Date) async throws {
        guard record.isEnabled, record.cadence == .afterSuccess, let runID = record.upstreamRunID,
              try await workspace?.isCompletedScheduleRun(runID) == true else { return }
        _ = try await store.recordRunCompletion(runID: runID, succeeded: true, cancelled: false, summary: nil, at: date)
    }

    private func dispatch(_ schedule: TaskScheduleRecord, occurrence: TaskScheduleOccurrence,
                          store: SQLiteTaskScheduleStore, onBound: ManualLaunch? = nil) async throws {
        guard try await store.claimOccurrence(id: occurrence.id, at: Date()) else { return }
        launching.insert(schedule.id)
        if workspace?.launchScheduledTask(schedule, occurrence: occurrence, store: store, onBound: onBound) != true {
            await failLaunch(occurrence, store: store)
        }
    }

    func bindLaunched(occurrence: TaskScheduleOccurrence, runID: UUID, conversationID: UUID,
                      store: SQLiteTaskScheduleStore, onBound: ManualLaunch?) async {
        defer { launching.remove(occurrence.scheduleID); running.insert(occurrence.scheduleID) }
        do {
            let now = Date()
            guard try await store.markOccurrenceRunning(id: occurrence.id, runID: runID, conversationID: conversationID, at: now) else {
                errorMessage = MacPermissionsText.t("无法关联这次定时运行。", "Could not link this scheduled run.")
                return
            }
            if occurrence.isManualRun {
                onBound?(conversationID)
                try await store.markManualStarted(id: occurrence.scheduleID, at: now)
            } else {
                try await store.markStarted(id: occurrence.scheduleID, at: now)
            }
            try await refresh(store)
        } catch { showStorageError() }
    }

    func failLaunch(_ occurrence: TaskScheduleOccurrence, store: SQLiteTaskScheduleStore) async {
        defer { launching.remove(occurrence.scheduleID) }
        do {
            let now = Date()
            try await store.finishOccurrence(id: occurrence.id, state: .failed, summary: nil,
                errorText: MacPermissionsText.t("无法启动。请检查项目和所选模型。", "Could not start. Check the project and selected model."), at: now)
            if !occurrence.isManualRun {
                try await store.recordMissedCalendarOccurrences(id: occurrence.scheduleID, through: now)
            }
            try await refresh(store)
        } catch { showStorageError() }
    }

    func finishRun(_ occurrence: TaskScheduleOccurrence, terminal: FloeMacSelfTerminalReceipt?,
                   store: SQLiteTaskScheduleStore) async {
        defer { running.remove(occurrence.scheduleID) }
        do {
            let now = Date()
            if let terminal, terminal.confirmed {
                _ = try await store.recordRunCompletion(runID: terminal.runID, succeeded: terminal.outcome == .completed,
                                                        cancelled: terminal.outcome == .cancelled, summary: nil, at: now)
                if try await store.occurrence(runID: terminal.runID) == nil {
                    try await store.finishOccurrence(id: occurrence.id, state: .interrupted, summary: nil, errorText: nil, at: now)
                }
            } else {
                try await store.finishOccurrence(id: occurrence.id, state: .interrupted, summary: nil, errorText: nil, at: now)
            }
            try await refresh(store)
        } catch { showStorageError() }
    }

    @discardableResult
    private func change(_ operation: (SQLiteTaskScheduleStore) async throws -> Void) async -> Bool {
        guard !isBusy, let store, let workspace, workspace.isReady, !workspace.isTerminating,
              let release = workspace.admitScheduleWork() else { return false }
        isBusy = true
        defer { isBusy = false; release() }
        do {
            try await operation(store)
            try await refresh(store)
            return true
        } catch {
            showStorageError()
            return false
        }
    }

    private func refresh(_ store: SQLiteTaskScheduleStore) async throws {
        let records = try await store.schedules()
        let recent = try await store.recentOccurrences(limit: 48)
        if records != self.records { self.records = records }
        if recent != self.recent { self.recent = recent }
    }

    private func showStorageError() {
        errorMessage = MacPermissionsText.t("无法更新定时任务。请重试。", "Could not update scheduled tasks. Try again.")
    }
}
