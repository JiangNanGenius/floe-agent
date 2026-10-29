import Foundation
import FloeCore

/// The cadence family of one scheduled task.
///
/// Raw values are persisted in `task_schedules.cadence`; never rename them.
public enum TaskScheduleCadence: String, Sendable, Codable, CaseIterable, Hashable {
    /// Fires exactly once at `scheduledAt`.
    case once
    /// Fires every day at the anchor's wall-clock time.
    case daily
    /// Fires every seven days at the anchor's wall-clock time (same weekday).
    case weekly
    /// Fires every `intervalSeconds` seconds measured from the anchor.
    ///
    /// The interval is an ABSOLUTE duration (not a wall-clock reading), so it
    /// is deliberately DST-stable: a 6-hour interval stays 6 hours across a
    /// clock change instead of drifting by the offset.
    case interval
    /// Fires when a bound upstream schedule's task completes successfully.
    ///
    /// Never fires on failure, cancellation or interruption; one occurrence
    /// per successful upstream run (the upstream run id is the logical
    /// occurrence identity, so replayed completion callbacks cannot duplicate
    /// it).
    case afterSuccess

    /// True when the cadence repeats without an upstream event.
    public var isRepeating: Bool {
        switch self {
        case .once, .afterSuccess: false
        case .daily, .weekly, .interval: true
        }
    }
}

public struct TaskScheduleRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var prompt: String
    public var workspaceID: UUID?
    public var cadence: TaskScheduleCadence
    public var scheduledAt: Date
    public var weekday: Int?
    public var isEnabled: Bool
    public var lastStartedAt: Date?
    public var nextExpectedAt: Date?
    public var policyJSON: String
    public var createdAt: Date
    public var updatedAt: Date

    /// Fixed-interval cadence duration in seconds. Required for `.interval`.
    public var intervalSeconds: Int?
    /// IANA timezone identifier anchoring daily/weekly wall-clock times.
    /// Nil keeps the user's current calendar (historical behavior).
    public var anchorTimezone: String?
    /// For `.afterSuccess`: the CONCRETE upstream run selected when this
    /// schedule was created. This schedule fires exactly once, after that run
    /// completes SUCCESSFULLY; it is not bound to future rounds of any
    /// conversation and never to a delegated child's completion.
    public var upstreamRunID: UUID?
    /// Explicit model binding frozen at schedule time. Nil means "resolve the
    /// current default at execution".
    public var modelID: UUID?
    /// Explicit environment binding frozen at schedule time; revalidated
    /// before every execution. Nil resolves through the task's workspace.
    public var environmentID: String?
    /// Encoded `DraftTaskPolicy` permission binding frozen at schedule time.
    /// Nil keeps the settings default at execution.
    public var permissionJSON: String?

    public init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        workspaceID: UUID? = nil,
        cadence: TaskScheduleCadence,
        scheduledAt: Date,
        weekday: Int? = nil,
        isEnabled: Bool = true,
        lastStartedAt: Date? = nil,
        nextExpectedAt: Date? = nil,
        policyJSON: String = "{}",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        intervalSeconds: Int? = nil,
        anchorTimezone: String? = nil,
        upstreamRunID: UUID? = nil,
        modelID: UUID? = nil,
        environmentID: String? = nil,
        permissionJSON: String? = nil
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.workspaceID = workspaceID
        self.cadence = cadence
        self.scheduledAt = scheduledAt
        self.weekday = weekday
        self.isEnabled = isEnabled
        self.lastStartedAt = lastStartedAt
        self.nextExpectedAt = nextExpectedAt ?? scheduledAt
        self.policyJSON = policyJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.intervalSeconds = intervalSeconds
        self.anchorTimezone = anchorTimezone
        self.upstreamRunID = upstreamRunID
        self.modelID = modelID
        self.environmentID = environmentID
        self.permissionJSON = permissionJSON
    }
}

/// Durable state of one logical execution instance.
public enum TaskScheduleOccurrenceState: String, Sendable, Codable, CaseIterable, Hashable {
    /// Due (or future); nothing has been claimed yet.
    case pending
    /// Atomically claimed by one executor BEFORE the task was launched. A
    /// crash between claim and launch is reconciled honestly as interrupted.
    case claimed
    /// The task was launched; `runID` names the owning run.
    case running
    case completed
    case failed
    case cancelled
    /// A missed fire time that was coalesced away (only the most recent due
    /// occurrence executes by default); recorded for honest history instead of
    /// being silently dropped.
    case skipped
    /// Claimed but the process exited before/while launching.
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .pending, .claimed, .running: false
        case .completed, .failed, .cancelled, .skipped, .interrupted: true
        }
    }
}

/// One durable execution instance of a schedule. `id` is a deterministic
/// function of (schedule, logical fire time), so the same fire time produces
/// the same row in every process and duplicate wakeups collapse on the unique
/// index instead of double-launching a task.
public struct TaskScheduleOccurrence: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var scheduleID: UUID
    public var scheduledFor: Date
    public var state: TaskScheduleOccurrenceState
    /// Stable logical key: a calendar bucket for daily/weekly, exact epoch
    /// seconds for intervals, the upstream run id for after-success.
    public var dedupeKey: String
    public var runID: UUID?
    public var conversationID: UUID?
    public var claimedAt: Date?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var summary: String?
    public var errorText: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        scheduleID: UUID,
        scheduledFor: Date,
        state: TaskScheduleOccurrenceState = .pending,
        dedupeKey: String,
        runID: UUID? = nil,
        conversationID: UUID? = nil,
        claimedAt: Date? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        summary: String? = nil,
        errorText: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.scheduleID = scheduleID
        self.scheduledFor = scheduledFor
        self.state = state
        self.dedupeKey = dedupeKey
        self.runID = runID
        self.conversationID = conversationID
        self.claimedAt = claimedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.summary = summary
        self.errorText = errorText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public extension TaskScheduleOccurrence {
    /// Deterministic occurrence identity for (schedule, logical fire key).
    /// One-way and not security-sensitive; the same inputs always produce the
    /// same UUID so any number of wakeups address one logical instance.
    static func stableID(scheduleID: UUID, dedupeKey: String) -> UUID {
        let hex = Array(FloeDigest.sha256Hex(
            Data("floe.schedule.occurrence:\(scheduleID.uuidString):\(dedupeKey)".utf8)
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

/// Pure fire-time planning. All calendar math is anchored in the schedule's
/// stored timezone (falling back to the user's current calendar), so a
/// daily/weekly schedule keeps its wall-clock time across travel and DST
/// changes, while `.interval` stays an absolute duration.
public enum TaskSchedulePlanner {
    /// How many missed fire times are materialized as history entries in one
    /// reconciliation pass. Older missed times are represented by a single
    /// explicit `skipped` row beyond the window, never silently dropped.
    public static let missedHistoryWindow = 8

    public static func calendar(for record: TaskScheduleRecord) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let identifier = record.anchorTimezone, let zone = TimeZone(identifier: identifier) {
            calendar.timeZone = zone
        }
        return calendar
    }

    /// The logical dedupe key for one fire time. Daily/weekly use the anchor
    /// calendar's local date; interval uses exact epoch seconds; once uses a
    /// constant; after-success is keyed by the upstream run by the caller.
    public static func dedupeKey(for fireTime: Date, record: TaskScheduleRecord) -> String {
        switch record.cadence {
        case .once:
            return "once"
        case .interval:
            return "epoch:\(Int(fireTime.timeIntervalSince1970))"
        case .daily, .weekly:
            var calendar = calendar(for: record)
            calendar.timeZone = calendar.timeZone
            let parts = calendar.dateComponents([.year, .month, .day], from: fireTime)
            return String(
                format: "day:%04d-%02d-%02d",
                parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
            )
        case .afterSuccess:
            return "afterSuccess"
        }
    }

    /// Every scheduled fire time at or before `now`, most recent last, at
    /// most `limit` entries. `once`/`afterSuccess` yield at most one entry.
    public static func dueFireTimes(
        record: TaskScheduleRecord,
        now: Date,
        limit: Int = missedHistoryWindow
    ) -> [Date] {
        let bounded = max(1, limit)
        let anchor = record.scheduledAt
        switch record.cadence {
        case .once:
            return anchor <= now ? [anchor] : []
        case .afterSuccess:
            // Armed only by a recorded upstream success; a clock pass must
            // never materialize a fire time for it.
            return []
        case .daily:
            return recurringFireTimes(record: record, now: now, component: .day, step: 1, limit: bounded)
        case .weekly:
            return recurringFireTimes(record: record, now: now, component: .day, step: 7, limit: bounded)
        case .interval:
            let interval = TimeInterval(max(1, record.intervalSeconds ?? 0))
            guard anchor <= now else { return [] }
            let elapsed = now.timeIntervalSince(anchor)
            let index = Int(floor(elapsed / interval))
            let first = max(0, index - (bounded - 1))
            return (first...index).map { anchor.addingTimeInterval(Double($0) * interval) }
        }
    }

    /// The ONE execution target an explicit "run this schedule now" caller
    /// (Shortcuts personal automation bound to one selected schedule)
    /// addresses: the most recent due fire time, coalesced exactly like the
    /// background pass, with its deterministic occurrence identity so any
    /// number of duplicate callbacks address one logical instance. Returns
    /// nil when the schedule has no time-based due occurrence (a future
    /// one-shot, an interval that has not reached its first fire, or an
    /// event-armed after-success cadence the clock can never materialize).
    public static func selectedRunTarget(
        record: TaskScheduleRecord,
        now: Date
    ) -> (fireTime: Date, dedupeKey: String, occurrenceID: UUID)? {
        guard let fireTime = dueFireTimes(record: record, now: now).last else { return nil }
        let key = dedupeKey(for: fireTime, record: record)
        return (
            fireTime,
            key,
            TaskScheduleOccurrence.stableID(scheduleID: record.id, dedupeKey: key)
        )
    }

    /// The next fire time strictly after `reference`, or nil for one-shot and
    /// after-success cadences.
    public static func nextFireTime(
        after reference: Date,
        record: TaskScheduleRecord
    ) -> Date? {
        switch record.cadence {
        case .once, .afterSuccess:
            return nil
        case .daily, .weekly:
            let step = record.cadence == .weekly ? 7 : 1
            var calendar = calendar(for: record)
            // Preserve the anchor's wall-clock components.
            let components = calendar.dateComponents([.hour, .minute, .second], from: record.scheduledAt)
            var candidate = record.scheduledAt
            var guardCount = 0
            while candidate <= reference, guardCount < 4000 {
                guard let next = calendar.date(byAdding: .day, value: step, to: candidate) else { return nil }
                candidate = next
                guardCount += 1
            }
            // Re-pin the wall clock (a DST jump can shift the derived time).
            if let pinned = calendar.date(
                bySettingHour: components.hour ?? 0,
                minute: components.minute ?? 0,
                second: components.second ?? 0,
                of: candidate
            ) {
                candidate = pinned
            }
            return candidate > reference ? candidate : calendar.date(byAdding: .day, value: step, to: candidate)
        case .interval:
            let interval = TimeInterval(max(1, record.intervalSeconds ?? 0))
            guard interval > 0 else { return nil }
            if reference < record.scheduledAt { return record.scheduledAt }
            let elapsed = reference.timeIntervalSince(record.scheduledAt)
            let index = Int(floor(elapsed / interval)) + 1
            return record.scheduledAt.addingTimeInterval(Double(index) * interval)
        }
    }

    private static func recurringFireTimes(
        record: TaskScheduleRecord,
        now: Date,
        component: Calendar.Component,
        step: Int,
        limit: Int
    ) -> [Date] {
        var calendar = calendar(for: record)
        calendar.timeZone = calendar.timeZone
        let anchor = record.scheduledAt
        guard anchor <= now else { return [] }
        let components = calendar.dateComponents([.hour, .minute, .second], from: anchor)
        // Bounded forward walk. Daily schedules older than ~11 years would be
        // pathological; the loop cap keeps planning O(limit) in practice while
        // still being exact because we re-pin the wall clock per hop.
        var candidate = anchor
        var collected: [Date] = [anchor]
        var hops = 0
        while candidate <= now, hops < 100_000 {
            guard let next = calendar.date(byAdding: component, value: step, to: candidate) else { break }
            candidate = next
            if let pinned = calendar.date(
                bySettingHour: components.hour ?? 0,
                minute: components.minute ?? 0,
                second: components.second ?? 0,
                of: candidate
            ) {
                candidate = pinned
            }
            guard candidate <= now else { break }
            collected.append(candidate)
            hops += 1
        }
        return Array(collected.suffix(limit))
    }
}
