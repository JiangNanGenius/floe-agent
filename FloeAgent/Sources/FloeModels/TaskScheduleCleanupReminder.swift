import Foundation
import FloeCore

/// Why a retired scheduled task may need a manual system-automation cleanup.
///
/// Raw values are persisted in `task_schedule_cleanup_reminders.reason`;
/// never rename them. A row that is still in silent monitoring has NO
/// reason yet — the reason is written exactly when the row becomes visible.
public enum TaskScheduleCleanupReason: String, Sendable, Codable, CaseIterable, Hashable {
    /// The schedule row was permanently deleted (Home, the `task.schedule`
    /// tool, `apple.automation.update`, or any other store caller — every
    /// path funnels through `SQLiteTaskScheduleStore.delete`). Opened only
    /// for plans whose actual Shortcut handoff/confirmation was monitored.
    case deleted
    /// A one-time schedule's bound occurrence REACHED A TERMINAL STATE while
    /// the plan stays permanently disabled from its launch. This is the
    /// schedule's OWN retirement — distinct from one occurrence of a
    /// recurring schedule completing (retires nothing) and from a
    /// reversible pause (also retires nothing).
    case onceConsumed
    /// The "Run Scheduled Task" action still fired against a schedule the
    /// durable store can no longer find. Direct evidence that a system
    /// automation exists, so this reason may open a row even when the app
    /// never recorded a setup — and may REOPEN a row the user marked
    /// removed (a fresh fire contradicts that claim). It never reopens a
    /// silenced (`dismissed`) row: dismissing keeps the same event quiet.
    case staleTrigger
}

/// User-side handling state. Floe has no API to detect a system automation
/// being created or deleted, so `removed` records ONLY the user's own
/// confirmation and `dismissed` simply silences the reminder — neither
/// claims anything about the Shortcuts app.
public enum TaskScheduleCleanupStatus: String, Sendable, Codable, CaseIterable, Hashable {
    /// Silent monitoring: an actual import/share handoff or explicit user
    /// confirmation was recorded for this plan while it is (or was) alive.
    /// NEVER rendered in ordinary UI; it is the durable marker that lets a
    /// later delete/terminal open exactly one cleanup reminder.
    case monitoring
    case open
    case dismissed
    case removed
}

/// The bounded trigger that (re)starts monitoring for one schedule. Raw
/// values are persisted in `setup_source`; never rename them. Failed or
/// cancelled imports are NOT sources: handoff evidence only ever comes from
/// the system actually receiving the file, or the user's own confirmation.
public enum TaskScheduleSetupSource: String, Sendable, Codable, CaseIterable, Hashable {
    case importFlowOpened
    case handedOffToUser
    case userConfirmed
}

/// One durable, deduplicated monitoring/cleanup record per schedule.
///
/// The record is intentionally a side note, not lifecycle state: it never
/// gates, re-arms, enables or launches a schedule, and it lives in its own
/// table (no foreign key) so the captured title survives the schedule
/// deletion and every relaunch.
public struct TaskScheduleCleanupReminder: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var scheduleID: UUID
    /// The schedule's human title at the time of recording — the only
    /// identifier shown in ordinary UI. The stable UUID stays internal.
    public var title: String
    /// nil while the row is silent monitoring; always set once visible.
    public var reason: TaskScheduleCleanupReason?
    public var status: TaskScheduleCleanupStatus
    /// The most recent actual handoff/confirmation, and when it happened.
    public var setupSource: TaskScheduleSetupSource?
    public var setupAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    /// Advanced by every repeated monitoring/retirement event for the same
    /// schedule (dedupe signal: the row stays single, the recurrence stays
    /// visible).
    public var lastSeenAt: Date

    public init(
        id: UUID,
        scheduleID: UUID,
        title: String,
        reason: TaskScheduleCleanupReason?,
        status: TaskScheduleCleanupStatus,
        setupSource: TaskScheduleSetupSource?,
        setupAt: Date?,
        createdAt: Date,
        updatedAt: Date,
        lastSeenAt: Date
    ) {
        self.id = id
        self.scheduleID = scheduleID
        self.title = title
        self.reason = reason
        self.status = status
        self.setupSource = setupSource
        self.setupAt = setupAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSeenAt = lastSeenAt
    }

    /// Deterministic one-per-schedule identity (same derivation style as
    /// `TaskScheduleOccurrence.stableID`): repeated events for one schedule
    /// address exactly one record row.
    public static func stableID(scheduleID: UUID) -> UUID {
        let hex = Array(FloeDigest.sha256Hex(
            Data("floe.schedule.cleanup:\(scheduleID.uuidString)".utf8)
        ).prefix(32))
        guard hex.count == 32 else { return UUID() }
        let text = String(hex)
        let formatted = [
            text.prefix(8),
            text.dropFirst(8).prefix(4),
            text.dropFirst(12).prefix(4),
            text.dropFirst(16).prefix(4),
            text.dropFirst(20).prefix(12),
        ].joined(separator: "-")
        return UUID(uuidString: formatted) ?? UUID()
    }
}
