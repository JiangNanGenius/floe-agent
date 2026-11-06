// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeMeetings

final class PersistenceAndProtectionTests: XCTestCase {
    var dbURL: URL!

    override func tearDown() {
        if let dbURL { TestServices.cleanup(dbURL) }
    }

    func testReopenLosesNothing() async throws {
        let (service, url) = try TestServices.makeService()
        dbURL = url
        let meeting = try await service.createMeeting(title: "Quarterly")
        let session = try await TestServices.importedSession(service, meeting: meeting)

        let speaker = try await service.addSpeaker(meeting: meeting, label: "Speaker 1")
        let segment = try await service.appendFinal(
            meeting: meeting, session: session, text: "we decided to ship",
            range: MediaTimeRange(start: 0, end: 4), speaker: speaker.id
        )
        _ = try await service.correctSegment(segment.id, meeting: meeting, newText: "we decided to ship Friday")
        let note = try await service.addNote(
            meeting: meeting, body: "Check the roadmap",
            source: .segment(segment.id)
        )
        _ = try await service.addMarker(
            meeting: meeting, label: "关键决定",
            source: .recording(session: session, range: MediaTimeRange(start: 2, end: 4))
        )
        _ = try await service.addTodo(meeting: meeting, text: "  Send   recap  ", origin: .aiProposed)
        _ = try await service.recordDecision(
            meeting: meeting, text: "Ship Friday",
            source: .recording(session: session, range: MediaTimeRange(start: 1, end: 3))
        )
        _ = try await service.recordSummary(meeting: meeting, kind: .first, text: "First summary", window: MediaTimeRange(start: 0, end: 60))

        // Reopen from the same database file with a brand-new service.
        let database = try MeetingDatabase(path: url.path)
        let reopened = MeetingService(database: database)

        let reopenedTranscript = try await reopened.transcript(meeting: meeting)
        XCTAssertEqual(reopenedTranscript.first?.text, "we decided to ship Friday")
        XCTAssertEqual(reopenedTranscript.first?.originalText, "we decided to ship")
        let reopenedSpeakers = try await reopened.speakers(meeting: meeting)
        XCTAssertEqual(reopenedSpeakers.first?.label, "Speaker 1")
        let notes = try await reopened.notes(meeting: meeting)
        XCTAssertEqual(notes.first?.body, "Check the roadmap")
        guard case .segment(let noteSegment) = notes.first?.source else {
            XCTFail("note source link lost")
            return
        }
        XCTAssertEqual(noteSegment, segment.id)
        let markers = try await reopened.markers(meeting: meeting)
        XCTAssertEqual(markers.first?.label, "关键决定")
        let todos = try await reopened.todos(meeting: meeting)
        XCTAssertEqual(todos.first?.normalizedText, "send recap")
        let decisions = try await reopened.decisions(meeting: meeting)
        XCTAssertEqual(decisions.first?.text, "Ship Friday")
        let summaries = try await reopened.summaries(meeting: meeting)
        XCTAssertEqual(summaries.first?.text, "First summary")
        let reopenedMeeting = try await reopened.meeting(meeting)
        XCTAssertEqual(reopenedMeeting.title, "Quarterly")
    }

    func testNoteStaleRevisionEditFailsInsteadOfClobbering() async throws {
        let (service, url) = try TestServices.makeService()
        dbURL = url
        let meeting = try await service.createMeeting(title: "Notes")
        let note = try await service.addNote(meeting: meeting, body: "v1")

        let updated = try await service.updateNoteBody(note.id, meeting: meeting, body: "v2", expectedRevision: 0)
        XCTAssertEqual(updated.body, "v2")
        XCTAssertEqual(updated.revision, 1)

        do {
            _ = try await service.updateNoteBody(note.id, meeting: meeting, body: "clobber", expectedRevision: 0)
            XCTFail("expected staleRevision failure")
        } catch MeetingError.staleRevision(let expected, let actual) {
            XCTAssertEqual(expected, 0)
            XCTAssertEqual(actual, 1)
        }
        let notes = try await service.notes(meeting: meeting)
        XCTAssertEqual(notes.first?.body, "v2")
    }

    func testTodoDedupAndUserModificationProtection() async throws {
        let (service, url) = try TestServices.makeService()
        dbURL = url
        let meeting = try await service.createMeeting(title: "Todos")

        let first = try await service.addTodo(meeting: meeting, text: "Send the recap", origin: .aiProposed)
        let duplicate = try await service.addTodo(meeting: meeting, text: "  send  the RECAP ", origin: .aiProposed)
        XCTAssertEqual(first.id, duplicate.id)
        let todoCount = try await service.todos(meeting: meeting)
        XCTAssertEqual(todoCount.count, 1)

        // User edits → protected. A later proposal must not overwrite.
        _ = try await service.updateTodo(first.id, meeting: meeting, status: .done)
        let proposal = try await service.addTodo(
            meeting: meeting, text: "Send the recap",
            source: .none, origin: .aiProposed
        )
        XCTAssertEqual(proposal.id, first.id)
        XCTAssertEqual(proposal.status, .done, "user status must survive later proposals")
        XCTAssertEqual(proposal.userModified, true)

        // A brand-new todo is not protected.
        let other = try await service.addTodo(meeting: meeting, text: "Book a room", origin: .aiProposed)
        let refreshed = try await service.addTodo(meeting: meeting, text: "Book a room", origin: .aiProposed)
        XCTAssertEqual(other.id, refreshed.id)
        XCTAssertFalse(refreshed.userModified)
    }
}
