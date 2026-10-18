// FloeExecution — exact Apple Calendar occurrence identity and write targeting.
//
// EventKit's `EKEvent` represents one occurrence, but `event(withIdentifier:)`
// returns the FIRST occurrence of a recurring series. The calendar list tool
// therefore emits an occurrence token `eventIdentifier@startISO`; update and
// delete must resolve that token back to exactly one occurrence. This file
// contains only Foundation value/selection logic. EventKit objects stay in the
// App target behind `CalendarOccurrenceWriting`, so the same selection and
// span propagation can be exercised with an injected spy.

import Foundation

/// One occurrence of an Apple Calendar event, identified by the series event
/// identifier plus the occurrence start instant emitted by `apple.calendar.list`.
///
/// Starts are canonicalized to whole UTC seconds. EventKit's ISO-8601
/// formatter emits whole seconds; a stored event carrying fractional seconds
/// still matches the token for its second, while a moved occurrence no longer
/// matches the stale token and is rejected instead of replacing another
/// instance.
public struct CalendarOccurrenceIdentity: Hashable, Sendable {
    public let eventIdentifier: String
    public let start: Date

    public init(eventIdentifier: String, start: Date) {
        self.eventIdentifier = eventIdentifier
        self.start = Self.canonicalStart(start)
    }

    /// Strictly parses the token emitted by `apple.calendar.list`.
    ///
    /// The date part must be the exact whole-second UTC ISO-8601 form. Offset
    /// or fractional strings are not accepted even when they denote the same
    /// instant: the caller must reuse the listed token rather than invent a
    /// new selector.
    public init?(token: String) {
        guard let separator = token.lastIndex(of: "@") else { return nil }
        let identifier = String(token[..<separator])
        let datePart = String(token[token.index(after: separator)...])
        guard !identifier.isEmpty,
              !datePart.isEmpty,
              identifier.utf8.count <= 1_024,
              !identifier.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: datePart),
              Self.isoString(date) == datePart else {
            return nil
        }
        self.init(eventIdentifier: identifier, start: date)
    }

    /// The exact `id@startISO` token consumed by update/delete.
    public var token: String {
        "\(eventIdentifier)@\(Self.isoString(start))"
    }

    public var startISO8601: String {
        Self.isoString(start)
    }

    public func matches(_ candidate: CalendarOccurrenceCandidate) -> Bool {
        candidate.eventIdentifier == eventIdentifier
            && Self.sameSecond(candidate.start, start)
    }

    public static func sameSecond(_ lhs: Date, _ rhs: Date) -> Bool {
        canonicalStart(lhs) == canonicalStart(rhs)
    }

    /// Whole-second canonical start. ISO-8601 list output truncates fractional
    /// seconds, so identity comparison must use the same precision.
    public static func canonicalStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// Minimal occurrence facts needed to validate a write target. The App adapter
/// fills these from its EventKit object; tests can build them directly.
public struct CalendarOccurrenceCandidate: Equatable, Sendable {
    public let eventIdentifier: String
    public let start: Date
    public let hasRecurrenceRules: Bool
    public let isDetached: Bool

    public init(
        eventIdentifier: String,
        start: Date,
        hasRecurrenceRules: Bool = false,
        isDetached: Bool = false
    ) {
        self.eventIdentifier = eventIdentifier
        self.start = CalendarOccurrenceIdentity.canonicalStart(start)
        self.hasRecurrenceRules = hasRecurrenceRules
        self.isDetached = isDetached
    }
}

/// Explicit write scope. `thisEvent` is the default; `futureEvents` is only
/// valid when the caller asked for the rest of a recurring series.
public enum CalendarWriteSpan: String, CaseIterable, Sendable {
    case thisEvent
    case futureEvents
}

/// The write operation is carried through the same targeting seam so update
/// and delete cannot diverge in how they choose an occurrence.
public enum CalendarOccurrenceWriteOperation: Sendable {
    case save
    case remove
}

public enum CalendarOccurrenceError: Error, Equatable, Sendable, LocalizedError {
    case malformedOccurrenceToken
    case occurrenceIdentifierMismatch
    case noMatchingOccurrence
    case ambiguousOccurrence(count: Int)
    case legacyRecurringRequiresOccurrence
    case futureEventsRequiresOccurrence
    case futureEventsRequiresRecurring
    case occurrenceNotAllowedForCreate
    case spanNotAllowedForCreate
    case invalidSpan(String)

    public var errorDescription: String? {
        switch self {
        case .malformedOccurrenceToken:
            "occurrence must be the exact id@start token returned by apple.calendar.list"
        case .occurrenceIdentifierMismatch:
            "id and occurrence refer to different calendar events; use the id and occurrence token from the same apple.calendar.list row"
        case .noMatchingOccurrence:
            "Calendar occurrence no longer matches the listed start. Call apple.calendar.list again and use the new occurrence token; no event was changed."
        case .ambiguousOccurrence(let count):
            "Calendar occurrence matches \(count) events. No event was changed; list the range again and choose a unique occurrence."
        case .legacyRecurringRequiresOccurrence:
            "This calendar event is recurring or detached. Pass the exact occurrence token from apple.calendar.list; an id alone cannot select one instance."
        case .futureEventsRequiresOccurrence:
            "span=futureEvents requires the exact occurrence token from apple.calendar.list."
        case .futureEventsRequiresRecurring:
            "span=futureEvents is only valid for a recurring calendar series."
        case .occurrenceNotAllowedForCreate:
            "create does not accept occurrence; create the event, then list its occurrences before editing one."
        case .spanNotAllowedForCreate:
            "create does not accept span."
        case .invalidSpan(let raw):
            "span must be thisEvent or futureEvents (received \(raw))."
        }
    }
}

public enum CalendarOccurrenceResolver {
    public static func parse(occurrenceToken: String) throws -> CalendarOccurrenceIdentity {
        guard let identity = CalendarOccurrenceIdentity(token: occurrenceToken) else {
            throw CalendarOccurrenceError.malformedOccurrenceToken
        }
        return identity
    }

    /// Binds the caller's `id` to the occurrence token. A valid token for a
    /// different series must never become the write target merely because the
    /// caller also supplied an `id`; validate and execute both use this seam.
    public static func bind(
        eventIdentifier: String,
        occurrenceToken: String
    ) throws -> CalendarOccurrenceIdentity {
        let identity = try parse(occurrenceToken: occurrenceToken)
        guard identity.eventIdentifier == eventIdentifier else {
            throw CalendarOccurrenceError.occurrenceIdentifierMismatch
        }
        return identity
    }

    public static func parseSpan(_ raw: String?) throws -> CalendarWriteSpan {
        guard let raw else { return .thisEvent }
        guard let span = CalendarWriteSpan(rawValue: raw) else {
            throw CalendarOccurrenceError.invalidSpan(raw)
        }
        return span
    }

    public static func validateCreate(
        occurrenceToken: String?,
        spanRaw: String?
    ) throws {
        if occurrenceToken != nil {
            throw CalendarOccurrenceError.occurrenceNotAllowedForCreate
        }
        if spanRaw != nil {
            throw CalendarOccurrenceError.spanNotAllowedForCreate
        }
    }

    /// Selects exactly one candidate. Zero matches (deleted, moved since the
    /// list, or a token for another id) and multiple matches (for example
    /// duplicate calendar items exposing the same id/start) both fail closed.
    public static func resolve<T: CalendarOccurrenceTarget>(
        _ identity: CalendarOccurrenceIdentity,
        among targets: [T]
    ) throws -> T {
        let matches = targets.filter { identity.matches($0.occurrenceCandidate) }
        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            throw CalendarOccurrenceError.noMatchingOccurrence
        default:
            throw CalendarOccurrenceError.ambiguousOccurrence(count: matches.count)
        }
    }

    /// Compatibility rule for id-only writes: allowed only for an ordinary
    /// non-recurring event, and only for `thisEvent`. A recurring or detached
    /// event requires the listed occurrence token.
    public static func validateLegacyWrite(
        hasRecurrenceRules: Bool,
        isDetached: Bool,
        span: CalendarWriteSpan
    ) throws {
        guard !hasRecurrenceRules, !isDetached else {
            throw CalendarOccurrenceError.legacyRecurringRequiresOccurrence
        }
        guard span == .thisEvent else {
            throw CalendarOccurrenceError.futureEventsRequiresRecurring
        }
    }
}

/// The App supplies EventKit-backed targets; tests supply spies. Only the
/// minimal identity facts and the already-selected target cross this seam.
public protocol CalendarOccurrenceTarget {
    var occurrenceCandidate: CalendarOccurrenceCandidate { get }
}

public protocol CalendarOccurrenceWriting {
    associatedtype Target: CalendarOccurrenceTarget
    func candidates(for identity: CalendarOccurrenceIdentity) throws -> [Target]
    func apply(
        _ operation: CalendarOccurrenceWriteOperation,
        span: CalendarWriteSpan,
        to target: Target
    ) throws
}

/// Production selection path: resolve the exact occurrence first, validate the
/// requested span against the selected target, then invoke the adapter exactly
/// once. Resolution or validation failure performs no write.
public struct CalendarOccurrenceWriter<Adapter: CalendarOccurrenceWriting> {
    public let adapter: Adapter

    public init(adapter: Adapter) {
        self.adapter = adapter
    }

    @discardableResult
    public func apply(
        identity: CalendarOccurrenceIdentity,
        span: CalendarWriteSpan,
        operation: CalendarOccurrenceWriteOperation = .save
    ) throws -> Adapter.Target {
        let target = try CalendarOccurrenceResolver.resolve(
            identity,
            among: adapter.candidates(for: identity)
        )
        if span == .futureEvents, !target.occurrenceCandidate.hasRecurrenceRules {
            throw CalendarOccurrenceError.futureEventsRequiresRecurring
        }
        try adapter.apply(operation, span: span, to: target)
        return target
    }
}
