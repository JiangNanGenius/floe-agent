// FloeAppTests — real EventKit acceptance for exact Apple Calendar occurrences.
//
// Creates ONE task-owned local-only calendar (unique UUID title) with a
// three-occurrence recurring series and one standalone event, then drives the
// REAL production `AppleCalendarUpdateTool` to update exactly the second
// occurrence. EventKit read-back is restricted to that owned calendar and
// proves the first/third occurrences and the standalone event are unchanged.
// The same production tool then deletes the selected occurrence, and the
// read-back proves only that occurrence disappeared. A second case supplies
// the id of series A with the occurrence token of event B and proves the
// production path rejects it before any EventKit write.
//
// The fixture never selects or writes an account-backed source; its own reads
// are restricted to the owned calendar and it never exports a pre-existing
// user calendar. If full access or a local source is missing the test FAILS
// with the exact precondition; an unavailable environment is never reported
// as a pass or a skip.
//
// Host precondition (canonical iPad only, serialized): pre-grant the App
// bundle's Calendar access, for example
//   xcrun simctl privacy "$FLOE_SIMULATOR_UDID" grant calendar org.floeagent.ios
// This test does not present a permission prompt and does not reset EventKit
// or any simulator-global data.

#if canImport(UIKit)
import Foundation
import XCTest
import FloeCore
import FloeExecution
import FloeTools
@preconcurrency import EventKit
@testable import FloeApp

@MainActor
final class AppleCalendarOccurrenceAppQualificationTests: XCTestCase {

    // MARK: - Required acceptance

    func testUpdatesOnlySecondOccurrenceThenDeletesIt() async throws {
        executionTimeAllowance = 180
        let fixture = try makeFixture(occurrenceCount: 3, includeStandaloneEvent: true)
        defer { removeFixture(fixture) }
        let context = makeContext()

        let initial = try fixtureOccurrences(fixture)
        XCTAssertEqual(initial.count, 4,
                       "expected three series occurrences plus one standalone fixture event: \(describe(initial))")
        let series = initial.filter { $0.title == fixture.seriesTitle }
            .sorted { $0.start < $1.start }
        XCTAssertEqual(series.count, 3, "EventKit must expose all three recurring occurrences")
        XCTAssertEqual(Set(series.map(\.start)).count, 3,
                       "the recurring occurrences must have distinct starts")
        XCTAssertTrue(series.allSatisfy { $0.hasRecurrenceRules },
                      "the fixture occurrences must belong to a real recurring EventKit series")
        let first = try XCTUnwrap(series.first, "missing first fixture occurrence")
        let second = try XCTUnwrap(series.dropFirst().first, "missing second fixture occurrence")
        let third = try XCTUnwrap(series.dropFirst(2).first, "missing third fixture occurrence")
        XCTAssertEqual(first.title, fixture.seriesTitle)
        XCTAssertEqual(second.title, fixture.seriesTitle)
        XCTAssertEqual(third.title, fixture.seriesTitle)
        let standaloneTitle = try XCTUnwrap(fixture.standaloneTitle)
        let standalone = try XCTUnwrap(initial.first { $0.title == standaloneTitle },
                                       "the standalone fixture event must be listed")

        let tool = AppleCalendarUpdateTool()
        // Supply the selected occurrence's own start/end so the update
        // exercises the production requestedStart binding, not only the
        // no-start fallback.
        let updateArgs = AppleCalendarUpdateTool.Arguments(
            action: "update",
            id: second.identifier,
            occurrence: second.token,
            span: "thisEvent",
            title: fixture.editedTitle,
            start: iso(second.start),
            end: iso(second.start.addingTimeInterval(30 * 60)),
            notes: fixture.editedNote,
            location: nil,
            isAllDay: nil
        )
        try tool.validate(updateArgs)
        let updated = try await tool.execute(updateArgs, context: context)
        XCTAssertEqual(updated.exitStatus ?? -1, 0)
        XCTAssertTrue(updated.summary.contains("status=ok action=update"), updated.summary)
        XCTAssertTrue(updated.summary.contains("verified=true"),
                      "the update must prove the write with a real EventKit read-back: \(updated.summary)")
        XCTAssertTrue(updated.summary.contains("readback=occurrence"), updated.summary)
        XCTAssertTrue(updated.summary.contains("verificationScope=targetOccurrence"), updated.summary)
        XCTAssertTrue(updated.summary.contains("span=thisEvent"), updated.summary)
        let updatedToken = try field("occurrence", in: updated.summary)
        let updatedIdentifier = try field("id", in: updated.summary)
        let updatedIdentity = try XCTUnwrap(
            CalendarOccurrenceIdentity(token: updatedToken),
            "the update response must return a reusable occurrence token"
        )
        XCTAssertEqual(updatedIdentity.eventIdentifier, updatedIdentifier)
        XCTAssertEqual(CalendarOccurrenceIdentity.canonicalStart(updatedIdentity.start),
                       second.start,
                       "the update response must identify the selected occurrence start")

        let afterUpdate = try fixtureOccurrences(fixture)
        XCTAssertEqual(afterUpdate.count, 4,
                       "updating one occurrence must not add or remove fixture events: \(describe(afterUpdate))")
        let afterFirst = try occurrence(at: first.start, in: afterUpdate)
        let afterSecond = try occurrence(at: second.start, in: afterUpdate)
        let afterThird = try occurrence(at: third.start, in: afterUpdate)
        XCTAssertEqual(afterFirst.title, first.title,
                       "the first occurrence must be unchanged")
        XCTAssertEqual(afterFirst.notes, first.notes,
                       "the first occurrence notes must be unchanged")
        XCTAssertEqual(afterFirst.end, first.end,
                       "the first occurrence end must be unchanged")
        XCTAssertEqual(afterFirst.hasRecurrenceRules, first.hasRecurrenceRules)
        XCTAssertEqual(afterFirst.isDetached, first.isDetached)
        XCTAssertEqual(afterThird.title, third.title,
                       "the last occurrence must be unchanged")
        XCTAssertEqual(afterThird.notes, third.notes,
                       "the last occurrence notes must be unchanged")
        XCTAssertEqual(afterThird.end, third.end,
                       "the last occurrence end must be unchanged")
        XCTAssertEqual(afterThird.hasRecurrenceRules, third.hasRecurrenceRules)
        XCTAssertEqual(afterThird.isDetached, third.isDetached)
        XCTAssertEqual(afterSecond.title, fixture.editedTitle,
                       "only the selected second occurrence may change")
        XCTAssertEqual(afterSecond.notes, fixture.editedNote,
                       "the selected second occurrence must carry the written notes")
        let afterSecondEnd = try XCTUnwrap(afterSecond.end)
        XCTAssertEqual(CalendarOccurrenceIdentity.canonicalStart(afterSecondEnd),
                       CalendarOccurrenceIdentity.canonicalStart(
                           second.start.addingTimeInterval(30 * 60)
                       ),
                       "the selected second occurrence must keep the requested end")
        XCTAssertTrue(afterSecond.isDetached,
                      "editing exactly one occurrence must detach it from the recurring series")
        XCTAssertEqual(afterSecond.identifier, updatedIdentifier,
                       "the read-back must expose the identity returned by the tool")
        let afterStandalone = try occurrence(at: standalone.start, in: afterUpdate)
        XCTAssertEqual(afterStandalone.title, standalone.title)
        XCTAssertEqual(afterStandalone.notes, standalone.notes)
        XCTAssertEqual(afterStandalone.end, standalone.end)
        XCTAssertEqual(afterStandalone.token, standalone.token,
                       "the standalone fixture event must not change")

        let deleteArgs = AppleCalendarUpdateTool.Arguments(
            action: "delete",
            id: updatedIdentity.eventIdentifier,
            occurrence: updatedToken,
            span: "thisEvent",
            title: nil,
            start: nil,
            end: nil,
            notes: nil,
            location: nil,
            isAllDay: nil
        )
        try tool.validate(deleteArgs)
        let deleted = try await tool.execute(deleteArgs, context: context)
        XCTAssertEqual(deleted.exitStatus ?? -1, 0)
        XCTAssertTrue(deleted.summary.contains("status=ok action=delete"), deleted.summary)
        XCTAssertTrue(deleted.summary.contains("verified=true"),
                      "the delete must prove absence with a real EventKit read-back: \(deleted.summary)")
        XCTAssertTrue(deleted.summary.contains("readback=absent"), deleted.summary)
        XCTAssertTrue(deleted.summary.contains("verificationScope=targetOccurrence"), deleted.summary)
        XCTAssertTrue(deleted.summary.contains("span=thisEvent"), deleted.summary)
        XCTAssertTrue(deleted.summary.contains("occurrence=\(updatedToken)"), deleted.summary)

        let afterDelete = try fixtureOccurrences(fixture)
        XCTAssertEqual(afterDelete.count, 3,
                       "deleting the selected occurrence must leave three fixture events: \(describe(afterDelete))")
        XCTAssertTrue(afterDelete.allSatisfy {
            !CalendarOccurrenceIdentity.sameSecond($0.start, second.start)
        }, "the deleted occurrence must no longer be listed")
        let remainingFirst = try occurrence(at: first.start, in: afterDelete)
        let remainingThird = try occurrence(at: third.start, in: afterDelete)
        XCTAssertEqual(remainingFirst.title, first.title)
        XCTAssertEqual(remainingFirst.notes, first.notes)
        XCTAssertEqual(remainingFirst.end, first.end)
        XCTAssertEqual(remainingThird.title, third.title)
        XCTAssertEqual(remainingThird.notes, third.notes)
        XCTAssertEqual(remainingThird.end, third.end)
        let remainingStandalone = try occurrence(at: standalone.start, in: afterDelete)
        XCTAssertEqual(remainingStandalone.token, standalone.token)
    }

    func testFutureScopeStartsAtSelectedOccurrence() async throws {
        executionTimeAllowance = 180
        let fixture = try makeFixture(occurrenceCount: 3, includeStandaloneEvent: true)
        defer { removeFixture(fixture) }
        let initial = try fixtureOccurrences(fixture)
        let series = initial.filter { $0.title == fixture.seriesTitle }
            .sorted { $0.start < $1.start }
        XCTAssertEqual(series.count, 3)
        let first = try XCTUnwrap(series.first)
        let second = try XCTUnwrap(series.dropFirst().first)
        let third = try XCTUnwrap(series.dropFirst(2).first)
        let standalone = try XCTUnwrap(initial.first { $0.title == fixture.standaloneTitle })
        let tool = AppleCalendarUpdateTool()
        let context = makeContext()
        let update = AppleCalendarUpdateTool.Arguments(
            action: "update", id: second.identifier, occurrence: second.token,
            span: "futureEvents", title: fixture.editedTitle, start: nil, end: nil,
            notes: fixture.editedNote, location: nil, isAllDay: nil
        )
        try tool.validate(update)
        let result = try await tool.execute(update, context: context)
        XCTAssertEqual(result.exitStatus ?? -1, 0)
        XCTAssertTrue(result.summary.contains("verified=true"), result.summary)
        XCTAssertTrue(result.summary.contains("span=futureEvents"), result.summary)
        XCTAssertTrue(result.summary.contains("verificationScope=targetOccurrence"), result.summary)
        let updated = try fixtureOccurrences(fixture)
        XCTAssertEqual(updated.count, 4)
        let untouchedFirst = try occurrence(at: first.start, in: updated)
        XCTAssertEqual(untouchedFirst.title, first.title)
        XCTAssertEqual(untouchedFirst.notes, first.notes)
        XCTAssertEqual(untouchedFirst.end, first.end)
        for original in [second, third] {
            let changed = try occurrence(at: original.start, in: updated)
            XCTAssertEqual(changed.title, fixture.editedTitle)
            XCTAssertEqual(changed.notes, fixture.editedNote)
            XCTAssertEqual(changed.end, original.end)
        }
        XCTAssertEqual(try occurrence(at: standalone.start, in: updated), standalone)

        // A future-series split may change its identifier. Reuse the actual
        // post-write occurrence instead of assuming the previous series id.
        let selected = try occurrence(at: second.start, in: updated)
        XCTAssertEqual(try field("occurrence", in: result.summary), selected.token)
        let remove = AppleCalendarUpdateTool.Arguments(
            action: "delete", id: selected.identifier, occurrence: selected.token,
            span: "futureEvents", title: nil, start: nil, end: nil,
            notes: nil, location: nil, isAllDay: nil
        )
        try tool.validate(remove)
        let deleted = try await tool.execute(remove, context: context)
        XCTAssertEqual(deleted.exitStatus ?? -1, 0)
        XCTAssertTrue(deleted.summary.contains("verified=true"), deleted.summary)
        XCTAssertTrue(deleted.summary.contains("span=futureEvents"), deleted.summary)
        let remaining = try fixtureOccurrences(fixture)
        XCTAssertEqual(remaining.count, 2)
        let keptFirst = try occurrence(at: first.start, in: remaining)
        XCTAssertEqual(keptFirst.title, first.title)
        XCTAssertEqual(keptFirst.notes, first.notes)
        XCTAssertEqual(keptFirst.end, first.end)
        XCTAssertEqual(try occurrence(at: standalone.start, in: remaining), standalone)
        XCTAssertFalse(remaining.contains { $0.start == second.start || $0.start == third.start })
    }

    func testMismatchedSeriesIdAndOccurrenceTokenWritesNothing() async throws {
        executionTimeAllowance = 120
        let fixture = try makeFixture(occurrenceCount: 3, includeStandaloneEvent: true)
        defer { removeFixture(fixture) }
        let context = makeContext()

        let initial = try fixtureOccurrences(fixture)
        XCTAssertEqual(initial.count, 4, describe(initial))
        let series = initial.filter { $0.title == fixture.seriesTitle }
            .sorted { $0.start < $1.start }
        XCTAssertEqual(series.count, 3)
        let targetOccurrence = try XCTUnwrap(series.dropFirst().first,
                                             "missing second fixture occurrence")
        let standaloneTitle = try XCTUnwrap(fixture.standaloneTitle)
        let standalone = try XCTUnwrap(initial.first { $0.title == standaloneTitle })

        let args = AppleCalendarUpdateTool.Arguments(
            action: "update",
            id: targetOccurrence.identifier,   // series A
            occurrence: standalone.token,      // occurrence B from a different event
            span: "thisEvent",
            title: "\(fixture.identifier)-must-not-apply",
            start: nil,
            end: nil,
            notes: nil,
            location: nil,
            isAllDay: nil
        )
        let tool = AppleCalendarUpdateTool()

        var validateRejected = false
        do {
            try tool.validate(args)
        } catch {
            validateRejected = true
            assertMismatchError(error)
        }
        XCTAssertTrue(validateRejected,
                      "preflight must reject an id and occurrence from different events")

        var executeRejected = false
        do {
            _ = try await tool.execute(args, context: context)
        } catch {
            executeRejected = true
            assertMismatchError(error)
        }
        XCTAssertTrue(executeRejected,
                      "execute must reject an id and occurrence from different events")

        let after = try fixtureOccurrences(fixture)
        XCTAssertEqual(after, initial,
                       "a rejected id/occurrence mismatch must leave every EventKit fixture event unchanged")
    }

    // MARK: - Task-owned local fixture

    private struct Fixture {
        let identifier: String
        let calendarIdentifier: String
        let calendarTitle: String
        let seriesTitle: String
        let editedTitle: String
        let standaloneTitle: String?
        let editedNote: String
        let queryStart: Date
        let queryEnd: Date
    }

    private struct FixtureOccurrence: Equatable {
        let identifier: String
        let token: String
        let start: Date
        let end: Date?
        let title: String
        let notes: String?
        let hasRecurrenceRules: Bool
        let isDetached: Bool
    }

    private enum FixtureError: LocalizedError {
        case precondition(String)
        case invalidFixture(String)

        var errorDescription: String? {
            switch self {
            case .precondition(let message), .invalidFixture(let message):
                return message
            }
        }
    }

    private func makeFixture(
        occurrenceCount: Int,
        includeStandaloneEvent: Bool
    ) throws -> Fixture {
        try requireCalendarAccess()

        let identifier = "FloeOccQA-\(UUID().uuidString)"
        let seriesTitle = "\(identifier)-series"
        let editedTitle = "\(identifier)-edited"
        let standaloneTitle = includeStandaloneEvent ? "\(identifier)-standalone" : nil
        let seriesNote = "\(identifier)-series-note"
        let editedNote = "\(identifier)-edited-note"

        let store = EKEventStore()
        store.reset()
        guard let source = store.sources.first(where: { $0.sourceType == .local }) else {
            throw FixtureError.precondition(
                "No local EventKit source is available on this simulator. This qualification "
                + "refuses to use an account-backed source. Ensure the canonical iPad has its "
                + "local 'On My iPad' calendar source (open Calendar once), then rerun. "
                + "No account login or user calendar is used."
            )
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.source = source
        calendar.title = identifier
        calendar.timeZone = TimeZone.current
        try store.saveCalendar(calendar, commit: true)
        guard let savedSource = calendar.source, savedSource.sourceType == .local else {
            do {
                try store.removeCalendar(calendar, commit: true)
            } catch let cleanupError {
                XCTFail("failed to remove the non-local fixture calendar: \(cleanupError)")
            }
            throw FixtureError.invalidFixture(
                "the saved fixture calendar is not on a local, non-account source"
            )
        }
        let calendarIdentifier = calendar.calendarIdentifier

        do {
            let start = try fixtureStart()
            let series = EKEvent(eventStore: store)
            series.calendar = calendar
            series.title = seriesTitle
            series.startDate = start
            series.endDate = start.addingTimeInterval(30 * 60)
            series.notes = seriesNote
            series.addRecurrenceRule(
                EKRecurrenceRule(
                    recurrenceWith: .daily,
                    interval: 1,
                    end: EKRecurrenceEnd(occurrenceCount: occurrenceCount)
                )
            )
            try store.save(series, span: .thisEvent, commit: true)

            if let standaloneTitle {
                let standaloneStart = start.addingTimeInterval(6 * 3600)
                let standalone = EKEvent(eventStore: store)
                standalone.calendar = calendar
                standalone.title = standaloneTitle
                standalone.startDate = standaloneStart
                standalone.endDate = standaloneStart.addingTimeInterval(30 * 60)
                try store.save(standalone, span: .thisEvent, commit: true)
            }

            return Fixture(
                identifier: identifier,
                calendarIdentifier: calendarIdentifier,
                calendarTitle: identifier,
                seriesTitle: seriesTitle,
                editedTitle: editedTitle,
                standaloneTitle: standaloneTitle,
                editedNote: editedNote,
                queryStart: start.addingTimeInterval(-24 * 3600),
                queryEnd: start.addingTimeInterval(6 * 24 * 3600)
            )
        } catch {
            do {
                try store.removeCalendar(calendar, commit: true)
            } catch let cleanupError {
                XCTFail("failed to remove the task-owned fixture calendar after setup failed: \(cleanupError)")
            }
            throw error
        }
    }

    private func fixtureStart() throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let day = calendar.date(byAdding: .day, value: 7, to: Date()) else {
            throw FixtureError.invalidFixture("could not compute the fixture day")
        }
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = 10
        components.minute = 0
        components.second = 0
        components.nanosecond = 0
        guard let start = calendar.date(from: components) else {
            throw FixtureError.invalidFixture("could not build the fixture start")
        }
        return start
    }

    private func requireCalendarAccess() throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            throw FixtureError.precondition(
                "Calendar full access is \(authorizationLabel(status)) for the App host. "
                + "Pre-grant the canonical iPad before running, for example: "
                + "xcrun simctl privacy \"$FLOE_SIMULATOR_UDID\" grant calendar org.floeagent.ios. "
                + "This test creates only its own local calendar and never writes an "
                + "account-backed or pre-existing user calendar."
            )
        }
    }

    private func authorizationLabel(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: return "fullAccess"
        case .writeOnly: return "writeOnly"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    /// Read-only EventKit view restricted to the task-owned fixture calendar.
    /// No user/account calendar is queried or returned.
    private func fixtureOccurrences(_ fixture: Fixture) throws -> [FixtureOccurrence] {
        let store = EKEventStore()
        store.reset()
        guard let calendar = store.calendar(withIdentifier: fixture.calendarIdentifier) else {
            throw FixtureError.invalidFixture(
                "the task-owned fixture calendar is missing: \(fixture.calendarTitle)"
            )
        }
        let predicate = store.predicateForEvents(
            withStart: fixture.queryStart,
            end: fixture.queryEnd,
            calendars: [calendar]
        )
        var occurrences: [FixtureOccurrence] = []
        for event in store.events(matching: predicate) {
            guard let identifier = event.eventIdentifier, !identifier.isEmpty,
                  let start = event.startDate else {
                throw FixtureError.invalidFixture(
                    "a fixture event has no readable EventKit identity"
                )
            }
            let identity = CalendarOccurrenceIdentity(eventIdentifier: identifier, start: start)
            occurrences.append(FixtureOccurrence(
                identifier: identifier,
                token: identity.token,
                start: identity.start,
                end: event.endDate.map(CalendarOccurrenceIdentity.canonicalStart),
                title: event.title ?? "",
                notes: event.notes,
                hasRecurrenceRules: event.hasRecurrenceRules,
                isDetached: event.isDetached
            ))
        }
        return occurrences.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.token < rhs.token
        }
    }

    private func removeFixture(_ fixture: Fixture) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            XCTFail(
                "Calendar access is no longer full access; the task-owned fixture calendar "
                + "\(fixture.calendarTitle) could not be removed"
            )
            return
        }
        let store = EKEventStore()
        store.reset()
        guard let calendar = store.calendar(withIdentifier: fixture.calendarIdentifier) else {
            return
        }
        do {
            try store.removeCalendar(calendar, commit: true)
        } catch {
            XCTFail("failed to remove the task-owned fixture calendar \(fixture.calendarTitle): \(error)")
            return
        }
        // removeCalendar(commit: true) is synchronous locally, but allow the
        // store daemon a bounded moment to reflect the deletion before
        // reporting a cleanup failure.
        for _ in 0..<20 {
            store.reset()
            if store.calendar(withIdentifier: fixture.calendarIdentifier) == nil {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("the task-owned fixture calendar still exists after cleanup: \(fixture.calendarTitle)")
    }

    // MARK: - Helpers

    private func makeContext() -> ToolContext {
        ToolContext(
            runID: UUID(),
            cancellation: CancellationToken(),
            environmentID: "calendar-app-qualification",
            conversationID: UUID()
        )
    }

    private func occurrence(
        at start: Date,
        in rows: [FixtureOccurrence]
    ) throws -> FixtureOccurrence {
        let matches = rows.filter {
            CalendarOccurrenceIdentity.sameSecond($0.start, start)
        }
        guard matches.count == 1, let match = matches.first else {
            throw FixtureError.invalidFixture(
                "expected exactly one fixture occurrence at \(iso(start)); "
                + "found \(matches.count): \(describe(rows))"
            )
        }
        return match
    }

    private func field(_ name: String, in summary: String) throws -> String {
        for part in summary.split(whereSeparator: { $0.isWhitespace }) {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2, String(pair[0]) == name {
                return String(pair[1])
            }
        }
        throw FixtureError.invalidFixture("tool response lacked \(name): \(summary)")
    }

    private func describe(_ rows: [FixtureOccurrence]) -> String {
        rows.map { "\($0.title)|\($0.token)" }.joined(separator: ", ")
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func assertMismatchError(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let floe = error as? FloeError,
              case let .validationFailed(message) = floe else {
            XCTFail("unexpected error: \(error)", file: file, line: line)
            return
        }
        XCTAssertTrue(message.contains("different calendar events"),
                      message, file: file, line: line)
    }
}
#endif
