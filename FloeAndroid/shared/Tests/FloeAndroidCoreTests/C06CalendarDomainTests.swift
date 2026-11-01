// SPDX-License-Identifier: MPL-2.0
//
// C06 calendar domain tests. Authored source; NOT RUN by this lane.
// The real domain runs over an injected provider port. No CalendarContract
// row, permission, Intent or device participates.

import Foundation
import XCTest
import FloeCore
@testable import FloeAndroidCore

private final class FakeCalendarPort: C06CalendarProviderPort, @unchecked Sendable {
    var snapshotValue = C06CalendarSnapshot(
        providerAvailable: true,
        readGranted: true,
        writeGranted: true,
        calendars: [
            C06CalendarSummary(
                id: 5,
                displayName: "Personal",
                accountName: "user@example.com",
                accountType: "com.google",
                ownerAccount: "user@example.com",
                timeZone: "Australia/Sydney",
                color: 1,
                accessLevel: 700,
                writable: true,
                visible: true,
                isPrimary: true
            ),
        ],
        revision: 1
    )
    var pageValue = C06CalendarHostPage(rows: [], hasMore: false, totalCount: 0)
    var eventValue: C06CalendarEvent?
    var createReceipt = C06CalendarReceipt(
        action: "create",
        eventID: 11,
        calendarID: 5,
        occurrenceStart: nil,
        deleted: false,
        readbackVerified: true,
        verificationScope: "targetOccurrence",
        verifiedFields: ["id", "calendarID", "title", "start", "end"]
    )
    var updateReceipt = C06CalendarReceipt(
        action: "update",
        eventID: 11,
        calendarID: 5,
        occurrenceStart: nil,
        deleted: false,
        readbackVerified: true,
        verificationScope: "targetOccurrence",
        verifiedFields: ["id", "calendarID", "title", "start", "end"]
    )
    var deleteReceipt = C06CalendarReceipt(
        action: "delete",
        eventID: 11,
        calendarID: 5,
        occurrenceStart: nil,
        deleted: true,
        readbackVerified: true,
        verificationScope: "targetOccurrence",
        verifiedFields: ["id", "deleted"]
    )
    var failure: C06CalendarError?
    var capturedUpdate: (occurrence: Date?, span: String, patch: C06CalendarEventPatch)?
    var capturedCreate: (calendarID: Int64, start: Date, end: Date, allDay: Bool, zone: String)?
    var capturedListOffset = -1

    func snapshot(owner: C06CalendarOwner) async throws -> C06CalendarSnapshot {
        if let failure { throw failure }
        return snapshotValue
    }

    func instances(
        owner: C06CalendarOwner,
        start: Date,
        end: Date,
        calendarID: Int64?,
        query: String?,
        limit: Int,
        offset: Int
    ) async throws -> C06CalendarHostPage {
        capturedListOffset = offset
        if let failure { throw failure }
        return pageValue
    }

    func event(id: Int64, owner: C06CalendarOwner) async throws -> C06CalendarEvent {
        if let failure { throw failure }
        guard let eventValue else {
            throw C06CalendarError(.eventNotFound, "eventNotFound")
        }
        return eventValue
    }

    func create(
        owner: C06CalendarOwner,
        calendarID: Int64,
        title: String,
        start: Date,
        end: Date,
        allDay: Bool,
        timeZone: String,
        notes: String?,
        location: String?,
        recurrence: String?
    ) async throws -> C06CalendarReceipt {
        capturedCreate = (calendarID, start, end, allDay, timeZone)
        if let failure { throw failure }
        return createReceipt
    }

    func update(
        owner: C06CalendarOwner,
        eventID: Int64,
        occurrenceStart: Date?,
        span: String,
        patch: C06CalendarEventPatch
    ) async throws -> C06CalendarReceipt {
        capturedUpdate = (occurrenceStart, span, patch)
        if let failure { throw failure }
        return updateReceipt
    }

    func delete(
        owner: C06CalendarOwner,
        eventID: Int64,
        occurrenceStart: Date?,
        span: String
    ) async throws -> C06CalendarReceipt {
        capturedUpdate = (occurrenceStart, span, C06CalendarEventPatch())
        if let failure { throw failure }
        return deleteReceipt
    }
}

final class C06CalendarDomainTests: XCTestCase {
    private var port: FakeCalendarPort!
    private var domain: C06CalendarDomain!

    override func setUp() {
        super.setUp()
        C06CalendarDomain.availability.reset()
        port = FakeCalendarPort()
        let fake = port!
        domain = C06CalendarDomain(
            provider: { _ in fake },
            readiness: { (true, 1) }
        )
    }

    override func tearDown() {
        C06CalendarDomain.availability.reset()
        super.tearDown()
    }

    private func owner() throws -> C06CalendarOwner {
        try C06CalendarOwner(token: "test.owner.token", nativeEpoch: 1,
                             taskID: UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
    }

    private func date(_ raw: String) throws -> Date {
        try C06CalendarDate.parseISO8601(raw)
    }

    func testOccurrenceTokenIsStrictAndBindsTheSeriesID() throws {
        let start = Date(timeIntervalSince1970: 1_730_000_000.75)
        let occurrence = C06CalendarOccurrence(eventID: 7, start: start)
        XCTAssertEqual(occurrence.token, "7@2024-10-27T03:33:20Z")
        XCTAssertEqual(C06CalendarOccurrence(token: occurrence.token), occurrence)
        XCTAssertNil(C06CalendarOccurrence(token: "7@2024-10-27T03:33:20.500Z"))
        XCTAssertNil(C06CalendarOccurrence(token: "7@2024-10-27T14:33:20+11:00"))
        XCTAssertNil(C06CalendarOccurrence(token: "0@2024-10-27T03:33:20Z"))
        XCTAssertThrowsError(
            try C06CalendarDomain.occurrenceForTool(token: "8@2024-10-27T03:33:20Z", eventID: 7)
        )
    }

    func testListMapsOccurrenceRowsAndPages() async throws {
        let start = try date("2026-11-02T00:00:00Z")
        let end = try date("2026-11-09T00:00:00Z")
        port.pageValue = C06CalendarHostPage(
            rows: [
                C06CalendarEvent(
                    eventID: 7,
                    calendarID: 5,
                    calendarName: "Personal",
                    title: "Focus",
                    start: start.addingTimeInterval(3600),
                    end: start.addingTimeInterval(7200),
                    allDay: false,
                    timeZone: "Australia/Sydney"
                ),
            ],
            hasMore: true,
            totalCount: 3
        )
        let result = try await domain.list(
            owner: owner(),
            start: start,
            end: end,
            calendarID: nil,
            query: nil,
            limit: 1,
            cursor: nil
        )
        XCTAssertEqual(result.returnedCount, 1)
        XCTAssertTrue(result.hasMore)
        XCTAssertNotNil(result.nextCursor)
        XCTAssertTrue(result.lines.first?.contains("occurrence=7@") == true)
        XCTAssertTrue(result.lines.first?.contains("calendar=Personal") == true)

        let cursor = try XCTUnwrap(result.nextCursor)
        _ = try await domain.list(
            owner: owner(),
            start: start,
            end: end,
            calendarID: nil,
            query: nil,
            limit: 1,
            cursor: cursor
        )
        XCTAssertEqual(port.capturedListOffset, 1)
    }

    func testCursorIsBoundToFiltersAndExpires() async throws {
        let start = try date("2026-11-02T00:00:00Z")
        let end = try date("2026-11-09T00:00:00Z")
        let filter = "start=\(C06CalendarDate.iso8601(start))"
            + " end=\(C06CalendarDate.iso8601(end)) calendar=all query="
        let expired = C06CalendarCursor.encode(
            offset: 1,
            filter: filter,
            issuedAt: Date(timeIntervalSinceNow: -601)
        )
        do {
            _ = try await domain.list(
                owner: owner(), start: start, end: end, calendarID: nil,
                query: nil, limit: 10, cursor: expired
            )
            XCTFail("expired cursor must fail")
        } catch let error as C06CalendarError {
            XCTAssertEqual(error.code, .cursorExpired)
        }
        let mismatched = C06CalendarCursor.encode(
            offset: 1,
            filter: filter + "different",
            issuedAt: Date()
        )
        do {
            _ = try await domain.list(
                owner: owner(), start: start, end: end, calendarID: nil,
                query: nil, limit: 10, cursor: mismatched
            )
            XCTFail("mismatched cursor must fail")
        } catch let error as C06CalendarError {
            XCTAssertEqual(error.code, .cursorMismatch)
        }
    }

    func testPermissionProviderAndAccountStatesAreDistinct() async throws {
        let start = try date("2026-11-02T00:00:00Z")
        let end = try date("2026-11-09T00:00:00Z")

        port.snapshotValue = C06CalendarSnapshot(
            providerAvailable: true, readGranted: false, writeGranted: false,
            calendars: [], revision: 2
        )
        await assertList(start, end, code: .permissionDenied)

        port.snapshotValue = C06CalendarSnapshot(
            providerAvailable: false, readGranted: false, writeGranted: false,
            calendars: [], revision: 3
        )
        await assertList(start, end, code: .providerAbsent)

        port.snapshotValue = C06CalendarSnapshot(
            providerAvailable: true, readGranted: true, writeGranted: true,
            calendars: [], revision: 4
        )
        await assertList(start, end, code: .noCalendars)
    }

    private func assertList(_ start: Date, _ end: Date,
                            code: C06CalendarErrorCode,
                            file: StaticString = #filePath,
                            line: UInt = #line) async {
        do {
            _ = try await domain.list(
                owner: try owner(), start: start, end: end,
                calendarID: nil, query: nil, limit: 10, cursor: nil
            )
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as C06CalendarError {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testCreateRequiresExplicitWritableCalendar() async throws {
        let start = try date("2026-11-02T09:00:00+11:00")
        let end = start.addingTimeInterval(3600)
        do {
            _ = try await domain.create(
                owner: owner(), calendarID: 0, title: "No calendar",
                start: start, end: end, allDay: false, timeZone: "Australia/Sydney",
                notes: nil, location: nil, recurrence: nil
            )
            XCTFail("calendarID 0 must be refused")
        } catch let error as C06CalendarError {
            XCTAssertEqual(error.code, .invalidRequest)
        }

        port.snapshotValue = C06CalendarSnapshot(
            providerAvailable: true, readGranted: true, writeGranted: true,
            calendars: [
                C06CalendarSummary(
                    id: 5, displayName: "Read only", accountName: "user@example.com",
                    accountType: "local", ownerAccount: "user@example.com",
                    timeZone: "UTC", color: 0, accessLevel: 200,
                    writable: false, visible: true, isPrimary: false
                ),
            ],
            revision: 5
        )
        do {
            _ = try await domain.create(
                owner: owner(), calendarID: 5, title: "No write",
                start: start, end: end, allDay: false, timeZone: "Australia/Sydney",
                notes: nil, location: nil, recurrence: nil
            )
            XCTFail("read-only calendar must be refused")
        } catch let error as C06CalendarError {
            XCTAssertEqual(error.code, .calendarNotWritable)
        }
    }

    func testCreateValidatesAllDayAndRecurrenceThenRequiresReadback() async throws {
        let start = try date("2026-11-02T09:00:00+11:00")
        let end = start.addingTimeInterval(3600)
        do {
            _ = try await domain.create(
                owner: owner(), calendarID: 5, title: "All day",
                start: start, end: end, allDay: true, timeZone: "UTC",
                notes: nil, location: nil, recurrence: nil
            )
            XCTFail("all-day start must be UTC midnight")
        } catch let error as C06CalendarError {
            XCTAssertEqual(error.code, .invalidAllDay)
        }

        do {
            _ = try await domain.create(
                owner: owner(), calendarID: 5, title: "Bad rule",
                start: start, end: end, allDay: false, timeZone: "Australia/Sydney",
                notes: nil, location: nil, recurrence: "FREQ=HOURLY"
            )
            XCTFail("unsupported recurrence must be refused")
        } catch let error as C06CalendarError {
            XCTAssertEqual(error.code, .invalidRecurrence)
        }

        port.createReceipt = C06CalendarReceipt(
            action: "create", eventID: 11, calendarID: 5, occurrenceStart: start,
            deleted: false, readbackVerified: false, verificationScope: "targetOccurrence",
            verifiedFields: ["id", "start"]
        )
        do {
            _ = try await domain.create(
                owner: owner(), calendarID: 5, title: "Focus",
                start: start, end: end, allDay: false, timeZone: "Australia/Sydney",
                notes: nil, location: nil, recurrence: "FREQ=DAILY"
            )
            XCTFail("unverified provider readback must fail")
        } catch let error as C06CalendarError {
            XCTAssertEqual(error.code, .readbackMismatch)
        }
        XCTAssertEqual(port.capturedCreate?.calendarID, 5)
    }

    func testUpdateBindsOccurrenceAndNeverWritesWithoutItForFutureSpan() async throws {
        let start = try date("2026-11-02T09:00:00+11:00")
        let token = C06CalendarOccurrence(eventID: 11, start: start).token
        let receipt = try await domain.update(
            owner: owner(), eventID: 11, occurrenceToken: token,
            spanRaw: "thisEvent", patch: C06CalendarEventPatch(title: "Moved")
        )
        XCTAssertEqual(receipt.eventID, 11)
        XCTAssertEqual(port.capturedUpdate?.occurrence, C06CalendarOccurrence(eventID: 11, start: start).start)
        XCTAssertEqual(port.capturedUpdate?.patch.title, "Moved")

        do {
            _ = try await domain.update(
                owner: owner(), eventID: 11, occurrenceToken: nil,
                spanRaw: "futureEvents", patch: C06CalendarEventPatch(title: "Moved")
            )
            XCTFail("futureEvents without occurrence must fail")
        } catch let error as C06CalendarError {
            XCTAssertEqual(error.code, .unsupportedSpan)
        }

        do {
            _ = try await domain.update(
                owner: owner(), eventID: 12, occurrenceToken: token,
                spanRaw: "thisEvent", patch: C06CalendarEventPatch(title: "Moved")
            )
            XCTFail("mismatched series id must fail")
        } catch let error as C06CalendarError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
    }

    func testDeleteRequiresVerifiedProviderReceipt() async throws {
        port.deleteReceipt = C06CalendarReceipt(
            action: "delete", eventID: 11, calendarID: 5, occurrenceStart: nil,
            deleted: true, readbackVerified: false, verificationScope: "targetOccurrence",
            verifiedFields: ["id", "deleted"]
        )
        do {
            _ = try await domain.delete(
                owner: owner(), eventID: 11, occurrenceToken: nil, spanRaw: "thisEvent"
            )
            XCTFail("unverified delete must fail")
        } catch let error as C06CalendarError {
            XCTAssertEqual(error.code, .readbackMismatch)
        }
        port.deleteReceipt = C06CalendarReceipt(
            action: "delete", eventID: 11, calendarID: 5, occurrenceStart: nil,
            deleted: true, readbackVerified: true, verificationScope: "targetOccurrence",
            verifiedFields: ["id", "deleted"]
        )
        let receipt = try await domain.delete(
            owner: owner(), eventID: 11, occurrenceToken: nil, spanRaw: "thisEvent"
        )
        XCTAssertTrue(receipt.deleted)
    }

    func testAvailabilityRequiresActualGrantAndWritableCalendar() async throws {
        await domain.applyHostAvailability(
            providerAvailable: true, readGranted: true, writeGranted: true,
            calendarCount: 1, writableCalendarCount: 1, revision: 10, epoch: 1
        )
        XCTAssertTrue(C06CalendarDomain.availability.snapshot.readAvailable)
        XCTAssertTrue(C06CalendarDomain.availability.snapshot.writeAvailable)

        await domain.applyHostAvailability(
            providerAvailable: true, readGranted: true, writeGranted: true,
            calendarCount: 1, writableCalendarCount: 0, revision: 11, epoch: 1
        )
        XCTAssertTrue(C06CalendarDomain.availability.snapshot.readAvailable)
        XCTAssertFalse(C06CalendarDomain.availability.snapshot.writeAvailable)

        // A stale projection never regresses live permission state.
        await domain.applyHostAvailability(
            providerAvailable: false, readGranted: false, writeGranted: false,
            calendarCount: 0, writableCalendarCount: 0, revision: 9, epoch: 1
        )
        XCTAssertTrue(C06CalendarDomain.availability.snapshot.readAvailable)
    }

    func testTemporaryOwnerIsRefused() {
        XCTAssertThrowsError(
            try C06CalendarOwner(token: "temporary.owner", nativeEpoch: 1,
                                 taskID: UUID(), temporary: true)
        )
    }
}
