// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeMeetings

final class SummaryInputTests: XCTestCase {
    var dbURL: URL!

    override func tearDown() {
        if let dbURL { TestServices.cleanup(dbURL) }
    }

    func testRollingWindowKeepsEarlierDecisions() async throws {
        let (service, url) = try TestServices.makeService()
        dbURL = url
        let meeting = try await service.createMeeting(title: "Planning")
        let session = try await TestServices.importedSession(service, meeting: meeting)

        // Old content at t=60, decision attached at t=60.
        _ = try await service.appendFinal(
            meeting: meeting, session: session, text: "early discussion",
            range: MediaTimeRange(start: 30, end: 60)
        )
        _ = try await service.recordDecision(
            meeting: meeting, text: "Budget approved",
            source: .recording(session: session, range: MediaTimeRange(start: 55, end: 58))
        )

        // Recent content inside the last-5-minutes window ending at t=600.
        _ = try await service.appendFinal(
            meeting: meeting, session: session, text: "recent discussion",
            range: MediaTimeRange(start: 340, end: 380)
        )
        _ = try await service.appendFinal(
            meeting: meeting, session: session, text: "boundary segment",
            range: MediaTimeRange(start: 299, end: 320)
        )
        _ = try await service.recordDecision(
            meeting: meeting, text: "Launch in May",
            source: .recording(session: session, range: MediaTimeRange(start: 560, end: 570))
        )

        let input = try await service.summaryInput(meeting: meeting, session: session, at: 600, window: 300)

        // Window segments only (>= 300), boundary overlap included, ordered.
        XCTAssertEqual(input.window, MediaTimeRange(uncheckedStart: 300, end: 600))
        XCTAssertEqual(input.segments.map(\.text), ["boundary segment", "recent discussion"])

        // Cumulative decisions include the pre-window one — the rolling
        // window must never lose earlier conclusions.
        XCTAssertEqual(input.cumulativeDecisions.map(\.text), ["Budget approved", "Launch in May"])

        // Fresh decisions are those anchored inside the window.
        XCTAssertEqual(input.freshDecisions.map(\.text), ["Launch in May"])
    }

    func testFirstSummaryEarlyMeetingUsesFullAvailableWindow() async throws {
        let (service, url) = try TestServices.makeService()
        dbURL = url
        let meeting = try await service.createMeeting(title: "Kickoff")
        let session = try await TestServices.importedSession(service, meeting: meeting)
        _ = try await service.appendFinal(
            meeting: meeting, session: session, text: "hello",
            range: MediaTimeRange(start: 0, end: 2)
        )
        // "Recent 5 minutes" clamps to 0 when the meeting just started.
        let input = try await service.summaryInput(meeting: meeting, session: session, at: 120, window: 300)
        XCTAssertEqual(input.window, MediaTimeRange(uncheckedStart: 0, end: 120))
        XCTAssertEqual(input.segments.map(\.text), ["hello"])
        XCTAssertTrue(input.cumulativeDecisions.isEmpty)
    }
}
