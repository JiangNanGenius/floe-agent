// FloeApp — ordinary-task Live Activity owner.
//
// SPDX-License-Identifier: MPL-2.0
//
// One coordinator per process owns the single task Live Activity: it starts it
// only while tasks are actually running, pushes the bounded real state, and
// ends it as soon as the last task finishes, is cancelled or the user turns
// the independent switch off.
//
// Truth rules:
// - Content comes from the App's live run owner (`BackgroundRunCoordinator`),
//   never from a timer, a keep-alive loop or a fabricated "idle" activity.
// - Updates are coalesced: one drain runs at a time, a change that lands during
//   a drain requests exactly one more pass with the latest state, identical
//   state never reaches ActivityKit, and non-terminal updates keep a small
//   minimum interval. A queued foreground reconcile is tracked separately so
//   replacing the change reason can never drop it. Per-token callbacks are not
//   connected to this owner.
// - Every asynchronous step is fenced by a generation: a stop, a disable, an
//   end or a foreground reconcile makes in-flight work inert, so a late
//   callback cannot recreate or overwrite another task's activity. A stop also
//   releases the drain slot immediately instead of waiting for a suspended
//   callback to return.
// - Launch/foreground reconciles end activities this process does not own and
//   never adopt them as if work were still running.
// - When the platform or the system-wide Live Activities setting is
//   unavailable, nothing is requested and no success is reported.

import Foundation
import FloeCore

// MARK: - Activity ownership seams

/// What the system currently considers live for our attributes type.
enum TaskLiveActivityLifecycle: Sendable, Equatable {
    case active
    case stale
    case ended
    case dismissed
}

@MainActor
protocol TaskLiveActivityOwnedActivity: AnyObject {
    var id: String { get }
    var lifecycle: TaskLiveActivityLifecycle { get }
    func update(_ state: FloeTaskActivitySnapshot, staleDate: Date) async
    func end(_ state: FloeTaskActivitySnapshot?, immediate: Bool) async
}

/// The narrow surface the coordinator needs. The production implementation is
/// ActivityKit; focused tests inject a deterministic in-memory owner so the
/// lifecycle/throttle/fencing rules are exercised without a simulator.
@MainActor
protocol TaskLiveActivityControlling: AnyObject {
    var isSupported: Bool { get }
    var areActivitiesEnabled: Bool { get }
    func existingActivities() -> [any TaskLiveActivityOwnedActivity]
    func request(
        startDate: Date,
        state: FloeTaskActivitySnapshot,
        staleDate: Date
    ) throws -> any TaskLiveActivityOwnedActivity
}

// MARK: - Projection

/// Converts the live run owner's candidates into the bounded display snapshot.
/// Kept pure so the production decision is directly testable.
enum TaskLiveActivityProjection {
    /// One running task as the coordinator knows it. `publishesContent` is
    /// false for temporary/ephemeral runs, which must never reach a Lock
    /// Screen; a candidate without an owned conversation has no task route.
    struct Candidate: Equatable, Sendable {
        var runID: UUID
        var conversationID: UUID?
        var title: String
        var stage: String
        var pendingApprovalToolName: String?
        var isAwaitingUserAttention: Bool
        var startedAt: Date
        var publishesContent: Bool

        init(
            runID: UUID,
            conversationID: UUID?,
            title: String,
            stage: String,
            pendingApprovalToolName: String?,
            isAwaitingUserAttention: Bool,
            startedAt: Date,
            publishesContent: Bool
        ) {
            self.runID = runID
            self.conversationID = conversationID
            self.title = title
            self.stage = stage
            self.pendingApprovalToolName = pendingApprovalToolName
            self.isAwaitingUserAttention = isAwaitingUserAttention
            self.startedAt = startedAt
            self.publishesContent = publishesContent
        }
    }

    static func snapshot(from candidates: [Candidate]) -> FloeTaskActivitySnapshot {
        let eligible = candidates
            .filter { $0.publishesContent && $0.conversationID != nil }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
                return $0.runID.uuidString > $1.runID.uuidString
            }
        let rows = eligible
            .prefix(FloeTaskActivitySnapshot.maximumRows)
            .map { candidate -> FloeTaskActivitySnapshot.Row in
                let state: WidgetTaskState
                let status: String
                if let tool = candidate.pendingApprovalToolName {
                    state = .waiting
                    status = FloeL10n.l(
                        "platform.background_run_coordinator.waiting_for_approval", tool
                    )
                } else if candidate.isAwaitingUserAttention {
                    state = .paused
                    status = candidate.stage
                } else {
                    state = .running
                    status = candidate.stage
                }
                return FloeTaskActivitySnapshot.Row.task(
                    runID: candidate.runID,
                    conversationID: candidate.conversationID,
                    title: candidate.title,
                    state: state,
                    status: status,
                    startedAt: candidate.startedAt
                )
            }
        return FloeTaskActivitySnapshot(
            rows: Array(rows),
            activeCount: min(eligible.count, FloeTaskActivitySnapshot.maximumActiveCount)
        )
    }
}

// MARK: - Coordinator

@MainActor
final class TaskLiveActivityCoordinator {
    private let snapshotProvider: @MainActor (Date) -> FloeTaskActivitySnapshot
    private let isEnabledProvider: @MainActor () -> Bool
    private let control: (any TaskLiveActivityControlling)?
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let logger: @MainActor (String) -> Void
    private let minimumUpdateInterval: TimeInterval
    private let staleInterval: TimeInterval

    private var ownedActivity: (any TaskLiveActivityOwnedActivity)?
    private var lastPushedState: FloeTaskActivitySnapshot?
    private var lastPushAt: Date?
    private var refreshRequested = false
    /// A foreground/launch request is kept apart from the latest change reason
    /// so a reconcile that arrives while a drain is mid-pass is never lost.
    private var reconcileRequested = false
    private var pendingReason = "refresh"
    private var drainTask: Task<Void, Never>?
    private var drainToken: UUID?
    private var trailingTask: Task<Void, Never>?
    private var trailingToken: UUID?
    /// Bumped by every terminal owner transition (end, stop, disable). Work
    /// started under an older generation may finish but must not write state.
    private var generation: UInt64 = 0

    private(set) var lastActivityID: String?
    private(set) var lastErrorDescription: String?

    init(
        snapshotProvider: @escaping @MainActor (Date) -> FloeTaskActivitySnapshot,
        isEnabledProvider: @escaping @MainActor () -> Bool,
        control: (any TaskLiveActivityControlling)? = nil,
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { interval in
            guard interval > 0 else { return }
            try? await Task.sleep(for: .seconds(interval))
        },
        minimumUpdateInterval: TimeInterval = 2,
        staleInterval: TimeInterval = 20 * 60,
        logger: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.snapshotProvider = snapshotProvider
        self.isEnabledProvider = isEnabledProvider
        self.control = control ?? Self.systemControl()
        self.now = now
        self.sleep = sleep
        self.minimumUpdateInterval = max(0, minimumUpdateInterval)
        self.staleInterval = max(1, staleInterval)
        self.logger = logger
    }

    // MARK: Entry points

    /// A real task lifecycle change (start, progress stage, tool event,
    /// approval, suspension, finish) happened. Cheap and idempotent.
    func noteTasksChanged(reason: String) {
        requestRefresh(reason: reason)
    }

    /// The independent switch changed. Turning it off ends the activity now;
    /// turning it on only makes the next truthful state visible.
    func preferencesDidChange() {
        guard isEnabledProvider() else {
            stop(reason: "switchOff")
            return
        }
        requestRefresh(reason: "switchOn")
    }

    /// Foreground/launch reconciliation: end activities this process does not
    /// own, then adopt the current real state (or stay absent).
    func reconcileForForeground() {
        requestRefresh(reason: "foreground")
    }

    /// Ends the activity immediately and fences every in-flight callback.
    func stop(reason: String = "stop") {
        generation &+= 1
        refreshRequested = false
        reconcileRequested = false
        pendingReason = "stop"
        // Release the drain slot here, not from the cancelled task: a task
        // suspended inside an ActivityKit await may not resume for a while,
        // and its token guard would then leave `drainTask` non-nil forever,
        // permanently blocking every later refresh (notably re-enabling the
        // switch). The token guard keeps the old epilogue from touching the
        // slot once a newer drain owns it.
        drainToken = nil
        drainTask?.cancel()
        drainTask = nil
        trailingToken = nil
        trailingTask?.cancel()
        trailingTask = nil
        let handle = ownedActivity
        ownedActivity = nil
        lastPushedState = nil
        lastPushAt = nil
        lastActivityID = nil
        guard let handle else { return }
        logger("taskLiveActivityStop reason=\(reason)")
        Task { @MainActor in
            await handle.end(nil, immediate: true)
        }
    }

    // MARK: Scheduling

    private func requestRefresh(reason: String) {
        refreshRequested = true
        pendingReason = reason
        if reason == "foreground" || reason == "launch" {
            reconcileRequested = true
        }
        guard drainTask == nil else { return }
        startDrain()
    }

    private func startDrain() {
        let token = UUID()
        drainToken = token
        let startGeneration = generation
        drainTask = Task { @MainActor [weak self] in
            while let self,
                  self.drainToken == token,
                  self.generation == startGeneration,
                  !Task.isCancelled {
                guard self.refreshRequested else { break }
                self.refreshRequested = false
                let reason = self.pendingReason
                let reconcile = self.reconcileRequested
                self.reconcileRequested = false
                await self.performPass(
                    generation: startGeneration,
                    reason: reason,
                    reconcileOrphans: reconcile
                )
            }
            guard let self, self.drainToken == token else { return }
            self.drainToken = nil
            self.drainTask = nil
            if self.refreshRequested {
                // Changes that arrived while the last pass ran need exactly
                // one more pass against the current truth, including a queued
                // foreground reconcile.
                self.startDrain()
            }
        }
    }

    // MARK: One coalesced pass

    private func performPass(
        generation passGeneration: UInt64,
        reason: String,
        reconcileOrphans: Bool
    ) async {
        guard passGeneration == generation else { return }
        guard let control, control.isSupported else { return }

        if reconcileOrphans {
            await reconcileExistingActivities(control: control)
            guard passGeneration == generation else { return }
        }

        // A handle the system already ended or the user dismissed is not an
        // owner; a later pass may start a new activity for real running work.
        if let handle = ownedActivity,
           handle.lifecycle == .ended || handle.lifecycle == .dismissed {
            ownedActivity = nil
            lastPushedState = nil
            lastPushAt = nil
            lastActivityID = nil
        }

        let timestamp = now()
        let enabled = isEnabledProvider()
        var snapshot = snapshotProvider(timestamp)
        if enabled {
            do {
                try snapshot.validate()
            } catch let error as FloeTaskActivitySnapshotError {
                lastErrorDescription = error.logKind
                logger("taskLiveActivityInvalidState kind=\(error.logKind)")
                snapshot = .empty
            } catch {
                lastErrorDescription = "invalid_state"
                snapshot = .empty
            }
        } else {
            // The switch is off: no content may remain visible.
            snapshot = .empty
        }

        guard !snapshot.isIdle else {
            await endOwnedActivity(finalState: snapshot, reason: "idle")
            return
        }

        guard control.areActivitiesEnabled else {
            // System-wide Live Activities are disabled. Never request here and
            // never report success; clear anything that is still on screen.
            await endOwnedActivity(
                finalState: FloeTaskActivitySnapshot.empty,
                reason: "systemDisabled"
            )
            return
        }

        guard let handle = ownedActivity else {
            let startDate = snapshot.rows.map(\.startedAt).min() ?? timestamp
            do {
                let created = try control.request(
                    startDate: startDate,
                    state: snapshot,
                    staleDate: timestamp.addingTimeInterval(staleInterval)
                )
                guard passGeneration == generation else {
                    await created.end(nil, immediate: true)
                    return
                }
                ownedActivity = created
                lastPushedState = snapshot
                lastPushAt = timestamp
                lastActivityID = created.id
                lastErrorDescription = nil
                logger(
                    "taskLiveActivityStart id=\(created.id) rows=\(snapshot.rows.count) "
                        + "active=\(snapshot.activeCount) reason=\(reason)"
                )
            } catch {
                lastErrorDescription = "request_failed"
                logger("taskLiveActivityStartFailed reason=\(reason) error=\(error)")
            }
            return
        }

        guard lastPushedState != snapshot else { return }

        let elapsed = timestamp.timeIntervalSince(lastPushAt ?? .distantPast)
        if elapsed < minimumUpdateInterval {
            scheduleTrailingPush(
                after: minimumUpdateInterval - elapsed,
                generation: passGeneration
            )
            return
        }

        lastPushedState = snapshot
        lastPushAt = timestamp
        lastErrorDescription = nil
        await handle.update(
            snapshot,
            staleDate: timestamp.addingTimeInterval(staleInterval)
        )
        guard passGeneration == generation else { return }
        logger(
            "taskLiveActivityUpdate rows=\(snapshot.rows.count) "
                + "active=\(snapshot.activeCount) reason=\(reason)"
        )
    }

    private func scheduleTrailingPush(after delay: TimeInterval, generation passGeneration: UInt64) {
        trailingTask?.cancel()
        let token = UUID()
        trailingToken = token
        trailingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(delay)
            guard !Task.isCancelled,
                  self.trailingToken == token,
                  self.generation == passGeneration else { return }
            self.trailingToken = nil
            self.trailingTask = nil
            self.requestRefresh(reason: "coalesced")
        }
    }

    private func endOwnedActivity(
        finalState: FloeTaskActivitySnapshot,
        reason: String
    ) async {
        trailingToken = nil
        trailingTask?.cancel()
        trailingTask = nil
        guard let handle = ownedActivity else { return }
        ownedActivity = nil
        lastPushedState = nil
        lastPushAt = nil
        lastActivityID = nil
        generation &+= 1
        logger("taskLiveActivityEnd id=\(handle.id) reason=\(reason)")
        await handle.end(finalState, immediate: true)
    }

    /// Ends activities this process does not own. They can only be leftovers
    /// from an earlier launch; nothing is adopted, so a relaunch never shows
    /// work that is not actually running.
    private func reconcileExistingActivities(control: any TaskLiveActivityControlling) async {
        let existing = control.existingActivities()
        guard !existing.isEmpty else { return }
        let ownedID = ownedActivity?.id
        var endedOrphans = 0
        for handle in existing where handle.id != ownedID {
            await handle.end(nil, immediate: true)
            endedOrphans += 1
        }
        if endedOrphans > 0 {
            logger("taskLiveActivityReconciled ended=\(endedOrphans)")
        }
    }

    // MARK: Testing seams

    var hasActivityForTesting: Bool { ownedActivity != nil }

    /// True while a coalescing drain owns the update slot. A stop must release
    /// it synchronously; otherwise later refreshes can never start.
    var hasDrainForTesting: Bool { drainTask != nil }

    var pushedStateForTesting: FloeTaskActivitySnapshot? { lastPushedState }

    func waitForIdleForTesting() async {
        for _ in 0..<64 {
            if let task = drainTask {
                await task.value
                continue
            }
            if let task = trailingTask {
                await task.value
                continue
            }
            return
        }
    }

    // MARK: System wiring

    nonisolated static var isSupported: Bool {
        #if os(iOS) && canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    /// The user's system-wide Live Activities setting. Read-only query used by
    /// the settings surface for an actionable limitation; the coordinator
    /// itself re-reads it before every request.
    nonisolated static var areSystemLiveActivitiesEnabled: Bool {
        #if os(iOS) && canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        return false
        #endif
    }

    static func systemControl() -> (any TaskLiveActivityControlling)? {
        #if os(iOS) && canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        return ActivityKitTaskLiveActivityControl()
        #else
        return nil
        #endif
    }
}

// MARK: - ActivityKit implementation

#if os(iOS) && canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

@MainActor
private final class ActivityKitTaskLiveActivityControl: TaskLiveActivityControlling {
    var isSupported: Bool { true }

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func existingActivities() -> [any TaskLiveActivityOwnedActivity] {
        Activity<FloeTaskActivityAttributes>.activities.map {
            ActivityKitTaskLiveActivityHandle($0)
        }
    }

    func request(
        startDate: Date,
        state: FloeTaskActivitySnapshot,
        staleDate: Date
    ) throws -> any TaskLiveActivityOwnedActivity {
        let activity = try Activity.request(
            attributes: FloeTaskActivityAttributes(startDate: startDate),
            content: ActivityContent(state: state, staleDate: staleDate),
            pushType: nil
        )
        return ActivityKitTaskLiveActivityHandle(activity)
    }
}

@MainActor
private final class ActivityKitTaskLiveActivityHandle: TaskLiveActivityOwnedActivity {
    private let activity: Activity<FloeTaskActivityAttributes>

    init(_ activity: Activity<FloeTaskActivityAttributes>) {
        self.activity = activity
    }

    var id: String { activity.id }

    var lifecycle: TaskLiveActivityLifecycle {
        switch activity.activityState {
        case .active, .pending: .active
        case .stale: .stale
        case .ended: .ended
        case .dismissed: .dismissed
        @unknown default: .ended
        }
    }

    func update(_ state: FloeTaskActivitySnapshot, staleDate: Date) async {
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    func end(_ state: FloeTaskActivitySnapshot?, immediate: Bool) async {
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        await activity.end(
            content,
            dismissalPolicy: immediate ? .immediate : .default
        )
    }
}
#endif
