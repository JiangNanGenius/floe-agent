// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeMeetings

final class TranscriptWorkflowTests: XCTestCase {
    var dbURL: URL!

    override func tearDown() {
        if let dbURL { TestServices.cleanup(dbURL) }
    }

    func testPartialCommitAndFinalOrdering() async throws {
        let (service, url) = try TestServices.makeService()
        dbURL = url
        let meeting = try await service.createMeeting(title: "Sync")
        let session = try await TestServices.importedSession(service, meeting: meeting)
        try await service.importFile(meeting: meeting, file: makeTempFile(), kind: .importedAudio) { _ in
            MediaTimeRange(uncheckedStart: 0, end: 120)
        }

        let p1 = try await service.beginPartial(meeting: meeting, session: session, text: "hel")
        await service.updatePartial(p1, meeting: meeting, text: "hello world")
        let p2 = try await service.beginPartial(meeting: meeting, session: session, text: "second")

        // Commit out of media-time order; reads must come back ordered.
        _ = try await service.commitPartial(p2, meeting: meeting, range: MediaTimeRange(start: 20, end: 24))
        _ = try await service.commitPartial(p1, meeting: meeting, range: MediaTimeRange(start: 0, end: 5))

        let final = try await service.appendFinal(
            meeting: meeting, session: session, text: "middle",
            range: MediaTimeRange(start: 10, end: 12)
        )

        let transcript = try await service.transcript(meeting: meeting)
        XCTAssertEqual(transcript.map(\.text), ["hello world", "middle", "second"])
        XCTAssertEqual(transcript.map(\.range.start), [0, 10, 20])
        XCTAssertEqual(final.ordinal, 2)
        let remainingPartials = await service.currentPartials(meeting: meeting)
        XCTAssertEqual(remainingPartials, [])
    }

    func testUserCorrectionKeepsOriginalAndSource() async throws {
        let (service, url) = try TestServices.makeService()
        dbURL = url
        let meeting = try await service.createMeeting(title: "Correction")
        let session = try await TestServices.importedSession(service, meeting: meeting)
        let segment = try await service.appendFinal(
            meeting: meeting, session: session, text: "ship on tuesday",
            range: MediaTimeRange(start: 3, end: 6)
        )
        let corrected = try await service.correctSegment(segment.id, meeting: meeting, newText: "ship on Thursday")
        XCTAssertEqual(corrected.text, "ship on Thursday")
        XCTAssertEqual(corrected.originalText, "ship on tuesday")
        XCTAssertEqual(corrected.correctedBy, .user)
        XCTAssertEqual(corrected.id, segment.id)
        // Source reference still points at the same recording span.
        guard case .recording(let sourceSession, let range) = corrected.source else {
            XCTFail("expected recording source")
            return
        }
        XCTAssertEqual(sourceSession, session)
        XCTAssertEqual(range.start, 3)
    }

    func testSpeakerRenameAndMergePreserveSegmentSource() async throws {
        let (service, url) = try TestServices.makeService()
        dbURL = url
        let meeting = try await service.createMeeting(title: "Speakers")
        let session = try await TestServices.importedSession(service, meeting: meeting)

        let engineSpeaker = try await service.addSpeaker(meeting: meeting, label: "Speaker 1")
        let segment = try await service.appendFinal(
            meeting: meeting, session: session, text: "I agree",
            range: MediaTimeRange(start: 1, end: 2), speaker: engineSpeaker.id
        )

        // User renames: id stays stable.
        try await service.renameSpeaker(engineSpeaker.id, meeting: meeting, to: "Alice", byUser: true)
        var speakers = try await service.speakers(meeting: meeting)
        XCTAssertEqual(speakers.first?.id, engineSpeaker.id)
        XCTAssertEqual(speakers.first?.label, "Alice")
        XCTAssertEqual(speakers.first?.userNamed, true)

        // Merge Alice into Bob; the segment must still reference Alice's id.
        let bob = try await service.addSpeaker(meeting: meeting, label: "Bob")
        try await service.mergeSpeaker(engineSpeaker.id, into: bob.id, meeting: meeting)
        let resolved = try await service.resolveSpeaker(engineSpeaker.id, meeting: meeting)
        XCTAssertEqual(resolved, bob.id)

        let transcript = try await service.transcript(meeting: meeting)
        XCTAssertEqual(transcript.first?.speakerID, engineSpeaker.id, "segment source must not be rewritten by merge")
        XCTAssertEqual(transcript.first?.text, "I agree")

        speakers = try await service.speakers(meeting: meeting)
        XCTAssertEqual(speakers.first { $0.id == engineSpeaker.id }?.mergedInto, bob.id)
    }

    func testRenameDoesNotAffectOtherSpeakers() async throws {
        let (service, url) = try TestServices.makeService()
        dbURL = url
        let meeting = try await service.createMeeting(title: "Rename isolation")
        let a = try await service.addSpeaker(meeting: meeting, label: "S1")
        let b = try await service.addSpeaker(meeting: meeting, label: "S2")
        try await service.renameSpeaker(a.id, meeting: meeting, to: "Carol", byUser: true)
        let speakers = try await service.speakers(meeting: meeting)
        XCTAssertEqual(speakers.first { $0.id == b.id }?.label, "S2")
        XCTAssertEqual(speakers.first { $0.id == a.id }?.label, "Carol")
    }

    private func makeTempFile() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("import-\(UUID().uuidString).wav")
        try? Data().write(to: url)
        return url
    }
}
