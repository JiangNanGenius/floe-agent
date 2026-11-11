// SPDX-License-Identifier: MPL-2.0
import XCTest
import GRDB
@testable import FloeMeetings

/// W7 speaker-attribution core: engine labels map to stable anonymous
/// speakers per REAL recognition request (never across requests), renames and
/// merges persist and win over later recognition, user corrections survive
/// the canonical post-record pass, and engines that return no label never
/// fabricate a speaker.
final class SpeakerAttributionTests: XCTestCase {
    var dbURL: URL!

    override func tearDown() {
        if let dbURL { TestServices.cleanup(dbURL) }
    }

    private func makeMeeting() async throws -> (MeetingService, MeetingID, URL) {
        let (service, url) = try TestServices.makeService()
        dbURL = url
        let meeting = try await service.createMeeting(title: "Speakers")
        return (service, meeting, url)
    }

    func testEngineLabelMapsStableWithinOneRequestAndDiffersAcrossRequests() async throws {
        let (service, meeting, _) = try await makeMeeting()
        let firstRequest = UUID().uuidString
        let secondRequest = UUID().uuidString

        let a = try await service.resolveEngineSpeaker(meeting: meeting, scope: firstRequest, label: "1")
        let b = try await service.resolveEngineSpeaker(meeting: meeting, scope: firstRequest, label: "2")
        let aAgain = try await service.resolveEngineSpeaker(meeting: meeting, scope: firstRequest, label: "1")
        // The same recording's second, independent request says "1" again:
        // providers restart numbering per request, so this is a DIFFERENT
        // person until the user merges.
        let otherRequestSameNumber = try await service.resolveEngineSpeaker(meeting: meeting, scope: secondRequest, label: "1")

        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(a, aAgain, "same label in the same request must reuse the same speaker")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, otherRequestSameNumber,
                          "independent requests must never merge on a bare number")
        let speakers = try await service.speakers(meeting: meeting)
        XCTAssertEqual(speakers.count, 3)
        XCTAssertEqual(speakers.filter { !$0.userNamed }.count, 3)
    }

    func testConcurrentResolutionsDoNotDuplicateSpeakers() async throws {
        let (service, meeting, _) = try await makeMeeting()
        let scope = UUID().uuidString
        let ids = try await withThrowingTaskGroup(of: SpeakerID?.self) { group in
            for _ in 0..<8 {
                group.addTask { try await service.resolveEngineSpeaker(meeting: meeting, scope: scope, label: "1") }
            }
            var collected: [SpeakerID?] = []
            for try await id in group { collected.append(id) }
            return collected
        }
        let unique = Set(ids.compactMap { $0 })
        let speakerCount = try await service.speakers(meeting: meeting).count
        XCTAssertEqual(unique.count, 1, "get-or-create is one transaction; concurrency cannot duplicate a speaker")
        XCTAssertEqual(speakerCount, 1)
    }

    func testNilOrEmptyLabelNeverFabricatesSpeaker() async throws {
        let (service, meeting, _) = try await makeMeeting()
        let scope = UUID().uuidString
        let nilResult = try await service.resolveEngineSpeaker(meeting: meeting, scope: scope, label: nil)
        let blankResult = try await service.resolveEngineSpeaker(meeting: meeting, scope: scope, label: "   ")
        XCTAssertNil(nilResult)
        XCTAssertNil(blankResult)
        let session = try await TestServices.importedSession(service, meeting: meeting)
        let segment = try await service.appendFinal(
            meeting: meeting, session: session, text: "hello",
            range: MediaTimeRange(start: 0, end: 1), speaker: nil)
        XCTAssertNil(segment.speakerID)
        let speakersAfterEmpty = try await service.speakers(meeting: meeting)
        XCTAssertTrue(speakersAfterEmpty.isEmpty)
    }

    func testRenameAndMergePersistAcrossReopenAndSurviveLaterRecognition() async throws {
        let (service, meeting, url) = try await makeMeeting()
        let request = UUID().uuidString
        let __resolved1 = try await service.resolveEngineSpeaker(meeting: meeting, scope: request, label: "1")
        let one = try XCTUnwrap(__resolved1)
        let __resolved2 = try await service.resolveEngineSpeaker(meeting: meeting, scope: request, label: "2")
        let two = try XCTUnwrap(__resolved2)
        try await service.renameSpeaker(one, meeting: meeting, to: "Alice", byUser: true)
        try await service.mergeSpeaker(two, into: one, meeting: meeting)

        // Later recognition in the SAME request still says "2": the binding
        // was re-pointed at the merge target, so the merge survives.
        let late = try await service.resolveEngineSpeaker(meeting: meeting, scope: request, label: "2")
        let resolvedTwo = try await service.resolveSpeaker(two, meeting: meeting)
        XCTAssertEqual(late, resolvedTwo)
        XCTAssertEqual(late, one, "post-merge recognition must commit into the merged identity")

        // Reopen from the same database: names, merge and bindings durable.
        let reopened = MeetingService(database: try MeetingDatabase(path: url.path))
        let speakers = try await reopened.speakers(meeting: meeting)
        let alice = try XCTUnwrap(speakers.first { $0.id == one })
        XCTAssertEqual(alice.label, "Alice")
        XCTAssertTrue(alice.userNamed)
        let merged = try XCTUnwrap(speakers.first { $0.id == two })
        XCTAssertEqual(merged.mergedInto, one)
        let rebound = try await reopened.resolveEngineSpeaker(meeting: meeting, scope: request, label: "2")
        XCTAssertEqual(rebound, one)
    }

    func testUserReassignmentPersistsAndSurvivesRetranscription() async throws {
        let (service, meeting, url) = try await makeMeeting()
        let request = UUID().uuidString
        let session = try await TestServices.importedSession(service, meeting: meeting)
        let __resolved3 = try await service.resolveEngineSpeaker(meeting: meeting, scope: request, label: "1")
        let one = try XCTUnwrap(__resolved3)
        let __resolved4 = try await service.resolveEngineSpeaker(meeting: meeting, scope: request, label: "2")
        let two = try XCTUnwrap(__resolved4)

        let segment = try await service.appendFinal(
            meeting: meeting, session: session, text: "engine said speaker one",
            range: MediaTimeRange(start: 0, end: 2), speaker: one)
        let corrected = try await service.reassignSegmentSpeaker(segment.id, meeting: meeting, speaker: two)
        XCTAssertEqual(corrected.speakerID, two)
        XCTAssertTrue(corrected.speakerCorrected)

        // The canonical post-record pass for this original must preserve the
        // user's speaker choice even where the engine now disagrees; the
        // engine-provisional TEXT may still be upgraded by the canonical pass.
        let canonical = try await service.reconcileCanonicalTranscription(
            meeting: meeting,
            analysisSessions: [session],
            target: session,
            inputs: [CanonicalTranscriptInput(startSeconds: 0, endSeconds: 2,
                                              text: "engine revised text", speakerID: one)])
        XCTAssertEqual(canonical.adopted, 1)
        XCTAssertEqual(canonical.preserved, 0)

        // Full reopen: the speaker correction persists; the text is the
        // canonical upgrade (the user never corrected text).
        let reopened = MeetingService(database: try MeetingDatabase(path: url.path))
        let persisted = try await reopened.transcript(meeting: meeting)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.speakerID, two)
        XCTAssertEqual(persisted.first?.text, "engine revised text")

        // Clearing the attribution is also a user correction and persists.
        let cleared = try await reopened.reassignSegmentSpeaker(segment.id, meeting: meeting, speaker: nil)
        XCTAssertNil(cleared.speakerID)
        XCTAssertTrue(cleared.speakerCorrected)
    }

    func testCanonicalReconciliationAdoptsEngineRowsAndKeepsUserText() async throws {
        let (service, meeting, _) = try await makeMeeting()
        let request = UUID().uuidString
        let session = try await TestServices.importedSession(service, meeting: meeting)
        let __resolved5 = try await service.resolveEngineSpeaker(meeting: meeting, scope: request, label: "1")
        let one = try XCTUnwrap(__resolved5)
        let __resolved6 = try await service.resolveEngineSpeaker(meeting: meeting, scope: request, label: "2")
        let two = try XCTUnwrap(__resolved6)

        let engineRow = try await service.appendFinal(
            meeting: meeting, session: session, text: "provisional words",
            range: MediaTimeRange(start: 0, end: 2), speaker: one)
        let userRow = try await service.appendFinal(
            meeting: meeting, session: session, text: "user fixed this",
            range: MediaTimeRange(start: 2, end: 4), speaker: one)
        _ = try await service.correctSegment(userRow.id, meeting: meeting, newText: "user fixed this")

        let outcome = try await service.reconcileCanonicalTranscription(
            meeting: meeting,
            analysisSessions: [session],
            target: session,
            inputs: [
                .init(startSeconds: 0, endSeconds: 2, text: "canonical words", speakerID: two),
                .init(startSeconds: 2, endSeconds: 4, text: "canonical disagree", speakerID: two),
                .init(startSeconds: 4, endSeconds: 6, text: "brand new canonical", speakerID: two),
            ])
        XCTAssertEqual(outcome.adopted, 2, "engine rows adopt canonical text/speaker; the user-text row still adopts the speaker")
        XCTAssertEqual(outcome.preserved, 0)
        XCTAssertEqual(outcome.appended, 1)

        let segments = try await service.transcript(meeting: meeting)
        let adopted = try XCTUnwrap(segments.first { $0.id == engineRow.id })
        XCTAssertEqual(adopted.text, "canonical words")
        XCTAssertEqual(adopted.speakerID, two, "canonical speaker replaces engine attribution on engine rows")
        let kept = try XCTUnwrap(segments.first { $0.id == userRow.id })
        XCTAssertEqual(kept.text, "user fixed this")
        XCTAssertEqual(kept.speakerID, two, "speaker adoption still applies when only text is user-protected")
        XCTAssertEqual(segments.count, 3)
    }

    func testReconcileAcrossChunkSessionsOfOneOriginal() async throws {
        let (service, meeting, _) = try await makeMeeting()
        let chunkA = try await TestServices.importedSession(service, meeting: meeting)
        let chunkB = try await TestServices.importedSession(service, meeting: meeting)
        let canonical = try await TestServices.importedSession(service, meeting: meeting)
        // Two independent chunk requests both said "1" → two speakers, even
        // though the numbers match.
        let reqA = UUID().uuidString, reqB = UUID().uuidString
        let __resolved7 = try await service.resolveEngineSpeaker(meeting: meeting, scope: reqA, label: "1")
        let speakerA = try XCTUnwrap(__resolved7)
        let __resolved8 = try await service.resolveEngineSpeaker(meeting: meeting, scope: reqB, label: "1")
        let speakerB = try XCTUnwrap(__resolved8)
        XCTAssertNotEqual(speakerA, speakerB)
        _ = try await service.appendFinal(meeting: meeting, session: chunkA, text: "chunk one text",
                                          range: MediaTimeRange(start: 0, end: 2), speaker: speakerA)
        _ = try await service.appendFinal(meeting: meeting, session: chunkB, text: "chunk two text",
                                          range: MediaTimeRange(start: 2, end: 4), speaker: speakerB)
        // The whole-file run reconciles BOTH chunk sessions: no duplicate
        // transcript text is appended where time correspondence exists.
        let __resolved9 = try await service.resolveEngineSpeaker(meeting: meeting, scope: canonical.description, label: "1")
        let whole = try XCTUnwrap(__resolved9)
        let outcome = try await service.reconcileCanonicalTranscription(
            meeting: meeting,
            analysisSessions: [chunkA, chunkB, canonical],
            target: canonical,
            inputs: [
                .init(startSeconds: 0, endSeconds: 2, text: "chunk one text", speakerID: whole),
                .init(startSeconds: 2, endSeconds: 4, text: "chunk two text", speakerID: whole),
            ])
        XCTAssertEqual(outcome.adopted, 2)
        XCTAssertEqual(outcome.appended, 0)
        let segments = try await service.transcript(meeting: meeting)
        XCTAssertEqual(segments.count, 2, "canonical pass upgrades in place; transcript stays single-copy")
        XCTAssertTrue(segments.allSatisfy { $0.speakerID == whole })
    }

    func testExportOmitsLabelForUnattributedSegmentsAndUsesCorrectedNames() async throws {
        let (service, meeting, _) = try await makeMeeting()
        let request = UUID().uuidString
        let session = try await TestServices.importedSession(service, meeting: meeting)
        let __resolved10 = try await service.resolveEngineSpeaker(meeting: meeting, scope: request, label: "1")
        let one = try XCTUnwrap(__resolved10)
        try await service.renameSpeaker(one, meeting: meeting, to: "Alice", byUser: true)
        _ = try await service.appendFinal(
            meeting: meeting, session: session, text: "attributed words",
            range: MediaTimeRange(start: 0, end: 1), speaker: one)
        _ = try await service.appendFinal(
            meeting: meeting, session: session, text: "unattributed words",
            range: MediaTimeRange(start: 1, end: 2), speaker: nil)
        let segments = try await service.transcript(meeting: meeting)
        let speakers = try await service.speakers(meeting: meeting)
        let data = try MeetingExport.documentData(segments: segments, speakers: speakers, title: "T", format: .txt)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("Alice: attributed words"))
        XCTAssertTrue(text.contains("unattributed words"))
        XCTAssertFalse(text.contains("Unknown speaker"), "missing metadata stays honest, never a fabricated identity")
        XCTAssertFalse(text.contains("未知发言人"))
    }

    func testMergedSegmentExportResolvesThroughMergeToUserName() async throws {
        let (service, meeting, _) = try await makeMeeting()
        let request = UUID().uuidString
        let session = try await TestServices.importedSession(service, meeting: meeting)
        let __resolved11 = try await service.resolveEngineSpeaker(meeting: meeting, scope: request, label: "1")
        let one = try XCTUnwrap(__resolved11)
        let __resolved12 = try await service.resolveEngineSpeaker(meeting: meeting, scope: request, label: "2")
        let two = try XCTUnwrap(__resolved12)
        _ = try await service.appendFinal(
            meeting: meeting, session: session, text: "from two",
            range: MediaTimeRange(start: 0, end: 1), speaker: two)
        try await service.renameSpeaker(one, meeting: meeting, to: "Alice", byUser: true)
        try await service.mergeSpeaker(two, into: one, meeting: meeting)
        let segments = try await service.transcript(meeting: meeting)
        let speakers = try await service.speakers(meeting: meeting)
        let data = try MeetingExport.documentData(segments: segments, speakers: speakers, title: "T", format: .markdown)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("Alice: from two"))
    }
    func testCanonicalSplitUsesOneVisibleCopyAndDistinctSpeakers() async throws {
        let (service, meeting, _) = try await makeMeeting()
        let session = try await TestServices.importedSession(service, meeting: meeting)
        let old = try await service.appendFinal(meeting: meeting, session: session,
            text: "old combined sentence", range: MediaTimeRange(start: 0, end: 4), speaker: nil)
        let one = try await service.resolveEngineSpeaker(meeting: meeting, scope: "whole-request", label: "1")
        let two = try await service.resolveEngineSpeaker(meeting: meeting, scope: "whole-request", label: "2")
        let inputs: [CanonicalTranscriptInput] = [
            .init(startSeconds: 0, endSeconds: 2, text: "first", speakerID: one),
            .init(startSeconds: 2, endSeconds: 4, text: "second", speakerID: two)]
        _ = try await service.reconcileCanonicalTranscription(meeting: meeting,
            analysisSessions: [session], target: session, inputs: inputs)
        let rows = try await service.transcript(meeting: meeting)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.text), ["first", "second"])
        XCTAssertEqual(rows.map(\.speakerID), [one, two])
        XCTAssertEqual(rows.map(\.range), [try MediaTimeRange(start: 0, end: 2), try MediaTimeRange(start: 2, end: 4)])
        XCTAssertEqual(rows.filter { $0.id == old.id }.count, 1)
        _ = try await service.reconcileCanonicalTranscription(meeting: meeting,
            analysisSessions: [session], target: session, inputs: inputs)
        let repeated = try await service.transcript(meeting: meeting)
        XCTAssertEqual(repeated, rows, "repeating the canonical result must be idempotent")
    }

    func testCanonicalMergeRetainsHistoryReferencesWithoutDuplicateExport() async throws {
        let (service, meeting, url) = try await makeMeeting()
        let session = try await TestServices.importedSession(service, meeting: meeting)
        let first = try await service.appendFinal(meeting: meeting, session: session,
            text: "first old", range: MediaTimeRange(start: 0, end: 2), speaker: nil)
        let second = try await service.appendFinal(meeting: meeting, session: session,
            text: "second old", range: MediaTimeRange(start: 2, end: 4), speaker: nil)
        let note = try await service.addNote(meeting: meeting, body: "keep this source", source: .segment(first.id))
        _ = try await service.reconcileCanonicalTranscription(meeting: meeting,
            analysisSessions: [session], target: session,
            inputs: [.init(startSeconds: 0, endSeconds: 4, text: "canonical combined")])
        let reopened = MeetingService(database: try MeetingDatabase(path: url.path))
        let rows = try await reopened.transcript(meeting: meeting)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.text, "canonical combined")
        XCTAssertEqual(rows.first?.range, try MediaTimeRange(start: 0, end: 4))
        let notes = try await reopened.notes(meeting: meeting)
        XCTAssertEqual(notes.first { $0.id == note.id }?.source, .segment(first.id))
        let historical = rows[0].id == first.id ? second.id : first.id
        let sources = try await reopened.sourceSegments(meeting: meeting, ids: [historical])
        let retained = try XCTUnwrap(sources.first)
        XCTAssertEqual(retained.id, historical, "superseded IDs remain addressable and their original data is retained")
        XCTAssertTrue(["first old", "second old"].contains(retained.text))
        do {
            _ = try await reopened.correctSegment(historical, meeting: meeting, newText: "history annotation")
            XCTFail("stale mutation must not silently edit invisible history")
        } catch MeetingError.segmentNotFound(let id) { XCTAssertEqual(id, historical) }
        let visible = try await reopened.transcript(meeting: meeting)
        XCTAssertEqual(visible.count, 1, "history edits must not resurrect another visible transcript")
        let exported = try MeetingExport.documentData(segments: visible, speakers: [], title: "Meeting", format: .txt)
        let text = String(decoding: exported, as: UTF8.self)
        XCTAssertTrue(text.contains("canonical combined"))
        XCTAssertFalse(text.contains("second old"))
        XCTAssertFalse(text.contains("history annotation"))
    }

    func testCanonicalResegmentationPreservesManualTextAndSpeakerWithoutAppendingOverIt() async throws {
        let (service, meeting, _) = try await makeMeeting()
        let session = try await TestServices.importedSession(service, meeting: meeting)
        let one = try await service.resolveEngineSpeaker(meeting: meeting, scope: "live", label: "1")
        let two = try await service.resolveEngineSpeaker(meeting: meeting, scope: "whole", label: "1")
        let first = try await service.appendFinal(meeting: meeting, session: session,
            text: "first old", range: MediaTimeRange(start: 0, end: 2), speaker: one)
        let second = try await service.appendFinal(meeting: meeting, session: session,
            text: "second old", range: MediaTimeRange(start: 2, end: 4), speaker: one)
        _ = try await service.correctSegment(first.id, meeting: meeting, newText: "my exact words")
        _ = try await service.reassignSegmentSpeaker(first.id, meeting: meeting, speaker: nil)
        _ = try await service.reconcileCanonicalTranscription(meeting: meeting,
            analysisSessions: [session], target: session,
            inputs: [.init(startSeconds: 0, endSeconds: 4, text: "a merged sentence", speakerID: two)])
        let rows = try await service.transcript(meeting: meeting)
        XCTAssertEqual(rows.count, 2, "a merged observation must not duplicate protected words")
        let protected = try XCTUnwrap(rows.first { $0.id == first.id })
        XCTAssertEqual(protected.text, "my exact words")
        XCTAssertNil(protected.speakerID)
        XCTAssertTrue(protected.speakerCorrected)
        XCTAssertEqual(rows.first { $0.id == second.id }?.text, "second old", "ambiguous merged text cannot be copied onto each old row")
        XCTAssertEqual(rows.first { $0.id == second.id }?.speakerID, two)
    }

    func testCanonicalInputValidationIsAtomicAndDoesNotDiscardDisjointAudio() async throws {
        let (service, meeting, _) = try await makeMeeting()
        let session = try await TestServices.importedSession(service, meeting: meeting)
        _ = try await service.appendFinal(meeting: meeting, session: session,
            text: "late words", range: MediaTimeRange(start: 10, end: 12), speaker: nil)
        do {
            _ = try await service.reconcileCanonicalTranscription(meeting: meeting,
                analysisSessions: [session], target: session, inputs: [
                    .init(startSeconds: 0, endSeconds: 1, text: "must roll back"),
                    .init(startSeconds: .nan, endSeconds: 2, text: "invalid")])
            XCTFail("invalid provider time must fail without crashing or partially committing")
        } catch {}
        let unchanged = try await service.transcript(meeting: meeting)
        XCTAssertEqual(unchanged.map(\.text), ["late words"])
        _ = try await service.reconcileCanonicalTranscription(meeting: meeting,
            analysisSessions: [session], target: session,
            inputs: [.init(startSeconds: 0, endSeconds: 1, text: "early words")])
        let preserved = try await service.transcript(meeting: meeting)
        XCTAssertEqual(Set(preserved.map(\.text)), ["late words", "early words"])
    }

    func testCanonicalSplitAcrossChunksStaysInOriginalMediaOrder() async throws {
        let (service, meeting, _) = try await makeMeeting()
        let chunkA = try await TestServices.importedSession(service, meeting: meeting)
        let chunkB = try await TestServices.importedSession(service, meeting: meeting)
        let full = try await TestServices.importedSession(service, meeting: meeting)
        let first = try await service.appendFinal(meeting: meeting, session: chunkA,
            text: "old combined", range: MediaTimeRange(start: 0, end: 4), speaker: nil)
        let last = try await service.appendFinal(meeting: meeting, session: chunkB,
            text: "last", range: MediaTimeRange(start: 4, end: 6), speaker: nil)
        _ = try await service.reconcileCanonicalTranscription(meeting: meeting,
            analysisSessions: [chunkA, chunkB, full], target: full, inputs: [
                .init(startSeconds: 0, endSeconds: 2, text: "first"),
                .init(startSeconds: 2, endSeconds: 4, text: "middle"),
                .init(startSeconds: 4, endSeconds: 6, text: "last")])
        let rows = try await service.transcript(meeting: meeting)
        XCTAssertEqual(rows.map(\.text), ["first", "middle", "last"])
        XCTAssertEqual(Set(rows.map(\.sessionID)), [full], "canonical rows must seek the whole original, including newly split parts")
        XCTAssertTrue(rows.contains { $0.id == first.id })
        XCTAssertTrue(rows.contains { $0.id == last.id })
        XCTAssertEqual(rows.map(\.source), rows.map { .recording(session: full, range: $0.range) })
    }

    func testLegacyTranscriptJSONDefaultsSpeakerCorrectionToFalse() throws {
        let segment = TranscriptSegment(meetingID: MeetingID(), sessionID: CaptureSessionID(),
            speakerID: nil, range: try MediaTimeRange(start: 0, end: 1), text: "old", ordinal: 0)
        let data = try JSONEncoder().encode(segment)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "speakerCorrected")
        let decoded = try JSONDecoder().decode(TranscriptSegment.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.id, segment.id)
        XCTAssertEqual(decoded.text, "old")
        XCTAssertEqual(decoded.source, segment.source)
        XCTAssertFalse(decoded.speakerCorrected)
    }

    func testV2DatabaseMigrationKeepsExistingVisibleTranscriptAndReferences() async throws {
        let (service, meeting, url) = try await makeMeeting()
        let session = try await TestServices.importedSession(service, meeting: meeting)
        let segment = try await service.appendFinal(meeting: meeting, session: session,
            text: "existing words", range: MediaTimeRange(start: 0, end: 2), speaker: nil)
        _ = try await service.addNote(meeting: meeting, body: "existing source", source: .segment(segment.id))
        let fixture = try MeetingDatabase(path: url.path)
        // Materialize the released v2 schema around real stored rows, then
        // let the production migrator reopen it. No new flags exist in v2.
        try await fixture.pool.write { db in
            try db.execute(sql: "ALTER TABLE transcript_segments DROP COLUMN superseded")
            try db.execute(sql: "ALTER TABLE transcript_segments DROP COLUMN speakerCorrected")
            try db.execute(sql: "DROP TABLE speaker_bindings")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('v3-speaker-bindings', 'v4-segment-speaker-correction', 'v5-canonical-transcript-history')")
        }
        let reopened = MeetingService(database: try MeetingDatabase(path: url.path))
        let rows = try await reopened.transcript(meeting: meeting)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, segment.id)
        XCTAssertEqual(rows[0].text, "existing words")
        XCTAssertFalse(rows[0].speakerCorrected)
        let notes = try await reopened.notes(meeting: meeting)
        XCTAssertEqual(notes.first?.source, .segment(segment.id))
    }

    func testCanonicalOverlappingComponentKeepsManualWordsAndSingleCopy() async throws {
        let (service, meeting, _) = try await makeMeeting()
        let session = try await TestServices.importedSession(service, meeting: meeting)
        var original: [TranscriptSegment] = []
        var canonical: [CanonicalTranscriptInput] = []
        for index in 0..<120 {
            let start = Double(index) * 0.2
            original.append(try await service.appendFinal(meeting: meeting, session: session,
                text: "old \(index)", range: MediaTimeRange(start: start, end: start + 0.2), speaker: nil))
            canonical.append(.init(startSeconds: start + 0.01, endSeconds: start + 0.21, text: "new \(index)"))
        }
        _ = try await service.correctSegment(original[0].id, meeting: meeting, newText: "my exact words")
        _ = try await service.reconcileCanonicalTranscription(meeting: meeting,
            analysisSessions: [session], target: session, inputs: canonical)
        let rows = try await service.transcript(meeting: meeting)
        XCTAssertEqual(rows.count, 120, "an overlapping component must not produce another transcript")
        XCTAssertEqual(Set(rows.map(\.id)), Set(original.map(\.id)))
        XCTAssertEqual(rows.first?.text, "my exact words")
    }

}

extension SpeakerAttributionTests {
    func testNativeCentroidsMatchOnlyWithinRecordingAndKeepUnknowns() throws {
        let meeting = MeetingID(), original = CaptureSessionID()
        var first = RecordingSpeakerIdentity(meeting: meeting, original: original)
        var a = [Float](repeating: 0, count: 16), b = a
        a[0] = 1; b[1] = 1
        let initial = first.resolve(centroids: [0: a, 1: b], speechSeconds: [0: 4, 1: 4])
        XCTAssertEqual(initial.count, 2)
        XCTAssertNotEqual(initial[0], initial[1])
        // Native cluster indices can change in the next real analysis window.
        let next = first.resolve(centroids: [5: b, 9: a], speechSeconds: [5: 3, 9: 3])
        XCTAssertEqual(next[5], initial[1]); XCTAssertEqual(next[9], initial[0])
        var gray = a; gray[0] = 0.7; gray[1] = 0.7
        XCTAssertTrue(first.resolve(centroids: [2: gray, 3: []], speechSeconds: [2: 3, 3: 3]).isEmpty,
                      "ambiguous, absent or invalid acoustic evidence is unknown")
        XCTAssertTrue(first.resolve(centroids: [0: a], speechSeconds: [0: 0.1]).isEmpty)
        var reopened = try JSONDecoder().decode(RecordingSpeakerIdentity.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(reopened.resolve(centroids: [7: a], speechSeconds: [7: 2])[7], initial[0])
        var otherRecording = RecordingSpeakerIdentity(meeting: meeting, original: CaptureSessionID())
        XCTAssertNotEqual(otherRecording.resolve(centroids: [0: a], speechSeconds: [0: 4])[0], initial[0],
                          "voice identity is never reused across originals, even in the same meeting")
    }

    func testNativeAttributionPersistsAndProtectsOriginalLineageAndUserChoices() async throws {
        let (service, meeting, url) = try await makeMeeting()
        let original = try await TestServices.importedSession(service, meeting: meeting)
        let otherOriginal = try await TestServices.importedSession(service, meeting: meeting)
        let file = url.deletingLastPathComponent().appendingPathComponent("native-speaker-\(UUID().uuidString).wav")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let analysis = try await service.importFile(meeting: meeting, file: file, kind: .importedAudio, origin: original) { _ in
            try MediaTimeRange(start: 0, end: 8)
        }
        let trackA = try await service.resolveEngineSpeaker(meeting: meeting, scope: "native|" + original.description, label: UUID().uuidString)
        let a = try XCTUnwrap(trackA)
        let b = try await service.addSpeaker(meeting: meeting, label: "User name", userNamed: true)
        let row = try await service.appendFinal(meeting: meeting, session: analysis, text: "kept text", range: .init(start: 0, end: 2))
        let corrected = try await service.appendFinal(meeting: meeting, session: analysis, text: "manual attribution", range: .init(start: 2, end: 4))
        _ = try await service.reassignSegmentSpeaker(corrected.id, meeting: meeting, speaker: nil)
        _ = try await service.appendFinal(meeting: meeting, session: analysis, text: "named person", range: .init(start: 4, end: 6), speaker: b.id)
        let foreign = try await service.appendFinal(meeting: meeting, session: otherOriginal, text: "other original", range: .init(start: 0, end: 2))
        let partial = try await service.beginPartial(meeting: meeting, session: analysis, text: "real decoder draft")
        await service.updatePartial(partial, meeting: meeting, text: "revised draft")
        await service.discardPartial(partial, meeting: meeting)
        let partials = await service.currentPartials(meeting: meeting)
        XCTAssertTrue(partials.isEmpty)
        let window = try MediaTimeRange(start: 0, end: 6)
        let spans = [RecordingSpeakerSpan(range: window, speaker: a)]
        let changed = try await service.applyRecordingSpeakers(meeting: meeting, original: original, window: window, spans: spans)
        XCTAssertEqual(changed, 1)
        let reopened = MeetingService(database: try MeetingDatabase(path: url.path))
        let rows = try await reopened.transcript(meeting: meeting)
        XCTAssertEqual(rows.count, 4, "partial text is never committed by attribution")
        let adopted = try XCTUnwrap(rows.first { $0.id == row.id })
        XCTAssertEqual(adopted.speakerID, a); XCTAssertEqual(adopted.text, "kept text")
        XCTAssertEqual(adopted.range, row.range); XCTAssertEqual(adopted.source, row.source)
        XCTAssertNil(rows.first { $0.id == corrected.id }?.speakerID)
        XCTAssertNil(rows.first { $0.id == foreign.id }?.speakerID)
        XCTAssertEqual(rows.first { $0.text == "named person" }?.speakerID, b.id)
        try await reopened.renameSpeaker(a, meeting: meeting, to: "Alice", byUser: true)
        try await reopened.mergeSpeaker(a, into: b.id, meeting: meeting)
        let afterMerge = try await reopened.applyRecordingSpeakers(meeting: meeting, original: original, window: window, spans: spans)
        XCTAssertEqual(afterMerge, 0, "late native projection cannot undo a rename, merge or manual clear")
        let resolved = try await reopened.resolveSpeaker(a, meeting: meeting)
        XCTAssertEqual(resolved, b.id)
        do {
            _ = try await reopened.applyRecordingSpeakers(meeting: meeting, original: analysis, window: window, spans: spans)
            XCTFail("an analysis child cannot acquire original ownership")
        } catch MeetingError.captureSessionEnded { }
    }
}
