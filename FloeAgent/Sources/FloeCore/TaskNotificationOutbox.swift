// FloeCore — Durable terminal-event outbox for task notifications.
//
// Completion, failure, cancellation and action-required are terminal events:
// one attempt to deliver each of them must survive the first-authorization
// race instead of being dropped. The app resolves the real per-conversation
// policy into a `TaskNotificationEventGate`, enqueues the event, and then asks
// the outbox for everything that may be presented *now* (authorization
// present). Events that cannot be presented are queued, persisted and retried
// on the next authorization change or foreground/background transition.
//
// Diagnostics are part of the contract: the last scheduling failure and the
// authorization state the app used are recorded so settings can explain why an
// alert did or did not appear.

import Foundation

/// The durable terminal event kinds. Raw values are persisted.
public enum TaskTerminalEventKind: String, Sendable, Codable, CaseIterable, Hashable {
    case completed
    case failed
    case cancelled
    /// Waiting on the user (tool approval, browser takeover, …): actionable,
    /// so it is delivered even though the run is not finished.
    case actionRequired

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .actionRequired: false
        }
    }
}

/// User-facing bounds for a persistent alert. System banners truncate
/// unpredictably; truncating here keeps the task name and the result readable
/// and makes the behavior testable.
public enum TaskNotificationContentBounds {
    public static let maximumTitleCharacters = 80
    public static let maximumBodyCharacters = 220

    /// Single-line, whitespace-normalized truncation at a character bound.
    public static func truncating(_ text: String, to limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit))
    }
}

/// One durable notification-worthy event, carrying the same deep-link identity
/// the work record and the in-app route use.
public struct TaskTerminalEvent: Sendable, Codable, Hashable, Identifiable {
    /// Stable notification identifier, e.g. "run.<uuid>.terminal". Two
    /// publications of the same terminal state replace each other instead of
    /// stacking duplicate alerts.
    public let identifier: String
    public let kind: TaskTerminalEventKind
    public let title: String
    public let body: String
    public let createdAt: Date
    public let deepLink: BackgroundWorkDeepLink

    public var id: String { identifier }

    /// Maximum alert age before a tap is treated as expired: the identity is
    /// still routed, but the target is re-checked before navigation.
    public static let defaultMaximumAlertAge: TimeInterval = 24 * 60 * 60

    public init(
        identifier: String,
        kind: TaskTerminalEventKind,
        title: String,
        body: String,
        createdAt: Date = Date(),
        deepLink: BackgroundWorkDeepLink
    ) {
        self.identifier = identifier
        self.kind = kind
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.deepLink = deepLink
    }

    /// True when the alert is older than the maximum age. Expired alerts still
    /// carry a stable identity; the router re-validates their target before it
    /// navigates so a tap on a days-old notification cannot crash into a
    /// deleted conversation or environment.
    public func isExpired(
        now: Date = Date(),
        maximumAge: TimeInterval = TaskTerminalEvent.defaultMaximumAlertAge
    ) -> Bool {
        now.timeIntervalSince(createdAt) > maximumAge
    }

    /// Persistent terminal alert for one model run. The task name is the
    /// title, the body is the caller-composed outcome line (the App layer
    /// owns locale), and `run.<id>.terminal` is the stable identifier and
    /// route: two publications of the same terminal state replace each other
    /// instead of stacking duplicate banners.
    public static func modelRunTerminal(
        runID: UUID,
        conversationID: UUID,
        taskName: String,
        kind: TaskTerminalEventKind,
        body: String,
        createdAt: Date = Date()
    ) -> TaskTerminalEvent {
        TaskTerminalEvent(
            identifier: "run.\(runID.uuidString).terminal",
            kind: kind,
            title: TaskNotificationContentBounds.truncating(
                taskName, to: TaskNotificationContentBounds.maximumTitleCharacters
            ),
            body: TaskNotificationContentBounds.truncating(
                body, to: TaskNotificationContentBounds.maximumBodyCharacters
            ),
            createdAt: createdAt,
            deepLink: BackgroundWorkDeepLink(
                kind: .modelRun,
                conversationID: conversationID,
                runID: runID
            )
        )
    }

    /// Persistent terminal alert for one Linux environment session, scoped to
    /// one boot via the runtime launch generation. Without the generation a
    /// later restart would replace the previous boot's alert under the same
    /// identifier; when the runtime token is unknown the unsuffixed
    /// identifier is preserved instead of inventing a generation.
    public static func linuxSessionTerminal(
        environmentID: String,
        environmentTitle: String,
        kind: TaskTerminalEventKind,
        body: String,
        launchGeneration: UInt64? = nil,
        createdAt: Date = Date()
    ) -> TaskTerminalEvent {
        let identifier = launchGeneration.map {
            "linux.session.\(environmentID).g\($0).terminal"
        } ?? "linux.session.\(environmentID).terminal"
        return TaskTerminalEvent(
            identifier: identifier,
            kind: kind,
            title: TaskNotificationContentBounds.truncating(
                environmentTitle,
                to: TaskNotificationContentBounds.maximumTitleCharacters
            ),
            body: TaskNotificationContentBounds.truncating(
                body, to: TaskNotificationContentBounds.maximumBodyCharacters
            ),
            createdAt: createdAt,
            deepLink: BackgroundWorkDeepLink(
                kind: .linuxSession,
                environmentID: environmentID
            )
        )
    }
}

/// Persisted record of the last failed scheduling attempt. `at` and `reason`
/// are exactly what diagnostics show.
public struct TaskNotificationSchedulingFailure: Sendable, Codable, Hashable {
    public var identifier: String
    public var reason: String
    public var at: Date
    /// True when authorization (not a system error) blocked presentation.
    public var wasAuthorizationBlocked: Bool

    public init(
        identifier: String,
        reason: String,
        at: Date,
        wasAuthorizationBlocked: Bool
    ) {
        self.identifier = identifier
        self.reason = reason
        self.at = at
        self.wasAuthorizationBlocked = wasAuthorizationBlocked
    }
}

public enum TaskNotificationOutboxDisposition: Sendable, Equatable {
    /// Authorization is available: present immediately through
    /// UNUserNotificationCenter.
    case presentNow
    /// The event is durable in the queue and will be presented once
    /// authorization exists.
    case queuedForAuthorization
    /// The same identifier was already queued; the newest content wins and the
    /// queue position moves to the end.
    case replacedQueuedEvent
}

/// Resolves the per-conversation notification policy into which terminal kinds
/// the user asked to be told about. The app layer owns the enum mapping; this
/// value keeps the delivery decision testable and explicit.
public struct TaskNotificationEventGate: Sendable, Equatable {
    public var notifiesCompleted: Bool
    public var notifiesFailed: Bool
    public var notifiesCancelled: Bool
    public var notifiesActionRequired: Bool

    public init(
        notifiesCompleted: Bool,
        notifiesFailed: Bool,
        notifiesCancelled: Bool,
        notifiesActionRequired: Bool
    ) {
        self.notifiesCompleted = notifiesCompleted
        self.notifiesFailed = notifiesFailed
        self.notifiesCancelled = notifiesCancelled
        self.notifiesActionRequired = notifiesActionRequired
    }

    /// Everything off: used when no durable task record exists.
    public static let silent = TaskNotificationEventGate(
        notifiesCompleted: false,
        notifiesFailed: false,
        notifiesCancelled: false,
        notifiesActionRequired: false
    )

    public func allows(_ kind: TaskTerminalEventKind) -> Bool {
        switch kind {
        case .completed: notifiesCompleted
        case .failed: notifiesFailed
        case .cancelled: notifiesCancelled
        case .actionRequired: notifiesActionRequired
        }
    }
}

/// Delivery queue. Value semantics: the owner (the run coordinator) holds the
/// authoritative copy, mutates it on the main actor and persists it after each
/// change.
public struct TaskNotificationOutbox: Sendable, Codable, Equatable {
    /// Safety valve, not a drop policy: reaching it records a scheduling
    /// failure so diagnostics can show it, and only then evicts the oldest
    /// non-action-required event.
    public static let defaultMaximumPendingEvents = 64

    public private(set) var pending: [TaskTerminalEvent]
    public private(set) var lastSchedulingFailure: TaskNotificationSchedulingFailure?
    public private(set) var lastScheduledIdentifier: String?
    public private(set) var lastScheduledAt: Date?
    public private(set) var droppedEventCount: Int
    public var maximumPendingEvents: Int

    public init(
        pending: [TaskTerminalEvent] = [],
        lastSchedulingFailure: TaskNotificationSchedulingFailure? = nil,
        lastScheduledIdentifier: String? = nil,
        lastScheduledAt: Date? = nil,
        droppedEventCount: Int = 0,
        maximumPendingEvents: Int = TaskNotificationOutbox.defaultMaximumPendingEvents
    ) {
        self.pending = pending
        self.lastSchedulingFailure = lastSchedulingFailure
        self.lastScheduledIdentifier = lastScheduledIdentifier
        self.lastScheduledAt = lastScheduledAt
        self.droppedEventCount = droppedEventCount
        self.maximumPendingEvents = max(1, maximumPendingEvents)
    }

    public var pendingCount: Int { pending.count }
    public var hasPendingEvents: Bool { !pending.isEmpty }

    /// Enqueues one event. `canPresent` is the app's real authorization answer
    /// *now*; false means "queue, never drop".
    @discardableResult
    public mutating func enqueue(
        _ event: TaskTerminalEvent,
        canPresent: Bool
    ) -> TaskNotificationOutboxDisposition {
        let replaced = pending.contains { $0.identifier == event.identifier }
        pending.removeAll { $0.identifier == event.identifier }
        guard !canPresent else {
            return .presentNow
        }
        pending.append(event)
        if pending.count > maximumPendingEvents {
            // Evict the oldest event that is not waiting on the user.
            if let index = pending.firstIndex(where: { $0.kind != .actionRequired }) {
                let dropped = pending.remove(at: index)
                droppedEventCount += 1
                lastSchedulingFailure = TaskNotificationSchedulingFailure(
                    identifier: dropped.identifier,
                    reason: "Notification queue exceeded \(maximumPendingEvents) events; oldest queued alert was discarded after persistent failure",
                    at: Date(),
                    wasAuthorizationBlocked: false
                )
            }
        }
        return replaced ? .replacedQueuedEvent : .queuedForAuthorization
    }

    /// Removes and returns the queued events that may be presented now, oldest
    /// first. Nothing is returned while authorization is missing.
    public mutating func takePresentable(
        canPresent: Bool,
        limit: Int = 8
    ) -> [TaskTerminalEvent] {
        guard canPresent, !pending.isEmpty else { return [] }
        let count = min(max(1, limit), pending.count)
        let events = Array(pending.prefix(count))
        pending.removeFirst(count)
        return events
    }

    /// Records a successful hand-off to UNUserNotificationCenter.
    public mutating func recordSchedulingSuccess(
        identifier: String,
        at date: Date = Date()
    ) {
        lastScheduledIdentifier = identifier
        lastScheduledAt = date
        lastSchedulingFailure = nil
    }

    /// Records a real failure to schedule (system error) or a blocked attempt.
    public mutating func recordSchedulingFailure(
        identifier: String,
        reason: String,
        at date: Date = Date(),
        wasAuthorizationBlocked: Bool
    ) {
        lastSchedulingFailure = TaskNotificationSchedulingFailure(
            identifier: identifier,
            reason: reason,
            at: date,
            wasAuthorizationBlocked: wasAuthorizationBlocked
        )
    }

    /// Drops a queued event after the user acted on the underlying task.
    public mutating func discard(identifier: String) {
        pending.removeAll { $0.identifier == identifier }
    }

    public mutating func discardAll() {
        pending.removeAll()
    }
}

/// Diagnostics snapshot for the settings surface.
public struct TaskNotificationDiagnostics: Sendable, Equatable {
    /// Raw authorization state as the app read it (for example "authorized").
    public var authorization: String
    public var canPresentAlert: Bool
    public var pendingCount: Int
    public var droppedEventCount: Int
    public var lastScheduledIdentifier: String?
    public var lastScheduledAt: Date?
    public var lastFailure: TaskNotificationSchedulingFailure?

    public init(
        authorization: String,
        canPresentAlert: Bool,
        pendingCount: Int,
        droppedEventCount: Int,
        lastScheduledIdentifier: String?,
        lastScheduledAt: Date?,
        lastFailure: TaskNotificationSchedulingFailure?
    ) {
        self.authorization = authorization
        self.canPresentAlert = canPresentAlert
        self.pendingCount = pendingCount
        self.droppedEventCount = droppedEventCount
        self.lastScheduledIdentifier = lastScheduledIdentifier
        self.lastScheduledAt = lastScheduledAt
        self.lastFailure = lastFailure
    }

    public static func make(
        outbox: TaskNotificationOutbox,
        authorization: String,
        canPresentAlert: Bool
    ) -> TaskNotificationDiagnostics {
        TaskNotificationDiagnostics(
            authorization: authorization,
            canPresentAlert: canPresentAlert,
            pendingCount: outbox.pendingCount,
            droppedEventCount: outbox.droppedEventCount,
            lastScheduledIdentifier: outbox.lastScheduledIdentifier,
            lastScheduledAt: outbox.lastScheduledAt,
            lastFailure: outbox.lastSchedulingFailure
        )
    }

    public var authorizationSummary: String {
        canPresentAlert ? "\(authorization)（可显示通知）" : "\(authorization)（无法显示通知）"
    }

    public var lastFailureSummary: String {
        guard let lastFailure else { return "无" }
        return "\(lastFailure.identifier) · \(lastFailure.reason)"
    }
}

/// Persistence codec for the outbox.
public enum TaskNotificationOutboxStore {
    public static let defaultsKey = "taskNotificationOutbox.v1"

    public static func load(from defaults: UserDefaults = .standard) -> TaskNotificationOutbox {
        guard let data = defaults.data(forKey: defaultsKey),
              let outbox = try? JSONDecoder().decode(
                TaskNotificationOutbox.self, from: data
              ) else { return TaskNotificationOutbox() }
        return outbox
    }

    public static func save(
        _ outbox: TaskNotificationOutbox,
        to defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(outbox) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
