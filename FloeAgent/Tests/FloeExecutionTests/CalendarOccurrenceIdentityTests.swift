// FloeExecutionTests — exact Apple Calendar occurrence targeting.
//
// EventKit object reads/writes stay in the App host; these cases exercise the
// production pure resolver and writer with an injected spy. They pin the
// identity that reaches the write adapter (same-series instances, all-day and
// timezone instants, moved starts, delete targeting) and the explicit span and
// operation, plus every fail-closed path: stale, wrong id, zero, ambiguous,
// legacy recurring and malformed arguments.

import Foundation
import Testing
@testable import FloeExecution

private func instant(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso)!
}

private struct SpyOccurrenceTarget: CalendarOccurrenceTarget {
    let label: String
    let occurrenceCandidate: CalendarOccurrenceCandidate
}

private final class SpyOccurrenceWriter: CalendarOccurrenceWriting {
    typealias Target = SpyOccurrenceTarget

    let targets: [SpyOccurrenceTarget]
    private(set) var candidateRequests = 0
    private(set) var applications: [(operation: CalendarOccurrenceWriteOperation, span: CalendarWriteSpan, label: String)] = []

    init(targets: [SpyOccurrenceTarget]) {
        self.targets = targets
    }

    func candidates(for identity: CalendarOccurrenceIdentity) throws -> [SpyOccurrenceTarget] {
        candidateRequests += 1
        return targets
    }

    func apply(
        _ operation: CalendarOccurrenceWriteOperation,
        span: CalendarWriteSpan,
        to target: SpyOccurrenceTarget
    ) throws {
        applications.append((operation, span, target.label))
    }
}

private func target(
    _ label: String,
    id: String = "series-A",
    startISO: String,
    hasRecurrenceRules: Bool = true,
    isDetached: Bool = false
) -> SpyOccurrenceTarget {
    SpyOccurrenceTarget(
        label: label,
        occurrenceCandidate: CalendarOccurrenceCandidate(
            eventIdentifier: id,
            start: instant(startISO),
            hasRecurrenceRules: hasRecurrenceRules,
            isDetached: isDetached
        )
    )
}

@Suite("FloeExecution.CalendarOccurrenceIdentity")
struct CalendarOccurrenceIdentityTests {

    @Test("Token round-trips the exact instant and canonicalizes time zones")
    func tokenRoundTripsAndCanonicalizesTimeZone() throws {
        let sydney = CalendarOccurrenceIdentity(
            eventIdentifier: "series-A",
            start: instant("2026-10-25T19:00:00+10:00")
        )
        #expect(sydney.token == "series-A@2026-10-25T09:00:00Z")
        let parsed = try CalendarOccurrenceResolver.parse(occurrenceToken: sydney.token)
        #expect(parsed == sydney)

        // All-day starts are instants too; the token keeps the same instant
        // even when the source was expressed in a +11:00 zone.
        let allDay = CalendarOccurrenceIdentity(
            eventIdentifier: "series-B",
            start: instant("2026-10-19T00:00:00+11:00")
        )
        #expect(allDay.token == "series-B@2026-10-18T13:00:00Z")
        let parsedAllDay = try CalendarOccurrenceResolver.parse(occurrenceToken: allDay.token)
        #expect(parsedAllDay == allDay)
    }

    @Test("Malformed or invented tokens fail closed")
    func malformedTokensFailClosed() {
        let malformed = [
            "series-A",
            "@2026-10-25T09:00:00Z",
            "series-A@",
            "series-A@2026-10-25",
            "series-A@2026-10-25T09:00:00.500Z",
            "series-A@2026-10-25T19:00:00+10:00",
            "series-A@2026-02-30T09:00:00Z",
            "series-A@2026-10-25T09:00:00Z\n",
            "bad\nid@2026-10-25T09:00:00Z",
            "\(String(repeating: "x", count: 1_025))@2026-10-25T09:00:00Z"
        ]
        for token in malformed {
            #expect(throws: CalendarOccurrenceError.malformedOccurrenceToken) {
                try CalendarOccurrenceResolver.parse(occurrenceToken: token)
            }
        }
    }

    @Test("A series token selects the listed occurrence, never the first instance")
    func selectsExactSeriesOccurrence() throws {
        let spy = SpyOccurrenceWriter(targets: [
            target("first", startISO: "2026-10-18T09:00:00Z"),
            target("second", startISO: "2026-10-25T09:00:00Z"),
            target("third", startISO: "2026-11-01T09:00:00Z")
        ])
        let writer = CalendarOccurrenceWriter(adapter: spy)
        let identity = try CalendarOccurrenceResolver.parse(
            occurrenceToken: "series-A@2026-10-25T09:00:00Z"
        )

        let selected = try writer.apply(identity: identity, span: .thisEvent)
        #expect(selected.label == "second")
        #expect(spy.candidateRequests == 1)
        #expect(spy.applications.count == 1)
        #expect(spy.applications.first?.label == "second")
        #expect(spy.applications.first?.span == .thisEvent)
        #expect(spy.applications.first?.operation == .save)
    }

    @Test("futureEvents and delete carry the selected occurrence and explicit scope")
    func futureScopeAndDeleteUseSelectedOccurrence() throws {
        let spy = SpyOccurrenceWriter(targets: [
            target("first", startISO: "2026-10-18T09:00:00Z"),
            target("second", startISO: "2026-10-25T09:00:00Z"),
            target("third", startISO: "2026-11-01T09:00:00Z")
        ])
        let writer = CalendarOccurrenceWriter(adapter: spy)
        let identity = try CalendarOccurrenceResolver.parse(
            occurrenceToken: "series-A@2026-10-25T09:00:00Z"
        )

        let future = try writer.apply(identity: identity, span: .futureEvents, operation: .save)
        #expect(future.label == "second")
        #expect(spy.applications.last?.span == .futureEvents)
        #expect(spy.applications.last?.operation == .save)

        let deleted = try writer.apply(identity: identity, span: .thisEvent, operation: .remove)
        #expect(deleted.label == "second")
        #expect(spy.applications.last?.span == .thisEvent)
        #expect(spy.applications.last?.operation == .remove)
        #expect(spy.applications.count == 2)
    }

    @Test("A moved occurrence is selectable only through its listed new start")
    func movedOccurrenceRequiresFreshToken() throws {
        let spy = SpyOccurrenceWriter(targets: [
            target("moved", startISO: "2026-10-25T10:30:00Z")
        ])
        let writer = CalendarOccurrenceWriter(adapter: spy)
        let stale = try CalendarOccurrenceResolver.parse(
            occurrenceToken: "series-A@2026-10-25T09:00:00Z"
        )

        #expect(throws: CalendarOccurrenceError.noMatchingOccurrence) {
            try writer.apply(identity: stale, span: .thisEvent)
        }
        #expect(spy.applications.isEmpty)

        let fresh = try CalendarOccurrenceResolver.parse(
            occurrenceToken: "series-A@2026-10-25T10:30:00Z"
        )
        let selected = try writer.apply(identity: fresh, span: .thisEvent)
        #expect(selected.label == "moved")
        #expect(spy.applications.count == 1)
    }

    @Test("A same-start event under another series id is not a match")
    func wrongIdentifierFailsClosed() throws {
        let spy = SpyOccurrenceWriter(targets: [
            target("other-series", id: "series-B", startISO: "2026-10-25T09:00:00Z")
        ])
        let identity = try CalendarOccurrenceResolver.parse(
            occurrenceToken: "series-A@2026-10-25T09:00:00Z"
        )
        #expect(throws: CalendarOccurrenceError.noMatchingOccurrence) {
            try CalendarOccurrenceWriter(adapter: spy).apply(identity: identity, span: .thisEvent)
        }
        #expect(spy.applications.isEmpty)
    }

    @Test("An id and occurrence from different events are rejected before any write")
    func identifierBindingFailsClosed() throws {
        #expect(throws: CalendarOccurrenceError.occurrenceIdentifierMismatch) {
            try CalendarOccurrenceResolver.bind(
                eventIdentifier: "series-A",
                occurrenceToken: "series-B@2026-10-25T09:00:00Z"
            )
        }

        let bound = try CalendarOccurrenceResolver.bind(
            eventIdentifier: "series-A",
            occurrenceToken: "series-A@2026-10-25T09:00:00Z"
        )
        #expect(bound.eventIdentifier == "series-A")

        // A valid token for B must not become the target of an id=A request:
        // binding fails before candidate lookup, so the adapter is never asked
        // to select or write anything.
        let spy = SpyOccurrenceWriter(targets: [
            target("series-b-instance", id: "series-B", startISO: "2026-10-25T09:00:00Z")
        ])
        #expect(throws: CalendarOccurrenceError.occurrenceIdentifierMismatch) {
            let identity = try CalendarOccurrenceResolver.bind(
                eventIdentifier: "series-A",
                occurrenceToken: "series-B@2026-10-25T09:00:00Z"
            )
            _ = try CalendarOccurrenceWriter(adapter: spy).apply(
                identity: identity,
                span: .thisEvent
            )
        }
        #expect(spy.candidateRequests == 0)
        #expect(spy.applications.isEmpty)
    }

    @Test("Zero candidates never falls back to a first occurrence")
    func zeroCandidatesFailClosed() throws {
        let spy = SpyOccurrenceWriter(targets: [])
        let identity = try CalendarOccurrenceResolver.parse(
            occurrenceToken: "series-A@2026-10-25T09:00:00Z"
        )
        #expect(throws: CalendarOccurrenceError.noMatchingOccurrence) {
            try CalendarOccurrenceWriter(adapter: spy).apply(identity: identity, span: .thisEvent)
        }
        #expect(spy.candidateRequests == 1)
        #expect(spy.applications.isEmpty)
    }

    @Test("Duplicate id and start are ambiguous and perform no write")
    func ambiguousOccurrenceFailsClosed() throws {
        let duplicate = CalendarOccurrenceCandidate(
            eventIdentifier: "series-A",
            start: instant("2026-10-25T09:00:00Z"),
            hasRecurrenceRules: true
        )
        let spy = SpyOccurrenceWriter(targets: [
            SpyOccurrenceTarget(label: "calendar-one", occurrenceCandidate: duplicate),
            SpyOccurrenceTarget(label: "calendar-two", occurrenceCandidate: duplicate)
        ])
        let identity = try CalendarOccurrenceResolver.parse(
            occurrenceToken: "series-A@2026-10-25T09:00:00Z"
        )
        #expect(throws: CalendarOccurrenceError.ambiguousOccurrence(count: 2)) {
            try CalendarOccurrenceWriter(adapter: spy).apply(identity: identity, span: .thisEvent)
        }
        #expect(spy.applications.isEmpty)
    }

    @Test("Fractional starts match the whole-second token emitted by the list")
    func fractionalStartMatchesItsSecond() throws {
        let fractional = CalendarOccurrenceCandidate(
            eventIdentifier: "series-A",
            start: instant("2026-10-25T09:00:00Z").addingTimeInterval(0.75),
            hasRecurrenceRules: true
        )
        #expect(fractional.start == instant("2026-10-25T09:00:00Z"))
        let spy = SpyOccurrenceWriter(targets: [
            SpyOccurrenceTarget(label: "fractional", occurrenceCandidate: fractional)
        ])
        let identity = try CalendarOccurrenceResolver.parse(
            occurrenceToken: "series-A@2026-10-25T09:00:00Z"
        )
        let selected = try CalendarOccurrenceWriter(adapter: spy).apply(
            identity: identity,
            span: .thisEvent
        )
        #expect(selected.label == "fractional")
    }

    @Test("Legacy id-only writes are limited to ordinary non-recurring thisEvent")
    func legacyWritesFailClosed() throws {
        try CalendarOccurrenceResolver.validateLegacyWrite(
            hasRecurrenceRules: false,
            isDetached: false,
            span: .thisEvent
        )
        #expect(throws: CalendarOccurrenceError.legacyRecurringRequiresOccurrence) {
            try CalendarOccurrenceResolver.validateLegacyWrite(
                hasRecurrenceRules: true,
                isDetached: false,
                span: .thisEvent
            )
        }
        #expect(throws: CalendarOccurrenceError.legacyRecurringRequiresOccurrence) {
            try CalendarOccurrenceResolver.validateLegacyWrite(
                hasRecurrenceRules: false,
                isDetached: true,
                span: .thisEvent
            )
        }
        #expect(throws: CalendarOccurrenceError.futureEventsRequiresRecurring) {
            try CalendarOccurrenceResolver.validateLegacyWrite(
                hasRecurrenceRules: false,
                isDetached: false,
                span: .futureEvents
            )
        }

        // Even a valid occurrence token cannot expand a non-recurring event
        // into a future series.
        let spy = SpyOccurrenceWriter(targets: [
            target(
                "ordinary",
                startISO: "2026-10-25T09:00:00Z",
                hasRecurrenceRules: false
            )
        ])
        let identity = try CalendarOccurrenceResolver.parse(
            occurrenceToken: "series-A@2026-10-25T09:00:00Z"
        )
        #expect(throws: CalendarOccurrenceError.futureEventsRequiresRecurring) {
            try CalendarOccurrenceWriter(adapter: spy).apply(
                identity: identity,
                span: .futureEvents
            )
        }
        #expect(spy.applications.isEmpty)
    }

    @Test("Create rejects occurrence/span and span parsing is explicit")
    func createAndSpanValidation() throws {
        try CalendarOccurrenceResolver.validateCreate(occurrenceToken: nil, spanRaw: nil)
        #expect(throws: CalendarOccurrenceError.occurrenceNotAllowedForCreate) {
            try CalendarOccurrenceResolver.validateCreate(
                occurrenceToken: "series-A@2026-10-25T09:00:00Z",
                spanRaw: nil
            )
        }
        #expect(throws: CalendarOccurrenceError.spanNotAllowedForCreate) {
            try CalendarOccurrenceResolver.validateCreate(
                occurrenceToken: nil,
                spanRaw: "thisEvent"
            )
        }

        let defaultSpan = try CalendarOccurrenceResolver.parseSpan(nil)
        let thisEvent = try CalendarOccurrenceResolver.parseSpan("thisEvent")
        let futureEvents = try CalendarOccurrenceResolver.parseSpan("futureEvents")
        #expect(defaultSpan == .thisEvent)
        #expect(thisEvent == .thisEvent)
        #expect(futureEvents == .futureEvents)
        #expect(throws: CalendarOccurrenceError.invalidSpan("series")) {
            try CalendarOccurrenceResolver.parseSpan("series")
        }
    }
}
