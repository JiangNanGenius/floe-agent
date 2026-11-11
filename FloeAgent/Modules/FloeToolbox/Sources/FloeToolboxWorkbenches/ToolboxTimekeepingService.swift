import Foundation
import Combine
import FloeToolboxUtilities

@MainActor public struct ToolboxTimerReminderBridge {
    public var authorize: () async throws -> Bool
    public var synchronize: (ToolboxTimerAlarmRequest) async throws -> ToolboxTimerAlarmState?
    public var cancel: (UUID) async throws -> Void
    public var prune: ([UUID]) async throws -> Void
    public var updates: (() -> AsyncStream<ToolboxTimerAlarmState>)?
    public init(authorize: @escaping () async throws -> Bool,
                synchronize: @escaping (ToolboxTimerAlarmRequest) async throws -> ToolboxTimerAlarmState?,
                cancel: @escaping (UUID) async throws -> Void,
                prune: @escaping ([UUID]) async throws -> Void,
                updates: (() -> AsyncStream<ToolboxTimerAlarmState>)? = nil) {
        self.authorize = authorize; self.synchronize = synchronize; self.cancel = cancel
        self.prune = prune; self.updates = updates
    }
}

public enum ToolboxClockIssue: Equatable { case load, save, export, limit, invalid, reminder(String) }
public enum ToolboxReminderStatus: Equatable { case off, working, scheduled, ringing, failed }
private struct ToolboxClockLoadResult: Sendable {
    var archive: ToolboxTimekeepingArchive
    var alarmError: String?
}

/// Service ownership keeps stopwatch and timer state alive across navigation.
/// No background polling or audio keepalive is required to measure elapsed time.
@MainActor public final class ToolboxTimekeepingService: ObservableObject {
    public static let shared = ToolboxTimekeepingService()
    @Published public private(set) var state = ToolboxTimekeepingArchive()
    @Published public private(set) var loaded = false
    @Published public private(set) var loading = false
    @Published public private(set) var saving = false
    @Published public var issue: ToolboxClockIssue?
    @Published public private(set) var reminderStatus: [UUID: ToolboxReminderStatus] = [:]
    private let store: ToolboxTimekeepingStore
    private var bridge: ToolboxTimerReminderBridge?
    private var loadTask: Task<ToolboxClockLoadResult, Error>?
    private var saveTask: Task<Void, Never>?
    private var reminderTasks: [UUID: Task<Void, Never>] = [:]
    private var reminderOperations: [UUID: UUID] = [:]
    private var authorizing: Set<UUID> = []
    private var pendingRefresh: Set<UUID> = []
    private var observationTask: Task<Void, Never>?

    public init(store: ToolboxTimekeepingStore? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.store = store ?? ToolboxTimekeepingStore(url: root.appendingPathComponent("FloeToolbox/Timekeeping/state.json"))
    }

    public func load(reminders: ToolboxTimerReminderBridge? = nil) async {
        if let reminders { bridge = reminders }
        if loaded { observeNativeTimers(); refreshReminders(); return }
        loading = true
        let task: Task<ToolboxClockLoadResult, Error>
        if let existing = loadTask { task = existing }
        else {
            let store = store, bridge = bridge
            task = Task {
                var value = try await store.load()
                value.recover(at: .now)
                // Single-flight before publishing loaded state: no new timer
                // can race removal of orphaned notifications after a crash.
                do {
                    try await bridge?.prune(value.timers.filter(\.reminder).map(\.id))
                    return ToolboxClockLoadResult(archive: value, alarmError: nil)
                } catch {
                    // An alarm permission/ownership problem must not disable
                    // the independent stopwatch and silent countdowns.
                    return ToolboxClockLoadResult(archive: value, alarmError: error.localizedDescription)
                }
            }
            loadTask = task
        }
        do {
            let value = try await task.value
            if !loaded {
                state = value.archive; loaded = true; issue = value.alarmError.map { .reminder($0) }
                persist()
                for id in state.timers.map(\.id) where timer(id)?.reminder == true { reconcileReminder(id) }
                observeNativeTimers()
            }
        } catch { if !loaded { issue = .load } }
        loading = false; loadTask = nil
    }

    public func startStopwatch(at now: ToolboxTimeSample = .now) {
        change { $0.stopwatch.start(at: now) }
    }
    public func pauseStopwatch(at now: ToolboxTimeSample = .now) {
        change { $0.stopwatch.pause(at: now) }
    }
    public func resetStopwatch() { change { $0.stopwatch.reset() } }
    public func lap(at now: ToolboxTimeSample = .now) {
        change { try $0.stopwatch.lap(at: now) }
    }
    public func acknowledgeClockReview() { change { $0.clockReview = false } }
    public func rebuildRecords() async {
        guard !loaded, !loading else { return }
        loading = true
        do {
            let value = try await store.rebuildPreservingOriginal()
            do { try await bridge?.prune([]); issue = nil }
            catch { issue = .reminder(error.localizedDescription) }
            state = value; loaded = true
        } catch { issue = .load }
        loading = false
    }

    public func addTimer(label: String, duration: Double, ring: Bool = false, at now: ToolboxTimeSample = .now) {
        var added: UUID?
        change {
            guard $0.timers.count < ToolboxTimekeepingArchive.maximumTimers else { throw ToolboxTimekeepingError.limit }
            let timer = try ToolboxCountdown(label: label, duration: duration, now: now)
            $0.timers.append(timer); added = timer.id
        }
        if ring, let added, timer(added) != nil { setReminder(true, for: added) }
    }
    public func pause(_ id: UUID, at now: ToolboxTimeSample = .now) { update(id, action: .pause) { $0.pause(at: now) } }
    public func resume(_ id: UUID, at now: ToolboxTimeSample = .now) { update(id, action: .resume) { $0.resume(at: now) } }
    public func reset(_ id: UUID) { update(id, action: .reset) { $0.reset() } }
    public func restart(_ id: UUID, at now: ToolboxTimeSample = .now) {
        update(id, action: .restart) { $0.reset(); $0.resume(at: now) }
    }
    public func remove(_ id: UUID) {
        change { $0.timers.removeAll { $0.id == id } }
        #if TOOLBOX_CLOCK_DIAGNOSTICS
        print("ToolboxClock remove id=\(id.uuidString) loaded=\(loaded) revision=\(state.revision) remains=\(state.timers.contains { $0.id == id }) issue=\(issue == nil ? "none" : "present")")
        #endif
        cancelReminder(id)
    }
    public func expiredIDs(at now: ToolboxTimeSample) -> [UUID] {
        state.timers.filter { !$0.reminder && $0.phase == .running && $0.remaining(at: now) <= 0 }.map(\.id)
    }
    public func reconcile(at now: ToolboxTimeSample = .now) {
        let ids = expiredIDs(at: now)
        guard !ids.isEmpty else { return }
        change { archive in
            for index in archive.timers.indices where !archive.timers[index].reminder { _ = archive.timers[index].finishIfNeeded(at: now) }
        }
        for id in ids { reconcileReminder(id) }
    }
    public func refreshReminders() {
        reconcile()
        // Dismissing a system permission sheet activates the scene too. It
        // must not cancel the explicit authorization that is returning.
        for id in state.timers.map(\.id) {
            if reminderOperations[id] != nil { pendingRefresh.insert(id) }
            else { reconcileReminder(id) }
        }
    }
    public func setReminder(_ enabled: Bool, for id: UUID) {
        guard loaded, let timer = state.timers.first(where: { $0.id == id }) else { return }
        guard enabled else { update(id) { $0.reminder = false; $0.generation += 1 }; return }
        guard let bridge else { issue = .reminder(""); return }
        let operation = beginReminder(id)
        authorizing.insert(id)
        reminderStatus[id] = .working
        reminderTasks[id] = Task { [weak self] in
            do {
                let allowed = try await bridge.authorize()
                guard let self, self.current(id, operation), self.timer(id)?.generation == timer.generation else { return }
                guard allowed else { self.issue = .reminder(""); self.reminderStatus[id] = .failed; self.finishReminder(id, operation); return }
                self.finishReminder(id, operation)
                self.update(id, action: .start) { $0.reminder = true; $0.generation += 1 }
            } catch {
                guard let self, self.current(id, operation) else { return }
                self.issue = .reminder(error.localizedDescription); self.reminderStatus[id] = .failed
                self.finishReminder(id, operation)
            }
        }
    }

    private func timer(_ id: UUID) -> ToolboxCountdown? { state.timers.first { $0.id == id } }
    private func update(_ id: UUID, action: ToolboxTimerAlarmAction = .refresh, _ mutate: (inout ToolboxCountdown) -> Void) {
        guard loaded, let index = state.timers.firstIndex(where: { $0.id == id }) else { return }
        change {
            mutate(&$0.timers[index])
            if $0.timers[index].reminder, action != .refresh { $0.timers[index].pendingAlarmAction = action }
            else if !$0.timers[index].reminder { $0.timers[index].pendingAlarmAction = nil }
        }
        reconcileReminder(id, action: action)
    }
    private func change(_ mutate: (inout ToolboxTimekeepingArchive) throws -> Void) {
        guard loaded else { return }
        do {
            var next = state
            try mutate(&next)
            guard next.isValid else { throw ToolboxTimekeepingError.invalid }
            next.revision += 1; state = next; persist()
        } catch ToolboxTimekeepingError.limit { issue = .limit }
        catch { issue = .invalid }
    }
    private func persist() {
        let snapshot = state, store = store
        saving = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                guard !Task.isCancelled else { return }
                try await store.save(snapshot)
                guard let self, self.state.revision == snapshot.revision else { return }
                self.saving = false
                if self.issue == .save { self.issue = nil }
            } catch {
                guard let self, self.state.revision == snapshot.revision, !Task.isCancelled else { return }
                self.saving = false; self.issue = .save
            }
        }
    }
    private func observeNativeTimers() {
        guard observationTask == nil, let updates = bridge?.updates else { return }
        observationTask = Task { [weak self] in
            for await value in updates() {
                guard !Task.isCancelled, let self else { return }
                guard self.reminderOperations[value.timerID] == nil else {
                    self.pendingRefresh.insert(value.timerID)
                    continue
                }
                if let pending = self.timer(value.timerID)?.pendingAlarmAction {
                    let confirms: Bool
                    switch pending {
                    case .pause: confirms = value.phase != .running
                    case .reset: confirms = false
                    case .start, .resume, .restart, .refresh: confirms = true
                    }
                    if confirms { self.applyNative(value, acknowledgesAction: true) }
                } else { self.applyNative(value) }
            }
        }
    }
    private func applyNative(_ value: ToolboxTimerAlarmState, acknowledgesAction: Bool = false) {
        guard let index = state.timers.firstIndex(where: { $0.id == value.timerID }),
              state.timers[index].reminder, state.timers[index].generation == value.generation else { return }
        guard acknowledgesAction || state.timers[index].pendingAlarmAction == nil else { return }
        guard value.phase != .unverified else { reminderStatus[value.timerID] = .failed; return }
        if value.phase == .running || value.phase == .paused {
            guard let amount = value.remaining, amount.isFinite, amount >= 0 else {
                reminderStatus[value.timerID] = .failed; return
            }
        }
        reminderStatus[value.timerID] = value.phase == .alerting ? .ringing :
            (value.phase == .stopped || value.phase == .paused ? .off : .scheduled)
        let now = ToolboxTimeSample.now
        var next = state.timers[index]
        if acknowledgesAction { next.pendingAlarmAction = nil }
        if value.phase == .stopped {
            // Absence is a stopped/removed timer, never proof that it rang.
            next.pause(at: now); next.reminder = false
        } else if value.phase == .alerting {
            next.retained = 0; next.started = nil; next.phase = .finished
        } else if let remaining = value.remaining, remaining.isFinite, remaining >= 0 {
            let elapsed = value.phase == .running ? max(0, now.wall.timeIntervalSince(value.observedAt)) : 0
            let amount = min(next.duration, max(0, remaining - elapsed))
            let desiredPhase: ToolboxCountdownPhase = value.phase == .running ? .running : .paused
            if next.phase == desiredPhase && abs(next.remaining(at: now) - amount) < 0.25,
               next.pendingAlarmAction == state.timers[index].pendingAlarmAction { return }
            next.retained = amount; next.started = desiredPhase == .running ? now : nil; next.phase = desiredPhase
        } else { reminderStatus[value.timerID] = .failed; return }
        guard next.isValid, next != state.timers[index] else { return }
        change { $0.timers[index] = next }
    }

    private func beginReminder(_ id: UUID) -> UUID {
        reminderTasks[id]?.cancel()
        authorizing.remove(id)
        let operation = UUID(); reminderOperations[id] = operation
        return operation
    }
    private func current(_ id: UUID, _ operation: UUID) -> Bool {
        !Task.isCancelled && reminderOperations[id] == operation
    }
    private func finishReminder(_ id: UUID, _ operation: UUID) {
        guard reminderOperations[id] == operation else { return }
        authorizing.remove(id)
        reminderOperations.removeValue(forKey: id); reminderTasks.removeValue(forKey: id)
        if pendingRefresh.remove(id) != nil, timer(id)?.reminder == true { reconcileReminder(id) }
    }
    private func cancelReminder(_ id: UUID) {
        let operation = beginReminder(id), bridge = bridge
        reminderTasks[id] = Task { [weak self] in
            do { try await bridge?.cancel(id) } catch {
                if let self, self.current(id, operation) { self.issue = .reminder(error.localizedDescription) }
            }
            guard let self, self.current(id, operation) else { return }
            self.reminderStatus.removeValue(forKey: id); self.finishReminder(id, operation)
        }
    }
    private func reconcileReminder(_ id: UUID, action: ToolboxTimerAlarmAction = .refresh) {
        guard let timer = timer(id) else { cancelReminder(id); return }
        let operation = beginReminder(id), bridge = bridge, store = store, snapshot = state
        reminderStatus[id] = .working
        reminderTasks[id] = Task { [weak self] in
            do {
                if timer.reminder {
                    guard let bridge else { throw ToolboxTimekeepingError.invalid }
                    // Persist the user action before an externally visible mutation.
                    do { try await store.save(snapshot) }
                    catch ToolboxTimekeepingError.staleArchive {
                        let saved = try await store.load()
                        guard saved.timers.contains(where: { $0.id == id && $0.generation == timer.generation && $0.reminder }) else {
                            throw CancellationError()
                        }
                    }
                    guard let self, self.current(id, operation), self.timer(id)?.generation == timer.generation else { return }
                    let result = try await bridge.synchronize(.init(timerID: id, generation: timer.generation,
                        label: timer.label, remaining: timer.remaining(at: .now),
                        action: timer.pendingAlarmAction ?? action, isRunning: timer.phase == .running))
                    guard self.current(id, operation), self.timer(id)?.generation == timer.generation else { return }
                    if let result {
                        guard result.timerID == id, result.generation == timer.generation else { throw ToolboxTimekeepingError.invalid }
                        self.applyNative(result, acknowledgesAction: true)
                    }
                    self.reminderStatus[id] = self.timer(id)?.reminder != true ? .off :
                        (result == nil || result?.phase == .unverified ? .failed :
                            (result?.phase == .alerting ? .ringing : (result?.phase == .paused ? .off : .scheduled)))
                } else {
                    try await bridge?.cancel(id)
                    guard let self, self.current(id, operation) else { return }
                    self.reminderStatus[id] = .off
                }
            } catch {
                guard let self, self.current(id, operation) else { return }
                self.reminderStatus[id] = .failed; self.issue = .reminder(error.localizedDescription)
            }
            self?.finishReminder(id, operation)
        }
    }
}
