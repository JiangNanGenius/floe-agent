// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeMeetings

final class MeetingExportTests: XCTestCase {
    private func sampleSegments() throws -> [TranscriptSegment] {
        let meeting = MeetingID()
        let session = CaptureSessionID()
        return [
            TranscriptSegment(meetingID: meeting, sessionID: session, speakerID: nil, range: try MediaTimeRange(start: 0, end: 3.5), text: "Hello & <welcome>", ordinal: 0),
            TranscriptSegment(meetingID: meeting, sessionID: session, speakerID: nil, range: try MediaTimeRange(start: 4, end: 7.25), text: "line one\nline two", ordinal: 1),
        ]
    }

    func testSRTFormattingMatchesExistingCaptionRules() throws {
        let cues = try MeetingExport.cues(segments: sampleSegments())
        let data = try MeetingExport.captionData(cues: cues, format: .srt)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(
            text,
            "1\n00:00:00,000 --> 00:00:03,500\nHello &amp; &lt;welcome&gt;\n\n" +
            "2\n00:00:04,000 --> 00:00:07,250\nline one line two\n\n"
        )
        // Time references stay linked to their segment ids.
        XCTAssertEqual(cues.map(\.range.start), [0, 4])
        XCTAssertEqual(cues.first?.text, "Hello & <welcome>")
    }

    func testVTTFormattingMatchesExistingCaptionRules() throws {
        let cues = try MeetingExport.cues(segments: sampleSegments())
        let data = try MeetingExport.captionData(cues: cues, format: .vtt)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(text.contains("00:00:00.000 --> 00:00:03.500"))
        XCTAssertTrue(text.contains("00:00:04.000 --> 00:00:07.250"))
        XCTAssertFalse(text.contains("--> 00:00:03,500"), "VTT must use the dot separator")
    }

    func testHourLongTimestamps() throws {
        let meeting = MeetingID()
        let segment = TranscriptSegment(
            meetingID: meeting, sessionID: CaptureSessionID(), speakerID: nil,
            range: try MediaTimeRange(start: 3661.5, end: 3663), text: "late", ordinal: 0
        )
        let cues = try MeetingExport.cues(segments: [segment])
        let text = String(decoding: try MeetingExport.captionData(cues: cues, format: .srt), as: UTF8.self)
        XCTAssertTrue(text.contains("01:01:01,500 --> 01:01:03,000"))
    }

    func testDocumentExportResolvesMergedSpeakers() throws {
        let meeting = MeetingID()
        let session = CaptureSessionID()
        let old = Speaker(id: SpeakerID(), label: "Speaker 1")
        let target = Speaker(id: SpeakerID(), label: "Alice")
        let merged = Speaker(id: old.id, label: "Alice", userNamed: true, mergedInto: target.id)
        let segment = TranscriptSegment(meetingID: meeting, sessionID: session, speakerID: old.id, range: try MediaTimeRange(start: 5, end: 9), text: "ship it", ordinal: 0)
        let data = try MeetingExport.documentData(segments: [segment], speakers: [merged, target], title: "Sync", format: .markdown)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("# Sync\n"))
        XCTAssertTrue(text.contains("[00:00:05.000] Alice: ship it"))
    }

    func testCuesStayLinkedToSegments() throws {
        let segments = try sampleSegments()
        let cues = try MeetingExport.cues(segments: segments)
        XCTAssertEqual(cues.map(\.segmentID), segments.map(\.id))
        XCTAssertEqual(cues.map(\.range), segments.map(\.range))
    }
}
